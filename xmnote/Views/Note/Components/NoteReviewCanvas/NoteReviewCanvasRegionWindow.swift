/**
 * [INPUT]: 接收稳定叶子身份、已完成的局部几何尺寸与受保护区域
 * [OUTPUT]: 提供最多九区的连续空间窗口及等量坐标补偿，不保存正文
 * [POS]: 分层桌面的局部坐标内核；与全景目录坐标明确分离
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreGraphics

/// 一个就绪区域的逻辑位置；frame 包含局部画布外边距，跨区只折叠重复的边距。
nonisolated struct NoteReviewCanvasRegionPlacement: Equatable, Sendable {
    let id: NoteReviewDirectoryGroupID
    let frame: CGRect
    var paperBounds: CGRect { frame.insetBy(dx: 48, dy: 48) }
}

/// 主 actor 所属场景保存此值；计算只处理最多九个区域，不访问目录或重新测量纸张。
nonisolated struct NoteReviewCanvasRegionWindow: Sendable {
    static let maximumRegions = 9
    private(set) var placements: [NoteReviewDirectoryGroupID: NoteReviewCanvasRegionPlacement] = [:]
    let regionWidth: CGFloat
    let isRTL: Bool

    /// 区域宽度在一次卡宽／环境会话中固定；自然高度独立，不按最大卡高预留空槽。
    init(regionWidth: CGFloat, isRTL: Bool) {
        self.regionWidth = max(97, regionWidth)
        self.isRTL = isRTL
    }

    /// 已验证的新一代调宽几何恢复成相同局部坐标，不重新选择区域位置。
    init?(regionWidth: CGFloat, isRTL: Bool, restoring values: [NoteReviewCanvasRegionPlacement]) {
        self.init(regionWidth: regionWidth, isRTL: isRTL)
        guard values.count <= Self.maximumRegions, Set(values.map(\.id)).count == values.count,
              Set(values.map { $0.id.snapshotID }).count <= 1 else { return nil }
        for value in values {
            guard value.frame.origin.x.isFinite, value.frame.origin.y.isFinite,
                  value.frame.width.isFinite, value.frame.height.isFinite,
                  value.frame.width > 96, value.frame.height > 96,
                  placements.values.allSatisfy({ !$0.paperBounds.intersects(value.paperBounds) }) else { return nil }
            placements[value.id] = value
        }
    }

    /// 当前所在行优先，然后沿运动方向准备上下邻区；最多生成九个稳定叶子身份。
    static func demand(around id: NoteReviewDirectoryGroupID, forward: Bool = true) -> [NoteReviewDirectoryGroupID] {
        guard id.level == 0 else { return [] }
        let row = id.bucket / 3
        let rows = forward ? [row, row + 1, row - 1] : [row, row - 1, row + 1]
        var buckets = [id.bucket]
        for value in rows where value >= 0 {
            for column in Int64(0)..<3 where value * 3 + column != id.bucket {
                buckets.append(value * 3 + column)
            }
        }
        return buckets.prefix(maximumRegions).map { .init(snapshotID: id.snapshotID, level: 0, bucket: $0) }
    }

    /// 只加入已精确排版的区域，既有位置不变；额度满时先等待受保护旧区离屏，不强行回收。
    mutating func admit(id: NoteReviewDirectoryGroupID, size: CGSize) -> Bool {
        guard id.level == 0, size.width.isFinite, size.height.isFinite,
              size.width > 96, size.width <= regionWidth + 0.001, size.height > 96 else { return false }
        if let old = placements[id] { return old.frame.size == size }
        guard placements.count < Self.maximumRegions,
              placements.keys.allSatisfy({ $0.snapshotID == id.snapshotID }) else { return false }
        let column = id.bucket % 3
        let row = id.bucket / 3
        let previous = NoteReviewDirectoryGroupID(snapshotID: id.snapshotID, level: 0, bucket: id.bucket - 3)
        let next = NoteReviewDirectoryGroupID(snapshotID: id.snapshotID, level: 0, bucket: id.bucket + 3)
        let y: CGFloat
        if let above = placements[previous] { y = above.frame.maxY - 96 + 20 }
        else if let below = placements[next] { y = below.frame.minY - size.height + 96 - 20 }
        else if let peer = placements.values.filter({ $0.id.bucket / 3 == row }).min(by: { $0.id.bucket < $1.id.bucket }) {
            y = peer.frame.minY
        }
        else if placements.isEmpty { y = 0 }
        else { return false }
        let visualColumn = isRTL ? 2 - column : column
        let x = CGFloat(visualColumn) * (regionWidth - 96 + 24)
        let placement = NoteReviewCanvasRegionPlacement(id: id,
            frame: CGRect(x: x, y: y, width: size.width, height: size.height))
        // A late region cannot occupy paper space already owned by a visible region.
        guard placements.values.allSatisfy({ !$0.paperBounds.intersects(placement.paperBounds) }) else { return false }
        placements[id] = placement
        return true
    }

    /// 需求推进只释放不再需要且不受视口、惯性或转场保护的区域，不改变幸存区域的位置。
    mutating func retain(wanted: Set<NoteReviewDirectoryGroupID>, protected: Set<NoteReviewDirectoryGroupID>) {
        placements = placements.filter { wanted.contains($0.key) || protected.contains($0.key) }
    }

    /// 画布坐标只做共同平移；同时把 offset 加上 translation×zoom，屏幕上的纸张保持原位置。
    var canvasTranslation: CGPoint {
        let bounds = placements.values.reduce(CGRect.null) { $0.union($1.frame) }
        return bounds.isNull ? .zero : CGPoint(x: -min(0, bounds.minX), y: -min(0, bounds.minY))
    }
    var contentSize: CGSize {
        let bounds = placements.values.reduce(CGRect.null) { $0.union($1.frame) }
        let shift = canvasTranslation
        return bounds.isNull ? .zero : CGSize(width: bounds.maxX + shift.x, height: bounds.maxY + shift.y)
    }
}
