/**
 * [INPUT]: 依赖 TimelineReviewEvent 数据模型、TimelineCardMetaLine、CardContainer 容器、DesignTokens 设计令牌、ExpandableRichText 可展开富文本、XMJXImageWall/XMJXGalleryItem 图片墙
 * [OUTPUT]: 对外提供 TimelineReviewCard（时间线书评卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染书评标题、HTML 正文、图片墙与星级评分
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线书评卡片，展示书评标题（粗体）、HTML 富文本正文、图片墙与星级评分。
struct TimelineReviewCard: View {
    let event: TimelineReviewEvent
    let timestamp: Int64
    let bookName: String

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                TimelineCardMetaLine(timestamp: timestamp, bookName: bookName)

                if !event.title.isEmpty {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !event.content.isEmpty {
                    ExpandableRichText(
                        html: event.content,
                        baseFont: TimelineTypography.eventRichTextBaseFont,
                        lineSpacing: TimelineTypography.eventRichTextLineSpacing
                    )
                    .equatable()
                }

                if !event.imageURLs.isEmpty {
                    imageWall
                }

                if event.bookScore > 0 {
                    starRating
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - Image Wall

    private var imageWall: some View {
        XMJXImageWall(
            items: event.imageURLs.enumerated().map { index, url in
                XMJXGalleryItem(id: "review-img-\(index)", thumbnailURL: url, originalURL: url)
            },
            columnCount: 3
        )
    }

    // MARK: - Star Rating

    private var starRating: some View {
        let score = Double(event.bookScore) / 10.0
        return HStack(spacing: Spacing.tiny) {
            ForEach(1...5, id: \.self) { index in
                starImage(for: index, score: score)
                    .font(.caption)
                    .foregroundStyle(Color.statusDone)
            }
        }
    }

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
        Color.windowBackground.ignoresSafeArea()
        ScrollView {
            VStack(spacing: Spacing.base) {
                TimelineReviewCard(
                    event: TimelineReviewEvent(
                        title: "一本改变思维方式的书",
                        content: "作者用大量案例说明了<b>系统思维</b>的重要性，读完之后对复杂问题的分析能力有了显著提升。",
                        bookScore: 40,
                        imageURLs: [
                            "https://picsum.photos/200/300",
                            "https://picsum.photos/201/300",
                        ]
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "系统之美"
                )
                TimelineReviewCard(
                    event: TimelineReviewEvent(
                        title: "",
                        content: "简短书评，没有标题也没有评分。",
                        bookScore: 0,
                        imageURLs: []
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "某本书"
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
    }
}
