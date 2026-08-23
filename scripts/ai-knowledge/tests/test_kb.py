from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "kb.py"
REPOSITORY_ROOT = MODULE_PATH.parents[2]
SPEC = importlib.util.spec_from_file_location("xmnote_ai_knowledge", MODULE_PATH)
assert SPEC and SPEC.loader
kb = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = kb
SPEC.loader.exec_module(kb)


class KnowledgeFixture(unittest.TestCase):
    """在临时 Git 仓库中验证知识工具，不触碰 XMNote 业务工作树。"""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        tool_directory = self.root / "scripts/ai-knowledge"
        tool_directory.mkdir(parents=True)
        shutil.copyfile(MODULE_PATH, tool_directory / "kb.py")
        shutil.copyfile(MODULE_PATH.parent / "policy.json", tool_directory / "policy.json")
        (self.root / "AGENTS.md").write_text("# Fixture rules\n事实优先。\n", encoding="utf-8")
        (self.root / "xmnote/Views/Books").mkdir(parents=True)
        (self.root / "xmnote/Views/Notes").mkdir(parents=True)
        (self.root / "xmnote/Views/Books/BookView.swift").write_text("struct BookView {}\n", encoding="utf-8")
        (self.root / "xmnote/Views/Notes/NoteView.swift").write_text("struct NoteView {}\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.com")
        self.git("config", "user.name", "Fixture")
        self.git("add", "AGENTS.md", "xmnote")
        self.git("commit", "-qm", "chore: fixture")
        self.repository = kb.Repository(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def complete_draft(
        self,
        title: str,
        context: str,
        fix_tags: list[str] | None = None,
    ) -> dict:
        draft = self.repository.init_draft(
            title,
            paths=["xmnote/Views/Books/BookView.swift"],
            modules=["reading"],
            evidence_context=context,
        )
        values = {
            "symptom": "横向翻页后内容错位并崩溃",
            "reproduction": "打开混合内容，连续翻页三次稳定复现",
            "owner_paths": ["xmnote/Views/Books/BookView.swift"],
            "write_points": ["BookView.updateSelection"],
            "lifecycle": "分页动画完成前异步结果回写",
            "platform_evidence": ["最小 fixture 证明过期任务晚于页面代际返回"],
            "root_cause": "过期异步任务向新页面代际写入状态",
            "root_cause_tags": ["stale-task", "generation"],
            "trigger_tags": ["horizontal-paging", "async-result"],
            "anti_pattern": "异步结果未绑定页面代际",
            "fix_strategy": "引入页面代际令牌并丢弃过期结果",
            "fix_strategy_tags": fix_tags or ["generation-token", "drop-stale-result"],
            "impact": "混合内容横向分页",
            "non_impact": "静态单页阅读",
            "validation": ["fixture 连续执行 20 次无过期写入"],
            "regression_guards": ["scripts/fixture_generation_guard.py"],
        }
        assignments = [f"{key}={json.dumps(value, ensure_ascii=False)}" for key, value in values.items()]
        self.repository.update_draft(draft["id"], assignments)
        return self.repository.close_draft(draft["id"])

    def publish_case(self, title: str, context: str, fix_tags: list[str] | None = None) -> dict:
        draft = self.complete_draft(title, context, fix_tags)
        _, metadata = self.repository.publish_case(draft["id"], confirmed=True)
        return metadata


class KnowledgeModelTests(KnowledgeFixture):
    def test_front_matter_and_fingerprints_are_deterministic(self) -> None:
        metadata = {"id": "IOS-BUG-20260823-001", "type": "case", "title": "示例"}
        rendered = kb.render_front_matter(metadata, "# 示例\n")
        parsed, body = kb.parse_front_matter(rendered)
        self.assertEqual(metadata, parsed)
        self.assertIn("# 示例", body)

        first = {
            "modules": ["Reader", "Data"],
            "root_cause_tags": ["Race", "Owner"],
            "trigger_tags": ["Paging"],
            "anti_pattern": "Late write",
        }
        second = {
            "modules": ["data", "reader"],
            "root_cause_tags": ["owner", "race"],
            "trigger_tags": ["paging"],
            "anti_pattern": "late write",
        }
        self.assertEqual(kb.root_cause_fingerprint(first), kb.root_cause_fingerprint(second))

    def test_development_draft_only_writes_artifacts(self) -> None:
        draft = self.repository.init_draft("开发期草稿", paths=["xmnote/Views/Books/BookView.swift"])
        self.assertTrue(self.repository.draft_path(draft["id"]).exists())
        self.assertFalse((self.root / "docs/knowledge").exists())
        with self.assertRaisesRegex(kb.KnowledgeError, "收口前禁止发布"):
            self.repository.publish_case(draft["id"], confirmed=False)
        self.assertFalse((self.root / "docs/knowledge").exists())

    def test_draft_requires_minimum_fact_loop_before_close(self) -> None:
        draft = self.repository.init_draft("事实不足")
        with self.assertRaisesRegex(kb.KnowledgeError, "owner_paths"):
            self.repository.close_draft(draft["id"])
        closed = self.complete_draft("事实完整", "fixture-a")
        self.assertEqual("closed", closed["status"])
        self.assertTrue(closed["root_cause_fingerprint"])
        self.assertTrue(closed["fix_strategy_fingerprint"])

    def test_meta_bug_workflow_prompt_is_not_a_production_bug(self) -> None:
        meta = "PLEASE IMPLEMENT THIS PLAN: iOS AI Bug 经验闭环接入方案，请详细调研并制定方案"
        actual = "阅读页点击后崩溃，每次稳定复现；实际退出，预期继续阅读"
        self.assertFalse(self.repository.suspected_bug_prompt(meta))
        self.assertTrue(self.repository.suspected_bug_prompt(actual))


class BaselineAndHookTests(KnowledgeFixture):
    def test_existing_dirty_file_is_not_attributed_until_it_changes_again(self) -> None:
        path = self.root / "xmnote/Views/Books/BookView.swift"
        path.write_text("struct BookView { let userChange = true }\n", encoding="utf-8")
        baseline = self.repository.changed_state()
        self.assertEqual([], self.repository.task_attributable_changes(baseline))
        path.write_text("struct BookView { let taskChange = true }\n", encoding="utf-8")
        self.assertEqual(
            ["xmnote/Views/Books/BookView.swift"],
            self.repository.task_attributable_changes(baseline),
        )

    def test_first_bug_write_blocks_once_and_new_scope_blocks_again(self) -> None:
        session_id = "hook-bug"
        self.repository.hook_user_prompt(
            {
                "session_id": session_id,
                "prompt": "阅读页点击后崩溃，每次稳定复现；实际闪退",
            }
        )
        books_patch = {
            "session_id": session_id,
            "tool_name": "apply_patch",
            "tool_input": {"patch": "*** Update File: xmnote/Views/Books/BookView.swift\n"},
        }
        first = self.repository.hook_pre_tool_use(books_patch)
        self.assertEqual("deny", first["hookSpecificOutput"]["permissionDecision"])
        self.assertEqual({}, self.repository.hook_pre_tool_use(books_patch))
        notes_patch = {
            "session_id": session_id,
            "tool_name": "apply_patch",
            "tool_input": {"patch": "*** Update File: xmnote/Views/Notes/NoteView.swift\n"},
        }
        second_scope = self.repository.hook_pre_tool_use(notes_patch)
        self.assertEqual("deny", second_scope["hookSpecificOutput"]["permissionDecision"])
        self.assertEqual(2, len(self.repository.load_session(session_id)["draft_ids"]))

    def test_feature_task_is_never_blocked(self) -> None:
        session_id = "hook-feature"
        self.repository.hook_user_prompt(
            {"session_id": session_id, "prompt": "新增阅读统计筛选功能并接入现有页面"}
        )
        result = self.repository.hook_pre_tool_use(
            {
                "session_id": session_id,
                "tool_input": {"path": "xmnote/Views/Books/BookView.swift"},
            }
        )
        self.assertEqual({}, result)
        self.assertEqual([], self.repository.iter_drafts())

    def test_stop_checks_only_task_changes_and_does_not_loop(self) -> None:
        session_id = "hook-stop"
        self.repository.hook_user_prompt(
            {
                "session_id": session_id,
                "prompt": "阅读页点击后崩溃，每次稳定复现；实际闪退",
            }
        )
        self.repository.hook_pre_tool_use(
            {
                "session_id": session_id,
                "tool_input": {"path": "xmnote/Views/Books/BookView.swift"},
            }
        )
        target = self.root / "xmnote/Views/Books/BookView.swift"
        target.write_text("struct BookView { let fixed = true }\n", encoding="utf-8")
        blocked = self.repository.hook_stop({"session_id": session_id})
        self.assertEqual("block", blocked["decision"])
        self.assertIn("事实闭环", blocked["reason"])
        self.assertEqual({}, self.repository.hook_stop({"session_id": session_id, "stop_hook_active": True}))

        draft_id = self.repository.load_session(session_id)["draft_ids"][0]
        values = {
            "symptom": "点击后崩溃",
            "reproduction": "每次点击稳定复现",
            "evidence_context": "fixture-stop",
            "owner_paths": ["xmnote/Views/Books/BookView.swift"],
            "write_points": ["BookView.tap"],
            "lifecycle": "点击回调",
            "platform_evidence": ["fixture 堆栈"],
            "root_cause": "数组越界",
            "root_cause_tags": ["bounds"],
            "trigger_tags": ["tap"],
            "anti_pattern": "未检查索引",
            "fix_strategy": "写入前校验索引",
            "fix_strategy_tags": ["bounds-check"],
            "impact": "阅读页",
            "non_impact": "书架页",
            "validation": ["fixture 通过"],
            "regression_exception": "当前用户只批准知识工具测试，不新增 App 测试",
        }
        assignments = [f"{key}={json.dumps(value, ensure_ascii=False)}" for key, value in values.items()]
        self.repository.update_draft(draft_id, assignments)
        self.repository.close_draft(draft_id)
        self.assertEqual({}, self.repository.hook_stop({"session_id": session_id}))

        self.repository.hook_user_prompt({"session_id": session_id, "prompt": "任务已完成"})
        closure_session = self.repository.load_session(session_id)
        self.assertEqual([draft_id], closure_session["draft_ids"])
        closure_block = self.repository.hook_stop({"session_id": session_id})
        self.assertEqual("block", closure_block["decision"])
        self.assertIn("尚未发布正式案例", closure_block["reason"])

    def test_commit_message_hook_warns_missing_case_and_rejects_bad_reference(self) -> None:
        hooks = self.root / ".githooks"
        hooks.mkdir()
        shutil.copyfile(REPOSITORY_ROOT / ".githooks/commit-msg", hooks / "commit-msg")
        (hooks / "commit-msg").chmod(0o755)
        message = self.root / "COMMIT_EDITMSG"
        message.write_text("fix(阅读): 修复分页崩溃\n", encoding="utf-8")
        warning = subprocess.run(
            [str(hooks / "commit-msg"), str(message)],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(0, warning.returncode, warning.stderr)
        self.assertIn("不阻止提交", warning.stderr)

        message.write_text(
            "fix(阅读): 修复分页崩溃\n\nKnowledge-Case: IOS-BUG-20260823-999\n",
            encoding="utf-8",
        )
        rejected = subprocess.run(
            [str(hooks / "commit-msg"), str(message)],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertIn("不存在或无效", rejected.stderr)


class RetrievalAndPromotionTests(KnowledgeFixture):
    def test_unmatched_pattern_cannot_enter_results_from_type_bonus(self) -> None:
        pattern_directory = self.root / "docs/knowledge/bugs/patterns"
        pattern_directory.mkdir(parents=True)
        metadata = {
            "schema_version": 1,
            "id": "IOS-PATTERN-001",
            "type": "pattern",
            "title": "数据库事务边界",
            "status": "enforced",
            "modules": ["database"],
            "paths": ["xmnote/Database"],
        }
        (pattern_directory / "IOS-PATTERN-001.md").write_text(
            kb.render_front_matter(metadata, "# 数据库事务边界\n\n处理迁移和外键。"),
            encoding="utf-8",
        )
        result = self.repository.search("动画回弹", limit=5)
        self.assertEqual([], result["matches"])

    def test_pattern_requires_two_independent_cases_and_same_fix(self) -> None:
        first = self.publish_case("分页异步写入 A", "feature-a")
        with self.assertRaisesRegex(kb.KnowledgeError, "至少需要 2"):
            self.repository.propose_pattern(
                [first["id"]], "分页代际保护", "异步横向分页", "同步静态页面", confirmed=True
            )
        different = self.publish_case("分页异步写入 B", "feature-b", ["cancel-only"])
        with self.assertRaisesRegex(kb.KnowledgeError, "修复策略指纹不一致"):
            self.repository.propose_pattern(
                [first["id"], different["id"]],
                "分页代际保护",
                "异步横向分页",
                "同步静态页面",
                confirmed=True,
            )
        third = self.publish_case("分页异步写入 C", "feature-c")
        _, pattern = self.repository.propose_pattern(
            [first["id"], third["id"]],
            "分页代际保护",
            "异步横向分页且结果可能跨代际返回",
            "同步静态页面和无状态任务",
            confirmed=True,
        )
        self.assertEqual("candidate", pattern["status"])
        self.assertEqual(2, len(pattern["case_ids"]))
        self.assertTrue(self.repository.validate()["ok"])

    def test_fixed_evaluation_reports_recall_mrr_and_negative_rate(self) -> None:
        case = self.publish_case("横向分页异步生命周期崩溃", "eval-feature")
        evaluation = self.root / "evaluation.json"
        evaluation.write_text(
            json.dumps(
                {
                    "queries": [
                        {"query": "横向分页 异步 崩溃", "expected_ids": [case["id"]]},
                        {"query": "页面代际 过期任务", "expected_ids": [case["id"]]},
                        {
                            "query": "事实优先",
                            "negative": True,
                            "forbidden_ids": [case["id"]],
                        },
                    ]
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        result = self.repository.evaluate(evaluation)
        self.assertTrue(result["ok"], result)
        self.assertGreaterEqual(result["recall_at_5"], 0.8)
        self.assertGreater(result["mrr"], 0)
        self.assertEqual(0, result["negative_false_positive_rate"])

    def test_enforced_requires_existing_mandatory_programmatic_guard(self) -> None:
        fake = [{"type": "static-check", "mandatory": True, "path": "scripts/missing.sh"}]
        self.assertFalse(self.repository.valid_enforcement(fake))
        guard = self.root / "scripts/guard.sh"
        guard.write_text("#!/bin/sh\n", encoding="utf-8")
        real = [{"type": "static-check", "mandatory": True, "path": "scripts/guard.sh"}]
        self.assertTrue(self.repository.valid_enforcement(real))

    def test_local_state_is_isolated_by_worktree_root(self) -> None:
        other_root = self.root / "parallel-worktree"
        (other_root / "scripts/ai-knowledge").mkdir(parents=True)
        shutil.copyfile(MODULE_PATH.parent / "policy.json", other_root / "scripts/ai-knowledge/policy.json")
        other_repository = kb.Repository(other_root)
        first = self.repository.init_draft("主 worktree")
        second = other_repository.init_draft("并行 worktree")
        self.assertNotEqual(self.repository.local_root, other_repository.local_root)
        self.assertTrue(self.repository.draft_path(first["id"]).exists())
        self.assertTrue(other_repository.draft_path(second["id"]).exists())
        self.assertEqual(1, len(self.repository.iter_drafts()))
        self.assertEqual(1, len(other_repository.iter_drafts()))


if __name__ == "__main__":
    unittest.main()
