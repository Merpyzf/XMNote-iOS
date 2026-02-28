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

struct BookGridItemView: View {
    let book: BookItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverImage
            bookInfo
        }
    }

    // MARK: - Cover

    private var coverImage: some View {
        AsyncImage(url: URL(string: book.cover)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
                coverPlaceholder
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(0.68, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        )
        .overlay(alignment: .topTrailing) {
            noteBadge
        }
    }

    private var coverPlaceholder: some View {
        Color.tagBackground
            .overlay {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(Color.textHint)
            }
    }

    // MARK: - Badge

    @ViewBuilder
    private var noteBadge: some View {
        if book.noteCount > 0 {
            Text("\(book.noteCount)")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.brand, in: Capsule())
                .padding(4)
        }
    }

    // MARK: - Info

    private var bookInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.name)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Text(book.author.isEmpty ? " " : book.author)
                .font(.caption2)
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
    .padding()
}
