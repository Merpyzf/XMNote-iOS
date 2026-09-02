#!/usr/bin/env python3
"""Compare book-alignment transitions with strict and semantic privacy-safe oracles."""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import pathlib
import sqlite3
import sys
from dataclasses import dataclass
from types import ModuleType
from typing import Any, Iterable

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from book_alignment.common import (  # type: ignore[import-not-found]
        AlignmentError,
        file_sha256,
        foreign_key_summary,
        immutable_connection,
        inspect_database,
        json_digest,
        load_json,
        privacy_policy,
        resolve_default_baseline,
        schema_fingerprint,
        utc_now,
        write_json_exclusive,
    )
    from book_alignment.contract import (  # type: ignore[import-not-found]
        ContractBundle,
        load_contract_bundle,
    )
else:
    from .common import (
        AlignmentError,
        file_sha256,
        foreign_key_summary,
        immutable_connection,
        inspect_database,
        json_digest,
        load_json,
        privacy_policy,
        resolve_default_baseline,
        schema_fingerprint,
        utc_now,
        write_json_exclusive,
    )
    from .contract import ContractBundle, load_contract_bundle


ROLE_NAMES = ("androidBefore", "iosBefore", "androidAfter", "iosAfter")


@dataclass
class TableDelta:
    """In-memory row changes; reports expose only counts, columns and key digests."""

    table: str
    columns: list[str]
    before_rows: dict[tuple[Any, ...], dict[str, Any]]
    after_rows: dict[tuple[Any, ...], dict[str, Any]]
    added: set[tuple[Any, ...]]
    removed: set[tuple[Any, ...]]
    updated: dict[tuple[Any, ...], set[str]]


@dataclass
class PlatformDelta:
    """All logical row mutations made by one platform during a transition."""

    platform: str
    tables: dict[str, TableDelta]
    schema_failures: list[dict[str, Any]]

    @property
    def has_changes(self) -> bool:
        return any(
            delta.added or delta.removed or delta.updated
            for delta in self.tables.values()
        ) or bool(self.schema_failures)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Replay S2→S3 or S3→S4 database contracts using the existing parity "
            "digests plus write-set, time-window, FK and semantic assertions."
        )
    )
    parser.add_argument("--case", type=pathlib.Path, required=True)
    parser.add_argument("--bindings", type=pathlib.Path, required=True)
    parser.add_argument("--runtime-profile", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--android-before", type=pathlib.Path, required=True)
    parser.add_argument("--ios-before", type=pathlib.Path, required=True)
    parser.add_argument("--android-after", type=pathlib.Path, required=True)
    parser.add_argument("--ios-after", type=pathlib.Path, required=True)
    parser.add_argument("--android-before-manifest", type=pathlib.Path)
    parser.add_argument("--ios-before-manifest", type=pathlib.Path)
    parser.add_argument("--android-after-manifest", type=pathlib.Path)
    parser.add_argument("--ios-after-manifest", type=pathlib.Path)
    parser.add_argument(
        "--transition", choices=("operation", "stability"), default="operation"
    )
    parser.add_argument(
        "--android-window-millis", type=int, nargs=2, metavar=("START", "END")
    )
    parser.add_argument(
        "--ios-window-millis", type=int, nargs=2, metavar=("START", "END")
    )
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument(
        "--skip-missing-private-inputs",
        action="store_true",
        help="emit SKIP and exit 77 when B0/bindings/profile/snapshots are absent",
    )
    parser.add_argument(
        "--allow-missing-manifests",
        action="store_true",
        help="ad-hoc diagnostics only; formal replay requires snapshot manifests",
    )
    return parser.parse_args(argv)


def _load_parity_module() -> ModuleType:
    """Load the established privacy-safe diff implementation without copying it."""

    module_path = (
        pathlib.Path(__file__).resolve().parents[1]
        / "desktop_web_api_parity"
        / "compare_database_parity.py"
    )
    spec = importlib.util.spec_from_file_location(
        "xmnote_desktop_database_parity", module_path
    )
    if spec is None or spec.loader is None:
        raise AlignmentError("Unable to load existing database parity tool")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _input_paths(args: argparse.Namespace) -> dict[str, pathlib.Path]:
    return {
        "baseline": (args.baseline or resolve_default_baseline()).expanduser(),
        "bindings": args.bindings.expanduser(),
        "runtimeProfile": args.runtime_profile.expanduser(),
        "androidBefore": args.android_before.expanduser(),
        "iosBefore": args.ios_before.expanduser(),
        "androidAfter": args.android_after.expanduser(),
        "iosAfter": args.ios_after.expanduser(),
    }


def _missing_inputs(paths: dict[str, pathlib.Path]) -> list[str]:
    return sorted(name for name, path in paths.items() if not path.is_file())


def _skip_report(args: argparse.Namespace, missing: list[str]) -> int:
    report = {
        "schemaVersion": 1,
        "tool": "book-alignment-compare",
        "generatedAt": utc_now(),
        "dataPolicy": privacy_policy(),
        "result": "SKIP",
        "passed": False,
        "skipReason": "missing-private-baseline"
        if "baseline" in missing
        else "missing-private-inputs",
        "missingRoles": missing,
    }
    write_json_exclusive(args.output, report)
    if "baseline" in missing:
        print("SKIP: missing private baseline")
    else:
        print("SKIP: missing private book-alignment inputs")
    return 77


def _manifest_arguments(args: argparse.Namespace) -> dict[str, pathlib.Path]:
    explicit = {
        "androidBefore": args.android_before_manifest,
        "iosBefore": args.ios_before_manifest,
        "androidAfter": args.android_after_manifest,
        "iosAfter": args.ios_after_manifest,
    }
    databases = {
        "androidBefore": args.android_before,
        "iosBefore": args.ios_before,
        "androidAfter": args.android_after,
        "iosAfter": args.ios_after,
    }
    return {
        role: (path if path is not None else pathlib.Path(f"{databases[role]}.manifest.json"))
        for role, path in explicit.items()
    }


def _parse_timestamp_millis(value: Any) -> int:
    if not isinstance(value, str):
        raise AlignmentError("Snapshot manifest generatedAt must be an ISO-8601 string")
    try:
        timestamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise AlignmentError("Snapshot manifest generatedAt is invalid") from error
    if timestamp.tzinfo is None:
        raise AlignmentError("Snapshot manifest generatedAt must include a timezone")
    return int(timestamp.timestamp() * 1000)


def _validate_manifests(
    args: argparse.Namespace,
    bundle: ContractBundle,
    database_paths: dict[str, pathlib.Path],
) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    manifests: dict[str, dict[str, Any]] = {}
    failures: list[dict[str, Any]] = []
    expected_stages = (
        {"androidBefore": "S2", "iosBefore": "S2", "androidAfter": "S3", "iosAfter": "S3"}
        if args.transition == "operation"
        else {"androidBefore": "S3", "iosBefore": "S3", "androidAfter": "S4", "iosAfter": "S4"}
    )
    expected_platforms = {
        "androidBefore": "android",
        "androidAfter": "android",
        "iosBefore": "ios",
        "iosAfter": "ios",
    }
    for role, manifest_path in _manifest_arguments(args).items():
        if not manifest_path.is_file():
            if not args.allow_missing_manifests:
                failures.append({"role": role, "reason": "missing-snapshot-manifest"})
            continue
        try:
            manifest = load_json(manifest_path)
        except AlignmentError:
            failures.append({"role": role, "reason": "invalid-snapshot-manifest"})
            continue
        manifests[role] = manifest
        checks = {
            "case-id": manifest.get("caseId") == bundle.case["caseId"],
            "platform": manifest.get("platform") == expected_platforms[role],
            "stage": manifest.get("stage") == expected_stages[role],
            "lineage": manifest.get("baselineSha256")
            == bundle.resolved_case["baseline"]["sha256"],
            "capture-passed": manifest.get("passed") is True,
            "snapshot-sha256": manifest.get("snapshot", {}).get("sha256")
            == file_sha256(database_paths[role]),
        }
        for reason, passed in checks.items():
            if not passed:
                failures.append({"role": role, "reason": reason})
        try:
            _parse_timestamp_millis(manifest.get("generatedAt"))
        except AlignmentError:
            failures.append({"role": role, "reason": "generated-at"})
    return manifests, failures


def _operation_windows(
    args: argparse.Namespace,
    manifests: dict[str, dict[str, Any]],
) -> dict[str, tuple[int, int] | None]:
    windows: dict[str, tuple[int, int] | None] = {}
    explicit = {
        "android": args.android_window_millis,
        "ios": args.ios_window_millis,
    }
    for platform in ("android", "ios"):
        if explicit[platform] is not None:
            start, end = map(int, explicit[platform])
            if start > end:
                raise AlignmentError(f"{platform} operation window start exceeds end")
            windows[platform] = (start, end)
            continue
        before = manifests.get(f"{platform}Before")
        after = manifests.get(f"{platform}After")
        if before is None or after is None:
            windows[platform] = None
            continue
        start = _parse_timestamp_millis(before["generatedAt"])
        end = _parse_timestamp_millis(after["generatedAt"])
        if start > end:
            raise AlignmentError(f"{platform} snapshot timestamps are reversed")
        windows[platform] = (start, end)
    return windows


def _platform_delta(
    parity: ModuleType,
    platform: str,
    before: sqlite3.Connection,
    after: sqlite3.Connection,
) -> PlatformDelta:
    before_tables = parity.table_names(before)
    after_tables = parity.table_names(after)
    failures: list[dict[str, Any]] = []
    if before_tables != after_tables:
        failures.append(
            {
                "reason": "table-set-mutated",
                "beforeDigest": json_digest(before_tables),
                "afterDigest": json_digest(after_tables),
            }
        )
    table_deltas: dict[str, TableDelta] = {}
    for table in sorted(set(before_tables) & set(after_tables)):
        before_schema = parity.columns(before, table)
        after_schema = parity.columns(after, table)
        if before_schema != after_schema:
            failures.append(
                {
                    "table": table,
                    "reason": "column-or-primary-key-schema-mutated",
                    "beforeDigest": json_digest(before_schema),
                    "afterDigest": json_digest(after_schema),
                }
            )
            continue
        column_names, primary_keys = before_schema
        before_rows = parity.rows_by_key(before, table, column_names, primary_keys)
        after_rows = parity.rows_by_key(after, table, column_names, primary_keys)
        added = set(after_rows) - set(before_rows)
        removed = set(before_rows) - set(after_rows)
        updated: dict[tuple[Any, ...], set[str]] = {}
        for key in set(before_rows) & set(after_rows):
            changed_columns = {
                column
                for column in column_names
                if before_rows[key][column] != after_rows[key][column]
            }
            if changed_columns:
                updated[key] = changed_columns
        table_deltas[table] = TableDelta(
            table=table,
            columns=column_names,
            before_rows=before_rows,
            after_rows=after_rows,
            added=added,
            removed=removed,
            updated=updated,
        )
    return PlatformDelta(platform=platform, tables=table_deltas, schema_failures=failures)


def _delta_summary(delta: PlatformDelta) -> dict[str, Any]:
    tables = []
    for table, change in sorted(delta.tables.items()):
        if not (change.added or change.removed or change.updated):
            continue
        updated_columns = sorted(
            {column for columns in change.updated.values() for column in columns}
        )
        tables.append(
            {
                "table": table,
                "insertedRows": len(change.added),
                "deletedRows": len(change.removed),
                "updatedRows": len(change.updated),
                "updatedColumns": updated_columns,
            }
        )
    return {
        "platform": delta.platform,
        "changedTableCount": len(tables),
        "tables": tables,
        "schemaFailures": delta.schema_failures,
    }


def _rule_matches_write(
    rule: dict[str, Any], platform: str, table: str, operation: str, column: str | None
) -> bool:
    if platform not in rule["platforms"] or table != rule["table"]:
        return False
    if operation not in rule["operations"]:
        return False
    if operation != "update":
        return True
    return column is not None and (
        "*" in rule.get("columns", []) or column in rule.get("columns", [])
    )


def _write_policy(
    case: dict[str, Any], deltas: Iterable[PlatformDelta], transition: str
) -> dict[str, Any]:
    allowed = case["database"]["allowedWrites"]
    forbidden = case["database"]["forbiddenWrites"]
    violations: list[dict[str, Any]] = []
    changed_operations = 0
    for platform_delta in deltas:
        for table, delta in sorted(platform_delta.tables.items()):
            operations: list[tuple[str, str | None, int]] = []
            if delta.added:
                operations.append(("insert", None, len(delta.added)))
            if delta.removed:
                operations.append(("delete", None, len(delta.removed)))
            update_counts: dict[str, int] = {}
            for columns in delta.updated.values():
                for column in columns:
                    update_counts[column] = update_counts.get(column, 0) + 1
            operations.extend(
                ("update", column, count)
                for column, count in sorted(update_counts.items())
            )
            for operation, column, count in operations:
                changed_operations += 1
                item = {
                    "platform": platform_delta.platform,
                    "table": table,
                    "operation": operation,
                    "count": count,
                }
                if column is not None:
                    item["column"] = column
                if transition == "stability":
                    violations.append({**item, "reason": "s3-s4-must-be-stable"})
                    continue
                if case["intent"]["outcome"] == "cancelled":
                    violations.append({**item, "reason": "cancel-must-not-write"})
                    continue
                if any(
                    _rule_matches_write(
                        rule, platform_delta.platform, table, operation, column
                    )
                    for rule in forbidden
                ):
                    violations.append({**item, "reason": "forbidden-write"})
                    continue
                if not any(
                    _rule_matches_write(
                        rule, platform_delta.platform, table, operation, column
                    )
                    for rule in allowed
                ):
                    violations.append({**item, "reason": "write-not-whitelisted"})
    for delta in deltas:
        violations.extend(
            {"platform": delta.platform, **failure}
            for failure in delta.schema_failures
        )
    return {
        "passed": not violations,
        "changedOperations": changed_operations,
        "violations": violations,
    }


def _strict_rules(
    parity: ModuleType, case: dict[str, Any]
) -> tuple[dict[tuple[str, str], Any], dict[str, Any]]:
    epoch_rules = {
        (rule["table"], rule["column"]): parity.EpochRule(
            table=rule["table"], column=rule["column"], reason=rule["reason"]
        )
        for rule in case["database"]["timeColumns"]
    }
    stable_tables = {
        rule["table"]: parity.StablePlatformTableRule(
            table=rule["table"], reason=rule["reason"]
        )
        for rule in case["database"]["platformInternalTables"]
    }
    return epoch_rules, stable_tables


def _exception_matches(rule: dict[str, Any], mismatch: dict[str, Any]) -> bool:
    if mismatch.get("reason") not in rule["reasons"]:
        return False
    for field in ("table", "column", "androidCount", "iosCount"):
        if field in rule and mismatch.get(field) != rule[field]:
            return False
    return True


def _classify_strict(
    base: dict[str, Any], case: dict[str, Any], transition: str
) -> dict[str, Any]:
    # Strict exceptions describe the intentionally different database result of
    # the user operation.  They must not weaken S3→S4: restart stability is
    # always exact, and operation-only exceptions are therefore neither matched
    # nor reported as stale during that transition.
    rules = (
        case["database"]["strictExceptions"]
        if transition == "operation"
        else []
    )
    matched_counts = {rule["code"]: 0 for rule in rules}
    approved: list[dict[str, Any]] = []
    unapproved: list[dict[str, Any]] = []
    for mismatch in base["mismatches"]:
        matched_rule = next(
            (
                rule
                for rule in rules
                if matched_counts[rule["code"]] < rule["maxMatches"]
                and _exception_matches(rule, mismatch)
            ),
            None,
        )
        if matched_rule is None:
            unapproved.append(mismatch)
            continue
        code = matched_rule["code"]
        matched_counts[code] += 1
        approved.append(
            {
                "exceptionCode": code,
                "mismatchDigest": json_digest(mismatch),
                "reason": mismatch.get("reason"),
                **({"table": mismatch["table"]} if "table" in mismatch else {}),
                **({"column": mismatch["column"]} if "column" in mismatch else {}),
            }
        )
    unused = sorted(code for code, count in matched_counts.items() if count == 0)
    passed = not unapproved and not unused
    return {
        "passed": passed,
        "strictExact": not base["mismatches"],
        "schemaExact": base["schemaExact"],
        "schemaStableWithinEachPlatform": base["schemaStableWithinEachPlatform"],
        "comparedTables": base["comparedTables"],
        "comparedMutatedCells": base["comparedMutatedCells"],
        "androidChangedCells": base["androidChangedCells"],
        "iosChangedCells": base["iosChangedCells"],
        "normalizedEpochCells": base["normalizedEpochCells"],
        "normalizations": base["normalizations"],
        "stablePlatformTables": base["stablePlatformTables"],
        "approvedExceptions": approved,
        "unusedExceptionCodes": unused,
        "unapprovedMismatches": unapproved,
    }


def _before_parity(
    parity: ModuleType,
    android: sqlite3.Connection,
    ios: sqlite3.Connection,
    excluded_tables: set[str],
) -> dict[str, Any]:
    android_tables = set(parity.table_names(android)) - excluded_tables
    ios_tables = set(parity.table_names(ios)) - excluded_tables
    mismatches: list[dict[str, Any]] = []
    if android_tables != ios_tables:
        mismatches.append(
            {
                "reason": "business-table-set",
                "androidDigest": json_digest(sorted(android_tables)),
                "iosDigest": json_digest(sorted(ios_tables)),
            }
        )
    compared_cells = 0
    for table in sorted(android_tables & ios_tables):
        android_schema = parity.columns(android, table)
        ios_schema = parity.columns(ios, table)
        if android_schema != ios_schema:
            mismatches.append(
                {
                    "table": table,
                    "reason": "business-schema",
                    "androidDigest": json_digest(android_schema),
                    "iosDigest": json_digest(ios_schema),
                }
            )
            continue
        columns, primary_keys = android_schema
        android_rows = parity.rows_by_key(android, table, columns, primary_keys)
        ios_rows = parity.rows_by_key(ios, table, columns, primary_keys)
        if set(android_rows) != set(ios_rows):
            mismatches.append(
                {
                    "table": table,
                    "reason": "business-row-key-set",
                    "androidCount": len(android_rows),
                    "iosCount": len(ios_rows),
                    "androidDigest": json_digest(sorted(map(json_digest, android_rows))),
                    "iosDigest": json_digest(sorted(map(json_digest, ios_rows))),
                }
            )
            continue
        for key in sorted(android_rows, key=json_digest):
            for column in columns:
                compared_cells += 1
                if android_rows[key][column] != ios_rows[key][column]:
                    mismatches.append(
                        {
                            "table": table,
                            "column": column,
                            "keyDigest": json_digest(key),
                            "reason": "business-value",
                            "androidDigest": json_digest(android_rows[key][column]),
                            "iosDigest": json_digest(ios_rows[key][column]),
                        }
                    )
    return {
        "passed": not mismatches,
        "comparedTables": len(android_tables & ios_tables),
        "comparedCells": compared_cells,
        "mismatches": mismatches,
    }


def _before_parity_for_transition(
    parity: ModuleType,
    android: sqlite3.Connection,
    ios: sqlite3.Connection,
    excluded_tables: set[str],
    transition: str,
) -> dict[str, Any]:
    """Require a shared S2 only for the operation; S3 may contain approved divergence."""

    if transition == "stability":
        return {
            "applicable": False,
            "passed": True,
            "reason": "stability-compares-each-platform-s3-to-s4",
            "comparedTables": 0,
            "comparedCells": 0,
            "mismatches": [],
        }
    return {
        "applicable": True,
        **_before_parity(parity, android, ios, excluded_tables),
    }


def _time_validation(
    case: dict[str, Any],
    deltas: dict[str, PlatformDelta],
    windows: dict[str, tuple[int, int] | None],
    parity: ModuleType,
) -> dict[str, Any]:
    violations: list[dict[str, Any]] = []
    rule_results: list[dict[str, Any]] = []
    for rule in case["database"]["timeColumns"]:
        for platform in ("android", "ios"):
            table_delta = deltas[platform].tables.get(rule["table"])
            checked = 0
            if table_delta is None or rule["column"] not in table_delta.columns:
                violations.append(
                    {
                        "platform": platform,
                        "table": rule["table"],
                        "column": rule["column"],
                        "reason": "time-column-not-found",
                    }
                )
                continue
            candidates: list[tuple[tuple[Any, ...], Any | None, Any, bool]] = []
            for key in table_delta.added:
                candidates.append(
                    (key, None, table_delta.after_rows[key][rule["column"]], True)
                )
            for key, columns in table_delta.updated.items():
                if rule["column"] in columns:
                    candidates.append(
                        (
                            key,
                            table_delta.before_rows[key][rule["column"]],
                            table_delta.after_rows[key][rule["column"]],
                            False,
                        )
                    )
            for key, before_value, after_value, inserted in candidates:
                checked += 1
                item = {
                    "platform": platform,
                    "table": rule["table"],
                    "column": rule["column"],
                    "keyDigest": parity.digest(key),
                }
                if isinstance(after_value, bool) or not isinstance(
                    after_value, (int, float)
                ):
                    violations.append({**item, "reason": "time-value-not-numeric"})
                    continue
                if after_value < 0:
                    violations.append({**item, "reason": "time-value-negative"})
                    continue
                if inserted and after_value == 0 and rule["allowZeroOnInsert"]:
                    continue
                if (
                    not inserted
                    and rule["monotonic"]
                    and (
                        isinstance(before_value, bool)
                        or not isinstance(before_value, (int, float))
                        or after_value < before_value
                    )
                ):
                    violations.append({**item, "reason": "time-not-monotonic"})
                    continue
                if rule["requireOperationWindow"]:
                    window = windows[platform]
                    if window is None:
                        violations.append({**item, "reason": "missing-operation-window"})
                        continue
                    millis = (
                        float(after_value) * 1000
                        if rule["unit"] == "epoch-seconds"
                        else float(after_value)
                    )
                    tolerance = int(rule.get("toleranceMillis", 0))
                    if not window[0] - tolerance <= millis <= window[1] + tolerance:
                        violations.append({**item, "reason": "time-outside-operation-window"})
            rule_results.append(
                {
                    "platform": platform,
                    "table": rule["table"],
                    "column": rule["column"],
                    "unit": rule["unit"],
                    "monotonic": rule["monotonic"],
                    "requireOperationWindow": rule["requireOperationWindow"],
                    "checkedChangedValues": checked,
                }
            )
    return {"passed": not violations, "rules": rule_results, "violations": violations}


def _compact_database_check(
    path: pathlib.Path,
    expected: dict[str, Any],
    excluded_tables: set[str],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    metadata = inspect_database(path)
    connection = immutable_connection(path)
    try:
        business_schema = schema_fingerprint(connection, excluded_tables)
    finally:
        connection.close()
    failures: list[dict[str, Any]] = []
    if metadata["integrityCheck"]["status"] != "ok":
        failures.append({"reason": "integrity-check"})
    if metadata["quickCheck"]["status"] != "ok":
        failures.append({"reason": "quick-check"})
    if metadata["userVersion"] != expected["userVersion"]:
        failures.append(
            {
                "reason": "user-version",
                "expected": expected["userVersion"],
                "actual": metadata["userVersion"],
            }
        )
    if metadata["roomIdentityHash"] != expected["roomIdentityHash"]:
        failures.append({"reason": "room-identity-hash"})
    if business_schema["sha256"] != expected["schemaFingerprint"]:
        failures.append(
            {
                "reason": "business-schema-fingerprint",
                "expected": expected["schemaFingerprint"],
                "actual": business_schema["sha256"],
            }
        )
    return (
        {
            "sha256": file_sha256(path),
            "integrityCheck": metadata["integrityCheck"],
            "quickCheck": metadata["quickCheck"],
            "userVersion": metadata["userVersion"],
            "roomIdentityHash": metadata["roomIdentityHash"],
            "businessSchemaFingerprint": business_schema,
            "foreignKeyCheck": metadata["foreignKeyCheck"],
        },
        failures,
    )


def _foreign_key_delta(
    baseline: dict[str, Any],
    checks: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    failures: list[dict[str, Any]] = []
    baseline_set = set(baseline["foreignKeyCheck"]["violationDigests"])
    for platform in ("android", "ios"):
        before = checks[f"{platform}Before"]["foreignKeyCheck"]
        after = checks[f"{platform}After"]["foreignKeyCheck"]
        before_set = set(before["violationDigests"])
        after_set = set(after["violationDigests"])
        preexisting_new = sorted(before_set - baseline_set)
        transition_new = sorted(after_set - before_set)
        if preexisting_new:
            failures.append(
                {
                    "platform": platform,
                    "reason": "scenario-start-added-foreign-key-violations",
                    "count": len(preexisting_new),
                    "violationDigests": preexisting_new,
                }
            )
        if transition_new:
            failures.append(
                {
                    "platform": platform,
                    "reason": "transition-added-foreign-key-violations",
                    "count": len(transition_new),
                    "violationDigests": transition_new,
                }
            )
    return {
        "passed": not failures,
        "baselineViolationCount": len(baseline_set),
        "failures": failures,
    }


def _projection_authorizer(
    action: int,
    _arg1: str | None,
    _arg2: str | None,
    _database: str | None,
    _trigger: str | None,
) -> int:
    denied_names = (
        "SQLITE_INSERT",
        "SQLITE_UPDATE",
        "SQLITE_DELETE",
        "SQLITE_CREATE_INDEX",
        "SQLITE_CREATE_TABLE",
        "SQLITE_CREATE_TEMP_INDEX",
        "SQLITE_CREATE_TEMP_TABLE",
        "SQLITE_CREATE_TEMP_TRIGGER",
        "SQLITE_CREATE_TEMP_VIEW",
        "SQLITE_CREATE_TRIGGER",
        "SQLITE_CREATE_VIEW",
        "SQLITE_DROP_INDEX",
        "SQLITE_DROP_TABLE",
        "SQLITE_DROP_TEMP_INDEX",
        "SQLITE_DROP_TEMP_TABLE",
        "SQLITE_DROP_TEMP_TRIGGER",
        "SQLITE_DROP_TEMP_VIEW",
        "SQLITE_DROP_TRIGGER",
        "SQLITE_DROP_VIEW",
        "SQLITE_ALTER_TABLE",
        "SQLITE_ATTACH",
        "SQLITE_DETACH",
        "SQLITE_PRAGMA",
        "SQLITE_REINDEX",
        "SQLITE_ANALYZE",
    )
    denied = {getattr(sqlite3, name) for name in denied_names if hasattr(sqlite3, name)}
    return sqlite3.SQLITE_DENY if action in denied else sqlite3.SQLITE_OK


def _projection_parameters(
    projection: dict[str, Any], bindings: dict[str, Any]
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name, specification in projection["parameters"].items():
        if "binding" in specification:
            result[name] = bindings["aliases"][specification["binding"]]["id"]
        else:
            result[name] = specification["literal"]
    return result


def _canonical_projection(
    connection: sqlite3.Connection,
    projection: dict[str, Any],
    bindings: dict[str, Any],
) -> tuple[Any, int, list[dict[str, Any]]]:
    connection.set_authorizer(_projection_authorizer)
    try:
        cursor = connection.execute(
            projection["sql"], _projection_parameters(projection, bindings)
        )
        rows = cursor.fetchall()
        names = [str(item[0]) for item in (cursor.description or [])]
    finally:
        connection.set_authorizer(None)
    declared = [column["name"] for column in projection["columns"]]
    if names != declared:
        raise AlignmentError(
            f"Projection {projection['name']} output columns do not match its contract"
        )

    reverse: dict[tuple[str, Any], str] = {}
    for alias in bindings["aliases"].values():
        reverse[(alias["entity"], alias["id"])] = next(
            name for name, value in bindings["aliases"].items() if value is alias
        )
    alias_entities = {
        column["name"]: column.get("aliasEntity")
        for column in projection["columns"]
    }
    failures: list[dict[str, Any]] = []
    canonical_rows: list[dict[str, Any]] = []
    for row_index, row in enumerate(rows):
        canonical_row: dict[str, Any] = {}
        for column_name in names:
            value = row[column_name]
            entity = alias_entities[column_name]
            if entity is not None and value is not None:
                alias_name = reverse.get((entity, value))
                if alias_name is None:
                    failures.append(
                        {
                            "reason": "unbound-semantic-value",
                            "column": column_name,
                            "rowIndex": row_index,
                            "valueDigest": json_digest(value),
                        }
                    )
                    value = {"unboundValueDigest": json_digest(value)}
                else:
                    value = alias_name
            elif isinstance(value, bytes):
                value = {"blobSha256": json_digest(value), "byteCount": len(value)}
            canonical_row[column_name] = value
        canonical_rows.append(canonical_row)

    mode = projection["mode"]
    if mode == "unordered-rows":
        canonical_rows.sort(key=json_digest)
        return canonical_rows, len(canonical_rows), failures
    if mode == "scalar":
        if len(canonical_rows) != 1 or len(names) != 1:
            raise AlignmentError(
                f"Projection {projection['name']} scalar mode requires one row and column"
            )
        return canonical_rows[0][names[0]], 1, failures
    return canonical_rows, len(canonical_rows), failures


def _normalized_expected(projection: dict[str, Any], value: Any) -> Any:
    if projection["mode"] == "unordered-rows" and isinstance(value, list):
        return sorted(value, key=json_digest)
    return value


def _semantic_comparison(
    case: dict[str, Any],
    bindings: dict[str, Any],
    connections: dict[str, sqlite3.Connection],
    transition: str,
) -> dict[str, Any]:
    failures: list[dict[str, Any]] = []
    reports: list[dict[str, Any]] = []
    for projection in case["oracle"]["semanticProjections"]:
        actual: dict[str, Any] = {}
        role_reports: dict[str, Any] = {}
        try:
            for role in ROLE_NAMES:
                value, count, unbound = _canonical_projection(
                    connections[role], projection, bindings
                )
                actual[role] = value
                role_reports[role] = {
                    "rowCount": count,
                    "digest": json_digest(value),
                    "unboundValueCount": len(unbound),
                }
                failures.extend(
                    {
                        "projection": projection["name"],
                        "role": role,
                        **item,
                    }
                    for item in unbound
                )
        except (AlignmentError, sqlite3.Error) as error:
            failures.append(
                {
                    "projection": projection["name"],
                    "reason": "projection-query-failed",
                    "errorDigest": json_digest(str(error)),
                }
            )
            reports.append(
                {
                    "name": projection["name"],
                    "queryDigest": json_digest(projection["sql"]),
                    "passed": False,
                }
            )
            continue

        projection_failures_before = len(failures)
        expectations = projection["expected"]
        roles_to_check = (
            ROLE_NAMES
            if transition == "operation"
            else ("androidAfter", "iosAfter")
        )
        for role in roles_to_check:
            if role not in expectations:
                continue
            expected = _normalized_expected(projection, expectations[role])
            if actual[role] != expected:
                failures.append(
                    {
                        "projection": projection["name"],
                        "role": role,
                        "reason": "semantic-expectation",
                        "expectedDigest": json_digest(expected),
                        "actualDigest": json_digest(actual[role]),
                    }
                )
        if transition == "stability":
            for platform in ("android", "ios"):
                if actual[f"{platform}Before"] != actual[f"{platform}After"]:
                    failures.append(
                        {
                            "projection": projection["name"],
                            "platform": platform,
                            "reason": "s3-s4-semantic-instability",
                            "beforeDigest": json_digest(actual[f"{platform}Before"]),
                            "afterDigest": json_digest(actual[f"{platform}After"]),
                        }
                    )
        if (
            projection["compareAndroidIOSAfter"]
            and actual["androidAfter"] != actual["iosAfter"]
        ):
            failures.append(
                {
                    "projection": projection["name"],
                    "reason": "cross-platform-after-semantic-delta",
                    "androidDigest": json_digest(actual["androidAfter"]),
                    "iosDigest": json_digest(actual["iosAfter"]),
                }
            )
        reports.append(
            {
                "name": projection["name"],
                "queryDigest": json_digest(projection["sql"]),
                "roles": role_reports,
                "passed": len(failures) == projection_failures_before,
            }
        )
    return {"passed": not failures, "projections": reports, "failures": failures}


def compare(args: argparse.Namespace) -> int:
    paths = _input_paths(args)
    missing = _missing_inputs(paths)
    if missing:
        if args.skip_missing_private_inputs:
            return _skip_report(args, missing)
        raise AlignmentError("Missing required inputs: " + ", ".join(missing))
    if args.output.exists():
        raise AlignmentError(f"Refusing to overwrite existing report: {args.output}")

    bundle = load_contract_bundle(
        args.case,
        paths["bindings"],
        paths["runtimeProfile"],
        runnable=True,
    )
    case = bundle.resolved_case
    baseline_path = paths["baseline"]
    baseline_sha = file_sha256(baseline_path)
    if baseline_sha != case["baseline"]["sha256"]:
        raise AlignmentError("Private B0 SHA-256 does not match the case contract")

    database_paths = {role: paths[role] for role in ROLE_NAMES}
    manifests, manifest_failures = _validate_manifests(
        args, bundle, database_paths
    )
    windows = _operation_windows(args, manifests)
    parity = _load_parity_module()
    excluded_tables = {
        rule["table"] for rule in case["database"]["platformInternalTables"]
    }

    database_checks: dict[str, dict[str, Any]] = {}
    database_failures: list[dict[str, Any]] = []
    baseline_check, baseline_failures = _compact_database_check(
        baseline_path, case["baseline"], excluded_tables
    )
    database_checks["baseline"] = baseline_check
    database_failures.extend(
        {"role": "baseline", **failure} for failure in baseline_failures
    )
    target_database = case.get("targetDatabase", case["baseline"])
    for role, path in database_paths.items():
        check, failures = _compact_database_check(
            path, target_database, excluded_tables
        )
        database_checks[role] = check
        database_failures.extend(
            {"role": role, **failure} for failure in failures
        )

    connections = {
        role: immutable_connection(path) for role, path in database_paths.items()
    }
    try:
        android_delta = _platform_delta(
            parity,
            "android",
            connections["androidBefore"],
            connections["androidAfter"],
        )
        ios_delta = _platform_delta(
            parity,
            "ios",
            connections["iosBefore"],
            connections["iosAfter"],
        )
        epoch_rules, stable_tables = _strict_rules(parity, case)
        base_strict = parity.compare_database_deltas(
            connections["androidBefore"],
            connections["iosBefore"],
            connections["androidAfter"],
            connections["iosAfter"],
            epoch_rules,
            stable_tables,
        )
        strict = _classify_strict(base_strict, case, args.transition)
        before_parity = _before_parity_for_transition(
            parity,
            connections["androidBefore"],
            connections["iosBefore"],
            excluded_tables,
            args.transition,
        )
        semantic = _semantic_comparison(
            case, bundle.bindings, connections, args.transition
        )
    finally:
        for connection in connections.values():
            connection.close()

    deltas = {"android": android_delta, "ios": ios_delta}
    write_policy = _write_policy(
        case, (android_delta, ios_delta), args.transition
    )
    time_validation = _time_validation(case, deltas, windows, parity)
    foreign_keys = _foreign_key_delta(baseline_check, database_checks)
    health_passed = not database_failures
    manifest_passed = not manifest_failures
    passed = all(
        (
            health_passed,
            manifest_passed,
            before_parity["passed"],
            strict["passed"],
            write_policy["passed"],
            time_validation["passed"],
            foreign_keys["passed"],
            semantic["passed"],
        )
    )
    has_approved_exception = bool(strict["approvedExceptions"])
    result = (
        "FAIL"
        if not passed
        else "PASS_WITH_DECLARED_EXCEPTION"
        if has_approved_exception
        else "PASS"
    )
    report = {
        "schemaVersion": 1,
        "tool": "book-alignment-compare",
        "generatedAt": utc_now(),
        "dataPolicy": privacy_policy(),
        "caseId": case["caseId"],
        "caseStatus": case["status"],
        "transition": args.transition,
        "result": result,
        "passed": passed,
        "baselineSha256": baseline_sha,
        "manifestValidation": {
            "passed": manifest_passed,
            "validatedCount": len(manifests),
            "failures": manifest_failures,
        },
        "databaseValidation": {
            "passed": health_passed,
            "checks": database_checks,
            "failures": database_failures,
        },
        "beforeParity": before_parity,
        "strictComparison": strict,
        "writeSet": {
            "android": _delta_summary(android_delta),
            "ios": _delta_summary(ios_delta),
            "policy": write_policy,
        },
        "timeValidation": time_validation,
        "foreignKeyValidation": foreign_keys,
        "semanticComparison": semantic,
    }
    write_json_exclusive(args.output, report)
    print(
        f"{result} {case['caseId']} {args.transition}: "
        f"strictMismatches={len(strict['unapprovedMismatches'])} "
        f"approvedExceptions={len(strict['approvedExceptions'])} "
        f"writeViolations={len(write_policy['violations'])} "
        f"semanticFailures={len(semantic['failures'])}; report={args.output}"
    )
    return 0 if passed else 1


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return compare(args)
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except sqlite3.Error as error:
        print(f"ERROR: SQLite comparison failed ({json_digest(str(error))})", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
