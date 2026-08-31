# Personal/
> L2 | 父级: Views/CLAUDE.md

个人设置功能模块。含 Backup/ 子目录。

## 成员清单

- `PersonalView.swift`: 我的 Tab 核心入口
- `AIConfigurationView.swift`: AI 服务商、模型、访问凭证与提示词配置页，使用公共 Settings 语法组合业务行。
- `AIPromptEditorView.swift`: 三类 AI 任务的独立提示词编辑页，承载双字段切换、令牌编辑、校验、退出保护和保存。
- `ApiIntegrationView.swift`: API 集成设置页面
- `DesktopWeb/DesktopWebView.swift`: 网页端启停、自动启动与访问授权配置页面。
- `TagManagementView.swift`: 标签管理页面
- `BookGroupManagementView.swift`: 书籍分组新增、搜索、重命名、排序与删除页面
- `SourceManagementView.swift`: 用户/默认书籍来源的搜索、增改删与排序页面
- `Components/BookGroupManagementRowView.swift`: 分组管理页面私有行与组合封面接入
- `Components/SourceManagementListView.swift`: 来源管理页面私有列表与拖拽排序承载
- `Components/AIPromptEditorAppearance.swift`: 提示词变量令牌的 feature-private 图标、语义配色、排版与局部尺寸 owner
- `Components/AIPromptTokenTextEditor.swift`: SwiftUI 与 TextKit 的提示词令牌编辑桥接，负责原子变量、选区和撤销/重做
- `Sheets/BookGroupNameEditSheet.swift`: 分组新增与重命名业务 Sheet
- `Sheets/AIPromptEditorSheets.swift`: 提示词实际请求预览、试运行和字段优化业务 Sheet
- `Sheets/AIPromptExplanationSheet.swift`: 用户提示词、系统提示词与变量边界说明 Sheet
- `Components/TagManagementCollectionView.swift`: 标签管理页面私有集合视图

## 子目录

- `Backup/`: 数据备份与恢复。
- `DataImport/`: 微信读书扫码授权、分批导入、内容预览与批次业务状态。
- `DesktopWeb/`: 网页端服务配置。

分组、来源、标签、备份和桌面网页功能的通用空态、无搜索结果与局部失败视觉统一复用 `StatePresentation` 组件族；UICollectionView 背景适配器只保留容器职责。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
