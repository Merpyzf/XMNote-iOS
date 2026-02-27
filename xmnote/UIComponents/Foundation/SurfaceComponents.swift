/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignTokens.swift 的颜色、间距、圆角设计令牌
 * [OUTPUT]: 对外提供 CardContainer（支持圆角/描边可配置）、EmptyStateView、HomeTopHeaderGradient 三个通用表层组件
 * [POS]: UIComponents/Foundation 的基础表层组件集合，被各业务页面直接复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Card Container

/// 内容卡片容器，对应 Android 端的 ContentBox
/// 极细边框定义边界，白色背景浮于窗口背景之上
struct CardContainer<Content: View>: View {
    let cornerRadius: CGFloat
    let showsBorder: Bool
    let content: Content

    init(
        cornerRadius: CGFloat = CornerRadius.card,
        showsBorder: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.showsBorder = showsBorder
        self.content = content()
    }

    var body: some View {
        content
            .background(Color.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
                }
            }
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
                Color(light: Color.brand.opacity(0.2), dark: Color(hex: 0x1E2A25)),
                Color.windowBackground.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)
        .ignoresSafeArea(edges: .top)
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
