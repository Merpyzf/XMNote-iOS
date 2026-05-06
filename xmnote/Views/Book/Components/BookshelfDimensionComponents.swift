/**
 * [INPUT]: 依赖 BookshelfDimension、BookshelfSection、BookshelfAggregateGroup 等只读书架模型
 * [OUTPUT]: 对外提供 Book 页面私有的维度 rail、聚合卡、分区卡与搜索栏组件
 * [POS]: Book 模块页面私有子视图集合，服务 Phase 2 书架维度骨架，不承担数据读取与写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架维度横向 rail，表达“怎么看书架”，不承载写入动作。
struct BookshelfDimensionRail: View {
    let selectedDimension: BookshelfDimension
    let onSelect: (BookshelfDimension) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.compact) {
                ForEach(BookshelfDimension.allCases, id: \.self) { dimension in
                    Button {
                        onSelect(dimension)
                    } label: {
                        Text(dimension.title)
                            .font(AppTypography.subheadline)
                            .fontWeight(selectedDimension == dimension ? .semibold : .medium)
                            .foregroundStyle(selectedDimension == dimension ? .white : .primary)
                            .padding(.horizontal, Spacing.base)
                            .frame(minHeight: 36)
                            .background(
                                selectedDimension == dimension ? Color.brand : Color.surfaceCard,
                                in: Capsule()
                            )
                            .overlay {
                                if selectedDimension != dimension {
                                    Capsule()
                                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dimension.title)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.compact)
        }
        .frame(minHeight: 44)
    }
}

/// 页内搜索栏，搜索只参与只读过滤，不承载排序写入。
struct BookshelfSearchBar: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.compact) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("搜索书名或作者", text: $text)
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

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Spacing.tiny),
        count: 3
    )

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
        ZStack(alignment: .bottomTrailing) {
            LazyVGrid(columns: columns, spacing: Spacing.tiny) {
                ForEach(coverSlots) { slot in
                    XMBookCover.responsive(
                        urlString: slot.cover,
                        cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                        placeholderIconSize: .small,
                        surfaceStyle: .spine
                    )
                }
            }

            Text("\(group.count)本")
                .font(AppTypography.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.half)
                .padding(.vertical, Spacing.tiny)
                .background(Color.black.opacity(0.36), in: Capsule())
                .padding(Spacing.tiny)
        }
        .aspectRatio(1.18, contentMode: .fit)
    }

    private var coverSlots: [BookshelfCoverSlot] {
        let covers = Array(group.representativeCovers.prefix(6))
        return (0..<6).map { index in
            BookshelfCoverSlot(id: index, cover: index < covers.count ? covers[index] : "")
        }
    }
}

/// 状态、评分等维度使用的纵向分区卡。
struct BookshelfSectionCardView: View {
    let section: BookshelfSection

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.compact) {
                Text(section.title)
                    .font(AppTypography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: Spacing.compact)

                Text(section.subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.compact) {
                    ForEach(section.books.prefix(6), id: \.id) { book in
                        XMBookCover.responsive(
                            urlString: book.cover,
                            cornerRadius: CornerRadius.inlaySmall,
                            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                            placeholderIconSize: .small,
                            surfaceStyle: .spine
                        )
                        .frame(width: 54)
                    }
                }
            }
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title)，\(section.subtitle)")
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

private struct BookshelfCoverSlot: Identifiable {
    let id: Int
    let cover: String
}
