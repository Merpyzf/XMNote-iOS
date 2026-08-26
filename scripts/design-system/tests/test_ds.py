"""Regression tests for the repository-owned design-system orchestrator."""

from __future__ import annotations

import copy
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "ds.py"
SPEC = importlib.util.spec_from_file_location("xmnote_design_system", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load design-system module at {MODULE_PATH}")
DS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DS)


class DesignSystemOrchestratorTests(unittest.TestCase):
    def test_settings_page_discovers_settings_and_common_page_layers(self) -> None:
        layers = DS.relevant_component_layers(
            "xmnote/Views/Personal/AIConfigurationView.swift"
        )

        self.assertEqual(layers, {"settings", "feedback", "navigation"})

    def test_feature_sheet_discovers_sheet_and_feature_specific_layers(self) -> None:
        layers = DS.relevant_component_layers(
            "xmnote/Views/Book/Sheets/BookCollectionCoverSearchSheet.swift"
        )

        self.assertEqual(
            layers,
            {"feature", "feedback", "media", "navigation", "sheet"},
        )

    def test_catalog_schema_and_symbol_anchors_are_valid(self) -> None:
        self.assertEqual(DS.audit_catalog(), [])

    def test_policy_schema_owner_paths_and_symbols_are_valid(self) -> None:
        self.assertEqual(DS.audit_policy(), [])

    def test_context_exposes_only_exact_owner_low_level_entry_points(self) -> None:
        policy = DS.load_json(DS.POLICY_PATH)

        semantic_permissions = DS.allowed_low_level_entry_points(
            "xmnote/Utilities/DesignSystem/SemanticColors.swift",
            policy,
        )
        similarly_named_permissions = DS.allowed_low_level_entry_points(
            "xmnote/Utilities/DesignSystem/SemanticColorsCopy.swift",
            policy,
        )
        heatmap_permissions = DS.allowed_low_level_entry_points(
            "xmnote/UIComponents/Charts/HeatmapLegend.swift",
            policy,
        )

        self.assertEqual(
            {item["name"] for item in semantic_permissions},
            {
                "baseBrandPaletteCore",
                "swiftUIColorAdaptiveConstruction",
                "swiftUIColorBridgeConstruction",
                "swiftUIColorHexConstruction",
            },
        )
        self.assertEqual(
            {item["name"] for item in heatmap_permissions},
            {
                "baseBrandPaletteCore",
                "baseBrandPaletteHeatmapExtremes",
                "swiftUIColorAdaptiveConstruction",
                "swiftUIColorHexConstruction",
            },
        )
        self.assertEqual(similarly_named_permissions, [])

    def test_context_exposes_all_foundational_design_entry_points(self) -> None:
        arguments = DS.build_parser().parse_args(
            ["context", "--paths", "xmnote/Views/Book/BookDetailView.swift"]
        )
        stream = io.StringIO()

        with redirect_stdout(stream):
            result = DS.context_command(arguments)

        payload = DS.json.loads(stream.getvalue())
        self.assertEqual(result, 0)
        self.assertIn(
            "xmnote/Utilities/DesignSystem/StrokeWidth.swift",
            payload["requiredDesignEntryPoints"],
        )

    def test_policy_audit_rejects_unknown_rule_missing_owner_and_duplicate_symbol(self) -> None:
        policy = copy.deepcopy(DS.load_json(DS.POLICY_PATH))
        policy["constructionPolicies"]["rawColor"]["allowedPaths"] = [
            "xmnote/Utilities/DesignSystem/MissingPalette.swift"
        ]
        policy["symbolPolicies"] = [
            {
                "name": "first",
                "ruleID": "DS999",
                "symbols": ["Color.xmHex"],
                "allowedPaths": [],
                "replacement": "Color.textPrimary",
                "matchInferred": "yes",
            },
            {
                "name": "second",
                "ruleID": "DS003",
                "symbols": ["Color.xmHex"],
                "allowedPaths": [],
                "replacement": "Color.textPrimary",
            },
        ]

        errors = DS.audit_policy(policy)

        self.assertTrue(any("未知规则" in error for error in errors))
        self.assertTrue(any("owner path 不存在" in error for error in errors))
        self.assertTrue(any("重复受限 symbol" in error for error in errors))
        self.assertTrue(any("matchInferred 必须是布尔值" in error for error in errors))

    def test_policy_audit_rejects_invalid_dependency_and_gesture_exception_schema(self) -> None:
        policy = copy.deepcopy(DS.load_json(DS.POLICY_PATH))
        policy["dependencyPolicies"][0]["forbiddenIdentifierSuffixes"] = []
        policy["interactionPolicy"]["gestureExceptions"] = [
            {
                "path": "xmnote/UIComponents/**/DenseControl.swift",
                "declaration": "DenseControl.body",
                "reason": "密集交互",
                "owner": "DenseControl",
                "accessibilityAlternative": "可访问性表示",
                "visualFreezeRationale": "保持视觉",
            }
        ]

        errors = DS.audit_policy(policy)

        self.assertTrue(
            any("forbiddenIdentifierSuffixes" in error for error in errors)
        )
        self.assertTrue(any("gesture exception 必须使用精确路径" in error for error in errors))

    def test_catalog_coverage_reports_missing_layer_and_preview_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            component_root = root / "xmnote/UIComponents"
            (component_root / "Foundation").mkdir(parents=True)
            (component_root / "Controls").mkdir(parents=True)
            registered = component_root / "Foundation/Registered.swift"
            missing = component_root / "Controls/Missing.swift"
            registered.write_text("struct Registered {}\n", encoding="utf-8")
            missing.write_text("struct Missing {}\n", encoding="utf-8")
            catalog = {
                "schemaVersion": 3,
                "components": [
                    {
                        "path": "xmnote/UIComponents/Foundation/Registered.swift",
                        "symbols": ["Registered"],
                        "status": "canonical",
                        "category": "foundationVisual",
                        "layer": "controls",
                        "framework": "swiftui",
                        "usageScope": "crossFeature",
                        "stateCoverage": ["normal"],
                        "dependencies": [],
                        "useWhen": "测试",
                        "avoidWhen": "非测试",
                        "previewPolicy": {
                            "kind": "required",
                            "path": "xmnote/UIComponents/Foundation/Registered.swift",
                        },
                        "guidePath": None,
                    }
                ],
            }
            policy = {
                "componentCatalogPolicy": {
                    "root": "xmnote/UIComponents",
                    "excludedPathFragments": ["/Vendor/"],
                    "layerDirectories": {
                        "foundation": ["Foundation/"],
                        "controls": ["Controls/"],
                    },
                    "layerPathExceptions": [],
                }
            }

            with mock.patch.object(DS, "ROOT", root):
                findings = DS.catalog_coverage_findings(catalog, policy)

        self.assertIn(
            "未登记 UIComponents 文件：xmnote/UIComponents/Controls/Missing.swift",
            findings,
        )
        self.assertIn(
            "组件层级与目录不一致：xmnote/UIComponents/Foundation/Registered.swift -> controls",
            findings,
        )
        self.assertIn(
            "必需 Preview 尚未实现：Registered -> xmnote/UIComponents/Foundation/Registered.swift",
            findings,
        )

    def test_catalog_command_hides_support_entries_unless_all_is_requested(self) -> None:
        components = [
            {
                "path": "xmnote/UIComponents/Foundation/Canonical.swift",
                "symbols": ["Canonical"],
                "status": "canonical",
                "category": "foundationVisual",
                "layer": "foundation",
                "framework": "swiftui",
                "usageScope": "crossFeature",
                "stateCoverage": ["normal"],
                "dependencies": ["DesignSystem"],
                "useWhen": "复用",
                "avoidWhen": "不复用",
                "previewPolicy": {
                    "kind": "required",
                    "path": "xmnote/UIComponents/Foundation/Canonical.swift",
                },
            },
            {
                "path": "xmnote/UIComponents/Foundation/Support.swift",
                "symbols": ["Support"],
                "status": "support",
                "category": "designInfrastructure",
                "layer": "foundation",
                "framework": "value",
                "usageScope": "internalSupport",
                "stateCoverage": [],
                "dependencies": [],
                "useWhen": "内部实现",
                "avoidWhen": "直接使用",
                "previewPolicy": {
                    "kind": "notApplicable",
                    "reason": "纯内部实现",
                },
            },
        ]
        outputs: dict[bool, str] = {}
        for include_all in (False, True):
            arguments = DS.build_parser().parse_args(
                ["catalog"] + (["--all"] if include_all else [])
            )
            stream = io.StringIO()
            with (
                mock.patch.object(DS, "load_json", return_value={"components": components}),
                redirect_stdout(stream),
            ):
                status = DS.catalog_command(arguments)
            self.assertEqual(status, 0)
            outputs[include_all] = stream.getvalue()

        self.assertIn("Canonical", outputs[False])
        self.assertNotIn("Support", outputs[False])
        self.assertIn("Support", outputs[True])

    def test_repository_catalog_schema_and_coverage_are_complete(self) -> None:
        self.assertEqual(DS.audit_catalog(), [])
        self.assertEqual(DS.catalog_coverage_findings(), [])

    def test_catalog_audit_rejects_invalid_governance_metadata(self) -> None:
        catalog = copy.deepcopy(DS.load_json(DS.CATALOG_PATH))
        first = catalog["components"][0]
        first["category"] = "universal"
        first["stateCoverage"] = ["normal", "normal"]
        first["previewPolicy"] = {
            "kind": "notApplicable",
            "reason": "跳过验证",
        }

        errors = DS.audit_catalog(catalog)

        self.assertTrue(any("组件类别无效" in error for error in errors))
        self.assertTrue(any("状态覆盖存在重复值" in error for error in errors))
        self.assertTrue(any("canonical 组件必须提供" in error for error in errors))

    def test_project_specific_inferred_helpers_are_explicitly_guarded(self) -> None:
        policy = DS.load_json(DS.POLICY_PATH)
        guarded_symbols = {
            symbol
            for item in policy["symbolPolicies"]
            if item.get("matchInferred") is True
            for symbol in item["symbols"]
        }

        self.assertEqual(
            guarded_symbols,
            {
                "Color.xmHex",
                "Color.xmAdaptive",
                "Color.xmResolved",
                "Color.xmSRGB",
                "UIColor.xmHex",
                "UIColor.xmAdaptive",
                "UIColor.xmResolved",
                "UIColor.xmSRGB",
                "Font.brandDisplay",
                "UIFont.brandDisplay",
            },
        )

    def test_policy_accepts_retired_symbol_without_allowed_owner(self) -> None:
        policy = copy.deepcopy(DS.load_json(DS.POLICY_PATH))
        retired_policy = next(
            item
            for item in policy["symbolPolicies"]
            if item["name"] == "retiredLayoutAndStrokeAliases"
        )

        self.assertEqual(DS.audit_policy(policy), [])
        self.assertEqual(retired_policy["allowedPaths"], [])
        self.assertIn("Spacing.actionReserved", retired_policy["symbols"])
        for path in (
            "xmnote/Views/ExampleView.swift",
            "xmnote/Utilities/DesignSystem/Spacing.swift",
        ):
            permissions = DS.allowed_low_level_entry_points(path, policy)
            self.assertNotIn(
                "retiredLayoutAndStrokeAliases",
                [item["name"] for item in permissions],
            )

    def test_retired_policy_families_keep_required_symbols_deny_all(self) -> None:
        policy = DS.load_json(DS.POLICY_PATH)
        policies = {item["name"]: item for item in policy["symbolPolicies"]}
        required = {
            "retiredGlobalColorAliases": {
                "Color.brand",
                "Color.bookCoverSpineDark",
                "Color.statusReading",
                "Color.ratingActive",
                "Color.readCalendarTopAction",
                "Color.xmRGBAHex",
            },
            "retiredTypographyAliases": {
                "NoteExcerptTypography.body",
                "ReadCalendarTypography.topControlTitleFont",
                "ReadCalendarSummaryTypography.metricNumber",
                "AppTypography.topSwitcherTitleFont",
                "SemanticTypography.scaledPointSize",
            },
            "retiredLayoutAndStrokeAliases": {
                "Spacing.actionReserved",
                "CardStyle.borderWidth",
            },
            "retiredCornerAlias": {"CornerRadius.containerXXL"},
        }

        for name, symbols in required.items():
            self.assertIn(name, policies)
            self.assertEqual(policies[name]["allowedPaths"], [])
            self.assertTrue(symbols.issubset(set(policies[name]["symbols"])))

    def test_retired_tokens_remain_absent_from_first_party_swift(self) -> None:
        source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (DS.ROOT / "xmnote").rglob("*.swift")
            if "Vendor" not in path.parts and not path.name.endswith(".generated.swift")
        )
        retired_patterns = [
            r"\bColor\.brand\b",
            r"\bColor\.brand(?:Light|Deep|Darkest)\b",
            r"\bColor\.bookCover[A-Z]\w*\b",
            r"\bColor\.status(?:Reading|Done|Wish|OnHold|Abandoned)\b",
            r"\bColor\.rating(?:Active|Inactive)\b",
            r"\bColor\.readCalendar[A-Z]\w*\b",
            r"\bNoteExcerptTypography\b",
            r"\bReadCalendarSummaryTypography\b",
            r"\bSpacing\.actionReserved\b",
            r"\bCardStyle(?:\.borderWidth)?\b",
            r"\bCornerRadius\.containerXXL\b",
        ]

        for pattern in retired_patterns:
            self.assertIsNone(re.search(pattern, source), pattern)

    def test_changed_line_map_tracks_hunks_and_treats_untracked_as_full_file(self) -> None:
        diff = """diff --git a/xmnote/Views/Tracked.swift b/xmnote/Views/Tracked.swift
--- a/xmnote/Views/Tracked.swift
+++ b/xmnote/Views/Tracked.swift
@@ -4,0 +5,2 @@
+first
+second
"""
        paths = [
            "xmnote/Views/Tracked.swift",
            "xmnote/Views/Untracked.swift",
        ]

        with (
            mock.patch.object(
                DS,
                "git_output",
                return_value=["xmnote/Views/Untracked.swift"],
            ),
            mock.patch.object(DS, "git_text", return_value=diff),
        ):
            line_map = DS.changed_line_map("changed", paths)

        self.assertEqual(line_map["xmnote/Views/Tracked.swift"], {5, 6})
        self.assertIsNone(line_map["xmnote/Views/Untracked.swift"])

    def test_scoped_reports_only_keeps_changed_candidates_actionable(self) -> None:
        reports = [
            {
                "ruleID": "DSR002",
                "path": "xmnote/Views/Tracked.swift",
                "line": 5,
                "reportDisposition": "candidate",
                "reportGroup": "motion|inline-literal",
            },
            {
                "ruleID": "DSR002",
                "path": "xmnote/Views/Tracked.swift",
                "line": 12,
                "reportDisposition": "candidate",
                "reportGroup": "motion|inline-literal",
            },
            {
                "ruleID": "DSR001",
                "path": "xmnote/Views/Tracked.swift",
                "line": 15,
                "reportDisposition": "inventory",
                "reportGroup": "sf-symbol|Views|plus",
            },
            {
                "ruleID": "DSR003",
                "path": "xmnote/Views/Untracked.swift",
                "line": 20,
                "reportDisposition": "candidate",
                "reportGroup": "progress|unclassified",
            },
        ]
        with mock.patch.object(
            DS,
            "changed_line_map",
            return_value={
                "xmnote/Views/Tracked.swift": {5},
                "xmnote/Views/Untracked.swift": None,
            },
        ):
            scoped = DS.scoped_reports(
                reports,
                "changed",
                ["xmnote/Views/Tracked.swift", "xmnote/Views/Untracked.swift"],
            )

        self.assertEqual(
            [item["reportDisposition"] for item in scoped],
            ["candidate", "inventory", "inventory", "candidate"],
        )

    def test_report_modes_keep_summary_compact_and_all_evidence_complete(self) -> None:
        rules = {
            "DSR001": {"title": "SF Symbol 库存", "correctPath": "局部语义"},
            "DSR002": {"title": "动画字面量", "correctPath": "局部 Motion owner"},
        }
        reports = [
            {
                "ruleID": "DSR001",
                "path": "xmnote/Views/Book/Example.swift",
                "line": 8,
                "column": 9,
                "declaration": "var body",
                "evidence": "Image(systemName: \"plus\")",
                "message": "库存",
                "reportDisposition": "inventory",
                "reportGroup": "sf-symbol|Views/Book|plus",
            },
            {
                "ruleID": "DSR002",
                "path": "xmnote/Views/Book/Example.swift",
                "line": 12,
                "column": 9,
                "declaration": "var body",
                "evidence": ".smooth(duration: 0.22)",
                "message": "候选",
                "reportDisposition": "candidate",
                "reportGroup": "motion|inline-literal",
            },
            {
                "ruleID": "DSR002",
                "path": "xmnote/Views/Book/Example.swift",
                "line": 14,
                "column": 9,
                "declaration": "var body",
                "evidence": ".snappy(duration: 0.24)",
                "message": "候选",
                "reportDisposition": "candidate",
                "reportGroup": "motion|inline-literal",
            },
        ]

        outputs: dict[str, str] = {}
        for mode in ("summary", "actionable", "all"):
            stream = io.StringIO()
            with redirect_stdout(stream):
                DS.print_reports(reports, rules, mode)
            outputs[mode] = stream.getvalue()

        self.assertIn("库存 1 · 候选 0", outputs["summary"])
        self.assertNotIn("ACTIONABLE", outputs["summary"])
        self.assertIn("1 个 owner，共 2 条", outputs["actionable"])
        self.assertNotIn("Image(systemName", outputs["actionable"])
        self.assertIn("REPORT-ALL: 完整展开 3 条", outputs["all"])
        self.assertIn("Image(systemName", outputs["all"])
        self.assertIn(".snappy(duration: 0.24)", outputs["all"])

    def test_show_reports_remains_all_mode_alias(self) -> None:
        arguments = DS.build_parser().parse_args(["lint", "--reports", "summary"])
        compatibility_arguments = DS.build_parser().parse_args(
            ["audit", "--reports", "summary", "--show-reports"]
        )

        self.assertEqual(DS.requested_report_mode(arguments), "summary")
        self.assertEqual(DS.requested_report_mode(compatibility_arguments), "all")


if __name__ == "__main__":
    unittest.main()
