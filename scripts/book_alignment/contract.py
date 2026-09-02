#!/usr/bin/env python3
"""Dependency-free validation and private binding resolution for alignment cases."""

from __future__ import annotations

import copy
import pathlib
import re
from dataclasses import dataclass
from typing import Any

from .common import (
    AlignmentError,
    HEX_128_PATTERN,
    HEX_256_PATTERN,
    SAFE_NAME_PATTERN,
    ensure_keys,
    file_sha256,
    load_json,
    unique_sequence,
)


CASE_STATUSES = {
    "exact-current",
    "platform-variant",
    "known-android-bug-compat",
    "safety-exception",
    "pending-protocol",
}
ENTITY_TYPES = {
    "book",
    "group",
    "tag",
    "source",
    "readStatus",
    "collection",
    "author",
    "publisher",
    "categoryContent",
    "other",
}
ALIAS_SELECTORS = {
    "active-book": "book",
    "active-ungrouped-book": "book",
    "active-empty-group": "group",
    "active-non-empty-group": "group",
}
SQL_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
PLACEHOLDER_BINDINGS = {
    "${B0_SHA256}": "baselineSha256",
    "${SCHEMA_FINGERPRINT}": "schemaFingerprint",
    "${RUNTIME_PROFILE_SHA256}": "runtimeProfileSha256",
    "${SETUP_SQL_SHA256}": "setupSqlSha256",
}
RUNTIME_SETTING_KEYS = {
    "bookSortMode",
    "bookGroupingMode",
    "newBookPosition",
}


@dataclass(frozen=True)
class ContractBundle:
    """A public scenario plus its in-memory private aliases and resolved hashes."""

    case: dict[str, Any]
    bindings: dict[str, Any]
    resolved_case: dict[str, Any]
    runtime_profile: dict[str, Any] | None


def _safe_name(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SAFE_NAME_PATTERN.fullmatch(value):
        raise AlignmentError(f"{label} must be a safe logical name")
    return value


def _sql_identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SQL_IDENTIFIER_PATTERN.fullmatch(value):
        raise AlignmentError(f"{label} must be a SQLite identifier")
    return value


def _non_empty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AlignmentError(f"{label} must be a non-empty string")
    return value


def _list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise AlignmentError(f"{label} must be an array")
    return value


def _sha_or_placeholder(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise AlignmentError(f"{label} must be a SHA-256 or local binding placeholder")
    if HEX_256_PATTERN.fullmatch(value) or value in PLACEHOLDER_BINDINGS:
        return value
    raise AlignmentError(f"{label} is not a SHA-256 or supported binding placeholder")


def validate_case_payload(case: Any) -> dict[str, Any]:
    """Validate the executable invariants represented by the published JSON Schema."""

    case = ensure_keys(
        case,
        required=(
            "schemaVersion",
            "caseId",
            "title",
            "status",
            "baseline",
            "runtimeProfile",
            "aliases",
            "intent",
            "adapters",
            "database",
            "setup",
            "oracle",
            "lifecycle",
        ),
        allowed=(
            "schemaVersion",
            "caseId",
            "title",
            "status",
            "baseline",
            "targetDatabase",
            "runtimeProfile",
            "aliases",
            "intent",
            "adapters",
            "database",
            "setup",
            "oracle",
            "lifecycle",
        ),
        label="case",
    )
    if case["schemaVersion"] != 1:
        raise AlignmentError("case.schemaVersion must be 1")
    _safe_name(case["caseId"], "case.caseId")
    _non_empty_string(case["title"], "case.title")
    if case["status"] not in CASE_STATUSES:
        raise AlignmentError("case.status is unsupported")

    baseline = ensure_keys(
        case["baseline"],
        required=("sha256", "userVersion", "roomIdentityHash", "schemaFingerprint"),
        allowed=("sha256", "userVersion", "roomIdentityHash", "schemaFingerprint"),
        label="case.baseline",
    )
    _sha_or_placeholder(baseline["sha256"], "case.baseline.sha256")
    if not isinstance(baseline["userVersion"], int) or baseline["userVersion"] < 1:
        raise AlignmentError("case.baseline.userVersion must be a positive integer")
    if not isinstance(baseline["roomIdentityHash"], str) or not HEX_128_PATTERN.fullmatch(
        baseline["roomIdentityHash"]
    ):
        raise AlignmentError("case.baseline.roomIdentityHash must be 32 lowercase hex chars")
    _sha_or_placeholder(
        baseline["schemaFingerprint"], "case.baseline.schemaFingerprint"
    )

    if "targetDatabase" in case:
        target_database = ensure_keys(
            case["targetDatabase"],
            required=("userVersion", "roomIdentityHash", "schemaFingerprint"),
            allowed=("userVersion", "roomIdentityHash", "schemaFingerprint"),
            label="case.targetDatabase",
        )
        if (
            not isinstance(target_database["userVersion"], int)
            or target_database["userVersion"] < baseline["userVersion"]
        ):
            raise AlignmentError(
                "case.targetDatabase.userVersion must be at least the baseline version"
            )
        if (
            not isinstance(target_database["roomIdentityHash"], str)
            or not HEX_128_PATTERN.fullmatch(target_database["roomIdentityHash"])
        ):
            raise AlignmentError(
                "case.targetDatabase.roomIdentityHash must be 32 lowercase hex chars"
            )
        _sha_or_placeholder(
            target_database["schemaFingerprint"],
            "case.targetDatabase.schemaFingerprint",
        )

    runtime = ensure_keys(
        case["runtimeProfile"],
        required=("sha256", "requiredSettings"),
        allowed=("sha256", "requiredSettings"),
        label="case.runtimeProfile",
    )
    _sha_or_placeholder(runtime["sha256"], "case.runtimeProfile.sha256")
    required_settings = unique_sequence(
        (_safe_name(item, "runtime setting") for item in _list(
            runtime["requiredSettings"], "case.runtimeProfile.requiredSettings"
        )),
        "runtime setting",
    )
    unknown_settings = sorted(set(required_settings) - RUNTIME_SETTING_KEYS)
    if unknown_settings:
        raise AlignmentError(
            "Unknown platform-neutral runtime settings: " + ", ".join(unknown_settings)
        )

    aliases = _list(case["aliases"], "case.aliases")
    if not aliases:
        raise AlignmentError("case.aliases must not be empty")
    alias_entities: dict[str, str] = {}
    for index, raw_alias in enumerate(aliases):
        alias = ensure_keys(
            raw_alias,
            required=("name", "entity", "description", "requirements"),
            allowed=("name", "entity", "description", "requirements", "selector"),
            label=f"case.aliases[{index}]",
        )
        name = _safe_name(alias["name"], f"case.aliases[{index}].name")
        if name in alias_entities:
            raise AlignmentError(f"Duplicate logical alias: {name}")
        if alias["entity"] not in ENTITY_TYPES:
            raise AlignmentError(f"Unsupported entity for alias {name}")
        if "selector" in alias and alias["selector"] not in ALIAS_SELECTORS:
            raise AlignmentError(f"Unsupported selector for alias {name}")
        if (
            "selector" in alias
            and ALIAS_SELECTORS[alias["selector"]] != alias["entity"]
        ):
            raise AlignmentError(
                f"Selector {alias['selector']} does not match alias {name} entity"
            )
        alias_entities[name] = alias["entity"]
        _non_empty_string(alias["description"], f"alias {name} description")
        for requirement in _list(alias["requirements"], f"alias {name} requirements"):
            _non_empty_string(requirement, f"alias {name} requirement")

    _validate_intent(case["intent"], alias_entities)
    _validate_adapters(case["adapters"], alias_entities)
    _validate_database(case["database"], case["status"])
    _validate_setup(case["setup"])
    _validate_oracle(case["oracle"], alias_entities)
    _validate_lifecycle(case["lifecycle"])
    return case


def _validate_intent(value: Any, aliases: dict[str, str]) -> None:
    intent = ensure_keys(
        value,
        required=("summary", "selectionScope", "confirmation", "outcome", "repeatTrigger"),
        allowed=(
            "summary",
            "selectionScope",
            "confirmation",
            "outcome",
            "repeatTrigger",
            "selectedAliases",
        ),
        label="case.intent",
    )
    _non_empty_string(intent["summary"], "case.intent.summary")
    if intent["selectionScope"] not in {
        "single",
        "batch",
        "group-expanded",
        "all-visible",
        "none",
    }:
        raise AlignmentError("case.intent.selectionScope is unsupported")
    if intent["confirmation"] not in {
        "immediate",
        "required",
        "cancellable",
        "destructive-required",
    }:
        raise AlignmentError("case.intent.confirmation is unsupported")
    if intent["outcome"] not in {"committed", "cancelled", "failed"}:
        raise AlignmentError("case.intent.outcome is unsupported")
    if intent["repeatTrigger"] not in {"once", "idempotent", "single-commit"}:
        raise AlignmentError("case.intent.repeatTrigger is unsupported")
    selected = intent.get("selectedAliases", [])
    for alias in _list(selected, "case.intent.selectedAliases"):
        if alias not in aliases:
            raise AlignmentError(f"Selected alias is not declared: {alias}")


def _validate_adapters(value: Any, aliases: dict[str, str]) -> None:
    adapters = ensure_keys(
        value,
        required=("android", "ios"),
        allowed=("android", "ios"),
        label="case.adapters",
    )
    for platform in ("android", "ios"):
        adapter = ensure_keys(
            adapters[platform],
            required=("entry", "steps"),
            allowed=("entry", "steps"),
            label=f"case.adapters.{platform}",
        )
        _non_empty_string(adapter["entry"], f"{platform} entry")
        steps = _list(adapter["steps"], f"{platform} steps")
        if not steps:
            raise AlignmentError(f"case.adapters.{platform}.steps must not be empty")
        for index, raw_step in enumerate(steps):
            step = ensure_keys(
                raw_step,
                required=("action",),
                allowed=("action", "targetAlias", "checkpoint", "semanticExpectation"),
                label=f"{platform} step {index}",
            )
            _non_empty_string(step["action"], f"{platform} step action")
            if "targetAlias" in step and step["targetAlias"] not in aliases:
                raise AlignmentError(
                    f"{platform} step references undeclared alias: {step['targetAlias']}"
                )
            if "checkpoint" in step and step["checkpoint"] not in {
                f"S{index}" for index in range(8)
            }:
                raise AlignmentError(f"{platform} step checkpoint is invalid")


def _validate_database(value: Any, status: str) -> None:
    database = ensure_keys(
        value,
        required=(
            "allowedWrites",
            "forbiddenWrites",
            "platformInternalTables",
            "timeColumns",
            "strictExceptions",
        ),
        allowed=(
            "allowedWrites",
            "forbiddenWrites",
            "platformInternalTables",
            "timeColumns",
            "strictExceptions",
        ),
        label="case.database",
    )
    for collection_name in ("allowedWrites", "forbiddenWrites"):
        for index, rule in enumerate(_list(database[collection_name], collection_name)):
            _validate_write_rule(rule, f"{collection_name}[{index}]")

    table_names: set[str] = set()
    for index, raw_table in enumerate(
        _list(database["platformInternalTables"], "platformInternalTables")
    ):
        table = ensure_keys(
            raw_table,
            required=("table", "platform", "reason"),
            allowed=("table", "platform", "reason"),
            label=f"platformInternalTables[{index}]",
        )
        name = _sql_identifier(table["table"], "platform internal table")
        if name in table_names:
            raise AlignmentError(f"Duplicate platform-internal table: {name}")
        table_names.add(name)
        if table["platform"] not in {"android", "ios"}:
            raise AlignmentError("platformInternalTables.platform is unsupported")
        _non_empty_string(table["reason"], "platform internal table reason")

    time_keys: set[tuple[str, str]] = set()
    for index, raw_rule in enumerate(_list(database["timeColumns"], "timeColumns")):
        rule = ensure_keys(
            raw_rule,
            required=(
                "table",
                "column",
                "unit",
                "monotonic",
                "allowZeroOnInsert",
                "requireOperationWindow",
                "reason",
            ),
            allowed=(
                "table",
                "column",
                "unit",
                "monotonic",
                "allowZeroOnInsert",
                "requireOperationWindow",
                "toleranceMillis",
                "reason",
            ),
            label=f"timeColumns[{index}]",
        )
        key = (
            _sql_identifier(rule["table"], "time table"),
            _sql_identifier(rule["column"], "time column"),
        )
        if key in time_keys:
            raise AlignmentError(f"Duplicate time rule: {key[0]}.{key[1]}")
        time_keys.add(key)
        if rule["unit"] not in {"epoch-millis", "epoch-seconds"}:
            raise AlignmentError("timeColumns.unit is unsupported")
        for boolean_key in ("monotonic", "allowZeroOnInsert", "requireOperationWindow"):
            if not isinstance(rule[boolean_key], bool):
                raise AlignmentError(f"timeColumns.{boolean_key} must be boolean")
        tolerance = rule.get("toleranceMillis", 0)
        if not isinstance(tolerance, int) or not 0 <= tolerance <= 60_000:
            raise AlignmentError("timeColumns.toleranceMillis must be 0...60000")
        _non_empty_string(rule["reason"], "time rule reason")

    exceptions = _list(database["strictExceptions"], "strictExceptions")
    if exceptions and status not in {
        "known-android-bug-compat",
        "safety-exception",
        "pending-protocol",
    }:
        raise AlignmentError(
            "strictExceptions require known-android-bug-compat, safety-exception or pending-protocol"
        )
    codes: set[str] = set()
    for index, raw_exception in enumerate(exceptions):
        exception = ensure_keys(
            raw_exception,
            required=("code", "reasons", "maxMatches", "rationale"),
            allowed=(
                "code",
                "reasons",
                "table",
                "column",
                "androidCount",
                "iosCount",
                "maxMatches",
                "rationale",
            ),
            label=f"strictExceptions[{index}]",
        )
        code = _safe_name(exception["code"], "strict exception code")
        if code in codes:
            raise AlignmentError(f"Duplicate strict exception code: {code}")
        codes.add(code)
        reasons = _list(exception["reasons"], f"strict exception {code} reasons")
        if not reasons:
            raise AlignmentError(f"Strict exception {code} must list exact reasons")
        for reason in reasons:
            _non_empty_string(reason, f"strict exception {code} reason")
        if "table" in exception:
            _sql_identifier(exception["table"], f"strict exception {code} table")
        if "column" in exception:
            _sql_identifier(exception["column"], f"strict exception {code} column")
        if not isinstance(exception["maxMatches"], int) or exception["maxMatches"] < 1:
            raise AlignmentError(f"Strict exception {code} maxMatches must be positive")
        _non_empty_string(exception["rationale"], f"strict exception {code} rationale")


def _validate_write_rule(value: Any, label: str) -> None:
    rule = ensure_keys(
        value,
        required=("table", "operations", "platforms", "reason"),
        allowed=("table", "operations", "columns", "platforms", "reason"),
        label=label,
    )
    _sql_identifier(rule["table"], f"{label}.table")
    operations = unique_sequence(
        _list(rule["operations"], f"{label}.operations"), f"{label} operation"
    )
    if not operations or not set(operations) <= {"insert", "update", "delete"}:
        raise AlignmentError(f"{label}.operations is unsupported")
    platforms = unique_sequence(
        _list(rule["platforms"], f"{label}.platforms"), f"{label} platform"
    )
    if not platforms or not set(platforms) <= {"android", "ios"}:
        raise AlignmentError(f"{label}.platforms is unsupported")
    columns = rule.get("columns", [])
    if "update" in operations and not columns:
        raise AlignmentError(f"{label}.columns is required for update")
    for column in _list(columns, f"{label}.columns"):
        if column != "*":
            _sql_identifier(column, f"{label} column")
    _non_empty_string(rule["reason"], f"{label}.reason")


def _validate_setup(value: Any) -> None:
    if not isinstance(value, dict) or value.get("mode") not in {
        "none",
        "deterministic-sql",
    }:
        raise AlignmentError("case.setup.mode is unsupported")
    if value["mode"] == "none":
        ensure_keys(
            value,
            required=("mode",),
            allowed=("mode",),
            label="case.setup",
        )
        return
    setup = ensure_keys(
        value,
        required=("mode", "sqlFile", "sha256", "reason"),
        allowed=("mode", "sqlFile", "sha256", "reason"),
        label="case.setup",
    )
    sql_file = _non_empty_string(setup["sqlFile"], "case.setup.sqlFile")
    pure_path = pathlib.PurePosixPath(sql_file)
    if pure_path.is_absolute() or ".." in pure_path.parts or pure_path.suffix != ".sql":
        raise AlignmentError("case.setup.sqlFile must be a normalized relative .sql path")
    _sha_or_placeholder(setup["sha256"], "case.setup.sha256")
    _non_empty_string(setup["reason"], "case.setup.reason")


def _validate_oracle(value: Any, aliases: dict[str, str]) -> None:
    oracle = ensure_keys(
        value,
        required=("currentOracle", "desiredSemantics", "semanticProjections"),
        allowed=("currentOracle", "desiredSemantics", "semanticProjections"),
        label="case.oracle",
    )
    _non_empty_string(oracle["currentOracle"], "case.oracle.currentOracle")
    _non_empty_string(oracle["desiredSemantics"], "case.oracle.desiredSemantics")
    projection_names: set[str] = set()
    for index, raw_projection in enumerate(
        _list(oracle["semanticProjections"], "semanticProjections")
    ):
        projection = ensure_keys(
            raw_projection,
            required=(
                "name",
                "description",
                "sql",
                "mode",
                "columns",
                "parameters",
                "compareAndroidIOSAfter",
                "expected",
            ),
            allowed=(
                "name",
                "description",
                "sql",
                "mode",
                "columns",
                "parameters",
                "compareAndroidIOSAfter",
                "expected",
            ),
            label=f"semanticProjections[{index}]",
        )
        name = _safe_name(projection["name"], "projection name")
        if name in projection_names:
            raise AlignmentError(f"Duplicate semantic projection: {name}")
        projection_names.add(name)
        _non_empty_string(projection["description"], f"projection {name} description")
        sql = _non_empty_string(projection["sql"], f"projection {name} SQL")
        stripped = sql.strip()
        if not re.match(r"^(SELECT|WITH)\b", stripped, flags=re.IGNORECASE):
            raise AlignmentError(f"Projection {name} must be a SELECT/WITH query")
        if ";" in stripped.rstrip(";"):
            raise AlignmentError(f"Projection {name} must contain exactly one statement")
        if projection["mode"] not in {"ordered-rows", "unordered-rows", "scalar"}:
            raise AlignmentError(f"Projection {name} mode is unsupported")
        columns = _list(projection["columns"], f"projection {name} columns")
        if not columns:
            raise AlignmentError(f"Projection {name} must declare output columns")
        column_names: set[str] = set()
        for column in columns:
            column = ensure_keys(
                column,
                required=("name",),
                allowed=("name", "aliasEntity"),
                label=f"projection {name} column",
            )
            column_name = _sql_identifier(column["name"], f"projection {name} column")
            if column_name in column_names:
                raise AlignmentError(f"Projection {name} has duplicate column {column_name}")
            column_names.add(column_name)
            if "aliasEntity" in column and column["aliasEntity"] not in ENTITY_TYPES:
                raise AlignmentError(f"Projection {name} aliasEntity is unsupported")
        parameters = ensure_keys(
            projection["parameters"],
            required=(),
            allowed=None,
            label=f"projection {name} parameters",
        )
        for parameter_name, parameter in parameters.items():
            _sql_identifier(parameter_name, f"projection {name} parameter")
            if not isinstance(parameter, dict) or set(parameter) not in (
                {"binding"},
                {"literal"},
            ):
                raise AlignmentError(
                    f"Projection {name} parameter {parameter_name} must use binding or literal"
                )
            if "binding" in parameter and parameter["binding"] not in aliases:
                raise AlignmentError(
                    f"Projection {name} references undeclared alias {parameter['binding']}"
                )
            if "literal" in parameter and not isinstance(
                parameter["literal"], (type(None), bool, int, float, str)
            ):
                raise AlignmentError(f"Projection {name} literal must be scalar")
        if not isinstance(projection["compareAndroidIOSAfter"], bool):
            raise AlignmentError(f"Projection {name} comparison flag must be boolean")
        expected = ensure_keys(
            projection["expected"],
            required=(),
            allowed=("androidBefore", "iosBefore", "androidAfter", "iosAfter"),
            label=f"projection {name} expected",
        )
        alias_columns = {
            column["name"]: column["aliasEntity"]
            for column in columns
            if "aliasEntity" in column
        }
        for expectation_name, expectation in expected.items():
            _validate_expected_aliases(
                expectation,
                alias_columns,
                aliases,
                f"projection {name} {expectation_name}",
            )


def _validate_expected_aliases(
    expectation: Any,
    alias_columns: dict[str, str],
    aliases: dict[str, str],
    label: str,
) -> None:
    rows = expectation if isinstance(expectation, list) else [expectation]
    for row in rows:
        if not isinstance(row, dict):
            continue
        for column_name, entity in alias_columns.items():
            if column_name not in row:
                continue
            alias = row[column_name]
            if alias not in aliases:
                raise AlignmentError(f"{label} uses undeclared alias {alias!r}")
            if aliases[alias] != entity:
                raise AlignmentError(
                    f"{label} alias {alias} has entity {aliases[alias]}, expected {entity}"
                )


def _validate_lifecycle(value: Any) -> None:
    lifecycle = ensure_keys(
        value,
        required=(
            "checkpoints",
            "requireS3S4BusinessStable",
            "requireRestart",
            "restoreDirection",
        ),
        allowed=(
            "checkpoints",
            "requireS3S4BusinessStable",
            "requireRestart",
            "restoreDirection",
        ),
        label="case.lifecycle",
    )
    stages: list[str] = []
    for index, raw_checkpoint in enumerate(
        _list(lifecycle["checkpoints"], "case.lifecycle.checkpoints")
    ):
        checkpoint = ensure_keys(
            raw_checkpoint,
            required=("stage", "meaning"),
            allowed=("stage", "meaning"),
            label=f"checkpoint[{index}]",
        )
        if checkpoint["stage"] not in {f"S{number}" for number in range(8)}:
            raise AlignmentError("Lifecycle checkpoint stage is invalid")
        stages.append(checkpoint["stage"])
        _non_empty_string(checkpoint["meaning"], "checkpoint meaning")
    unique_sequence(stages, "lifecycle checkpoint")
    missing = [stage for stage in ("S0", "S1", "S2", "S3", "S4") if stage not in stages]
    if missing:
        raise AlignmentError("Lifecycle must define S0-S4: " + ", ".join(missing))
    if lifecycle["restoreDirection"] not in {"none", "android-to-ios"}:
        raise AlignmentError("case.lifecycle.restoreDirection is unsupported")
    if lifecycle["restoreDirection"] == "android-to-ios":
        restore_missing = [stage for stage in ("S5", "S6", "S7") if stage not in stages]
        if restore_missing:
            raise AlignmentError(
                "Android-to-iOS restore cases must define S5-S7: "
                + ", ".join(restore_missing)
            )
    for key in ("requireS3S4BusinessStable", "requireRestart"):
        if not isinstance(lifecycle[key], bool):
            raise AlignmentError(f"case.lifecycle.{key} must be boolean")


def validate_bindings_payload(
    payload: Any, aliases: dict[str, str]
) -> dict[str, Any]:
    """Validate local-only IDs while ensuring they never enter a generated report."""

    bindings = ensure_keys(
        payload,
        required=(
            "schemaVersion",
            "baselineSha256",
            "schemaFingerprint",
            "runtimeProfileSha256",
            "aliases",
        ),
        allowed=(
            "schemaVersion",
            "baselineSha256",
            "schemaFingerprint",
            "runtimeProfileSha256",
            "setupSqlSha256",
            "aliases",
        ),
        label="bindings",
    )
    if bindings["schemaVersion"] != 1:
        raise AlignmentError("bindings.schemaVersion must be 1")
    for key in ("baselineSha256", "schemaFingerprint", "runtimeProfileSha256"):
        if not isinstance(bindings[key], str) or not HEX_256_PATTERN.fullmatch(bindings[key]):
            raise AlignmentError(f"bindings.{key} must be a lowercase SHA-256")
    if "setupSqlSha256" in bindings and not HEX_256_PATTERN.fullmatch(
        str(bindings["setupSqlSha256"])
    ):
        raise AlignmentError("bindings.setupSqlSha256 must be a lowercase SHA-256")
    private_aliases = ensure_keys(
        bindings["aliases"], required=(), allowed=None, label="bindings.aliases"
    )
    for alias_name, expected_entity in aliases.items():
        if alias_name not in private_aliases:
            raise AlignmentError(f"bindings is missing alias: {alias_name}")
        binding = ensure_keys(
            private_aliases[alias_name],
            required=("entity", "id"),
            allowed=("entity", "id", "privateLabel"),
            label=f"bindings.aliases.{alias_name}",
        )
        if binding["entity"] != expected_entity:
            raise AlignmentError(
                f"bindings alias {alias_name} entity does not match the public case"
            )
        if isinstance(binding["id"], bool) or not isinstance(binding["id"], (int, str)):
            raise AlignmentError(f"bindings alias {alias_name} id must be integer or string")
    return bindings


def validate_runtime_profile_payload(payload: Any) -> dict[str, Any]:
    """Allow only the non-credential settings approved by the alignment plan."""

    profile = ensure_keys(
        payload,
        required=("schemaVersion", "settings"),
        allowed=("schemaVersion", "settings"),
        label="runtime profile",
    )
    if profile["schemaVersion"] != 1:
        raise AlignmentError("runtime profile schemaVersion must be 1")
    settings = ensure_keys(
        profile["settings"], required=(), allowed=RUNTIME_SETTING_KEYS, label="settings"
    )
    for key, value in settings.items():
        if not isinstance(value, (type(None), bool, int, float, str)):
            raise AlignmentError(f"runtime setting {key} must be a scalar")
    return profile


def _resolve_case_hashes(
    case: dict[str, Any], bindings: dict[str, Any]
) -> dict[str, Any]:
    resolved = copy.deepcopy(case)

    def replace(value: str, label: str) -> str:
        if value in PLACEHOLDER_BINDINGS:
            binding_key = PLACEHOLDER_BINDINGS[value]
            if binding_key not in bindings:
                raise AlignmentError(f"{label} requires bindings.{binding_key}")
            return str(bindings[binding_key])
        binding_key_by_label = {
            "baseline SHA": "baselineSha256",
            "schema fingerprint": "schemaFingerprint",
            "runtime profile SHA": "runtimeProfileSha256",
            "setup SQL SHA": "setupSqlSha256",
        }
        binding_key = binding_key_by_label[label]
        if binding_key in bindings and bindings[binding_key] != value:
            raise AlignmentError(f"Public {label} does not match local bindings")
        return value

    resolved["baseline"]["sha256"] = replace(
        resolved["baseline"]["sha256"], "baseline SHA"
    )
    resolved["baseline"]["schemaFingerprint"] = replace(
        resolved["baseline"]["schemaFingerprint"], "schema fingerprint"
    )
    resolved["runtimeProfile"]["sha256"] = replace(
        resolved["runtimeProfile"]["sha256"], "runtime profile SHA"
    )
    if resolved["setup"]["mode"] == "deterministic-sql":
        resolved["setup"]["sha256"] = replace(
            resolved["setup"]["sha256"], "setup SQL SHA"
        )
    return resolved


def load_contract_bundle(
    case_path: pathlib.Path,
    bindings_path: pathlib.Path,
    runtime_profile_path: pathlib.Path | None,
    *,
    runnable: bool,
) -> ContractBundle:
    """Load a public case and private inputs, verifying hashes before any DB access."""

    case = validate_case_payload(load_json(case_path))
    alias_entities = {item["name"]: item["entity"] for item in case["aliases"]}
    bindings = validate_bindings_payload(load_json(bindings_path), alias_entities)
    resolved = _resolve_case_hashes(case, bindings)

    profile: dict[str, Any] | None = None
    if runtime_profile_path is not None:
        profile = validate_runtime_profile_payload(load_json(runtime_profile_path))
        actual_profile_sha = file_sha256(runtime_profile_path)
        if actual_profile_sha != resolved["runtimeProfile"]["sha256"]:
            raise AlignmentError("runtime-profile.json SHA-256 does not match bindings")
        missing_settings = sorted(
            set(resolved["runtimeProfile"]["requiredSettings"])
            - set(profile["settings"])
        )
        if missing_settings:
            raise AlignmentError(
                "runtime profile is missing settings: " + ", ".join(missing_settings)
            )
    elif runnable and resolved["runtimeProfile"]["requiredSettings"]:
        raise AlignmentError("Runnable validation requires --runtime-profile")

    if runnable and resolved["status"] == "pending-protocol":
        raise AlignmentError("pending-protocol cases are intentionally not runnable")
    return ContractBundle(
        case=case,
        bindings=bindings,
        resolved_case=resolved,
        runtime_profile=profile,
    )
