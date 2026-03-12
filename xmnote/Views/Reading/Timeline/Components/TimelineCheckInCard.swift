/**
 * [INPUT]: 依赖 TimelineCheckInEvent/CheckInAmountLevel 数据模型、TimelineCardMetaLine、XMBookCover 封面、CardContainer 容器、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineCheckInCard（时间线打卡卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染书籍封面+阅读量级别徽章
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线打卡卡片，展示书籍封面、书名/作者与 4 级阅读量胶囊徽章。
struct TimelineCheckInCard: View {
    let event: TimelineCheckInEvent
    let timestamp: Int64
    let bookName: String
    let bookAuthor: String
    let bookCover: String

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                TimelineCardMetaLine(timestamp: timestamp, bookName: "")

                HStack(alignment: .top, spacing: Spacing.screenEdge) {
                    XMBookCover.fixedWidth(
                        54,
                        urlString: bookCover,
                        border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                    )

                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text(bookName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)

                        Text(bookAuthor)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    amountBadge
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - Amount Badge

    private var level: CheckInAmountLevel {
        CheckInAmountLevel(amount: event.amount)
    }

    private var amountBadge: some View {
        Text(level.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(amountColor, in: Capsule())
    }

    /// 4 级绿色梯度，对齐 Android ChartHelper.getColorsForDataLevel
    private var amountColor: Color {
        switch level {
        case .veryLess: Color(hex: 0x9BE9A8)
        case .less: Color(hex: 0x40C463)
        case .more: Color(hex: 0x30A14F)
        case .veryMore: Color(hex: 0x226E39)
        }
    }
}

#Preview {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        VStack(spacing: Spacing.base) {
            TimelineCheckInCard(
                event: TimelineCheckInEvent(amount: 1),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                bookName: "原则", bookAuthor: "瑞·达利欧", bookCover: ""
            )
            TimelineCheckInCard(
                event: TimelineCheckInEvent(amount: 4),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                bookName: "刻意练习", bookAuthor: "安德斯·艾利克森", bookCover: ""
            )
        }
        .padding(.horizontal, Spacing.screenEdge)
    }
}
