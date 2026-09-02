#!/usr/bin/env python3
"""Seed isolated live copies and capture immutable S0-S7 SQLite snapshots."""

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
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        copy_file_exclusive,
        ensure_safe_name,
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
        ensure_safe_name,
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


STAGES = tuple(f"S{index}" for index in range(8))
PLATFORMS = ("baseline", "android", "ios", "archive")


def _add_database_contract(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--expected-user-version", type=int, default=DEFAULT_USER_VERSION
    )
    parser.add_argument(
        "--expected-room-identity-hash", default=DEFAULT_ROOM_IDENTITY_HASH
    )
    parser.add_argument("--expected-schema-fingerprint")
    parser.add_argument("--require-no-foreign-key-violations", action="store_true")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create byte-identical Android/iOS live copies from B0, or checkpoint a "
            "closed scenario database into an immutable S0-S7 evidence snapshot."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    seed = subparsers.add_parser(
        "seed", help="copy B0 byte-for-byte to a distinct writable platform live DB"
    )
    seed.add_argument("--baseline", type=pathlib.Path)
    seed.add_argument("--output", type=pathlib.Path, required=True)
    seed.add_argument("--report", type=pathlib.Path)
    seed.add_argument("--case-id", required=True)
    seed.add_argument("--platform", choices=("android", "ios"), required=True)
    seed.add_argument("--expected-baseline-sha256")
    seed.add_argument("--skip-missing-private-baseline", action="store_true")
    _add_database_contract(seed)

    capture = subparsers.add_parser(
        "capture",
        help="copy db/wal/shm, checkpoint only that copy, and publish one read-only snapshot",
    )
    capture.add_argument("--db", type=pathlib.Path, required=True)
    capture.add_argument("--wal", type=pathlib.Path)
    capture.add_argument("--shm", type=pathlib.Path)
    capture.add_argument("--output", type=pathlib.Path, required=True)
    capture.add_argument("--manifest", type=pathlib.Path)
    capture.add_argument("--case-id", required=True)
    capture.add_argument("--platform", choices=PLATFORMS, required=True)
    capture.add_argument("--stage", choices=STAGES, required=True)
    capture.add_argument(
        "--baseline-sha256",
        help="lineage SHA; default is derived from the env/fallback private B0",
    )
    _add_database_contract(capture)
    return parser.parse_args(argv)


def _base_report(command: str, case_id: str, platform: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "tool": "book-alignment-snapshot",
        "command": command,
        "generatedAt": utc_now(),
        "caseId": ensure_safe_name(case_id, "case-id"),
        "platform": platform,
        "dataPolicy": privacy_policy(),
    }


def _database_failures(
    metadata: dict[str, Any], args: argparse.Namespace
) -> list[dict[str, Any]]:
    expected_schema = (
        validate_sha256(
            args.expected_schema_fingerprint, "--expected-schema-fingerprint"
        )
        if args.expected_schema_fingerprint
        else None
    )
    return validate_database_contract(
        metadata,
        expected_user_version=args.expected_user_version,
        expected_room_identity_hash=args.expected_room_identity_hash or None,
        expected_schema_fingerprint=expected_schema,
        require_no_foreign_key_violations=args.require_no_foreign_key_violations,
    )


def seed_live_database(args: argparse.Namespace) -> int:
    baseline = (args.baseline or resolve_default_baseline()).expanduser()
    report_path = args.report or pathlib.Path(f"{args.output}.seed.json")
    if not baseline.is_file():
        if not args.skip_missing_private_baseline:
            raise AlignmentError(f"Private baseline does not exist: {baseline}")
        report = {
            **_base_report("seed", args.case_id, args.platform),
            "result": "SKIP",
            "passed": False,
            "skipReason": "missing-private-baseline",
        }
        write_json_exclusive(report_path, report)
        print("SKIP: missing private baseline")
        return 77

    output = args.output.expanduser()
    if baseline.resolve() == output.resolve(strict=False):
        raise AlignmentError(
            "Live database must be a distinct path; B0 is never opened as a live store"
        )
    if output.exists() or pathlib.Path(f"{output}-wal").exists() or pathlib.Path(
        f"{output}-shm"
    ).exists():
        raise AlignmentError(
            "Refusing to seed over an existing live database or SQLite sidecar"
        )
    if report_path.exists():
        raise AlignmentError(f"Refusing to overwrite existing report: {report_path}")

    baseline_sha256 = file_sha256(baseline)
    if args.expected_baseline_sha256:
        expected_sha256 = validate_sha256(
            args.expected_baseline_sha256, "--expected-baseline-sha256"
        )
        if baseline_sha256 != expected_sha256:
            raise AlignmentError(
                "B0 SHA-256 does not match the case contract; live copy was not created"
            )
    metadata = inspect_database(baseline)
    failures = _database_failures(metadata, args)
    if failures:
        report = {
            **_base_report("seed", args.case_id, args.platform),
            "result": "FAIL",
            "passed": False,
            "baselineSha256": baseline_sha256,
            "database": metadata,
            "failures": failures,
        }
        write_json_exclusive(report_path, report)
        print(f"FAIL seed: {len(failures)} B0 contract violation(s); report={report_path}")
        return 1

    copy_file_exclusive(baseline, output, mode=0o600)
    output_sha256 = file_sha256(output)
    if output_sha256 != baseline_sha256:
        raise AlignmentError("Seeded live database is not byte-identical to B0")
    report = {
        **_base_report("seed", args.case_id, args.platform),
        "result": "PASS",
        "passed": True,
        "baselineSha256": baseline_sha256,
        "liveCopySha256": output_sha256,
        "byteIdentical": True,
        "distinctFile": baseline.stat().st_ino != output.stat().st_ino,
        "database": metadata,
    }
    write_json_exclusive(report_path, report)
    print(
        f"PASS seed {args.platform}: byte-identical SHA-256={output_sha256}; "
        f"report={report_path}"
    )
    return 0


def _resolve_lineage_sha(value: str | None) -> str:
    if value:
        return validate_sha256(value, "--baseline-sha256")
    baseline = resolve_default_baseline()
    if not baseline.is_file():
        raise AlignmentError(
            "Baseline lineage is required: pass --baseline-sha256 or provide the "
            "private baseline convention"
        )
    return file_sha256(baseline)


def capture_snapshot(args: argparse.Namespace) -> int:
    output = args.output.expanduser()
    manifest_path = args.manifest or pathlib.Path(f"{output}.manifest.json")
    if output.exists():
        raise AlignmentError(f"Refusing to overwrite existing snapshot: {output}")
    if manifest_path.exists():
        raise AlignmentError(f"Refusing to overwrite existing manifest: {manifest_path}")
    baseline_sha256 = _resolve_lineage_sha(args.baseline_sha256)
    capture = frozen_checkpoint_copy(
        args.db,
        args.wal,
        args.shm,
        output,
        output_mode=0o400,
    )
    failures = _database_failures(capture["database"], args)
    if args.stage == "S0" and capture["sha256"] != baseline_sha256:
        failures.append(
            {
                "reason": "s0-not-byte-identical-to-b0",
                "expected": baseline_sha256,
                "actual": capture["sha256"],
            }
        )
    report = {
        **_base_report("capture", args.case_id, args.platform),
        "stage": args.stage,
        "result": "PASS" if not failures else "FAIL",
        "passed": not failures,
        "baselineSha256": baseline_sha256,
        "snapshot": capture,
        "failures": failures,
    }
    write_json_exclusive(manifest_path, report)
    print(
        f"{'PASS' if not failures else 'FAIL'} {args.platform}-{args.stage}: "
        f"sha256={capture['sha256']} foreignKeys="
        f"{capture['database']['foreignKeyCheck']['violationCount']}; "
        f"manifest={manifest_path}"
    )
    return 0 if not failures else 1


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "seed":
            return seed_live_database(args)
        return capture_snapshot(args)
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except sqlite3.Error as error:
        print(f"ERROR: SQLite operation failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
