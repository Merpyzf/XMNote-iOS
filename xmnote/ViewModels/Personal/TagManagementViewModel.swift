/**
 * [INPUT]: 依赖 TagManagementRepositoryProtocol 提供标签管理观察流与写入能力，依赖 TagManagementModels 表达范围、列表项与错误
 * [OUTPUT]: 对外提供 TagManagementViewModel 及标签编辑/删除状态，驱动“我的 > 标签管理”页面
 * [POS]: ViewModels/Personal 的标签管理状态编排器，被 Personal/TagManagementView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 标签管理读取状态，区分加载、内容、空态与错误，便于页面给出明确反馈。
enum TagManagementContentState: Equatable {
    case loading
    case content
    case empty
    case error(String)
}

/// 标签名称编辑 Sheet 状态，区分新增与重命名，并保留影响范围展示所需信息。
struct TagManagementNameEdit: Identifiable, Hashable, Sendable {
    let scope: TagManagementScope
    let tagID: Int64?
    let currentName: String
    let associatedCount: Int

    var id: String {
        if let tagID {
            return "\(scope.rawValue)-edit-\(tagID)"
        }
        return "\(scope.rawValue)-create"
    }

    var isCreating: Bool {
        tagID == nil
    }

    var title: String {
        isCreating ? "添加标签" : "编辑标签"
    }
}

/// 标签删除确认状态，记录删除范围、标签数量与关联数量。
struct TagManagementDeleteConfirmation: Identifiable, Hashable, Sendable {
    let scope: TagManagementScope
    let tagIDs: [Int64]
    let tagCount: Int
    let associatedCount: Int

    var id: String {
        "\(scope.rawValue)-delete-\(tagIDs.map(String.init).joined(separator: "-"))"
    }
}

/// 标签管理写入动作，用于禁用重复触发并显示即时反馈。
enum TagManagementWriteAction: Hashable {
    case create
    case rename
    case delete
    case reorder

    var progressTitle: String {
        switch self {
        case .create:
            return "正在添加标签"
        case .rename:
            return "正在更新标签"
        case .delete:
            return "正在删除标签"
        case .reorder:
            return "正在保存排序"
        }
    }
}

/// 标签管理页状态源，负责订阅标签快照并提交增改删与排序操作；所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class TagManagementViewModel {
    var selectedScope: TagManagementScope = .note {
        didSet {
            guard selectedScope != oldValue else { return }
            exitSelectionMode()
            refreshContentState()
        }
    }
    var snapshot: TagManagementSnapshot = .empty
    var contentState: TagManagementContentState = .loading
    var selectedTagIDs: Set<Int64> = []
    var isSelectionMode = false
    var activeWriteAction: TagManagementWriteAction?
    var actionNotice: String?
    var writeError: String?
    var activeNameEdit: TagManagementNameEdit?
    var activeDeleteConfirmation: TagManagementDeleteConfirmation?
    var nameEditText = ""
    /// 记录标签管理页搜索栏输入，切换书摘/书籍范围时保留关键字以延续用户当前筛选意图。
    var searchText = ""

    private let repository: any TagManagementRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    var currentTags: [TagManagementItem] {
        snapshot.tags(for: selectedScope)
    }

    var selectedTags: [TagManagementItem] {
        currentTags.filter { selectedTagIDs.contains($0.id) }
    }

    /// 将搜索栏输入收敛为用于本地匹配的关键字；首尾空白不参与筛选，避免空格输入制造伪搜索态。
    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 标记页面是否处在标签筛选语境，供列表空态和排序入口区分全量数据与搜索子集。
    var isSearchFiltering: Bool {
        !normalizedSearchText.isEmpty
    }

    /// 为当前选中范围提供可展示标签；筛选只作用于当前范围的全量标签，不跨书摘/书籍混合查询。
    var visibleTags: [TagManagementItem] {
        let keyword = normalizedSearchText
        guard !keyword.isEmpty else { return currentTags }
        return currentTags.filter { item in
            item.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    /// 区分“当前范围有标签但没有命中搜索”和真正无标签，避免读取状态被搜索结果污染。
    var isSearchResultEmpty: Bool {
        isSearchFiltering && !currentTags.isEmpty && visibleTags.isEmpty
    }

    /// 控制批量选择入口；过滤后没有可见标签时不进入，以免用户面对空结果仍进入编辑态。
    var canEnterSelectionMode: Bool {
        activeWriteAction == nil && !visibleTags.isEmpty
    }

    /// 控制手动排序入口；搜索过滤态只展示子集，禁止进入以保证落盘顺序始终来自当前范围全量标签。
    var canEnterReorder: Bool {
        activeWriteAction == nil && !isSelectionMode && !isSearchFiltering && currentTags.count >= 2
    }

    var canSubmitNameEdit: Bool {
        guard activeWriteAction == nil, let edit = activeNameEdit else { return false }
        guard nameEditValidationMessage == nil else { return false }
        if !edit.isCreating && normalizedNameEditText == edit.currentName {
            return false
        }
        return true
    }

    var nameEditValidationMessage: String? {
        guard activeNameEdit != nil else { return nil }
        guard !normalizedNameEditText.isEmpty else { return "标签名称不能为空" }
        guard normalizedNameEditText.count <= Constants.tagNameMaxLength else {
            return "标签名称长度不能超过\(Constants.tagNameMaxLength)个字符"
        }
        return nil
    }

    var normalizedNameEditText: String {
        nameEditText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注入标签管理仓储并启动数据库观察；观察任务在实例释放时取消，避免页面退出后继续回写状态。
    init(repository: any TagManagementRepositoryProtocol) {
        self.repository = repository
        startObservation()
    }

    /// 释放观察与写入任务，避免页面退出后继续回写状态。
    isolated deinit {
        observationTask?.cancel()
        writeTask?.cancel()
    }

    /// 打开新增标签 Sheet，提交前不会触发写库。
    func presentCreateSheet() {
        guard activeWriteAction == nil else { return }
        activeNameEdit = TagManagementNameEdit(
            scope: selectedScope,
            tagID: nil,
            currentName: "",
            associatedCount: 0
        )
        nameEditText = ""
        clearTransientMessages()
    }

    /// 打开重命名标签 Sheet，提交前不会触发写库。
    func presentRenameSheet(for item: TagManagementItem) {
        guard activeWriteAction == nil else { return }
        activeNameEdit = TagManagementNameEdit(
            scope: selectedScope,
            tagID: item.id,
            currentName: item.name,
            associatedCount: item.associatedCount
        )
        nameEditText = item.name
        clearTransientMessages()
    }

    /// 用户修改名称输入时清理上一轮写入错误。
    func updateNameEditText(_ value: String) {
        nameEditText = value
        writeError = nil
        actionNotice = nil
    }

    /// 关闭名称编辑 Sheet；写入进行中时忽略关闭请求。
    func dismissNameEdit() {
        guard activeWriteAction == nil else { return }
        activeNameEdit = nil
        nameEditText = ""
        writeError = nil
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

        if !edit.isCreating && nextName == edit.currentName {
            dismissNameEdit()
            return
        }

        let action: TagManagementWriteAction = edit.isCreating ? .create : .rename
        activeWriteAction = action
        actionNotice = action.progressTitle
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                if let tagID = edit.tagID {
                    try await repository.updateTag(tagID: tagID, name: nextName, scope: edit.scope)
                } else {
                    try await repository.createTag(named: nextName, scope: edit.scope)
                }
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.activeNameEdit = nil
                    self.nameEditText = ""
                    self.actionNotice = edit.isCreating ? "标签已添加" : "标签已更新"
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = self.displayMessage(for: error)
                    self.actionNotice = self.writeError
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

    /// 清除当前筛选关键字，让用户从搜索结果回到当前范围的完整标签列表。
    func clearSearchText() {
        guard !searchText.isEmpty else { return }
        searchText = ""
    }

    /// 退出多选模式并清空选中项。
    func exitSelectionMode() {
        isSelectionMode = false
        selectedTagIDs.removeAll()
    }

    /// 切换指定标签的选中状态。
    func toggleSelection(for item: TagManagementItem) {
        guard isSelectionMode else { return }
        if selectedTagIDs.contains(item.id) {
            selectedTagIDs.remove(item.id)
        } else {
            selectedTagIDs.insert(item.id)
        }
    }

    /// 打开单个标签删除确认。
    func presentDeleteConfirmation(for item: TagManagementItem) {
        guard activeWriteAction == nil else { return }
        activeDeleteConfirmation = TagManagementDeleteConfirmation(
            scope: selectedScope,
            tagIDs: [item.id],
            tagCount: 1,
            associatedCount: item.associatedCount
        )
        clearTransientMessages()
    }

    /// 打开选中标签删除确认；无选中时只给出可感知反馈。
    func presentDeleteConfirmationForSelection() {
        guard activeWriteAction == nil else { return }
        let tags = selectedTags
        guard !tags.isEmpty else {
            actionNotice = TagManagementRepositoryError.emptySelection.localizedDescription
            return
        }
        activeDeleteConfirmation = TagManagementDeleteConfirmation(
            scope: selectedScope,
            tagIDs: tags.map(\.id),
            tagCount: tags.count,
            associatedCount: tags.reduce(0) { $0 + $1.associatedCount }
        )
        clearTransientMessages()
    }

    /// 提交删除确认，Repository 负责按 Android 类型语义清理关联并软删标签。
    func submitDelete() {
        guard let confirmation = activeDeleteConfirmation, activeWriteAction == nil else { return }
        activeWriteAction = .delete
        actionNotice = TagManagementWriteAction.delete.progressTitle
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await repository.deleteTags(tagIDs: confirmation.tagIDs, scope: confirmation.scope)
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.exitSelectionMode()
                    self.actionNotice = confirmation.tagCount > 1 ? "标签已删除" : "标签已删除"
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = self.displayMessage(for: error)
                    self.actionNotice = self.writeError
                }
            }
        }
    }

    /// 提交拖拽后的最终标签 ID 顺序；调用方只传预览结果，写入期间会阻止重复排序并在失败时恢复当前范围的旧顺序。
    func commitTagOrder(_ orderedIDs: [Int64]) {
        guard activeWriteAction == nil else { return }
        let previousItems = currentTags
        let currentIDs = previousItems.map(\.id)
        guard orderedIDs != currentIDs else { return }
        guard orderedIDs.count == currentIDs.count, Set(orderedIDs) == Set(currentIDs) else {
            writeError = "标签列表已更新，请重新调整顺序"
            actionNotice = writeError
            return
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
        let reorderedItems = orderedIDs.compactMap { itemsByID[$0] }
        guard reorderedItems.count == orderedIDs.count else {
            writeError = "标签列表已更新，请重新调整顺序"
            actionNotice = writeError
            return
        }

        let scope = selectedScope
        snapshot = snapshot.replacing(reorderedItems, for: scope)

        activeWriteAction = .reorder
        actionNotice = TagManagementWriteAction.reorder.progressTitle
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await repository.updateTagOrder(tagIDs: orderedIDs, scope: scope)
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.actionNotice = nil
                }
            } catch {
                await MainActor.run {
                    self.snapshot = self.snapshot.replacing(previousItems, for: scope)
                    self.activeWriteAction = nil
                    self.writeError = self.displayMessage(for: error)
                    self.actionNotice = self.writeError
                }
            }
        }
    }
}

private extension TagManagementViewModel {
    enum Constants {
        static let tagNameMaxLength = 100
    }

    func startObservation() {
        contentState = .loading
        observationTask = Task {
            do {
                for try await nextSnapshot in repository.observeTagManagementSnapshot() {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.snapshot = nextSnapshot
                        self.selectedTagIDs = self.selectedTagIDs.intersection(Set(self.currentTags.map(\.id)))
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
        if currentTags.isEmpty {
            contentState = .empty
        } else {
            contentState = .content
        }
    }

    func clearTransientMessages() {
        writeError = nil
        actionNotice = nil
    }

    func displayMessage(for error: Error) -> String {
        error.localizedDescription
    }
}
