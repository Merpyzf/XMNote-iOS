# scripts/
> L2 | 父级: /CLAUDE.md

成员清单
- `verify_glossary.sh`: 校验核心类型（Repository/ViewModel/Service 等）是否已登记到 `docs/architecture/术语对照表.md`。
- `verify_ui_glossary_scope.sh`: 校验 `xmnote/UIComponents` 可复用 UI 与白名单核心页面组件是否完整登记且类别正确。
- `verify_view_component_boundaries.sh`: 校验页面壳层、页面私有子视图、业务 Sheet、ViewModel 与跨模块复用组件的目录边界。
- `verify_component_guides.sh`: 校验重要 UI 组件使用文档清单、白名单覆盖、路径与文档必备章节是否完整。
- `verify_state_presentations.sh`: 校验生产路径的 ContentUnavailableView 唯一入口、旧状态组件回流和未审查状态型 View，并强制公共状态视觉具备测试目录样例、术语/组件登记、组件指南消费证据与至少两个生产消费者；容器/领域例外必须带原因白名单。
- `verify_l3_protocol_headers.sh`: 校验 `xmnote/**/*.swift` 是否具备 L3 头部协议语句。
- `sync_arch_docs.sh`: 根据 `xmnote/` 顶层目录自动同步 `AGENTS.md` 与 `CLAUDE.md` 的模块清单块。
- `verify_arch_docs_sync.sh`: 校验 `AGENTS.md` 与 `CLAUDE.md` 模块清单块是否与实际目录一致。
- `lint_warnings.sh`: 使用当前已启动的 iOS 模拟器执行 `xcodebuild clean build`，并过滤仓库源码 warning/error。
- `parallel-ios/`: 管理非主任务 worktree 的专属 Simulator、DerivedData、测试结果与 Swift Package 隔离状态。
- `ai-knowledge/`: 仅依赖 Python 标准库的 Bug 知识 CLI、策略、固定检索评测与工具测试；正式知识以 `docs/knowledge/bugs/` 为权威源，本地索引与草稿位于已忽略的 `artifacts/ai-knowledge/`。
- `design-system/`: 设计系统唯一机器可读治理入口；`ds.py` 提供上下文发现、组件查询、变更/全量 lint、规则解释与审计，`policy.json` 定义 DS001–DS011 与观察项，`component-catalog.json` schema v3 定义公共组件分类、状态、框架边界和 Preview 策略，`tests/` 固化编排与发现路径，`ui-lint/` 使用 SwiftSyntax 实现 AST 规则。
- `verify_ai_bug_knowledge.sh`: 依次执行知识格式校验、审计、固定检索评测与工具测试，不触发 App XCTest/UI Test。

执行约束
- 修改生产 UI 前执行：`python3 scripts/design-system/ds.py context --paths <相关 Swift 路径>`；开发中执行 `python3 scripts/design-system/ds.py lint --changed`。
- 变更设计规则、组件目录或上下文路由后执行：`make -f Makefile.parallel-ios ai-ui-lint-test`。
- 提交前执行：`python3 scripts/design-system/ds.py audit && bash scripts/verify_glossary.sh && bash scripts/verify_ui_glossary_scope.sh && bash scripts/verify_view_component_boundaries.sh && bash scripts/verify_l3_protocol_headers.sh && bash scripts/verify_arch_docs_sync.sh && bash scripts/verify_component_guides.sh && bash scripts/verify_state_presentations.sh && bash scripts/verify_scroll_ux.sh && bash scripts/verify_ai_bug_knowledge.sh`。
- 变更 `scripts/` 中的规则、扫描范围、输出格式时，必须同步更新本文件与根 `CLAUDE.md`。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
