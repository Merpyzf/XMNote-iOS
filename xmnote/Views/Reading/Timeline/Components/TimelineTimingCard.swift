/**
 * [INPUT]: 依赖 TimelineReadTimingEvent/ReadDurationFormatter 数据模型、TimelineCardMetaLine、XMBookCover 封面、CardContainer 容器、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineTimingCard（时间线阅读计时卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染书籍封面+时长徽章
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线阅读计时卡片，展示书籍封面、书名/作者与阅读时长胶囊徽章。
struct TimelineTimingCard: View {
    let event: TimelineReadTimingEvent
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
                        border: .init(color: .cardBorder, width: CardStyle.borderWidth)
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

                    durationBadge
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - Duration Badge

    private var durationBadge: some View {
        Text(ReadDurationFormatter.format(seconds: event.elapsedSeconds))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Color.brand, in: Capsule())
    }
}

#Preview {
    ZStack {
        Color.windowBackground.ignoresSafeArea()
        TimelineTimingCard(
            event: TimelineReadTimingEvent(
                elapsedSeconds: 6300,
                startTime: 0, endTime: 0, fuzzyReadDate: 0
            ),
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            bookName: "人类简史",
            bookAuthor: "尤瓦尔·赫拉利",
            bookCover: ""
        )
        .padding(.horizontal, Spacing.screenEdge)
    }
}
