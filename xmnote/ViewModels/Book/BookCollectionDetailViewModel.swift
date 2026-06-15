/**
 * [INPUT]: 依赖 BookshelfRepositoryProtocol 的书单详情观察流与 collection_book 写入能力
 * [OUTPUT]: 对外提供 BookCollectionDetailViewModel，驱动书单详情、加入书籍、移除、推荐语编辑与删除反馈
 * [POS]: ViewModels/Book 的书单详情状态编排器，被 BookCollectionDetailView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书单内推荐语编辑弹窗状态。
struct BookCollectionRecommendEdit: Identifiable, Hashable {
    let item: BookCollectionBookItem

    var id: Int64 { item.id }
}

/// 书单内移除书籍确认状态。
struct BookCollectionBookRemoveConfirmation: Identifiable, Hashable {
    let item: BookCollectionBookItem

    var id: Int64 { item.id }
}

/// 书单详情状态编排器，所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class BookCollectionDetailViewModel {
    let collectionID: Int64
    var detail: BookCollectionDetail?
    var contentState: BookCollectionContentState = .loading
    var activeAction: BookCollectionPendingAction?
    var actionFeedback: BookshelfActionFeedback?
    var activeForm: BookCollectionFormPresentation?
    var recommendEdit: BookCollectionRecommendEdit?
    var removeConfirmation: BookCollectionBookRemoveConfirmation?
    var deleteConfirmation: BookCollectionDeleteConfirmation?
    var shouldDismissAfterDelete = false

    private let repository: any BookshelfRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var feedbackClearTask: Task<Void, Never>?

    var isManual: Bool {
        detail?.kind == .manual
    }

    var canEditCollection: Bool {
        isManual && activeAction == nil
    }

    /// 注入书单 ID 与仓储，并启动详情观察。
    init(collectionID: Int64, repository: any BookshelfRepositoryProtocol) {
        self.collectionID = collectionID
        self.repository = repository
        startObservation()
    }

    /// 取消详情观察与写入任务。
    isolated deinit {
        observationTask?.cancel()
        writeTask?.cancel()
        feedbackClearTask?.cancel()
    }

    /// 将 BookPicker 返回的本地书籍加入当前手动书单。
    func addPickerResult(_ result: BookPickerResult) {
        let bookIDs: [Int64]
        switch result {
        case .cancelled, .addFlowRequested:
            bookIDs = []
        case .single(let selection):
            bookIDs = Self.localBookID(from: selection).map { [$0] } ?? []
        case .multiple(let selections):
            bookIDs = selections.compactMap(Self.localBookID(from:))
        }
        addBooks(bookIDs)
    }

    /// 打开推荐语编辑弹窗。
    func presentRecommendEdit(for item: BookCollectionBookItem) {
        guard activeAction == nil else { return }
        recommendEdit = BookCollectionRecommendEdit(item: item)
    }

    /// 打开书单标题与简介编辑面板；年度书单保持只读。
    func presentEditForm() {
        guard let detail, detail.kind == .manual, activeAction == nil else { return }
        activeForm = BookCollectionFormPresentation(
            mode: .edit(listItem(from: detail))
        )
    }

    /// 打开移除关系确认弹窗。
    func presentRemoveConfirmation(for item: BookCollectionBookItem) {
        guard isManual, activeAction == nil else { return }
        removeConfirmation = BookCollectionBookRemoveConfirmation(item: item)
    }

    /// 打开删除书单确认弹窗。
    func presentDeleteConfirmation() {
        guard let detail, detail.kind == .manual, activeAction == nil else { return }
        deleteConfirmation = BookCollectionDeleteConfirmation(item: listItem(from: detail))
    }

    /// 提交详情页书单标题与简介编辑。
    func submitForm(_ presentation: BookCollectionFormPresentation, title: String, description: String) {
        guard activeAction == nil else { return }
        guard case .edit(let item) = presentation.mode else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.update, message: "正在保存书单…")
            do {
                try await repository.updateBookCollection(
                    collectionID: item.id,
                    input: BookCollectionFormInput(title: title, description: description)
                )
                finishAction(message: "书单已保存")
            } catch {
                failAction(error)
            }
        }
    }

    /// 提交推荐语编辑。
    func submitRecommend(_ edit: BookCollectionRecommendEdit, recommend: String) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.update, message: "正在保存推荐语…")
            do {
                try await repository.updateCollectionBookRecommend(collectionBookID: edit.item.id, recommend: recommend)
                finishAction(message: "推荐语已保存")
            } catch {
                failAction(error)
            }
        }
    }

    /// 确认从书单移除单本书籍 relation。
    func confirmRemove(_ confirmation: BookCollectionBookRemoveConfirmation) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.delete, message: "正在移出书籍…")
            do {
                try await repository.removeBooksFromCollection(collectionBookIDs: [confirmation.item.id])
                finishAction(message: "已移出书单")
            } catch {
                failAction(error)
            }
        }
    }

    /// 确认删除当前手动书单。
    func confirmDelete(_ confirmation: BookCollectionDeleteConfirmation) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.delete, message: "正在删除书单…")
            do {
                try await repository.deleteBookCollection(collectionID: confirmation.item.id)
                finishAction(message: "书单已删除")
                shouldDismissAfterDelete = true
            } catch {
                failAction(error)
            }
        }
    }

    /// 按拖拽后的 relation 顺序提交书单内排序。
    func submitBookOrder(_ relationIDs: [Int64]) {
        guard isManual, activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository, collectionID] in
            setActiveAction(.reorder, message: "正在更新排序…")
            do {
                try await repository.updateBooksInCollectionOrder(collectionID: collectionID, relationIDs: relationIDs)
                finishAction(message: "排序已更新")
            } catch {
                failAction(error)
            }
        }
    }

    private func addBooks(_ bookIDs: [Int64]) {
        guard isManual, activeAction == nil, !bookIDs.isEmpty else { return }
        writeTask?.cancel()
        writeTask = Task { [repository, collectionID] in
            setActiveAction(.create, message: "正在加入书单…")
            do {
                try await repository.addBooks(bookIDs, toCollection: collectionID)
                finishAction(message: "已加入书单")
            } catch {
                failAction(error)
            }
        }
    }

    private func startObservation() {
        observationTask?.cancel()
        contentState = .loading
        observationTask = Task { [repository, collectionID] in
            do {
                for try await detail in repository.observeBookCollectionDetail(collectionID: collectionID) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.detail = detail
                        if let detail {
                            self.contentState = detail.books.isEmpty ? .empty : .content
                        } else {
                            self.contentState = .error("未能查询到书单")
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.contentState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func setActiveAction(_ action: BookCollectionPendingAction, message: String) {
        activeAction = action
        actionFeedback = BookshelfActionFeedback(kind: .processing, message: message)
    }

    private func finishAction(message: String) {
        activeAction = nil
        activeForm = nil
        recommendEdit = nil
        removeConfirmation = nil
        deleteConfirmation = nil
        actionFeedback = BookshelfActionFeedback(kind: .success, message: message)
        scheduleFeedbackClear()
    }

    private func failAction(_ error: Error) {
        activeAction = nil
        actionFeedback = BookshelfActionFeedback(kind: .error, message: error.localizedDescription)
        scheduleFeedbackClear()
    }

    private func scheduleFeedbackClear() {
        feedbackClearTask?.cancel()
        feedbackClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run {
                guard self?.activeAction == nil else { return }
                self?.actionFeedback = nil
            }
        }
    }

    private static func localBookID(from selection: BookPickerSelection) -> Int64? {
        if case .local(let book) = selection {
            return book.id
        }
        return nil
    }

    private func listItem(from detail: BookCollectionDetail) -> BookCollectionListItem {
        BookCollectionListItem(
            id: detail.id,
            title: detail.title,
            description: detail.description,
            kind: detail.kind,
            order: detail.order,
            year: detail.year,
            bookCount: detail.bookCount,
            finishedCount: detail.finishedCount,
            targetReadCount: detail.targetReadCount,
            representativeCovers: detail.books.prefix(5).map(\.book.cover)
        )
    }
}
