# ReadCalendar/
> L2 | 父级: Reading/CLAUDE.md

阅读日历子功能，View + ViewModel + 布局引擎共置。

## 成员清单

- `ReadCalendarView.swift`: 阅读日历页面壳层（仓储注入 + 状态映射，挂载 ReadCalendarPanel 公共组件）
- `ReadCalendarViewModel.swift`: 阅读日历页面状态中枢（月份切换、选中态、周布局构建）
- `ReadCalendarEventLayoutEngine.swift`: 连续区间构建与跨周分段、lane 分配算法引擎

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
