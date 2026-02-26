# Repository Guidelines

## 协作与决策原则
- 统一使用中文沟通，结论直接、可执行。
- 先理解再实现：先读现有代码与文档，再动手改动。
- 坚持第一性原理与建设性对抗：发现需求或实现有明显问题时，必须说明风险并给出替代方案。
- 本仓库是 Android → iOS 迁移项目，优先做“业务意图对齐”，禁止机械翻译实现。
- Android 参考工程路径：`/Users/wangke/Workspace/AndroidProjects/XMNote`。
- 规范分层：本文件是执行摘要；完整背景与细则以 `CLAUDE.md` 为准。

## 执行优先级（与 CLAUDE.md 融合）
- 优先级顺序：用户当次明确要求 > `AGENTS.md` > `CLAUDE.md`。
- 默认执行策略：实现完成后先做编译校验；未被明确要求时，不单独执行 UI Test，不主动编写 UI 测试用例。
- 需要测试时：优先单元测试（ViewModel、迁移、服务异常路径）；UI 测试仅在需求明确且收益大于耗时时执行。

## 项目结构与模块组织
- `XMNote.xcodeproj`：工程入口（scheme: `xmnote`）。
- `xmnote/Views`、`xmnote/Navigation`：SwiftUI 页面与路由。
- `xmnote/ViewModels`：`@Observable` 状态与业务编排。
- `xmnote/Database`、`xmnote/Database/Records`：GRDB schema、迁移、Record 映射。
- `xmnote/Services`、`xmnote/Networking`：网络、WebDAV、备份恢复。
- `xmnote/RichTextEditor`：富文本编辑模块。
- `docs/feature/`：功能文档（需求 + 设计）。

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
- 代码实现与文档冲突时，先更新文档再改代码。
- 严禁提交真实账号、密码、Token、服务器地址；示例配置必须脱敏。
