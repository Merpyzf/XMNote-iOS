//
//  BookDetailView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 BookDetailViewModel 驱动状态，依赖 ContentRoute 承接书摘查看路由
 * [OUTPUT]: 对外提供 BookDetailView，书籍详情与书摘列表页面
 * [POS]: Book 模块详情壳层，通过导航接收 bookId 参数，并把书摘点击转入专用书摘查看器
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍详情页入口，负责加载书籍信息并展示关联书摘列表。
struct BookDetailView: View {
    let bookId: Int64
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookDetailViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            if let viewModel {
                BookDetailContentView(
                    bookId: bookId,
                    viewModel: viewModel
                )
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在加载书籍详情…", style: .card)
                }
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let vm = BookDetailViewModel(
                bookId: bookId,
                repository: repositories.bookRepository
            )
            viewModel = vm
            bootstrapLoadingGate.update(intent: .none)
            vm.startObservation()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

// MARK: - Content

/// BookDetailContentView 负责当前场景的struct定义，明确职责边界并组织相关能力。
private struct BookDetailContentView: View {
    let bookId: Int64
    @Bindable var viewModel: BookDetailViewModel
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        Group {
            if let book = viewModel.book {
                scrollContent(book)
            } else {
                if readLoadingGate.isVisible {
                    LoadingStateView("正在加载书籍详情…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            syncReadLoadingVisibility()
        }
        .onChange(of: viewModel.book == nil) { _, _ in
            syncReadLoadingVisibility()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
    }

    func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel.book == nil ? .read : .none)
    }

    /// 封装scrollContent对应的业务步骤，确保调用方可以稳定复用该能力。
    private func scrollContent(_ book: BookDetail) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.base) {
                bookHeader(book)

                if viewModel.hasNotes {
                    ForEach(viewModel.notes) { note in
                        NavigationLink(
                            value: ContentRoute.contentViewer(
                                source: .bookNotes(bookId: bookId),
                                initialItemID: .note(note.id)
                            )
                        ) {
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

    /// 封装bookHeader对应的业务步骤，确保调用方可以稳定复用该能力。
    private func bookHeader(_ book: BookDetail) -> some View {
        CardContainer {
            HStack(alignment: .top, spacing: Spacing.base) {
                coverImage(book.cover)
                bookInfo(book)
            }
            .padding(Spacing.contentEdge)
        }
    }

    /// 封装coverImage对应的业务步骤，确保调用方可以稳定复用该能力。
    private func coverImage(_ url: String) -> some View {
        XMBookCover.fixedWidth(
            80,
            urlString: url,
            cornerRadius: CornerRadius.inlayHairline,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: .medium,
            surfaceStyle: .spine
        )
    }

    /// 封装bookInfo对应的业务步骤，确保调用方可以稳定复用该能力。
    private func bookInfo(_ book: BookDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(book.name)
                .font(AppTypography.body)
                .fontWeight(.semibold)
                .lineLimit(2)
                .foregroundStyle(.primary)

            if !book.author.isEmpty {
                Text(book.author)
                    .font(AppTypography.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            if !book.press.isEmpty {
                Text(book.press)
                    .font(AppTypography.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: Spacing.cozy) {
                if !book.readStatusName.isEmpty {
                    Text(book.readStatusName)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.brand)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.micro)
                        .background(Color.brand.opacity(0.12), in: Capsule())
                }

                Text("\(book.noteCount) 条书摘")
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Note Card

    /// 封装noteCard对应的业务步骤，确保调用方可以稳定复用该能力。
    private func noteCard(_ note: NoteExcerpt) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.none) {
                // 正文
                if !note.content.isEmpty {
                    Text(plainTextPreview(from: note.content))
                        .font(AppTypography.subheadline)
                        .lineLimit(4)
                        .foregroundStyle(.primary)
                }

                // 想法
                if !note.idea.isEmpty {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                            .fill(Color.textHint.opacity(0.6))
                            .frame(width: 3)

                        Text(plainTextPreview(from: note.idea))
                            .font(AppTypography.caption)
                            .lineLimit(3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Spacing.base)
                }

                // 底部信息
                let footer = note.footerText
                if !footer.isEmpty {
                    Text(footer)
                        .font(AppTypography.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Spacing.base)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
        }
    }

    /// 封装plainTextPreview对应的业务步骤，确保调用方可以稳定复用该能力。
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
