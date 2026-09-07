/**
 * [INPUT]: 依赖 Repository 提供同一读取快照的有界元数据批次、GRDB 与可清除缓存 URL
 * [OUTPUT]: 提供磁盘有界的四叉目录、固定种子排序、可校验续建及有界定位/成员读取
 * [POS]: Data 的回顾专用派生索引；独立 SQLite 文件，不写业务 schema，不保存正文
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import CryptoKit
import GRDB

/// 独占同一派生文件，防止旧页面仍在查询时新准备任务覆盖它；关闭与失败均释放租约。
private actor NoteReviewDirectoryFileLeases {
    static let shared = NoteReviewDirectoryFileLeases()
    private var paths: [String: UUID] = [:]
    private var preparingRoots: [String: UUID] = [:]

    /// 只锁定一个确切文件，不持有任何业务身份或正文。
    func acquire(_ path: String, token: UUID) throws {
        let root = (path as NSString).deletingLastPathComponent
        guard paths[path] == nil, preparingRoots[root] == nil else { throw NoteReviewDirectoryError.cacheInUse }
        paths[path] = token
        preparingRoots[root] = token
    }

    /// 同一缓存根一次只扩建一个文件，避免两个构建任务同时把同一磁盘余量计算为自己的额度。
    func finishPreparation(_ path: String, token: UUID) {
        let root = (path as NSString).deletingLastPathComponent
        if preparingRoots[root] == token { preparingRoots[root] = nil }
    }

    /// 迟到释放不能解锁新租约。
    func release(_ path: String, token: UUID) {
        if paths[path] == token { paths[path] = nil }
        finishPreparation(path, token: token)
    }
}

/// Actor 维护句柄资格，GRDB 的独立串行队列执行磁盘操作；每次 await 前后核对取消与关闭代次。
actor NoteReviewDirectoryIndex: NoteReviewDirectory {
    typealias Reader = @Sendable (_ afterNoteID: Int64?, _ limit: Int) async throws -> [NoteReviewDirectoryRecord]
    typealias Progress = @Sendable (NoteReviewDirectoryPreparation) async -> Void

    nonisolated static let batchLimit = 1_024
    nonisolated static let leafCapacity: Int64 = 32
    nonisolated static let diskBudget = 256 * 1_024 * 1_024
    private let database: DatabaseQueue
    private let url: URL
    private let lease: UUID
    private let snapshotID = UUID()
    private var isClosed = false
    private let allocatedCount: Int64
    private let rootLevel: Int

    /// 仅完整校验和索引成功后创建可查询句柄；不让部分构建的数量泄漏到页面。
    private init(database: DatabaseQueue, url: URL, lease: UUID, count: Int64) {
        self.database = database
        self.url = url
        self.lease = lease
        allocatedCount = count
        rootLevel = Self.level(for: count)
    }

    deinit {
        let path = url.path
        let token = lease
        Task { await NoteReviewDirectoryFileLeases.shared.release(path, token: token) }
    }

    /// 后台逐批转换并释放；源必须来自同一仓储快照。取消保留已提交检查点，但不启动下一批。
    @concurrent
    nonisolated static func open(at url: URL, request: NoteReviewDirectoryRequest, byteBudget: Int = diskBudget,
                     reader: @escaping Reader, progress: @escaping Progress = { _ in }) async throws -> NoteReviewDirectoryIndex {
        let token = UUID()
        try await NoteReviewDirectoryFileLeases.shared.acquire(url.path, token: token)
        do {
            try Task.checkCancellation()
            let opening = Task.detached(priority: .utility) {
                try Self.makeDatabase(at: url, byteBudget: byteBudget)
            }
            let database = try await withTaskCancellationHandler {
                try await opening.value
            } onCancel: {
                opening.cancel()
            }
            let key = try requestKey(request)
            let oldKey = try await database.read { try Self.metadata($0, "request") }
            if oldKey != key {
                try await reset(database, request: request, key: key)
            }
            do {
                try await scan(database, url: url, request: request, byteBudget: byteBudget, reader: reader, progress: progress)
            } catch NoteReviewDirectoryError.staleSource {
                // 只清除当前独占的派生文件内容；业务数据及其他已打开快照完全不受影响。
                try Task.checkCancellation()
                try await reset(database, request: request, key: key)
                try await scan(database, url: url, request: request, byteBudget: byteBudget, reader: reader, progress: progress)
            }
            let count = try await index(database, url: url, byteBudget: byteBudget, progress: progress)
            try Task.checkCancellation()
            await progress(.ready(count: count))
            try Task.checkCancellation()
            await NoteReviewDirectoryFileLeases.shared.finishPreparation(url.path, token: token)
            try Task.checkCancellation()
            return NoteReviewDirectoryIndex(database: database, url: url, lease: token, count: count)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
            await NoteReviewDirectoryFileLeases.shared.release(url.path, token: token)
            throw NoteReviewDirectoryError.cacheBudgetExceeded
        } catch {
            await NoteReviewDirectoryFileLeases.shared.release(url.path, token: token)
            throw error
        }
    }

    /// 根节点数量来自已完成的快照，不读取正文或构建全量节点数组。
    func root() async throws -> NoteReviewDirectoryGroup {
        try checkOpen()
        let depth = rootLevel
        let count = try await database.read { db in
            // SQL：根计数与删除处于同一派生事务；不依赖可能因取消而漏更新的第二份内存计数。
            try Int64.fetchOne(db, sql: "SELECT count FROM groups WHERE level = ? AND bucket = 0", arguments: [depth]) ?? 0
        }
        try checkOpen()
        return .init(id: .init(snapshotID: snapshotID, level: rootLevel, bucket: 0), count: count, firstOrdinal: 0)
    }

    /// 每次至多返回四个子集合；顺序范围通过祖先计数计算，删除后仍能正确显示实际进度。
    func children(of group: NoteReviewDirectoryGroupID) async throws -> [NoteReviewDirectoryGroup] {
        try validate(group)
        guard group.level > 0 else { return [] }
        let result = try await database.read { db in
            let first = try Self.ordinalBeforeGroup(db, level: group.level, bucket: group.bucket, rootLevel: self.rootLevel)
            let counts = try Self.childCounts(db, level: group.level - 1, bucket: group.bucket)
            var ordinal = first
            return counts.enumerated().compactMap { offset, count -> NoteReviewDirectoryGroup? in
                defer { ordinal += count }
                guard count > 0 else { return nil }
                return .init(id: .init(snapshotID: group.snapshotID, level: group.level - 1,
                                      bucket: group.bucket * 4 + Int64(offset)), count: count, firstOrdinal: ordinal)
            }
        }
        try checkOpen()
        return result
    }

    /// 只恢复请求的集合及其祖先范围，空集合返回 nil；不把整棵范围树常驻到页面。
    func group(_ id: NoteReviewDirectoryGroupID) async throws -> NoteReviewDirectoryGroup? {
        try validate(id)
        let depth = rootLevel
        let result = try await database.read { db -> NoteReviewDirectoryGroup? in
            // SQL：复合主键读取一个集合；空叶子保留身份记录，但不成为可展开内容。
            guard let count = try Int64.fetchOne(db, sql: "SELECT count FROM groups WHERE level = ? AND bucket = ?",
                                                arguments: [id.level, id.bucket]), count > 0 else { return nil }
            let first = try Self.ordinalBeforeGroup(db, level: id.level, bucket: id.bucket, rootLevel: depth)
            return .init(id: id, count: count, firstOrdinal: first)
        }
        try checkOpen()
        return result
    }

    /// 叶子读取严格限制 32 个固定尺寸记录，空叶子返回空数组而不是等待不存在的内容。
    func members(in leaf: NoteReviewDirectoryGroupID) async throws -> [NoteReviewDirectoryMember] {
        try validate(leaf)
        guard leaf.level == 0 else { throw NoteReviewDirectoryError.invalidGroup }
        let start = leaf.bucket * Self.leafCapacity
        let result = try await database.read { db in
            // SQL：positions 的 slot 范围索引命中一个叶子，再按主键补充固定元数据；无正文/时间转换。
            try Row.fetchAll(db, sql: "SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.slot >= ? AND p.slot < ? ORDER BY p.slot LIMIT 32",
                             arguments: [start, start + Self.leafCapacity]).map(Self.member)
        }
        try checkOpen()
        return result
    }

    /// 单条/瀑布流消费游标窗口，limit 强制截断为 128；不会使用深 OFFSET 或全量身份数组。
    func window(after slot: Int64?, limit: Int) async throws -> [NoteReviewDirectoryMember] {
        try checkOpen()
        let count = max(1, min(128, limit))
        let result = try await database.read { db in
            // SQL：positions_slot seek 到上一窗口后，按回顾顺序取有界成员；时间字段保持原值。
            try Row.fetchAll(db, sql: "SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.slot > ? ORDER BY p.slot LIMIT ?",
                             arguments: [slot ?? -1, count]).map(Self.member)
        }
        try checkOpen()
        return result
    }

    /// 上一窗口使用反向索引 seek，结果仍按业务顺序返回；删除留下的槽位洞不会成为空白项目。
    func window(before slot: Int64, limit: Int) async throws -> [NoteReviewDirectoryMember] {
        try checkOpen()
        let count = max(1, min(128, limit))
        let result = try await database.read { db in
            // SQL：positions_slot 反向取最多 128 个存活成员，只对这个小批次反转；不使用全局 OFFSET。
            try Row.fetchAll(db, sql: "SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.slot < ? ORDER BY p.slot DESC LIMIT ?",
                             arguments: [slot, count]).reversed().map(Self.member)
        }
        try checkOpen()
        return result
    }

    /// 按 note 主键与四叉祖先计数定位；只扫描当前叶子的最多 32 个槽位，不扫描前面的全部成员。
    func locate(noteID: Int64) async throws -> NoteReviewDirectoryLocation? {
        try checkOpen()
        let identifier = snapshotID
        let depth = rootLevel
        let result = try await database.read { db -> NoteReviewDirectoryLocation? in
            // SQL：两个派生主键命中目标；尚未排序的记录没有 positions，不会成为有效目标。
            guard let row = try Row.fetchOne(db, sql: "SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.note_id = ?",
                                            arguments: [noteID]) else { return nil }
            return try Self.location(db, row: row, identifier: identifier, depth: depth)
        }
        try checkOpen()
        return result
    }

    /// 从全局进度逐级扣减子集合计数，到叶子才读取最多 32 条；百万条定位不执行深 OFFSET。
    func locate(ordinal: Int64) async throws -> NoteReviewDirectoryLocation? {
        try checkOpen()
        let identifier = snapshotID
        let depth = rootLevel
        let result = try await database.read { try Self.location($0, ordinal: ordinal, identifier: identifier, depth: depth) }
        try checkOpen()
        return result
    }

    /// 单个只读事务返回总数、焦点与最多 128 条身份；并发删除不能造成窗口与进度错代。
    func page(around anchor: NoteReviewDirectoryAnchor, limit: Int) async throws -> NoteReviewDirectoryPage? {
        try checkOpen()
        let identifier = snapshotID
        let depth = rootLevel
        let capacity = max(1, min(128, limit))
        let result = try await database.read { db -> NoteReviewDirectoryPage? in
            // SQL：实际根计数与页面成员在同一派生事务中读取；零数据直接提供真实空态。
            let count = try Int64.fetchOne(db, sql: "SELECT count FROM groups WHERE level = ? AND bucket = 0",
                                          arguments: [depth]) ?? 0
            guard count > 0 else { return .init(totalCount: 0, firstOrdinal: 0, focus: nil, members: []) }
            let focus: NoteReviewDirectoryLocation?
            switch anchor {
            case .noteID(let id):
                // SQL：note 主键恢复焦点；缺失对象显式返回 nil，不跳到另一条书摘。
                if let row = try Row.fetchOne(db, sql: "SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.note_id = ?", arguments: [id]) {
                    focus = try Self.location(db, row: row, identifier: identifier, depth: depth)
                } else { focus = nil }
            case .ordinal(let ordinal):
                focus = try Self.location(db, ordinal: ordinal, identifier: identifier, depth: depth)
            }
            guard let focus else { return nil }
            let slot = focus.member.slot
            // SQL：两次有界索引 seek 构造焦点邻域；反向结果只在最多 64 条的小批次内反转。
            let before = try Row.fetchAll(db, sql: "SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.slot < ? ORDER BY p.slot DESC LIMIT ?",
                                          arguments: [slot, capacity / 2]).reversed().map(Self.member)
            let after = try Row.fetchAll(db, sql: "SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.slot > ? ORDER BY p.slot LIMIT ?",
                                         arguments: [slot, capacity - before.count - 1]).map(Self.member)
            return .init(totalCount: count, firstOrdinal: focus.ordinal - Int64(before.count), focus: focus,
                         members: before + [focus.member] + after)
        }
        try checkOpen()
        return result
    }

    /// 仅由 Session 确认业务删除成功后调用；移除派生成员并递减祖先，不给其他叶子重新分组。
    func removeConfirmed(noteID: Int64) async throws {
        try checkOpen()
        let depth = rootLevel
        try await database.write { db in
            // SQL：只在派生文件内命中并删除已确认消失的成员；不执行业务删除，不涉及时间转换。
            guard let slot = try Int64.fetchOne(db, sql: "SELECT slot FROM positions WHERE note_id = ?", arguments: [noteID]) else { return }
            try db.execute(sql: "DELETE FROM positions WHERE note_id = ?", arguments: [noteID])
            try db.execute(sql: "DELETE FROM records WHERE note_id = ?", arguments: [noteID])
            for level in 0...depth {
                // SQL：仅递减本叶子与祖先的存活数量；槽位和其他集合身份保持不变。
                try db.execute(sql: "UPDATE groups SET count = count - 1 WHERE level = ? AND bucket = ?",
                               arguments: [level, slot / Self.span(level)])
            }
            // 不再允许跨进程将这个运行态修改版本误认为原始扫描结果。
            try Self.setMetadata(db, "mutated", "1")
        }
        try checkOpen()
    }

    /// 先撤销交付资格，再异步关闭连接和释放文件；迟到查询不能向已关闭页面提交。
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let database = database
        _ = await Task.detached { try? database.close() }.value
        await NoteReviewDirectoryFileLeases.shared.release(url.path, token: lease)
    }

    /// Debug/Test 读取查询计划和项目可控资源，不把 SQLite/CATiledLayer 内部内存宣称为硬限制。
    func diagnostics() async throws -> (bytes: Int, count: Int64, depth: Int, windowPlan: [String]) {
        try checkOpen()
        let plan = try await database.read { db in
            // SQL：仅解释实际游标窗口查询；验证 slot 索引而非推测 SQLite 必然采用高效计划。
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.slot > 500000 ORDER BY p.slot LIMIT 128")
                .map { $0["detail"] as String }
        }
        let bytes = try Self.cacheBytes(in: url.deletingLastPathComponent())
        try checkOpen()
        let count = try await root().count
        return (bytes, count, rootLevel, plan)
    }

    /// 查询与 await 交还共用同一关闭/取消检查。
    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !isClosed else { throw NoteReviewDirectoryError.closed }
    }

    /// 拒绝其他代次、越界层级及非法桶，避免外部输入造成乘法溢出或访问错误集合。
    private func validate(_ group: NoteReviewDirectoryGroupID) throws {
        try checkOpen()
        guard group.snapshotID == snapshotID, (0...rootLevel).contains(group.level), group.bucket >= 0,
              group.bucket <= max(0, allocatedCount - 1) / Self.span(group.level) else {
            throw NoteReviewDirectoryError.invalidGroup
        }
    }
}

private extension NoteReviewDirectoryIndex {
    /// 按祖先计数做 order-statistic 查找；每层最多四项，到叶子才读取至多 32 条身份。
    nonisolated static func location(_ db: Database, ordinal: Int64, identifier: UUID, depth: Int) throws -> NoteReviewDirectoryLocation? {
        // SQL：根计数用于边界验证；同一只读事务中继续遍历路径，删除不会混入两份进度。
        let count = try Int64.fetchOne(db, sql: "SELECT count FROM groups WHERE level = ? AND bucket = 0",
                                      arguments: [depth]) ?? 0
        guard ordinal >= 0, ordinal < count else { return nil }
        var bucket: Int64 = 0
        var local = ordinal
        for level in stride(from: depth - 1, through: 0, by: -1) {
            let counts = try Self.childCounts(db, level: level, bucket: bucket)
            var selected: Int?
            for (offset, count) in counts.enumerated() {
                if local < count { selected = offset; break }
                local -= count
            }
            guard let selected else { throw NoteReviewDirectoryError.invalidBatch }
            bucket = bucket * 4 + Int64(selected)
        }
        // SQL：叶子内有界读取后按本地序号选取；最大 32 条，包含删除后的空槽语义。
        let rows = try Row.fetchAll(db, sql: "SELECT p.slot, r.* FROM positions p JOIN records r ON r.note_id = p.note_id WHERE p.slot >= ? AND p.slot < ? ORDER BY p.slot LIMIT 32",
                                   arguments: [bucket * 32, bucket * 32 + 32])
        guard local < rows.count else { throw NoteReviewDirectoryError.invalidBatch }
        return try Self.location(db, row: rows[Int(local)], identifier: identifier, depth: depth)
    }

    /// 两种定位入口共用同一读取事务中的身份与实际进度，避免一次定位混用删除前后的计数。
    nonisolated static func location(_ db: Database, row: Row, identifier: UUID, depth: Int) throws -> NoteReviewDirectoryLocation {
        let member = Self.member(row)
        var path: [NoteReviewDirectoryGroup] = []
        var first: Int64 = 0
        for level in stride(from: depth, through: 0, by: -1) {
            let bucket = member.slot / Self.span(level)
            if level < depth {
                let siblings = try Self.childCounts(db, level: level, bucket: bucket / 4)
                first += siblings.prefix(Int(bucket % 4)).reduce(0, +)
            }
            // SQL：groups 复合主键读取当前节点存活计数；无时间字段或业务数据副作用。
            let count = try Int64.fetchOne(db, sql: "SELECT count FROM groups WHERE level = ? AND bucket = ?",
                                          arguments: [level, bucket]) ?? 0
            path.append(.init(id: .init(snapshotID: identifier, level: level, bucket: bucket), count: count, firstOrdinal: first))
        }
        // SQL：只统计叶子内部目标之前的槽位（最多 31 个），得到删除后的局部可见序号。
        let local = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM positions WHERE slot >= ? AND slot < ?",
                                    arguments: [member.slot / 32 * 32, member.slot]) ?? 0
        return .init(member: member, path: path, ordinal: first + Int64(local), localIndex: local)
    }

    /// 连接只在后台创建；页面最多持有句柄，SQLite 页缓存 4MB、禁用 mmap，回滚日志计入整体预算。
    nonisolated static func makeDatabase(at url: URL, byteBudget: Int) throws -> DatabaseQueue {
        try Task.checkCancellation()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let used = try cacheBytes(in: directory)
        let existing = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let available = byteBudget - used + existing
        guard available >= 128 * 1_024, existing <= available / 2 else { throw NoteReviewDirectoryError.cacheBudgetExceeded }
        var configuration = Configuration()
        configuration.label = "NoteReviewDirectory"
        configuration.prepareDatabase { db in
            // SQL：仅配置派生连接，限制页缓存/mmap/文件大小；预留一半预算给回滚日志，无业务 schema 副作用。
            try db.execute(sql: "PRAGMA cache_size = -4096; PRAGMA mmap_size = 0; PRAGMA journal_mode = DELETE; PRAGMA temp_store = MEMORY;")
            try db.execute(sql: "PRAGMA max_page_count = \(available / 2 / 4096)")
        }
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        try Task.checkCancellation()
        try database.write { db in
            if try db.tableExists("records"), try db.columns(in: "records").contains(where: { $0.name == "slot" }) {
                // SQL：旧派生 v1 随机回写结构不可续用；只在独占的缓存文件事务内重建，不触及业务库。
                try db.execute(sql: "DROP TABLE IF EXISTS positions; DROP TABLE records; DROP TABLE groups; DROP TABLE prefix; DROP TABLE metadata;")
            }
            // SQL：创建独立可清除索引的内部表；仅保存身份、原始毫秒 revision、顺序/槽位/计数。
            // records_order 支持三元组 seek；positions_slot 支持浏览与叶子查询，不保存 HTML、文字或位图。
            // 排序只随机写入两个整数的 positions，不随机回写含多个 revision 的整条元数据。
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS prefix (note_id INTEGER PRIMARY KEY, rank INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS records (
                    note_id INTEGER PRIMARY KEY, book_id INTEGER NOT NULL, chapter_id INTEGER NOT NULL,
                    note_revision INTEGER NOT NULL, book_revision INTEGER NOT NULL, chapter_revision INTEGER NOT NULL,
                    prefix_rank INTEGER NOT NULL, order_key INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS records_order ON records(prefix_rank, order_key, note_id);
                CREATE TABLE IF NOT EXISTS positions (note_id INTEGER PRIMARY KEY, slot INTEGER NOT NULL);
                CREATE UNIQUE INDEX IF NOT EXISTS positions_slot ON positions(slot);
                CREATE TABLE IF NOT EXISTS groups (level INTEGER NOT NULL, bucket INTEGER NOT NULL, count INTEGER NOT NULL,
                    PRIMARY KEY (level, bucket)) WITHOUT ROWID;
                """)
        }
        return database
    }

    /// 只枚举专用缓存目录第一层的文件元数据，包含 journal/temp 文件；不打开其他用户文件内容。
    nonisolated static func cacheBytes(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            .reduce(0) { total, url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                return total + (values.isRegularFile == true ? values.fileSize ?? 0 : 0)
            }
    }

    /// 逐批写入前留出当前小事务的日志空间；超过预算中止，不借扩大缓存换速度。
    nonisolated static func checkBudget(url: URL, byteBudget: Int) throws {
        try Task.checkCancellation()
        guard try cacheBytes(in: url.deletingLastPathComponent()) < byteBudget else {
            throw NoteReviewDirectoryError.cacheBudgetExceeded
        }
    }

    /// 内容配置不参与请求键；格式版本明确隔离旧派生文件。
    nonisolated static func requestKey(_ request: NoteReviewDirectoryRequest) throws -> String {
        var digest = SHA256()
        digest.update(data: Data((request.tagMatchRule.rawValue + ":" + request.sortRule.rawValue).utf8))
        var seed = request.seed.littleEndian
        withUnsafeBytes(of: &seed) { digest.update(bufferPointer: $0) }
        // 迁移旧随机会话时前缀可能很长；逐个哈希现有数组，不再复制成整份 JSON/Data。
        for values in [request.bookIDs, request.tagIDs, request.preservedIDs] {
            var count = Int64(values.count).littleEndian
            withUnsafeBytes(of: &count) { digest.update(bufferPointer: $0) }
            for (offset, value) in values.enumerated() {
                if offset.isMultiple(of: batchLimit) { try Task.checkCancellation() }
                var integer = value.littleEndian
                withUnsafeBytes(of: &integer) { digest.update(bufferPointer: $0) }
            }
        }
        return "directory-v3-" + hex(digest)
    }

    /// 清空仅属于当前句柄的派生表。前缀逐批写入，重复 ID 保留首次位置，不建立全量内存 Set。
    nonisolated static func reset(_ database: DatabaseQueue, request: NoteReviewDirectoryRequest, key: String) async throws {
        try Task.checkCancellation()
        try await database.write { db in
            // SQL：回收当前独占派生代次，不触及业务库；取消中断事务会回滚，不留下假 ready 状态。
            try db.execute(sql: "DELETE FROM records; DELETE FROM positions; DELETE FROM groups; DELETE FROM prefix; DELETE FROM metadata;")
        }
        for start in stride(from: 0, to: request.preservedIDs.count, by: batchLimit) {
            try Task.checkCancellation()
            let batch = Array(request.preservedIDs[start..<min(start + batchLimit, request.preservedIDs.count)])
            try await database.write { db in
                // SQL：用主键去重启动/旧会话前缀；不存在的业务 ID 不会在 records 中出现。
                let statement = try db.makeStatement(sql: "INSERT OR IGNORE INTO prefix(note_id, rank) VALUES (?, ?)")
                for (offset, id) in batch.enumerated() where id > 0 {
                    try statement.execute(arguments: [id, Int64(start + offset)])
                }
            }
        }
        // 前缀完整后才写请求键；中途中断重开必须重置，不能拿半个前缀续建。
        try await database.write { try setMetadata($0, "request", key) }
    }

    /// 同一源快照按主键游标扫描；续建先复核完整已存前缀的 SHA256，而不是 count/MAX(timestamp)。
    nonisolated static func scan(_ database: DatabaseQueue, url: URL, request: NoteReviewDirectoryRequest, byteBudget: Int,
                     reader: Reader, progress: Progress) async throws {
        let saved = try await database.read { db in
            (Int64(try metadata(db, "cursor")) ?? 0, try metadata(db, "digest"),
             try metadata(db, "sourceComplete") == "1", try metadata(db, "mutated") == "1")
        }
        if saved.3 { throw NoteReviewDirectoryError.staleSource }
        var cursor: Int64 = 0
        var processed: Int64 = 0
        var digest = SHA256()
        var verifiedPrefix = saved.0 == 0
        while true {
            try Task.checkCancellation()
            let batch = try await reader(cursor == 0 ? nil : cursor, batchLimit)
            try Task.checkCancellation()
            guard batch.count <= batchLimit else { throw NoteReviewDirectoryError.invalidBatch }
            if batch.isEmpty { break }
            var additions: [NoteReviewDirectoryRecord] = []
            additions.reserveCapacity(batch.count)
            for record in batch {
                guard record.noteID > cursor else { throw NoteReviewDirectoryError.invalidBatch }
                if !verifiedPrefix && record.noteID > saved.0 { throw NoteReviewDirectoryError.staleSource }
                cursor = record.noteID
                updateDigest(&digest, record)
                processed += 1
                if cursor == saved.0 {
                    guard hex(digest) == saved.1 else { throw NoteReviewDirectoryError.staleSource }
                    verifiedPrefix = true
                }
                if cursor > saved.0 {
                    if saved.2 { throw NoteReviewDirectoryError.staleSource }
                    additions.append(record)
                }
            }
            if !additions.isEmpty {
                try checkBudget(url: url, byteBudget: byteBudget)
                let checksum = hex(digest)
                let end = cursor
                let count = processed
                let rows = additions
                try await database.write { db in
                    // SQL：原始元数据批次写入派生索引；排序由固定前缀/seed key/note_id 决定。
                    // 关联 revision 为 Android 毫秒原值；同事务持久化游标和校验摘要，保证可取消续建。
                    let insert = try db.makeStatement(sql: """
                        INSERT INTO records(note_id, book_id, chapter_id, note_revision, book_revision, chapter_revision, prefix_rank, order_key)
                        VALUES (?, ?, ?, ?, ?, ?, COALESCE((SELECT rank - ? FROM prefix WHERE note_id = ?), 0), ?)
                        """)
                    for record in rows {
                        let order = request.sortRule == .random ? randomKey(record.noteID, seed: request.seed) : ~record.bookID
                        try insert.execute(arguments: [record.noteID, record.bookID, record.chapterID, record.noteRevision,
                                                       record.bookRevision, record.chapterRevision, Int64(request.preservedIDs.count), record.noteID, order])
                    }
                    try setMetadata(db, "cursor", String(end))
                    try setMetadata(db, "digest", checksum)
                    try setMetadata(db, "count", String(count))
                }
            }
            try Task.checkCancellation()
            await progress(.scanning(processed: processed))
        }
        guard verifiedPrefix, !saved.2 || hex(digest) == saved.1 else { throw NoteReviewDirectoryError.staleSource }
        try Task.checkCancellation()
        let checksum = hex(digest)
        let count = processed
        try await database.write { db in
            try setMetadata(db, "digest", checksum)
            try setMetadata(db, "count", String(count))
            try setMetadata(db, "sourceComplete", "1")
        }
    }

    /// 按派生排序索引 seek，每批分配最多 1024 个稳定槽位；不在内存排序百万成员。
    nonisolated static func index(_ database: DatabaseQueue, url: URL, byteBudget: Int, progress: Progress) async throws -> Int64 {
        let count = try await database.read { Int64(try metadata($0, "count")) ?? 0 }
        if try await database.read({ try metadata($0, "ready") == "1" }) { return count }
        var indexed = try await database.read { Int64(try metadata($0, "indexed")) ?? 0 }
        await progress(.indexing(processed: indexed))
        while indexed < count {
            try checkBudget(url: url, byteBudget: byteBudget)
            let start = indexed
            indexed = try await database.write { db in
                let cursorRank = Int64(try metadata(db, "orderPrefix")) ?? Int64.min
                let cursorKey = Int64(try metadata(db, "orderKey")) ?? Int64.min
                let cursorID = Int64(try metadata(db, "orderID")) ?? 0
                // SQL：匹配 records_order 的复合游标，无 OFFSET、全表排序或全文读取。
                let rows = try Row.fetchAll(db, sql: """
                    SELECT note_id, prefix_rank, order_key FROM records
                    WHERE (prefix_rank, order_key, note_id) > (?, ?, ?)
                    ORDER BY prefix_rank, order_key, note_id LIMIT 1024
                    """, arguments: [cursorRank, cursorKey, cursorID])
                guard !rows.isEmpty else { throw NoteReviewDirectoryError.invalidBatch }
                // SQL：同事务内写入小型 noteID→slot 映射并保存检查点；元数据主表不做随机更新。
                let update = try db.makeStatement(sql: "INSERT INTO positions(slot, note_id) VALUES (?, ?)")
                for (offset, row) in rows.enumerated() {
                    try update.execute(arguments: [start + Int64(offset), row["note_id"] as Int64])
                }
                let end = start + Int64(rows.count)
                let last = rows[rows.count - 1]
                try setMetadata(db, "indexed", String(end))
                try setMetadata(db, "orderPrefix", String(last["prefix_rank"] as Int64))
                try setMetadata(db, "orderKey", String(last["order_key"] as Int64))
                try setMetadata(db, "orderID", String(last["note_id"] as Int64))
                return end
            }
            try Task.checkCancellation()
            await progress(.indexing(processed: indexed))
        }
        for level in 0...Self.level(for: count) {
            let size = span(level)
            let buckets = max(1, (count + size - 1) / size)
            for start in stride(from: Int64(0), to: buckets, by: batchLimit) {
                try checkBudget(url: url, byteBudget: byteBudget)
                try await database.write { db in
                    // SQL：初次连续槽位可直接算节点数量，避免逐层 GROUP BY 扫描整个 records；续建幂等覆盖计数。
                    let insert = try db.makeStatement(sql: "INSERT OR REPLACE INTO groups(level, bucket, count) VALUES (?, ?, ?)")
                    for bucket in start..<min(buckets, start + Int64(batchLimit)) {
                        try insert.execute(arguments: [Int64(level), bucket, min(size, max(0, count - bucket * size))])
                    }
                }
            }
        }
        try Task.checkCancellation()
        try await database.write { try setMetadata($0, "ready", "1") }
        try checkBudget(url: url, byteBudget: byteBudget)
        return count
    }

    /// 固定 64 位排列键；SQLite 有符号排序配合 noteID 唯一打破并列，不逐批调用 RANDOM()。
    nonisolated static func randomKey(_ id: Int64, seed: UInt64) -> Int64 {
        var value = UInt64(bitPattern: id) &+ seed &+ 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return Int64(bitPattern: value ^ (value >> 31))
    }

    /// 哈希输入固定为六个小端整数，无文本拼接歧义，版本组合不损失信息。
    nonisolated static func updateDigest(_ digest: inout SHA256, _ record: NoteReviewDirectoryRecord) {
        for value in [record.noteID, record.bookID, record.chapterID, record.noteRevision, record.bookRevision, record.chapterRevision] {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { digest.update(bufferPointer: $0) }
        }
    }

    /// 复制 SHA 状态求检查点，不终止仍在继续的流式校验。
    nonisolated static func hex(_ digest: SHA256) -> String { digest.finalize().map { String(format: "%02x", $0) }.joined() }

    /// 仅用整数计算层级，不依赖数量相关浮点误差。
    nonisolated static func level(for count: Int64) -> Int {
        var level = 0
        var capacity: Int64 = 32
        while capacity < count, capacity <= Int64.max / 4 { level += 1; capacity *= 4 }
        return level
    }

    /// 有效 level 由目录根层级限制；叶子覆盖 32 个不可变槽位。
    nonisolated static func span(_ level: Int) -> Int64 { Int64(32) << (2 * level) }

    /// 记录恢复不创建任何正文对象。
    nonisolated static func member(_ row: Row) -> NoteReviewDirectoryMember {
        .init(slot: row["slot"], record: .init(noteID: row["note_id"], bookID: row["book_id"], chapterID: row["chapter_id"],
              noteRevision: row["note_revision"], bookRevision: row["book_revision"], chapterRevision: row["chapter_revision"]))
    }

    /// 字符串只用于固定数量构建检查点，不随书摘数量常驻增长。
    nonisolated static func metadata(_ db: Database, _ key: String) throws -> String {
        // SQL：派生 metadata 主键读取一个检查点；无关联表或时间换算。
        try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = ?", arguments: [key]) ?? ""
    }

    /// 与当前批事务一起保存恢复点；取消不会留下游标领先于数据的状态。
    nonisolated static func setMetadata(_ db: Database, _ key: String, _ value: String) throws {
        // SQL：派生 metadata 单键幂等写入；无业务库副作用。
        try db.execute(sql: "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)", arguments: [key, value])
    }

    /// 每层读取至多四个相邻桶，通过复合主键范围查询跳过空集合。
    nonisolated static func childCounts(_ db: Database, level: Int, bucket: Int64) throws -> [Int64] {
        // SQL：groups 的 (level,bucket) 索引范围最多四行，不扫描完整叶子清单。
        let rows = try Row.fetchAll(db, sql: "SELECT bucket, count FROM groups WHERE level = ? AND bucket >= ? AND bucket < ? ORDER BY bucket",
                                    arguments: [Int64(level), bucket * 4, bucket * 4 + 4])
        var counts = [Int64](repeating: 0, count: 4)
        for row in rows { counts[Int((row["bucket"] as Int64) % 4)] = row["count"] }
        return counts
    }

    /// 沿祖先加总左侧兄弟，得到真实序号，不用 COUNT(slot < target) 扫描百万行。
    nonisolated static func ordinalBeforeGroup(_ db: Database, level: Int, bucket: Int64, rootLevel: Int) throws -> Int64 {
        var current = bucket
        var ordinal: Int64 = 0
        if level < rootLevel {
            for depth in level..<rootLevel {
                ordinal += try childCounts(db, level: depth, bucket: current / 4).prefix(Int(current % 4)).reduce(0, +)
                current /= 4
            }
        }
        return ordinal
    }
}
