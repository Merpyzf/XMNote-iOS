/**
 * [INPUT]: 依赖 DesignSystem 与 XMScrollEdgeChrome，接收标题、副标题、交互锁定、关闭动作及类型安全的顶部/底部/标题栏内容槽位
 * [OUTPUT]: 对外提供基于 iOS 26 系统导航标题与副标题的统一 Sheet 根骨架、标准内容顶部间距、Sheet 主复合面板的 xmSheetContentPanel 同心圆角语义，并组合滚动回弹、安全区边缘及可选固定栏
 * [POS]: UIComponents/Sheet 的通用业务 Sheet 根骨架；Settings、Book、Tag 等模块共享，禁止 AnyView 类型擦除
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 集中持有业务 Sheet 内部稳定布局关系，避免调用方按页面重复校准系统标题区后的内容距离。
enum XMSheetScaffoldLayout {
    /// 普通滚动内容在系统标题安全区之后追加的标准距离；固定内容顶栏场景不消费该值。
    static let standardContentTopSpacing = Spacing.base
}

extension Shape where Self == ConcentricRectangle {
    /// Sheet 主要任务表层的统一轮廓；调用方组合两个以上协同区域且与外缘平行时显式使用。
    /// 普通独立内容卡继续使用 `CardContainer` 的 12pt 默认 Shape。
    static var xmSheetContentPanel: ConcentricRectangle {
        ConcentricRectangle(
            corners: .concentric(
                minimum: .fixed(CornerRadius.containerMedium)
            ),
            isUniform: false
        )
    }
}

/// 为系统 Sheet 工具栏提供固定尺寸的确认与原位加载状态，避免各业务重复制造按钮壳层。
struct XMSheetConfirmationAction: View {
    let isDisabled: Bool
    let isConfirming: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .opacity(isConfirming ? 0 : 1)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.primaryActionForeground)
                        .opacity(isConfirming ? 1 : 0)
                }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.appTint)
        .disabled(isDisabled || isConfirming)
        .accessibilityLabel(isConfirming ? "正在确认" : "确认")
    }
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

    private let isInteractionLocked: Bool
    private let scrollEdgePresentation: XMScrollEdgeChromePresentation
    private let hasCustomLeadingAction: Bool
    private let hasTrailingAction: Bool
    private let showsCustomTitleSubtitle: Bool
    private let showsContentTopBar: Bool
    private let showsBottomBar: Bool

    /// 注入标题、关闭动作与滚动内容；未提供固定栏时保持标准纯滚动结构。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
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
        self.isInteractionLocked = isInteractionLocked
        self.scrollEdgePresentation = .contained
        self.hasCustomLeadingAction = false
        self.hasTrailingAction = false
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = false
        self.showsBottomBar = false
    }

    /// 创建带固定顶部控件的系统确认 Sheet；搜索或筛选控件进入 safe-area bar，滚动内容获得系统 soft edge。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
        scrollEdgePresentation: XMScrollEdgeChromePresentation = .overlaySoft,
        isConfirmationDisabled: Bool = false,
        isConfirming: Bool = false,
        confirmationAction: @escaping () -> Void,
        @ViewBuilder contentTopBar: () -> ContentTopBar,
        @ViewBuilder content: () -> Content
    ) where LeadingAction == EmptyView,
            TrailingAction == XMSheetConfirmationAction,
            TitleSubtitle == EmptyView,
            BottomBar == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
        self.leadingAction = EmptyView()
        self.trailingAction = XMSheetConfirmationAction(
            isDisabled: isConfirmationDisabled,
            isConfirming: isConfirming,
            action: confirmationAction
        )
        self.titleSubtitle = EmptyView()
        self.contentTopBar = contentTopBar()
        self.bottomBar = EmptyView()
        self.isInteractionLocked = isInteractionLocked || isConfirming
        self.scrollEdgePresentation = scrollEdgePresentation
        self.hasCustomLeadingAction = false
        self.hasTrailingAction = true
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = true
        self.showsBottomBar = false
    }

    /// 创建带动态辅助信息和固定顶部控件的系统确认 Sheet，避免把选择数量塞进导航标题。
    init(
        title: String,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
        scrollEdgePresentation: XMScrollEdgeChromePresentation = .overlaySoft,
        isConfirmationDisabled: Bool = false,
        isConfirming: Bool = false,
        confirmationAction: @escaping () -> Void,
        @ViewBuilder titleSubtitle: () -> TitleSubtitle,
        @ViewBuilder contentTopBar: () -> ContentTopBar,
        @ViewBuilder content: () -> Content
    ) where LeadingAction == EmptyView,
            TrailingAction == XMSheetConfirmationAction,
            BottomBar == EmptyView {
        self.title = title
        self.subtitle = nil
        self.onClose = onClose
        self.content = content()
        self.leadingAction = EmptyView()
        self.trailingAction = XMSheetConfirmationAction(
            isDisabled: isConfirmationDisabled,
            isConfirming: isConfirming,
            action: confirmationAction
        )
        self.titleSubtitle = titleSubtitle()
        self.contentTopBar = contentTopBar()
        self.bottomBar = EmptyView()
        self.isInteractionLocked = isInteractionLocked || isConfirming
        self.scrollEdgePresentation = scrollEdgePresentation
        self.hasCustomLeadingAction = false
        self.hasTrailingAction = true
        self.showsCustomTitleSubtitle = true
        self.showsContentTopBar = true
        self.showsBottomBar = false
    }

    /// 注入标题、关闭动作、滚动内容与固定底部操作区。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
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
        self.isInteractionLocked = isInteractionLocked
        self.scrollEdgePresentation = scrollEdgePresentation
        self.hasCustomLeadingAction = false
        self.hasTrailingAction = false
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = false
        self.showsBottomBar = true
    }

    /// 注入标题、关闭动作、固定内容顶部栏与滚动内容。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
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
        self.isInteractionLocked = isInteractionLocked
        self.scrollEdgePresentation = scrollEdgePresentation
        self.hasCustomLeadingAction = false
        self.hasTrailingAction = false
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = true
        self.showsBottomBar = false
    }

    /// 注入标题、关闭动作、固定内容顶部栏、固定底部栏与滚动内容。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
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
        self.isInteractionLocked = isInteractionLocked
        self.scrollEdgePresentation = scrollEdgePresentation
        self.hasCustomLeadingAction = false
        self.hasTrailingAction = false
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = true
        self.showsBottomBar = true
    }

    /// 注入动态副标题、固定内容顶部栏与底部栏，让业务交互留在标准标题视觉层级内。
    init(
        title: String,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
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
        self.isInteractionLocked = isInteractionLocked
        self.scrollEdgePresentation = scrollEdgePresentation
        self.hasCustomLeadingAction = false
        self.hasTrailingAction = false
        self.showsCustomTitleSubtitle = true
        self.showsContentTopBar = true
        self.showsBottomBar = true
    }

    /// 注入双侧标题栏操作与滚动内容；槽位保持具体 View 类型，不使用 AnyView。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
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
        self.isInteractionLocked = isInteractionLocked
        self.scrollEdgePresentation = .contained
        self.hasCustomLeadingAction = true
        self.hasTrailingAction = true
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = false
        self.showsBottomBar = false
    }

    /// 创建使用默认关闭按钮与标准确认按钮的系统 Sheet；确认中自动锁定内容、关闭和交互式收起。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        isInteractionLocked: Bool = false,
        isConfirmationDisabled: Bool = false,
        isConfirming: Bool = false,
        confirmationAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) where LeadingAction == EmptyView,
            TrailingAction == XMSheetConfirmationAction,
            TitleSubtitle == EmptyView,
            ContentTopBar == EmptyView,
            BottomBar == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
        self.leadingAction = EmptyView()
        self.trailingAction = XMSheetConfirmationAction(
            isDisabled: isConfirmationDisabled,
            isConfirming: isConfirming,
            action: confirmationAction
        )
        self.titleSubtitle = EmptyView()
        self.contentTopBar = EmptyView()
        self.bottomBar = EmptyView()
        self.isInteractionLocked = isInteractionLocked || isConfirming
        self.scrollEdgePresentation = .contained
        self.hasCustomLeadingAction = false
        self.hasTrailingAction = true
        self.showsCustomTitleSubtitle = false
        self.showsContentTopBar = false
        self.showsBottomBar = false
    }

    var body: some View {
        systemToolbarBody
    }

    private var systemToolbarBody: some View {
        NavigationStack {
            systemNavigationContent
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .interactiveDismissDisabled(isInteractionLocked)
    }

    @ViewBuilder
    private var systemNavigationContent: some View {
        if let subtitle, !subtitle.isEmpty {
            configuredSystemScrollContent
                .navigationSubtitle(subtitle)
        } else {
            configuredSystemScrollContent
        }
    }

    private var configuredSystemScrollContent: some View {
        systemScrollContent
            .disabled(isInteractionLocked)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { systemToolbarContent }
    }

    @ToolbarContentBuilder
    private var systemToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if hasCustomLeadingAction {
                leadingAction
                    .disabled(isInteractionLocked)
            } else {
                systemCloseButton
            }
        }

        if hasTrailingAction {
            ToolbarItem(placement: .confirmationAction) {
                trailingAction
                    .disabled(isInteractionLocked)
            }
        }

        if showsCustomTitleSubtitle {
            ToolbarItem(placement: .principal) {
                VStack(spacing: Spacing.micro) {
                    Text(title)
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    titleSubtitle
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var systemScrollContent: some View {
        if hasSystemTopBar, showsBottomBar {
            XMScrollEdgeChrome(
                presentation: scrollEdgePresentation,
                edges: [.top, .bottom],
                topBar: { systemTopBar },
                bottomBar: { bottomBar },
                content: { baseScrollContent }
            )
        } else if hasSystemTopBar {
            XMScrollEdgeChrome(
                presentation: scrollEdgePresentation,
                edges: .top,
                topBar: { systemTopBar },
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

    private var hasSystemTopBar: Bool {
        showsContentTopBar
    }

    private var systemTopBar: some View {
        contentTopBar
            .frame(maxWidth: .infinity)
    }

    private var resolvedContentTopSpacing: CGFloat {
        showsContentTopBar
            ? Spacing.none
            : XMSheetScaffoldLayout.standardContentTopSpacing
    }

    private var systemCloseButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
        }
        .tint(Color.textSecondary)
        .disabled(isInteractionLocked)
        .accessibilityLabel("关闭")
    }

    private var baseScrollContent: some View {
        ScrollView {
            content
        }
        .contentMargins(
            .top,
            resolvedContentTopSpacing,
            for: .scrollContent
        )
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
    }

}

#Preview("普通内容标准顶部间距") {
    XMSheetScaffold(
        title: "编辑内容",
        subtitle: "标准标题与滚动区域",
        onClose: { }
    ) {
        LazyVStack(alignment: .leading, spacing: Spacing.base) {
            CardContainer(
                shape: ConcentricRectangle.xmSheetContentPanel,
                showsBorder: true,
                borderColor: .surfaceBorderSubtle
            ) {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("Sheet 内容面板")
                        .font(AppTypography.headlineSemibold)
                    Text("主任务与协同操作共用这一表层，圆角跟随 Sheet 外缘逐角同心计算。")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(Spacing.contentEdge)
            }

            CardContainer {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("普通独立内容卡")
                        .font(AppTypography.subheadlineMedium)
                    Text("默认 12pt 圆角，只表达一个独立 block，不追随 Sheet 外轮廓。")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(Spacing.contentEdge)
            }

            VStack(alignment: .leading, spacing: Spacing.none) {
                Text("普通列表行不需要卡片")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.bottom, Spacing.half)

                ForEach(1...3, id: \.self) { index in
                    Text("列表内容 \(index)")
                        .font(AppTypography.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Spacing.base)

                    if index < 3 {
                        Rectangle()
                            .fill(Color.surfaceDividerSubtle)
                            .frame(height: StrokeWidth.hairline)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.contentEdge)
    }
}

#Preview("固定顶部栏排除标准间距") {
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
        Text("固定顶部栏后的滚动内容不叠加标准标题区间距")
            .font(AppTypography.body)
            .frame(maxWidth: .infinity, minHeight: 320)
    }
}
