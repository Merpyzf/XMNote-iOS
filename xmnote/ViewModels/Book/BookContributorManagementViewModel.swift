/**
 * [INPUT]: 依赖 BookRepositoryProtocol 观察作者/出版社聚合快照，并提交作者/出版社重命名与删除写入
 * [OUTPUT]: 对外提供 BookContributorKind、BookContributorManagementViewModel 与作者/出版社编辑删除弹窗状态
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

/// 作者/出版社管理写入动作，用于禁用重复触发并显示即时反馈。
enum BookContributorWriteAction: Hashable {
    case rename
    case delete

    var title: String {
        switch self {
        case .rename:
            return "编辑"
        case .delete:
            return "删除"
        }
    }
}

/// 作者/出版社管理页状态源，负责观察聚合数据并提交编辑、删除动作。
@Observable
final class BookContributorManagementViewModel {
    var groups: [BookshelfAggregateGroup] = []
    var contentState: BookshelfContentState = .loading
    var activeWriteAction: BookContributorWriteAction?
    var writeError: String?
    var actionNotice: String?
    var activeNameEdit: BookContributorNameEdit?
    var activeDeleteConfirmation: BookContributorDeleteConfirmation?
    var nameEditText = ""

    let kind: BookContributorKind

    private let repository: any BookRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    /// 注入仓储并启动聚合快照观察；观察任务在实例释放时取消，回写 UI 状态统一回到 MainActor。
    init(kind: BookContributorKind, repository: any BookRepositoryProtocol) {
        self.kind = kind
        self.repository = repository
        startObservation()
    }

    /// 释放观察与写入任务，避免页面退出后继续回写状态。
    deinit {
        observationTask?.cancel()
        writeTask?.cancel()
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
        contentState = .loading
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
                        self.contentState = nextGroups.isEmpty ? .empty : .content
                    }
                }
            } catch {
                await MainActor.run {
                    self.contentState = .error(error.localizedDescription)
                }
            }
        }
    }

    /// 启动作者/出版社写操作；会取消旧写任务并在 MainActor 收口，避免并发重复提交。
    func runWriteAction(
        _ action: BookContributorWriteAction,
        successMessage: String,
        operation: @escaping () async throws -> Void
    ) {
        guard activeWriteAction == nil else { return }
        activeWriteAction = action
        actionNotice = "\(action.title)处理中..."
        writeError = nil
        writeTask?.cancel()
        writeTask = Task {
            do {
                try await operation()
                await MainActor.run {
                    self.activeWriteAction = nil
                    self.actionNotice = successMessage
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
