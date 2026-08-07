/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 的书摘/章节观察流与批量写入接口，依赖 ExternalAppIntegrationRepositoryProtocol 承接所选书摘顺序外发，依赖 NoteCollectionModels/NoteBatchModels 描述查询和编辑状态
 * [OUTPUT]: 对外提供 NoteExcerptListOrigin、NoteExcerptListPhase、快照变更语义、NoteExternalBatchSendSummary 与 NoteExcerptListViewModel，统一驱动书摘和章节二级列表
 * [POS]: ViewModels/Note 的二级书摘列表状态源，集中维护局部搜索、稳定排序、渐进分页、语义动效、选择与批量事务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 二级书摘列表的真实数据范围；两种来源共享展示和批量操作，但保持各自 Repository 查询。
enum NoteExcerptListOrigin: Hashable, Sendable {
    case scope(NoteExcerptScope)
    case chapter(bookID: Int64, chapterID: Int64, includeDescendants: Bool)

    var navigationTitle: String {
        switch self {
        case .scope(let scope):
            switch scope {
            case .all: "所有书摘"
            case .untagged: "不含标签"
            case .withIdea: "包含想法"
            case .withImages: "包含图片"
            case .tag: "标签书摘"
            case .book: "本书书摘"
            }
        case .chapter:
            "章节书摘"
        }
    }
}

/// 二级列表首屏阶段；增量翻页沿用已有内容，不用全屏加载态打断阅读。
enum NoteExcerptListPhase: Equatable {
    case loading
    case content
    case empty
    case failure(String)
}

/// 已提交快照相对上一帧的业务变化，用于把列表动画限制在真实数据交接时刻。
enum NoteExcerptListChangeKind: Hashable {
    case initial
    case search
    case removal
    case update
    case reorder
    case insertion
    case pagination
    case refresh
}

/// 快照交接描述；revision 只在可见结果确实改变时递增，查询词与当前结果始终成对发布。
struct NoteExcerptListSnapshotChange: Hashable {
    let revision: Int
    let kind: NoteExcerptListChangeKind
    let appliedSearchText: String
}

/// 批量外发结果摘要；单条失败不阻断后续书摘，最终由页面明确反馈成功与失败数量。
nonisolated struct NoteExternalBatchSendSummary: Equatable, Sendable {
    let destination: ExternalAppDestination
    let sentCount: Int
    let failedCount: Int

    var totalCount: Int { sentCount + failedCount }
}

private enum NoteExcerptListPolicy {
    static let pageSize = 30
    static let searchDelay: Duration = .milliseconds(200)
}

private enum NoteExcerptListRestartReason {
    case initial
    case search
    case reorder
    case pagination
    case refresh

    var changeKind: NoteExcerptListChangeKind {
        switch self {
        case .initial: .initial
        case .search: .search
        case .reorder: .reorder
        case .pagination: .pagination
        case .refresh: .refresh
        }
    }
}

@MainActor
@Observable
/// 书摘/章节列表共享状态机，所有数据库读取和写入均经 NoteRepository 完成。
final class NoteExcerptListViewModel {
    let origin: NoteExcerptListOrigin
    var searchText = "" {
        didSet {
            guard normalized(oldValue) != normalized(searchText) else { return }
            scheduleQueryRestart()
        }
    }
    var sort: NoteExcerptSortRule = .createdDescending {
        didSet {
            guard oldValue != sort else { return }
            restartObservation(resetsPagination: true, reason: .reorder)
        }
    }
    var isEditing = false
    var selectedNoteIDs: Set<Int64> = []

    private(set) var items: [NoteExcerptListItem] = []
    private(set) var totalCount = 0
    private(set) var phase: NoteExcerptListPhase = .loading
    private(set) var isLoadingMore = false
    private(set) var isWriting = false
    private(set) var isChapterStarred = true
    private(set) var batchBootstrap: NoteBatchEditBootstrap?
    private(set) var isLoadingBatchBootstrap = false
    private(set) var isSelectingAll = false
    private(set) var configuredExternalDestinations: [ExternalAppDestination]
    private(set) var snapshotChange = NoteExcerptListSnapshotChange(
        revision: 0,
        kind: .initial,
        appliedSearchText: ""
    )

    private let repository: any NoteRepositoryProtocol
    private let externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol
    private var randomSeed: Int64
    private var requestedLimit = NoteExcerptListPolicy.pageSize
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var externalConfigurationTask: Task<Void, Never>?
    private var hasReceivedSnapshot = false

    /// 注入列表来源与仓储；随机 seed 仅创建一次，保证随机排序在本次浏览会话中稳定。
    init(
        origin: NoteExcerptListOrigin,
        repository: any NoteRepositoryProtocol,
        externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol
    ) {
        self.origin = origin
        self.repository = repository
        self.externalAppIntegrationRepository = externalAppIntegrationRepository
        self.configuredExternalDestinations = externalAppIntegrationRepository.configuredDestinations()
        self.randomSeed = Int64.random(in: 1...Int64.max)
        startObservation(reason: .initial)
        observeExternalConfiguration()
    }

    var normalizedSearchText: String { normalized(searchText) }
    var appliedSearchText: String { snapshotChange.appliedSearchText }
    var hasMore: Bool { items.count < totalCount }
    var selectedItems: [NoteExcerptListItem] { items.filter { selectedNoteIDs.contains($0.id) } }
    var selectedCount: Int { selectedNoteIDs.count }
    var isAllSelected: Bool { !items.isEmpty && selectedNoteIDs.count == items.count }
    var canMerge: Bool {
        selectedItems.count >= 2 && Set(selectedItems.map(\.bookID)).count == 1
    }
    var canMoveToChapter: Bool {
        !selectedItems.isEmpty && Set(selectedItems.map(\.bookID)).count == 1
    }

    /// 当前搜索、排序和随机 seed 对应的统一 Viewer 来源，确保列表和详情分页结果一致。
    var viewerSource: ContentViewerSourceContext {
        switch origin {
        case .scope(let scope):
            .noteExcerpts(
                scope: scope,
                query: appliedSearchText,
                sort: sort,
                randomSeed: randomSeed
            )
        case .chapter(let bookID, let chapterID, let includeDescendants):
            .chapterNotes(
                bookID: bookID,
                chapterID: chapterID,
                includeDescendants: includeDescendants,
                query: appliedSearchText,
                sort: sort,
                randomSeed: randomSeed
            )
        }
    }

    /// 切换编辑态时用短促结构动画承接底部工具栏显隐；退出会清空选择，避免下次误操作。
    func setEditing(_ isEditing: Bool) {
        self.isEditing = isEditing
        if !isEditing { selectedNoteIDs.removeAll() }
    }

    /// 切换单项选中状态；只接受当前快照仍存在的 ID。
    func toggleSelection(noteID: Int64) {
        guard items.contains(where: { $0.id == noteID }) else { return }
        isSelectingAll = false
        if selectedNoteIDs.contains(noteID) {
            selectedNoteIDs.remove(noteID)
        } else {
            selectedNoteIDs.insert(noteID)
        }
    }

    /// 全选会先把观察窗口扩大到当前总数，等待完整快照后再选中全部 ID；再次点击可取消挂起选择。
    func toggleSelectAll() {
        if isAllSelected || isSelectingAll {
            isSelectingAll = false
            selectedNoteIDs.removeAll()
        } else {
            guard hasMore else {
                selectedNoteIDs = Set(items.map(\.id))
                return
            }
            isSelectingAll = true
            isLoadingMore = true
            requestedLimit = max(totalCount, NoteExcerptListPolicy.pageSize)
            restartObservation(resetsPagination: false, reason: .pagination)
        }
    }

    /// 最后一行出现时扩大同一查询的 limit；观察任务取消可阻止旧页晚到覆盖新查询。
    func loadMoreIfNeeded(currentItemID: Int64) {
        guard hasMore, !isLoadingMore, items.last?.id == currentItemID else { return }
        isLoadingMore = true
        requestedLimit += NoteExcerptListPolicy.pageSize
        restartObservation(resetsPagination: false, reason: .pagination)
    }

    /// 失败后按当前查询重建观察流，已有内容保留，首屏失败才继续显示错误页。
    func retry() {
        restartObservation(resetsPagination: items.isEmpty, reason: .refresh)
    }

    /// 用户在随机模式下显式请求换一组顺序时更新 seed，并重置分页；同一次浏览期间未触发此动作时顺序仍保持稳定。
    func reshuffleRandomOrder() {
        guard sort == .random else { return }
        randomSeed = Int64.random(in: 1...Int64.max)
        restartObservation(resetsPagination: true, reason: .reorder)
    }

    /// 读取批量面板所需书籍和标签；任务取消后不回写页面状态。
    func prepareBatchEditing() async throws -> NoteBatchEditBootstrap {
        guard !selectedNoteIDs.isEmpty else { throw NoteBatchMutationError.emptySelection }
        isLoadingBatchBootstrap = true
        defer { isLoadingBatchBootstrap = false }
        let bootstrap = try await repository.fetchNoteBatchEditBootstrap(
            noteIDs: selectedNoteIDs.sorted()
        )
        try Task.checkCancellation()
        selectedNoteIDs.subtract(bootstrap.unavailableNoteIDs)
        batchBootstrap = bootstrap
        return bootstrap
    }

    /// 物理删除指定书摘；写入期间入口禁用，成功后由观察流刷新并收缩选择。
    func deleteNotes(_ noteIDs: [Int64]) async throws {
        guard !noteIDs.isEmpty else { throw NoteBatchMutationError.emptySelection }
        try await performWrite {
            try await repository.deleteNotes(noteIDs: noteIDs)
        }
        selectedNoteIDs.subtract(noteIDs)
        if selectedNoteIDs.isEmpty { setEditing(false) }
    }

    /// 将选择移动到目标书籍；章节路径复制/复用规则由 Repository 事务负责。
    func moveSelectedNotes(toBookID bookID: Int64) async throws {
        let ids = try selectedIDsOrThrow()
        try await performWrite {
            try await repository.moveNotes(noteIDs: ids, toBookID: bookID)
        }
        setEditing(false)
    }

    /// 将同一本书内选择移动到目标章节，跨书选择会在进入面板前被阻断。
    func moveSelectedNotes(toChapterID chapterID: Int64) async throws {
        let ids = try selectedIDsOrThrow()
        try await performWrite {
            try await repository.moveNotes(noteIDs: ids, toChapterID: chapterID)
        }
        setEditing(false)
    }

    /// 读取当前选择所属书籍的章节；跨书选择没有合法目标，直接抛出领域错误。
    func fetchChapterOptionsForSelection() async throws -> [NoteEditorChapterOption] {
        guard canMoveToChapter, let bookID = selectedItems.first?.bookID else {
            throw NoteBatchMutationError.notesFromDifferentBooks
        }
        return try await repository.fetchNoteEditorChapters(bookId: bookID)
    }

    /// 在当前选择所属书籍中新建根章节，成功返回可立即作为移动目标的真实章节记录。
    func createChapterForSelection(
        named title: String,
        parentID: Int64 = 0
    ) async throws -> NoteEditorChapterOption {
        guard canMoveToChapter, let bookID = selectedItems.first?.bookID else {
            throw NoteBatchMutationError.notesFromDifferentBooks
        }
        guard !isWriting else { throw NoteBatchMutationError.invalidChapterDepth }
        isWriting = true
        defer { isWriting = false }
        let option = try await repository.createChapter(
            bookID: bookID,
            parentID: parentID,
            title: title
        )
        try Task.checkCancellation()
        return option
    }

    /// 在批量标签 Sheet 现场创建书摘标签，并返回数据库确认后的选项供当前面板选中。
    func createTag(named title: String) async throws -> NoteEditorTagOption {
        guard !isWriting else { throw NoteBatchMutationError.invalidMergeDraft }
        isWriting = true
        defer { isWriting = false }
        let option = try await repository.createNoteTag(named: title)
        try Task.checkCancellation()
        return option
    }

    /// 物理替换所选书摘的标签关系；空集合表示清空标签。
    func replaceTagsForSelectedNotes(tagIDs: [Int64]) async throws {
        let ids = try selectedIDsOrThrow()
        try await performWrite {
            try await repository.replaceTagsForNotes(noteIDs: ids, tagIDs: tagIDs)
        }
        setEditing(false)
    }

    /// 取消章节星标，不删除章节或书摘；仅章节来源可执行。
    func removeChapterStar() async throws {
        guard case .chapter(_, let chapterID, _) = origin else { return }
        try await performWrite {
            try await repository.setChapterStarred(chapterID: chapterID, isStarred: false)
        }
        isChapterStarred = false
    }

    /// 逐条发送当前选择；单条失败继续下一条，取消会立即终止，目标间隔对齐 Android 的限流节奏。
    func sendSelectedNotes(
        to destination: ExternalAppDestination
    ) async throws -> NoteExternalBatchSendSummary {
        let noteIDs = try selectedIDsOrThrow()
        guard configuredExternalDestinations.contains(destination) else {
            throw ExternalAppIntegrationError.missingConfiguration(destination)
        }
        guard !isWriting else {
            return NoteExternalBatchSendSummary(
                destination: destination,
                sentCount: 0,
                failedCount: noteIDs.count
            )
        }

        isWriting = true
        defer { isWriting = false }
        var sentCount = 0
        var failedCount = 0
        for (index, noteID) in noteIDs.enumerated() {
            try Task.checkCancellation()
            do {
                _ = try await externalAppIntegrationRepository.send(
                    noteID: noteID,
                    to: destination
                )
                sentCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedCount += 1
            }

            guard index < noteIDs.index(before: noteIDs.endIndex) else { continue }
            try await Task.sleep(for: destination == .writeathon ? .seconds(1) : .milliseconds(300))
        }
        return NoteExternalBatchSendSummary(
            destination: destination,
            sentCount: sentCount,
            failedCount: failedCount
        )
    }

    /// 释放观察与防抖任务，防止页面销毁后异步流继续回写。
    isolated deinit {
        observationTask?.cancel()
        searchTask?.cancel()
        externalConfigurationTask?.cancel()
    }

    // MARK: - Observation

    /// 建立当前范围的数据库观察流；取消旧任务后，晚到快照无法覆盖新搜索或排序。
    private func startObservation(reason: NoteExcerptListRestartReason) {
        if !hasReceivedSnapshot {
            phase = .loading
        } else if case .failure = phase {
            phase = .loading
        }
        let limit = requestedLimit
        let query = normalizedSearchText
        let selectedSort = sort
        let seed = randomSeed
        let stream: AsyncThrowingStream<NoteExcerptListSnapshot, Error>
        switch origin {
        case .scope(let scope):
            stream = repository.observeNoteExcerptList(
                request: NoteExcerptPageRequest(
                    scope: scope,
                    query: query,
                    sort: selectedSort,
                    randomSeed: seed,
                    offset: 0,
                    limit: limit
                )
            )
        case .chapter(let bookID, let chapterID, let includeDescendants):
            stream = repository.observeChapterNoteList(
                request: ChapterNotePageRequest(
                    bookID: bookID,
                    chapterID: chapterID,
                    includesDescendants: includeDescendants,
                    query: query,
                    sort: selectedSort,
                    randomSeed: seed,
                    offset: 0,
                    limit: limit
                )
            )
        }

        observationTask = Task { [weak self] in
            var isFirstSnapshot = true
            do {
                for try await snapshot in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.apply(
                        snapshot,
                        query: query,
                        preferredKind: isFirstSnapshot ? reason.changeKind : nil
                    )
                    isFirstSnapshot = false
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoadingMore = false
                self.phase = self.items.isEmpty ? .failure(error.localizedDescription) : .content
            }
        }
    }

    /// 关联应用设置变更后刷新批量发送菜单，任务取消时不再回写页面。
    private func observeExternalConfiguration() {
        let changes = externalAppIntegrationRepository.observeConfigurationChanges()
        externalConfigurationTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { return }
                self.configuredExternalDestinations = self.externalAppIntegrationRepository
                    .configuredDestinations()
            }
        }
    }

    private func scheduleQueryRestart() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: NoteExcerptListPolicy.searchDelay)
                try Task.checkCancellation()
                self?.restartObservation(resetsPagination: true, reason: .search)
            } catch {
                return
            }
        }
    }

    private func restartObservation(
        resetsPagination: Bool,
        reason: NoteExcerptListRestartReason
    ) {
        observationTask?.cancel()
        if resetsPagination {
            requestedLimit = NoteExcerptListPolicy.pageSize
            isLoadingMore = false
            isSelectingAll = false
        }
        startObservation(reason: reason)
    }

    /// 在 MainActor 上原子提交快照与对应查询词；重复数据库通知只收口加载态，不制造动画 revision。
    private func apply(
        _ snapshot: NoteExcerptListSnapshot,
        query: String,
        preferredKind: NoteExcerptListChangeKind?
    ) {
        let nextPhase: NoteExcerptListPhase = snapshot.items.isEmpty ? .empty : .content
        let hasVisibleChange = !hasReceivedSnapshot
            || items != snapshot.items
            || totalCount != snapshot.totalCount
            || appliedSearchText != query
            || phase != nextPhase
        let previousItems = items

        items = snapshot.items
        totalCount = snapshot.totalCount
        if isSelectingAll {
            selectedNoteIDs = Set(snapshot.items.map(\.id))
            if snapshot.items.count >= snapshot.totalCount {
                isSelectingAll = false
            }
        } else {
            selectedNoteIDs.formIntersection(snapshot.items.map(\.id))
        }
        isLoadingMore = false
        phase = nextPhase

        guard hasVisibleChange else { return }
        let kind: NoteExcerptListChangeKind
        if !hasReceivedSnapshot {
            kind = .initial
        } else if let preferredKind {
            kind = preferredKind
        } else {
            kind = classifyChange(from: previousItems, to: snapshot.items)
        }
        hasReceivedSnapshot = true
        snapshotChange = NoteExcerptListSnapshotChange(
            revision: snapshotChange.revision + 1,
            kind: kind,
            appliedSearchText: query
        )
    }

    /// 同一观察流的后续通知按稳定 ID、顺序和内容差异分类，避免把删除或更新误画成整页刷新。
    private func classifyChange(
        from previousItems: [NoteExcerptListItem],
        to nextItems: [NoteExcerptListItem]
    ) -> NoteExcerptListChangeKind {
        let previousIDs = previousItems.map(\.id)
        let nextIDs = nextItems.map(\.id)
        let previousIDSet = Set(previousIDs)
        let nextIDSet = Set(nextIDs)
        let removedIDs = previousIDSet.subtracting(nextIDSet)
        let insertedIDs = nextIDSet.subtracting(previousIDSet)

        if !removedIDs.isEmpty, insertedIDs.isEmpty { return .removal }
        if removedIDs.isEmpty, !insertedIDs.isEmpty { return .insertion }
        if !removedIDs.isEmpty, !insertedIDs.isEmpty { return .refresh }
        if previousIDs != nextIDs { return .reorder }
        if previousItems != nextItems { return .update }
        return .refresh
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectedIDsOrThrow() throws -> [Int64] {
        let ids = selectedNoteIDs.sorted()
        guard !ids.isEmpty else { throw NoteBatchMutationError.emptySelection }
        return ids
    }

    /// 写操作在 MainActor 上即时切换禁用态；取消和错误向上抛出，由页面用系统反馈表达。
    private func performWrite(_ operation: () async throws -> Void) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        try await operation()
        try Task.checkCancellation()
    }
}
