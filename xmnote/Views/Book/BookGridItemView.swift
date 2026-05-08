//
//  BookGridItemView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

/**
 * [INPUT]: 依赖 BookshelfBookPayload 展示模型
 * [OUTPUT]: 对外提供 BookGridItemView，单本书籍卡片渲染
 * [POS]: Book 模块最小展示单元，被 BookGridView 复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍网格中的单卡片视图，展示封面、标题、作者与书摘数量。
struct BookGridItemView: View {
    let book: BookshelfBookPayload
    var showsNoteCount = true
    var isPinned = false
    var titleDisplayMode: BookshelfTitleDisplayMode = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            coverImage
            bookInfo
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cover

    private var coverImage: some View {
        BookshelfGridBookCoverView(
            book: book,
            showsNoteCount: showsNoteCount,
            isPinned: isPinned
        )
    }

    // MARK: - Info

    private var bookInfo: some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            BookshelfTitleText(
                text: book.name,
                mode: titleDisplayMode,
                style: .captionMedium,
                color: .textPrimary
            )

            Text(book.author.isEmpty ? " " : book.author)
                .font(AppTypography.caption2)
                .lineLimit(1)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    BookGridItemView(book: BookshelfBookPayload(
        id: 1,
        name: "人类简史",
        author: "尤瓦尔·赫拉利",
        cover: "",
        readStatusId: 2,
        noteCount: 5
    ), isPinned: true)
    .frame(width: 110)
    .padding(Spacing.screenEdge)
}
