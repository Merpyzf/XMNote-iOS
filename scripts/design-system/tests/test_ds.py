"""Regression tests for the repository-owned design-system orchestrator."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


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


if __name__ == "__main__":
    unittest.main()
