#!/usr/bin/env python3
"""Byte-compare Android Oracle output against the committed v2 corpus."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = REPOSITORY_ROOT / "xmnoteTests/Fixtures/ImportParity/v2"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("oracle_output", type=Path)
    return parser.parse_args()


def first_difference(expected: object, actual: object, path: str = "$") -> str | None:
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(expected.keys() | actual.keys()):
            if key not in expected:
                return f"{path}.{key} Android Oracle 多出字段"
            if key not in actual:
                return f"{path}.{key} Android Oracle 缺少字段"
            nested = first_difference(expected[key], actual[key], f"{path}.{key}")
            if nested:
                return nested
        return None
    if isinstance(expected, list) and isinstance(actual, list):
        for index, (left, right) in enumerate(zip(expected, actual)):
            nested = first_difference(left, right, f"{path}[{index}]")
            if nested:
                return nested
        if len(expected) != len(actual):
            return f"{path} 数组长度不同: frozen={len(expected)}, oracle={len(actual)}"
        return None
    if expected != actual:
        return f"{path} 值不同: frozen={expected!r}, oracle={actual!r}"
    return None


def cases(manifest_path: Path, root: Path) -> list[tuple[str, Path]]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    return [(item["id"], root / item["expected"]) for item in manifest["cases"]]


def main() -> int:
    output = parse_arguments().oracle_output.resolve()
    all_cases = cases(FIXTURE_ROOT / "manifest.json", output)
    all_cases += cases(
        FIXTURE_ROOT / "mutations/mutation-manifest.json",
        output / "mutations",
    )
    failures: list[str] = []
    for case_id, oracle_path in all_cases:
        relative = oracle_path.relative_to(output)
        frozen_path = FIXTURE_ROOT / relative
        if not oracle_path.is_file():
            failures.append(f"{case_id}: 缺少 Android Oracle 输出 {oracle_path}")
            continue
        if not frozen_path.is_file():
            failures.append(f"{case_id}: 缺少冻结 Golden {frozen_path}")
            continue
        oracle_bytes = oracle_path.read_bytes()
        frozen_bytes = frozen_path.read_bytes()
        if oracle_bytes == frozen_bytes:
            continue
        try:
            detail = first_difference(
                json.loads(frozen_bytes),
                json.loads(oracle_bytes),
            ) or "JSON 相等但字节序列不同"
        except json.JSONDecodeError as error:
            detail = f"JSON 无法解码: {error}"
        failures.append(f"{case_id}: {detail}")
    if failures:
        print("Android Oracle 与冻结 Golden 不一致:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"Android Oracle Golden 字节级一致: {len(all_cases)} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
