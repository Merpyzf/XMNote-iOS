import SwiftUI

/**
 * [INPUT]: 依赖错误文案与重试回调，依赖 DesignTokens 提供视觉样式
 * [OUTPUT]: 对外提供 ReadCalendarInlineErrorBanner（阅读日历内联错误提示）
 * [POS]: ReadCalendar 业务内复用组件，统一内容区错误反馈与重试入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 日历内联错误横幅，负责在内容区提示失败原因并提供重试入口。
struct ReadCalendarInlineErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.feedbackWarning)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("重试", action: onRetry)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brand)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.cozy)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.readCalendarSelectionFill.opacity(0.62))
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.readCalendarSelectionStroke.opacity(0.62), lineWidth: CardStyle.borderWidth)
        }
        .padding(.top, Spacing.base)
    }
}
