#!/usr/bin/env python3
"""Freeze the approved Android production SQLite triple without device-side copies."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, BinaryIO

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from book_alignment.common import (  # type: ignore[import-not-found]
        AlignmentError,
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        ensure_private_directory,
        privacy_policy,
        utc_now,
        write_json_exclusive,
    )
else:
    from .common import (
        AlignmentError,
        DEFAULT_ROOM_IDENTITY_HASH,
        DEFAULT_USER_VERSION,
        ensure_private_directory,
        privacy_policy,
        utc_now,
        write_json_exclusive,
    )


DEVICE_PATTERN = re.compile(r"^[A-Za-z0-9._:-]+$")
RELATIVE_PATH_PATTERN = re.compile(r"^[A-Za-z0-9._/-]+$")
SOURCE_PACKAGE_ALLOWLIST = frozenset({"com.merpyzf.xmnote"})


@dataclass(frozen=True)
class RemoteComponent:
    """One required app-private SQLite component selected by a safe relative path."""

    kind: str
    relative_path: str
    host_name: str


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Preflight the approved Android production source, force-stop it, stream "
            "db/wal/shm through adb exec-out run-as, then validate and publish B0 on "
            "the host. The .uitest package only consumes later copies."
        )
    )
    parser.add_argument("--device", required=True, help="exact adb device serial")
    parser.add_argument(
        "--package",
        default="com.merpyzf.xmnote",
        help="source package; only com.merpyzf.xmnote is accepted",
    )
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    parser.add_argument(
        "--database-relative-path",
        default="databases/xm_note.db",
        help="app-private path relative to run-as cwd (default: databases/xm_note.db)",
    )
    parser.add_argument(
        "--capture-only",
        action="store_true",
        help="publish the raw triple but do not invoke baseline.py",
    )
    parser.add_argument(
        "--expected-user-version", type=int, default=DEFAULT_USER_VERSION
    )
    parser.add_argument(
        "--expected-room-identity-hash", default=DEFAULT_ROOM_IDENTITY_HASH
    )
    parser.add_argument("--expected-schema-fingerprint")
    parser.add_argument("--expected-b0-sha256")
    parser.add_argument("--require-no-foreign-key-violations", action="store_true")
    return parser.parse_args(argv)


def _validate_inputs(args: argparse.Namespace) -> tuple[pathlib.Path, pathlib.Path]:
    if not DEVICE_PATTERN.fullmatch(args.device):
        raise AlignmentError("--device contains unsupported characters")
    if args.package not in SOURCE_PACKAGE_ALLOWLIST:
        raise AlignmentError(
            "--package is not the approved production baseline source"
        )
    relative = pathlib.PurePosixPath(args.database_relative_path)
    if (
        not RELATIVE_PATH_PATTERN.fullmatch(args.database_relative_path)
        or
        relative.is_absolute()
        or not relative.parts
        or any(part in ("", ".", "..") for part in relative.parts)
    ):
        raise AlignmentError("--database-relative-path must be a normalized relative path")
    output_dir = args.output_dir.expanduser()
    report = pathlib.Path(f"{output_dir}.capture.json")
    if output_dir.exists():
        raise AlignmentError(f"Refusing to replace existing output directory: {output_dir}")
    if report.exists():
        raise AlignmentError(f"Refusing to overwrite existing capture report: {report}")
    if shutil.which("adb") is None:
        raise AlignmentError("adb is not available on PATH")
    return output_dir, report


def _adb(args: argparse.Namespace, *command: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["adb", "-s", args.device, *command],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def _require_success(
    result: subprocess.CompletedProcess[bytes], failure_code: str
) -> bytes:
    if result.returncode != 0:
        raise AlignmentError(failure_code)
    return result.stdout


def _remote_size(args: argparse.Namespace, relative_path: str) -> int:
    result = _adb(
        args,
        "shell",
        "run-as",
        args.package,
        "stat",
        "-c",
        "%s",
        relative_path,
    )
    output = _require_success(result, "required-sqlite-component-unavailable").strip()
    try:
        size = int(output)
    except ValueError as error:
        raise AlignmentError("invalid-component-size-from-device") from error
    if size < 0:
        raise AlignmentError("invalid-component-size-from-device")
    return size


def _stream_component(
    args: argparse.Namespace,
    component: RemoteComponent,
    destination: pathlib.Path,
) -> dict[str, Any]:
    try:
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as error:
        raise AlignmentError("temporary-capture-collision") from error

    process = subprocess.Popen(
        [
            "adb",
            "-s",
            args.device,
            "exec-out",
            "run-as",
            args.package,
            "cat",
            component.relative_path,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.stdout is None or process.stderr is None:
        raise AlignmentError("unable-to-open-adb-stream")

    hasher = hashlib.sha256()
    byte_count = 0
    try:
        with os.fdopen(descriptor, "wb") as handle:
            while True:
                chunk = process.stdout.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
                hasher.update(chunk)
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
    if return_code != 0:
        try:
            destination.unlink(missing_ok=True)
        except OSError:
            pass
        raise AlignmentError("adb-component-stream-failed")
    return {"kind": component.kind, "byteCount": byte_count, "sha256": hasher.hexdigest()}


def _components(database_relative_path: str) -> list[RemoteComponent]:
    return [
        RemoteComponent("db", database_relative_path, "xm_note.db"),
        RemoteComponent("wal", f"{database_relative_path}-wal", "xm_note.db-wal"),
        RemoteComponent("shm", f"{database_relative_path}-shm", "xm_note.db-shm"),
    ]


def _base_report(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "tool": "book-alignment-android-capture",
        "generatedAt": utc_now(),
        "dataPolicy": privacy_policy(),
        "deviceDigest": hashlib.sha256(args.device.encode("utf-8")).hexdigest(),
        "sourcePackageHash": hashlib.sha256(args.package.encode("utf-8")).hexdigest(),
        "transport": "adb-exec-out-run-as",
        "deviceSideCopy": False,
    }


def _run_baseline(
    args: argparse.Namespace, output_dir: pathlib.Path
) -> subprocess.CompletedProcess[str]:
    script = pathlib.Path(__file__).with_name("baseline.py")
    command = [
        sys.executable,
        str(script),
        "create",
        "--db",
        str(output_dir / "xm_note.db"),
        "--wal",
        str(output_dir / "xm_note.db-wal"),
        "--shm",
        str(output_dir / "xm_note.db-shm"),
        "--output",
        str(output_dir / "B0.db"),
        "--expected-user-version",
        str(args.expected_user_version),
        "--expected-room-identity-hash",
        args.expected_room_identity_hash,
    ]
    if args.expected_schema_fingerprint:
        command.extend(
            ["--expected-schema-fingerprint", args.expected_schema_fingerprint]
        )
    if args.expected_b0_sha256:
        command.extend(["--expected-b0-sha256", args.expected_b0_sha256])
    if args.require_no_foreign_key_violations:
        command.append("--require-no-foreign-key-violations")
    return subprocess.run(command, text=True, capture_output=True, check=False)


def capture(args: argparse.Namespace) -> int:
    output_dir, report_path = _validate_inputs(args)
    components = _components(args.database_relative_path)
    base_report = _base_report(args)

    try:
        package_path = _adb(args, "shell", "pm", "path", args.package)
        package_output = _require_success(package_path, "source-package-not-installed")
        if not package_output.strip():
            raise AlignmentError("source-package-not-installed")

        preflight_sizes = {
            component.kind: _remote_size(args, component.relative_path)
            for component in components
        }
    except AlignmentError as error:
        report = {
            **base_report,
            "result": "FAIL",
            "passed": False,
            "forceStopIssued": False,
            "failureCode": str(error),
            "components": [],
        }
        write_json_exclusive(report_path, report)
        print(f"FAIL Android capture preflight: {error}; report={report_path}")
        return 1

    force_stop = _adb(args, "shell", "am", "force-stop", args.package)
    try:
        _require_success(force_stop, "force-stop-failed")
        pid = _adb(args, "shell", "pidof", args.package)
        if pid.returncode == 0 and pid.stdout.strip():
            raise AlignmentError("source-package-still-running-after-force-stop")
    except AlignmentError as error:
        report = {
            **base_report,
            "result": "FAIL",
            "passed": False,
            "forceStopIssued": True,
            "failureCode": str(error),
            "preflightSizes": preflight_sizes,
            "components": [],
        }
        write_json_exclusive(report_path, report)
        print(f"FAIL Android capture stop: {error}; report={report_path}")
        return 1

    ensure_private_directory(output_dir.parent)
    captured: list[dict[str, Any]] = []
    try:
        with tempfile.TemporaryDirectory(
            prefix=f".{output_dir.name}.stream-", dir=output_dir.parent
        ) as temporary_directory:
            temporary_root = pathlib.Path(temporary_directory)
            for component in components:
                summary = _stream_component(
                    args, component, temporary_root / component.host_name
                )
                expected_size = preflight_sizes[component.kind]
                if summary["byteCount"] != expected_size:
                    raise AlignmentError("component-size-changed-during-stream")
                captured.append(summary)

            postflight_sizes = {
                component.kind: _remote_size(args, component.relative_path)
                for component in components
            }
            if postflight_sizes != preflight_sizes:
                raise AlignmentError("component-size-changed-after-force-stop")
            if output_dir.exists():
                raise AlignmentError("output-directory-appeared-during-capture")
            pathlib.Path(temporary_directory).rename(output_dir)
    except AlignmentError as error:
        report = {
            **base_report,
            "result": "FAIL",
            "passed": False,
            "forceStopIssued": True,
            "failureCode": str(error),
            "preflightSizes": preflight_sizes,
            "components": captured,
            "promoted": False,
        }
        write_json_exclusive(report_path, report)
        print(f"FAIL Android capture stream: {error}; report={report_path}")
        return 1

    baseline_result: subprocess.CompletedProcess[str] | None = None
    if not args.capture_only:
        baseline_result = _run_baseline(args, output_dir)

    passed = baseline_result is None or baseline_result.returncode == 0
    report = {
        **base_report,
        "result": "PASS" if passed else "FAIL",
        "passed": passed,
        "forceStopIssued": True,
        "preflightSizes": preflight_sizes,
        "components": captured,
        "postflightSizes": preflight_sizes,
        "promoted": True,
        "baseline": {
            "invoked": baseline_result is not None,
            "passed": None if baseline_result is None else baseline_result.returncode == 0,
            "artifact": None if baseline_result is None else "B0.db",
        },
    }
    write_json_exclusive(report_path, report)
    if baseline_result is not None and baseline_result.stdout.strip():
        print(baseline_result.stdout.strip())
    if not passed:
        print(
            "FAIL Android capture: raw triple is private and complete, but B0 was not "
            f"published; report={report_path}"
        )
        return 1
    if args.capture_only:
        print(
            "PASS Android capture: raw triple promoted; run baseline.py create against "
            f"the three files in {output_dir}; report={report_path}"
        )
    else:
        print(f"PASS Android capture and B0 validation; report={report_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return capture(args)
    except AlignmentError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
