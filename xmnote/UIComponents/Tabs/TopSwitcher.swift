/**
 * [INPUT]: 依赖 UIComponents/TopBar 的 PrimaryTopBar 与 AddMenuCircleButton，依赖 SwiftUI 事务、局部动画与无障碍能力
 * [OUTPUT]: 对外提供 TopSwitcher 组件（支持标签模式与标题模式，默认将外部 selection 作为无动画路由写入）
 * [POS]: UIComponents/Tabs 的顶部切换入口，被 Book/Note/Reading/Personal 页面复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 顶部切换器写入外部 selection 时采用的事务策略，区分路由硬切与显式动画切换。
enum TopSwitcherSelectionTransactionPolicy {
    case hardSwitch
    case animated(Animation)

    /// 写入父级路由 selection；首页二级页默认禁用动画，避免动画事务污染内容宿主。
    func updateRouteSelection(_ update: () -> Void) {
        switch self {
        case .hardSwitch:
            updateWithoutAnimation(update)
        case .animated(let animation):
            withAnimation(animation) {
                update()
            }
        }
    }

    /// 更新 TopSwitcher 自己的视觉 selection；硬切路由必须与内容页同帧落位。
    func updateTopFeedback(_ update: () -> Void) {
        switch self {
        case .hardSwitch:
            updateWithoutAnimation(update)
        case .animated(let animation):
            withAnimation(animation) {
                update()
            }
        }
    }

    /// 在禁动画事务中同步 selection，避免外层事务把路由硬切扩散成视觉过渡。
    private func updateWithoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            update()
        }
    }
}

/// 首页顶部切换控件：支持「二级标签」与「单标题」两种模式。
struct TopSwitcher<Tab: Hashable, Trailing: View>: View {
    private enum Mode {
        case tabs(
            selection: Binding<Tab>,
            tabs: [Tab],
            quote: String,
            titleProvider: (Tab) -> String
        )
        case title(text: String, quote: String)
    }

    private let mode: Mode
    private let selectionTransactionPolicy: TopSwitcherSelectionTransactionPolicy
    private let trailing: Trailing

    /// 注入分段数据与标题文案，构建顶部切换器交互。
    init(
        selection: Binding<Tab>,
        tabs: [Tab],
        quote: String = "“",
        selectionTransactionPolicy: TopSwitcherSelectionTransactionPolicy = .hardSwitch,
        titleProvider: @escaping (Tab) -> String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.mode = .tabs(
            selection: selection,
            tabs: tabs,
            quote: quote,
            titleProvider: titleProvider
        )
        self.selectionTransactionPolicy = selectionTransactionPolicy
        self.trailing = trailing()
    }

    var body: some View {
        PrimaryTopBar {
            switch mode {
            case .tabs(let selection, let tabs, let quote, let titleProvider):
                TopSwitcherTabBar(
                    selection: selection,
                    tabs: tabs,
                    quote: quote,
                    selectionTransactionPolicy: selectionTransactionPolicy,
                    titleProvider: titleProvider
                )
                .onAppear {
                    #if DEBUG
                    let currentTitle = titleProvider(selection.wrappedValue)
                    BrandTypography.debugLogTopSwitcherMode(
                        "tabs",
                        tabsCount: tabs.count,
                        title: currentTitle
                    )
                    #endif
                }
            case .title(let text, let quote):
                TopSwitcherTitleLabel(text: text, quote: quote)
                    .onAppear {
                        #if DEBUG
                        BrandTypography.debugLogTopSwitcherMode(
                            "title",
                            tabsCount: 0,
                            title: text
                        )
                        #endif
                    }
            }
        } trailing: {
            trailing
        }
        .accessibilityIdentifier("top_switcher")
    }
}

extension TopSwitcher where Tab == Never {
    /// 注入分段数据与标题文案，构建顶部切换器交互。
    init(
        title: String,
        quote: String = "“",
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.mode = .title(text: title, quote: quote)
        self.selectionTransactionPolicy = .hardSwitch
        self.trailing = trailing()
    }
}

private enum TopSwitcherQuoteDecorationMetrics {
    static let assetName = "TopSwitcherQuote"
    static let iconWidth: CGFloat = 26
    static let iconHeight: CGFloat = 18
    static let offsetX: CGFloat = -11
    static let offsetY: CGFloat = -7
}

private enum TopSwitcherTypography {
    static let titleSize: CGFloat = 24
    static let minLabelHeight: CGFloat = 40
    static let verticalPadding: CGFloat = Spacing.half
}

private struct TopSwitcherTabBar<Tab: Hashable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let quote: String
    let selectionTransactionPolicy: TopSwitcherSelectionTransactionPolicy
    let titleProvider: (Tab) -> String

    @State private var visualSelection: Tab?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var displayedSelection: Tab {
        visualSelection ?? selection
    }

    var body: some View {
        HStack(spacing: Spacing.double) {
            ForEach(tabs, id: \.self, content: tabItem)
        }
        .onAppear {
            #if DEBUG
            BrandTypography.debugLogTopSwitcherTabsUsesQuoteIcon(tabs.count)
            #endif
            guard visualSelection == nil else { return }
            selectionTransactionPolicy.updateTopFeedback {
                visualSelection = selection
            }
        }
        .onChange(of: selection) { _, newSelection in
            guard visualSelection != newSelection else { return }
            selectionTransactionPolicy.updateTopFeedback {
                visualSelection = newSelection
            }
        }
        .onChange(of: tabs) { _, newTabs in
            guard let visualSelection, !newTabs.contains(visualSelection) else { return }
            selectionTransactionPolicy.updateTopFeedback {
                self.visualSelection = selection
            }
        }
        .backgroundPreferenceValue(TopSwitcherTabAnchorKey.self, alignment: .topLeading) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors[displayedSelection] {
                    let rect = proxy[anchor]
                    Image(TopSwitcherQuoteDecorationMetrics.assetName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: TopSwitcherQuoteDecorationMetrics.iconWidth,
                            height: TopSwitcherQuoteDecorationMetrics.iconHeight
                        )
                        .offset(
                            x: rect.minX + TopSwitcherQuoteDecorationMetrics.offsetX,
                            y: rect.minY + TopSwitcherQuoteDecorationMetrics.offsetY
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private struct TopSwitcherTabAnchorKey: PreferenceKey {
        static var defaultValue: [Tab: Anchor<CGRect>] { [:] }

        /// 合并每个 Tab 的锚点信息，供背景引号定位动画使用。
        static func reduce(value: inout [Tab: Anchor<CGRect>], nextValue: () -> [Tab: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func tabItem(_ tab: Tab) -> some View {
        let isSelected = displayedSelection == tab
        let title = titleProvider(tab)

        return Button {
            guard selection != tab else { return }
            selectionTransactionPolicy.updateRouteSelection {
                selection = tab
            }
            selectionTransactionPolicy.updateTopFeedback {
                visualSelection = tab
            }
        } label: {
            Text(title)
                .font(isSelected ? BookshelfTypography.topSelected : BookshelfTypography.topUnselected)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .anchorPreference(key: TopSwitcherTabAnchorKey.self, value: .bounds) { [tab: $0] }
                .padding(.vertical, TopSwitcherTypography.verticalPadding)
                .frame(minHeight: TopSwitcherTypography.minLabelHeight)
                .lineLimit(dynamicTypeSize >= .accessibility1 ? 2 : 1)
                .multilineTextAlignment(.leading)
                .modifier(TopSwitcherFixedSizeModifier(isEnabled: dynamicTypeSize < .accessibility1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("top_switcher_tab_\(title)")
    }
}

private struct TopSwitcherTitleLabel: View {
    let text: String
    let quote: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var titleTrim: BrandTypography.VerticalTrim {
        AppTypography.topSwitcherTitleTrim(for: text, size: TopSwitcherTypography.titleSize)
    }

    var body: some View {
        Text(text)
            .font(AppTypography.topSwitcherTitleFont(for: text, size: TopSwitcherTypography.titleSize))
            .foregroundStyle(.primary)
            .brandVerticalTrim(titleTrim, edges: [.top, .bottom])
            .padding(.vertical, TopSwitcherTypography.verticalPadding)
            .frame(minHeight: TopSwitcherTypography.minLabelHeight, alignment: .leading)
            .lineLimit(dynamicTypeSize >= .accessibility1 ? 2 : 1)
            .background(alignment: .topLeading) {
                Image(TopSwitcherQuoteDecorationMetrics.assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: TopSwitcherQuoteDecorationMetrics.iconWidth,
                        height: TopSwitcherQuoteDecorationMetrics.iconHeight
                    )
                    .offset(
                        x: TopSwitcherQuoteDecorationMetrics.offsetX,
                        y: TopSwitcherQuoteDecorationMetrics.offsetY
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier("top_switcher_title_\(text)")
            .onAppear {
                #if DEBUG
                BrandTypography.debugLogTopSwitcherTitle(text, size: TopSwitcherTypography.titleSize)
                #endif
            }
    }
}

private struct TopSwitcherFixedSizeModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.fixedSize()
        } else {
            content
        }
    }
}

#Preview("TopSwitcher Tabs") {
    @Previewable @State var selection: TopSwitcherPreviewTab = .first
    ZStack(alignment: .top) {
        Color.surfacePage.ignoresSafeArea()
        TopSwitcher(
            selection: $selection,
            tabs: TopSwitcherPreviewTab.allCases,
            titleProvider: \.title
        ) {
            AddMenuCircleButton(onAddBook: {}, onAddNote: {})
        }
    }
}

#Preview("TopSwitcher Title") {
    ZStack(alignment: .top) {
        Color.surfacePage.ignoresSafeArea()
        TopSwitcher(title: "我的") {
            AddMenuCircleButton(onAddBook: {}, onAddNote: {})
        }
    }
}

private enum TopSwitcherPreviewTab: CaseIterable, Hashable {
    case first, second, third

    var title: String {
        switch self {
        case .first: "标签一"
        case .second: "标签二"
        case .third: "标签三"
        }
    }
}
