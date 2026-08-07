/**
 * [INPUT]: 依赖调用方注入 NoteRepository 与外部应用仓储，依赖 NoteExcerptListViewModel 的已提交查询和快照变更语义、列表组件、BookPicker 与批量 Sheet
 * [OUTPUT]: 对外提供 NoteExcerptListView，以系统底部搜索、关键字高亮、语义列表动效、首帧稳定的导航数量副标题与中性菜单承载渐进分页、查看/编辑/复制反馈、页面级分享、删除确认及批量操作
 * [POS]: Note 模块书摘二级页面壳层，由 NoteRoute.noteExcerpts 与旧标签路由进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘二级列表；导航回调携带当前真实查询上下文，确保 Viewer 与列表顺序一致。
struct NoteExcerptListView: View {
    let onOpenViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void

    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: NoteExcerptListViewModel
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    @State private var pendingAlert: NoteExcerptListAlert?
    @State private var presentedSheet: NoteBatchSheet?
    @State private var sharePayload: XMActivitySharePayload?

    private let origin: NoteExcerptListOrigin
    private let displayTitle: String
    private let showsRemoveChapterStar: Bool

    /// 创建默认分组或标签范围列表。
    init(
        context: NoteExcerptListContext,
        repository: any NoteRepositoryProtocol,
        externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol,
        onOpenViewer: @escaping (ContentViewerSourceContext, ContentViewerItemID) -> Void,
        onOpenNoteRoute: @escaping (NoteRoute) -> Void
    ) {
        self.init(
            origin: .scope(context.scope),
            displayTitle: context.displayTitle,
            showsRemoveChapterStar: false,
            repository: repository,
            externalAppIntegrationRepository: externalAppIntegrationRepository,
            onOpenViewer: onOpenViewer,
            onOpenNoteRoute: onOpenNoteRoute
        )
    }

    /// 章节包装页复用同一列表实现，并显式开放取消星标动作。
    init(
        origin: NoteExcerptListOrigin,
        displayTitle: String,
        showsRemoveChapterStar: Bool,
        repository: any NoteRepositoryProtocol,
        externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol,
        onOpenViewer: @escaping (ContentViewerSourceContext, ContentViewerItemID) -> Void,
        onOpenNoteRoute: @escaping (NoteRoute) -> Void
    ) {
        self.origin = origin
        self.displayTitle = displayTitle
        self.showsRemoveChapterStar = showsRemoveChapterStar
        self.onOpenViewer = onOpenViewer
        self.onOpenNoteRoute = onOpenNoteRoute
        _viewModel = State(
            initialValue: NoteExcerptListViewModel(
                origin: origin,
                repository: repository,
                externalAppIntegrationRepository: externalAppIntegrationRepository
            )
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        return listContent(viewModel)
            .background(Color.surfacePage)
            .navigationTitle(navigationTitle(viewModel))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $viewModel.searchText,
                isPresented: $isSearchPresented,
                prompt: "搜索当前列表"
            )
            .searchFocused($isSearchFocused)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar(removing: viewModel.isEditing ? .search : nil)
            .toolbar { toolbarContent(viewModel) }
            .sheet(item: $sharePayload) { payload in
                XMActivityShareSheet(activityItems: payload.activityItems)
            }
    }

    private func listContent(_ viewModel: NoteExcerptListViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return NoteListPhaseHost(
            isLoading: viewModel.phase == .loading,
            isEmpty: viewModel.phase == .empty,
            errorMessage: failureMessage(viewModel.phase),
            loadingMessage: "正在加载书摘…",
            emptyMessage: viewModel.appliedSearchText.isEmpty ? "这里还没有书摘" : "没有匹配的书摘",
            emptyIcon: "text.quote",
            animatesEmptyContentTransition: true,
            onRetry: viewModel.retry
        ) {
            noteList(viewModel)
        }
        .safeAreaInset(edge: .bottom, spacing: Spacing.none) {
            if viewModel.isEditing {
                batchBar(viewModel)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(
            reduceMotion ? .smooth(duration: 0.12) : .smooth(duration: 0.28),
            value: viewModel.isEditing
        )
        .sheet(item: $presentedSheet) { sheet in
            batchSheet(sheet, viewModel: viewModel)
        }
        .xmSystemAlert(item: $pendingAlert) { alert in
            alertDescriptor(alert, viewModel: viewModel)
        }
    }

    private func noteList(_ viewModel: NoteExcerptListViewModel) -> some View {
        List {
            ForEach(viewModel.items) { item in
                noteRow(item, viewModel: viewModel)
                    .transition(.opacity)
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
        .scrollBounceBehavior(.always)
        .scrollContentBackground(.hidden)
        .background(Color.surfacePage)
        .animation(
            listChangeAnimation(for: viewModel.snapshotChange.kind),
            value: viewModel.snapshotChange.revision
        )
        .animation(
            reduceMotion ? .smooth(duration: 0.12) : .snappy(duration: 0.18),
            value: viewModel.selectedNoteIDs
        )
    }

    private func noteRow(
        _ item: NoteExcerptListItem,
        viewModel: NoteExcerptListViewModel
    ) -> some View {
        Button {
            if viewModel.isEditing {
                withAnimation(reduceMotion ? .smooth(duration: 0.12) : .snappy(duration: 0.18)) {
                    viewModel.toggleSelection(noteID: item.id)
                }
            } else {
                onOpenViewer(viewModel.viewerSource, .note(item.id))
            }
        } label: {
            NoteExcerptListRow(
                item: item,
                searchKeyword: viewModel.appliedSearchText,
                hiddenTagID: hiddenTagID,
                isSelecting: viewModel.isEditing,
                isSelected: viewModel.selectedNoteIDs.contains(item.id)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !viewModel.isEditing {
                Button {
                    onOpenViewer(viewModel.viewerSource, .note(item.id))
                } label: {
                    XMMenuLabel("查看", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    onOpenNoteRoute(.edit(noteId: item.id))
                } label: {
                    XMMenuLabel("编辑", systemImage: "square.and.pencil")
                }
                copyMenu(item)
                Button {
                    sharePayload = XMActivitySharePayload(activityItems: [shareText(item)])
                } label: {
                    XMMenuLabel("分享", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) {
                    pendingAlert = .delete(noteIDs: [item.id], count: 1)
                }
                .disabled(viewModel.isWriting)
            }
        }
        .xmMenuNeutralTint()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !viewModel.isEditing {
                Button(role: .destructive) {
                    pendingAlert = .delete(noteIDs: [item.id], count: 1)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    onOpenNoteRoute(.edit(noteId: item.id))
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                .tint(Color.brand)
            }
        }
    }

    private var hiddenTagID: Int64? {
        guard case .scope(.tag(let tagID)) = origin else { return nil }
        return tagID
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ viewModel: NoteExcerptListViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .subtitle) {
            navigationSubtitleLabel(
                isNavigationSubtitleVisible(viewModel)
                    ? navigationSubtitleText(viewModel)
                    : " "
            )
        }

        ToolbarItem(placement: .topBarTrailing) {
            if viewModel.isEditing {
                Button("完成") {
                    withAnimation(reduceMotion ? .smooth(duration: 0.12) : .snappy(duration: 0.18)) {
                        viewModel.setEditing(false)
                    }
                }
                .disabled(viewModel.isWriting)
            } else {
                Menu {
                    Menu {
                        ForEach(NoteExcerptSortRule.allCases, id: \.self) { rule in
                            Button {
                                viewModel.sort = rule
                            } label: {
                                XMMenuLabel(
                                    rule.displayTitle,
                                    isSelected: viewModel.sort == rule
                                )
                            }
                        }

                        if viewModel.sort == .random {
                            Divider()
                            Button {
                                viewModel.reshuffleRandomOrder()
                            } label: {
                                XMMenuLabel("重新随机", systemImage: "shuffle")
                            }
                        }
                    } label: {
                        XMMenuLabel("排序", systemImage: "arrow.up.arrow.down")
                    }

                    Button {
                        beginEditing(viewModel)
                    } label: {
                        XMMenuLabel("选择书摘", systemImage: "checkmark.circle")
                    }
                    .disabled(viewModel.items.isEmpty || viewModel.isWriting)

                    if showsRemoveChapterStar, viewModel.isChapterStarred {
                        Divider()
                        Button("取消章节星标", systemImage: "bookmark.slash", role: .destructive) {
                            pendingAlert = .removeChapterStar
                        }
                        .disabled(viewModel.isWriting)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.iconPrimary)
                }
                .xmMenuNeutralTint()
                .accessibilityLabel("更多操作")
            }
        }

        if !viewModel.isEditing {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)

            ToolbarSpacer(placement: .bottomBar)

            ToolbarItem(placement: .bottomBar) {
                Button {
                    onOpenNoteRoute(.create(seed: createSeed))
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(isSearchActive)
                .opacity(isSearchActive ? 0 : 1)
                .animation(searchControlAnimation, value: isSearchActive)
                .xmToolbarNeutralTint()
                .accessibilityHidden(isSearchActive)
                .accessibilityLabel("新建书摘")
            }
        }
    }

    private var isSearchActive: Bool {
        isSearchPresented || isSearchFocused || !viewModel.normalizedSearchText.isEmpty
    }

    private var searchControlAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.14)
    }

    private func navigationTitle(_ viewModel: NoteExcerptListViewModel) -> String {
        viewModel.isEditing ? "已选择 \(viewModel.selectedCount) 条" : displayTitle
    }

    private func isNavigationSubtitleVisible(_ viewModel: NoteExcerptListViewModel) -> Bool {
        switch viewModel.phase {
        case .content, .empty:
            true
        case .loading, .failure:
            false
        }
    }

    private func navigationSubtitleText(_ viewModel: NoteExcerptListViewModel) -> String {
        if viewModel.isEditing {
            if viewModel.appliedSearchText.isEmpty {
                "共 \(viewModel.totalCount.formatted()) 条书摘"
            } else {
                "\(viewModel.totalCount.formatted()) 个搜索结果"
            }
        } else if viewModel.appliedSearchText.isEmpty {
            "\(viewModel.totalCount.formatted()) 条书摘"
        } else {
            "\(viewModel.totalCount.formatted()) 个结果"
        }
    }

    private func navigationSubtitleLabel(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
    }

    private func listChangeAnimation(for kind: NoteExcerptListChangeKind) -> Animation? {
        guard !reduceMotion else { return nil }
        return switch kind {
        case .initial:
            nil
        case .search:
            .easeOut(duration: 0.16)
        case .removal:
            .smooth(duration: 0.22)
        case .update:
            .smooth(duration: 0.20)
        case .reorder:
            .smooth(duration: 0.28)
        case .insertion, .pagination, .refresh:
            .easeOut(duration: 0.18)
        }
    }

    /// 进入批量选择时仅收起键盘，保留查询与结果，退出选择后继续恢复同一搜索上下文。
    private func beginEditing(_ viewModel: NoteExcerptListViewModel) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSearchFocused = false
        }
        withAnimation(reduceMotion ? .smooth(duration: 0.12) : .snappy(duration: 0.18)) {
            viewModel.setEditing(true)
        }
    }

    private func batchBar(_ viewModel: NoteExcerptListViewModel) -> some View {
        HStack(spacing: Spacing.base) {
            Button(viewModel.isSelectingAll ? "取消" : (viewModel.isAllSelected ? "取消全选" : "全选")) {
                withAnimation(reduceMotion ? .smooth(duration: 0.12) : .snappy(duration: 0.18)) {
                    viewModel.toggleSelectAll()
                }
            }
            .font(AppTypography.subheadline)

            Text("已选 \(viewModel.selectedCount) 条")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textSecondary)
                .contentTransition(.numericText())

            Spacer(minLength: Spacing.compact)

            Menu {
                Button("移动到书籍", systemImage: "books.vertical") {
                    presentedSheet = .moveBook
                }
                Button("移动到章节", systemImage: "text.book.closed") {
                    prepareChapterSheet(viewModel)
                }
                .disabled(!viewModel.canMoveToChapter)
                Button("设置标签", systemImage: "tag") {
                    prepareTagSheet(viewModel)
                }
                Menu("发送到", systemImage: "paperplane") {
                    if viewModel.configuredExternalDestinations.isEmpty {
                        Button("请先在“我的 > 关联应用”中配置") { }
                            .disabled(true)
                    } else {
                        ForEach(viewModel.configuredExternalDestinations) { destination in
                            Button(destination.displayName, systemImage: destination.systemImageName) {
                                sendSelectedNotes(to: destination, viewModel: viewModel)
                            }
                        }
                    }
                }
                Button("合并书摘", systemImage: "arrow.triangle.merge") {
                    openMerge(viewModel)
                }
                .disabled(!viewModel.canMerge)
            } label: {
                Label("批量操作", systemImage: "ellipsis.circle")
            }
            .disabled(viewModel.selectedNoteIDs.isEmpty || viewModel.isWriting)

            Button(role: .destructive) {
                pendingAlert = .delete(
                    noteIDs: viewModel.selectedNoteIDs.sorted(),
                    count: viewModel.selectedCount
                )
            } label: {
                Image(systemName: "trash")
            }
            .disabled(viewModel.selectedNoteIDs.isEmpty || viewModel.isWriting)
            .accessibilityLabel("删除所选书摘")
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(minHeight: 56)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func batchSheet(
        _ sheet: NoteBatchSheet,
        viewModel: NoteExcerptListViewModel
    ) -> some View {
        switch sheet {
        case .moveBook:
            BookPickerView(
                configuration: BookPickerConfiguration(
                    title: "移动到书籍",
                    scope: .local,
                    selectionMode: .single,
                    allowsCreationFlow: false
                )
            ) { result in
                guard case .single(.local(let book)) = result else { return }
                performWrite("正在移动书摘…") {
                    try await viewModel.moveSelectedNotes(toBookID: book.id)
                }
            }
        case .moveChapter(let options):
            NoteChapterSelectionSheet(
                options: options,
                onSelect: { chapterID in
                    performWrite("正在移动书摘…") {
                        try await viewModel.moveSelectedNotes(toChapterID: chapterID)
                    }
                },
                onCreate: { parentID, title in
                    try await viewModel.createChapterForSelection(
                        named: title,
                        parentID: parentID
                    )
                }
            )
        case .tags(let options, let initialIDs):
            NoteTagSelectionSheet(
                options: options,
                initialIDs: initialIDs,
                onCreate: { title in
                    try await viewModel.createTag(named: title)
                },
                onConfirm: { tags in
                    performWrite("正在更新标签…") {
                        try await viewModel.replaceTagsForSelectedNotes(tagIDs: tags.map(\.id))
                    }
                }
            )
        }
    }

    private func prepareChapterSheet(_ viewModel: NoteExcerptListViewModel) {
        guard viewModel.canMoveToChapter else {
            pendingAlert = .info(title: "无法移动到章节", message: "只能同时移动同一本书中的书摘。")
            return
        }
        Task {
            let toastID = showProcessing("正在读取章节…")
            do {
                let options = try await viewModel.fetchChapterOptionsForSelection()
                toastCenter.dismiss(id: toastID)
                presentedSheet = .moveChapter(options)
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private func prepareTagSheet(_ viewModel: NoteExcerptListViewModel) {
        Task {
            let toastID = showProcessing("正在读取标签…")
            do {
                let bootstrap = try await viewModel.prepareBatchEditing()
                toastCenter.dismiss(id: toastID)
                let initialIDs: Set<Int64>
                if viewModel.selectedCount == 1 {
                    initialIDs = Set(viewModel.selectedItems.first?.tags.map(\.id) ?? [])
                } else {
                    initialIDs = []
                }
                presentedSheet = .tags(bootstrap.tags, initialIDs)
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private func openMerge(_ viewModel: NoteExcerptListViewModel) {
        guard viewModel.canMerge, let bookID = viewModel.selectedItems.first?.bookID else {
            pendingAlert = .info(title: "无法合并", message: "请选择同一本书中的至少两条书摘。")
            return
        }
        let ids = viewModel.selectedNoteIDs.sorted()
        viewModel.setEditing(false)
        onOpenNoteRoute(.mergeNotes(bookID: bookID, noteIDs: ids))
    }

    private func alertDescriptor(
        _ alert: NoteExcerptListAlert,
        viewModel: NoteExcerptListViewModel
    ) -> XMSystemAlertDescriptor {
        switch alert {
        case .delete(let noteIDs, let count):
            XMSystemAlertDescriptor(
                title: count == 1 ? "删除这条书摘？" : "删除所选 \(count) 条书摘？",
                message: "书摘、附图和标签关系将被物理删除，此操作无法撤销。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "删除", role: .destructive) {
                        performWrite("正在删除书摘…") {
                            try await viewModel.deleteNotes(noteIDs)
                        }
                    }
                ]
            )
        case .removeChapterStar:
            XMSystemAlertDescriptor(
                title: "取消章节星标？",
                message: "章节和书摘会保留，只会从星标章节入口移除。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "取消星标") {
                        performWrite("正在取消星标…") {
                            try await viewModel.removeChapterStar()
                        }
                    }
                ]
            )
        case .info(let title, let message):
            XMSystemAlertDescriptor(
                title: title,
                message: message,
                actions: [XMSystemAlertAction(title: "知道了", role: .cancel) { }]
            )
        }
    }

    /// 写操作即时展示不可自动消失的处理中反馈，成功由列表状态变化表达，失败替换为错误 Toast。
    private func performWrite(
        _ message: String,
        operation: @escaping () async throws -> Void
    ) {
        Task {
            let toastID = showProcessing(message)
            do {
                try await operation()
                toastCenter.dismiss(id: toastID)
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private func showProcessing(_ text: String) -> XMToastMessage.ID? {
        toastCenter.processing(text)
        return toastCenter.current?.id
    }

    /// 批量发送期间保持选择现场；全部成功或部分失败都给出可感知结果，取消不伪报成功。
    private func sendSelectedNotes(
        to destination: ExternalAppDestination,
        viewModel: NoteExcerptListViewModel
    ) {
        Task {
            let toastID = showProcessing("正在发送到 \(destination.displayName)…")
            do {
                let summary = try await viewModel.sendSelectedNotes(to: destination)
                toastCenter.dismiss(id: toastID)
                if summary.failedCount == 0 {
                    toastCenter.success("已发送 \(summary.sentCount) 条到 \(destination.displayName)")
                } else if summary.sentCount == 0 {
                    toastCenter.error("发送失败，请检查 \(destination.displayName) 配置或网络")
                } else {
                    toastCenter.error(
                        "已发送 \(summary.sentCount) 条，\(summary.failedCount) 条失败"
                    )
                }
            } catch is CancellationError {
                toastCenter.dismiss(id: toastID)
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private func failureMessage(_ phase: NoteExcerptListPhase) -> String? {
        if case .failure(let message) = phase { return message }
        return nil
    }

    private var createSeed: NoteEditorSeed {
        switch origin {
        case .scope(let scope):
            if case .book(let bookID) = scope {
                NoteEditorSeed(
                    bookId: bookID,
                    chapterId: nil,
                    contentHTML: "",
                    ideaHTML: ""
                )
            } else {
                .empty
            }
        case .chapter(let bookID, let chapterID, _):
            NoteEditorSeed(
                bookId: bookID,
                chapterId: chapterID,
                contentHTML: "",
                ideaHTML: ""
            )
        }
    }

    private func plainContent(_ item: NoteExcerptListItem) -> String {
        item.plainContent
    }

    private func plainIdea(_ item: NoteExcerptListItem) -> String {
        item.plainIdea
    }

    /// 仅为当前书摘中真实存在的内容提供复制动作，并在剪贴板写入后给出对应的轻量反馈。
    @ViewBuilder
    private func copyMenu(_ item: NoteExcerptListItem) -> some View {
        let content = plainContent(item)
        let idea = plainIdea(item)
        let allText = copyAllText(item)
        if !allText.isEmpty {
            Menu {
                if !content.isEmpty {
                    Button {
                        copyToPasteboard(content, feedback: "已复制正文")
                    } label: {
                        XMMenuLabel("正文")
                    }
                }
                if !idea.isEmpty {
                    Button {
                        copyToPasteboard(idea, feedback: "已复制想法")
                    } label: {
                        XMMenuLabel("想法")
                    }
                }
                Button {
                    copyToPasteboard(allText, feedback: "已复制全部")
                } label: {
                    XMMenuLabel("全部")
                }
            } label: {
                XMMenuLabel("复制", systemImage: "doc.on.doc")
            }
        }
    }

    /// 响应用户明确的复制动作写入系统剪贴板；空文本不会产生误导性的成功提示。
    private func copyToPasteboard(_ text: String, feedback: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        toastCenter.success(feedback)
    }

    /// Android 复制“全部”只组合正文和想法，不额外混入书名或章节元信息。
    private func copyAllText(_ item: NoteExcerptListItem) -> String {
        [plainContent(item), plainIdea(item)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func shareText(_ item: NoteExcerptListItem) -> String {
        let content = plainContent(item)
        let idea = plainIdea(item)
        return [item.bookTitle, item.chapterTitle, content, idea]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

private enum NoteExcerptListAlert: Identifiable {
    case delete(noteIDs: [Int64], count: Int)
    case removeChapterStar
    case info(title: String, message: String)

    var id: String {
        switch self {
        case .delete(let noteIDs, _): "delete-\(noteIDs.map(String.init).joined(separator: "-"))"
        case .removeChapterStar: "remove-chapter-star"
        case .info(let title, _): "info-\(title)"
        }
    }
}

private enum NoteBatchSheet: Identifiable {
    case moveBook
    case moveChapter([NoteEditorChapterOption])
    case tags([NoteEditorTagOption], Set<Int64>)

    var id: String {
        switch self {
        case .moveBook: "move-book"
        case .moveChapter: "move-chapter"
        case .tags: "tags"
        }
    }
}

private extension NoteExcerptSortRule {
    var displayTitle: String {
        switch self {
        case .createdAscending: "时间从早到晚"
        case .createdDescending: "时间从晚到早"
        case .random: "随机顺序"
        }
    }
}
