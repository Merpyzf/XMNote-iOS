#!/usr/bin/env python3
"""XMNote AI Bug 经验闭环的本地 CLI、检索索引与生命周期 Hook。"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = 1
CASE_ID_PATTERN = re.compile(r"^IOS-BUG-\d{8}-\d{3}$")
PATTERN_ID_PATTERN = re.compile(r"^IOS-PATTERN-\d{3}$")
DRAFT_ID_PATTERN = re.compile(r"^DRAFT-\d{8}-\d{3}$")
CASE_SECTIONS = (
    "问题现象与最小复现",
    "事实链",
    "根因机制",
    "触发条件与影响范围",
    "修复策略与取舍",
    "验证证据",
    "预防与边界",
)
PATTERN_SECTIONS = ("模式说明", "适用边界", "不适用边界", "统一修复策略", "保护方式")


class KnowledgeError(RuntimeError):
    """表示用户输入、知识格式或治理前置条件不满足。"""


@dataclass(frozen=True)
class SearchRecord:
    """统一承载案例、模式、规则、学习资料和本地草稿的可检索内容。"""

    record_id: str
    kind: str
    title: str
    path: str
    status: str
    metadata: dict[str, Any]
    body: str


def utc_now() -> datetime:
    """返回稳定的 UTC 时间，避免本地索引和多 worktree 因时区产生歧义。"""

    return datetime.now(timezone.utc)


def now_iso() -> str:
    """生成秒级 ISO 8601 时间戳。"""

    return utc_now().replace(microsecond=0).isoformat()


def normalize_path(value: str, root: Path | None = None) -> str:
    """把绝对或相对路径规整为仓库相对 POSIX 路径。"""

    text = str(value).strip().replace("\\", "/")
    if text.startswith("a/") or text.startswith("b/"):
        text = text[2:]
    candidate = Path(text)
    if root and candidate.is_absolute():
        try:
            text = candidate.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            return candidate.as_posix()
    return text.lstrip("./")


def stable_hash(value: Any) -> str:
    """对可序列化内容生成短指纹，用于根因、策略和基线比较。"""

    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def file_hash(path: Path) -> str:
    """计算当前文件内容哈希；不存在的路径使用显式哨兵值。"""

    if not path.exists() or not path.is_file():
        return "<missing>"
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_text(path: Path, content: str) -> None:
    """原子写入文本，避免 Hook 中断留下半截状态文件。"""

    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        handle.write(content)
        temporary = Path(handle.name)
    os.replace(temporary, path)


def atomic_write_json(path: Path, data: Any) -> None:
    """以可审阅格式原子写入本地 JSON 状态。"""

    atomic_write_text(path, json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def read_json(path: Path, default: Any = None) -> Any:
    """读取 JSON；仅在文件不存在时返回调用方提供的默认值。"""

    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_front_matter(text: str, source: str = "<memory>") -> tuple[dict[str, Any], str]:
    """解析以 JSON 作为 Front Matter 负载的 Markdown 文档。"""

    if not text.startswith("---\n"):
        raise KnowledgeError(f"{source}: 缺少 JSON Front Matter 起始分隔符")
    boundary = text.find("\n---\n", 4)
    if boundary < 0:
        raise KnowledgeError(f"{source}: 缺少 JSON Front Matter 结束分隔符")
    raw = text[4:boundary].strip()
    try:
        metadata = json.loads(raw)
    except json.JSONDecodeError as error:
        raise KnowledgeError(f"{source}: Front Matter 不是合法 JSON: {error}") from error
    if not isinstance(metadata, dict):
        raise KnowledgeError(f"{source}: Front Matter 必须是 JSON 对象")
    return metadata, text[boundary + 5 :]


def render_front_matter(metadata: dict[str, Any], body: str) -> str:
    """输出可被标准库无损解析的 Markdown/JSON Front Matter。"""

    payload = json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True)
    return f"---\n{payload}\n---\n{body.rstrip()}\n"


def as_list(value: Any) -> list[Any]:
    """把标量、元组或空值统一为列表。"""

    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    return [value]


def normalized_tags(value: Any) -> list[str]:
    """生成去空、去重、稳定排序的标签集合。"""

    tags = {str(item).strip().lower() for item in as_list(value) if str(item).strip()}
    return sorted(tags)


def root_cause_fingerprint(data: dict[str, Any]) -> str:
    """由模块、根因标签、触发标签和反模式生成根因指纹。"""

    payload = {
        "modules": normalized_tags(data.get("modules")),
        "root_cause_tags": normalized_tags(data.get("root_cause_tags")),
        "trigger_tags": normalized_tags(data.get("trigger_tags")),
        "anti_pattern": str(data.get("anti_pattern", "")).strip().lower(),
    }
    return stable_hash(payload)


def fix_strategy_fingerprint(data: dict[str, Any]) -> str:
    """由修复策略标签生成跨案例可比较的策略指纹。"""

    return stable_hash({"fix_strategy_tags": normalized_tags(data.get("fix_strategy_tags"))})


def has_value(value: Any) -> bool:
    """判断事实字段是否包含非占位内容。"""

    if value is None:
        return False
    if isinstance(value, str):
        text = value.strip().lower()
        return bool(text) and text not in {"todo", "tbd", "待补充", "未知", "无"}
    if isinstance(value, (list, tuple, dict, set)):
        return bool(value)
    return True


def format_markdown_value(value: Any) -> str:
    """把结构化字段转换为案例正文中的紧凑 Markdown。"""

    if isinstance(value, list):
        return "\n".join(f"- {item}" for item in value) if value else "- 未记录"
    if isinstance(value, dict):
        return "\n".join(f"- {key}: {item}" for key, item in value.items()) if value else "- 未记录"
    return str(value).strip() or "未记录"


class Repository:
    """封装单个 worktree 内的知识、索引、草稿和 Hook 会话状态。"""

    def __init__(self, root: Path):
        self.root = root.resolve()
        policy_path = self.root / "scripts/ai-knowledge/policy.json"
        if not policy_path.exists():
            raise KnowledgeError(f"找不到策略文件: {policy_path}")
        self.policy = read_json(policy_path)
        self.local_root = self.root / self.policy["local_state_root"]
        self.sessions_dir = self.local_root / "sessions"
        self.drafts_dir = self.local_root / "drafts"
        self.metrics_dir = self.local_root / "metrics"
        self.index_path = self.local_root / "index.sqlite"

    @classmethod
    def discover(cls, start: Path | None = None) -> "Repository":
        """从当前目录向上寻找仓库策略文件并创建仓库上下文。"""

        current = (start or Path.cwd()).resolve()
        for candidate in (current, *current.parents):
            if (candidate / "scripts/ai-knowledge/policy.json").exists():
                return cls(candidate)
        raise KnowledgeError("无法定位 XMNote 仓库根目录")

    def ensure_local_state(self) -> None:
        """仅创建被 Git 忽略的 worktree 本地状态目录。"""

        for directory in (self.sessions_dir, self.drafts_dir, self.metrics_dir):
            directory.mkdir(parents=True, exist_ok=True)

    def relative(self, path: Path) -> str:
        """返回用于知识记录和 Hook 判断的仓库相对路径。"""

        try:
            return path.resolve().relative_to(self.root).as_posix()
        except ValueError:
            return path.resolve().as_posix()

    def is_excluded(self, path: str) -> bool:
        """判断路径是否属于测试、文档、工具自身或其他排除范围。"""

        normalized = normalize_path(path, self.root)
        return any(fnmatch.fnmatch(normalized, pattern) for pattern in self.policy["excluded_paths"])

    def is_protected(self, path: str) -> bool:
        """判断路径是否属于生产代码、工程配置或生产脚本保护范围。"""

        normalized = normalize_path(path, self.root)
        if self.is_excluded(normalized):
            return False
        return any(fnmatch.fnmatch(normalized, pattern) for pattern in self.policy["protected_paths"])

    def scope_for_path(self, path: str) -> str:
        """按 iOS 功能域或顶层模块生成首次写入检索凭证。"""

        parts = Path(normalize_path(path, self.root)).parts
        if len(parts) >= 3 and parts[0] == "xmnote" and parts[1] in {"Views", "ViewModels"}:
            return "/".join(parts[:3])
        if len(parts) >= 2 and parts[0] == "xmnote":
            return "/".join(parts[:2])
        if parts and parts[0] == "scripts":
            return "scripts"
        return parts[0] if parts else "repository"

    def run_git(self, arguments: Sequence[str], check: bool = False) -> subprocess.CompletedProcess[str]:
        """在当前 worktree 内执行只读 Git 查询。"""

        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def branch_name(self) -> str:
        """获取当前分支；分离头指针下返回 HEAD。"""

        result = self.run_git(["branch", "--show-current"])
        return result.stdout.strip() or "HEAD"

    def changed_files(self) -> list[str]:
        """读取当前工作树变更，保留用户既有未提交文件作为基线候选。"""

        result = self.run_git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        if result.returncode != 0:
            return []
        paths: list[str] = []
        entries = result.stdout.split("\0")
        skip_next = False
        for entry in entries:
            if skip_next:
                skip_next = False
                continue
            if len(entry) < 4:
                continue
            status = entry[:2]
            raw = entry[3:]
            if status.startswith("R") or status.startswith("C"):
                skip_next = True
            paths.append(normalize_path(raw, self.root))
        return sorted(set(paths))

    def changed_state(self) -> dict[str, str]:
        """记录当前工作树文件哈希，用于排除任务开始前的脏文件。"""

        return {path: file_hash(self.root / path) for path in self.changed_files()}

    def task_attributable_changes(self, baseline: dict[str, str]) -> list[str]:
        """返回相对会话基线新增或内容继续变化的生产路径。"""

        current = self.changed_state()
        return sorted(
            path
            for path, digest in current.items()
            if self.is_protected(path) and baseline.get(path) != digest
        )

    def formal_paths(self, kind: str | None = None) -> list[Path]:
        """枚举正式案例、模式和归档文档；目录不存在时返回空集合。"""

        knowledge = self.policy["knowledge"]
        roots: list[Path] = []
        if kind in (None, "case"):
            roots.append(self.root / knowledge["cases"])
        if kind in (None, "pattern"):
            roots.append(self.root / knowledge["patterns"])
        if kind is None:
            roots.append(self.root / knowledge["archive"])
        paths: list[Path] = []
        for directory in roots:
            if directory.exists():
                paths.extend(sorted(directory.rglob("*.md")))
        return sorted(set(paths))

    def load_formal(self, kind: str | None = None) -> list[tuple[Path, dict[str, Any], str]]:
        """解析全部正式知识卡，格式错误直接交给调用方处理。"""

        documents = []
        for path in self.formal_paths(kind):
            metadata, body = parse_front_matter(path.read_text(encoding="utf-8"), self.relative(path))
            if kind and metadata.get("type") != kind:
                continue
            documents.append((path, metadata, body))
        return documents

    def iter_drafts(self) -> list[dict[str, Any]]:
        """读取当前 worktree 的所有本地草稿。"""

        if not self.drafts_dir.exists():
            return []
        drafts = []
        for path in sorted(self.drafts_dir.glob("*.json")):
            data = read_json(path)
            if isinstance(data, dict):
                drafts.append(data)
        return drafts

    def draft_path(self, draft_id: str) -> Path:
        """返回本地草稿路径并拒绝路径穿越。"""

        if not DRAFT_ID_PATTERN.match(draft_id):
            raise KnowledgeError(f"非法草稿 ID: {draft_id}")
        return self.drafts_dir / f"{draft_id}.json"

    def load_draft(self, draft_id: str) -> dict[str, Any]:
        """读取指定草稿，不存在时给出可操作错误。"""

        path = self.draft_path(draft_id)
        data = read_json(path)
        if not isinstance(data, dict):
            raise KnowledgeError(f"找不到草稿: {draft_id}")
        return data

    def next_id(self, prefix: str, pattern: re.Pattern[str], paths: Iterable[Path]) -> str:
        """在既有本地或正式文件中分配当日/全局递增 ID。"""

        maximum = 0
        for path in paths:
            match = re.search(r"(\d{3})(?:\.json|\.md)?$", path.stem)
            if match:
                maximum = max(maximum, int(match.group(1)))
        candidate = f"{prefix}{maximum + 1:03d}"
        if not pattern.match(candidate):
            raise KnowledgeError(f"生成了非法 ID: {candidate}")
        return candidate

    def next_draft_id(self) -> str:
        """为当天开发草稿分配递增 ID。"""

        self.ensure_local_state()
        prefix = f"DRAFT-{date.today():%Y%m%d}-"
        same_day = self.drafts_dir.glob(f"{prefix}*.json")
        return self.next_id(prefix, DRAFT_ID_PATTERN, same_day)

    def next_case_id(self) -> str:
        """为收口阶段正式案例分配递增 ID。"""

        prefix = f"IOS-BUG-{date.today():%Y%m%d}-"
        same_day = [path for path in self.formal_paths("case") if path.stem.startswith(prefix)]
        return self.next_id(prefix, CASE_ID_PATTERN, same_day)

    def next_pattern_id(self) -> str:
        """为候选模式分配全局递增 ID。"""

        return self.next_id("IOS-PATTERN-", PATTERN_ID_PATTERN, self.formal_paths("pattern"))

    def init_draft(
        self,
        title: str,
        paths: Sequence[str] = (),
        modules: Sequence[str] = (),
        evidence_context: str = "",
        session_id: str = "",
        knowledge_hits: Sequence[str] = (),
    ) -> dict[str, Any]:
        """在 artifacts 中创建开发期草稿，不写任何仓库文档。"""

        self.ensure_local_state()
        draft_id = self.next_draft_id()
        timestamp = now_iso()
        normalized_paths = sorted({normalize_path(path, self.root) for path in paths if path})
        inferred_modules = sorted({self.scope_for_path(path) for path in normalized_paths})
        draft = {
            "schema_version": SCHEMA_VERSION,
            "id": draft_id,
            "type": "bug-draft",
            "title": title.strip() or "待确认的生产缺陷",
            "status": "open",
            "severity": "medium",
            "modules": sorted(set(modules)) or inferred_modules,
            "paths": normalized_paths,
            "evidence_context": evidence_context.strip(),
            "symptom": "",
            "reproduction": "",
            "owner_paths": [],
            "write_points": [],
            "lifecycle": "",
            "platform_evidence": [],
            "root_cause": "",
            "root_cause_tags": [],
            "trigger_tags": [],
            "anti_pattern": "",
            "fix_strategy": "",
            "fix_strategy_tags": [],
            "impact": "",
            "non_impact": "",
            "validation": [],
            "regression_guards": [],
            "regression_exception": "",
            "related_commits": [],
            "knowledge_hits": list(dict.fromkeys(knowledge_hits)),
            "session_id": session_id,
            "branch": self.branch_name(),
            "created_at": timestamp,
            "updated_at": timestamp,
            "closed_at": "",
            "published_case_id": "",
        }
        atomic_write_json(self.draft_path(draft_id), draft)
        self.metric("draft_created", {"draft_id": draft_id, "session_id": session_id})
        return draft

    def update_draft(self, draft_id: str, assignments: Sequence[str]) -> dict[str, Any]:
        """用 key=JSON/value 形式增量维护开发期事实。"""

        draft = self.load_draft(draft_id)
        immutable = {"id", "type", "created_at", "published_case_id"}
        for assignment in assignments:
            if "=" not in assignment:
                raise KnowledgeError(f"草稿更新项必须是 key=value: {assignment}")
            key, raw = assignment.split("=", 1)
            key = key.strip()
            if key not in draft or key in immutable:
                raise KnowledgeError(f"不允许更新草稿字段: {key}")
            try:
                value = json.loads(raw)
            except json.JSONDecodeError:
                value = raw
            draft[key] = value
        draft["updated_at"] = now_iso()
        atomic_write_json(self.draft_path(draft_id), draft)
        return draft

    def draft_gaps(self, draft: dict[str, Any]) -> list[str]:
        """检查草稿是否完成复现、owner、写入点、生命周期与验证事实闭环。"""

        required = (
            "symptom",
            "reproduction",
            "evidence_context",
            "owner_paths",
            "write_points",
            "lifecycle",
            "platform_evidence",
            "root_cause",
            "root_cause_tags",
            "trigger_tags",
            "anti_pattern",
            "fix_strategy",
            "fix_strategy_tags",
            "impact",
            "non_impact",
            "validation",
        )
        gaps = [field for field in required if not has_value(draft.get(field))]
        if not has_value(draft.get("regression_guards")) and not has_value(draft.get("regression_exception")):
            gaps.append("regression_guards|regression_exception")
        return gaps

    def close_draft(self, draft_id: str) -> dict[str, Any]:
        """仅在事实闭环完整时关闭草稿，仍然不发布仓库文档。"""

        draft = self.load_draft(draft_id)
        gaps = self.draft_gaps(draft)
        if gaps:
            raise KnowledgeError(f"草稿事实闭环不完整: {', '.join(gaps)}")
        draft["status"] = "closed"
        draft["closed_at"] = now_iso()
        draft["updated_at"] = draft["closed_at"]
        draft["root_cause_fingerprint"] = root_cause_fingerprint(draft)
        draft["fix_strategy_fingerprint"] = fix_strategy_fingerprint(draft)
        atomic_write_json(self.draft_path(draft_id), draft)
        self.metric("draft_closed", {"draft_id": draft_id})
        return draft

    def assess(self, data: dict[str, Any]) -> dict[str, Any]:
        """评估复发风险、严重度、影响面和可门禁性，但不自动晋升模式。"""

        severity_points = {"low": 5, "medium": 12, "high": 20, "critical": 28}
        severity = str(data.get("severity", "medium"))
        breadth = min(20, len(as_list(data.get("modules"))) * 5 + len(as_list(data.get("paths"))) * 2)
        recurrence = 18 if has_value(data.get("related_case_ids")) else 8
        reproducibility = 12 if has_value(data.get("reproduction")) else 0
        guardable = 18 if has_value(data.get("regression_guards")) else 5
        score = min(100, severity_points.get(severity, 12) + breadth + recurrence + reproducibility + guardable)
        decision = "case_only"
        if score >= 70:
            decision = "promotion_and_prevention"
        elif score >= 48:
            decision = "promotion_review"
        return {
            "score": score,
            "decision": decision,
            "note": "评分只用于复审优先级；模式晋升仍要求两个独立案例、同根因、同修复策略和用户批准。",
        }

    def publish_case(self, draft_id: str, confirmed: bool = False) -> tuple[Path, dict[str, Any]]:
        """在用户明确确认任务完成后，把关闭草稿发布为正式案例卡。"""

        if not confirmed:
            raise KnowledgeError("收口前禁止发布正式案例；请在用户明确“任务已完成”后使用 --confirm-task-complete")
        draft = self.load_draft(draft_id)
        if draft.get("status") != "closed":
            raise KnowledgeError("只有事实闭环完整且已关闭的草稿才能发布")
        if draft.get("published_case_id"):
            raise KnowledgeError(f"草稿已经发布为 {draft['published_case_id']}")
        case_id = self.next_case_id()
        assessment = self.assess(draft)
        created = date.today()
        metadata = {
            "schema_version": SCHEMA_VERSION,
            "id": case_id,
            "type": "case",
            "title": draft["title"],
            "status": "closed",
            "severity": draft["severity"],
            "modules": draft["modules"],
            "paths": draft["paths"],
            "evidence_context": draft["evidence_context"],
            "owner_paths": draft["owner_paths"],
            "write_points": draft["write_points"],
            "lifecycle": draft["lifecycle"],
            "platform_evidence": draft["platform_evidence"],
            "root_cause_tags": normalized_tags(draft["root_cause_tags"]),
            "trigger_tags": normalized_tags(draft["trigger_tags"]),
            "anti_pattern": draft["anti_pattern"],
            "root_cause_fingerprint": root_cause_fingerprint(draft),
            "fix_strategy_tags": normalized_tags(draft["fix_strategy_tags"]),
            "fix_strategy_fingerprint": fix_strategy_fingerprint(draft),
            "pattern_ids": [],
            "validation": draft["validation"],
            "regression_guards": draft["regression_guards"],
            "regression_exception": draft["regression_exception"],
            "related_commits": draft["related_commits"],
            "created_at": created.isoformat(),
            "updated_at": created.isoformat(),
            "fixed_at": draft["closed_at"],
            "review_after": (created + timedelta(days=self.policy["case"]["review_days"])).isoformat(),
            "archive_reason": "",
            "score": assessment["score"],
            "pattern_deferral_reason": "等待至少两个独立案例证明同根因且同修复策略",
        }
        body = (
            f"# {draft['title']}\n\n"
            "## 问题现象与最小复现\n\n"
            f"{format_markdown_value(draft['symptom'])}\n\n"
            f"{format_markdown_value(draft['reproduction'])}\n\n"
            "## 事实链\n\n"
            f"- 真实 owner：{', '.join(draft['owner_paths'])}\n"
            f"- 真实写入点：{', '.join(draft['write_points'])}\n"
            f"- 生命周期/调用时机：{format_markdown_value(draft['lifecycle'])}\n"
            f"- 平台事实来源：\n{format_markdown_value(draft['platform_evidence'])}\n\n"
            "## 根因机制\n\n"
            f"{format_markdown_value(draft['root_cause'])}\n\n"
            "## 触发条件与影响范围\n\n"
            f"- 影响：{format_markdown_value(draft['impact'])}\n"
            f"- 不影响：{format_markdown_value(draft['non_impact'])}\n\n"
            "## 修复策略与取舍\n\n"
            f"{format_markdown_value(draft['fix_strategy'])}\n\n"
            "## 验证证据\n\n"
            f"{format_markdown_value(draft['validation'])}\n\n"
            "## 预防与边界\n\n"
            f"- 回归保护：\n{format_markdown_value(draft['regression_guards'])}\n"
            f"- 无法自动化原因：{format_markdown_value(draft['regression_exception'])}"
        )
        target = self.root / self.policy["knowledge"]["cases"] / f"{case_id}.md"
        atomic_write_text(target, render_front_matter(metadata, body))
        draft["status"] = "published"
        draft["published_case_id"] = case_id
        draft["updated_at"] = now_iso()
        atomic_write_json(self.draft_path(draft_id), draft)
        self.metric("case_published", {"draft_id": draft_id, "case_id": case_id})
        return target, metadata

    def propose_pattern(
        self,
        case_ids: Sequence[str],
        title: str,
        applicability: str,
        exclusions: str,
        confirmed: bool = False,
    ) -> tuple[Path, dict[str, Any]]:
        """从至少两个独立且同根因、同策略的正式案例起草候选模式。"""

        if not confirmed:
            raise KnowledgeError("收口前禁止写模式文档；请在用户明确“任务已完成”后使用 --confirm-task-complete")
        cases = {meta.get("id"): (path, meta, body) for path, meta, body in self.load_formal("case")}
        unique_ids = list(dict.fromkeys(case_ids))
        minimum = int(self.policy["pattern"]["minimum_independent_cases"])
        if len(unique_ids) < minimum:
            raise KnowledgeError(f"模式至少需要 {minimum} 个独立案例")
        missing = [case_id for case_id in unique_ids if case_id not in cases]
        if missing:
            raise KnowledgeError(f"找不到正式案例: {', '.join(missing)}")
        selected = [cases[case_id][1] for case_id in unique_ids]
        contexts = {str(case.get("evidence_context", "")).strip() for case in selected}
        if "" in contexts or len(contexts) < minimum:
            raise KnowledgeError("案例必须来自至少两个独立证据上下文")
        root_fingerprints = {case.get("root_cause_fingerprint") for case in selected}
        fix_fingerprints = {case.get("fix_strategy_fingerprint") for case in selected}
        if len(root_fingerprints) != 1 or None in root_fingerprints:
            raise KnowledgeError("所选案例的根因指纹不一致")
        if len(fix_fingerprints) != 1 or None in fix_fingerprints:
            raise KnowledgeError("所选案例的修复策略指纹不一致")
        if not has_value(applicability) or not has_value(exclusions):
            raise KnowledgeError("候选模式必须明确适用和不适用边界")
        pattern_id = self.next_pattern_id()
        today = date.today()
        strategy_tags = selected[0].get("fix_strategy_tags", [])
        metadata = {
            "schema_version": SCHEMA_VERSION,
            "id": pattern_id,
            "type": "pattern",
            "title": title,
            "status": "candidate",
            "case_ids": unique_ids,
            "root_cause_fingerprint": next(iter(root_fingerprints)),
            "fix_strategy_fingerprint": next(iter(fix_fingerprints)),
            "fix_strategy_tags": strategy_tags,
            "modules": sorted({module for case in selected for module in as_list(case.get("modules"))}),
            "paths": sorted({path for case in selected for path in as_list(case.get("paths"))}),
            "applicability": applicability,
            "exclusions": exclusions,
            "enforcement": [],
            "approved_by": "",
            "approved_at": "",
            "created_at": today.isoformat(),
            "updated_at": today.isoformat(),
            "review_after": (today + timedelta(days=self.policy["pattern"]["review_days"])).isoformat(),
        }
        body = (
            f"# {title}\n\n"
            "## 模式说明\n\n"
            f"由案例 {', '.join(unique_ids)} 证明的同根因、同修复策略候选模式。\n\n"
            "## 适用边界\n\n"
            f"{applicability}\n\n"
            "## 不适用边界\n\n"
            f"{exclusions}\n\n"
            "## 统一修复策略\n\n"
            f"{', '.join(strategy_tags)}\n\n"
            "## 保护方式\n\n"
            "当前为 candidate；用户批准后方可进入 active，且只有必执行测试、静态脚本、构建路径或 Git Hook 覆盖后方可进入 enforced。"
        )
        target = self.root / self.policy["knowledge"]["patterns"] / f"{pattern_id}.md"
        atomic_write_text(target, render_front_matter(metadata, body))
        self.metric("pattern_proposed", {"pattern_id": pattern_id, "case_ids": unique_ids})
        return target, metadata

    def source_paths(self) -> list[Path]:
        """枚举允许进入本地索引的权威知识来源，排除工具副本与用户数据。"""

        paths = set(self.formal_paths())
        for pattern in self.policy["index_sources"]:
            for path in self.root.glob(pattern):
                if path.is_file() and not self.is_excluded_for_index(path):
                    paths.add(path)
        return sorted(paths)

    def is_excluded_for_index(self, path: Path) -> bool:
        """限制索引只读取明确允许的仓库规则和经验资料。"""

        relative = self.relative(path)
        blocked = ("Vendor/", "vendor/", ".codex/skills/", "artifacts/", "tmp/")
        return relative.startswith(blocked)

    def search_records(self, include_drafts: bool = True) -> list[SearchRecord]:
        """把异构知识源转换为统一检索记录。"""

        records: list[SearchRecord] = []
        formal = {path.resolve() for path in self.formal_paths()}
        for path in self.source_paths():
            relative = self.relative(path)
            text = path.read_text(encoding="utf-8", errors="replace")
            if path.resolve() in formal:
                metadata, body = parse_front_matter(text, relative)
                kind = str(metadata.get("type", "document"))
                records.append(
                    SearchRecord(
                        str(metadata.get("id", relative)),
                        kind,
                        str(metadata.get("title", path.stem)),
                        relative,
                        str(metadata.get("status", "")),
                        metadata,
                        body,
                    )
                )
                continue
            kind = "rule" if relative == "AGENTS.md" or relative.startswith(".agents/skills/") else "learning"
            title_match = re.search(r"^#\s+(.+)$", text, re.MULTILINE)
            title = title_match.group(1).strip() if title_match else path.stem
            records.append(SearchRecord(relative, kind, title, relative, "current", {}, text))
        if include_drafts:
            for draft in self.iter_drafts():
                body_fields = (
                    "symptom",
                    "reproduction",
                    "root_cause",
                    "fix_strategy",
                    "impact",
                    "non_impact",
                )
                body = "\n".join(str(draft.get(field, "")) for field in body_fields)
                records.append(
                    SearchRecord(
                        draft["id"],
                        "draft",
                        draft.get("title", draft["id"]),
                        self.relative(self.draft_path(draft["id"])),
                        draft.get("status", "open"),
                        draft,
                        body,
                    )
                )
        return records

    def rebuild_index(self, records: Sequence[SearchRecord] | None = None) -> None:
        """重建可随时删除的 SQLite/FTS 本地索引。"""

        self.ensure_local_state()
        records = list(records or self.search_records())
        temporary = self.index_path.with_suffix(f".{uuid.uuid4().hex}.tmp")
        connection = sqlite3.connect(temporary)
        try:
            connection.execute(
                "CREATE TABLE documents (record_id TEXT PRIMARY KEY, kind TEXT, title TEXT, path TEXT, status TEXT, metadata TEXT, body TEXT)"
            )
            try:
                connection.execute(
                    "CREATE VIRTUAL TABLE documents_fts USING fts5(record_id UNINDEXED, title, path, metadata, body, tokenize='unicode61')"
                )
                has_fts = True
            except sqlite3.OperationalError:
                has_fts = False
            for record in records:
                metadata = json.dumps(record.metadata, ensure_ascii=False, sort_keys=True)
                connection.execute(
                    "INSERT INTO documents VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (record.record_id, record.kind, record.title, record.path, record.status, metadata, record.body),
                )
                if has_fts:
                    connection.execute(
                        "INSERT INTO documents_fts VALUES (?, ?, ?, ?, ?)",
                        (record.record_id, record.title, record.path, metadata, record.body),
                    )
            connection.commit()
        finally:
            connection.close()
        os.replace(temporary, self.index_path)

    @staticmethod
    def query_terms(query: str) -> list[str]:
        """提取英文、路径和中文短语，供无外部依赖的确定性排序使用。"""

        raw = re.findall(r"[A-Za-z0-9_./-]+|[\u4e00-\u9fff]+", query.lower())
        return [term for term in raw if len(term) >= 2 or term.isascii()]

    def record_match(self, record: SearchRecord, query: str, paths: Sequence[str]) -> tuple[bool, float, list[str]]:
        """先确认真实文本/元数据/路径命中，再计算类型与状态加权。"""

        metadata_text = json.dumps(record.metadata, ensure_ascii=False, sort_keys=True)
        haystack = f"{record.title}\n{record.path}\n{metadata_text}\n{record.body}".lower()
        normalized_query = " ".join(query.lower().split())
        terms = self.query_terms(query)
        reasons: list[str] = []
        base = 0.0
        if normalized_query and normalized_query in haystack:
            base += 10.0
            reasons.append("完整短语")
        matched_terms = [term for term in terms if term in haystack]
        if matched_terms:
            base += min(18.0, len(matched_terms) * 4.0)
            reasons.append("关键词:" + ",".join(matched_terms[:4]))
        title_ratio = SequenceMatcher(None, normalized_query, record.title.lower()).ratio() if normalized_query else 0.0
        if title_ratio >= 0.58:
            base += title_ratio * 6.0
            reasons.append("标题近似")
        record_paths = [record.path, *[str(item) for item in as_list(record.metadata.get("paths"))]]
        path_hits = []
        for requested in paths:
            requested_normalized = normalize_path(requested, self.root)
            for candidate in record_paths:
                candidate_normalized = normalize_path(candidate, self.root)
                if (
                    requested_normalized == candidate_normalized
                    or requested_normalized.startswith(candidate_normalized.rstrip("/") + "/")
                    or candidate_normalized.startswith(requested_normalized.rstrip("/") + "/")
                    or self.scope_for_path(requested_normalized) == self.scope_for_path(candidate_normalized)
                ):
                    path_hits.append(requested_normalized)
                    break
        if path_hits:
            base += min(16.0, len(set(path_hits)) * 8.0)
            reasons.append("相关路径")
        if base <= 0:
            return False, 0.0, []
        kind_bonus = {"pattern": 7.0, "rule": 6.0, "case": 5.0, "learning": 2.0, "draft": 1.0}.get(record.kind, 0.0)
        status_bonus = {"enforced": 8.0, "active": 6.0, "candidate": 1.0, "current": 2.0}.get(record.status, 0.0)
        return True, base + kind_bonus + status_bonus, reasons

    def rank_records(
        self,
        records: Sequence[SearchRecord],
        query: str,
        paths: Sequence[str],
        limit: int,
    ) -> list[dict[str, Any]]:
        """对已加载知识执行先命中、后加权的确定性排序。"""

        ranked = []
        for record in records:
            matched, score, reasons = self.record_match(record, query, paths)
            if not matched:
                continue
            ranked.append(
                {
                    "id": record.record_id,
                    "kind": record.kind,
                    "title": record.title,
                    "path": record.path,
                    "status": record.status,
                    "score": round(score, 3),
                    "reasons": reasons,
                }
            )
        ranked.sort(key=lambda item: (-item["score"], item["kind"], item["id"]))
        return ranked[:limit]

    def search(self, query: str, paths: Sequence[str] = (), limit: int | None = None) -> dict[str, Any]:
        """检索正式知识、项目规则、学习资料、草稿和 Git 历史。"""

        records = self.search_records()
        self.rebuild_index(records)
        requested_limit = limit or int(self.policy["search"]["default_limit"])
        result = {
            "query": query,
            "paths": [normalize_path(path, self.root) for path in paths],
            "matches": self.rank_records(records, query, paths, requested_limit),
            "repository_matches": self.repository_text_matches(query, requested_limit),
            "git_history": self.git_history(query, paths, requested_limit),
        }
        self.metric(
            "search",
            {
                "query_hash": stable_hash(query),
                "paths": result["paths"],
                "match_count": len(result["matches"]),
                "no_hit": not bool(result["matches"]),
            },
        )
        return result

    def repository_text_matches(self, query: str, limit: int) -> list[str]:
        """使用 rg 补充未结构化资料命中；不可用时安静降级。"""

        terms = self.query_terms(query)
        if not terms:
            return []
        candidates = ["AGENTS.md", ".agents/skills", "docs/architecture", "docs/learning", "docs/踩坑记录.md", "docs/feature"]
        existing = [item for item in candidates if (self.root / item).exists()]
        if not existing:
            return []
        seen: list[str] = []
        for term in terms[:4]:
            try:
                result = subprocess.run(
                    ["rg", "-l", "-i", "--fixed-strings", term, *existing],
                    cwd=self.root,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
            except FileNotFoundError:
                return []
            for line in result.stdout.splitlines():
                normalized = normalize_path(line, self.root)
                if normalized not in seen:
                    seen.append(normalized)
                if len(seen) >= limit:
                    return seen
        return seen

    def git_history(self, query: str, paths: Sequence[str], limit: int) -> list[dict[str, str]]:
        """从提交说明、相关路径历史和内容差异历史补充证据来源。"""

        entries: dict[str, dict[str, str]] = {}

        def collect(arguments: list[str]) -> None:
            result = self.run_git(arguments)
            if result.returncode != 0:
                return
            for line in result.stdout.splitlines():
                parts = line.split("\x1f", 2)
                if len(parts) == 3:
                    entries.setdefault(parts[0], {"commit": parts[0], "date": parts[1], "subject": parts[2]})

        pretty = "%H%x1f%cs%x1f%s"
        if query.strip():
            collect(["log", "--all", f"--max-count={limit}", f"--pretty=format:{pretty}", "--regexp-ignore-case", f"--grep={query}"])
        normalized_paths = [normalize_path(path, self.root) for path in paths if (self.root / normalize_path(path, self.root)).exists()]
        if normalized_paths:
            collect(["log", f"--max-count={limit}", f"--pretty=format:{pretty}", "--", *normalized_paths])
        terms = self.query_terms(query)
        if terms:
            collect(["log", "--all", f"--max-count={limit}", f"--pretty=format:{pretty}", f"-G{re.escape(terms[0])}"])
        return list(entries.values())[:limit]

    def validate(self) -> dict[str, Any]:
        """校验正式知识的格式、ID、引用、指纹、评分与状态语义。"""

        errors: list[str] = []
        warnings: list[str] = []
        documents: list[tuple[Path, dict[str, Any], str]] = []
        for path in self.formal_paths():
            try:
                metadata, body = parse_front_matter(path.read_text(encoding="utf-8"), self.relative(path))
                documents.append((path, metadata, body))
            except KnowledgeError as error:
                errors.append(str(error))
        ids: dict[str, str] = {}
        case_ids: set[str] = set()
        pattern_ids: set[str] = set()
        for path, metadata, body in documents:
            relative = self.relative(path)
            identifier = str(metadata.get("id", ""))
            kind = metadata.get("type")
            if identifier in ids:
                errors.append(f"{relative}: ID 与 {ids[identifier]} 重复: {identifier}")
            ids[identifier] = relative
            if metadata.get("schema_version") != SCHEMA_VERSION:
                errors.append(f"{relative}: schema_version 必须为 {SCHEMA_VERSION}")
            if kind == "case":
                case_ids.add(identifier)
                if not CASE_ID_PATTERN.match(identifier):
                    errors.append(f"{relative}: 非法案例 ID {identifier}")
                if metadata.get("status") not in self.policy["case"]["statuses"]:
                    errors.append(f"{relative}: 非法案例状态 {metadata.get('status')}")
                required = (
                    "title", "severity", "modules", "paths", "evidence_context", "owner_paths", "write_points",
                    "lifecycle", "platform_evidence", "root_cause_tags", "trigger_tags", "anti_pattern",
                    "root_cause_fingerprint", "fix_strategy_tags", "fix_strategy_fingerprint", "validation",
                    "review_after", "score",
                )
                for field in required:
                    if not has_value(metadata.get(field)):
                        errors.append(f"{relative}: 缺少案例字段 {field}")
                if metadata.get("root_cause_fingerprint") != root_cause_fingerprint(metadata):
                    errors.append(f"{relative}: 根因指纹与元数据不一致")
                if metadata.get("fix_strategy_fingerprint") != fix_strategy_fingerprint(metadata):
                    errors.append(f"{relative}: 修复策略指纹与元数据不一致")
                if not has_value(metadata.get("regression_guards")) and not has_value(metadata.get("regression_exception")):
                    errors.append(f"{relative}: 必须记录回归保护或无法自动化原因")
                for section in CASE_SECTIONS:
                    if f"## {section}" not in body:
                        errors.append(f"{relative}: 缺少正文段落 {section}")
            elif kind == "pattern":
                pattern_ids.add(identifier)
                if not PATTERN_ID_PATTERN.match(identifier):
                    errors.append(f"{relative}: 非法模式 ID {identifier}")
                status = metadata.get("status")
                if status not in self.policy["pattern"]["statuses"]:
                    errors.append(f"{relative}: 非法模式状态 {status}")
                case_refs = as_list(metadata.get("case_ids"))
                if len(set(case_refs)) < int(self.policy["pattern"]["minimum_independent_cases"]):
                    errors.append(f"{relative}: 模式不足两个独立案例")
                for field in ("applicability", "exclusions", "root_cause_fingerprint", "fix_strategy_fingerprint", "review_after"):
                    if not has_value(metadata.get(field)):
                        errors.append(f"{relative}: 缺少模式字段 {field}")
                if status in {"active", "enforced"} and (
                    not has_value(metadata.get("approved_by")) or not has_value(metadata.get("approved_at"))
                ):
                    errors.append(f"{relative}: {status} 模式缺少用户批准记录")
                if status == "enforced" and not self.valid_enforcement(metadata.get("enforcement")):
                    errors.append(f"{relative}: enforced 模式没有真实必执行保护")
                for section in PATTERN_SECTIONS:
                    if f"## {section}" not in body:
                        errors.append(f"{relative}: 缺少正文段落 {section}")
            else:
                errors.append(f"{relative}: type 必须是 case 或 pattern")
            score = metadata.get("score")
            if score is not None and (not isinstance(score, int) or not 0 <= score <= 100):
                errors.append(f"{relative}: score 必须是 0...100 的整数")
        cases_by_id = {
            str(metadata.get("id")): metadata
            for _, metadata, _ in documents
            if metadata.get("type") == "case"
        }
        for path, metadata, _ in documents:
            relative = self.relative(path)
            if metadata.get("type") == "case":
                for pattern_id in as_list(metadata.get("pattern_ids")):
                    if pattern_id not in pattern_ids:
                        errors.append(f"{relative}: 引用了不存在的模式 {pattern_id}")
            if metadata.get("type") == "pattern":
                referenced_cases = []
                for case_id in as_list(metadata.get("case_ids")):
                    if case_id not in case_ids:
                        errors.append(f"{relative}: 引用了不存在的案例 {case_id}")
                    else:
                        referenced_cases.append(cases_by_id[case_id])
                if referenced_cases:
                    contexts = {str(case.get("evidence_context", "")).strip() for case in referenced_cases}
                    roots = {case.get("root_cause_fingerprint") for case in referenced_cases}
                    fixes = {case.get("fix_strategy_fingerprint") for case in referenced_cases}
                    if "" in contexts or len(contexts) < int(self.policy["pattern"]["minimum_independent_cases"]):
                        errors.append(f"{relative}: 引用案例不是独立证据上下文")
                    if len(roots) != 1 or metadata.get("root_cause_fingerprint") not in roots:
                        errors.append(f"{relative}: 引用案例根因指纹不一致")
                    if len(fixes) != 1 or metadata.get("fix_strategy_fingerprint") not in fixes:
                        errors.append(f"{relative}: 引用案例修复策略指纹不一致")
        return {"ok": not errors, "documents": len(documents), "errors": errors, "warnings": warnings}

    def valid_enforcement(self, enforcement: Any) -> bool:
        """确认 enforced 模式确有必执行且路径存在的程序化保护。"""

        allowed = set(self.policy["pattern"]["enforcement_types"])
        for guard in as_list(enforcement):
            if not isinstance(guard, dict):
                continue
            path = normalize_path(str(guard.get("path", "")), self.root)
            if guard.get("type") in allowed and guard.get("mandatory") is True and path and (self.root / path).exists():
                return True
        return False

    def audit(self) -> dict[str, Any]:
        """审计重复根因、失效路径、到期复审和虚假 enforced。"""

        validation = self.validate()
        errors = list(validation["errors"])
        warnings: list[str] = []
        fingerprints: dict[tuple[str, str], list[str]] = {}
        today = date.today()
        for path, metadata, _ in self.load_formal():
            identifier = str(metadata.get("id", self.relative(path)))
            if metadata.get("type") == "case":
                key = (
                    str(metadata.get("root_cause_fingerprint", "")),
                    str(metadata.get("fix_strategy_fingerprint", "")),
                )
                fingerprints.setdefault(key, []).append(identifier)
            review_after = str(metadata.get("review_after", ""))
            try:
                if review_after and date.fromisoformat(review_after) < today:
                    warnings.append(f"{identifier}: 已超过复审日期 {review_after}")
            except ValueError:
                errors.append(f"{identifier}: review_after 不是合法日期")
            for recorded_path in as_list(metadata.get("paths")):
                normalized = normalize_path(str(recorded_path), self.root)
                if normalized and not any(self.root.glob(normalized)):
                    warnings.append(f"{identifier}: 相关路径当前不存在 {normalized}")
            if metadata.get("type") == "pattern" and metadata.get("status") == "enforced" and not self.valid_enforcement(metadata.get("enforcement")):
                errors.append(f"{identifier}: 虚假 enforced")
        duplicates = [ids for key, ids in fingerprints.items() if all(key) and len(ids) >= 2]
        for identifiers in duplicates:
            warnings.append(f"发现可评估为候选模式的重复根因/策略: {', '.join(identifiers)}")
        return {
            "ok": not errors,
            "errors": sorted(set(errors)),
            "warnings": sorted(set(warnings)),
            "duplicate_groups": duplicates,
            "open_drafts": sum(1 for draft in self.iter_drafts() if draft.get("status") == "open"),
        }

    def evaluate(self, evaluation_file: Path | None = None) -> dict[str, Any]:
        """执行固定检索评测并报告 Recall@5、MRR、无结果率和负例误召回率。"""

        default = self.root / "scripts/ai-knowledge/eval_queries.json"
        path = evaluation_file or default
        payload = read_json(path, {"queries": []})
        queries = payload.get("queries", []) if isinstance(payload, dict) else payload
        if not queries:
            return {
                "ok": True,
                "query_count": 0,
                "recall_at_5": None,
                "mrr": None,
                "no_result_rate": None,
                "negative_false_positive_rate": None,
                "note": "尚未发布正式种子案例，固定评测集将在用户确认任务完成后的收口阶段补齐。",
            }
        positive_expected = 0
        positive_hits = 0
        reciprocal_ranks: list[float] = []
        zero_results = 0
        negative_count = 0
        negative_false_positives = 0
        details = []
        records = self.search_records(include_drafts=False)
        self.rebuild_index(records)
        for item in queries:
            matches = self.rank_records(records, item["query"], item.get("paths", []), 5)
            ids = [match["id"] for match in matches]
            if not ids:
                zero_results += 1
            if item.get("negative"):
                negative_count += 1
                forbidden = set(item.get("forbidden_ids", item.get("expected_ids", [])))
                is_false_positive = bool(forbidden.intersection(ids)) if forbidden else bool(ids)
                if is_false_positive:
                    negative_false_positives += 1
                details.append(
                    {
                        "query": item["query"],
                        "negative": True,
                        "forbidden": sorted(forbidden),
                        "results": ids,
                        "false_positive": is_false_positive,
                    }
                )
                continue
            expected = set(item.get("expected_ids", []))
            positive_expected += len(expected)
            hits = expected.intersection(ids)
            positive_hits += len(hits)
            first_rank = next((index + 1 for index, identifier in enumerate(ids) if identifier in expected), None)
            reciprocal_ranks.append(1.0 / first_rank if first_rank else 0.0)
            details.append({"query": item["query"], "expected": sorted(expected), "results": ids, "hits": sorted(hits)})
        recall = positive_hits / positive_expected if positive_expected else 1.0
        mrr = sum(reciprocal_ranks) / len(reciprocal_ranks) if reciprocal_ranks else 1.0
        no_result_rate = zero_results / len(queries)
        negative_rate = negative_false_positives / negative_count if negative_count else 0.0
        minimum = float(self.policy["search"]["minimum_recall_at_5"])
        return {
            "ok": recall >= minimum and negative_rate <= 0.2,
            "query_count": len(queries),
            "recall_at_5": round(recall, 4),
            "mrr": round(mrr, 4),
            "no_result_rate": round(no_result_rate, 4),
            "negative_false_positive_rate": round(negative_rate, 4),
            "details": details,
        }

    def metric(self, event: str, fields: dict[str, Any]) -> None:
        """追加匿名化试运行事件，不把用户提示正文写入指标。"""

        self.ensure_local_state()
        path = self.metrics_dir / f"{date.today():%Y-%m}.jsonl"
        payload = {"timestamp": now_iso(), "event": event, **fields}
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")

    def metrics(self) -> dict[str, Any]:
        """汇总试运行采用率、无命中率、首次拦截和案例保护覆盖率。"""

        events = []
        if self.metrics_dir.exists():
            for path in sorted(self.metrics_dir.glob("*.jsonl")):
                for line in path.read_text(encoding="utf-8").splitlines():
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        counts: dict[str, int] = {}
        for event in events:
            name = str(event.get("event", "unknown"))
            counts[name] = counts.get(name, 0) + 1
        searches = [event for event in events if event.get("event") == "search"]
        cases = [metadata for _, metadata, _ in self.load_formal("case")]
        protected_cases = sum(
            1
            for case in cases
            if has_value(case.get("regression_guards")) and not has_value(case.get("regression_exception"))
        )
        closed_drafts = sum(1 for draft in self.iter_drafts() if draft.get("status") in {"closed", "published"})
        published = sum(1 for draft in self.iter_drafts() if draft.get("status") == "published")
        return {
            "events": counts,
            "search_no_hit_rate": (
                sum(1 for event in searches if event.get("no_hit")) / len(searches) if searches else None
            ),
            "draft_to_case_adoption_rate": published / closed_drafts if closed_drafts else None,
            "protection_coverage": protected_cases / len(cases) if cases else None,
            "false_block_rate": None,
            "note": "误拦截率需要在人工确认误报后通过 metric 事件补充，试运行期不伪造数值。",
        }

    def session_path(self, session_id: str) -> Path:
        """返回安全的 Hook 会话文件路径。"""

        safe = re.sub(r"[^A-Za-z0-9_.-]", "_", session_id)[:120]
        return self.sessions_dir / f"{safe}.json"

    def resolve_session_id(self, payload: dict[str, Any], create: bool = False) -> str:
        """兼容 Codex 字段并在缺失时使用 worktree 本地当前会话指针。"""

        for key in ("session_id", "sessionId", "conversation_id", "thread_id", "threadId"):
            if payload.get(key):
                return str(payload[key])
        for key in ("CODEX_SESSION_ID", "CODEX_THREAD_ID"):
            if os.environ.get(key):
                return os.environ[key]
        pointer = read_json(self.sessions_dir / "current.json", {}) if self.sessions_dir.exists() else {}
        if pointer.get("session_id"):
            return str(pointer["session_id"])
        if create:
            return f"local-{uuid.uuid4().hex[:12]}"
        return "local-default"

    def save_session(self, session: dict[str, Any]) -> None:
        """保存会话基线、范围凭证和关联草稿。"""

        self.ensure_local_state()
        atomic_write_json(self.session_path(session["session_id"]), session)
        atomic_write_json(self.sessions_dir / "current.json", {"session_id": session["session_id"]})

    def load_session(self, session_id: str) -> dict[str, Any]:
        """读取 Hook 会话；不存在时返回最小空状态。"""

        return read_json(
            self.session_path(session_id),
            {
                "session_id": session_id,
                "suspected_bug": False,
                "closure_requested": False,
                "prompt": "",
                "baseline": {},
                "covered_scopes": [],
                "draft_ids": [],
            },
        )

    def suspected_bug_prompt(self, prompt: str) -> bool:
        """区分真实缺陷任务与“设计 Bug 工作流”等元任务。"""

        lowered = prompt.lower()
        detection = self.policy["bug_detection"]
        has_bug = any(marker.lower() in lowered for marker in detection["bug_markers"])
        has_meta = any(marker.lower() in lowered for marker in detection["meta_task_markers"])
        has_concrete = any(marker.lower() in lowered for marker in detection["concrete_evidence_markers"])
        if has_meta and not has_concrete:
            return False
        return has_bug

    def closure_requested(self, prompt: str) -> bool:
        """仅识别仓库约定的用户明确收口信号。"""

        return any(marker in prompt for marker in self.policy["bug_detection"]["completion_markers"])

    def hook_session_start(self, payload: dict[str, Any]) -> dict[str, Any]:
        """在会话开始时只注入入口、待处理草稿和到期数量。"""

        session_id = self.resolve_session_id(payload, create=True)
        self.ensure_local_state()
        self.save_session(self.load_session(session_id))
        audit = self.audit()
        open_drafts = audit["open_drafts"]
        overdue = sum(1 for warning in audit["warnings"] if "超过复审日期" in warning)
        context = (
            "XMNote Bug 经验入口：真实生产缺陷在首次写入相关范围前会检索一次。"
            f" 当前 worktree 有 {open_drafts} 个开放草稿、{overdue} 个到期复审项。"
            " 开发期只写 artifacts/ai-knowledge；仅在用户明确“任务已完成”后发布正式案例。"
        )
        return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}

    def hook_user_prompt(self, payload: dict[str, Any]) -> dict[str, Any]:
        """识别任务类型并保存当前脏工作树哈希基线。"""

        session_id = self.resolve_session_id(payload, create=True)
        prompt = str(payload.get("prompt") or payload.get("user_prompt") or payload.get("input") or "")
        previous = self.load_session(session_id)
        is_closure = self.closure_requested(prompt)
        if is_closure and previous.get("suspected_bug"):
            previous["closure_requested"] = True
            previous["last_prompt"] = prompt
            previous["updated_at"] = now_iso()
            self.save_session(previous)
            return {}
        session = {
            "session_id": session_id,
            "suspected_bug": self.suspected_bug_prompt(prompt),
            "closure_requested": is_closure,
            "prompt": prompt,
            "baseline": self.changed_state(),
            "covered_scopes": [],
            "draft_ids": [],
            "branch": self.branch_name(),
            "started_at": now_iso(),
        }
        self.save_session(session)
        return {}

    def extract_tool_paths(self, payload: dict[str, Any]) -> list[str]:
        """从 apply_patch、编辑器和命令工具输入中提取可能写入的仓库路径。"""

        tool_input = payload.get("tool_input") or payload.get("toolInput") or payload.get("input") or {}
        paths: set[str] = set()

        def visit(value: Any, key: str = "") -> None:
            if isinstance(value, dict):
                for child_key, child in value.items():
                    visit(child, child_key)
            elif isinstance(value, list):
                for child in value:
                    visit(child, key)
            elif isinstance(value, str):
                if key in {"file_path", "filePath", "path", "target"}:
                    paths.add(normalize_path(value, self.root))
                for pattern in (
                    r"^\*\*\* (?:Add|Update|Delete) File: (.+)$",
                    r"^\+\+\+ (?:b/)?(.+)$",
                ):
                    for match in re.finditer(pattern, value, re.MULTILINE):
                        candidate = match.group(1).strip()
                        if candidate != "/dev/null":
                            paths.add(normalize_path(candidate, self.root))
                for match in re.finditer(
                    r"(?<![A-Za-z0-9_.-])((?:xmnote|scripts|Vendor|docs|artifacts|\.codex|\.agents|\.githooks)/[^\s'\";|&()]+|xmnote\.xcodeproj/project\.pbxproj|Package\.resolved|Makefile\.parallel-ios)",
                    value,
                ):
                    paths.add(normalize_path(match.group(1).rstrip(",:)"), self.root))

        visit(tool_input)
        return sorted(path for path in paths if self.is_protected(path))

    def hook_pre_tool_use(self, payload: dict[str, Any]) -> dict[str, Any]:
        """对真实 Bug 任务的每个新功能域首次生产写入拒绝一次并返回命中项。"""

        session_id = self.resolve_session_id(payload)
        session = self.load_session(session_id)
        if not session.get("suspected_bug"):
            return {}
        paths = self.extract_tool_paths(payload)
        if not paths:
            return {}
        scopes = sorted({self.scope_for_path(path) for path in paths})
        new_scopes = [scope for scope in scopes if scope not in session.get("covered_scopes", [])]
        if not new_scopes:
            return {}
        query = str(session.get("prompt", ""))
        result = self.search(query, paths, limit=5)
        hits = [item["id"] for item in result["matches"]]
        draft = self.init_draft(
            title=f"待确认：{query.strip()[:72] or '生产缺陷'}",
            paths=paths,
            evidence_context=f"session:{session_id}; branch:{session.get('branch', self.branch_name())}",
            session_id=session_id,
            knowledge_hits=hits,
        )
        session.setdefault("covered_scopes", []).extend(new_scopes)
        session["covered_scopes"] = sorted(set(session["covered_scopes"]))
        session.setdefault("draft_ids", []).append(draft["id"])
        self.save_session(session)
        self.metric("first_write_block", {"session_id": session_id, "scopes": new_scopes, "draft_id": draft["id"]})
        summaries = [f"{item['id']} {item['title']} ({item['path']})" for item in result["matches"]]
        reason = (
            f"该 Bug 任务首次写入范围 {', '.join(new_scopes)}，已完成经验检索并创建本地草稿 {draft['id']}。\n"
            + ("命中：\n- " + "\n- ".join(summaries) + "\n" if summaries else "未命中正式知识；请继续按事实闭环诊断。\n")
            + "请先阅读命中项，再原样重试本次写入；同范围后续不会重复拦截。"
        )
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }

    def hook_stop(self, payload: dict[str, Any]) -> dict[str, Any]:
        """只检查本轮相对基线的生产改动，并通过 stop_hook_active 防止无限续跑。"""

        if payload.get("stop_hook_active") or payload.get("stopHookActive"):
            return {}
        session_id = self.resolve_session_id(payload)
        session = self.load_session(session_id)
        if not session.get("suspected_bug"):
            return {}
        changed = self.task_attributable_changes(session.get("baseline", {}))
        if not changed:
            return {}
        drafts = []
        for draft_id in session.get("draft_ids", []):
            try:
                drafts.append(self.load_draft(draft_id))
            except KnowledgeError:
                continue
        if not drafts:
            return {
                "decision": "block",
                "reason": "本轮产生了生产改动，但没有关联 Bug 草稿。请先运行 draft init 并补齐事实闭环。",
            }
        incomplete = []
        for draft in drafts:
            if draft.get("status") == "open":
                gaps = self.draft_gaps(draft)
                incomplete.append(f"{draft['id']}: {', '.join(gaps)}")
        if incomplete:
            return {
                "decision": "block",
                "reason": "Bug 草稿尚未形成事实闭环：\n" + "\n".join(incomplete) + "\n补齐后执行 draft close。",
            }
        if session.get("closure_requested"):
            unpublished = [draft["id"] for draft in drafts if draft.get("status") == "closed"]
            if unpublished:
                return {
                    "decision": "block",
                    "reason": (
                        "用户已明确“任务已完成”，但草稿尚未发布正式案例："
                        + ", ".join(unpublished)
                        + "。请执行 case publish --confirm-task-complete 并完成知识校验。"
                    ),
                }
        return {}


def discover_repository(root: str | None) -> Repository:
    """创建 CLI 仓库上下文，并支持测试 fixture 显式指定根目录。"""

    return Repository(Path(root)) if root else Repository.discover()


def print_result(data: Any, as_json: bool = True) -> None:
    """以稳定 JSON 输出供 Hook、测试和人工审阅。"""

    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(data)


def parse_hook_payload() -> dict[str, Any]:
    """从 stdin 读取 Codex Hook JSON；空输入视为空对象。"""

    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise KnowledgeError("Hook 输入必须是 JSON 对象")
    return data


def build_parser() -> argparse.ArgumentParser:
    """构建稳定的命令行接口。"""

    parser = argparse.ArgumentParser(description="XMNote iOS AI Bug 经验闭环工具")
    parser.add_argument("--root", help="显式指定仓库根目录，主要用于 fixture 测试")
    subparsers = parser.add_subparsers(dest="command", required=True)

    search = subparsers.add_parser("search", help="检索案例、模式、规则、学习资料和 Git 历史")
    search.add_argument("--query", required=True)
    search.add_argument("--paths", nargs="*", default=[])
    search.add_argument("--limit", type=int)

    draft = subparsers.add_parser("draft", help="管理开发期本地草稿")
    draft_commands = draft.add_subparsers(dest="draft_command", required=True)
    draft_init = draft_commands.add_parser("init")
    draft_init.add_argument("--title", required=True)
    draft_init.add_argument("--paths", nargs="*", default=[])
    draft_init.add_argument("--modules", nargs="*", default=[])
    draft_init.add_argument("--evidence-context", default="")
    draft_init.add_argument("--session-id", default="")
    draft_update = draft_commands.add_parser("update")
    draft_update.add_argument("draft_id")
    draft_update.add_argument("--set", dest="assignments", action="append", required=True)
    draft_close = draft_commands.add_parser("close")
    draft_close.add_argument("draft_id")
    draft_show = draft_commands.add_parser("show")
    draft_show.add_argument("draft_id")
    draft_commands.add_parser("list")

    case = subparsers.add_parser("case", help="评估或发布正式案例")
    case_commands = case.add_subparsers(dest="case_command", required=True)
    case_publish = case_commands.add_parser("publish")
    case_publish.add_argument("draft_id")
    case_publish.add_argument("--confirm-task-complete", action="store_true")
    case_assess = case_commands.add_parser("assess")
    case_assess.add_argument("identifier")

    pattern = subparsers.add_parser("pattern", help="从独立正式案例提出候选模式")
    pattern_commands = pattern.add_subparsers(dest="pattern_command", required=True)
    propose = pattern_commands.add_parser("propose")
    propose.add_argument("--case-ids", nargs="+", required=True)
    propose.add_argument("--title", required=True)
    propose.add_argument("--applicability", required=True)
    propose.add_argument("--exclusions", required=True)
    propose.add_argument("--confirm-task-complete", action="store_true")

    subparsers.add_parser("validate", help="校验正式知识格式与状态")
    subparsers.add_parser("audit", help="审计重复、过期和虚假 enforced")
    evaluation = subparsers.add_parser("eval", help="运行固定检索评测")
    evaluation.add_argument("--file")
    subparsers.add_parser("metrics", help="汇总 30 天试运行指标")

    hook = subparsers.add_parser("hook", help="承载 Codex 生命周期事件")
    hook.add_argument("event", choices=("session-start", "user-prompt", "pre-tool-use", "stop"))
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """执行 CLI 命令并用非零退出码表达治理失败。"""

    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        repository = discover_repository(args.root)
        if args.command == "search":
            print_result(repository.search(args.query, args.paths, args.limit))
        elif args.command == "draft":
            if args.draft_command == "init":
                print_result(
                    repository.init_draft(
                        args.title,
                        args.paths,
                        args.modules,
                        args.evidence_context,
                        args.session_id,
                    )
                )
            elif args.draft_command == "update":
                print_result(repository.update_draft(args.draft_id, args.assignments))
            elif args.draft_command == "close":
                print_result(repository.close_draft(args.draft_id))
            elif args.draft_command == "show":
                print_result(repository.load_draft(args.draft_id))
            else:
                print_result(repository.iter_drafts())
        elif args.command == "case":
            if args.case_command == "publish":
                path, metadata = repository.publish_case(args.draft_id, args.confirm_task_complete)
                print_result({"path": repository.relative(path), "case": metadata})
            else:
                data = None
                if DRAFT_ID_PATTERN.match(args.identifier):
                    data = repository.load_draft(args.identifier)
                else:
                    for _, metadata, _ in repository.load_formal("case"):
                        if metadata.get("id") == args.identifier:
                            data = metadata
                            break
                if data is None:
                    raise KnowledgeError(f"找不到草稿或案例: {args.identifier}")
                print_result(repository.assess(data))
        elif args.command == "pattern":
            path, metadata = repository.propose_pattern(
                args.case_ids,
                args.title,
                args.applicability,
                args.exclusions,
                args.confirm_task_complete,
            )
            print_result({"path": repository.relative(path), "pattern": metadata})
        elif args.command == "validate":
            result = repository.validate()
            print_result(result)
            return 0 if result["ok"] else 1
        elif args.command == "audit":
            result = repository.audit()
            print_result(result)
            return 0 if result["ok"] else 1
        elif args.command == "eval":
            result = repository.evaluate(Path(args.file) if args.file else None)
            print_result(result)
            return 0 if result["ok"] else 1
        elif args.command == "metrics":
            print_result(repository.metrics())
        elif args.command == "hook":
            payload = parse_hook_payload()
            handlers = {
                "session-start": repository.hook_session_start,
                "user-prompt": repository.hook_user_prompt,
                "pre-tool-use": repository.hook_pre_tool_use,
                "stop": repository.hook_stop,
            }
            print(json.dumps(handlers[args.event](payload), ensure_ascii=False))
        return 0
    except (KnowledgeError, json.JSONDecodeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
