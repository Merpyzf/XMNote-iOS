# ReadCalendar/
> L2 | 父级: Reading/CLAUDE.md

阅读日历子功能视图层，页面壳层 + 业务内容壳层 + 页面私有子视图 + 业务 Sheet + 布局引擎共置。对应 ViewModel 位于 `xmnote/ViewModels/Reading/ReadCalendar/`。

## 成员清单

- `ReadCalendarView.swift`: 阅读日历页面壳层（仓储注入 + 状态映射，挂载 ReadCalendarContentView，管理设置弹层）
- `ReadCalendarContentView.swift`: 阅读日历业务内容壳层（顶部控制、周标题、分页网格、状态反馈与月总结触发）
- `ReadCalendarEventLayoutEngine.swift`: 连续区间构建与跨周分段、lane 分配算法引擎
- `ReadCalendarSettings.swift`: 阅读日历页面配置状态（事件过滤、触感反馈、连续阅读提示、每日书籍数）
- `Components/CalendarMonthStepperBar.swift`: 页面私有月份切换触发器组件（点击月份菜单快速跳月）
- `Components/ReadCalendarMonthGrid.swift`: 页面私有月网格组件（热力图/活动事件/书籍封面三模式）
- `Components/ReadCalendarTopControlBar.swift`: 页面私有顶部控制区组件（月份切换、统计入口、模式切换）
- `Components/ReadCalendarWeekdayHeader.swift`: 页面私有星期标题行组件
- `Components/ReadCalendarStreakHintBanner.swift`: 页面私有连续阅读提示横幅组件
- `Components/ReadCalendarInlineErrorBanner.swift`: 页面私有内联错误提示组件
- `Components/ReadCalendarSummaryFloatingButton.swift`: 页面私有月总结悬浮入口组件
- `Sheets/ReadCalendarSettingsSheet.swift`: 业务设置弹层
- `Sheets/ReadCalendarMonthSummarySheet.swift`: 业务月总结弹层

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
