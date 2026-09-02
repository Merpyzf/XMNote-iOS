#!/usr/bin/env python3
"""Apply one deterministic setup SQL file to two independent B0 live copies."""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import re
import shutil
import sqlite3
import sys
import tempfile
from types import ModuleType
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from book_alignment.common import (  # type: ignore[import-not-found]
        AlignmentError,
        ensure_private_directory,
        file_sha256,
        foreign_key_summary,
        immutable_connection,
        inspect_database,
        json_digest,
        privacy_policy,
        resolve_default_baseline,
        room_identity_hash,
        schema_fingerprint,
        utc_now,
        write_json_exclusive,
    )
    from book_alignment.contract import load_contract_bundle  # type: ignore[import-not-found]
else:
    from .common import (
        AlignmentError,
        ensure_private_directory,
        file_sha256,
        foreign_key_summary,
        immutable_connection,
        inspect_database,
        json_digest,
        privacy_policy,
        resolve_default_baseline,
        room_identity_hash,
        schema_fingerprint,
        utc_now,
        write_json_exclusive,
    )
    from .contract import load_contract_bundle


PARAMETER_PATTERN = re.compile(r"(?<!:):([A-Za-z][A-Za-z0-9._-]{0,95})")
NONDETERMINISTIC_PATTERN = re.compile(
    r"\b(CURRENT_DATE|CURRENT_TIME|CURRENT_TIMESTAMP|RANDOM|RANDOMBLOB|"
    r"DATE|TIME|DATETIME|JULIANDAY|UNIXEPOCH|STRFTIME|LAST_INSERT_ROWID|"
    r"CHANGES|READFILE|WRITEFILE|LOAD_EXTENSION)\b",
    flags=re.IGNORECASE,
)
FORBIDDEN_INTERNAL_PATTERN = re.compile(
    r"\b(sqlite_[A-Za-z0-9_]*|room_master_table|grdb_migrations)\b",
    flags=re.IGNORECASE,
)
ALLOWED_STATEMENT_PATTERN = re.compile(
    r"^(INSERT|UPDATE|DELETE|WITH)\b", flags=re.IGNORECASE
)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Seed two byte-identical B0 copies, transactionally execute the same "
            "hash-pinned deterministic SQL, then publish only if both are equivalent."
        )
    )
    parser.add_argument("--case", type=pathlib.Path, required=True)
    parser.add_argument("--bindings", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument(
        "--setup-sql",
        type=pathlib.Path,
        help="optional private SQL path; default resolves case.setup.sqlFile beside the case",
    )
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    parser.add_argument("--skip-missing-private-baseline", action="store_true")
    return parser.parse_args(argv)


def _load_parity_module() -> ModuleType:
    module_path = (
        pathlib.Path(__file__).resolve().parents[1]
        / "desktop_web_api_parity"
        / "compare_database_parity.py"
    )
    spec = importlib.util.spec_from_file_location(
        "xmnote_setup_database_parity", module_path
    )
    if spec is None or spec.loader is None:
        raise AlignmentError("Unable to load existing database parity tool")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _split_sql(text: str) -> list[str]:
    statements: list[str] = []
    buffer = ""
    for line in text.splitlines(keepends=True):
        buffer += line
        if sqlite3.complete_statement(buffer):
            statement = buffer.strip()
            buffer = ""
            if statement and statement != ";":
                statements.append(statement)
    if buffer.strip():
        raise AlignmentError("Setup SQL ends with an incomplete statement")
    return statements


def _lexical_sql(sql: str) -> str:
    """Remove comments and quoted literals before deterministic-keyword checks."""

    result: list[str] = []
    index = 0
    state = "plain"
    while index < len(sql):
        char = sql[index]
        next_char = sql[index + 1] if index + 1 < len(sql) else ""
        if state == "plain":
            if char == "'":
                state = "single"
                result.append(" ")
            elif char == '"':
                state = "double"
                result.append(" ")
            elif char == "-" and next_char == "-":
                state = "line-comment"
                result.extend((" ", " "))
                index += 1
            elif char == "/" and next_char == "*":
                state = "block-comment"
                result.extend((" ", " "))
                index += 1
            else:
                result.append(char)
        elif state == "single":
            result.append(" ")
            if char == "'":
                if next_char == "'":
                    result.append(" ")
                    index += 1
                else:
                    state = "plain"
        elif state == "double":
            result.append(" ")
            if char == '"':
                if next_char == '"':
                    result.append(" ")
                    index += 1
                else:
                    state = "plain"
        elif state == "line-comment":
            result.append("\n" if char == "\n" else " ")
            if char == "\n":
                state = "plain"
        else:
            result.append(" ")
            if char == "*" and next_char == "/":
                result.append(" ")
                index += 1
                state = "plain"
        index += 1
    if state in {"single", "double", "block-comment"}:
        raise AlignmentError("Setup SQL contains an unterminated literal or comment")
    return "".join(result)


def _validate_statements(
    statements: list[str], declared_aliases: set[str]
) -> None:
    if not statements:
        raise AlignmentError("deterministic-sql setup must contain at least one statement")
    for index, statement in enumerate(statements):
        lexical = _lexical_sql(statement).strip()
        if not ALLOWED_STATEMENT_PATTERN.match(lexical):
            raise AlignmentError(
                f"Setup statement {index + 1} must begin with INSERT/UPDATE/DELETE/WITH"
            )
        if NONDETERMINISTIC_PATTERN.search(lexical):
            raise AlignmentError(
                f"Setup statement {index + 1} uses a nondeterministic or external function"
            )
        if FORBIDDEN_INTERNAL_PATTERN.search(lexical):
            raise AlignmentError(
                f"Setup statement {index + 1} targets an internal metadata table"
            )
        unknown_parameters = sorted(
            set(PARAMETER_PATTERN.findall(statement)) - declared_aliases
        )
        if unknown_parameters:
            raise AlignmentError(
                "Setup SQL references undeclared aliases: "
                + ", ".join(unknown_parameters)
            )


class SetupAuthorizer:
    """Allow business DML while denying schema, external-file and transaction SQL."""

    def __init__(self) -> None:
        self.writes: list[tuple[str, str, str | None]] = []
        self.denied_actions = {
            getattr(sqlite3, name)
            for name in (
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
                "SQLITE_TRANSACTION",
                "SQLITE_SAVEPOINT",
            )
            if hasattr(sqlite3, name)
        }

    def __call__(
        self,
        action: int,
        arg1: str | None,
        arg2: str | None,
        _database: str | None,
        _trigger: str | None,
    ) -> int:
        if action in self.denied_actions:
            return sqlite3.SQLITE_DENY
        operation_by_action = {
            sqlite3.SQLITE_INSERT: "insert",
            sqlite3.SQLITE_UPDATE: "update",
            sqlite3.SQLITE_DELETE: "delete",
        }
        operation = operation_by_action.get(action)
        if operation is not None:
            table = arg1 or ""
            if table in {"room_master_table", "grdb_migrations"}:
                return sqlite3.SQLITE_DENY
            self.writes.append((table, operation, arg2))
        if action == getattr(sqlite3, "SQLITE_FUNCTION", -1):
            function_name = (arg2 or arg1 or "").upper()
            if NONDETERMINISTIC_PATTERN.fullmatch(function_name):
                return sqlite3.SQLITE_DENY
        return sqlite3.SQLITE_OK


def _health_in_transaction(connection: sqlite3.Connection) -> dict[str, Any]:
    integrity = [tuple(row) for row in connection.execute("PRAGMA integrity_check")]
    quick = [tuple(row) for row in connection.execute("PRAGMA quick_check")]
    return {
        "integrity": integrity,
        "quick": quick,
        "foreignKeyCheck": foreign_key_summary(connection),
        "schemaFingerprint": schema_fingerprint(connection),
        "userVersion": int(connection.execute("PRAGMA user_version").fetchone()[0]),
        "roomIdentityHash": room_identity_hash(connection),
    }


def _health_failures(
    health: dict[str, Any], baseline_health: dict[str, Any]
) -> list[str]:
    failures: list[str] = []
    if health["integrity"] != [("ok",)]:
        failures.append("integrity-check")
    if health["quick"] != [("ok",)]:
        failures.append("quick-check")
    if health["schemaFingerprint"]["sha256"] != baseline_health["schemaFingerprint"]["sha256"]:
        failures.append("schema-mutated")
    if health["userVersion"] != baseline_health["userVersion"]:
        failures.append("user-version-mutated")
    if health["roomIdentityHash"] != baseline_health["roomIdentityHash"]:
        failures.append("room-identity-mutated")
    before_fk = set(baseline_health["foreignKeyCheck"]["violationDigests"])
    after_fk = set(health["foreignKeyCheck"]["violationDigests"])
    if after_fk - before_fk:
        failures.append("new-foreign-key-violations")
    return failures


def _logical_equivalence(
    parity: ModuleType,
    first: sqlite3.Connection,
    second: sqlite3.Connection,
) -> list[dict[str, Any]]:
    failures: list[dict[str, Any]] = []
    first_tables = parity.table_names(first)
    second_tables = parity.table_names(second)
    if first_tables != second_tables:
        return [
            {
                "reason": "table-set",
                "androidDigest": json_digest(first_tables),
                "iosDigest": json_digest(second_tables),
            }
        ]
    for table in first_tables:
        first_schema = parity.columns(first, table)
        second_schema = parity.columns(second, table)
        if first_schema != second_schema:
            failures.append({"table": table, "reason": "schema"})
            continue
        columns, primary_keys = first_schema
        first_rows = parity.rows_by_key(first, table, columns, primary_keys)
        second_rows = parity.rows_by_key(second, table, columns, primary_keys)
        if set(first_rows) != set(second_rows):
            failures.append(
                {
                    "table": table,
                    "reason": "row-key-set",
                    "androidCount": len(first_rows),
                    "iosCount": len(second_rows),
                    "androidDigest": json_digest(sorted(map(json_digest, first_rows))),
                    "iosDigest": json_digest(sorted(map(json_digest, second_rows))),
                }
            )
            continue
        for key in first_rows:
            for column in columns:
                if first_rows[key][column] != second_rows[key][column]:
                    failures.append(
                        {
                            "table": table,
                            "column": column,
                            "keyDigest": json_digest(key),
                            "reason": "value",
                            "androidDigest": json_digest(first_rows[key][column]),
                            "iosDigest": json_digest(second_rows[key][column]),
                        }
                    )
    return failures


def _change_summary(
    parity: ModuleType,
    baseline: sqlite3.Connection,
    after: sqlite3.Connection,
) -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    for table in parity.table_names(baseline):
        if table not in parity.table_names(after):
            continue
        schema = parity.columns(baseline, table)
        if schema != parity.columns(after, table):
            continue
        columns, primary_keys = schema
        before_rows = parity.rows_by_key(baseline, table, columns, primary_keys)
        after_rows = parity.rows_by_key(after, table, columns, primary_keys)
        added = set(after_rows) - set(before_rows)
        removed = set(before_rows) - set(after_rows)
        updated_columns: set[str] = set()
        updated_rows = 0
        for key in set(before_rows) & set(after_rows):
            changed = {
                column
                for column in columns
                if before_rows[key][column] != after_rows[key][column]
            }
            if changed:
                updated_rows += 1
                updated_columns.update(changed)
        if added or removed or updated_rows:
            summaries.append(
                {
                    "table": table,
                    "insertedRows": len(added),
                    "deletedRows": len(removed),
                    "updatedRows": updated_rows,
                    "updatedColumns": sorted(updated_columns),
                }
            )
    return summaries


def _checkpoint(connection: sqlite3.Connection) -> None:
    row = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    if row is None or int(row[0]) != 0:
        raise AlignmentError("Setup output WAL checkpoint failed")


def _resolve_setup_sql(
    args: argparse.Namespace, case: dict[str, Any]
) -> tuple[pathlib.Path | None, list[str]]:
    if case["setup"]["mode"] == "none":
        if args.setup_sql is not None:
            raise AlignmentError("--setup-sql is invalid when case.setup.mode is none")
        return None, []
    path = args.setup_sql or (args.case.parent / case["setup"]["sqlFile"])
    path = path.expanduser()
    if not path.is_file():
        raise AlignmentError("Deterministic setup SQL file does not exist")
    if file_sha256(path) != case["setup"]["sha256"]:
        raise AlignmentError("Deterministic setup SQL SHA-256 does not match the case")
    before = path.stat()
    text = path.read_text(encoding="utf-8")
    after = path.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise AlignmentError("Setup SQL file changed while it was read")
    statements = _split_sql(text)
    return path, statements


def apply_pair(args: argparse.Namespace) -> int:
    output_dir = args.output_dir.expanduser()
    if output_dir.exists():
        raise AlignmentError(f"Refusing to replace existing output directory: {output_dir}")
    baseline = (args.baseline or resolve_default_baseline()).expanduser()
    if not baseline.is_file():
        if args.skip_missing_private_baseline:
            print("SKIP: missing private baseline")
            return 77
        raise AlignmentError("Private baseline does not exist")
    bundle = load_contract_bundle(
        args.case, args.bindings, None, runnable=False
    )
    case = bundle.resolved_case
    if case["status"] == "pending-protocol":
        raise AlignmentError("pending-protocol cases cannot create live setup copies")
    if file_sha256(baseline) != case["baseline"]["sha256"]:
        raise AlignmentError("B0 SHA-256 does not match the case contract")
    setup_path, statements = _resolve_setup_sql(args, case)
    _validate_statements(
        statements, {alias["name"] for alias in case["aliases"]}
    ) if statements else None
    parameters = {
        name: binding["id"] for name, binding in bundle.bindings["aliases"].items()
    }
    baseline_metadata = inspect_database(baseline)
    if (
        baseline_metadata["integrityCheck"]["status"] != "ok"
        or baseline_metadata["quickCheck"]["status"] != "ok"
    ):
        raise AlignmentError("B0 integrity validation failed before setup")
    baseline_health = {
        "foreignKeyCheck": baseline_metadata["foreignKeyCheck"],
        "schemaFingerprint": baseline_metadata["schemaFingerprint"],
        "userVersion": baseline_metadata["userVersion"],
        "roomIdentityHash": baseline_metadata["roomIdentityHash"],
    }

    ensure_private_directory(output_dir.parent)
    parity = _load_parity_module()
    with tempfile.TemporaryDirectory(
        prefix=f".{output_dir.name}.setup-", dir=output_dir.parent
    ) as temporary_directory:
        root = pathlib.Path(temporary_directory)
        android_path = root / "android.live.db"
        ios_path = root / "ios.live.db"
        shutil.copyfile(baseline, android_path)
        shutil.copyfile(baseline, ios_path)
        baseline_sha256 = case["baseline"]["sha256"]
        if (
            file_sha256(android_path) != baseline_sha256
            or file_sha256(ios_path) != baseline_sha256
        ):
            raise AlignmentError("Setup seed copies are not byte-identical to B0")
        authorizers = {
            "android": SetupAuthorizer(),
            "ios": SetupAuthorizer(),
        }
        total_changes: dict[str, int] = {"android": 0, "ios": 0}
        android_health = baseline_health
        if statements:
            android_connection = sqlite3.connect(android_path, isolation_level=None)
            ios_connection = sqlite3.connect(ios_path, isolation_level=None)
            for connection in (android_connection, ios_connection):
                connection.row_factory = sqlite3.Row
            try:
                for connection in (android_connection, ios_connection):
                    connection.execute("BEGIN IMMEDIATE")
                for platform, connection in (
                    ("android", android_connection),
                    ("ios", ios_connection),
                ):
                    before_changes = connection.total_changes
                    connection.set_authorizer(authorizers[platform])
                    try:
                        for statement in statements:
                            connection.execute(statement, parameters)
                    finally:
                        connection.set_authorizer(None)
                    total_changes[platform] = connection.total_changes - before_changes

                android_health = _health_in_transaction(android_connection)
                ios_health = _health_in_transaction(ios_connection)
                health_failures = {
                    "android": _health_failures(android_health, baseline_health),
                    "ios": _health_failures(ios_health, baseline_health),
                }
                equivalence_failures = _logical_equivalence(
                    parity, android_connection, ios_connection
                )
                if total_changes["android"] == 0 or total_changes["ios"] == 0:
                    raise AlignmentError("Deterministic setup did not change both copies")
                if health_failures["android"] or health_failures["ios"]:
                    raise AlignmentError(
                        "Setup validation failed: " + json_digest(health_failures)
                    )
                if equivalence_failures:
                    raise AlignmentError(
                        "Setup copies are not logically equivalent: "
                        + json_digest(equivalence_failures)
                    )
                android_connection.execute("COMMIT")
                ios_connection.execute("COMMIT")
                _checkpoint(android_connection)
                _checkpoint(ios_connection)
            except BaseException:
                for connection in (android_connection, ios_connection):
                    try:
                        if connection.in_transaction:
                            connection.execute("ROLLBACK")
                    except sqlite3.Error:
                        pass
                raise
            finally:
                android_connection.close()
                ios_connection.close()

        if file_sha256(android_path) != file_sha256(ios_path):
            raise AlignmentError("Deterministic setup produced different database bytes")
        if not statements and file_sha256(android_path) != baseline_sha256:
            raise AlignmentError("No-setup copies must remain byte-identical to B0")
        baseline_connection = immutable_connection(baseline)
        after_connection = immutable_connection(android_path)
        try:
            changes = _change_summary(parity, baseline_connection, after_connection)
        finally:
            baseline_connection.close()
            after_connection.close()
        for path in (android_path, ios_path):
            path.chmod(0o600)
        report = {
            "schemaVersion": 1,
            "tool": "book-alignment-setup",
            "generatedAt": utc_now(),
            "dataPolicy": privacy_policy(),
            "caseId": case["caseId"],
            "result": "PASS",
            "passed": True,
            "mode": case["setup"]["mode"],
            "baselineSha256": case["baseline"]["sha256"],
            "setupSqlSha256": None if setup_path is None else file_sha256(setup_path),
            "statementCount": len(statements),
            "seedShaVerified": True,
            "transactionalPerCopy": bool(statements),
            "publishedAtomicallyAsDirectory": True,
            "copiesByteIdentical": True,
            "totalChanges": total_changes,
            "writeAuthorizations": {
                platform: [
                    {"table": table, "operation": operation, "column": column}
                    for table, operation, column in authorizer.writes
                ]
                for platform, authorizer in authorizers.items()
            },
            "databaseChanges": changes,
            "foreignKeyViolationCount": android_health["foreignKeyCheck"][
                "violationCount"
            ],
            "foreignKeyViolationSetDigest": android_health["foreignKeyCheck"][
                "setDigest"
            ],
        }
        write_json_exclusive(root / "setup.report.json", report)
        if output_dir.exists():
            raise AlignmentError("Output directory appeared while setup was running")
        root.rename(output_dir)
    print(
        f"PASS setup {case['caseId']}: mode={case['setup']['mode']} "
        f"changes={total_changes['android']} copies=byte-identical output={output_dir}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return apply_pair(args)
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except (OSError, UnicodeError, sqlite3.Error) as error:
        print(f"ERROR: setup failed ({json_digest(str(error))})", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
