@AGENTS.md

### AI Git 提交门禁兼容入口
- 唯一执行流程与 Commit Message 规范：`.agents/skills/xmnote-git-commit/SKILL.md`。
- 确定性门禁与测试：`.agents/skills/xmnote-git-commit/scripts/`；Codex AI Hook：`.codex/hooks.json`。

### AI Bug 经验闭环兼容入口
- 执行规范与状态定义：`AGENTS.md`、`docs/architecture/AI Bug经验闭环设计.md`、`docs/knowledge/bugs/问题库说明.md`。
- 仓库 Skill：`.agents/skills/xmnote-bug-knowledge/SKILL.md`；Codex 生命周期配置：`.codex/hooks.json`。
- 标准库工具与校验：`scripts/ai-knowledge/`、`scripts/verify_ai_bug_knowledge.sh`；Git 渐进门禁：`.githooks/`。
- 正式案例与模式：`docs/knowledge/bugs/`；本地索引、会话与草稿：已忽略的 `artifacts/ai-knowledge/`。

### 通用状态展示兼容入口
- 设计规范：`docs/architecture/通用状态展示设计规范.md`；组件接入：`docs/component-guides/XMStatePresentation使用说明.md`。
- 生产组件：`xmnote/UIComponents/Feedback/StatePresentation/`；静态闸门：`scripts/verify_state_presentations.sh`。
- 页面、Sheet 与列表背景使用 `XMContentStateView`，卡片/局部容器使用 `XMCompactStateView`，保留内容时的失败提示使用 `XMInlineStatusBanner`。
- 现有组件不能满足新 UI 时，优先配置参数或扩展既有 `Style`；只有两个独立生产场景证明相同语义与结构后，才允许新增公共状态组件，并同步测试目录与治理登记。

### iOS 设计系统兼容入口
- 唯一执行规范：`AGENTS.md` 的“设计系统工程入口”；架构说明：`docs/architecture/iOS设计系统工程规范.md`。
- 令牌真相源：`xmnote/Utilities/DesignSystem/`；公共组件真相源：`xmnote/UIComponents/`；机器目录：`scripts/design-system/component-catalog.json`。
- AI 上下文、组件查询与规则检查统一通过 `python3 scripts/design-system/ds.py context|catalog|lint|audit|explain`，禁止新增旁路脚本或扩大 baseline 掩盖违规。

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
