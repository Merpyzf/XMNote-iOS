#!/usr/bin/env python3
"""Create or validate an immutable single-file B0 from a copied SQLite triple."""

from __future__ import annotations

import argparse
import pathlib
import sqlite3
import sys
import tempfile
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from book_alignment.common import (  # type: ignore[import-not-found]
        AlignmentError,
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        copy_file_exclusive,
        ensure_private_directory,
        file_sha256,
        frozen_checkpoint_copy,
        inspect_database,
        privacy_policy,
        resolve_default_baseline,
        utc_now,
        validate_database_contract,
        validate_sha256,
        write_json_exclusive,
    )
else:
    from .common import (
        AlignmentError,
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        copy_file_exclusive,
        ensure_private_directory,
        file_sha256,
        frozen_checkpoint_copy,
        inspect_database,
        privacy_policy,
        resolve_default_baseline,
        utc_now,
        validate_database_contract,
        validate_sha256,
        write_json_exclusive,
    )


def _add_contract_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--expected-user-version",
        type=int,
        default=DEFAULT_USER_VERSION,
        help=f"required PRAGMA user_version (default: {DEFAULT_USER_VERSION})",
    )
    parser.add_argument(
        "--expected-room-identity-hash",
        default=DEFAULT_ROOM_IDENTITY_HASH,
        help="required Room identity hash; use an empty string only for a non-Room test DB",
    )
    parser.add_argument(
        "--expected-schema-fingerprint",
        help="optional sqlite-schema-v1 SHA-256 recorded by an approved baseline",
    )
    parser.add_argument(
        "--require-no-foreign-key-violations",
        action="store_true",
        help="fail on any violation instead of registering historical violations in B0",
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Freeze/checkpoint a copied db/wal/shm triple into B0, or validate an "
            "existing private B0 without mutating it."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser(
        "create",
        help="copy the source triple, checkpoint the copy, validate it, then publish B0",
    )
    create.add_argument("--db", type=pathlib.Path, required=True)
    create.add_argument("--wal", type=pathlib.Path)
    create.add_argument("--shm", type=pathlib.Path)
    create.add_argument(
        "--output",
        type=pathlib.Path,
        default=None,
        help="new B0 path (default: env/fallback private-baseline convention)",
    )
    create.add_argument(
        "--report",
        type=pathlib.Path,
        help="new capture report path (default: <output>.capture.json)",
    )
    create.add_argument("--expected-b0-sha256")
    _add_contract_arguments(create)

    validate = subparsers.add_parser(
        "validate", help="inspect an existing single-file B0 in immutable read-only mode"
    )
    validate.add_argument(
        "--baseline",
        type=pathlib.Path,
        default=None,
        help="B0 path (default: env/fallback private-baseline convention)",
    )
    validate.add_argument("--expected-b0-sha256")
    validate.add_argument("--report", type=pathlib.Path)
    validate.add_argument(
        "--skip-missing-private-baseline",
        action="store_true",
        help="emit SKIP and exit 77 when the local-only B0 is absent",
    )
    _add_contract_arguments(validate)
    return parser.parse_args(argv)


def _contract_failures(
    metadata: dict[str, Any],
    args: argparse.Namespace,
    actual_sha256: str,
) -> list[dict[str, Any]]:
    expected_room_hash = args.expected_room_identity_hash or None
    failures = validate_database_contract(
        metadata,
        expected_user_version=args.expected_user_version,
        expected_room_identity_hash=expected_room_hash,
        expected_schema_fingerprint=(
            validate_sha256(
                args.expected_schema_fingerprint,
                "--expected-schema-fingerprint",
            )
            if args.expected_schema_fingerprint
            else None
        ),
        require_no_foreign_key_violations=args.require_no_foreign_key_violations,
    )
    if args.expected_b0_sha256:
        expected_sha256 = validate_sha256(
            args.expected_b0_sha256, "--expected-b0-sha256"
        )
        if actual_sha256 != expected_sha256:
            failures.append(
                {
                    "reason": "b0-sha256",
                    "expected": expected_sha256,
                    "actual": actual_sha256,
                }
            )
    return failures


def _base_report(command: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "tool": "book-alignment-baseline",
        "command": command,
        "generatedAt": utc_now(),
        "dataPolicy": privacy_policy(),
    }


def create_baseline(args: argparse.Namespace) -> int:
    output = (args.output or resolve_default_baseline()).expanduser()
    report_path = args.report or pathlib.Path(f"{output}.capture.json")
    if output.exists():
        raise AlignmentError(f"Refusing to overwrite existing B0: {output}")
    if report_path.exists():
        raise AlignmentError(f"Refusing to overwrite existing report: {report_path}")

    ensure_private_directory(output.parent)
    with tempfile.TemporaryDirectory(
        prefix=".book-alignment-b0-", dir=output.parent
    ) as temporary_directory:
        candidate = pathlib.Path(temporary_directory) / "B0.db"
        capture = frozen_checkpoint_copy(
            args.db,
            args.wal,
            args.shm,
            candidate,
            output_mode=0o400,
        )
        failures = _contract_failures(
            capture["database"], args, capture["sha256"]
        )
        report = {
            **_base_report("create"),
            "result": "PASS" if not failures else "FAIL",
            "passed": not failures,
            "artifact": output.name if not failures else None,
            "capture": capture,
            "failures": failures,
        }
        if failures:
            write_json_exclusive(report_path, report)
            print(
                f"FAIL B0: {len(failures)} contract violation(s); "
                f"candidate not published; report={report_path}"
            )
            return 1

        copy_file_exclusive(candidate, output, mode=0o400)
        if file_sha256(output) != capture["sha256"]:
            raise AlignmentError("Published B0 does not match the validated candidate")
        write_json_exclusive(report_path, report)
        print(
            "PASS B0: "
            f"sha256={capture['sha256']} "
            f"schema={capture['database']['schemaFingerprint']['sha256']} "
            f"foreignKeys={capture['database']['foreignKeyCheck']['violationCount']} "
            f"report={report_path}"
        )
        return 0


def validate_baseline(args: argparse.Namespace) -> int:
    baseline = (args.baseline or resolve_default_baseline()).expanduser()
    if not baseline.is_file():
        if not args.skip_missing_private_baseline:
            raise AlignmentError(f"Private baseline does not exist: {baseline}")
        report = {
            **_base_report("validate"),
            "result": "SKIP",
            "passed": False,
            "skipReason": "missing-private-baseline",
            "artifact": baseline.name,
        }
        if args.report:
            write_json_exclusive(args.report, report)
        print("SKIP: missing private baseline")
        return 77

    metadata = inspect_database(baseline)
    actual_sha256 = file_sha256(baseline)
    failures = _contract_failures(metadata, args, actual_sha256)
    report = {
        **_base_report("validate"),
        "result": "PASS" if not failures else "FAIL",
        "passed": not failures,
        "artifact": baseline.name,
        "sha256": actual_sha256,
        "byteCount": baseline.stat().st_size,
        "database": metadata,
        "failures": failures,
    }
    if args.report:
        write_json_exclusive(args.report, report)
    print(
        f"{'PASS' if not failures else 'FAIL'} B0: "
        f"sha256={actual_sha256} "
        f"schema={metadata['schemaFingerprint']['sha256']} "
        f"foreignKeys={metadata['foreignKeyCheck']['violationCount']}"
        + (f"; report={args.report}" if args.report else "")
    )
    return 0 if not failures else 1


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "create":
            return create_baseline(args)
        return validate_baseline(args)
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except sqlite3.Error as error:  # type: ignore[name-defined]
        print(f"ERROR: SQLite validation failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
