/**
 * [INPUT]: 依赖 TimelineRelevantBookEvent 数据模型、TimelineCardMetaLine、XMBookCover 封面、CardContainer 容器、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineRelevantBookCard 与 TimelineRelatedBookMetadata，统一时间线和当日轨迹的相关书籍语义
 * [POS]: Reading/Timeline 页面共享子视图，渲染关联目标书封面、书籍信息、固定领域类型与来源书说明
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线相关书籍卡片，以关联目标书为主内容，并明确固定类型与来源书关系。
struct TimelineRelevantBookCard: View {
    let event: TimelineRelevantBookEvent
    let timestamp: Int64
    let bookName: String

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                TimelineCardMetaLine(timestamp: timestamp, bookName: "")

                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover.fixedWidth(
                        48,
                        urlString: event.contentBookCover,
                        border: .init(color: .surfaceBorderDefault, width: StrokeWidth.hairline),
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

                    Spacer(minLength: 0)
                }

                TimelineRelatedBookMetadata(sourceBookName: bookName)
            }
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("相关书籍《\(displayBookName)》，类型，书籍，关联自《\(displaySourceBookName)》")
    }

    private var displayBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(event.contentBookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }

    private var displayBookAuthor: String {
        TimelineMeaningfulText.trimmedText(event.contentBookAuthor)
    }

    private var displaySourceBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(bookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }
}

/// 相关书籍的固定类型与来源说明，采用普通辅助文字避免被误读为状态或按钮。
struct TimelineRelatedBookMetadata: View {
    let sourceBookName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text("相关 • 书籍")
                .font(ReadingContentTypography.metadata)
                .foregroundStyle(Color.textSecondary)

            Text("关联自《\(displaySourceBookName)》")
                .font(ReadingContentTypography.metadata)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    private var displaySourceBookName: String {
        let trimmed = TimelineMeaningfulText.trimmedText(sourceBookName)
        return trimmed.isEmpty ? "未命名书籍" : trimmed
    }
}

#Preview {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        TimelineRelevantBookCard(
            event: TimelineRelevantBookEvent(
                contentBookId: 88,
                contentBookName: "思考快与慢",
                contentBookAuthor: "丹尼尔·卡尼曼",
                contentBookCover: ""
            ),
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            bookName: "创新者的窘境"
        )
        .padding(.horizontal, Spacing.screenEdge)
    }
}
