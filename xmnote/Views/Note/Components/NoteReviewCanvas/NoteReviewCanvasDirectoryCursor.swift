/**
 * [INPUT]: 接收 Session 注入的目录打开闭包与有界定位请求
 * [OUTPUT]: 提供共用打开任务、全局计数、局部身份窗口和叶子读取
 * [POS]: NoteReviewCanvas 的目录适配器；不持有业务选择、不访问 Repository 或偏好
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// 单个叶子及其目录位置；正文读取范围只能取 members，不能把根计数转为全量请求。
nonisolated struct NoteReviewCanvasDirectoryRegion: Sendable {
    let group: NoteReviewDirectoryGroup
    let members: [NoteReviewDirectoryMember]
    let totalCount: Int64
    let path: [NoteReviewDirectoryGroup]
    var stackID: NoteReviewCanvasStackID? = nil
}

/// 全景仅持有有界集合及当前路径，不包含正文或全量纸张坐标。
nonisolated struct NoteReviewCanvasDirectoryCatalog: Sendable {
    let root: NoteReviewDirectoryGroup
    let scope: NoteReviewDirectoryGroup
    let groups: [NoteReviewDirectoryGroup]
    let currentPath: [NoteReviewDirectoryGroup]
}

/// 主 actor 合并同一会话的目录打开；每次定位有独立取消资格，关闭后所有迟到结果作废。
@MainActor
final class NoteReviewCanvasDirectoryCursor: NoteReviewDirectoryPageProvider {
    typealias Open = @MainActor (NoteReviewDirectoryRequest, UUID) async throws -> any NoteReviewDirectory
    private let open: Open
    private var opening: Task<any NoteReviewDirectory, Error>?
    private var directory: (any NoteReviewDirectory)?
    private var request: NoteReviewDirectoryRequest?
    private var cacheID = UUID()
    private(set) var generation: UInt64 = 0
    private(set) var totalCount: Int64?
    private var isClosed = false

    /// 仓储及并发限制由唯一业务 Session 注入，适配器仅管理目录资源生命周期。
    init(open: @escaping Open) { self.open = open }

    /// 相同请求共用打开任务；只有筛选或随机轮次变化才替换身份，调用者取消不取消其他消费者。
    func configure(_ value: NoteReviewDirectoryRequest, refresh: Bool = false) async throws {
        guard !isClosed else { throw CancellationError() }
        if request == value, !refresh, directory != nil || opening != nil {
            _ = try await handle(); return
        }
        generation &+= 1
        let token = generation
        let oldTask = opening
        oldTask?.cancel()
        let oldDirectory = directory
        directory = nil
        if request != value { cacheID = UUID() }
        request = value
        let cache = cacheID
        opening = Task { [open] in
            if let oldDirectory { await oldDirectory.close() }
            if let oldTask, let stale = try? await oldTask.value { await stale.close() }
            try Task.checkCancellation()
            return try await open(value, cache)
        }
        let result = try await handle()
        guard token == generation, !isClosed else { throw CancellationError() }
        totalCount = try await result.root().count
    }

    /// 目录窗口不超过 128 项；返回前检查取消及请求代次，不提交过去的定位结果。
    func page(around anchor: NoteReviewDirectoryAnchor) async throws -> NoteReviewDirectoryPage? {
        let token = generation
        let result = try await handle().page(around: anchor, limit: 128)
        try validate(token)
        if let result { totalCount = result.totalCount }
        return result
    }

    /// 只读取当前叶子的身份及至多四叉路径，不读取相邻正文。
    func region(around noteID: Int64) async throws -> NoteReviewCanvasDirectoryRegion? {
        let token = generation
        let source = try await handle()
        guard let location = try await source.locate(noteID: noteID), let leaf = location.path.last else { return nil }
        let members = try await source.members(in: leaf.id)
        let count = try await source.root().count
        try validate(token)
        return .init(group: leaf, members: members, totalCount: count, path: location.path)
    }

    /// 组查询只取得身份；一次最多 128 项，前后移动使用槽位游标跳过删除后的空组。
    /// 主 actor 验证取消与目录代次，不改变业务当前项或随机顺序。
    func stack(_ request: NoteReviewCanvasStackRequest) async throws -> NoteReviewCanvasStackGroup? {
        let token = generation
        let source = try await handle()
        let root = try await source.root()
        let location: NoteReviewDirectoryLocation?
        let capacity: Int
        switch request {
        case let .containing(id, requestedCapacity):
            capacity = NoteReviewSettings.validatedDesktopGroupCapacity(requestedCapacity)
            location = try await source.locate(noteID: id)
        case let .adjacent(id, direction):
            guard id.snapshotID == root.id.snapshotID else { throw NoteReviewDirectoryError.staleSource }
            capacity = id.capacity
            let next: NoteReviewDirectoryMember?
            if direction > 0 { next = try await source.window(after: id.upperSlot - 1, limit: 1).first }
            else { next = try await source.window(before: id.lowerSlot, limit: 1).last }
            try validate(token)
            if let next { location = try await source.locate(noteID: next.record.noteID) }
            else { location = nil }
        }
        try validate(token)
        guard let location else { return nil }
        let id = NoteReviewCanvasStackID(snapshotID: root.id.snapshotID,
            bucket: location.member.slot / Int64(capacity), capacity: capacity)
        let members = try await source.window(after: id.lowerSlot == 0 ? nil : id.lowerSlot - 1, limit: capacity)
            .filter { $0.slot < id.upperSlot }
        try validate(token)
        guard let first = members.first, let firstLocation = try await source.locate(noteID: first.record.noteID) else { return nil }
        try validate(token)
        return .init(id: id, members: members, firstOrdinal: firstLocation.ordinal, totalCount: root.count)
    }

    /// 集合层只读目录统计；不会因全景展开触发正文获取。
    func children(of group: NoteReviewDirectoryGroupID) async throws -> [NoteReviewDirectoryGroup] {
        let token = generation
        let result = try await handle().children(of: group)
        try validate(token)
        return result
    }

    /// 目录全景以范围四叉树细化到最多 24 个集合；只查询统计，不读取任何书摘正文。
    func catalog(in scopeID: NoteReviewDirectoryGroupID?, currentID: Int64, maximumGroups: Int = 24) async throws -> NoteReviewCanvasDirectoryCatalog {
        let token = generation
        let source = try await handle()
        let root = try await source.root()
        let scope: NoteReviewDirectoryGroup
        if let scopeID, let value = try await source.group(scopeID) { scope = value } else { scope = root }
        let path = try await source.locate(noteID: currentID)?.path ?? []
        var visible = scope.count > 0 ? [scope] : []
        let limit = min(24, max(4, maximumGroups))
        while visible.count <= limit - 3 {
            try validate(token)
            guard let index = visible.indices.filter({ !visible[$0].isLeaf })
                .max(by: { visible[$0].count < visible[$1].count }) else { break }
            let children = try await source.children(of: visible[index].id)
            guard !children.isEmpty, visible.count - 1 + children.count <= limit else { break }
            visible.replaceSubrange(index...index, with: children)
        }
        try validate(token)
        return .init(root: root, scope: scope, groups: visible, currentPath: path)
    }

    /// 邻区请求按稳定叶子身份执行；删除造成的空区域返回 nil，不能凭旧数量制造占位书摘。
    func region(_ id: NoteReviewDirectoryGroupID) async throws -> NoteReviewCanvasDirectoryRegion? {
        let token = generation
        let source = try await handle()
        let group: NoteReviewDirectoryGroup
        do {
            guard id.level == 0, let value = try await source.group(id) else { return nil }
            group = value
        } catch NoteReviewDirectoryError.invalidGroup {
            // A 3×3 demand can include a neighbor beyond the last allocated leaf.
            // A stale snapshot is not an empty neighbor and must retain its error semantics.
            let root = try await source.root()
            guard root.id.snapshotID == id.snapshotID else { throw NoteReviewDirectoryError.invalidGroup }
            try validate(token)
            return nil
        }
        let members = try await source.members(in: id)
        guard let first = members.first, let location = try await source.locate(noteID: first.record.noteID) else { return nil }
        let root = try await source.root()
        try validate(token)
        return .init(group: group, members: members, totalCount: root.count, path: location.path)
    }

    /// 关闭立即撤销资格；无法中断的系统读取结束后只释放资源，不重新交付页面。
    func close() {
        guard !isClosed else { return }
        isClosed = true; generation &+= 1
        let task = opening; opening = nil; task?.cancel()
        let source = directory; directory = nil
        Task {
            if let source { await source.close() }
            if let task, let result = try? await task.value { await result.close() }
        }
    }

    /// 共享任务成功后保留句柄；失败清除任务，下一次显式请求可重试。
    private func handle() async throws -> any NoteReviewDirectory {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        if let directory { return directory }
        guard let opening else { throw NoteReviewDirectoryError.unavailable }
        let token = generation
        let result: any NoteReviewDirectory
        do { result = try await opening.value } catch {
            if token == generation { self.opening = nil }
            throw error
        }
        // A cancelled consumer must not discard a successfully opened shared directory.
        guard !isClosed, token == generation else { throw CancellationError() }
        directory = result
        self.opening = nil
        try Task.checkCancellation()
        return result
    }

    /// 相同句柄的不同消费者不能让旧操作覆盖新会话。
    private func validate(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard !isClosed, token == generation else { throw CancellationError() }
    }
}
