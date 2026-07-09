/**
 * [INPUT]: 依赖 NoteReviewCardItem 与 NoteReviewSettings，复用 RichText、XMRemoteImage 和 NoteExcerptTypography
 * [OUTPUT]: 对外提供 NoteReviewCardView，渲染书摘回顾卡片内容
 * [POS]: Note 模块页面私有子视图，被 NoteReviewView 的卡堆内容闭包消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘回顾卡片内容，负责正文、想法、附图、标签摘要与来源信息的阅读排版。
struct NoteReviewCardView: View {
    let item: NoteReviewCardItem
    let settings: NoteReviewSettings

    @Environment(\.noteReviewPagingCardContentVisibility) private var cardContentVisibility

    var body: some View {
        VStack(spacing: Spacing.none) {
            ScrollView {
                reviewBodySection
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .padding(.horizontal, NoteReviewCardLayout.horizontalPadding)
                    .padding(.top, contentTopPadding)
                    .padding(.bottom, NoteReviewCardLayout.bodyBottomPadding)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .xmScrollEdgeWash(
                edges: [.top, .bottom],
                style: XMScrollEdgeWashStyle(
                    height: NoteReviewCardLayout.scrollEdgeWashHeight,
                    strength: .subtle,
                    surface: .custom(settings.palette.scrollEdgeWashSurfaceColor)
                )
            )
            .opacity(cardContentVisibility.bodyOpacity)

            bookFooterSection
                .padding(.horizontal, NoteReviewCardLayout.horizontalPadding)
                .padding(.bottom, NoteReviewCardLayout.bottomPadding)
                .opacity(cardContentVisibility.footerOpacity)
        }
        .background(settings.palette.backgroundStyle)
        .compositingGroup()
        .clipShape(cardShape)
        .overlay {
            cardShape
                .stroke(settings.palette.cardBorderColor, lineWidth: NoteReviewCardLayout.borderWidth)
        }
        .shadow(
            color: Color.black.opacity(NoteReviewCardLayout.shadowOpacity),
            radius: NoteReviewCardLayout.shadowRadius,
            x: 0,
            y: NoteReviewCardLayout.shadowYOffset
        )
        .accessibilityElement(children: .combine)
    }

    private var bookFooterSection: some View {
        HStack(alignment: .center, spacing: NoteReviewCardLayout.footerContentSpacing) {
            XMBookCover.fixedWidth(
                NoteReviewCardLayout.footerCoverWidth,
                urlString: item.bookCoverURL,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: settings.palette.textColor.opacity(NoteReviewCardLayout.coverBorderOpacity), width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: NoteReviewCardLayout.footerTextSpacing) {
                Text(bookTitle)
                    .font(NoteReviewCardTypography.footerTitle)
                    .foregroundStyle(settings.palette.textColor.opacity(NoteReviewCardLayout.footerTitleOpacity))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)

                if !bookAuthor.isEmpty {
                    Text(bookAuthor)
                        .font(NoteReviewCardTypography.footerAuthor)
                        .foregroundStyle(settings.palette.secondaryTextColor)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, NoteReviewCardLayout.footerTopPadding)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(settings.palette.footerDividerColor)
                .frame(height: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
    }

    private var reviewBodySection: some View {
        VStack(alignment: settings.textAlignment.horizontalAlignment, spacing: NoteReviewCardLayout.bodySectionSpacing) {
            contentSection
            ideaSection
            imageSection
            tagSection
        }
        .frame(maxWidth: NoteReviewCardLayout.textColumnMaxWidth, alignment: frameAlignment)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    @ViewBuilder
    private var contentSection: some View {
        if !item.contentHTML.isEmpty {
            RichText(
                html: item.contentHTML,
                baseFont: NoteReviewCardTypography.body,
                textColor: settings.palette.uiBodyTextColor,
                lineSpacing: NoteReviewCardTypography.bodyLineSpacing,
                textAlignment: settings.textAlignment.nsTextAlignment
            )
            .frame(maxWidth: NoteReviewCardLayout.textColumnMaxWidth, alignment: frameAlignment)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }

    @ViewBuilder
    private var ideaSection: some View {
        if !item.ideaHTML.isEmpty {
            RichText(
                html: item.ideaHTML,
                baseFont: NoteReviewCardTypography.idea,
                textColor: settings.palette.uiSupplementTextColor,
                lineSpacing: NoteReviewCardTypography.ideaLineSpacing,
                textAlignment: settings.textAlignment.nsTextAlignment
            )
            .padding(.vertical, NoteReviewCardLayout.ideaVerticalPadding)
            .padding(.leading, NoteReviewCardLayout.ideaLeadingPadding)
            .padding(.trailing, NoteReviewCardLayout.ideaTrailingPadding)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(settings.palette.textColor.opacity(NoteReviewCardLayout.ideaRuleOpacity))
                    .frame(width: NoteReviewCardLayout.ideaRuleWidth)
            }
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        if !item.imageURLs.isEmpty {
            NoteReviewImageCollage(
                imageURLs: item.imageURLs,
                namespace: "note-review-\(item.id)",
                palette: settings.palette
            )
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }

    @ViewBuilder
    private var tagSection: some View {
        if !item.tags.isEmpty {
            NoteReviewCardTagRail(
                tags: item.tags.map(\.title),
                foreground: settings.palette.secondaryTextColor,
                background: settings.palette.textColor.opacity(0.06),
                alignment: frameAlignment
            )
            .padding(.top, Spacing.half)
            .transition(.opacity)
        }
    }

    private var bookTitle: String {
        item.bookTitle.isEmpty ? "未知书籍" : item.bookTitle
    }

    private var bookAuthor: String {
        item.bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var contentTopPadding: CGFloat {
        isCompactPosterContent ? NoteReviewCardLayout.compactContentTopPadding : NoteReviewCardLayout.topPadding
    }

    private var isCompactPosterContent: Bool {
        item.ideaHTML.isEmpty
            && item.imageURLs.isEmpty
            && item.tags.isEmpty
            && item.contentHTML.count <= NoteReviewCardLayout.compactTextCharacterLimit
    }

    private var frameAlignment: Alignment {
        switch settings.textAlignment {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NoteReviewCardLayout.cornerRadius, style: .continuous)
    }
}

/// 回顾卡片内部的页面级字体包装，保持书摘文字系统基线但微调来源信息层级。
private enum NoteReviewCardTypography {
    static let body = AppTypography.uiFixed(
        baseSize: 17,
        textStyle: .body,
        minimumPointSize: 17
    )
    static let bodyLineSpacing: CGFloat = 8.5
    static let idea = AppTypography.uiFixed(
        baseSize: 14,
        textStyle: .callout,
        minimumPointSize: 14
    )
    static let ideaLineSpacing: CGFloat = 5
    static let footerTitle = AppTypography.fixed(
        baseSize: 13,
        relativeTo: .footnote,
        weight: .semibold,
        minimumPointSize: 13
    )
    static let footerAuthor = AppTypography.fixed(
        baseSize: 11,
        relativeTo: .caption2,
        weight: .regular,
        minimumPointSize: 11
    )
}

/// 回顾卡片布局常量，控制阅读纸面比例、来源区托底和正文内边距。
enum NoteReviewCardLayout {
    static let horizontalPadding: CGFloat = Spacing.comfortable
    static let textColumnMaxWidth: CGFloat = 340
    static let topPadding = Spacing.double
    static let compactContentTopPadding: CGFloat = 34
    static let bottomPadding = Spacing.contentEdge
    static let cornerRadius = CornerRadius.containerXL
    static let borderWidth: CGFloat = 0.75
    static let shadowOpacity = 0.052
    static let shadowRadius: CGFloat = 22
    static let shadowYOffset: CGFloat = 12
    static let bodyBottomPadding = Spacing.cozy
    static let compactTextCharacterLimit = 130
    static let bodySectionSpacing = Spacing.cozy
    static let footerContentSpacing = Spacing.cozy
    static let footerTextSpacing = Spacing.tiny
    static let footerTopPadding = Spacing.cozy
    static let footerCoverWidth: CGFloat = 36
    static let scrollEdgeWashHeight: CGFloat = 30
    static let coverBorderOpacity = 0.12
    static let footerTitleOpacity = 0.92
    static let ideaVerticalPadding = Spacing.half
    static let ideaLeadingPadding = Spacing.base
    static let ideaTrailingPadding = Spacing.half
    static let ideaRuleWidth: CGFloat = 2
    static let ideaRuleOpacity = 0.18
    static let imageWallSpacing = Spacing.half
    static let imageWallCornerRadius = CornerRadius.blockSmall
    static let imageWallSingleAspect: CGFloat = 1.62
    static let imageWallMosaicAspect: CGFloat = 1.48
    static let imageWallBorderOpacity = 0.11
    static let imageWallPlaceholderOpacity = 0.08
    static let imageWallOverlayOpacity = 0.34

    static func readableContentWidth(forCardWidth cardWidth: CGFloat) -> CGFloat {
        min(textColumnMaxWidth, max(0, cardWidth - horizontalPadding * 2))
    }
}

private struct NoteReviewImageCollage: View {
    let imageURLs: [String]
    let namespace: String
    let palette: NoteReviewPalette

    @State private var host: XMJXPhotoBrowserHost
    @State private var tapSequence = 0
    @State private var wallID: String

    private let galleryItems: [XMJXGalleryItem]

    /// 初始化卡片内图片拼贴，并为 JX 浏览器准备稳定的缩略图数据源。
    init(imageURLs: [String], namespace: String, palette: NoteReviewPalette) {
        self.imageURLs = imageURLs
        self.namespace = namespace
        self.palette = palette
        let items = imageURLs.enumerated().map { index, url in
            XMJXGalleryItem(
                id: "\(namespace)-image-\(index)",
                thumbnailURL: url,
                originalURL: url
            )
        }
        self.galleryItems = items
        _host = State(initialValue: XMJXPhotoBrowserHost(initialItems: items))
        _wallID = State(initialValue: "\(namespace)-wall")
    }

    var body: some View {
        collageContent
            .task {
                host.updateItems(galleryItems)
            }
            .onChange(of: galleryItems) { _, newValue in
                host.updateItems(newValue)
            }
    }

    @ViewBuilder
    private var collageContent: some View {
        switch galleryItems.count {
        case 0:
            EmptyView()
        case 1:
            tile(at: 0)
                .aspectRatio(NoteReviewCardLayout.imageWallSingleAspect, contentMode: .fit)
        case 2:
            HStack(spacing: NoteReviewCardLayout.imageWallSpacing) {
                tile(at: 0)
                    .aspectRatio(1, contentMode: .fit)
                tile(at: 1)
                    .aspectRatio(1, contentMode: .fit)
            }
        case 3:
            threeImageMosaic
                .aspectRatio(NoteReviewCardLayout.imageWallMosaicAspect, contentMode: .fit)
        default:
            fourImageMosaic
                .aspectRatio(NoteReviewCardLayout.imageWallMosaicAspect, contentMode: .fit)
        }
    }

    private var threeImageMosaic: some View {
        GeometryReader { proxy in
            let spacing = NoteReviewCardLayout.imageWallSpacing
            let width = proxy.size.width
            let height = proxy.size.height
            let leadWidth = (width - spacing) * 0.62
            let sideWidth = width - leadWidth - spacing
            let sideHeight = (height - spacing) / 2

            ZStack(alignment: .topLeading) {
                tile(at: 0)
                    .frame(width: leadWidth, height: height)
                tile(at: 1)
                    .frame(width: sideWidth, height: sideHeight)
                    .offset(x: leadWidth + spacing)
                tile(at: 2)
                    .frame(width: sideWidth, height: sideHeight)
                    .offset(x: leadWidth + spacing, y: sideHeight + spacing)
            }
        }
    }

    private var fourImageMosaic: some View {
        GeometryReader { proxy in
            let spacing = NoteReviewCardLayout.imageWallSpacing
            let width = proxy.size.width
            let height = proxy.size.height
            let cellWidth = (width - spacing) / 2
            let cellHeight = (height - spacing) / 2
            let visibleItems = min(galleryItems.count, 4)

            ZStack(alignment: .topLeading) {
                ForEach(0..<visibleItems, id: \.self) { index in
                    let column = CGFloat(index % 2)
                    let row = CGFloat(index / 2)
                    tile(at: index, hiddenCount: index == 3 ? galleryItems.count - 4 : 0)
                        .frame(width: cellWidth, height: cellHeight)
                        .offset(
                            x: column * (cellWidth + spacing),
                            y: row * (cellHeight + spacing)
                        )
                }
            }
        }
    }

    private func tile(at index: Int, hiddenCount: Int = 0) -> some View {
        Button {
            tapSequence += 1
            host.open(at: index, wallID: wallID, tapSequence: tapSequence)
        } label: {
            ZStack {
                XMJXThumbnailView(item: galleryItems[index], registry: host.registry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                if hiddenCount > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(NoteReviewCardLayout.imageWallOverlayOpacity))
                    Text("+\(hiddenCount)")
                        .font(AppTypography.title3Semibold)
                        .foregroundStyle(Color.white)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: NoteReviewCardLayout.imageWallCornerRadius, style: .continuous)
                    .fill(palette.textColor.opacity(NoteReviewCardLayout.imageWallPlaceholderOpacity))
                    .overlay {
                        Image(systemName: "photo")
                            .font(AppTypography.title3)
                            .foregroundStyle(palette.secondaryTextColor)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: NoteReviewCardLayout.imageWallCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NoteReviewCardLayout.imageWallCornerRadius, style: .continuous)
                    .stroke(
                        palette.textColor.opacity(NoteReviewCardLayout.imageWallBorderOpacity),
                        lineWidth: CardStyle.borderWidth
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: NoteReviewCardLayout.imageWallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("预览附图 \(index + 1)，共 \(galleryItems.count) 张")
    }
}

private struct NoteReviewCardTagRail: View {
    let tags: [String]
    let foreground: Color
    let background: Color
    let alignment: Alignment

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.half) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.half)
                        .frame(height: 22)
                        .background(background, in: Capsule())
                }
            }
            .padding(.horizontal, Spacing.micro)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前书摘标签")
    }
}
