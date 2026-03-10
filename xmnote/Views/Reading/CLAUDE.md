# Reading/
> L2 | 父级: Views/CLAUDE.md

在读追踪视图模块，承载页面壳层、时间线子功能、阅读日历子功能与业务弹层。对应 ViewModel 位于 `xmnote/ViewModels/Reading/`。

## 成员清单

- `ReadingContainerView.swift`: 在读 Tab 容器入口（在读 / 时间线 / 统计切换）
- `ReadingListPlaceholderView.swift`: 在读页内容容器（热力图小组件 + 列表占位）
- `ReadingHeatmapWidgetView.swift`: 在读页热力图小组件（帮助弹层、日期点击回调）
- `Timeline/ReadingTimelineView.swift`: 时间线正式页面壳层（日历、筛选、按日时间线列表）
- `Sheets/HeatmapHelpSheetView.swift`: 热力图说明弹层（纯展示）

## 子目录

- `ReadCalendar/`: 阅读日历子功能（含 Components/ 与 Sheets/）
- `Timeline/`: 时间线子功能（正式页面与页面私有卡片组件）
- `Sheets/`: 在读模块业务弹层目录

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
