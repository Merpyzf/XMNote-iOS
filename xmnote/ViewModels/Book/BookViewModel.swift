//
//  BookViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

import Foundation

/**
 * [INPUT]: 依赖 BookRepositoryProtocol 提供书架快照数据流和排序置顶写入，依赖 BookshelfSnapshot 进行多维度状态编排
 * [OUTPUT]: 对外提供 BookViewModel，驱动书籍页维度浏览、搜索态、显示设置、默认书架编辑态、排序置顶写入与 UICollectionView 排序提交
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
        case .more:
            return "更多"
        case .delete:
            return "删除"
        case .reorder:
            return "排序"
        }
    }
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
    var displaySetting: BookshelfDisplaySetting = .defaultValue
    var isEditing: Bool = false
    var selectedIDs: [BookshelfItemID] = []
    var activeWriteAction: BookshelfPendingAction?
    var writeError: String?

    private let repository: any BookRepositoryProtocol
    private var observationTask: Task<Void, Never>?

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
        startObservation()
    }

    /// 释放书籍模块运行过程持有的资源与观察任务。
    deinit {
        observationTask?.cancel()
    }

    // MARK: - Observation

    private func startObservation() {
        contentState = .loading
        let currentSetting = displaySetting
        let currentKeyword = normalizedSearchKeyword(searchKeyword)
        observationTask = Task {
            do {
                for try await snapshot in repository.observeBookshelfSnapshot(
                    setting: currentSetting,
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
        guard isEditing || !selectedIDs.isEmpty || activeWriteAction != nil || writeError != nil else { return }
        isEditing = false
        selectedIDs.removeAll()
        activeWriteAction = nil
        writeError = nil
    }

    /// 在当前默认书架可见范围内切换单个 Book 或 Group 的选中状态。
    func toggleSelection(_ id: BookshelfItemID) {
        guard isEditing, Set(visibleDefaultItemIDs).contains(id) else { return }
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(id)
        }
        writeError = nil
    }

    /// 选中当前默认书架可见的所有顶层 Book 和 Group。
    func selectAllVisible() {
        guard isEditing else { return }
        selectedIDs = visibleDefaultItemIDs
        writeError = nil
    }

    /// 在当前默认书架可见范围内执行反选，不保留不可见对象。
    func invertVisibleSelection() {
        guard isEditing else { return }
        let currentSelection = selectedIDSet
        selectedIDs = visibleDefaultItemIDs.filter { !currentSelection.contains($0) }
        writeError = nil
    }

    /// 清空当前编辑态选择集合，但保留编辑态本身。
    func clearSelection() {
        selectedIDs.removeAll()
        writeError = nil
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
