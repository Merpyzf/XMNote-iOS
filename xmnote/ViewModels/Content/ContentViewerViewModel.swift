/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 提供 viewer feed/详情/硬删除，依赖 NoteRepositoryProtocol 与 ExternalAppIntegrationRepositoryProtocol 提供标签和外部发送
 * [OUTPUT]: 对外提供 ContentViewerViewModel、ContentViewerActionFeedback，驱动分页、详情缓存、删除、标签编辑与外部发送
 * [POS]: Content 模块查看页状态中枢，负责时间线/书籍详情来源的统一内容查看体验
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Viewer 写操作反馈角色；View 将其映射到项目统一 Toast，状态层不直接依赖 UI 组件。
nonisolated enum ContentViewerActionFeedbackRole: Equatable, Sendable {
    case processing
    case success
    case warning
    case error
}

/// Viewer 一次性动作反馈；独立 ID 保证相同文案的连续失败仍能被界面消费。
nonisolated struct ContentViewerActionFeedback: Identifiable, Equatable, Sendable {
    let id = UUID()
    let role: ContentViewerActionFeedbackRole
    let message: String
}

@MainActor
@Observable
/// 通用内容查看器状态源，负责 feed 订阅、分页选择、详情刷新与删除后的相邻项回退。
final class ContentViewerViewModel {
    private struct PendingDeletedSelection {
        let deletedItemID: ContentViewerItemID
        let deletedIndex: Int
    }
    private enum CachePolicy {
        static let keepRadius = 5
        static let maxEntries = 80
    }

    let source: ContentViewerSourceContext
    let keyword: String

    var items: [ContentViewerListItem] = []
    var selectedItemID: ContentViewerItemID?
    var isLoadingList = false
    var isDeleting = false
    var isLoadingTagEditor = false
    var isSavingTags = false
    var sendingDestination: ExternalAppDestination?
    var configuredExternalAppDestinations: Set<ExternalAppDestination> = []
    var actionFeedback: ContentViewerActionFeedback?
    var listErrorMessage: String?
    private(set) var dismissalRequestToken: Int = 0

    private var detailCache: [ContentViewerItemID: ContentViewerDetail] = [:]
    private var detailLoadingIDs: Set<ContentViewerItemID> = []
    private var detailErrorMessages: [ContentViewerItemID: String] = [:]
    private var hasAppliedInitialSelection = false
    private var pendingDeletedSelection: PendingDeletedSelection?
    private var listObservationTask: Task<Void, Never>?
    private var externalAppObservationTask: Task<Void, Never>?
    private let restoredSelectedItemID: ContentViewerItemID?

    private let initialItemID: ContentViewerItemID
    private let defaultTitle: String
    private let missingItemMessage: String
    private let repository: any ContentRepositoryProtocol
    private let noteRepository: any NoteRepositoryProtocol
    private let externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol

    /// 注入 viewer 来源、初始项与仓储，建立分页状态初始化上下文。
    init(
        source: ContentViewerSourceContext,
        initialItemID: ContentViewerItemID,
        restoredSelectedItemID: ContentViewerItemID? = nil,
        keyword: String,
        defaultTitle: String,
        missingItemMessage: String,
        repository: any ContentRepositoryProtocol,
        noteRepository: any NoteRepositoryProtocol,
        externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol
    ) {
        self.source = source
        self.initialItemID = initialItemID
        self.restoredSelectedItemID = restoredSelectedItemID
        self.keyword = keyword
        self.defaultTitle = defaultTitle
        self.missingItemMessage = missingItemMessage
        self.repository = repository
        self.noteRepository = noteRepository
        self.externalAppIntegrationRepository = externalAppIntegrationRepository
    }

    /// 释放 Viewer 时取消数据库和配置观察流；在途网络发送遵循调用 View Task 的结构化取消。
    isolated deinit {
        listObservationTask?.cancel()
        externalAppObservationTask?.cancel()
    }

    var selectedListItem: ContentViewerListItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }

    var selectedDetail: ContentViewerDetail? {
        guard let selectedItemID else { return nil }
        return detailCache[selectedItemID]
    }

    var selectedBookTitle: String {
        if let detail = selectedDetail {
            return detail.bookTitle
        }
        return selectedListItem?.bookTitle ?? defaultTitle
    }

    var selectedBookID: Int64? {
        if let detail = selectedDetail {
            return detail.sourceBookId
        }
        return selectedListItem?.sourceBookId
    }

    var selectedPageProgress: ContentViewerPageProgress? {
        guard items.count > 1 else { return nil }
        guard
            let selectedItemID,
            let selectedIndex = items.firstIndex(where: { $0.id == selectedItemID })
        else {
            return ContentViewerPageProgress(current: 1, total: items.count)
        }
        return ContentViewerPageProgress(current: selectedIndex + 1, total: items.count)
    }

    /// 启动 feed 观察，持续同步来源列表并维护当前分页选择。
    func startObservation() {
        guard listObservationTask == nil else { return }
        isLoadingList = true
        listErrorMessage = nil
        let repository = self.repository
        let source = self.source
        let stream = repository.observeViewerItems(source: source)

        listObservationTask = Task { [weak self] in
            do {
                for try await observedItems in stream {
                    guard !Task.isCancelled else { return }
                    self?.listErrorMessage = nil
                    self?.applyObservedItems(observedItems)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.isLoadingList = false
                if self.items.isEmpty {
                    self.listErrorMessage = "加载失败：\(error.localizedDescription)"
                }
            }
        }
        startExternalAppObservation()
    }

    /// 读取当前书摘的标签编辑快照；只允许 note 类型调用，失败通过一次性反馈交给页面。
    func fetchTagEditSnapshot(noteID: Int64) async -> NoteReviewTagEditSnapshot? {
        guard !isLoadingTagEditor else { return nil }
        isLoadingTagEditor = true
        defer { isLoadingTagEditor = false }
        do {
            let snapshot = try await noteRepository.fetchNoteReviewTagEditSnapshot(noteID: noteID)
            guard !Task.isCancelled else { return nil }
            return snapshot
        } catch {
            guard !Task.isCancelled else { return nil }
            actionFeedback = ContentViewerActionFeedback(
                role: .error,
                message: "读取标签失败：\(error.localizedDescription)"
            )
            return nil
        }
    }

    /// 新建书摘标签并返回可立即选中的真实标签对象。
    func createTag(named name: String) async -> NoteEditorTagOption? {
        do {
            let tag = try await noteRepository.createNoteTag(named: name)
            guard !Task.isCancelled else { return nil }
            return tag
        } catch {
            guard !Task.isCancelled else { return nil }
            actionFeedback = ContentViewerActionFeedback(
                role: .error,
                message: "创建标签失败：\(error.localizedDescription)"
            )
            return nil
        }
    }

    /// 物理替换指定书摘标签关系，成功后强刷当前详情缓存以同步标签 rail。
    func replaceTags(_ tags: [NoteEditorTagOption], noteID: Int64) async -> Bool {
        guard !isSavingTags else { return false }
        isSavingTags = true
        defer { isSavingTags = false }
        do {
            _ = try await noteRepository.replaceNoteReviewTags(noteID: noteID, tags: tags)
            guard !Task.isCancelled else { return false }
            await refreshDetail(itemID: .note(noteID))
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            actionFeedback = ContentViewerActionFeedback(
                role: .error,
                message: "保存标签失败：\(error.localizedDescription)"
            )
            return false
        }
    }

    /// 发送当前书摘到已配置目标；写操作即时发布 processing 并阻止重复触发。
    func send(noteID: Int64, to destination: ExternalAppDestination) async {
        guard sendingDestination == nil else { return }
        guard configuredExternalAppDestinations.contains(destination) else {
            actionFeedback = ContentViewerActionFeedback(
                role: .warning,
                message: "请先在“我的 > 关联应用”配置 \(destination.displayName)"
            )
            return
        }
        sendingDestination = destination
        actionFeedback = ContentViewerActionFeedback(
            role: .processing,
            message: "正在发送到 \(destination.displayName)…"
        )
        defer { sendingDestination = nil }
        do {
            _ = try await externalAppIntegrationRepository.send(noteID: noteID, to: destination)
            guard !Task.isCancelled else { return }
            actionFeedback = ContentViewerActionFeedback(
                role: .success,
                message: "已发送到 \(destination.displayName)"
            )
        } catch {
            guard !Task.isCancelled else { return }
            actionFeedback = ContentViewerActionFeedback(
                role: .error,
                message: "发送到 \(destination.displayName) 失败：\(error.localizedDescription)"
            )
        }
    }

    /// 清空已由页面映射到 Toast 的事件，避免 Observation 重绘重复展示。
    func consumeActionFeedback() {
        actionFeedback = nil
    }

    /// 更新当前分页选择，并按需读取所选页详情，避免切页过程重复强刷新。
    func select(_ itemID: ContentViewerItemID) {
        guard itemID != selectedItemID else { return }
        selectedItemID = itemID
        Task { await loadDetailIfNeeded(itemID: itemID) }
    }

    /// 读取单页详情；命中缓存时可跳过，供分页切换和懒加载使用。
    func loadDetailIfNeeded(itemID: ContentViewerItemID) async {
        await loadDetail(itemID: itemID, forceRefresh: false)
    }

    /// 强制刷新单页详情，供从编辑页返回后的最新内容回填。
    func refreshDetail(itemID: ContentViewerItemID) async {
        await loadDetail(itemID: itemID, forceRefresh: true)
    }

    /// 删除当前页内容，按删除前索引回退到相邻页；若来源为空则请求退出查看器。
    func deleteCurrentItem() async {
        guard let selectedItemID else { return }
        isDeleting = true
        listErrorMessage = nil
        if let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) {
            pendingDeletedSelection = PendingDeletedSelection(
                deletedItemID: selectedItemID,
                deletedIndex: currentIndex
            )
        }

        do {
            try await repository.delete(itemID: selectedItemID)
            detailCache.removeValue(forKey: selectedItemID)
            detailErrorMessages.removeValue(forKey: selectedItemID)
            pruneDetailCache(around: self.selectedItemID)
        } catch {
            pendingDeletedSelection = nil
            listErrorMessage = "删除失败：\(error.localizedDescription)"
        }
        isDeleting = false
    }

    /// 返回指定分页项的详情缓存。
    func detail(for itemID: ContentViewerItemID) -> ContentViewerDetail? {
        detailCache[itemID]
    }

    /// 返回指定分页项的详情加载错误。
    func detailErrorMessage(for itemID: ContentViewerItemID) -> String? {
        detailErrorMessages[itemID]
    }

    /// 返回指定分页项是否处于详情加载中。
    func isLoadingDetail(for itemID: ContentViewerItemID) -> Bool {
        detailLoadingIDs.contains(itemID)
    }

    /// 预取当前页相邻内容详情，减少横向切页后的白屏等待。
    func prefetchDetails(around itemID: ContentViewerItemID, radius: Int) async {
        guard radius > 0 else { return }
        guard let anchorIndex = items.firstIndex(where: { $0.id == itemID }) else { return }

        let lower = max(0, anchorIndex - radius)
        let upper = min(items.count - 1, anchorIndex + radius)
        guard lower <= upper else { return }

        for index in lower...upper where index != anchorIndex {
            await loadDetailIfNeeded(itemID: items[index].id)
        }
    }
}

private extension ContentViewerViewModel {
    /// 观察关联应用配置变化；流在任务外创建，循环每次只短暂获取 weak self，避免 ViewModel/Task 强环。
    func startExternalAppObservation() {
        guard externalAppObservationTask == nil else { return }
        configuredExternalAppDestinations = Set(externalAppIntegrationRepository.configuredDestinations())
        let repository = externalAppIntegrationRepository
        let stream = repository.observeConfigurationChanges()
        externalAppObservationTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                self?.configuredExternalAppDestinations = Set(repository.configuredDestinations())
            }
        }
    }

    func applyObservedItems(_ newItems: [ContentViewerListItem]) {
        let previousItems = items
        let previousSelectedItemID = selectedItemID

        if hasAppliedInitialSelection,
           pendingDeletedSelection == nil,
           newItems == previousItems {
            isLoadingList = false
            if let previousSelectedItemID {
                Task { await refreshDetail(itemID: previousSelectedItemID) }
            }
            pruneDetailCache(around: previousSelectedItemID)
            return
        }

        items = newItems
        isLoadingList = false

        guard !newItems.isEmpty else {
            selectedItemID = nil
            detailCache.removeAll(keepingCapacity: false)
            detailLoadingIDs.removeAll(keepingCapacity: false)
            detailErrorMessages.removeAll(keepingCapacity: false)
            if hasAppliedInitialSelection || pendingDeletedSelection != nil {
                dismissalRequestToken &+= 1
            }
            pendingDeletedSelection = nil
            return
        }

        let resolvedSelection: ContentViewerItemID?
        if !hasAppliedInitialSelection {
            hasAppliedInitialSelection = true
            if let restoredSelectedItemID,
               newItems.contains(where: { $0.id == restoredSelectedItemID }) {
                resolvedSelection = restoredSelectedItemID
            } else if newItems.contains(where: { $0.id == initialItemID }) {
                resolvedSelection = initialItemID
            } else {
                resolvedSelection = newItems.first?.id
            }
        } else if let previousSelectedItemID, newItems.contains(where: { $0.id == previousSelectedItemID }) {
            resolvedSelection = previousSelectedItemID
        } else if let pendingDeletedSelection {
            let fallbackIndex = min(pendingDeletedSelection.deletedIndex, newItems.count - 1)
            resolvedSelection = newItems[max(0, fallbackIndex)].id
            if pendingDeletedSelection.deletedItemID == previousSelectedItemID {
                detailErrorMessages.removeValue(forKey: pendingDeletedSelection.deletedItemID)
            }
            self.pendingDeletedSelection = nil
        } else if
            let previousSelectedItemID,
            let previousIndex = previousItems.firstIndex(where: { $0.id == previousSelectedItemID })
        {
            resolvedSelection = newItems[min(previousIndex, newItems.count - 1)].id
        } else {
            resolvedSelection = newItems.first?.id
        }

        selectedItemID = resolvedSelection
        pruneDetailCache(around: resolvedSelection)
        if let resolvedSelection {
            Task { await refreshDetail(itemID: resolvedSelection) }
        }
    }

    func loadDetail(itemID: ContentViewerItemID, forceRefresh: Bool) async {
        if !forceRefresh, detailCache[itemID] != nil {
            return
        }
        guard !detailLoadingIDs.contains(itemID) else { return }

        detailLoadingIDs.insert(itemID)
        detailErrorMessages[itemID] = nil
        defer { detailLoadingIDs.remove(itemID) }

        do {
            guard let detail = try await repository.fetchViewerDetail(itemID: itemID) else {
                detailCache.removeValue(forKey: itemID)
                detailErrorMessages[itemID] = missingItemMessage
                pruneDetailCache(around: selectedItemID ?? itemID)
                return
            }
            detailCache[itemID] = detail
            pruneDetailCache(around: selectedItemID ?? itemID)
        } catch {
            detailErrorMessages[itemID] = "加载失败：\(error.localizedDescription)"
            pruneDetailCache(around: selectedItemID ?? itemID)
        }
    }

    /// 维持详情缓存有界：保留当前选中页邻域，裁剪超出窗口与超出上限的数据。
    func pruneDetailCache(around anchorID: ContentViewerItemID?) {
        let validItemIDs = Set(items.map(\.id))
        detailCache = detailCache.filter { validItemIDs.contains($0.key) }
        detailErrorMessages = detailErrorMessages.filter { validItemIDs.contains($0.key) }
        detailLoadingIDs = Set(detailLoadingIDs.filter { validItemIDs.contains($0) })

        guard detailCache.count > CachePolicy.maxEntries else { return }

        let removableIDs: [ContentViewerItemID]
        if let anchorID,
           let anchorIndex = items.firstIndex(where: { $0.id == anchorID }) {
            let lowerBound = max(0, anchorIndex - CachePolicy.keepRadius)
            let upperBound = min(items.count - 1, anchorIndex + CachePolicy.keepRadius)
            let protectedIDs = Set(items[lowerBound...upperBound].map(\.id))
            let indexMap = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })

            removableIDs = detailCache.keys
                .filter { !protectedIDs.contains($0) }
                .sorted { lhs, rhs in
                    let lhsDistance = indexMap[lhs].map { abs($0 - anchorIndex) } ?? .max
                    let rhsDistance = indexMap[rhs].map { abs($0 - anchorIndex) } ?? .max
                    return lhsDistance > rhsDistance
                }
        } else {
            removableIDs = Array(detailCache.keys)
        }

        var overflow = detailCache.count - CachePolicy.maxEntries
        guard overflow > 0 else { return }

        for id in removableIDs where overflow > 0 {
            detailCache.removeValue(forKey: id)
            detailErrorMessages.removeValue(forKey: id)
            overflow -= 1
        }
    }
}
