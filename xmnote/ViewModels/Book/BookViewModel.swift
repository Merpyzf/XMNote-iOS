//
//  BookViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

import Foundation

/**
 * [INPUT]: 依赖 BookRepositoryProtocol 提供书架快照数据流和排序置顶写入，依赖 BookshelfSnapshot 进行多维度状态编排
 * [OUTPUT]: 对外提供 BookViewModel，驱动书籍页维度浏览、搜索态、显示设置、默认书架编辑态、排序置顶、批量编辑、删除与 UICollectionView 排序提交
 * [POS]: Book 模块书籍列表状态编排器，被 BookContainerView/BookGridView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - Bookshelf Content State

/// 书架读取状态，区分加载、空态、内容和错误，便于 UI 给出明确反馈。
enum BookshelfContentState: Equatable {
    case loading
    case content
    case empty
    case error(String)
}

// MARK: - Bookshelf Pending Action

/// 书架编辑态中的当前写入或预留动作，用于统一禁用入口与展示操作反馈。
enum BookshelfPendingAction: Hashable {
    case pin
    case unpin
    case move
    case moveToStart
    case moveToEnd
    case moveToGroup
    case addToBookList
    case setTag
    case setSource
    case setReadStatus
    case more
    case delete
    case reorder

    var title: String {
        switch self {
        case .pin:
            return "置顶"
        case .unpin:
            return "取消置顶"
        case .move:
            return "移动"
        case .moveToStart:
            return "移到最前"
        case .moveToEnd:
            return "移到最后"
        case .moveToGroup:
            return "移组"
        case .addToBookList:
            return "书单"
        case .setTag:
            return "标签"
        case .setSource:
            return "来源"
        case .setReadStatus:
            return "状态"
        case .more:
            return "更多"
        case .delete:
            return "删除"
        case .reorder:
            return "排序"
        }
    }
}

/// 默认书架删除确认状态，记录打开确认弹窗时的选中对象数量。
struct BookshelfDefaultDeleteConfirmation: Identifiable, Hashable, Sendable {
    let bookCount: Int
    let groupCount: Int

    var id: String { "book-\(bookCount)-group-\(groupCount)" }

    var totalCount: Int { bookCount + groupCount }
}

// MARK: - BookViewModel

/// BookViewModel 负责书架快照订阅，把 Repository 多维度结果和编辑态选择映射成界面可消费的数据集。
@Observable
class BookViewModel {
    var snapshot: BookshelfSnapshot = .empty
    var contentState: BookshelfContentState = .loading
    var selectedDimension: BookshelfDimension = .default {
        didSet {
            if selectedDimension != .default {
                exitEditing()
            }
            refreshContentState()
        }
    }
    var searchKeyword: String = "" {
        didSet {
            guard normalizedSearchKeyword(oldValue) != normalizedSearchKeyword(searchKeyword) else { return }
            restartObservation()
        }
    }
    var isSearchActive: Bool = false
    var displaySettingsByDimension: [BookshelfDimension: BookshelfDisplaySetting]
    var displaySetting: BookshelfDisplaySetting {
        get {
            displaySettingsByDimension[selectedDimension] ?? BookshelfDisplaySetting.defaultValue(for: selectedDimension)
        }
        set {
            updateDisplaySetting(newValue, for: selectedDimension)
        }
    }
    var isEditing: Bool = false
    var selectedIDs: [BookshelfItemID] = []
    var activeWriteAction: BookshelfPendingAction?
    var writeError: String?
    var actionNotice: String?
    var activeBatchSheet: BookshelfBatchEditSheet?
    var activeDeleteConfirmation: BookshelfDefaultDeleteConfirmation?
    var isLoadingBatchOptions = false

    private let repository: any BookRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var batchOptionsTask: Task<Void, Never>?

    var bookshelfItems: [BookshelfItem] {
        snapshot.defaultItems
    }

    var currentDefaultItems: [BookshelfItem] {
        snapshot.defaultItems
    }

    var currentDimensionTitle: String {
        selectedDimension.title
    }

    var hasSearchKeyword: Bool {
        !normalizedSearchKeyword(searchKeyword).isEmpty
    }

    var selectedCount: Int {
        selectedIDs.count
    }

    var selectedIDSet: Set<BookshelfItemID> {
        Set(selectedIDs)
    }

    var selectedBookIDs: [Int64] {
        selectedIDs.compactMap { id in
            if case .book(let bookID) = id { return bookID }
            return nil
        }
    }

    var selectedGroupCount: Int {
        selectedIDs.reduce(0) { count, id in
            if case .group = id { return count + 1 }
            return count
        }
    }

    var visibleDefaultItemIDs: [BookshelfItemID] {
        currentDefaultItems.map(\.id)
    }

    var isAllVisibleSelected: Bool {
        let visibleIDs = Set(visibleDefaultItemIDs)
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedIDSet)
    }

    var canEditCurrentDimension: Bool {
        selectedDimension == .default
            && contentState == .content
            && !visibleDefaultItemIDs.isEmpty
            && activeWriteAction == nil
    }

    var canReorderDefaultItems: Bool {
        isEditing
            && selectedDimension == .default
            && displaySetting.sortMode == .custom
            && !hasSearchKeyword
            && activeWriteAction == nil
            && contentState == .content
    }

    var canSubmitSelectedPin: Bool {
        isEditing && !selectedIDs.isEmpty && activeWriteAction == nil
    }

    var canMoveSelectedItems: Bool {
        isEditing && activeWriteAction == nil && !hasSearchKeyword && hasSelectedNormalItem
    }

    var canMoreSelectedItems: Bool {
        isEditing && activeWriteAction == nil && !selectedIDs.isEmpty
    }

    var canDeleteSelectedItems: Bool {
        canMoreSelectedItems
    }

    var defaultMoreActions: [BookshelfBookListEditAction] {
        [.moveToGroup, .addToBookList, .setTag, .setSource, .setReadStatus]
    }

    var hasSelectedNormalItem: Bool {
        let itemsByID = Dictionary(uniqueKeysWithValues: currentDefaultItems.map { ($0.id, $0) })
        return selectedIDs.contains { id in
            itemsByID[id]?.pinned == false
        }
    }

    var currentOrderItems: [BookshelfOrderItem] {
        currentDefaultItems.map { BookshelfOrderItem(id: $0.id, isPinned: $0.pinned) }
    }

    var moveDisabledReason: String? {
        if hasSearchKeyword {
            return "搜索结果不支持移动排序，清除搜索后可调整书架顺序"
        }
        if !hasSelectedNormalItem {
            return "至少选择一个非置顶项后才能移动"
        }
        return nil
    }

    /// 注入书籍仓储并启动列表数据观察。
    init(repository: any BookRepositoryProtocol) {
        self.repository = repository
        self.displaySettingsByDimension = repository.fetchBookshelfDisplaySettings(scope: .main)
        startObservation()
    }

    /// 释放书籍模块运行过程持有的资源与观察任务。
    deinit {
        observationTask?.cancel()
        writeTask?.cancel()
        batchOptionsTask?.cancel()
    }

    // MARK: - Observation

    private func startObservation() {
        contentState = .loading
        let currentSettingsByDimension = displaySettingsByDimension
        let currentKeyword = normalizedSearchKeyword(searchKeyword)
        observationTask = Task {
            do {
                for try await snapshot in repository.observeBookshelfSnapshot(
                    settingsByDimension: currentSettingsByDimension,
                    searchKeyword: currentKeyword
                ) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.snapshot = snapshot
                        self.applySnapshotContentState()
                    }
                }
            } catch {
                await MainActor.run {
                    self.contentState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func restartObservation() {
        observationTask?.cancel()
        startObservation()
    }

    private func refreshContentState() {
        switch contentState {
        case .loading, .error:
            return
        case .content, .empty:
            applySnapshotContentState()
        }
    }

    private func applySnapshotContentState() {
        contentState = snapshot.isEmpty(for: selectedDimension) ? .empty : .content
        pruneSelectionToVisibleItems()
    }

    private func normalizedSearchKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pruneSelectionToVisibleItems() {
        guard selectedDimension == .default else {
            exitEditing()
            return
        }
        let visibleIDs = Set(visibleDefaultItemIDs)
        let nextSelection = selectedIDs.filter { visibleIDs.contains($0) }
        guard nextSelection != selectedIDs else { return }
        selectedIDs = nextSelection
    }

    // MARK: - User Intent

    /// 切换书架浏览维度，仅影响 UI 展示，不触发任何写库动作。
    func selectDimension(_ dimension: BookshelfDimension) {
        guard selectedDimension != dimension else { return }
        selectedDimension = dimension
        restartObservation()
    }

    /// 保存当前维度显示设置并重启观察流，使排序和布局偏好立即生效。
    func updateDisplaySetting(_ setting: BookshelfDisplaySetting, for dimension: BookshelfDimension) {
        let sanitized = sanitizedDisplaySetting(setting, for: dimension)
        guard displaySettingsByDimension[dimension] != sanitized else { return }
        displaySettingsByDimension[dimension] = sanitized
        repository.saveBookshelfDisplaySetting(sanitized, for: dimension, scope: .main)
        if dimension == selectedDimension {
            restartObservation()
        }
    }

    /// 返回指定维度当前显示设置。
    func displaySetting(for dimension: BookshelfDimension) -> BookshelfDisplaySetting {
        displaySettingsByDimension[dimension] ?? BookshelfDisplaySetting.defaultValue(for: dimension)
    }

    /// 判断聚合维度是否允许长按排序。
    func canReorderAggregateItems(for dimension: BookshelfDimension) -> Bool {
        !isEditing
            && !hasSearchKeyword
            && activeWriteAction == nil
            && contentState == .content
            && displaySetting(for: dimension).sortCriteria == .custom
            && aggregateOrderContext(for: dimension) != nil
    }

    /// 按 UIKit 聚合列表拖拽结束后的最终 ID 顺序提交标签、来源或状态排序。
    func commitAggregateOrder(_ orderedIDs: [Int64], for dimension: BookshelfDimension) {
        guard let context = aggregateOrderContext(for: dimension),
              canReorderAggregateItems(for: dimension),
              !orderedIDs.isEmpty else {
            return
        }
        activeWriteAction = .reorder
        writeError = nil

        Task {
            do {
                try await repository.updateBookshelfAggregateOrder(context: context, orderedIDs: orderedIDs)
                await MainActor.run {
                    self.activeWriteAction = nil
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = error.localizedDescription
                    self.restartObservation()
                }
            }
        }
    }

    /// 激活页内搜索栏，搜索只参与只读过滤。
    func activateSearch() {
        isSearchActive = true
    }

    /// 退出搜索并清空关键词，恢复当前维度的完整只读数据。
    func deactivateSearch() {
        isSearchActive = false
        searchKeyword = ""
    }

    /// 清空搜索关键词但保持搜索栏展开，便于用户继续输入。
    func clearSearchKeyword() {
        searchKeyword = ""
    }

    /// 进入默认书架编辑态，可携带一个初始选中项；不会触发任何数据写入。
    func enterEditing(initialSelection: BookshelfItemID? = nil) {
        guard canEditCurrentDimension else { return }
        isEditing = true
        writeError = nil
        activeWriteAction = nil

        guard let initialSelection else {
            pruneSelectionToVisibleItems()
            return
        }

        if Set(visibleDefaultItemIDs).contains(initialSelection) {
            selectedIDs = [initialSelection]
        }
    }

    /// 退出默认书架编辑态，并清空选择集合和占位写操作状态。
    func exitEditing() {
        guard isEditing || !selectedIDs.isEmpty || activeWriteAction != nil || writeError != nil || actionNotice != nil else { return }
        isEditing = false
        selectedIDs.removeAll()
        activeWriteAction = nil
        writeError = nil
        actionNotice = nil
        activeBatchSheet = nil
        activeDeleteConfirmation = nil
        cancelBatchOptionsLoading()
    }

    /// 在当前默认书架可见范围内切换单个 Book 或 Group 的选中状态。
    func toggleSelection(_ id: BookshelfItemID) {
        guard isEditing, Set(visibleDefaultItemIDs).contains(id) else { return }
        cancelBatchOptionsLoading()
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(id)
        }
        writeError = nil
        actionNotice = nil
    }

    /// 选中当前默认书架可见的所有顶层 Book 和 Group。
    func selectAllVisible() {
        guard isEditing else { return }
        cancelBatchOptionsLoading()
        selectedIDs = visibleDefaultItemIDs
        writeError = nil
        actionNotice = nil
    }

    /// 在当前默认书架可见范围内执行反选，不保留不可见对象。
    func invertVisibleSelection() {
        guard isEditing else { return }
        cancelBatchOptionsLoading()
        let currentSelection = selectedIDSet
        selectedIDs = visibleDefaultItemIDs.filter { !currentSelection.contains($0) }
        writeError = nil
        actionNotice = nil
    }

    /// 清空当前编辑态选择集合，但保留编辑态本身。
    func clearSelection() {
        cancelBatchOptionsLoading()
        selectedIDs.removeAll()
        writeError = nil
        actionNotice = nil
    }

    /// 批量置顶当前有序选择集合，完成后保留编辑态并清空选择，避免重复提交。
    func pinSelectedItems() {
        guard canSubmitSelectedPin else { return }
        pinItems(selectedIDs, clearsSelectionOnSuccess: true)
    }

    /// 单项置顶默认书架 Book/Group，供 context menu 使用。
    func pinItem(_ id: BookshelfItemID) {
        guard activeWriteAction == nil else { return }
        pinItems([id], clearsSelectionOnSuccess: false)
    }

    /// 取消单项置顶，供 context menu 使用。
    func unpinItem(_ id: BookshelfItemID) {
        guard activeWriteAction == nil else { return }
        activeWriteAction = .unpin
        writeError = nil

        Task {
            do {
                try await repository.unpinBookshelfItem(id)
                await MainActor.run {
                    self.activeWriteAction = nil
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = error.localizedDescription
                }
            }
        }
    }

    /// 将选中普通项移动到普通区最前，置顶区保持不变；搜索过滤态禁止提交。
    func moveSelectedItemsToStart() {
        guard canMoveSelectedItems else { return }
        moveItems(selectedIDs, placement: .start, clearsSelectionOnSuccess: true)
    }

    /// 将选中普通项移动到普通区最后，置顶区保持不变；搜索过滤态禁止提交。
    func moveSelectedItemsToEnd() {
        guard canMoveSelectedItems else { return }
        moveItems(selectedIDs, placement: .end, clearsSelectionOnSuccess: true)
    }

    /// 执行默认书架“更多”菜单动作；混选时仅对 Book 生效，Group 被忽略。
    func performMoreAction(_ action: BookshelfBookListEditAction) {
        guard canMoreSelectedItems else {
            actionNotice = "请先选择书籍或分组"
            return
        }
        switch action {
        case .moveToGroup:
            presentMoveGroupSheet()
        case .addToBookList:
            guard !selectedBookIDs.isEmpty else {
                actionNotice = "分组暂不支持加入书单，请选择书籍"
                return
            }
            actionNotice = "书单添加将在书单模块开发时开放"
        case .setTag, .setSource, .setReadStatus:
            presentBatchSheet(for: action)
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveOut, .renameGroup, .deleteGroup, .renameTag, .deleteTag, .renameSource, .deleteSource, .deleteBooks:
            actionNotice = "\(action.title)不适用于默认书架更多菜单"
        }
    }

    /// 打开默认书架删除确认；Group 删除时需要用户选择组内书籍安置位置。
    func presentDeleteConfirmation() {
        guard canDeleteSelectedItems else {
            actionNotice = "请先选择要删除的书籍或分组"
            return
        }
        activeDeleteConfirmation = BookshelfDefaultDeleteConfirmation(
            bookCount: selectedBookIDs.count,
            groupCount: selectedGroupCount
        )
        actionNotice = nil
        writeError = nil
    }

    /// 删除默认书架选中的 Book/Group，分组内书籍按 placement 安置回默认书架。
    func submitDeleteSelectedItems(placement: GroupBooksPlacement) {
        let ids = selectedIDs
        activeDeleteConfirmation = nil
        runWriteAction(.delete, successMessage: "已删除选中项") {
            try await self.repository.deleteBookshelfItems(ids, groupBooksPlacement: placement)
        }
    }

    /// 提交默认书架批量标签写入；仅作用于选中的 Book，Group 会被忽略。
    func submitBatchTags(tagIDs: [Int64]) {
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        guard !bookIDs.isEmpty else {
            actionNotice = "分组不支持设置标签，请选择书籍"
            return
        }
        runWriteAction(.setTag, successMessage: "标签已更新") {
            try await self.repository.batchSetBooksTags(bookIDs: bookIDs, tagIDs: tagIDs)
        }
    }

    /// 提交默认书架批量来源写入；仅作用于选中的 Book。
    func submitBatchSource(sourceID: Int64) {
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        guard !bookIDs.isEmpty else {
            actionNotice = "分组不支持设置来源，请选择书籍"
            return
        }
        runWriteAction(.setSource, successMessage: "来源已更新") {
            try await self.repository.batchSetBooksSource(bookIDs: bookIDs, sourceID: sourceID)
        }
    }

    /// 提交默认书架批量阅读状态写入；读完状态必须携带评分。
    func submitBatchReadStatus(statusID: Int64, changedAt: Date, ratingScore: Int64?) {
        if statusID == BookEntryReadingStatus.finished.rawValue, (ratingScore ?? 0) <= 0 {
            actionNotice = "标记读完时需要选择评分"
            return
        }
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        guard !bookIDs.isEmpty else {
            actionNotice = "分组不支持设置阅读状态，请选择书籍"
            return
        }
        let input = BookshelfBatchReadStatusInput(
            statusID: statusID,
            changedAt: Int64(changedAt.timeIntervalSince1970 * 1000),
            ratingScore: ratingScore
        )
        runWriteAction(.setReadStatus, successMessage: "阅读状态已更新") {
            try await self.repository.batchSetBookReadStatus(bookIDs: bookIDs, input: input)
        }
    }

    /// 提交默认书架批量移入分组；仅作用于选中的 Book。
    func submitMoveToGroup(groupID: Int64) {
        let bookIDs = selectedBookIDs
        activeBatchSheet = nil
        guard !bookIDs.isEmpty else {
            actionNotice = "分组不能移入分组，请选择书籍"
            return
        }
        runWriteAction(.moveToGroup, successMessage: "已移入分组") {
            try await self.repository.moveBooks(bookIDs, toGroup: groupID)
        }
    }

    /// 将单项移动到普通区最前。
    func moveItemToStart(_ id: BookshelfItemID) {
        guard canMoveItem(id) else { return }
        moveItems([id], placement: .start, clearsSelectionOnSuccess: false)
    }

    /// 将单项移动到普通区最后。
    func moveItemToEnd(_ id: BookshelfItemID) {
        guard canMoveItem(id) else { return }
        moveItems([id], placement: .end, clearsSelectionOnSuccess: false)
    }

    /// 判断单项是否允许提交普通区移动；搜索过滤态与置顶项均不允许写入排序。
    func canMoveItem(_ id: BookshelfItemID) -> Bool {
        guard activeWriteAction == nil, !hasSearchKeyword else { return false }
        return currentDefaultItems.first(where: { $0.id == id })?.pinned == false
    }

    /// 按 UIKit 集合视图拖拽结束后的最终 ID 顺序提交默认书架排序；失败时恢复提交前预览顺序。
    func commitDefaultItemsOrder(_ orderedIDs: [BookshelfItemID]) {
        guard canReorderDefaultItems else { return }
        let originalItems = currentDefaultItems
        let originalIDs = originalItems.map(\.id)
        guard orderedIDs.count == originalIDs.count,
              Set(orderedIDs) == Set(originalIDs),
              orderedIDs != originalIDs else {
            return
        }

        let pinnedIDs = originalItems.filter(\.pinned).map(\.id)
        guard Array(orderedIDs.prefix(pinnedIDs.count)) == pinnedIDs else {
            return
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: originalItems.map { ($0.id, $0) })
        let nextItems = orderedIDs.compactMap { itemsByID[$0] }
        guard nextItems.count == orderedIDs.count,
              nextItems.dropFirst(pinnedIDs.count).allSatisfy({ !$0.pinned }) else {
            return
        }

        snapshot.defaultItems = nextItems
        activeWriteAction = .reorder
        writeError = nil

        let nextOrderItems = nextItems.map { BookshelfOrderItem(id: $0.id, isPinned: $0.pinned) }
        Task {
            do {
                try await repository.updateBookshelfOrder(nextOrderItems)
                await MainActor.run {
                    self.activeWriteAction = nil
                }
            } catch {
                await MainActor.run {
                    self.snapshot.defaultItems = originalItems
                    self.activeWriteAction = nil
                    self.writeError = error.localizedDescription
                }
            }
        }
    }
}

private enum BookshelfMoveIntent {
    case start
    case end
}

private extension BookViewModel {
    func sanitizedDisplaySetting(
        _ setting: BookshelfDisplaySetting,
        for dimension: BookshelfDimension
    ) -> BookshelfDisplaySetting {
        var result = setting
        result.columnCount = max(2, min(result.columnCount, 6))
        if !BookshelfSortCriteria.available(for: dimension).contains(result.sortCriteria) {
            result.sortCriteria = BookshelfDisplaySetting.defaultValue(for: dimension).sortCriteria
        }
        if !result.sortCriteria.supportsSection {
            result.isSectionEnabled = false
        }
        return result
    }

    func aggregateOrderContext(for dimension: BookshelfDimension) -> BookshelfAggregateOrderContext? {
        switch dimension {
        case .status:
            return .readStatus
        case .tag:
            return .tag
        case .source:
            return .source
        case .default, .rating, .author, .press:
            return nil
        }
    }

    func pinItems(
        _ ids: [BookshelfItemID],
        clearsSelectionOnSuccess: Bool
    ) {
        guard !ids.isEmpty else { return }
        activeWriteAction = .pin
        writeError = nil

        Task {
            do {
                try await repository.pinBookshelfItems(ids)
                await MainActor.run {
                    if clearsSelectionOnSuccess {
                        self.selectedIDs.removeAll()
                    }
                    self.activeWriteAction = nil
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = error.localizedDescription
                }
            }
        }
    }

    func moveItems(
        _ ids: [BookshelfItemID],
        placement: BookshelfMoveIntent,
        clearsSelectionOnSuccess: Bool
    ) {
        guard !ids.isEmpty, !hasSearchKeyword else {
            writeError = "搜索结果不支持移动排序，清除搜索后可调整书架顺序"
            return
        }
        let originalItems = currentDefaultItems
        let nextItems = reorderedDefaultItems(ids, placement: placement)
        guard originalItems.map(\.id) != nextItems.map(\.id) else { return }

        let currentOrder = originalItems.map { BookshelfOrderItem(id: $0.id, isPinned: $0.pinned) }
        snapshot.defaultItems = nextItems
        activeWriteAction = placement == .start ? .moveToStart : .moveToEnd
        writeError = nil

        Task {
            do {
                switch placement {
                case .start:
                    try await repository.moveBookshelfItemsToStart(ids, in: currentOrder)
                case .end:
                    try await repository.moveBookshelfItemsToEnd(ids, in: currentOrder)
                }
                await MainActor.run {
                    if clearsSelectionOnSuccess {
                        self.selectedIDs.removeAll()
                    }
                    self.activeWriteAction = nil
                }
            } catch {
                await MainActor.run {
                    self.snapshot.defaultItems = originalItems
                    self.activeWriteAction = nil
                    self.writeError = error.localizedDescription
                }
            }
        }
    }

    /// 拉取默认书架批量编辑候选项，混选时只以 Book 集合生成 Sheet。
    /// - Note: 候选项加载任务可被选择变化或页面释放取消；UI 状态只在 MainActor 回写。
    func presentBatchSheet(for action: BookshelfBookListEditAction) {
        guard activeWriteAction == nil, !isLoadingBatchOptions else { return }
        let bookIDs = selectedBookIDs
        guard !bookIDs.isEmpty else {
            actionNotice = "分组不支持\(action.title)，请至少选择一本书"
            return
        }
        isLoadingBatchOptions = true
        actionNotice = "正在加载\(action.title)选项..."
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

    /// 拉取默认书架可移入目标分组，并打开移组 Sheet。
    /// - Note: 只经 Repository 获取分组选项，避免 ViewModel 直接访问数据库。
    func presentMoveGroupSheet() {
        guard activeWriteAction == nil, !isLoadingBatchOptions else { return }
        let bookIDs = selectedBookIDs
        guard !bookIDs.isEmpty else {
            actionNotice = "分组不能移入分组，请至少选择一本书"
            return
        }
        isLoadingBatchOptions = true
        actionNotice = "正在加载分组选项..."
        writeError = nil
        batchOptionsTask?.cancel()
        batchOptionsTask = Task {
            do {
                let options = try await repository.fetchBookshelfMoveTargetGroups(excludingGroupID: nil)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedBookIDs == bookIDs else {
                        self.isLoadingBatchOptions = false
                        self.actionNotice = nil
                        return
                    }
                    self.isLoadingBatchOptions = false
                    guard !options.isEmpty else {
                        self.actionNotice = "暂无可移入的分组"
                        return
                    }
                    self.activeBatchSheet = .moveGroup(options: options)
                    self.actionNotice = nil
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

    /// 根据候选项快照打开具体默认书架批量编辑 Sheet。
    func presentBatchSheet(
        _ action: BookshelfBookListEditAction,
        options: BookshelfBatchEditOptions,
        bookIDs: [Int64]
    ) {
        switch action {
        case .setTag:
            activeBatchSheet = .tags(
                options: options.tags,
                initialSelectedIDs: bookIDs.count == 1 ? options.initialTagIDs : [],
                allowsEmptySelection: bookIDs.count == 1
            )
            actionNotice = nil
        case .setSource:
            guard !options.sources.isEmpty else {
                actionNotice = "暂无可用来源"
                return
            }
            activeBatchSheet = .source(
                options: options.sources,
                initialSelectedID: options.initialSourceID ?? options.sources.first?.id
            )
            actionNotice = nil
        case .setReadStatus:
            guard !options.readStatuses.isEmpty else {
                actionNotice = "暂无可用阅读状态"
                return
            }
            let initialChangedAt: Date? = options.initialReadStatusChangedAt.flatMap { timestamp in
                timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000) : nil
            }
            let initialStatusID = options.initialReadStatusID
                ?? options.readStatuses.first(where: { $0.id == BookEntryReadingStatus.reading.rawValue })?.id
                ?? options.readStatuses.first?.id
            activeBatchSheet = .readStatus(
                options: options.readStatuses,
                initialStatusID: initialStatusID,
                initialChangedAt: initialChangedAt,
                initialRatingScore: options.initialRatingScore
            )
            actionNotice = nil
        case .moveToGroup, .addToBookList, .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveOut, .renameGroup, .deleteGroup, .renameTag, .deleteTag, .renameSource, .deleteSource, .deleteBooks:
            return
        }
    }

    /// 取消批量候选项加载，避免旧选择集合打开过期 Sheet。
    func cancelBatchOptionsLoading() {
        batchOptionsTask?.cancel()
        batchOptionsTask = nil
        isLoadingBatchOptions = false
    }

    /// 启动默认书架写操作任务，并在成功后清空选择。
    /// - Note: Repository 写入在后台执行；完成后回到 MainActor 修改 UI 状态，页面释放时 Task 可被取消。
    func runWriteAction(
        _ action: BookshelfPendingAction,
        successMessage: String,
        operation: @escaping () async throws -> Void
    ) {
        guard activeWriteAction == nil else { return }
        cancelBatchOptionsLoading()
        activeWriteAction = action
        actionNotice = "\(action.title)处理中..."
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await operation()
                await MainActor.run {
                    self.selectedIDs.removeAll()
                    self.activeWriteAction = nil
                    self.actionNotice = successMessage
                    self.restartObservation()
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = error.localizedDescription
                    self.actionNotice = error.localizedDescription
                    self.restartObservation()
                }
            }
        }
    }

    func reorderedDefaultItems(
        _ ids: [BookshelfItemID],
        placement: BookshelfMoveIntent
    ) -> [BookshelfItem] {
        let selectedIDSet = Set(ids)
        let pinnedItems = currentDefaultItems.filter(\.pinned)
        let normalItems = currentDefaultItems.filter { !$0.pinned }
        let normalByID = Dictionary(uniqueKeysWithValues: normalItems.map { ($0.id, $0) })
        let selectedItems = ids.compactMap { normalByID[$0] }
        let remainingItems = normalItems.filter { !selectedIDSet.contains($0.id) }

        switch placement {
        case .start:
            return pinnedItems + selectedItems + remainingItems
        case .end:
            return pinnedItems + remainingItems + selectedItems
        }
    }

}
