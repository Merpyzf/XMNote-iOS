//
//  BookshelfBookListView.swift
//  xmnote
//
//  Created by Codex on 2026/5/6.
//

/**
 * [INPUT]: 依赖 BookshelfBookListRoute 提供只读聚合列表载荷，依赖 BookRoute.detail 承接书籍详情导航
 * [OUTPUT]: 对外提供 BookshelfBookListView，展示分组、状态、标签、来源、评分与作者聚合下的书籍列表
 * [POS]: Book 模块二级只读列表页，被 BookRoute.bookshelfList 导航目标消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架聚合入口的二级只读列表页，只消费上级快照裁剪出的展示载荷，不直接访问数据库。
struct BookshelfBookListView: View {
    let route: BookshelfBookListRoute

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.base) {
                if !route.subtitle.isEmpty {
                    Text(route.subtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.tiny)
                }

                if route.books.isEmpty {
                    EmptyStateView(icon: "books.vertical", message: "暂无书籍")
                        .frame(minHeight: 320)
                } else {
                    ForEach(route.books) { book in
                        NavigationLink(value: BookRoute.detail(bookId: book.id)) {
                            bookRow(book)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bookRow(_ book: BookshelfBookListItem) -> some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                48,
                urlString: book.cover,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(book.title)
                    .font(AppTypography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text(metadata(for: book))
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.compact)

            Image(systemName: "chevron.right")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title)，\(metadata(for: book))")
    }

    private func metadata(for book: BookshelfBookListItem) -> String {
        let authorText = book.author.isEmpty ? "未知作者" : book.author
        guard book.noteCount > 0 else { return authorText }
        return "\(authorText) · \(book.noteCount)条书摘"
    }
}

#Preview {
    NavigationStack {
        BookshelfBookListView(route: BookshelfBookListRoute(
            title: "文学",
            subtitle: "2本",
            books: [
                BookshelfBookListItem(id: 1, title: "月亮与六便士", author: "毛姆", cover: "", noteCount: 12),
                BookshelfBookListItem(id: 2, title: "长日将尽", author: "石黑一雄", cover: "", noteCount: 3)
            ]
        ))
    }
}
