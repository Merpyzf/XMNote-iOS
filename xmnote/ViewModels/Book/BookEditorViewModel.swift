/**
 * [INPUT]: 依赖 BookEditorRepositoryProtocol 提供录入选项、偏好与保存事务，依赖 BookEditorMode 区分新增/编辑入口
 * [OUTPUT]: 对外提供 BookEditorViewModel，驱动完整录入页的加载、编辑与保存交互
 * [POS]: ViewModels/Book 的书籍录入状态编排器，被 BookEditorView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 书籍录入状态源，负责新增、有效书编辑与相关占位书资料编辑的页面编排；所有 UI 状态均在主线程更新。
@MainActor
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

    /// 更新草稿文本字段，供输入控件通过统一入口写入页面状态。
    func updateDraftText(_ value: String, for keyPath: WritableKeyPath<BookEditorDraft, String>) {
        updateDraft { draft in
            draft[keyPath: keyPath] = value
        }
    }

    /// 更新标签输入框文本，便于后续集中增加去重、校验或输入清洗。
    func updateTagInput(_ value: String) {
        tagInput = value
    }

    /// 设置进度单位，不改变其它进度字段，保留用户当前输入。
    func setProgressUnit(_ progressUnit: BookEntryProgressUnit) {
        updateDraft { draft in
            draft.progressUnit = progressUnit
        }
    }

    /// 设置阅读状态，状态时间仍由用户或独立控件决定。
    func setReadingStatus(_ readingStatus: BookEntryReadingStatus) {
        updateDraft { draft in
            draft.readingStatus = readingStatus
        }
    }

    /// 设置阅读状态变更日期，供状态日期控件写入草稿。
    func setReadStatusChangedDate(_ date: Date) {
        updateDraft { draft in
            draft.readStatusChangedDate = date
        }
    }

    /// 设置购买日期，nil 由保存归一化流程继续按未填写处理。
    func setPurchaseDate(_ date: Date?) {
        updateDraft { draft in
            draft.purchaseDate = date
        }
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
            case .editRelatedPlaceholder(let bookId, _):
                draft = try await repository.fetchEditableRelatedPlaceholder(bookId: bookId)
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
        let normalized = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard let currentDraft = draft else { return }
        if !currentDraft.tagNames.contains(normalized) {
            updateDraft { draft in
                draft.tagNames.append(normalized)
                draft.tagNames.sort()
            }
        }
        tagInput = ""
    }

    /// 删除已选择标签。
    func removeTag(_ tag: String) {
        updateDraft { draft in
            draft.tagNames.removeAll { $0 == tag }
        }
    }

    /// 选择来源建议值，回填来源文本框。
    func selectSource(_ option: BookEditorNamedOption) {
        updateDraft { draft in
            draft.sourceName = option.title
        }
    }

    /// 选择分组建议值，回填分组文本框。
    func selectGroup(_ option: BookEditorNamedOption) {
        updateDraft { draft in
            draft.groupName = option.title
        }
    }

    /// 选择或取消标签建议值。
    func toggleTag(_ option: BookEditorNamedOption) {
        updateDraft { draft in
            if draft.tagNames.contains(option.title) {
                draft.tagNames.removeAll { $0 == option.title }
            } else {
                draft.tagNames.append(option.title)
                draft.tagNames.sort()
            }
        }
    }

    /// 按当前书籍类型重置默认进度单位，避免纸书和电子书沿用错误单位。
    func applyBookType(_ bookType: BookEntryBookType) {
        updateDraft { draft in
            draft.bookType = bookType
            draft.progressUnit = bookType.defaultProgressUnit
        }
    }

    private func updateDraft(_ mutate: (inout BookEditorDraft) -> Void) {
        guard var draft else { return }
        mutate(&draft)
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
