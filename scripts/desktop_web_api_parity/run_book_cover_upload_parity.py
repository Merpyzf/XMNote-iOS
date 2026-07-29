#!/usr/bin/env python3
"""Compare real Android/iOS book-cover uploads and remove both remote objects."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any

from run_upload_ticket_workflow_parity import (
    HTTPResult,
    contract_headers,
    decode_envelope,
    json_body,
    parse_headers,
    request,
    sha256,
)


OBJECT_NAME = re.compile(r"^web_cover_[0-9a-fA-F]{32}\.png$")
FIXTURE_PNG = (
    pathlib.Path(__file__).resolve().parents[2]
    / "Packages/XMNoteWeb/Sources/XMNoteWeb/Resources/DesktopWebSite/icons/xmnote-icon-192.png"
).read_bytes()
INSTRUMENTATION = (
    "com.merpyzf.xmnote.uitest.test/androidx.test.runner.AndroidJUnitRunner"
)
CLEANUP_TEST = (
    "com.merpyzf.xmnote.WebParityCOSCleanupTest"
    "#deleteUploadedBookCoverObjects"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare one real book-cover upload and delete both remote objects."
    )
    parser.add_argument("--android-base", required=True)
    parser.add_argument("--ios-base", required=True)
    parser.add_argument("--android-header", action="append", default=[])
    parser.add_argument("--ios-header", action="append", default=[])
    parser.add_argument("--android-serial", required=True)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def multipart_body(data: bytes) -> tuple[str, bytes]:
    boundary = f"xmnote-parity-{uuid.uuid4().hex}"
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="fixture.png"\r\n'
        "Content-Type: image/png\r\n\r\n"
    ).encode("utf-8")
    body += data
    body += f"\r\n--{boundary}--\r\n".encode("utf-8")
    return f"multipart/form-data; boundary={boundary}", body


def normalize_url(value: str) -> tuple[str, str]:
    parsed = urllib.parse.urlsplit(value)
    object_name = pathlib.PurePosixPath(parsed.path).name
    if parsed.scheme != "https" or not parsed.hostname:
        raise RuntimeError("uploaded URL must use HTTPS and include a host")
    if not OBJECT_NAME.fullmatch(object_name):
        raise RuntimeError(
            "uploaded URL object key does not match the frozen web_cover contract"
        )
    object_key = parsed.path.strip("/")
    normalized_path = str(
        pathlib.PurePosixPath(parsed.path).with_name("web_cover_<uuid>.png")
    )
    normalized = urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, normalized_path, parsed.query, parsed.fragment)
    )
    return normalized, object_key


def require_upload_data(result: HTTPResult) -> tuple[dict[str, Any], str, str]:
    envelope = decode_envelope(result)
    if result.status != 200 or envelope.get("code") != 200:
        raise RuntimeError(
            "upload failed: "
            f"status={result.status}, code={envelope.get('code')!r}, "
            f"message={envelope.get('msg')!r}, sha256={sha256(result.body)}"
        )
    data = envelope.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("url"), str):
        raise RuntimeError("upload response URL is missing")
    normalized_url, object_key = normalize_url(data["url"])
    normalized_envelope = {
        **envelope,
        "data": {**data, "url": normalized_url},
    }
    return normalized_envelope, data["url"], object_key


def try_extract_uploaded_object(result: HTTPResult | None) -> tuple[str, str] | None:
    if result is None:
        return None
    try:
        envelope = decode_envelope(result)
        data = envelope.get("data")
        url = data.get("url") if isinstance(data, dict) else None
        if not isinstance(url, str):
            return None
        _, object_key = normalize_url(url)
        return url, object_key
    except Exception:
        return None


def delete_remote_objects(
    adb: str,
    serial: str,
    android_object_key: str | None,
    ios_object_key: str | None,
    timeout: float,
) -> bool:
    command = [adb, "-s", serial, "shell", "am", "instrument", "-w"]
    if android_object_key:
        command.extend(["-e", "androidObjectKey", android_object_key])
    if ios_object_key:
        command.extend(["-e", "iosObjectKey", ios_object_key])
    command.extend(["-e", "class", CLEANUP_TEST, INSTRUMENTATION])
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    output = f"{result.stdout}\n{result.stderr}"
    return result.returncode == 0 and "OK (1 test)" in output


def remote_object_is_unavailable(url: str, timeout: float) -> tuple[bool, int]:
    last_status = 0
    for _ in range(10):
        separator = "&" if "?" in url else "?"
        probe_url = f"{url}{separator}xmnoteParityCleanup={uuid.uuid4().hex}"
        probe = urllib.request.Request(
            probe_url,
            method="HEAD",
            headers={"Cache-Control": "no-cache"},
        )
        try:
            with urllib.request.urlopen(probe, timeout=timeout) as response:
                last_status = response.status
        except urllib.error.HTTPError as error:
            last_status = error.code
        except Exception:
            last_status = 0
        if last_status in {403, 404}:
            return True, last_status
        time.sleep(1)
    return False, last_status


def execute(args: argparse.Namespace) -> dict[str, Any]:
    android_headers = parse_headers(args.android_header)
    ios_headers = parse_headers(args.ios_header)
    android_type, android_body = multipart_body(FIXTURE_PNG)
    ios_type, ios_body = multipart_body(FIXTURE_PNG)
    android_upload: HTTPResult | None = None
    ios_upload: HTTPResult | None = None
    cleanup_passed = False
    cleanup_probes: list[tuple[bool, int]] = []

    try:
        android_upload = request(
            args.android_base,
            "/api/v1/book-covers/upload",
            "POST",
            {**android_headers, "Content-Type": android_type},
            android_body,
            args.timeout,
        )
        ios_upload = request(
            args.ios_base,
            "/api/v1/book-covers/upload",
            "POST",
            {**ios_headers, "Content-Type": ios_type},
            ios_body,
            args.timeout,
        )
        android_envelope, _, _ = require_upload_data(android_upload)
        ios_envelope, _, _ = require_upload_data(ios_upload)
        differences: list[str] = []
        if android_upload.status != ios_upload.status:
            differences.append("httpStatus")
        if contract_headers(android_upload) != contract_headers(ios_upload):
            differences.append("headers")
        if android_envelope != ios_envelope:
            differences.append("json")
    finally:
        android_object = try_extract_uploaded_object(android_upload)
        ios_object = try_extract_uploaded_object(ios_upload)
        if android_object or ios_object:
            cleanup_passed = delete_remote_objects(
                args.adb,
                args.android_serial,
                android_object[1] if android_object else None,
                ios_object[1] if ios_object else None,
                args.timeout,
            )
            if cleanup_passed:
                for uploaded in (android_object, ios_object):
                    if uploaded:
                        cleanup_probes.append(
                            remote_object_is_unavailable(uploaded[0], args.timeout)
                        )

    upload_passed = not differences
    all_objects_unavailable = (
        len(cleanup_probes) == 2
        and all(unavailable for unavailable, _ in cleanup_probes)
    )
    cleanup_step_passed = cleanup_passed and all_objects_unavailable
    return {
        "schemaVersion": 1,
        "workflow": "book-cover-real-upload-and-cleanup",
        "fixture": {"imageSHA256": sha256(FIXTURE_PNG)},
        "normalizationPolicy": (
            "Uploaded URLs must share the exact HTTPS authority and "
            "web_cover_<32 hex>.png object-key shape; only the random 32-hex "
            "component is normalized."
        ),
        "dataPolicy": (
            "The report contains only the frozen public web-icon hash, response "
            "hashes and difference categories. URLs, object keys and credentials "
            "are never persisted. Both objects are deleted by an isolated Android "
            "instrumentation helper and probed with cache-busting HEAD requests."
        ),
        "passed": upload_passed and cleanup_step_passed,
        "summary": {
            "passed": int(upload_passed) + int(cleanup_step_passed),
            "total": 2,
        },
        "steps": [
            {
                "step": "upload",
                "passed": upload_passed,
                "differences": differences,
                "android": {
                    "status": android_upload.status,
                    "headers": contract_headers(android_upload),
                    "bodySHA256": sha256(android_upload.body),
                },
                "ios": {
                    "status": ios_upload.status,
                    "headers": contract_headers(ios_upload),
                    "bodySHA256": sha256(ios_upload.body),
                },
                "normalizedBodySHA256": {
                    "android": hashlib.sha256(json_body(android_envelope)).hexdigest(),
                    "ios": hashlib.sha256(json_body(ios_envelope)).hexdigest(),
                },
            },
            {
                "step": "cleanup-hygiene",
                "passed": cleanup_step_passed,
                "instrumentationPassed": cleanup_passed,
                "unavailableObjectCount": sum(
                    unavailable for unavailable, _ in cleanup_probes
                ),
                "objectCount": len(cleanup_probes),
                "probeStatuses": [status for _, status in cleanup_probes],
            },
        ],
    }


def main() -> int:
    args = parse_args()
    report = execute(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"book cover upload parity: {report['summary']['passed']}/"
        f"{report['summary']['total']} passed; report={args.output}"
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
