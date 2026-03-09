/**
 * [INPUT]: 依赖 TimelineRelevantEvent 数据模型、TimelineCardMetaLine、CardContainer 容器、DesignTokens 设计令牌、RichText 富文本展示、XMJXImageWall/XMJXGalleryItem 图片墙
 * [OUTPUT]: 对外提供 TimelineRelevantCard（时间线相关内容卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染相关内容标题/HTML 正文/图片墙/链接/分类标签
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线相关内容卡片，展示标题、HTML 富文本正文、图片墙、链接图标与分类标签。
struct TimelineRelevantCard: View {
    let event: TimelineRelevantEvent
    let timestamp: Int64
    let bookName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            CardContainer(cornerRadius: TimelineCalendarStyle.eventCardCornerRadius) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    TimelineCardMetaLine(timestamp: timestamp, bookName: bookName)

                    if !event.title.isEmpty {
                        Text(event.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if hasContent {
                        contentView
                    }

                    if !event.imageURLs.isEmpty {
                        imageWall
                    }

                    if showsLinkButton {
                        linkButton
                    }
                }
                .padding(Spacing.contentEdge)
            }

            if !event.categoryTitle.isEmpty {
                categoryTag
            }
        }
    }

    // MARK: - Content Logic

    /// 标题和内容都空时，URL 作为内容显示
    private var hasContent: Bool {
        !event.content.isEmpty || contentFallbackToURL
    }

    private var contentFallbackToURL: Bool {
        event.title.isEmpty && event.content.isEmpty && !event.url.isEmpty
    }

    /// 链接按钮仅在有 URL 且未被 fallback 为内容时显示
    private var showsLinkButton: Bool {
        !event.url.isEmpty && !contentFallbackToURL
    }

    // MARK: - Content View

    /// URL fallback 用纯文本，正常内容用 HTML 富文本
    @ViewBuilder
    private var contentView: some View {
        if contentFallbackToURL {
            Text(event.url)
                .font(TimelineTypography.eventFallbackTextFont)
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(TimelineTypography.eventRichTextLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            RichText(
                html: event.content,
                baseFont: TimelineTypography.eventRichTextBaseFont,
                lineSpacing: TimelineTypography.eventRichTextLineSpacing
            )
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

    // MARK: - Link Button

    private var linkButton: some View {
        HStack {
            Spacer()
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
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
        ScrollView {
            VStack(spacing: Spacing.base) {
                TimelineRelevantCard(
                    event: TimelineRelevantEvent(
                        title: "作者的 TED 演讲",
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
                        title: "",
                        content: "",
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
