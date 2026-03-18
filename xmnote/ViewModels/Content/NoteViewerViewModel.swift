/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 提供书摘 feed、详情读取与硬删除事务
 * [OUTPUT]: 对外提供 NoteViewerViewModel，驱动书摘全屏查看的分页、详情缓存与删除流程
 * [POS]: Content 模块书摘查看状态源，承接时间线与书籍详情进入的全屏书摘阅读体验
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

@MainActor
@Observable
/// 书摘全屏查看状态源，负责 note-only feed 订阅、分页选择和删除后的相邻项回退。
final class NoteViewerViewModel {
    private struct PendingDeletedSelection {
        let deletedNoteID: Int64
        let deletedIndex: Int
    }

    let source: ContentViewerSourceContext

    var items: [ContentViewerListItem] = []
    var selectedNoteID: Int64?
    var isLoadingList = false
    var isDeleting = false
    var listErrorMessage: String?
    private(set) var dismissalRequestToken: Int = 0

    private var detailCache: [Int64: NoteContentDetail] = [:]
    private var detailLoadingIDs: Set<Int64> = []
    private var detailErrorMessages: [Int64: String] = [:]
    private var hasAppliedInitialSelection = false
    private var pendingDeletedSelection: PendingDeletedSelection?
    private var listObservationTask: Task<Void, Never>?

    private let initialNoteID: Int64
    private let repository: any ContentRepositoryProtocol

    /// 注入书摘来源、初始书摘 ID 与仓储，建立全屏查看上下文。
    init(
        source: ContentViewerSourceContext,
        initialNoteID: Int64,
        repository: any ContentRepositoryProtocol
    ) {
        self.source = source
        self.initialNoteID = initialNoteID
        self.repository = repository
    }

    var selectedListItem: ContentViewerListItem? {
        guard let selectedNoteID else { return nil }
        return items.first(where: { $0.id == .note(selectedNoteID) })
    }

    var selectedDetail: NoteContentDetail? {
        guard let selectedNoteID else { return nil }
        return detailCache[selectedNoteID]
    }

    var selectedBookTitle: String {
        selectedDetail?.bookTitle ?? selectedListItem?.bookTitle ?? "书摘"
    }

    var selectedBookID: Int64? {
        selectedDetail?.sourceBookId ?? selectedListItem?.sourceBookId
    }

    var selectedPageProgress: ContentViewerPageProgress? {
        guard items.count > 1 else { return nil }
        guard
            let selectedNoteID,
            let selectedIndex = items.firstIndex(where: { $0.id == .note(selectedNoteID) })
        else {
            return ContentViewerPageProgress(current: 1, total: items.count)
        }
        return ContentViewerPageProgress(current: selectedIndex + 1, total: items.count)
    }

    var selectedTagNames: [String] {
        selectedDetail?.tagNames ?? []
    }

    /// 启动书摘列表观察，仅接受 note feed，避免混入书评与相关内容。
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

    /// 切换当前书摘页并主动刷新详情，保证从编辑页返回后内容同步。
    func select(_ noteID: Int64) {
        guard noteID != selectedNoteID else { return }
        selectedNoteID = noteID
        Task { await refreshDetail(noteID: noteID) }
    }

    /// 按需读取当前书摘详情。
    func loadDetailIfNeeded(noteID: Int64) async {
        await loadDetail(noteID: noteID, forceRefresh: false)
    }

    /// 强制刷新当前书摘详情。
    func refreshDetail(noteID: Int64) async {
        await loadDetail(noteID: noteID, forceRefresh: true)
    }

    /// 删除当前书摘并按删除前位置回退到相邻项；若已无内容则请求退出。
    func deleteCurrentNote() async {
        guard let selectedNoteID else { return }
        isDeleting = true
        listErrorMessage = nil

        if let currentIndex = items.firstIndex(where: { $0.id == .note(selectedNoteID) }) {
            pendingDeletedSelection = PendingDeletedSelection(
                deletedNoteID: selectedNoteID,
                deletedIndex: currentIndex
            )
        }

        do {
            try await repository.delete(itemID: .note(selectedNoteID))
            detailCache.removeValue(forKey: selectedNoteID)
            detailErrorMessages.removeValue(forKey: selectedNoteID)
        } catch {
            pendingDeletedSelection = nil
            listErrorMessage = "删除失败：\(error.localizedDescription)"
        }

        isDeleting = false
    }

    /// 返回指定书摘的详情缓存。
    func detail(for noteID: Int64) -> NoteContentDetail? {
        detailCache[noteID]
    }

    /// 返回指定书摘的详情加载错误。
    func detailErrorMessage(for noteID: Int64) -> String? {
        detailErrorMessages[noteID]
    }

    /// 返回当前选中书摘附近的窗口化列表，用于横向 pager 懒挂载。
    func visibleNoteItems(radius: Int) -> [ContentViewerListItem] {
        guard !items.isEmpty else { return [] }

        let resolvedRadius = max(0, radius)
        let anchorNoteID = selectedNoteID ?? items.first?.noteID
        guard
            let anchorNoteID,
            let anchorIndex = items.firstIndex(where: { $0.id == .note(anchorNoteID) })
        else {
            let upperBound = min(items.count, resolvedRadius * 2 + 1)
            return Array(items.prefix(upperBound))
        }

        let lower = max(0, anchorIndex - resolvedRadius)
        let upper = min(items.count - 1, anchorIndex + resolvedRadius)
        return Array(items[lower...upper])
    }

    /// 预取当前页相邻书摘详情，减少横向切页后的白屏等待。
    func prefetchDetails(around noteID: Int64, radius: Int) async {
        guard radius > 0 else { return }
        guard let anchorIndex = items.firstIndex(where: { $0.id == .note(noteID) }) else { return }

        let lower = max(0, anchorIndex - radius)
        let upper = min(items.count - 1, anchorIndex + radius)
        guard lower <= upper else { return }

        for index in lower...upper where index != anchorIndex {
            await loadDetailIfNeeded(noteID: items[index].noteID)
        }
    }
}

private extension NoteViewerViewModel {
    func applyObservedItems(_ observedItems: [ContentViewerListItem]) {
        let noteItems = observedItems.filter { item in
            if case .note = item.id {
                return true
            }
            return false
        }

        let previousItems = items
        let previousSelectedNoteID = selectedNoteID

        items = noteItems
        isLoadingList = false

        guard !noteItems.isEmpty else {
            selectedNoteID = nil
            if hasAppliedInitialSelection || pendingDeletedSelection != nil {
                dismissalRequestToken &+= 1
            }
            pendingDeletedSelection = nil
            return
        }

        let resolvedSelection: Int64?
        if !hasAppliedInitialSelection {
            hasAppliedInitialSelection = true
            if noteItems.contains(where: { $0.id == .note(initialNoteID) }) {
                resolvedSelection = initialNoteID
            } else {
                resolvedSelection = noteItems.first?.noteID
            }
        } else if let previousSelectedNoteID, noteItems.contains(where: { $0.id == .note(previousSelectedNoteID) }) {
            resolvedSelection = previousSelectedNoteID
        } else if let pendingDeletedSelection {
            let fallbackIndex = min(pendingDeletedSelection.deletedIndex, noteItems.count - 1)
            resolvedSelection = noteItems[max(0, fallbackIndex)].noteID
            detailErrorMessages.removeValue(forKey: pendingDeletedSelection.deletedNoteID)
            self.pendingDeletedSelection = nil
        } else if
            let previousSelectedNoteID,
            let previousIndex = previousItems.firstIndex(where: { $0.id == .note(previousSelectedNoteID) })
        {
            resolvedSelection = noteItems[min(previousIndex, noteItems.count - 1)].noteID
        } else {
            resolvedSelection = noteItems.first?.noteID
        }

        selectedNoteID = resolvedSelection
        if let resolvedSelection {
            Task { await refreshDetail(noteID: resolvedSelection) }
        }
    }

    func loadDetail(noteID: Int64, forceRefresh: Bool) async {
        if !forceRefresh, detailCache[noteID] != nil {
            return
        }
        guard !detailLoadingIDs.contains(noteID) else { return }

        detailLoadingIDs.insert(noteID)
        detailErrorMessages[noteID] = nil
        defer { detailLoadingIDs.remove(noteID) }

        do {
            guard let detail = try await repository.fetchViewerDetail(itemID: .note(noteID)) else {
                detailCache.removeValue(forKey: noteID)
                detailErrorMessages[noteID] = "书摘不存在或已删除"
                return
            }
            guard case .note(let noteDetail) = detail else {
                detailCache.removeValue(forKey: noteID)
                detailErrorMessages[noteID] = "书摘数据类型不匹配"
                return
            }
            detailCache[noteID] = noteDetail
        } catch {
            detailErrorMessages[noteID] = "加载失败：\(error.localizedDescription)"
        }
    }
}

extension ContentViewerListItem {
    var noteID: Int64 {
        switch id {
        case .note(let noteID):
            noteID
        case .review, .relevant:
            0
        }
    }
}
