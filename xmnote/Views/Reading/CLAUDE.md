# Reading/
> L2 | 父级: Views/CLAUDE.md

在读追踪视图模块，承载首页、热力图、时间线、阅读日历与相关业务弹层。对应 ViewModel 位于 `xmnote/ViewModels/Reading/`。

## 成员清单

- `ReadingContainerView.swift`: 在读 Tab 容器入口（在读首页 / 时间线 / 统计切换、时间线状态托管与 warmup 调度）
- `ReadingDashboardView.swift`: 在读首页真实内容壳层（热力图、趋势、目标、继续阅读、最近在读、年度摘要）
- `ReadingHeatmapWidgetView.swift`: 在读首页顶部热力图小组件（帮助弹层、日期点击回调）
- `TimelinePlaceholderView.swift`: 统计占位页旧入口（保留兼容位）
- `Timeline/ReadingTimelineView.swift`: 时间线正式页面壳层（日历、筛选、首开静态壳层与按日时间线列表）
- `Sheets/HeatmapHelpSheetView.swift`: 热力图说明弹层（纯展示）
- `Sheets/ReadingGoalEditorSheet.swift`: 首页阅读目标编辑弹层（今日目标 / 年度目标）
- `Sheets/ReadingYearSummarySheet.swift`: 首页年度已读摘要弹层（年度目标 + 已读书籍列表）

## 子目录

- `Components/`: 在读首页页面私有卡片组件（趋势总卡、今日阅读、继续阅读、最近在读、年度摘要）
- `ReadCalendar/`: 阅读日历子功能（含 Components/ 与 Sheets/）
- `Timeline/`: 时间线子功能（正式页面与页面私有卡片组件）
- `Sheets/`: 在读模块业务弹层目录

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
