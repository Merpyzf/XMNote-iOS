/**
 * [INPUT]: 依赖 NoteReviewLaunchPayload 与 NoteRepositoryProtocol，接收 UIKit 有序可见/预取范围、内存告警、本地设置写入和外部设置对账意图
 * [OUTPUT]: 对外提供 NoteReviewUIKitSession（身份索引、有背压布局源、统一双并发读取、需求保护、有界缓存、锁定对象读取、卡宽设置与业务操作）
 * [POS]: Views/Note/Components 的全屏回顾页面私有会话层，只长期持有轻量 ID 并把所有数据访问收口到 Repository
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit

/// 全屏回顾页面私有会话；`@MainActor` 串行维护身份索引与缓存，可取消的异步仓储请求不阻塞集合视图交互。
@MainActor
final class NoteReviewUIKitSession {
    private enum Constants {
        static let batchSize = 20
        static let overviewLayoutBatchSize = 128
        static let maximumConcurrentLoads = 2
        static let cacheCostLimit = 16 * 1024 * 1024
        static let cacheCountLimit = 240
    }

    private final class ItemBox: NSObject {
        let item: NoteReviewCardItem
        let contentGeneration: UInt64

        init(_ item: NoteReviewCardItem, contentGeneration: UInt64) {
            self.item = item
            self.contentGeneration = contentGeneration
        }
    }

    /// 对象菜单共享同一目标的读取；每个调用者只持有自己的取消资格。
    private struct ActionItemLoad {
        let token: UUID
        let generation: Int
        let contentGeneration: UInt64
        let task: Task<NoteReviewCardItem, Error>
        var consumers: Set<UUID>
    }

    private struct PendingLoad {
        let ids: [Int64]
        var priority: TaskPriority
        let task: Task<Void, Never>
    }

    private struct QueuedLoad {
        let token: UUID
        let ids: [Int64]
        var priority: TaskPriority
        let sequence: UInt64
    }

    private let repository: any NoteRepositoryProtocol
    private let readScheduler = NoteReviewCanvasReadScheduler()
    let usesDirectory: Bool
    private lazy var directoryCursor = NoteReviewCanvasDirectoryCursor { [repository, readScheduler] request, cacheID in
        try await repository.openNoteReviewDirectory(request: request, cacheID: cacheID,
            schedule: { operation in
                try await readScheduler.perform(priority: .utility, operation: operation)
            }, progress: { _ in })
    }
    private var directoryTotalCount: Int?
    private var directoryFirstOrdinal = 0
    private var regionalOrdinals: [Int64: Int] = [:]
    private var waterfallOrdinals: [Int64: Int] = [:]
    private var directoryPageTask: Task<Void, Never>?
    private var directoryPageGeneration: UInt64 = 0
    private var pendingDirectoryPage: NoteReviewDirectoryPage?
    private var requestedDirectoryPageID: Int64?
    private(set) var directoryVersion: UInt64 = 0
    var isReadingInteractionActive = false
    var canApplyReadingWindow: (() -> Bool)?
    private var isDisposed = false
    private let launchPayload: NoteReviewLaunchPayload
    private let cache = NSCache<NSNumber, ItemBox>()
    private var pinnedItems: [Int64: NoteReviewCardItem] = [:]
    private var currentIDs: Set<Int64> = []
    private var visibleIDs: Set<Int64> = []
    private var visibleIDOrder: [Int64] = []
    private var systemPrefetchIDs: Set<Int64> = []
    private var predictedIDs: Set<Int64> = []
    private var transitionIDs: Set<Int64> = []
    private var pendingLoads: [UUID: PendingLoad] = [:]
    private var actionItemLoads: [Int64: ActionItemLoad] = [:]
    private var queuedLoads: [QueuedLoad] = []
    private var recentSystemPrefetchIDs: [Int64] = []
    private var nextLoadSequence: UInt64 = 0
    private var manifestTask: Task<Void, Never>?
    private var overviewLayoutManifestTask: Task<Void, Never>?
    private var settingObservationTask: Task<Void, Never>?
    private var dataObservationTask: Task<Void, Never>?
    private var deletionTasks: [Int64: Task<Void, Error>] = [:]
    private var deletionInvalidationIDs: Set<Int64> = []
    private(set) var deletingNoteIDs: Set<Int64> = []
    private var generation = 0
    private var contentGeneration: UInt64 = 0
    private var overviewLayoutManifestGeneration = 0
    private var sessionSeed: UInt64 = 0
    private var shouldPreserveLaunchPrefix = true
    private var lastFetchedIDs: [Int64] = []
    private var noteIndexByID: [Int64: Int]
    private var overviewLayoutSourcesByID: [Int64: NoteReviewOverviewLayoutSource] = [:]
    private var receivedOverviewLayoutSourceIDs: Set<Int64> = []

    private(set) var orderedIDs: [Int64] {
        didSet {
            noteIndexByID = Self.makeIndexMap(for: orderedIDs)
        }
    }
    private(set) var settings: NoteReviewSettings
    private(set) var currentNoteID: Int64
    private(set) var isOverviewLayoutManifestComplete = false

    var onManifestChanged: (() -> Void)?
    var onOverviewInvalidated: (() -> Void)?
    var onOverviewLayoutSourcesChanged: ((Set<Int64>, Bool) -> Void)?
    /// 新内核逐批消费并释放源后才读取下一批；缺失 ID 单独交付，不等待不存在的内容。
    var onOverviewLayoutBatch: (([NoteReviewOverviewLayoutSource], Set<Int64>, Bool) async throws -> Void)?
    var automaticallyPreparesOverview = true
    var onItemsChanged: ((Set<Int64>) -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onError: ((String) -> Void)?

    /// 注入仓储与卡堆启动负载；首条完整内容同步写入有界缓存，避免出现加载中转页。
    init(payload: NoteReviewLaunchPayload, repository: any NoteRepositoryProtocol, usesDirectory: Bool = false) {
        self.repository = repository
        self.usesDirectory = usesDirectory
        self.launchPayload = payload
        self.settings = payload.settings
        self.currentNoteID = payload.selectedNoteID
        let orderedIDs = Self.orderedUniqueIDs(payload.loadedNoteIDs)
        self.orderedIDs = orderedIDs
        self.noteIndexByID = Self.makeIndexMap(for: orderedIDs)
        self.sessionSeed = payload.sessionID.stableUInt64Seed
        cache.totalCostLimit = Constants.cacheCostLimit
        cache.countLimit = Constants.cacheCountLimit
        for item in payload.seedItems {
            store(item)
        }
        if noteIndexByID[payload.selectedNoteID] != nil {
            currentIDs = [payload.selectedNoteID]
        }
        refreshPinnedItems()
        observeChanges()
    }

    deinit {
        manifestTask?.cancel()
        directoryPageTask?.cancel()
        overviewLayoutManifestTask?.cancel()
        settingObservationTask?.cancel()
        dataObservationTask?.cancel()
        deletionTasks.values.forEach { $0.cancel() }
        actionItemLoads.values.forEach { $0.task.cancel() }
        pendingLoads.values.forEach { $0.task.cancel() }
        queuedLoads.removeAll(keepingCapacity: false)
    }

    var currentIndex: Int {
        index(of: currentNoteID) ?? 0
    }

    var count: Int { directoryTotalCount ?? orderedIDs.count }
    var loadedCount: Int { orderedIDs.count }
    var localCurrentIndex: Int { noteIndexByID[currentNoteID] ?? 0 }
    var isCurrentReadingWindowReady: Bool { noteIndexByID[currentNoteID] != nil }
    var detailSource: ContentViewerSourceContext {
        usesDirectory ? .noteReviewDirectory(.init(id: launchPayload.sessionID, provider: directoryCursor))
            : .noteReview(noteIDs: orderedIDs)
    }

    /// 主 actor 去重同一目标的删除；仓储事务提交后只由数据观察更新清单，离场后不再交付页面结果。
    func deleteNote(noteID: Int64) async throws {
        guard !isDisposed else { throw CancellationError() }
        if let pending = deletionTasks[noteID] {
            try await pending.value
            guard !isDisposed else { throw CancellationError() }
            return
        }
        guard index(of: noteID) != nil else { throw NoteBatchMutationError.noteNotFound }
        let repository = repository
        let task = Task { try await repository.deleteNotes(noteIDs: [noteID]) }
        deletionTasks[noteID] = task
        deletingNoteIDs.insert(noteID)
        deletionInvalidationIDs.insert(noteID)
        defer {
            deletionTasks[noteID] = nil
            deletingNoteIDs.remove(noteID)
        }
        do {
            try await task.value
            guard !isDisposed else { throw CancellationError() }
        } catch {
            deletionInvalidationIDs.remove(noteID)
            throw error
        }
    }

    /// 首次读取完整身份清单；进入时已有 ID 与完整内容可先直接绘制，不等待清单查询。
    func start() {
        guard !isDisposed else { return }
        restartOverviewLayoutManifest()
        reloadManifest(
            preserving: currentNoteID,
            emitsLoadingState: false,
            preservesExistingRandomOrder: false
        )
    }

    /// 按索引返回稳定身份，越界时不制造替代对象。
    func noteID(at index: Int) -> Int64? {
        guard orderedIDs.indices.contains(index) else { return nil }
        return orderedIDs[index]
    }

    /// 以常数时间返回书摘在当前会话中的稳定索引。
    func index(of noteID: Int64) -> Int? {
        if let local = noteIndexByID[noteID] { return directoryFirstOrdinal + local }
        return regionalOrdinals[noteID] ?? waterfallOrdinals[noteID]
    }

    /// 总览仅取得当前叶子的身份；目录打开共用 Session 任务，取消后不交付陈旧区域。
    func readDirectoryRegion(noteID: Int64) async throws -> NoteReviewCanvasDirectoryRegion {
        guard usesDirectory, !isDisposed else { throw CancellationError() }
        try await directoryCursor.configure(directoryRequest())
        guard let stack = try await directoryCursor.stack(.containing(noteID, capacity: settings.desktopGroupCapacity)) else {
            throw NoteBatchMutationError.noteNotFound
        }
        let region = stack.region
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        directoryTotalCount = Int(region.totalCount)
        // Only the resident regional window is retained, never the complete directory.
        for (index, member) in region.members.enumerated() {
            regionalOrdinals[member.record.noteID] = Int(region.group.firstOrdinal) + index
        }
        return region
    }

    /// 卡片堆浏览只传递小窗口身份，预览不改变回顾进度；异步返回必须仍属于存活页面。
    func readDesktopStack(_ request: NoteReviewCanvasStackRequest) async throws -> NoteReviewCanvasStackGroup? {
        guard usesDirectory, !isDisposed else { throw CancellationError() }
        try await directoryCursor.configure(directoryRequest())
        let group = try await directoryCursor.stack(request)
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        return group
    }

    /// 局部视口归还时释放屏外身份映射；完整阅读窗口拥有自己的独立身份表。
    func retainDirectoryRegionIDs(_ ids: Set<Int64>) {
        regionalOrdinals = regionalOrdinals.filter { ids.contains($0.key) || $0.key == currentNoteID }
    }

    /// 区域窗口仅按叶子身份读取邻区；主 actor 维护有界全局序号，取消不回流旧区域。
    func readDirectoryRegion(groupID: NoteReviewDirectoryGroupID) async throws -> NoteReviewCanvasDirectoryRegion? {
        guard usesDirectory, !isDisposed else { throw CancellationError() }
        let region = try await directoryCursor.region(groupID)
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        if let region {
            for (index, member) in region.members.enumerated() {
                regionalOrdinals[member.record.noteID] = Int(region.group.firstOrdinal) + index
            }
        }
        return region
    }

    /// 全景只取得集合统计，绝不把全景请求转换为正文预取。
    func readDirectoryCatalog(scope: NoteReviewDirectoryGroupID?, maximumGroups: Int) async throws -> NoteReviewCanvasDirectoryCatalog {
        guard usesDirectory, !isDisposed else { throw CancellationError() }
        return try await directoryCursor.catalog(in: scope, currentID: currentNoteID, maximumGroups: maximumGroups)
    }

    /// 瀑布流独立持有最多 128 项身份，不会挤掉桌面当前九区的动作目标。
    func readDirectoryWaterfallPage(around id: Int64) async throws -> NoteReviewDirectoryPage? {
        guard usesDirectory, !isDisposed else { throw CancellationError() }
        let page = try await directoryCursor.page(around: .noteID(id))
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        if let page {
            waterfallOrdinals = Dictionary(uniqueKeysWithValues: page.members.enumerated().map {
                ($0.element.record.noteID, Int(page.firstOrdinal) + $0.offset)
            })
        }
        return page
    }

    /// 临近窗口边缘时异步准备相邻身份；手势结束后才原子替换集合数据，避免半途改变页码。
    func prepareReadingWindow(around noteID: Int64) {
        guard usesDirectory, !isDisposed else { return }
        if let index = noteIndexByID[noteID] {
            let hasLeadingRoom = index >= 24 || directoryFirstOrdinal == 0
            let hasTrailingRoom = index < orderedIDs.count - 24 || directoryFirstOrdinal + loadedCount >= count
            if hasLeadingRoom && hasTrailingRoom { return }
        }
        guard requestedDirectoryPageID != noteID else { return }
        requestedDirectoryPageID = noteID
        directoryPageTask?.cancel()
        directoryPageGeneration &+= 1
        let token = directoryPageGeneration
        directoryPageTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == directoryPageGeneration { requestedDirectoryPageID = nil } }
            do {
                try await directoryCursor.configure(directoryRequest())
                let page = try await directoryCursor.page(around: .noteID(noteID))
                try Task.checkCancellation()
                guard !isDisposed, token == directoryPageGeneration else { return }
                pendingDirectoryPage = page
                applyPendingReadingWindow()
            } catch is CancellationError { return }
            catch { if !isDisposed { onError?("暂时无法准备下一段回顾") } }
        }
    }

    /// 宿主在原生滚动落稳后调用；保留当前身份和它的屏幕位置，不用局部序号代替实际进度。
    func applyPendingReadingWindow() {
        guard !isReadingInteractionActive, canApplyReadingWindow?() != false, let page = pendingDirectoryPage,
              page.members.contains(where: { $0.record.noteID == currentNoteID }) else { return }
        pendingDirectoryPage = nil
        applyDirectoryPage(page)
    }

    /// 按身份返回纸流测高所需的轻量内容源；清单未完成时允许已到达批次先行使用。
    func overviewLayoutSource(for noteID: Int64) -> NoteReviewOverviewLayoutSource? {
        overviewLayoutSourcesByID[noteID]
    }

    /// 按当前清单顺序原子取出并移除轻量布局源；控制器应在变更回调内同步消费，以便及时释放原始 HTML。
    func consumeOverviewLayoutSources(
        for noteIDs: Set<Int64>
    ) -> [NoteReviewOverviewLayoutSource] {
        noteIDs.sorted { (noteIndexByID[$0] ?? .max) < (noteIndexByID[$1] ?? .max) }.compactMap { noteID in
            return overviewLayoutSourcesByID.removeValue(forKey: noteID)
        }
    }

    /// 为低清总览二次读取或邻域高清准备提供有界源；取消与并发许可由唯一会话管理。
    func readOverviewSources(noteIDs: [Int64], priority: TaskPriority = .utility) async throws -> [NoteReviewOverviewLayoutSource] {
        guard !isDisposed else { throw CancellationError() }
        let ids = Self.orderedUniqueIDs(noteIDs, limit: Constants.overviewLayoutBatchSize)
        guard !ids.isEmpty else { return [] }
        return try await readScheduler.perform(priority: priority) { [repository] in
            try await repository.fetchNoteReviewOverviewLayoutSources(noteIDs: ids)
        }
    }

    /// 背景读取继续经既有 Repository；网络等待可取消，永久离场不交付结果。
    func readCanvasBackground(url: URL) async throws -> Data {
        guard !isDisposed else { throw CancellationError() }
        let data = try await repository.fetchNoteReviewBackgroundData(remoteURL: url)
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        return data
    }

    /// 仅在调宽确认并落稳后调用；设置回流相等时不再触发第二次重排。
    func updateDesktopCardWidth(_ width: Int) {
        guard !isDisposed else { return }
        let value = NoteReviewSettings.validatedDesktopCardWidth(width)
        guard value != settings.desktopCardWidth else { return }
        settings.desktopCardWidth = value
        persistSettings()
    }

    /// 设置广播作为唯一布局失效入口，不改变目录或种子。
    func updateDesktopGroupCapacity(_ capacity: Int) {
        guard !isDisposed else { return }
        let value = NoteReviewSettings.validatedDesktopGroupCapacity(capacity)
        guard value != settings.desktopGroupCapacity else { return }
        settings.desktopGroupCapacity = value
        persistSettings()
    }

    /// 页面永久关闭时立即解除任务和观察；已执行的系统读取可以返回，但不得再次提交。
    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        generation &+= 1
        overviewLayoutManifestGeneration &+= 1
        manifestTask?.cancel()
        directoryPageTask?.cancel()
        if usesDirectory { directoryCursor.close() }
        overviewLayoutManifestTask?.cancel()
        settingObservationTask?.cancel()
        dataObservationTask?.cancel()
        deletionTasks.values.forEach { $0.cancel() }
        actionItemLoads.values.forEach { $0.task.cancel() }
        actionItemLoads.removeAll()
        pendingLoads.values.forEach { $0.task.cancel() }
        queuedLoads.removeAll()
        readScheduler.dispose()
        onManifestChanged = nil
        canApplyReadingWindow = nil
        onOverviewInvalidated = nil
        onOverviewLayoutSourcesChanged = nil
        onOverviewLayoutBatch = nil
        onItemsChanged = nil
        onSettingsChanged = nil
        onError = nil
    }

    /// 为字体、字号或概览显隐变化重新读取已消费的轻量源；不重建筛选 ID 或完整卡片缓存。
    func reloadOverviewLayoutManifest() {
        restartOverviewLayoutManifest()
    }

    /// 总览读取期间发现缺失身份时重新核对仓储清单，随机会话保留既有顺序。
    func refreshCanvasSnapshot() {
        reloadManifest(preserving: currentNoteID, emitsLoadingState: false, preservesExistingRandomOrder: true)
    }

    /// 从有界缓存读取完整书摘。
    func item(for noteID: Int64) -> NoteReviewCardItem? {
        pinnedItems[noteID] ?? cache.object(forKey: NSNumber(value: noteID))?.item
    }

    /// 对象操作始终读取点按时的身份；主 actor 合并同 ID 工作，取消或代次变化后不返回旧对象。
    func fetchActionItem(noteID: Int64) async throws -> NoteReviewCardItem {
        try validateActionTarget(noteID, generation: generation, contentGeneration: contentGeneration)
        if let item = cachedActionItem(for: noteID) { return item }
        let expectedGeneration = generation
        let expectedContentGeneration = contentGeneration
        let consumer = UUID()
        if let old = actionItemLoads[noteID],
           old.generation != expectedGeneration || old.contentGeneration != expectedContentGeneration {
            old.task.cancel()
            actionItemLoads[noteID] = nil
        }
        if actionItemLoads[noteID] == nil {
            let token = UUID()
            let pending = pendingLoads.values.first { $0.ids.contains(noteID) }
            promoteScheduledLoads(containing: [noteID], to: .userInitiated)
            // The object request supersedes only its own queued ID, not the rest of a prefetch batch.
            queuedLoads = queuedLoads.compactMap { load in
                let ids = load.ids.filter { $0 != noteID }
                return ids.isEmpty ? nil : QueuedLoad(token: load.token, ids: ids,
                    priority: load.priority, sequence: load.sequence)
            }
            let task = Task<NoteReviewCardItem, Error>(priority: .userInitiated) { [weak self] in
                guard let self else { throw CancellationError() }
                try validateActionTarget(noteID, generation: expectedGeneration, contentGeneration: expectedContentGeneration)
                if let pending {
                    await pending.task.value
                    try validateActionTarget(noteID, generation: expectedGeneration, contentGeneration: expectedContentGeneration)
                    if let item = cachedActionItem(for: noteID) { return item }
                    if pending.task.isCancelled { throw CancellationError() }
                    throw NoteBatchMutationError.noteNotFound
                }
                let items = try await readScheduler.perform(priority: .userInitiated) { [repository] in
                    try self.validateActionTarget(noteID, generation: expectedGeneration, contentGeneration: expectedContentGeneration)
                    return try await repository.fetchNoteReviewItems(noteIDs: [noteID])
                }
                try validateActionTarget(noteID, generation: expectedGeneration, contentGeneration: expectedContentGeneration)
                guard let item = items.first(where: { $0.id == noteID }) else { throw NoteBatchMutationError.noteNotFound }
                store(item)
                refreshPinnedItems()
                onItemsChanged?([noteID])
                return item
            }
            actionItemLoads[noteID] = ActionItemLoad(token: token, generation: expectedGeneration,
                contentGeneration: expectedContentGeneration, task: task, consumers: [])
        }
        guard var load = actionItemLoads[noteID] else { throw CancellationError() }
        load.consumers.insert(consumer)
        actionItemLoads[noteID] = load
        let token = load.token
        let task = load.task
        return try await withTaskCancellationHandler {
            defer { releaseActionConsumer(consumer, noteID: noteID, token: token) }
            let item = try await task.value
            try validateActionTarget(noteID, generation: expectedGeneration, contentGeneration: expectedContentGeneration)
            return item
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.releaseActionConsumer(consumer, noteID: noteID, token: token) }
        }
    }

    /// 旧代 pinned 内容可以继续遮蔽页面，但不能作为新一代对象操作的数据来源。
    private func cachedActionItem(for noteID: Int64) -> NoteReviewCardItem? {
        guard let box = cache.object(forKey: NSNumber(value: noteID)),
              box.contentGeneration == contentGeneration else { return nil }
        return box.item
    }

    /// 每个异步边界重新核对真实清单与内容版本，不以当前阅读项替代菜单锁定身份。
    private func validateActionTarget(_ noteID: Int64, generation expectedGeneration: Int,
                                      contentGeneration expectedContentGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard !isDisposed, generation == expectedGeneration, contentGeneration == expectedContentGeneration else {
            throw CancellationError()
        }
        guard index(of: noteID) != nil else { throw NoteBatchMutationError.noteNotFound }
    }

    /// 最后一个消费者离开才取消对象读取；仍被页面需要的既有批次继续由原需求位保护。
    private func releaseActionConsumer(_ consumer: UUID, noteID: Int64, token: UUID) {
        guard var load = actionItemLoads[noteID], load.token == token,
              load.consumers.remove(consumer) != nil else { return }
        if load.consumers.isEmpty {
            load.task.cancel()
            actionItemLoads[noteID] = nil
        } else { actionItemLoads[noteID] = load }
        refreshPinnedItems()
        cancelUnprotectedPendingLoads()
        drainLoadQueue()
    }

    /// 更新阅读锚点；当前项会被固定，直到下一次锚点变化。
    func setCurrentNoteID(_ noteID: Int64) {
        guard index(of: noteID) != nil else { return }
        currentNoteID = noteID
        currentIDs = [noteID]
        normalizeVisibleDemand()
        refreshPinnedItems()
        cancelUnprotectedPendingLoads()
        requestForegroundItems()
        prepareReadingWindow(around: noteID)
    }

    /// 固定最多二十个当前屏幕项目并按会话顺序补充内容，防止全景布局把全量 ID 长期驻留内存。
    func updateVisibleIDs(_ ids: Set<Int64>) {
        let ordered = ids.compactMap { id -> (index: Int, id: Int64)? in
            guard let index = index(of: id) else { return nil }
            return (index, id)
        }
        .sorted { $0.index < $1.index }
        .map { $0.id }
        updateVisibleIDs(ordered)
    }

    /// 按控制器提供的空间顺序去重并固定最多二十个可见项。
    func updateVisibleIDs(_ ids: [Int64]) {
        let normalizedOrder = normalizedVisibleIDOrder(ids)
        guard normalizedOrder != visibleIDOrder else { return }
        visibleIDOrder = normalizedOrder
        visibleIDs = Set(normalizedOrder)
        refreshPinnedItems()
        cancelUnprotectedPendingLoads()
        requestForegroundItems()
    }

    /// 预取调用严格按二十条切批；请求反向失效时可被取消。
    func prefetch(noteIDs: [Int64]) {
        let ids = Self.orderedUniqueIDs(
            noteIDs.filter { index(of: $0) != nil },
            limit: Constants.batchSize
        )
        for id in ids {
            recentSystemPrefetchIDs.removeAll(where: { $0 == id })
            recentSystemPrefetchIDs.append(id)
        }
        if recentSystemPrefetchIDs.count > Constants.batchSize {
            recentSystemPrefetchIDs.removeFirst(
                recentSystemPrefetchIDs.count - Constants.batchSize
            )
        }
        systemPrefetchIDs = Set(recentSystemPrefetchIDs)
        cancelUnprotectedPendingLoads()
        requestItems(for: ids, priority: .utility)
    }

    /// 取消 UIKit 已明确放弃的预取项；二维预测仍可独立保护同一 ID。
    func cancelPrefetch(noteIDs: [Int64]) {
        let cancelled = Set(noteIDs)
        recentSystemPrefetchIDs.removeAll(where: cancelled.contains)
        systemPrefetchIDs = Set(recentSystemPrefetchIDs)
        cancelUnprotectedPendingLoads()
        refreshPinnedItems()
        drainLoadQueue()
    }

    /// 用最新未来视口原子替换二维预测保护；系统预取拥有独立生命周期。
    func updateSpatialPrefetch(noteIDs: [Int64]) {
        let ids = Self.orderedUniqueIDs(
            noteIDs.filter { index(of: $0) != nil },
            limit: Constants.batchSize
        )
        predictedIDs = Set(ids)
        cancelUnprotectedPendingLoads()
        refreshPinnedItems()
        requestItems(for: ids, priority: .utility)
    }

    /// 清除上一移动方向的二维预测；不会误取消 UIKit 仍需要的预取项。
    func cancelSpatialPrefetch() {
        predictedIDs.removeAll(keepingCapacity: true)
        cancelUnprotectedPendingLoads()
        refreshPinnedItems()
        drainLoadQueue()
    }

    /// 保护模式转场锚点和目标首屏；与普通预取分离，手势清理不会误取消共享纸张所需内容。
    func updateTransitionProtection(noteIDs: [Int64]) {
        let ids = Self.orderedUniqueIDs(
            noteIDs.filter { index(of: $0) != nil },
            limit: Constants.batchSize
        )
        transitionIDs = Set(ids)
        refreshPinnedItems()
        cancelUnprotectedPendingLoads()
        requestItems(for: ids, priority: .userInitiated)
    }

    /// 转场落稳或被关闭后释放临时保护；仍被当前、可见或预取需要的批次继续执行。
    func cancelTransitionProtection() {
        transitionIDs.removeAll(keepingCapacity: true)
        cancelUnprotectedPendingLoads()
        refreshPinnedItems()
        drainLoadQueue()
    }

    /// 清空系统与二维预测共同留下的预取保护；不会释放当前、可见或转场锚点。
    func cancelAllPrefetch() {
        recentSystemPrefetchIDs.removeAll(keepingCapacity: true)
        systemPrefetchIDs.removeAll(keepingCapacity: true)
        predictedIDs.removeAll(keepingCapacity: true)
        cancelUnprotectedPendingLoads()
        refreshPinnedItems()
        drainLoadQueue()
    }

    /// 响应系统内存告警；主线程上保留当前/可见内容与身份顺序，并取消已失去保护的异步预取。
    func handleMemoryWarning() {
        recentSystemPrefetchIDs.removeAll(keepingCapacity: false)
        systemPrefetchIDs.removeAll(keepingCapacity: false)
        predictedIDs.removeAll(keepingCapacity: false)
        cancelUnprotectedPendingLoads()
        drainLoadQueue()

        let retainedIDs = currentIDs.union(visibleIDs).union(transitionIDs).union(actionItemLoads.keys)
        let currentGenerationIDs = retainedIDs.filter {
            cache.object(forKey: NSNumber(value: $0))?.contentGeneration == contentGeneration
        }
        let retainedItems = retainedIDs.reduce(into: [Int64: NoteReviewCardItem]()) { result, id in
            if let item = item(for: id) {
                result[id] = item
            }
        }

        cache.removeAllObjects()
        pinnedItems.removeAll(keepingCapacity: false)
        // A trusted old surface may stay pinned, but memory recovery must not relabel it as fresh action data.
        for item in retainedItems.values where currentGenerationIDs.contains(item.id) {
            store(item)
        }
        pinnedItems = retainedItems
    }

    /// 锁定目标书摘后读取标签目录与当前关系；取消由发起控制器负责，不会改变会话锚点。
    func fetchTagEditSnapshot(noteID: Int64) async throws -> NoteReviewTagEditSnapshot {
        try await repository.fetchNoteReviewTagEditSnapshot(noteID: noteID)
    }

    /// 新建书摘标签并返回可直接加入 Sheet 草稿的统一标签对象。
    func createTag(named name: String) async throws -> NoteEditorTagOption {
        try await repository.createNoteTag(named: name)
    }

    /// 替换锁定书摘的完整标签关系；成功后立即更新有界缓存，数据库观察继续负责最终收敛。
    func replaceTags(_ tags: [NoteEditorTagOption], noteID: Int64) async -> Bool {
        do {
            let confirmedTags = try await repository.replaceNoteReviewTags(noteID: noteID, tags: tags)
            guard !Task.isCancelled else { return false }
            contentGeneration &+= 1
            if let item = item(for: noteID) {
                store(item.replacingTags(confirmedTags))
                refreshPinnedItems()
                onItemsChanged?([noteID])
            } else {
                try await reloadItems(ids: [noteID])
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            onError?("保存标签失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 将标签改名或删除即时投影到会话缓存，防止当前页面在数据库观察到达前展示旧目录。
    func applyTagCatalogMutation(_ mutation: TagCatalogMutation) {
        guard mutation.scope == .note else { return }
        contentGeneration &+= 1
        var changedIDs = Set<Int64>()
        for noteID in orderedIDs {
            guard let item = item(for: noteID) else { continue }
            let nextTags = mutation.applying(to: item.tags)
            guard nextTags != item.tags else { continue }
            store(item.replacingTags(nextTags))
            changedIDs.insert(noteID)
        }
        guard !changedIDs.isEmpty else { return }
        refreshPinnedItems()
        onItemsChanged?(changedIDs)
    }

    /// 保存两种布局共享的内容显隐设置，不改变既有卡堆视觉。
    func updateDisplaySettings(_ display: NoteReviewImmersiveDisplaySettings) {
        guard settings.immersiveDisplay != display else { return }
        settings.immersiveDisplay = display
        persistSettings()
    }

    /// 重新生成随机会话；当前范围不变，入口前缀不再强制保留。
    func reshuffle() {
        guard settings.sortRule == .random else { return }
        sessionSeed = UInt64.random(in: UInt64.min...UInt64.max)
        shouldPreserveLaunchPrefix = false
        if usesDirectory {
            reloadDirectory(preserving: nil, refreshesContent: false)
            return
        }
        let sourceIDs = lastFetchedIDs.isEmpty ? orderedIDs : lastFetchedIDs
        orderedIDs = makeSessionOrder(from: sourceIDs, settings: settings)
        currentNoteID = orderedIDs.first ?? currentNoteID
        restartOverviewLayoutManifest()
        sanitizeDemandSetsAfterManifestChange()
        refreshPinnedItems()
        cancelUnprotectedPendingLoads()
        requestDemandedItems()
        onManifestChanged?()
    }
}

private extension NoteReviewUIKitSession {
    /// 外观不进入目录身份；随机前缀只取启动负载，避免分页过程改变全局排列。
    func directoryRequest() -> NoteReviewDirectoryRequest {
        .init(settings: settings, seed: sessionSeed,
              preservedIDs: shouldPreserveLaunchPrefix ? launchPayload.loadedNoteIDs : [])
    }

    /// 打开无正文目录并交付有界阅读页；源页面在等待期间不清空，也不恢复成全量 ID 读取。
    func reloadDirectory(preserving noteID: Int64?, refreshesContent: Bool) {
        manifestTask?.cancel()
        generation &+= 1
        let token = generation
        let request = directoryRequest()
        let selectionAtRequest = currentNoteID
        manifestTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await directoryCursor.configure(request,
                    refresh: refreshesContent && directoryTotalCount != nil)
                let anchor = noteID.map(NoteReviewDirectoryAnchor.noteID) ?? .ordinal(0)
                var page = try await directoryCursor.page(around: anchor)
                if page == nil {
                    page = try await directoryCursor.page(around: .ordinal(Int64(currentIndex)))
                }
                if page == nil { page = try await directoryCursor.page(around: .ordinal(0)) }
                try Task.checkCancellation()
                guard !isDisposed, token == generation else { return }
                if currentNoteID != selectionAtRequest {
                    page = try await directoryCursor.page(around: .noteID(currentNoteID))
                }
                if refreshesContent {
                    contentGeneration &+= 1
                    cache.removeAllObjects()
                    pendingLoads.values.forEach { $0.task.cancel() }
                    queuedLoads.removeAll()
                }
                directoryVersion &+= 1
                if let page {
                    if !page.members.contains(where: { $0.record.noteID == currentNoteID }) {
                        currentNoteID = page.focus?.member.record.noteID ?? page.members.first?.record.noteID ?? 0
                    }
                    pendingDirectoryPage = page
                    applyPendingReadingWindow()
                } else {
                    directoryTotalCount = 0; directoryFirstOrdinal = 0
                    orderedIDs = []; regionalOrdinals = [:]; currentNoteID = 0
                    onManifestChanged?()
                }
                if refreshesContent { onOverviewInvalidated?() }
            } catch is CancellationError { return }
            catch { if !isDisposed, token == generation { onError?("暂时无法准备回顾目录") } }
        }
    }

    /// 只替换最多 128 个身份；调用者负责在阅读手势外提交，并让真实正文缓存继续被复用。
    func applyDirectoryPage(_ page: NoteReviewDirectoryPage) {
        directoryTotalCount = Int(page.totalCount)
        directoryFirstOrdinal = Int(page.firstOrdinal)
        orderedIDs = page.members.map(\.record.noteID)
        refreshPinnedItems()
        requestForegroundItems()
        onManifestChanged?()
    }

    /// 把当前书摘及相邻项放进首个轻量批次；只改变读取优先级，不改变用户看到的筛选顺序。
    func prioritizedOverviewLayoutIDs() -> [Int64] {
        guard let currentIndex = noteIndexByID[currentNoteID], !orderedIDs.isEmpty else {
            return orderedIDs
        }
        var result: [Int64] = []
        result.reserveCapacity(orderedIDs.count)
        var seen = Set<Int64>()

        func append(at index: Int) {
            guard orderedIDs.indices.contains(index) else { return }
            let noteID = orderedIDs[index]
            if seen.insert(noteID).inserted {
                result.append(noteID)
            }
        }

        append(at: currentIndex)
        for distance in 1...64 {
            append(at: currentIndex - distance)
            append(at: currentIndex + distance)
        }
        for noteID in orderedIDs where seen.insert(noteID).inserted {
            result.append(noteID)
        }
        return result
    }

    /// 与完整内容共享双并发许可，消费完一批再读取下一批；主 actor 校验代次后才能提交。
    func restartOverviewLayoutManifest() {
        guard !isDisposed, automaticallyPreparesOverview else { return }
        overviewLayoutManifestTask?.cancel()
        overviewLayoutManifestGeneration &+= 1
        let expectedGeneration = overviewLayoutManifestGeneration
        let requestedIDs = prioritizedOverviewLayoutIDs()
        let removedIDs = receivedOverviewLayoutSourceIDs.union(overviewLayoutSourcesByID.keys).subtracting(requestedIDs)
        overviewLayoutSourcesByID.removeAll(keepingCapacity: false)
        receivedOverviewLayoutSourceIDs.removeAll(keepingCapacity: true)
        isOverviewLayoutManifestComplete = false
        onOverviewLayoutSourcesChanged?(removedIDs, false)
        let adapter = NoteReviewCanvasSourceAdapter { [weak self] ids, priority in
            guard let self, !isDisposed else { throw CancellationError() }
            return try await readOverviewSources(noteIDs: ids, priority: priority)
        }
        overviewLayoutManifestTask = Task(priority: .utility) { [weak self] in
            do {
                try await adapter.consume(ids: requestedIDs) { [weak self] batch in
                    guard let self, !isDisposed,
                          expectedGeneration == overviewLayoutManifestGeneration else { throw CancellationError() }
                    if let consumer = onOverviewLayoutBatch {
                        try await consumer(batch.sources, batch.missingIDs, batch.isLast)
                        try Task.checkCancellation()
                        guard !isDisposed, expectedGeneration == overviewLayoutManifestGeneration else { throw CancellationError() }
                    } else {
                        for source in batch.sources { overviewLayoutSourcesByID[source.noteID] = source }
                        for id in batch.missingIDs { overviewLayoutSourcesByID.removeValue(forKey: id) }
                    }
                    receivedOverviewLayoutSourceIDs.formUnion(batch.sources.map(\.noteID))
                    isOverviewLayoutManifestComplete = batch.isLast
                    if onOverviewLayoutBatch == nil {
                        onOverviewLayoutSourcesChanged?(Set(batch.sources.map(\.noteID)).union(batch.missingIDs), batch.isLast)
                    }
                }
                guard let self, expectedGeneration == overviewLayoutManifestGeneration else { return }
                overviewLayoutManifestTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, !isDisposed,
                      expectedGeneration == overviewLayoutManifestGeneration else { return }
                overviewLayoutManifestTask = nil
                isOverviewLayoutManifestComplete = false
                onOverviewLayoutSourcesChanged?([], false)
                onError?("读取回顾布局清单失败：\(error.localizedDescription)")
            }
        }
    }

    /// 观察设置和数据库变化；任务由会话拥有，取消后不会把过期结果写回已关闭控制器。
    func observeChanges() {
        let repository = repository
        settingObservationTask = Task { [weak self] in
            for await _ in repository.observeNoteReviewSettingChanges() {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                let nextSettings = repository.fetchNoteReviewSettings()
                guard nextSettings != settings else { continue }
                let needsManifest = !settings.hasSameDataScope(as: nextSettings)
                settings = nextSettings
                onSettingsChanged?()
                if needsManifest {
                    shouldPreserveLaunchPrefix = false
                    reloadManifest(
                        preserving: nil,
                        emitsLoadingState: false,
                        preservesExistingRandomOrder: false
                    )
                }
            }
        }
        dataObservationTask = Task { [weak self] in
            do {
                for try await _ in repository.observeNoteReviewDataChanges() {
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    reloadManifest(
                        preserving: currentNoteID,
                        emitsLoadingState: false,
                        preservesExistingRandomOrder: true,
                        refreshesContent: true
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                self?.onError?("同步书摘失败：\(error.localizedDescription)")
            }
        }
    }

    /// 取消上一轮清单请求并通过 generation 拒绝过期结果，保证主线程身份顺序不被竞态覆盖。
    func reloadManifest(
        preserving noteID: Int64?,
        emitsLoadingState: Bool,
        preservesExistingRandomOrder: Bool,
        refreshesContent: Bool = false
    ) {
        guard !isDisposed else { return }
        if usesDirectory {
            reloadDirectory(preserving: noteID, refreshesContent: refreshesContent)
            return
        }
        manifestTask?.cancel()
        generation &+= 1
        let expectedGeneration = generation
        let requestedSettings = settings
        let previousOrder = orderedIDs
        let selectionAtRequest = currentNoteID
        manifestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetchedIDs = try await readScheduler.perform { [repository] in
                    try await repository.fetchNoteReviewIDs(settings: requestedSettings)
                }
                guard !Task.isCancelled, expectedGeneration == generation else { return }
                lastFetchedIDs = fetchedIDs
                orderedIDs = preservesExistingRandomOrder
                    ? makeSessionOrderPreservingExisting(from: fetchedIDs, settings: requestedSettings)
                    : makeSessionOrder(from: fetchedIDs, settings: requestedSettings)
                let removedIDs = Set(previousOrder).subtracting(orderedIDs)
                let isConfirmedLocalDeletion = !removedIDs.isEmpty
                    && removedIDs.isSubset(of: deletionInvalidationIDs)
                    && previousOrder.filter { !removedIDs.contains($0) } == orderedIDs
                let needsOverviewInvalidation = refreshesContent && !isConfirmedLocalDeletion
                // A deletion signal can include a surviving note's edit, image, or tag change.
                // Only geometry may take the verified deletion fast path; complete business items cannot.
                if refreshesContent {
                    contentGeneration &+= 1
                    cache.removeAllObjects()
                    // Protected objects remain a trusted display until their replacements arrive.
                    // Scheduling and action reads below only accept the current content generation.
                    pendingLoads.values.forEach { $0.task.cancel() }
                    queuedLoads.removeAll()
                }
                for id in removedIDs {
                    cache.removeObject(forKey: NSNumber(value: id))
                    pinnedItems.removeValue(forKey: id)
                }
                deletionInvalidationIDs.subtract(removedIDs)
                // A data refresh cannot undo a selection made while its repository read was awaiting.
                // A scope reset intentionally passes nil and retains its explicit reset semantics.
                let anchorID = noteID.map { currentNoteID == selectionAtRequest ? $0 : currentNoteID }
                if let anchorID, index(of: anchorID) != nil {
                    currentNoteID = anchorID
                } else {
                    currentNoteID = NoteReviewCanvasSelection.replacement(
                        for: anchorID, previousOrder: previousOrder, nextOrder: orderedIDs
                    ) ?? 0
                }
                restartOverviewLayoutManifest()
                sanitizeDemandSetsAfterManifestChange()
                refreshPinnedItems()
                cancelUnprotectedPendingLoads()
                requestDemandedItems()
                onManifestChanged?()
                if refreshesContent {
                    try await reloadItems(ids: [currentNoteID] + visibleIDOrder)
                    guard !Task.isCancelled, expectedGeneration == generation else { return }
                    if needsOverviewInvalidation { onOverviewInvalidated?() }
                }
            } catch is CancellationError {
                return
            } catch {
                guard expectedGeneration == generation else { return }
                onError?("读取全屏回顾失败：\(error.localizedDescription)")
            }
        }
    }

    func makeSessionOrder(from fetchedIDs: [Int64], settings: NoteReviewSettings) -> [Int64] {
        let fetchedIDs = Self.orderedUniqueIDs(fetchedIDs)
        guard settings.sortRule == .random else { return fetchedIDs }
        let available = Set(fetchedIDs)
        var seenPrefixIDs = Set<Int64>()
        let prefix = shouldPreserveLaunchPrefix
            ? launchPayload.loadedNoteIDs.filter {
                available.contains($0) && seenPrefixIDs.insert($0).inserted
            }
            : []
        let prefixSet = Set(prefix)
        var remaining = fetchedIDs.filter { !prefixSet.contains($0) }
        var generator = SplitMix64(seed: sessionSeed)
        remaining.shuffle(using: &generator)
        return prefix + remaining
    }

    /// 普通数据增删时保留随机轮次中既有 ID 的相对顺序，只把新书摘追加到末端。
    func makeSessionOrderPreservingExisting(
        from fetchedIDs: [Int64],
        settings: NoteReviewSettings
    ) -> [Int64] {
        let fetchedIDs = Self.orderedUniqueIDs(fetchedIDs)
        guard settings.sortRule == .random else { return fetchedIDs }
        let available = Set(fetchedIDs)
        let retained = orderedIDs.filter(available.contains)
        let retainedSet = Set(retained)
        var additions = fetchedIDs.filter { !retainedSet.contains($0) }
        var generator = SplitMix64(seed: sessionSeed ^ UInt64(retained.count))
        additions.shuffle(using: &generator)
        return retained + additions
    }

    /// 将一次不超过二十条的请求并入优先级队列；同一 ID 在排队和执行阶段始终只属于一个批次。
    func requestItems(for ids: [Int64], priority: TaskPriority) {
        guard !isDisposed else { return }
        let requestedIDs = Self.orderedUniqueIDs(ids, limit: Constants.batchSize)
        guard !requestedIDs.isEmpty else { return }
        promoteScheduledLoads(containing: Set(requestedIDs), to: priority)

        var scheduledIDs = pendingLoads.values.reduce(into: Set<Int64>()) { result, load in
            result.formUnion(load.ids)
        }
        queuedLoads.forEach { scheduledIDs.formUnion($0.ids) }
        scheduledIDs.formUnion(actionItemLoads.keys)
        let missing = requestedIDs.filter {
            cachedActionItem(for: $0) == nil && !scheduledIDs.contains($0)
        }
        guard !missing.isEmpty else { return }
        nextLoadSequence &+= 1
        queuedLoads.append(
            QueuedLoad(
                token: UUID(),
                ids: missing,
                priority: maximumPriority(priority, effectivePriority(for: missing)),
                sequence: nextLoadSequence
            )
        )
        drainLoadQueue()
    }

    /// 从队列按优先级和到达顺序启动请求；执行中的 Repository 批次始终不超过两个。
    func drainLoadQueue() {
        guard !isDisposed else { return }
        reprioritizeQueuedLoads()
        while pendingLoads.count < Constants.maximumConcurrentLoads,
              !queuedLoads.isEmpty {
            let nextIndex = queuedLoads.indices.max { lhs, rhs in
                let left = queuedLoads[lhs]
                let right = queuedLoads[rhs]
                if left.priority.rawValue == right.priority.rawValue {
                    return left.sequence > right.sequence
                }
                return left.priority.rawValue < right.priority.rawValue
            } ?? queuedLoads.startIndex
            let load = queuedLoads.remove(at: nextIndex)
            guard !load.ids.allSatisfy({ cachedActionItem(for: $0) != nil }) else { continue }
            guard !Set(load.ids).isDisjoint(with: protectedIDs) else { continue }
            start(load)
        }
    }

    /// 为一个已排队批次创建唯一任务；取消、成功和失败都先释放并发槽，再调度后续批次。
    private func start(_ queuedLoad: QueuedLoad) {
        let token = queuedLoad.token
        let requestedIDs = queuedLoad.ids
        let expectedContentGeneration = contentGeneration
        let repository = repository
        let task = Task(priority: queuedLoad.priority) { [weak self] in
            guard let self else { return }
            do {
                let items = try await readScheduler.perform(priority: queuedLoad.priority) {
                    try await repository.fetchNoteReviewItems(noteIDs: requestedIDs)
                }
                guard !Task.isCancelled, expectedContentGeneration == contentGeneration else {
                    finishLoad(token: token, retryCandidates: requestedIDs)
                    return
                }
                for item in items where index(of: item.id) != nil { store(item) }
                refreshPinnedItems()
                pendingLoads.removeValue(forKey: token)
                if !items.isEmpty {
                    onItemsChanged?(Set(items.map(\.id)))
                }
                drainLoadQueue()
            } catch is CancellationError {
                finishLoad(token: token, retryCandidates: requestedIDs)
            } catch {
                if Task.isCancelled {
                    finishLoad(token: token, retryCandidates: requestedIDs)
                    return
                }
                pendingLoads.removeValue(forKey: token)
                drainLoadQueue()
                onError?("加载书摘失败：\(error.localizedDescription)")
            }
        }
        pendingLoads[token] = PendingLoad(
            ids: requestedIDs,
            priority: queuedLoad.priority,
            task: task
        )
    }

    /// 结束被取消的批次；若取消尚未完成时需求重新出现，只重建一次仍有需求的新批次。
    func finishLoad(token: UUID, retryCandidates: [Int64]) {
        pendingLoads.removeValue(forKey: token)
        let retryIDs = retryCandidates.filter {
            protectedIDs.contains($0) && item(for: $0) == nil
        }
        if !retryIDs.isEmpty {
            requestItems(for: retryIDs, priority: effectivePriority(for: retryIDs))
        }
        drainLoadQueue()
    }

    func reloadItems(ids: [Int64]) async throws {
        let requestedIDs = Self.orderedUniqueIDs(ids, limit: Constants.batchSize)
        let expectedContentGeneration = contentGeneration
        let items = try await readScheduler.perform { [repository] in
            try await repository.fetchNoteReviewItems(noteIDs: requestedIDs)
        }
        guard !Task.isCancelled, !isDisposed, expectedContentGeneration == contentGeneration else { return }
        for item in items { store(item) }
        refreshPinnedItems()
        onItemsChanged?(Set(items.map(\.id)))
    }

    func store(_ item: NoteReviewCardItem) {
        let cost = max(
            1,
            (item.contentHTML.utf8.count + item.ideaHTML.utf8.count
                + item.imageURLs.reduce(0) { $0 + $1.utf8.count }) * 2
        )
        cache.setObject(ItemBox(item, contentGeneration: contentGeneration), forKey: NSNumber(value: item.id), cost: cost)
        // A protected reference and the cache must advance as one main-actor write.
        if protectedIDs.contains(item.id) { pinnedItems[item.id] = item }
    }

    /// 将可见需求与当前项合并限制在一个二十条批次内，并保留控制器给出的空间顺序。
    func normalizeVisibleDemand() {
        visibleIDOrder = normalizedVisibleIDOrder(visibleIDOrder)
        visibleIDs = Set(visibleIDOrder)
    }

    /// 将控制器给出的可见身份归一化为有效、有序且不超过前台单批容量的稳定序列。
    func normalizedVisibleIDOrder(_ ids: [Int64]) -> [Int64] {
        let validOrder = Self.orderedUniqueIDs(ids.filter { index(of: $0) != nil })
        let currentID = currentIDs.first
        let maximumVisibleCount = currentID.map { validOrder.contains($0) ? Constants.batchSize : Constants.batchSize - 1 }
            ?? Constants.batchSize
        return Array(validOrder.prefix(maximumVisibleCount))
    }

    /// 清单变化后剔除失效需求并恢复唯一当前需求，避免旧筛选 ID 继续占用加载槽。
    func sanitizeDemandSetsAfterManifestChange() {
        let available = Set(orderedIDs)
        currentIDs = available.contains(currentNoteID) ? [currentNoteID] : []
        visibleIDOrder.removeAll(where: { !available.contains($0) })
        normalizeVisibleDemand()
        recentSystemPrefetchIDs.removeAll(where: { !available.contains($0) })
        systemPrefetchIDs.formIntersection(available)
        predictedIDs.formIntersection(available)
        transitionIDs.formIntersection(available)
    }

    /// 以当前项优先组织首屏请求；当前和可见集合的并集不会超过单批二十条。
    func requestForegroundItems() {
        let ids = Self.orderedUniqueIDs(
            Array(currentIDs) + visibleIDOrder,
            limit: Constants.batchSize
        )
        requestItems(for: ids, priority: .userInitiated)
    }

    /// 按五类需求重新补齐尚未排队的内容；用于清单更新以及取消批次竞态后的收敛。
    func requestDemandedItems() {
        requestForegroundItems()
        requestItems(for: orderedDemandIDs(transitionIDs), priority: .userInitiated)
        requestItems(for: orderedDemandIDs(predictedIDs), priority: .utility)
        requestItems(for: orderedDemandIDs(systemPrefetchIDs), priority: .utility)
    }

    /// 将集合恢复为当前会话顺序，确保 Repository 批次稳定且便于缓存局部命中。
    func orderedDemandIDs(_ ids: Set<Int64>) -> [Int64] {
        ids.sorted {
            (index(of: $0) ?? .max) < (index(of: $1) ?? .max)
        }
    }

    /// 返回所有仍需保护的身份；执行中批次只有与该集合完全无交集时才允许取消。
    var protectedIDs: Set<Int64> {
        currentIDs
            .union(visibleIDs)
            .union(systemPrefetchIDs)
            .union(predictedIDs)
            .union(transitionIDs)
            .union(actionItemLoads.keys)
    }

    func refreshPinnedItems() {
        let retainedIDs = protectedIDs
        let existingPinnedItems = pinnedItems
        pinnedItems = retainedIDs.reduce(into: [:]) { result, id in
            if let item = existingPinnedItems[id] ?? cache.object(forKey: NSNumber(value: id))?.item {
                result[id] = item
            }
        }
    }

    /// 只取消已经完全失去五类需求的整批任务；部分 ID 离开时原批次继续，避免取消后拆分重启。
    func cancelUnprotectedPendingLoads() {
        let retainedIDs = protectedIDs
        queuedLoads.removeAll { load in
            Set(load.ids).isDisjoint(with: retainedIDs)
        }
        for load in pendingLoads.values where Set(load.ids).isDisjoint(with: retainedIDs) {
            load.task.cancel()
        }
        reprioritizeQueuedLoads()
    }

    /// 提升已排队批次的优先级；执行中任务保持唯一，不以取消重建来模拟提权。
    func promoteScheduledLoads(containing ids: Set<Int64>, to priority: TaskPriority) {
        guard !ids.isEmpty else { return }
        for index in queuedLoads.indices where !Set(queuedLoads[index].ids).isDisjoint(with: ids) {
            queuedLoads[index].priority = maximumPriority(queuedLoads[index].priority, priority)
        }
        for token in Array(pendingLoads.keys) {
            guard var load = pendingLoads[token],
                  !Set(load.ids).isDisjoint(with: ids) else {
                continue
            }
            load.priority = maximumPriority(load.priority, priority)
            pendingLoads[token] = load
        }
    }

    /// 根据最新需求位重新计算等待批次优先级，保证预取在成为当前或转场目标时先行。
    func reprioritizeQueuedLoads() {
        for index in queuedLoads.indices {
            queuedLoads[index].priority = maximumPriority(
                queuedLoads[index].priority,
                effectivePriority(for: queuedLoads[index].ids)
            )
        }
    }

    /// 当前、可见和转场目标使用用户优先级，其余预测与系统预取使用工具优先级。
    func effectivePriority(for ids: [Int64]) -> TaskPriority {
        let ids = Set(ids)
        let foregroundIDs = currentIDs.union(visibleIDs).union(transitionIDs).union(actionItemLoads.keys)
        return ids.isDisjoint(with: foregroundIDs) ? .utility : .userInitiated
    }

    /// 比较 Swift 任务优先级并返回更高者，不依赖枚举可比较性的隐式实现。
    func maximumPriority(_ lhs: TaskPriority, _ rhs: TaskPriority) -> TaskPriority {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }

    /// 按首次出现顺序去重并可选截断，为可见与预取批次提供稳定输入。
    static func orderedUniqueIDs(_ ids: [Int64], limit: Int? = nil) -> [Int64] {
        var seen = Set<Int64>()
        var result: [Int64] = []
        if let limit {
            result.reserveCapacity(min(ids.count, limit))
        } else {
            result.reserveCapacity(ids.count)
        }
        for id in ids where seen.insert(id).inserted {
            result.append(id)
            if let limit, result.count >= limit {
                break
            }
        }
        return result
    }

    /// 为去重后的会话顺序建立常数时间反向索引；异常重复 ID 以首次出现为准。
    static func makeIndexMap(for ids: [Int64]) -> [Int64: Int] {
        ids.enumerated().reduce(into: [:]) { result, entry in
            if result[entry.element] == nil {
                result[entry.element] = entry.offset
            }
        }
    }

    /// 保存当前会话已应用的设置并立即通知控制器；随后到达的持久化通知会因值相等而幂等忽略。
    func persistSettings() {
        repository.saveNoteReviewSettings(settings)
        onSettingsChanged?()
    }
}

/// 小型确定性随机数生成器，保证同一会话种子的一轮随机顺序稳定且不重复。
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

private extension UUID {
    var stableUInt64Seed: UInt64 {
        withUnsafeBytes(of: uuid) { bytes in
            bytes.prefix(MemoryLayout<UInt64>.size).enumerated().reduce(0) { result, entry in
                result | (UInt64(entry.element) << UInt64(entry.offset * 8))
            }
        }
    }
}
