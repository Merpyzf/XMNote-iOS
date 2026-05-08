/**
 * [INPUT]: 依赖 BookshelfTitleDisplayMode、DesignTokens 字体与 SwiftUI 可访问性 Reduce Motion 环境
 * [OUTPUT]: 对外提供 BookshelfTitleText，统一书架卡片与列表中的书名单行、滚动和两行显示语义
 * [POS]: Book 模块页面私有标题组件，被默认书架与二级书籍列表复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书架书名文本，按显示设置在单行、省略、滚动与两行之间切换。
struct BookshelfTitleText: View {
    let text: String
    let mode: BookshelfTitleDisplayMode
    var style: BookshelfTitleTextStyle = .captionMedium
    var color: Color = .textPrimary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch mode {
        case .standard:
            titleLabel
                .lineLimit(1)
        case .compact:
            if reduceMotion {
                titleLabel
                    .lineLimit(1)
            } else {
                BookshelfMarqueeTitleText(
                    text: text,
                    style: style,
                    color: color
                )
            }
        case .full:
            titleLabel
                .lineLimit(2)
        }
    }

    private var titleLabel: some View {
        Text(text)
            .font(style.font)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 书架标题字号语义，保证渲染字体和滚动测量字体来自同一设计令牌。
enum BookshelfTitleTextStyle {
    case captionMedium
    case bodyMedium

    var font: Font {
        switch self {
        case .captionMedium:
            return AppTypography.captionMedium
        case .bodyMedium:
            return AppTypography.bodyMedium
        }
    }

    var uiFont: UIFont {
        switch self {
        case .captionMedium:
            return AppTypography.uiSemantic(.caption1, weight: .medium)
        case .bodyMedium:
            return AppTypography.uiSemantic(.body, weight: .medium)
        }
    }

    var lineHeight: CGFloat {
        ceil(uiFont.lineHeight + 2)
    }
}

/// 单行溢出时自动横向滚动的书名文本，Reduce Motion 由外层回退为静态省略。
private struct BookshelfMarqueeTitleText: View {
    let text: String
    let style: BookshelfTitleTextStyle
    let color: Color
    @State private var isScrolling = false
    @State private var animationToken = UUID()

    private let gap: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let containerWidth = proxy.size.width
            let textWidth = measuredTextWidth
            let shouldScroll = textWidth > containerWidth + 2

            Group {
                if shouldScroll {
                    HStack(spacing: gap) {
                        titleLabel
                            .fixedSize(horizontal: true, vertical: false)
                        titleLabel
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityHidden(true)
                    }
                    .offset(x: isScrolling ? -(textWidth + gap) : 0)
                    .onAppear {
                        restartAnimation(containerWidth: containerWidth, textWidth: textWidth)
                    }
                    .onChange(of: containerWidth) { _, newWidth in
                        restartAnimation(containerWidth: newWidth, textWidth: textWidth)
                    }
                    .onChange(of: text) { _, _ in
                        restartAnimation(containerWidth: containerWidth, textWidth: measuredTextWidth)
                    }
                } else {
                    titleLabel
                        .lineLimit(1)
                }
            }
        }
        .frame(height: style.lineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var titleLabel: some View {
        Text(text)
            .font(style.font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var measuredTextWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: style.uiFont]).width
    }

    private var animationDuration: Double {
        max(5.5, min(16, Double(measuredTextWidth / 18)))
    }

    private func restartAnimation(containerWidth: CGFloat, textWidth: CGFloat) {
        let token = UUID()
        animationToken = token
        isScrolling = false
        guard textWidth > containerWidth + 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard animationToken == token else { return }
            withAnimation(.linear(duration: animationDuration).repeatForever(autoreverses: false)) {
                isScrolling = true
            }
        }
    }
}
