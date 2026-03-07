/**
 * [INPUT]: 依赖 TimelineRelevantBookEvent 数据模型、TimelineCardMetaLine、XMBookCover 封面、CardContainer 容器、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineRelevantBookCard（时间线相关书籍卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染被关联书籍封面+信息+分类标签
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线相关书籍卡片，展示被关联书籍的封面、书名/作者与固定"书"标签。
struct TimelineRelevantBookCard: View {
    let event: TimelineRelevantBookEvent
    let timestamp: Int64
    let bookName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            CardContainer {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    TimelineCardMetaLine(timestamp: timestamp, bookName: bookName)

                    HStack(alignment: .top, spacing: Spacing.screenEdge) {
                        XMBookCover.fixedWidth(
                            54,
                            urlString: event.contentBookCover,
                            border: .init(color: .cardBorder, width: CardStyle.borderWidth)
                        )

                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text(event.contentBookName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)

                            Text(event.contentBookAuthor)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                }
                .padding(Spacing.contentEdge)
            }

            categoryTag
        }
    }

    // MARK: - Category Tag

    private var categoryTag: some View {
        Text(event.categoryTitle)
            .font(.caption2)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Color.tagBackground, in: Capsule())
    }
}

#Preview {
    ZStack {
        Color.windowBackground.ignoresSafeArea()
        TimelineRelevantBookCard(
            event: TimelineRelevantBookEvent(
                contentBookName: "思考快与慢",
                contentBookAuthor: "丹尼尔·卡尼曼",
                contentBookCover: "",
                categoryTitle: "书"
            ),
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            bookName: "创新者的窘境"
        )
        .padding(.horizontal, Spacing.screenEdge)
    }
}
