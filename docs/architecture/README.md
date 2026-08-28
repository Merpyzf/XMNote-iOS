# Architecture Docs 使用说明

- 术语表：`docs/architecture/术语对照表.md`
- UI 核心组件白名单：`docs/architecture/UI核心组件白名单.md`
- UI 组件文档清单：`docs/architecture/UI组件文档清单.md`
- 颜色系统优化规范：`docs/architecture/颜色系统优化规范.md`
- iOS 设计系统工程规范：`docs/architecture/iOS设计系统工程规范.md`
- 页面状态基建与开发模式：`docs/architecture/页面状态基建与开发模式.md`
- 加载状态反馈基建设计：`docs/architecture/加载状态反馈基建设计.md`
- 通用状态展示设计规范：`docs/architecture/通用状态展示设计规范.md`
- 消息提示设计规范：`docs/architecture/消息提示设计规范.md`
- AI Bug 经验闭环设计：`docs/architecture/AI Bug经验闭环设计.md`
- X5 外置存储开发工作流：`docs/architecture/X5外置存储开发工作流.md`
- Bug 问题库入口：`docs/knowledge/bugs/问题库说明.md`

自动同步
- `bash scripts/sync_arch_docs.sh`

触发规则
- 新增/重命名核心类：必须更新术语表。
- `xmnote/UIComponents` 新增可复用 UI 组件：必须更新术语表。
- 新增白名单内页面核心组件：必须更新术语表与白名单。
- 重要 UI 组件（白名单组件 + `xmnote/UIComponents` 下新增/重大重构组件）：必须维护组件使用文档与清单。
- `xmnote/` 顶层模块目录新增/删除：必须同步 `AGENTS.md` 与 `CLAUDE.md` 自动模块清单（可执行自动同步脚本）。
- 证据化生产缺陷在用户确认任务完成后：发布正式案例，并执行知识校验、审计、固定检索评测与工具测试。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
