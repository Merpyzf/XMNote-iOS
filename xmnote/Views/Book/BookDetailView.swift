//
//  BookDetailView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 BookDetailViewModel 驱动状态
 * [OUTPUT]: 对外提供 BookDetailView，书籍详情与书摘列表页面
 * [POS]: Book 模块详情壳层，通过导航接收 bookId 参数
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct BookDetailView: View {
    let bookId: Int64
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookDetailViewModel?

    var body: some View {
        Group {
            if let viewModel {
                BookDetailContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Color.windowBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            let vm = BookDetailViewModel(
                bookId: bookId,
                repository: repositories.bookRepository
            )
            viewModel = vm
            vm.startObservation()
        }
    }
}

// MARK: - Content

private struct BookDetailContentView: View {
    @Bindable var viewModel: BookDetailViewModel

    var body: some View {
        Group {
            if let book = viewModel.book {
                scrollContent(book)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func scrollContent(_ book: BookDetail) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.base) {
                bookHeader(book)

                if viewModel.hasNotes {
                    ForEach(viewModel.notes) { note in
                        NavigationLink(value: NoteRoute.detail(noteId: note.id)) {
                            noteCard(note)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    EmptyStateView(icon: "text.quote", message: "暂无书摘")
                        .frame(minHeight: 300)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
    }

    // MARK: - Header

    private func bookHeader(_ book: BookDetail) -> some View {
        CardContainer {
            HStack(alignment: .top, spacing: Spacing.base) {
                coverImage(book.cover)
                bookInfo(book)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func coverImage(_ url: String) -> some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
                Color.tagBackground
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.title3)
                            .foregroundStyle(Color.textHint)
                    }
            }
        }
        .aspectRatio(0.68, contentMode: .fit)
        .frame(width: 80)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.book))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.book)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        )
    }

    private func bookInfo(_ book: BookDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.name)
                .font(.body)
                .fontWeight(.semibold)
                .lineLimit(2)
                .foregroundStyle(.primary)

            if !book.author.isEmpty {
                Text(book.author)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            if !book.press.isEmpty {
                Text(book.press)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if !book.readStatusName.isEmpty {
                    Text(book.readStatusName)
                        .font(.caption)
                        .foregroundStyle(Color.brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.brand.opacity(0.12), in: Capsule())
                }

                Text("\(book.noteCount) 条书摘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Note Card

    private func noteCard(_ note: NoteExcerpt) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 0) {
                // 正文
                if !note.content.isEmpty {
                    Text(plainTextPreview(from: note.content))
                        .font(.subheadline)
                        .lineLimit(4)
                        .foregroundStyle(.primary)
                }

                // 想法
                if !note.idea.isEmpty {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.textHint.opacity(0.6))
                            .frame(width: 3)

                        Text(plainTextPreview(from: note.idea))
                            .font(.caption)
                            .lineLimit(3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Spacing.base)
                }

                // 底部信息
                let footer = note.footerText
                if !footer.isEmpty {
                    Text(footer)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Spacing.base)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
        }
    }

    private func plainTextPreview(from html: String) -> String {
        RichTextBridge.htmlToAttributed(html).string
    }
}

#Preview {
    NavigationStack {
        BookDetailView(bookId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
