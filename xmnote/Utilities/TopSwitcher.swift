//
//  TopSwitcher.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/26.
//

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
            case .title(let text, let quote):
                TopSwitcherTitleLabel(text: text, quote: quote)
            }
        } trailing: {
            trailing
        }
        .accessibilityIdentifier("top_switcher")
    }
}

extension TopSwitcher where Tab == Never {
    init(
        title: String,
        quote: String = "“",
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.mode = .title(text: title, quote: quote)
        self.trailing = trailing()
    }
}

private struct TopSwitcherTabBar<Tab: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: Tab
    let tabs: [Tab]
    let quote: String
    let titleProvider: (Tab) -> String

    var body: some View {
        let quoteFontSize: CGFloat = 50
        let quoteOffsetX: CGFloat = -10
        let quoteOffsetY: CGFloat = -18

        HStack(spacing: 22) {
            ForEach(tabs, id: \.self, content: tabItem)
        }
        .backgroundPreferenceValue(TopSwitcherTabAnchorKey.self, alignment: .topLeading) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors[selection] {
                    let rect = proxy[anchor]
                    Text(quote)
                        .font(.system(size: quoteFontSize, weight: .bold))
                        .foregroundStyle(colorScheme == .dark
                            ? Color.brand.opacity(0.28)
                            : Color.brand.opacity(0.22))
                        .offset(x: rect.minX + quoteOffsetX, y: rect.minY + quoteOffsetY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .animation(.snappy(duration: 0.25, extraBounce: 0.06), value: selection)
                }
            }
        }
    }

    private struct TopSwitcherTabAnchorKey: PreferenceKey {
        static var defaultValue: [Tab: Anchor<CGRect>] { [:] }

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
                .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .anchorPreference(key: TopSwitcherTabAnchorKey.self, value: .bounds) { [tab: $0] }
                .padding(.vertical, 4)
                .frame(minHeight: 32)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("top_switcher_tab_\(title)")
    }
}

private struct TopSwitcherTitleLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let quote: String

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.vertical, 4)
            .frame(minHeight: 32, alignment: .leading)
            .background(alignment: .topLeading) {
                Text(quote)
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(colorScheme == .dark
                        ? Color.brand.opacity(0.28)
                        : Color.brand.opacity(0.22))
                    .offset(x: -10, y: -18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier("top_switcher_title_\(text)")
    }
}

#Preview("TopSwitcher Tabs") {
    @Previewable @State var selection: TopSwitcherPreviewTab = .first
    ZStack(alignment: .top) {
        Color.windowBackground.ignoresSafeArea()
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
        Color.windowBackground.ignoresSafeArea()
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
