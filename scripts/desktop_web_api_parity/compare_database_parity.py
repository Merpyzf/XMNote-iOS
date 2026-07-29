#!/usr/bin/env python3
"""Compare isolated Android/iOS SQLite outcomes without persisting user payloads."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import sqlite3
import sys
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class EpochRule:
    table: str
    column: str
    reason: str


@dataclass(frozen=True)
class StablePlatformTableRule:
    table: str
    reason: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare complete Android/iOS SQLite outcomes against one frozen baseline."
    )
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--android", type=pathlib.Path)
    parser.add_argument("--ios", type=pathlib.Path)
    parser.add_argument("--android-before", type=pathlib.Path)
    parser.add_argument("--ios-before", type=pathlib.Path)
    parser.add_argument("--android-after", type=pathlib.Path)
    parser.add_argument("--ios-after", type=pathlib.Path)
    parser.add_argument("--rules", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    snapshot_mode = all(
        value is not None
        for value in (arguments.baseline, arguments.android, arguments.ios)
    )
    delta_mode = all(
        value is not None
        for value in (
            arguments.android_before,
            arguments.ios_before,
            arguments.android_after,
            arguments.ios_after,
        )
    )
    if snapshot_mode == delta_mode:
        parser.error(
            "Choose either --baseline/--android/--ios or all four before/after arguments"
        )
    return arguments


def digest(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def quoted(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def load_rules(
    path: pathlib.Path,
) -> tuple[
    str,
    dict[tuple[str, str], EpochRule],
    dict[str, StablePlatformTableRule],
]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != 1:
        raise ValueError("Database parity rules schemaVersion must be 1")
    name = payload.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError("Database parity rules require a non-empty name")

    rules: dict[tuple[str, str], EpochRule] = {}
    for raw_rule in payload.get("epochMillisColumns", []):
        if not isinstance(raw_rule, dict):
            raise ValueError("Each epochMillisColumns item must be an object")
        table = raw_rule.get("table")
        column = raw_rule.get("column")
        reason = raw_rule.get("reason")
        if not all(isinstance(value, str) and value for value in (table, column, reason)):
            raise ValueError("Epoch rules require non-empty table, column and reason")
        key = (table, column)
        if key in rules:
            raise ValueError(f"Duplicate epoch rule for {table}.{column}")
        rules[key] = EpochRule(table=table, column=column, reason=reason)

    stable_platform_tables: dict[str, StablePlatformTableRule] = {}
    for raw_rule in payload.get("stablePlatformTables", []):
        if not isinstance(raw_rule, dict):
            raise ValueError("Each stablePlatformTables item must be an object")
        table = raw_rule.get("table")
        reason = raw_rule.get("reason")
        if not all(isinstance(value, str) and value for value in (table, reason)):
            raise ValueError("Stable platform table rules require non-empty table and reason")
        if table in stable_platform_tables:
            raise ValueError(f"Duplicate stable platform table rule for {table}")
        stable_platform_tables[table] = StablePlatformTableRule(
            table=table,
            reason=reason,
        )
    return name, rules, stable_platform_tables


def open_read_only(path: pathlib.Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def integrity_check(connection: sqlite3.Connection) -> str:
    return str(connection.execute("PRAGMA integrity_check").fetchone()[0])


def table_names(connection: sqlite3.Connection) -> list[str]:
    names = [
        str(row[0])
        for row in connection.execute(
            """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
    ]
    if connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'"
    ).fetchone():
        names.append("sqlite_sequence")
    return names


def columns(connection: sqlite3.Connection, table: str) -> tuple[list[str], list[str]]:
    table_info = list(connection.execute(f"PRAGMA table_info({quoted(table)})"))
    names = [str(row[1]) for row in table_info]
    primary_keys = [
        str(row[1])
        for row in sorted(table_info, key=lambda row: int(row[5]))
        if int(row[5]) > 0
    ]
    if table == "sqlite_sequence":
        primary_keys = ["name"]
    if not primary_keys:
        primary_keys = names
    return names, primary_keys


def rows_by_key(
    connection: sqlite3.Connection,
    table: str,
    column_names: list[str],
    primary_keys: list[str],
) -> dict[tuple[Any, ...], dict[str, Any]]:
    selected = ", ".join(quoted(name) for name in column_names)
    rows = connection.execute(f"SELECT {selected} FROM {quoted(table)}").fetchall()
    return {
        tuple(row[name] for name in primary_keys): {
            name: row[name]
            for name in column_names
        }
        for row in rows
    }


def is_valid_epoch_pair(
    android: Any,
    ios: Any,
    baseline: Any | None,
    has_baseline: bool,
) -> tuple[bool, str]:
    if isinstance(android, bool) or isinstance(ios, bool):
        return False, "epoch-value-is-boolean"
    if not isinstance(android, (int, float)) or not isinstance(ios, (int, float)):
        return False, "epoch-value-is-not-numeric"
    if android < 0 or ios < 0:
        return False, "epoch-value-is-negative"
    if not has_baseline:
        if (android == 0) != (ios == 0):
            return False, "inserted-epoch-zero-state-differs"
        return True, "inserted-epoch-generated-by-each-device-clock"

    android_changed = android != baseline
    ios_changed = ios != baseline
    if android_changed != ios_changed:
        return False, "only-one-platform-updated-epoch"
    if not android_changed:
        return False, "equal-baseline-values-should-have-compared-exactly"
    if isinstance(baseline, (int, float)):
        if android < baseline or ios < baseline:
            return False, "epoch-moved-backwards"
    return True, "both-platforms-updated-epoch-with-independent-device-clocks"


def is_valid_epoch_delta_pair(
    android_after: Any,
    ios_after: Any,
    android_before: Any | None,
    ios_before: Any | None,
    inserted: bool,
) -> tuple[bool, str]:
    values = (android_after, ios_after)
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in values):
        return False, "epoch-value-is-not-numeric"
    if android_after < 0 or ios_after < 0:
        return False, "epoch-value-is-negative"
    if inserted:
        if (android_after == 0) != (ios_after == 0):
            return False, "inserted-epoch-zero-state-differs"
        return True, "inserted-epoch-generated-by-each-device-clock"

    before_values = (android_before, ios_before)
    if any(
        isinstance(value, bool) or not isinstance(value, (int, float))
        for value in before_values
    ):
        return False, "baseline-epoch-value-is-not-numeric"
    if android_after < android_before or ios_after < ios_before:
        return False, "epoch-moved-backwards"
    return True, "both-platforms-updated-epoch-with-independent-device-clocks"


def compare_databases(
    baseline: sqlite3.Connection,
    android: sqlite3.Connection,
    ios: sqlite3.Connection,
    rules: dict[tuple[str, str], EpochRule],
) -> dict[str, Any]:
    baseline_tables = table_names(baseline)
    android_tables = table_names(android)
    ios_tables = table_names(ios)
    schema_exact = baseline_tables == android_tables == ios_tables
    mismatches: list[dict[str, Any]] = []
    normalized: list[dict[str, Any]] = []
    compared_cells = 0

    if not schema_exact:
        mismatches.append(
            {
                "reason": "table-set",
                "baselineDigest": digest(baseline_tables),
                "androidDigest": digest(android_tables),
                "iosDigest": digest(ios_tables),
            }
        )

    for table in sorted(set(baseline_tables) & set(android_tables) & set(ios_tables)):
        baseline_columns, primary_keys = columns(baseline, table)
        android_columns, android_primary_keys = columns(android, table)
        ios_columns, ios_primary_keys = columns(ios, table)
        if (
            baseline_columns != android_columns
            or baseline_columns != ios_columns
            or primary_keys != android_primary_keys
            or primary_keys != ios_primary_keys
        ):
            mismatches.append(
                {
                    "table": table,
                    "reason": "column-or-primary-key-schema",
                    "baselineDigest": digest([baseline_columns, primary_keys]),
                    "androidDigest": digest([android_columns, android_primary_keys]),
                    "iosDigest": digest([ios_columns, ios_primary_keys]),
                }
            )
            continue

        baseline_rows = rows_by_key(
            baseline,
            table,
            baseline_columns,
            primary_keys,
        )
        android_rows = rows_by_key(
            android,
            table,
            baseline_columns,
            primary_keys,
        )
        ios_rows = rows_by_key(
            ios,
            table,
            baseline_columns,
            primary_keys,
        )
        if set(android_rows) != set(ios_rows):
            mismatches.append(
                {
                    "table": table,
                    "reason": "row-key-set",
                    "androidDigest": digest(sorted(map(digest, android_rows))),
                    "iosDigest": digest(sorted(map(digest, ios_rows))),
                    "androidCount": len(android_rows),
                    "iosCount": len(ios_rows),
                }
            )
            continue

        for key in sorted(android_rows, key=digest):
            android_row = android_rows[key]
            ios_row = ios_rows[key]
            baseline_row = baseline_rows.get(key)
            for column in baseline_columns:
                compared_cells += 1
                android_value = android_row[column]
                ios_value = ios_row[column]
                if android_value == ios_value:
                    continue
                rule = rules.get((table, column))
                if rule is None:
                    mismatches.append(
                        {
                            "table": table,
                            "keyDigest": digest(key),
                            "column": column,
                            "reason": "value",
                            "androidDigest": digest(android_value),
                            "iosDigest": digest(ios_value),
                        }
                    )
                    continue

                valid, reason = is_valid_epoch_pair(
                    android_value,
                    ios_value,
                    baseline_row[column] if baseline_row is not None else None,
                    baseline_row is not None,
                )
                item = {
                    "table": table,
                    "keyDigest": digest(key),
                    "column": column,
                    "reason": reason,
                    "ruleReason": rule.reason,
                }
                if valid:
                    normalized.append(item)
                else:
                    mismatches.append(item)

    unused_rules = sorted(
        f"{table}.{column}"
        for table, column in rules
        if table not in set(baseline_tables) | set(android_tables) | set(ios_tables)
        or column not in (
            columns(
                baseline if table in baseline_tables else android if table in android_tables else ios,
                table,
            )[0]
        )
    )
    if unused_rules:
        mismatches.append(
            {
                "reason": "unknown-normalization-rule",
                "rules": unused_rules,
            }
        )

    return {
        "passed": not mismatches,
        "schemaExact": schema_exact,
        "comparedTables": len(set(baseline_tables) & set(android_tables) & set(ios_tables)),
        "comparedCells": compared_cells,
        "normalizedEpochCells": len(normalized),
        "normalizations": normalized,
        "mismatches": mismatches,
    }


def compare_database_deltas(
    android_before: sqlite3.Connection,
    ios_before: sqlite3.Connection,
    android_after: sqlite3.Connection,
    ios_after: sqlite3.Connection,
    rules: dict[tuple[str, str], EpochRule],
    stable_platform_table_rules: dict[str, StablePlatformTableRule],
) -> dict[str, Any]:
    connections = (android_before, ios_before, android_after, ios_after)
    table_sets = [table_names(connection) for connection in connections]
    schema_exact = all(names == table_sets[0] for names in table_sets[1:])
    mismatches: list[dict[str, Any]] = []
    normalized: list[dict[str, Any]] = []
    stable_platform_tables: list[dict[str, Any]] = []
    compared_cells = 0
    android_changed_cells = 0
    ios_changed_cells = 0

    android_table_set_stable = table_sets[0] == table_sets[2]
    ios_table_set_stable = table_sets[1] == table_sets[3]
    if not android_table_set_stable or not ios_table_set_stable:
        mismatches.append(
            {
                "reason": "platform-table-set-mutated-during-api-run",
                "androidBeforeDigest": digest(table_sets[0]),
                "androidAfterDigest": digest(table_sets[2]),
                "iosBeforeDigest": digest(table_sets[1]),
                "iosAfterDigest": digest(table_sets[3]),
            }
        )

    cross_platform_difference = (
        set(table_sets[0])
        ^ set(table_sets[1])
        | set(table_sets[2])
        ^ set(table_sets[3])
    )
    unknown_platform_tables = sorted(
        cross_platform_difference - set(stable_platform_table_rules)
    )
    if unknown_platform_tables:
        mismatches.append(
            {
                "reason": "unapproved-cross-platform-table-set",
                "tables": unknown_platform_tables,
                "androidBeforeDigest": digest(table_sets[0]),
                "iosBeforeDigest": digest(table_sets[1]),
                "androidAfterDigest": digest(table_sets[2]),
                "iosAfterDigest": digest(table_sets[3]),
            }
        )

    for table in sorted(cross_platform_difference & set(stable_platform_table_rules)):
        rule = stable_platform_table_rules[table]
        stable_platform_tables.append(
            {
                "table": table,
                "androidPresent": table in table_sets[0],
                "iosPresent": table in table_sets[1],
                "reason": rule.reason,
            }
        )

    unused_stable_table_rules = sorted(
        set(stable_platform_table_rules) - cross_platform_difference
    )
    if unused_stable_table_rules:
        mismatches.append(
            {
                "reason": "unused-stable-platform-table-rule",
                "tables": unused_stable_table_rules,
            }
        )

    shared_tables = set.intersection(*(set(names) for names in table_sets))
    for table in sorted(shared_tables):
        schemas = [columns(connection, table) for connection in connections]
        if any(schema != schemas[0] for schema in schemas[1:]):
            mismatches.append(
                {
                    "table": table,
                    "reason": "column-or-primary-key-schema",
                    "androidBeforeDigest": digest(schemas[0]),
                    "iosBeforeDigest": digest(schemas[1]),
                    "androidAfterDigest": digest(schemas[2]),
                    "iosAfterDigest": digest(schemas[3]),
                }
            )
            continue

        column_names, primary_keys = schemas[0]
        row_sets = [
            rows_by_key(connection, table, column_names, primary_keys)
            for connection in connections
        ]
        android_before_rows, ios_before_rows, android_after_rows, ios_after_rows = row_sets
        android_added = set(android_after_rows) - set(android_before_rows)
        ios_added = set(ios_after_rows) - set(ios_before_rows)
        android_removed = set(android_before_rows) - set(android_after_rows)
        ios_removed = set(ios_before_rows) - set(ios_after_rows)

        if android_added != ios_added:
            mismatches.append(
                {
                    "table": table,
                    "reason": "added-row-key-set",
                    "androidDigest": digest(sorted(map(digest, android_added))),
                    "iosDigest": digest(sorted(map(digest, ios_added))),
                    "androidCount": len(android_added),
                    "iosCount": len(ios_added),
                }
            )
        if android_removed != ios_removed:
            mismatches.append(
                {
                    "table": table,
                    "reason": "removed-row-key-set",
                    "androidDigest": digest(sorted(map(digest, android_removed))),
                    "iosDigest": digest(sorted(map(digest, ios_removed))),
                    "androidCount": len(android_removed),
                    "iosCount": len(ios_removed),
                }
            )

        for key in sorted(android_added & ios_added, key=digest):
            for column in column_names:
                compared_cells += 1
                android_changed_cells += 1
                ios_changed_cells += 1
                android_value = android_after_rows[key][column]
                ios_value = ios_after_rows[key][column]
                if android_value == ios_value:
                    continue
                rule = rules.get((table, column))
                if rule is None:
                    mismatches.append(
                        {
                            "table": table,
                            "keyDigest": digest(key),
                            "column": column,
                            "reason": "inserted-value",
                            "androidDigest": digest(android_value),
                            "iosDigest": digest(ios_value),
                        }
                    )
                    continue
                valid, reason = is_valid_epoch_delta_pair(
                    android_value,
                    ios_value,
                    None,
                    None,
                    inserted=True,
                )
                item = {
                    "table": table,
                    "keyDigest": digest(key),
                    "column": column,
                    "reason": reason,
                    "ruleReason": rule.reason,
                }
                (normalized if valid else mismatches).append(item)

        stable_android_keys = set(android_before_rows) & set(android_after_rows)
        stable_ios_keys = set(ios_before_rows) & set(ios_after_rows)
        for key in sorted(stable_android_keys & stable_ios_keys, key=digest):
            for column in column_names:
                android_changed = (
                    android_before_rows[key][column]
                    != android_after_rows[key][column]
                )
                ios_changed = (
                    ios_before_rows[key][column]
                    != ios_after_rows[key][column]
                )
                android_changed_cells += int(android_changed)
                ios_changed_cells += int(ios_changed)
                if not android_changed and not ios_changed:
                    continue
                compared_cells += 1
                if android_changed != ios_changed:
                    mismatches.append(
                        {
                            "table": table,
                            "keyDigest": digest(key),
                            "column": column,
                            "reason": "only-one-platform-mutated-cell",
                        }
                    )
                    continue

                android_value = android_after_rows[key][column]
                ios_value = ios_after_rows[key][column]
                if android_value == ios_value:
                    continue
                rule = rules.get((table, column))
                if rule is None:
                    mismatches.append(
                        {
                            "table": table,
                            "keyDigest": digest(key),
                            "column": column,
                            "reason": "mutated-value",
                            "androidDigest": digest(android_value),
                            "iosDigest": digest(ios_value),
                        }
                    )
                    continue
                valid, reason = is_valid_epoch_delta_pair(
                    android_value,
                    ios_value,
                    android_before_rows[key][column],
                    ios_before_rows[key][column],
                    inserted=False,
                )
                item = {
                    "table": table,
                    "keyDigest": digest(key),
                    "column": column,
                    "reason": reason,
                    "ruleReason": rule.reason,
                }
                (normalized if valid else mismatches).append(item)

    known_columns = {
        table: set(columns(android_before, table)[0])
        for table in shared_tables
    }
    unused_rules = sorted(
        f"{table}.{column}"
        for table, column in rules
        if table not in known_columns or column not in known_columns[table]
    )
    if unused_rules:
        mismatches.append(
            {
                "reason": "unknown-normalization-rule",
                "rules": unused_rules,
            }
        )

    return {
        "passed": not mismatches,
        "schemaExact": schema_exact,
        "schemaStableWithinEachPlatform": (
            android_table_set_stable and ios_table_set_stable
        ),
        "comparedTables": len(shared_tables),
        "comparedMutatedCells": compared_cells,
        "androidChangedCells": android_changed_cells,
        "iosChangedCells": ios_changed_cells,
        "normalizedEpochCells": len(normalized),
        "normalizations": normalized,
        "stablePlatformTables": stable_platform_tables,
        "mismatches": mismatches,
    }


def main() -> int:
    args = parse_args()
    fixture_name, rules, stable_platform_table_rules = load_rules(args.rules)
    snapshot_mode = args.baseline is not None
    paths = (
        [args.baseline, args.android, args.ios]
        if snapshot_mode
        else [
            args.android_before,
            args.ios_before,
            args.android_after,
            args.ios_after,
        ]
    )
    connections = [open_read_only(path) for path in paths]
    try:
        integrity = [integrity_check(connection) for connection in connections]
        comparison = (
            compare_databases(*connections, rules)
            if snapshot_mode
            else compare_database_deltas(
                *connections,
                rules,
                stable_platform_table_rules,
            )
        )
    finally:
        for connection in connections:
            connection.close()

    passed = all(value == "ok" for value in integrity) and comparison["passed"]
    report = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "fixture": fixture_name,
        "dataPolicy": "Only structural counts and SHA-256 digests are persisted; row payloads are omitted.",
        "mode": "snapshot" if snapshot_mode else "delta",
        "integrity": (
            {
                "baseline": integrity[0],
                "android": integrity[1],
                "ios": integrity[2],
            }
            if snapshot_mode
            else {
                "androidBefore": integrity[0],
                "iosBefore": integrity[1],
                "androidAfter": integrity[2],
                "iosAfter": integrity[3],
            }
        ),
        "passed": passed,
        "comparison": comparison,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"{'PASS' if passed else 'FAIL'} {fixture_name}: "
        f"{comparison['comparedTables']} tables, "
        f"{comparison.get('comparedCells', comparison.get('comparedMutatedCells'))} cells, "
        f"{comparison['normalizedEpochCells']} normalized epoch cells, "
        f"{len(comparison['mismatches'])} mismatches; report={args.output}"
    )
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
