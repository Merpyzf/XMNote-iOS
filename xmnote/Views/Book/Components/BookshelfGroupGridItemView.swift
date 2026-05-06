/**
 * [INPUT]: 依赖 BookshelfGroupPayload 展示分组名称、书籍数量与代表封面
 * [OUTPUT]: 对外提供 BookshelfGroupGridItemView，渲染默认书架中的分组聚合卡
 * [POS]: Book 模块页面私有子视图，服务 BookGridView 的分组条目展示，不承担导航与数据读取
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 默认书架中的分组聚合卡，以轻量封面拼贴表达组内内容。
struct BookshelfGroupGridItemView: View {
    let group: BookshelfGroupPayload

    private let coverGridColumns = Array(
        repeating: GridItem(.flexible(), spacing: Spacing.compact),
        count: 2
    )

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            coverMosaic
            groupInfo
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name)，\(group.bookCount)本")
    }

    private var coverMosaic: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.surfaceCard)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }

            LazyVGrid(columns: coverGridColumns, spacing: Spacing.compact) {
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
            .padding(Spacing.half)

            countBadge
        }
        .aspectRatio(XMBookCover.aspectRatio, contentMode: .fit)
    }

    private var countBadge: some View {
        Text("\(group.bookCount)本")
            .font(AppTypography.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.tiny)
            .background(Color.black.opacity(0.36), in: Capsule())
            .padding(Spacing.compact)
    }

    private var groupInfo: some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(group.name)
                .font(AppTypography.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Text("\(group.bookCount)本")
                .font(AppTypography.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coverSlots: [BookshelfGroupCoverSlot] {
        let covers = Array(group.representativeCovers.prefix(4))
        return (0..<4).map { index in
            BookshelfGroupCoverSlot(id: index, cover: index < covers.count ? covers[index] : "")
        }
    }
}

private struct BookshelfGroupCoverSlot: Identifiable {
    let id: Int
    let cover: String
}

#Preview {
    BookshelfGroupGridItemView(group: BookshelfGroupPayload(
        id: 1,
        name: "计算机",
        bookCount: 25,
        representativeCovers: ["", "", "", ""],
        books: []
    ))
    .frame(width: 110)
    .padding(Spacing.screenEdge)
}
