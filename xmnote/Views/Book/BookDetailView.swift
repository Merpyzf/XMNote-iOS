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

private struct BookDetailContentView: View {
    let bookId: Int64
    @Bindable var viewModel: BookDetailViewModel
    @State private var readLoadingGate = LoadingGate()

    private enum Layout {
        static let attributeTitleWidth: CGFloat = 76
        static var attributeDividerInset: CGFloat {
            attributeTitleWidth + Spacing.base
        }
    }

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

    private func scrollContent(_ book: BookDetail) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.base) {
                bookHeader(book)

                if !book.attributes.isEmpty {
                    attributesSection(book.attributes)
                }

                if let summary = nonEmptyPlainText(book.summary) {
                    textSection(title: "简介", text: summary)
                }

                if let authorIntro = nonEmptyPlainText(book.authorIntro) {
                    textSection(title: "作者简介", text: authorIntro)
                }

                if !book.chapters.isEmpty {
                    chaptersSection(book.chapters)
                }

                notesSection
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
        XMBookCover.fixedWidth(
            80,
            urlString: url,
            cornerRadius: CornerRadius.inlayHairline,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: .medium,
            surfaceStyle: .spine
        )
    }

    private func bookInfo(_ book: BookDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(book.name)
                .font(AppTypography.bodyMedium)
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

    // MARK: - Detail Sections

    private func attributesSection(_ attributes: [BookDetailAttribute]) -> some View {
        CardContainer {
            VStack(spacing: Spacing.none) {
                ForEach(Array(attributes.enumerated()), id: \.element.id) { index, attribute in
                    if let route = route(for: attribute) {
                        NavigationLink(value: route) {
                            attributeRow(attribute, showsDisclosure: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        attributeRow(attribute, showsDisclosure: false)
                    }

                    if index < attributes.count - 1 {
                        Divider()
                            .padding(.leading, Layout.attributeDividerInset)
                    }
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
        }
    }

    private func attributeRow(_ attribute: BookDetailAttribute, showsDisclosure: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            Text(attribute.kind.title)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
                .frame(width: Layout.attributeTitleWidth, alignment: .leading)

            Text(attribute.value)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
            }
        }
        .padding(.vertical, Spacing.cozy)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func textSection(title: String, text: String) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text(text)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
        }
    }

    private func chaptersSection(_ chapters: [BookDetailChapter]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("目录")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.none) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        Text(chapter.title)
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, chapterIndent(for: chapter))
                            .padding(.vertical, Spacing.tight)

                        if index < chapters.count - 1 {
                            Divider()
                                .padding(.leading, chapterIndent(for: chapter))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("书摘")
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.half)

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
                    .frame(minHeight: 180)
            }
        }
    }

    private func route(for attribute: BookDetailAttribute) -> BookRoute? {
        switch attribute.kind {
        case .author:
            return BookRoute.bookshelfList(BookshelfBookListRoute(
                context: .author(attribute.value),
                title: attribute.value,
                subtitleHint: "相关书籍"
            ))
        case .press:
            return BookRoute.bookshelfList(BookshelfBookListRoute(
                context: .press(attribute.value),
                title: attribute.value,
                subtitleHint: "相关书籍"
            ))
        case .translator, .pubDate, .isbn, .source, .readStatus:
            return nil
        }
    }

    private func chapterIndent(for chapter: BookDetailChapter) -> CGFloat {
        CGFloat(max(0, min(chapter.level - 1, 4))) * Spacing.base
    }

    // MARK: - Note Card

    private func noteCard(_ note: NoteExcerpt) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.none) {
                // 正文
                if !note.content.isEmpty {
                    Text(plainTextPreview(from: note.content))
                        .font(NoteExcerptTypography.body)
                        .lineSpacing(NoteExcerptTypography.bodyLineSpacing)
                        .lineLimit(6)
                        .foregroundStyle(.primary)
                }

                // 想法
                if !note.idea.isEmpty {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                            .fill(Color.textHint.opacity(0.6))
                            .frame(width: 3)

                        Text(plainTextPreview(from: note.idea))
                            .font(NoteExcerptTypography.idea)
                            .lineSpacing(NoteExcerptTypography.ideaLineSpacing)
                            .lineLimit(3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Spacing.base)
                }

                // 底部信息
                let footer = note.footerText
                if !footer.isEmpty {
                    Text(footer)
                        .font(NoteExcerptTypography.footer)
                        .foregroundStyle(Color.textSecondary)
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

    private func nonEmptyPlainText(_ value: String) -> String? {
        let text = plainTextPreview(from: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

#Preview {
    NavigationStack {
        BookDetailView(bookId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
