/**
 * [INPUT]: 依赖固定列数、卡宽、已测高度和项目间距令牌
 * [OUTPUT]: 提供调宽预览与最终桌面共用的双行组碰撞安全几何
 * [POS]: NoteReviewCanvas 无视图、无数据访问的确定性布局内核
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 桌面的稳定排列策略；原始行带仅供开发对照。
nonisolated enum NoteReviewCanvasDesktopPacking: String, CaseIterable, Sendable {
    case originalRows, compactPairs
    var title: String { self == .compactPairs ? "局部填空" : "原始行带" }
}

/// Geometry-only values shared by the canvas, preview, hit testing and raster queues.
nonisolated struct NoteReviewCanvasDesktopLayoutParameters: Sendable {
    var packing: NoteReviewCanvasDesktopPacking = .compactPairs
    var permitsLift = true
    var usesAccessibleLayout = false
    static let minimumHeight: CGFloat = 168
    static let maximumHeight: CGFloat = 300
    static let margin: CGFloat = 48
    // Product collision limits in unscaled canvas coordinates, not dynamic UI spacing.
    static let horizontalClearance: CGFloat = 24
    static let compactVerticalClearance: CGFloat = 20
    static let phases: [CGFloat] = [0, 12, 0, -12]
    static let angles: [CGFloat] = [0, 0.35, -0.35, 0.6, -0.6, 0].map { $0 * .pi / 180 }
    var verticalGap: CGFloat { packing == .compactPairs ? Self.compactVerticalClearance : Self.horizontalClearance }
    var maximumLift: CGFloat { packing == .compactPairs && permitsLift && !usesAccessibleLayout ? 48 : 0 }
    var version: String { "pairs-v2-\(packing.rawValue)-\(permitsLift)-\(usesAccessibleLayout)" }
    var horizontalReserve: CGFloat {
        guard packing == .compactPairs else { return 4 }
        let angle: CGFloat = 0.6 * .pi / 180
        // The extremum over widths 180...360 and heights 168...300, rounded outward.
        return ceil((Self.maximumHeight * sin(angle) - 180 * (1 - cos(angle))) / 2 * 1_000) / 1_000
    }
    /// 卡片旋转安全包络在整个调宽范围内固定。
    func stride(width: CGFloat) -> CGFloat { width + Self.horizontalClearance + horizontalReserve * 2 }
    /// 只改变整行相位；辅助功能保留严格基线。
    func rowX(_ row: Int, column: Int, width: CGFloat) -> CGFloat {
        Self.margin + horizontalReserve + (usesAccessibleLayout ? 0 : 12 + Self.phases[row % Self.phases.count])
            + CGFloat(column) * stride(width: width)
    }
    /// 使用最大允许卡宽保护拖动中的旋转外框。
    func overflow(height: CGFloat, angle: CGFloat, width: CGFloat) -> CGFloat {
        // Freeze the compact vertical envelope over the whole slider range. Text can lag width
        // without allowing a fast width change to rotate a corner into the preceding paper.
        let protectedWidth: CGFloat = packing == .compactPairs ? 360 : width
        return max(0, (abs(sin(angle)) * protectedWidth + (cos(angle) - 1) * height) / 2)
    }
}

/// 双行组的相对位置与真实下边界，不持有任何正文。
nonisolated struct NoteReviewCanvasPairPlacement {
    let frames: [CGRect]
    let lifts: [CGFloat]
    let height: CGFloat
}

/// Bounded two-row placement; no text, views or preceding-group state is read here.
nonisolated enum NoteReviewCanvasPairGeometry {
    /// 工作量最多两行；可在准备队列或有界实时预览调用，不测量文本。
    static func place(firstRow: Int, columns: Int, width: CGFloat, heights: [CGFloat],
                      parameters p: NoteReviewCanvasDesktopLayoutParameters,
                      rotations: [CGFloat]? = nil) -> NoteReviewCanvasPairPlacement {
        guard !heights.isEmpty, columns > 0, heights.count <= columns * 2,
              width.isFinite, (180...360).contains(width),
              heights.allSatisfy({ $0.isFinite && (168...300).contains($0) }),
              rotations == nil || rotations?.count == heights.count else {
            return NoteReviewCanvasPairPlacement(frames: [], lifts: [], height: 0)
        }
        var frames: [CGRect] = []
        var lifts: [CGFloat] = []
        var safeBounds: [CGRect] = []
        var bottom: CGFloat = 0
        for localRow in 0..<2 {
            let start = localRow * columns
            let end = min(heights.count, start + columns)
            guard start < end else { break }
            let row = firstRow + localRow
            let topOverflow = (start..<end).map { local -> CGFloat in
                let angle = p.usesAccessibleLayout ? 0 : (rotations?[local] ?? NoteReviewCanvasDesktopLayoutParameters.angles[(firstRow * columns + local) % 6])
                return p.overflow(height: heights[local], angle: angle, width: width)
            }.max() ?? 0
            let baseline = (localRow == 0 ? 0 : bottom + p.verticalGap) + topOverflow
            for local in start..<end {
                let column = local - start
                let angle = p.usesAccessibleLayout ? 0 : (rotations?[local] ?? NoteReviewCanvasDesktopLayoutParameters.angles[(firstRow * columns + local) % 6])
                let overflow = p.overflow(height: heights[local], angle: angle, width: width)
                var frame = CGRect(x: p.rowX(row, column: column, width: width), y: baseline,
                                   width: width, height: heights[local])
                var safe = frame.insetBy(dx: -p.horizontalReserve, dy: -overflow)
                var lift: CGFloat = 0
                if localRow == 1, p.maximumLift > 0 {
                    lift = p.maximumLift
                    // Frozen neighbour protection across all permitted widths: row phases and
                    // horizontal reserves are constant, so only the same/adjacent columns can meet.
                    for above in max(0, column - 1)..<min(columns, column + 2) where above < safeBounds.count {
                        let upper = safeBounds[above]
                        let xDistance = max(upper.minX - safe.maxX, safe.minX - upper.maxX)
                        if xDistance < p.verticalGap {
                            lift = min(lift, max(0, safe.minY - upper.maxY - p.verticalGap))
                        }
                    }
                    frame.origin.y -= lift
                    safe.origin.y -= lift
                }
                frames.append(frame)
                lifts.append(lift)
                safeBounds.append(safe)
                bottom = max(bottom, safe.maxY)
            }
        }
        return NoteReviewCanvasPairPlacement(frames: frames, lifts: lifts, height: bottom)
    }
}
