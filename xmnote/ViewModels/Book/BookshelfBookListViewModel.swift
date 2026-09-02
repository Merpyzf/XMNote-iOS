/**
 * [INPUT]: 依赖 BookshelfRepositoryProtocol 提供二级书籍列表观察流，依赖 BookshelfBookListRoute 描述当前聚合上下文
 * [OUTPUT]: 对外提供 BookshelfBookListViewModel，驱动二级书籍列表加载、空态、搜索、编辑选择、分组移动、可等待批量标签保存与实时刷新
 * [POS]: Book 模块二级书籍列表状态编排器，被 BookshelfBookListView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 二级书籍列表搜索输入防抖策略，避免连续输入期间反复重建列表观察流。
private enum BookshelfBookListSearchDebouncePolicy {
    static let delayNanoseconds: UInt64 = 200_000_000
}

@MainActor
@Observable
final class BookshelfBookListViewModel {
    let route: BookshelfBookListRoute
    var snapshot: BookshelfBookListSnapshot = .empty
    var contentState: BookshelfContentState = .loading
    var hasCompletedInitialLoad = false
    var searchKeyword: String = "" {
        didSet {
            guard normalizedSearchKeyword(oldValue) != normalizedSearchKeyword(searchKeyword) else { return }
            scheduleSearchObservationRestart()
        }
    }
    var displaySetting: BookshelfDisplaySetting
    var isEditing = false
    var selectedBookIDs: [Int64] = []
    private var writeActionState = BookshelfWriteActionState<BookshelfBookListEditAction>()
    var actionFeedback: BookshelfActionFeedback? {
        get { writeActionState.feedback }
        set { writeActionState.feedback = newValue }
    }
    var actionNotice: String? {
        get { writeActionState.notice }
        set { writeActionState.notice = newValue }
    }
    var activeWriteAction: BookshelfBookListEditAction? {
        get { writeActionState.activeAction }
        set { writeActionState.activeAction = newValue }
    }
    var writeError: String? {
        get { writeActionState.error }
        set { writeActionState.error = newValue }
    }
    var activeBatchSheet: BookshelfBatchEditSheet?
    var activeBatchTagModeConfirmation: BookshelfBatchTagModeConfirmation?
    var activeMoveOutConfirmation: BookshelfMoveOutPlacementConfirmation?
    var activeDeleteConfirmation: BookshelfBookListDeleteConfirmation?
    var activeNameEdit: BookshelfBookListNameEdit?
    var nameEditText = ""
    var isLoadingBatchOptions = false

    private let repository: any BookshelfRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var batchOptionsTask: Task<Void, Never>?
    private var feedbackClearTask: Task<Void, Never>?

    var navigationTitle: String {
        snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? route.title : snapshot.title
    }

    var subtitle: String {
        snapshot.subtitle.isEmpty ? route.subtitleHint : snapshot.subtitle
    }

    var selectedBookIDSet: Set<Int64> {
        Set(selectedBookIDs)
    }

    var selectedCount: Int {
        selectedBookIDs.count
    }

    var visibleBookIDs: [Int64] {
        snapshot.books.map(\.id)
    }

    var visibleOrderItems: [BookshelfBookListOrderItem] {
        snapshot.books.map { BookshelfBookListOrderItem(id: $0.id, isPinned: $0.pinned) }
    }

    var isAllVisibleSelected: Bool {
        let visibleIDs = Set(visibleBookIDs)
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedBookIDSet)
    }

    var canEnterEditing: Bool {
        contentState == .content && !visibleBookIDs.isEmpty && activeWriteAction == nil
    }

    var canReorderBooksInDefaultGroup: Bool {
        isEditing
            && activeWriteAction == nil
            && !hasSearchKeyword
            && contentState == .content
            && displaySetting.sortCriteria == .custom
            && defaultGroupID != nil
            && snapshot.sections.count == 1
    }

    var movableBookIDs: Set<Int64> {
        guard canReorderBooksInDefaultGroup else { return [] }
        return Set(snapshot.books.filter { !$0.pinned }.map(\.id))
    }

    var supportsContextPin: Bool {
        defaultGroupID != nil
    }

    var hasSearchKeyword: Bool {
        !normalizedSearchKeyword(searchKeyword).isEmpty
    }

    var searchReorderDisabledNotice: String? {
        guard isEditing,
              hasSearchKeyword,
              activeWriteAction == nil,
              !isLoadingBatchOptions,
              contentState == .content,
              displaySetting.sortCriteria == .custom,
              defaultGroupID != nil,
              snapshot.sections.count == 1 else {
            return nil
        }
        return "搜索结果暂不支持排序，清除搜索后可调整组内顺序"
    }

    var editActions: [BookshelfBookListEditAction] {
        BookshelfBookListActionPolicy.editActions(for: route.context)
    }

    private var defaultGroupID: Int64? {
        guard case .defaultGroup(let groupID) = route.context else { return nil }
        return groupID
    }

    /// 注入路由和仓储，并启动二级列表观察流。
    init(
        route: BookshelfBookListRoute,
        repository: any BookshelfRepositoryProtocol
    ) {
        self.route = route
        self.repository = repository
        let settings = repository.fetchBookshelfDisplaySettings(scope: .bookList)
        self.displaySetting = settings[route.context.dimension] ?? .defaultBookListValue(for: route.context.dimension)
        startObservation()
    }

    /// 取消二级列表观察与写入任务，避免页面释放后继续回写 UI 状态。
    isolated deinit {
        observationTask?.cancel()
        searchDebounceTask?.cancel()
        writeTask?.cancel()
        batchOptionsTask?.cancel()
        feedbackClearTask?.cancel()
    }

    /// 清空搜索关键词并恢复完整列表。
    func clearSearchKeyword() {
        searchKeyword = ""
    }

    /// 处理列表内搜索输入变化，统一由页面意图驱动关键词过滤与观察流刷新。
    func searchQueryDidChange(_ keyword: String) {
        if normalizedSearchKeyword(keyword).isEmpty {
            clearSearchKeyword()
        } else {
            setSearchKeyword(keyword)
        }
    }

    /// 提交列表内搜索输入，空查询恢复完整列表，非空查询写入最终关键词。
    func submitSearchQuery(_ keyword: String) {
        searchQueryDidChange(keyword)
    }

    /// 保存二级列表显示设置，并重启观察流让排序、分区和布局立即生效。
    func updateDisplaySetting(_ setting: BookshelfDisplaySetting) {
        let sanitized = sanitizedDisplaySetting(setting)
        guard sanitized != displaySetting else { return }
        displaySetting = sanitized
        repository.saveBookshelfDisplaySetting(sanitized, for: route.context.dimension, scope: .bookList)
        restartObservation()
    }

    /// 进入二级列表编辑态，只改变本地选择状态，不触发任何写入。
    func enterEditing() {
        guard canEnterEditing else { return }
        isEditing = true
        actionNotice = nil
        writeError = nil
        pruneSelectionToVisibleBooks()
    }

    /// 退出二级列表编辑态并清空本地选择。
    func exitEditing() {
        isEditing = false
        selectedBookIDs.removeAll()
        activeBatchSheet = nil
        activeBatchTagModeConfirmation = nil
        activeMoveOutConfirmation = nil
        activeDeleteConfirmation = nil
        activeNameEdit = nil
        nameEditText = ""
        cancelBatchOptionsLoading()
        actionNotice = nil
        writeError = nil
    }

    /// 切换单本书籍的本地选中状态。
    func toggleSelection(_ bookID: Int64) {
        guard isEditing, visibleBookIDs.contains(bookID) else { return }
        cancelBatchOptionsLoading()
        if let index = selectedBookIDs.firstIndex(of: bookID) {
            selectedBookIDs.remove(at: index)
        } else {
            selectedBookIDs.append(bookID)
        }
        actionNotice = nil
        writeError = nil
    }

    /// 清空二级列表本地选择，供整理态顶部“取消全选”语义复用。
    func clearSelection() {
        guard isEditing else { return }
        cancelBatchOptionsLoading()
        selectedBookIDs.removeAll()
        actionNotice = nil
        writeError = nil
    }

    /// 选择当前可见的全部书籍。
    func selectAllVisible() {
        guard isEditing else { return }
        cancelBatchOptionsLoading()
        if hasSearchKeyword {
            for id in visibleBookIDs where !selectedBookIDs.contains(id) {
                selectedBookIDs.append(id)
            }
        } else {
            selectedBookIDs = visibleBookIDs
        }
        actionNotice = nil
        writeError = nil
    }

    /// 取消当前可见书籍的选择；搜索中仅移除搜索结果，非搜索状态下清空全部选择。
    func clearVisibleSelection() {
        guard isEditing else { return }
        cancelBatchOptionsLoading()
        if hasSearchKeyword {
            let visibleIDs = Set(visibleBookIDs)
            selectedBookIDs.removeAll { visibleIDs.contains($0) }
        } else {
            selectedBookIDs.removeAll()
        }
        actionNotice = nil
        writeError = nil
    }

    /// 反选当前可见书籍，搜索中保留不可见对象。
    func invertVisibleSelection() {
        guard isEditing else { return }
        cancelBatchOptionsLoading()
        let selected = selectedBookIDSet
        let visibleIDs = Set(visibleBookIDs)
        let hiddenSelection = hasSearchKeyword ? selectedBookIDs.filter { !visibleIDs.contains($0) } : []
        selectedBookIDs = hiddenSelection + visibleBookIDs.filter { !selected.contains($0) }
        actionNotice = nil
        writeError = nil
    }

    /// 执行二级列表编辑动作；已核对的排序/置顶和第一批批量写入会走 Repository，未核对动作保留保护提示。
    func performEditAction(_ action: BookshelfBookListEditAction) {
        if action.requiresSelection, selectedBookIDs.isEmpty {
            actionNotice = "请先选择书籍"
            return
        }
        switch action {
        case .pin:
            pinSelectedBooks()
        case .unpin:
            unpinSelectedBooks()
        case .moveToStart:
            moveSelectedBooks(toStart: true)
        case .moveToEnd:
            moveSelectedBooks(toStart: false)
        case .moveToGroup:
            presentMoveGroupSheet()
        case .addToBookList:
            presentBookCollectionSheet()
        case .exportNote, .exportBook:
            performPlaceholderAction(action)
        case .moveOut:
            presentMoveOutConfirmation()
        case .setTag:
            presentTagMutationFlow()
        case .setSource, .setReadStatus:
            presentBatchSheet(for: action)
        case .renameGroup, .renameTag, .renameSource:
            presentNameEdit(for: action)
        case .deleteBooks:
            activeDeleteConfirmation = .init(kind: .books(bookIDs: selectedBookIDs))
            actionNotice = nil
            writeError = nil
        case .deleteGroup, .deleteTag, .deleteSource:
            presentDeleteConfirmation(for: action)
        case .reorder:
            performPlaceholderAction(action)
        }
    }

    /// 提交显式标签命令；任务由标签 Sheet 等待，Repository 在一个事务内完成全部关系变更。
    func submitTagMutation(
        bookIDs: [Int64],
        tagIDs: [Int64],
        mode: BookTagMutationMode
    ) async -> Bool {
        guard !bookIDs.isEmpty,
              selectedBookIDs == bookIDs,
              activeWriteAction == nil else { return false }
        batchOptionsTask?.cancel()
        isLoadingBatchOptions = false
        activeWriteAction = .setTag
        writeError = nil
        actionFeedback = nil

        do {
            try await repository.mutateBooksTags(bookIDs: bookIDs, tagIDs: tagIDs, mode: mode)
            try Task.checkCancellation()
            selectedBookIDs.removeAll()
            activeWriteAction = nil
            actionFeedback = nil
            restartObservation()
            return true
        } catch is CancellationError {
            activeWriteAction = nil
            actionFeedback = nil
            return false
        } catch {
            writeActionState.finishFailure(error)
            restartObservation()
            return false
        }
    }

    /// 提交批量来源写入，成功后由观察流刷新来源维度与当前二级列表。
    func submitBatchSource(sourceID: Int64) {
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        runWriteAction(.setSource, successMessage: "来源已更新") {
            try await self.repository.batchSetBooksSource(bookIDs: bookIDs, sourceID: sourceID)
        }
    }

    /// 提交批量阅读状态写入；读完未选择评分时按 0 分保存，时间统一转成毫秒时间戳。
    func submitBatchReadStatus(statusID: Int64, changedAt: Date, ratingScore: Int64?) {
        let bookIDs = selectedBookIDs
        let input = BookshelfBatchReadStatusInput(
            statusID: statusID,
            changedAt: Int64(changedAt.timeIntervalSince1970 * 1000),
            ratingScore: ratingScore
        )
        activeBatchSheet = nil
        runWriteAction(.setReadStatus, successMessage: "阅读状态已更新") {
            try await self.repository.batchSetBookReadStatus(bookIDs: bookIDs, input: input)
        }
    }

    /// 提交批量移入分组，成功后由观察流刷新当前列表与默认书架。
    func submitMoveToGroup(groupID: Int64) {
        let bookIDs = selectedBookIDs
        let currentGroupID = defaultGroupID ?? 0
        activeBatchSheet = nil
        runWriteAction(.moveToGroup, successMessage: "已移入分组") {
            try await self.repository.moveBooks(
                bookIDs,
                fromGroup: currentGroupID,
                toGroup: groupID
            )
        }
    }

    /// 提交批量加入书单，成功后由观察流刷新关联数据。
    func submitBookCollection(_ collectionID: Int64) {
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        runWriteAction(.addToBookList, successMessage: "已加入书单") {
            try await self.repository.addBooks(bookIDs, toCollection: collectionID)
        }
    }

    /// 在移组面板内新建分组，并返回可直接选中的目标分组选项。
    func createMoveTargetGroup(named name: String) async throws -> BookEditorNamedOption {
        try await repository.createGroup(named: name)
    }

    /// 在加入书单面板内新建手动书单，并返回可直接选中的目标书单。
    func createBookCollection(named name: String) async throws -> BookCollectionSummary {
        try await repository.createBookCollection(title: name)
    }

    /// 在标签面板内新建标签，并返回可直接选中的标签选项。
    func createBatchTag(named name: String) async throws -> BookEditorNamedOption {
        try await repository.createTag(named: name)
    }

    /// 在来源面板内新建来源，并返回可直接选中的来源选项。
    func createBatchSource(named name: String) async throws -> BookshelfSourceOption {
        try await repository.createSource(named: name)
    }

    /// 提交从当前分组移出，placement 决定回到默认书架的头部或尾部。
    func submitMoveOut(placement: GroupBooksPlacement) {
        let bookIDs = selectedBookIDs
        activeMoveOutConfirmation = nil
        runWriteAction(.moveOut, successMessage: "已移出分组") {
            try await self.repository.moveBooksOutOfGroup(bookIDs: bookIDs, placement: placement)
        }
    }

    /// 提交二级列表批量删书，成功后清空选择并由观察流刷新当前列表。
    func submitDeleteBooks() {
        let bookIDs: [Int64]
        if case .books(let targetIDs) = activeDeleteConfirmation?.kind {
            bookIDs = targetIDs
        } else {
            bookIDs = selectedBookIDs
        }
        activeDeleteConfirmation = nil
        runWriteAction(.deleteBooks, successMessage: "已删除 \(bookIDs.count) 本") {
            try await self.repository.deleteBooks(bookIDs)
        }
    }

    /// 单本置顶，供二级列表长按菜单使用；仅默认分组上下文开放。
    func pinBook(_ bookID: Int64) {
        guard let groupID = defaultGroupID else { return }
        guard snapshot.books.first(where: { $0.id == bookID })?.pinned == false else {
            actionNotice = "该书籍已置顶"
            return
        }
        runWriteAction(.pin, successMessage: "已置顶") {
            try await self.repository.pinBooksInGroup(groupID: groupID, bookIDs: [bookID])
        }
    }

    /// 单本取消置顶，供二级列表长按菜单使用；仅默认分组上下文开放。
    func unpinBook(_ bookID: Int64) {
        guard defaultGroupID != nil else { return }
        guard snapshot.books.first(where: { $0.id == bookID })?.pinned == true else {
            actionNotice = "该书籍未置顶"
            return
        }
        runWriteAction(.unpin, successMessage: "已取消置顶") {
            try await self.repository.unpinBooksInGroup(bookIDs: [bookID])
        }
    }

    /// 打开单本书删除确认，供二级列表长按菜单使用。
    func presentDeleteBookConfirmation(bookID: Int64) {
        activeDeleteConfirmation = BookshelfBookListDeleteConfirmation(kind: .books(bookIDs: [bookID]))
        actionNotice = nil
        writeError = nil
    }

    /// 展示尚未迁移的跨模块能力占位提示。
    func presentContextPlaceholder(_ message: String) {
        writeError = nil
        actionNotice = message
    }

    /// 删除当前默认分组上下文，并按 placement 安置组内书籍。
    func submitDeleteGroup(placement: GroupBooksPlacement) {
        guard case .defaultGroup(let groupID) = route.context else { return }
        activeDeleteConfirmation = nil
        runWriteAction(.deleteGroup, successMessage: "分组已删除") {
            try await self.repository.deleteGroup(groupID: groupID, placement: placement)
        }
    }

    /// 删除当前标签上下文。
    func submitDeleteTag() {
        guard case .tag(let tagID) = route.context, let tagID else { return }
        activeDeleteConfirmation = nil
        runWriteAction(.deleteTag, successMessage: "标签已删除") {
            try await self.repository.deleteTag(tagID: tagID)
        }
    }

    /// 删除当前来源上下文。
    func submitDeleteSource() {
        guard case .source(let sourceID) = route.context, let sourceID else { return }
        activeDeleteConfirmation = nil
        runWriteAction(.deleteSource, successMessage: "来源已删除") {
            try await self.repository.deleteSource(sourceID: sourceID)
        }
    }

    /// 提交当前上下文重命名输入，Repository 负责重名校验与真实写入。
    func submitNameEdit() {
        guard let activeNameEdit else { return }
        let name = nameEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionNotice = "\(activeNameEdit.action.title)名称不能为空"
            return
        }
        self.activeNameEdit = nil
        switch activeNameEdit.action {
        case .renameGroup:
            guard case .defaultGroup(let groupID) = route.context else { return }
            runWriteAction(.renameGroup, successMessage: "分组已重命名") {
                try await self.repository.renameGroup(groupID: groupID, newName: name)
            }
        case .renameTag:
            guard case .tag(let tagID) = route.context, let tagID else { return }
            runWriteAction(.renameTag, successMessage: "标签已重命名") {
                try await self.repository.renameTag(tagID: tagID, newName: name)
            }
        case .renameSource:
            guard case .source(let sourceID) = route.context, let sourceID else { return }
            runWriteAction(.renameSource, successMessage: "来源已重命名") {
                try await self.repository.renameSource(sourceID: sourceID, newName: name)
            }
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook, .deleteGroup, .deleteTag, .deleteSource, .deleteBooks:
            return
        }
    }

    /// 按 UIKit 拖拽结束后的最终 ID 顺序提交默认分组内排序。
    func commitBooksInDefaultGroupOrder(_ orderedBookIDs: [Int64]) {
        guard let groupID = defaultGroupID,
              canReorderBooksInDefaultGroup,
              orderedBookIDs != visibleBookIDs else {
            return
        }
        runWriteAction(.reorder, successMessage: "排序已更新") {
            try await self.repository.updateBooksInGroupOrder(groupID: groupID, orderedBookIDs: orderedBookIDs)
        }
    }

    private func pinSelectedBooks() {
        guard let groupID = defaultGroupID else {
            performPlaceholderAction(.pin)
            return
        }
        let targetIDs = selectedBookIDs.filter { selectedID in
            snapshot.books.first(where: { $0.id == selectedID })?.pinned == false
        }
        guard !targetIDs.isEmpty else {
            actionNotice = "所选书籍已置顶"
            selectedBookIDs.removeAll()
            return
        }
        runWriteAction(.pin, successMessage: "已置顶 \(targetIDs.count) 本") {
            try await self.repository.pinBooksInGroup(groupID: groupID, bookIDs: targetIDs)
        }
    }

    private func unpinSelectedBooks() {
        guard defaultGroupID != nil else {
            performPlaceholderAction(.unpin)
            return
        }
        let targetIDs = selectedBookIDs.filter { selectedID in
            snapshot.books.first(where: { $0.id == selectedID })?.pinned == true
        }
        guard !targetIDs.isEmpty else {
            actionNotice = "所选书籍未置顶"
            selectedBookIDs.removeAll()
            return
        }
        runWriteAction(.unpin, successMessage: "已取消置顶 \(targetIDs.count) 本") {
            try await self.repository.unpinBooksInGroup(bookIDs: targetIDs)
        }
    }

    private func moveSelectedBooks(toStart: Bool) {
        guard let groupID = defaultGroupID else {
            performPlaceholderAction(toStart ? .moveToStart : .moveToEnd)
            return
        }
        guard !hasSearchKeyword else {
            actionNotice = "搜索结果不支持移动排序，清除搜索后可调整组内顺序"
            return
        }
        guard displaySetting.sortCriteria == .custom else {
            actionNotice = "仅手动排序下支持移动到最前或最后"
            return
        }
        let targetIDs = selectedBookIDs.filter { selectedID in
            snapshot.books.first(where: { $0.id == selectedID })?.pinned == false
        }
        guard !targetIDs.isEmpty else {
            actionNotice = "至少选择一本非置顶书籍后才能移动"
            selectedBookIDs.removeAll()
            return
        }
        let action: BookshelfBookListEditAction = toStart ? .moveToStart : .moveToEnd
        let currentItems = visibleOrderItems
        runWriteAction(action, successMessage: toStart ? "已移到最前" : "已移到最后") {
            if toStart {
                try await self.repository.moveBooksInGroupToStart(targetIDs, groupID: groupID, currentItems: currentItems)
            } else {
                try await self.repository.moveBooksInGroupToEnd(targetIDs, groupID: groupID, currentItems: currentItems)
            }
        }
    }

    /// 拉取批量编辑候选项并打开对应 Sheet；Task 可被页面释放或下一次打开请求取消。
    /// - Note: 只在主线程回写 Sheet 状态；Repository 仍是唯一数据入口，避免 ViewModel 直接访问数据库。
    private func presentBatchSheet(for action: BookshelfBookListEditAction) {
        guard activeWriteAction == nil, !isLoadingBatchOptions, !selectedBookIDs.isEmpty else { return }
        let bookIDs = selectedBookIDs
        isLoadingBatchOptions = true
        actionNotice = "正在加载\(action.title)选项…"
        writeError = nil
        batchOptionsTask?.cancel()
        batchOptionsTask = Task {
            do {
                let options = try await repository.fetchBookshelfBatchEditOptions(bookIDs: bookIDs)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.isLoadingBatchOptions = false
                        self.actionNotice = nil
                        return
                    }
                    self.isLoadingBatchOptions = false
                    self.presentBatchSheet(action, options: options, bookIDs: bookIDs)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isLoadingBatchOptions = false
                    self.writeError = error.localizedDescription
                    self.actionNotice = error.localizedDescription
                }
            }
        }
    }

    /// 按当前选择范围决定单本替换或多本显式添加/移除入口，确认前不读取也不写入数据库。
    private func presentTagMutationFlow() {
        guard activeWriteAction == nil, !isLoadingBatchOptions, !selectedBookIDs.isEmpty else { return }
        let bookIDs = selectedBookIDs
        if bookIDs.count == 1 {
            presentBatchTagsSheet(bookIDs: bookIDs, mode: .replace)
        } else {
            activeBatchTagModeConfirmation = BookshelfBatchTagModeConfirmation(bookIDs: bookIDs)
            actionNotice = nil
            writeError = nil
        }
    }

    /// 确认多本书标签变更模式；只有选择范围仍与确认弹窗快照一致时才打开标签 Sheet。
    func confirmBatchTagMode(_ mode: BookTagMutationMode, bookIDs: [Int64]) {
        guard mode != .replace, selectedBookIDs == bookIDs else { return }
        activeBatchTagModeConfirmation = nil
        presentBatchTagsSheet(bookIDs: bookIDs, mode: mode)
    }

    /// 立即打开标签 Sheet，并在 Sheet 内容区异步刷新候选项，避免底部操作栏闪出读取文案。
    /// - Note: Repository 读取任务可被新请求取消；成功或失败后只在原 Sheet 仍存在且选择集合未变化时回写 MainActor 状态。
    private func presentBatchTagsSheet(bookIDs: [Int64], mode: BookTagMutationMode) {
        batchOptionsTask?.cancel()
        isLoadingBatchOptions = false
        actionNotice = nil
        writeError = nil
        activeBatchSheet = .tags(
            mode: mode,
            bookIDs: bookIDs,
            options: [],
            initialSelectedIDs: [],
            allowsEmptySelection: mode == .replace,
            isLoading: true,
            errorMessage: nil
        )
        batchOptionsTask = Task {
            do {
                let options = try await repository.fetchBookshelfBatchEditOptions(bookIDs: bookIDs)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.activeBatchSheet = nil
                        self.actionNotice = nil
                        return
                    }
                    guard self.activeBatchSheet?.id == "tags-\(mode.rawValue)" else { return }
                    self.activeBatchSheet = .tags(
                        mode: mode,
                        bookIDs: bookIDs,
                        options: options.tags,
                        initialSelectedIDs: mode == .replace ? options.initialTagIDs : [],
                        allowsEmptySelection: mode == .replace,
                        isLoading: false,
                        errorMessage: nil
                    )
                    self.actionNotice = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.activeBatchSheet = nil
                        self.actionNotice = nil
                        return
                    }
                    guard self.activeBatchSheet?.id == "tags-\(mode.rawValue)" else { return }
                    self.activeBatchSheet = .tags(
                        mode: mode,
                        bookIDs: bookIDs,
                        options: [],
                        initialSelectedIDs: [],
                        allowsEmptySelection: mode == .replace,
                        isLoading: false,
                        errorMessage: error.localizedDescription
                    )
                    self.writeError = nil
                    self.actionNotice = nil
                }
            }
        }
    }

    /// 拉取目标分组选项并打开移组 Sheet，避免 ViewModel 直接查询数据库。
    private func presentMoveGroupSheet() {
        guard activeWriteAction == nil, !isLoadingBatchOptions, !selectedBookIDs.isEmpty else { return }
        isLoadingBatchOptions = false
        actionNotice = nil
        writeError = nil
        let bookIDs = selectedBookIDs
        let excludingGroupID = defaultGroupID
        batchOptionsTask?.cancel()
        activeBatchSheet = .moveGroup(
            options: [],
            isLoading: true,
            errorMessage: nil
        )
        batchOptionsTask = Task {
            do {
                let options = try await repository.fetchBookshelfMoveTargetGroups(excludingGroupID: excludingGroupID)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.isLoadingBatchOptions = false
                        self.actionNotice = nil
                        self.activeBatchSheet = nil
                        return
                    }
                    guard self.activeBatchSheet?.id == "moveGroup" else { return }
                    self.isLoadingBatchOptions = false
                    self.activeBatchSheet = .moveGroup(
                        options: options,
                        isLoading: false,
                        errorMessage: nil
                    )
                    self.actionNotice = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.isLoadingBatchOptions = false
                        self.actionNotice = nil
                        self.activeBatchSheet = nil
                        return
                    }
                    guard self.activeBatchSheet?.id == "moveGroup" else { return }
                    self.isLoadingBatchOptions = false
                    self.activeBatchSheet = .moveGroup(
                        options: [],
                        isLoading: false,
                        errorMessage: error.localizedDescription
                    )
                    self.writeError = nil
                    self.actionNotice = nil
                }
            }
        }
    }

    /// 拉取手动书单候选项并打开加入书单 Sheet，避免 ViewModel 直接查询数据库。
    private func presentBookCollectionSheet() {
        guard activeWriteAction == nil, !isLoadingBatchOptions, !selectedBookIDs.isEmpty else { return }
        isLoadingBatchOptions = false
        actionNotice = nil
        writeError = nil
        let bookIDs = selectedBookIDs
        batchOptionsTask?.cancel()
        activeBatchSheet = .bookCollection(
            options: [],
            isLoading: true,
            errorMessage: nil
        )
        batchOptionsTask = Task {
            do {
                let options = try await repository.fetchManualBookCollections()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.isLoadingBatchOptions = false
                        self.actionNotice = nil
                        self.activeBatchSheet = nil
                        return
                    }
                    guard self.activeBatchSheet?.id == "bookCollection" else { return }
                    self.isLoadingBatchOptions = false
                    self.activeBatchSheet = .bookCollection(
                        options: options,
                        isLoading: false,
                        errorMessage: nil
                    )
                    self.actionNotice = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.isLoadingBatchOptions = false
                        self.actionNotice = nil
                        self.activeBatchSheet = nil
                        return
                    }
                    guard self.activeBatchSheet?.id == "bookCollection" else { return }
                    self.isLoadingBatchOptions = false
                    self.activeBatchSheet = .bookCollection(
                        options: [],
                        isLoading: false,
                        errorMessage: error.localizedDescription
                    )
                    self.writeError = nil
                    self.actionNotice = nil
                }
            }
        }
    }

    /// 打开默认分组移出确认，用户选择回到默认书架的头部或尾部。
    private func presentMoveOutConfirmation() {
        guard case .defaultGroup = route.context else {
            performPlaceholderAction(.moveOut)
            return
        }
        guard activeWriteAction == nil, !selectedBookIDs.isEmpty else { return }
        activeMoveOutConfirmation = BookshelfMoveOutPlacementConfirmation(selectedCount: selectedBookIDs.count)
        actionNotice = nil
        writeError = nil
    }

    /// 打开当前上下文对象的重命名输入弹窗。
    private func presentNameEdit(for action: BookshelfBookListEditAction) {
        guard activeWriteAction == nil else { return }
        guard BookshelfBookListActionPolicy.canManageCurrentContext(action, in: route.context) else {
            performPlaceholderAction(action)
            return
        }
        let currentName = route.title
        nameEditText = currentName
        activeNameEdit = BookshelfBookListNameEdit(action: action, currentName: currentName)
        actionNotice = nil
        writeError = nil
    }

    /// 打开当前上下文对象的删除确认弹窗。
    private func presentDeleteConfirmation(for action: BookshelfBookListEditAction) {
        guard activeWriteAction == nil else { return }
        guard BookshelfBookListActionPolicy.canManageCurrentContext(action, in: route.context) else {
            performPlaceholderAction(action)
            return
        }
        switch action {
        case .deleteGroup:
            activeDeleteConfirmation = BookshelfBookListDeleteConfirmation(kind: .group(title: route.title))
        case .deleteTag:
            activeDeleteConfirmation = BookshelfBookListDeleteConfirmation(kind: .tag(title: route.title))
        case .deleteSource:
            activeDeleteConfirmation = BookshelfBookListDeleteConfirmation(kind: .source(title: route.title))
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook, .renameGroup, .renameTag, .renameSource, .deleteBooks:
            return
        }
        actionNotice = nil
        writeError = nil
    }

    /// 取消正在加载的批量编辑候选项，避免选择集合变化后继续打开旧快照 Sheet。
    private func cancelBatchOptionsLoading() {
        batchOptionsTask?.cancel()
        batchOptionsTask = nil
        isLoadingBatchOptions = false
    }

    /// 根据候选项快照打开具体批量编辑 Sheet。
    private func presentBatchSheet(
        _ action: BookshelfBookListEditAction,
        options: BookshelfBatchEditOptions,
        bookIDs: [Int64]
    ) {
        switch action {
        case .setTag:
            return
        case .setSource:
            guard !options.sources.isEmpty else {
                actionNotice = "暂无可用来源"
                return
            }
            activeBatchSheet = .source(
                options: options.sources,
                initialSelectedID: preferredSourceID(from: options)
            )
            actionNotice = nil
        case .setReadStatus:
            guard !options.readStatuses.isEmpty else {
                actionNotice = "暂无可用阅读状态"
                return
            }
            activeBatchSheet = .readStatus(
                options: options.readStatuses,
                initialStatusID: preferredReadStatusID(from: options),
                initialChangedAt: preferredReadStatusChangedAt(from: options),
                initialRatingScore: options.initialRatingScore
            )
            actionNotice = nil
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .exportNote, .exportBook, .renameGroup, .deleteGroup, .renameTag, .deleteTag, .renameSource, .deleteSource, .deleteBooks:
            return
        }
    }

    /// 为来源 Sheet 选择进入时的默认来源，优先保留单本书当前来源，其次沿用来源维度上下文。
    private func preferredSourceID(from options: BookshelfBatchEditOptions) -> Int64? {
        if let sourceID = options.initialSourceID {
            return sourceID
        }
        if case .source(let sourceID) = route.context, let sourceID {
            return sourceID
        }
        return nil
    }

    /// 为阅读状态 Sheet 选择进入时的默认状态，优先保留单本书当前状态，其次沿用状态维度上下文。
    private func preferredReadStatusID(from options: BookshelfBatchEditOptions) -> Int64? {
        if let statusID = options.initialReadStatusID {
            return statusID
        }
        if case .readStatus(let statusID) = route.context, let statusID {
            return statusID
        }
        return options.readStatuses.first(where: { $0.id == BookEntryReadingStatus.reading.rawValue })?.id
            ?? options.readStatuses.first?.id
    }

    /// 将单本书当前阅读状态时间转换为 Sheet 可编辑的日期，缺失时交给 Sheet 使用当前时间。
    private func preferredReadStatusChangedAt(from options: BookshelfBatchEditOptions) -> Date? {
        guard let timestamp = options.initialReadStatusChangedAt, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }

    /// 启动写操作任务；状态只在主线程回写，失败后保留当前选择并通过观察流恢复列表。
    /// - Note: Task 可被页面释放时自然取消；Repository 写入完成后再回到 MainActor 更新 UI，避免竞态污染选择状态。
    private func runWriteAction(
        _ action: BookshelfBookListEditAction,
        successMessage: String,
        operation: @escaping () async throws -> Void
    ) {
        guard activeWriteAction == nil else { return }
        batchOptionsTask?.cancel()
        isLoadingBatchOptions = false
        writeActionState.start(action)
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await operation()
                await MainActor.run {
                    self.selectedBookIDs.removeAll()
                    let feedback = self.writeActionState.finishSuccess(successMessage)
                    self.clearSuccessFeedbackLater(feedback)
                    self.restartObservation()
                }
            } catch {
                await MainActor.run {
                    self.writeActionState.finishFailure(error)
                    self.restartObservation()
                }
            }
        }
    }

    /// 成功反馈短驻留后自动收起；警告和错误不自动清除，等用户下一次操作覆盖。
    private func clearSuccessFeedbackLater(_ feedback: BookshelfActionFeedback) {
        feedbackClearTask?.cancel()
        feedbackClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run {
                self?.writeActionState.clearFeedback(ifMatches: feedback)
            }
        }
    }

    /// 展示未开放写入动作的保护提示，避免绕过 Android 数据语义核对。
    private func performPlaceholderAction(_ action: BookshelfBookListEditAction) {
        if action == .addToBookList {
            actionNotice = "书单添加将在书单模块开发时开放"
            return
        }
        if action == .exportNote || action == .exportBook {
            actionNotice = "\(action.title)将在导出模块迁移时开放"
            return
        }
        actionNotice = "\(action.title)需先完成 Android 数据语义核对后再开放"
    }

    private func startObservation() {
        if !hasCompletedInitialLoad {
            contentState = .loading
        }
        let context = route.context
        let currentSetting = displaySetting
        let currentKeyword = normalizedSearchKeyword(searchKeyword)
        observationTask = Task {
            do {
                for try await snapshot in repository.observeBookshelfBookList(
                    context: context,
                    setting: currentSetting,
                    searchKeyword: currentKeyword
                ) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.snapshot = snapshot
                        self.hasCompletedInitialLoad = true
                        self.contentState = snapshot.books.isEmpty ? .empty : .content
                        self.pruneSelectionToVisibleBooks()
                    }
                }
            } catch {
                await MainActor.run {
                    self.hasCompletedInitialLoad = true
                    self.contentState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func restartObservation() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        restartObservationNow()
    }

    private func restartObservationNow() {
        observationTask?.cancel()
        startObservation()
    }

    /// 列表内搜索输入稳定 200ms 后再重启观察流；新输入会取消旧任务，避免连续敲字时反复读取二级列表快照。
    private func scheduleSearchObservationRestart() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: BookshelfBookListSearchDebouncePolicy.delayNanoseconds)
                try Task.checkCancellation()
                self?.restartObservationAfterDebounce()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func restartObservationAfterDebounce() {
        searchDebounceTask = nil
        restartObservationNow()
    }

    private func normalizedSearchKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setSearchKeyword(_ keyword: String) {
        let normalized = normalizedSearchKeyword(keyword)
        guard searchKeyword != normalized else { return }
        searchKeyword = normalized
    }

    private func sanitizedDisplaySetting(_ setting: BookshelfDisplaySetting) -> BookshelfDisplaySetting {
        var sanitized = setting
        let availableCriteria = BookshelfSortCriteria.availableForBookList(for: route.context.dimension)
        if !availableCriteria.contains(sanitized.sortCriteria) {
            sanitized.sortCriteria = BookshelfDisplaySetting.defaultBookListValue(for: route.context.dimension).sortCriteria
        }
        if sanitized.sortCriteria == .custom {
            sanitized.sortOrder = .descending
            sanitized.isSectionEnabled = false
        } else if !sanitized.sortCriteria.supportsSection {
            sanitized.isSectionEnabled = false
        }
        sanitized.pinnedInAllSorts = true
        sanitized.columnCount = max(2, min(sanitized.columnCount, 6))
        return sanitized
    }

    private func pruneSelectionToVisibleBooks() {
        guard !(isEditing && hasSearchKeyword) else { return }
        let visibleIDs = Set(visibleBookIDs)
        selectedBookIDs = selectedBookIDs.filter { visibleIDs.contains($0) }
        if visibleIDs.isEmpty {
            isEditing = false
            actionNotice = nil
        }
    }
}
