# Personal/
> L2 | 父级: Views/CLAUDE.md

个人设置功能模块。含 Backup/ 子目录。

## 成员清单

- `PersonalView.swift`: 我的 Tab 核心入口
- `ApiIntegrationView.swift`: API 集成设置页面
- `TagManagementView.swift`: 标签管理页面
- `BookGroupManagementView.swift`: 书籍分组新增、搜索、重命名、排序与删除页面
- `SourceManagementView.swift`: 用户/默认书籍来源的搜索、增改删与排序页面
- `Components/BookGroupManagementRowView.swift`: 分组管理页面私有行与组合封面接入
- `Components/SourceManagementListView.swift`: 来源管理页面私有列表与拖拽排序承载
- `Sheets/BookGroupNameEditSheet.swift`: 分组新增与重命名业务 Sheet
- `Components/TagManagementCollectionView.swift`: 标签管理页面私有集合视图

## 子目录

- `Backup/`: 数据备份与恢复（6 个文件）

分组、来源、标签、备份和桌面网页功能的通用空态、无搜索结果与局部失败视觉统一复用 `StatePresentation` 组件族；UICollectionView 背景适配器只保留容器职责。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
