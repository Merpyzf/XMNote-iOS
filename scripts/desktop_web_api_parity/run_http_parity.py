#!/usr/bin/env python3
"""Run reproducible Android/iOS Web API response comparisons without persisting user payloads."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


CONTRACT_HEADERS = (
    "content-type",
    "content-disposition",
    "cache-control",
    "etag",
    "accept-ranges",
    "content-range",
)

MEMBERSHIP_WHITELISTED_WRITE_PATHS = {
    "/api/v1/settings/web",
    "/api/v1/settings/export",
    "/api/v1/statistics/yearly-goal-celebration",
    "/api/v1/ai/config",
    "/api/v1/native/actions/open-vip-upgrade",
    "/api/v1/bookshelf/items/query",
}

MEMBERSHIP_WHITELISTED_WRITE_PREFIXES = (
    "/api/v1/settings/access-auth",
)


@dataclass(frozen=True)
class HTTPResult:
    status: int
    headers: dict[str, str]
    body: bytes
    request_error: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare Android and iOS XMNote Web API responses."
    )
    parser.add_argument("--android-base", required=True)
    parser.add_argument("--ios-base", required=True)
    parser.add_argument("--android-header", action="append", default=[])
    parser.add_argument("--ios-header", action="append", default=[])
    parser.add_argument(
        "--manifest",
        type=pathlib.Path,
        default=pathlib.Path(
            "Packages/XMNoteWeb/Tests/XMNoteWebTests/Fixtures/APIParity/"
            "endpoint-manifest.json"
        ),
    )
    parser.add_argument(
        "--preset",
        choices=(
            "safe-root-get",
            "frozen-apk-dto-body-failure",
            "local-mutation-malformed-boundary",
            "auth-rejection",
            "membership-readonly",
        ),
        default=None,
        help=(
            "safe-root-get selects local, read-only GET routes without path placeholders; "
            "frozen-apk-dto-body-failure selects the 26 ANDROID-WEB-087 routes and sends {}; "
            "local-mutation-malformed-boundary selects 57 isolated local writes, substitutes "
            "a missing resource ID, and sends malformed JSON where a body is accepted; "
            "auth-rejection selects the 158 routes protected by the Android access-code interceptor; "
            "membership-readonly selects the 82 core writes blocked for a non-premium account."
        ),
    )
    parser.add_argument(
        "--cases",
        type=pathlib.Path,
        help=(
            "Run explicit synthetic cases from a JSON fixture. The fixture may override "
            "the request path, body and headers without persisting response payloads."
        ),
    )
    parser.add_argument(
        "--ids",
        help="Optional comma-separated endpoint IDs. Intersects with the selected preset.",
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


def is_safe_root_get(endpoint: dict[str, Any]) -> bool:
    return (
        endpoint["method"] == "GET"
        and "{" not in endpoint["path"]
        and not endpoint["mutatesState"]
        and not endpoint["hasExternalDependency"]
    )


def is_frozen_apk_dto_body_failure(endpoint: dict[str, Any]) -> bool:
    return "ANDROID-WEB-087" in endpoint.get("issueIds", [])


def is_local_mutation_malformed_boundary(endpoint: dict[str, Any]) -> bool:
    return (
        endpoint["mutatesState"]
        and not endpoint["hasExternalDependency"]
        and not is_frozen_apk_dto_body_failure(endpoint)
        and endpoint["id"] != "WEB-API-067"
    )


def is_auth_rejection(endpoint: dict[str, Any]) -> bool:
    return endpoint["path"] not in {
        "/api/v1/settings/access-auth",
        "/api/v1/book-covers/proxy/{bookId}",
    }


def is_membership_readonly(endpoint: dict[str, Any]) -> bool:
    path = endpoint["path"].removesuffix("/")
    return (
        endpoint["method"] not in {"GET", "OPTIONS"}
        and path.startswith("/api/v1/")
        and path not in MEMBERSHIP_WHITELISTED_WRITE_PATHS
        and not any(
            path.startswith(prefix)
            for prefix in MEMBERSHIP_WHITELISTED_WRITE_PREFIXES
        )
    )


def make_request_case(endpoint: dict[str, Any], preset: str) -> tuple[dict[str, Any], bytes | None]:
    if preset == "safe-root-get":
        return endpoint, None

    request_endpoint = dict(endpoint)
    request_endpoint["pathTemplate"] = endpoint["path"]
    if preset == "frozen-apk-dto-body-failure":
        request_endpoint["path"] = re.sub(r"\{[^/{}]+\}", "7", endpoint["path"])
        return request_endpoint, b"{}"
    if preset in {"auth-rejection", "membership-readonly"}:
        request_endpoint["path"] = re.sub(r"\{[^/{}]+\}", "7", endpoint["path"])
        body = None if endpoint["method"] in {"GET", "DELETE"} else b"{}"
        return request_endpoint, body

    request_endpoint["path"] = re.sub(
        r"\{[^/{}]+\}",
        "999999",
        endpoint["path"],
    )
    return request_endpoint, None if endpoint["method"] == "DELETE" else b"{"


def request_body(case: dict[str, Any]) -> bytes | None:
    body_keys = [
        key
        for key in ("jsonBody", "textBody", "base64Body")
        if key in case
    ]
    if len(body_keys) > 1:
        raise ValueError(
            f"Case {case.get('caseId')!r} defines multiple request body representations"
        )
    if "jsonBody" in case:
        return json.dumps(
            case["jsonBody"],
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    if "textBody" in case:
        if not isinstance(case["textBody"], str):
            raise ValueError(f"Case {case.get('caseId')!r} textBody must be a string")
        return case["textBody"].encode("utf-8")
    if "base64Body" in case:
        try:
            return base64.b64decode(case["base64Body"], validate=True)
        except Exception as error:
            raise ValueError(
                f"Case {case.get('caseId')!r} has invalid base64Body"
            ) from error
    return None


def load_explicit_cases(
    case_path: pathlib.Path,
    endpoints_by_id: dict[str, dict[str, Any]],
    selected_ids: set[str] | None,
) -> tuple[str, list[tuple[dict[str, Any], bytes | None, dict[str, str]]]]:
    fixture = json.loads(case_path.read_text(encoding="utf-8"))
    if fixture.get("schemaVersion") != 1:
        raise ValueError("Explicit case fixture schemaVersion must be 1")
    fixture_name = fixture.get("name")
    if not isinstance(fixture_name, str) or not fixture_name:
        raise ValueError("Explicit case fixture requires a non-empty name")
    raw_cases = fixture.get("cases")
    if not isinstance(raw_cases, list) or not raw_cases:
        raise ValueError("Explicit case fixture requires a non-empty cases array")

    prepared: list[tuple[dict[str, Any], bytes | None, dict[str, str]]] = []
    seen_case_ids: set[str] = set()
    for case in raw_cases:
        if not isinstance(case, dict):
            raise ValueError("Each explicit case must be an object")
        case_id = case.get("caseId")
        endpoint_id = case.get("endpointId")
        if not isinstance(case_id, str) or not case_id:
            raise ValueError("Each explicit case requires a non-empty caseId")
        if case_id in seen_case_ids:
            raise ValueError(f"Duplicate explicit caseId {case_id!r}")
        seen_case_ids.add(case_id)
        if not isinstance(endpoint_id, str) or endpoint_id not in endpoints_by_id:
            raise ValueError(
                f"Case {case_id!r} references unknown endpointId {endpoint_id!r}"
            )
        if selected_ids is not None and endpoint_id not in selected_ids:
            continue

        path = case.get("path")
        if not isinstance(path, str) or not path.startswith("/api/v1/"):
            raise ValueError(
                f"Case {case_id!r} path must start with '/api/v1/'"
            )
        headers = case.get("headers", {})
        if not isinstance(headers, dict) or not all(
            isinstance(name, str) and isinstance(value, str)
            for name, value in headers.items()
        ):
            raise ValueError(f"Case {case_id!r} headers must be string pairs")

        request_endpoint = dict(endpoints_by_id[endpoint_id])
        request_endpoint["pathTemplate"] = request_endpoint["path"]
        request_endpoint["path"] = path
        request_endpoint["caseId"] = case_id
        response_normalizations = case.get("responseNormalizations", [])
        if not isinstance(response_normalizations, list):
            raise ValueError(
                f"Case {case_id!r} responseNormalizations must be an array"
            )
        seen_normalization_paths: set[str] = set()
        for normalization in response_normalizations:
            if not isinstance(normalization, dict):
                raise ValueError(
                    f"Case {case_id!r} response normalizations must be objects"
                )
            normalization_path = normalization.get("path")
            strategy = normalization.get("strategy")
            reason = normalization.get("reason")
            if (
                not isinstance(normalization_path, str)
                or not normalization_path.startswith("$.")
                or strategy != "independent-epoch-millis"
                or not isinstance(reason, str)
                or not reason
            ):
                raise ValueError(
                    f"Case {case_id!r} has an invalid response normalization"
                )
            if normalization_path in seen_normalization_paths:
                raise ValueError(
                    f"Case {case_id!r} repeats normalization path "
                    f"{normalization_path!r}"
                )
            seen_normalization_paths.add(normalization_path)
        if response_normalizations:
            request_endpoint["responseNormalizations"] = response_normalizations
        prepared.append((request_endpoint, request_body(case), headers))

    if selected_ids is not None:
        represented_ids = {endpoint["id"] for endpoint, _, _ in prepared}
        missing_ids = selected_ids - represented_ids
        if missing_ids:
            raise ValueError(
                "Endpoint IDs are absent from the explicit case fixture: "
                + ", ".join(sorted(missing_ids))
            )
    if not prepared:
        raise ValueError("No explicit cases remain after endpoint filtering")
    return fixture_name, prepared


def request(
    base_url: str,
    endpoint: dict[str, Any],
    headers: dict[str, str],
    timeout: float,
    body: bytes | None,
) -> HTTPResult:
    url = base_url.rstrip("/") + endpoint["path"]
    default_headers = {
        "Accept": "application/json",
        "User-Agent": "XMNote-Web-API-Parity/1",
    }
    if body is not None:
        default_headers["Content-Type"] = "application/json"
    request_value = urllib.request.Request(
        url,
        data=body,
        method=endpoint["method"],
        headers={
            **default_headers,
            **headers,
        },
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
    except Exception as error:  # noqa: BLE001 - the report must retain transport failures.
        return HTTPResult(
            status=0,
            headers={},
            body=b"",
            request_error=f"{type(error).__name__}: {error}",
        )


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def json_digest(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return sha256(encoded)


def json_type(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def strict_json_differences(
    android: Any,
    ios: Any,
    path: str = "$",
    limit: int = 20,
    normalization_rules_list: list[dict[str, str]] | None = None,
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    differences: list[dict[str, str]] = []
    applied_normalizations: list[dict[str, str]] = []
    normalization_rules = {
        rule["path"]: rule
        for rule in normalization_rules_list or []
    }

    def append(reason: str, left: Any, right: Any, current_path: str) -> None:
        if len(differences) >= limit:
            return
        differences.append(
            {
                "path": current_path,
                "reason": reason,
                "androidType": json_type(left),
                "iosType": json_type(right),
                "androidDigest": json_digest(left),
                "iosDigest": json_digest(right),
            }
        )

    def normalize_epoch(
        left: Any,
        right: Any,
        current_path: str,
    ) -> bool:
        rule = normalization_rules.get(current_path)
        if rule is None:
            return False
        values = (left, right)
        if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in values):
            append("normalization-value-is-not-numeric", left, right, current_path)
            return True
        minimum_epoch = 946_684_800_000
        maximum_epoch = 4_102_444_800_000
        if any(value < minimum_epoch or value > maximum_epoch for value in values):
            append("normalization-value-is-not-epoch-millis", left, right, current_path)
            return True
        applied_normalizations.append(
            {
                "path": current_path,
                "strategy": rule["strategy"],
                "reason": rule["reason"],
                "androidDigest": json_digest(left),
                "iosDigest": json_digest(right),
            }
        )
        return True

    def walk(left: Any, right: Any, current_path: str) -> None:
        if len(differences) >= limit:
            return
        left_type = json_type(left)
        right_type = json_type(right)
        if left_type != right_type:
            append("type", left, right, current_path)
            return
        if isinstance(left, dict):
            left_keys = set(left)
            right_keys = set(right)
            for key in sorted(left_keys - right_keys):
                append("missing-on-ios", left[key], None, f"{current_path}.{key}")
            for key in sorted(right_keys - left_keys):
                append("missing-on-android", None, right[key], f"{current_path}.{key}")
            for key in sorted(left_keys & right_keys):
                walk(left[key], right[key], f"{current_path}.{key}")
            return
        if isinstance(left, list):
            if len(left) != len(right):
                append("array-length", left, right, current_path)
                return
            for index, (left_item, right_item) in enumerate(zip(left, right)):
                walk(left_item, right_item, f"{current_path}[{index}]")
            return
        if left != right:
            if normalize_epoch(left, right, current_path):
                return
            append("value", left, right, current_path)

    walk(android, ios, path)
    return differences, applied_normalizations


def parse_json_body(result: HTTPResult) -> tuple[Any | None, str | None]:
    try:
        return json.loads(result.body), None
    except Exception as error:  # noqa: BLE001 - malformed JSON is comparison evidence.
        return None, f"{type(error).__name__}: {error}"


def response_summary(result: HTTPResult, parsed: Any | None, parse_error: str | None) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "status": result.status,
        "bodyBytes": len(result.body),
        "bodySHA256": sha256(result.body),
        "headers": {
            name: result.headers[name]
            for name in CONTRACT_HEADERS
            if name in result.headers
        },
    }
    if result.request_error:
        summary["requestError"] = result.request_error
    if parse_error:
        summary["jsonParseError"] = parse_error
    elif isinstance(parsed, dict):
        summary["json"] = {
            "code": parsed.get("code"),
            "msg": parsed.get("msg"),
            "dataType": json_type(parsed.get("data")) if "data" in parsed else "absent",
            "canonicalSHA256": json_digest(parsed),
        }
    return summary


def compare_endpoint(
    endpoint: dict[str, Any],
    android_result: HTTPResult,
    ios_result: HTTPResult,
) -> dict[str, Any]:
    android_json, android_parse_error = parse_json_body(android_result)
    ios_json, ios_parse_error = parse_json_body(ios_result)
    status_exact = android_result.status == ios_result.status
    transport_exact = (
        android_result.request_error is None and ios_result.request_error is None
    )
    header_differences = {
        name: {
            "android": android_result.headers.get(name),
            "ios": ios_result.headers.get(name),
        }
        for name in CONTRACT_HEADERS
        if android_result.headers.get(name) != ios_result.headers.get(name)
        and (
            name in android_result.headers
            or name in ios_result.headers
        )
    }
    normalizations = endpoint.get("responseNormalizations", [])
    if android_parse_error and ios_parse_error and android_result.body == ios_result.body:
        json_differences = []
        applied_normalizations = []
    elif android_parse_error or ios_parse_error:
        json_differences = [
            {
                "path": "$",
                "reason": "json-parse",
                "androidType": "invalid" if android_parse_error else json_type(android_json),
                "iosType": "invalid" if ios_parse_error else json_type(ios_json),
                "androidDigest": sha256(android_result.body),
                "iosDigest": sha256(ios_result.body),
            }
        ]
        applied_normalizations = []
    else:
        json_differences, applied_normalizations = strict_json_differences(
            android_json,
            ios_json,
            normalization_rules_list=normalizations,
        )
    structural_exact = not json_differences
    passed = transport_exact and status_exact and structural_exact and not header_differences
    return {
        "id": endpoint["id"],
        **({"caseId": endpoint["caseId"]} if "caseId" in endpoint else {}),
        "method": endpoint["method"],
        "path": endpoint["path"],
        **(
            {"pathTemplate": endpoint["pathTemplate"]}
            if "pathTemplate" in endpoint
            else {}
        ),
        "passed": passed,
        "comparison": {
            "transportExact": transport_exact,
            "statusExact": status_exact,
            "headersExact": not header_differences,
            "structuralJSONExact": structural_exact,
            "rawBodyExact": android_result.body == ios_result.body,
            "headerDifferences": header_differences,
            "jsonDifferences": json_differences,
            "normalizationsApplied": applied_normalizations,
        },
        "android": response_summary(
            android_result,
            android_json,
            android_parse_error,
        ),
        "ios": response_summary(
            ios_result,
            ios_json,
            ios_parse_error,
        ),
    }


def main() -> int:
    args = parse_args()
    if args.cases is not None and args.preset is not None:
        raise ValueError("--cases and --preset cannot be used together")
    preset = args.preset or "safe-root-get"
    android_headers = parse_headers(args.android_header)
    ios_headers = parse_headers(args.ios_header)
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    selected_ids = set(args.ids.split(",")) if args.ids else None
    endpoints_by_id = {
        endpoint["id"]: endpoint
        for endpoint in manifest["endpoints"]
    }
    fixture_name: str | None = None
    if args.cases is not None:
        fixture_name, request_cases = load_explicit_cases(
            args.cases,
            endpoints_by_id,
            selected_ids,
        )
    else:
        selectors = {
            "safe-root-get": is_safe_root_get,
            "frozen-apk-dto-body-failure": is_frozen_apk_dto_body_failure,
            "local-mutation-malformed-boundary": is_local_mutation_malformed_boundary,
            "auth-rejection": is_auth_rejection,
            "membership-readonly": is_membership_readonly,
        }
        selector = selectors[preset]
        endpoints = [
            endpoint
            for endpoint in manifest["endpoints"]
            if selector(endpoint)
            and (selected_ids is None or endpoint["id"] in selected_ids)
        ]
        if selected_ids is not None:
            missing_ids = selected_ids - {endpoint["id"] for endpoint in endpoints}
            if missing_ids:
                raise ValueError(
                    f"Endpoint IDs are absent or outside the {preset} preset: "
                    + ", ".join(sorted(missing_ids))
                )
        if (
            preset == "frozen-apk-dto-body-failure"
            and selected_ids is None
            and len(endpoints) != 26
        ):
            raise ValueError(
                "ANDROID-WEB-087 preset must contain exactly 26 endpoints; "
                f"found {len(endpoints)}"
            )
        if (
            preset == "local-mutation-malformed-boundary"
            and selected_ids is None
            and len(endpoints) != 57
        ):
            raise ValueError(
                "Local malformed mutation preset must contain exactly 57 endpoints; "
                f"found {len(endpoints)}"
            )
        if (
            preset == "auth-rejection"
            and selected_ids is None
            and len(endpoints) != 158
        ):
            raise ValueError(
                "Access-code rejection preset must contain exactly 158 endpoints; "
                f"found {len(endpoints)}"
            )
        if (
            preset == "membership-readonly"
            and selected_ids is None
            and len(endpoints) != 82
        ):
            raise ValueError(
                "Non-premium membership preset must contain exactly 82 endpoints; "
                f"found {len(endpoints)}"
            )
        request_cases = []
        for endpoint in endpoints:
            request_endpoint, body = make_request_case(endpoint, preset)
            request_cases.append((request_endpoint, body, {}))

    results: list[dict[str, Any]] = []
    for request_endpoint, body, case_headers in request_cases:
        android_result = request(
            args.android_base,
            request_endpoint,
            {**android_headers, **case_headers},
            args.timeout,
            body,
        )
        ios_result = request(
            args.ios_base,
            request_endpoint,
            {**ios_headers, **case_headers},
            args.timeout,
            body,
        )
        comparison = compare_endpoint(request_endpoint, android_result, ios_result)
        results.append(comparison)
        marker = "PASS" if comparison["passed"] else "FAIL"
        print(
            f"{marker} {request_endpoint.get('caseId', request_endpoint['id'])} "
            f"[{request_endpoint['id']}] "
            f"{request_endpoint['method']} {request_endpoint['path']}"
        )

    passed_count = sum(1 for result in results if result["passed"])
    report = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "androidBaseline": manifest["androidBaseline"],
        "iosSimulator": {
            "name": "iPhone 17 Pro Clean",
            "udid": "F33C38B2-5F2E-4003-B0EF-19E48285BB4C",
        },
        "preset": None if args.cases is not None else preset,
        **({"fixture": fixture_name} if fixture_name is not None else {}),
        "dataPolicy": "Hashes and structural mismatch paths only; response payloads are not persisted.",
        "summary": {
            "executed": len(results),
            "passed": passed_count,
            "failed": len(results) - passed_count,
        },
        "results": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"Summary: {passed_count}/{len(results)} passed; "
        f"report={args.output}"
    )
    return 0 if passed_count == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
