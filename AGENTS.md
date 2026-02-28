# Repository Guidelines

## 协作与决策原则
- 统一使用中文沟通，结论直接、可执行。
- 先理解再实现：先读现有代码与文档，再动手改动。
- 坚持第一性原理与建设性对抗：发现需求或实现有明显问题时，必须说明风险并给出替代方案。
- 本仓库是 Android → iOS 迁移项目，优先做“业务意图对齐”，禁止机械翻译实现。
- Android 参考工程路径：`/Users/wangke/Workspace/AndroidProjects/XMNote`。
- 规范分层：本文件是执行摘要；完整背景与细则以 `CLAUDE.md` 为准。
- 学习输出约定：每完成一个功能开发，必须补充本次涉及的 iOS 知识点总结，并给出面向 Android Compose 开发者的学习示例（含对照思路与可运行代码片段）；学习文档统一存放在 `docs/learning/`。
- 组件文档机制：重要 UI 组件（`docs/architecture/UI核心组件白名单.md` 白名单组件 + `xmnote/UIComponents` 下新增/重大重构组件）开发完成后，必须新增或更新组件使用文档（`docs/component-guides/`），并登记到 `docs/architecture/UI组件文档清单.md`。
- iOS26 参考入口：涉及液态玻璃与 iOS26 新特性时，优先查阅 `docs/learning/iOS26液态玻璃与高相关新特性开发参考.md`，并据此执行“Android 业务意图对齐 + iOS 原生表达”。

## 执行优先级（与 CLAUDE.md 融合）
- 优先级顺序：用户当次明确要求 > `AGENTS.md` > `CLAUDE.md`。
- 默认执行策略：实现完成后先做编译校验；未被明确要求时，不单独执行 UI Test，不主动编写 UI 测试用例。
- 需要测试时：优先单元测试（ViewModel、迁移、服务异常路径）；UI 测试仅在需求明确且收益大于耗时时执行。
- 数据访问铁律：所有本地/网络数据获取必须经 Repository，`ViewModel` 禁止直接访问 `AppDatabase`、`WebDAVClient`、`NetworkClient`。

## 术语对照机制（强制）
- 术语总表：`docs/architecture/术语对照表.md`。
- UI 核心组件白名单：`docs/architecture/UI核心组件白名单.md`。
- 触发更新：
  - 新增/重命名核心类（如 `*Repository`、`*ViewModel`、`*Service`、`*Client`、`*Manager`、`*Container`、`*Payload`、`*Input`）必须更新术语表。
  - `xmnote/UIComponents` 下新增可复用 UI 组件必须更新术语表（类别：`UI-复用`）。
  - 白名单内新增/调整核心页面组件必须同步更新白名单与术语表（类别：`UI-核心页面`）。
- 提交前强制执行：
  - `bash scripts/verify_glossary.sh`
  - `bash scripts/verify_ui_glossary_scope.sh`
  - `bash scripts/verify_arch_docs_sync.sh`
  - `bash scripts/verify_component_guides.sh`

## UI组件归位规则（阻塞级）
- 可复用 UI 组件唯一归属目录：`xmnote/UIComponents`。
- `UIComponents` 只允许放置无业务状态、无数据访问、副作用可控的可复用 UI 组件。
- 禁止在 `xmnote/Utilities`、`xmnote/Views`、`xmnote/Services` 中新增可复用 UI 组件。
- `xmnote/RichTextEditor` 属于功能模块，不整体迁入 `UIComponents`；仅纯展示且跨页面复用的子组件允许抽取到 `UIComponents`。
- 违反本规则视为阻塞级问题：必须先完成组件归位整改，再继续开发与提交流程。

## 分形文档系统执行约束（GEB）
- The map IS the terrain. The terrain IS the map.
- 代码与文档必须同构：任何一相变化，另一相必须同步更新，否则视为未完成。
- 三层分形映射：
  - L1：`/CLAUDE.md`，负责项目宪法与全局地图（触发：顶级模块/架构变化）。
  - L2：`/{module}/CLAUDE.md`，负责模块地图与成员清单（触发：文件增删、重命名、接口变更）。
  - L3：文件头部注释，负责 INPUT/OUTPUT/POS 契约（触发：依赖、导出、职责变化）。
- 强制回环（代码→文档）：代码改动完成后必须依次检查 `L3 -> L2 -> L1`。
- 进入新目录前置检查：先读目标目录 `CLAUDE.md`，再读目标文件 L3 头部契约。
- 固定协议语句（L2/L3 必须保留原文）：`[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md`。
- 发现业务文件缺少 L3 头部注释时，必须先补齐后继续，属于阻塞级优先事项。
- 禁止孤立变更：改代码不检查文档、删文件不更新 L2、新模块不创建 L2 均视为严重违规。
- 双文档同构约束：`CLAUDE.md` 与 `AGENTS.md` 的项目结构、全局配置、工具链描述必须保持一致。变更任一文件的手工维护区域时，必须同步检查并更新另一文件对应内容，否则视为 SEVERE-005 违规。
- 本节为执行摘要；模板、禁令与完整回环流程以根目录 `CLAUDE.md` 的 GEB 完整版为准。

## 项目结构与模块组织
- `XMNote.xcodeproj`：工程入口（scheme: `xmnote`）。
- `xmnote/Localizable.xcstrings`：String Catalog，统一字符串管理（sourceLanguage: zh-Hans，含 en 占位）。
- `xmnote/Views`、`xmnote/Navigation`：SwiftUI 页面、ViewModel 与路由（View + ViewModel 按功能模块共置）。
- `xmnote/Domain`：Repository 协议与跨层模型。
- `xmnote/Data`：Repository 实现与依赖组装。
- `xmnote/Infra`：底层桥接与技术实现支持。
- `xmnote/Database`、`xmnote/Database/Records`：GRDB schema、迁移、Record 映射（仅 Repository 访问）。
- `xmnote/Services`、`xmnote/Networking`：网络、WebDAV、备份恢复（仅 Repository 访问）。
- `xmnote/RichTextEditor`：富文本编辑模块。
- `xmnote/UIComponents`：可复用 UI 组件唯一归属模块（按 Foundation/TopBar/Tabs 分层）。
- `xmnote/Utilities`：设计令牌与非 UI 工具（禁止新增可复用 UI 组件）。
- `scripts/`：架构术语与 UI 组件范围校验脚本。
- `docs/feature/`：功能文档（需求 + 设计）。
- `docs/component-guides/`：重要 UI 组件使用文档（参数说明 + 接入示例 + 常见问题）。

## 自动同步模块清单（脚本生成）
<!-- AUTO_SYNC_MODULES_START -->
- 由 `scripts/sync_arch_docs.sh` 自动维护，请勿手工修改。
- `xmnote/Data`
- `xmnote/Database`
- `xmnote/Domain`
- `xmnote/Infra`
- `xmnote/Navigation`
- `xmnote/RichTextEditor`
- `xmnote/Services`
- `xmnote/UIComponents`
- `xmnote/Utilities`
- `xmnote/Views`
<!-- AUTO_SYNC_MODULES_END -->
- 同步命令：`bash scripts/sync_arch_docs.sh`
- 校验命令：`bash scripts/verify_arch_docs_sync.sh`

## 构建与验证命令
- `open XMNote.xcodeproj`：用 Xcode 打开工程。
- `xcodebuild -project XMNote.xcodeproj -scheme xmnote -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`：默认交付验证命令。
- `xcodebuild -project XMNote.xcodeproj -scheme xmnote clean`：清理构建产物。

## UI 与交互约束
- 遵循 iOS HIG，保持品牌与信息层级一致，避免无意义视觉修饰。
- 结构性 UI 变化必须带过渡动画，优先 `.snappy`、`.smooth`、`.spring`。
- 异步操作必须立即反馈（加载态/按钮禁用/错误提示），避免“点击无响应”。
- 迁移 Android 功能时，保证体验与业务一致，但采用 iOS 原生表达。
- 视觉要求：简洁、克制、现代，避免 Android 视觉直译。

## 编码风格与命名规范
- Swift/SwiftUI，4 空格缩进；优先小函数与单一职责。
- 类型 `PascalCase`，属性/方法 `camelCase`，布尔值使用 `is/has/should` 前缀。
- 文件名与主类型名一致：`BookDetailView.swift` → `BookDetailView`。
- 约定后缀：View 用 `View`，ViewModel 用 `ViewModel`，数据实体用 `Record`。
- 大文件用 `// MARK:` 与 `extension` 分组。
- GRDB `Record` 必须通过 `CodingKeys` 做 camelCase → snake_case 映射，并与表结构保持一致。

## 提交与 PR 规范
- 提交信息必须使用中文，且统一格式：`fix(功能模块): 提交信息`。
- 单次提交只做一个逻辑变更，避免混入无关改动。
- PR 必须包含：变更摘要、影响模块、测试证据（命令与结果）、关联任务/Issue。

## 文档与安全规范
- 新功能文档统一放在 `docs/feature/功能名/`，至少包含《需求文档》《设计文档》。
- 重要 UI 组件使用文档统一放在 `docs/component-guides/`，并同步维护 `docs/architecture/UI组件文档清单.md`。
- 代码实现与文档冲突时，先更新文档再改代码。
- 严禁提交真实账号、密码、Token、服务器地址；示例配置必须脱敏。
