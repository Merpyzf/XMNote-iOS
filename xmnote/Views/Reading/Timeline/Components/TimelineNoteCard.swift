/**
 * [INPUT]: 依赖 TimelineNoteEvent、TimelineCardPresentationStyle/TimelineBookSourceFooter、CardContainer、DesignTokens、RichTextAppearance、ExpandableRichText 与图片墙
 * [OUTPUT]: 对外提供 TimelineNoteCard，支持首页标准头部与每日详情内容优先/来源置底两种排版
 * [POS]: Reading/Timeline 页面私有书摘卡片，复用正式长文本披露基建渲染摘录、批注、附图、标签与上下文来源
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线书摘卡片，展示富文本摘录、想法、附图、标签和所在页面需要的书籍上下文。
struct TimelineNoteCard: View {
    let event: TimelineNoteEvent
    let timestamp: Int64
    let bookName: String
    var presentationStyle: TimelineCardPresentationStyle = .standard
    var actionColor: Color = .textSecondary
    var quoteColor: UIColor = RichTextAppearance.quoteAccent
    var onOpenDetail: (() -> Void)? = nil

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if presentationStyle == .standard {
                    TimelineCardHeaderBar(
                        iconSystemName: "note.text",
                        timestamp: timestamp,
                        bookName: bookName,
                        fallbackBookTitle: event.bookTitle,
                        openDetailAccessibilityLabel: "打开书摘详情",
                        onOpenDetail: onOpenDetail
                    )
                    TimelineCardDivider()
                }

                excerptSection

                if !event.idea.isEmpty {
                    ideaSection
                }

                if !event.imageURLs.isEmpty {
                    imageWall
                }

                if !event.tagNames.isEmpty {
                    tagsSection
                }

                if presentationStyle == .contentFirst {
                    TimelineBookSourceFooter(
                        bookName: bookName,
                        fallbackBookTitle: event.bookTitle
                    )
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    @ViewBuilder
    private var excerptSection: some View {
        if !event.content.isEmpty {
            ExpandableRichText(
                html: event.content,
                baseFont: primaryBodyFont,
                textColor: .label,
                lineSpacing: primaryBodyLineSpacing,
                actionColor: actionColor,
                quoteColor: quoteColor
            )
        }
    }

    private var ideaSection: some View {
        ExpandableRichText(
            html: event.idea,
            baseFont: ideaBodyFont,
            textColor: UIColor.xmResolved(Color.textSecondary),
            lineSpacing: ideaBodyLineSpacing,
            actionColor: actionColor,
            quoteColor: quoteColor
        )
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.half)
        .background(
            Color.controlFillSecondary.opacity(0.55),
            in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
        )
    }

    private var primaryBodyFont: UIFont {
        presentationStyle == .contentFirst
            ? ReadingContentTypography.uiBody
            : TimelineTypography.eventRichTextBaseFont
    }

    private var primaryBodyLineSpacing: CGFloat {
        presentationStyle == .contentFirst
            ? ReadingContentTypography.bodyLineSpacing
            : TimelineTypography.eventRichTextLineSpacing
    }

    private var ideaBodyFont: UIFont {
        presentationStyle == .contentFirst
            ? ReadingContentTypography.uiAnnotation
            : TimelineTypography.eventRichTextBaseFont
    }

    private var ideaBodyLineSpacing: CGFloat {
        presentationStyle == .contentFirst
            ? ReadingContentTypography.annotationLineSpacing
            : TimelineTypography.eventRichTextLineSpacing
    }

    private var imageWall: some View {
        XMJXImageWall(
            items: event.imageURLs.enumerated().map { index, url in
                XMJXGalleryItem(
                    id: "note-img-\(index)",
                    thumbnailURL: url,
                    originalURL: url
                )
            },
            columnCount: event.imageURLs.count == 1 ? 1 : 3
        )
    }

    private var tagsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.tight) {
                ForEach(Array(event.tagNames.enumerated()), id: \.offset) { _, tag in
                    TimelineInlineTag(text: tag)
                }
            }
            .padding(.vertical, Spacing.hairline)
        }
    }
}

#Preview {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        ScrollView {
            TimelineNoteCard(
                event: TimelineNoteEvent(
                    noteId: 1,
                    content: "人生最大的幸运，就是在年富力强时发现了自己的<b>使命</b>。这段内容继续延伸，用来验证第三行末尾的内联展开与完整正文收起。",
                    idea: "这句话让我想到了乔布斯在斯坦福的演讲。",
                    bookTitle: "活法",
                    imageURLs: [],
                    tagNames: ["方法论", "人生"]
                ),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                bookName: "活法"
            )
            .padding()
        }
    }
}
