import CoreGraphics
import Foundation

/**
 * [INPUT]: 依赖 BookshelfItem/BookshelfItemID 与 CoreGraphics 几何数据描述默认书架拖拽排序会话
 * [OUTPUT]: 对外提供 BookshelfReorderSession、BookshelfReorderPolicy、BookshelfReorderDropTarget 与滚动快照，供 BookViewModel/BookGridView 共享排序交互状态
 * [POS]: Book ViewModel 模块的拖拽排序状态基础设施，只管理内存会话与几何计算，不直接执行 Repository 写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 默认书架拖拽排序布局类型，用于在同一会话中区分网格与列表命中规则。
enum BookshelfReorderLayout: Hashable, Sendable {
    case grid
    case list
}

/// 默认书架拖拽排序更新来源，用于区分手势主动更新与滚动几何回补更新的落点清理策略。
enum BookshelfReorderUpdateSource: Hashable, Sendable {
    case gesture
    case scrollGeometry

    var preservesDropTargetOnMiss: Bool {
        self == .scrollGeometry
    }
}

/// 默认书架拖拽排序插入方向，用于把命中项转换为确定的数组插入位置。
enum BookshelfReorderDropPlacement: Equatable {
    case before
    case after
}

/// 默认书架拖拽排序落点，记录目标项、插入方向和移除拖拽项后的稳定插入槽位。
struct BookshelfReorderDropTarget: Equatable {
    let itemID: BookshelfItemID
    let placement: BookshelfReorderDropPlacement
    let insertionIndex: Int
}

/// 默认书架拖拽排序策略，集中表达 Android 对齐边界，避免入口分散判断。
struct BookshelfReorderPolicy: Equatable {
    let isEditing: Bool
    let selectedDimension: BookshelfDimension
    let sortMode: BookshelfSortMode
    let hasSearchKeyword: Bool
    let activeWriteAction: BookshelfPendingAction?
    let contentState: BookshelfContentState

    /// 当前页面状态是否允许进入默认书架手动排序会话。
    var isEnabled: Bool {
        isEditing
            && selectedDimension == .default
            && sortMode == .custom
            && !hasSearchKeyword
            && activeWriteAction == nil
            && contentState == .content
    }

    /// 返回当前禁用原因，供 UI 与测试验证排序入口边界。
    var disabledReason: String? {
        if !isEditing {
            return "当前不是编辑态，无法拖拽排序"
        }
        if selectedDimension != .default {
            return "仅默认书架支持拖拽排序"
        }
        if sortMode != .custom {
            return "仅手动排序支持拖拽调整"
        }
        if hasSearchKeyword {
            return "搜索结果不支持排序，清除搜索后可调整书架顺序"
        }
        if activeWriteAction != nil {
            return "当前操作完成后才能继续排序"
        }
        if contentState != .content {
            return "书架内容加载完成后才能排序"
        }
        return nil
    }

    /// 判断指定书架项是否允许作为拖拽起点，置顶项保持 Android 普通排序边界。
    func canStartReorder(item: BookshelfItem?) -> Bool {
        isEnabled && item?.pinned == false
    }
}

/// 默认书架 ScrollView 几何快照，用于拖拽到边缘时计算自动滚动速度。
struct BookshelfReorderScrollSnapshot: Equatable, Sendable {
    static let zero = BookshelfReorderScrollSnapshot()

    var contentOffsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    var maxOffsetY: CGFloat {
        max(contentHeight - viewportHeight, 0)
    }

    /// 将滚动增量约束在当前内容范围内，避免自动滚动越界。
    func nextOffsetY(delta: CGFloat) -> CGFloat {
        min(max(contentOffsetY + delta, 0), maxOffsetY)
    }
}

/// 默认书架拖拽浮层状态，记录原始尺寸和当前中心点以驱动跟手视觉。
struct BookshelfReorderOverlayState: Equatable {
    let itemID: BookshelfItemID
    let frame: CGRect
    let center: CGPoint

    var size: CGSize {
        frame.size
    }
}

/// 默认书架拖拽排序会话，封装起点快照、拖拽位置、命中目标与自动滚动计算。
struct BookshelfReorderSession: Equatable {
    private(set) var draggedItemID: BookshelfItemID?
    private(set) var dragTargetItemID: BookshelfItemID?
    private(set) var dragLocation: CGPoint?
    private(set) var originalItems: [BookshelfItem] = []

    private var originalFrame: CGRect?
    private var fingerToCenterOffset: CGSize = .zero
    private var lastDropTarget: BookshelfReorderDropTarget?

    var isActive: Bool {
        draggedItemID != nil
    }

    var overlayState: BookshelfReorderOverlayState? {
        guard let draggedItemID,
              let dragLocation,
              let originalFrame else {
            return nil
        }
        let center = CGPoint(
            x: dragLocation.x + fingerToCenterOffset.width,
            y: dragLocation.y + fingerToCenterOffset.height
        )
        return BookshelfReorderOverlayState(
            itemID: draggedItemID,
            frame: originalFrame,
            center: center
        )
    }

    /// 开始拖拽会话，记录拖拽前完整顺序与手指相对卡片中心的偏移。
    mutating func begin(
        item: BookshelfItem,
        items: [BookshelfItem],
        location: CGPoint,
        itemFrames: [BookshelfItemID: CGRect]
    ) -> Bool {
        guard draggedItemID == nil,
              let frame = itemFrames[item.id],
              !item.pinned else {
            return false
        }

        draggedItemID = item.id
        dragTargetItemID = item.id
        dragLocation = location
        originalItems = items
        originalFrame = frame
        fingerToCenterOffset = CGSize(
            width: frame.midX - location.x,
            height: frame.midY - location.y
        )
        lastDropTarget = nil
        return true
    }

    /// 更新当前手指位置，拖拽视图通过 overlayState 派生跟手坐标。
    mutating func updateLocation(_ location: CGPoint) {
        guard isActive else { return }
        guard dragLocation != location else { return }
        dragLocation = location
    }

    /// 根据当前布局和 item frame 计算稳定插入槽位；命中点应使用浮层中心而不是手指位置。
    func dropTarget(
        at hitPoint: CGPoint,
        layout: BookshelfReorderLayout,
        itemFrames: [BookshelfItemID: CGRect],
        items: [BookshelfItem]
    ) -> BookshelfReorderDropTarget? {
        guard let draggedItemID,
              let draggedIndex = items.firstIndex(where: { $0.id == draggedItemID }) else {
            return nil
        }
        let candidates = orderedCandidates(
            draggedItemID: draggedItemID,
            itemFrames: itemFrames,
            items: items
        )
        guard let slot = insertionSlot(
            at: hitPoint,
            layout: layout,
            candidates: candidates
        ) else {
            return nil
        }
        guard let dropTarget = makeDropTarget(
            candidate: slot.candidate,
            placement: slot.placement,
            draggedIndex: draggedIndex
        ) else {
            return nil
        }
        return stabilizedDropTarget(
            dropTarget,
            at: hitPoint,
            layout: layout,
            candidates: candidates
        )
    }

    /// 记录新的落点；同一插入槽位重复进入时返回 false，减少热路径状态更新。
    mutating func setDropTarget(_ dropTarget: BookshelfReorderDropTarget) -> Bool {
        guard lastDropTarget?.insertionIndex != dropTarget.insertionIndex else { return false }
        dragTargetItemID = dropTarget.itemID
        lastDropTarget = dropTarget
        return true
    }

    /// 清理当前落点高亮；滚动几何短暂缺帧时可保留当前目标，等待下一帧稳定后再更新。
    mutating func clearDropTarget(preservingCurrentTarget: Bool = false) {
        guard !preservingCurrentTarget else { return }
        guard dragTargetItemID != draggedItemID || lastDropTarget != nil else { return }
        dragTargetItemID = draggedItemID
        lastDropTarget = nil
    }

    /// 取消或完成拖拽会话，清理全部临时几何状态。
    mutating func reset() {
        draggedItemID = nil
        dragTargetItemID = nil
        dragLocation = nil
        originalItems = []
        originalFrame = nil
        fingerToCenterOffset = .zero
        lastDropTarget = nil
    }

    /// 根据当前手指位置和滚动快照计算自动滚动增量；返回 0 表示不滚动。
    static func autoScrollDelta(
        locationY: CGFloat,
        scrollSnapshot: BookshelfReorderScrollSnapshot,
        edgeZone: CGFloat = 72,
        minimumSpeed: CGFloat = 3,
        maximumSpeed: CGFloat = 18
    ) -> CGFloat {
        guard scrollSnapshot.viewportHeight > edgeZone * 2,
              scrollSnapshot.contentHeight > scrollSnapshot.viewportHeight else {
            return 0
        }

        if locationY < edgeZone, scrollSnapshot.contentOffsetY > 0 {
            let ratio = min(max((edgeZone - locationY) / edgeZone, 0), 1)
            let speed = minimumSpeed + (maximumSpeed - minimumSpeed) * ratio
            return -min(speed, scrollSnapshot.contentOffsetY)
        }

        if locationY > scrollSnapshot.viewportHeight - edgeZone,
           scrollSnapshot.contentOffsetY < scrollSnapshot.maxOffsetY {
            let distance = locationY - (scrollSnapshot.viewportHeight - edgeZone)
            let ratio = min(max(distance / edgeZone, 0), 1)
            let speed = minimumSpeed + (maximumSpeed - minimumSpeed) * ratio
            return min(speed, scrollSnapshot.maxOffsetY - scrollSnapshot.contentOffsetY)
        }

        return 0
    }

    /// 按当前数据顺序生成可移动候选，避免字典遍历顺序影响命中结果。
    private func orderedCandidates(
        draggedItemID: BookshelfItemID,
        itemFrames: [BookshelfItemID: CGRect],
        items: [BookshelfItem]
    ) -> [BookshelfReorderCandidate] {
        items.enumerated().compactMap { index, item in
            guard !item.pinned,
                  item.id != draggedItemID,
                  let frame = itemFrames[item.id] else {
                return nil
            }
            return BookshelfReorderCandidate(
                itemID: item.id,
                index: index,
                frame: frame
            )
        }
    }

    /// 根据布局选择稳定插入槽位，避免当前顺序变化后同一命中点反复翻转。
    private func insertionSlot(
        at hitPoint: CGPoint,
        layout: BookshelfReorderLayout,
        candidates: [BookshelfReorderCandidate]
    ) -> BookshelfReorderSlot? {
        guard !candidates.isEmpty else { return nil }
        switch layout {
        case .grid:
            return gridInsertionSlot(at: hitPoint, candidates: candidates)
        case .list:
            return listInsertionSlot(at: hitPoint, candidates: candidates)
        }
    }

    /// 列表模式按行中线确定插入槽位；同一个物理槽位不会受拖拽项当前 index 变化影响。
    private func listInsertionSlot(
        at hitPoint: CGPoint,
        candidates: [BookshelfReorderCandidate]
    ) -> BookshelfReorderSlot? {
        let orderedCandidates = candidates.sortedByDataOrder()
        for candidate in orderedCandidates {
            if hitPoint.y < candidate.frame.midY {
                return BookshelfReorderSlot(candidate: candidate, placement: .before)
            }
        }
        guard let lastCandidate = orderedCandidates.last else { return nil }
        return BookshelfReorderSlot(candidate: lastCandidate, placement: .after)
    }

    /// 网格模式先确定目标行，再用同一行的 X 中线确定插入槽位。
    private func gridInsertionSlot(
        at hitPoint: CGPoint,
        candidates: [BookshelfReorderCandidate]
    ) -> BookshelfReorderSlot? {
        let rows = BookshelfReorderGridRow.makeRows(from: candidates)
        guard let row = targetGridRow(at: hitPoint, rows: rows) else { return nil }
        for candidate in row.candidates {
            if hitPoint.x < candidate.frame.midX {
                return BookshelfReorderSlot(candidate: candidate, placement: .before)
            }
        }
        guard let lastCandidate = row.candidates.last else { return nil }
        return BookshelfReorderSlot(candidate: lastCandidate, placement: .after)
    }

    /// 根据 Y 轴距离选择目标行，超出首尾时固定在首尾行，保持行优先排序语义。
    private func targetGridRow(
        at hitPoint: CGPoint,
        rows: [BookshelfReorderGridRow]
    ) -> BookshelfReorderGridRow? {
        guard let firstRow = rows.first,
              let lastRow = rows.last else {
            return nil
        }
        if hitPoint.y <= firstRow.midY {
            return firstRow
        }
        if hitPoint.y >= lastRow.midY {
            return lastRow
        }
        return rows.min { lhs, rhs in
            abs(lhs.midY - hitPoint.y) < abs(rhs.midY - hitPoint.y)
        }
    }

    /// 在中线附近保留上一槽位，防止用户手指停在边界时来回反复换位。
    private func stabilizedDropTarget(
        _ dropTarget: BookshelfReorderDropTarget,
        at hitPoint: CGPoint,
        layout: BookshelfReorderLayout,
        candidates: [BookshelfReorderCandidate],
        hysteresis: CGFloat = 8
    ) -> BookshelfReorderDropTarget {
        guard let lastDropTarget,
              lastDropTarget.insertionIndex != dropTarget.insertionIndex,
              candidates.contains(where: { $0.itemID == lastDropTarget.itemID }),
              isNearDecisionBoundary(
                hitPoint,
                layout: layout,
                candidates: candidates,
                threshold: hysteresis
              ) else {
            return dropTarget
        }
        return lastDropTarget
    }

    /// 判断命中点是否贴近当前布局的切换边界，用于落点迟滞。
    private func isNearDecisionBoundary(
        _ hitPoint: CGPoint,
        layout: BookshelfReorderLayout,
        candidates: [BookshelfReorderCandidate],
        threshold: CGFloat
    ) -> Bool {
        switch layout {
        case .list:
            return candidates.contains { abs($0.frame.midY - hitPoint.y) <= threshold }
        case .grid:
            let rows = BookshelfReorderGridRow.makeRows(from: candidates)
            guard let row = targetGridRow(at: hitPoint, rows: rows) else { return false }
            return row.candidates.contains { abs($0.frame.midX - hitPoint.x) <= threshold }
        }
    }

    /// 计算移除拖拽项后的插入 index；无实际顺序变化时返回 nil。
    private func makeDropTarget(
        candidate: BookshelfReorderCandidate,
        placement: BookshelfReorderDropPlacement,
        draggedIndex: Int
    ) -> BookshelfReorderDropTarget? {
        let adjustedTargetIndex = candidate.index - (draggedIndex < candidate.index ? 1 : 0)
        let insertionIndex: Int
        switch placement {
        case .before:
            insertionIndex = adjustedTargetIndex
        case .after:
            insertionIndex = adjustedTargetIndex + 1
        }
        guard insertionIndex != draggedIndex else { return nil }
        return BookshelfReorderDropTarget(
            itemID: candidate.itemID,
            placement: placement,
            insertionIndex: insertionIndex
        )
    }
}

/// 默认书架拖拽排序候选项，保留数据顺序 index 与当前可见 frame。
private struct BookshelfReorderCandidate {
    let itemID: BookshelfItemID
    let index: Int
    let frame: CGRect
}

/// 默认书架拖拽排序插入槽位，表达某个候选项前后，而不是拖拽项相对方向。
private struct BookshelfReorderSlot {
    let candidate: BookshelfReorderCandidate
    let placement: BookshelfReorderDropPlacement
}

/// 默认书架网格拖拽命中行，按几何行聚合候选项。
private struct BookshelfReorderGridRow {
    let candidates: [BookshelfReorderCandidate]
    let midY: CGFloat

    static func makeRows(from candidates: [BookshelfReorderCandidate]) -> [BookshelfReorderGridRow] {
        let orderedCandidates = candidates.sortedForGridRows()
        let rowThreshold = max(
            8,
            (orderedCandidates.map(\.frame.height).min() ?? 0) * 0.45
        )
        var rows: [[BookshelfReorderCandidate]] = []
        for candidate in orderedCandidates {
            guard var lastRow = rows.last,
                  let lastMidY = lastRow.averageMidY,
                  abs(candidate.frame.midY - lastMidY) <= rowThreshold else {
                rows.append([candidate])
                continue
            }
            lastRow.append(candidate)
            rows[rows.endIndex - 1] = lastRow
        }
        return rows.map { rowCandidates in
            let orderedRowCandidates = rowCandidates.sortedByHorizontalPosition()
            return BookshelfReorderGridRow(
                candidates: orderedRowCandidates,
                midY: orderedRowCandidates.averageMidY ?? 0
            )
        }
    }
}

private extension Array where Element == BookshelfReorderCandidate {
    func sortedByDataOrder() -> [BookshelfReorderCandidate] {
        sorted { lhs, rhs in lhs.index < rhs.index }
    }

    func sortedByHorizontalPosition() -> [BookshelfReorderCandidate] {
        sorted { lhs, rhs in
            if abs(lhs.frame.midX - rhs.frame.midX) >= 1 {
                return lhs.frame.midX < rhs.frame.midX
            }
            return lhs.index < rhs.index
        }
    }

    func sortedForGridRows() -> [BookshelfReorderCandidate] {
        sorted { lhs, rhs in
            if abs(lhs.frame.midY - rhs.frame.midY) >= 1 {
                return lhs.frame.midY < rhs.frame.midY
            }
            if abs(lhs.frame.midX - rhs.frame.midX) >= 1 {
                return lhs.frame.midX < rhs.frame.midX
            }
            return lhs.index < rhs.index
        }
    }

    var averageMidY: CGFloat? {
        guard !isEmpty else { return nil }
        return map(\.frame.midY).reduce(0, +) / CGFloat(count)
    }
}
