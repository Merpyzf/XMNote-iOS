#!/usr/bin/env python3
"""Host orchestration for seeding and replaying the isolated Android .uitest app."""

from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from book_alignment.common import (  # type: ignore[import-not-found]
        AlignmentError,
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        ensure_private_directory,
        ensure_safe_name,
        file_sha256,
        inspect_database,
        load_json,
        privacy_policy,
        resolve_default_baseline,
        utc_now,
        write_json_exclusive,
    )
    from book_alignment.contract import (  # type: ignore[import-not-found]
        validate_case_payload,
    )
else:
    from .common import (
        AlignmentError,
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        ensure_private_directory,
        ensure_safe_name,
        file_sha256,
        inspect_database,
        load_json,
        privacy_policy,
        resolve_default_baseline,
        utc_now,
        write_json_exclusive,
    )
    from .contract import validate_case_payload


TARGET_PACKAGE = "com.merpyzf.xmnote.uitest"
TEST_PACKAGE = "com.merpyzf.xmnote.uitest.test"
RUNNER = "com.merpyzf.xmnote.alignment.BookAlignmentAndroidJUnitRunner"
NOOP_TEST_SELECTOR = (
    "com.merpyzf.xmnote.alignment.BookAlignmentInfrastructureReplayTest"
    "#privateBaseline_canOpenAndProduceReplaySnapshots"
)
STABILITY_TEST_SELECTOR = (
    "com.merpyzf.xmnote.alignment.BookAlignmentStabilityReplayTest"
    "#restartedProcess_capturesS4"
)
RESUME_ARGUMENT = "xmnote.bookAlignment.resume"
INSTRUMENTATION_COMPONENT = f"{TEST_PACKAGE}/{RUNNER}"
INBOX = "files/book-alignment/inbox"
RESUME_MARKER = f"{INBOX}/resume-request"
OUTBOX = "files/book-alignment/out"
NOOP_CASE_ID = "infrastructure.noop"
CASE_CONTRACT_DIRECTORY = pathlib.Path(__file__).resolve().parent / "cases"
DEVICE_PATTERN = re.compile(r"^[A-Za-z0-9._:-]+$")
PASSING_TEST_PATTERN = re.compile(r"\bOK \(1 test\)")
DIAGNOSTIC_AGGREGATE_STATUS_KEY = "xmnote.bookAlignment.aggregate.v1"
ANDROID_TARGET_USER_VERSION = 48
ANDROID_TARGET_ROOM_IDENTITY_HASH = "cda5a591da1f57aca266af36255e5df7"
DIAGNOSTIC_AGGREGATE_PATTERN = re.compile(
    rf"^INSTRUMENTATION_STATUS: {re.escape(DIAGNOSTIC_AGGREGATE_STATUS_KEY)}=(\{{.*\}})$",
    re.MULTILINE,
)
INBOX_SHA_MAX_ATTEMPTS = 8
INBOX_SHA_RETRY_INTERVAL_SECONDS = 0.25
REQUIRED_BASELINE_KEYS = (
    "formatVersion",
    "snapshotId",
    "baselineSha256",
    "schemaSha256",
    "roomIdentityHash",
    "userVersion",
    "foreignKeyViolationCount",
    "foreignKeyViolationSha256",
)
OPTIONAL_BASELINE_KEYS = ("runtimeProfileSha256", "bindingsSha256")
REQUIRED_SNAPSHOT_KEYS = (
    "formatVersion",
    "snapshotId",
    "baselineSha256",
    "caseId",
    "stage",
    "generatedAt",
    "databaseSha256",
    "schemaSha256",
    "roomIdentityHash",
    "userVersion",
    "foreignKeyViolationCount",
    "foreignKeyViolationSha256",
)


@dataclass(frozen=True)
class ReplayAdapter:
    """One auditable case-to-JUnit mapping; callers cannot inject a test selector."""

    test_selector: str
    contract_file: str | None


A01_A04_GOLDEN_CLASS = (
    "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
)
A05_A09_GOLDEN_CLASS = (
    "com.merpyzf.xmnote.alignment.BookAlignmentScenarioReplayTest"
)
SORTING_OWNER_GOLDEN_CLASS = (
    "com.merpyzf.xmnote.alignment.BookAlignmentSortingOwnerReplayTest"
)
MERGE_DELETE_LIFECYCLE_GOLDEN_CLASS = (
    "com.merpyzf.xmnote.alignment.BookAlignmentMergeDeleteLifecycleReplayTest"
)
COLLECTION_CONCURRENCY_STRESS_CLASS = (
    "com.merpyzf.xmnote.alignment.BookAlignmentCollectionConcurrencyStressTest"
)
A01_A04_REQUESTED_SELECTOR = f"{A01_A04_GOLDEN_CLASS}#runRequestedGolden"
SORTING_OWNER_REQUESTED_SELECTOR = f"{SORTING_OWNER_GOLDEN_CLASS}#runRequestedGolden"
MERGE_DELETE_LIFECYCLE_REQUESTED_SELECTOR = (
    f"{MERGE_DELETE_LIFECYCLE_GOLDEN_CLASS}#runRequestedGolden"
)
REPLAY_ADAPTERS = {
    NOOP_CASE_ID: ReplayAdapter(NOOP_TEST_SELECTOR, None),
    "a-01-delete-groups-late-failure": ReplayAdapter(
        f"{A01_A04_GOLDEN_CLASS}#a01_deleteGroups_lateFailure",
        "a-01-delete-groups-late-failure.case.json",
    ),
    "a-02-delete-books-late-failure": ReplayAdapter(
        f"{A01_A04_GOLDEN_CLASS}#a02_deleteBooks_lateFailure",
        "a-02-delete-books-late-failure.case.json",
    ),
    "a-03-batch-source-late-failure": ReplayAdapter(
        f"{A01_A04_GOLDEN_CLASS}#a03_batchSource_lateFailure",
        "a-03-batch-source-late-failure.case.json",
    ),
    "a-04-single-replace-batch-append-tags": ReplayAdapter(
        f"{A01_A04_GOLDEN_CLASS}#a04_singleReplace_batchAppendTags",
        "a-04-single-replace-batch-append-tags.case.json",
    ),
    "a-05-sort-late-failure": ReplayAdapter(
        f"{A05_A09_GOLDEN_CLASS}#a05_sort_lateFailure",
        "a-05-sort-late-failure.case.json",
    ),
    "a-06-move-out-start-reverses-order": ReplayAdapter(
        f"{A05_A09_GOLDEN_CLASS}#a06_moveOutStart_reversesOrder",
        "a-06-move-out-start-reverses-order.case.json",
    ),
    "a-07-merge-updates-deleted-books": ReplayAdapter(
        f"{A05_A09_GOLDEN_CLASS}#a07_merge_updatesDeletedBooks",
        "a-07-merge-updates-deleted-books.case.json",
    ),
    "a-08-collection-duplicate-schema-gap": ReplayAdapter(
        f"{A05_A09_GOLDEN_CLASS}#a08_collection_duplicateSchemaGap",
        "a-08-collection-duplicate-schema-gap.case.json",
    ),
    "a-09-soft-vs-hard-delete": ReplayAdapter(
        f"{A05_A09_GOLDEN_CLASS}#a09_softDelete",
        "a-09-soft-vs-hard-delete.case.json",
    ),
    "a03.status-rating.late-failure": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a03-status-rating-late-failure.case.json",
    ),
    "a03.single-tag.late-failure": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a03-single-tag-late-failure.case.json",
    ),
    "a03.multi-tag.late-failure": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a03-multi-tag-late-failure.case.json",
    ),
    "a03.tag-delete.late-failure": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a03-tag-delete-late-failure.case.json",
    ),
    "a03.source-delete.late-failure": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a03-source-delete-late-failure.case.json",
    ),
    "a01.group-moveout.late-failure": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a01-group-moveout-late-failure.case.json",
    ),
    "a03.duplicate-tag-and-book-ids": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a03-duplicate-tag-and-book-ids.case.json",
    ),
    "a03.source-delete.success": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a03-source-delete-success.case.json",
    ),
    "a04.empty-tag-selection": ReplayAdapter(
        A01_A04_REQUESTED_SELECTOR,
        "a04-empty-tag-selection.case.json",
    ),
    "a05.group-suspend-sort.late-failure": ReplayAdapter(
        SORTING_OWNER_REQUESTED_SELECTOR,
        "a05-group-suspend-sort-late-failure.case.json",
    ),
    "a05.group-rx-sort.late-failure": ReplayAdapter(
        SORTING_OWNER_REQUESTED_SELECTOR,
        "a05-group-rx-sort-late-failure.case.json",
    ),
    "a05.read-status-sort.late-failure": ReplayAdapter(
        SORTING_OWNER_REQUESTED_SELECTOR,
        "a05-read-status-sort-late-failure.case.json",
    ),
    "a05.source-sort.late-failure": ReplayAdapter(
        SORTING_OWNER_REQUESTED_SELECTOR,
        "a05-source-sort-late-failure.case.json",
    ),
    "a05.tag-sort.late-failure": ReplayAdapter(
        SORTING_OWNER_REQUESTED_SELECTOR,
        "a05-tag-sort-late-failure.case.json",
    ),
    "a07.author-merge.late-failure": ReplayAdapter(
        MERGE_DELETE_LIFECYCLE_REQUESTED_SELECTOR,
        "a07-author-merge-late-failure.case.json",
    ),
    "a07.press-merge.late-failure": ReplayAdapter(
        MERGE_DELETE_LIFECYCLE_REQUESTED_SELECTOR,
        "a07-press-merge-late-failure.case.json",
    ),
    "a09.tag-replace-tombstone-growth": ReplayAdapter(
        MERGE_DELETE_LIFECYCLE_REQUESTED_SELECTOR,
        "a09-tag-replace-tombstone-growth.case.json",
    ),
    "a11.group-only-collection-scope": ReplayAdapter(
        f"{A05_A09_GOLDEN_CLASS}#a11_groupOnlyCollectionScope_isStableAndDeduplicated",
        "a11-group-only-collection-scope.case.json",
    ),
    "a08.collection-concurrency.stress": ReplayAdapter(
        f"{COLLECTION_CONCURRENCY_STRESS_CLASS}#runRepositoryConcurrencyStress",
        "a08-collection-concurrency-stress.case.json",
    ),
}
DIAGNOSTIC_CASE_IDS = ("a08.collection-concurrency.stress",)
PRIMARY_ALIGNMENT_CASE_IDS = tuple(
    case_id
    for case_id in REPLAY_ADAPTERS
    if case_id.startswith("a-")
)
EXTENDED_ALIGNMENT_CASE_IDS = tuple(
    case_id
    for case_id in REPLAY_ADAPTERS
    if case_id != NOOP_CASE_ID
    and case_id not in PRIMARY_ALIGNMENT_CASE_IDS
    and case_id not in DIAGNOSTIC_CASE_IDS
)
ALIGNMENT_CASE_IDS = PRIMARY_ALIGNMENT_CASE_IDS + EXTENDED_ALIGNMENT_CASE_IDS
RUNNABLE_CASE_IDS = ALIGNMENT_CASE_IDS + DIAGNOSTIC_CASE_IDS


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate baseline.properties with common.py metadata, stream B0 only "
            "into the .uitest inbox, run allowlisted scenarios, and pull S1-S4."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    properties = subparsers.add_parser(
        "properties", help="generate the exact ASCII baseline.properties contract"
    )
    _add_baseline_inputs(properties)
    properties.add_argument("--snapshot-id", required=True)
    properties.add_argument("--output", type=pathlib.Path, required=True)

    seed = subparsers.add_parser(
        "seed", help="stream B0 and baseline.properties to the fixed .uitest inbox"
    )
    seed.add_argument("--device", required=True)
    seed.add_argument("--baseline", type=pathlib.Path)
    seed.add_argument("--properties", type=pathlib.Path, required=True)
    seed.add_argument("--skip-missing-private-baseline", action="store_true")
    seed.add_argument(
        "--reset-uitest-data",
        action="store_true",
        help="clear only com.merpyzf.xmnote.uitest before seeding; never touches production",
    )

    run = subparsers.add_parser(
        "run", help="run one allowlisted case in a fresh instrumentation process"
    )
    run.add_argument("--device", required=True)
    run.add_argument("--case-id", required=True)
    run.add_argument("--manifest", type=pathlib.Path)

    run_noop = subparsers.add_parser(
        "run-noop", help="compatibility alias for the infrastructure.noop method"
    )
    run_noop.add_argument("--device", required=True)

    pull = subparsers.add_parser(
        "pull", help="stream and validate S1-S4 plus properties from the .uitest outbox"
    )
    pull.add_argument("--device", required=True)
    pull.add_argument("--case-id", default=NOOP_CASE_ID)
    pull.add_argument("--snapshot-id", required=True)
    pull.add_argument("--baseline", type=pathlib.Path)
    pull.add_argument("--output-dir", type=pathlib.Path, required=True)
    pull.add_argument(
        "--instrumentation-manifest",
        type=pathlib.Path,
        help="required privacy-safe manifest produced by the matching run command",
    )
    pull.add_argument("--skip-missing-private-baseline", action="store_true")

    noop = subparsers.add_parser(
        "noop", help="generate properties, seed, run infrastructure.noop, and pull S1-S4"
    )
    noop.add_argument("--device", required=True)
    noop.add_argument("--snapshot-id", required=True)
    noop.add_argument("--output-dir", type=pathlib.Path, required=True)
    noop.add_argument("--properties-output", type=pathlib.Path)
    noop.add_argument("--reset-uitest-data", action="store_true")
    _add_baseline_inputs(noop)

    replay = subparsers.add_parser(
        "replay", help="seed, run, and pull one allowlisted case"
    )
    replay.add_argument("--device", required=True)
    replay.add_argument("--case-id", required=True)
    replay.add_argument("--snapshot-id", required=True)
    replay.add_argument("--output-dir", type=pathlib.Path, required=True)
    replay.add_argument("--properties-output", type=pathlib.Path)
    _add_baseline_inputs(replay)

    batch = subparsers.add_parser(
        "batch-all",
        help="run all primary and extended cases with a fresh DB per case",
    )
    batch.add_argument("--device", required=True)
    batch.add_argument("--snapshot-id", required=True)
    batch.add_argument("--output-root", type=pathlib.Path, required=True)
    batch.add_argument("--properties-output", type=pathlib.Path)
    _add_baseline_inputs(batch)
    return parser.parse_args(argv)


def _add_baseline_inputs(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--capture-report", type=pathlib.Path)
    parser.add_argument("--runtime-profile", type=pathlib.Path)
    parser.add_argument("--bindings", type=pathlib.Path)
    parser.add_argument("--skip-missing-private-baseline", action="store_true")


def _device(value: str) -> str:
    if not DEVICE_PATTERN.fullmatch(value):
        raise AlignmentError("--device contains unsupported characters")
    return value


def _adapter_for_case(case_id: str) -> ReplayAdapter:
    safe_case_id = ensure_safe_name(case_id, "case-id")
    adapter = REPLAY_ADAPTERS.get(safe_case_id)
    if adapter is None:
        raise AlignmentError("Case is not registered in the Android replay allowlist")
    if adapter.contract_file is not None:
        contract_path = CASE_CONTRACT_DIRECTORY / adapter.contract_file
        case = validate_case_payload(load_json(contract_path))
        if case["caseId"] != safe_case_id:
            raise AlignmentError("Allowlisted Android adapter does not match its contract")
    return adapter


def _instrumentation_command(case_id: str) -> list[str]:
    adapter = _adapter_for_case(case_id)
    return [
        "shell",
        "am",
        "instrument",
        "-w",
        "-r",
        "-e",
        "xmnote.bookAlignment.caseId",
        case_id,
        "-e",
        "class",
        adapter.test_selector,
        INSTRUMENTATION_COMPONENT,
    ]


def _stability_instrumentation_command(case_id: str) -> list[str]:
    _adapter_for_case(case_id)
    return [
        "shell",
        "am",
        "instrument",
        "-w",
        "-r",
        "-e",
        "xmnote.bookAlignment.caseId",
        case_id,
        "-e",
        RESUME_ARGUMENT,
        "true",
        "-e",
        "class",
        STABILITY_TEST_SELECTOR,
        INSTRUMENTATION_COMPONENT,
    ]


def _baseline_path(value: pathlib.Path | None) -> pathlib.Path:
    path = (value or resolve_default_baseline()).expanduser()
    if not path.is_file():
        raise AlignmentError(f"Private baseline does not exist: {path}")
    return path


def _adb(device: str, *command: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["adb", "-s", _device(device), *command],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def _require_adb() -> None:
    if shutil.which("adb") is None:
        raise AlignmentError("adb is not available on PATH")


def _require_success(
    result: subprocess.CompletedProcess[bytes], code: str
) -> bytes:
    if result.returncode != 0:
        raise AlignmentError(code)
    return result.stdout


def _verify_installed(device: str, package: str, code: str) -> None:
    result = _adb(device, "shell", "pm", "path", package)
    output = _require_success(result, code)
    if not output.strip():
        raise AlignmentError(code)


def _read_properties(path: pathlib.Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        raise AlignmentError("Unable to read ASCII properties") from error
    properties: dict[str, str] = {}
    for line_number, line in enumerate(lines, start=1):
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise AlignmentError(f"Invalid properties line {line_number}")
        key, value = line.split("=", 1)
        if not key or key in properties:
            raise AlignmentError(f"Duplicate/empty properties key on line {line_number}")
        properties[key] = value
    return properties


def _write_properties_exclusive(path: pathlib.Path, properties: dict[str, str]) -> None:
    ensure_private_directory(path.parent)
    data = "".join(f"{key}={value}\n" for key, value in properties.items()).encode(
        "ascii"
    )
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as error:
        raise AlignmentError(f"Refusing to overwrite existing properties: {path}") from error
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _validate_capture_report(path: pathlib.Path | None) -> None:
    if path is None:
        return
    report = load_json(path)
    if report.get("passed") is not True:
        raise AlignmentError("Capture report did not pass")
    if report.get("tool") not in {
        "book-alignment-baseline",
        "book-alignment-android-capture",
    }:
        raise AlignmentError("Capture report was not produced by book-alignment tooling")
    if report.get("tool") == "book-alignment-android-capture":
        baseline = report.get("baseline", {})
        if baseline.get("invoked") is not True or baseline.get("passed") is not True:
            raise AlignmentError("Android capture report does not contain a passed B0")


def generate_properties(args: argparse.Namespace) -> int:
    baseline = _baseline_path(args.baseline)
    snapshot_id = ensure_safe_name(args.snapshot_id, "snapshot-id")
    _validate_capture_report(args.capture_report)
    metadata = inspect_database(baseline)
    if metadata["integrityCheck"]["status"] != "ok" or metadata["quickCheck"]["status"] != "ok":
        raise AlignmentError("B0 integrity validation failed")
    if metadata["userVersion"] != DEFAULT_USER_VERSION:
        raise AlignmentError("B0 user_version is not 47")
    if metadata["roomIdentityHash"] != DEFAULT_ROOM_IDENTITY_HASH:
        raise AlignmentError("B0 Room identity hash is not v47")
    properties: dict[str, str] = {
        "formatVersion": "1",
        "snapshotId": snapshot_id,
        "baselineSha256": file_sha256(baseline),
        "schemaSha256": metadata["schemaFingerprint"]["sha256"],
        "roomIdentityHash": metadata["roomIdentityHash"],
        "userVersion": str(metadata["userVersion"]),
        "foreignKeyViolationCount": str(
            metadata["foreignKeyCheck"]["violationCount"]
        ),
        "foreignKeyViolationSha256": metadata["foreignKeyCheck"]["setDigest"],
    }
    if args.runtime_profile is not None:
        if not args.runtime_profile.is_file():
            raise AlignmentError("runtime-profile.json does not exist")
        properties["runtimeProfileSha256"] = file_sha256(args.runtime_profile)
    if args.bindings is not None:
        if not args.bindings.is_file():
            raise AlignmentError("bindings.json does not exist")
        properties["bindingsSha256"] = file_sha256(args.bindings)
    _write_properties_exclusive(args.output, properties)
    print(
        f"PASS baseline.properties: snapshotId={snapshot_id} "
        f"foreignKeys={properties['foreignKeyViolationCount']} output={args.output}"
    )
    return 0


def _validate_baseline_properties(
    properties_path: pathlib.Path, baseline: pathlib.Path
) -> dict[str, str]:
    properties = _read_properties(properties_path)
    allowed = set(REQUIRED_BASELINE_KEYS) | set(OPTIONAL_BASELINE_KEYS)
    if set(properties) - allowed:
        raise AlignmentError("baseline.properties contains unknown keys")
    missing = [key for key in REQUIRED_BASELINE_KEYS if key not in properties]
    if missing:
        raise AlignmentError("baseline.properties is missing required keys")
    if properties["formatVersion"] != "1":
        raise AlignmentError("baseline.properties formatVersion must be 1")
    ensure_safe_name(properties["snapshotId"], "snapshotId")
    metadata = inspect_database(baseline)
    expected = {
        "baselineSha256": file_sha256(baseline),
        "schemaSha256": metadata["schemaFingerprint"]["sha256"],
        "roomIdentityHash": str(metadata["roomIdentityHash"]),
        "userVersion": str(metadata["userVersion"]),
        "foreignKeyViolationCount": str(
            metadata["foreignKeyCheck"]["violationCount"]
        ),
        "foreignKeyViolationSha256": metadata["foreignKeyCheck"]["setDigest"],
    }
    if any(properties[key] != value for key, value in expected.items()):
        raise AlignmentError("baseline.properties does not describe the supplied B0")
    return properties


def _remote_exists(device: str, relative_path: str) -> bool:
    result = _adb(
        device,
        "shell",
        "run-as",
        TARGET_PACKAGE,
        "stat",
        "-c",
        "%s",
        relative_path,
    )
    return result.returncode == 0


def _stream_to_inbox(
    device: str, source: pathlib.Path, remote_name: str
) -> None:
    remote_path = f"{INBOX}/{remote_name}"
    if _remote_exists(device, remote_path):
        raise AlignmentError(f".uitest inbox already contains {remote_name}")
    command = f"set -C; umask 077; cat > {remote_path}"
    with source.open("rb") as handle:
        process = subprocess.run(
            [
                "adb",
                "-s",
                _device(device),
                "exec-in",
                "run-as",
                TARGET_PACKAGE,
                "sh",
                "-c",
                command,
            ],
            stdin=handle,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if process.returncode != 0:
        raise AlignmentError(f"Failed to stream {remote_name} into .uitest inbox")
    _poll_inbox_sha(device, remote_path, file_sha256(source), remote_name)


def _poll_inbox_sha(
    device: str,
    remote_path: str,
    expected_digest: str,
    remote_name: str,
) -> None:
    for attempt in range(1, INBOX_SHA_MAX_ATTEMPTS + 1):
        digest_result = _adb(
            device,
            "shell",
            "run-as",
            TARGET_PACKAGE,
            "sha256sum",
            remote_path,
        )
        remote_digest: str | None = None
        if digest_result.returncode == 0:
            try:
                fields = digest_result.stdout.decode("ascii", errors="strict").split()
                remote_digest = fields[0] if fields else None
            except UnicodeError:
                remote_digest = None
        if remote_digest == expected_digest:
            return
        if attempt < INBOX_SHA_MAX_ATTEMPTS:
            time.sleep(INBOX_SHA_RETRY_INTERVAL_SECONDS)
    raise AlignmentError(
        f".uitest inbox SHA mismatch for {remote_name} "
        f"after {INBOX_SHA_MAX_ATTEMPTS} attempts"
    )


def seed_inbox(args: argparse.Namespace) -> int:
    _require_adb()
    baseline = _baseline_path(args.baseline)
    if not args.properties.is_file():
        raise AlignmentError("baseline.properties does not exist")
    _validate_baseline_properties(args.properties, baseline)
    _verify_installed(args.device, TARGET_PACKAGE, ".uitest target package is not installed")
    _require_success(
        _adb(args.device, "shell", "am", "force-stop", TARGET_PACKAGE),
        "Unable to force-stop .uitest target",
    )
    if args.reset_uitest_data:
        output = _require_success(
            _adb(args.device, "shell", "pm", "clear", TARGET_PACKAGE),
            "Unable to clear isolated .uitest data",
        )
        if b"Success" not in output:
            raise AlignmentError("Isolated .uitest data clear did not report success")
    _require_success(
        _adb(
            args.device,
            "shell",
            "run-as",
            TARGET_PACKAGE,
            "mkdir",
            "-p",
            INBOX,
        ),
        "Unable to create .uitest inbox",
    )
    _stream_to_inbox(args.device, baseline, "B0.db")
    _stream_to_inbox(args.device, args.properties, "baseline.properties")
    print("PASS .uitest seed: B0 and baseline.properties streamed and SHA-verified")
    return 0


def run_case(args: argparse.Namespace) -> int:
    manifest = getattr(args, "manifest", None)
    if manifest is not None and manifest.expanduser().exists():
        raise AlignmentError("Refusing to overwrite instrumentation manifest")
    result, evidence = _execute_case(args.device, args.case_id)
    if manifest is not None:
        write_json_exclusive(manifest.expanduser(), evidence)
    return result


def _execute_case(device: str, requested_case_id: str) -> tuple[int, dict[str, Any]]:
    started_at = utc_now()
    case_id = ensure_safe_name(requested_case_id, "case-id")
    adapter = _adapter_for_case(case_id)
    _require_adb()
    _verify_installed(device, TARGET_PACKAGE, ".uitest target package is not installed")
    _verify_installed(device, TEST_PACKAGE, ".uitest test package is not installed")
    operation_result, operation_evidence = _execute_instrumentation_phase(
        device,
        case_id=case_id,
        phase="operation",
        selector=adapter.test_selector,
        command=_instrumentation_command(case_id),
        allow_missing_baseline_skip=True,
    )
    if operation_result != 0:
        evidence = _instrumentation_evidence(
            case_id, started_at, [operation_evidence], "SKIP", False
        )
        return operation_result, evidence

    _require_success(
        _adb(device, "shell", "am", "force-stop", TARGET_PACKAGE),
        "Unable to force-stop .uitest between replay phases",
    )
    _require_success(
        _adb(
            device,
            "shell",
            "run-as",
            TARGET_PACKAGE,
            "touch",
            RESUME_MARKER,
        ),
        "Unable to create the .uitest resume marker",
    )
    stability_result, stability_evidence = _execute_instrumentation_phase(
        device,
        case_id=case_id,
        phase="cold-restart-s4",
        selector=STABILITY_TEST_SELECTOR,
        command=_stability_instrumentation_command(case_id),
        allow_missing_baseline_skip=False,
    )
    evidence = _instrumentation_evidence(
        case_id,
        started_at,
        [operation_evidence, stability_evidence],
        "PASS" if stability_result == 0 else "FAIL",
        stability_result == 0,
    )
    return stability_result, evidence


def _execute_instrumentation_phase(
    device: str,
    *,
    case_id: str,
    phase: str,
    selector: str,
    command: list[str],
    allow_missing_baseline_skip: bool,
) -> tuple[int, dict[str, Any]]:
    started_at = utc_now()
    result = _adb(device, *command)
    output = result.stdout.decode("utf-8", errors="replace")
    diagnostic_sha256 = hashlib.sha256(
        result.stdout + b"\n" + result.stderr
    ).hexdigest()
    phase_evidence = {
        "phase": phase,
        "startedAt": started_at,
        "finishedAt": utc_now(),
        "junitSelector": selector,
        "junitSelectorSha256": hashlib.sha256(
            selector.encode("utf-8")
        ).hexdigest(),
        "stdoutStderrSha256": diagnostic_sha256,
    }
    if "SKIP: missing private" in output:
        if not allow_missing_baseline_skip:
            raise AlignmentError(
                "Cold-restart S4 unexpectedly skipped its preserved live database"
            )
        phase_evidence.update({"result": "SKIP", "passed": False})
        print("SKIP: missing private baseline")
        return 77, phase_evidence
    if result.returncode != 0 or "FAILURES!!!" in output or "INSTRUMENTATION_FAILED" in output:
        raise AlignmentError(
            f"Android {phase} instrumentation failed; "
            f"diagnosticSha256={diagnostic_sha256}"
        )
    if not PASSING_TEST_PATTERN.search(output) or "INSTRUMENTATION_STATUS_CODE: -3" in output:
        raise AlignmentError(
            f"Android {phase} did not execute exactly one passing test; "
            f"diagnosticSha256={diagnostic_sha256}"
        )
    diagnostic_aggregate = _parse_diagnostic_aggregate(case_id, phase, output)
    if diagnostic_aggregate is not None:
        phase_evidence["diagnosticAggregate"] = diagnostic_aggregate
    phase_evidence.update({"result": "PASS", "passed": True})
    print(
        f"PASS Android replay phase={phase}: case={case_id} "
        f"diagnosticSha256={diagnostic_sha256}"
    )
    return 0, phase_evidence


def _parse_diagnostic_aggregate(
    case_id: str,
    phase: str,
    output: str,
) -> dict[str, Any] | None:
    """Extract only the allowlisted, privacy-safe aggregate from a diagnostic run."""

    is_diagnostic_operation = case_id in DIAGNOSTIC_CASE_IDS and phase == "operation"
    matches = DIAGNOSTIC_AGGREGATE_PATTERN.findall(output)
    if not is_diagnostic_operation:
        if matches:
            raise AlignmentError("Unexpected diagnostic aggregate in a Golden phase")
        return None
    if len(matches) != 1:
        raise AlignmentError("Diagnostic operation must emit exactly one aggregate")
    try:
        aggregate = json.loads(matches[0])
    except json.JSONDecodeError as error:
        raise AlignmentError("Diagnostic aggregate is not valid JSON") from error
    _validate_collection_concurrency_aggregate(aggregate, case_id)
    return aggregate


def _validate_collection_concurrency_aggregate(
    aggregate: Any,
    case_id: str,
) -> None:
    expected_keys = {
        "schemaVersion",
        "kind",
        "caseId",
        "collectionId",
        "bookCount",
        "trialsPerBook",
        "workers",
        "callCount",
        "callErrorCount",
        "relationCountsByOrdinal",
        "relationCountHistogram",
        "errorTypeHistogram",
        "duplicateBookCount",
        "minValidRelationCount",
        "maxValidRelationCount",
        "stableAfterReopen",
    }
    if not isinstance(aggregate, dict) or set(aggregate) != expected_keys:
        raise AlignmentError("Diagnostic aggregate has an unexpected key set")
    if (
        aggregate["schemaVersion"] != 1
        or aggregate["kind"] != "collection-concurrency-stress"
        or aggregate["caseId"] != case_id
        or aggregate["collectionId"] != 9_088_101
        or aggregate["bookCount"] != 24
        or aggregate["trialsPerBook"] != 16
        or aggregate["workers"] != 16
        or aggregate["callCount"] != 384
        or aggregate["callErrorCount"] != 0
        or aggregate["duplicateBookCount"] != 0
        or aggregate["minValidRelationCount"] != 1
        or aggregate["maxValidRelationCount"] != 1
        or aggregate["stableAfterReopen"] is not True
    ):
        raise AlignmentError(
            "Diagnostic aggregate does not prove the concurrency uniqueness invariant"
        )

    counts = aggregate["relationCountsByOrdinal"]
    if (
        not isinstance(counts, list)
        or len(counts) != 24
        or any(isinstance(value, bool) or not isinstance(value, int) or value != 1 for value in counts)
    ):
        raise AlignmentError("Diagnostic relation counts are not exactly one per book")
    expected_histogram = {
        str(key): value for key, value in sorted(Counter(counts).items())
    }
    if aggregate["relationCountHistogram"] != expected_histogram:
        raise AlignmentError("Diagnostic relation histogram does not match its counts")
    if (
        aggregate["duplicateBookCount"] != sum(value > 1 for value in counts)
        or aggregate["minValidRelationCount"] != min(counts)
        or aggregate["maxValidRelationCount"] != max(counts)
    ):
        raise AlignmentError("Diagnostic relation summary does not match its counts")

    error_count = aggregate["callErrorCount"]
    error_histogram = aggregate["errorTypeHistogram"]
    if (
        isinstance(error_count, bool)
        or not isinstance(error_count, int)
        or not 0 <= error_count <= 384
        or not isinstance(error_histogram, dict)
        or any(
            not isinstance(name, str)
            or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_$]*", name)
            or isinstance(count, bool)
            or not isinstance(count, int)
            or count < 1
            for name, count in error_histogram.items()
        )
        or sum(error_histogram.values()) != error_count
    ):
        raise AlignmentError("Diagnostic error histogram is invalid")


def _instrumentation_evidence(
    case_id: str,
    started_at: str,
    phases: list[dict[str, Any]],
    result: str,
    passed: bool,
) -> dict[str, Any]:
    digest_input = "\n".join(str(phase["stdoutStderrSha256"]) for phase in phases)
    return {
        "schemaVersion": 1,
        "tool": "book-alignment-android-instrumentation",
        "startedAt": started_at,
        "finishedAt": utc_now(),
        "dataPolicy": privacy_policy(),
        "caseId": case_id,
        "targetPackage": TARGET_PACKAGE,
        "testPackage": TEST_PACKAGE,
        "phases": phases,
        "phaseOutputDigestSha256": hashlib.sha256(
            digest_input.encode("ascii")
        ).hexdigest(),
        "result": result,
        "passed": passed,
    }


def run_noop(args: argparse.Namespace) -> int:
    """Preserve the original run-noop command while using the common safe runner."""

    return run_case(
        argparse.Namespace(device=args.device, case_id=NOOP_CASE_ID, manifest=None)
    )


def _remote_size(device: str, relative_path: str) -> int:
    output = _require_success(
        _adb(
            device,
            "shell",
            "run-as",
            TARGET_PACKAGE,
            "stat",
            "-c",
            "%s",
            relative_path,
        ),
        "Required .uitest outbox artifact is missing",
    ).strip()
    try:
        return int(output)
    except ValueError as error:
        raise AlignmentError("Invalid .uitest outbox size") from error


def _stream_from_outbox(
    device: str,
    relative_path: str,
    destination: pathlib.Path,
    expected_size: int,
) -> None:
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    process = subprocess.Popen(
        [
            "adb",
            "-s",
            _device(device),
            "exec-out",
            "run-as",
            TARGET_PACKAGE,
            "cat",
            relative_path,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.stdout is None or process.stderr is None:
        raise AlignmentError("Unable to open .uitest outbox stream")
    byte_count = 0
    try:
        with os.fdopen(descriptor, "wb") as handle:
            while True:
                chunk = process.stdout.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
                byte_count += len(chunk)
            handle.flush()
            os.fsync(handle.fileno())
        _ = process.stderr.read()
        return_code = process.wait()
    except BaseException:
        process.kill()
        process.wait()
        try:
            destination.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    if return_code != 0 or byte_count != expected_size:
        raise AlignmentError(".uitest outbox stream was incomplete")


def _parse_generated_at(value: str) -> None:
    if not isinstance(value, str):
        raise AlignmentError("Snapshot generatedAt must be text")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise AlignmentError("Snapshot generatedAt is not ISO-8601") from error
    if parsed.tzinfo is None:
        raise AlignmentError("Snapshot generatedAt must include a timezone")


def _validate_instrumentation_evidence(
    evidence: Any, case_id: str
) -> dict[str, Any]:
    if not isinstance(evidence, dict):
        raise AlignmentError("Instrumentation manifest must be an object")
    expected_keys = {
        "schemaVersion",
        "tool",
        "startedAt",
        "finishedAt",
        "dataPolicy",
        "caseId",
        "targetPackage",
        "testPackage",
        "phases",
        "phaseOutputDigestSha256",
        "result",
        "passed",
    }
    if set(evidence) != expected_keys:
        raise AlignmentError("Instrumentation manifest has an unexpected key set")
    if (
        evidence["schemaVersion"] != 1
        or evidence["tool"] != "book-alignment-android-instrumentation"
        or evidence["dataPolicy"] != privacy_policy()
        or evidence["caseId"] != case_id
        or evidence["targetPackage"] != TARGET_PACKAGE
        or evidence["testPackage"] != TEST_PACKAGE
        or evidence["result"] != "PASS"
        or evidence["passed"] is not True
    ):
        raise AlignmentError("Instrumentation manifest does not prove this replay")
    _parse_generated_at(evidence["startedAt"])
    _parse_generated_at(evidence["finishedAt"])

    phases = evidence["phases"]
    expected_phases = (
        ("operation", _adapter_for_case(case_id).test_selector),
        ("cold-restart-s4", STABILITY_TEST_SELECTOR),
    )
    if not isinstance(phases, list) or len(phases) != len(expected_phases):
        raise AlignmentError("Instrumentation manifest must contain both replay phases")
    base_phase_keys = {
        "phase",
        "startedAt",
        "finishedAt",
        "junitSelector",
        "junitSelectorSha256",
        "stdoutStderrSha256",
        "result",
        "passed",
    }
    output_digests: list[str] = []
    for phase, (expected_phase, expected_selector) in zip(
        phases, expected_phases, strict=True
    ):
        phase_keys = set(base_phase_keys)
        if case_id in DIAGNOSTIC_CASE_IDS and expected_phase == "operation":
            phase_keys.add("diagnosticAggregate")
        if not isinstance(phase, dict) or set(phase) != phase_keys:
            raise AlignmentError("Instrumentation phase has an unexpected key set")
        selector_digest = hashlib.sha256(expected_selector.encode("utf-8")).hexdigest()
        output_digest = phase["stdoutStderrSha256"]
        if (
            phase["phase"] != expected_phase
            or phase["junitSelector"] != expected_selector
            or phase["junitSelectorSha256"] != selector_digest
            or phase["result"] != "PASS"
            or phase["passed"] is not True
            or not isinstance(output_digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", output_digest)
        ):
            raise AlignmentError("Instrumentation phase does not prove the allowlisted test")
        _parse_generated_at(phase["startedAt"])
        _parse_generated_at(phase["finishedAt"])
        if "diagnosticAggregate" in phase:
            _validate_collection_concurrency_aggregate(
                phase["diagnosticAggregate"], case_id
            )
        output_digests.append(output_digest)

    expected_digest = hashlib.sha256("\n".join(output_digests).encode("ascii")).hexdigest()
    if evidence["phaseOutputDigestSha256"] != expected_digest:
        raise AlignmentError("Instrumentation phase digest does not match its evidence")
    return evidence


def _validate_pulled_stage(
    stage: str,
    database_path: pathlib.Path,
    properties_path: pathlib.Path,
    *,
    case_id: str,
    snapshot_id: str,
    baseline_sha256: str,
    baseline_metadata: dict[str, Any],
    runtime_metadata: dict[str, Any] | None,
) -> dict[str, Any]:
    properties = _read_properties(properties_path)
    if set(properties) != set(REQUIRED_SNAPSHOT_KEYS):
        raise AlignmentError(f"{stage}.properties has an unexpected key set")
    expected_text = {
        "formatVersion": "1",
        "snapshotId": snapshot_id,
        "baselineSha256": baseline_sha256,
        "caseId": case_id,
        "stage": stage,
    }
    if any(properties[key] != value for key, value in expected_text.items()):
        raise AlignmentError(f"{stage}.properties lineage does not match the replay")
    _parse_generated_at(properties["generatedAt"])
    metadata = inspect_database(database_path)
    actual = {
        "databaseSha256": file_sha256(database_path),
        "schemaSha256": metadata["schemaFingerprint"]["sha256"],
        "roomIdentityHash": str(metadata["roomIdentityHash"]),
        "userVersion": str(metadata["userVersion"]),
        "foreignKeyViolationCount": str(
            metadata["foreignKeyCheck"]["violationCount"]
        ),
        "foreignKeyViolationSha256": metadata["foreignKeyCheck"]["setDigest"],
    }
    if any(properties[key] != value for key, value in actual.items()):
        raise AlignmentError(f"{stage} database does not match its Android properties")
    if metadata["integrityCheck"]["status"] != "ok" or metadata["quickCheck"]["status"] != "ok":
        raise AlignmentError(f"{stage} database integrity check failed")
    if (
        metadata["userVersion"] != ANDROID_TARGET_USER_VERSION
        or metadata["roomIdentityHash"] != ANDROID_TARGET_ROOM_IDENTITY_HASH
    ):
        raise AlignmentError(f"{stage} is not the expected migrated Android v48 schema")
    if runtime_metadata is not None and (
        metadata["userVersion"] != runtime_metadata["userVersion"]
        or metadata["roomIdentityHash"] != runtime_metadata["roomIdentityHash"]
        or metadata["schemaFingerprint"]["sha256"]
        != runtime_metadata["schemaFingerprint"]["sha256"]
    ):
        raise AlignmentError(f"{stage} changed the migrated Android runtime schema")
    baseline_violations = Counter(
        baseline_metadata["foreignKeyCheck"]["violationDigests"]
    )
    snapshot_violations = Counter(metadata["foreignKeyCheck"]["violationDigests"])
    added_violation_count = sum((snapshot_violations - baseline_violations).values())
    if added_violation_count:
        raise AlignmentError(f"{stage} introduced foreign-key violations")
    return {
        "schemaVersion": 1,
        "tool": "book-alignment-android-fixture-pull",
        "generatedAt": properties["generatedAt"],
        "dataPolicy": privacy_policy(),
        "caseId": case_id,
        "platform": "android",
        "stage": stage,
        "result": "PASS",
        "passed": True,
        "baselineSha256": baseline_sha256,
        "snapshot": {
            "sha256": actual["databaseSha256"],
            "byteCount": database_path.stat().st_size,
            "database": metadata,
        },
        "failures": [],
    }


def pull_snapshots(args: argparse.Namespace) -> int:
    case_id = ensure_safe_name(args.case_id, "case-id")
    _adapter_for_case(case_id)
    snapshot_id = ensure_safe_name(args.snapshot_id, "snapshot-id")
    output_dir = args.output_dir.expanduser()
    if output_dir.exists():
        raise AlignmentError(f"Refusing to replace existing output directory: {output_dir}")
    instrumentation_evidence = getattr(args, "instrumentation_evidence", None)
    if instrumentation_evidence is None:
        manifest_path = getattr(args, "instrumentation_manifest", None)
        if manifest_path is None:
            raise AlignmentError("A matching instrumentation manifest is required")
        instrumentation_evidence = load_json(manifest_path.expanduser())
    instrumentation_evidence = _validate_instrumentation_evidence(
        instrumentation_evidence, case_id
    )
    baseline = _baseline_path(args.baseline)
    baseline_sha256 = file_sha256(baseline)
    baseline_metadata = inspect_database(baseline)
    _require_adb()
    _verify_installed(args.device, TARGET_PACKAGE, ".uitest target package is not installed")
    remote_root = f"{OUTBOX}/{case_id}"
    remote_files = [
        f"{stage}.{extension}"
        for stage in ("S1", "S2", "S3", "S4")
        for extension in ("db", "properties")
    ]
    sizes = {
        name: _remote_size(args.device, f"{remote_root}/{name}")
        for name in remote_files
    }
    ensure_private_directory(output_dir.parent)
    with tempfile.TemporaryDirectory(
        prefix=f".{output_dir.name}.pull-", dir=output_dir.parent
    ) as temporary_directory:
        root = pathlib.Path(temporary_directory)
        for name in remote_files:
            _stream_from_outbox(
                args.device,
                f"{remote_root}/{name}",
                root / name,
                sizes[name],
            )
        post_sizes = {
            name: _remote_size(args.device, f"{remote_root}/{name}")
            for name in remote_files
        }
        if post_sizes != sizes:
            raise AlignmentError(".uitest outbox changed while snapshots were pulled")
        runtime_metadata: dict[str, Any] | None = None
        for stage in ("S1", "S2", "S3", "S4"):
            database_path = root / f"{stage}.db"
            properties_path = root / f"{stage}.properties"
            manifest = _validate_pulled_stage(
                stage,
                database_path,
                properties_path,
                case_id=case_id,
                snapshot_id=snapshot_id,
                baseline_sha256=baseline_sha256,
                baseline_metadata=baseline_metadata,
                runtime_metadata=runtime_metadata,
            )
            if runtime_metadata is None:
                runtime_metadata = manifest["snapshot"]["database"]
            write_json_exclusive(
                root / f"{stage}.db.manifest.json", manifest
            )
            database_path.chmod(0o400)
            properties_path.chmod(0o400)
        write_json_exclusive(
            root / "instrumentation.manifest.json",
            instrumentation_evidence,
        )
        if output_dir.exists():
            raise AlignmentError("Output directory appeared while snapshots were pulled")
        root.rename(output_dir)
    print(
        f"PASS Android pull {case_id}: validated S1-S4 and generated manifests; "
        f"output={output_dir}"
    )
    return 0


def _generate_replay_properties(
    args: argparse.Namespace, properties_output: pathlib.Path
) -> None:
    properties_args = argparse.Namespace(
        baseline=args.baseline,
        capture_report=args.capture_report,
        runtime_profile=args.runtime_profile,
        bindings=args.bindings,
        snapshot_id=args.snapshot_id,
        output=properties_output,
    )
    generate_properties(properties_args)


def _seed_run_pull(
    args: argparse.Namespace,
    *,
    case_id: str,
    output_dir: pathlib.Path,
    properties_output: pathlib.Path,
    reset_uitest_data: bool,
) -> int:
    _adapter_for_case(case_id)
    seed_args = argparse.Namespace(
        device=args.device,
        baseline=args.baseline,
        properties=properties_output,
        reset_uitest_data=reset_uitest_data,
    )
    seed_inbox(seed_args)
    run_result, instrumentation_evidence = _execute_case(args.device, case_id)
    if run_result != 0:
        return run_result
    pull_args = argparse.Namespace(
        device=args.device,
        case_id=case_id,
        snapshot_id=args.snapshot_id,
        baseline=args.baseline,
        output_dir=output_dir,
        instrumentation_evidence=instrumentation_evidence,
    )
    pull_result = pull_snapshots(pull_args)
    if pull_result != 0:
        return pull_result
    return 0


def run_noop_all(args: argparse.Namespace) -> int:
    output_dir = args.output_dir.expanduser()
    properties_output = (
        args.properties_output or pathlib.Path(f"{output_dir}.baseline.properties")
    ).expanduser()
    if output_dir.exists():
        raise AlignmentError("Refusing to replace existing noop output directory")
    if properties_output.exists():
        raise AlignmentError("Refusing to replace existing baseline properties")
    _generate_replay_properties(args, properties_output)
    return _seed_run_pull(
        args,
        case_id=NOOP_CASE_ID,
        output_dir=output_dir,
        properties_output=properties_output,
        reset_uitest_data=args.reset_uitest_data,
    )


def run_replay(args: argparse.Namespace) -> int:
    case_id = ensure_safe_name(args.case_id, "case-id")
    _adapter_for_case(case_id)
    output_dir = args.output_dir.expanduser()
    properties_output = (
        args.properties_output or pathlib.Path(f"{output_dir}.baseline.properties")
    ).expanduser()
    if output_dir.exists():
        raise AlignmentError("Refusing to replace existing replay output directory")
    if properties_output.exists():
        raise AlignmentError("Refusing to replace existing baseline properties")
    _generate_replay_properties(args, properties_output)
    return _seed_run_pull(
        args,
        case_id=case_id,
        output_dir=output_dir,
        properties_output=properties_output,
        reset_uitest_data=True,
    )


def run_batch_all(args: argparse.Namespace) -> int:
    output_root = args.output_root.expanduser()
    properties_output = (
        args.properties_output or pathlib.Path(f"{output_root}.baseline.properties")
    ).expanduser()
    if output_root.exists():
        raise AlignmentError("Refusing to replace an existing batch output root")
    if properties_output.exists():
        raise AlignmentError("Refusing to replace existing baseline properties")
    for case_id in ALIGNMENT_CASE_IDS:
        _adapter_for_case(case_id)
    _generate_replay_properties(args, properties_output)
    completed = 0
    for case_id in ALIGNMENT_CASE_IDS:
        result = _seed_run_pull(
            args,
            case_id=case_id,
            output_dir=output_root / case_id,
            properties_output=properties_output,
            reset_uitest_data=True,
        )
        if result != 0:
            return result
        completed += 1
    print(f"PASS Android batch-all: completedCases={completed}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if (
        getattr(args, "skip_missing_private_baseline", False)
        and args.command in {"properties", "seed", "pull", "noop", "replay", "batch-all"}
        and not (args.baseline or resolve_default_baseline()).expanduser().is_file()
    ):
        print("SKIP: missing private baseline")
        return 77
    try:
        if args.command == "properties":
            return generate_properties(args)
        if args.command == "seed":
            return seed_inbox(args)
        if args.command == "run":
            return run_case(args)
        if args.command == "run-noop":
            return run_noop(args)
        if args.command == "pull":
            return pull_snapshots(args)
        if args.command == "noop":
            return run_noop_all(args)
        if args.command == "replay":
            return run_replay(args)
        return run_batch_all(args)
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
