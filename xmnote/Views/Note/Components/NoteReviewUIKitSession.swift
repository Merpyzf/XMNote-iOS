/**
 * [INPUT]: 依赖 NoteReviewLaunchPayload 与 NoteRepositoryProtocol，接收 UIKit 可见/预取范围和设置写入意图
 * [OUTPUT]: 对外提供 NoteReviewUIKitSession（有界完整内容缓存、稳定 ID 序列、随机会话与收藏标签编排）
 * [POS]: Views/Note/Components 的全屏回顾页面私有会话层，只长期持有轻量 ID 并把所有数据访问收口到 Repository
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit

/// 全屏回顾页面私有会话；主线程拥有状态，数据库等待期间不阻塞集合视图交互。
@MainActor
final class NoteReviewUIKitSession {
    private enum Constants {
        static let batchSize = 20
        static let cacheCostLimit = 16 * 1024 * 1024
        static let cacheCountLimit = 240
    }

    private final class ItemBox: NSObject {
        let item: NoteReviewCardItem

        init(_ item: NoteReviewCardItem) {
            self.item = item
        }
    }

    private struct PendingLoad {
        let ids: Set<Int64>
        let task: Task<Void, Never>
    }

    private let repository: any NoteRepositoryProtocol
    private let launchPayload: NoteReviewLaunchPayload
    private let cache = NSCache<NSNumber, ItemBox>()
    private var pinnedItems: [Int64: NoteReviewCardItem] = [:]
    private var visibleIDs: Set<Int64> = []
    private var prefetchedIDs: Set<Int64> = []
    private var pendingLoads: [UUID: PendingLoad] = [:]
    private var recentPrefetchIDs: [Int64] = []
    private var manifestTask: Task<Void, Never>?
    private var settingObservationTask: Task<Void, Never>?
    private var dataObservationTask: Task<Void, Never>?
    private var generation = 0
    private var isSavingSettings = false
    private var sessionSeed: UInt64 = 0
    private var shouldPreserveLaunchPrefix = true
    private var lastFetchedIDs: [Int64] = []

    private(set) var orderedIDs: [Int64]
    private(set) var settings: NoteReviewSettings
    private(set) var currentNoteID: Int64

    var onManifestChanged: (() -> Void)?
    var onItemsChanged: ((Set<Int64>) -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onError: ((String) -> Void)?

    /// 注入仓储与卡堆启动负载；首条完整内容同步写入有界缓存，避免出现加载中转页。
    init(payload: NoteReviewLaunchPayload, repository: any NoteRepositoryProtocol) {
        self.repository = repository
        self.launchPayload = payload
        self.settings = payload.settings
        self.currentNoteID = payload.selectedNoteID
        self.orderedIDs = payload.loadedNoteIDs
        self.sessionSeed = payload.sessionID.stableUInt64Seed
        cache.totalCostLimit = Constants.cacheCostLimit
        cache.countLimit = Constants.cacheCountLimit
        for item in payload.seedItems {
            store(item)
        }
        observeChanges()
    }

    deinit {
        manifestTask?.cancel()
        settingObservationTask?.cancel()
        dataObservationTask?.cancel()
        pendingLoads.values.forEach { $0.task.cancel() }
    }

    var currentIndex: Int {
        orderedIDs.firstIndex(of: currentNoteID) ?? 0
    }

    var count: Int { orderedIDs.count }

    /// 首次读取完整身份清单；进入时已有 ID 与完整内容可先直接绘制，不等待清单查询。
    func start() {
        reloadManifest(preserving: currentNoteID, emitsLoadingState: false)
    }

    /// 按索引返回稳定身份，越界时不制造替代对象。
    func noteID(at index: Int) -> Int64? {
        guard orderedIDs.indices.contains(index) else { return nil }
        return orderedIDs[index]
    }

    /// 从有界缓存读取完整书摘。
    func item(for noteID: Int64) -> NoteReviewCardItem? {
        pinnedItems[noteID] ?? cache.object(forKey: NSNumber(value: noteID))?.item
    }

    /// 更新阅读锚点；当前项会被固定，直到下一次锚点变化。
    func setCurrentNoteID(_ noteID: Int64) {
        guard orderedIDs.contains(noteID) else { return }
        currentNoteID = noteID
        refreshPinnedItems()
    }

    /// 固定当前屏幕项目并按需批量补充完整内容，缓存淘汰不会影响仍在显示的 Cell。
    func updateVisibleIDs(_ ids: Set<Int64>) {
        visibleIDs = ids
        refreshPinnedItems()
        requestItems(for: Array(ids), priority: .userInitiated)
    }

    /// 预取调用严格按二十条切批；请求反向失效时可被取消。
    func prefetch(noteIDs: [Int64]) {
        let ids = Array(noteIDs.prefix(Constants.batchSize))
        for id in ids {
            recentPrefetchIDs.removeAll(where: { $0 == id })
            recentPrefetchIDs.append(id)
        }
        if recentPrefetchIDs.count > Constants.batchSize * 2 {
            recentPrefetchIDs.removeFirst(recentPrefetchIDs.count - Constants.batchSize * 2)
        }
        prefetchedIDs = Set(recentPrefetchIDs)
        cancelUnprotectedPendingLoads()
        requestItems(for: ids, priority: .utility)
    }

    /// 取消完全离开预取与可见范围的批次，避免快速反向滚动继续占用数据库读取结果。
    func cancelPrefetch(noteIDs: [Int64]) {
        let cancelled = Set(noteIDs)
        recentPrefetchIDs.removeAll(where: cancelled.contains)
        prefetchedIDs = Set(recentPrefetchIDs)
        cancelUnprotectedPendingLoads()
        refreshPinnedItems()
    }

    /// 判断当前书摘是否拥有已绑定收藏标签。
    func isFavorite(noteID: Int64) -> Bool {
        guard let favoriteTagID = settings.favoriteTagID,
              let item = item(for: noteID) else {
            return false
        }
        return item.tags.contains(where: { $0.id == favoriteTagID })
    }

    /// 切换爱心关系；未绑定标签时返回 false，由控制器打开单选 Sheet。
    @discardableResult
    func toggleFavorite(noteID: Int64) -> Bool {
        guard let favoriteTagID = settings.favoriteTagID else { return false }
        let nextValue = !isFavorite(noteID: noteID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setNoteTagMembership(
                    noteID: noteID,
                    tagID: favoriteTagID,
                    isPresent: nextValue
                )
                try await self.reloadItems(ids: [noteID])
            } catch is CancellationError {
                return
            } catch {
                self.onError?("更新收藏失败：\(error.localizedDescription)")
            }
        }
        return true
    }

    /// 绑定任意自定义标签；首次绑定可同时收藏当前书摘，重新绑定不会迁移旧关系。
    func bindFavoriteTag(_ tagID: Int64, favoriteNoteID: Int64?) {
        guard tagID > 0 else { return }
        settings.favoriteTagID = tagID
        persistSettings()
        guard let favoriteNoteID else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setNoteTagMembership(
                    noteID: favoriteNoteID,
                    tagID: tagID,
                    isPresent: true
                )
                try await self.reloadItems(ids: [favoriteNoteID])
            } catch is CancellationError {
                return
            } catch {
                self.onError?("绑定收藏标签失败：\(error.localizedDescription)")
            }
        }
    }

    /// 读取全部书摘标签，供 UIKit 单选 Sheet 展示。
    func fetchTagOptions() async throws -> [NoteReviewTagOption] {
        try await repository.fetchNoteReviewTagOptions()
    }

    /// 新建书摘标签并转换成回顾选择项。
    func createTag(named name: String) async throws -> NoteReviewTagOption {
        let tag = try await repository.createNoteTag(named: name)
        return NoteReviewTagOption(id: tag.id, title: tag.title, noteCount: 0)
    }

    /// 保存两种布局共享的内容显隐设置，不改变既有卡堆视觉。
    func updateDisplaySettings(_ display: NoteReviewImmersiveDisplaySettings) {
        guard settings.immersiveDisplay != display else { return }
        settings.immersiveDisplay = display
        persistSettings()
        onSettingsChanged?()
    }

    /// 重新生成随机会话；当前范围不变，入口前缀不再强制保留。
    func reshuffle() {
        guard settings.sortRule == .random else { return }
        sessionSeed = UInt64.random(in: UInt64.min...UInt64.max)
        shouldPreserveLaunchPrefix = false
        let sourceIDs = lastFetchedIDs.isEmpty ? orderedIDs : lastFetchedIDs
        orderedIDs = makeSessionOrder(from: sourceIDs, settings: settings)
        currentNoteID = orderedIDs.first ?? currentNoteID
        refreshPinnedItems()
        onManifestChanged?()
    }
}

private extension NoteReviewUIKitSession {
    /// 观察设置和数据库变化；任务由会话拥有，取消后不会把过期结果写回已关闭控制器。
    func observeChanges() {
        let repository = repository
        settingObservationTask = Task { [weak self] in
            for await _ in repository.observeNoteReviewSettingChanges() {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                if isSavingSettings {
                    isSavingSettings = false
                    continue
                }
                let nextSettings = repository.fetchNoteReviewSettings()
                let needsManifest = !settings.hasSameDataScope(as: nextSettings)
                settings = nextSettings
                onSettingsChanged?()
                if needsManifest {
                    reloadManifest(preserving: currentNoteID, emitsLoadingState: false)
                }
            }
        }
        dataObservationTask = Task { [weak self] in
            do {
                for try await _ in repository.observeNoteReviewDataChanges() {
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    reloadManifest(preserving: currentNoteID, emitsLoadingState: false)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.onError?("同步书摘失败：\(error.localizedDescription)")
            }
        }
    }

    func reloadManifest(preserving noteID: Int64, emitsLoadingState: Bool) {
        manifestTask?.cancel()
        generation &+= 1
        let expectedGeneration = generation
        let requestedSettings = settings
        manifestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetchedIDs = try await repository.fetchNoteReviewIDs(settings: requestedSettings)
                guard !Task.isCancelled, expectedGeneration == generation else { return }
                lastFetchedIDs = fetchedIDs
                orderedIDs = makeSessionOrder(from: fetchedIDs, settings: requestedSettings)
                if orderedIDs.contains(noteID) {
                    currentNoteID = noteID
                } else if let first = orderedIDs.first {
                    currentNoteID = first
                }
                refreshPinnedItems()
                onManifestChanged?()
            } catch is CancellationError {
                return
            } catch {
                guard expectedGeneration == generation else { return }
                onError?("读取全屏回顾失败：\(error.localizedDescription)")
            }
        }
    }

    func makeSessionOrder(from fetchedIDs: [Int64], settings: NoteReviewSettings) -> [Int64] {
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

    func requestItems(for ids: [Int64], priority: TaskPriority) {
        let missing = ids.reduce(into: [Int64]()) { result, id in
            guard result.count < Constants.batchSize,
                  item(for: id) == nil,
                  !result.contains(id),
                  !pendingLoads.values.contains(where: { $0.ids.contains(id) }) else {
                return
            }
            result.append(id)
        }
        guard !missing.isEmpty else { return }
        let token = UUID()
        let task = Task(priority: priority) { [weak self] in
            guard let self else { return }
            defer { pendingLoads.removeValue(forKey: token) }
            do {
                let items = try await repository.fetchNoteReviewItems(noteIDs: missing)
                guard !Task.isCancelled else { return }
                for item in items { store(item) }
                refreshPinnedItems()
                onItemsChanged?(Set(items.map(\.id)))
            } catch is CancellationError {
                return
            } catch {
                onError?("加载书摘失败：\(error.localizedDescription)")
            }
        }
        pendingLoads[token] = PendingLoad(ids: Set(missing), task: task)
    }

    func reloadItems(ids: [Int64]) async throws {
        let items = try await repository.fetchNoteReviewItems(noteIDs: Array(ids.prefix(Constants.batchSize)))
        guard !Task.isCancelled else { return }
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
        cache.setObject(ItemBox(item), forKey: NSNumber(value: item.id), cost: cost)
    }

    func refreshPinnedItems() {
        let protectedIDs = visibleIDs.union(prefetchedIDs).union([currentNoteID])
        pinnedItems = protectedIDs.reduce(into: [:]) { result, id in
            if let item = cache.object(forKey: NSNumber(value: id))?.item {
                result[id] = item
            }
        }
    }

    func cancelUnprotectedPendingLoads() {
        let protected = visibleIDs.union(prefetchedIDs).union([currentNoteID])
        let tokensToCancel = pendingLoads.compactMap { token, load in
            load.ids.isDisjoint(with: protected) ? token : nil
        }
        for token in tokensToCancel {
            pendingLoads.removeValue(forKey: token)?.task.cancel()
        }
    }

    func persistSettings() {
        isSavingSettings = true
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
