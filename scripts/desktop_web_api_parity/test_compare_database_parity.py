#!/usr/bin/env python3
"""Regression checks for privacy-safe frozen SQLite snapshot handling."""

from __future__ import annotations

import os
import pathlib
import shutil
import sqlite3
import stat
import tempfile
import unittest

from scripts.desktop_web_api_parity import compare_database_parity


class FrozenSnapshotOpenTests(unittest.TestCase):
    """Prove read-only parity inspection never creates files beside a frozen DB."""

    def test_wal_header_snapshot_is_opened_immutable_without_sidecars(self) -> None:
        with tempfile.TemporaryDirectory(prefix="xmnote-parity-open-") as temporary:
            root = pathlib.Path(temporary)
            source = root / "source.db"
            connection = sqlite3.connect(source)
            try:
                self.assertEqual(
                    "wal", str(connection.execute("PRAGMA journal_mode = WAL").fetchone()[0])
                )
                connection.execute("CREATE TABLE sample (value TEXT NOT NULL)")
                connection.execute("INSERT INTO sample (value) VALUES ('ok')")
                connection.commit()
                checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
                self.assertIsNotNone(checkpoint)
                self.assertEqual(0, int(checkpoint[0]))
            finally:
                connection.close()

            frozen_directory = root / "frozen #? snapshot"
            frozen_directory.mkdir()
            frozen = frozen_directory / "B0 #?.db"
            shutil.copyfile(source, frozen)
            os.chmod(frozen, stat.S_IRUSR)

            with frozen.open("rb") as handle:
                header = handle.read(20)
            self.assertEqual(b"SQLite format 3\x00", header[:16])
            self.assertEqual((2, 2), (header[18], header[19]))
            self.assertFalse(pathlib.Path(f"{frozen}-wal").exists())
            self.assertFalse(pathlib.Path(f"{frozen}-shm").exists())

            read_only = compare_database_parity.open_read_only(frozen)
            try:
                self.assertEqual(
                    "ok", read_only.execute("SELECT value FROM sample").fetchone()[0]
                )
            finally:
                read_only.close()

            self.assertFalse(pathlib.Path(f"{frozen}-wal").exists())
            self.assertFalse(pathlib.Path(f"{frozen}-shm").exists())


if __name__ == "__main__":
    unittest.main()
