@AGENTS.md

### AI Bug 经验闭环兼容入口
- 执行规范与状态定义：`AGENTS.md`、`docs/architecture/AI Bug经验闭环设计.md`、`docs/knowledge/bugs/问题库说明.md`。
- 仓库 Skill：`.agents/skills/xmnote-bug-knowledge/SKILL.md`；Codex 生命周期配置：`.codex/hooks.json`。
- 标准库工具与校验：`scripts/ai-knowledge/`、`scripts/verify_ai_bug_knowledge.sh`；Git 渐进门禁：`.githooks/`。
- 正式案例与模式：`docs/knowledge/bugs/`；本地索引、会话与草稿：已忽略的 `artifacts/ai-knowledge/`。

### 自动同步模块清单（脚本生成）
<!-- AUTO_SYNC_MODULES_START -->
- 由 `scripts/sync_arch_docs.sh` 自动维护，请勿手工修改。
- `xmnote/AppState`
- `xmnote/Data`
- `xmnote/Database`
- `xmnote/Domain`
- `xmnote/Infra`
- `xmnote/Navigation`
- `xmnote/Resources`
- `xmnote/RichTextEditor`
- `xmnote/Services`
- `xmnote/UIComponents`
- `xmnote/Utilities`
- `xmnote/ViewModels`
- `xmnote/Views`
- `xmnote/zh-Hans.lproj`
<!-- AUTO_SYNC_MODULES_END -->
