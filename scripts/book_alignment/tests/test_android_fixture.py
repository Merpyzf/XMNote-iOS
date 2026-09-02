from __future__ import annotations

import argparse
import contextlib
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT_ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from book_alignment import android_fixture  # noqa: E402
from book_alignment.common import AlignmentError  # noqa: E402
from book_alignment.contract import validate_case_payload  # noqa: E402


class AndroidFixtureHostTests(unittest.TestCase):
    def test_diagnostic_aggregate_is_structurally_validated(self) -> None:
        counts = [1] * 24
        aggregate = {
            "schemaVersion": 1,
            "kind": "collection-concurrency-stress",
            "caseId": "a08.collection-concurrency.stress",
            "collectionId": 9_088_101,
            "bookCount": 24,
            "trialsPerBook": 16,
            "workers": 16,
            "callCount": 384,
            "callErrorCount": 0,
            "relationCountsByOrdinal": counts,
            "relationCountHistogram": {"1": 24},
            "errorTypeHistogram": {},
            "duplicateBookCount": 0,
            "minValidRelationCount": 1,
            "maxValidRelationCount": 1,
            "stableAfterReopen": True,
        }
        output = (
            "INSTRUMENTATION_STATUS: xmnote.bookAlignment.aggregate.v1="
            + json.dumps(aggregate, separators=(",", ":"))
            + "\nOK (1 test)\n"
        )

        self.assertEqual(
            android_fixture._parse_diagnostic_aggregate(
                "a08.collection-concurrency.stress", "operation", output
            ),
            aggregate,
        )
        with self.assertRaises(AlignmentError):
            android_fixture._parse_diagnostic_aggregate(
                "a-01-delete-groups-late-failure", "operation", output
            )
        invalid = dict(
            aggregate,
            relationCountsByOrdinal=[2] * 24,
            relationCountHistogram={"2": 24},
            duplicateBookCount=24,
            minValidRelationCount=2,
            maxValidRelationCount=2,
        )
        with self.assertRaises(AlignmentError):
            android_fixture._validate_collection_concurrency_aggregate(
                invalid, "a08.collection-concurrency.stress"
            )
        inconsistent_summary = dict(aggregate, duplicateBookCount=1)
        with self.assertRaises(AlignmentError):
            android_fixture._validate_collection_concurrency_aggregate(
                inconsistent_summary, "a08.collection-concurrency.stress"
            )

    def test_inbox_sha_poll_retries_a_transient_mismatch(self) -> None:
        expected_digest = "a" * 64
        mismatch = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=("b" * 64).encode(), stderr=b""
        )
        match = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=expected_digest.encode(), stderr=b""
        )
        with mock.patch.object(
            android_fixture, "_adb", side_effect=[mismatch, match]
        ) as adb, mock.patch.object(android_fixture.time, "sleep") as sleep:
            android_fixture._poll_inbox_sha(
                "fixture-device",
                "files/book-alignment/inbox/B0.db",
                expected_digest,
                "B0.db",
            )

        self.assertEqual(adb.call_count, 2)
        sleep.assert_called_once_with(
            android_fixture.INBOX_SHA_RETRY_INTERVAL_SECONDS
        )

    def test_inbox_sha_poll_still_fails_after_the_bound(self) -> None:
        mismatch = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=("b" * 64).encode(), stderr=b""
        )
        with mock.patch.object(
            android_fixture, "INBOX_SHA_MAX_ATTEMPTS", 3
        ), mock.patch.object(
            android_fixture, "_adb", return_value=mismatch
        ) as adb, mock.patch.object(android_fixture.time, "sleep") as sleep:
            with self.assertRaisesRegex(AlignmentError, "after 3 attempts"):
                android_fixture._poll_inbox_sha(
                    "fixture-device",
                    "files/book-alignment/inbox/B0.db",
                    "a" * 64,
                    "B0.db",
                )

        self.assertEqual(adb.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    def test_all_case_selectors_are_fixed_to_the_published_android_methods(self) -> None:
        expected = {
            "a-01-delete-groups-late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#a01_deleteGroups_lateFailure"
            ),
            "a-02-delete-books-late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#a02_deleteBooks_lateFailure"
            ),
            "a-03-batch-source-late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#a03_batchSource_lateFailure"
            ),
            "a-04-single-replace-batch-append-tags": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#a04_singleReplace_batchAppendTags"
            ),
            "a-05-sort-late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentScenarioReplayTest"
                "#a05_sort_lateFailure"
            ),
            "a-06-move-out-start-reverses-order": (
                "com.merpyzf.xmnote.alignment.BookAlignmentScenarioReplayTest"
                "#a06_moveOutStart_reversesOrder"
            ),
            "a-07-merge-updates-deleted-books": (
                "com.merpyzf.xmnote.alignment.BookAlignmentScenarioReplayTest"
                "#a07_merge_updatesDeletedBooks"
            ),
            "a-08-collection-duplicate-schema-gap": (
                "com.merpyzf.xmnote.alignment.BookAlignmentScenarioReplayTest"
                "#a08_collection_duplicateSchemaGap"
            ),
            "a-09-soft-vs-hard-delete": (
                "com.merpyzf.xmnote.alignment.BookAlignmentScenarioReplayTest"
                "#a09_softDelete"
            ),
            "a03.status-rating.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a03.single-tag.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a03.multi-tag.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a03.tag-delete.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a03.source-delete.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a01.group-moveout.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a03.duplicate-tag-and-book-ids": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a03.source-delete.success": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a04.empty-tag-selection": (
                "com.merpyzf.xmnote.alignment.BookAlignmentA01A04GoldenTest"
                "#runRequestedGolden"
            ),
            "a05.group-suspend-sort.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentSortingOwnerReplayTest"
                "#runRequestedGolden"
            ),
            "a05.group-rx-sort.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentSortingOwnerReplayTest"
                "#runRequestedGolden"
            ),
            "a05.read-status-sort.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentSortingOwnerReplayTest"
                "#runRequestedGolden"
            ),
            "a05.source-sort.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentSortingOwnerReplayTest"
                "#runRequestedGolden"
            ),
            "a05.tag-sort.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentSortingOwnerReplayTest"
                "#runRequestedGolden"
            ),
            "a07.author-merge.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentMergeDeleteLifecycleReplayTest"
                "#runRequestedGolden"
            ),
            "a07.press-merge.late-failure": (
                "com.merpyzf.xmnote.alignment.BookAlignmentMergeDeleteLifecycleReplayTest"
                "#runRequestedGolden"
            ),
            "a09.tag-replace-tombstone-growth": (
                "com.merpyzf.xmnote.alignment.BookAlignmentMergeDeleteLifecycleReplayTest"
                "#runRequestedGolden"
            ),
            "a11.group-only-collection-scope": (
                "com.merpyzf.xmnote.alignment.BookAlignmentScenarioReplayTest"
                "#a11_groupOnlyCollectionScope_isStableAndDeduplicated"
            ),
            "a08.collection-concurrency.stress": (
                "com.merpyzf.xmnote.alignment.BookAlignmentCollectionConcurrencyStressTest"
                "#runRepositoryConcurrencyStress"
            ),
        }

        self.assertEqual(
            {
                case_id: android_fixture.REPLAY_ADAPTERS[case_id].test_selector
                for case_id in android_fixture.RUNNABLE_CASE_IDS
            },
            expected,
        )

    def test_allowlist_builds_fixed_instrumentation_selector(self) -> None:
        case_id = "a-01-delete-groups-late-failure"
        adapter = android_fixture._adapter_for_case(case_id)
        arguments = android_fixture._instrumentation_command(case_id)

        self.assertEqual(
            arguments,
            [
                "shell",
                "am",
                "instrument",
                "-w",
                "-r",
                "-e",
                "xmnote.bookAlignment.caseId",
                case_id,
                "-e",
                "class",
                adapter.test_selector,
                android_fixture.INSTRUMENTATION_COMPONENT,
            ],
        )
        self.assertEqual(arguments.count("instrument"), 1)
        self.assertNotEqual(adapter.test_selector, android_fixture.NOOP_TEST_SELECTOR)
        self.assertEqual(
            android_fixture._stability_instrumentation_command(case_id),
            [
                "shell",
                "am",
                "instrument",
                "-w",
                "-r",
                "-e",
                "xmnote.bookAlignment.caseId",
                case_id,
                "-e",
                "xmnote.bookAlignment.resume",
                "true",
                "-e",
                "class",
                android_fixture.STABILITY_TEST_SELECTOR,
                android_fixture.INSTRUMENTATION_COMPONENT,
            ],
        )

    def test_unregistered_case_and_selector_injection_fail_closed(self) -> None:
        for case_id in (
            "unregistered-case",
            "a-01-delete-groups-late-failure#otherMethod",
            "../a-01-delete-groups-late-failure",
        ):
            with self.subTest(case_id=case_id), self.assertRaises(AlignmentError):
                android_fixture._adapter_for_case(case_id)

    def test_run_executes_only_allowlisted_test_in_uitest_packages(self) -> None:
        case_id = "a-01-delete-groups-late-failure"
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=b"OK (1 test)\n", stderr=b""
        )
        stopped = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=b"", stderr=b""
        )
        marker_created = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=b"", stderr=b""
        )
        with mock.patch.object(android_fixture, "_require_adb"), mock.patch.object(
            android_fixture, "_verify_installed"
        ) as verify, mock.patch.object(
            android_fixture,
            "_adb",
            side_effect=[completed, stopped, marker_created, completed],
        ) as adb:
            result = android_fixture.run_case(
                argparse.Namespace(
                    device="fixture-device", case_id=case_id, manifest=None
                )
            )

        self.assertEqual(result, 0)
        self.assertEqual(
            [call.args[1] for call in verify.call_args_list],
            [android_fixture.TARGET_PACKAGE, android_fixture.TEST_PACKAGE],
        )
        self.assertEqual(
            adb.call_args_list,
            [
                mock.call(
                    "fixture-device",
                    *android_fixture._instrumentation_command(case_id),
                ),
                mock.call(
                    "fixture-device",
                    "shell",
                    "am",
                    "force-stop",
                    android_fixture.TARGET_PACKAGE,
                ),
                mock.call(
                    "fixture-device",
                    "shell",
                    "run-as",
                    android_fixture.TARGET_PACKAGE,
                    "touch",
                    android_fixture.RESUME_MARKER,
                ),
                mock.call(
                    "fixture-device",
                    *android_fixture._stability_instrumentation_command(case_id),
                ),
            ],
        )

    def test_run_manifest_contains_digest_not_raw_output(self) -> None:
        case_id = "a-01-delete-groups-late-failure"
        raw_output = b"private-looking-instrumentation-output\nOK (1 test)\n"
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=raw_output, stderr=b""
        )
        stopped = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=b"", stderr=b""
        )
        marker_created = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=b"", stderr=b""
        )
        with tempfile.TemporaryDirectory() as directory:
            manifest = pathlib.Path(directory) / "instrumentation.json"
            with mock.patch.object(android_fixture, "_require_adb"), mock.patch.object(
                android_fixture, "_verify_installed"
            ), mock.patch.object(
                android_fixture,
                "_adb",
                side_effect=[completed, stopped, marker_created, completed],
            ):
                result = android_fixture.run_case(
                    argparse.Namespace(
                        device="fixture-device",
                        case_id=case_id,
                        manifest=manifest,
                    )
                )
            payload = manifest.read_text(encoding="utf-8")

        self.assertEqual(result, 0)
        self.assertIn('"result": "PASS"', payload)
        self.assertEqual(payload.count('"stdoutStderrSha256"'), 2)
        self.assertIn('"phase": "cold-restart-s4"', payload)
        self.assertNotIn(raw_output.decode().strip(), payload)
        self.assertNotIn("private-looking", payload)
        evidence = json.loads(payload)
        self.assertEqual(
            android_fixture._validate_instrumentation_evidence(evidence, case_id),
            evidence,
        )
        evidence["phases"][0]["rawStdout"] = raw_output.decode()
        with self.assertRaises(AlignmentError):
            android_fixture._validate_instrumentation_evidence(evidence, case_id)

    def test_replay_missing_private_baseline_skips_before_adb(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            stdout = io.StringIO()
            with mock.patch.object(android_fixture, "_adb") as adb, contextlib.redirect_stdout(
                stdout
            ):
                result = android_fixture.main(
                    [
                        "replay",
                        "--device",
                        "fixture-device",
                        "--case-id",
                        "a-01-delete-groups-late-failure",
                        "--snapshot-id",
                        "fixture-snapshot",
                        "--baseline",
                        str(root / "missing-B0.db"),
                        "--output-dir",
                        str(root / "output"),
                        "--skip-missing-private-baseline",
                    ]
                )

        self.assertEqual(result, 77)
        self.assertEqual(stdout.getvalue().strip(), "SKIP: missing private baseline")
        adb.assert_not_called()

    def test_pull_missing_private_baseline_skips_without_manifest_or_adb(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            stdout = io.StringIO()
            with mock.patch.object(
                android_fixture, "_adb"
            ) as adb, contextlib.redirect_stdout(stdout):
                result = android_fixture.main(
                    [
                        "pull",
                        "--device",
                        "fixture-device",
                        "--case-id",
                        "a-01-delete-groups-late-failure",
                        "--snapshot-id",
                        "fixture-snapshot",
                        "--baseline",
                        str(root / "missing-B0.db"),
                        "--output-dir",
                        str(root / "output"),
                        "--skip-missing-private-baseline",
                    ]
                )

        self.assertEqual(result, 77)
        self.assertEqual(stdout.getvalue().strip(), "SKIP: missing private baseline")
        adb.assert_not_called()

    def test_pull_rejects_existing_output_before_adb_or_database_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            baseline = root / "B0.db"
            baseline.touch()
            output = root / "existing"
            output.mkdir()
            args = argparse.Namespace(
                device="fixture-device",
                case_id="a-01-delete-groups-late-failure",
                snapshot_id="fixture-snapshot",
                baseline=baseline,
                output_dir=output,
            )
            with mock.patch.object(
                android_fixture, "_require_adb"
            ) as require_adb, mock.patch.object(
                android_fixture, "inspect_database"
            ) as inspect:
                with self.assertRaises(AlignmentError):
                    android_fixture.pull_snapshots(args)

        require_adb.assert_not_called()
        inspect.assert_not_called()

    def test_batch_all_contains_nine_primary_and_eighteen_extended_cases(self) -> None:
        self.assertEqual(len(android_fixture.PRIMARY_ALIGNMENT_CASE_IDS), 9)
        self.assertEqual(
            [case_id[:4] for case_id in android_fixture.PRIMARY_ALIGNMENT_CASE_IDS],
            [f"a-{index:02d}" for index in range(1, 10)],
        )
        self.assertEqual(
            android_fixture.EXTENDED_ALIGNMENT_CASE_IDS,
            (
                "a03.status-rating.late-failure",
                "a03.single-tag.late-failure",
                "a03.multi-tag.late-failure",
                "a03.tag-delete.late-failure",
                "a03.source-delete.late-failure",
                "a01.group-moveout.late-failure",
                "a03.duplicate-tag-and-book-ids",
                "a03.source-delete.success",
                "a04.empty-tag-selection",
                "a05.group-suspend-sort.late-failure",
                "a05.group-rx-sort.late-failure",
                "a05.read-status-sort.late-failure",
                "a05.source-sort.late-failure",
                "a05.tag-sort.late-failure",
                "a07.author-merge.late-failure",
                "a07.press-merge.late-failure",
                "a09.tag-replace-tombstone-growth",
                "a11.group-only-collection-scope",
            ),
        )
        self.assertEqual(len(android_fixture.EXTENDED_ALIGNMENT_CASE_IDS), 18)
        self.assertEqual(len(android_fixture.ALIGNMENT_CASE_IDS), 27)
        self.assertEqual(
            android_fixture.ALIGNMENT_CASE_IDS,
            android_fixture.PRIMARY_ALIGNMENT_CASE_IDS
            + android_fixture.EXTENDED_ALIGNMENT_CASE_IDS,
        )
        self.assertNotIn(
            android_fixture.NOOP_CASE_ID, android_fixture.ALIGNMENT_CASE_IDS
        )
        self.assertEqual(
            android_fixture.DIAGNOSTIC_CASE_IDS,
            ("a08.collection-concurrency.stress",),
        )
        self.assertEqual(
            android_fixture.RUNNABLE_CASE_IDS,
            android_fixture.ALIGNMENT_CASE_IDS + android_fixture.DIAGNOSTIC_CASE_IDS,
        )

    def test_all_allowlisted_contracts_validate_without_private_bindings(self) -> None:
        files = {
            path.name: path
            for path in android_fixture.CASE_CONTRACT_DIRECTORY.glob("*.case.json")
        }
        registered_files = {
            adapter.contract_file
            for adapter in android_fixture.REPLAY_ADAPTERS.values()
            if adapter.contract_file is not None
        }
        self.assertEqual(set(files), registered_files)
        for case_id in android_fixture.RUNNABLE_CASE_IDS:
            with self.subTest(case_id=case_id):
                adapter = android_fixture.REPLAY_ADAPTERS[case_id]
                payload = json.loads(files[adapter.contract_file].read_text())
                case = validate_case_payload(payload)
                self.assertEqual(case["caseId"], case_id)
                self.assertTrue(case["lifecycle"]["requireRestart"])
                self.assertIn(
                    "冷启动",
                    next(
                        checkpoint["meaning"]
                        for checkpoint in case["lifecycle"]["checkpoints"]
                        if checkpoint["stage"] == "S4"
                    ),
                )
                for alias in case["aliases"]:
                    self.assertNotIn("id", alias)
                    self.assertNotIn("privateLabel", alias)
                self.assertNotIn("bindings", case)

        a05 = json.loads(files["a-05-sort-late-failure.case.json"].read_text())
        self.assertEqual(
            [alias["name"] for alias in a05["aliases"]],
            ["prefixBook", "prefixGroup", "failingBook", "suffixBook"],
        )
        self.assertEqual(a05["database"]["timeColumns"], [])
        self.assertEqual(
            {
                rule["table"]: rule["columns"]
                for rule in a05["database"]["allowedWrites"]
            },
            {},
        )
        self.assertEqual(a05["status"], "exact-current")
        self.assertEqual(a05["targetDatabase"]["userVersion"], 48)

        a08 = json.loads(
            files["a-08-collection-duplicate-schema-gap.case.json"].read_text()
        )
        a08_projections = {
            projection["name"]: projection
            for projection in a08["oracle"]["semanticProjections"]
        }
        self.assertEqual(
            a08_projections["direct-dao-duplicate-relation-count"]["expected"][
                "androidAfter"
            ],
            1,
        )
        self.assertEqual(
            a08_projections["serial-repository-updated-date"]["expected"][
                "androidAfter"
            ],
            0,
        )

        a09 = json.loads(files["a-09-soft-vs-hard-delete.case.json"].read_text())
        self.assertEqual(a09["aliases"][0]["name"], "relatedBook")
        self.assertIn("S2 时三类关系各有一条有效记录", a09["aliases"][0]["requirements"])
        cross_platform_relation_deletes = {
            rule["table"]
            for rule in a09["database"]["allowedWrites"]
            if rule["platforms"] == ["android", "ios"]
            and "delete" in rule["operations"]
        }
        self.assertEqual(
            cross_platform_relation_deletes,
            {"book", "group_book", "tag_book", "collection_book"},
        )


if __name__ == "__main__":
    unittest.main()
