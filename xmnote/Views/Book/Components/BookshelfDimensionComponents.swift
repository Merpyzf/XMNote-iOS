/**
 * [INPUT]: 依赖 BookshelfDimension、BookshelfAggregateGroup 等只读书架模型
 * [OUTPUT]: 对外提供 Book 页面私有的维度 rail、聚合卡、搜索栏与默认书架列表行组件
 * [POS]: Book 模块页面私有子视图集合，服务 Phase 2 书架维度骨架，不承担数据读取与写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架维度横向 rail，表达“怎么看书架”，不承载写入动作。
struct BookshelfDimensionRail: View {
    let selectedDimension: BookshelfDimension
    let onSelect: (BookshelfDimension) -> Void
    var trailingPadding: CGFloat = Spacing.screenEdge

    private enum Style {
        static let itemSpacing: CGFloat = Spacing.tight
        static let horizontalPadding: CGFloat = Spacing.tight
        static let verticalPadding: CGFloat = Spacing.none
        static let visualMinHeight: CGFloat = 28
        static let touchMinHeight: CGFloat = 44
        static let railMinHeight: CGFloat = 44
        static let cornerRadius: CGFloat = CornerRadius.blockSmall
        static let unselectedBorderOpacity: Double = 0.18
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Style.itemSpacing) {
                ForEach(BookshelfDimension.allCases, id: \.self) { dimension in
                    let isSelected = selectedDimension == dimension

                    Button {
                        onSelect(dimension)
                    } label: {
                        Text(dimension.title)
                            .font(AppTypography.caption)
                            .fontWeight(isSelected ? .medium : .regular)
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, Style.horizontalPadding)
                            .frame(minHeight: Style.visualMinHeight)
                            .background(
                                isSelected ? Color.brand : Color.surfaceCard,
                                in: RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                                    .stroke(
                                        Color.surfaceBorderSubtle.opacity(isSelected ? 0 : Style.unselectedBorderOpacity),
                                        lineWidth: CardStyle.borderWidth
                                    )
                            }
                            .frame(minHeight: Style.touchMinHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dimension.title)
                }
            }
            .padding(.leading, Spacing.screenEdge)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, Style.verticalPadding)
        }
        .frame(minHeight: Style.railMinHeight)
    }
}

/// 页内搜索栏，搜索只参与只读过滤，不承载排序写入。
struct BookshelfSearchBar: View {
    @Binding var text: String
    var placeholder: String = "搜索书名或作者"
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.compact) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $text)
                    .font(BookshelfTypography.searchField)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                if !text.isEmpty {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: 40)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }

            Button("取消", action: onCancel)
                .font(BookshelfTypography.searchField)
                .foregroundStyle(Color.brand)
                .frame(minHeight: 40)
        }
        .padding(.horizontal, Spacing.screenEdge)
    }
}

/// 标签、来源、作者等聚合维度使用的轻量封面入口。
struct BookshelfAggregateCardView: View {
    let group: BookshelfAggregateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            coverMosaic
            titleContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title)，\(group.subtitle)")
    }

    private var coverMosaic: some View {
        BookshelfGridGroupCoverView(
            covers: group.representativeCovers,
            count: group.count
        )
    }

    @ViewBuilder
    private var titleContent: some View {
        if let ratingScore = group.aggregateRatingScore {
            ratingTitle(for: ratingScore)
        } else {
            Text(group.title)
                .font(BookshelfTypography.gridTitle)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
        }
    }

    private func ratingTitle(for score: Int64) -> some View {
        HStack(spacing: Spacing.compact) {
            if score > 0 {
                XMRatingBar(score: score, preset: .listSmall)
                    .accessibilityHidden(true)

                Text(score.aggregateRatingTitle)
                    .font(BookshelfTypography.gridTitle)
                    .foregroundStyle(Color.ratingActive)
                    .lineLimit(1)
            } else {
                Image(systemName: "star")
                    .font(BookshelfTypography.gridTitle)
                    .foregroundStyle(Color.textHint)
                    .accessibilityHidden(true)

                Text(group.title)
                    .font(BookshelfTypography.gridTitle)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 聚合分组语义展示信息，统一管理维度图标和语义色。
private struct BookshelfAggregateSemanticPresentation {
    let systemImage: String
    let color: Color
}

private extension BookshelfAggregateGroup {
    var aggregateRatingScore: Int64? {
        guard case .rating(let score) = context else { return nil }
        return score
    }
}

private extension Int64 {
    var aggregateRatingValue: Double {
        Swift.min(Swift.max(Double(self) / 10.0, 0), 5)
    }

    var aggregateRatingTitle: String {
        String(format: "%.1f", aggregateRatingValue)
    }
}

/// 聚合维度列表模式卡片，使用标题信息与书封横排帮助用户快速识别分组。
struct BookshelfAggregateListRowView: View {
    let group: BookshelfAggregateGroup

    private enum Style {
        static let iconFrame: CGFloat = 24
        static let maxPreviewCovers = 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            header
            BookshelfAggregateCoverShelfView(
                covers: group.representativeCovers,
                maxVisibleCovers: Style.maxPreviewCovers
            )
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: cardShape)
        .overlay {
            cardShape
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .contentShape(cardShape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var header: some View {
        HStack(spacing: Spacing.tight) {
            headerLeadingContent

            Spacer(minLength: Spacing.tight)

            Text(countText)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .monospacedDigit()
                .padding(.horizontal, Spacing.half)
                .padding(.vertical, Spacing.micro)
                .background(Color.surfaceNested, in: Capsule())

            chevron
        }
        .frame(maxWidth: .infinity, minHeight: Style.iconFrame, alignment: .leading)
    }

    @ViewBuilder
    private var headerLeadingContent: some View {
        if let ratingScore = group.aggregateRatingScore {
            ratingHeader(for: ratingScore)
        } else {
            Image(systemName: semanticPresentation.systemImage)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(semanticPresentation.color)
                .frame(width: Style.iconFrame, height: Style.iconFrame)
                .accessibilityHidden(true)

            Text(group.title)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private func ratingHeader(for score: Int64) -> some View {
        HStack(spacing: Spacing.compact) {
            if score > 0 {
                XMRatingBar(score: score, preset: .listSmall)
                    .accessibilityHidden(true)

                Text(score.aggregateRatingTitle)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.ratingActive)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Image(systemName: "star")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textHint)
                    .frame(width: Style.iconFrame, height: Style.iconFrame)
                    .accessibilityHidden(true)

                Text(group.title)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(AppTypography.captionSemibold)
            .foregroundStyle(Color.textHint)
            .accessibilityHidden(true)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
    }

    private var countText: String {
        "\(group.count)本"
    }

    private var accessibilityText: String {
        guard !group.subtitle.isEmpty,
              group.subtitle != countText else {
            return "\(group.title)，\(countText)"
        }
        return "\(group.title)，\(countText)，\(group.subtitle)"
    }

    private var semanticPresentation: BookshelfAggregateSemanticPresentation {
        switch group.context {
        case .readStatus(let statusID):
            return readingStatusPresentation(for: statusID)
        case .rating(let score):
            return BookshelfAggregateSemanticPresentation(
                systemImage: "star",
                color: score > 0 ? .ratingActive : .textHint
            )
        case .tag:
            return BookshelfAggregateSemanticPresentation(systemImage: "tag", color: .brand)
        case .source:
            return BookshelfAggregateSemanticPresentation(systemImage: "tray", color: .statusReading)
        case .author:
            return BookshelfAggregateSemanticPresentation(systemImage: "person.text.rectangle", color: .textSecondary)
        case .press:
            return BookshelfAggregateSemanticPresentation(systemImage: "building.columns", color: .textSecondary)
        case .defaultGroup:
            return BookshelfAggregateSemanticPresentation(systemImage: "books.vertical", color: .textSecondary)
        }
    }

    private func readingStatusPresentation(for statusID: Int64?) -> BookshelfAggregateSemanticPresentation {
        guard let statusID,
              let status = BookEntryReadingStatus(rawValue: statusID) else {
            return BookshelfAggregateSemanticPresentation(systemImage: "circle.dotted", color: .textHint)
        }

        return status.bookshelfAggregatePresentation
    }
}

/// 聚合分组列表模式中的封面托盘，让代表书封形成一组可扫描的书架索引。
private struct BookshelfAggregateCoverShelfView: View {
    let covers: [String]
    var maxVisibleCovers = 5

    private enum Style {
        static let targetCoverWidth: CGFloat = 52
        static let minimumCoverWidth: CGFloat = 42
        static let coverSpacing: CGFloat = Spacing.cozy
        static let horizontalPadding: CGFloat = Spacing.tight
        static let verticalPadding: CGFloat = Spacing.half
        static let shelfHeight: CGFloat = XMBookCover.height(forWidth: targetCoverWidth) + verticalPadding * 2
        static let placeholderSpines: [(width: CGFloat, heightRatio: CGFloat, opacity: Double)] = [
            (8, 0.72, 0.28),
            (10, 0.88, 0.34),
            (7, 0.64, 0.24),
            (9, 0.80, 0.30),
            (11, 0.92, 0.36)
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            let coverWidth = resolvedCoverWidth(for: proxy.size.width)

            shelfContent(coverWidth: coverWidth)
                .padding(.horizontal, Style.horizontalPadding)
                .padding(.vertical, Style.verticalPadding)
                .frame(maxWidth: .infinity, minHeight: Style.shelfHeight, alignment: .bottomLeading)
                .background(Color.surfaceNested, in: shelfShape)
                .overlay {
                    shelfShape
                        .stroke(Color.surfaceBorderSubtle.opacity(0.45), lineWidth: CardStyle.borderWidth)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.surfaceBorderSubtle.opacity(0.22))
                        .frame(height: CardStyle.borderWidth)
                        .padding(.horizontal, Style.horizontalPadding)
                }
        }
        .frame(height: Style.shelfHeight)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func shelfContent(coverWidth: CGFloat) -> some View {
        if previewCovers.isEmpty {
            emptyShelf(coverWidth: coverWidth)
        } else {
            HStack(alignment: .bottom, spacing: Style.coverSpacing) {
                ForEach(previewCovers) { cover in
                    previewCover(cover.urlString, width: coverWidth)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func previewCover(_ cover: String, width: CGFloat) -> some View {
        XMBookCover.fixedWidth(
            width,
            urlString: cover,
            cornerRadius: CornerRadius.inlaySmall,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: cover.isEmpty ? .hidden : .small,
            surfaceStyle: .spine
        )
    }

    private func emptyShelf(coverWidth: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: Spacing.compact) {
            ForEach(Array(Style.placeholderSpines.enumerated()), id: \.offset) { _, spine in
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceBorderSubtle.opacity(spine.opacity))
                    .frame(
                        width: spine.width,
                        height: XMBookCover.height(forWidth: coverWidth) * spine.heightRatio
                    )
            }

            Spacer(minLength: 0)
        }
    }

    private func resolvedCoverWidth(for containerWidth: CGFloat) -> CGFloat {
        let visibleCount = CGFloat(max(1, maxVisibleCovers))
        let horizontalPadding = Style.horizontalPadding * 2
        let spacing = Style.coverSpacing * max(0, visibleCount - 1)
        let availableWidth = max(0, containerWidth - horizontalPadding - spacing)
        let fittingWidth = availableWidth / visibleCount
        return min(Style.targetCoverWidth, max(Style.minimumCoverWidth, fittingWidth))
    }

    private var previewCovers: [CoverPreview] {
        covers
            .prefix(maxVisibleCovers)
            .enumerated()
            .map { CoverPreview(id: $0.offset, urlString: $0.element) }
    }

    private var shelfShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
    }

    private struct CoverPreview: Identifiable {
        let id: Int
        let urlString: String
    }
}

private extension BookEntryReadingStatus {
    var bookshelfAggregatePresentation: BookshelfAggregateSemanticPresentation {
        switch self {
        case .wantRead:
            return BookshelfAggregateSemanticPresentation(systemImage: "heart", color: .statusWish)
        case .reading:
            return BookshelfAggregateSemanticPresentation(systemImage: "book", color: .statusReading)
        case .finished:
            return BookshelfAggregateSemanticPresentation(systemImage: "checkmark.circle", color: .statusDone)
        case .abandoned:
            return BookshelfAggregateSemanticPresentation(systemImage: "xmark.circle", color: .statusAbandoned)
        case .onHold:
            return BookshelfAggregateSemanticPresentation(systemImage: "archivebox", color: .statusOnHold)
        }
    }
}

/// 默认维度列表模式行，作为显示设置的只读 UI 替代形态。
struct BookshelfDefaultListRow: View {
    let item: BookshelfItem
    var showsNoteCount = true
    var titleDisplayMode: BookshelfTitleDisplayMode = .standard

    var body: some View {
        HStack(spacing: Spacing.base) {
            thumbnail

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                BookshelfTitleText(
                    text: item.title,
                    mode: titleDisplayMode,
                    style: .bodyMedium,
                    color: .textPrimary
                )

                Text(subtitle)
                    .font(BookshelfTypography.gridSubtitle)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.compact)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.content {
        case .book(let book):
            XMBookCover.responsive(
                urlString: book.cover,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )
            .frame(width: 44)
        case .group(let group):
            BookshelfGroupGridItemView(
                group: group,
                titleDisplayMode: titleDisplayMode
            )
                .frame(width: 48)
        }
    }

    private var subtitle: String {
        switch item.content {
        case .book(let book):
            if showsNoteCount, book.noteCount > 0 {
                return book.author.isEmpty ? "\(book.noteCount)条书摘" : "\(book.author) · \(book.noteCount)条书摘"
            }
            return book.author.isEmpty ? " " : book.author
        case .group(let group):
            return "\(group.bookCount)本"
        }
    }
}
