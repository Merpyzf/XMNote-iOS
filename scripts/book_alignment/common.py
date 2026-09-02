#!/usr/bin/env python3
"""Shared, standard-library-only primitives for book-alignment tooling."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass
from typing import Any, Iterable, Sequence


TOOL_SCHEMA_VERSION = 1
DEFAULT_USER_VERSION = 47
DEFAULT_ROOM_IDENTITY_HASH = "4e076c66571412594ff567eae85b68fc"
DEFAULT_BASELINE_RELATIVE_PATH = pathlib.Path(
    "artifacts/book-alignment/current/B0.db"
)
BASELINE_ENVIRONMENT_VARIABLE = "XMNOTE_BOOK_ALIGNMENT_BASELINE_PATH"
HEX_256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
HEX_128_PATTERN = re.compile(r"^[0-9a-f]{32}$")
SAFE_NAME_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,95}$")


class AlignmentError(RuntimeError):
    """Raised when a safety or alignment invariant is not satisfied."""


@dataclass(frozen=True)
class SourceComponent:
    """One frozen SQLite component and its role in the copied database triple."""

    kind: str
    path: pathlib.Path


@dataclass(frozen=True)
class FileObservation:
    """Metadata used to detect a source changing while it is being copied."""

    device: int
    inode: int
    size: int
    modified_ns: int


def utc_now() -> str:
    """Return a stable UTC timestamp for manifests and privacy-safe reports."""

    return dt.datetime.now(dt.timezone.utc).isoformat()


def json_digest(value: Any) -> str:
    """Hash a JSON-compatible value without exposing its original payload."""

    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        default=_json_default,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _json_default(value: Any) -> Any:
    if isinstance(value, bytes):
        return {"blobSha256": hashlib.sha256(value).hexdigest(), "byteCount": len(value)}
    if isinstance(value, pathlib.Path):
        return value.name
    return str(value)


def file_sha256(path: pathlib.Path) -> str:
    """Stream a file into SHA-256 without retaining database bytes in memory."""

    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def resolve_default_baseline(
    repository_root: pathlib.Path | None = None,
) -> pathlib.Path:
    """Resolve the shared private-baseline convention without requiring it to exist."""

    configured = os.environ.get(BASELINE_ENVIRONMENT_VARIABLE)
    if configured:
        return pathlib.Path(configured).expanduser()
    root = repository_root or pathlib.Path.cwd()
    return root / DEFAULT_BASELINE_RELATIVE_PATH


def ensure_safe_name(value: str, label: str) -> str:
    """Reject path-like or ambiguous identifiers before using them in artifact names."""

    if not SAFE_NAME_PATTERN.fullmatch(value):
        raise AlignmentError(
            f"{label} must match {SAFE_NAME_PATTERN.pattern!r}; got {value!r}"
        )
    return value


def ensure_private_directory(path: pathlib.Path) -> None:
    """Create artifact directories with user-only permissions when they are absent."""

    missing: list[pathlib.Path] = []
    cursor = path
    while not cursor.exists():
        missing.append(cursor)
        if cursor.parent == cursor:
            break
        cursor = cursor.parent
    path.mkdir(parents=True, exist_ok=True)
    for created in reversed(missing):
        try:
            created.chmod(0o700)
        except OSError:
            # Some mounted filesystems do not expose POSIX modes. File-level privacy
            # is still enforced below and the manifest records no source paths.
            pass


def write_json_exclusive(path: pathlib.Path, payload: Any, mode: int = 0o600) -> None:
    """Persist JSON without overwriting an earlier evidence artifact."""

    ensure_private_directory(path.parent)
    encoded = (
        json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    except FileExistsError as error:
        raise AlignmentError(f"Refusing to overwrite existing report: {path}") from error
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def copy_file_exclusive(source: pathlib.Path, destination: pathlib.Path, mode: int) -> None:
    """Copy a completed artifact to a new path while refusing replacement."""

    ensure_private_directory(destination.parent)
    try:
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    except FileExistsError as error:
        raise AlignmentError(f"Refusing to overwrite existing file: {destination}") from error
    try:
        with source.open("rb") as input_handle, os.fdopen(descriptor, "wb") as output_handle:
            shutil.copyfileobj(input_handle, output_handle, length=1024 * 1024)
            output_handle.flush()
            os.fsync(output_handle.fileno())
    except BaseException:
        try:
            destination.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def observe_file(path: pathlib.Path) -> FileObservation:
    """Capture source metadata used to reject a changing SQLite triple."""

    stat = path.stat()
    if not path.is_file():
        raise AlignmentError(f"SQLite component is not a regular file: {path}")
    return FileObservation(
        device=stat.st_dev,
        inode=stat.st_ino,
        size=stat.st_size,
        modified_ns=stat.st_mtime_ns,
    )


def resolve_source_components(
    database: pathlib.Path,
    wal: pathlib.Path | None,
    shm: pathlib.Path | None,
) -> list[SourceComponent]:
    """Resolve an explicit or adjacent db/wal/shm triple without opening the source."""

    database = database.expanduser()
    if not database.is_file():
        raise AlignmentError(f"Database does not exist: {database}")

    adjacent_wal = pathlib.Path(f"{database}-wal")
    adjacent_shm = pathlib.Path(f"{database}-shm")
    resolved_wal = wal.expanduser() if wal is not None else (
        adjacent_wal if adjacent_wal.is_file() else None
    )
    resolved_shm = shm.expanduser() if shm is not None else (
        adjacent_shm if resolved_wal is not None and adjacent_shm.is_file() else None
    )

    if resolved_wal is not None and not resolved_wal.is_file():
        raise AlignmentError(f"WAL does not exist: {resolved_wal}")
    if resolved_shm is not None and not resolved_shm.is_file():
        raise AlignmentError(f"SHM does not exist: {resolved_shm}")
    if resolved_shm is not None and resolved_wal is None:
        raise AlignmentError("A SHM component cannot be captured without its WAL")

    components = [SourceComponent("db", database)]
    if resolved_wal is not None:
        components.append(SourceComponent("wal", resolved_wal))
    if resolved_shm is not None:
        components.append(SourceComponent("shm", resolved_shm))
    return components


def frozen_checkpoint_copy(
    database: pathlib.Path,
    wal: pathlib.Path | None,
    shm: pathlib.Path | None,
    destination: pathlib.Path,
    output_mode: int = 0o400,
) -> dict[str, Any]:
    """Copy a stable SQLite triple, checkpoint only the copy, and emit one DB file.

    The source files are never opened through SQLite. Their metadata is checked before
    and after copying so a concurrently changing capture is rejected rather than
    silently promoted to a baseline.
    """

    components = resolve_source_components(database, wal, shm)
    destination = destination.expanduser()
    if destination.exists():
        raise AlignmentError(f"Refusing to overwrite existing database: {destination}")
    resolved_destination = destination.resolve(strict=False)
    for component in components:
        if component.path.resolve() == resolved_destination:
            raise AlignmentError("Source and destination database paths must differ")

    ensure_private_directory(destination.parent)
    before = {component.kind: observe_file(component.path) for component in components}
    source_summary = [
        {
            "kind": component.kind,
            "byteCount": before[component.kind].size,
            "sha256": file_sha256(component.path),
        }
        for component in components
    ]

    with tempfile.TemporaryDirectory(
        prefix=".book-alignment-capture-", dir=destination.parent
    ) as temporary_directory:
        temporary_root = pathlib.Path(temporary_directory)
        staged_database = temporary_root / "capture.db"
        suffixes = {"db": "", "wal": "-wal", "shm": "-shm"}
        for component in components:
            shutil.copyfile(
                component.path,
                pathlib.Path(f"{staged_database}{suffixes[component.kind]}"),
            )

        after = {component.kind: observe_file(component.path) for component in components}
        changed = [kind for kind in before if before[kind] != after[kind]]
        if changed:
            raise AlignmentError(
                "Source SQLite components changed during capture: " + ", ".join(changed)
            )

        connection = sqlite3.connect(staged_database)
        try:
            connection.execute("PRAGMA busy_timeout = 5000")
            journal_mode = str(connection.execute("PRAGMA journal_mode").fetchone()[0])
            checkpoint_row = connection.execute(
                "PRAGMA wal_checkpoint(TRUNCATE)"
            ).fetchone()
        finally:
            connection.close()

        if checkpoint_row is None or len(checkpoint_row) != 3:
            raise AlignmentError("SQLite did not return a WAL checkpoint result")
        busy, remaining_frames, checkpointed_frames = map(int, checkpoint_row)
        if busy != 0:
            raise AlignmentError("Copied SQLite WAL could not be fully checkpointed")
        staged_wal = pathlib.Path(f"{staged_database}-wal")
        if staged_wal.exists() and staged_wal.stat().st_size != 0:
            raise AlignmentError("Checkpoint left a non-empty WAL; refusing single-file B0")

        health = inspect_database(staged_database)
        copy_file_exclusive(staged_database, destination, output_mode)

    destination_sha256 = file_sha256(destination)
    if destination_sha256 != file_sha256(destination):
        raise AlignmentError("Destination changed immediately after capture")
    return {
        "sourceComponents": source_summary,
        "sourceStableDuringCopy": True,
        "sourceOpenedBySQLite": False,
        "checkpoint": {
            "journalModeBeforeCheckpoint": journal_mode,
            "busy": busy,
            "remainingFrames": remaining_frames,
            "checkpointedFrames": checkpointed_frames,
            "singleFile": True,
        },
        "database": health,
        "sha256": destination_sha256,
        "byteCount": destination.stat().st_size,
    }


def immutable_connection(path: pathlib.Path) -> sqlite3.Connection:
    """Open a single-file snapshot in immutable read-only mode without sidecars."""

    if not path.is_file():
        raise AlignmentError(f"Database does not exist: {path}")
    uri = f"{path.resolve().as_uri()}?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    return connection


def quoted(identifier: str) -> str:
    """Quote a SQLite identifier obtained from schema metadata."""

    return '"' + identifier.replace('"', '""') + '"'


def schema_fingerprint(
    connection: sqlite3.Connection,
    excluded_tables: Iterable[str] = (),
) -> dict[str, Any]:
    """Hash canonical sqlite_schema entries while retaining only structural metadata."""

    rows = connection.execute(
        """
        SELECT type, name, tbl_name, sql
        FROM sqlite_schema
        WHERE name NOT LIKE 'sqlite_temp_%'
        ORDER BY type, name, tbl_name
        """
    ).fetchall()
    excluded = set(excluded_tables)
    canonical = [
        {
            "type": str(row[0]),
            "name": str(row[1]),
            "table": str(row[2]),
            "sql": _normalize_schema_sql(row[3]),
        }
        for row in rows
        if str(row[1]) not in excluded and str(row[2]) not in excluded
    ]
    counts: dict[str, int] = {}
    for item in canonical:
        counts[item["type"]] = counts.get(item["type"], 0) + 1
    return {
        "algorithm": "sqlite-schema-v1",
        "sha256": json_digest(canonical),
        "objectCount": len(canonical),
        "objectCountsByType": dict(sorted(counts.items())),
    }


def _normalize_schema_sql(value: Any) -> str | None:
    if value is None:
        return None
    return " ".join(str(value).split())


def _pragma_result(connection: sqlite3.Connection, pragma: str) -> dict[str, Any]:
    rows = [tuple(row) for row in connection.execute(f"PRAGMA {pragma}").fetchall()]
    passed = len(rows) == 1 and len(rows[0]) == 1 and str(rows[0][0]).lower() == "ok"
    return {
        "status": "ok" if passed else "failed",
        "resultCount": len(rows),
        "resultDigest": json_digest(rows),
    }


def foreign_key_summary(connection: sqlite3.Connection) -> dict[str, Any]:
    """Describe foreign-key violations by count and hashes, never row identifiers."""

    rows = [tuple(row) for row in connection.execute("PRAGMA foreign_key_check")]
    signatures = sorted(json_digest(row) for row in rows)
    return {
        "violationCount": len(rows),
        "violationDigests": signatures,
        "setDigest": json_digest(signatures),
    }


def room_identity_hash(connection: sqlite3.Connection) -> str | None:
    """Read Room's schema identity marker without reading any business payload."""

    table = connection.execute(
        "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'room_master_table'"
    ).fetchone()
    if table is None:
        return None
    columns = {
        str(row[1]) for row in connection.execute("PRAGMA table_info(room_master_table)")
    }
    if not {"id", "identity_hash"}.issubset(columns):
        return None
    row = connection.execute(
        "SELECT identity_hash FROM room_master_table WHERE id = 42"
    ).fetchone()
    return None if row is None or row[0] is None else str(row[0])


def table_row_counts(connection: sqlite3.Connection) -> dict[str, int]:
    """Return structural row counts for diagnostics without exposing row values."""

    names = [
        str(row[0])
        for row in connection.execute(
            """
            SELECT name
            FROM sqlite_schema
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
    ]
    return {
        name: int(connection.execute(f"SELECT COUNT(*) FROM {quoted(name)}").fetchone()[0])
        for name in names
    }


def inspect_database(path: pathlib.Path) -> dict[str, Any]:
    """Collect the baseline health and schema contract using read-only SQLite access."""

    connection = immutable_connection(path)
    try:
        user_version = int(connection.execute("PRAGMA user_version").fetchone()[0])
        return {
            "integrityCheck": _pragma_result(connection, "integrity_check"),
            "quickCheck": _pragma_result(connection, "quick_check"),
            "foreignKeyCheck": foreign_key_summary(connection),
            "userVersion": user_version,
            "roomIdentityHash": room_identity_hash(connection),
            "schemaFingerprint": schema_fingerprint(connection),
            "tableRowCounts": table_row_counts(connection),
        }
    finally:
        connection.close()


def validate_database_contract(
    metadata: dict[str, Any],
    *,
    expected_user_version: int | None,
    expected_room_identity_hash: str | None,
    expected_schema_fingerprint: str | None,
    require_no_foreign_key_violations: bool,
) -> list[dict[str, Any]]:
    """Return privacy-safe contract violations for one inspected database."""

    failures: list[dict[str, Any]] = []
    for key in ("integrityCheck", "quickCheck"):
        if metadata[key]["status"] != "ok":
            failures.append({"reason": key, "resultDigest": metadata[key]["resultDigest"]})
    if expected_user_version is not None and metadata["userVersion"] != expected_user_version:
        failures.append(
            {
                "reason": "user-version",
                "expected": expected_user_version,
                "actual": metadata["userVersion"],
            }
        )
    if (
        expected_room_identity_hash is not None
        and metadata["roomIdentityHash"] != expected_room_identity_hash
    ):
        failures.append(
            {
                "reason": "room-identity-hash",
                "expected": expected_room_identity_hash,
                "actual": metadata["roomIdentityHash"],
            }
        )
    actual_schema = metadata["schemaFingerprint"]["sha256"]
    if expected_schema_fingerprint is not None and actual_schema != expected_schema_fingerprint:
        failures.append(
            {
                "reason": "schema-fingerprint",
                "expected": expected_schema_fingerprint,
                "actual": actual_schema,
            }
        )
    if (
        require_no_foreign_key_violations
        and metadata["foreignKeyCheck"]["violationCount"] != 0
    ):
        failures.append(
            {
                "reason": "foreign-key-violations",
                "violationCount": metadata["foreignKeyCheck"]["violationCount"],
                "setDigest": metadata["foreignKeyCheck"]["setDigest"],
            }
        )
    return failures


def validate_sha256(value: str, label: str) -> str:
    """Normalize and validate a SHA-256 value supplied at a trust boundary."""

    normalized = value.lower()
    if not HEX_256_PATTERN.fullmatch(normalized):
        raise AlignmentError(f"{label} must be 64 lowercase hexadecimal characters")
    return normalized


def load_json(path: pathlib.Path) -> Any:
    """Read one UTF-8 JSON file with a concise domain error."""

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AlignmentError(f"Unable to load JSON {path}: {error}") from error


def privacy_policy() -> str:
    """Return the report policy shared by all book-alignment commands."""

    return (
        "Reports contain schema names, structural counts, logical aliases and SHA-256 "
        "digests only; database row payloads, binding values and source paths are omitted."
    )


def unique_sequence(values: Iterable[str], label: str) -> list[str]:
    """Materialize a sequence and reject duplicates that weaken a contract."""

    materialized = list(values)
    duplicates = sorted({value for value in materialized if materialized.count(value) > 1})
    if duplicates:
        raise AlignmentError(f"Duplicate {label}: {', '.join(duplicates)}")
    return materialized


def ensure_keys(
    value: Any,
    *,
    required: Sequence[str],
    allowed: Sequence[str] | None,
    label: str,
) -> dict[str, Any]:
    """Validate JSON object shape for the dependency-free contract validator."""

    if not isinstance(value, dict):
        raise AlignmentError(f"{label} must be an object")
    missing = [key for key in required if key not in value]
    if missing:
        raise AlignmentError(f"{label} is missing required keys: {', '.join(missing)}")
    if allowed is not None:
        extras = sorted(set(value) - set(allowed))
        if extras:
            raise AlignmentError(f"{label} has unknown keys: {', '.join(extras)}")
    return value
