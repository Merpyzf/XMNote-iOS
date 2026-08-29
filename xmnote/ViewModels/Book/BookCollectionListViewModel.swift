/**
 * [INPUT]: 依赖 BookshelfRepositoryProtocol 的书单观察流、写入能力、微信读书书单解析保存能力与书单显示设置读写入口
 * [OUTPUT]: 对外提供 BookCollectionListViewModel，驱动书单 Tab 的列表、分组偏好恢复、显示设置、创建、编辑、删除、排序、系统分享导入与反馈状态
 * [POS]: ViewModels/Book 的书单列表状态编排器，被书单列表页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书单列表读取状态，区分加载、内容、空态和错误。
enum BookCollectionContentState: Equatable {
    case loading
    case content
    case empty
    case error(String)
}

/// 书单列表当前写入动作，用于禁用重复提交并展示语义反馈。
enum BookCollectionPendingAction: Hashable {
    case create
    case update
    case delete
    case reorder
    case repairAnnual
    case restore
    case `import`
    case export
    case share
}

/// 书单表单弹窗状态，承载创建或编辑时的初始值。
struct BookCollectionFormPresentation: Identifiable, Hashable {
    enum Mode: Hashable {
        case create
        case edit(BookCollectionListItem)
    }

    let mode: Mode

    var id: String {
        switch mode {
        case .create:
            return "create"
        case .edit(let item):
            return "edit-\(item.id)"
        }
    }

    var title: String {
        switch mode {
        case .create:
            return "新建书单"
        case .edit:
            return "编辑书单"
        }
    }

    var initialTitle: String {
        switch mode {
        case .create:
            return ""
        case .edit(let item):
            return item.title
        }
    }

    var initialDescription: String {
        switch mode {
        case .create:
            return ""
        case .edit(let item):
            return item.description
        }
    }
}

/// 书单删除确认状态，限制为手动书单。
struct BookCollectionDeleteConfirmation: Identifiable, Hashable {
    let item: BookCollectionListItem

    var id: Int64 { item.id }
}

/// 微信读书书单导入链接输入 Sheet 状态。
struct BookCollectionWereadImportRequest: Identifiable, Hashable {
    let id = UUID()
}

/// 书单列表状态编排器，负责把 Repository 快照转换为列表 UI 可消费状态；所有 UI 状态在主线程更新。
@MainActor
@Observable
final class BookCollectionListViewModel {
    var snapshot: BookCollectionListSnapshot = .empty
    var contentState: BookCollectionContentState = .loading
    var selectedKind: BookCollectionKind = .manual
    var displaySetting: BookCollectionDisplaySetting
    var activeForm: BookCollectionFormPresentation?
    var deleteConfirmation: BookCollectionDeleteConfirmation?
    var wereadImportRequest: BookCollectionWereadImportRequest?
    var importPreview: BookCollectionImportPreview?
    var wereadImportErrorMessage: String?
    var importedCollectionID: Int64?
    var activeAction: BookCollectionPendingAction?
    var actionFeedback: BookshelfActionFeedback?
    var observationErrorMessage: String?

    private let repository: any BookshelfRepositoryProtocol
    private var persistedSelectedKind: BookCollectionKind = .manual
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var feedbackClearTask: Task<Void, Never>?

    var visibleCollections: [BookCollectionListItem] {
        switch selectedKind {
        case .manual:
            return snapshot.manualCollections
        case .annual:
            return snapshot.annualCollections
        }
    }

    var canCreateManualCollection: Bool {
        selectedKind == .manual && activeAction == nil
    }

    /// 注入书架仓储并启动书单观察流。
    init(repository: any BookshelfRepositoryProtocol) {
        self.repository = repository
        let initialDisplaySetting = repository.fetchBookCollectionDisplaySetting()
        self.displaySetting = initialDisplaySetting
        self.selectedKind = initialDisplaySetting.selectedKind
        self.persistedSelectedKind = initialDisplaySetting.selectedKind
        startObservation()
        repairAnnualCollections()
    }

    /// 取消观察与写入任务，避免页面释放后继续更新状态。
    isolated deinit {
        observationTask?.cancel()
        writeTask?.cancel()
        feedbackClearTask?.cancel()
    }

    /// 打开新建书单表单。
    func presentCreateForm() {
        guard canCreateManualCollection else { return }
        activeForm = BookCollectionFormPresentation(mode: .create)
    }

    /// 打开编辑书单表单；年度书单保持只读。
    func presentEditForm(for item: BookCollectionListItem) {
        guard item.kind == .manual, activeAction == nil else { return }
        activeForm = BookCollectionFormPresentation(mode: .edit(item))
    }

    /// 打开删除确认；年度书单保持只读。
    func presentDeleteConfirmation(for item: BookCollectionListItem) {
        guard item.kind == .manual, activeAction == nil else { return }
        deleteConfirmation = BookCollectionDeleteConfirmation(item: item)
    }

    /// 打开微信读书书单导入链接输入面板。
    func presentWereadImport() {
        guard activeAction == nil else { return }
        wereadImportErrorMessage = nil
        wereadImportRequest = BookCollectionWereadImportRequest()
    }

    /// 保存书单首页显示设置，立即驱动列表渲染刷新。
    func updateDisplaySetting(_ setting: BookCollectionDisplaySetting) {
        var nextSetting = setting
        nextSetting.selectedKind = persistedSelectedKind
        guard nextSetting != displaySetting else { return }
        displaySetting = nextSetting
        repository.saveBookCollectionDisplaySetting(nextSetting)
    }

    /// 切换书单首页分组，并把用户主动选择立即写入轻量偏好。
    func selectKind(_ kind: BookCollectionKind) {
        guard selectedKind != kind || persistedSelectedKind != kind else { return }
        selectedKind = kind
        persistSelectedKind(kind)
    }

    /// 提交创建或编辑表单。
    func submitForm(_ presentation: BookCollectionFormPresentation, title: String, description: String) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(presentation.mode == .create ? .create : .update, message: "正在保存书单…")
            do {
                let input = BookCollectionFormInput(title: title, description: description)
                switch presentation.mode {
                case .create:
                    _ = try await repository.createBookCollection(input: input)
                case .edit(let item):
                    try await repository.updateBookCollection(collectionID: item.id, input: input)
                }
                finishAction(message: "书单已保存")
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
            } catch {
                failAction(error)
            }
        }
    }

    /// 按当前拖拽后的顺序提交手动书单排序。
    func submitManualOrder(_ ids: [Int64]) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.reorder, message: "正在更新排序…")
            do {
                try await repository.updateManualBookCollectionOrder(ids)
                activeAction = nil
                actionFeedback = nil
            } catch {
                failAction(error)
            }
        }
    }

    /// 解析微信读书书单链接，成功后进入导入预览，不提前写入数据库。
    func parseWereadImportLink(_ link: String) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            wereadImportErrorMessage = nil
            setActiveAction(.import, message: "正在解析微信读书书单…")
            do {
                let preview = try await repository.parseWereadBookCollectionImport(link: link)
                activeAction = nil
                wereadImportRequest = nil
                importPreview = preview
                wereadImportErrorMessage = nil
                actionFeedback = nil
            } catch {
                failWereadImportInSheet(error)
            }
        }
    }

    /// 系统分享入口直接完成解析与保存；数据库写入仍经 Repository，并在成功后跳转新书单详情。
    func importWereadLinkDirectly(_ link: String) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            wereadImportErrorMessage = nil
            setActiveAction(.import, message: "正在导入微信读书书单…")
            do {
                let preview = try await repository.parseWereadBookCollectionImport(link: link)
                let item = try await repository.saveWereadBookCollectionImport(preview)
                wereadImportRequest = nil
                importPreview = nil
                wereadImportErrorMessage = nil
                selectKind(.manual)
                importedCollectionID = item.id
                finishAction(message: "微信读书书单已导入")
            } catch {
                failAction(error)
            }
        }
    }

    /// 确认导入预览，在单个事务中创建书单、占位书与收藏理由。
    func confirmWereadImport(_ preview: BookCollectionImportPreview) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            wereadImportErrorMessage = nil
            setActiveAction(.import, message: "正在导入书单…")
            do {
                let item = try await repository.saveWereadBookCollectionImport(preview)
                importPreview = nil
                wereadImportErrorMessage = nil
                selectKind(.manual)
                importedCollectionID = item.id
                finishAction(message: "微信读书书单已导入")
            } catch {
                failWereadImportInSheet(error)
            }
        }
    }

    /// 消费导入成功后的详情跳转 ID，避免页面重绘重复导航。
    func consumeImportedCollectionID() {
        importedCollectionID = nil
    }

    /// 重新建立书单列表观察流，用于首轮读取失败后的显式恢复。
    func retryObservation() {
        startObservation()
    }

    private func startObservation() {
        observationTask?.cancel()
        observationErrorMessage = nil
        if snapshot.isEmpty {
            contentState = .loading
        }
        observationTask = Task { [repository] in
            do {
                for try await snapshot in repository.observeBookCollectionList() {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.snapshot = snapshot
                        self.observationErrorMessage = nil
                        self.refreshContentState()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if self.snapshot.isEmpty {
                        self.contentState = .error("暂时无法加载书单")
                    } else {
                        self.refreshContentState()
                        self.observationErrorMessage = "书单刷新失败"
                    }
                }
            }
        }
    }

    private func repairAnnualCollections() {
        Task { [repository] in
            do {
                try await repository.repairAnnualBookCollections()
            } catch {
                await MainActor.run {
                    self.actionFeedback = BookshelfActionFeedback(kind: .warning, message: "年度书单同步失败")
                }
            }
        }
    }

    private func refreshContentState() {
        if snapshot.isEmpty {
            contentState = .empty
        } else {
            contentState = .content
        }
        if selectedKind == .annual, snapshot.annualCollections.isEmpty, !snapshot.manualCollections.isEmpty {
            selectedKind = .manual
        }
    }

    private func persistSelectedKind(_ kind: BookCollectionKind) {
        persistedSelectedKind = kind
        var nextSetting = displaySetting
        nextSetting.selectedKind = kind
        guard nextSetting != displaySetting else { return }
        displaySetting = nextSetting
        repository.saveBookCollectionDisplaySetting(nextSetting)
    }

    private func setActiveAction(_ action: BookCollectionPendingAction, message: String) {
        activeAction = action
        actionFeedback = BookshelfActionFeedback(kind: .processing, message: message)
    }

    private func finishAction(message: String) {
        activeAction = nil
        activeForm = nil
        deleteConfirmation = nil
        wereadImportRequest = nil
        wereadImportErrorMessage = nil
        actionFeedback = BookshelfActionFeedback(kind: .success, message: message)
        scheduleFeedbackClear()
    }

    private func failWereadImportInSheet(_ error: Error) {
        activeAction = nil
        actionFeedback = nil
        wereadImportErrorMessage = error.localizedDescription
    }

    private func failAction(_ error: Error) {
        activeAction = nil
        wereadImportErrorMessage = nil
        actionFeedback = BookshelfActionFeedback(kind: .error, message: "操作失败")
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
}
