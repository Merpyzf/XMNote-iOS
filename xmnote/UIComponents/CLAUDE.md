# UIComponents/
> L2 | 父级: /CLAUDE.md

可复用 UI 组件唯一归属目录。按功能分四个子目录。

## Foundation/

- `SurfaceComponents.swift`: CardContainer（圆角/描边可配置）、EmptyStateView、HomeTopHeaderGradient 通用容器组件
- `HighlightColorPicker.swift`: 高亮 ARGB 色值网格选择组件
- `XMRemoteImage.swift`: 统一远程图片组件（静态图 + GIF 探测/降级 + 占位）
- `XMGIFImageView.swift`: GIF 动画承载桥接组件（基于 Gifu）

## TopBar/

- `PrimaryTopBar.swift`: 顶部左内容 + 右操作容器
- `TopBarActionIcon.swift`: 顶部栏统一图标组件
- `AddMenuCircleButton.swift`: 顶部 `+` 菜单按钮组件
- `TopBarGlassButtonStyle.swift`: 顶部栏液态玻璃按钮样式

## Tabs/

- `TopSwitcher.swift`: 顶部标题/标签切换组件

## Charts/

- `HeatmapChart.swift`: GitHub 风格阅读热力图组件（支持 `HeatmapChartStyle` 配置方格尺寸/间距/圆角/视口防裁切，右侧固定中文星期标签 + 顶部月/年交接标签 + Android 同步 overflow 防重叠绘制 + 分段方格渲染 + 程序化滚动 + 今日高亮）
- `ReadingDurationRankingChart.swift`: 阅读时长排行组件（封面 + 时长标签 + 条形宽度动画，支持 placeholder/resolved/fallback 三态）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
