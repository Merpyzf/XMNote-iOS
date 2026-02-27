/**
 * [INPUT]: 依赖 SwiftUI PreferenceKey、GeometryReader 与动画能力，依赖 DesignTokens 品牌色扩展
 * [OUTPUT]: 对外提供 QuoteInlineTabBar 引号样式标签组件
 * [POS]: UIComponents/Tabs 的强调型标签组件，用于顶部主导航的视觉锚定场景
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 顶部引号样式标签栏，用于阅读页的轻量导航表达。
/// 选中态强化文字与引号，避免液态玻璃风格造成层级混乱。
struct QuoteInlineTabBar<Tab: Hashable & CaseIterable>: View where Tab.AllCases: RandomAccessCollection {

    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: Tab
    let titleProvider: (Tab) -> String
    let quote: String

    init(
        selection: Binding<Tab>,
        quote: String = "“",
        titleProvider: @escaping (Tab) -> String
    ) {
        self._selection = selection
        self.quote = quote
        self.titleProvider = titleProvider
    }

    var body: some View {
        let quoteFontSize: CGFloat = 50
        let quoteOffsetX: CGFloat = -10
        let quoteOffsetY: CGFloat = -18

        HStack(spacing: 22) {
            ForEach(Array(Tab.allCases), id: \.self, content: tabItem)
        }
        .backgroundPreferenceValue(QuoteTabAnchorKey.self, alignment: .topLeading) { anchors in
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

    private struct QuoteTabAnchorKey: PreferenceKey {
        static var defaultValue: [Tab: Anchor<CGRect>] { [:] }

        static func reduce(value: inout [Tab: Anchor<CGRect>], nextValue: () -> [Tab: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func tabItem(_ tab: Tab) -> some View {
        let isSelected = selection == tab

        return Button {
            withAnimation(.snappy(duration: 0.25, extraBounce: 0.06)) {
                selection = tab
            }
        } label: {
            Text(titleProvider(tab))
                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .anchorPreference(key: QuoteTabAnchorKey.self, value: .bounds) { [tab: $0] }
                .padding(.vertical, 4)
                .frame(minHeight: 32)
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

#Preview("QuoteInlineTabBar") {
    @Previewable @State var selection: QuoteInlineTabBarPreviewTab = .second
    VStack(alignment: .leading, spacing: 0) {
        QuoteInlineTabBar(selection: $selection) { $0.title }
        Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 20)
    .background(
        LinearGradient(
            colors: [Color.brand.opacity(0.12), Color.windowBackground],
            startPoint: .top,
            endPoint: .bottom
        )
    )
}

private enum QuoteInlineTabBarPreviewTab: CaseIterable, Hashable {
    case first, second, third

    var title: String {
        switch self {
        case .first: "标签一"
        case .second: "标签二"
        case .third: "标签三"
        }
    }
}
