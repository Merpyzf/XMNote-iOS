/**
 * [INPUT]: 依赖 ChapterManagementRepositoryProtocol 提供章节树观察、批量导入与可恢复事务写入，接收 bookID/focusChapterID 路由参数
 * [OUTPUT]: 对外提供 ChapterManagerViewModel 及标题、批量/远端目录同步、移动、排序、Undo、删除页面状态
 * [POS]: ViewModels/Book 的目录管理状态源，负责展开、多选、定位、写入门闩、持久化撤销与错误恢复
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 章节管理页面读取阶段；写入状态由独立即时门闩表达。
enum ChapterManagerContentState: Hashable {
    case loading
    case empty
    case content
    case error(String)
}

/// 标题编辑请求，区分新增根/子章节与重命名已有章节。
struct ChapterTitleEditorRequest: Identifiable, Hashable {
    enum Mode: Hashable {
        case create(parentID: Int64)
        case rename(chapterID: Int64)
    }

    let id = UUID()
    let mode: Mode
    let title: String

    var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }
}

/// 移动 Sheet 请求，保留已经去除后代重复项的顶层章节 ID。
struct ChapterMoveRequest: Identifiable, Hashable {
    let id = UUID()
    let chapterIDs: [Int64]
    let title: String
}

/// 同级排序 Sheet 请求，以打开时快照作为本地拖动草稿。
struct ChapterSiblingOrderRequest: Identifiable, Hashable {
    let id = UUID()
    let parentID: Int64
    let title: String
    let siblings: [ChapterManagementItem]
}

/// 移动或同级重排成功后的可行动反馈；快照由 Repository 在原写事务内生成。
struct ChapterStructureUndoFeedback: Identifiable, Hashable {
    let id = UUID()
    let message: String
    let snapshot: ChapterStructureRestoreSnapshot
    let focusChapterIDs: [Int64]
}

/// 删除确认请求，明确区分“所选及后代”与“只清空子章节”两条 Android 操作链。
struct ChapterDeletionRequest: Identifiable, Hashable {
    enum Scope: Hashable {
        case subtrees(chapterIDs: [Int64])
        case descendants(parentID: Int64)
    }

    let id = UUID()
    let scope: Scope
    let title: String
    let message: String
    let affectedNoteCount: Int
}

/// 目录管理状态源；Observation 状态与所有 UI 写入统一由 MainActor 串行维护。
@MainActor
@Observable
final class ChapterManagerViewModel {
    let bookID: Int64
    let bookName: String
    let doubanID: Int?
    let focusChapterID: Int64?

    var snapshot: ChapterManagementSnapshot
    var contentState: ChapterManagerContentState = .loading
    var expandedIDs: Set<Int64> = []
    var selectedIDs: Set<Int64> = []
    var searchText = ""
    var isWriting = false
    var activeWriteTitle = "正在保存…"
    var writeErrorMessage: String?
    var pendingScrollTargetID: Int64?
    var titleEditorRequest: ChapterTitleEditorRequest?
    var titleEditorText = ""
    var moveRequest: ChapterMoveRequest?
    var siblingOrderRequest: ChapterSiblingOrderRequest?
    var deletionRequest: ChapterDeletionRequest?
    var remoteSyncViewModel: ChapterRemoteSyncViewModel?
    var batchImportViewModel: ChapterBatchImportViewModel?
    var structureUndoFeedback: ChapterStructureUndoFeedback?
    var editModeDismissalToken = 0

    private let repository: any ChapterManagementRepositoryProtocol
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var hasAppliedInitialFocus = false
    private var pendingImportedFocusID: Int64?

    /// 注入书籍路由参数与仓储；观察由页面完成依赖注入后显式启动。
    init(
        bookID: Int64,
        bookName: String = "",
        doubanID: Int? = nil,
        focusChapterID: Int64? = nil,
        repository: any ChapterManagementRepositoryProtocol
    ) {
        self.bookID = bookID
        self.bookName = bookName
        self.doubanID = doubanID
        self.focusChapterID = focusChapterID
        self.repository = repository
        snapshot = .empty(bookID: bookID)
    }

    /// 取消页面持有的观察与写入 Task，避免离场后继续回写状态。
    isolated deinit {
        observationTask?.cancel()
        writeTask?.cancel()
    }

    var visibleItems: [ChapterManagementVisibleItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            return snapshot.flattened.compactMap { node in
                guard node.item.displayTitle.localizedCaseInsensitiveContains(keyword)
                        || node.item.pathText.localizedCaseInsensitiveContains(keyword) else {
                    return nil
                }
                return ChapterManagementVisibleItem(node: node, isExpanded: false)
            }
        }
        var result: [ChapterManagementVisibleItem] = []
        func visit(_ node: ChapterManagementNode) {
            let isExpanded = expandedIDs.contains(node.id) && !node.children.isEmpty
            result.append(ChapterManagementVisibleItem(node: node, isExpanded: isExpanded))
            if isExpanded {
                node.children.forEach(visit)
            }
        }
        snapshot.roots.forEach(visit)
        return result
    }

    var selectionCount: Int { selectedIDs.count }

    var isAllVisibleSelected: Bool {
        let visibleIDs = Set(visibleItems.map(\.id))
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedIDs)
    }

    var moveTargets: [ChapterMoveTarget] {
        guard let request = moveRequest else { return [] }
        let selected = Set(request.chapterIDs)
        let roots = snapshot.topLevelSelection(from: selected)
        let excludedIDs = roots.reduce(into: Set<Int64>()) { result, node in
            result.formUnion(node.subtreeIDs())
        }
        let movingHeight = roots.map { $0.subtreeHeight() }.max() ?? 0
        let rootTarget = ChapterMoveTarget(
            id: 0,
            title: "根目录",
            pathText: "移动为一级章节",
            level: 0,
            disabledReason: nil
        )
        let chapterTargets = snapshot.flattened.map { node in
            let reason: String?
            if excludedIDs.contains(node.id) {
                reason = "不能移动到所选章节或其后代"
            } else if node.item.level + movingHeight > ChapterManagementPolicy.maximumDepth {
                reason = "移动后会超过 \(ChapterManagementPolicy.maximumDepth) 层"
            } else {
                reason = nil
            }
            return ChapterMoveTarget(
                id: node.id,
                title: node.item.displayTitle,
                pathText: node.item.pathText,
                level: node.item.level,
                disabledReason: reason
            )
        }
        return [rootTarget] + chapterTargets
    }

    /// 建立数据库观察；AsyncSequence 在实例释放或重试时取消，错误保留当前可信快照。
    func startObservation() {
        guard observationTask == nil else { return }
        if snapshot.chapterCount == 0 {
            contentState = .loading
        }
        let stream = repository.observeSnapshot(bookID: bookID)
        observationTask = Task { [weak self] in
            do {
                for try await nextSnapshot in stream {
                    guard !Task.isCancelled, let self else { return }
                    apply(nextSnapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                contentState = .error(error.localizedDescription)
                observationTask = nil
            }
        }
    }

    /// 重新建立失败的观察流；已有内容先保留，避免页面闪空。
    func retryObservation() {
        observationTask?.cancel()
        observationTask = nil
        startObservation()
    }

    /// 展开或收起一个有子章节的行；叶子不产生无意义状态。
    func toggleExpanded(chapterID: Int64) {
        guard let node = snapshot.node(id: chapterID), !node.children.isEmpty else { return }
        if expandedIDs.contains(chapterID) {
            expandedIDs.remove(chapterID)
        } else {
            expandedIDs.insert(chapterID)
        }
    }

    /// 切换多选；不存在或已被并发删除的章节不会进入选择集合。
    func toggleSelection(chapterID: Int64) {
        guard snapshot.node(id: chapterID) != nil else { return }
        if selectedIDs.contains(chapterID) {
            selectedIDs.remove(chapterID)
        } else {
            selectedIDs.insert(chapterID)
        }
    }

    /// 选择或取消当前可见章节；搜索结果之外的既有选择保持不变。
    func toggleSelectAllVisible() {
        let visibleIDs = Set(visibleItems.map(\.id))
        if visibleIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(visibleIDs)
        } else {
            selectedIDs.formUnion(visibleIDs)
        }
    }

    /// 退出编辑态时清空选择，避免返回后保留不可见批量上下文。
    func clearSelection() {
        selectedIDs.removeAll()
    }

    /// 打开远端目录业务 Sheet；子状态源复用同一 Repository，并在呈现后立即启动可取消读取。
    func presentRemoteSync() {
        guard !isWriting, remoteSyncViewModel == nil else { return }
        let model = ChapterRemoteSyncViewModel(bookID: bookID, repository: repository)
        remoteSyncViewModel = model
        model.load()
    }

    /// 打开手工批量录入 Sheet；目录写入与 OCR 识别分别复用页面现有 Repository。
    func presentBatchImport(ocrRepository: any OCRRepositoryProtocol) {
        guard !isWriting, batchImportViewModel == nil else { return }
        batchImportViewModel = ChapterBatchImportViewModel(
            bookID: bookID,
            chapterRepository: repository,
            ocrRepository: ocrRepository
        )
    }

    /// 接收批量导入结果并定位首个根章节；成功本身由目录列表变化表达。
    func completeBatchImport(_ result: ChapterBatchImportResult) {
        structureUndoFeedback = nil
        guard let chapterID = result.firstRootChapterID else { return }
        if snapshot.node(id: chapterID) != nil {
            expandedIDs.formUnion(snapshot.ancestorIDs(of: chapterID))
            pendingScrollTargetID = chapterID
        } else {
            pendingImportedFocusID = chapterID
        }
    }

    /// 打开新增根章节输入。
    func presentCreateRoot() {
        presentCreate(parentID: 0)
    }

    /// 打开新增子章节输入；五级章节在入口前置阻断并说明原因。
    func presentCreateChild(parentID: Int64) {
        guard let parent = snapshot.node(id: parentID) else {
            writeErrorMessage = ChapterManagementError.parentNotFound.localizedDescription
            return
        }
        guard parent.item.level < ChapterManagementPolicy.maximumDepth else {
            writeErrorMessage = ChapterManagementError.exceedsMaximumDepth.localizedDescription
            return
        }
        presentCreate(parentID: parentID)
    }

    /// 打开章节重命名输入；并发删除对象会立即提示而不是展示空弹窗。
    func presentRename(chapterID: Int64) {
        guard let node = snapshot.node(id: chapterID) else {
            writeErrorMessage = ChapterManagementError.chapterNotFound.localizedDescription
            return
        }
        titleEditorText = node.item.title
        titleEditorRequest = ChapterTitleEditorRequest(
            mode: .rename(chapterID: chapterID),
            title: "编辑章节"
        )
    }

    /// 提交当前标题输入；新增后自动展开父级并定位新章节。
    func submitTitleEditor() {
        guard let request = titleEditorRequest else { return }
        let title = titleEditorText
        titleEditorRequest = nil
        switch request.mode {
        case .create(let parentID):
            performWrite(title: "正在创建章节…") { [repository, bookID] in
                let chapterID = try await repository.createChapter(
                    bookID: bookID,
                    parentID: parentID,
                    title: title
                )
                return { [weak self] in
                    if parentID != 0 { self?.expandedIDs.insert(parentID) }
                    self?.pendingScrollTargetID = chapterID
                }
            }
        case .rename(let chapterID):
            performWrite(title: "正在保存章节…") { [repository, bookID] in
                try await repository.renameChapter(bookID: bookID, chapterID: chapterID, title: title)
                return { [weak self] in
                    self?.pendingScrollTargetID = chapterID
                }
            }
        }
    }

    /// 切换星标；成功由星形状态和首页聚合变化表达，不额外展示成功消息。
    func setStarred(chapterID: Int64, isStarred: Bool) {
        performWrite(title: isStarred ? "正在星标章节…" : "正在取消星标…") { [repository, bookID] in
            try await repository.setChapterStarred(
                bookID: bookID,
                chapterID: chapterID,
                isStarred: isStarred
            )
            return nil
        }
    }

    /// 为单行或批量选择打开移动目的地 Sheet，自动去掉已选祖先覆盖的后代。
    func presentMove(chapterIDs: Set<Int64>) {
        let roots = snapshot.topLevelSelection(from: chapterIDs)
        guard !roots.isEmpty else {
            writeErrorMessage = "请先选择要移动的章节。"
            return
        }
        moveRequest = ChapterMoveRequest(
            chapterIDs: roots.map(\.id),
            title: roots.count == 1 ? "移动“\(roots[0].item.displayTitle)”" : "移动 \(roots.count) 个章节"
        )
    }

    /// 将移动请求提交到目标父级；Sheet 先收起，结构变化由观察流平滑刷新。
    func submitMove(targetParentID: Int64) {
        guard let request = moveRequest else { return }
        let targetTitle = targetParentID == 0
            ? "根目录"
            : snapshot.node(id: targetParentID)?.item.displayTitle ?? "目标目录"
        moveRequest = nil
        performWrite(title: "正在移动章节…") { [repository, bookID] in
            let restoreSnapshot = try await repository.moveChapters(
                bookID: bookID,
                chapterIDs: request.chapterIDs,
                targetParentID: targetParentID
            )
            return { [weak self] in
                if targetParentID != 0 { self?.expandedIDs.insert(targetParentID) }
                self?.selectedIDs.removeAll()
                self?.editModeDismissalToken += 1
                self?.pendingScrollTargetID = request.chapterIDs.first
                if restoreSnapshot.restorePositions != restoreSnapshot.expectedCurrentPositions {
                    self?.structureUndoFeedback = ChapterStructureUndoFeedback(
                        message: "已移动 \(request.chapterIDs.count) 个章节到“\(targetTitle)”",
                        snapshot: restoreSnapshot,
                        focusChapterIDs: request.chapterIDs
                    )
                }
            }
        }
    }

    /// 打开指定章节所在同级的排序 Sheet。
    func presentSiblingOrder(chapterID: Int64) {
        guard let node = snapshot.node(id: chapterID) else {
            writeErrorMessage = ChapterManagementError.chapterNotFound.localizedDescription
            return
        }
        let siblings = snapshot.directChildren(parentID: node.item.parentID).map(\.item)
        siblingOrderRequest = ChapterSiblingOrderRequest(
            parentID: node.item.parentID,
            title: node.item.parentID == 0 ? "调整一级目录顺序" : "调整同级顺序",
            siblings: siblings
        )
    }

    /// 保存完整同级顺序；列表位置表达结果，并提供可行动的持久化 Undo。
    func submitSiblingOrder(parentID: Int64, orderedIDs: [Int64]) {
        let feedbackTitle = siblingOrderRequest?.title ?? "目录顺序"
        siblingOrderRequest = nil
        performWrite(title: "正在保存顺序…") { [repository, bookID] in
            let restoreSnapshot = try await repository.reorderSiblings(
                bookID: bookID,
                parentID: parentID,
                orderedChapterIDs: orderedIDs
            )
            return { [weak self] in
                if restoreSnapshot.restorePositions != restoreSnapshot.expectedCurrentPositions {
                    self?.structureUndoFeedback = ChapterStructureUndoFeedback(
                        message: "已调整\(feedbackTitle)",
                        snapshot: restoreSnapshot,
                        focusChapterIDs: orderedIDs
                    )
                }
            }
        }
    }

    /// 通过 Repository 恢复移动或重排前的持久化结构；并发变化会被快照校验拒绝覆盖。
    func undoLastStructureChange() {
        guard let feedback = structureUndoFeedback else { return }
        performWrite(title: "正在撤销调整…") { [repository] in
            try await repository.restoreChapterStructure(feedback.snapshot)
            return { [weak self] in
                self?.structureUndoFeedback = nil
                self?.expandedIDs.formUnion(
                    feedback.snapshot.restorePositions
                        .map(\.parentID)
                        .filter { $0 != 0 }
                )
                self?.pendingScrollTargetID = feedback.focusChapterIDs.first
            }
        }
    }

    /// 主动关闭当前结构 Undo 反馈；不会改变已经提交的数据库结果。
    func dismissStructureUndo() {
        structureUndoFeedback = nil
    }

    /// 请求删除单个或批量章节及其后代，文案明确书摘会进入未分章节。
    func presentDelete(chapterIDs: Set<Int64>) {
        let roots = snapshot.topLevelSelection(from: chapterIDs)
        guard !roots.isEmpty else {
            writeErrorMessage = "请先选择要删除的章节。"
            return
        }
        let deletedChapterCount = roots.reduce(0) { $0 + $1.subtreeIDs().count }
        let affectedNoteCount = roots.reduce(0) { $0 + $1.item.descendantNoteCount }
        let title = roots.count == 1 ? "删除“\(roots[0].item.displayTitle)”" : "删除所选章节"
        deletionRequest = ChapterDeletionRequest(
            scope: .subtrees(chapterIDs: roots.map(\.id)),
            title: title,
            message: "将删除 \(deletedChapterCount) 个章节（含后代）。请选择 \(affectedNoteCount) 条关联书摘的处理方式。",
            affectedNoteCount: affectedNoteCount
        )
    }

    /// 请求清空某章节的全部后代；父章节和父章节直接书摘保持不变。
    func presentDeleteDescendants(parentID: Int64) {
        guard let parent = snapshot.node(id: parentID) else {
            writeErrorMessage = ChapterManagementError.parentNotFound.localizedDescription
            return
        }
        let descendants = parent.children.reduce(into: Set<Int64>()) { result, child in
            result.formUnion(child.subtreeIDs())
        }
        guard !descendants.isEmpty else {
            writeErrorMessage = "“\(parent.item.displayTitle)”没有子章节。"
            return
        }
        let affectedNoteCount = parent.children.reduce(0) { $0 + $1.item.descendantNoteCount }
        deletionRequest = ChapterDeletionRequest(
            scope: .descendants(parentID: parentID),
            title: "删除子章节",
            message: "将保留“\(parent.item.displayTitle)”，并删除其下 \(descendants.count) 个子章节。请选择 \(affectedNoteCount) 条关联书摘的处理方式。",
            affectedNoteCount: affectedNoteCount
        )
    }

    /// 执行已经确认的删除请求；写入期间禁止重复触发。
    func confirmDeletion(noteDisposition: ChapterNoteDisposition) {
        guard let request = deletionRequest else { return }
        deletionRequest = nil
        switch request.scope {
        case .subtrees(let chapterIDs):
            performWrite(title: "正在删除章节…") { [repository, bookID] in
                _ = try await repository.deleteChapters(
                    bookID: bookID,
                    chapterIDs: chapterIDs,
                    noteDisposition: noteDisposition
                )
                return { [weak self] in
                    self?.selectedIDs.removeAll()
                    self?.editModeDismissalToken += 1
                }
            }
        case .descendants(let parentID):
            performWrite(title: "正在删除子章节…") { [repository, bookID] in
                _ = try await repository.deleteDescendants(
                    bookID: bookID,
                    parentID: parentID,
                    noteDisposition: noteDisposition
                )
                return { [weak self] in
                    self?.expandedIDs.remove(parentID)
                    self?.pendingScrollTargetID = parentID
                }
            }
        }
    }

    /// 页面完成滚动后消费一次性定位目标，避免后续状态更新重复滚动。
    func consumeScrollTarget(_ chapterID: Int64) {
        guard pendingScrollTargetID == chapterID else { return }
        pendingScrollTargetID = nil
    }

    /// 清除阻断错误，供 XMSystemAlert 关闭后恢复交互。
    func consumeWriteError() {
        writeErrorMessage = nil
    }
}

private extension ChapterManagerViewModel {
    /// 应用数据库快照，清理已经失效的展开/选择项，并完成首次路由定位。
    func apply(_ nextSnapshot: ChapterManagementSnapshot) {
        let validIDs = Set(nextSnapshot.flattened.map(\.id))
        snapshot = nextSnapshot
        expandedIDs.formIntersection(validIDs)
        selectedIDs.formIntersection(validIDs)
        contentState = nextSnapshot.roots.isEmpty ? .empty : .content
        if let feedback = structureUndoFeedback {
            let currentPositions = nextSnapshot.flattened
                .map { node in
                    ChapterStructurePosition(
                        chapterID: node.id,
                        parentID: node.item.parentID,
                        order: node.item.order
                    )
                }
                .sorted { $0.chapterID < $1.chapterID }
            if currentPositions != feedback.snapshot.expectedCurrentPositions {
                structureUndoFeedback = nil
            }
        }
        if let pendingImportedFocusID, validIDs.contains(pendingImportedFocusID) {
            expandedIDs.formUnion(nextSnapshot.ancestorIDs(of: pendingImportedFocusID))
            pendingScrollTargetID = pendingImportedFocusID
            self.pendingImportedFocusID = nil
        }

        guard !hasAppliedInitialFocus else { return }
        hasAppliedInitialFocus = true
        guard let focusChapterID, validIDs.contains(focusChapterID) else { return }
        expandedIDs.formUnion(nextSnapshot.ancestorIDs(of: focusChapterID))
        pendingScrollTargetID = focusChapterID
    }

    /// 构建新增请求并清空上一次输入。
    func presentCreate(parentID: Int64) {
        titleEditorText = ""
        titleEditorRequest = ChapterTitleEditorRequest(
            mode: .create(parentID: parentID),
            title: parentID == 0 ? "新增一级章节" : "新增子章节"
        )
    }

    /// 串行执行写操作；Task 继承 MainActor，Repository 负责数据库线程切换与事务，取消后不回写 UI。
    func performWrite(
        title: String,
        operation: @escaping () async throws -> (@MainActor () -> Void)?
    ) {
        guard !isWriting else { return }
        writeErrorMessage = nil
        activeWriteTitle = title
        isWriting = true
        writeTask = Task { [weak self] in
            defer {
                self?.isWriting = false
                self?.writeTask = nil
            }
            do {
                let completion = try await operation()
                guard !Task.isCancelled else { return }
                completion?()
            } catch is CancellationError {
                return
            } catch {
                self?.writeErrorMessage = error.localizedDescription
            }
        }
    }
}
