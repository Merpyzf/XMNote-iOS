# ViewModels/
> L2 | 父级: /CLAUDE.md

@Observable 视图模型层，持有 UI 状态与业务逻辑编排。通过构造器注入 Repository 协议。

## 成员清单

- `BookViewModel.swift`: 书籍页状态与过滤编排，含 ReadStatusFilter 枚举
- `BookDetailViewModel.swift`: 书籍详情与书摘观察编排
- `NoteViewModel.swift`: 笔记标签页状态编排
- `NoteDetailViewModel.swift`: 笔记详情加载保存编排，含 Metadata 内嵌结构
- `DataBackupViewModel.swift`: 备份恢复状态编排，含 BackupOperationState 枚举
- `WebDAVServerViewModel.swift`: 服务器配置管理状态编排
- `ReadingHeatmapWidgetViewModel.swift`: 在读页热力图小组件状态编排（加载、跨天刷新、统计类型切换）
- `ReadCalendarViewModel.swift`: 阅读日历页面状态编排（月切换、选中态、周布局聚合）
- `ReadCalendarEventLayoutEngine.swift`: 阅读日历事件条布局算法（自然日连续 Run + 周分段 + lane 分配）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
