# UIComponents/
成员清单
- Foundation/SurfaceComponents.swift: 提供通用表层组件（CardContainer、EmptyStateView、HomeTopHeaderGradient）。
- Foundation/XMRemoteImage.swift: 提供统一远程图片组件（静态图 + GIF 探测/降级）。
- Foundation/XMGIFImageView.swift: 提供 GIF 动画桥接组件（Gifu）。
- Foundation/XMYearMonthPickerSheet.swift: 提供项目级年月/年份随机访问选择 Sheet（固定标题栏、两种选择模式、动态字体自适应）。
- Foundation/RichText.swift: 提供只读 HTML 富文本展示组件（完整富文本排版、截断检测与布局缓存）。
- Foundation/CollapsedRichTextPreview.swift: 提供 ExpandableRichText 收起态轻量预览组件（UILabel 截断 + 展开按钮）。
- Foundation/ExpandableRichText.swift: 提供可展开/收起 HTML 富文本组件（完整态与轻量收起态双通道）。
- Foundation/ImmersiveBottomChrome.swift: 提供底部沉浸遮罩与悬浮 ornament 组件（渐变托底、安全区延展、滚动补偿与统一图标热区）。
- TopBar/PrimaryTopBar.swift: 提供顶部栏布局容器（PrimaryTopBar）。
- TopBar/TopBarActionIcon.swift: 提供顶部栏图标组件（TopBarActionIcon）。
- TopBar/AddMenuCircleButton.swift: 提供顶部添加菜单组件（AddMenuCircleButton）。
- TopBar/TopBarGlassButtonStyle.swift: 提供顶部栏玻璃态样式扩展（topBarGlassButtonStyle）。
- Tabs/KeepAliveSwitcherHost.swift: 提供通用懒激活保活切换容器（已激活子页常驻，仅切换可见性）。
- Tabs/HorizontalPagingHost.swift: 提供通用横向分页宿主（分页吸附、选中同步、窗口化懒挂载与页级生命周期）。
- Tabs/SubtabBootstrapCoordinator.swift: 提供通用二级页启动协调器（warmup 去重与阶段跟踪）。
- Tabs/TopSwitcher.swift: 提供顶部切换组件（TopSwitcher）。
- Charts/HeatmapChart.swift: 提供 GitHub 风格阅读热力图组件。
- Charts/ReadingDurationRankingChart.swift: 提供阅读时长排行组件（封面 + 条形动画 + 占位态）。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
