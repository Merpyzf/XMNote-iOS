# Views/
> L2 | 父级: /CLAUDE.md

SwiftUI 视图层，按功能模块分子目录。纯 UI 渲染，不包含业务逻辑。

## 顶层成员

- `MainTabView.swift`: 四 Tab 根视图（在读/书籍/笔记/我的）

## 子目录

- `Book/`: 书籍管理视图（6 个文件）
- `Note/`: 笔记管理视图（5 个文件）
- `Personal/`: 个人设置与备份视图（2 个文件 + Backup/ 子目录）
- `Reading/`: 在读追踪视图（3 个文件）
- `Statistics/`: 统计视图（占位）
- `Debug/`: 调试测试视图（#if DEBUG 编译隔离，2 个文件）

## Book/

- `BookContainerView.swift`: 书籍 Tab 容器与二级切换入口
- `BookGridView.swift`: 书籍网格展示与筛选
- `BookGridItemView.swift`: 单本书籍卡片渲染
- `BookDetailView.swift`: 书籍详情与书摘列表
- `BookPlaceholderView.swift`: 书籍空态占位
- `CollectionListPlaceholderView.swift`: 书单空态占位

## Note/

- `NoteContainerView.swift`: 笔记 Tab 容器与二级切换入口
- `NoteCollectionView.swift`: 笔记分类切换与内容分发
- `NoteTagsView.swift`: 标签分组网格展示
- `NoteDetailView.swift`: 笔记详情阅读与编辑
- `NoteReviewPlaceholderView.swift`: 书评空态占位

## Personal/

- `PersonalView.swift`: 我的 Tab 核心入口
- `PersonalPlaceholderView.swift`: 个人页占位
- `Backup/DataBackupView.swift`: 备份与恢复入口
- `Backup/WebDAVServerListView.swift`: 备份服务器列表管理
- `Backup/WebDAVServerFormView.swift`: 备份服务器新增编辑
- `Backup/BackupHistorySheet.swift`: 备份历史展示与恢复确认

## Reading/

- `ReadingContainerView.swift`: 在读 Tab 容器入口
- `ReadingListPlaceholderView.swift`: 在读列表占位
- `TimelinePlaceholderView.swift`: 时间线占位

## Debug/

- `RichTextTestView.swift`: 富文本编辑器测试页（#if DEBUG）
- `RichTextTestViewModel.swift`: 测试页状态编排（#if DEBUG）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
