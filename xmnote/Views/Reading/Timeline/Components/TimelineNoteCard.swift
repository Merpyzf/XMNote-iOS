/**
 * [INPUT]: 依赖 TimelineNoteEvent 数据模型、TimelineCardMetaLine、CardContainer 容器、DesignTokens 设计令牌、ExpandableRichText 可展开富文本、XMJXImageWall/XMJXGalleryItem 图片墙
 * [OUTPUT]: 对外提供 TimelineNoteCard（时间线书摘卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染书摘 HTML 正文、用户批注与附图墙
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线书摘卡片，展示 HTML 富文本正文、用户批注（引用块风格）与附图墙。
struct TimelineNoteCard: View {
    let event: TimelineNoteEvent
    let timestamp: Int64
    let bookName: String

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                TimelineCardMetaLine(timestamp: timestamp, bookName: bookName)

                ExpandableRichText(
                    html: event.content,
                    baseFont: TimelineTypography.eventRichTextBaseFont,
                    lineSpacing: TimelineTypography.eventRichTextLineSpacing
                )
                .equatable()

                if !event.idea.isEmpty {
                    ideaSection
                }

                if !event.imageURLs.isEmpty {
                    imageWall
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - Idea

    private var ideaSection: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                .fill(Color.brand.opacity(0.5))
                .frame(width: 2.5)

            ExpandableRichText(
                html: event.idea,
                baseFont: TimelineTypography.eventRichTextBaseFont,
                textColor: .secondaryLabel,
                lineSpacing: TimelineTypography.eventRichTextLineSpacing
            )
            .equatable()
        }
    }

    // MARK: - Image Wall

    private var imageWall: some View {
        XMJXImageWall(
            items: event.imageURLs.enumerated().map { index, url in
                XMJXGalleryItem(id: "note-img-\(index)", thumbnailURL: url, originalURL: url)
            },
            columnCount: event.imageURLs.count == 1 ? 1 : 3
        )
    }
}

#Preview {
    ZStack {
        Color.windowBackground.ignoresSafeArea()
        ScrollView {
            VStack(spacing: Spacing.base) {
                TimelineNoteCard(
                    event: TimelineNoteEvent(
                        content: "人生最大的幸运，就是在年富力强时发现了自己的<b>使命</b>。",
                        idea: "这句话让我想到了乔布斯在斯坦福的演讲",
                        bookTitle: "活法",
                        imageURLs: [
                            "https://picsum.photos/200/300",
                            "https://picsum.photos/201/300",
                            "https://picsum.photos/202/300",
                        ]
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "活法"
                )
                TimelineNoteCard(
                    event: TimelineNoteEvent(
                        content: "我们总是倾向于用最复杂的方式来解决问题，却忽略了最简单的途径往往就在眼前。",
                        idea: "",
                        bookTitle: "思考快与慢",
                        imageURLs: []
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "思考快与慢"
                )
                TimelineNoteCard(
                    event: TimelineNoteEvent(
                        content: "单图书摘测试",
                        idea: "",
                        bookTitle: "测试",
                        imageURLs: ["https://picsum.photos/400/300"]
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "测试"
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
    }
}
