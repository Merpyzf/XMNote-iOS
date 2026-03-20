/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 提供 viewer feed、详情读取与硬删除事务
 * [OUTPUT]: 对外提供 ContentViewerViewModel，驱动通用内容查看器的分页、详情缓存与删除流程
 * [POS]: Content 模块查看页状态中枢，负责时间线/书籍详情来源的统一内容查看体验
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

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
    var listErrorMessage: String?
    private(set) var dismissalRequestToken: Int = 0

    private var detailCache: [ContentViewerItemID: ContentViewerDetail] = [:]
    private var detailLoadingIDs: Set<ContentViewerItemID> = []
    private var detailErrorMessages: [ContentViewerItemID: String] = [:]
    private var hasAppliedInitialSelection = false
    private var pendingDeletedSelection: PendingDeletedSelection?
    private var listObservationTask: Task<Void, Never>?
    private let restoredSelectedItemID: ContentViewerItemID?

    private let initialItemID: ContentViewerItemID
    private let defaultTitle: String
    private let missingItemMessage: String
    private let repository: any ContentRepositoryProtocol

    /// 注入 viewer 来源、初始项与仓储，建立分页状态初始化上下文。
    init(
        source: ContentViewerSourceContext,
        initialItemID: ContentViewerItemID,
        restoredSelectedItemID: ContentViewerItemID? = nil,
        keyword: String,
        defaultTitle: String,
        missingItemMessage: String,
        repository: any ContentRepositoryProtocol
    ) {
        self.source = source
        self.initialItemID = initialItemID
        self.restoredSelectedItemID = restoredSelectedItemID
        self.keyword = keyword
        self.defaultTitle = defaultTitle
        self.missingItemMessage = missingItemMessage
        self.repository = repository
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

        listObservationTask = Task { [weak self] in
            do {
                for try await observedItems in repository.observeViewerItems(source: source) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self else { return }
                        self.listErrorMessage = nil
                        self.applyObservedItems(observedItems)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.isLoadingList = false
                    if self.items.isEmpty {
                        self.listErrorMessage = "加载失败：\(error.localizedDescription)"
                    }
                }
            }
        }
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
