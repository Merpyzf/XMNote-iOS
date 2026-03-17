/**
 * [INPUT]: 依赖 TimelineRelevantEvent 数据模型、TimelineCardHeaderBar/TimelineCardDivider/TimelineCardFooterRow 共享骨架、CardContainer 容器、DesignTokens 设计令牌、ExpandableRichText 可展开富文本、XMJXImageWall/XMJXGalleryItem 图片墙
 * [OUTPUT]: 对外提供 TimelineRelevantCard（时间线相关内容卡片）
 * [POS]: Reading/Timeline 页面私有子视图，按书摘骨架渲染相关内容标题、HTML 正文、图片墙与分类/链接尾部行
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线相关内容卡片，对齐书摘结构展示头部、标题、正文、图片墙与分类/链接尾部信息。
struct TimelineRelevantCard: View {
    let event: TimelineRelevantEvent
    let timestamp: Int64
    let bookName: String

    var body: some View {
        CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                TimelineCardHeaderBar(
                    iconSystemName: "tray.full",
                    timestamp: timestamp,
                    bookName: bookName
                )

                TimelineCardDivider()

                if hasTitle {
                    Text(trimmedTitle)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if hasDisplayContent {
                    contentView
                }

                if !event.imageURLs.isEmpty {
                    imageWall
                }

                if showsFooterRow {
                    TimelineCardFooterRow(
                        tagTitle: trimmedCategoryTitle,
                        linkURLString: showsLinkButton ? trimmedURL : nil,
                        linkAccessibilityLabel: "打开相关内容链接"
                    )
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - Content Logic

    private var trimmedTitle: String {
        TimelineMeaningfulText.trimmedText(event.title)
    }

    private var trimmedURL: String {
        TimelineMeaningfulText.trimmedText(event.url)
    }

    private var trimmedCategoryTitle: String {
        TimelineMeaningfulText.trimmedText(event.categoryTitle)
    }

    private var hasTitle: Bool {
        !trimmedTitle.isEmpty
    }

    private var hasMeaningfulHTMLContent: Bool {
        TimelineMeaningfulText.hasMeaningfulHTML(event.content)
    }

    /// 对齐 Android：仅当标题、正文、图片都不可展示且 URL 存在时，才把 URL 作为正文回填。
    private var contentFallbackToURL: Bool {
        !hasTitle && !hasMeaningfulHTMLContent && event.imageURLs.isEmpty && !trimmedURL.isEmpty
    }

    private var hasDisplayContent: Bool {
        hasMeaningfulHTMLContent || contentFallbackToURL
    }

    private var showsFooterRow: Bool {
        !trimmedCategoryTitle.isEmpty || showsLinkButton
    }

    /// Android 规则：URL 被正文兜底消费时，底部不再显示链接按钮。
    private var showsLinkButton: Bool {
        !trimmedURL.isEmpty && !contentFallbackToURL
    }

    // MARK: - Content View

    /// URL fallback 用纯文本，正常内容用可展开 HTML 富文本。
    @ViewBuilder
    private var contentView: some View {
        if contentFallbackToURL {
            Text(trimmedURL)
                .font(TimelineTypography.eventFallbackTextFont)
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(TimelineTypography.eventRichTextLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ExpandableRichText(
                html: event.content,
                baseFont: TimelineTypography.eventRichTextBaseFont,
                lineSpacing: TimelineTypography.eventRichTextLineSpacing
            )
            .equatable()
        }
    }

    // MARK: - Image Wall

    private var imageWall: some View {
        XMJXImageWall(
            items: event.imageURLs.enumerated().map { index, url in
                XMJXGalleryItem(id: "relevant-img-\(index)", thumbnailURL: url, originalURL: url)
            },
            columnCount: 3
        )
    }
}

#Preview {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        ScrollView {
            VStack(spacing: Spacing.base) {
                TimelineRelevantCard(
                    event: TimelineRelevantEvent(
                        contentId: 1,
                        categoryId: 11,
                        title: " 作者的 TED 演讲 ",
                        content: "关于创造力与约束之间关系的<b>精彩</b>演讲",
                        url: "https://example.com",
                        categoryTitle: "延伸阅读",
                        imageURLs: ["https://picsum.photos/300/200"]
                    ),
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    bookName: "创新者的窘境"
                )
                TimelineRelevantCard(
                    event: TimelineRelevantEvent(
                        contentId: 2,
                        categoryId: 12,
                        title: " ",
                        content: "<p><br></p>",
                        url: "https://example.com/article",
                        categoryTitle: "参考资料",
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
