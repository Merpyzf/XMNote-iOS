from __future__ import annotations

import pathlib
import sys
import unittest

SCRIPT_ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from book_alignment import compare  # noqa: E402


class StrictComparisonPolicyTests(unittest.TestCase):
    def test_operation_requires_every_declared_exception_to_match(self) -> None:
        base = strict_base(
            mismatches=[
                {"reason": "removed-row-key-set", "table": "book"}
            ]
        )
        case = strict_case(
            [
                {
                    "code": "hard-delete",
                    "reasons": ["removed-row-key-set"],
                    "table": "book",
                    "maxMatches": 1,
                },
                {
                    "code": "stale-rule",
                    "reasons": ["mutated-value"],
                    "table": "book",
                    "maxMatches": 1,
                },
            ]
        )

        result = compare._classify_strict(base, case, "operation")

        self.assertFalse(result["passed"])
        self.assertEqual(result["unusedExceptionCodes"], ["stale-rule"])
        self.assertEqual(
            [item["exceptionCode"] for item in result["approvedExceptions"]],
            ["hard-delete"],
        )

    def test_stability_is_exact_and_does_not_require_operation_exceptions(self) -> None:
        base = strict_base(mismatches=[])
        case = strict_case(
            [
                {
                    "code": "operation-only",
                    "reasons": ["removed-row-key-set"],
                    "table": "book",
                    "maxMatches": 1,
                }
            ]
        )

        result = compare._classify_strict(base, case, "stability")

        self.assertTrue(result["passed"])
        self.assertTrue(result["strictExact"])
        self.assertEqual(result["approvedExceptions"], [])
        self.assertEqual(result["unusedExceptionCodes"], [])

    def test_stability_does_not_allow_an_operation_exception(self) -> None:
        base = strict_base(
            mismatches=[
                {"reason": "removed-row-key-set", "table": "book"}
            ]
        )
        case = strict_case(
            [
                {
                    "code": "operation-only",
                    "reasons": ["removed-row-key-set"],
                    "table": "book",
                    "maxMatches": 1,
                }
            ]
        )

        result = compare._classify_strict(base, case, "stability")

        self.assertFalse(result["passed"])
        self.assertEqual(result["approvedExceptions"], [])
        self.assertEqual(result["unapprovedMismatches"], base["mismatches"])

    def test_stability_does_not_require_cross_platform_s3_physical_parity(self) -> None:
        result = compare._before_parity_for_transition(
            parity=None,
            android=None,
            ios=None,
            excluded_tables=set(),
            transition="stability",
        )

        self.assertTrue(result["passed"])
        self.assertFalse(result["applicable"])
        self.assertEqual(
            result["reason"], "stability-compares-each-platform-s3-to-s4"
        )


def strict_case(exceptions: list[dict[str, object]]) -> dict[str, object]:
    return {"database": {"strictExceptions": exceptions}}


def strict_base(mismatches: list[dict[str, object]]) -> dict[str, object]:
    return {
        "mismatches": mismatches,
        "schemaExact": False,
        "schemaStableWithinEachPlatform": True,
        "comparedTables": 1,
        "comparedMutatedCells": 0,
        "androidChangedCells": 0,
        "iosChangedCells": 0,
        "normalizedEpochCells": 0,
        "normalizations": [],
        "stablePlatformTables": [
            {
                "table": "grdb_migrations",
                "androidPresent": False,
                "iosPresent": True,
                "reason": "platform internal",
            }
        ],
    }


if __name__ == "__main__":
    unittest.main()
