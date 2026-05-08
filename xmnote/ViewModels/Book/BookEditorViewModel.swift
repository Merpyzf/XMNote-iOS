/**
 * [INPUT]: 依赖 BookEditorRepositoryProtocol 提供录入选项、偏好与保存事务，依赖 BookEditorMode 区分新增/编辑入口
 * [OUTPUT]: 对外提供 BookEditorViewModel，驱动完整录入页的加载、编辑与保存交互
 * [POS]: ViewModels/Book 的书籍录入状态编排器，被 BookEditorView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书籍录入状态源，负责新增与编辑两类草稿、建议选项和保存事务的页面编排。
@Observable
final class BookEditorViewModel {
    var draft: BookEditorDraft?
    var initialDraft: BookEditorDraft?
    var options: BookEditorOptions?
    var errorMessage: String?
    var isLoading = false
    var isSaving = false
    var tagInput: String = ""
    var didSaveBook = false

    private let mode: BookEditorMode
    private let repository: any BookEditorRepositoryProtocol

    init(
        mode: BookEditorMode,
        repository: any BookEditorRepositoryProtocol
    ) {
        self.mode = mode
        self.repository = repository
    }

    var hasUnsavedChanges: Bool {
        guard let draft, let initialDraft else { return false }
        return draft != initialDraft
    }

    /// 首次进入录入页时加载选项并构建草稿。
    @MainActor
    func loadIfNeeded() async {
        guard draft == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let options = try await repository.fetchOptions()
            let draft: BookEditorDraft
            switch mode {
            case .create(let seed):
                draft = repository.makeDraft(from: seed)
            case .edit(let bookId):
                draft = try await repository.fetchEditableBook(bookId: bookId)
            }
            self.options = options
            self.draft = draft
            self.initialDraft = draft
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 录入新标签并去重，保持标签编辑区的即时反馈。
    func commitTagInput() {
        guard var draft else { return }
        let normalized = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if !draft.tagNames.contains(normalized) {
            draft.tagNames.append(normalized)
            draft.tagNames.sort()
            self.draft = draft
        }
        tagInput = ""
    }

    /// 删除已选择标签。
    func removeTag(_ tag: String) {
        guard var draft else { return }
        draft.tagNames.removeAll { $0 == tag }
        self.draft = draft
    }

    /// 选择来源建议值，回填来源文本框。
    func selectSource(_ option: BookEditorNamedOption) {
        guard var draft else { return }
        draft.sourceName = option.title
        self.draft = draft
    }

    /// 选择分组建议值，回填分组文本框。
    func selectGroup(_ option: BookEditorNamedOption) {
        guard var draft else { return }
        draft.groupName = option.title
        self.draft = draft
    }

    /// 选择或取消标签建议值。
    func toggleTag(_ option: BookEditorNamedOption) {
        guard var draft else { return }
        if draft.tagNames.contains(option.title) {
            draft.tagNames.removeAll { $0 == option.title }
        } else {
            draft.tagNames.append(option.title)
            draft.tagNames.sort()
        }
        self.draft = draft
    }

    /// 按当前书籍类型重置默认进度单位，避免纸书和电子书沿用错误单位。
    func applyBookType(_ bookType: BookEntryBookType) {
        guard var draft else { return }
        draft.bookType = bookType
        draft.progressUnit = bookType.defaultProgressUnit
        self.draft = draft
    }

    /// 保存录入草稿；成功后更新偏好与脏状态基线。
    @MainActor
    func save() async -> Int64? {
        guard let draft else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let bookId = try await repository.saveBookDraft(draft, mode: mode)
            initialDraft = self.draft
            didSaveBook = true
            return bookId
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }
}
