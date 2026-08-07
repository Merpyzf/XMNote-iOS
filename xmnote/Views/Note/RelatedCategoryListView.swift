/**
 * [INPUT]: 依赖 RepositoryContainer 注入 NoteRepository/ContentRepository，依赖 RelatedCategoryListViewModel 与 RelatedListRow
 * [OUTPUT]: 对外提供 RelatedCategoryListView，覆盖相关内容混排、局部搜索排序分页、内容/相关书编辑、复制/分享与软删除
 * [POS]: Note 模块相关分类二级页面壳层，由 NoteRoute.relatedCategory 进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 相关分类混排列表；普通相关进入统一 Viewer，相关书籍进入书籍详情。
struct RelatedCategoryListView: View {
    let scope: RelatedCategoryScope
    let onOpenViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenContentRoute: (ContentRoute) -> Void
    let onOpenBookRoute: (BookRoute) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: RelatedCategoryListViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var pendingDelete: RelatedDeleteRequest?
    @State private var relatedPlaceholder: RelatedPlaceholderSession?
    @State private var isRestoringPlaceholder = false

    var body: some View {
        Group {
            if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在加载相关内容…", style: .card)
                    .padding(Spacing.screenEdge)
            } else if let viewModel {
                listContent(viewModel)
            } else {
                Color.clear
            }
        }
        .background(Color.surfacePage)
        .navigationTitle(scope.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $relatedPlaceholder) { session in
            BookRelatedPlaceholderSheet(
                item: session.workspaceItem,
                isWriting: isRestoringPlaceholder,
                onEdit: { openBookEditor(session.book) },
                onRestore: { restorePlaceholder(session.book) }
            )
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = RelatedCategoryListViewModel(
                scope: scope,
                noteRepository: repositories.noteRepository,
                contentRepository: repositories.contentRepository
            )
        }
        .onAppear(perform: syncBootstrapLoading)
        .onChange(of: viewModel == nil) { _, _ in syncBootstrapLoading() }
        .onDisappear { bootstrapLoadingGate.hideImmediately() }
    }

    private func syncBootstrapLoading() {
        bootstrapLoadingGate.update(intent: viewModel == nil ? .read : .none)
    }

    private func listContent(_ viewModel: RelatedCategoryListViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return NoteListPhaseHost(
            isLoading: viewModel.phase == .loading,
            isEmpty: viewModel.phase == .empty,
            errorMessage: failureMessage(viewModel.phase),
            loadingMessage: "正在加载相关内容…",
            emptyMessage: viewModel.normalizedSearchText.isEmpty ? "这个分类还没有相关内容" : "没有匹配的相关内容",
            emptyIcon: "link",
            onRetry: viewModel.retry
        ) {
            relatedList(viewModel)
        }
        .searchable(text: $viewModel.searchText, prompt: "搜索当前分类")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: Binding(
                        get: { viewModel.sort },
                        set: { viewModel.sort = $0 }
                    )) {
                        ForEach(RelatedContentSortRule.allCases, id: \.self) { rule in
                            Text(rule.displayTitle).tag(rule)
                        }
                    }
                    if viewModel.sort == .random {
                        Divider()
                        Button("重新随机", systemImage: "shuffle") {
                            viewModel.reshuffleRandomOrder()
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .xmSystemAlert(item: $pendingDelete) { request in
            XMSystemAlertDescriptor(
                title: request.isBook ? "移除相关书籍？" : "删除相关内容？",
                message: request.isBook
                    ? "只会把这条书籍关联标记为删除，不会删除书架中的书籍。"
                    : "内容及附图将标记为删除，并从当前列表中移除。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: request.isBook ? "移除" : "删除", role: .destructive) {
                        delete(request.item, viewModel: viewModel)
                    }
                ]
            )
        }
    }

    private func relatedList(_ viewModel: RelatedCategoryListViewModel) -> some View {
        List {
            ForEach(viewModel.items) { item in
                row(item, viewModel: viewModel)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(
                        EdgeInsets(
                            top: Spacing.half,
                            leading: Spacing.screenEdge,
                            bottom: Spacing.half,
                            trailing: Spacing.screenEdge
                        )
                    )
                    .onAppear {
                        viewModel.loadMoreIfNeeded(currentItemID: item.id)
                    }
            }

            if viewModel.isLoadingMore {
                LoadingStateView("继续加载…", style: .inline)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.surfacePage)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: viewModel.items.map(\.id)
        )
    }

    private func row(
        _ item: RelatedListItem,
        viewModel: RelatedCategoryListViewModel
    ) -> some View {
        Button {
            open(item, viewModel: viewModel)
        } label: {
            RelatedListRow(item: item)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("查看", systemImage: "doc.text.magnifyingglass") {
                open(item, viewModel: viewModel)
            }
            if case .content(let content) = item {
                Button("编辑", systemImage: "square.and.pencil") {
                    onOpenContentRoute(.relevantEditor(contentId: content.relationID))
                }
            } else if case .book(let book) = item {
                Button("编辑书籍资料", systemImage: "square.and.pencil") {
                    openBookEditor(book)
                }
            }
            Button("复制纯文本", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = shareText(item)
            }
            ShareLink(item: shareText(item)) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(deleteTitle(item), systemImage: "trash", role: .destructive) {
                pendingDelete = RelatedDeleteRequest(item: item)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = RelatedDeleteRequest(item: item)
            } label: {
                Label(deleteTitle(item), systemImage: "trash")
            }
            if case .content(let content) = item {
                Button {
                    onOpenContentRoute(.relevantEditor(contentId: content.relationID))
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                .tint(Color.brand)
            } else if case .book(let book) = item {
                Button {
                    openBookEditor(book)
                } label: {
                    Label("编辑资料", systemImage: "square.and.pencil")
                }
                .tint(Color.brand)
            }
        }
    }

    private func open(
        _ item: RelatedListItem,
        viewModel: RelatedCategoryListViewModel
    ) {
        switch item {
        case .content(let content):
            onOpenViewer(viewModel.viewerSource, .relevant(content.relationID))
        case .book(let book):
            if book.isPlaceholder {
                relatedPlaceholder = RelatedPlaceholderSession(book: book)
            } else {
                onOpenBookRoute(.detail(bookId: book.relatedBookID))
            }
        }
    }

    /// 有效书沿用完整书籍编辑；占位书携带来源书上下文，供 Repository 做关系竞态校验与范围判重。
    private func openBookEditor(_ book: RelatedBookListItem) {
        if book.isPlaceholder {
            onOpenBookRoute(.editRelatedPlaceholder(
                bookId: book.relatedBookID,
                sourceBookId: book.sourceBookID
            ))
        } else {
            onOpenBookRoute(.edit(bookId: book.relatedBookID))
        }
    }

    /// 相关占位书只在用户明确确认后恢复为有效书架书；恢复成功再进入完整详情。
    private func restorePlaceholder(_ book: RelatedBookListItem) {
        guard !isRestoringPlaceholder else { return }
        Task {
            isRestoringPlaceholder = true
            toastCenter.processing("正在加入书架…")
            let toastID = toastCenter.current?.id
            defer { isRestoringPlaceholder = false }
            do {
                try await repositories.contentRepository.restoreRelatedBookPlaceholder(
                    bookID: book.relatedBookID
                )
                toastCenter.dismiss(id: toastID)
                onOpenBookRoute(.detail(bookId: book.relatedBookID))
            } catch {
                toastCenter.error("加入书架失败：\(error.localizedDescription)")
            }
        }
    }

    /// 删除时即时禁用重复入口并展示处理中状态；成功由观察流的行移除表达。
    private func delete(
        _ item: RelatedListItem,
        viewModel: RelatedCategoryListViewModel
    ) {
        Task {
            toastCenter.processing("正在删除相关关系…")
            let toastID = toastCenter.current?.id
            do {
                try await viewModel.deleteRelation(item)
                toastCenter.dismiss(id: toastID)
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private func deleteTitle(_ item: RelatedListItem) -> String {
        switch item {
        case .content: "删除"
        case .book: "移除关联"
        }
    }

    private func shareText(_ item: RelatedListItem) -> String {
        switch item {
        case .content(let content):
            let body = RichTextPlainTextExtractor.plainText(from: content.contentHTML)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [content.title, body, content.url, content.sourceBookTitle]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        case .book(let book):
            return [book.title, book.author, "来自《\(book.sourceBookTitle)》"]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private func failureMessage(_ phase: RelatedCategoryListPhase) -> String? {
        if case .failure(let message) = phase { return message }
        return nil
    }
}

private struct RelatedDeleteRequest: Identifiable {
    let item: RelatedListItem
    var id: RelatedListItemID { item.id }
    var isBook: Bool {
        if case .book = item { return true }
        return false
    }
}

/// 首页相关列表的占位书 Sheet 载荷，复用书籍工作区既有视觉与恢复语义。
private struct RelatedPlaceholderSession: Identifiable {
    let book: RelatedBookListItem

    var id: Int64 { book.relationID }

    var workspaceItem: BookContentRelatedItem {
        BookContentRelatedItem(
            id: book.relationID,
            destination: .book(bookID: book.relatedBookID),
            title: book.title,
            subtitle: book.author,
            contentHTML: "",
            coverURL: book.coverURL,
            createdDate: book.createdDate,
            isPlaceholder: true
        )
    }
}

private extension RelatedContentSortRule {
    var displayTitle: String {
        switch self {
        case .createdAscending: "时间从早到晚"
        case .createdDescending: "时间从晚到早"
        case .random: "随机顺序"
        }
    }
}
