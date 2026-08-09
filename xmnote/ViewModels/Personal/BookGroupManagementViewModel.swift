/**
 * [INPUT]: 依赖 BookGroupManagementRepositoryProtocol 提供书籍分组管理观察流与写入能力，依赖 BookGroupManagementModels 表达列表项、搜索筛选与错误
 * [OUTPUT]: 对外提供 BookGroupManagementViewModel 及分组搜索、可见结果多选、编辑与删除状态，驱动“我的 > 书籍分组”页面
 * [POS]: ViewModels/Personal 的书籍分组管理状态编排器，被 Personal/BookGroupManagementView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书籍分组管理读取状态，区分加载、内容、空态与错误，便于页面给出明确反馈。
enum BookGroupManagementContentState: Equatable {
    case loading
    case content
    case empty
    case error(String)
}

/// 分组名称编辑 Sheet 状态，区分新增与重命名，并保留组内书籍数量展示所需信息。
struct BookGroupManagementNameEdit: Identifiable, Hashable, Sendable {
    let groupID: Int64?
    let currentName: String
    let bookCount: Int

    var id: String {
        if let groupID {
            return "edit-\(groupID)"
        }
        return "create"
    }

    var isCreating: Bool {
        groupID == nil
    }

    var title: String {
        isCreating ? "添加分组" : "编辑分组"
    }
}

/// 分组删除确认状态，记录删除数量、受影响书籍数量与目标分组 id。
struct BookGroupManagementDeleteConfirmation: Identifiable, Hashable, Sendable {
    let groupIDs: [Int64]
    let groupCount: Int
    let affectedBookCount: Int

    var id: String {
        "delete-\(groupIDs.map(String.init).joined(separator: "-"))"
    }

    var containsBooks: Bool {
        affectedBookCount > 0
    }
}

/// 书籍分组管理一次性轻提示事件，只承载无法由界面变化直接表达的 warning/error。
struct BookGroupManagementToastFeedback: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case warning
        case error
    }

    let id = UUID()
    let role: Role
    let message: String
}

/// 书籍分组管理写入动作，用于禁用重复触发并驱动局部写入反馈。
enum BookGroupManagementWriteAction: Hashable {
    case create
    case rename
    case delete
    case reorder
}

/// 书籍分组管理页状态源，负责订阅分组快照并提交增改删与排序操作；所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class BookGroupManagementViewModel {
    var snapshot: BookGroupManagementSnapshot = .empty
    var contentState: BookGroupManagementContentState = .loading
    var selectedGroupIDs: Set<Int64> = []
    var isSelectionMode = false
    var activeWriteAction: BookGroupManagementWriteAction?
    var writeError: String?
    var toastFeedback: BookGroupManagementToastFeedback?
    var activeNameEdit: BookGroupManagementNameEdit?
    var activeDeleteConfirmation: BookGroupManagementDeleteConfirmation?
    var nameEditText = ""
    /// 记录书籍分组管理页搜索栏输入，仅用于本地按分组名筛选，不触发数据库查询。
    var searchText = ""

    private let repository: any BookGroupManagementRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    var groups: [BookGroupManagementItem] {
        snapshot.groups
    }

    var selectedGroups: [BookGroupManagementItem] {
        groups.filter { selectedGroupIDs.contains($0.id) }
    }

    /// 将搜索栏输入收敛为用于本地匹配的关键字；首尾空白不参与筛选。
    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 标记页面是否处于分组筛选语境，供空态与排序入口区分全量数据和搜索子集。
    var isSearchFiltering: Bool {
        !normalizedSearchText.isEmpty
    }

    /// 当前可展示分组；搜索只按分组名匹配，不查询组内书籍标题。
    var visibleGroups: [BookGroupManagementItem] {
        let keyword = normalizedSearchText
        guard !keyword.isEmpty else { return groups }
        return groups.filter { item in
            item.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    /// 区分“有分组但没有命中搜索”和真正无分组，避免搜索结果污染读取状态。
    var isSearchResultEmpty: Bool {
        isSearchFiltering && !groups.isEmpty && visibleGroups.isEmpty
    }

    var selectedCount: Int {
        selectedGroupIDs.count
    }

    var isAllSelected: Bool {
        !groups.isEmpty && Set(groups.map(\.id)).isSubset(of: selectedGroupIDs)
    }

    /// 判断当前搜索结果是否均已选中，不受筛选外已选项影响。
    var isAllVisibleSelected: Bool {
        !visibleGroups.isEmpty && Set(visibleGroups.map(\.id)).isSubset(of: selectedGroupIDs)
    }

    var canEnterSelectionMode: Bool {
        activeWriteAction == nil && !visibleGroups.isEmpty
    }

    var canEnterReorder: Bool {
        activeWriteAction == nil && !isSelectionMode && !isSearchFiltering && groups.count >= 2
    }

    var reorderActionAccessibilityHint: String {
        if activeWriteAction != nil {
            return "当前操作完成后可调整顺序"
        }
        if isSearchFiltering {
            return "清除搜索后可调整顺序"
        }
        if groups.count < 2 {
            return "至少需要两个分组才能调整顺序"
        }
        return "进入后可拖动分组调整顺序"
    }

    var canSubmitNameEdit: Bool {
        guard activeWriteAction == nil, activeNameEdit != nil else { return false }
        return nameEditValidationMessage == nil
    }

    var nameEditValidationMessage: String? {
        guard activeNameEdit != nil else { return nil }
        guard !normalizedNameEditText.isEmpty else { return "分组名称不能为空" }
        guard normalizedNameEditText.count <= Constants.groupNameMaxLength else {
            return "分组名称长度不能超过\(Constants.groupNameMaxLength)个字符"
        }
        return nil
    }

    var normalizedNameEditText: String {
        nameEditText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注入书籍分组管理仓储并启动数据库观察；观察任务在实例释放时取消，避免页面退出后继续回写状态。
    init(repository: any BookGroupManagementRepositoryProtocol) {
        self.repository = repository
        startObservation()
    }

    /// 释放观察与写入任务，避免页面退出后继续回写状态。
    isolated deinit {
        observationTask?.cancel()
        writeTask?.cancel()
    }

    /// 打开新增分组 Sheet，提交前不会触发写库。
    func presentCreateSheet() {
        guard activeWriteAction == nil else { return }
        activeNameEdit = BookGroupManagementNameEdit(groupID: nil, currentName: "", bookCount: 0)
        nameEditText = ""
        clearTransientMessages()
    }

    /// 打开重命名分组 Sheet，提交前不会触发写库。
    func presentRenameSheet(for item: BookGroupManagementItem) {
        guard activeWriteAction == nil else { return }
        activeNameEdit = BookGroupManagementNameEdit(
            groupID: item.id,
            currentName: item.name,
            bookCount: item.bookCount
        )
        nameEditText = item.name
        clearTransientMessages()
    }

    /// 用户修改名称输入时清理上一轮写入错误。
    func updateNameEditText(_ value: String) {
        nameEditText = value
        writeError = nil
    }

    /// 关闭名称编辑 Sheet；写入进行中时忽略关闭请求。
    func dismissNameEdit() {
        guard activeWriteAction == nil else { return }
        activeNameEdit = nil
        nameEditText = ""
        writeError = nil
    }

    /// 清除当前筛选关键字，让用户从搜索结果回到完整分组列表。
    func clearSearchText() {
        guard !searchText.isEmpty else { return }
        searchText = ""
    }

    /// 提交新增或重命名；成功后关闭 Sheet，失败时保留 Sheet 供用户继续修改。
    func submitNameEdit() {
        guard let edit = activeNameEdit, activeWriteAction == nil else { return }
        guard nameEditValidationMessage == nil else {
            writeError = nameEditValidationMessage
            return
        }
        let nextName = normalizedNameEditText
        guard !nextName.isEmpty else { return }

        let action: BookGroupManagementWriteAction = edit.isCreating ? .create : .rename
        activeWriteAction = action
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                if let groupID = edit.groupID {
                    try await repository.updateGroup(groupID: groupID, name: nextName)
                } else {
                    try await repository.createGroup(named: nextName)
                }
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.activeNameEdit = nil
                    self.nameEditText = ""
                    self.writeError = nil
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = self.displayMessage(for: error)
                }
            }
        }
    }

    /// 进入多选模式；空列表或写入中不进入。
    func enterSelectionMode() {
        guard canEnterSelectionMode else { return }
        isSelectionMode = true
        clearTransientMessages()
    }

    /// 退出多选模式并清空选中项。
    func exitSelectionMode() {
        isSelectionMode = false
        selectedGroupIDs.removeAll()
    }

    /// 切换指定分组的选中状态。
    func toggleSelection(for item: BookGroupManagementItem) {
        guard isSelectionMode else { return }
        if selectedGroupIDs.contains(item.id) {
            selectedGroupIDs.remove(item.id)
        } else {
            selectedGroupIDs.insert(item.id)
        }
    }

    /// 选中全部分组。
    func selectAll() {
        guard isSelectionMode else { return }
        selectedGroupIDs.formUnion(Set(groups.map(\.id)))
        clearTransientMessages()
    }

    /// 清空全部分组选择。
    func clearSelection() {
        guard isSelectionMode else { return }
        selectedGroupIDs.removeAll()
        clearTransientMessages()
    }

    /// 在多选模式中选中当前搜索可见的所有分组，保留筛选外的已选项。
    func selectAllVisible() {
        guard isSelectionMode else { return }
        selectedGroupIDs.formUnion(Set(visibleGroups.map(\.id)))
        clearTransientMessages()
    }

    /// 在多选模式中取消当前搜索可见的选择，保留筛选外的已选项。
    func clearVisibleSelection() {
        guard isSelectionMode else { return }
        selectedGroupIDs.subtract(Set(visibleGroups.map(\.id)))
        clearTransientMessages()
    }

    /// 打开单个分组删除确认。
    func presentDeleteConfirmation(for item: BookGroupManagementItem) {
        guard activeWriteAction == nil else { return }
        activeDeleteConfirmation = BookGroupManagementDeleteConfirmation(
            groupIDs: [item.id],
            groupCount: 1,
            affectedBookCount: item.bookCount
        )
        clearTransientMessages()
    }

    /// 打开选中分组删除确认；无选中时只给出可感知反馈。
    func presentDeleteConfirmationForSelection() {
        guard activeWriteAction == nil else { return }
        let selected = selectedGroups
        guard !selected.isEmpty else {
            toastFeedback = BookGroupManagementToastFeedback(
                role: .warning,
                message: BookGroupManagementRepositoryError.emptySelection.localizedDescription
            )
            return
        }
        activeDeleteConfirmation = BookGroupManagementDeleteConfirmation(
            groupIDs: selected.map(\.id),
            groupCount: selected.count,
            affectedBookCount: selected.reduce(0) { $0 + $1.bookCount }
        )
        clearTransientMessages()
    }

    /// 提交删除确认，Repository 负责按 Android 分组语义移出书籍并软删分组。
    func submitDelete(placement: GroupBooksPlacement) {
        guard let confirmation = activeDeleteConfirmation, activeWriteAction == nil else { return }
        activeWriteAction = .delete
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await repository.deleteGroups(groupIDs: confirmation.groupIDs, placement: placement)
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.exitSelectionMode()
                    self.writeError = nil
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = nil
                    self.toastFeedback = BookGroupManagementToastFeedback(
                        role: .error,
                        message: self.displayMessage(for: error)
                    )
                }
            }
        }
    }

    /// 提交拖拽后的最终分组 ID 顺序；失败时恢复当前观察流中的可信顺序并提示用户。
    func commitGroupOrder(_ orderedIDs: [Int64]) {
        guard activeWriteAction == nil else { return }
        let previousGroups = groups
        let currentIDs = previousGroups.map(\.id)
        guard orderedIDs != currentIDs else { return }
        guard orderedIDs.count == currentIDs.count, Set(orderedIDs) == Set(currentIDs) else {
            toastFeedback = BookGroupManagementToastFeedback(
                role: .warning,
                message: BookGroupManagementRepositoryError.staleOrder.localizedDescription
            )
            return
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: previousGroups.map { ($0.id, $0) })
        let reorderedGroups = orderedIDs.compactMap { itemsByID[$0] }
        guard reorderedGroups.count == orderedIDs.count else {
            toastFeedback = BookGroupManagementToastFeedback(
                role: .warning,
                message: BookGroupManagementRepositoryError.staleOrder.localizedDescription
            )
            return
        }

        snapshot = snapshot.replacing(reorderedGroups)
        activeWriteAction = .reorder
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await repository.updateGroupOrder(groupIDs: orderedIDs)
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = nil
                }
            } catch {
                await MainActor.run {
                    self.snapshot = self.snapshot.replacing(previousGroups)
                    self.activeWriteAction = nil
                    self.writeError = nil
                    self.toastFeedback = BookGroupManagementToastFeedback(
                        role: .error,
                        message: self.displayMessage(for: error)
                    )
                }
            }
        }
    }

    /// 消费一次性 Toast 事件，避免 SwiftUI 重绘或页面返回时重复展示。
    func consumeToastFeedback() {
        toastFeedback = nil
    }
}

private extension BookGroupManagementViewModel {
    enum Constants {
        static let groupNameMaxLength = 100
    }

    func startObservation() {
        contentState = .loading
        observationTask = Task {
            do {
                for try await nextSnapshot in repository.observeBookGroupManagementSnapshot() {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.snapshot = nextSnapshot
                        self.selectedGroupIDs = self.selectedGroupIDs.intersection(Set(self.groups.map(\.id)))
                        if self.groups.isEmpty {
                            self.exitSelectionMode()
                        }
                        self.refreshContentState()
                    }
                }
            } catch {
                await MainActor.run {
                    self.contentState = .error(self.displayMessage(for: error))
                }
            }
        }
    }

    func refreshContentState() {
        if groups.isEmpty {
            contentState = .empty
        } else {
            contentState = .content
        }
    }

    func clearTransientMessages() {
        writeError = nil
        toastFeedback = nil
    }

    func displayMessage(for error: Error) -> String {
        error.localizedDescription
    }
}
