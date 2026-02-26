# Repository Guidelines

## 协作与决策原则
- 统一使用中文沟通，结论直接、可执行。
- 先理解再实现：先读现有代码与文档，再动手改动。
- 坚持第一性原理与建设性对抗：发现需求或实现有明显问题时，必须说明风险并给出替代方案。
- 本仓库是 Android → iOS 迁移项目，优先做“业务意图对齐”，禁止机械翻译实现。
- Android 参考工程路径：`/Users/wangke/Workspace/AndroidProjects/XMNote`
- 规范分层：本文件是贡献执行摘要；背景与完整约束以 `CLAUDE.md` 为补充来源。

## 项目结构与模块组织
- `XMNote.xcodeproj`：工程入口（scheme: `xmnote`）。
- `xmnote/Views`、`xmnote/Navigation`：SwiftUI 页面与路由。
- `xmnote/ViewModels`：`@Observable` 状态与业务编排。
- `xmnote/Database`、`xmnote/Database/Records`：GRDB schema、迁移、Record 映射。
- `xmnote/Services`、`xmnote/Networking`：网络、WebDAV、备份恢复。
- `xmnote/RichTextEditor`：富文本编辑模块。
- `xmnoteTests`：单元/集成测试（`Testing`）；`xmnoteUITests`：UI 自动化（`XCTest`）。
- `docs/feature/`：功能文档（需求+设计）。

## 构建、测试与开发命令
- `open XMNote.xcodeproj`：用 Xcode 打开工程。
- `xcodebuild -project XMNote.xcodeproj -scheme xmnote -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`：模拟器构建。
- `xcodebuild -project XMNote.xcodeproj -scheme xmnote clean`：清理构建产物。

## UI 与交互实现约束
- 遵循 iOS HIG，保持品牌与信息层级一致，避免无意义视觉修饰。
- 结构性 UI 变化必须带过渡动画，优先 `.snappy`、`.smooth`、`.spring`。
- 异步操作必须立即反馈（加载态/按钮禁用/错误提示），避免“点击无响应”。
- 迁移 Android 功能时，保证体验与业务一致，但采用 iOS 原生表达。

## 编码风格与命名规范
- Swift/SwiftUI，4 空格缩进；优先小函数与单一职责。
- 类型 `PascalCase`，属性/方法 `camelCase`，布尔值使用 `is/has/should` 前缀。
- 文件名与主类型名一致：`BookDetailView.swift` → `BookDetailView`。
- 约定后缀：View 用 `View`，ViewModel 用 `ViewModel`，数据实体用 `Record`。
- 大文件用 `// MARK:` 与 `extension` 分组。
- GRDB `Record` 必须通过 `CodingKeys` 做 camelCase → snake_case 映射，并与表结构保持一致。

## 测试与质量要求
- 任何行为变更必须同步补测试。
- 单元测试放在 `xmnoteTests/`，使用 `@Test` + `#expect(...)`。
- UI 测试放在 `xmnoteUITests/`，使用 `XCTestCase` 与 `test...` 命名。
- 优先覆盖 ViewModel 逻辑、数据库迁移、服务层异常路径。

## 提交与 PR 规范
- 建议提交格式：`<type>: <summary>`，如 `feat:`、`fix:`、`refactor:`、`docs:`、`test:`、`chore:`。
- 单次提交只做一个逻辑变更，避免混入无关改动。
- PR 必须包含：变更摘要、影响模块、测试证据（命令与结果）、UI 变更截图/录屏（如适用）、关联任务/Issue。

## 文档与安全规范
- 新功能文档统一放在 `docs/feature/功能名/`，至少包含《需求文档》《设计文档》。
- 代码实现与文档冲突时，先更新文档再改代码。
- 严禁提交真实账号、密码、Token、服务器地址；示例配置必须脱敏。
