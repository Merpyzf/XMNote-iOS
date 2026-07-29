#!/usr/bin/env python3
"""Compare the stateful Android/iOS upload-ticket workflow without persisting payloads."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import pathlib
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any


CONTRACT_HEADERS = ("content-type", "cache-control")
FIXTURE_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


@dataclass(frozen=True)
class HTTPResult:
    status: int
    headers: dict[str, str]
    body: bytes
    error: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare Android/iOS note-image upload ticket workflows."
    )
    parser.add_argument("--android-base", required=True)
    parser.add_argument("--ios-base", required=True)
    parser.add_argument("--android-header", action="append", default=[])
    parser.add_argument("--ios-header", action="append", default=[])
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def parse_headers(values: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        name, separator, content = value.partition(":")
        if not separator or not name.strip():
            raise ValueError(f"Invalid header {value!r}; expected 'Name: value'")
        result[name.strip()] = content.strip()
    return result


def request(
    base: str,
    path: str,
    method: str,
    headers: dict[str, str],
    body: bytes | None,
    timeout: float,
) -> HTTPResult:
    request_headers = dict(headers)
    if body is not None:
        request_headers.setdefault("Content-Length", str(len(body)))
    value = urllib.request.Request(
        f"{base.rstrip('/')}{path}",
        data=body,
        method=method,
        headers=request_headers,
    )
    try:
        with urllib.request.urlopen(value, timeout=timeout) as response:
            return HTTPResult(
                status=response.status,
                headers={key.lower(): item for key, item in response.headers.items()},
                body=response.read(),
            )
    except urllib.error.HTTPError as error:
        return HTTPResult(
            status=error.code,
            headers={key.lower(): item for key, item in error.headers.items()},
            body=error.read(),
        )
    except Exception as error:
        return HTTPResult(status=0, headers={}, body=b"", error=type(error).__name__)


def json_body(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def multipart_body(ticket_id: str, data: bytes) -> tuple[str, bytes]:
    boundary = f"xmnote-parity-{uuid.uuid4().hex}"
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="ticketId"\r\n\r\n'
        f"{ticket_id}\r\n"
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="fixture.png"\r\n'
        "Content-Type: image/png\r\n\r\n"
    ).encode("utf-8")
    body += data
    body += f"\r\n--{boundary}--\r\n".encode("utf-8")
    return f"multipart/form-data; boundary={boundary}", body


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def decode_envelope(result: HTTPResult) -> dict[str, Any]:
    if result.error:
        raise RuntimeError(f"request failed: {result.error}")
    try:
        value = json.loads(result.body)
    except Exception as error:
        raise RuntimeError(
            f"response is not JSON: status={result.status}, sha256={sha256(result.body)}"
        ) from error
    if not isinstance(value, dict):
        raise RuntimeError("response envelope is not an object")
    return value


def require_reserved_ticket(result: HTTPResult) -> str:
    envelope = decode_envelope(result)
    if result.status != 200 or envelope.get("code") != 200:
        raise RuntimeError(
            f"reservation failed: status={result.status}, sha256={sha256(result.body)}"
        )
    data = envelope.get("data")
    tickets = data.get("tickets") if isinstance(data, dict) else None
    if not isinstance(tickets, list) or len(tickets) != 1:
        raise RuntimeError("reservation must return exactly one ticket")
    ticket = tickets[0]
    ticket_id = ticket.get("ticketId") if isinstance(ticket, dict) else None
    expires_at = ticket.get("expiresAt") if isinstance(ticket, dict) else None
    if not isinstance(ticket_id, str) or not ticket_id:
        raise RuntimeError("reservation ticketId is missing")
    if not isinstance(expires_at, int) or expires_at <= 0:
        raise RuntimeError("reservation expiresAt is not a positive epoch millisecond")
    return ticket_id


def contract_headers(result: HTTPResult) -> dict[str, str]:
    return {
        name: result.headers[name]
        for name in CONTRACT_HEADERS
        if name in result.headers
    }


def normalize(value: Any, ticket_ids: list[str]) -> Any:
    ticket_mapping = {
        ticket_id: f"<ticket-{index}>"
        for index, ticket_id in enumerate(ticket_ids)
    }

    def visit(item: Any, key: str | None = None) -> Any:
        if isinstance(item, dict):
            return {name: visit(child, name) for name, child in item.items()}
        if isinstance(item, list):
            return [visit(child) for child in item]
        if isinstance(item, str) and item in ticket_mapping:
            return ticket_mapping[item]
        if key == "expiresAt":
            if not isinstance(item, int) or item <= 0:
                raise RuntimeError("expiresAt must be a positive epoch millisecond")
            return "<epoch-millis>"
        return item

    return visit(value)


def compare_step(
    name: str,
    android_result: HTTPResult,
    ios_result: HTTPResult,
    android_ticket_ids: list[str],
    ios_ticket_ids: list[str],
) -> dict[str, Any]:
    android_envelope = normalize(
        decode_envelope(android_result),
        android_ticket_ids,
    )
    ios_envelope = normalize(
        decode_envelope(ios_result),
        ios_ticket_ids,
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
            "android": sha256(json_body(android_envelope)),
            "ios": sha256(json_body(ios_envelope)),
        },
    }


def execute(args: argparse.Namespace) -> dict[str, Any]:
    android_headers = parse_headers(args.android_header)
    ios_headers = parse_headers(args.ios_header)
    android_json_headers = {**android_headers, "Content-Type": "application/json"}
    ios_json_headers = {**ios_headers, "Content-Type": "application/json"}
    android_ticket_ids: list[str] = []
    ios_ticket_ids: list[str] = []
    steps: list[dict[str, Any]] = []

    android_reserve = request(
        args.android_base,
        "/api/v1/note-images/upload-tickets",
        "POST",
        android_json_headers,
        json_body({"count": 0}),
        args.timeout,
    )
    ios_reserve = request(
        args.ios_base,
        "/api/v1/note-images/upload-tickets",
        "POST",
        ios_json_headers,
        json_body({"count": 0}),
        args.timeout,
    )
    android_ticket_ids.append(require_reserved_ticket(android_reserve))
    ios_ticket_ids.append(require_reserved_ticket(ios_reserve))
    steps.append(
        compare_step(
            "reserve-zero-normalizes-to-one",
            android_reserve,
            ios_reserve,
            android_ticket_ids,
            ios_ticket_ids,
        )
    )

    android_release_body = json_body(
        {
            "ticketIds": [
                f" {android_ticket_ids[0]} ",
                android_ticket_ids[0],
                "",
                "unknown-ticket",
            ]
        }
    )
    ios_release_body = json_body(
        {
            "ticketIds": [
                f" {ios_ticket_ids[0]} ",
                ios_ticket_ids[0],
                "",
                "unknown-ticket",
            ]
        }
    )
    android_release = request(
        args.android_base,
        "/api/v1/note-images/upload-tickets/release",
        "POST",
        android_json_headers,
        android_release_body,
        args.timeout,
    )
    ios_release = request(
        args.ios_base,
        "/api/v1/note-images/upload-tickets/release",
        "POST",
        ios_json_headers,
        ios_release_body,
        args.timeout,
    )
    steps.append(
        compare_step(
            "release-trims-deduplicates-and-ignores-unknown",
            android_release,
            ios_release,
            android_ticket_ids,
            ios_ticket_ids,
        )
    )

    android_upload_type, android_upload_body = multipart_body(
        android_ticket_ids[0],
        FIXTURE_PNG,
    )
    ios_upload_type, ios_upload_body = multipart_body(
        ios_ticket_ids[0],
        FIXTURE_PNG,
    )
    android_released_upload = request(
        args.android_base,
        "/api/v1/note-images/upload",
        "POST",
        {**android_headers, "Content-Type": android_upload_type},
        android_upload_body,
        args.timeout,
    )
    ios_released_upload = request(
        args.ios_base,
        "/api/v1/note-images/upload",
        "POST",
        {**ios_headers, "Content-Type": ios_upload_type},
        ios_upload_body,
        args.timeout,
    )
    steps.append(
        compare_step(
            "released-ticket-cannot-upload",
            android_released_upload,
            ios_released_upload,
            android_ticket_ids,
            ios_ticket_ids,
        )
    )

    android_limit = request(
        args.android_base,
        "/api/v1/note-images/upload-tickets",
        "POST",
        android_json_headers,
        json_body({"count": 21}),
        args.timeout,
    )
    ios_limit = request(
        args.ios_base,
        "/api/v1/note-images/upload-tickets",
        "POST",
        ios_json_headers,
        json_body({"count": 21}),
        args.timeout,
    )
    steps.append(
        compare_step(
            "reserve-rejects-more-than-twenty",
            android_limit,
            ios_limit,
            android_ticket_ids,
            ios_ticket_ids,
        )
    )

    android_empty_release = request(
        args.android_base,
        "/api/v1/note-images/upload-tickets/release",
        "POST",
        android_json_headers,
        json_body({"ticketIds": ["", "  "]}),
        args.timeout,
    )
    ios_empty_release = request(
        args.ios_base,
        "/api/v1/note-images/upload-tickets/release",
        "POST",
        ios_json_headers,
        json_body({"ticketIds": ["", "  "]}),
        args.timeout,
    )
    steps.append(
        compare_step(
            "release-empty-is-idempotent",
            android_empty_release,
            ios_empty_release,
            android_ticket_ids,
            ios_ticket_ids,
        )
    )

    passed = all(step["passed"] for step in steps)
    return {
        "schemaVersion": 1,
        "workflow": "upload-ticket-reserve-release",
        "fixture": {
            "imageSHA256": sha256(FIXTURE_PNG),
        },
        "dataPolicy": (
            "The report contains only synthetic fixture hashes, response hashes and "
            "difference categories; ticket IDs and response payloads are not persisted."
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
        f"upload ticket parity: {report['summary']['passed']}/"
        f"{report['summary']['total']} passed; report={args.output}"
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
