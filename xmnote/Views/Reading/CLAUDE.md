# Reading/
> L2 | 父级: Views/CLAUDE.md

在读追踪功能模块，View + ViewModel 共置。含 ReadCalendar/ 子功能目录。

## 成员清单

- `ReadingContainerView.swift`: 在读 Tab 容器入口
- `ReadingListPlaceholderView.swift`: 在读页内容容器（热力图小组件 + 列表占位）
- `ReadingHeatmapWidgetView.swift`: 在读页热力图小组件（帮助弹层、日期点击回调）
- `ReadingHeatmapWidgetViewModel.swift`: 热力图加载、跨天刷新与统计类型切换状态编排
- `HeatmapHelpSheetView.swift`: 热力图说明弹层（纯展示）
- `TimelinePlaceholderView.swift`: 时间线占位

## 子目录

- `ReadCalendar/`: 阅读日历子功能（3 个文件）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
