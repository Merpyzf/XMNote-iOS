#!/usr/bin/env python3
"""Local, repository-owned entry point for XMNote design-system constraints."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
DESIGN_SYSTEM_DIR = ROOT / "scripts" / "design-system"
POLICY_PATH = DESIGN_SYSTEM_DIR / "policy.json"
CATALOG_PATH = DESIGN_SYSTEM_DIR / "component-catalog.json"
BASELINE_PATH = DESIGN_SYSTEM_DIR / "ui-lint-baseline.json"
PACKAGE_PATH = DESIGN_SYSTEM_DIR / "ui-lint"
SCRATCH_PATH = ROOT / "artifacts" / "design-system" / "swiftpm"
MODULE_CACHE_PATH = ROOT / "artifacts" / "design-system" / "module-cache"
SWIFTPM_CACHE_PATH = ROOT / "artifacts" / "design-system" / "swiftpm-cache"


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")


def git_output(*arguments: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def unique_ordered(values: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(values))


def is_in_scope(path: str, policy: dict[str, Any]) -> bool:
    if not path.endswith(".swift"):
        return False
    if not any(path == root or path.startswith(f"{root}/") for root in policy["sourceRoots"]):
        return False
    return not any(fnmatch.fnmatch(path, pattern) for pattern in policy["excludedGlobs"])


def selected_files(mode: str, policy: dict[str, Any]) -> list[str]:
    if mode == "all":
        candidates = [
            str(path.relative_to(ROOT))
            for source_root in policy["sourceRoots"]
            for path in (ROOT / source_root).rglob("*.swift")
        ]
    elif mode == "staged":
        candidates = git_output("diff", "--cached", "--name-only", "--diff-filter=ACMR")
    else:
        candidates = git_output("diff", "HEAD", "--name-only", "--diff-filter=ACMR")
        candidates += git_output("ls-files", "--others", "--exclude-standard")

    return sorted(
        path
        for path in unique_ordered(candidates)
        if is_in_scope(path, policy) and (ROOT / path).is_file()
    )


def run_swift_linter(paths: list[str]) -> list[dict[str, Any]]:
    if not paths:
        return []

    SCRATCH_PATH.mkdir(parents=True, exist_ok=True)
    MODULE_CACHE_PATH.mkdir(parents=True, exist_ok=True)
    SWIFTPM_CACHE_PATH.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(MODULE_CACHE_PATH)
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(MODULE_CACHE_PATH)
    environment["SWIFTPM_CUSTOM_CACHE_PATH"] = str(SWIFTPM_CACHE_PATH)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        prefix="ui-lint-files-",
        suffix=".txt",
        dir=ROOT / "artifacts" / "design-system",
        delete=False,
    ) as stream:
        stream.write("\n".join(paths))
        stream.write("\n")
        file_list_path = Path(stream.name)

    try:
        result = subprocess.run(
            [
                "swift",
                "run",
                "--disable-sandbox",
                "--package-path",
                str(PACKAGE_PATH),
                "--scratch-path",
                str(SCRATCH_PATH),
                "--quiet",
                "XMNoteUILint",
                "--root",
                str(ROOT),
                "--file-list",
                str(file_list_path),
            ],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
        )
    finally:
        file_list_path.unlink(missing_ok=True)

    if result.returncode != 0:
        if result.stdout:
            print(result.stdout, file=sys.stderr)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        print("ERROR: SwiftSyntax 规则工具返回了无效 JSON。", file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(1) from error


def normalize_evidence(evidence: str) -> str:
    return re.sub(r"\s+", " ", evidence).strip()


def fingerprint(diagnostic: dict[str, Any]) -> str:
    identity = "\u241f".join(
        [
            diagnostic["ruleID"],
            diagnostic["path"],
            diagnostic["declaration"],
            normalize_evidence(diagnostic["evidence"]),
        ]
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def policy_rules(policy: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {rule["id"]: rule for rule in policy["rules"]}


def load_baseline() -> dict[str, Any]:
    if not BASELINE_PATH.exists():
        return {"schemaVersion": 1, "entries": []}
    return load_json(BASELINE_PATH)


def baseline_entry(diagnostic: dict[str, Any]) -> dict[str, Any]:
    return {
        "declaration": diagnostic["declaration"],
        "evidence": normalize_evidence(diagnostic["evidence"]),
        "fingerprint": fingerprint(diagnostic),
        "lineAtCapture": diagnostic["line"],
        "owner": "design-system-migration",
        "path": diagnostic["path"],
        "reason": "DS1 引入规则前已存在；仅阻止新增，DS2–DS6 分阶段清偿。",
        "reviewAfter": "DS6",
        "ruleID": diagnostic["ruleID"],
    }


def print_diagnostic(diagnostic: dict[str, Any], rule: dict[str, Any]) -> None:
    location = f"{diagnostic['path']}:{diagnostic['line']}:{diagnostic['column']}"
    print(f"{location}: {diagnostic['ruleID']} {rule['title']}")
    print(f"  {diagnostic['message']}")
    print(f"  正确入口：{rule['correctPath']}")
    print(f"  上下文：{diagnostic['declaration']} · {normalize_evidence(diagnostic['evidence'])}")


def lint_command(arguments: argparse.Namespace) -> int:
    policy = load_json(POLICY_PATH)
    rules = policy_rules(policy)
    mode = "all" if arguments.all else "staged" if arguments.staged else "changed"
    paths = selected_files(mode, policy)
    diagnostics = run_swift_linter(paths)

    unknown_rule_ids = sorted({item["ruleID"] for item in diagnostics} - set(rules))
    if unknown_rule_ids:
        print(f"ERROR: policy.json 未登记规则：{', '.join(unknown_rule_ids)}", file=sys.stderr)
        return 1

    enforced = [item for item in diagnostics if rules[item["ruleID"]]["enforcement"] == "enforced"]
    reports = [item for item in diagnostics if rules[item["ruleID"]]["enforcement"] == "report"]

    if arguments.write_baseline:
        if mode != "all":
            print("ERROR: --write-baseline 只能与 --all 一起使用。", file=sys.stderr)
            return 2
        entries = sorted(
            (baseline_entry(item) for item in enforced),
            key=lambda item: (item["path"], item["lineAtCapture"], item["ruleID"]),
        )
        write_json(
            BASELINE_PATH,
            {
                "schemaVersion": 1,
                "capturedOn": dt.date.today().isoformat(),
                "identity": "rule ID + relative path + enclosing declaration + normalized syntax hash",
                "entries": entries,
            },
        )
        print(f"OK: 写入 {len(entries)} 条 enforced 基线：{BASELINE_PATH.relative_to(ROOT)}")
        return 0

    baseline = load_baseline()
    known = {entry["fingerprint"] for entry in baseline.get("entries", [])}
    new_enforced = [item for item in enforced if fingerprint(item) not in known]

    for item in new_enforced:
        print_diagnostic(item, rules[item["ruleID"]])
    if reports and arguments.show_reports:
        print(f"REPORT: {len(reports)} 条观察项（不阻断）")
        for item in reports:
            print_diagnostic(item, rules[item["ruleID"]])

    if new_enforced:
        print(
            f"FAIL: {len(new_enforced)} 条新增 enforced 设计违规；"
            f"已识别 {len(enforced) - len(new_enforced)} 条历史基线。"
        )
        return 1

    print(
        f"OK: {mode} 范围 {len(paths)} 个 Swift 文件无新增 enforced 违规；"
        f"历史基线命中 {len(enforced)} 条，观察项 {len(reports)} 条。"
    )
    return 0


def context_command(arguments: argparse.Namespace) -> int:
    policy = load_json(POLICY_PATH)
    catalog = load_json(CATALOG_PATH)
    paths = unique_ordered(arguments.paths)
    component_layers = sorted({
        layer
        for path in paths
        for layer in relevant_component_layers(path)
    })
    required_entry_points = [
        "xmnote/Utilities/DesignSystem/AppTypography.swift",
        "xmnote/Utilities/DesignSystem/SemanticColors.swift",
        "xmnote/Utilities/DesignSystem/Spacing.swift",
        "xmnote/Utilities/DesignSystem/CornerRadius.swift",
        "xmnote/Utilities/DesignSystem/InteractionMetrics.swift",
    ]
    if "settings" in component_layers:
        required_entry_points += [
            "xmnote/UIComponents/Settings/XMSettingsPage.swift",
            "xmnote/UIComponents/Settings/XMSettingsSection.swift",
            "xmnote/UIComponents/Settings/XMSettingsGroup.swift",
            "xmnote/UIComponents/Settings/XMSettingsRows.swift",
        ]
    if "sheet" in component_layers:
        required_entry_points.append("xmnote/UIComponents/Sheet/XMSheetScaffold.swift")
    required_entry_points += [
        "scripts/design-system/policy.json",
        "scripts/design-system/component-catalog.json",
    ]
    payload = {
        "paths": [
            {
                "path": path,
                "inLintScope": is_in_scope(path, policy),
                "layer": infer_layer(path),
            }
            for path in paths
        ],
        "componentLayers": component_layers,
        "requiredDesignEntryPoints": required_entry_points,
        "nearbyComponents": [
            component
            for component in catalog["components"]
            if component["layer"] in component_layers
        ],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def infer_layer(path: str) -> str:
    if "/Domain/" in path:
        return "domain"
    if "/UIComponents/" in path:
        return "component"
    if "/Views/Personal/" in path:
        return "settings"
    if "/Views/" in path:
        return "feature"
    if "/Utilities/" in path:
        return "foundation"
    return "unknown"


def relevant_component_layers(path: str) -> set[str]:
    layers = {infer_layer(path)}
    if path.startswith("xmnote/Views/"):
        layers.update({"feedback", "navigation"})
    if "/Sheets/" in path or Path(path).stem.endswith("Sheet"):
        layers.add("sheet")
    if any(segment in path for segment in ("/Book/", "/Content/", "/Note/")):
        layers.add("media")
    return layers


def catalog_command(arguments: argparse.Namespace) -> int:
    catalog = load_json(CATALOG_PATH)
    components = catalog["components"]
    if arguments.symbol:
        query = arguments.symbol.casefold()
        components = [
            component
            for component in components
            if query in component["symbol"].casefold()
        ]
    print(json.dumps(components, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if components else 1


def explain_command(arguments: argparse.Namespace) -> int:
    rules = policy_rules(load_json(POLICY_PATH))
    rule = rules.get(arguments.rule_id)
    if rule is None:
        print(f"ERROR: 未知规则 {arguments.rule_id}", file=sys.stderr)
        return 1
    print(json.dumps(rule, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def audit_catalog() -> list[str]:
    errors: list[str] = []
    catalog = load_json(CATALOG_PATH)
    components = catalog.get("components")
    if not isinstance(components, list):
        return ["组件目录缺少 components 数组"]

    required_keys = {"symbol", "path", "layer", "useWhen"}
    allowed_layers = {"feedback", "media", "navigation", "settings", "sheet"}
    seen_symbols: set[str] = set()
    for index, component in enumerate(components):
        if not isinstance(component, dict):
            errors.append(f"组件目录第 {index + 1} 项不是对象")
            continue
        missing_keys = sorted(required_keys - set(component))
        if missing_keys:
            errors.append(
                f"组件目录第 {index + 1} 项缺少字段：{', '.join(missing_keys)}"
            )
            continue
        symbol = component["symbol"]
        if not all(isinstance(component[key], str) and component[key].strip() for key in required_keys):
            errors.append(f"组件目录第 {index + 1} 项包含空值或非字符串字段")
            continue
        if component["layer"] not in allowed_layers:
            errors.append(f"组件层级无效：{symbol} -> {component['layer']}")
        path = ROOT / component["path"]
        if symbol in seen_symbols:
            errors.append(f"重复组件 symbol：{symbol}")
        seen_symbols.add(symbol)
        if not path.is_file():
            errors.append(f"组件路径不存在：{component['path']}")
            continue
        source = path.read_text(encoding="utf-8")
        if re.search(rf"\b{re.escape(symbol)}\b", source) is None:
            errors.append(f"组件路径中未找到 symbol：{symbol} -> {component['path']}")
    return errors


def audit_command(arguments: argparse.Namespace) -> int:
    catalog_errors = audit_catalog()
    for error in catalog_errors:
        print(f"ERROR: {error}")
    lint_arguments = argparse.Namespace(
        all=True,
        staged=False,
        write_baseline=False,
        show_reports=arguments.show_reports,
    )
    lint_status = lint_command(lint_arguments)
    if catalog_errors or lint_status != 0:
        return 1
    print("OK: 组件目录与全量设计规则审计通过。")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ds.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    context_parser = subparsers.add_parser("context", help="给定路径返回规范与组件上下文")
    context_parser.add_argument("--paths", nargs="+", required=True)
    context_parser.set_defaults(handler=context_command)

    lint_parser = subparsers.add_parser("lint", help="运行 AST 设计规则")
    lint_scope = lint_parser.add_mutually_exclusive_group()
    lint_scope.add_argument("--changed", action="store_true", help="扫描工作区变更（默认）")
    lint_scope.add_argument("--staged", action="store_true", help="扫描暂存路径")
    lint_scope.add_argument("--all", action="store_true", help="扫描全部生产 Swift 源码")
    lint_parser.add_argument("--write-baseline", action="store_true")
    lint_parser.add_argument("--show-reports", action="store_true")
    lint_parser.set_defaults(handler=lint_command)

    catalog_parser = subparsers.add_parser("catalog", help="查询可复用组件的唯一入口")
    catalog_parser.add_argument("--symbol")
    catalog_parser.set_defaults(handler=catalog_command)

    audit_parser = subparsers.add_parser("audit", help="审计全量规则与组件目录")
    audit_parser.add_argument("--show-reports", action="store_true")
    audit_parser.set_defaults(handler=audit_command)

    explain_parser = subparsers.add_parser("explain", help="解释规则与正确实现入口")
    explain_parser.add_argument("rule_id")
    explain_parser.set_defaults(handler=explain_command)
    return parser


def main() -> int:
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    arguments = build_parser().parse_args()
    return arguments.handler(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
