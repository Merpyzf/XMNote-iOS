# UIComponents/
> L2 | 父级: /CLAUDE.md

可复用 UI 组件唯一归属目录。按功能分三个子目录。

## Foundation/

- `SurfaceComponents.swift`: CardContainer（圆角/描边可配置）、EmptyStateView、HomeTopHeaderGradient 通用容器组件
- `HighlightColorPicker.swift`: 高亮 ARGB 色值网格选择组件
- `CalendarMonthStepperBar.swift`: 月视图顶部月份切换触发器（点击标题菜单快速跳月，不含左侧日历图标与液态玻璃背景）
- `ReadCalendarPanel.swift`: 阅读日历完整控件（单行顶部控制：左月份菜单 + 右图标模式切换 + weekday + 分页网格 + 状态反馈）
- `ReadCalendarMonthGrid.swift`: 阅读日历月网格组件（支持热力图/活动事件/书籍封面三模式渲染）

## TopBar/

- `PrimaryTopBar.swift`: 顶部左内容 + 右操作容器
- `TopBarActionIcon.swift`: 顶部栏统一图标组件
- `AddMenuCircleButton.swift`: 顶部 `+` 菜单按钮组件
- `TopBarGlassButtonStyle.swift`: 顶部栏液态玻璃按钮样式

## Tabs/

- `InlineTabBar.swift`: 通用内嵌标签组件
- `QuoteInlineTabBar.swift`: 带引号动效的标签组件
- `TopSwitcher.swift`: 顶部标题/标签切换组件

## Charts/

- `HeatmapChart.swift`: GitHub 风格阅读热力图组件（支持 `HeatmapChartStyle` 配置方格尺寸/间距/圆角/视口防裁切，右侧固定中文星期标签 + 顶部月/年交接标签 + Android 同步 overflow 防重叠绘制 + 分段方格渲染 + 程序化滚动 + 今日高亮）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
