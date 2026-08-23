# AI Bug 经验闭环架构设计

## 1. 设计目标

这套基建把“历史 Bug 文档”变成修复前可检索、修复中可追溯、收口后可治理的本地工程闭环，同时遵守 iOS 仓库的事实优先、文档冻结、抽象准入和 Parallel iOS worktree 隔离规则。

目标不是自动生成更多文档，而是提高三件事的确定性：

- 新缺陷先复用真实历史证据。
- 当前脏工作树不会被误认为本任务修改。
- 单点修复不会在证据不足时被提升成公共架构或强制规则。

## 2. Android 方案的适配结论

保留：

- Markdown/JSON Front Matter 为权威数据，SQLite 仅作可重建索引。
- Skill、Codex Hook、Git Hook 分层，不把案例正文塞入全局提示词。
- 修复前检索、修复后记录、多个独立案例再晋升模式。
- Python 标准库实现，不依赖在线向量库或 App 运行时。

iOS 修正：

- 正式案例改为“开发期本地草稿 + 用户确认后发布”的双阶段模型。
- 排序必须先真实命中，再增加模式/规则权重。
- `active` 必须有用户批准；`enforced` 必须有真实必执行保护。
- Git `fix` trailer 先 warning 试运行，不假设流程已经被稳定采用。
- Xcode Build Phase 不承载知识治理，普通 App 编译不依赖问题库。

## 3. 组件与数据流

```text
.agents/skills/xmnote-bug-knowledge/SKILL.md
                 │ 诊断顺序与准入边界
                 ▼
.codex/hooks.json ───→ scripts/ai-knowledge/kb.py ←─── .githooks/
      │                        │                         │
      │                        ├─ search/validate/audit │
      │                        ├─ draft/case/pattern    │
      │                        └─ eval/metrics/hook     │
      ▼                        │                         ▼
artifacts/ai-knowledge/        │             commit warning / format gate
 sessions/drafts/index/metrics │
                               ▼
                    docs/knowledge/bugs/
                    cases/patterns/archive
```

权威 owner：

- 知识格式、路径范围、状态：`scripts/ai-knowledge/policy.json`。
- CLI 与 Hook 行为：`scripts/ai-knowledge/kb.py`。
- 正式事实：`docs/knowledge/bugs/`。
- 开发期状态：当前 worktree 的 `artifacts/ai-knowledge/`。
- 协作顺序：仓库 Skill 与 `AGENTS.md`。

## 4. 两阶段写入模型

### 开发阶段

`UserPromptSubmit` 保存任务开始时全部脏文件及内容哈希。Hook 只把此后新增或继续变化的保护路径归因给本任务。首次生产写入按 scope 检索并拒绝一次，同时创建本地草稿。

草稿关闭需要：现象、复现、证据上下文、owner、写入点、生命周期、平台事实、根因、触发、反模式、修复策略、影响/不影响、验证，以及回归保护或无法自动化原因。

### 收口阶段

只有用户明确说“任务已完成”后才能发布正式案例。收口消息保留原任务基线和草稿关联，不会重置成新会话。发布后执行 validate、audit、eval、工具测试和仓库全部文档闸门。

## 5. 路径保护与 scope

保护：`xmnote/**`、工程配置、`Package.resolved`、Parallel iOS Makefile 和生产脚本。

排除：测试、文档、Vendor、Debug 实验页、知识工具自身、`.agents/.codex/.githooks`、`artifacts/**` 和 OpenSpec。

scope：

- `Views/ViewModels` 按 `<层>/<Feature>`。
- 其他 `xmnote` 路径按顶层模块。
- 工程配置和生产脚本分别形成独立 scope。

同 scope 原样重试放行；新 scope 再检索一次。

## 6. 正式知识模型

案例根因指纹由模块、根因标签、触发标签和反模式生成；修复策略另有独立指纹。这样可以区分“表象相似但机制不同”和“同机制但修法不同”。

模式晋升必须同时满足：

1. 至少两个独立证据上下文。
2. 根因指纹一致。
3. 修复策略指纹一致。
4. 适用和不适用边界明确。
5. 用户批准后才可 active。
6. 必执行测试、静态检查、构建 gate 或 Git Hook 路径真实存在后才可 enforced。

## 7. 检索与索引

索引包含正式案例/模式、根 `AGENTS.md`、仓库 Skill、架构文档、学习资料、踩坑记录和功能复盘；不索引 Vendor、生成物、完整 `.codex/skills` 副本或 App 用户数据。

排序分两步：

1. 文本、元数据、关键词或路径真实命中，否则淘汰。
2. 对命中项增加 `enforced/active pattern → rule → case → learning → draft` 的状态/类型权重。

交互查询再补充全文文件和 Git 提交证据；评测不重复扫描 Git，以保证可重复性和速度。

## 8. Hook 与安全边界

Codex 官方支持仓库级 Skills、`AGENTS.md` 和项目 Hooks：

- [Skills](https://learn.chatgpt.com/docs/build-skills)
- [Hooks](https://learn.chatgpt.com/docs/hooks)
- [AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)

项目 Hook 必须由用户审查信任。Hook 是工作流护栏，不是完整安全隔离：命令仍需保持最小权限，索引与状态只写被忽略的 worktree 本地目录，不接入网络、CI 或 App 数据库。

## 9. Git 渐进门禁

当前 worktree 配置 `core.hooksPath=.githooks`：

- `pre-commit`：正式知识格式错误时失败关闭。
- `commit-msg`：`fix` 缺 `Knowledge-Case` 只告警；提供 trailer 但 ID 非法、案例不存在或案例无效时失败关闭。

30 天后评估采用率、无命中率、人工确认的误拦截率和回归保护覆盖率。严格门禁不是自动升级项。

## 10. 失败模式与回滚

- 索引损坏：删除 `artifacts/ai-knowledge/index.sqlite` 后下次 search 自动重建；正式知识不受影响。
- Hook 误判：普通功能任务不创建草稿；真实 Bug 的首次拒绝只发生一次。必要时用户可在 Codex 中取消项目 Hook 信任。
- Git Hook 影响工作流：`git config --local --unset core.hooksPath` 可关闭当前 worktree 配置；不会修改全局 Git。
- 过期路径/虚假状态：`audit` 报告，不自动删除历史。
- 检索评测下降：先区分知识缺失、标签不足和排序错误，不直接引入 Embedding。

## 11. 验收基线

- 8 个经过事实闭环核验的历史案例。
- 24 条固定查询；Recall@5 100%、MRR 0.9688、负例误召回率 0%。
- 工具测试覆盖 Front Matter、双阶段写入、元任务分类、脏基线、首次拒绝/重试、scope、排序、模式准入、Stop 和 worktree 隔离。
- 不新增 Xcode Build Phase，不修改 App 运行时和业务数据库。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
