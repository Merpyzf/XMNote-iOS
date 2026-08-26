/**
 * [INPUT]: 依赖 SwiftUI、AppTypography 与语义色/间距令牌，接收 SF Symbol 名称和空态文案
 * [OUTPUT]: 对外提供 EmptyStateView 中性紧凑空态
 * [POS]: UIComponents/Feedback 的通用空态反馈组件，不承载页面主操作
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用空状态以中性图标和辅助文字表达无内容，不与页面主操作争夺视觉焦点。
struct EmptyStateView: View {
    let icon: String
    let message: String
    @ScaledMetric(relativeTo: .footnote) private var iconSize = EmptyStateMetrics.iconSize

    var body: some View {
        VStack(spacing: Spacing.cozy) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(Color.textHint)
            Text(message)
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

private enum EmptyStateMetrics {
    static let iconSize: CGFloat = 32
}

#Preview("EmptyState") {
    EmptyStateView(icon: "book.pages", message: "暂无在读书籍")
}
