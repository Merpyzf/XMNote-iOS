/**
 * [INPUT]: 依赖回顾筛选、固定种子与无正文的仓储元数据
 * [OUTPUT]: 提供可取消目录句柄、有界成员窗口、稳定四叉集合身份及定位结果
 * [POS]: Domain 的书摘回顾专用目录契约；不承载正文、UIKit 或磁盘实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 每次只为一个元数据批次取得仓储许可，索引排序与磁盘构建不占用业务读取名额。
typealias NoteReviewDirectoryReadOperation = @Sendable () async throws -> [NoteReviewDirectoryRecord]
typealias NoteReviewDirectoryReadScheduling = @Sendable (@escaping NoteReviewDirectoryReadOperation) async throws -> [NoteReviewDirectoryRecord]

/// 只保存会影响集合成员与顺序的输入，颜色、字号和卡宽不会使目录失效。
nonisolated struct NoteReviewDirectoryRequest: Hashable, Sendable, Codable {
    let bookIDs: [Int64]
    let tagIDs: [Int64]
    let tagMatchRule: NoteReviewTagMatchRule
    let sortRule: NoteReviewSortRule
    let seed: UInt64
    let preservedIDs: [Int64]

    /// 新会话传启动前缀；迁移已开始的旧会话时传其已有顺序，不重新洗牌。
    init(settings: NoteReviewSettings, seed: UInt64, preservedIDs: [Int64] = []) {
        bookIDs = settings.selectedBookIDs.sorted()
        tagIDs = settings.selectedTagIDs.sorted()
        tagMatchRule = settings.tagMatchRule
        sortRule = settings.sortRule
        self.seed = seed
        self.preservedIDs = settings.sortRule == .random ? preservedIDs : []
    }
}

/// 目录扫描仅传递固定尺寸元数据；关联身份也进入校验，防止同时间戳的换书/换章遗漏失效。
nonisolated struct NoteReviewDirectoryRecord: Equatable, Sendable {
    let noteID: Int64
    let bookID: Int64
    let chapterID: Int64
    let noteRevision: Int64
    let bookRevision: Int64
    let chapterRevision: Int64
}

/// 稳定槽位不因删除变化；全局可见序号由祖先计数求出，而不是把后续 ID 全部前移。
nonisolated struct NoteReviewDirectoryMember: Equatable, Sendable {
    let slot: Int64
    let record: NoteReviewDirectoryRecord
}

/// level=0 表示最多 32 条的叶子，较高层每个节点覆盖最多四个子节点。
nonisolated struct NoteReviewDirectoryGroupID: Hashable, Sendable {
    let snapshotID: UUID
    let level: Int
    let bucket: Int64
}

/// 集合显示真实存活数量和全局范围；不要求读取正文来生成封面或摘要。
nonisolated struct NoteReviewDirectoryGroup: Equatable, Sendable {
    let id: NoteReviewDirectoryGroupID
    let count: Int64
    let firstOrdinal: Int64
    var lastOrdinal: Int64 { firstOrdinal + count - 1 }
    var isLeaf: Bool { id.level == 0 }
}

/// 完整路径包含根与叶子，ordinal 为从零开始的实际进度，localIndex 不超过 31。
nonisolated struct NoteReviewDirectoryLocation: Equatable, Sendable {
    let member: NoteReviewDirectoryMember
    let path: [NoteReviewDirectoryGroup]
    let ordinal: Int64
    let localIndex: Int
}

/// 浏览窗口可以按业务身份或全局进度打开；两者都不要求调用方持有完整身份数组。
nonisolated enum NoteReviewDirectoryAnchor: Equatable, Sendable {
    case noteID(Int64)
    case ordinal(Int64)
}

/// 详情页借用会话的只读分页能力；不能关闭目录或写入回顾选择。
nonisolated protocol NoteReviewDirectoryPageProvider: AnyObject, Sendable {
    @MainActor
    func page(around anchor: NoteReviewDirectoryAnchor) async throws -> NoteReviewDirectoryPage?
}

/// 导航仅编码身份；进程恢复后的失效引用显式报错，不偷偷重建另一份随机会话。
nonisolated struct NoteReviewDirectoryReference: Hashable, Sendable, Codable {
    let id: UUID
    let provider: (any NoteReviewDirectoryPageProvider)?

    init(id: UUID, provider: any NoteReviewDirectoryPageProvider) { self.id = id; self.provider = provider }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    init(from decoder: any Decoder) throws { id = try decoder.singleValueContainer().decode(UUID.self); provider = nil }
    func encode(to encoder: any Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(id) }
}

/// 单条与瀑布流的身份窗口，最多 128 个成员；firstOrdinal 明确区分局部索引和全局进度。
nonisolated struct NoteReviewDirectoryPage: Equatable, Sendable {
    let totalCount: Int64
    let firstOrdinal: Int64
    let focus: NoteReviewDirectoryLocation?
    let members: [NoteReviewDirectoryMember]

    /// 将已有小窗口映射为全局序号；超出窗口不制造占位身份，也不发起同步读取。
    func member(at ordinal: Int64) -> NoteReviewDirectoryMember? {
        guard ordinal >= firstOrdinal, ordinal - firstOrdinal < members.count else { return nil }
        return members[Int(ordinal - firstOrdinal)]
    }
}

/// 目录准备分为可恢复的元数据扫描、排序索引与可查询状态，未完成快照不冒充准确目录。
nonisolated enum NoteReviewDirectoryPreparation: Equatable, Sendable {
    case scanning(processed: Int64)
    case indexing(processed: Int64)
    case ready(count: Int64)
    case closed
}

/// 仓储返回的不透明目录句柄；所有查询异步且有界，取消或关闭后不得交付迟到结果。
nonisolated protocol NoteReviewDirectory: Sendable {
    func root() async throws -> NoteReviewDirectoryGroup
    func children(of group: NoteReviewDirectoryGroupID) async throws -> [NoteReviewDirectoryGroup]
    func group(_ id: NoteReviewDirectoryGroupID) async throws -> NoteReviewDirectoryGroup?
    func members(in leaf: NoteReviewDirectoryGroupID) async throws -> [NoteReviewDirectoryMember]
    func window(after slot: Int64?, limit: Int) async throws -> [NoteReviewDirectoryMember]
    func window(before slot: Int64, limit: Int) async throws -> [NoteReviewDirectoryMember]
    func locate(noteID: Int64) async throws -> NoteReviewDirectoryLocation?
    func locate(ordinal: Int64) async throws -> NoteReviewDirectoryLocation?
    func page(around anchor: NoteReviewDirectoryAnchor, limit: Int) async throws -> NoteReviewDirectoryPage?
    func removeConfirmed(noteID: Int64) async throws
    func close() async
}

/// 目录失败保留原阅读页面；与真实书摘删除或业务数据库错误分开处理。
nonisolated enum NoteReviewDirectoryError: Error, Equatable {
    case closed
    case invalidGroup
    case invalidBatch
    case staleSource
    case cacheInUse
    case cacheBudgetExceeded
    case unavailable
}

extension NoteRepositoryProtocol {
    /// 独立调用者使用直接批次读取；生产会话通过重载注入与完整正文共用的调度许可。
    func openNoteReviewDirectory(request: NoteReviewDirectoryRequest, cacheID: UUID,
                                 progress: @escaping @Sendable (NoteReviewDirectoryPreparation) async -> Void) async throws -> any NoteReviewDirectory {
        try await openNoteReviewDirectory(request: request, cacheID: cacheID,
                                          schedule: { try await $0() }, progress: progress)
    }

    /// 未接入目录的隔离假仓储显式失败，不能暗中回退为读取全部 ID；生产 NoteRepository 提供真实实现。
    func openNoteReviewDirectory(request: NoteReviewDirectoryRequest, cacheID: UUID,
                                 schedule: @escaping NoteReviewDirectoryReadScheduling,
                                 progress: @escaping @Sendable (NoteReviewDirectoryPreparation) async -> Void) async throws -> any NoteReviewDirectory {
        throw NoteReviewDirectoryError.unavailable
    }
}
