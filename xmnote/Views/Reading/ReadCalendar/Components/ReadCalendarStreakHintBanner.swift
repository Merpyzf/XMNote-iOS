import SwiftUI

/**
 * [INPUT]: 依赖提示文本与 DesignTokens 视觉语义
 * [OUTPUT]: 对外提供 ReadCalendarStreakHintBanner（连续阅读提示横幅）
 * [POS]: ReadCalendar 业务内复用组件，统一连续阅读里程碑提示样式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarStreakHintBanner: View {
    private enum Layout {
        static let horizontalPadding: CGFloat = Spacing.base
        static let verticalPadding: CGFloat = 6
    }

    let text: String

    var body: some View {
        HStack(spacing: Spacing.half) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brand)

            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.readCalendarSubtleText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.readCalendarSelectionFill.opacity(0.56))
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.readCalendarSelectionStroke.opacity(0.54), lineWidth: 0.6)
        }
    }
}
