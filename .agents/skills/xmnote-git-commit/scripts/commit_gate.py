#!/usr/bin/env python3
"""XMNote AI Git history gate.

The gate is intentionally implemented with the Python standard library so it can
run from Codex hooks before project dependencies are available.  It does not
replace Git hooks used by humans; it only issues and verifies AI attestations.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


VERSION = 1
GATE_RELATIVE_DIR = Path("artifacts/git-commit-gate")
ATTESTATION_NAME = "attestation.json"
MESSAGE_NAME = "message.txt"
CONSUMED_NAME = "last-consumed.json"

ALLOWED_TYPES = {
    "feat",
    "fix",
    "refactor",
    "chore",
    "docs",
    "test",
    "build",
    "ci",
    "revert",
}
SUBJECT_RE = re.compile(
    r"^(feat|fix|refactor|chore|docs|test|build|ci|revert)\(([^()\r\n]+)\): (\S.*)$"
)
SCOPE_RE = re.compile(
    r"^(?:feat|fix|refactor|chore|docs|test|build|ci|revert)\(([^()\r\n]+)\):"
)
KNOWLEDGE_CASE_RE = re.compile(r"^Knowledge-Case: IOS-BUG-\d{8}-\d{3}$", re.MULTILINE)
GENERIC_SUBJECTS = ("提交本地全部改动", "更新代码", "修复问题", "调整代码", "代码更新")

ALWAYS_REQUIRED_VALIDATIONS = (
    "git diff --cached --check",
    "bash scripts/verify_glossary.sh",
    "bash scripts/verify_l3_protocol_headers.sh",
    "bash scripts/verify_arch_docs_sync.sh",
    "bash scripts/verify_ai_bug_knowledge.sh",
    "python3 scripts/ai-knowledge/kb.py validate",
    "python3 scripts/design-system/ds.py lint --staged",
)
BASELINE_VALIDATION_ARGV = {
    "git diff --cached --check": ["git", "diff", "--cached", "--check"],
    "bash scripts/verify_glossary.sh": ["bash", "scripts/verify_glossary.sh"],
    "bash scripts/verify_l3_protocol_headers.sh": ["bash", "scripts/verify_l3_protocol_headers.sh"],
    "bash scripts/verify_arch_docs_sync.sh": ["bash", "scripts/verify_arch_docs_sync.sh"],
    "bash scripts/verify_ai_bug_knowledge.sh": ["bash", "scripts/verify_ai_bug_knowledge.sh"],
    "python3 scripts/ai-knowledge/kb.py validate": ["python3", "scripts/ai-knowledge/kb.py", "validate"],
    "python3 scripts/design-system/ds.py lint --staged": [
        "python3",
        "scripts/design-system/ds.py",
        "lint",
        "--staged",
    ],
}

HISTORY_COMMANDS = {"commit", "merge", "revert", "cherry-pick", "rebase"}
PERMANENTLY_FORBIDDEN_COMMANDS = {
    "am",
    "commit-tree",
    "fast-import",
    "filter-branch",
    "mktag",
    "mktree",
    "update-ref",
    "replace",
    "notes",
    "reset",
}
SHELL_SEPARATORS = {";", "&&", "||", "|", "&", "\n"}

GENERATED_OR_TEMP_PATTERNS = (
    re.compile(r"(^|/)\.DS_Store$"),
    re.compile(r"(^|/)(?:DerivedData|build|Build)(/|$)"),
    re.compile(r"(^|/)xcuserdata(/|$)"),
    re.compile(r"(^|/)artifacts/git-commit-gate(/|$)"),
    re.compile(r"\.(?:log|tmp|temp|swp|swo)$", re.IGNORECASE),
)
DEBUG_MARKERS = ("debugPrint(", "print(", "TODO", "FIXME", "#warning")


class GateError(RuntimeError):
    """A deterministic gate failure suitable for user-facing output."""


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_text(value: str) -> str:
    return sha256_bytes(value.encode("utf-8"))


def stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def run(
    args: list[str],
    *,
    cwd: Path,
    check: bool = True,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        args,
        cwd=cwd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "命令失败"
        raise GateError(f"{' '.join(args)}: {detail}")
    return completed


def git(repo: Path, *args: str, check: bool = True) -> str:
    return run(["git", *args], cwd=repo, check=check).stdout


def discover_repo(explicit: str | None = None, cwd: str | None = None) -> Path:
    if explicit:
        start = Path(explicit).expanduser().resolve()
    elif cwd:
        start = Path(cwd).expanduser().resolve()
    else:
        start = Path(__file__).resolve().parents[4]
    result = run(["git", "rev-parse", "--show-toplevel"], cwd=start, check=False)
    if result.returncode != 0:
        raise GateError(f"无法定位 Git 仓库：{start}")
    return Path(result.stdout.strip()).resolve()


def git_dir(repo: Path) -> Path:
    value = git(repo, "rev-parse", "--absolute-git-dir").strip()
    return Path(value).resolve()


def git_head(repo: Path) -> str:
    result = run(["git", "rev-parse", "--verify", "HEAD"], cwd=repo, check=False)
    return result.stdout.strip() if result.returncode == 0 else "UNBORN"


def branch_name(repo: Path) -> str:
    result = run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], cwd=repo, check=False)
    return result.stdout.strip() if result.returncode == 0 else "DETACHED"


def split_nul(value: str) -> list[str]:
    return sorted(item for item in value.split("\0") if item)


def staged_paths(repo: Path, operation: str = "commit") -> list[str]:
    if operation == "amend" and git_head(repo) != "UNBORN":
        parent = run(["git", "rev-parse", "HEAD^"], cwd=repo, check=False)
        base = parent.stdout.strip() if parent.returncode == 0 else EMPTY_TREE
        return split_nul(git(repo, "diff", "--cached", "--name-only", "-z", base))
    return split_nul(git(repo, "diff", "--cached", "--name-only", "-z"))


def ordinary_staged_paths(repo: Path) -> list[str]:
    return split_nul(git(repo, "diff", "--cached", "--name-only", "-z"))


def unstaged_paths(repo: Path) -> list[str]:
    return split_nul(git(repo, "diff", "--name-only", "-z"))


def untracked_paths(repo: Path) -> list[str]:
    return split_nul(git(repo, "ls-files", "--others", "--exclude-standard", "-z"))


def index_tree(repo: Path) -> str:
    result = run(["git", "write-tree"], cwd=repo, check=False)
    if result.returncode == 0:
        return result.stdout.strip()
    return "UNMERGED"


def refs_digest(repo: Path) -> str:
    refs = git(repo, "for-each-ref", "--format=%(refname)%00%(objectname)")
    return sha256_text(refs)


def read_untracked_digest(repo: Path, paths: Iterable[str]) -> str:
    digest = hashlib.sha256()
    for relative in sorted(paths):
        path = repo / relative
        digest.update(relative.encode("utf-8", errors="surrogateescape"))
        digest.update(b"\0")
        try:
            if path.is_symlink():
                digest.update(os.readlink(path).encode("utf-8", errors="surrogateescape"))
            elif path.is_file():
                with path.open("rb") as handle:
                    while True:
                        chunk = handle.read(1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
            else:
                digest.update(b"<non-file>")
        except OSError as error:
            digest.update(f"<unreadable:{error}>".encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def workspace_snapshot(repo: Path) -> dict[str, Any]:
    untracked = untracked_paths(repo)
    status = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    cached_diff = git(repo, "diff", "--cached", "--binary", "--no-ext-diff")
    unstaged_diff = git(repo, "diff", "--binary", "--no-ext-diff")
    return {
        "status_digest": sha256_text(status),
        "cached_diff_digest": sha256_text(cached_diff),
        "unstaged_diff_digest": sha256_text(unstaged_diff),
        "untracked_digest": read_untracked_digest(repo, untracked),
        "untracked_paths": untracked,
    }


def workspace_digest(snapshot: dict[str, Any]) -> str:
    return sha256_text(stable_json(snapshot))


def history_scopes(repo: Path) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    log = run(
        ["git", "log", "--all", "--pretty=format:%H%x09%s"],
        cwd=repo,
        check=False,
    )
    if log.returncode != 0:
        return result
    for line in log.stdout.splitlines():
        commit, separator, subject = line.partition("\t")
        if not separator:
            continue
        match = SCOPE_RE.match(subject)
        if not match:
            continue
        scope = match.group(1)
        entry = result.setdefault(scope, {"count": 0, "examples": []})
        entry["count"] += 1
        if len(entry["examples"]) < 3:
            entry["examples"].append({"commit": commit, "subject": subject})
    return dict(sorted(result.items(), key=lambda item: (-item[1]["count"], item[0])))


def path_risks(paths: Iterable[str]) -> list[str]:
    risks: list[str] = []
    for path in sorted(paths):
        if any(pattern.search(path) for pattern in GENERATED_OR_TEMP_PATTERNS):
            risks.append(path)
    return risks


def inspect_state(repo: Path) -> dict[str, Any]:
    staged = ordinary_staged_paths(repo)
    unstaged = unstaged_paths(repo)
    untracked = untracked_paths(repo)
    return {
        "result": "INSPECT",
        "repository": str(repo),
        "branch": branch_name(repo),
        "head": git_head(repo),
        "staged": staged,
        "unstaged": unstaged,
        "untracked": untracked,
        "candidate": staged,
        "other_changes": sorted(set(unstaged + untracked) - set(staged)),
        "risks": path_risks(staged + unstaged + untracked),
        "historical_scopes": history_scopes(repo),
    }


def print_inspect(state: dict[str, Any]) -> None:
    print("INSPECT")
    print(f"- 仓库：{state['repository']}")
    print(f"- 分支/HEAD：{state['branch']} / {state['head']}")
    print(f"- 已暂存：{', '.join(state['staged']) or '无'}")
    print(f"- 未暂存：{', '.join(state['unstaged']) or '无'}")
    print(f"- 未跟踪：{', '.join(state['untracked']) or '无'}")
    print(f"- 风险项：{', '.join(state['risks']) or '无'}")
    scopes = list(state["historical_scopes"].items())[:20]
    scope_text = ", ".join(f"{name}({data['count']})" for name, data in scopes)
    print(f"- 历史 scope：{scope_text or '无'}")


def shell_tokens(command: str) -> list[str]:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError as error:
        raise GateError(f"无法解析目标命令：{error}") from error


def command_segments(command: str) -> list[list[str]]:
    segments: list[list[str]] = []
    current: list[str] = []
    for token in shell_tokens(command):
        if token in SHELL_SEPARATORS or set(token) <= {";", "&", "|"}:
            if current:
                segments.append(current)
                current = []
            continue
        if token in {"(", ")"}:
            continue
        current.append(token)
    if current:
        segments.append(current)
    return segments


def locate_git(tokens: list[str]) -> int | None:
    for index, token in enumerate(tokens):
        if Path(token).name == "git":
            if index == 0:
                return index
            prefix = tokens[:index]
            if Path(prefix[0]).name == "env" or all(
                "=" in item and not item.startswith("=") for item in prefix
            ):
                return index
    return None


def parse_git_invocation(tokens: list[str]) -> dict[str, Any] | None:
    git_index = locate_git(tokens)
    if git_index is None:
        return None
    args = tokens[git_index + 1 :]
    index = 0
    git_c: str | None = None
    dangerous_config = False
    while index < len(args):
        token = args[index]
        if token == "-C" and index + 1 < len(args):
            git_c = args[index + 1]
            index += 2
            continue
        if token.startswith("-C") and token != "-C":
            git_c = token[2:]
            index += 1
            continue
        if token in {"-c", "--config-env"} and index + 1 < len(args):
            value = args[index + 1]
            if "core.hookspath" in value.lower():
                dangerous_config = True
            index += 2
            continue
        if token.startswith("-c") and "core.hookspath" in token.lower():
            dangerous_config = True
            index += 1
            continue
        if token in {"--git-dir", "--work-tree", "--namespace"} and index + 1 < len(args):
            index += 2
            continue
        if token.startswith(("--git-dir=", "--work-tree=", "--namespace=")):
            index += 1
            continue
        if token in {"--no-pager", "--paginate", "--literal-pathspecs", "--no-optional-locks"}:
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        break
    if index >= len(args):
        return None
    verb = args[index]
    verb_args = args[index + 1 :]
    bypass = dangerous_config or any(
        item == "--no-verify"
        or item.startswith("--no-verify=")
        or "core.hookspath" in item.lower()
        for item in tokens
    )
    return {
        "verb": verb,
        "args": verb_args,
        "git_c": git_c,
        "bypass": bypass,
        "tokens": tokens,
    }


def contains_option(args: Iterable[str], option: str) -> bool:
    return any(item == option or item.startswith(f"{option}=") for item in args)


def operation_for(invocation: dict[str, Any]) -> str | None:
    verb = invocation["verb"]
    args = invocation["args"]
    if verb == "commit":
        return "amend" if contains_option(args, "--amend") else "commit"
    if verb in {"revert", "cherry-pick"} and (
        contains_option(args, "--no-commit") or "-n" in args
    ):
        return None
    if verb in HISTORY_COMMANDS:
        return verb
    return None


def command_targets(invocation: dict[str, Any]) -> list[str]:
    args = invocation["args"]
    targets: list[str] = []
    skip_next = False
    options_with_values = {
        "-m",
        "--message",
        "-F",
        "--file",
        "--author",
        "--date",
        "--cleanup",
        "--strategy",
        "-s",
        "-X",
        "--strategy-option",
        "--onto",
        "--exec",
    }
    for item in args:
        if skip_next:
            skip_next = False
            continue
        if item in options_with_values:
            skip_next = True
            continue
        if item.startswith("-"):
            continue
        targets.append(item)
    return targets


def command_message_file(repo: Path, args: list[str]) -> Path | None:
    index = 0
    while index < len(args):
        item = args[index]
        value: str | None = None
        if item in {"-F", "--file"} and index + 1 < len(args):
            value = args[index + 1]
            index += 2
        elif item.startswith("--file="):
            value = item.split("=", 1)[1]
            index += 1
        elif item.startswith("-F") and item != "-F":
            value = item[2:]
            index += 1
        else:
            index += 1
        if value:
            return resolve_repo_path(repo, value)
    return None


def analyze_command(command: str) -> dict[str, Any]:
    invocations = [
        parsed
        for segment in command_segments(command)
        if (parsed := parse_git_invocation(segment)) is not None
    ]
    forbidden: list[str] = []
    history: list[dict[str, Any]] = []
    for invocation in invocations:
        verb = invocation["verb"]
        if invocation["bypass"]:
            forbidden.append("禁用 Git Hook 或使用 --no-verify")
        if verb in PERMANENTLY_FORBIDDEN_COMMANDS:
            forbidden.append(f"禁止使用低层或旁路命令 git {verb}")
        if verb == "pull":
            forbidden.append("禁止使用组合式 git pull；请拆分获取与受门禁保护的 merge")
        if verb == "stash" and (
            not invocation["args"]
            or invocation["args"][0] not in {"list", "show"}
        ):
            forbidden.append("提交准备期间禁止 stash、push 或 pop 工作区修改")
        if verb == "hash-object" and contains_option(invocation["args"], "-w"):
            forbidden.append("禁止使用 git hash-object -w 写入低层对象")
        if verb == "symbolic-ref":
            positional = [item for item in invocation["args"] if not item.startswith("-")]
            if len(positional) > 1 or contains_option(invocation["args"], "--delete"):
                forbidden.append("禁止使用 git symbolic-ref 直接修改引用")
        if verb == "config" and any("core.hookspath" in item.lower() for item in invocation["args"]):
            forbidden.append("禁止修改 core.hooksPath")
        operation = operation_for(invocation)
        if operation:
            history.append(
                {
                    "operation": operation,
                    "verb": verb,
                    "args": invocation["args"],
                    "git_c": invocation["git_c"],
                    "targets": command_targets(invocation),
                }
            )
    if len(history) > 1:
        forbidden.append("单个工具调用包含多个 Git 历史写入，无法逐提交门禁")
    return {"forbidden": sorted(set(forbidden)), "history": history, "git": invocations}


def invocation_repo(repo: Path, invocation: dict[str, Any], cwd: Path | None = None) -> Path:
    base = cwd or repo
    git_c = invocation.get("git_c")
    if git_c:
        candidate = Path(str(git_c)).expanduser()
        base = candidate.resolve() if candidate.is_absolute() else (base / candidate).resolve()
    result = run(["git", "rev-parse", "--show-toplevel"], cwd=base, check=False)
    if result.returncode != 0:
        raise GateError(f"目标命令未指向有效 Git 仓库：{base}")
    return Path(result.stdout.strip()).resolve()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise GateError(f"文件不存在：{path}") from error
    except json.JSONDecodeError as error:
        raise GateError(f"JSON 无效：{path}: {error}") from error
    if not isinstance(value, dict):
        raise GateError(f"JSON 顶层必须是对象：{path}")
    return value


def resolve_repo_path(repo: Path, value: str) -> Path:
    path = Path(value).expanduser()
    return path.resolve() if path.is_absolute() else (repo / path).resolve()


def normalize_command(value: str) -> str:
    return value.strip()


def validate_message(message: str, paths: list[str], scope_review: dict[str, Any], repo: Path) -> dict[str, str]:
    normalized = message.rstrip() + "\n"
    subject = normalized.splitlines()[0] if normalized.splitlines() else ""
    match = SUBJECT_RE.match(subject)
    if not match:
        raise GateError("Commit Message 主题必须为中文 type(scope): 动作 + 结果 格式")
    commit_type, scope, action = match.groups()
    if commit_type not in ALLOWED_TYPES:
        raise GateError(f"不允许的提交类型：{commit_type}")
    if not re.search(r"[\u3400-\u9fff]", subject):
        raise GateError("Commit Message 主题必须使用中文")
    if any(generic in action for generic in GENERIC_SUBJECTS):
        raise GateError("Commit Message 使用了无信息标题")
    if not isinstance(scope_review, dict):
        raise GateError("review.scope 必须是对象")
    if scope_review.get("value") != scope:
        raise GateError("Commit Message scope 与 review.scope.value 不一致")
    source = scope_review.get("source")
    scopes = history_scopes(repo)
    search_terms = scope_review.get("search_terms")
    if not isinstance(search_terms, list) or not any(str(item).strip() for item in search_terms):
        raise GateError("scope 决策必须记录至少一个历史检索词")
    if source == "historical":
        if scope not in scopes:
            raise GateError(f"scope 标为 historical，但完整历史中不存在：{scope}")
    elif source == "new":
        candidates = scope_review.get("candidates")
        reason = str(scope_review.get("new_reason", "")).strip()
        if not reason:
            raise GateError("新增 scope 必须记录 new_reason")
        if scopes and (not isinstance(candidates, list) or not candidates):
            raise GateError("新增 scope 必须记录相邻历史候选及不适用理由")
        for candidate in candidates or []:
            if not isinstance(candidate, dict) or not str(candidate.get("name", "")).strip() or not str(candidate.get("reason", "")).strip():
                raise GateError("每个新增 scope 候选必须包含 name 与 reason")
    else:
        raise GateError("scope.source 必须是 historical 或 new")

    needs_body = len(paths) > 1 or any(
        path.startswith(("scripts/", ".agents/", ".codex/", ".githooks/"))
        or path.endswith((".json", ".yaml", ".yml", ".xcconfig", ".pbxproj"))
        or Path(path).name in {"Package.resolved", "Package.swift"}
        for path in paths
    )
    if needs_body:
        body = "\n".join(normalized.splitlines()[1:])
        missing = [heading for heading in ("变更点", "影响范围", "验证命令与结果") if heading not in body]
        if missing:
            raise GateError(f"多文件或治理/配置提交正文缺少：{', '.join(missing)}")
    for line in normalized.splitlines():
        if line.startswith("Knowledge-Case:") and not re.fullmatch(
            r"Knowledge-Case: IOS-BUG-\d{8}-\d{3}", line
        ):
            raise GateError("Knowledge-Case trailer 格式无效")
    return {"subject": subject, "scope": scope, "type": commit_type, "message": normalized}


def validation_entries(review: dict[str, Any]) -> list[dict[str, str]]:
    entries = review.get("validation")
    if not isinstance(entries, list):
        raise GateError("review.validation 必须是数组")
    normalized: list[dict[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise GateError("每条验证记录必须是对象")
        command = str(entry.get("command", "")).strip()
        status = str(entry.get("status", "")).strip()
        if not command or status not in {"passed", "not_run"}:
            raise GateError("验证记录必须包含 command，status 只能为 passed 或 not_run")
        if status == "passed" and not str(entry.get("result", "")).strip():
            raise GateError(f"已通过的验证缺少结果摘要：{command}")
        if status == "not_run" and not str(entry.get("reason", "")).strip():
            raise GateError(f"未运行的验证缺少原因：{command}")
        normalized.append({key: str(value) for key, value in entry.items()})
    return normalized


def passed_commands(entries: list[dict[str, str]]) -> set[str]:
    return {entry["command"] for entry in entries if entry["status"] == "passed"}


def require_command(passed: set[str], expected: str) -> None:
    if expected not in passed:
        raise GateError(f"缺少已通过的必需验证：{expected}")


def require_matching_command(passed: set[str], description: str, predicate: Any) -> None:
    if not any(predicate(command) for command in passed):
        raise GateError(f"缺少已通过的专项验证：{description}")


def validate_matrix(paths: list[str], review: dict[str, Any]) -> list[dict[str, str]]:
    entries = validation_entries(review)
    passed = passed_commands(entries)
    for command in ALWAYS_REQUIRED_VALIDATIONS:
        require_command(passed, command)

    production_or_project = any(
        (path.startswith("xmnote/") and path.endswith(".swift"))
        or path.endswith(".pbxproj")
        or Path(path).name in {"Package.resolved", "Package.swift"}
        for path in paths
    )
    if production_or_project:
        require_matching_command(passed, "Xcode 编译", lambda command: "xcodebuild" in command or "ai-build" in command)

    ui_change = any(
        path.startswith(("xmnote/Views/", "xmnote/UIComponents/", "xmnote/Utilities/DesignSystem/"))
        for path in paths
    )
    if ui_change:
        require_matching_command(
            passed,
            "设计系统上下文或审计",
            lambda command: "scripts/design-system/ds.py" in command
            and (" context " in f" {command} " or " audit" in command),
        )

    skill_change = any(path.startswith(".agents/skills/") for path in paths)
    if skill_change:
        require_matching_command(
            passed,
            "Skill quick_validate.py",
            lambda command: "quick_validate.py" in command and ".agents/skills/" in command,
        )

    gate_change = any("xmnote-git-commit/scripts/commit_gate.py" in path for path in paths)
    if gate_change:
        require_matching_command(
            passed,
            "Git 门禁临时仓库测试",
            lambda command: "xmnote-git-commit/scripts/test_commit_gate.py" in command,
        )

    hook_change = ".codex/hooks.json" in paths
    if hook_change:
        require_matching_command(
            passed,
            "Hook JSON 解析",
            lambda command: "json.tool" in command and ".codex/hooks.json" in command,
        )
    return entries


def concise_result(completed: subprocess.CompletedProcess[str]) -> str:
    output = (completed.stdout.strip() or completed.stderr.strip() or "通过").splitlines()
    return output[-1][:300] if output else "通过"


def execute_baseline_validations(repo: Path, entries: list[dict[str, str]]) -> list[dict[str, str]]:
    """Execute the deterministic baseline instead of trusting asserted evidence."""

    by_command = {entry["command"]: dict(entry) for entry in entries}
    for command in ALWAYS_REQUIRED_VALIDATIONS:
        completed = run(BASELINE_VALIDATION_ARGV[command], cwd=repo, check=False)
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "无输出"
            raise GateError(f"必需验证失败：{command}\n{detail[-2000:]}")
        entry = by_command[command]
        entry.update(
            {
                "status": "passed",
                "result": concise_result(completed),
                "executed_at": now_iso(),
                "output_digest": sha256_text(completed.stdout + "\n" + completed.stderr),
            }
        )
        by_command[command] = entry
    return [by_command.get(entry["command"], entry) for entry in entries]


def staged_debug_markers(repo: Path) -> list[str]:
    diff = git(repo, "diff", "--cached", "--unified=0", "--no-ext-diff")
    findings: list[str] = []
    for line in diff.splitlines():
        if not line.startswith("+") or line.startswith("+++"):
            continue
        for marker in DEBUG_MARKERS:
            if marker in line:
                findings.append(marker)
    return sorted(set(findings))


def resolve_commit(repo: Path, value: str) -> str:
    result = run(["git", "rev-parse", "--verify", f"{value}^{{commit}}"], cwd=repo, check=False)
    if result.returncode != 0:
        raise GateError(f"无法解析目标提交：{value}")
    return result.stdout.strip()


def expand_commit_targets(repo: Path, targets: list[str]) -> list[str]:
    commits: list[str] = []
    for target in targets:
        if ".." in target:
            result = run(["git", "rev-list", "--reverse", target], cwd=repo, check=False)
            if result.returncode != 0:
                raise GateError(f"无法展开提交范围：{target}")
            commits.extend(line.strip() for line in result.stdout.splitlines() if line.strip())
        else:
            commits.append(resolve_commit(repo, target))
    return list(dict.fromkeys(commits))


def commit_audit(repo: Path, commit: str) -> dict[str, Any]:
    message = git(repo, "show", "-s", "--format=%B", commit).rstrip() + "\n"
    paths = split_nul(
        git(repo, "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z", commit)
    )
    return {
        "commit": commit,
        "subject": message.splitlines()[0] if message.splitlines() else "",
        "message_digest": sha256_text(message),
        "paths": paths,
    }


def require_replay_confirmation(review: dict[str, Any], commits: list[str]) -> None:
    if review.get("history_audit_confirmed") is not True:
        raise GateError("保留或重放历史消息前必须声明 history_audit_confirmed=true")
    declared = review.get("replay_commits")
    if not isinstance(declared, list) or declared != commits:
        raise GateError(f"review.replay_commits 与实际 replay 范围不一致：actual={commits}")


def validate_preserved_commit_message(repo: Path, audit: dict[str, Any]) -> None:
    subject = str(audit.get("subject", ""))
    match = SUBJECT_RE.match(subject)
    if not match or not re.search(r"[\u3400-\u9fff]", subject):
        raise GateError(
            f"cherry-pick 目标 {audit.get('commit')} 的消息不合规；请改用 --no-commit 后重新生成"
        )
    _, scope, action = match.groups()
    if any(generic in action for generic in GENERIC_SUBJECTS):
        raise GateError(
            f"cherry-pick 目标 {audit.get('commit')} 使用无信息标题；请改用 --no-commit"
        )
    if scope not in history_scopes(repo):
        raise GateError(f"cherry-pick 目标 scope `{scope}` 缺少完整历史依据")
    message = git(repo, "show", "-s", "--format=%B", str(audit["commit"]))
    validate_message(
        message,
        list(audit.get("paths", [])),
        {
            "value": scope,
            "source": "historical",
            "search_terms": [scope],
            "candidates": [],
        },
        repo,
    )


def rebase_replay_commits(repo: Path, args: list[str], targets: list[str]) -> list[str]:
    git_path = git_dir(repo)
    if any(item in {"--continue", "--skip"} for item in args):
        for state_dir_name in ("rebase-merge", "rebase-apply"):
            state_dir = git_path / state_dir_name
            orig_head_path = state_dir / "orig-head"
            onto_path = state_dir / "onto"
            if orig_head_path.exists() and onto_path.exists():
                orig_head = orig_head_path.read_text(encoding="utf-8").strip()
                onto = onto_path.read_text(encoding="utf-8").strip()
                output = git(repo, "rev-list", "--reverse", f"{onto}..{orig_head}")
                return [line for line in output.splitlines() if line]
        raise GateError("无法定位 rebase continue/skip 的完整 replay 状态")
    if "--abort" in args or "--quit" in args:
        return []
    branch = targets[1] if len(targets) > 1 else "HEAD"
    if "--root" in args:
        output = git(repo, "rev-list", "--reverse", branch)
        return [line for line in output.splitlines() if line]
    if not targets:
        raise GateError("无法确定 rebase upstream 与完整 replay 范围")
    upstream = targets[0]
    output = git(repo, "rev-list", "--reverse", f"{upstream}..{branch}")
    return [line for line in output.splitlines() if line]


def validate_preserved_operation(
    repo: Path,
    review: dict[str, Any],
    history: dict[str, Any],
) -> list[dict[str, Any]]:
    operation = history["operation"]
    args = history["args"]
    targets = history["targets"]
    if operation == "merge":
        safe_without_new_message = (
            contains_option(args, "--ff-only")
            or contains_option(args, "--squash")
            or (
                contains_option(args, "--no-commit")
                and contains_option(args, "--no-ff")
            )
            or contains_option(args, "--abort")
            or contains_option(args, "--quit")
        )
        if not safe_without_new_message:
            raise GateError(
                "merge 可能直接生成未受控消息；fast-forward 使用 --ff-only，"
                "合并提交使用 --no-ff --no-commit 后再走普通 commit 门禁"
            )
        require_replay_confirmation(review, [])
        return [{"operation": "merge", "targets": targets, "message_mode": "preserve"}]
    if operation == "revert":
        if contains_option(args, "--abort") or contains_option(args, "--quit"):
            require_replay_confirmation(review, [])
            return [{"operation": "revert", "targets": targets, "message_mode": "preserve"}]
        raise GateError("revert 必须先使用 --no-commit，再按普通 commit 生成并校验中文消息")
    if operation == "cherry-pick":
        if contains_option(args, "--abort") or contains_option(args, "--quit"):
            require_replay_confirmation(review, [])
            return [{"operation": "cherry-pick", "targets": targets, "message_mode": "preserve"}]
        if any(item in {"--continue", "--skip"} for item in args):
            raise GateError(
                "cherry-pick continue/skip 必须先重新检查冲突后的 staged diff；"
                "需要生成提交时使用普通 commit 门禁"
            )
        commits = expand_commit_targets(repo, targets)
        if not commits:
            raise GateError("cherry-pick 没有可审计的目标提交")
        require_replay_confirmation(review, commits)
        audits = [commit_audit(repo, commit) for commit in commits]
        for audit in audits:
            validate_preserved_commit_message(repo, audit)
        return audits
    if operation == "rebase":
        commits = rebase_replay_commits(repo, args, targets)
        require_replay_confirmation(review, commits)
        return [commit_audit(repo, commit) for commit in commits]
    raise GateError(f"不支持的保留消息操作：{operation}")


def validate_review(
    repo: Path,
    review: dict[str, Any],
    command: str,
    analysis: dict[str, Any],
) -> dict[str, Any]:
    if review.get("version") != VERSION:
        raise GateError(f"review.version 必须为 {VERSION}")
    if analysis["forbidden"]:
        raise GateError("；".join(analysis["forbidden"]))
    if len(analysis["history"]) != 1:
        raise GateError("prepare 的精确命令必须包含且仅包含一个 Git 历史写入")
    history = analysis["history"][0]
    if invocation_repo(repo, history) != repo:
        raise GateError("目标命令指向其他仓库，不能使用当前项目凭据")
    operation = history["operation"]
    if review.get("operation") != operation:
        raise GateError(f"review.operation 与命令不一致：应为 {operation}")
    if review.get("boundary_confirmed") is not True:
        raise GateError("尚未确认提交边界")
    mixed_files = review.get("mixed_files")
    if not isinstance(mixed_files, list) or mixed_files:
        raise GateError("存在同文件混合修改，无法安全提交")
    summary = str(review.get("summary", "")).strip()
    if not summary:
        raise GateError("review.summary 不能为空")
    modules = review.get("modules")
    if not isinstance(modules, list) or not modules or not all(str(item).strip() for item in modules):
        raise GateError("review.modules 必须列出主要模块")

    effective_paths = staged_paths(repo, operation)
    included = review.get("included_paths")
    if not isinstance(included, list) or not all(isinstance(item, str) for item in included):
        raise GateError("review.included_paths 必须是路径数组")
    included = sorted(set(included))
    if operation in {"commit", "amend"}:
        if operation == "commit" and not effective_paths:
            raise GateError("普通提交没有实际暂存 diff")
        if included != effective_paths:
            raise GateError(
                "review.included_paths 与目标提交实际文件不一致："
                f"review={included}, actual={effective_paths}"
            )
        expected_message_path = (gate_dir(repo) / MESSAGE_NAME).resolve()
        actual_message_path = command_message_file(repo, history["args"])
        if actual_message_path != expected_message_path:
            raise GateError(
                "commit/amend 必须使用 -F artifacts/git-commit-gate/message.txt，"
                "确保实际消息与 PASS 凭据一致"
            )

    debug_markers = staged_debug_markers(repo) if ordinary_staged_paths(repo) else []
    if debug_markers and review.get("debug_code_reviewed") is not True:
        raise GateError(f"暂存 diff 含调试标记，需明确复核：{', '.join(debug_markers)}")

    message = str(review.get("message", ""))
    message_data: dict[str, str] | None = None
    history_audit: list[dict[str, Any]] = []
    if operation in {"commit", "amend"}:
        if not message.strip():
            raise GateError("commit/amend 必须提供基于实际 diff 的完整消息")
        message_data = validate_message(message, effective_paths, review.get("scope"), repo)
    else:
        if message.strip():
            raise GateError("非 commit/amend 操作不得声明一份实际命令不会使用的新消息")
        if review.get("message_mode") != "preserve":
            raise GateError("不生成新消息的历史操作必须声明 message_mode=preserve")
        history_audit = validate_preserved_operation(repo, review, history)

    audit_paths = sorted(
        {
            path
            for audit in history_audit
            for path in audit.get("paths", [])
            if isinstance(path, str)
        }
    )
    actual_paths = effective_paths or included or audit_paths
    risky = path_risks(actual_paths)
    controlled_generated = sorted(review.get("controlled_generated_files") or [])
    unapproved_risks = sorted(set(risky) - set(controlled_generated))
    if unapproved_risks:
        raise GateError(f"包含未批准的临时或生成文件：{', '.join(unapproved_risks)}")
    if controlled_generated and not str(review.get("generated_reason", "")).strip():
        raise GateError("受控生成文件必须说明 generated_reason")
    entries = validate_matrix(actual_paths, review)

    working_other = sorted(
        (set(unstaged_paths(repo)) | set(untracked_paths(repo))) - set(ordinary_staged_paths(repo))
    )
    declared_other = review.get("other_changes")
    if declared_other is not None and sorted(declared_other) != working_other:
        raise GateError("review.other_changes 与实时保留修改不一致")
    return {
        "operation": operation,
        "targets": history["targets"],
        "included_paths": actual_paths,
        "other_changes": working_other,
        "summary": summary,
        "modules": [str(item) for item in modules],
        "validation": entries,
        "message": message_data["message"] if message_data else "",
        "subject": message_data["subject"] if message_data else "保留现有历史消息",
        "scope": review.get("scope") or {},
        "history_audit": history_audit,
    }


def gate_dir(repo: Path) -> Path:
    return repo / GATE_RELATIVE_DIR


def write_text_atomic(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(value, encoding="utf-8")
    os.replace(temporary, path)


def write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    write_text_atomic(path, json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def prepare(repo: Path, review_path: Path, command: str) -> dict[str, Any]:
    command = normalize_command(command)
    if not command:
        raise GateError("--command 不能为空")
    review = load_json(review_path)
    analysis = analyze_command(command)
    decision = validate_review(repo, review, command, analysis)
    before_validation = {
        "head": git_head(repo),
        "refs_digest": refs_digest(repo),
        "index_tree": index_tree(repo),
        "workspace_digest": workspace_digest(workspace_snapshot(repo)),
    }
    decision["validation"] = execute_baseline_validations(repo, decision["validation"])
    after_validation = {
        "head": git_head(repo),
        "refs_digest": refs_digest(repo),
        "index_tree": index_tree(repo),
        "workspace_digest": workspace_digest(workspace_snapshot(repo)),
    }
    if before_validation != after_validation:
        raise GateError("验证期间 HEAD、索引或工作区发生变化，请重新检查实际 diff")
    gate = gate_dir(repo)
    gate.mkdir(parents=True, exist_ok=True)
    message_path = gate / MESSAGE_NAME
    if decision["message"]:
        write_text_atomic(message_path, decision["message"])
    elif message_path.exists():
        message_path.unlink()

    snapshot = workspace_snapshot(repo)
    validation_digest = sha256_text(stable_json(decision["validation"]))
    attestation = {
        "version": VERSION,
        "prepared_at": now_iso(),
        "repository": str(repo),
        "git_dir": str(git_dir(repo)),
        "head": git_head(repo),
        "branch": branch_name(repo),
        "refs_digest": refs_digest(repo),
        "index_tree": index_tree(repo),
        "staged_paths": ordinary_staged_paths(repo),
        "included_paths": decision["included_paths"],
        "workspace_snapshot": snapshot,
        "workspace_digest": workspace_digest(snapshot),
        "operation": decision["operation"],
        "targets": decision["targets"],
        "command": command,
        "command_digest": sha256_text(command),
        "message_path": str(message_path.relative_to(repo)) if decision["message"] else None,
        "message_digest": sha256_text(decision["message"]) if decision["message"] else None,
        "validation": decision["validation"],
        "validation_digest": validation_digest,
        "history_audit": decision["history_audit"],
        "history_audit_digest": sha256_text(stable_json(decision["history_audit"])),
        "review_digest": sha256_text(stable_json(review)),
        "summary": decision["summary"],
        "modules": decision["modules"],
        "other_changes": decision["other_changes"],
        "scope": decision["scope"],
        "subject": decision["subject"],
    }
    write_json_atomic(gate / ATTESTATION_NAME, attestation)
    return {"result": "PASS", **attestation}


def compare_attestation(repo: Path, attestation: dict[str, Any], command: str, operation: str, targets: list[str]) -> list[str]:
    failures: list[str] = []
    if attestation.get("version") != VERSION:
        failures.append("凭据版本不匹配")
    if Path(str(attestation.get("repository", ""))).resolve() != repo:
        failures.append("凭据不属于当前 worktree")
    if attestation.get("git_dir") != str(git_dir(repo)):
        failures.append("Git 目录已变化")
    if attestation.get("head") != git_head(repo):
        failures.append("HEAD 已变化")
    if attestation.get("branch") != branch_name(repo):
        failures.append("当前分支已变化")
    if attestation.get("refs_digest") != refs_digest(repo):
        failures.append("引用状态已变化")
    if attestation.get("index_tree") != index_tree(repo):
        failures.append("暂存 tree 已变化")
    if attestation.get("staged_paths") != ordinary_staged_paths(repo):
        failures.append("暂存文件集合已变化")
    snapshot = workspace_snapshot(repo)
    if attestation.get("workspace_digest") != workspace_digest(snapshot):
        failures.append("工作区内容已变化")
    normalized = normalize_command(command)
    if attestation.get("command_digest") != sha256_text(normalized) or attestation.get("command") != normalized:
        failures.append("目标命令已变化")
    if attestation.get("operation") != operation:
        failures.append("目标操作已变化")
    if attestation.get("targets") != targets:
        failures.append("目标提交或分支已变化")
    message_path_value = attestation.get("message_path")
    if message_path_value:
        message_path = resolve_repo_path(repo, str(message_path_value))
        try:
            message = message_path.read_text(encoding="utf-8")
        except OSError:
            failures.append("提交消息文件不存在或不可读")
        else:
            if attestation.get("message_digest") != sha256_text(message):
                failures.append("提交消息已变化")
    if attestation.get("validation_digest") != sha256_text(stable_json(attestation.get("validation"))):
        failures.append("验证证据已被篡改")
    if attestation.get("history_audit_digest") != sha256_text(stable_json(attestation.get("history_audit"))):
        failures.append("历史 replay 审计已被篡改")
    return failures


def hook_deny(reason: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def extract_hook_command(payload: dict[str, Any]) -> str:
    tool_input = payload.get("tool_input") or payload.get("toolInput") or payload.get("input") or {}
    if not isinstance(tool_input, dict):
        return ""
    for key in ("command", "cmd"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    return ""


def hook_repo(default_repo: Path, payload: dict[str, Any]) -> Path:
    cwd = payload.get("cwd")
    if not isinstance(cwd, str):
        tool_input = payload.get("tool_input") or payload.get("toolInput") or {}
        cwd = tool_input.get("workdir") if isinstance(tool_input, dict) else None
    if isinstance(cwd, str):
        result = run(["git", "rev-parse", "--show-toplevel"], cwd=Path(cwd), check=False)
        if result.returncode == 0:
            candidate = Path(result.stdout.strip()).resolve()
            if candidate == default_repo:
                return candidate
    return default_repo


def hook_pre_tool_use(repo: Path, payload: dict[str, Any]) -> dict[str, Any]:
    command = extract_hook_command(payload)
    if not command:
        return {}
    analysis = analyze_command(command)
    if analysis["forbidden"]:
        return hook_deny("XMNote Git 门禁永久拒绝：" + "；".join(analysis["forbidden"]))
    if not analysis["history"]:
        return {}
    history = analysis["history"][0]
    repo = hook_repo(repo, payload)
    tool_input = payload.get("tool_input") or payload.get("toolInput") or {}
    command_cwd = tool_input.get("workdir") if isinstance(tool_input, dict) else None
    payload_cwd = payload.get("cwd")
    base_cwd_value = command_cwd if isinstance(command_cwd, str) else payload_cwd
    base_cwd = Path(base_cwd_value).resolve() if isinstance(base_cwd_value, str) else repo
    try:
        target_repo = invocation_repo(repo, history, base_cwd)
    except (GateError, OSError) as error:
        return hook_deny(f"无法确认 Git 历史写入目标：{error}")
    if target_repo != repo:
        return {}
    path = gate_dir(repo) / ATTESTATION_NAME
    try:
        attestation = load_json(path)
    except GateError:
        return hook_deny(
            "该 Git 历史写入没有 $xmnote-git-commit PASS 凭据。"
            "请先检查实时 diff、边界、历史 scope、消息和验证，再运行 commit_gate.py prepare。"
        )
    failures = compare_attestation(
        repo,
        attestation,
        command,
        history["operation"],
        history["targets"],
    )
    if failures:
        return hook_deny("$xmnote-git-commit 凭据已失效：" + "；".join(failures))
    return {}


def hook_post_tool_use(repo: Path, payload: dict[str, Any]) -> dict[str, Any]:
    command = extract_hook_command(payload)
    if not command:
        return {}
    analysis = analyze_command(command)
    if len(analysis["history"]) != 1:
        return {}
    repo = hook_repo(repo, payload)
    path = gate_dir(repo) / ATTESTATION_NAME
    if not path.exists():
        return {}
    try:
        attestation = load_json(path)
    except GateError:
        return {}
    if attestation.get("command_digest") != sha256_text(normalize_command(command)):
        return {}
    history_changed = (
        attestation.get("head") != git_head(repo)
        or attestation.get("refs_digest") != refs_digest(repo)
    )
    if not history_changed:
        return {}
    consumed = {
        "version": VERSION,
        "consumed_at": now_iso(),
        "operation": attestation.get("operation"),
        "previous_head": attestation.get("head"),
        "current_head": git_head(repo),
        "command_digest": attestation.get("command_digest"),
        "subject": attestation.get("subject"),
    }
    write_json_atomic(gate_dir(repo) / CONSUMED_NAME, consumed)
    path.unlink()
    return {}


def read_hook_payload() -> dict[str, Any]:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        raise GateError(f"Hook 输入不是有效 JSON：{error}") from error
    if not isinstance(payload, dict):
        raise GateError("Hook 输入顶层必须是对象")
    return payload


def print_pass(result: dict[str, Any]) -> None:
    print("PASS")
    print(f"- 准备提交：{result['summary']}")
    print(f"- 主要文件/模块：{', '.join(result['included_paths'])} / {', '.join(result['modules'])}")
    passed = [entry["command"] for entry in result["validation"] if entry["status"] == "passed"]
    not_run = [
        f"{entry['command']}（{entry.get('reason', '未说明')}）"
        for entry in result["validation"]
        if entry["status"] == "not_run"
    ]
    validation = f"已通过 {len(passed)} 项"
    if not_run:
        validation += "；未运行：" + "、".join(not_run)
    print(f"- 验证：{validation}")
    print(f"- 保留的其他修改：{', '.join(result['other_changes']) or '无'}")
    scope = result.get("scope") or {}
    if scope.get("source") == "historical":
        scope_text = f"复用历史 scope `{scope.get('value')}`"
    elif scope:
        scope_text = f"新增 scope `{scope.get('value')}`：{scope.get('new_reason')}"
    else:
        scope_text = "该操作保留现有历史消息"
    print(f"- scope 依据：{scope_text}")
    print(f"- Commit Message：{result['subject']}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="XMNote AI Git commit gate")
    parser.add_argument("--repo", help="用于测试或显式指定的仓库路径")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    inspect_parser = subparsers.add_parser("inspect", help="只读检查工作区和历史 scope")
    inspect_parser.add_argument("--json", action="store_true", help="输出 JSON")

    prepare_parser = subparsers.add_parser("prepare", help="校验决策并生成一次性凭据")
    prepare_parser.add_argument("--review", required=True, help="review.json 路径")
    prepare_parser.add_argument("--command", required=True, help="随后将原样执行的精确命令")
    prepare_parser.add_argument("--json", action="store_true", help="输出 JSON")

    hook_parser = subparsers.add_parser("hook", help="Codex Hook 入口")
    hook_parser.add_argument("event", choices=("pre-tool-use", "post-tool-use"))
    return parser


EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        repo = discover_repo(args.repo)
        if args.subcommand == "inspect":
            state = inspect_state(repo)
            if args.json:
                print(json.dumps(state, ensure_ascii=False, indent=2))
            else:
                print_inspect(state)
            return 0
        if args.subcommand == "prepare":
            review_path = resolve_repo_path(repo, args.review)
            result = prepare(repo, review_path, args.command)
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print_pass(result)
            return 0
        payload = read_hook_payload()
        if args.event == "pre-tool-use":
            output = hook_pre_tool_use(repo, payload)
        else:
            output = hook_post_tool_use(repo, payload)
        if output:
            print(json.dumps(output, ensure_ascii=False))
        return 0
    except GateError as error:
        if args.subcommand == "hook" and args.event == "pre-tool-use":
            print(json.dumps(hook_deny(f"XMNote Git 门禁检查失败：{error}"), ensure_ascii=False))
            return 0
        print("FAIL", file=sys.stderr)
        print(f"- 阻断原因：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
