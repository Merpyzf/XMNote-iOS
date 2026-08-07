//
//  BookDetailView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

/**
 * [INPUT]: 依赖 RepositoryContainer 注入书籍与内容仓储，依赖 BookDetailViewModel、阅读计时路由回调、XMBookRatingSheet 与 NoteRoute/ContentRoute/BookRoute
 * [OUTPUT]: 对外提供 BookDetailView，展示书籍资料、阅读/补录入口、可写评分、目录管理与可持久化排序的书内内容工作区
 * [POS]: Book 模块详情壳层，通过导航接收 bookId，并把计时、补录与内容导航交给根导航 owner
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍详情页入口，负责加载书籍信息并展示关联书摘列表。
struct BookDetailView: View {
    let bookId: Int64
    let onStartReading: (Int64) -> Void
    let onSupplementReading: (Int64) -> Void
    let readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?
    let onOpenContentRoute: (ContentRoute) -> Void
    let onOpenBookRoute: (BookRoute) -> Void
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookDetailViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    /// 注入书籍主键与 Sheet 选参后需要追加到当前 Tab 的内容路由回调。
    init(
        bookId: Int64,
        onStartReading: @escaping (Int64) -> Void = { _ in },
        onSupplementReading: @escaping (Int64) -> Void = { _ in },
        readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration? = nil,
        onOpenContentRoute: @escaping (ContentRoute) -> Void = { _ in },
        onOpenBookRoute: @escaping (BookRoute) -> Void = { _ in }
    ) {
        self.bookId = bookId
        self.onStartReading = onStartReading
        self.onSupplementReading = onSupplementReading
        self.readingTimerZoomConfiguration = readingTimerZoomConfiguration
        self.onOpenContentRoute = onOpenContentRoute
        self.onOpenBookRoute = onOpenBookRoute
    }

    var body: some View {
        ZStack {
            if let viewModel {
                BookDetailContentView(
                    bookId: bookId,
                    viewModel: viewModel,
                    onStartReading: onStartReading,
                    onSupplementReading: onSupplementReading,
                    readingTimerZoomConfiguration: readingTimerZoomConfiguration,
                    onOpenContentRoute: onOpenContentRoute,
                    onOpenBookRoute: onOpenBookRoute
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
                repository: repositories.bookRepository,
                contentRepository: repositories.contentRepository
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
    let onOpenContentRoute: (ContentRoute) -> Void
    let onOpenBookRoute: (BookRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var readLoadingGate = LoadingGate()
    @State private var presentedSheet: BookDetailPresentedSheet?
    @State private var relatedBookDeletion: BookContentRelatedItem?

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
                if viewModel.isDetailLoading, readLoadingGate.isVisible {
                    LoadingStateView("正在加载书籍详情…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else if !viewModel.isDetailLoading {
                    unavailableBookState
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
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
        .onChange(of: viewModel.isDetailLoading) { _, _ in
            syncReadLoadingVisibility()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
        .sheet(item: $presentedSheet, content: sheetContent)
        .xmSystemAlert(
            isPresented: workspaceActionErrorIsPresented,
            descriptor: workspaceActionErrorDescriptor
        )
        .xmSystemAlert(item: $relatedBookDeletion, descriptor: relatedBookDeleteDescriptor)
        .toolbar {
            if viewModel.book != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(
                        value: BookRoute.chapterManager(
                            bookID: bookId,
                            focusChapterID: nil
                        )
                    ) {
                        TopBarActionIcon(systemName: "list.bullet.indent")
                    }
                    .accessibilityLabel("管理目录")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: BookRoute.edit(bookId: bookId)) {
                        TopBarActionIcon(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("编辑书籍")
                }
            }
        }
        .animation(
            reduceMotion ? .smooth(duration: 0.12) : .smooth(duration: 0.24),
            value: viewModel.isDetailLoading
        )
    }

    func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel.isDetailLoading ? .read : .none)
    }

    private var unavailableBookState: some View {
        VStack(spacing: Spacing.base) {
            EmptyStateView(
                icon: "book.closed",
                message: viewModel.detailErrorMessage ?? "书籍暂时无法显示"
            )

            HStack(spacing: Spacing.cozy) {
                Button("返回") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("重新读取") {
                    viewModel.retryDetailObservation()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.screenEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: BookDetailPresentedSheet) -> some View {
        switch sheet {
        case .rating:
            if let book = viewModel.book {
                XMBookRatingSheet(
                    bookTitle: book.name,
                    initialScore: book.score,
                    onSubmit: viewModel.updateBookRating
                )
            } else {
                EmptyStateView(icon: "star", message: "书籍不存在或暂时无法评分")
                    .padding(Spacing.screenEdge)
            }
        case .categoryPicker:
            BookRelatedCategoryPickerSheet(
                categories: viewModel.workspace.categoryOptions,
                onSelect: { category in
                    presentedSheet = nil
                    onOpenContentRoute(.relevantEditorCreate(
                        bookId: bookId,
                        categoryId: category.id
                    ))
                }
            ) {
                relatedCategoryManagementSheet(presentation: .navigationDestination)
            }
        case .categoryManagement:
            relatedCategoryManagementSheet(presentation: .sheet)
        case .relatedBookPicker:
            BookPickerView(configuration: relatedBookPickerConfiguration) { result in
                presentedSheet = nil
                handleRelatedBookPickerResult(result)
            }
        case .relatedPlaceholder(let relationID):
            if let item = relatedItem(relationID: relationID) {
                BookRelatedPlaceholderSheet(
                    item: item,
                    isWriting: viewModel.isWorkspaceWriting,
                    onEdit: {
                        guard case .book(let relatedBookID) = item.destination else { return }
                        onOpenBookRoute(.editRelatedPlaceholder(
                            bookId: relatedBookID,
                            sourceBookId: bookId
                        ))
                    },
                    onRestore: {
                        guard case .book(let relatedBookID) = item.destination else { return }
                        viewModel.restoreRelatedBookPlaceholder(bookID: relatedBookID)
                    }
                )
            } else {
                EmptyStateView(icon: "books.vertical", message: "相关书籍不存在或已移除")
                    .padding(Spacing.screenEdge)
            }
        }
    }

    private func relatedCategoryManagementSheet(
        presentation: BookRelatedCategoryManagementPresentation
    ) -> some View {
        BookRelatedCategoryManagementSheet(
            categories: viewModel.workspace.categories,
            isWriting: viewModel.isWorkspaceWriting,
            actionErrorMessage: viewModel.workspaceActionErrorMessage,
            presentation: presentation,
            onCreate: viewModel.createRelatedCategory,
            onRename: viewModel.renameRelatedCategory,
            onDelete: viewModel.deleteRelatedCategory,
            onSetHidden: viewModel.setDefaultRelatedCategoryHidden,
            onReorder: viewModel.reorderRelatedCategories,
            onConsumeError: viewModel.consumeWorkspaceActionError
        )
    }

    private func relatedItem(relationID: Int64) -> BookContentRelatedItem? {
        viewModel.workspace.relatedSections
            .lazy
            .flatMap { $0.items }
            .first { $0.id == relationID }
    }

    private var relatedBookPickerConfiguration: BookPickerConfiguration {
        BookPickerConfiguration(
            title: "添加相关书籍",
            scope: .both,
            selectionMode: .single,
            allowsCreationFlow: true,
            creationAction: .inlineManualEditor,
            onlineSelectionPolicy: .returnRemoteSelection,
            defaultQuery: "",
            preselectedBooks: [],
            onlineSources: BookSearchSource.productionCases,
            preferredOnlineSource: .wenqu
        )
    }

    private func handleRelatedBookPickerResult(_ result: BookPickerResult) {
        guard case .single(let selection) = result else { return }
        switch selection {
        case .local(let book):
            viewModel.addRelatedBook(bookID: book.id)
        case .remote(let remoteSelection):
            viewModel.addRelatedBook(remoteSelection: remoteSelection)
        }
    }

    private var workspaceActionErrorIsPresented: Binding<Bool> {
        Binding(
            get: {
                viewModel.workspaceActionErrorMessage != nil
                    && presentedSheet != .categoryManagement
                    && presentedSheet != .categoryPicker
            },
            set: { isPresented in
                guard !isPresented else { return }
                viewModel.consumeWorkspaceActionError()
            }
        )
    }

    private var workspaceActionErrorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.workspaceActionErrorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "操作未完成",
            message: message,
            actions: [XMSystemAlertAction(title: "好") {
                viewModel.consumeWorkspaceActionError()
            }]
        )
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

                chaptersSection(book.chapters)

                BookContentWorkspaceView(
                    bookID: bookId,
                    notes: viewModel.notes,
                    snapshot: viewModel.workspace,
                    isLoading: viewModel.isWorkspaceLoading,
                    errorMessage: viewModel.workspaceErrorMessage,
                    isWriting: viewModel.isWorkspaceWriting,
                    onRetry: viewModel.retryWorkspaceObservation,
                    onCreateRelatedContent: { presentedSheet = .categoryPicker },
                    onAddRelatedBook: { presentedSheet = .relatedBookPicker },
                    onManageCategories: { presentedSheet = .categoryManagement },
                    onChangeSort: viewModel.updateContentSort,
                    onEditRelatedBook: openRelatedBookEditor,
                    onRequestDeleteRelatedBook: { relatedBookDeletion = $0 },
                    onOpenRelatedPlaceholder: {
                        presentedSheet = .relatedPlaceholder(relationID: $0.id)
                    }
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
    }

    /// 有效相关书复用完整编辑路由，占位书进入保持 is_deleted=1 的专用资料编辑模式。
    private func openRelatedBookEditor(_ item: BookContentRelatedItem) {
        guard case .book(let relatedBookID) = item.destination else { return }
        if item.isPlaceholder {
            onOpenBookRoute(.editRelatedPlaceholder(
                bookId: relatedBookID,
                sourceBookId: bookId
            ))
        } else {
            onOpenBookRoute(.edit(bookId: relatedBookID))
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

            Button {
                presentedSheet = .rating
            } label: {
                HStack(spacing: Spacing.compact) {
                    XMRatingBar(score: book.score, preset: .listSmall)

                    Text(book.score > 0 ? formattedBookScore(book.score) : "未评分")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .contentTransition(.numericText())

                    Image(systemName: "chevron.up.chevron.down")
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textHint)
                }
                .frame(minHeight: Spacing.actionReserved)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRatingWriting)
            .accessibilityLabel("为《\(book.name)》评分，当前\(book.score > 0 ? "\(formattedBookScore(book.score)) 星" : "未评分")")

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

    private func formattedBookScore(_ score: Int64) -> String {
        (Double(score) / 10.0).formatted(
            .number.precision(.fractionLength(1))
        )
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
                HStack(spacing: Spacing.cozy) {
                    Text("目录")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)

                    Spacer(minLength: Spacing.compact)

                    NavigationLink(
                        value: BookRoute.chapterManager(
                            bookID: bookId,
                            focusChapterID: nil
                        )
                    ) {
                        Label("管理", systemImage: "slider.horizontal.3")
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(Color.brand)
                            .frame(minHeight: Spacing.actionReserved)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("新增、编辑、移动或删除章节")
                }

                if chapters.isEmpty {
                    Text("还没有章节，可进入目录管理新增并整理书摘结构。")
                        .font(AppTypography.callout)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Spacing.cozy)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.none) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        NavigationLink(
                            value: NoteRoute.chapterNotes(
                                bookID: bookId,
                                chapterID: chapter.id,
                                includeDescendants: true
                            )
                        ) {
                            HStack(spacing: Spacing.base) {
                                Text(chapter.title)
                                    .font(AppTypography.body)
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textHint)
                            }
                            .padding(.leading, chapterIndent(for: chapter))
                            .padding(.vertical, Spacing.tight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < chapters.count - 1 {
                            Divider()
                                .padding(.leading, chapterIndent(for: chapter))
                        }
                    }
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
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

    private func relatedBookDeleteDescriptor(_ item: BookContentRelatedItem) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "移除相关书籍",
            message: "将从当前书的相关内容中移除“\(item.title.isEmpty ? "未命名书籍" : item.title)”。书架中的有效书籍不会被删除。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "移除", role: .destructive) {
                    viewModel.deleteRelatedRelation(relationID: item.id)
                }
            ]
        )
    }

}

/// 书籍详情只展示一个业务 Sheet，切换时由系统 presentation 保持底层滚动现场。
private enum BookDetailPresentedSheet: Equatable, Identifiable {
    case rating
    case categoryPicker
    case categoryManagement
    case relatedBookPicker
    case relatedPlaceholder(relationID: Int64)

    var id: String {
        switch self {
        case .rating: "rating"
        case .categoryPicker: "category-picker"
        case .categoryManagement: "category-management"
        case .relatedBookPicker: "related-book-picker"
        case .relatedPlaceholder(let relationID): "related-placeholder-\(relationID)"
        }
    }
}

#Preview {
    NavigationStack {
        BookDetailView(bookId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
