/**
 * [INPUT]: 依赖 TimelineCheckInEvent/CheckInAmountLevel 数据模型、TimelineCardMetaLine、XMBookCover 封面、CardContainer 容器、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineCheckInCard 与 ReadingCheckInLevelIndicator，统一时间线和当日轨迹的书籍身份与四级阅读量表达
 * [POS]: Reading/Timeline 页面共享子视图，渲染书籍封面、信息与仅点亮当前档位的四格热力指示器
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线打卡卡片，展示书籍封面、书名/作者与只点亮当前等级的四格阅读量指示器。
struct TimelineCheckInCard: View {
    let event: TimelineCheckInEvent
    let timestamp: Int64
    let bookName: String
    let bookAuthor: String
    let bookCover: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                TimelineCardMetaLine(timestamp: timestamp, bookName: "")

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        bookIdentity
                        levelIndicator
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(alignment: .center, spacing: Spacing.base) {
                        bookIdentity
                            .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
                        levelIndicator
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阅读打卡，阅读量\(level.label)，来源书籍《\(displayBookName)》")
    }

    private var level: CheckInAmountLevel {
        CheckInAmountLevel(amount: Int64(selectedLevel))
    }

    private var selectedLevel: Int {
        min(4, max(1, Int(event.amount)))
    }

    private var bookIdentity: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                48,
                urlString: bookCover,
                border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth),
                placeholderIconSize: .small
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(displayBookName)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                if !displayBookAuthor.isEmpty {
                    Text(displayBookAuthor)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var levelIndicator: some View {
        ReadingCheckInLevelIndicator(selectedLevel: selectedLevel, label: level.label)
            .accessibilityHidden(true)
    }

    private var displayBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(bookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }

    private var displayBookAuthor: String {
        TimelineMeaningfulText.trimmedText(bookAuthor)
    }
}

/// 四枚热力格仅点亮当前阅读量等级，文字标签确保颜色不是唯一的信息通道。
struct ReadingCheckInLevelIndicator: View {
    let selectedLevel: Int
    let label: String

    @ScaledMetric(relativeTo: .caption) private var cellSize = 14.0

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.half) {
            HStack(spacing: Spacing.compact) {
                ForEach(1...4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: CornerRadius.inlayTiny)
                        .fill(color(for: index))
                        .frame(
                            width: min(cellSize, 20),
                            height: min(cellSize, 20)
                        )
                }
            }

            Text(label)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阅读量\(label)")
    }

    private func color(for index: Int) -> Color {
        guard index == min(4, max(1, selectedLevel)),
              let heatmapLevel = HeatmapLevel(rawValue: index) else {
            return .heatmapNone
        }
        return heatmapLevel.color
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
