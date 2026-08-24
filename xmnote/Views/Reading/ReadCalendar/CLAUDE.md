# ReadCalendar/
> L2 | 父级: Reading/CLAUDE.md

阅读日历子功能视图层，页面壳层 + 业务内容壳层 + 页面私有子视图 + 业务 Sheet + 布局引擎共置。对应 ViewModel 位于 `xmnote/ViewModels/Reading/ReadCalendar/`。

## 成员清单

- `ReadCalendarView.swift`: 阅读日历页面壳层（仓储注入 + 状态映射，挂载 ReadCalendarContentView，管理设置弹层）
- `ReadCalendarContentView.swift`: 阅读日历业务内容壳层（顶部控制、周标题、分页网格、状态反馈与月总结触发）
- `ReadCalendarEventLayoutEngine.swift`: 连续区间构建与跨周分段、lane 分配算法引擎
- `ReadCalendarSettings.swift`: 阅读日历页面配置状态（事件过滤、触感反馈、连续阅读提示、每日书籍数）
- `DailyReadingView.swift`: 指定自然日轨迹、筛选、打卡、记录管理、分享和相关书籍编辑页
- `ReadCalendarShareView.swift`: 月度/年度阅读日历分享预览与系统分享入口
- `Components/CalendarMonthStepperBar.swift`: 页面私有月份切换触发器组件（打开统一年月选择 Sheet）
- `Components/ReadCalendarMonthGrid.swift`: 页面私有月网格组件（热力图/活动事件/书籍封面三模式）
- `Components/ReadCalendarTopControlBar.swift`: 页面私有顶部控制区组件（月份/年份选择触发、统计入口、模式切换）
- `Components/ReadCalendarWeekdayHeader.swift`: 页面私有星期标题行组件
- `Components/ReadCalendarStreakHintBanner.swift`: 页面私有连续阅读提示横幅组件
- `Components/ReadCalendarSummaryFloatingButton.swift`: 页面私有月总结悬浮入口组件
- `Components/DailyReadingComponents.swift`: 每日轨迹更多菜单、筛选与提示组件组
- `Components/DailyReadingRecordRow.swift`: 每日轨迹记录行与上下文动作
- `Components/ReadCalendarDoneCelebration.swift`: 打卡完成庆祝效果
- `Components/ReadCalendarMonthContributionTreemap.swift`: 月度书籍贡献比例图
- `Components/ReadCalendarSelectedDaySummaryBar.swift`: 选中日期摘要栏
- `Components/ReadCalendarShareCard.swift`: 分享图片内容卡
- `Components/ReadCalendarSummaryMetricGrid.swift`: 月/年摘要指标网格
- `Sheets/ReadCalendarSettingsSheet.swift`: 业务设置弹层
- `Sheets/ReadCalendarMonthSummarySheet.swift`: 业务月总结弹层
- `Sheets/DailyReadingBookFilterSheet.swift`: 每日轨迹书籍筛选 Sheet
- `Sheets/ReadCalendarCheckInSheet.swift`: 阅读打卡 Sheet
- `Sheets/ReadCalendarTimingEditorSheet.swift`: 阅读记录编辑 Sheet
- `Sheets/ReadCalendarYearSummarySheet.swift`: 年度总结 Sheet

阅读日历空态、无内容失败和保留内容时的局部失败分别复用 `XMContentStateView`/`XMCompactStateView` 与 `XMInlineStatusBanner`；连续阅读提示、打卡庆祝和领域记录状态仍由本模块组件负责。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
