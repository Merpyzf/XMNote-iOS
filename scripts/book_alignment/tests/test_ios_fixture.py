from __future__ import annotations

import contextlib
import io
import pathlib
import plistlib
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT_ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from book_alignment import ios_fixture  # noqa: E402
from book_alignment.common import AlignmentError  # noqa: E402


class IOSFixtureSafetyTests(unittest.TestCase):
    def test_replay_parser_requires_explicit_android_s2_and_output(self) -> None:
        args = ios_fixture.parse_args(
            [
                "replay-a09",
                "--android-s2",
                "/private/a09/S2.db",
                "--output-dir",
                "/private/a09/ios",
            ]
        )

        self.assertEqual(args.command, "replay-a09")
        self.assertEqual(args.case_id, ios_fixture.REPLAY_CASE_ID)
        self.assertEqual(args.udid, ios_fixture.DEDICATED_SIMULATOR_UDID)

    def test_commands_pin_dedicated_udid_and_debug_launch_contract(self) -> None:
        udid = ios_fixture.DEDICATED_SIMULATOR_UDID

        self.assertEqual(
            ios_fixture._simctl_get_container_command(udid, "data"),
            [
                "xcrun",
                "simctl",
                "get_app_container",
                udid,
                ios_fixture.DEBUG_APP_BUNDLE_ID,
                "data",
            ],
        )
        self.assertEqual(
            ios_fixture._simctl_launch_command(udid),
            [
                "xcrun",
                "simctl",
                "launch",
                "--terminate-running-process",
                udid,
                ios_fixture.DEBUG_APP_BUNDLE_ID,
                "-XMNoteBookAlignmentScene",
                "bookshelf.default",
            ],
        )
        self.assertEqual(
            ios_fixture._simctl_launch_command(
                udid,
                replay_case_id=ios_fixture.REPLAY_CASE_ID,
                replay_mode="operation",
            )[-4:],
            [
                ios_fixture.REPLAY_CASE_ARGUMENT,
                ios_fixture.REPLAY_CASE_ID,
                ios_fixture.REPLAY_MODE_ARGUMENT,
                "operation",
            ],
        )
        database = pathlib.Path("/private/case/xm_note.db")
        environment = ios_fixture._launch_environment(
            database,
            {
                "KEEP": "yes",
                "SIMCTL_CHILD_XMNOTE_WEB_PARITY_DATABASE_PATH": "/unsafe.db",
            },
        )
        self.assertEqual(environment["KEEP"], "yes")
        self.assertNotIn(
            "SIMCTL_CHILD_XMNOTE_WEB_PARITY_DATABASE_PATH", environment
        )
        self.assertEqual(
            environment[
                "SIMCTL_CHILD_XMNOTE_BOOK_ALIGNMENT_DATABASE_PATH"
            ],
            str(database),
        )

    def test_booted_and_any_other_udid_fail_closed(self) -> None:
        for value in ("booted", "00000000-0000-0000-0000-000000000000", ""):
            with self.subTest(value=value), self.assertRaises(AlignmentError):
                ios_fixture._validated_udid(value)

        with self.assertRaises(AlignmentError):
            ios_fixture._simctl_launch_command(
                ios_fixture.DEDICATED_SIMULATOR_UDID,
                replay_case_id="a-01-delete-groups-late-failure",
                replay_mode="operation",
            )
        with self.assertRaises(AlignmentError):
            ios_fixture._simctl_launch_command(
                ios_fixture.DEDICATED_SIMULATOR_UDID,
                replay_case_id=ios_fixture.REPLAY_CASE_ID,
                replay_mode="unsupported",
            )

    def test_container_path_must_belong_to_dedicated_device_and_kind(self) -> None:
        udid = ios_fixture.DEDICATED_SIMULATOR_UDID
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            valid = (
                home
                / "Library/Developer/CoreSimulator/Devices"
                / udid
                / "data/Containers/Data/Application/fixture"
            )
            valid.mkdir(parents=True)
            self.assertEqual(
                ios_fixture._validated_container_path(
                    valid, udid=udid, kind="data", home=home
                ),
                valid.resolve(),
            )

            outside = home / "unrelated"
            outside.mkdir()
            with self.assertRaises(AlignmentError):
                ios_fixture._validated_container_path(
                    outside, udid=udid, kind="data", home=home
                )
            with self.assertRaises(AlignmentError):
                ios_fixture._validated_container_path(
                    valid, udid=udid, kind="app", home=home
                )

    def test_missing_private_baseline_is_explicit_skip_without_simctl(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            missing = root / "missing-B0.db"
            host_output = root / "live.db"
            stdout = io.StringIO()
            with mock.patch.object(ios_fixture, "_run") as run, contextlib.redirect_stdout(
                stdout
            ):
                result = ios_fixture.main(
                    [
                        "seed",
                        "--case-id",
                        "fixture.noop",
                        "--baseline",
                        str(missing),
                        "--host-output",
                        str(host_output),
                        "--skip-missing-private-baseline",
                    ]
                )

            self.assertEqual(result, 77)
            self.assertEqual(stdout.getvalue().strip(), "SKIP: missing private baseline")
            run.assert_not_called()

    def test_debug_app_must_contain_debug_only_alignment_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app_bundle = pathlib.Path(directory) / "XMNote.app"
            app_bundle.mkdir()
            (app_bundle / "Info.plist").write_bytes(
                plist_bytes(
                    {
                        "CFBundleIdentifier": ios_fixture.DEBUG_APP_BUNDLE_ID,
                        "CFBundleExecutable": "xmnote",
                        "DTPlatformName": "iphonesimulator",
                    }
                )
            )
            debug_dylib = app_bundle / "xmnote.debug.dylib"
            debug_dylib.write_bytes(
                b"\x00".join(
                    (
                        ios_fixture.DATABASE_ENVIRONMENT_VARIABLE.encode(),
                        ios_fixture.SCENE_ARGUMENT.encode(),
                        ios_fixture.SCENE_VALUE.encode(),
                        ios_fixture.REPLAY_CASE_ARGUMENT.encode(),
                        ios_fixture.REPLAY_MODE_ARGUMENT.encode(),
                        ios_fixture.REPLAY_CASE_ID.encode(),
                    )
                )
            )
            ios_fixture._verify_debug_app(app_bundle)

            debug_dylib.write_bytes(b"release-like-binary")
            with self.assertRaises(AlignmentError):
                ios_fixture._verify_debug_app(app_bundle)

    def test_a09_replay_contract_and_semantic_digest_are_privacy_safe(self) -> None:
        contract = ios_fixture._validate_replay_contract(ios_fixture.REPLAY_CASE_ID)
        self.assertEqual(contract["status"], "exact-current")
        self.assertEqual(contract["targetDatabase"]["userVersion"], 48)
        self.assertEqual(
            contract["targetDatabase"]["roomIdentityHash"],
            ios_fixture.IOS_TARGET_ROOM_IDENTITY_HASH,
        )
        with self.assertRaises(AlignmentError):
            ios_fixture._validate_replay_contract("a-08-collection-duplicate-schema-gap")

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            first = root / "first.db"
            second = root / "second.db"
            for path in (first, second):
                connection = sqlite3.connect(path)
                try:
                    connection.executescript(
                        """
                        CREATE TABLE book (id INTEGER PRIMARY KEY, name TEXT);
                        CREATE TABLE group_book (id INTEGER PRIMARY KEY, book_id INTEGER);
                        CREATE TABLE tag_book (id INTEGER PRIMARY KEY, book_id INTEGER);
                        CREATE TABLE collection_book (id INTEGER PRIMARY KEY, book_id INTEGER);
                        CREATE TABLE `group` (id INTEGER PRIMARY KEY);
                        CREATE TABLE tag (id INTEGER PRIMARY KEY);
                        CREATE TABLE collection (id INTEGER PRIMARY KEY);
                        CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY);
                        INSERT INTO book VALUES (9090001, 'private-value-never-returned');
                        INSERT INTO group_book VALUES (1, 9090001);
                        INSERT INTO tag_book VALUES (2, 9090001);
                        INSERT INTO collection_book VALUES (3, 9090001);
                        INSERT INTO `group` VALUES (9090101);
                        INSERT INTO tag VALUES (9090201);
                        INSERT INTO collection VALUES (9090301);
                        """
                    )
                    connection.execute(
                        "INSERT INTO grdb_migrations VALUES (?)",
                        ("ios-only-a" if path == first else "ios-only-b",),
                    )
                    connection.commit()
                finally:
                    connection.close()

            self.assertEqual(
                ios_fixture._a09_projection(first),
                {"targetPhysicalRows": 4, "fixtureParentRows": 3},
            )
            self.assertEqual(
                ios_fixture._business_database_digest(first),
                ios_fixture._business_database_digest(second),
            )

    def test_foreign_key_delta_preserves_duplicate_violation_counts(self) -> None:
        baseline = {
            "foreignKeyCheck": {"violationDigests": ["a", "a", "b"]}
        }
        after = {
            "foreignKeyCheck": {"violationDigests": ["a", "b", "b", "c"]}
        }

        self.assertEqual(
            ios_fixture._added_foreign_key_digests(baseline, after),
            ["b", "c"],
        )

    def test_replay_marker_requires_exact_allowlisted_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / "replay-operation.json"
            marker.write_text(
                '{"schemaVersion":1,"caseId":"a-09-soft-vs-hard-delete",'
                '"mode":"operation","result":"PASS"}',
                encoding="utf-8",
            )
            payload = ios_fixture._wait_for_replay_marker(
                marker,
                case_id=ios_fixture.REPLAY_CASE_ID,
                mode="operation",
                timeout_seconds=0.25,
            )
            self.assertEqual(payload["result"], "PASS")

            marker.write_text(
                '{"schemaVersion":1,"caseId":"a-09-soft-vs-hard-delete",'
                '"mode":"operation","result":"PASS","extra":1}',
                encoding="utf-8",
            )
            with self.assertRaises(AlignmentError):
                ios_fixture._wait_for_replay_marker(
                    marker,
                    case_id=ios_fixture.REPLAY_CASE_ID,
                    mode="operation",
                    timeout_seconds=0.25,
                )


def plist_bytes(value: dict[str, object]) -> bytes:
    return plistlib.dumps(value, fmt=plistlib.FMT_XML)


if __name__ == "__main__":
    unittest.main()
