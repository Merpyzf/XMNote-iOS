#!/usr/bin/env python3
"""Compare the stateful Android/iOS Web import workflow without persisting payloads."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any


CONTRACT_HEADERS = ("content-type", "cache-control")
TERMINAL_STATUSES = {"succeeded", "failed", "committed"}


@dataclass(frozen=True)
class HTTPResult:
    status: int
    headers: dict[str, str]
    body: bytes
    error: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare Android/iOS import create, query, commit and delete workflows."
    )
    parser.add_argument("--android-base", required=True)
    parser.add_argument("--ios-base", required=True)
    parser.add_argument("--android-header", action="append", default=[])
    parser.add_argument("--ios-header", action="append", default=[])
    parser.add_argument("--file", type=pathlib.Path, required=True)
    parser.add_argument("--file-name", default="koodo-single-note.csv")
    parser.add_argument("--target-book-id", type=int, required=True)
    parser.add_argument(
        "--lifecycle-only",
        action="store_true",
        help="Create, query and delete the task without committing database content.",
    )
    parser.add_argument(
        "--skip-query-after-delete",
        action="store_true",
        help=(
            "Skip the duplicate missing-task check after a successful delete. "
            "Use only when that error contract is proven separately against the formal APK."
        ),
    )
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
    request_value = urllib.request.Request(
        f"{base.rstrip('/')}{path}",
        data=body,
        method=method,
        headers=request_headers,
    )
    try:
        with urllib.request.urlopen(request_value, timeout=timeout) as response:
            return HTTPResult(
                status=response.status,
                headers={key.lower(): value for key, value in response.headers.items()},
                body=response.read(),
            )
    except urllib.error.HTTPError as error:
        return HTTPResult(
            status=error.code,
            headers={key.lower(): value for key, value in error.headers.items()},
            body=error.read(),
        )
    except Exception as error:
        return HTTPResult(status=0, headers={}, body=b"", error=type(error).__name__)


def multipart_body(file_name: str, data: bytes) -> tuple[str, bytes]:
    boundary = f"xmnote-parity-{uuid.uuid4().hex}"
    prefix = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{file_name}"\r\n'
        "Content-Type: text/csv\r\n\r\n"
    ).encode("utf-8")
    body = prefix + data + f"\r\n--{boundary}--\r\n".encode("utf-8")
    return f"multipart/form-data; boundary={boundary}", body


def json_body(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


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


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def contract_headers(result: HTTPResult) -> dict[str, str]:
    return {
        name: result.headers[name]
        for name in CONTRACT_HEADERS
        if name in result.headers
    }


def normalize(
    value: Any,
    task_id: str,
    *,
    allow_epoch_fields: bool = True,
) -> Any:
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            if key == "taskId" and item == task_id:
                result[key] = "<task-id>"
            elif allow_epoch_fields and key in {"createdTime", "updatedTime"}:
                if not isinstance(item, int) or item <= 0:
                    raise RuntimeError(f"{key} must be a positive epoch millisecond")
                result[key] = "<epoch-millis>"
            else:
                result[key] = normalize(
                    item,
                    task_id,
                    allow_epoch_fields=allow_epoch_fields,
                )
        return result
    if isinstance(value, list):
        return [
            normalize(item, task_id, allow_epoch_fields=allow_epoch_fields)
            for item in value
        ]
    return value


def compare_step(
    name: str,
    android_result: HTTPResult,
    ios_result: HTTPResult,
    android_task_id: str,
    ios_task_id: str,
) -> dict[str, Any]:
    android_envelope = decode_envelope(android_result)
    ios_envelope = decode_envelope(ios_result)
    normalized_android = normalize(android_envelope, android_task_id)
    normalized_ios = normalize(ios_envelope, ios_task_id)
    differences: list[str] = []
    if android_result.status != ios_result.status:
        differences.append("httpStatus")
    if contract_headers(android_result) != contract_headers(ios_result):
        differences.append("headers")
    if normalized_android != normalized_ios:
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
            "android": sha256(json_body(normalized_android)),
            "ios": sha256(json_body(normalized_ios)),
        },
    }


def wait_for_terminal(
    base: str,
    task_id: str,
    headers: dict[str, str],
    timeout: float,
) -> HTTPResult:
    deadline = time.monotonic() + timeout
    latest: HTTPResult | None = None
    while time.monotonic() < deadline:
        latest = request(
            base,
            f"/api/v1/import/tasks/{task_id}",
            "GET",
            headers,
            None,
            timeout,
        )
        envelope = decode_envelope(latest)
        data = envelope.get("data")
        status = data.get("status") if isinstance(data, dict) else None
        if status in TERMINAL_STATUSES:
            return latest
        time.sleep(0.05)
    if latest is None:
        raise RuntimeError("import task was never queried")
    raise RuntimeError(
        f"import task did not reach a terminal status; bodySHA256={sha256(latest.body)}"
    )


def require_success_data(result: HTTPResult) -> dict[str, Any]:
    envelope = decode_envelope(result)
    if result.status != 200 or envelope.get("code") != 200:
        raise RuntimeError(
            f"expected success; status={result.status}, bodySHA256={sha256(result.body)}"
        )
    data = envelope.get("data")
    if not isinstance(data, dict):
        raise RuntimeError("success envelope data is not an object")
    return data


def execute(args: argparse.Namespace) -> dict[str, Any]:
    android_headers = parse_headers(args.android_header)
    ios_headers = parse_headers(args.ios_header)
    fixture = args.file.read_bytes()
    android_content_type, android_body = multipart_body(args.file_name, fixture)
    ios_content_type, ios_body = multipart_body(args.file_name, fixture)

    android_create = request(
        args.android_base,
        "/api/v1/import/tasks",
        "POST",
        {**android_headers, "Content-Type": android_content_type},
        android_body,
        args.timeout,
    )
    ios_create = request(
        args.ios_base,
        "/api/v1/import/tasks",
        "POST",
        {**ios_headers, "Content-Type": ios_content_type},
        ios_body,
        args.timeout,
    )
    android_create_data = require_success_data(android_create)
    ios_create_data = require_success_data(ios_create)
    android_task_id = android_create_data.get("taskId")
    ios_task_id = ios_create_data.get("taskId")
    if not isinstance(android_task_id, str) or not android_task_id:
        raise RuntimeError("Android create response has no taskId")
    if not isinstance(ios_task_id, str) or not ios_task_id:
        raise RuntimeError("iOS create response has no taskId")

    steps = [
        compare_step(
            "create",
            android_create,
            ios_create,
            android_task_id,
            ios_task_id,
        )
    ]

    android_detail = wait_for_terminal(
        args.android_base,
        android_task_id,
        android_headers,
        args.timeout,
    )
    ios_detail = wait_for_terminal(
        args.ios_base,
        ios_task_id,
        ios_headers,
        args.timeout,
    )
    steps.append(
        compare_step(
            "query-succeeded",
            android_detail,
            ios_detail,
            android_task_id,
            ios_task_id,
        )
    )
    for result in (android_detail, ios_detail):
        data = require_success_data(result)
        if data.get("status") != "succeeded":
            raise RuntimeError(
                f"fixture parsing failed; bodySHA256={sha256(result.body)}"
            )

    if args.lifecycle_only:
        android_delete = request(
            args.android_base,
            f"/api/v1/import/tasks/{android_task_id}",
            "DELETE",
            android_headers,
            None,
            args.timeout,
        )
        ios_delete = request(
            args.ios_base,
            f"/api/v1/import/tasks/{ios_task_id}",
            "DELETE",
            ios_headers,
            None,
            args.timeout,
        )
        steps.append(
            compare_step(
                "delete",
                android_delete,
                ios_delete,
                android_task_id,
                ios_task_id,
            )
        )
        android_missing = request(
            args.android_base,
            f"/api/v1/import/tasks/{android_task_id}",
            "GET",
            android_headers,
            None,
            args.timeout,
        )
        ios_missing = request(
            args.ios_base,
            f"/api/v1/import/tasks/{ios_task_id}",
            "GET",
            ios_headers,
            None,
            args.timeout,
        )
        steps.append(
            compare_step(
                "query-after-delete",
                android_missing,
                ios_missing,
                android_task_id,
                ios_task_id,
            )
        )
        passed = all(step["passed"] for step in steps)
        return {
            "schemaVersion": 1,
            "workflow": "import-task-lifecycle",
            "fixture": {
                "fileName": args.file_name,
                "sha256": sha256(fixture),
                "targetBookId": args.target_book_id,
            },
            "dataPolicy": (
                "The report contains only synthetic fixture metadata, hashes and difference "
                "categories; task IDs and response payloads are not persisted."
            ),
            "passed": passed,
            "summary": {
                "passed": sum(step["passed"] for step in steps),
                "total": len(steps),
            },
            "steps": steps,
        }

    commit_payload = {
        "books": [
            {
                "index": 0,
                "noteIndexes": [0],
                "targetBookId": args.target_book_id,
                "clearTargetBook": False,
            }
        ]
    }
    commit_data = json_body(commit_payload)
    json_headers_android = {**android_headers, "Content-Type": "application/json"}
    json_headers_ios = {**ios_headers, "Content-Type": "application/json"}
    android_commit = request(
        args.android_base,
        f"/api/v1/import/tasks/{android_task_id}/commit",
        "POST",
        json_headers_android,
        commit_data,
        args.timeout,
    )
    ios_commit = request(
        args.ios_base,
        f"/api/v1/import/tasks/{ios_task_id}/commit",
        "POST",
        json_headers_ios,
        commit_data,
        args.timeout,
    )
    steps.append(
        compare_step(
            "commit",
            android_commit,
            ios_commit,
            android_task_id,
            ios_task_id,
        )
    )
    for result in (android_commit, ios_commit):
        data = require_success_data(result)
        if data != {"importedBookCount": 1, "importedNoteCount": 1}:
            raise RuntimeError(
                f"unexpected commit counts; bodySHA256={sha256(result.body)}"
            )

    android_committed = request(
        args.android_base,
        f"/api/v1/import/tasks/{android_task_id}",
        "GET",
        android_headers,
        None,
        args.timeout,
    )
    ios_committed = request(
        args.ios_base,
        f"/api/v1/import/tasks/{ios_task_id}",
        "GET",
        ios_headers,
        None,
        args.timeout,
    )
    steps.append(
        compare_step(
            "query-committed",
            android_committed,
            ios_committed,
            android_task_id,
            ios_task_id,
        )
    )

    android_recommit = request(
        args.android_base,
        f"/api/v1/import/tasks/{android_task_id}/commit",
        "POST",
        json_headers_android,
        commit_data,
        args.timeout,
    )
    ios_recommit = request(
        args.ios_base,
        f"/api/v1/import/tasks/{ios_task_id}/commit",
        "POST",
        json_headers_ios,
        commit_data,
        args.timeout,
    )
    steps.append(
        compare_step(
            "commit-idempotent",
            android_recommit,
            ios_recommit,
            android_task_id,
            ios_task_id,
        )
    )

    android_delete = request(
        args.android_base,
        f"/api/v1/import/tasks/{android_task_id}",
        "DELETE",
        android_headers,
        None,
        args.timeout,
    )
    ios_delete = request(
        args.ios_base,
        f"/api/v1/import/tasks/{ios_task_id}",
        "DELETE",
        ios_headers,
        None,
        args.timeout,
    )
    steps.append(
        compare_step(
            "delete",
            android_delete,
            ios_delete,
            android_task_id,
            ios_task_id,
        )
    )

    if not args.skip_query_after_delete:
        android_missing = request(
            args.android_base,
            f"/api/v1/import/tasks/{android_task_id}",
            "GET",
            android_headers,
            None,
            args.timeout,
        )
        ios_missing = request(
            args.ios_base,
            f"/api/v1/import/tasks/{ios_task_id}",
            "GET",
            ios_headers,
            None,
            args.timeout,
        )
        steps.append(
            compare_step(
                "query-after-delete",
                android_missing,
                ios_missing,
                android_task_id,
                ios_task_id,
            )
        )

    passed = all(step["passed"] for step in steps)
    return {
        "schemaVersion": 1,
        "workflow": "import-task-success",
        "fixture": {
            "fileName": args.file_name,
            "sha256": sha256(fixture),
            "targetBookId": args.target_book_id,
        },
        "dataPolicy": (
            "The report contains only synthetic fixture metadata, hashes and difference "
            "categories; task IDs and response payloads are not persisted."
        ),
        "passed": passed,
        "summary": {"passed": sum(step["passed"] for step in steps), "total": len(steps)},
        "steps": steps,
    }


def main() -> int:
    args = parse_args()
    report: dict[str, Any]
    try:
        report = execute(args)
    except Exception as error:
        report = {
            "schemaVersion": 1,
            "workflow": "import-task-success",
            "passed": False,
            "fatalError": type(error).__name__,
            "message": str(error),
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    summary = report.get("summary")
    if isinstance(summary, dict):
        print(
            f"Summary: {summary.get('passed', 0)}/{summary.get('total', 0)} passed; "
            f"report={args.output}"
        )
    else:
        print(
            f"FAILED {report.get('fatalError', 'UnknownError')}: "
            f"{report.get('message', '')}; report={args.output}"
        )
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
