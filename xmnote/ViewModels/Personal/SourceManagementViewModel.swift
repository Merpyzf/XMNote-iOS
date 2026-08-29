/**
 * [INPUT]: 依赖 SourceManagementRepositoryProtocol 提供来源管理观察流与写入能力，依赖 SourceManagementModels 表达范围、列表项与错误
 * [OUTPUT]: 对外提供 SourceManagementViewModel 及来源编辑/删除状态，驱动“我的 > 书籍来源”页面
 * [POS]: ViewModels/Personal 的书籍来源管理状态编排器，被 Personal/SourceManagementView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书籍来源管理读取状态，区分加载、内容、空态与错误，便于页面给出明确反馈。
enum SourceManagementContentState: Equatable {
    case loading
    case content
    case empty
    case error(String)
}

/// 来源名称编辑 Sheet 状态，区分新增与重命名，并保留影响范围展示所需信息。
struct SourceManagementNameEdit: Identifiable, Hashable, Sendable {
    let scope: SourceManagementScope
    let sourceID: Int64?
    let currentName: String
    let associatedBookCount: Int

    var id: String {
        if let sourceID {
            return "\(scope.rawValue)-edit-\(sourceID)"
        }
        return "\(scope.rawValue)-create"
    }

    var isCreating: Bool {
        sourceID == nil
    }

    var title: String {
        isCreating ? "添加来源" : "编辑来源"
    }
}

/// 来源删除确认状态，记录删除来源与关联书籍数量。
struct SourceManagementDeleteConfirmation: Identifiable, Hashable, Sendable {
    let sourceIDs: [Int64]
    let sourceName: String
    let sourceCount: Int
    let associatedBookCount: Int

    var id: String {
        "source-delete-\(sourceIDs.map(String.init).joined(separator: "-"))"
    }
}

/// 来源管理一次性轻提示事件，只承载无法由界面变化直接表达的 warning/error。
struct SourceManagementToastFeedback: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case warning
        case error
    }

    let id = UUID()
    let role: Role
    let message: String
}

/// 来源管理写入动作，用于禁用重复触发并驱动局部写入反馈。
enum SourceManagementWriteAction: Hashable {
    case create
    case rename
    case delete
    case reorder
}

/// 书籍来源管理页状态源，负责订阅来源快照并提交增改删与排序操作；所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class SourceManagementViewModel {
    var selectedScope: SourceManagementScope = .mine {
        didSet {
            guard selectedScope != oldValue else { return }
            refreshContentState()
        }
    }
    var snapshot: SourceManagementSnapshot = .empty
    var contentState: SourceManagementContentState = .loading
    var observationErrorMessage: String?
    var activeWriteAction: SourceManagementWriteAction?
    var writeError: String?
    var toastFeedback: SourceManagementToastFeedback?
    var activeNameEdit: SourceManagementNameEdit?
    var activeDeleteConfirmation: SourceManagementDeleteConfirmation?
    var nameEditText = ""
    /// 记录来源管理页搜索栏输入，切换范围时保留关键字以延续用户当前筛选意图。
    var searchText = ""

    private let repository: any SourceManagementRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    var currentSources: [SourceManagementItem] {
        snapshot.sources(for: selectedScope)
    }

    /// 将搜索栏输入收敛为用于本地匹配的关键字；首尾空白不参与筛选，避免空格输入制造伪搜索态。
    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 标记页面是否处在来源筛选语境，供列表空态和排序入口区分全量数据与搜索子集。
    var isSearchFiltering: Bool {
        !normalizedSearchText.isEmpty
    }

    /// 为当前选中范围提供可展示来源；筛选只作用于当前范围的全量来源，不跨我的来源/默认来源混合查询。
    var visibleSources: [SourceManagementItem] {
        let keyword = normalizedSearchText
        guard !keyword.isEmpty else { return currentSources }
        return currentSources.filter { item in
            item.name.localizedCaseInsensitiveContains(keyword)
        }
    }

    /// 区分“当前范围有来源但没有命中搜索”和真正无来源，避免读取状态被搜索结果污染。
    var isSearchResultEmpty: Bool {
        isSearchFiltering && !currentSources.isEmpty && visibleSources.isEmpty
    }

    /// 控制新增入口；默认来源为 Android 内置字典，iOS 只读展示，新增始终归入我的来源。
    var canCreateSource: Bool {
        activeWriteAction == nil && selectedScope == .mine
    }

    /// 控制手动排序入口；搜索过滤态只展示子集，默认来源只读展示，禁止进入排序。
    var canEnterReorder: Bool {
        activeWriteAction == nil
            && selectedScope == .mine
            && !isSearchFiltering
            && currentSources.count >= 2
    }

    /// 为“调整顺序”入口提供可访问性说明，禁用时解释阻断原因。
    var reorderActionAccessibilityHint: String {
        if activeWriteAction != nil {
            return "当前操作完成后可调整顺序"
        }
        if selectedScope == .appDefault {
            return "默认来源由应用内置，不能在这里调整顺序"
        }
        if isSearchFiltering {
            return "清除搜索后可调整顺序"
        }
        if currentSources.count < 2 {
            return "至少需要两个来源才能调整顺序"
        }
        return "进入后可拖动来源调整顺序"
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
        guard !normalizedNameEditText.isEmpty else { return "来源名称不能为空" }
        guard normalizedNameEditText.count <= Constants.sourceNameMaxLength else {
            return "来源名称长度不能超过\(Constants.sourceNameMaxLength)个字符"
        }
        return nil
    }

    var normalizedNameEditText: String {
        nameEditText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注入来源管理仓储并启动数据库观察；观察任务在主线程回写状态，调用方取消迭代后底层流会结束。
    init(repository: any SourceManagementRepositoryProtocol) {
        self.repository = repository
        startObservation()
    }

    /// 释放观察与写入任务；Task 取消后不会再向已释放页面状态回写。
    isolated deinit {
        observationTask?.cancel()
        writeTask?.cancel()
    }

    /// 重新建立来源观察流，用于首轮读取失败后的显式恢复。
    func retryObservation() {
        observationTask?.cancel()
        startObservation()
    }

    /// 打开新增来源 Sheet，提交前不会触发写库。
    func presentCreateSheet() {
        guard activeWriteAction == nil else { return }
        guard selectedScope == .mine else {
            toastFeedback = SourceManagementToastFeedback(
                role: .warning,
                message: SourceManagementRepositoryError.defaultSourceReadonly.localizedDescription
            )
            return
        }
        activeNameEdit = SourceManagementNameEdit(
            scope: .mine,
            sourceID: nil,
            currentName: "",
            associatedBookCount: 0
        )
        nameEditText = ""
        clearTransientMessages()
    }

    /// 打开重命名来源 Sheet；默认来源保持只读，不进入编辑。
    func presentRenameSheet(for item: SourceManagementItem) {
        guard activeWriteAction == nil else { return }
        guard !item.isAppDefault else {
            toastFeedback = SourceManagementToastFeedback(
                role: .warning,
                message: SourceManagementRepositoryError.defaultSourceReadonly.localizedDescription
            )
            return
        }
        activeNameEdit = SourceManagementNameEdit(
            scope: .mine,
            sourceID: item.id,
            currentName: item.name,
            associatedBookCount: item.associatedBookCount
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

    /// 提交新增或重命名；写入 Task 可取消，成功后关闭 Sheet，失败时保留 Sheet 供用户继续修改。
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

        let action: SourceManagementWriteAction = edit.isCreating ? .create : .rename
        activeWriteAction = action
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                if let sourceID = edit.sourceID {
                    try await repository.updateSource(sourceID: sourceID, name: nextName)
                } else {
                    try await repository.createSource(named: nextName)
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

    /// 清除当前筛选关键字，让用户从搜索结果回到当前范围的完整来源列表。
    func clearSearchText() {
        guard !searchText.isEmpty else { return }
        searchText = ""
    }

    /// 打开单个来源删除确认；默认来源保持只读，不进入删除。
    func presentDeleteConfirmation(for item: SourceManagementItem) {
        guard activeWriteAction == nil else { return }
        guard !item.isAppDefault else {
            toastFeedback = SourceManagementToastFeedback(
                role: .warning,
                message: SourceManagementRepositoryError.defaultSourceReadonly.localizedDescription
            )
            return
        }
        activeDeleteConfirmation = SourceManagementDeleteConfirmation(
            sourceIDs: [item.id],
            sourceName: item.name,
            sourceCount: 1,
            associatedBookCount: item.associatedBookCount
        )
        clearTransientMessages()
    }

    /// 提交删除确认，Repository 负责迁移关联书籍并软删来源。
    func submitDelete() {
        guard let confirmation = activeDeleteConfirmation, activeWriteAction == nil else { return }
        activeWriteAction = .delete
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await repository.deleteSources(sourceIDs: confirmation.sourceIDs)
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = nil
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = nil
                    self.toastFeedback = SourceManagementToastFeedback(
                        role: .error,
                        message: self.displayMessage(for: error)
                    )
                }
            }
        }
    }

    /// 提交拖拽后的最终来源 ID 顺序；写入期间会阻止重复排序并在失败时恢复旧顺序。
    func commitSourceOrder(_ orderedIDs: [Int64]) {
        guard activeWriteAction == nil else { return }
        guard selectedScope == .mine else {
            toastFeedback = SourceManagementToastFeedback(
                role: .warning,
                message: SourceManagementRepositoryError.defaultSourceReadonly.localizedDescription
            )
            return
        }

        let previousItems = currentSources
        let currentIDs = previousItems.map(\.id)
        guard orderedIDs != currentIDs else { return }
        guard orderedIDs.count == currentIDs.count, Set(orderedIDs) == Set(currentIDs) else {
            toastFeedback = SourceManagementToastFeedback(
                role: .warning,
                message: SourceManagementRepositoryError.invalidOrder.localizedDescription
            )
            return
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
        let reorderedItems = orderedIDs.compactMap { itemsByID[$0] }
        guard reorderedItems.count == orderedIDs.count else {
            toastFeedback = SourceManagementToastFeedback(
                role: .warning,
                message: SourceManagementRepositoryError.invalidOrder.localizedDescription
            )
            return
        }

        snapshot = snapshot.replacing(reorderedItems, for: .mine)

        activeWriteAction = .reorder
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await repository.updateSourceOrder(sourceIDs: orderedIDs, scope: .mine)
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = nil
                }
            } catch {
                await MainActor.run {
                    self.snapshot = self.snapshot.replacing(previousItems, for: .mine)
                    self.activeWriteAction = nil
                    self.writeError = nil
                    self.toastFeedback = SourceManagementToastFeedback(
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

private extension SourceManagementViewModel {
    enum Constants {
        static let sourceNameMaxLength = 100
    }

    /// 启动来源快照观察；观察流在后台 Task 中迭代，所有状态写回通过 MainActor 串行化以避免竞态。
    func startObservation() {
        observationErrorMessage = nil
        if currentSources.isEmpty {
            contentState = .loading
        }
        observationTask = Task {
            do {
                for try await nextSnapshot in repository.observeSourceManagementSnapshot() {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.snapshot = nextSnapshot
                        self.observationErrorMessage = nil
                        self.refreshContentState()
                    }
                }
            } catch {
                await MainActor.run {
                    if self.currentSources.isEmpty {
                        self.contentState = .error("暂时无法加载来源")
                    } else {
                        self.contentState = .content
                        self.observationErrorMessage = "来源刷新失败"
                    }
                }
            }
        }
    }

    func refreshContentState() {
        if currentSources.isEmpty {
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
