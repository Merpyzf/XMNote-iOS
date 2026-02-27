# scripts/
> L2 | 父级: /CLAUDE.md

成员清单
- `verify_glossary.sh`: 校验核心类型（Repository/ViewModel/Service 等）是否已登记到 `docs/architecture/术语对照表.md`。
- `verify_ui_glossary_scope.sh`: 校验 `xmnote/UIComponents` 可复用 UI 与白名单核心页面组件是否完整登记且类别正确。
- `sync_arch_docs.sh`: 根据 `xmnote/` 顶层目录自动同步 `AGENTS.md` 与 `CLAUDE.md` 的模块清单块。
- `verify_arch_docs_sync.sh`: 校验 `AGENTS.md` 与 `CLAUDE.md` 模块清单块是否与实际目录一致。

执行约束
- 提交前执行：`bash scripts/verify_glossary.sh && bash scripts/verify_ui_glossary_scope.sh && bash scripts/verify_arch_docs_sync.sh`。
- 变更 `scripts/` 中的规则、扫描范围、输出格式时，必须同步更新本文件与根 `CLAUDE.md`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
