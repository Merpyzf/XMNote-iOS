/**
 * [INPUT]: 依赖稳定身份、目标卡宽下的精确高度和有效视口
 * [OUTPUT]: 提供可复用瀑布流的完整不可变几何和逐列二分索引
 * [POS]: NoteReviewCanvas 页面内核；不持有文字、视图或业务会话
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 瀑布流列数与卡宽在准备阶段确定；缩放与滚动不参与重新布局。
nonisolated struct NoteReviewCanvasWaterfallMetrics: Sendable {
    let columns: Int
    let cardWidth: CGFloat
    let margin: CGFloat = 16
    let gap: CGFloat = 16

    /// 窄屏及辅助功能字号优先可读性，规则宽度最多四列。
    init(viewport: CGSize, accessibility: Bool, regularWidth: Bool) {
        if accessibility || viewport.width < 360 {
            columns = 1
        } else if regularWidth {
            columns = max(1, min(4, Int((viewport.width - 16) / 196)))
        } else {
            columns = viewport.width > viewport.height ? 3 : 2
        }
        cardWidth = max(1, (viewport.width - 32 - CGFloat(columns - 1) * 16) / CGFloat(columns))
    }
}

/// 身份索引与空间索引只在完整 generation 中提交；离屏 Cell 由 Collection View 回收。
nonisolated struct NoteReviewCanvasWaterfallGeometry: Sendable {
    let generation: UInt64
    let frames: [CGRect]
    let columnIndexes: [[Int]]
    let indexByID: [Int64: Int]
    let orderedIDs: [Int64]
    let contentSize: CGSize
    let metrics: NoteReviewCanvasWaterfallMetrics

    /// 准备任务每项检查取消；所有高度必须已完成测量，失败不返回部分布局。
    init(ids: [Int64], heights: [CGFloat], viewport: CGSize, generation: UInt64,
         accessibility: Bool = false, regularWidth: Bool = false, isRTL: Bool = false,
         retainingFrames: [Int64: CGRect] = [:],
         isCancelled: () -> Bool = { false }) throws {
        guard ids.count == heights.count, viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 32, viewport.height > 0,
              heights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw NoteReviewCanvasGeometryError.invalidInput
        }
        let metrics = NoteReviewCanvasWaterfallMetrics(viewport: viewport,
            accessibility: accessibility, regularWidth: regularWidth)
        var bottoms = Array(repeating: metrics.margin, count: metrics.columns)
        var indexes = Array(repeating: [Int](), count: metrics.columns)
        var frames: [CGRect] = []
        var identities: [Int64: Int] = [:]
        for (index, id) in ids.enumerated() {
            if isCancelled() { throw NoteReviewCanvasGeometryError.cancelled }
            guard identities.updateValue(index, forKey: id) == nil else {
                throw NoteReviewCanvasGeometryError.duplicateIdentity
            }
            // 最短列相等时选择业务顺序中靠前的一列；RTL 仅镜像显示坐标。
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            let x = metrics.margin + CGFloat(column) * (metrics.cardWidth + metrics.gap)
            frames.append(CGRect(x: isRTL ? viewport.width - x - metrics.cardWidth : x,
                y: bottoms[column], width: metrics.cardWidth, height: heights[index]))
            indexes[column].append(index)
            bottoms[column] += heights[index] + metrics.gap
        }
        let overlap = ids.indices.filter { retainingFrames[ids[$0]] != nil }
        if let first = overlap.first, let last = overlap.last,
           (first...last).allSatisfy({ retainingFrames[ids[$0]] != nil }),
           overlap.allSatisfy({ abs((retainingFrames[ids[$0]]?.height ?? 0) - heights[$0]) < 0.01
               && abs((retainingFrames[ids[$0]]?.width ?? 0) - metrics.cardWidth) < 0.01 }) {
            var tops = Array(repeating: CGFloat.greatestFiniteMagnitude, count: metrics.columns)
            bottoms = Array(repeating: -CGFloat.greatestFiniteMagnitude, count: metrics.columns)
            /// Column identity is recovered from committed physical x, including RTL mirroring.
            func column(for frame: CGRect) -> Int {
                let x = isRTL ? viewport.width - frame.maxX : frame.minX
                return min(metrics.columns - 1, max(0, Int(((x - metrics.margin) / (metrics.cardWidth + metrics.gap)).rounded())))
            }
            for index in overlap {
                guard let frame = retainingFrames[ids[index]] else { continue }
                frames[index] = frame
                let col = column(for: frame)
                tops[col] = min(tops[col], frame.minY)
                bottoms[col] = max(bottoms[col], frame.maxY + metrics.gap)
            }
            let top = tops.min() ?? metrics.margin
            let bottom = bottoms.max() ?? metrics.margin
            for col in 0..<metrics.columns {
                if tops[col] == .greatestFiniteMagnitude { tops[col] = top }
                if bottoms[col] == -.greatestFiniteMagnitude { bottoms[col] = bottom }
            }
            for index in (0..<first).reversed() {
                if isCancelled() { throw NoteReviewCanvasGeometryError.cancelled }
                let col = tops.indices.max { tops[$0] < tops[$1] } ?? 0
                let x = metrics.margin + CGFloat(col) * (metrics.cardWidth + metrics.gap)
                let y = tops[col] - metrics.gap - heights[index]
                frames[index] = CGRect(x: isRTL ? viewport.width - x - metrics.cardWidth : x,
                    y: y, width: metrics.cardWidth, height: heights[index])
                tops[col] = y
            }
            for index in (last + 1)..<ids.count {
                if isCancelled() { throw NoteReviewCanvasGeometryError.cancelled }
                let col = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
                let x = metrics.margin + CGFloat(col) * (metrics.cardWidth + metrics.gap)
                frames[index] = CGRect(x: isRTL ? viewport.width - x - metrics.cardWidth : x,
                    y: bottoms[col], width: metrics.cardWidth, height: heights[index])
                bottoms[col] += heights[index] + metrics.gap
            }
            let translation = metrics.margin - (frames.map(\.minY).min() ?? metrics.margin)
            frames = frames.map { $0.offsetBy(dx: 0, dy: translation) }
            bottoms = Array(repeating: metrics.margin, count: metrics.columns)
            indexes = Array(repeating: [], count: metrics.columns)
            for index in frames.indices {
                let col = column(for: frames[index])
                indexes[col].append(index)
                bottoms[col] = max(bottoms[col], frames[index].maxY + metrics.gap)
            }
            indexes = indexes.map { column in column.sorted { frames[$0].minY < frames[$1].minY } }
        }
        if isCancelled() { throw NoteReviewCanvasGeometryError.cancelled }
        self.generation = generation; self.metrics = metrics
        self.frames = frames; columnIndexes = indexes; indexByID = identities; orderedIDs = ids
        contentSize = CGSize(width: viewport.width,
            height: ids.isEmpty ? 32 : (bottoms.max() ?? 16) - metrics.gap + metrics.margin)
    }

    /// 最多四列分别二分；返回实际相交项，不扫描全部身份或构造离屏属性。
    func indexes(in rect: CGRect) -> [Int] {
        guard !rect.isNull, !rect.isInfinite else { return [] }
        var result: [Int] = []
        for column in columnIndexes {
            var lower = 0, upper = column.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if frames[column[middle]].maxY < rect.minY { lower = middle + 1 } else { upper = middle }
            }
            var cursor = lower
            while cursor < column.count {
                let index = column[cursor]
                if frames[index].minY > rect.maxY { break }
                if frames[index].intersects(rect) { result.append(index) }
                cursor += 1
            }
        }
        return result.sorted()
    }

    /// 使用与显示相同的 frame 命中，不依赖可能已复用的 IndexPath。
    func hitTest(_ point: CGPoint) -> Int64? {
        indexes(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
            .first(where: { frames[$0].contains(point) }).map { orderedIDs[$0] }
    }
}
