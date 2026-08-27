import SwiftUI

/**
 * [INPUT]: 依赖目标月份与回调事件，依赖 ReadCalendarTheme 与 DesignTokens 提供视觉语义
 * [OUTPUT]: 对外提供使用中性占位图标的 ReadCalendarMonthRecordPlaceholderSheet（月度阅读记录占位弹层）
 * [POS]: ReadCalendar 业务模块 Sheet，占位承接“点击月份进入当月阅读记录页”的后续能力
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 月度阅读记录占位弹层，当前用于承接未完成能力并提供月总结入口。
struct ReadCalendarMonthRecordPlaceholderSheet: View {
    private enum Layout {
        static let containerPadding: CGFloat = Spacing.contentEdge
        static let contentSpacing: CGFloat = Spacing.base
        static let iconSize: CGFloat = 32
        static let cardPadding: CGFloat = Spacing.base
        static let cardCornerRadius: CGFloat = CornerRadius.containerMedium
        static let buttonHeight: CGFloat = InteractionMetrics.minimumTouchTarget
    }

    let monthStart: Date
    let onOpenMonthSummary: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: "\(monthTitle)阅读记录",
            onClose: { dismiss() },
            bottomBar: {
                Button {
                    onOpenMonthSummary(monthStart)
                } label: {
                    Text("查看当月总结")
                        .font(AppTypography.subheadlineSemibold)
                        .frame(maxWidth: .infinity, minHeight: Layout.buttonHeight)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.cozy)
            }
        ) {
            VStack(spacing: Spacing.cozy) {
                Image(systemName: "book.pages")
                    .font(.system(size: Layout.iconSize, weight: .medium))
                    .foregroundStyle(Color.iconSecondary)

                Text("当月阅读记录页正在接入，当前可先查看该月总结")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(Layout.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .fill(Color.surfaceNested)
            )

            .padding(Layout.containerPadding)
        }
    }
}

private extension ReadCalendarMonthRecordPlaceholderSheet {
    var monthTitle: String {
        let year = Calendar.current.component(.year, from: monthStart)
        let month = Calendar.current.component(.month, from: monthStart)
        return "\(year)年\(month)月"
    }
}
