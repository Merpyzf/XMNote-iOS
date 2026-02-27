# Architecture Docs 使用说明

- 术语表：`docs/architecture/术语对照表.md`
- UI 核心组件白名单：`docs/architecture/UI核心组件白名单.md`
- UI 组件文档清单：`docs/architecture/UI组件文档清单.md`

提交前校验
- `bash scripts/verify_glossary.sh`
- `bash scripts/verify_ui_glossary_scope.sh`
- `bash scripts/verify_arch_docs_sync.sh`
- `bash scripts/verify_component_guides.sh`

自动同步
- `bash scripts/sync_arch_docs.sh`

触发规则
- 新增/重命名核心类：必须更新术语表。
- `xmnote/UIComponents` 新增可复用 UI 组件：必须更新术语表。
- 新增白名单内页面核心组件：必须更新术语表与白名单。
- 重要 UI 组件（白名单组件 + `xmnote/UIComponents` 下新增/重大重构组件）：必须维护组件使用文档与清单。
- `xmnote/` 顶层模块目录新增/删除：必须同步 `AGENTS.md` 与 `CLAUDE.md` 自动模块清单（可执行自动同步脚本）。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
