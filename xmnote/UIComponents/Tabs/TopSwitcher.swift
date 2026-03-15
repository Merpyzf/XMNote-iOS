/**
 * [INPUT]: 依赖 UIComponents/TopBar 的 PrimaryTopBar 与 AddMenuCircleButton，依赖 SwiftUI 动画与无障碍能力
 * [OUTPUT]: 对外提供 TopSwitcher 组件（支持标签模式与标题模式）
 * [POS]: UIComponents/Tabs 的顶部切换入口，被 Book/Note/Reading/Personal 页面复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

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
    private let trailing: Trailing

    /// 注入分段数据与标题文案，构建顶部切换器交互。
    init(
        selection: Binding<Tab>,
        tabs: [Tab],
        quote: String = "“",
        titleProvider: @escaping (Tab) -> String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.mode = .tabs(
            selection: selection,
            tabs: tabs,
            quote: quote,
            titleProvider: titleProvider
        )
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
    static let selectedTabSize: CGFloat = 22
    static let unselectedTabSize: CGFloat = 19
    static let titleSize: CGFloat = 24
    static let minLabelHeight: CGFloat = 40
    static let verticalPadding: CGFloat = Spacing.half
}

private struct TopSwitcherTabBar<Tab: Hashable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let quote: String
    let titleProvider: (Tab) -> String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Spacing.double) {
            ForEach(tabs, id: \.self, content: tabItem)
        }
        .onAppear {
            #if DEBUG
            BrandTypography.debugLogTopSwitcherTabsUsesQuoteIcon(tabs.count)
            #endif
        }
        .backgroundPreferenceValue(TopSwitcherTabAnchorKey.self, alignment: .topLeading) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors[selection] {
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
                        .animation(.snappy(duration: 0.25, extraBounce: 0.06), value: selection)
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
        let isSelected = selection == tab
        let title = titleProvider(tab)

        return Button {
            withAnimation(.snappy(duration: 0.25, extraBounce: 0.06)) {
                selection = tab
            }
        } label: {
            Text(title)
                .font(
                    AppTypography.fixed(
                        baseSize: isSelected ? TopSwitcherTypography.selectedTabSize : TopSwitcherTypography.unselectedTabSize,
                        relativeTo: .title3,
                        weight: isSelected ? .semibold : .medium,
                        minimumPointSize: isSelected ? TopSwitcherTypography.selectedTabSize : TopSwitcherTypography.unselectedTabSize
                    )
                )
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
