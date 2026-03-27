/**
 * [INPUT]: 依赖 TimelineReadStatusEvent/ReadStatusHelper 数据模型、TimelineCardMetaLine、XMBookCover 封面、CardContainer 容器、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineStatusCard（时间线状态变更卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染书籍封面+状态标签+评分
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线状态变更卡片，展示书籍封面、书名/作者、状态标签，已读时显示星级评分。
struct TimelineStatusCard: View {
    let event: TimelineReadStatusEvent
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
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)

                        Text(bookAuthor)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)

                        if showsRating {
                            starRating
                        }
                    }

                    Spacer(minLength: 0)

                    statusBadge
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        Text(ReadStatusHelper.statusName(
            for: event.statusId,
            readDoneCount: event.readDoneCount
        ))
        .font(AppTypography.caption2Medium)
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.compact)
        .background(statusColor, in: Capsule())
    }

    private var statusColor: Color {
        switch event.statusId {
        case 1: .statusWish
        case 2: .statusReading
        case 3: .statusDone
        case 4: .statusAbandoned
        case 5: .statusOnHold
        default: .textHint
        }
    }

    // MARK: - Star Rating

    private var showsRating: Bool {
        event.statusId == 3 && event.bookScore > 0
    }

    private var starRating: some View {
        let score = Double(event.bookScore) / 10.0
        return HStack(spacing: Spacing.tiny) {
            ForEach(1...5, id: \.self) { index in
                starImage(for: index, score: score)
                    .font(AppTypography.caption2)
                    .foregroundStyle(Color.statusDone)
            }
        }
    }

    /// 封装starImage对应的业务步骤，确保调用方可以稳定复用该能力。
    private func starImage(for index: Int, score: Double) -> Image {
        let threshold = Double(index)
        if score >= threshold {
            return Image(systemName: "star.fill")
        } else if score >= threshold - 0.5 {
            return Image(systemName: "star.leadinghalf.filled")
        }
        return Image(systemName: "star")
    }
}

#Preview {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        VStack(spacing: Spacing.base) {
            TimelineStatusCard(
                event: TimelineReadStatusEvent(statusId: 3, readDoneCount: 2, bookScore: 45),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                bookName: "百年孤独", bookAuthor: "马尔克斯", bookCover: ""
            )
            TimelineStatusCard(
                event: TimelineReadStatusEvent(statusId: 1, readDoneCount: 0, bookScore: 0),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                bookName: "深度工作", bookAuthor: "卡尔·纽波特", bookCover: ""
            )
        }
        .padding(.horizontal, Spacing.screenEdge)
    }
}
