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
                    .font(AppTypography.body)
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
                .font(AppTypography.body)
                .foregroundStyle(Color.brand)
                .frame(minHeight: 40)
        }
        .padding(.horizontal, Spacing.screenEdge)
    }
}

/// 标签、来源、作者等聚合维度使用的两列卡片。
struct BookshelfAggregateCardView: View {
    let group: BookshelfAggregateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            coverMosaic
            Text(group.title)
                .font(AppTypography.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(group.subtitle)
                .font(AppTypography.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Spacing.half)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title)，\(group.subtitle)")
    }

    private var coverMosaic: some View {
        BookshelfGridGroupCoverView(
            covers: group.representativeCovers,
            count: group.count
        )
    }
}

/// 默认维度列表模式行，作为显示设置的只读 UI 替代形态。
struct BookshelfDefaultListRow: View {
    let item: BookshelfItem
    var showsNoteCount = true

    var body: some View {
        HStack(spacing: Spacing.base) {
            thumbnail

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(item.title)
                    .font(AppTypography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
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
            BookshelfGroupGridItemView(group: group)
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
