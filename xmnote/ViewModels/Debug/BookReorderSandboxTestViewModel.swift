#if DEBUG
/**
 * [INPUT]: 依赖 Foundation/Observation 管理书架手动排序 DEBUG 样本、拖拽状态与模拟写入日志
 * [OUTPUT]: 对外提供 BookReorderSandboxTestViewModel 及书架排序沙盒模型，供测试中心验证 Android 首页书籍管理迁移风险
 * [POS]: Debug 模块书架手动排序验证状态中枢，只操作内存样本，不读写真实 Book 表
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreGraphics
import Foundation
import Observation

/// 书架排序沙盒状态中枢，复现 Android 首页书架高风险交互的最小事实闭环。
@MainActor
@Observable
final class BookReorderSandboxTestViewModel {
    enum SortMode: String, CaseIterable, Identifiable {
        case custom
        case createdDate
        case noteCount

        var id: String { rawValue }

        var title: String {
            switch self {
            case .custom:
                return "手动"
            case .createdDate:
                return "创建"
            case .noteCount:
                return "书摘"
            }
        }
    }

    enum ItemKind: String, Hashable {
        case book
        case group

        var title: String {
            switch self {
            case .book:
                return "书籍"
            case .group:
                return "分组"
            }
        }
    }

    struct SandboxItem: Identifiable, Hashable {
        let id: Int64
        let kind: ItemKind
        var title: String
        var subtitle: String
        var coverURL: String
        var coverTone: Int
        var groupCoverTones: [Int]
        var noteCount: Int
        var createdSequence: Int
        var customOrder: Int
        var isPinned: Bool
        var pinOrder: Int

        var isMovable: Bool {
            !isPinned
        }

        var displaySubtitle: String {
            switch kind {
            case .book:
                return subtitle
            case .group:
                return "\(subtitle) | \(noteCount) 本"
            }
        }
    }

    struct OrderLogEntry: Identifiable, Hashable {
        let id: Int
        let message: String
    }

    var items: [SandboxItem] = BookReorderSandboxTestViewModel.makeSampleItems()
    var isEditMode = true {
        didSet {
            if !isEditMode {
                endDrag(cancelled: true)
            }
        }
    }
    var sortMode: SortMode = .custom {
        didSet {
            if sortMode != .custom {
                endDrag(cancelled: true)
            }
        }
    }
    var columnCount = 3
    var searchText = "" {
        didSet {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                endDrag(cancelled: true)
            }
        }
    }
    var draggedItemID: Int64?
    var dragTargetItemID: Int64?
    var dragLocation: CGPoint?
    var feedbackTick = 0
    private(set) var orderLog: [OrderLogEntry] = [
        OrderLogEntry(id: 1, message: "等待操作：当前为 DEBUG 内存样本，不会写入真实 Book 表。")
    ]

    private var nextLogID = 2
    private var originalItemsBeforeDrag: [SandboxItem] = []
    private var lastBlockedTargetID: Int64?

    var displayedItems: [SandboxItem] {
        let sorted = sortedItems(for: sortMode)
        let keyword = normalizedSearchText
        guard !keyword.isEmpty else { return sorted }
        return sorted.filter { item in
            item.title.localizedCaseInsensitiveContains(keyword)
                || item.subtitle.localizedCaseInsensitiveContains(keyword)
                || item.kind.title.localizedCaseInsensitiveContains(keyword)
        }
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var dragDisabledReason: String? {
        if !isEditMode {
            return "当前不是编辑态，拖拽入口关闭。"
        }
        if sortMode != .custom {
            return "当前排序不是手动排序，拖拽会破坏用户对排序规则的预期。"
        }
        if !normalizedSearchText.isEmpty {
            return "搜索过滤态只展示子集，直接重排会让落盘顺序产生歧义。"
        }
        return nil
    }

    var isDragAvailable: Bool {
        dragDisabledReason == nil
    }

    var orderedSummary: String {
        sortedItems(for: .custom)
            .enumerated()
            .map { index, item in
                let pin = item.isPinned ? " 置顶" : ""
                return "\(index + 1). \(item.title)\(pin)"
            }
            .joined(separator: "\n")
    }

    var migrationRiskSummary: [String] {
        [
            "LazyVGrid 没有 List.onMove 同级的系统重排入口，需要自建网格命中与占位反馈。",
            "Android 置顶项参与展示但不可被普通书拖入；iOS 迁移必须保留这个边界。",
            "搜索过滤态不应落盘排序，生产实现需要禁用拖拽或先退出过滤。",
            "生产写入应由 Repository 一次性提交 orderedIDs，失败时回滚 UI 快照。"
        ]
    }

    /// 重置全部沙盒输入，便于重复验证跨行拖拽与禁用态。
    func reset() {
        items = Self.makeSampleItems()
        isEditMode = true
        sortMode = .custom
        columnCount = 3
        searchText = ""
        endDrag(cancelled: true)
        appendLog("已重置 DEBUG 样本顺序。")
    }

    /// 进入拖拽会话，记录原始顺序用于取消或失败回滚演示。
    func beginDrag(itemID: Int64) {
        guard draggedItemID == nil || draggedItemID == itemID else { return }
        guard isDragAvailable else {
            appendLog(dragDisabledReason ?? "当前状态不允许拖拽。")
            return
        }
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        guard item.isMovable else {
            appendLog("置顶项「\(item.title)」不可直接拖拽。")
            return
        }

        draggedItemID = itemID
        dragTargetItemID = itemID
        originalItemsBeforeDrag = items
        lastBlockedTargetID = nil
        feedbackTick += 1
        appendLog("开始拖拽「\(item.title)」。")
    }

    /// 根据当前指针位置更新目标项，并实时预览内存顺序。
    func updateDrag(itemID: Int64, location: CGPoint, itemFrames: [Int64: CGRect]) {
        guard draggedItemID == itemID else { return }
        dragLocation = location
        guard let targetID = targetItemID(at: location, itemFrames: itemFrames) else { return }
        guard targetID != itemID else {
            dragTargetItemID = targetID
            return
        }
        moveDraggedItem(itemID, over: targetID)
    }

    /// 结束拖拽会话，模拟一次 Repository 写入提交。
    func endDrag(itemID: Int64? = nil, cancelled: Bool = false) {
        guard let draggedItemID else { return }
        guard itemID == nil || itemID == draggedItemID else { return }

        let draggedTitle = items.first(where: { $0.id == draggedItemID })?.title ?? "未知书籍"
        if cancelled {
            if !originalItemsBeforeDrag.isEmpty {
                items = originalItemsBeforeDrag
            }
            appendLog("已取消「\(draggedTitle)」拖拽并回滚内存快照。")
        } else {
            renumberCustomOrder()
            appendLog("模拟写入成功：已按当前网格顺序更新 custom order。")
        }

        self.draggedItemID = nil
        dragTargetItemID = nil
        dragLocation = nil
        originalItemsBeforeDrag = []
        lastBlockedTargetID = nil
        feedbackTick += 1
    }
}

private extension BookReorderSandboxTestViewModel {
    func sortedItems(for mode: SortMode) -> [SandboxItem] {
        let pinnedItems = items
            .filter(\.isPinned)
            .sorted { $0.pinOrder > $1.pinOrder }
        let normalItems = items.filter { !$0.isPinned }

        switch mode {
        case .custom:
            return pinnedItems + normalItems.sorted { $0.customOrder < $1.customOrder }
        case .createdDate:
            return pinnedItems + normalItems.sorted { $0.createdSequence > $1.createdSequence }
        case .noteCount:
            return pinnedItems + normalItems.sorted { $0.noteCount > $1.noteCount }
        }
    }

    func moveDraggedItem(_ draggedID: Int64, over targetID: Int64) {
        guard let draggedIndex = items.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let targetItem = items[targetIndex]
        guard targetItem.isMovable else {
            if lastBlockedTargetID != targetID {
                appendLog("已阻止拖入置顶区：目标「\(targetItem.title)」为置顶项。")
                lastBlockedTargetID = targetID
            }
            return
        }

        var reordered = items
        let isMovingDown = draggedIndex < targetIndex
        let dragged = reordered.remove(at: draggedIndex)
        guard let currentTargetIndex = reordered.firstIndex(where: { $0.id == targetID }) else { return }
        let insertionIndex = isMovingDown ? min(currentTargetIndex + 1, reordered.endIndex) : currentTargetIndex
        reordered.insert(dragged, at: insertionIndex)
        items = reordered
        renumberCustomOrder()
        dragTargetItemID = targetID
        lastBlockedTargetID = nil
        feedbackTick += 1
    }

    func renumberCustomOrder() {
        var nextOrder = 0
        for index in items.indices where !items[index].isPinned {
            items[index].customOrder = nextOrder
            nextOrder += 1
        }
    }

    func targetItemID(at location: CGPoint, itemFrames: [Int64: CGRect]) -> Int64? {
        if let directHit = itemFrames.first(where: { $0.value.contains(location) }) {
            return directHit.key
        }

        return itemFrames
            .min { lhs, rhs in
                lhs.value.centerDistance(to: location) < rhs.value.centerDistance(to: location)
            }?
            .key
    }

    func appendLog(_ message: String) {
        orderLog.insert(OrderLogEntry(id: nextLogID, message: message), at: 0)
        nextLogID += 1
        if orderLog.count > 8 {
            orderLog.removeLast(orderLog.count - 8)
        }
    }

    static func makeSampleItems() -> [SandboxItem] {
        [
            SandboxItem(
                id: 101,
                kind: .book,
                title: "置顶：人类简史",
                subtitle: "尤瓦尔·赫拉利",
                coverURL: "",
                coverTone: 0,
                groupCoverTones: [],
                noteCount: 42,
                createdSequence: 8,
                customOrder: 0,
                isPinned: true,
                pinOrder: 2
            ),
            SandboxItem(
                id: 102,
                kind: .group,
                title: "置顶：年度阅读",
                subtitle: "2026 计划",
                coverURL: "",
                coverTone: 1,
                groupCoverTones: [1, 2, 3, 4],
                noteCount: 6,
                createdSequence: 7,
                customOrder: 1,
                isPinned: true,
                pinOrder: 1
            ),
            SandboxItem(
                id: 201,
                kind: .book,
                title: "长标题验证：从 Android 书架到 iOS 原生体验迁移笔记",
                subtitle: "迁移样本",
                coverURL: "",
                coverTone: 2,
                groupCoverTones: [],
                noteCount: 18,
                createdSequence: 6,
                customOrder: 2,
                isPinned: false,
                pinOrder: 0
            ),
            SandboxItem(
                id: 202,
                kind: .book,
                title: "空封面样本",
                subtitle: "占位图验证",
                coverURL: "",
                coverTone: 3,
                groupCoverTones: [],
                noteCount: 0,
                createdSequence: 5,
                customOrder: 3,
                isPinned: false,
                pinOrder: 0
            ),
            SandboxItem(
                id: 203,
                kind: .group,
                title: "分组：技术阅读",
                subtitle: "SwiftUI / Compose",
                coverURL: "",
                coverTone: 4,
                groupCoverTones: [0, 3, 5, 2],
                noteCount: 4,
                createdSequence: 4,
                customOrder: 4,
                isPinned: false,
                pinOrder: 0
            ),
            SandboxItem(
                id: 204,
                kind: .book,
                title: "设计心理学",
                subtitle: "Donald Norman",
                coverURL: "",
                coverTone: 5,
                groupCoverTones: [],
                noteCount: 11,
                createdSequence: 3,
                customOrder: 5,
                isPinned: false,
                pinOrder: 0
            ),
            SandboxItem(
                id: 205,
                kind: .book,
                title: "禅与摩托车维修艺术",
                subtitle: "Robert M. Pirsig",
                coverURL: "",
                coverTone: 6,
                groupCoverTones: [],
                noteCount: 7,
                createdSequence: 2,
                customOrder: 6,
                isPinned: false,
                pinOrder: 0
            ),
            SandboxItem(
                id: 206,
                kind: .book,
                title: "Swift 并发实践",
                subtitle: "Actor / Task",
                coverURL: "",
                coverTone: 7,
                groupCoverTones: [],
                noteCount: 25,
                createdSequence: 1,
                customOrder: 7,
                isPinned: false,
                pinOrder: 0
            )
        ]
    }
}

private extension CGRect {
    func centerDistance(to point: CGPoint) -> CGFloat {
        let dx = midX - point.x
        let dy = midY - point.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
#endif
