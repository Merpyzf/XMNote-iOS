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
