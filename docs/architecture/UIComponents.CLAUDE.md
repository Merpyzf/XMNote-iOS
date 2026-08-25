# UIComponents/
成员清单
- Foundation/SurfaceComponents.swift: 提供通用表层组件（CardContainer、EmptyStateView、HomeTopHeaderGradient）。
- Foundation/XMRemoteImage.swift: 提供统一远程图片组件（静态图 + GIF 探测/降级）。
- Foundation/XMGIFImageView.swift: 提供 GIF 动画桥接组件（Gifu）。
- Foundation/XMYearMonthPickerSheet.swift: 提供项目级年月/年份随机访问选择 Sheet（固定标题栏、两种选择模式、动态字体自适应）。
- Foundation/XMScopeSelector.swift: 提供范围选择控件（2-5 项等宽同屏、6+ 内部横向滚动、数量 badge、跟手拖拽、内容流/浮层玻璃两种样式）。
- Foundation/XMScrollEdgeChrome.swift: 提供滚动边缘栏容器（contained 固定占位栏、overlaySoft 系统软边缘）。
- Foundation/XMScrollEdgeWash.swift: 提供滚动视口边缘柔化层（顶部/底部/双向覆盖、强度/高度/surface/可见性策略）。
- Foundation/RichText.swift: 提供只读 HTML 富文本展示组件（完整富文本排版、截断检测与布局缓存）。
- Foundation/CollapsedRichTextPreview.swift: 提供 ExpandableRichText 收起态轻量预览组件（UILabel 截断 + 展开按钮）。
- Foundation/ExpandableRichText.swift: 提供可展开/收起 HTML 富文本组件（完整态与轻量收起态双通道）。
- Foundation/ImmersiveBottomChrome.swift: 提供底部沉浸遮罩与悬浮 ornament 组件（渐变托底、安全区延展、滚动补偿与统一图标热区）。
- Foundation/XMTagLabel.swift: 提供纯展示领域标签的统一排版、语义背景、内边距与 4pt 连续圆角；不承载筛选或操作状态。
- TopBar/PrimaryTopBar.swift: 提供顶部栏布局容器（PrimaryTopBar）。
- TopBar/TopBarActionIcon.swift: 提供顶部栏图标组件（TopBarActionIcon）。
- TopBar/AddMenuCircleButton.swift: 提供顶部添加菜单组件（AddMenuCircleButton）。
- TopBar/TopBarGlassButtonStyle.swift: 提供顶部栏玻璃态样式扩展（topBarGlassButtonStyle）。
- Tabs/KeepAliveSwitcherHost.swift: 提供通用懒激活保活切换容器（已激活子页常驻，selection/激活集合/显隐硬切）。
- Tabs/HomeSubtabScaffold.swift: 提供首页二级页壳层（统一顶部切换、保活宿主、顶部渐变与 hardSwitch 默认策略）。
- Tabs/HorizontalPagingHost.swift: 提供通用横向分页宿主（分页吸附、选中同步、窗口化懒挂载与页级生命周期）。
- Tabs/SubtabBootstrapCoordinator.swift: 提供通用二级页启动协调器（warmup 去重与阶段跟踪）。
- Tabs/TopSwitcher.swift: 提供顶部切换组件（hardSwitch 下路由 selection 与视觉 selection 同帧无动画写入）。
- Charts/HeatmapChart.swift: 提供 GitHub 风格阅读热力图组件。
- Charts/HeatmapPresentation.swift: 在 UI 层把纯值热力等级映射为展示文案与语义色，保持 Domain 无 UI 框架依赖。
- Charts/ReadingDurationRankingChart.swift: 提供阅读时长排行组件（封面 + 条形动画 + 占位态）。
- Settings/XMSettingsPage.swift: 提供卡片式配置页滚动、全轴回弹、页面边距、最大宽度与背景。
- Settings/XMSettingsSection.swift: 提供配置页分区标题层级与内容亲密性。
- Settings/XMSettingsGroup.swift: 提供配置项 grouped/singleItem 表层、固定 24pt grouped 连续圆角与弱分隔线。
- Settings/XMSettingsRows.swift: 提供已证明复用的菜单值行与开关行，不扩展为万能设置行。
- Sheet/XMSheetScaffold.swift: 提供通用业务 Sheet 标题、滚动区及可选固定顶栏/底栏的泛型根骨架。

机器可读组件入口：`scripts/design-system/component-catalog.json`；使用 `python3 scripts/design-system/ds.py catalog` 查询。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
