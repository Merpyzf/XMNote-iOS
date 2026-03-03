import SwiftUI

/**
 * [INPUT]: 依赖目标月份与回调事件，依赖 DesignTokens 提供基础视觉语义
 * [OUTPUT]: 对外提供 ReadCalendarMonthRecordPlaceholderSheet（月度阅读记录占位弹层）
 * [POS]: ReadCalendar 业务模块 Sheet，占位承接“点击月份进入当月阅读记录页”的后续能力
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarMonthRecordPlaceholderSheet: View {
    private enum Layout {
        static let containerPadding: CGFloat = Spacing.contentEdge
        static let contentSpacing: CGFloat = Spacing.base
        static let iconSize: CGFloat = 32
        static let cardPadding: CGFloat = Spacing.base
        static let cardCornerRadius: CGFloat = CornerRadius.containerMedium
        static let buttonHeight: CGFloat = 44
    }

    let monthStart: Date
    let onOpenMonthSummary: (Date) -> Void

    var body: some View {
        VStack(spacing: Layout.contentSpacing) {
            VStack(spacing: Spacing.cozy) {
                Image(systemName: "book.pages")
                    .font(.system(size: Layout.iconSize, weight: .medium))
                    .foregroundStyle(Color.brand)

                Text("\(monthTitle)阅读记录")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()

                Text("当月阅读记录页正在接入，当前可先查看该月总结。")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(Layout.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .fill(Color.contentBackground.opacity(0.96))
            )
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .stroke(Color.cardBorder.opacity(0.72), lineWidth: CardStyle.borderWidth)
            }

            Button {
                onOpenMonthSummary(monthStart)
            } label: {
                Text("查看当月总结")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.readCalendarTopAction)
                    .frame(maxWidth: .infinity, minHeight: Layout.buttonHeight)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .fill(Color.readCalendarSelectionFill.opacity(0.72))
            )
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .stroke(Color.cardBorder.opacity(0.62), lineWidth: CardStyle.borderWidth)
            }
        }
        .padding(Layout.containerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.bgSheet)
    }
}

private extension ReadCalendarMonthRecordPlaceholderSheet {
    var monthTitle: String {
        let year = Calendar.current.component(.year, from: monthStart)
        let month = Calendar.current.component(.month, from: monthStart)
        return "\(year)年\(month)月"
    }
}
