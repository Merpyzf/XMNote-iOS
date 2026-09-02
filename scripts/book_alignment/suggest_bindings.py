#!/usr/bin/env python3
"""Resolve declared aliases from private B0 without printing candidate payloads."""

from __future__ import annotations

import argparse
import pathlib
import sqlite3
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from book_alignment.common import (  # type: ignore[import-not-found]
        AlignmentError,
        file_sha256,
        immutable_connection,
        inspect_database,
        json_digest,
        privacy_policy,
        resolve_default_baseline,
        utc_now,
        write_json_exclusive,
    )
    from book_alignment.contract import (  # type: ignore[import-not-found]
        validate_bindings_payload,
        validate_case_payload,
        validate_runtime_profile_payload,
    )
    from book_alignment.common import load_json  # type: ignore[import-not-found]
else:
    from .common import (
        AlignmentError,
        file_sha256,
        immutable_connection,
        inspect_database,
        json_digest,
        load_json,
        privacy_policy,
        resolve_default_baseline,
        utc_now,
        write_json_exclusive,
    )
    from .contract import (
        validate_bindings_payload,
        validate_case_payload,
        validate_runtime_profile_payload,
    )


SELECTOR_QUERIES = {
    "active-book": """
        SELECT b.id AS candidate_id, b.name AS private_label
        FROM book AS b
        WHERE b.is_deleted = 0
        ORDER BY b.id
    """,
    "active-ungrouped-book": """
        SELECT b.id AS candidate_id, b.name AS private_label
        FROM book AS b
        WHERE b.is_deleted = 0
          AND NOT EXISTS (
              SELECT 1
              FROM group_book AS gb
              INNER JOIN "group" AS g ON g.id = gb.group_id
              WHERE gb.book_id = b.id
                AND gb.is_deleted = 0
                AND g.is_deleted = 0
          )
        ORDER BY b.id
    """,
    "active-empty-group": """
        SELECT g.id AS candidate_id, g.name AS private_label
        FROM "group" AS g
        WHERE g.is_deleted = 0
          AND NOT EXISTS (
              SELECT 1
              FROM group_book AS gb
              INNER JOIN book AS b ON b.id = gb.book_id
              WHERE gb.group_id = g.id
                AND gb.is_deleted = 0
                AND b.is_deleted = 0
          )
        ORDER BY g.id
    """,
    "active-non-empty-group": """
        SELECT g.id AS candidate_id, g.name AS private_label
        FROM "group" AS g
        WHERE g.is_deleted = 0
          AND EXISTS (
              SELECT 1
              FROM group_book AS gb
              INNER JOIN book AS b ON b.id = gb.book_id
              WHERE gb.group_id = g.id
                AND gb.is_deleted = 0
                AND b.is_deleted = 0
          )
        ORDER BY g.id
    """,
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Resolve case selectors against immutable B0 and write real IDs/labels only "
            "to an ignored 0600 bindings.json."
        )
    )
    parser.add_argument("--case", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--runtime-profile", type=pathlib.Path, required=True)
    parser.add_argument("--setup-sql", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--report", type=pathlib.Path)
    parser.add_argument("--skip-missing-private-baseline", action="store_true")
    return parser.parse_args(argv)


def _enforce_ignored_output(path: pathlib.Path) -> None:
    repository_root = pathlib.Path(__file__).resolve().parents[2]
    resolved = path.resolve(strict=False)
    try:
        resolved.relative_to(repository_root)
    except ValueError:
        return
    ignored_root = repository_root / "artifacts" / "book-alignment"
    try:
        resolved.relative_to(ignored_root)
    except ValueError as error:
        raise AlignmentError(
            "bindings.json inside the repository must be under ignored "
            "artifacts/book-alignment/"
        ) from error


def _resolved_public_sha(value: str, actual: str, label: str) -> str:
    if value.startswith("${"):
        return actual
    if value != actual:
        raise AlignmentError(f"Public case {label} does not match the private input")
    return value


def _candidate_count(connection: sqlite3.Connection, query: str) -> int:
    normalized = query.strip().rstrip(";")
    return int(
        connection.execute(f"SELECT COUNT(*) FROM ({normalized}) AS candidates").fetchone()[0]
    )


def _choose_candidate(
    connection: sqlite3.Connection,
    query: str,
    entity: str,
    already_bound: set[tuple[str, Any]],
) -> dict[str, Any] | None:
    for row in connection.execute(query):
        candidate_id = row["candidate_id"]
        if isinstance(candidate_id, bool) or not isinstance(candidate_id, (int, str)):
            raise AlignmentError("Alias selector returned a non-scalar ID")
        if (entity, candidate_id) in already_bound:
            continue
        binding: dict[str, Any] = {"entity": entity, "id": candidate_id}
        private_label = row["private_label"]
        if private_label is not None:
            binding["privateLabel"] = str(private_label)
        return binding
    return None


def suggest(args: argparse.Namespace) -> int:
    output = args.output.expanduser()
    report_path = args.report or pathlib.Path(f"{output}.suggestion.json")
    _enforce_ignored_output(output)
    if output.exists():
        raise AlignmentError(f"Refusing to overwrite existing bindings: {output}")
    if report_path.exists():
        raise AlignmentError(f"Refusing to overwrite existing report: {report_path}")
    baseline = (args.baseline or resolve_default_baseline()).expanduser()
    if not baseline.is_file():
        if args.skip_missing_private_baseline:
            print("SKIP: missing private baseline")
            return 77
        raise AlignmentError("Private baseline does not exist")
    if not args.runtime_profile.is_file():
        raise AlignmentError("runtime-profile.json does not exist")
    case = validate_case_payload(load_json(args.case))
    profile = validate_runtime_profile_payload(load_json(args.runtime_profile))
    missing_settings = sorted(
        set(case["runtimeProfile"]["requiredSettings"])
        - set(profile["settings"])
    )
    if missing_settings:
        raise AlignmentError(
            "runtime profile is missing required settings: "
            + ", ".join(missing_settings)
        )

    metadata = inspect_database(baseline)
    if metadata["integrityCheck"]["status"] != "ok" or metadata["quickCheck"]["status"] != "ok":
        raise AlignmentError("Private B0 integrity validation failed")
    baseline_sha = _resolved_public_sha(
        case["baseline"]["sha256"], file_sha256(baseline), "baseline SHA"
    )
    schema_sha = _resolved_public_sha(
        case["baseline"]["schemaFingerprint"],
        metadata["schemaFingerprint"]["sha256"],
        "schema fingerprint",
    )
    profile_sha = _resolved_public_sha(
        case["runtimeProfile"]["sha256"],
        file_sha256(args.runtime_profile),
        "runtime profile SHA",
    )
    if metadata["userVersion"] != case["baseline"]["userVersion"]:
        raise AlignmentError("Private B0 user_version does not match the case")
    if metadata["roomIdentityHash"] != case["baseline"]["roomIdentityHash"]:
        raise AlignmentError("Private B0 Room identity does not match the case")

    setup_sha: str | None = None
    if case["setup"]["mode"] == "deterministic-sql":
        setup_path = args.setup_sql or (args.case.parent / case["setup"]["sqlFile"])
        if not setup_path.is_file():
            raise AlignmentError("Deterministic setup SQL file does not exist")
        setup_sha = _resolved_public_sha(
            case["setup"]["sha256"], file_sha256(setup_path), "setup SQL SHA"
        )
    elif args.setup_sql is not None:
        raise AlignmentError("--setup-sql is invalid when case.setup.mode is none")

    alias_entities = {alias["name"]: alias["entity"] for alias in case["aliases"]}
    bindings_by_alias: dict[str, dict[str, Any]] = {}
    summaries: list[dict[str, Any]] = []
    already_bound: set[tuple[str, Any]] = set()
    failures: list[dict[str, Any]] = []
    connection = immutable_connection(baseline)
    try:
        for alias in case["aliases"]:
            name = alias["name"]
            selector = alias.get("selector")
            if selector not in SELECTOR_QUERIES:
                failures.append(
                    {
                        "alias": name,
                        "candidateCount": 0,
                        "reason": "selector-not-supported",
                        "requirementsDigest": json_digest(alias["requirements"]),
                    }
                )
                continue
            query = SELECTOR_QUERIES[selector]
            count = _candidate_count(connection, query)
            binding = _choose_candidate(
                connection, query, alias["entity"], already_bound
            )
            if binding is None:
                failures.append(
                    {
                        "alias": name,
                        "candidateCount": count,
                        "reason": "no-distinct-candidate",
                        "requirementsDigest": json_digest(alias["requirements"]),
                    }
                )
                continue
            bindings_by_alias[name] = binding
            already_bound.add((binding["entity"], binding["id"]))
            summaries.append(
                {
                    "alias": name,
                    "selector": selector,
                    "candidateCount": count,
                    "requirementsDigest": json_digest(alias["requirements"]),
                    "bindingDigest": json_digest(binding),
                }
            )
    finally:
        connection.close()

    report = {
        "schemaVersion": 1,
        "tool": "book-alignment-suggest-bindings",
        "generatedAt": utc_now(),
        "dataPolicy": privacy_policy(),
        "caseId": case["caseId"],
        "result": "PASS" if not failures else "FAIL",
        "passed": not failures,
        "baselineSha256": baseline_sha,
        "aliases": summaries,
        "failures": failures,
    }
    if failures:
        write_json_exclusive(report_path, report)
        print(
            f"FAIL bindings {case['caseId']}: unresolved={len(failures)}; "
            f"report={report_path}; private values omitted"
        )
        return 1

    bindings: dict[str, Any] = {
        "schemaVersion": 1,
        "baselineSha256": baseline_sha,
        "schemaFingerprint": schema_sha,
        "runtimeProfileSha256": profile_sha,
        "aliases": bindings_by_alias,
    }
    if setup_sha is not None:
        bindings["setupSqlSha256"] = setup_sha
    validate_bindings_payload(bindings, alias_entities)
    write_json_exclusive(output, bindings, mode=0o600)
    report["bindingsSha256"] = file_sha256(output)
    write_json_exclusive(report_path, report)
    for summary in summaries:
        print(
            f"alias={summary['alias']} candidates={summary['candidateCount']} "
            f"bindingDigest={summary['bindingDigest']}"
        )
    print(
        f"PASS bindings {case['caseId']}: aliases={len(summaries)} "
        f"report={report_path}; private names and IDs omitted"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return suggest(args)
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except sqlite3.Error as error:
        print(f"ERROR: binding query failed ({json_digest(str(error))})", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
