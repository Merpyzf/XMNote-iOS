/**
 * [INPUT]: 依赖有序 Int64 身份、已测高度及固定双行组参数
 * [OUTPUT]: 提供不可变桌面 frame、组索引、命中与定位
 * [POS]: NoteReviewCanvas 轻量几何快照，不持有正文或绘制资源
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 完整几何生成失败时保留旧画面，不提交部分卡片。
nonisolated enum NoteReviewCanvasGeometryError: Error {
    case duplicateIdentity, invalidInput, cancelled
}

/// 单张纸的业务身份与几何；删除的身份可由上层保留为不可激活槽位。
nonisolated struct NoteReviewCanvasPaperGeometry: Sendable {
    let noteID: Int64
    let frame: CGRect
    let visualFrame: CGRect
    let rotation: CGFloat
    let lift: CGFloat
}

/// 组范围为实际纸边，允许局部填空后仍可靠地查询可见区域。
nonisolated struct NoteReviewCanvasGeometryGroup: Sendable {
    let indexes: Range<Int>
    let minY: CGFloat
    let maxY: CGFloat
}

/// 可跨线程传递的完整一代几何；热路径只扫描二分命中的组及其可见列。
nonisolated struct NoteReviewCanvasGeometry: Sendable {
    let generation: UInt64
    let cardWidth: CGFloat
    let columnCount: Int
    let parameters: NoteReviewCanvasDesktopLayoutParameters
    let papers: [NoteReviewCanvasPaperGeometry]
    let groups: [NoteReviewCanvasGeometryGroup]
    let indexByID: [Int64: Int]
    let contentSize: CGSize
    let isRTL: Bool

    /// 在准备队列生成整代结果；每个双行组检查取消，抛错后调用方不得提交半成品。
    init(ids: [Int64], heights: [CGFloat], cardWidth: CGFloat, viewport: CGSize,
         generation: UInt64, fixedColumns: Int? = nil,
         parameters: NoteReviewCanvasDesktopLayoutParameters = .init(),
         isRTL: Bool = false, isCancelled: () -> Bool = { false }) throws {
        guard ids.count == heights.count, cardWidth.isFinite, (180...360).contains(cardWidth),
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              fixedColumns == nil || fixedColumns! > 0,
              heights.allSatisfy({ $0.isFinite && (168...300).contains($0) }) else {
            throw NoteReviewCanvasGeometryError.invalidInput
        }
        var map: [Int64: Int] = [:]
        for (index, id) in ids.enumerated() {
            if isCancelled() { throw NoteReviewCanvasGeometryError.cancelled }
            guard map.updateValue(index, forKey: id) == nil else {
                throw NoteReviewCanvasGeometryError.duplicateIdentity
            }
        }
        self.generation = generation; self.cardWidth = cardWidth
        self.parameters = parameters; self.isRTL = isRTL
        let aspect = max(0.35, viewport.width / viewport.height)
        let ideal = sqrt(CGFloat(ids.count) * aspect * 250 / parameters.stride(width: cardWidth))
        // A deletion keeps the session's tracks even when fewer cards remain than columns.
        let columns = fixedColumns ?? max(1, min(max(1, ids.count), ids.count == 2 ? 2 : Int(ideal.rounded())))
        columnCount = columns
        var result: [NoteReviewCanvasPaperGeometry] = []
        var grouped: [NoteReviewCanvasGeometryGroup] = []
        var top = NoteReviewCanvasDesktopLayoutParameters.margin
        var maxX = top
        for start in stride(from: 0, to: ids.count, by: columns * 2) {
            if isCancelled() { throw NoteReviewCanvasGeometryError.cancelled }
            let end = min(ids.count, start + columns * 2)
            let rotations = (start..<end).map {
                parameters.usesAccessibleLayout ? 0 : Self.rotation(for: ids[$0])
            }
            let placement = NoteReviewCanvasPairGeometry.place(firstRow: start / columns, columns: columns,
                width: cardWidth, heights: Array(heights[start..<end]), parameters: parameters, rotations: rotations)
            var minY = CGFloat.greatestFiniteMagnitude, maxY: CGFloat = 0
            for index in start..<end {
                let local = index - start
                let frame = placement.frames[local].offsetBy(dx: 0, dy: top)
                let visual = Self.rotatedBounds(frame, angle: rotations[local])
                result.append(NoteReviewCanvasPaperGeometry(noteID: ids[index], frame: frame,
                    visualFrame: visual, rotation: rotations[local], lift: placement.lifts[local]))
                maxX = max(maxX, visual.maxX); minY = min(minY, visual.minY); maxY = max(maxY, visual.maxY)
            }
            grouped.append(NoteReviewCanvasGeometryGroup(indexes: start..<end, minY: minY, maxY: maxY))
            top += placement.height + parameters.verticalGap
        }
        if isCancelled() { throw NoteReviewCanvasGeometryError.cancelled }
        let size = CGSize(width: maxX + 48, height: ids.isEmpty ? 96 : top - parameters.verticalGap + 48)
        if isRTL {
            result = result.map {
                NoteReviewCanvasPaperGeometry(noteID: $0.noteID,
                    frame: CGRect(x: size.width - $0.frame.maxX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height),
                    visualFrame: CGRect(x: size.width - $0.visualFrame.maxX, y: $0.visualFrame.minY,
                        width: $0.visualFrame.width, height: $0.visualFrame.height),
                    rotation: -$0.rotation, lift: $0.lift)
            }
        }
        papers = result; groups = grouped; indexByID = map; contentSize = size
    }

    /// 返回与查询区域相交的纸张索引，顺序与输入身份一致；不创建布局属性或视图。
    func indexes(in rect: CGRect) -> [Int] {
        guard !papers.isEmpty, !rect.isNull, !rect.isInfinite else { return [] }
        let query = isRTL
            ? CGRect(x: contentSize.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        var lower = 0, upper = groups.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if groups[middle].maxY < query.minY { lower = middle + 1 } else { upper = middle }
        }
        var result: [Int] = []
        var groupIndex = lower
        while groupIndex < groups.count, groups[groupIndex].minY <= query.maxY {
            let group = groups[groupIndex]
            for rowStart in stride(from: group.indexes.lowerBound, to: group.indexes.upperBound, by: columnCount) {
                let row = rowStart / columnCount
                let x = parameters.rowX(row, column: 0, width: cardWidth)
                let step = parameters.stride(width: cardWidth)
                let first = max(0, min(columnCount - 1, Int(floor((query.minX - x - parameters.horizontalReserve) / step)) - 1))
                let last = max(0, min(columnCount - 1, Int(floor((query.maxX - x + parameters.horizontalReserve) / step)) + 1))
                guard first <= last else { continue }
                for column in first...last {
                    let index = rowStart + column
                    if index < group.indexes.upperBound, papers[index].visualFrame.intersects(rect) { result.append(index) }
                }
            }
            groupIndex += 1
        }
        return result
    }

    /// 逆旋转后确认纸面命中，空白及阴影不冒充可激活卡片。
    func hitTest(_ point: CGPoint) -> Int64? {
        for index in indexes(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)) {
            let paper = papers[index]
            let dx = point.x - paper.frame.midX, dy = point.y - paper.frame.midY
            let x = dx * cos(paper.rotation) + dy * sin(paper.rotation)
            let y = -dx * sin(paper.rotation) + dy * cos(paper.rotation)
            if abs(x) <= paper.frame.width / 2, abs(y) <= paper.frame.height / 2 { return paper.noteID }
        }
        return nil
    }

    /// 稳定 ID 决定纸张角度，重新排序或删除相邻项不改变该纸张的旋转。
    static func rotation(for id: Int64) -> CGFloat {
        var value = UInt64(bitPattern: id) &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        value ^= value >> 31
        return NoteReviewCanvasDesktopLayoutParameters.angles[Int(value % 6)]
    }

    /// 保守轴对齐外框用于旋转后的间距、可见索引和命中初筛。
    static func rotatedBounds(_ rect: CGRect, angle: CGFloat) -> CGRect {
        let width = rect.width * abs(cos(angle)) + rect.height * abs(sin(angle))
        let height = rect.width * abs(sin(angle)) + rect.height * abs(cos(angle))
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
