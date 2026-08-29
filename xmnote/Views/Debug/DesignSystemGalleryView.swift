#if DEBUG
/**
 * [INPUT]: 依赖 DesignSystem 令牌、UIComponents 的基础视觉/控件/反馈/布局入口、最小命中区基础设施及现有专项调试页
 * [OUTPUT]: 对外提供 DesignSystemGalleryView，集中展示核心组件、常见状态与适配场景
 * [POS]: Views/Debug 的设计系统展示入口，为 Preview、人工视觉检查和组件发现提供稳定宿主
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 设计系统核心展示入口；只持有演示状态，不进入生产导航或业务数据流。
struct DesignSystemGalleryView: View {
    fileprivate enum Scope: String, Hashable {
        case all
        case books
        case notes

        var title: String {
            switch self {
            case .all:
                return "全部"
            case .books:
                return "书籍"
            case .notes:
                return "书摘"
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText = "设计"
    @State private var isSearchActive = false
    @State private var scope: Scope = .all
    @State private var pagingSelection: Int? = 0
    @State private var rating = 3.5
    @State private var isSettingEnabled = true
    @State private var settingsOrder = 0
    @State private var isScaffoldPresented = false
    @State private var isTagSheetPresented = false
    @State private var tagLayout: TagSelectionLayoutMode = .list
    @State private var sharePayload: XMActivitySharePayload?
    @State private var toastCenter = XMToastCenter()
    @State private var compactBaselineHitProbeCount = 0
    @State private var compactExpandedHitProbeCount = 0

    private let tagItems = [
        XMTagSelectionItem(id: 1, title: "人物"),
        XMTagSelectionItem(id: 2, title: "产品设计"),
        XMTagSelectionItem(id: 3, title: "长期阅读"),
        XMTagSelectionItem(id: 4, title: "待整理"),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.double) {
                environmentSummary
                foundationSection
                controlsSection
                hitTargetProbeSection
                feedbackSection
                layoutSection
                validationLinksSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .scrollBounceBehavior(.always)
        .background(Color.surfacePage)
        .navigationTitle("设计系统展厅")
        .navigationBarTitleDisplayMode(.inline)
        .environment(toastCenter)
        .xmToastHost(center: toastCenter)
        .sheet(isPresented: $isScaffoldPresented) {
            scaffoldSample
        }
        .sheet(isPresented: $isTagSheetPresented) {
            tagSelectionSample
                .environment(toastCenter)
        }
        .sheet(item: $sharePayload) { payload in
            XMActivityShareSheet(activityItems: payload.activityItems)
        }
    }

    private var environmentSummary: some View {
        gallerySection("当前适配环境", subtitle: "用于确认颜色、字体、对比度和动效降级") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.half) {
                    environmentBadge(colorScheme == .dark ? "深色" : "浅色")
                    environmentBadge(colorSchemeContrast == .increased ? "高对比度" : "标准对比度")
                    environmentBadge(dynamicTypeSize.isAccessibilitySize ? "辅助功能字号" : "标准字号")
                    environmentBadge(reduceMotion ? "减少动态效果" : "标准动效")
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    environmentBadge(colorScheme == .dark ? "深色" : "浅色")
                    environmentBadge(colorSchemeContrast == .increased ? "高对比度" : "标准对比度")
                    environmentBadge(dynamicTypeSize.isAccessibilitySize ? "辅助功能字号" : "标准字号")
                    environmentBadge(reduceMotion ? "减少动态效果" : "标准动效")
                }
            }
        }
    }

    private var foundationSection: some View {
        gallerySection("基础视觉", subtitle: "语义色、排版、表层、书籍封面、标签与关键字") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                typographySample("页面标题", font: AppTypography.title3Semibold, color: .textPrimary)
                typographySample("正文用于持续阅读与信息说明", font: AppTypography.body, color: .textPrimary)
                typographySample("辅助信息保持可读但不抢占正文", font: AppTypography.caption, color: .textSecondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 112), spacing: Spacing.half)],
                    spacing: Spacing.half
                ) {
                    colorSample("页面表层", color: .surfacePage)
                    colorSample("卡片表层", color: .surfaceCard)
                    colorSample("主要交互", color: .appTint)
                    colorSample("错误反馈", color: .feedbackError)
                    colorSample("警告反馈", color: .feedbackWarning)
                    colorSample("成功反馈", color: .feedbackSuccess)
                }

                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover(urlString: "", width: 58, surfaceStyle: .spine)

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        HStack(spacing: Spacing.half) {
                            XMTagLabel("人物")
                            XMTagLabel("设计")
                        }
                        XMKeywordHighlighting.text(
                            "设计系统治理",
                            keyword: "设计",
                            baseFont: AppTypography.body,
                            highlightFont: AppTypography.bodyMedium,
                            baseColor: .textPrimary
                        )
                    }
                }
            }
        }
    }

    private var controlsSection: some View {
        gallerySection("表单与交互", subtitle: "焦点、选择、评分、禁用与原生菜单语义") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                XMInlineSearchField(
                    text: $searchText,
                    isActive: $isSearchActive,
                    prompt: "搜索组件"
                )

                XMScopeSelector(
                    items: Scope.allCasesForGallery,
                    selection: $scope,
                    accessibilityLabel: "组件范围"
                )

                HStack(spacing: Spacing.base) {
                    ForEach(XMSelectionIndicatorStyle.allCases) { style in
                        VStack(spacing: Spacing.half) {
                            XMSelectionIndicator(
                                style: style,
                                isSelected: style != .radio,
                                font: AppTypography.title3
                            )
                            Text(style.galleryTitle)
                                .font(AppTypography.caption2)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                XMRatingBar(value: $rating, preset: .form)
                    .accessibilityLabel("演示评分")

                controlsButtonSamples
            }
        }
    }

    private var feedbackSection: some View {
        gallerySection("反馈状态", subtitle: "加载、空态、错误和轻量消息保持职责分离") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                LoadingStateView("正在加载", style: .card)

                XMCompactStateView(
                    role: .empty,
                    title: "暂无内容"
                )
                    .frame(height: 96)

                Text("网络连接失败，请稍后重试")
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.feedbackError)

                toastButtonSamples
            }
        }
    }

    private var hitTargetProbeSection: some View {
        gallerySection("点击区验证", subtitle: "对照系统默认命中与显式 44pt 轮廓，视觉均保持 24pt") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(spacing: Spacing.double) {
                    Button {
                        compactBaselineHitProbeCount += 1
                    } label: {
                        hitTargetProbeIcon
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("默认点击区验证")
                    .accessibilityIdentifier("designSystem.compactHitTargetBaselineProbe")

                    Text("默认命中 \(compactBaselineHitProbeCount) 次")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .contentTransition(.numericText())
                }

                HStack(spacing: Spacing.double) {
                    Button {
                        compactExpandedHitProbeCount += 1
                    } label: {
                        hitTargetProbeIcon
                    }
                    .buttonStyle(.plain)
                    .xmMinimumHitTarget()
                    .accessibilityLabel("扩展点击区验证")
                    .accessibilityIdentifier("designSystem.compactHitTargetExpandedProbe")

                    Text("扩展命中 \(compactExpandedHitProbeCount) 次")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    private var hitTargetProbeIcon: some View {
        Image(systemName: "hand.tap")
            .font(AppTypography.captionSemibold)
            .foregroundStyle(Color.textPrimary)
            .frame(width: 24, height: 24)
            .background(Color.controlFillSecondary, in: Circle())
    }

    @ViewBuilder
    private var controlsButtonSamples: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.base) {
                controlsButtons
            }
        } else {
            HStack(spacing: Spacing.base) {
                controlsButtons
            }
        }
    }

    @ViewBuilder
    private var controlsButtons: some View {
        Button("普通按钮") { }
            .buttonStyle(.bordered)
        Button("主操作") { }
            .buttonStyle(.borderedProminent)
        Button("禁用") { }
            .buttonStyle(.bordered)
            .disabled(true)
    }

    @ViewBuilder
    private var toastButtonSamples: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.base) {
                toastButtons
            }
        } else {
            HStack(spacing: Spacing.base) {
                toastButtons
            }
        }
    }

    @ViewBuilder
    private var toastButtons: some View {
        Button("信息 Toast") {
            toastCenter.info("这是一条信息提示")
        }
        .buttonStyle(.bordered)
        Button("错误 Toast") {
            toastCenter.error("操作失败，请重试")
        }
        .buttonStyle(.bordered)
    }

    private var layoutSection: some View {
        gallerySection("布局与系统桥接", subtitle: "设置组合、业务 Sheet、标签选择和系统分享") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                PrimaryTopBar {
                    Text("纸间书摘")
                        .font(AppTypography.title3Semibold)
                        .foregroundStyle(Color.textPrimary)
                } trailing: {
                    TopBarActionPill {
                        Button { } label: {
                            TopBarActionIcon(
                                systemName: "magnifyingglass",
                                hitShape: .rectangle
                            )
                        }
                        .topBarActionPresentationStyle(.pillSegment)
                        .accessibilityLabel("搜索")
                    } trailing: {
                        AddMenuCircleButton(
                            onAddBook: { },
                            onAddNote: { },
                            presentation: .pillSegment
                        )
                    }
                }
                .padding(.horizontal, -Spacing.screenEdge)

                Button { } label: {
                    TopBarActionIcon(systemName: "ellipsis")
                }
                .topBarActionButtonStyle(true)
                .accessibilityLabel("更多")

                KeepAliveSwitcherHost(
                    selection: scope,
                    tabs: [.all, .books, .notes],
                    lazyActivation: false
                ) { item in
                    Text("当前常驻内容：\(item.title)")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget)
                        .background(Color.controlFillSecondary, in: RoundedRectangle(cornerRadius: CornerRadius.inlaySmall))
                }

                HorizontalPagingHost(
                    ids: [0, 1, 2],
                    selection: $pagingSelection,
                    showsIndicators: false
                ) { page in
                    RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                        .fill(Color.controlFillSecondary)
                        .overlay {
                            Text("分页 \(page + 1)")
                                .font(AppTypography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                        }
                }
                .frame(height: 72)

                ZStack {
                    Color.surfaceNested
                    ImmersiveBottomChromeOverlay(
                        metrics: .make(
                            measuredOrnamentHeight: 68,
                            safeAreaBottomInset: 0,
                            gradientMinimumHeight: 96
                        )
                    ) {
                        HStack(spacing: Spacing.base) {
                            Button { } label: {
                                ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                            }
                            Button { } label: {
                                ImmersiveBottomChromeIcon(systemName: "doc.on.doc")
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Spacing.base)
                        .background(.regularMaterial, in: Capsule())
                    }
                }
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))

                XMSettingsSection("阅读偏好") {
                    XMSettingsGroup {
                        XMSettingsToggleRow(title: "显示阅读进度", isOn: $isSettingEnabled)
                        XMSettingsDivider()
                        XMSettingsValueMenuRow(
                            title: "默认排序",
                            value: settingsOrder == 0 ? "最近阅读" : "书名",
                            options: [0, 1],
                            selection: settingsOrder,
                            optionTitle: { $0 == 0 ? "最近阅读" : "书名" },
                            optionImage: { $0 == 0 ? "clock" : "textformat" },
                            onSelect: { settingsOrder = $0 }
                        )
                    }
                }

                HStack(spacing: Spacing.base) {
                    Button("业务 Sheet") {
                        isScaffoldPresented = true
                    }
                    Button("标签选择") {
                        isTagSheetPresented = true
                    }
                    Button("系统分享") {
                        sharePayload = XMActivitySharePayload(activityItems: ["XMNote 设计系统"])
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var validationLinksSection: some View {
        gallerySection("专项验收", subtitle: "复杂交互与 UIKit 桥接保留独立运行环境") {
            VStack(spacing: Spacing.none) {
                validationLink("顶部栏与 Liquid Glass", destination: TopBarActionStyleLabTestView())
                Divider()
                validationLink("范围选择与状态矩阵", destination: XMScopeSelectorTestView())
                Divider()
                validationLink("搜索历史", destination: SearchHistoryTestView())
                Divider()
                validationLink("评分组件", destination: RatingBarTestView())
                Divider()
                validationLink("系统 Alert", destination: SystemAlertTestView())
                Divider()
                validationLink("系统颜色", destination: SystemColorsTestView())
            }
        }
    }

    private var scaffoldSample: some View {
        XMSheetScaffold(
            title: "标准业务 Sheet",
            subtitle: "标题、内容与安全区由骨架统一",
            onClose: { isScaffoldPresented = false }
        ) {
            LazyVStack(spacing: Spacing.base) {
                ForEach(1...8, id: \.self) { index in
                    CardContainer {
                        Text("内容项 \(index)")
                            .font(AppTypography.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.contentEdge)
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    private var tagSelectionSample: some View {
        XMTagSelectionSheet(
            items: tagItems,
            initialSelectedIDs: [1, 3],
            layout: XMTagSelectionLayoutConfiguration(
                initialMode: tagLayout,
                onChange: { tagLayout = $0 }
            ),
            onCreate: { title in
                XMTagSelectionItem(id: Int64(tagItems.count + 1), title: title)
            },
            onSave: { _ in true }
        )
    }

    private func gallerySection<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            VStack(alignment: .leading, spacing: Spacing.micro) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal, Spacing.half)

            CardContainer {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.contentEdge)
            }
        }
    }

    private func environmentBadge(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.captionMedium)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Color.controlFillSecondary, in: Capsule())
    }

    private func typographySample(_ text: String, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func colorSample(_ title: String, color: Color) -> some View {
        HStack(spacing: Spacing.half) {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(color)
                .frame(width: 28, height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
                }
                .accessibilityHidden(true)
            Text(title)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textPrimary)
        }
    }

    private func validationLink<Destination: View>(
        _ title: String,
        destination: Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: Spacing.base)
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.iconSecondary)
            }
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension DesignSystemGalleryView.Scope {
    static var allCasesForGallery: [XMScopeSelectorItem<Self>] {
        [
            XMScopeSelectorItem(id: .all, title: Self.all.title),
            XMScopeSelectorItem(id: .books, title: Self.books.title),
            XMScopeSelectorItem(id: .notes, title: Self.notes.title),
        ]
    }
}

private extension XMSelectionIndicatorStyle {
    var galleryTitle: String {
        switch self {
        case .checkbox:
            return "多选"
        case .radio:
            return "单选"
        case .checkmarkOnly:
            return "勾选"
        }
    }
}

#Preview("默认") {
    NavigationStack {
        DesignSystemGalleryView()
    }
}

#Preview("深色") {
    NavigationStack {
        DesignSystemGalleryView()
    }
    .preferredColorScheme(.dark)
}

#Preview("辅助功能字号") {
    NavigationStack {
        DesignSystemGalleryView()
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("紧凑宽度", traits: .fixedLayout(width: 320, height: 844)) {
    NavigationStack {
        DesignSystemGalleryView()
    }
    .environment(\.horizontalSizeClass, .compact)
}

#Preview("规则宽度", traits: .fixedLayout(width: 768, height: 1024)) {
    NavigationStack {
        DesignSystemGalleryView()
    }
    .environment(\.horizontalSizeClass, .regular)
}
#endif
