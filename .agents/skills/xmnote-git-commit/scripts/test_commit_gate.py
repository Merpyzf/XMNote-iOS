#!/usr/bin/env python3
"""Temporary-repository tests for the XMNote AI Git commit gate."""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


SCRIPT_PATH = Path(__file__).with_name("commit_gate.py")
SPEC = importlib.util.spec_from_file_location("xmnote_commit_gate", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载 {SCRIPT_PATH}")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def run(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        list(args),
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        raise AssertionError(
            f"command failed: {' '.join(args)}\nstdout={completed.stdout}\nstderr={completed.stderr}"
        )
    return completed


class CommitGateTest(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="xmnote-commit-gate-")
        self.repo = Path(self.temporary.name).resolve()
        run(self.repo, "git", "init", "-q")
        run(self.repo, "git", "config", "user.name", "XMNote Gate Test")
        run(self.repo, "git", "config", "user.email", "gate@example.invalid")
        (self.repo / ".gitignore").write_text("/artifacts/\n", encoding="utf-8")
        (self.repo / "base.txt").write_text("base\n", encoding="utf-8")
        run(self.repo, "git", "add", ".gitignore", "base.txt")
        run(self.repo, "git", "commit", "-q", "-m", "docs(规范): 初始化门禁测试仓库")
        self.create_validation_fixtures()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def validations(self, extra: list[dict[str, str]] | None = None) -> list[dict[str, str]]:
        entries = [
            {"command": command, "status": "passed", "result": "测试证据"}
            for command in gate.ALWAYS_REQUIRED_VALIDATIONS
        ]
        entries.append(
            {
                "command": "App XCTest / UI Test",
                "status": "not_run",
                "reason": "仓库规则要求用户明确提出才运行",
            }
        )
        return entries + (extra or [])

    def create_validation_fixtures(self) -> None:
        for relative in (
            "scripts/verify_glossary.sh",
            "scripts/verify_l3_protocol_headers.sh",
            "scripts/verify_arch_docs_sync.sh",
            "scripts/verify_ai_bug_knowledge.sh",
        ):
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        for relative in ("scripts/ai-knowledge/kb.py", "scripts/design-system/ds.py"):
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("print('fixture passed')\n", encoding="utf-8")
        run(self.repo, "git", "add", "scripts")
        run(self.repo, "git", "commit", "-q", "-m", "test(规范): 增加验证命令桩")

    def stage(self, path: str = "feature.txt", content: str = "feature\n") -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        run(self.repo, "git", "add", path)

    def review(
        self,
        *,
        paths: list[str] | None = None,
        message: str = "feat(规范): 建立一次性提交门禁",
        scope: dict[str, Any] | None = None,
        operation: str = "commit",
        extra: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        value: dict[str, Any] = {
            "version": 1,
            "operation": operation,
            "summary": "根据实际暂存 diff 建立门禁",
            "included_paths": paths if paths is not None else ["feature.txt"],
            "modules": ["Git 提交门禁"],
            "boundary_confirmed": True,
            "mixed_files": [],
            "scope": scope
            or {
                "value": "规范",
                "source": "historical",
                "search_terms": ["规范", "提交"],
                "candidates": [],
            },
            "validation": self.validations(),
            "message": message,
        }
        if extra:
            value.update(extra)
        return value

    def prepare(
        self,
        review: dict[str, Any] | None = None,
        command: str = "git commit -F artifacts/git-commit-gate/message.txt",
    ) -> dict[str, Any]:
        review_path = self.repo / gate.GATE_RELATIVE_DIR / "review.json"
        review_path.parent.mkdir(parents=True, exist_ok=True)
        review_path.write_text(json.dumps(review or self.review(), ensure_ascii=False), encoding="utf-8")
        return gate.prepare(self.repo, review_path, command)

    def pre(self, command: str) -> dict[str, Any]:
        return gate.hook_pre_tool_use(
            self.repo,
            {"cwd": str(self.repo), "tool_input": {"command": command}},
        )

    def assert_denied(self, output: dict[str, Any], contains: str | None = None) -> None:
        specific = output.get("hookSpecificOutput", {})
        self.assertEqual(specific.get("permissionDecision"), "deny")
        if contains:
            self.assertIn(contains, specific.get("permissionDecisionReason", ""))

    def test_inspect_reports_staged_unrelated_untracked_and_scope_history(self) -> None:
        self.stage()
        (self.repo / "other.txt").write_text("other\n", encoding="utf-8")
        (self.repo / "trace.log").write_text("generated\n", encoding="utf-8")
        state = gate.inspect_state(self.repo)
        self.assertEqual(state["staged"], ["feature.txt"])
        self.assertEqual(state["other_changes"], ["other.txt", "trace.log"])
        self.assertIn("trace.log", state["risks"])
        self.assertIn("规范", state["historical_scopes"])

    def test_prepare_passes_for_clean_single_scope_commit_and_reports_other_changes(self) -> None:
        self.stage()
        (self.repo / "unrelated.txt").write_text("keep\n", encoding="utf-8")
        review = self.review(extra={"other_changes": ["unrelated.txt"]})
        result = self.prepare(review)
        self.assertEqual(result["result"], "PASS")
        self.assertEqual(result["included_paths"], ["feature.txt"])
        self.assertEqual(result["other_changes"], ["unrelated.txt"])
        self.assertEqual(result["scope"]["value"], "规范")
        self.assertTrue((self.repo / gate.GATE_RELATIVE_DIR / gate.ATTESTATION_NAME).exists())
        self.assertTrue((self.repo / gate.GATE_RELATIVE_DIR / gate.MESSAGE_NAME).exists())

    def test_historical_scope_must_exist_and_new_scope_needs_evidence(self) -> None:
        self.stage()
        bad_historical = self.review(
            message="feat(不存在): 建立门禁",
            scope={
                "value": "不存在",
                "source": "historical",
                "search_terms": ["不存在"],
                "candidates": [],
            },
        )
        with self.assertRaisesRegex(gate.GateError, "完整历史中不存在"):
            self.prepare(bad_historical)

        new_scope = {
            "value": "提交门禁",
            "source": "new",
            "search_terms": ["提交", "门禁"],
            "candidates": [{"name": "规范", "reason": "范围过宽，不能表达门禁 owner"}],
            "new_reason": "历史没有语义等价的提交门禁名称",
        }
        result = self.prepare(
            self.review(message="feat(提交门禁): 建立一次性历史写入凭据", scope=new_scope)
        )
        self.assertEqual(result["scope"]["source"], "new")

    def test_new_scope_without_candidate_reason_fails(self) -> None:
        self.stage()
        scope = {
            "value": "提交门禁",
            "source": "new",
            "search_terms": ["提交"],
            "candidates": [{"name": "规范", "reason": ""}],
            "new_reason": "没有等价名称",
        }
        with self.assertRaisesRegex(gate.GateError, "name 与 reason"):
            self.prepare(self.review(message="feat(提交门禁): 建立门禁", scope=scope))

    def test_mixed_file_and_staged_generated_file_fail(self) -> None:
        self.stage()
        mixed = self.review(extra={"mixed_files": ["feature.txt"]})
        with self.assertRaisesRegex(gate.GateError, "同文件混合修改"):
            self.prepare(mixed)

        run(self.repo, "git", "reset", "-q")
        self.stage("trace.log", "generated\n")
        with self.assertRaisesRegex(gate.GateError, "临时或生成文件"):
            self.prepare(self.review(paths=["trace.log"]))

    def test_multiple_files_require_structured_body(self) -> None:
        self.stage()
        self.stage("second.txt", "second\n")
        review = self.review(paths=["feature.txt", "second.txt"])
        with self.assertRaisesRegex(gate.GateError, "正文缺少"):
            self.prepare(review)

        review["message"] = (
            "feat(规范): 建立一次性提交门禁\n\n"
            "变更点\n- 增加凭据\n\n"
            "影响范围\n- AI Git 提交\n\n"
            "验证命令与结果\n- 门禁测试通过\n"
        )
        self.assertEqual(self.prepare(review)["result"], "PASS")

    def test_validation_matrix_requires_all_baseline_commands(self) -> None:
        self.stage()
        review = self.review()
        review["validation"] = review["validation"][1:]
        with self.assertRaisesRegex(gate.GateError, "缺少已通过的必需验证"):
            self.prepare(review)

    def test_commit_must_use_gate_generated_message_file(self) -> None:
        self.stage()
        with self.assertRaisesRegex(gate.GateError, "必须使用 -F"):
            self.prepare(command="git commit -m 'feat(规范): 绕过消息文件'")

    def test_skill_hook_and_gate_paths_require_specialized_validation(self) -> None:
        path = ".agents/skills/xmnote-git-commit/scripts/commit_gate.py"
        self.stage(path, "placeholder\n")
        message = (
            "feat(规范): 建立项目级提交门禁\n\n"
            "变更点\n- 增加门禁\n\n"
            "影响范围\n- AI 提交\n\n"
            "验证命令与结果\n- 测试通过\n"
        )
        review = self.review(paths=[path], message=message)
        with self.assertRaisesRegex(gate.GateError, "quick_validate"):
            self.prepare(review)
        review["validation"] += [
            {
                "command": "python3 /opt/skill-creator/quick_validate.py .agents/skills/xmnote-git-commit",
                "status": "passed",
                "result": "Skill 有效",
            },
            {
                "command": "python3 .agents/skills/xmnote-git-commit/scripts/test_commit_gate.py",
                "status": "passed",
                "result": "测试通过",
            },
        ]
        self.assertEqual(self.prepare(review)["result"], "PASS")

    def test_hook_json_path_requires_json_parse(self) -> None:
        path = ".codex/hooks.json"
        self.stage(path, "{}\n")
        message = (
            "feat(规范): 接入提交门禁 Hook\n\n"
            "变更点\n- 增加 Hook\n\n"
            "影响范围\n- AI 提交\n\n"
            "验证命令与结果\n- JSON 有效\n"
        )
        review = self.review(paths=[path], message=message)
        with self.assertRaisesRegex(gate.GateError, "Hook JSON"):
            self.prepare(review)
        review["validation"].append(
            {
                "command": "python3 -m json.tool .codex/hooks.json",
                "status": "passed",
                "result": "JSON 有效",
            }
        )
        self.assertEqual(self.prepare(review)["result"], "PASS")

    def test_valid_attestation_allows_exact_command_and_success_consumes_once(self) -> None:
        self.stage()
        command = "git commit -F artifacts/git-commit-gate/message.txt"
        self.prepare(command=command)
        self.assertEqual(self.pre(command), {})
        completed = run(self.repo, "git", "commit", "-F", "artifacts/git-commit-gate/message.txt")
        output = gate.hook_post_tool_use(
            self.repo,
            {
                "cwd": str(self.repo),
                "tool_input": {"command": command},
                "tool_response": {"exit_code": completed.returncode},
            },
        )
        self.assertEqual(output, {})
        self.assertFalse((self.repo / gate.GATE_RELATIVE_DIR / gate.ATTESTATION_NAME).exists())
        self.assertTrue((self.repo / gate.GATE_RELATIVE_DIR / gate.CONSUMED_NAME).exists())
        self.assert_denied(self.pre(command), "没有")

    def test_failed_command_without_history_change_keeps_attestation_for_retry(self) -> None:
        self.stage()
        command = "git commit -F artifacts/git-commit-gate/message.txt"
        self.prepare(command=command)
        gate.hook_post_tool_use(
            self.repo,
            {
                "cwd": str(self.repo),
                "tool_input": {"command": command},
                "tool_response": {"exit_code": 1},
            },
        )
        self.assertTrue((self.repo / gate.GATE_RELATIVE_DIR / gate.ATTESTATION_NAME).exists())
        self.assertEqual(self.pre(command), {})

    def test_history_change_consumes_attestation_even_when_tool_reports_failure(self) -> None:
        self.stage()
        command = "git commit -F artifacts/git-commit-gate/message.txt"
        self.prepare(command=command)
        run(self.repo, "git", "commit", "-F", "artifacts/git-commit-gate/message.txt")
        gate.hook_post_tool_use(
            self.repo,
            {
                "cwd": str(self.repo),
                "tool_input": {"command": command},
                "tool_response": {"exit_code": 1},
            },
        )
        self.assertFalse((self.repo / gate.GATE_RELATIVE_DIR / gate.ATTESTATION_NAME).exists())

    def test_head_index_workspace_message_command_and_target_changes_invalidate(self) -> None:
        mutations = (
            "head",
            "index",
            "workspace",
            "message",
            "command",
            "operation",
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.tearDown()
                self.setUp()
                self.stage()
                command = "git commit -F artifacts/git-commit-gate/message.txt"
                self.prepare(command=command)
                actual = command
                if mutation == "head":
                    run(self.repo, "git", "commit", "-q", "-m", "feat(规范): 旁路改变 HEAD")
                elif mutation == "index":
                    self.stage("index.txt", "changed\n")
                elif mutation == "workspace":
                    (self.repo / "working.txt").write_text("changed\n", encoding="utf-8")
                elif mutation == "message":
                    (self.repo / gate.GATE_RELATIVE_DIR / gate.MESSAGE_NAME).write_text(
                        "feat(规范): 篡改消息\n", encoding="utf-8"
                    )
                elif mutation == "command":
                    actual = "git commit --verbose -F artifacts/git-commit-gate/message.txt"
                else:
                    actual = "git merge main"
                self.assert_denied(self.pre(actual))

    def test_all_selected_history_operations_require_attestation(self) -> None:
        commands = (
            "git commit -m 'feat(规范): 提交'",
            "git commit --amend -m 'feat(规范): 重写'",
            "git merge topic",
            "git revert HEAD",
            "git revert --continue",
            "git cherry-pick HEAD",
            "git cherry-pick --continue",
            "git rebase main",
            "git rebase --continue",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assert_denied(self.pre(command), "没有")
        self.assertEqual(self.pre("git revert --no-commit HEAD"), {})
        self.assertEqual(self.pre("git cherry-pick -n HEAD"), {})

    def test_merge_fast_forward_can_receive_preserve_attestation(self) -> None:
        command = "git merge --ff-only topic"
        review = self.review(
            paths=[],
            message="",
            operation="merge",
            extra={
                "message_mode": "preserve",
                "history_audit_confirmed": True,
                "replay_commits": [],
            },
        )
        result = self.prepare(review, command)
        self.assertEqual(result["operation"], "merge")
        self.assertEqual(self.pre(command), {})

    def test_direct_revert_and_merge_commit_are_forced_through_normal_commit_gate(self) -> None:
        revert_review = self.review(
            paths=[],
            message="",
            operation="revert",
            extra={"message_mode": "preserve"},
        )
        with self.assertRaisesRegex(gate.GateError, "revert 必须先使用 --no-commit"):
            self.prepare(revert_review, "git revert HEAD")

        merge_review = self.review(
            paths=[],
            message="",
            operation="merge",
            extra={"message_mode": "preserve"},
        )
        with self.assertRaisesRegex(gate.GateError, "可能直接生成未受控消息"):
            self.prepare(merge_review, "git merge topic")

    def test_cherry_pick_and_rebase_bind_complete_replay_audit(self) -> None:
        self.stage("cherry.txt", "cherry\n")
        run(self.repo, "git", "commit", "-q", "-m", "feat(规范): 增加可重放门禁样例")
        head = run(self.repo, "git", "rev-parse", "HEAD").stdout.strip()
        parent = run(self.repo, "git", "rev-parse", "HEAD^").stdout.strip()
        cherry_review = self.review(
            paths=[],
            message="",
            operation="cherry-pick",
            extra={
                "message_mode": "preserve",
                "history_audit_confirmed": True,
                "replay_commits": [head],
            },
        )
        cherry = self.prepare(cherry_review, "git cherry-pick HEAD")
        self.assertEqual([item["commit"] for item in cherry["history_audit"]], [head])

        rebase_review = self.review(
            paths=[],
            message="",
            operation="rebase",
            extra={
                "message_mode": "preserve",
                "history_audit_confirmed": True,
                "replay_commits": [head],
            },
        )
        rebase = self.prepare(rebase_review, f"git rebase {parent}")
        self.assertEqual([item["commit"] for item in rebase["history_audit"]], [head])

    def test_hook_detects_dash_c_absolute_env_and_chained_forms(self) -> None:
        git_path = shutil.which("git") or "git"
        commands = (
            f"git -C {shlex_quote(self.repo)} commit -m 'feat(规范): 提交'",
            f"{git_path} commit -m 'feat(规范): 提交'",
            "env XMNOTE_GATE_TEST=1 git commit -m 'feat(规范): 提交'",
            "git status && git commit -m 'feat(规范): 提交'",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assert_denied(self.pre(command))
        self.assertEqual(self.pre("git -C . status --short"), {})
        self.assertEqual(self.pre("git log -1 --oneline && git diff --stat"), {})

    def test_bypass_and_low_level_history_commands_are_permanently_denied(self) -> None:
        commands = (
            "git commit --no-verify -m 'feat(规范): 绕过'",
            "git -c core.hooksPath=/dev/null commit -m 'feat(规范): 绕过'",
            "env GIT_CONFIG_KEY_0=core.hooksPath git commit -m 'feat(规范): 绕过'",
            "git config core.hooksPath /dev/null",
            "git commit-tree HEAD^{tree}",
            "git update-ref refs/heads/main HEAD",
            "git fast-import",
            "git pull --ff-only",
            "git stash push -m temporary",
            "git hash-object -w base.txt",
            "git symbolic-ref HEAD refs/heads/other",
            "git reset --hard HEAD^",
        )
        for command in commands:
            with self.subTest(command=command):
                self.assert_denied(self.pre(command), "永久拒绝")

    def test_attestation_file_and_validation_tampering_fail(self) -> None:
        self.stage()
        command = "git commit -F artifacts/git-commit-gate/message.txt"
        self.prepare(command=command)
        path = self.repo / gate.GATE_RELATIVE_DIR / gate.ATTESTATION_NAME
        value = json.loads(path.read_text(encoding="utf-8"))
        value["validation"][0]["result"] = "伪造"
        path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        self.assert_denied(self.pre(command), "验证证据已被篡改")


def shlex_quote(path: Path) -> str:
    value = str(path)
    return "'" + value.replace("'", "'\\''") + "'"


def run_dry_run() -> int:
    """Print an acceptance PASS, then prove tampering blocks the unexecuted commit."""

    with tempfile.TemporaryDirectory(prefix="xmnote-commit-gate-dry-run-") as temporary:
        repo = Path(temporary).resolve()
        run(repo, "git", "init", "-q")
        run(repo, "git", "config", "user.name", "XMNote Gate Dry Run")
        run(repo, "git", "config", "user.email", "dry-run@example.invalid")
        (repo / ".gitignore").write_text("/artifacts/\n", encoding="utf-8")
        (repo / "base.txt").write_text("base\n", encoding="utf-8")
        for relative in (
            "scripts/verify_glossary.sh",
            "scripts/verify_l3_protocol_headers.sh",
            "scripts/verify_arch_docs_sync.sh",
            "scripts/verify_ai_bug_knowledge.sh",
        ):
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        for relative in ("scripts/ai-knowledge/kb.py", "scripts/design-system/ds.py"):
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("print('fixture passed')\n", encoding="utf-8")
        run(repo, "git", "add", ".gitignore", "base.txt", "scripts")
        run(repo, "git", "commit", "-q", "-m", "docs(规范): 初始化 dry-run 仓库")

        (repo / "candidate.txt").write_text("candidate\n", encoding="utf-8")
        run(repo, "git", "add", "candidate.txt")
        review = {
            "version": 1,
            "operation": "commit",
            "summary": "为候选修改验证一次性提交凭据",
            "included_paths": ["candidate.txt"],
            "modules": ["Git 提交门禁 dry-run"],
            "boundary_confirmed": True,
            "mixed_files": [],
            "scope": {
                "value": "规范",
                "source": "historical",
                "search_terms": ["规范", "门禁"],
                "candidates": [],
            },
            "validation": [
                {"command": command, "status": "passed", "result": "待 prepare 实际重跑"}
                for command in gate.ALWAYS_REQUIRED_VALIDATIONS
            ]
            + [
                {
                    "command": "App XCTest / UI Test",
                    "status": "not_run",
                    "reason": "本次仅验证 Skill/Hook，且用户未要求 App 测试",
                }
            ],
            "message": "feat(规范): 验证一次性提交门禁",
        }
        review_path = repo / gate.GATE_RELATIVE_DIR / "review.json"
        review_path.parent.mkdir(parents=True, exist_ok=True)
        review_path.write_text(json.dumps(review, ensure_ascii=False), encoding="utf-8")
        command = "git commit -F artifacts/git-commit-gate/message.txt"
        result = gate.prepare(repo, review_path, command)
        gate.print_pass(result)
        allowed = gate.hook_pre_tool_use(
            repo,
            {"cwd": str(repo), "tool_input": {"command": command}},
        )
        if allowed:
            raise AssertionError(f"有效凭据未放行：{allowed}")
        message_path = repo / gate.GATE_RELATIVE_DIR / gate.MESSAGE_NAME
        message_path.write_text(message_path.read_text(encoding="utf-8") + "篡改\n", encoding="utf-8")
        denied = gate.hook_pre_tool_use(
            repo,
            {"cwd": str(repo), "tool_input": {"command": command}},
        )
        reason = denied.get("hookSpecificOutput", {}).get("permissionDecisionReason", "")
        if denied.get("hookSpecificOutput", {}).get("permissionDecision") != "deny":
            raise AssertionError("篡改凭据后未拒绝提交")
        print("DRY-RUN DENY")
        print(f"- 篡改后阻断：{reason}")
        print("- 候选提交：未执行，HEAD 保持不变")
    return 0


if __name__ == "__main__":
    if "--dry-run" in sys.argv:
        raise SystemExit(run_dry_run())
    unittest.main(verbosity=2)
