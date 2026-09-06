/**
 * [INPUT]: 接收目录稳定槽位、有界成员及组容量
 * [OUTPUT]: 提供与正文样式无关的卡片堆身份和相邻组查询意图
 * [POS]: 书摘回顾页面内部组模型；不读仓储、不持有 View 或正文
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// 以原始槽位分组；组内删除不会导致后续书摘换组，容量变更才重新划组。
nonisolated struct NoteReviewCanvasStackID: Hashable, Sendable {
    let snapshotID: UUID
    let bucket: Int64
    let capacity: Int
    var lowerSlot: Int64 { bucket * Int64(capacity) }
    var upperSlot: Int64 { lowerSlot + Int64(capacity) }
}

/// 一堆纸只保存最多 128 条轻量身份；正文预览由另一个有界准备器持有。
nonisolated struct NoteReviewCanvasStackGroup: Sendable {
    let id: NoteReviewCanvasStackID
    let members: [NoteReviewDirectoryMember]
    let firstOrdinal: Int64
    let totalCount: Int64
    var noteIDs: [Int64] { members.map(\.record.noteID) }

    /// 默认露出前三条；当前书摘不在前三条时作为第四张主纸，取消浏览仍回到原阅读身份。
    func previewIDs(currentID: Int64?) -> [Int64] {
        let first = Array(members.prefix(3).map(\.record.noteID))
        guard let currentID, members.contains(where: { $0.record.noteID == currentID }) else { return first }
        return [currentID] + first.filter { $0 != currentID }
    }

    /// 兼容既有局部准备入口，不向桌面暴露四叉目录的层级。
    var region: NoteReviewCanvasDirectoryRegion {
        .init(group: .init(id: .init(snapshotID: id.snapshotID, level: 0, bucket: id.lowerSlot / 32),
                           count: Int64(members.count), firstOrdinal: firstOrdinal),
              members: members, totalCount: totalCount, path: [], stackID: id)
    }
}

/// 相邻组从真实存活槽位查找，空组可以跳过，不能按总数猜测连续身份。
nonisolated enum NoteReviewCanvasStackRequest: Sendable {
    case containing(Int64, capacity: Int)
    case adjacent(NoteReviewCanvasStackID, direction: Int)
}
