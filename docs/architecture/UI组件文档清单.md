# UI 组件文档清单

说明
- 该清单用于 `scripts/verify_component_guides.sh` 校验。
- 重要 UI 组件（UI 核心白名单组件 + `xmnote/UIComponents` 下新增/重大重构组件）必须登记。

| 组件名 | 重要级别 | 源码路径 | 使用文档路径 | 触发条件 |
| --- | --- | --- | --- | --- |
| HeatmapChart | UI-复用关键 | xmnote/UIComponents/Charts/HeatmapChart.swift | docs/component-guides/HeatmapChart使用说明.md | 新增/重大重构 |
| CalendarMonthStepperBar | UI-复用关键 | xmnote/UIComponents/Foundation/CalendarMonthStepperBar.swift | docs/component-guides/CalendarMonthStepperBar使用说明.md | 新增/重大重构 |
| ReadCalendarPanel | UI-复用关键 | xmnote/UIComponents/Foundation/ReadCalendarPanel.swift | docs/component-guides/ReadCalendarPanel使用说明.md | 新增/重大重构 |
| ReadCalendarMonthGrid | UI-复用关键 | xmnote/UIComponents/Foundation/ReadCalendarMonthGrid.swift | docs/component-guides/ReadCalendarMonthGrid使用说明.md | 新增/重大重构 |
| ReadCalendarView | UI-核心页面关键 | xmnote/Views/Reading/ReadCalendarView.swift | docs/component-guides/ReadCalendar使用说明.md | 新增/重大重构 |

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
