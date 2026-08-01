//
//  BookDetailView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

/**
 * [INPUT]: 依赖 RepositoryContainer、AppNavigationCoordinator、BookDetailViewModel 与外层阅读计时路由配置
 * [OUTPUT]: 对外提供 BookDetailView，书籍详情、阅读入口与书摘列表页面
 * [POS]: Book 模块详情壳层，通过导航接收 bookId，并把计时、补录与书摘查看交给对应根导航 owner
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍详情页入口，负责加载书籍信息并展示关联书摘列表。
struct BookDetailView: View {
    let bookId: Int64
    let onStartReading: (Int64) -> Void
    let onSupplementReading: (Int64) -> Void
    let readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookDetailViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    /// 注入书籍详情 ID 与阅读计时相关路由回调，保持详情页不直接持有外层 NavigationPath。
    init(
        bookId: Int64,
        onStartReading: @escaping (Int64) -> Void = { _ in },
        onSupplementReading: @escaping (Int64) -> Void = { _ in },
        readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration? = nil
    ) {
        self.bookId = bookId
        self.onStartReading = onStartReading
        self.onSupplementReading = onSupplementReading
        self.readingTimerZoomConfiguration = readingTimerZoomConfiguration
    }

    var body: some View {
        ZStack {
            if let viewModel {
                BookDetailContentView(
                    bookId: bookId,
                    viewModel: viewModel,
                    onStartReading: onStartReading,
                    onSupplementReading: onSupplementReading,
                    readingTimerZoomConfiguration: readingTimerZoomConfiguration
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
    let onStartReading: (Int64) -> Void
    let onSupplementReading: (Int64) -> Void
    let readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?
    @State private var readLoadingGate = LoadingGate()
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator

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
                if let readingTimerZoomConfiguration {
                    ReadingTimerNormalZoomSource(configuration: readingTimerZoomConfiguration) { open in
                        bookHeader(book, onStartReading: { _ in open() })
                    }
                } else {
                    bookHeader(book)
                }

                if !book.attributes.isEmpty {
                    attributesSection(book.attributes)
                }

                if !book.summaryPlainText.isEmpty {
                    textSection(title: "简介", text: book.summaryPlainText)
                }

                if !book.authorIntroPlainText.isEmpty {
                    textSection(title: "作者简介", text: book.authorIntroPlainText)
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

    private func bookHeader(
        _ book: BookDetail,
        onStartReading: ((Int64) -> Void)? = nil
    ) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    coverImage(book.cover)
                    bookInfo(book)
                }

                Divider()

                HStack(spacing: Spacing.base) {
                    Button {
                        (onStartReading ?? self.onStartReading)(bookId)
                    } label: {
                        Label("开始阅读", systemImage: "play.fill")
                            .font(AppTypography.bodyMedium)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.cozy)
                            .background(Color.brand, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSupplementReading(bookId)
                    } label: {
                        Label("补录阅读", systemImage: "plus.circle")
                            .font(AppTypography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.cozy)
                            .background(Color.controlFillSecondary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
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
                    Button {
                        navigationCoordinator.present(
                            .contentViewer(
                            source: .bookNotes(bookId: bookId),
                            initialItemID: .note(note.id),
                            keyword: ""
                            )
                        )
                    } label: {
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
                if !note.contentPlainText.isEmpty {
                    Text(note.contentPlainText)
                        .font(NoteExcerptTypography.body)
                        .lineSpacing(NoteExcerptTypography.bodyLineSpacing)
                        .lineLimit(6)
                        .foregroundStyle(.primary)
                }

                // 想法
                if !note.ideaPlainText.isEmpty {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                            .fill(Color.textHint.opacity(0.6))
                            .frame(width: 3)

                        Text(note.ideaPlainText)
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

}

#Preview {
    NavigationStack {
        BookDetailView(bookId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
