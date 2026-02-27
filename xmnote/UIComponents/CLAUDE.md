# UIComponents/
> L2 | 父级: /CLAUDE.md

可复用 UI 组件唯一归属目录。按功能分三个子目录。

## Foundation/

- `SurfaceComponents.swift`: CardContainer、EmptyStateView、HomeTopHeaderGradient 通用容器组件
- `HighlightColorPicker.swift`: 高亮 ARGB 色值网格选择组件

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

- `HeatmapChart.swift`: GitHub 风格阅读热力图组件（右侧固定中文星期标签，日/二/四/六显示 + 顶部月/年交接标签，采用 Android 同步的 overflow 防重叠绘制策略 + 分段方格渲染（阅读状态色+阅读量色）+ 统一 8pt 轴距与四周外边距 + 左侧真实日期列补齐 + scrollToMonth 程序化滚动 + 今日高亮 + maxWidth 铺满父容器）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
