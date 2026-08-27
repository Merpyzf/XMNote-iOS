/**
 * [INPUT]: 依赖 DesignSystem、TopBarActionIcon 与 XMScrollEdgeChrome，接收标题、可选动态副标题、关闭动作及类型安全的顶部/底部/标题栏内容槽位
 * [OUTPUT]: 对外提供统一标题与副标题层级、滚动回弹、安全区边缘及可选固定栏的 XMSheetScaffold
 * [POS]: UIComponents/Sheet 的通用业务 Sheet 根骨架；Settings、Book、Tag 等模块共享，禁止 AnyView 类型擦除
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

enum XMSheetScaffoldLayout {
    static let defaultTitleHorizontalReserve = InteractionMetrics.minimumTouchTarget + Spacing.base
    static let textActionTitleHorizontalReserve: CGFloat = 96
    static let closeVisualSize: CGFloat = 32
    static let titleChromeMinHeight = InteractionMetrics.minimumTouchTarget
    static let closeFillOpacity = 0.82
}

/// 通用业务 Sheet 根骨架，组合标准标题栏、全轴回弹滚动区与可选固定内容栏。
struct XMSheetScaffold<
    Content: View,
    LeadingAction: View,
    TrailingAction: View,
    TitleSubtitle: View,
    ContentTopBar: View,
    BottomBar: View
>: View {
    let title: String
    let subtitle: String?
    let onClose: () -> Void
    let content: Content
    let leadingAction: LeadingAction
    let trailingAction: TrailingAction
    let titleSubtitle: TitleSubtitle
    let contentTopBar: ContentTopBar
    let bottomBar: BottomBar

    private let closeVisualSize: CGFloat
    private let scrollEdgePresentation: XMScrollEdgeChromePresentation
    private let usesCustomTitleActions: Bool
    private let showsCustomTitleSubtitle: Bool
    private let showsContentTopBar: Bool
    private let showsBottomBar: Bool

    /// 注入标题、关闭动作与滚动内容；未提供固定栏时保持标准纯滚动结构。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        closeVisualSize: CGFloat = XMSheetScaffoldLayout.closeVisualSize,
        @ViewBuilder content: () -> Content
    ) where LeadingAction == EmptyView,
            TrailingAction == EmptyView,
            TitleSubtitle == EmptyView,
            ContentTopBar == EmptyView,
            BottomBar == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
        self.leadingAction = EmptyView()
        self.trailingAction = EmptyView()
        self.titleSubtitle = EmptyView()
        self.contentTopBar = EmptyView()
        self.bottomBar = EmptyView()
        self.closeVisualSize = closeVisualSize
        self.scrollEdgePresentation = .contained
        self.usesCustomTitleActions = false
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = false
        self.showsBottomBar = false
    }

    /// 注入标题、关闭动作、滚动内容与固定底部操作区。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        closeVisualSize: CGFloat = XMSheetScaffoldLayout.closeVisualSize,
        scrollEdgePresentation: XMScrollEdgeChromePresentation = .overlaySoft,
        @ViewBuilder bottomBar: () -> BottomBar,
        @ViewBuilder content: () -> Content
    ) where LeadingAction == EmptyView,
            TrailingAction == EmptyView,
            TitleSubtitle == EmptyView,
            ContentTopBar == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
        self.leadingAction = EmptyView()
        self.trailingAction = EmptyView()
        self.titleSubtitle = EmptyView()
        self.contentTopBar = EmptyView()
        self.bottomBar = bottomBar()
        self.closeVisualSize = closeVisualSize
        self.scrollEdgePresentation = scrollEdgePresentation
        self.usesCustomTitleActions = false
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = false
        self.showsBottomBar = true
    }

    /// 注入标题、关闭动作、固定内容顶部栏与滚动内容。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        closeVisualSize: CGFloat = XMSheetScaffoldLayout.closeVisualSize,
        scrollEdgePresentation: XMScrollEdgeChromePresentation = .overlaySoft,
        @ViewBuilder contentTopBar: () -> ContentTopBar,
        @ViewBuilder content: () -> Content
    ) where LeadingAction == EmptyView,
            TrailingAction == EmptyView,
            TitleSubtitle == EmptyView,
            BottomBar == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
        self.leadingAction = EmptyView()
        self.trailingAction = EmptyView()
        self.titleSubtitle = EmptyView()
        self.contentTopBar = contentTopBar()
        self.bottomBar = EmptyView()
        self.closeVisualSize = closeVisualSize
        self.scrollEdgePresentation = scrollEdgePresentation
        self.usesCustomTitleActions = false
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = true
        self.showsBottomBar = false
    }

    /// 注入标题、关闭动作、固定内容顶部栏、固定底部栏与滚动内容。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        closeVisualSize: CGFloat = XMSheetScaffoldLayout.closeVisualSize,
        scrollEdgePresentation: XMScrollEdgeChromePresentation = .overlaySoft,
        @ViewBuilder contentTopBar: () -> ContentTopBar,
        @ViewBuilder bottomBar: () -> BottomBar,
        @ViewBuilder content: () -> Content
    ) where LeadingAction == EmptyView,
            TrailingAction == EmptyView,
            TitleSubtitle == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
        self.leadingAction = EmptyView()
        self.trailingAction = EmptyView()
        self.titleSubtitle = EmptyView()
        self.contentTopBar = contentTopBar()
        self.bottomBar = bottomBar()
        self.closeVisualSize = closeVisualSize
        self.scrollEdgePresentation = scrollEdgePresentation
        self.usesCustomTitleActions = false
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = true
        self.showsBottomBar = true
    }

    /// 注入动态副标题、固定内容顶部栏与底部栏，让业务交互留在标准标题视觉层级内。
    init(
        title: String,
        onClose: @escaping () -> Void,
        closeVisualSize: CGFloat = XMSheetScaffoldLayout.closeVisualSize,
        scrollEdgePresentation: XMScrollEdgeChromePresentation = .overlaySoft,
        @ViewBuilder titleSubtitle: () -> TitleSubtitle,
        @ViewBuilder contentTopBar: () -> ContentTopBar,
        @ViewBuilder bottomBar: () -> BottomBar,
        @ViewBuilder content: () -> Content
    ) where LeadingAction == EmptyView, TrailingAction == EmptyView {
        self.title = title
        self.subtitle = nil
        self.onClose = onClose
        self.content = content()
        self.leadingAction = EmptyView()
        self.trailingAction = EmptyView()
        self.titleSubtitle = titleSubtitle()
        self.contentTopBar = contentTopBar()
        self.bottomBar = bottomBar()
        self.closeVisualSize = closeVisualSize
        self.scrollEdgePresentation = scrollEdgePresentation
        self.usesCustomTitleActions = false
        self.showsCustomTitleSubtitle = true
        self.showsContentTopBar = true
        self.showsBottomBar = true
    }

    /// 注入双侧标题栏操作与滚动内容；槽位保持具体 View 类型，不使用 AnyView。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder leadingAction: () -> LeadingAction,
        @ViewBuilder trailingAction: () -> TrailingAction,
        @ViewBuilder content: () -> Content
    ) where TitleSubtitle == EmptyView, ContentTopBar == EmptyView, BottomBar == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
        self.leadingAction = leadingAction()
        self.trailingAction = trailingAction()
        self.titleSubtitle = EmptyView()
        self.contentTopBar = EmptyView()
        self.bottomBar = EmptyView()
        self.closeVisualSize = XMSheetScaffoldLayout.closeVisualSize
        self.scrollEdgePresentation = .contained
        self.usesCustomTitleActions = true
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = false
        self.showsBottomBar = false
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            titleChrome
            scrollContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceSheet.ignoresSafeArea())
    }

    @ViewBuilder
    private var scrollContent: some View {
        if showsContentTopBar, showsBottomBar {
            XMScrollEdgeChrome(
                presentation: scrollEdgePresentation,
                edges: [.top, .bottom],
                topBar: { contentTopBar },
                bottomBar: { bottomBar },
                content: { baseScrollContent }
            )
        } else if showsContentTopBar {
            XMScrollEdgeChrome(
                presentation: scrollEdgePresentation,
                edges: .top,
                topBar: { contentTopBar },
                content: { baseScrollContent }
            )
        } else if showsBottomBar {
            XMScrollEdgeChrome(
                presentation: scrollEdgePresentation,
                edges: .bottom,
                bottomBar: { bottomBar },
                content: { baseScrollContent }
            )
        } else {
            baseScrollContent
        }
    }

    private var baseScrollContent: some View {
        ScrollView {
            content
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
    }

    private var titleChrome: some View {
        ZStack {
            HStack {
                leadingActionSlot
                Spacer(minLength: Spacing.none)
                trailingActionSlot
            }
            .frame(minHeight: XMSheetScaffoldLayout.titleChromeMinHeight)

            VStack(spacing: Spacing.micro) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if showsCustomTitleSubtitle {
                    titleSubtitle
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                } else if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, titleHorizontalReserve)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.comfortable)
    }

    private var titleHorizontalReserve: CGFloat {
        usesCustomTitleActions
            ? XMSheetScaffoldLayout.textActionTitleHorizontalReserve
            : XMSheetScaffoldLayout.defaultTitleHorizontalReserve
    }

    @ViewBuilder
    private var leadingActionSlot: some View {
        if usesCustomTitleActions {
            leadingAction
        } else {
            Color.clear
                .frame(
                    width: InteractionMetrics.minimumTouchTarget,
                    height: InteractionMetrics.minimumTouchTarget
                )
        }
    }

    @ViewBuilder
    private var trailingActionSlot: some View {
        if usesCustomTitleActions {
            trailingAction
        } else {
            closeButton
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            TopBarActionIcon(
                systemName: "xmark",
                iconSize: 13,
                containerSize: closeVisualSize,
                weight: .bold,
                foregroundColor: .textSecondary
            )
            .background(
                Color.controlFillSecondary.opacity(XMSheetScaffoldLayout.closeFillOpacity),
                in: Circle()
            )
            .frame(
                width: InteractionMetrics.minimumTouchTarget,
                height: InteractionMetrics.minimumTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
    }
}

#Preview("业务 Sheet 骨架") {
    XMSheetScaffold(
        title: "编辑内容",
        subtitle: "标准标题与滚动区域",
        onClose: { }
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

#Preview("可交互动态副标题") {
    XMSheetScaffold(
        title: "选择书籍",
        onClose: { },
        titleSubtitle: {
            // 预览复现以信息展示为主、低频且非破坏性的副标题入口；保留文字自然命中范围，避免标题栏空白响应点击。
            Button("已选择 1 本") { }
                .buttonStyle(.plain)
                .accessibilityLabel("已选择 1 本书")
                .accessibilityHint("查看并管理已选书籍")
        },
        contentTopBar: {
            Text("固定搜索区域")
                .font(AppTypography.body)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Spacing.section)
        },
        bottomBar: {
            Button("完成") { }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.bottom, Spacing.base)
        }
    ) {
        Text("滚动内容")
            .font(AppTypography.body)
            .frame(maxWidth: .infinity, minHeight: 320)
    }
}
