//
//  Components.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import SwiftUI

// MARK: - Card Container

/// 内容卡片容器，对应 Android 端的 ContentBox
/// 极细边框定义边界，白色背景浮于窗口背景之上
struct CardContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(Color.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card)
                    .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
            )
    }
}

// MARK: - Empty State View

/// 通用占位视图，品牌绿图标 + 灰色文字
struct EmptyStateView: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.brand.opacity(0.3))
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Home Header Gradient

struct HomeTopHeaderGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(light: Color(hex: 0x2ECF77).opacity(0.2), dark: Color(hex: 0x1E2A25)),
                Color.windowBackground.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Primary Top Bar

/// 主 Tab 顶部容器：左侧内容 + 右侧操作区，统一高度与边距。
struct PrimaryTopBar<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                trailing
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(height: 52)
        .background(Color.clear)
    }
}

// MARK: - Top Bar Action Icon

struct TopBarActionIcon: View {
    let systemName: String
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .medium
    var foregroundColor: Color = .secondary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: weight))
            .foregroundStyle(foregroundColor)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
    }
}

// MARK: - Glass Button Style

extension View {
    @ViewBuilder
    func topBarGlassButtonStyle(_ enabled: Bool) -> some View {
        if enabled {
            self.buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.buttonStyle(.plain)
        }
    }
}

// MARK: - Add Menu Button

/// 统一 `+` 菜单按钮。glass 模式下通过 `.glassEffect(.regular.interactive())` 实现液态玻璃与按压反馈。
struct AddMenuCircleButton: View {
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let usesGlassStyle: Bool

    init(
        onAddBook: @escaping () -> Void,
        onAddNote: @escaping () -> Void,
        usesGlassStyle: Bool = false
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.usesGlassStyle = usesGlassStyle
    }

    var body: some View {
        Menu {
            Button("添加书籍", systemImage: "book.badge.plus", action: onAddBook)
            Button("添加书摘", systemImage: "square.and.pencil", action: onAddNote)
        } label: {
            if usesGlassStyle {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.brand)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.brand)
                    .frame(width: 36, height: 36)
                    .background(Color.contentBackground, in: Circle())
                    .overlay(Circle().stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
        }
        .topBarGlassButtonStyle(usesGlassStyle)
        .accessibilityLabel("添加")
    }
}

// MARK: - Inline Tab Bar

/// 通用内嵌标签栏，左对齐、内容自适应宽度、品牌绿下划线指示器
/// 对应 Android 端 TabLayout 的 scrollable + wrap_content 模式
struct InlineTabBar<Tab: Hashable & CaseIterable>: View
    where Tab.AllCases: RandomAccessCollection {

    @Binding var selection: Tab
    let titleProvider: (Tab) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Tab.allCases), id: \.self) { tab in
                tabItem(tab)
            }
        }
    }

    private func tabItem(_ tab: Tab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(.snappy) { selection = tab }
        } label: {
            VStack(spacing: 4) {
                Text(titleProvider(tab))
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .fixedSize()
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.brand)
                        .frame(height: 3)
                        .matchedGeometryEffect(id: "indicator", in: namespace)
                } else {
                    Color.clear.frame(height: 3)
                }
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }
}

#if canImport(SwiftUI)
// MARK: - Quote Inline Tab Bar

/// 顶部引号样式标签栏，用于阅读页的轻量导航表达。
/// 选中态强化文字与引号，避免液态玻璃风格造成层级混乱。
struct QuoteInlineTabBar<Tab: Hashable & CaseIterable>: View
    where Tab.AllCases: RandomAccessCollection {

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
#endif

#Preview("InlineTabBar") {
    @Previewable @State var selection: PreviewTab = .first
    NavigationStack {
        Color.clear
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    InlineTabBar(selection: $selection) { $0.title }
                }
            }
    }
}

#Preview("QuoteInlineTabBar") {
    @Previewable @State var selection: PreviewTab = .second
    VStack(alignment: .leading, spacing: 0) {
        QuoteInlineTabBar(selection: $selection) { $0.title }
        Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 20)
    .background(
        LinearGradient(
            colors: [Color(hex: 0xEAF4F0), Color.windowBackground],
            startPoint: .top,
            endPoint: .bottom
        )
    )
}

private enum PreviewTab: CaseIterable, Hashable {
    case first, second, third
    var title: String {
        switch self {
        case .first: "标签一"
        case .second: "标签二"
        case .third: "标签三"
        }
    }
}

#Preview("CardContainer") {
    ZStack {
        Color.windowBackground.ignoresSafeArea()
        CardContainer {
            VStack(spacing: 0) {
                Text("卡片内容示例")
                    .padding()
            }
        }
        .padding()
    }
}

#Preview("EmptyState") {
    EmptyStateView(icon: "book.pages", message: "暂无在读书籍")
}
