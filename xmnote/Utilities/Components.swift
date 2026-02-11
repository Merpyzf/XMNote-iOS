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
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? Color.brand : .clear)
                    .frame(height: 3)
                    .matchedGeometryEffect(
                        id: isSelected ? "indicator" : "idle_\(String(describing: tab))",
                        in: namespace
                    )
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }
}

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
