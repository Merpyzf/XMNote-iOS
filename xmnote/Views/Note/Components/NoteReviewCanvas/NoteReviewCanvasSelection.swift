/**
 * [INPUT]: 依赖旧、新有序身份快照与旧当前 ID
 * [OUTPUT]: 提供读取期间删除后的确定性选择恢复
 * [POS]: NoteReviewCanvas 与唯一 Session 共用的身份策略
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 删除只移动到旧顺序中最近的有效下一项，没有下一项才回到上一项。
nonisolated enum NoteReviewCanvasSelection {
    /// 仅在数据 generation 更新时运行，不进入滚动或显示时钟路径。
    static func replacement(for current: Int64?, previousOrder: [Int64], nextOrder: [Int64]) -> Int64? {
        let available = Set(nextOrder)
        guard let current else { return nextOrder.first }
        if available.contains(current) { return current }
        guard let index = previousOrder.firstIndex(of: current) else { return nextOrder.first }
        for id in previousOrder.dropFirst(index + 1) where available.contains(id) { return id }
        for id in previousOrder.prefix(index).reversed() where available.contains(id) { return id }
        return nextOrder.first
    }
}
