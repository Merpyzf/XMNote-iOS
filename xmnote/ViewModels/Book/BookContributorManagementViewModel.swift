/**
 * [INPUT]: 依赖 BookshelfRepositoryProtocol 观察作者/出版社聚合快照，并提交资料重命名、书籍字段批量修改与删除写入
 * [OUTPUT]: 对外提供 BookContributorKind、BookContributorManagementViewModel 与作者/出版社编辑、批量修改、删除状态
 * [POS]: ViewModels/Book 的作者/出版社管理状态编排器，被书架聚合卡和管理页复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 作者/出版社管理类型，复用 Android 作者与出版社聚合管理语义。
enum BookContributorKind: String, Identifiable, Hashable, Sendable {
    case author
    case press

    var id: String { rawValue }

    var title: String {
        switch self {
        case .author:
            return "作者管理"
        case .press:
            return "出版社管理"
        }
    }

    var itemTitle: String {
        switch self {
        case .author:
            return "作者"
        case .press:
            return "出版社"
        }
    }

    var dimension: BookshelfDimension {
        switch self {
        case .author:
            return .author
        case .press:
            return .press
        }
    }

    init?(context: BookshelfListContext) {
        switch context {
        case .author:
            self = .author
        case .press:
            self = .press
        case .defaultGroup, .readStatus, .tag, .source, .rating:
            return nil
        }
    }
}

/// 作者/出版社名称编辑弹窗状态，记录提交时需要同步更新的旧名称。
struct BookContributorNameEdit: Identifiable, Hashable, Sendable {
    let kind: BookContributorKind
    let currentName: String
    let bookCount: Int

    var id: String {
        "\(kind.rawValue)-edit-\(currentName)"
    }
}

/// 作者/出版社删除确认状态，记录删除范围与提示文案所需的书籍数量。
struct BookContributorDeleteConfirmation: Identifiable, Hashable, Sendable {
    let kind: BookContributorKind
    let name: String
    let bookCount: Int

    var id: String {
        "\(kind.rawValue)-delete-\(name)"
    }
}

/// 作者/出版社批量修改输入状态，冻结用户确认前的来源维度与影响书籍数量。
struct BookContributorBatchNameEdit: Identifiable, Hashable, Sendable {
    let kind: BookContributorKind
    let sourceNames: [String]
    let bookCount: Int

    var id: String {
        "\(kind.rawValue)-batch-name-\(sourceNames.joined(separator: "|"))"
    }
}

/// 作者/出版社批量修改最终确认状态，确保确认阶段使用冻结后的来源名称和目标名称。
struct BookContributorBatchConfirmation: Identifiable, Hashable, Sendable {
    let kind: BookContributorKind
    let sourceNames: [String]
    let targetName: String
    let bookCount: Int

    var id: String {
        "\(kind.rawValue)-batch-confirm-\(sourceNames.joined(separator: "|"))-\(targetName)"
    }
}

/// 作者/出版社管理写入动作，用于禁用重复触发并显示即时反馈。
enum BookContributorWriteAction: Hashable {
    case rename
    case batchModify
    case delete

    var title: String {
        switch self {
        case .rename:
            return "编辑"
        case .batchModify:
            return "修改"
        case .delete:
            return "删除"
        }
    }
}

/// 作者/出版社管理页状态源，负责观察聚合数据并提交编辑、删除动作；所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class BookContributorManagementViewModel {
    var groups: [BookshelfAggregateGroup] = []
    var contentState: BookshelfContentState = .loading
    var observationErrorMessage: String?
    var activeWriteAction: BookContributorWriteAction?
    var writeError: String?
    var actionNotice: String?
    var activeNameEdit: BookContributorNameEdit?
    var activeDeleteConfirmation: BookContributorDeleteConfirmation?
    var activeBatchNameEdit: BookContributorBatchNameEdit?
    var activeBatchConfirmation: BookContributorBatchConfirmation?
    var nameEditText = ""
    var batchNameText = ""
    var isSelectionMode = false
    var selectedNames: [String] = []

    let kind: BookContributorKind

    private let repository: any BookshelfRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    var selectionCount: Int {
        selectedNames.count
    }

    var selectedBookCount: Int {
        let selectedNameSet = Set(selectedNames)
        return groups.reduce(0) { count, group in
            count + (selectedNameSet.contains(group.title) ? group.count : 0)
        }
    }

    var batchActionTitle: String {
        "修改书籍\(kind.itemTitle)"
    }

    /// 注入仓储并启动聚合快照观察；观察任务在实例释放时取消，回写 UI 状态统一回到 MainActor。
    init(kind: BookContributorKind, repository: any BookshelfRepositoryProtocol) {
        self.kind = kind
        self.repository = repository
        startObservation()
    }

    /// 释放观察与写入任务，避免页面退出后继续回写状态。
    isolated deinit {
        observationTask?.cancel()
        writeTask?.cancel()
    }

    /// 重新建立作者或出版社观察流，用于首轮读取失败后的显式恢复。
    func retryObservation() {
        observationTask?.cancel()
        startObservation()
    }

    /// 进入多选模式；此时行点击只切换选择，不打开编辑或删除菜单。
    func enterSelectionMode() {
        guard activeWriteAction == nil else { return }
        isSelectionMode = true
        writeError = nil
        actionNotice = nil
    }

    /// 退出多选模式并清空尚未提交的选择与弹窗状态，不产生数据库写入。
    func cancelSelectionMode() {
        isSelectionMode = false
        selectedNames.removeAll()
        activeBatchNameEdit = nil
        activeBatchConfirmation = nil
        batchNameText = ""
    }

    /// 按当前聚合行切换作者或出版社选择，保持首次选择顺序供批量命令稳定回放。
    func toggleSelection(for group: BookshelfAggregateGroup) {
        guard isSelectionMode, activeWriteAction == nil else { return }
        guard BookContributorKind(context: group.context) == kind else { return }
        if let index = selectedNames.firstIndex(of: group.title) {
            selectedNames.remove(at: index)
        } else {
            selectedNames.append(group.title)
        }
    }

    /// 打开批量修改名称输入；提交前冻结来源名称和影响书籍数量，不写数据库。
    func presentBatchNameEdit() {
        guard activeWriteAction == nil, !selectedNames.isEmpty else { return }
        let validNameSet = Set(groups.map(\.title))
        let frozenNames = selectedNames.filter { validNameSet.contains($0) }
        guard !frozenNames.isEmpty else {
            writeError = "所选内容已变化，请重新选择"
            actionNotice = writeError
            cancelSelectionMode()
            return
        }
        activeBatchNameEdit = BookContributorBatchNameEdit(
            kind: kind,
            sourceNames: frozenNames,
            bookCount: selectedBookCount
        )
        batchNameText = frozenNames[0]
        writeError = nil
        actionNotice = nil
    }

    /// 校验批量目标名并进入最终确认；取消任一弹窗均不会触发 Repository。
    func confirmBatchNameInput() {
        guard let edit = activeBatchNameEdit else { return }
        let targetName = batchNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else {
            writeError = "\(kind.itemTitle)名称不能为空"
            actionNotice = writeError
            return
        }
        guard edit.sourceNames.contains(where: { $0 != targetName }) else {
            writeError = "请输入不同的\(kind.itemTitle)名称"
            actionNotice = writeError
            return
        }
        activeBatchNameEdit = nil
        activeBatchConfirmation = BookContributorBatchConfirmation(
            kind: edit.kind,
            sourceNames: edit.sourceNames,
            targetName: targetName,
            bookCount: edit.bookCount
        )
    }

    /// 最终确认后提交书籍字段批量修改；Repository 保证校验、统一时间和完整回滚。
    func submitBatchModification() {
        guard let confirmation = activeBatchConfirmation else { return }
        activeBatchConfirmation = nil
        runWriteAction(
            .batchModify,
            successMessage: "书籍\(kind.itemTitle)已更新",
            clearsSelectionOnSuccess: true
        ) {
            switch confirmation.kind {
            case .author:
                try await self.repository.batchModifyBooksAuthor(
                    sourceNames: confirmation.sourceNames,
                    newName: confirmation.targetName
                )
            case .press:
                try await self.repository.batchModifyBooksPress(
                    sourceNames: confirmation.sourceNames,
                    newName: confirmation.targetName
                )
            }
        }
    }

    /// 打开名称编辑弹窗，提交前不会触发写库。
    func presentNameEdit(for group: BookshelfAggregateGroup) {
        guard activeWriteAction == nil else { return }
        guard BookContributorKind(context: group.context) == kind else { return }
        activeNameEdit = BookContributorNameEdit(
            kind: kind,
            currentName: group.title,
            bookCount: group.count
        )
        nameEditText = group.title
        writeError = nil
        actionNotice = nil
    }

    /// 提交名称编辑；写入任务可被下一次写入取消，成功或失败后只在 MainActor 更新 UI 状态。
    func submitNameEdit() {
        guard let edit = activeNameEdit else { return }
        let nextName = nameEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextName.isEmpty else {
            writeError = "\(kind.itemTitle)名称不能为空"
            actionNotice = writeError
            return
        }
        activeNameEdit = nil
        guard nextName != edit.currentName else {
            actionNotice = nil
            return
        }

        runWriteAction(.rename, successMessage: "\(kind.itemTitle)已更新") {
            switch edit.kind {
            case .author:
                try await self.repository.renameAuthor(oldName: edit.currentName, newName: nextName)
            case .press:
                try await self.repository.renamePress(oldName: edit.currentName, newName: nextName)
            }
        }
    }

    /// 打开删除确认弹窗，确认前不会触发写库。
    func presentDeleteConfirmation(for group: BookshelfAggregateGroup) {
        guard activeWriteAction == nil else { return }
        guard BookContributorKind(context: group.context) == kind else { return }
        activeDeleteConfirmation = BookContributorDeleteConfirmation(
            kind: kind,
            name: group.title,
            bookCount: group.count
        )
        writeError = nil
        actionNotice = nil
    }

    /// 提交删除；Repository 负责按 Android 语义删除该作者/出版社下书籍并移除资料记录。
    func submitDelete() {
        guard let confirmation = activeDeleteConfirmation else { return }
        activeDeleteConfirmation = nil
        runWriteAction(.delete, successMessage: "\(kind.itemTitle)已删除") {
            switch confirmation.kind {
            case .author:
                try await self.repository.deleteAuthor(name: confirmation.name)
            case .press:
                try await self.repository.deletePress(name: confirmation.name)
            }
        }
    }
}

private extension BookContributorManagementViewModel {
    func startObservation() {
        observationErrorMessage = nil
        if groups.isEmpty {
            contentState = .loading
        }
        let setting = BookshelfDisplaySetting.defaultValue(for: kind.dimension)
        observationTask = Task {
            do {
                for try await snapshot in repository.observeBookshelfAggregateSnapshot(
                    setting: setting,
                    searchKeyword: nil
                ) {
                    guard !Task.isCancelled else { return }
                    let nextGroups: [BookshelfAggregateGroup]
                    switch kind {
                    case .author:
                        nextGroups = snapshot.authorSections.flatMap(\.authors)
                    case .press:
                        nextGroups = snapshot.pressGroups
                    }
                    await MainActor.run {
                        self.groups = nextGroups
                        let validNames = Set(nextGroups.map(\.title))
                        self.selectedNames = self.selectedNames.filter { validNames.contains($0) }
                        self.observationErrorMessage = nil
                        self.contentState = nextGroups.isEmpty ? .empty : .content
                    }
                }
            } catch {
                await MainActor.run {
                    if self.groups.isEmpty {
                        self.contentState = .error("暂时无法加载\(self.kind.title)")
                    } else {
                        self.contentState = .content
                        self.observationErrorMessage = "\(self.kind.title)刷新失败"
                    }
                }
            }
        }
    }

    /// 启动作者/出版社写操作；会取消旧写任务并在 MainActor 收口，避免并发重复提交。
    func runWriteAction(
        _ action: BookContributorWriteAction,
        successMessage: String,
        clearsSelectionOnSuccess: Bool = false,
        operation: @escaping () async throws -> Void
    ) {
        guard activeWriteAction == nil else { return }
        activeWriteAction = action
        actionNotice = "\(action.title)处理中…"
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await operation()
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.actionNotice = successMessage
                    if clearsSelectionOnSuccess {
                        self.cancelSelectionMode()
                        self.actionNotice = successMessage
                    }
                }
            } catch {
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.writeError = error.localizedDescription
                    self.actionNotice = error.localizedDescription
                }
            }
        }
    }
}
