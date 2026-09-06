/**
 * [INPUT]: 接收至多九个已完成区域的不可变几何和稳定区域位置
 * [OUTPUT]: 输出单画布可绘制、命中与调宽共用的局部空间索引
 * [POS]: 分层桌面的几何合成器；不读取正文，不为目录生成全量 frame
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 每个区域保留原有双行组二分索引；共同坐标补偿不会改变其内部排版。
nonisolated struct CanvasOverviewRegionSlice: Sendable {
    let id: NoteReviewDirectoryGroupID
    let origin: CGPoint
    let indexRange: Range<Int>
    let geometry: NoteReviewCanvasGeometry
    var frame: CGRect { CGRect(origin: origin, size: geometry.contentSize) }
}

/// 后台只合并窗口内的轻量几何；没有全局 ID 清单，也不创建卡片视图。
nonisolated enum CanvasOverviewRegionalGeometry {
    /// 水平轨道使用全部行相位及旋转的固定安全包络，不由第一叶的随机角度或短末行决定。
    static func trackWidth(for geometry: CanvasOverviewCanvasGeometry) -> CGFloat {
        let parameters = geometry.parameters
        let right = (0..<4).map {
            parameters.rowX($0, column: geometry.columnCount - 1, width: geometry.cardWidth)
                + geometry.cardWidth + parameters.horizontalReserve
        }.max() ?? 48
        return right + NoteReviewCanvasDesktopLayoutParameters.margin
    }

    static func compose(_ regions: [(NoteReviewDirectoryGroupID, CanvasOverviewCanvasGeometry)],
                        window: NoteReviewCanvasRegionWindow) -> CanvasOverviewCanvasGeometry? {
        guard let first = regions.first?.1, !regions.isEmpty, regions.count <= 9 else { return nil }
        var notes: [CanvasOverviewNote] = []
        var papers: [CanvasOverviewCanvasPaper] = []
        var rows: [CanvasOverviewCanvasRow] = []
        var groups: [CanvasOverviewCanvasGroup] = []
        var slices: [CanvasOverviewRegionSlice] = []
        var lifts: [CGFloat] = []
        let translation = window.canvasTranslation
        for (id, geometry) in regions.sorted(by: { $0.0.bucket < $1.0.bucket }) {
            guard let placement = window.placements[id], geometry.regionSlices.isEmpty else { return nil }
            let origin = CGPoint(x: placement.frame.minX + translation.x, y: placement.frame.minY + translation.y)
            let base = notes.count
            let rowBase = rows.count
            notes.append(contentsOf: geometry.notes)
            lifts.append(contentsOf: geometry.lifts)
            for paper in geometry.papers {
                papers.append(.init(index: base + paper.index, noteID: paper.noteID,
                    frame: paper.frame.offsetBy(dx: origin.x, dy: origin.y),
                    visualFrame: paper.visualFrame.offsetBy(dx: origin.x, dy: origin.y),
                    rotation: paper.rotation, contentGeometry: paper.contentGeometry))
            }
            rows.append(contentsOf: geometry.rows.map {
                .init(indexRange: ($0.indexRange.lowerBound + base)..<($0.indexRange.upperBound + base),
                      minY: $0.minY + origin.y, maxY: $0.maxY + origin.y)
            })
            groups.append(contentsOf: geometry.groups.map {
                .init(rowRange: ($0.rowRange.lowerBound + rowBase)..<($0.rowRange.upperBound + rowBase),
                      indexRange: ($0.indexRange.lowerBound + base)..<($0.indexRange.upperBound + base),
                      minY: $0.minY + origin.y, maxY: $0.maxY + origin.y)
            })
            slices.append(.init(id: id, origin: origin, indexRange: base..<notes.count, geometry: geometry.spatialIndex))
        }
        return .init(cardWidth: first.cardWidth, columnCount: first.columnCount, parameters: first.parameters,
            notes: notes, papers: papers, rows: rows, groups: groups, lifts: lifts,
            indexByID: Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element.id, $0.offset) }),
            contentSize: window.contentSize, packingSummary: "\(regions.count) 个区域 · \(notes.count) 条就绪",
            spatialIndex: first.spatialIndex, regionSlices: slices)
    }

    /// 调宽使用同一组区域成员和列归属；只在准备队列生成新几何，直接操控帧不调用此函数。
    static func reflow(_ old: CanvasOverviewCanvasGeometry, width: CGFloat, viewport: CGSize,
                       contents: [Int: CanvasOverviewPaperContentGeometry], anchorID: Int64,
                       cancellation: CanvasOverviewTransitionPreparation?, notes: [CanvasOverviewNote]? = nil) -> CanvasOverviewCanvasGeometry? {
        let notes = notes ?? old.notes
        guard notes.count == old.notes.count else { return nil }
        var locals: [NoteReviewDirectoryGroupID: CanvasOverviewCanvasGeometry] = [:]
        for slice in old.regionSlices {
            guard cancellation?.isCancelled != true else { return nil }
            let localContents = Dictionary(uniqueKeysWithValues: slice.indexRange.compactMap { index in
                contents[index].map { (index - slice.indexRange.lowerBound, $0) }
            })
            guard let geometry = CanvasOverviewGeometryBuilder.makeCanvas(notes: Array(notes[slice.indexRange]),
                viewportSize: viewport, cardWidth: width, fixedColumns: slice.geometry.columnCount,
                cancellation: cancellation, preparedContents: localContents, isRTL: slice.geometry.isRTL,
                parameters: old.parameters) else { return nil }
            locals[slice.id] = geometry
        }
        guard let anchorSlice = old.regionSlices.first(where: { $0.geometry.indexByID[anchorID] != nil }),
              let anchor = locals[anchorSlice.id] else { return nil }
        var window = NoteReviewCanvasRegionWindow(regionWidth: trackWidth(for: anchor), isRTL: anchor.spatialIndex.isRTL)
        let order = NoteReviewCanvasRegionWindow.demand(around: anchorSlice.id)
        for id in order {
            guard let geometry = locals[id] else { continue }
            guard window.admit(id: id, size: geometry.contentSize) else { return nil }
        }
        // A protected old neighbor can lie outside the newest nominal 3×3 demand.
        for slice in old.regionSlices where window.placements[slice.id] == nil {
            guard let geometry = locals[slice.id], window.admit(id: slice.id, size: geometry.contentSize) else { return nil }
        }
        return compose(locals.map { ($0.key, $0.value) }, window: window)
    }

    /// 从合成索引恢复局部轻量几何，用于调宽后的邻区继续加载；不再次排版文本。
    static func local(_ geometry: CanvasOverviewCanvasGeometry, slice: CanvasOverviewRegionSlice) -> CanvasOverviewCanvasGeometry {
        let base = slice.indexRange.lowerBound
        let notes = Array(geometry.notes[slice.indexRange])
        let papers = slice.indexRange.map { index in
            let paper = geometry.papers[index]
            return CanvasOverviewCanvasPaper(index: index - base, noteID: paper.noteID,
                frame: paper.frame.offsetBy(dx: -slice.origin.x, dy: -slice.origin.y),
                visualFrame: paper.visualFrame.offsetBy(dx: -slice.origin.x, dy: -slice.origin.y),
                rotation: paper.rotation, contentGeometry: paper.contentGeometry)
        }
        let columns = slice.geometry.columnCount
        let rows: [CanvasOverviewCanvasRow] = stride(from: 0, to: papers.count, by: columns).map { start in
            let range = start..<min(papers.count, start + columns)
            return .init(indexRange: range, minY: range.map { papers[$0].visualFrame.minY }.min() ?? 0,
                         maxY: range.map { papers[$0].visualFrame.maxY }.max() ?? 0)
        }
        let groups = slice.geometry.groups.map {
            CanvasOverviewCanvasGroup(rowRange: ($0.indexes.lowerBound / columns)..<Int(ceil(Double($0.indexes.upperBound) / Double(columns))),
                indexRange: $0.indexes, minY: $0.minY, maxY: $0.maxY)
        }
        return .init(cardWidth: geometry.cardWidth, columnCount: columns, parameters: geometry.parameters,
            notes: notes, papers: papers, rows: rows, groups: groups, lifts: Array(geometry.lifts[slice.indexRange]),
            indexByID: slice.geometry.indexByID, contentSize: slice.geometry.contentSize,
            packingSummary: geometry.packingSummary, spatialIndex: slice.geometry)
    }
}
