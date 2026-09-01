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


def git_text(*arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


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


def changed_line_map(mode: str, paths: list[str]) -> dict[str, set[int] | None]:
    """Returns changed new-file lines; ``None`` means the whole file is current scope."""
    if mode == "all" or not paths:
        return {path: None for path in paths}

    line_map: dict[str, set[int] | None] = {path: set() for path in paths}
    untracked: set[str] = set()
    if mode == "changed":
        untracked = set(git_output("ls-files", "--others", "--exclude-standard"))
        for path in paths:
            if path in untracked:
                line_map[path] = None

    tracked_paths = [path for path in paths if path not in untracked]
    if not tracked_paths:
        return line_map

    arguments = ["diff"]
    if mode == "staged":
        arguments.append("--cached")
    else:
        arguments.append("HEAD")
    arguments += ["--unified=0", "--no-color", "--no-ext-diff", "--", *tracked_paths]
    diff = git_text(*arguments)

    current_path: str | None = None
    hunk_pattern = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
    for line in diff.splitlines():
        if line.startswith("+++ "):
            marker = line[4:]
            if marker == "/dev/null":
                current_path = None
            elif marker.startswith("b/"):
                current_path = marker[2:]
            else:
                current_path = marker
            continue
        match = hunk_pattern.match(line)
        if match is None or current_path not in line_map or line_map[current_path] is None:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        line_map[current_path].update(range(start, start + count))

    return line_map


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
                "--policy",
                str(POLICY_PATH),
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
    if disposition := diagnostic.get("reportDisposition"):
        print(f"  观察分类：{disposition} · {diagnostic.get('reportGroup', 'ungrouped')}")


def scoped_reports(
    reports: list[dict[str, Any]],
    mode: str,
    paths: list[str],
) -> list[dict[str, Any]]:
    line_map = changed_line_map(mode, paths)
    scoped: list[dict[str, Any]] = []
    for report in reports:
        item = dict(report)
        disposition = item.get("reportDisposition", "candidate")
        if disposition == "candidate" and mode != "all":
            changed_lines = line_map.get(item["path"], set())
            if changed_lines is not None and item["line"] not in changed_lines:
                disposition = "inventory"
        item["reportDisposition"] = disposition
        item.setdefault("reportGroup", f"{item['ruleID']}|ungrouped")
        scoped.append(item)
    return scoped


def print_report_summary(
    reports: list[dict[str, Any]],
    rules: dict[str, dict[str, Any]],
) -> None:
    for rule_id in sorted({item["ruleID"] for item in reports}):
        items = [item for item in reports if item["ruleID"] == rule_id]
        inventory_count = sum(item["reportDisposition"] == "inventory" for item in items)
        candidate_count = sum(item["reportDisposition"] == "candidate" for item in items)
        group_count = len({item["reportGroup"] for item in items})
        print(
            f"REPORT: {rule_id} {rules[rule_id]['title']} · "
            f"库存 {inventory_count} · 候选 {candidate_count} · 分组 {group_count}"
        )


def print_actionable_reports(
    reports: list[dict[str, Any]],
    rules: dict[str, dict[str, Any]],
) -> None:
    candidates = [item for item in reports if item["reportDisposition"] == "candidate"]
    groups: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for item in candidates:
        key = (item["ruleID"], item["path"], item["declaration"])
        groups.setdefault(key, []).append(item)

    if not groups:
        print("ACTIONABLE: 当前范围无软观察候选。")
        return

    print(f"ACTIONABLE: {len(groups)} 个 owner，共 {len(candidates)} 条软观察候选。")
    for (rule_id, path, declaration), items in sorted(groups.items()):
        lines = sorted({item["line"] for item in items})
        line_text = ", ".join(str(line) for line in lines)
        print(
            f"{path}:{lines[0]}: {rule_id} {rules[rule_id]['title']} · "
            f"{declaration}（{len(items)} 条）"
        )
        print(f"  行：{line_text}")
        print(f"  正确入口：{rules[rule_id]['correctPath']}")


def print_reports(
    reports: list[dict[str, Any]],
    rules: dict[str, dict[str, Any]],
    report_mode: str,
) -> None:
    if not reports:
        print("REPORT: 当前范围无观察项。")
        return
    print_report_summary(reports, rules)
    if report_mode == "actionable":
        print_actionable_reports(reports, rules)
    elif report_mode == "all":
        print(f"REPORT-ALL: 完整展开 {len(reports)} 条观察项（不阻断）。")
        for item in reports:
            print_diagnostic(item, rules[item["ruleID"]])


def requested_report_mode(arguments: argparse.Namespace) -> str:
    if getattr(arguments, "show_reports", False):
        return "all"
    return getattr(arguments, "reports", "actionable")


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
    reports = scoped_reports(reports, mode, paths)
    report_mode = requested_report_mode(arguments)

    for item in new_enforced:
        print_diagnostic(item, rules[item["ruleID"]])
    print_reports(reports, rules, report_mode)

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


def allowed_low_level_entry_points(path: str, policy: dict[str, Any]) -> list[dict[str, Any]]:
    permissions: list[dict[str, Any]] = []
    for name, construction_policy in policy.get("constructionPolicies", {}).items():
        if path in construction_policy.get("allowedPaths", []):
            permissions.append(
                {
                    "name": name,
                    "ruleID": construction_policy["ruleID"],
                    "entryPoints": construction_policy["entryPoints"],
                }
            )
    for symbol_policy in policy.get("symbolPolicies", []):
        if path in symbol_policy.get("allowedPaths", []):
            permissions.append(
                {
                    "name": symbol_policy["name"],
                    "ruleID": symbol_policy["ruleID"],
                    "entryPoints": symbol_policy["symbols"],
                }
            )
    return sorted(permissions, key=lambda item: item["name"])


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
        "xmnote/Utilities/DesignSystem/StrokeWidth.swift",
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
                "allowedLowLevelEntryPoints": allowed_low_level_entry_points(path, policy),
            }
            for path in paths
        ],
        "componentLayers": component_layers,
        "requiredDesignEntryPoints": required_entry_points,
        "nearbyComponents": [
            catalog_display_entry(component)
            for component in catalog["components"]
            if component["status"] == "canonical"
            and component["layer"] in component_layers
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


def catalog_display_entry(component: dict[str, Any]) -> dict[str, Any]:
    """Returns the compact, backward-readable component discovery payload."""
    return {
        "symbol": component["symbols"][0],
        "symbols": component["symbols"],
        "path": component["path"],
        "category": component["category"],
        "layer": component["layer"],
        "status": component["status"],
        "framework": component["framework"],
        "usageScope": component["usageScope"],
        "stateCoverage": component["stateCoverage"],
        "dependencies": component["dependencies"],
        "useWhen": component["useWhen"],
        "avoidWhen": component["avoidWhen"],
        "previewPolicy": component["previewPolicy"],
    }


def catalog_command(arguments: argparse.Namespace) -> int:
    catalog = load_json(CATALOG_PATH)
    components = catalog["components"]
    if not arguments.all:
        components = [
            component for component in components if component["status"] == "canonical"
        ]
    if arguments.symbol:
        query = arguments.symbol.casefold()
        components = [
            component
            for component in components
            if any(query in symbol.casefold() for symbol in component["symbols"])
        ]
    print(
        json.dumps(
            [catalog_display_entry(component) for component in components],
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
    )
    return 0 if components else 1


def explain_command(arguments: argparse.Namespace) -> int:
    rules = policy_rules(load_json(POLICY_PATH))
    rule = rules.get(arguments.rule_id)
    if rule is None:
        print(f"ERROR: 未知规则 {arguments.rule_id}", file=sys.stderr)
        return 1
    print(json.dumps(rule, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def audit_policy(policy: dict[str, Any] | None = None) -> list[str]:
    errors: list[str] = []
    policy = policy if policy is not None else load_json(POLICY_PATH)

    if policy.get("schemaVersion") != 4:
        errors.append("设计系统 policy schemaVersion 必须为 4")

    rules = policy.get("rules")
    if not isinstance(rules, list):
        return errors + ["设计系统 policy 缺少 rules 数组"]
    registered_rule_ids = {
        rule.get("id")
        for rule in rules
        if isinstance(rule, dict) and isinstance(rule.get("id"), str)
    }
    registered_rule_enforcements = {
        rule.get("id"): rule.get("enforcement")
        for rule in rules
        if isinstance(rule, dict) and isinstance(rule.get("id"), str)
    }

    def validate_owner_policy(
        name: str,
        owner_policy: Any,
        entry_key: str,
    ) -> None:
        if not isinstance(owner_policy, dict):
            errors.append(f"owner policy 不是对象：{name}")
            return
        rule_id = owner_policy.get("ruleID")
        if rule_id not in registered_rule_ids:
            errors.append(f"owner policy 使用未知规则：{name} -> {rule_id}")

        entry_points = owner_policy.get(entry_key)
        if not isinstance(entry_points, list) or not entry_points or not all(
            isinstance(item, str) and item.strip() for item in entry_points
        ):
            errors.append(f"owner policy 缺少有效 {entry_key}：{name}")

        allowed_paths = owner_policy.get("allowedPaths")
        if not isinstance(allowed_paths, list) or not all(
            isinstance(item, str) and item.strip() for item in allowed_paths
        ):
            errors.append(f"owner policy 缺少有效 allowedPaths：{name}")
            return
        for path in allowed_paths:
            if any(character in path for character in "*?["):
                errors.append(f"owner path 必须是精确文件路径：{name} -> {path}")
                continue
            if not (ROOT / path).is_file():
                errors.append(f"owner path 不存在：{name} -> {path}")

    construction_policies = policy.get("constructionPolicies")
    if not isinstance(construction_policies, dict):
        errors.append("设计系统 policy 缺少 constructionPolicies 对象")
    else:
        required_construction_policies = {"rawColor", "rawTypography"}
        missing = sorted(required_construction_policies - set(construction_policies))
        if missing:
            errors.append(f"constructionPolicies 缺少：{', '.join(missing)}")
        for name, construction_policy in construction_policies.items():
            validate_owner_policy(name, construction_policy, "entryPoints")

    symbol_policies = policy.get("symbolPolicies")
    if not isinstance(symbol_policies, list):
        errors.append("设计系统 policy 缺少 symbolPolicies 数组")
        return errors

    seen_policy_names: set[str] = set()
    seen_symbols: dict[str, str] = {}
    for index, symbol_policy in enumerate(symbol_policies):
        name = (
            symbol_policy.get("name")
            if isinstance(symbol_policy, dict)
            else f"第 {index + 1} 项"
        )
        if not isinstance(name, str) or not name.strip():
            errors.append(f"symbol policy 第 {index + 1} 项缺少有效 name")
            name = f"第 {index + 1} 项"
        elif name in seen_policy_names:
            errors.append(f"重复 symbol policy name：{name}")
        seen_policy_names.add(name)

        validate_owner_policy(name, symbol_policy, "symbols")
        if not isinstance(symbol_policy, dict):
            continue
        replacement = symbol_policy.get("replacement")
        if not isinstance(replacement, str) or not replacement.strip():
            errors.append(f"symbol policy 缺少 replacement：{name}")
        match_inferred = symbol_policy.get("matchInferred")
        if match_inferred is not None and not isinstance(match_inferred, bool):
            errors.append(f"symbol policy 的 matchInferred 必须是布尔值：{name}")
        symbols = symbol_policy.get("symbols")
        if not isinstance(symbols, list):
            continue
        for symbol in symbols:
            if not isinstance(symbol, str):
                continue
            previous_owner = seen_symbols.get(symbol)
            if previous_owner is not None:
                errors.append(f"重复受限 symbol：{symbol} -> {previous_owner}, {name}")
            else:
                seen_symbols[symbol] = name

    dependency_policies = policy.get("dependencyPolicies")
    if not isinstance(dependency_policies, list) or not dependency_policies:
        errors.append("设计系统 policy 缺少 dependencyPolicies 数组")
    else:
        for index, dependency_policy in enumerate(dependency_policies):
            name = (
                dependency_policy.get("name")
                if isinstance(dependency_policy, dict)
                else f"第 {index + 1} 项"
            )
            if not isinstance(dependency_policy, dict):
                errors.append(f"dependency policy 不是对象：{name}")
                continue
            if dependency_policy.get("ruleID") not in registered_rule_ids:
                errors.append(
                    f"dependency policy 使用未知规则：{name} -> "
                    f"{dependency_policy.get('ruleID')}"
                )
            for key in (
                "pathPrefixes",
                "forbiddenExactIdentifiers",
                "forbiddenIdentifierSuffixes",
            ):
                values = dependency_policy.get(key)
                if not isinstance(values, list) or not values or not all(
                    isinstance(item, str) and item.strip() for item in values
                ):
                    errors.append(f"dependency policy 缺少有效 {key}：{name}")

    interaction_policy = policy.get("interactionPolicy")
    if not isinstance(interaction_policy, dict):
        errors.append("设计系统 policy 缺少 interactionPolicy 对象")
    else:
        for key in ("tapGestureRuleID", "touchTargetRuleID"):
            if interaction_policy.get(key) not in registered_rule_ids:
                errors.append(
                    f"interactionPolicy 使用未知规则：{key} -> "
                    f"{interaction_policy.get(key)}"
                )
        owner_path = interaction_policy.get("touchTargetOwnerPath")
        if not isinstance(owner_path, str) or not owner_path.strip():
            errors.append("interactionPolicy 缺少 touchTargetOwnerPath")
        elif any(character in owner_path for character in "*?["):
            errors.append("touchTargetOwnerPath 必须是精确文件路径")
        elif not (ROOT / owner_path).is_file():
            errors.append(f"touchTargetOwnerPath 不存在：{owner_path}")
        literal = interaction_policy.get("touchTargetLiteral")
        if not isinstance(literal, (int, float)) or literal != 44:
            errors.append("interactionPolicy touchTargetLiteral 必须为 44")
        fragments = interaction_policy.get("touchTargetNameFragments")
        if not isinstance(fragments, list) or not fragments or not all(
            isinstance(item, str) and item.strip() for item in fragments
        ):
            errors.append("interactionPolicy 缺少有效 touchTargetNameFragments")
        exceptions = interaction_policy.get("gestureExceptions")
        if not isinstance(exceptions, list):
            errors.append("interactionPolicy gestureExceptions 必须是数组")
        else:
            required_exception_keys = {
                "path",
                "declaration",
                "reason",
                "owner",
                "accessibilityAlternative",
                "visualFreezeRationale",
            }
            seen_exception_anchors: set[tuple[str, str]] = set()
            for index, exception in enumerate(exceptions):
                if not isinstance(exception, dict):
                    errors.append(f"gesture exception 第 {index + 1} 项不是对象")
                    continue
                missing = sorted(required_exception_keys - set(exception))
                if missing:
                    errors.append(
                        f"gesture exception 第 {index + 1} 项缺少字段：{', '.join(missing)}"
                    )
                    continue
                if not all(
                    isinstance(exception[key], str) and exception[key].strip()
                    for key in required_exception_keys
                ):
                    errors.append(f"gesture exception 第 {index + 1} 项包含空值")
                    continue
                exception_path = exception["path"]
                declaration = exception["declaration"]
                if any(character in exception_path for character in "*?["):
                    errors.append(f"gesture exception 必须使用精确路径：{exception_path}")
                    continue
                source_path = ROOT / exception_path
                if not source_path.is_file():
                    errors.append(f"gesture exception 路径不存在：{exception_path}")
                    continue
                anchor = (exception_path, declaration)
                if anchor in seen_exception_anchors:
                    errors.append(
                        f"重复 gesture exception：{exception_path} -> {declaration}"
                    )
                seen_exception_anchors.add(anchor)
                source = source_path.read_text(encoding="utf-8")
                owner, separator, member = declaration.rpartition(".")
                owner_pattern = rf"\b(?:struct|class|enum|actor|extension)\s+{re.escape(owner)}\b"
                member_pattern = rf"\b(?:var\s+|func\s+){re.escape(member)}\b"
                if (
                    not separator
                    or re.search(owner_pattern, source) is None
                    or re.search(member_pattern, source) is None
                    or ".onTapGesture" not in source
                ):
                    errors.append(
                        f"gesture exception 声明锚点失效：{exception_path} -> {declaration}"
                    )

    button_color_policy = policy.get("buttonColorPolicy")
    if not isinstance(button_color_policy, dict):
        errors.append("设计系统 policy 缺少 buttonColorPolicy 对象")
    else:
        button_rule_id = button_color_policy.get("ruleID")
        if button_rule_id not in registered_rule_ids:
            errors.append(
                f"buttonColorPolicy 使用未知规则：{button_rule_id}"
            )
        elif registered_rule_enforcements.get(button_rule_id) != "report":
            errors.append("buttonColorPolicy 必须使用 report 规则")

        list_keys = (
            "borderedStyleNames",
            "prominentStyleNames",
            "brandDerivedColorSymbols",
            "neutralColorSymbols",
            "feedbackColorSymbols",
        )
        validated_lists: dict[str, list[str]] = {}
        for key in list_keys:
            values = button_color_policy.get(key)
            if not isinstance(values, list) or not values or not all(
                isinstance(item, str) and item.strip() for item in values
            ):
                errors.append(f"buttonColorPolicy 缺少有效 {key}")
                continue
            if len(values) != len(set(values)):
                errors.append(f"buttonColorPolicy {key} 包含重复项")
            validated_lists[key] = values

        bordered_styles = set(validated_lists.get("borderedStyleNames", []))
        prominent_styles = set(validated_lists.get("prominentStyleNames", []))
        if "bordered" not in bordered_styles:
            errors.append("buttonColorPolicy borderedStyleNames 必须包含 bordered")
        if "borderedProminent" not in prominent_styles:
            errors.append(
                "buttonColorPolicy prominentStyleNames 必须包含 borderedProminent"
            )
        if bordered_styles & prominent_styles:
            errors.append("buttonColorPolicy 的普通与突出样式分类不得重叠")

        color_categories = {
            key: set(validated_lists.get(key, []))
            for key in (
                "brandDerivedColorSymbols",
                "neutralColorSymbols",
                "feedbackColorSymbols",
            )
        }
        color_owners: dict[str, str] = {}
        for category, symbols in color_categories.items():
            for symbol in symbols:
                previous_category = color_owners.get(symbol)
                if previous_category is not None:
                    errors.append(
                        "buttonColorPolicy 颜色分类重复："
                        f"{symbol} -> {previous_category}, {category}"
                    )
                else:
                    color_owners[symbol] = category

        expected_contrast = {
            "normalTextMinimumContrast": 4.5,
            "largeTextMinimumContrast": 3.0,
            "essentialGlyphMinimumContrast": 3.0,
        }
        for key, expected in expected_contrast.items():
            value = button_color_policy.get(key)
            if not isinstance(value, (int, float)) or value != expected:
                errors.append(
                    f"buttonColorPolicy {key} 必须为 {expected:g}"
                )

    catalog_policy = policy.get("componentCatalogPolicy")
    if not isinstance(catalog_policy, dict):
        errors.append("设计系统 policy 缺少 componentCatalogPolicy 对象")
    else:
        if catalog_policy.get("ruleID") not in registered_rule_ids:
            errors.append(
                f"componentCatalogPolicy 使用未知规则：{catalog_policy.get('ruleID')}"
            )
        catalog_root = catalog_policy.get("root")
        if not isinstance(catalog_root, str) or not (ROOT / catalog_root).is_dir():
            errors.append(f"componentCatalogPolicy root 不存在：{catalog_root}")
        layer_directories = catalog_policy.get("layerDirectories")
        if not isinstance(layer_directories, dict) or not layer_directories:
            errors.append("componentCatalogPolicy 缺少 layerDirectories")
        else:
            for layer, directories in layer_directories.items():
                if not isinstance(layer, str) or not isinstance(directories, list) or not directories:
                    errors.append(f"componentCatalogPolicy 层级目录无效：{layer}")
                    continue
                if not all(isinstance(item, str) and item.strip() for item in directories):
                    errors.append(f"componentCatalogPolicy 层级目录包含空值：{layer}")
        path_exceptions = catalog_policy.get("layerPathExceptions")
        if not isinstance(path_exceptions, list):
            errors.append("componentCatalogPolicy layerPathExceptions 必须是数组")
        else:
            for exception in path_exceptions:
                if not isinstance(exception, dict):
                    errors.append("component catalog path exception 不是对象")
                    continue
                exception_path = exception.get("path")
                if not isinstance(exception_path, str) or not (ROOT / exception_path).is_file():
                    errors.append(
                        f"component catalog path exception 路径不存在：{exception_path}"
                    )
                if not isinstance(exception.get("layer"), str):
                    errors.append(
                        f"component catalog path exception 缺少 layer：{exception_path}"
                    )
                if not isinstance(exception.get("reason"), str) or not exception["reason"].strip():
                    errors.append(
                        f"component catalog path exception 缺少 reason：{exception_path}"
                    )

    return errors


def audit_catalog(catalog: dict[str, Any] | None = None) -> list[str]:
    """Validates schema and anchors; coverage debt is reported separately by DS011."""
    errors: list[str] = []
    catalog = catalog if catalog is not None else load_json(CATALOG_PATH)
    if catalog.get("schemaVersion") != 3:
        errors.append("组件目录 schemaVersion 必须为 3")
    components = catalog.get("components")
    if not isinstance(components, list):
        return errors + ["组件目录缺少 components 数组"]

    required_keys = {
        "path",
        "symbols",
        "status",
        "category",
        "layer",
        "framework",
        "usageScope",
        "stateCoverage",
        "dependencies",
        "useWhen",
        "avoidWhen",
        "previewPolicy",
        "guidePath",
    }
    allowed_statuses = {"canonical", "support"}
    allowed_frameworks = {"swiftui", "uikit", "bridge", "value"}
    allowed_categories = {
        "foundationVisual",
        "formInteraction",
        "layout",
        "business",
        "pageLevel",
        "designInfrastructure",
    }
    allowed_usage_scopes = {
        "crossFeature",
        "featureFamily",
        "appShell",
        "internalSupport",
    }
    allowed_states = {
        "normal",
        "pressed",
        "focused",
        "selected",
        "disabled",
        "loading",
        "error",
        "empty",
        "expanded",
        "editing",
        "dragging",
        "readOnly",
    }
    policy = load_json(POLICY_PATH)
    allowed_layers = set(
        policy.get("componentCatalogPolicy", {}).get("layerDirectories", {})
    )
    seen_symbols: set[str] = set()
    seen_path_status: set[tuple[str, str]] = set()
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
        scalar_keys = {
            "path",
            "status",
            "category",
            "layer",
            "framework",
            "usageScope",
            "useWhen",
            "avoidWhen",
        }
        if not all(
            isinstance(component[key], str) and component[key].strip()
            for key in scalar_keys
        ):
            errors.append(f"组件目录第 {index + 1} 项包含空值或非字符串字段")
            continue
        symbols = component["symbols"]
        if not isinstance(symbols, list) or not symbols or not all(
            isinstance(symbol, str) and symbol.strip() for symbol in symbols
        ):
            errors.append(f"组件目录第 {index + 1} 项缺少有效 symbols")
            continue
        dependencies = component["dependencies"]
        if not isinstance(dependencies, list) or not all(
            isinstance(dependency, str) and dependency.strip() for dependency in dependencies
        ):
            errors.append(f"组件目录第 {index + 1} 项 dependencies 无效")
        state_coverage = component["stateCoverage"]
        if not isinstance(state_coverage, list) or not all(
            isinstance(state, str) and state in allowed_states
            for state in state_coverage
        ):
            errors.append(f"组件状态覆盖无效：{symbols[0]}")
        elif len(state_coverage) != len(set(state_coverage)):
            errors.append(f"组件状态覆盖存在重复值：{symbols[0]}")
        if component["status"] not in allowed_statuses:
            errors.append(
                f"组件状态无效：{symbols[0]} -> {component['status']}"
            )
        if component["framework"] not in allowed_frameworks:
            errors.append(
                f"组件框架边界无效：{symbols[0]} -> {component['framework']}"
            )
        if component["category"] not in allowed_categories:
            errors.append(
                f"组件类别无效：{symbols[0]} -> {component['category']}"
            )
        if component["usageScope"] not in allowed_usage_scopes:
            errors.append(
                f"组件复用范围无效：{symbols[0]} -> {component['usageScope']}"
            )
        if component["status"] == "support" and component["usageScope"] != "internalSupport":
            errors.append(f"support 组件必须标记 internalSupport：{symbols[0]}")
        if (
            component["status"] == "canonical"
            and component["framework"] != "value"
            and "normal" not in state_coverage
        ):
            errors.append(f"可视 canonical 组件缺少 normal 状态：{symbols[0]}")
        if component["layer"] not in allowed_layers:
            errors.append(f"组件层级无效：{symbols[0]} -> {component['layer']}")
        preview_policy = component["previewPolicy"]
        if not isinstance(preview_policy, dict):
            errors.append(f"组件 Preview 策略不是对象：{symbols[0]}")
        else:
            preview_kind = preview_policy.get("kind")
            if preview_kind not in {"required", "hosted", "notApplicable"}:
                errors.append(f"组件 Preview 策略无效：{symbols[0]} -> {preview_kind}")
            preview_path = preview_policy.get("path")
            if preview_kind in {"required", "hosted"}:
                if not isinstance(preview_path, str) or not preview_path.strip():
                    errors.append(f"组件 Preview 策略缺少 path：{symbols[0]}")
                elif not (ROOT / preview_path).is_file():
                    errors.append(f"组件 Preview 路径不存在：{symbols[0]} -> {preview_path}")
                elif preview_kind == "required" and preview_path != component["path"]:
                    errors.append(f"本地 Preview 必须位于组件文件：{symbols[0]}")
                elif preview_kind == "hosted" and not preview_path.startswith("xmnote/Views/Debug/"):
                    errors.append(f"hosted Preview 必须位于 Debug：{symbols[0]} -> {preview_path}")
                elif preview_kind == "hosted":
                    host_source = (ROOT / preview_path).read_text(encoding="utf-8")
                    if not any(symbol in host_source for symbol in symbols):
                        errors.append(
                            f"Debug 宿主未引用组件 symbol：{symbols[0]} -> {preview_path}"
                        )
            if preview_kind in {"hosted", "notApplicable"} and (
                not isinstance(preview_policy.get("reason"), str)
                or not preview_policy["reason"].strip()
            ):
                errors.append(f"组件 Preview 策略缺少 reason：{symbols[0]}")
            if component["status"] == "canonical" and preview_kind == "notApplicable":
                errors.append(f"canonical 组件必须提供本地 Preview 或 Debug 宿主：{symbols[0]}")
            if component["status"] == "support" and preview_kind != "notApplicable":
                errors.append(f"support 文件应由 canonical 入口间接验证：{symbols[0]}")
        guide_path = component["guidePath"]
        if guide_path is not None:
            if not isinstance(guide_path, str) or not guide_path.strip():
                errors.append(f"组件 guidePath 无效：{symbols[0]}")
            elif not (ROOT / guide_path).is_file():
                errors.append(f"组件指南不存在：{symbols[0]} -> {guide_path}")

        component_path = component["path"]
        path = ROOT / component_path
        path_status = (component_path, component["status"])
        if path_status in seen_path_status and component["status"] == "support":
            errors.append(f"重复 support 文件登记：{component_path}")
        seen_path_status.add(path_status)
        if not path.is_file():
            errors.append(f"组件路径不存在：{component_path}")
            continue
        source = path.read_text(encoding="utf-8")
        for symbol in symbols:
            if symbol in seen_symbols:
                errors.append(f"重复组件 symbol：{symbol}")
            seen_symbols.add(symbol)
            if re.search(rf"\b{re.escape(symbol)}\b", source) is None:
                errors.append(f"组件路径中未找到 symbol：{symbol} -> {component_path}")
    return errors


def catalog_coverage_findings(
    catalog: dict[str, Any] | None = None,
    policy: dict[str, Any] | None = None,
) -> list[str]:
    """Returns DS011 migration candidates without treating report-mode debt as schema errors."""
    catalog = catalog if catalog is not None else load_json(CATALOG_PATH)
    policy = policy if policy is not None else load_json(POLICY_PATH)
    catalog_policy = policy["componentCatalogPolicy"]
    catalog_root = ROOT / catalog_policy["root"]
    excluded_fragments = catalog_policy.get("excludedPathFragments", [])
    components = catalog.get("components", [])
    cataloged_paths = {
        component["path"]
        for component in components
        if isinstance(component, dict) and isinstance(component.get("path"), str)
    }
    swift_paths = {
        path.relative_to(ROOT).as_posix()
        for path in catalog_root.rglob("*.swift")
        if not any(fragment in f"/{path.relative_to(ROOT).as_posix()}" for fragment in excluded_fragments)
    }
    findings = [
        f"未登记 UIComponents 文件：{path}"
        for path in sorted(swift_paths - cataloged_paths)
    ]

    layer_directories = catalog_policy["layerDirectories"]
    exceptions = {
        (item["path"], item["layer"])
        for item in catalog_policy.get("layerPathExceptions", [])
        if isinstance(item, dict) and "path" in item and "layer" in item
    }
    root_prefix = f"{catalog_policy['root'].rstrip('/')}/"
    for component in components:
        if not isinstance(component, dict):
            continue
        component_path = component.get("path")
        layer = component.get("layer")
        if not isinstance(component_path, str) or not isinstance(layer, str):
            continue
        if (component_path, layer) in exceptions:
            continue
        relative_path = component_path.removeprefix(root_prefix)
        directories = layer_directories.get(layer, [])
        if not any(relative_path.startswith(directory) for directory in directories):
            findings.append(
                f"组件层级与目录不一致：{component_path} -> {layer}"
            )
        preview_policy = component.get("previewPolicy")
        if not isinstance(preview_policy, dict):
            continue
        preview_kind = preview_policy.get("kind")
        preview_path = preview_policy.get("path")
        if preview_kind == "required" and isinstance(preview_path, str):
            source = (ROOT / preview_path).read_text(encoding="utf-8")
            if "#Preview" not in source:
                findings.append(
                    f"必需 Preview 尚未实现：{component['symbols'][0]} -> {preview_path}"
                )
    return findings


def audit_command(arguments: argparse.Namespace) -> int:
    policy = load_json(POLICY_PATH)
    policy_errors = audit_policy(policy)
    catalog_errors = audit_catalog()
    coverage_findings = catalog_coverage_findings(policy=policy)
    catalog_rule = policy_rules(policy)[policy["componentCatalogPolicy"]["ruleID"]]
    if catalog_rule["enforcement"] == "enforced":
        catalog_errors += coverage_findings
    elif coverage_findings:
        grouped_findings: dict[str, int] = {}
        for finding in coverage_findings:
            group = finding.split("：", 1)[0]
            grouped_findings[group] = grouped_findings.get(group, 0) + 1
        print(
            f"REPORT: DS011 {catalog_rule['title']} · "
            f"库存 0 · 候选 {len(coverage_findings)} · 分组 {len(grouped_findings)}"
        )
        report_mode = requested_report_mode(arguments)
        if report_mode in {"actionable", "all"}:
            print(
                "ACTIONABLE: DS011 "
                + "；".join(
                    f"{group} {count} 条" for group, count in sorted(grouped_findings.items())
                )
            )
        if report_mode == "all":
            for finding in coverage_findings:
                print(f"DS011: {finding}")
    for error in policy_errors:
        print(f"ERROR: {error}")
    for error in catalog_errors:
        print(f"ERROR: {error}")
    if policy_errors:
        return 1
    lint_arguments = argparse.Namespace(
        all=True,
        staged=False,
        write_baseline=False,
        show_reports=arguments.show_reports,
        reports=arguments.reports,
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
    lint_parser.add_argument(
        "--reports",
        choices=("summary", "actionable", "all"),
        default="actionable",
        help="观察项输出：仅摘要、摘要加候选（默认）或完整证据",
    )
    lint_parser.add_argument(
        "--show-reports",
        action="store_true",
        help="兼容别名，等价于 --reports all",
    )
    lint_parser.set_defaults(handler=lint_command)

    catalog_parser = subparsers.add_parser("catalog", help="查询可复用组件的唯一入口")
    catalog_parser.add_argument("--symbol")
    catalog_parser.add_argument(
        "--all",
        action="store_true",
        help="同时显示 support 类型的实现辅助条目",
    )
    catalog_parser.set_defaults(handler=catalog_command)

    audit_parser = subparsers.add_parser("audit", help="审计全量规则与组件目录")
    audit_parser.add_argument(
        "--reports",
        choices=("summary", "actionable", "all"),
        default="actionable",
        help="观察项输出：仅摘要、摘要加候选（默认）或完整证据",
    )
    audit_parser.add_argument(
        "--show-reports",
        action="store_true",
        help="兼容别名，等价于 --reports all",
    )
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
