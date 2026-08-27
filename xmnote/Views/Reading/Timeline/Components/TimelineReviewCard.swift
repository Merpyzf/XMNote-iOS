/**
 * [INPUT]: 依赖 TimelineReviewEvent、TimelineCardPresentationStyle/TimelineBookSourceFooter、CardContainer、DesignTokens、ExpandableRichText、评分与图片墙
 * [OUTPUT]: 对外提供 TimelineReviewCard，支持首页标准头部与每日详情内容优先/来源置底两种排版
 * [POS]: Reading/Timeline 页面私有书评卡片，渲染标题、正文、图片、评分与上下文来源
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线书评卡片，对齐书摘结构展示头部、标题、正文、图片墙与星级评分。
struct TimelineReviewCard: View {
    let event: TimelineReviewEvent
    let timestamp: Int64
    let bookName: String
    var presentationStyle: TimelineCardPresentationStyle = .standard
    var actionColor: Color = .textSecondary
    var onOpenDetail: (() -> Void)? = nil

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if presentationStyle == .standard {
                    TimelineCardHeaderBar(
                        iconSystemName: "bubble.and.pencil",
                        timestamp: timestamp,
                        bookName: bookName,
                        openDetailAccessibilityLabel: "打开书评详情",
                        onOpenDetail: onOpenDetail
                    )
                    TimelineCardDivider()
                }

                if hasTitle {
                    Text(trimmedTitle)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if hasContent {
                    ExpandableRichText(
                        html: event.content,
                        baseFont: contentBodyFont,
                        lineSpacing: contentBodyLineSpacing,
                        actionColor: actionColor
                    )
                    .equatable()
                }

                if !event.imageURLs.isEmpty {
                    imageWall
                }

                if event.bookScore > 0 {
                    starRating
                }

                if presentationStyle == .contentFirst {
                    TimelineBookSourceFooter(bookName: bookName)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var trimmedTitle: String {
        TimelineMeaningfulText.trimmedText(event.title)
    }

    private var hasTitle: Bool {
        !trimmedTitle.isEmpty
    }

    private var hasContent: Bool {
        TimelineMeaningfulText.hasMeaningfulHTML(event.content)
    }

    private var contentBodyFont: UIFont {
        presentationStyle == .contentFirst
            ? ReadingContentTypography.uiBody
            : TimelineTypography.eventRichTextBaseFont
    }

    private var contentBodyLineSpacing: CGFloat {
        presentationStyle == .contentFirst
            ? ReadingContentTypography.bodyLineSpacing
            : TimelineTypography.eventRichTextLineSpacing
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
        XMRatingBar(score: event.bookScore, preset: .listSmall)
    }
}

#Preview {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        ScrollView {
            VStack(spacing: Spacing.base) {
                TimelineReviewCard(
                    event: TimelineReviewEvent(
                        reviewId: 1,
                        title: "  一本改变思维方式的书  ",
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
                        reviewId: 2,
                        title: "   ",
                        content: "<p><br></p>",
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
