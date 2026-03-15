//
//  BookGridItemView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

/**
 * [INPUT]: 依赖 BookItem 展示模型
 * [OUTPUT]: 对外提供 BookGridItemView，单本书籍卡片渲染
 * [POS]: Book 模块最小展示单元，被 BookGridView 复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍网格中的单卡片视图，展示封面、标题、作者与书摘数量。
struct BookGridItemView: View {
    let book: BookItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            coverImage
            bookInfo
        }
    }

    // MARK: - Cover

    private var coverImage: some View {
        XMBookCover.responsive(
            urlString: book.cover,
            cornerRadius: CornerRadius.inlayHairline,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            surfaceStyle: .spine
        )
        .overlay(alignment: .topTrailing) {
            noteBadge
        }
    }

    // MARK: - Badge

    @ViewBuilder
    private var noteBadge: some View {
        if book.noteCount > 0 {
            Text("\(book.noteCount)")
                .font(AppTypography.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.half)
                .padding(.vertical, Spacing.tiny)
                .background(Color.brand, in: Capsule())
                .padding(Spacing.compact)
        }
    }

    // MARK: - Info

    private var bookInfo: some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(book.name)
                .font(AppTypography.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Text(book.author.isEmpty ? " " : book.author)
                .font(AppTypography.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    BookGridItemView(book: BookItem(
        id: 1, name: "人类简史", author: "尤瓦尔·赫拉利",
        cover: "", readStatusId: 2, noteCount: 5, pinned: false
    ))
    .frame(width: 110)
    .padding(Spacing.screenEdge)
}
