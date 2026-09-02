#!/usr/bin/env python3
"""Host-only orchestration for the dedicated iOS book-alignment Simulator.

This adapter never opens B0 as a live store. It first asks ``snapshot.py`` to
produce a byte-identical writable host clone, then copies that clone into a
case-private directory inside the installed DEBUG app's data container. A live
database is captured only after the app has been terminated; ``snapshot.py``
checkpoints a frozen copy rather than the GRDB-owned source.

The allowlisted A-09 replay can instead import Android's validated S2 snapshot.
That S2 remains a scenario checkpoint (never relabeled as B0): its manifest must
prove B0 lineage and its bytes, schema, and foreign-key multiset are revalidated
before iOS opens an independent copy.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from book_alignment import snapshot  # type: ignore[import-not-found]
    from book_alignment.common import (  # type: ignore[import-not-found]
        AlignmentError,
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        copy_file_exclusive,
        ensure_private_directory,
        ensure_safe_name,
        file_sha256,
        foreign_key_summary,
        immutable_connection,
        inspect_database,
        json_digest,
        load_json,
        privacy_policy,
        quoted,
        resolve_default_baseline,
        schema_fingerprint,
        utc_now,
        validate_sha256,
        write_json_exclusive,
    )
    from book_alignment.contract import (  # type: ignore[import-not-found]
        validate_bindings_payload,
        validate_case_payload,
        validate_runtime_profile_payload,
    )
else:
    from . import snapshot
    from .common import (
        AlignmentError,
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        copy_file_exclusive,
        ensure_private_directory,
        ensure_safe_name,
        file_sha256,
        foreign_key_summary,
        immutable_connection,
        inspect_database,
        json_digest,
        load_json,
        privacy_policy,
        quoted,
        resolve_default_baseline,
        schema_fingerprint,
        utc_now,
        validate_sha256,
        write_json_exclusive,
    )
    from .contract import (
        validate_bindings_payload,
        validate_case_payload,
        validate_runtime_profile_payload,
    )


DEDICATED_SIMULATOR_UDID = "9236EB07-8DA6-496E-A145-740BCFF78468"
DEBUG_APP_BUNDLE_ID = "com.merpyzf.xmnote"
DATABASE_ENVIRONMENT_VARIABLE = "XMNOTE_BOOK_ALIGNMENT_DATABASE_PATH"
SCENE_ARGUMENT = "-XMNoteBookAlignmentScene"
SCENE_VALUE = "bookshelf.default"
REPLAY_CASE_ARGUMENT = "-XMNoteBookAlignmentReplayCase"
REPLAY_MODE_ARGUMENT = "-XMNoteBookAlignmentReplayMode"
REPLAY_MODES = ("prepare", "operation", "verify")
CASE_ROOT_RELATIVE = pathlib.Path(
    "Library/Application Support/BookAlignment/Cases"
)
DATABASE_FILE_NAME = "xm_note.db"
STAGES = tuple(f"S{index}" for index in range(8))
NOT_RUNNING_MARKERS = (
    b"found nothing to terminate",
    b"no such process",
    b"not running",
)
REPLAY_CASE_ID = "a-09-soft-vs-hard-delete"
REPLAY_CONTRACT = pathlib.Path(__file__).resolve().parent / "cases/a-09-soft-vs-hard-delete.case.json"
REPLAY_TARGET_BOOK_ID = 9_090_001
REPLAY_TARGET_GROUP_ID = 9_090_101
REPLAY_TARGET_TAG_ID = 9_090_201
REPLAY_TARGET_COLLECTION_ID = 9_090_301
REPLAY_MARKERS = {
    "prepare": "replay-prepare.json",
    "operation": "replay-operation.json",
    "verify": "replay-verify.json",
}
IOS_PLATFORM_INTERNAL_TABLES = {"grdb_migrations"}
IOS_TARGET_USER_VERSION = 48
IOS_TARGET_ROOM_IDENTITY_HASH = "cda5a591da1f57aca266af36255e5df7"


@dataclass(frozen=True)
class DebugAppContext:
    """Validated paths for the installed DEBUG app on the dedicated Simulator."""

    app_bundle: pathlib.Path
    data_container: pathlib.Path


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Seed, launch, terminate, or capture the isolated iOS book-alignment "
            "database on the one dedicated Simulator."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    seed = subparsers.add_parser(
        "seed",
        help="clone B0 on the host, then copy it into a new app-container case",
    )
    _add_simulator(seed)
    seed.add_argument("--case-id", required=True)
    seed.add_argument("--baseline", type=pathlib.Path)
    seed.add_argument("--host-output", type=pathlib.Path)
    seed.add_argument("--report", type=pathlib.Path)
    seed.add_argument("--expected-baseline-sha256")
    seed.add_argument("--expected-schema-fingerprint")
    seed.add_argument(
        "--expected-user-version", type=int, default=DEFAULT_USER_VERSION
    )
    seed.add_argument(
        "--expected-room-identity-hash", default=DEFAULT_ROOM_IDENTITY_HASH
    )
    seed.add_argument("--require-no-foreign-key-violations", action="store_true")
    seed.add_argument("--skip-missing-private-baseline", action="store_true")

    launch = subparsers.add_parser(
        "launch", help="launch the DEBUG app directly into the default bookshelf"
    )
    _add_simulator(launch)
    launch.add_argument("--case-id", required=True)

    terminate = subparsers.add_parser(
        "terminate", help="terminate the DEBUG app before offline inspection"
    )
    _add_simulator(terminate)

    capture = subparsers.add_parser(
        "capture",
        help="terminate the app and capture one immutable S0-S7 snapshot",
    )
    _add_simulator(capture)
    capture.add_argument("--case-id", required=True)
    capture.add_argument("--stage", choices=STAGES, required=True)
    capture.add_argument("--output", type=pathlib.Path, required=True)
    capture.add_argument("--manifest", type=pathlib.Path)
    capture.add_argument("--baseline-sha256")
    capture.add_argument("--expected-schema-fingerprint")
    capture.add_argument(
        "--expected-user-version", type=int, default=IOS_TARGET_USER_VERSION
    )
    capture.add_argument(
        "--expected-room-identity-hash", default=IOS_TARGET_ROOM_IDENTITY_HASH
    )
    capture.add_argument("--require-no-foreign-key-violations", action="store_true")

    replay = subparsers.add_parser(
        "replay-a09",
        help=(
            "import a validated Android S2 as the iOS operation start, run the "
            "allowlisted hard-delete Repository command, and capture S2-S4"
        ),
    )
    _add_simulator(replay)
    replay.add_argument("--case-id", default=REPLAY_CASE_ID)
    replay.add_argument("--baseline", type=pathlib.Path)
    replay.add_argument("--runtime-profile", type=pathlib.Path)
    replay.add_argument("--android-s2", type=pathlib.Path, required=True)
    replay.add_argument("--android-s2-manifest", type=pathlib.Path)
    replay.add_argument("--output-dir", type=pathlib.Path, required=True)
    replay.add_argument("--expected-baseline-sha256")
    replay.add_argument("--expected-schema-fingerprint")
    replay.add_argument(
        "--expected-user-version", type=int, default=DEFAULT_USER_VERSION
    )
    replay.add_argument(
        "--expected-room-identity-hash", default=DEFAULT_ROOM_IDENTITY_HASH
    )
    replay.add_argument("--skip-missing-private-baseline", action="store_true")
    replay.add_argument(
        "--marker-timeout-seconds", type=float, default=30.0
    )
    return parser.parse_args(argv)


def _add_simulator(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--udid",
        default=DEDICATED_SIMULATOR_UDID,
        help="must equal the repository-assigned dedicated Simulator UDID",
    )


def _validated_udid(value: str) -> str:
    if value != DEDICATED_SIMULATOR_UDID:
        raise AlignmentError(
            "Only the dedicated book-alignment Simulator UDID is allowed; "
            "selectors such as 'booted' and other devices are rejected"
        )
    return value


def _simctl_get_container_command(udid: str, kind: str) -> list[str]:
    if kind not in {"app", "data"}:
        raise AlignmentError("Unsupported Simulator container kind")
    return [
        "xcrun",
        "simctl",
        "get_app_container",
        _validated_udid(udid),
        DEBUG_APP_BUNDLE_ID,
        kind,
    ]


def _simctl_terminate_command(udid: str) -> list[str]:
    return [
        "xcrun",
        "simctl",
        "terminate",
        _validated_udid(udid),
        DEBUG_APP_BUNDLE_ID,
    ]


def _simctl_launch_command(
    udid: str,
    *,
    replay_case_id: str | None = None,
    replay_mode: str | None = None,
) -> list[str]:
    if (replay_case_id is None) != (replay_mode is None):
        raise AlignmentError("Replay case and mode must be provided together")
    if replay_case_id is not None and replay_case_id != REPLAY_CASE_ID:
        raise AlignmentError("The iOS replay case is not allowlisted")
    if replay_mode is not None and replay_mode not in REPLAY_MODES:
        raise AlignmentError("The iOS replay mode is not allowlisted")
    command = [
        "xcrun",
        "simctl",
        "launch",
        "--terminate-running-process",
        _validated_udid(udid),
        DEBUG_APP_BUNDLE_ID,
        SCENE_ARGUMENT,
        SCENE_VALUE,
    ]
    if replay_case_id is not None and replay_mode is not None:
        command.extend(
            [REPLAY_CASE_ARGUMENT, replay_case_id, REPLAY_MODE_ARGUMENT, replay_mode]
        )
    return command


def _launch_environment(
    database: pathlib.Path, base: Mapping[str, str] | None = None
) -> dict[str, str]:
    environment = dict(os.environ if base is None else base)
    for key in tuple(environment):
        if key.startswith("SIMCTL_CHILD_"):
            del environment[key]
    environment[f"SIMCTL_CHILD_{DATABASE_ENVIRONMENT_VARIABLE}"] = str(database)
    return environment


def _run(
    command: Sequence[str], *, environment: Mapping[str, str] | None = None
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        list(command),
        env=None if environment is None else dict(environment),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def _require_host_tools() -> None:
    if shutil.which("xcrun") is None:
        raise AlignmentError("xcrun is not available on PATH")


def _decode_single_path(result: subprocess.CompletedProcess[bytes]) -> pathlib.Path:
    if result.returncode != 0:
        raise AlignmentError("The required DEBUG app is not installed")
    try:
        text = result.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError as error:
        raise AlignmentError("Simulator returned an invalid container path") from error
    if not text or "\n" in text or "\x00" in text:
        raise AlignmentError("Simulator returned an invalid container path")
    return pathlib.Path(text)


def _simulator_device_root(
    udid: str, *, home: pathlib.Path | None = None
) -> pathlib.Path:
    root = (home or pathlib.Path.home()) / "Library/Developer/CoreSimulator/Devices"
    return (root / _validated_udid(udid) / "data").resolve(strict=False)


def _validated_container_path(
    path: pathlib.Path,
    *,
    udid: str,
    kind: str,
    home: pathlib.Path | None = None,
) -> pathlib.Path:
    if kind == "app":
        relative_root = pathlib.Path("Containers/Bundle/Application")
    elif kind == "data":
        relative_root = pathlib.Path("Containers/Data/Application")
    else:
        raise AlignmentError("Unsupported Simulator container kind")
    resolved = path.expanduser().resolve(strict=False)
    expected_root = (_simulator_device_root(udid, home=home) / relative_root).resolve(
        strict=False
    )
    if not resolved.is_relative_to(expected_root):
        raise AlignmentError(
            "Simulator returned a container outside the dedicated device root"
        )
    if not resolved.exists() or not resolved.is_dir():
        raise AlignmentError("Simulator container is unavailable")
    return resolved


def _verify_debug_app(app_bundle: pathlib.Path) -> None:
    info_path = app_bundle / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise AlignmentError("Unable to inspect the installed app bundle") from error
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable:
        raise AlignmentError("Installed app has an invalid executable contract")
    if info.get("CFBundleIdentifier") != DEBUG_APP_BUNDLE_ID or info.get(
        "DTPlatformName"
    ) != "iphonesimulator":
        raise AlignmentError("Installed app is not the expected Simulator build")

    # Modern Simulator builds are ad-hoc signed and may expose an empty entitlement
    # dictionary even in Debug. Xcode's debug dylib plus this project's #if DEBUG-only
    # launch tokens prove the installed binary can honor the isolated path and route.
    debug_dylib = app_bundle / f"{executable}.debug.dylib"
    required_debug_tokens = (
        DATABASE_ENVIRONMENT_VARIABLE.encode("utf-8"),
        SCENE_ARGUMENT.encode("utf-8"),
        SCENE_VALUE.encode("utf-8"),
        REPLAY_CASE_ARGUMENT.encode("utf-8"),
        REPLAY_MODE_ARGUMENT.encode("utf-8"),
        REPLAY_CASE_ID.encode("utf-8"),
    )
    if not _file_contains_all_tokens(debug_dylib, required_debug_tokens):
        raise AlignmentError(
            "Installed DEBUG app cannot honor the isolated database launch contract"
        )


def _file_contains_all_tokens(
    path: pathlib.Path, tokens: Sequence[bytes]
) -> bool:
    if not tokens or any(not token for token in tokens):
        raise AlignmentError("DEBUG launch token contract is invalid")
    remaining = set(tokens)
    overlap_size = max(map(len, remaining)) - 1
    carry = b""
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                window = carry + chunk
                remaining = {token for token in remaining if token not in window}
                if not remaining:
                    return True
                carry = window[-overlap_size:] if overlap_size else b""
    except OSError as error:
        raise AlignmentError("Installed app is not an Xcode DEBUG build") from error
    return False


def _debug_app_context(udid: str) -> DebugAppContext:
    _require_host_tools()
    app_result = _run(_simctl_get_container_command(udid, "app"))
    app_bundle = _validated_container_path(
        _decode_single_path(app_result), udid=udid, kind="app"
    )
    _verify_debug_app(app_bundle)
    data_result = _run(_simctl_get_container_command(udid, "data"))
    data_container = _validated_container_path(
        _decode_single_path(data_result), udid=udid, kind="data"
    )
    return DebugAppContext(app_bundle=app_bundle, data_container=data_container)


def _case_database(context: DebugAppContext, case_id: str) -> pathlib.Path:
    safe_case_id = ensure_safe_name(case_id, "case-id")
    database = (
        context.data_container
        / CASE_ROOT_RELATIVE
        / safe_case_id
        / DATABASE_FILE_NAME
    ).resolve(strict=False)
    if not database.is_relative_to(context.data_container):
        raise AlignmentError("Case database escaped the DEBUG app data container")
    return database


def _default_host_output(case_id: str) -> pathlib.Path:
    repository_root = pathlib.Path(__file__).resolve().parents[2]
    return (
        repository_root
        / "artifacts/book-alignment/ios-live"
        / ensure_safe_name(case_id, "case-id")
        / DATABASE_FILE_NAME
    )


def _validate_host_artifact_path(
    path: pathlib.Path, *, context: DebugAppContext
) -> pathlib.Path:
    resolved = path.expanduser().resolve(strict=False)
    simulator_devices = (
        pathlib.Path.home() / "Library/Developer/CoreSimulator/Devices"
    ).resolve(strict=False)
    if resolved.is_relative_to(context.data_container) or resolved.is_relative_to(
        simulator_devices
    ):
        raise AlignmentError("Host artifacts must remain outside Simulator containers")
    return resolved


def _terminate_app(udid: str) -> None:
    result = _run(_simctl_terminate_command(udid))
    if result.returncode == 0:
        return
    diagnostic = (result.stdout + b"\n" + result.stderr).lower()
    if any(marker in diagnostic for marker in NOT_RUNNING_MARKERS):
        return
    raise AlignmentError("Unable to establish that the DEBUG app is terminated")


def _baseline_or_skip(args: argparse.Namespace) -> pathlib.Path | None:
    baseline = (args.baseline or resolve_default_baseline()).expanduser()
    if baseline.is_file():
        return baseline
    if args.skip_missing_private_baseline:
        print("SKIP: missing private baseline")
        return None
    raise AlignmentError("Private baseline does not exist")


def seed_case(args: argparse.Namespace) -> int:
    baseline = _baseline_or_skip(args)
    if baseline is None:
        return 77
    udid = _validated_udid(args.udid)
    case_id = ensure_safe_name(args.case_id, "case-id")
    context = _debug_app_context(udid)
    _terminate_app(udid)

    target = _case_database(context, case_id)
    if target.parent.exists():
        raise AlignmentError("Refusing to replace an existing Simulator case directory")

    host_output = _validate_host_artifact_path(
        args.host_output or _default_host_output(case_id),
        context=context,
    )
    seed_report = pathlib.Path(f"{host_output}.seed.json")
    fixture_report = _validate_host_artifact_path(
        args.report or pathlib.Path(f"{host_output}.ios-fixture.json"),
        context=context,
    )
    if fixture_report.exists():
        raise AlignmentError("Refusing to overwrite an existing fixture report")

    result = snapshot.seed_live_database(
        argparse.Namespace(
            baseline=baseline,
            output=host_output,
            report=seed_report,
            case_id=case_id,
            platform="ios",
            expected_baseline_sha256=args.expected_baseline_sha256,
            expected_user_version=args.expected_user_version,
            expected_room_identity_hash=args.expected_room_identity_hash,
            expected_schema_fingerprint=args.expected_schema_fingerprint,
            require_no_foreign_key_violations=args.require_no_foreign_key_violations,
            skip_missing_private_baseline=False,
        )
    )
    if result != 0:
        return result

    copy_file_exclusive(host_output, target, mode=0o600)
    baseline_sha256 = file_sha256(baseline)
    host_sha256 = file_sha256(host_output)
    target_sha256 = file_sha256(target)
    if not (baseline_sha256 == host_sha256 == target_sha256):
        raise AlignmentError("iOS live-copy SHA verification failed")

    write_json_exclusive(
        fixture_report,
        {
            "schemaVersion": 1,
            "tool": "book-alignment-ios-fixture",
            "command": "seed",
            "generatedAt": utc_now(),
            "dataPolicy": privacy_policy(),
            "caseId": case_id,
            "platform": "ios",
            "dedicatedSimulatorUdid": udid,
            "debugBundleIdentifier": DEBUG_APP_BUNDLE_ID,
            "relativeDatabasePath": str(
                CASE_ROOT_RELATIVE / case_id / DATABASE_FILE_NAME
            ),
            "baselineSha256": baseline_sha256,
            "hostCloneSha256": host_sha256,
            "containerCloneSha256": target_sha256,
            "byteIdentical": True,
            "result": "PASS",
            "passed": True,
        },
    )
    print(f"PASS iOS seed: case={case_id} byte-identical SHA-256={target_sha256}")
    return 0


def launch_case(args: argparse.Namespace) -> int:
    udid = _validated_udid(args.udid)
    case_id = ensure_safe_name(args.case_id, "case-id")
    context = _debug_app_context(udid)
    database = _case_database(context, case_id)
    if not database.is_file():
        raise AlignmentError("The requested Simulator case has not been seeded")
    result = _run(
        _simctl_launch_command(udid),
        environment=_launch_environment(database),
    )
    if result.returncode != 0:
        raise AlignmentError("Unable to launch the DEBUG app for this case")
    print(f"PASS iOS launch: case={case_id} scene={SCENE_VALUE}")
    return 0


def terminate_app(args: argparse.Namespace) -> int:
    udid = _validated_udid(args.udid)
    _debug_app_context(udid)
    _terminate_app(udid)
    print("PASS iOS terminate: DEBUG app is not running")
    return 0


def capture_case(args: argparse.Namespace) -> int:
    udid = _validated_udid(args.udid)
    case_id = ensure_safe_name(args.case_id, "case-id")
    context = _debug_app_context(udid)
    _terminate_app(udid)
    database = _case_database(context, case_id)
    if not database.is_file():
        raise AlignmentError("The requested Simulator case has not been seeded")

    output = _validate_host_artifact_path(
        args.output, context=context
    )
    manifest = (
        _validate_host_artifact_path(args.manifest, context=context)
        if args.manifest is not None
        else None
    )
    command = [
        "capture",
        "--db",
        str(database),
        "--output",
        str(output),
        "--case-id",
        case_id,
        "--platform",
        "ios",
        "--stage",
        args.stage,
        "--expected-user-version",
        str(args.expected_user_version),
    ]
    if manifest is not None:
        command.extend(["--manifest", str(manifest)])
    if args.baseline_sha256:
        command.extend(["--baseline-sha256", args.baseline_sha256])
    if args.expected_room_identity_hash:
        command.extend(
            ["--expected-room-identity-hash", args.expected_room_identity_hash]
        )
    if args.expected_schema_fingerprint:
        command.extend(
            ["--expected-schema-fingerprint", args.expected_schema_fingerprint]
        )
    if args.require_no_foreign_key_violations:
        command.append("--require-no-foreign-key-violations")
    return snapshot.main(command)


def _validate_replay_contract(case_id: str) -> dict[str, Any]:
    if case_id != REPLAY_CASE_ID:
        raise AlignmentError("Only the audited A-09 iOS replay is supported")
    contract = validate_case_payload(load_json(REPLAY_CONTRACT))
    if (
        contract["caseId"] != case_id
        or contract["status"] != "exact-current"
        or contract.get("targetDatabase", {}).get("userVersion")
        != IOS_TARGET_USER_VERSION
        or contract.get("targetDatabase", {}).get("roomIdentityHash")
        != IOS_TARGET_ROOM_IDENTITY_HASH
        or contract["lifecycle"]["requireRestart"] is not True
        or contract["lifecycle"]["requireS3S4BusinessStable"] is not True
    ):
        raise AlignmentError("A-09 contract does not authorize this replay lifecycle")
    return contract


def _validate_baseline_for_replay(
    baseline: pathlib.Path,
    *,
    expected_sha256: str | None,
    expected_user_version: int,
    expected_room_identity_hash: str,
    expected_schema_fingerprint: str | None,
) -> tuple[str, dict[str, Any], str]:
    baseline_sha256 = file_sha256(baseline)
    if expected_sha256 is not None and baseline_sha256 != validate_sha256(
        expected_sha256, "--expected-baseline-sha256"
    ):
        raise AlignmentError("B0 SHA-256 does not match the replay request")
    metadata = inspect_database(baseline)
    schema_sha256 = metadata["schemaFingerprint"]["sha256"]
    expected_schema = (
        validate_sha256(
            expected_schema_fingerprint, "--expected-schema-fingerprint"
        )
        if expected_schema_fingerprint is not None
        else schema_sha256
    )
    if (
        metadata["integrityCheck"]["status"] != "ok"
        or metadata["quickCheck"]["status"] != "ok"
        or metadata["userVersion"] != expected_user_version
        or metadata["roomIdentityHash"] != expected_room_identity_hash
        or schema_sha256 != expected_schema
    ):
        raise AlignmentError("B0 does not satisfy the iOS replay database contract")
    return baseline_sha256, metadata, expected_schema


def _validate_replay_runtime_profile(
    path: pathlib.Path,
) -> str:
    validate_runtime_profile_payload(load_json(path))
    return file_sha256(path)


def _added_foreign_key_digests(
    baseline_metadata: dict[str, Any], after_metadata: dict[str, Any]
) -> list[str]:
    baseline = Counter(
        baseline_metadata["foreignKeyCheck"]["violationDigests"]
    )
    after = Counter(after_metadata["foreignKeyCheck"]["violationDigests"])
    return sorted((after - baseline).elements())


def _validate_android_s2_lineage(
    database: pathlib.Path,
    manifest_path: pathlib.Path,
    *,
    case_id: str,
    baseline_sha256: str,
    baseline_metadata: dict[str, Any],
) -> dict[str, Any]:
    manifest = load_json(manifest_path)
    if not isinstance(manifest, dict):
        raise AlignmentError("Android S2 manifest must be an object")
    if (
        manifest.get("schemaVersion") != 1
        or manifest.get("caseId") != case_id
        or manifest.get("platform") != "android"
        or manifest.get("stage") != "S2"
        or manifest.get("baselineSha256") != baseline_sha256
        or manifest.get("result") != "PASS"
        or manifest.get("passed") is not True
        or manifest.get("failures") != []
    ):
        raise AlignmentError("Android S2 manifest lineage is not valid for A-09")
    snapshot_payload = manifest.get("snapshot")
    if not isinstance(snapshot_payload, dict):
        raise AlignmentError("Android S2 manifest is missing its snapshot proof")
    database_sha256 = file_sha256(database)
    if snapshot_payload.get("sha256") != database_sha256:
        raise AlignmentError("Android S2 bytes do not match their manifest")
    metadata = inspect_database(database)
    recorded_metadata = snapshot_payload.get("database")
    if not isinstance(recorded_metadata, dict):
        raise AlignmentError("Android S2 manifest is missing database metadata")
    if (
        metadata["integrityCheck"]["status"] != "ok"
        or metadata["quickCheck"]["status"] != "ok"
        or metadata["userVersion"] != IOS_TARGET_USER_VERSION
        or metadata["roomIdentityHash"] != IOS_TARGET_ROOM_IDENTITY_HASH
        or recorded_metadata.get("userVersion") != metadata["userVersion"]
        or recorded_metadata.get("roomIdentityHash") != metadata["roomIdentityHash"]
        or recorded_metadata.get("schemaFingerprint", {}).get("sha256")
        != metadata["schemaFingerprint"]["sha256"]
        or recorded_metadata.get("foreignKeyCheck", {}).get("setDigest")
        != metadata["foreignKeyCheck"]["setDigest"]
    ):
        raise AlignmentError("Android S2 database contract is not the expected migrated v48 schema")
    if _added_foreign_key_digests(baseline_metadata, metadata):
        raise AlignmentError("Android S2 introduced foreign-key violations")
    projection = _a09_projection(database)
    if projection != {"targetPhysicalRows": 4, "fixtureParentRows": 3}:
        raise AlignmentError("Android S2 is not the deterministic A-09 operation start")
    return {
        "sha256": database_sha256,
        "schemaSha256": metadata["schemaFingerprint"]["sha256"],
        "businessDigest": _business_database_digest(database),
        "projection": projection,
    }


def _a09_projection(database: pathlib.Path) -> dict[str, int]:
    connection = immutable_connection(database)
    try:
        row = connection.execute(
            """
            SELECT
                (SELECT COUNT(*) FROM book WHERE id = ?) +
                (SELECT COUNT(*) FROM group_book WHERE book_id = ?) +
                (SELECT COUNT(*) FROM tag_book WHERE book_id = ?) +
                (SELECT COUNT(*) FROM collection_book WHERE book_id = ?),
                (SELECT COUNT(*) FROM `group` WHERE id = ?) +
                (SELECT COUNT(*) FROM tag WHERE id = ?) +
                (SELECT COUNT(*) FROM collection WHERE id = ?)
            """,
            (
                REPLAY_TARGET_BOOK_ID,
                REPLAY_TARGET_BOOK_ID,
                REPLAY_TARGET_BOOK_ID,
                REPLAY_TARGET_BOOK_ID,
                REPLAY_TARGET_GROUP_ID,
                REPLAY_TARGET_TAG_ID,
                REPLAY_TARGET_COLLECTION_ID,
            ),
        ).fetchone()
    finally:
        connection.close()
    if row is None:
        raise AlignmentError("Unable to read the A-09 semantic projection")
    return {
        "targetPhysicalRows": int(row[0]),
        "fixtureParentRows": int(row[1]),
    }


def _business_database_digest(database: pathlib.Path) -> str:
    connection = immutable_connection(database)
    try:
        table_names = [
            str(row[0])
            for row in connection.execute(
                """
                SELECT name
                FROM sqlite_schema
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
            )
            if str(row[0]) not in IOS_PLATFORM_INTERNAL_TABLES
        ]
        tables: list[dict[str, Any]] = []
        for table in table_names:
            columns = [
                str(row[1])
                for row in connection.execute(
                    f"PRAGMA table_info({quoted(table)})"
                )
            ]
            selected_columns = ", ".join(quoted(column) for column in columns)
            row_digests = sorted(
                json_digest(list(row))
                for row in connection.execute(
                    f"SELECT {selected_columns} FROM {quoted(table)}"
                )
            )
            tables.append(
                {
                    "table": table,
                    "columns": columns,
                    "rowCount": len(row_digests),
                    "rowDigests": row_digests,
                }
            )
        return json_digest(tables)
    finally:
        connection.close()


def _capture_replay_stage(
    source_database: pathlib.Path,
    output_root: pathlib.Path,
    *,
    case_id: str,
    stage: str,
    baseline_sha256: str,
    expected_user_version: int,
    expected_room_identity_hash: str,
    expected_schema_fingerprint: str | None,
) -> pathlib.Path:
    output = output_root / f"{stage}.db"
    manifest = output_root / f"{stage}.db.manifest.json"
    result = snapshot.capture_snapshot(
        argparse.Namespace(
            db=source_database,
            wal=None,
            shm=None,
            output=output,
            manifest=manifest,
            case_id=case_id,
            platform="ios",
            stage=stage,
            baseline_sha256=baseline_sha256,
            expected_user_version=expected_user_version,
            expected_room_identity_hash=expected_room_identity_hash,
            expected_schema_fingerprint=expected_schema_fingerprint,
            require_no_foreign_key_violations=False,
        )
    )
    if result != 0:
        raise AlignmentError(f"iOS {stage} snapshot failed its base contract")
    return output


def _validate_ios_replay_stage(
    database: pathlib.Path,
    *,
    baseline_metadata: dict[str, Any],
    expected_schema_fingerprint: str,
    expected_target_rows: int,
) -> dict[str, Any]:
    metadata = inspect_database(database)
    connection = immutable_connection(database)
    try:
        business_schema = schema_fingerprint(
            connection, IOS_PLATFORM_INTERNAL_TABLES
        )
        foreign_keys = foreign_key_summary(connection)
    finally:
        connection.close()
    if (
        metadata["integrityCheck"]["status"] != "ok"
        or metadata["quickCheck"]["status"] != "ok"
        or metadata["userVersion"] != IOS_TARGET_USER_VERSION
        or metadata["roomIdentityHash"] != IOS_TARGET_ROOM_IDENTITY_HASH
        or business_schema["sha256"] != expected_schema_fingerprint
        or foreign_keys["setDigest"] != metadata["foreignKeyCheck"]["setDigest"]
    ):
        raise AlignmentError("iOS replay stage changed the migrated v48 business schema contract")
    if _added_foreign_key_digests(baseline_metadata, metadata):
        raise AlignmentError("iOS replay stage introduced foreign-key violations")
    projection = _a09_projection(database)
    if projection != {
        "targetPhysicalRows": expected_target_rows,
        "fixtureParentRows": 3,
    }:
        raise AlignmentError("iOS replay stage does not satisfy A-09 hard-delete semantics")
    return {
        "sha256": file_sha256(database),
        "businessSchemaSha256": business_schema["sha256"],
        "businessDigest": _business_database_digest(database),
        "foreignKeyViolationCount": foreign_keys["violationCount"],
        "foreignKeyViolationSha256": foreign_keys["setDigest"],
        "projection": projection,
    }


def _replay_marker(database: pathlib.Path, mode: str) -> pathlib.Path:
    if mode not in REPLAY_MARKERS:
        raise AlignmentError("Unsupported iOS replay marker mode")
    return database.parent / REPLAY_MARKERS[mode]


def _wait_for_replay_marker(
    marker: pathlib.Path,
    *,
    case_id: str,
    mode: str,
    timeout_seconds: float,
) -> dict[str, Any]:
    if not 0.25 <= timeout_seconds <= 60:
        raise AlignmentError("Replay marker timeout must be between 0.25 and 60 seconds")
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if marker.is_file():
            payload = load_json(marker)
            if (
                not isinstance(payload, dict)
                or set(payload) != {"schemaVersion", "caseId", "mode", "result"}
                or payload.get("schemaVersion") != 1
                or payload.get("caseId") != case_id
                or payload.get("mode") != mode
            ):
                raise AlignmentError("iOS replay marker has an invalid contract")
            if payload.get("result") != "PASS":
                raise AlignmentError("iOS replay app reported a failed Repository command")
            return payload
        time.sleep(0.2)
    raise AlignmentError("Timed out waiting for the iOS replay marker")


def _execute_replay_launch(
    udid: str,
    database: pathlib.Path,
    *,
    case_id: str,
    mode: str,
    timeout_seconds: float,
) -> dict[str, Any]:
    marker = _replay_marker(database, mode)
    if marker.exists():
        raise AlignmentError("Refusing to reuse an existing iOS replay marker")
    started_at = utc_now()
    launch = _run(
        _simctl_launch_command(
            udid,
            replay_case_id=case_id,
            replay_mode=mode,
        ),
        environment=_launch_environment(database),
    )
    output_digest = hashlib.sha256(launch.stdout + b"\n" + launch.stderr).hexdigest()
    if launch.returncode != 0:
        raise AlignmentError("Unable to launch the DEBUG app replay adapter")
    marker_payload = _wait_for_replay_marker(
        marker,
        case_id=case_id,
        mode=mode,
        timeout_seconds=timeout_seconds,
    )
    return {
        "mode": mode,
        "startedAt": started_at,
        "finishedAt": utc_now(),
        "launchOutputSha256": output_digest,
        "markerSha256": file_sha256(marker),
        "result": marker_payload["result"],
        "passed": True,
    }


def replay_a09(args: argparse.Namespace) -> int:
    case_id = ensure_safe_name(args.case_id, "case-id")
    contract = _validate_replay_contract(case_id)
    baseline = (args.baseline or resolve_default_baseline()).expanduser()
    if not baseline.is_file():
        if args.skip_missing_private_baseline:
            print("SKIP: missing private baseline")
            return 77
        raise AlignmentError("Private baseline does not exist")
    android_s2 = args.android_s2.expanduser()
    if not android_s2.is_file():
        raise AlignmentError("Android S2 database does not exist")
    android_manifest = (
        args.android_s2_manifest.expanduser()
        if args.android_s2_manifest is not None
        else pathlib.Path(f"{android_s2}.manifest.json")
    )
    if not android_manifest.is_file():
        raise AlignmentError("Android S2 manifest does not exist")
    output_dir = args.output_dir.expanduser()
    if output_dir.exists():
        raise AlignmentError("Refusing to replace an existing iOS replay output")

    baseline_sha256, baseline_metadata, baseline_schema = _validate_baseline_for_replay(
        baseline,
        expected_sha256=args.expected_baseline_sha256,
        expected_user_version=args.expected_user_version,
        expected_room_identity_hash=args.expected_room_identity_hash,
        expected_schema_fingerprint=args.expected_schema_fingerprint,
    )
    runtime_profile = (
        args.runtime_profile.expanduser()
        if args.runtime_profile is not None
        else baseline.parent / "runtime-profile.json"
    )
    if not runtime_profile.is_file():
        raise AlignmentError("A validated runtime profile is required for replay comparison")
    runtime_profile_sha256 = _validate_replay_runtime_profile(runtime_profile)
    android_s2_evidence = _validate_android_s2_lineage(
        android_s2,
        android_manifest,
        case_id=case_id,
        baseline_sha256=baseline_sha256,
        baseline_metadata=baseline_metadata,
    )
    target_schema = android_s2_evidence["schemaSha256"]

    udid = _validated_udid(args.udid)
    context = _debug_app_context(udid)
    _terminate_app(udid)
    android_s2 = _validate_host_artifact_path(android_s2, context=context)
    android_manifest = _validate_host_artifact_path(
        android_manifest, context=context
    )
    output_dir = _validate_host_artifact_path(output_dir, context=context)
    live_database = _case_database(context, case_id)
    if live_database.parent.exists():
        raise AlignmentError("Refusing to replace an existing Simulator replay case")
    ensure_private_directory(live_database.parent)
    copy_file_exclusive(android_s2, live_database, mode=0o600)
    if file_sha256(live_database) != android_s2_evidence["sha256"]:
        raise AlignmentError("iOS live S2 is not byte-identical to Android S2")

    ensure_private_directory(output_dir.parent)
    with tempfile.TemporaryDirectory(
        prefix=f".{output_dir.name}.ios-replay-", dir=output_dir.parent
    ) as temporary_directory:
        root = pathlib.Path(temporary_directory)
        try:
            prepare_evidence = _execute_replay_launch(
                udid,
                live_database,
                case_id=case_id,
                mode="prepare",
                timeout_seconds=args.marker_timeout_seconds,
            )
        finally:
            _terminate_app(udid)
        s2 = _capture_replay_stage(
            live_database,
            root,
            case_id=case_id,
            stage="S2",
            baseline_sha256=baseline_sha256,
            expected_user_version=IOS_TARGET_USER_VERSION,
            expected_room_identity_hash=IOS_TARGET_ROOM_IDENTITY_HASH,
            expected_schema_fingerprint=None,
        )
        s2_evidence = _validate_ios_replay_stage(
            s2,
            baseline_metadata=baseline_metadata,
            expected_schema_fingerprint=target_schema,
            expected_target_rows=4,
        )

        try:
            operation_evidence = _execute_replay_launch(
                udid,
                live_database,
                case_id=case_id,
                mode="operation",
                timeout_seconds=args.marker_timeout_seconds,
            )
        finally:
            _terminate_app(udid)
        s3 = _capture_replay_stage(
            live_database,
            root,
            case_id=case_id,
            stage="S3",
            baseline_sha256=baseline_sha256,
            expected_user_version=IOS_TARGET_USER_VERSION,
            expected_room_identity_hash=IOS_TARGET_ROOM_IDENTITY_HASH,
            expected_schema_fingerprint=None,
        )
        s3_evidence = _validate_ios_replay_stage(
            s3,
            baseline_metadata=baseline_metadata,
            expected_schema_fingerprint=target_schema,
            expected_target_rows=0,
        )

        try:
            verify_evidence = _execute_replay_launch(
                udid,
                live_database,
                case_id=case_id,
                mode="verify",
                timeout_seconds=args.marker_timeout_seconds,
            )
        finally:
            _terminate_app(udid)
        s4 = _capture_replay_stage(
            live_database,
            root,
            case_id=case_id,
            stage="S4",
            baseline_sha256=baseline_sha256,
            expected_user_version=IOS_TARGET_USER_VERSION,
            expected_room_identity_hash=IOS_TARGET_ROOM_IDENTITY_HASH,
            expected_schema_fingerprint=None,
        )
        s4_evidence = _validate_ios_replay_stage(
            s4,
            baseline_metadata=baseline_metadata,
            expected_schema_fingerprint=target_schema,
            expected_target_rows=0,
        )
        if s3_evidence["businessDigest"] != s4_evidence["businessDigest"]:
            raise AlignmentError("iOS A-09 business state changed after cold restart")
        if file_sha256(baseline) != baseline_sha256:
            raise AlignmentError("B0 changed while the iOS replay was running")

        bindings = {
            "schemaVersion": 1,
            "baselineSha256": baseline_sha256,
            "schemaFingerprint": baseline_schema,
            "runtimeProfileSha256": runtime_profile_sha256,
            "aliases": {
                "relatedBook": {
                    "entity": "book",
                    "id": REPLAY_TARGET_BOOK_ID,
                },
                "owningGroup": {
                    "entity": "group",
                    "id": REPLAY_TARGET_GROUP_ID,
                },
                "attachedTag": {
                    "entity": "tag",
                    "id": REPLAY_TARGET_TAG_ID,
                },
                "containingCollection": {
                    "entity": "collection",
                    "id": REPLAY_TARGET_COLLECTION_ID,
                },
            },
        }
        alias_entities = {
            item["name"]: item["entity"] for item in contract["aliases"]
        }
        validate_bindings_payload(bindings, alias_entities)
        write_json_exclusive(
            root / "bindings.json",
            bindings,
        )
        write_json_exclusive(
            root / "replay.manifest.json",
            {
                "schemaVersion": 1,
                "tool": "book-alignment-ios-replay",
                "generatedAt": utc_now(),
                "dataPolicy": privacy_policy(),
                "caseId": case_id,
                "platform": "ios",
                "adapterLayer": "repository-debug",
                "coveredTransitions": ["S2-to-S3", "S3-to-S4"],
                "uiCheckpointsCovered": False,
                "baselineSha256": baseline_sha256,
                "baselineSchemaSha256": baseline_schema,
                "targetSchemaSha256": target_schema,
                "runtimeProfileSha256": runtime_profile_sha256,
                "input": {
                    "stage": "S2",
                    "platform": "android",
                    "sha256": android_s2_evidence["sha256"],
                    "byteIdenticalAtIOSImport": True,
                    "baselineLineageValidated": True,
                },
                "stages": {
                    "S2": s2_evidence,
                    "S3": s3_evidence,
                    "S4": s4_evidence,
                },
                "launches": [
                    prepare_evidence,
                    operation_evidence,
                    verify_evidence,
                ],
                "safetyException": {
                    "androidSoftDeleteNotReplicated": True,
                    "iosPhysicalDeleteVerified": True,
                },
                "s3S4BusinessStable": True,
                "result": "PASS",
                "passed": True,
                "failures": [],
            },
        )
        if output_dir.exists():
            raise AlignmentError("iOS replay output appeared during execution")
        root.rename(output_dir)
    print(
        "PASS iOS A-09 replay: Android S2 lineage validated, hard delete committed, "
        f"and S3-S4 remained stable; output={output_dir}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "seed":
            return seed_case(args)
        if args.command == "launch":
            return launch_case(args)
        if args.command == "terminate":
            return terminate_app(args)
        if args.command == "replay-a09":
            return replay_a09(args)
        return capture_case(args)
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
