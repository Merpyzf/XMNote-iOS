/**
 * [INPUT]: 依赖 SwiftUI 视图布局与 glassEffect 能力，依赖 DesignTokens 提供封面进度条轨道/完成段/描边语义色
 * [OUTPUT]: 对外提供 BookCoverProgressBar（书籍封面底部悬浮阅读进度条）
 * [POS]: UIComponents/Foundation 跨模块复用组件，作为 XMBookCover 等封面视图的覆盖层表达阅读进度
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 悬浮在封面底部的玻璃进度条，统一表达书籍阅读进度。
struct BookCoverProgressBar: View {
    private enum Layout {
        static let minHorizontalInset: CGFloat = 8
        static let maxHorizontalInset: CGFloat = 12
        static let horizontalInsetRatio: CGFloat = 0.12

        static let bottomInsetRatio: CGFloat = 0.068

        static let minHeight: CGFloat = 4
        static let maxHeight: CGFloat = 6
        static let heightRatio: CGFloat = 0.055

        static let borderWidth: CGFloat = 0.5
        static let animationDuration: CGFloat = 0.22
    }

    let progress: Double

    private var clampedProgress: CGFloat {
        CGFloat(min(1, max(0, progress)))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let horizontalInset = clamped(
                size.width * Layout.horizontalInsetRatio,
                min: Layout.minHorizontalInset,
                max: Layout.maxHorizontalInset
            )
            let bottomInset = size.height * Layout.bottomInsetRatio
            let barHeight = clamped(
                size.height * Layout.heightRatio,
                min: Layout.minHeight,
                max: Layout.maxHeight
            )
            let barWidth = max(0, size.width - horizontalInset * 2)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                progressBar(width: barWidth, height: barHeight)
                    .padding(.horizontal, horizontalInset)
                    .padding(.bottom, bottomInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension BookCoverProgressBar {
    func progressBar(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.bookCoverProgressTrack)

            Capsule()
                .fill(Color.bookCoverProgressFill)
                .frame(width: width * clampedProgress)
        }
        .frame(height: height)
        .overlay {
            Capsule()
                .stroke(Color.bookCoverProgressStroke, lineWidth: Layout.borderWidth)
        }
        .glassEffect(.regular, in: .capsule)
        .animation(.smooth(duration: Layout.animationDuration), value: clampedProgress)
    }

    func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(maxValue, Swift.max(minValue, value))
    }
}

#Preview("BookCoverProgressBar") {
    XMBookCover.fixedWidth(
        110,
        urlString: "",
        border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth),
        surfaceStyle: .spine
    )
    .overlay {
        BookCoverProgressBar(progress: 0.62)
    }
    .padding(Spacing.screenEdge)
    .background(Color.surfacePage)
}
