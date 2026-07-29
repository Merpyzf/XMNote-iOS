#!/usr/bin/env python3
"""Compare one real Android/iOS note-image upload and immediately release both objects."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import urllib.parse
from typing import Any

from run_upload_ticket_workflow_parity import (
    HTTPResult,
    contract_headers,
    decode_envelope,
    json_body,
    multipart_body,
    parse_headers,
    request,
    require_reserved_ticket,
    sha256,
)


OBJECT_NAME = re.compile(r"^web_note_[0-9a-fA-F]{32}\.png$")
FIXTURE_PNG = (
    pathlib.Path(__file__).resolve().parents[2]
    / "Packages/XMNoteWeb/Sources/XMNoteWeb/Resources/DesktopWebSite/icons/xmnote-icon-192.png"
).read_bytes()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare one real note-image COS upload and release workflow."
    )
    parser.add_argument("--android-base", required=True)
    parser.add_argument("--ios-base", required=True)
    parser.add_argument("--android-header", action="append", default=[])
    parser.add_argument("--ios-header", action="append", default=[])
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def normalize_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    object_name = pathlib.PurePosixPath(parsed.path).name
    if parsed.scheme != "https" or not parsed.hostname:
        raise RuntimeError("uploaded URL must use HTTPS and include a host")
    if not OBJECT_NAME.fullmatch(object_name):
        raise RuntimeError("uploaded URL object key does not match the frozen web_note contract")
    normalized_path = str(
        pathlib.PurePosixPath(parsed.path).with_name("web_note_<uuid>.png")
    )
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, normalized_path, parsed.query, parsed.fragment)
    )


def require_upload_data(result: HTTPResult, ticket_id: str) -> dict[str, Any]:
    envelope = decode_envelope(result)
    if result.status != 200 or envelope.get("code") != 200:
        raise RuntimeError(
            "upload failed: "
            f"status={result.status}, code={envelope.get('code')!r}, "
            f"message={envelope.get('msg')!r}, sha256={sha256(result.body)}"
        )
    data = envelope.get("data")
    if not isinstance(data, dict):
        raise RuntimeError("upload response data is not an object")
    if data.get("ticketId") != ticket_id:
        raise RuntimeError("upload response ticketId does not match the reservation")
    if not isinstance(data.get("expiresAt"), int) or data["expiresAt"] <= 0:
        raise RuntimeError("upload expiresAt is not a positive epoch millisecond")
    if not isinstance(data.get("url"), str):
        raise RuntimeError("upload response URL is missing")
    normalize_url(data["url"])
    return data


def normalized_envelope(
    result: HTTPResult,
    ticket_id: str,
    *,
    normalize_uploaded_url: bool,
) -> dict[str, Any]:
    envelope = decode_envelope(result)

    def visit(value: Any, key: str | None = None) -> Any:
        if isinstance(value, dict):
            return {name: visit(item, name) for name, item in value.items()}
        if isinstance(value, list):
            return [visit(item) for item in value]
        if key == "ticketId" and value == ticket_id:
            return "<ticket-id>"
        if key == "expiresAt":
            if not isinstance(value, int) or value <= 0:
                raise RuntimeError("expiresAt must be a positive epoch millisecond")
            return "<epoch-millis>"
        if key == "url" and normalize_uploaded_url:
            if not isinstance(value, str):
                raise RuntimeError("uploaded URL must be a string")
            return normalize_url(value)
        return value

    return visit(envelope)


def compare_step(
    name: str,
    android_result: HTTPResult,
    ios_result: HTTPResult,
    android_ticket_id: str,
    ios_ticket_id: str,
    *,
    normalize_uploaded_url: bool = False,
) -> dict[str, Any]:
    android_envelope = normalized_envelope(
        android_result,
        android_ticket_id,
        normalize_uploaded_url=normalize_uploaded_url,
    )
    ios_envelope = normalized_envelope(
        ios_result,
        ios_ticket_id,
        normalize_uploaded_url=normalize_uploaded_url,
    )
    differences: list[str] = []
    if android_result.status != ios_result.status:
        differences.append("httpStatus")
    if contract_headers(android_result) != contract_headers(ios_result):
        differences.append("headers")
    if android_envelope != ios_envelope:
        differences.append("json")
    return {
        "step": name,
        "passed": not differences,
        "differences": differences,
        "android": {
            "status": android_result.status,
            "headers": contract_headers(android_result),
            "bodySHA256": sha256(android_result.body),
        },
        "ios": {
            "status": ios_result.status,
            "headers": contract_headers(ios_result),
            "bodySHA256": sha256(ios_result.body),
        },
        "normalizedBodySHA256": {
            "android": hashlib.sha256(json_body(android_envelope)).hexdigest(),
            "ios": hashlib.sha256(json_body(ios_envelope)).hexdigest(),
        },
    }


def release(
    base: str,
    headers: dict[str, str],
    ticket_id: str,
    timeout: float,
) -> HTTPResult:
    return request(
        base,
        "/api/v1/note-images/upload-tickets/release",
        "POST",
        {**headers, "Content-Type": "application/json"},
        json_body({"ticketIds": [ticket_id]}),
        timeout,
    )


def execute(args: argparse.Namespace) -> dict[str, Any]:
    android_headers = parse_headers(args.android_header)
    ios_headers = parse_headers(args.ios_header)
    android_json_headers = {**android_headers, "Content-Type": "application/json"}
    ios_json_headers = {**ios_headers, "Content-Type": "application/json"}

    android_reserve = request(
        args.android_base,
        "/api/v1/note-images/upload-tickets",
        "POST",
        android_json_headers,
        json_body({"count": 1}),
        args.timeout,
    )
    ios_reserve = request(
        args.ios_base,
        "/api/v1/note-images/upload-tickets",
        "POST",
        ios_json_headers,
        json_body({"count": 1}),
        args.timeout,
    )
    android_ticket_id = require_reserved_ticket(android_reserve)
    ios_ticket_id = require_reserved_ticket(ios_reserve)
    steps = [
        compare_step(
            "reserve",
            android_reserve,
            ios_reserve,
            android_ticket_id,
            ios_ticket_id,
        )
    ]

    android_release: HTTPResult | None = None
    ios_release: HTTPResult | None = None
    try:
        android_type, android_body = multipart_body(android_ticket_id, FIXTURE_PNG)
        ios_type, ios_body = multipart_body(ios_ticket_id, FIXTURE_PNG)
        android_upload = request(
            args.android_base,
            "/api/v1/note-images/upload",
            "POST",
            {**android_headers, "Content-Type": android_type},
            android_body,
            args.timeout,
        )
        ios_upload = request(
            args.ios_base,
            "/api/v1/note-images/upload",
            "POST",
            {**ios_headers, "Content-Type": ios_type},
            ios_body,
            args.timeout,
        )
        require_upload_data(android_upload, android_ticket_id)
        require_upload_data(ios_upload, ios_ticket_id)
        steps.append(
            compare_step(
                "upload",
                android_upload,
                ios_upload,
                android_ticket_id,
                ios_ticket_id,
                normalize_uploaded_url=True,
            )
        )
    finally:
        android_release = release(
            args.android_base,
            android_headers,
            android_ticket_id,
            args.timeout,
        )
        ios_release = release(
            args.ios_base,
            ios_headers,
            ios_ticket_id,
            args.timeout,
        )

    steps.append(
        compare_step(
            "release-and-delete-remote-object",
            android_release,
            ios_release,
            android_ticket_id,
            ios_ticket_id,
        )
    )
    passed = all(step["passed"] for step in steps)
    return {
        "schemaVersion": 1,
        "workflow": "note-image-real-upload-and-release",
        "fixture": {
            "imageSHA256": sha256(FIXTURE_PNG),
        },
        "normalizationPolicy": (
            "Per-device ticket UUIDs and epoch milliseconds are normalized. Uploaded URLs "
            "must share the exact HTTPS authority and web_note_<32 hex>.png object-key shape; "
            "only the random 32-hex component is normalized."
        ),
        "dataPolicy": (
            "The report contains only the frozen public web-icon hash, response hashes and difference "
            "categories. URLs, object keys, credentials and ticket IDs are not persisted. "
            "Both uploaded objects are released through the production API in a finally block."
        ),
        "passed": passed,
        "summary": {
            "passed": sum(step["passed"] for step in steps),
            "total": len(steps),
        },
        "steps": steps,
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
        f"note image upload parity: {report['summary']['passed']}/"
        f"{report['summary']['total']} passed; report={args.output}"
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
