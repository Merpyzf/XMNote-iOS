# UIComponents/
> L2 | 父级: /CLAUDE.md

可复用 UI 组件唯一归属目录。按功能分四个子目录。

## Foundation/

- `SurfaceComponents.swift`: CardContainer（圆角/描边可配置）、EmptyStateView、HomeTopHeaderGradient 通用容器组件
- `HighlightColorPicker.swift`: 高亮 ARGB 色值网格选择组件
- `XMBookCover.swift`: 统一书籍封面组件（固定宽高比 0.7 + `.fill` Crop 裁切 + 占位图 + 可配边框，支持 responsive/fixedWidth/fixedHeight/fixedSize 四种尺寸模式）
- `XMYearMonthPickerSheet.swift`: 项目级年月/年份选择 Sheet（固定标题栏、年月/年份两种模式、动态字体自适应）
- `XMRemoteImage.swift`: 统一远程图片组件（静态图 + GIF 探测/降级 + 占位）
- `XMGIFImageView.swift`: GIF 动画承载桥接组件（基于 Gifu）
- `XMScopeSelector.swift`: 范围选择控件（2-5 项等宽同屏、6+ 内部横向滚动、数量 badge、跟手拖拽、内容流/浮层玻璃两种样式）
- `XMSearchHistorySection.swift`: 通用搜索历史区块（最近搜索词、展开/收起、编辑态、右侧删除操作槽、清空入口、可选空态与内容/玻璃两种样式）
- `XMScrollEdgeChrome.swift`: 滚动边缘栏容器（contained 固定占位栏、overlaySoft 系统软边缘、顶部/底部栏组合）
- `XMScrollEdgeWash.swift`: 滚动边缘柔化层（顶部/底部/双向覆盖层、强度/高度/surface/可见性策略）
- `RichText.swift`: 只读 HTML 富文本展示组件（`UITextView + RichTextLayoutManager`，支持截断状态回调与布局缓存）
- `CollapsedRichTextPreview.swift`: ExpandableRichText 收起态轻量预览组件（`UILabel` + 原生省略号截断）
- `ExpandableRichText.swift`: 可展开/收起 HTML 富文本组件（完整态 RichText + 收起态轻量预览双通道）
- `ImmersiveBottomChrome.swift`: 底部沉浸遮罩与悬浮 ornament 组件（统一渐变托底、安全区延展、滚动补偿与图标热区）

## TopBar/

- `PrimaryTopBar.swift`: 顶部左内容 + 右操作容器
- `TopBarActionIcon.swift`: 顶部栏统一图标组件
- `AddMenuCircleButton.swift`: 顶部 `+` 菜单按钮组件
- `TopBarGlassButtonStyle.swift`: 顶部栏液态玻璃按钮样式

## Tabs/

- `KeepAliveSwitcherHost.swift`: 通用懒激活保活切换容器（已激活子页常驻，selection/激活集合/显隐硬切）
- `HomeSubtabScaffold.swift`: 首页二级页壳层（统一顶部切换、保活宿主、顶部渐变与 hardSwitch 默认策略）
- `HorizontalPagingHost.swift`: 通用横向分页宿主（分页吸附、选中同步、窗口化懒挂载与页级生命周期）
- `SubtabBootstrapCoordinator.swift`: 通用二级页启动协调器（warmup 去重、启动阶段跟踪）
- `TopSwitcher.swift`: 顶部标题/标签切换组件（hardSwitch 下路由 selection 与视觉 selection 同帧无动画写入）

## Charts/

- `HeatmapChart.swift`: GitHub 风格阅读热力图组件（支持 `HeatmapChartStyle` 配置方格尺寸/间距/圆角/视口防裁切，右侧固定中文星期标签 + 顶部月/年交接标签 + Android 同步 overflow 防重叠绘制 + 分段方格渲染 + 程序化滚动 + 今日高亮）
- `ReadingDurationRankingChart.swift`: 阅读时长排行组件（封面 + 时长标签 + 条形宽度动画，支持 placeholder/resolved/fallback 三态）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
