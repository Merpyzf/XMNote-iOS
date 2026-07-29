/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 V44 source、book、tag、tag_note、tag_book 表与可注入毫秒时钟
 * [OUTPUT]: 对外提供 Android Web SourceService/TagService 可观察语义的专用目录仓储
 * [POS]: Data 层网页目录仓储；与 App 标签管理业务隔离，由 DesktopWebAPIAdapter 映射为 Package DTO
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 网页目录仓储可分类失败，由 Adapter 转换为 Android Web 固定业务错误码。
enum DesktopWebCatalogRepositoryError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case notFound(String)
    case duplicate(String)
    case invalidDatabaseValue(String)
}

/// 来源的数据库业务快照，不让 Data 层反向依赖 XMNoteWeb 的公开 DTO。
struct DesktopWebSourceSnapshot: Equatable, Sendable {
    let id: Int64
    let name: String
    let order: Int
    let isHidden: Bool
    let isDefault: Bool
    let bookCount: Int
    let createdTime: Int64
    let updatedTime: Int64
}

/// 标签列表的数据库业务快照，包含 Android Web 同时返回的两类关联数量。
struct DesktopWebTagSnapshot: Equatable, Sendable {
    let id: Int64
    let name: String
    let type: Int
    let order: Int
    let noteCount: Int
    let bookCount: Int
    let createdTime: Int64
}

/// 标签新增或编辑结果，不携带只有列表接口才需要的关联统计。
struct DesktopWebTagMutationSnapshot: Equatable, Sendable {
    let id: Int64
    let name: String
    let type: Int
    let order: Int
}

/// 使用独立 SQL 复刻 Android WebSourceRepository/WebTagRepository，避免污染 App 端既有业务规则。
nonisolated struct DesktopWebCatalogRepository: Sendable {
    private static let presetSourceMaxID: Int64 = 27
    private static let unknownSourceID: Int64 = 1

    private let database: AppDatabase
    private let currentTimeMillis: @Sendable () -> Int64

    /// 注入固定数据库和时钟；数据库连接池负责并发，调用取消不会自动回滚已完成的 Android 分步写入。
    init(
        database: AppDatabase,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.database = database
        self.currentTimeMillis = currentTimeMillis
    }

    /// 读取全部或仅可见的有效来源，并逐项统计有效书籍数量。
    func sources(showAll: Bool) async throws -> [DesktopWebSourceSnapshot] {
        let records = try await database.dbPool.read { db in
            // SQL 目的：按 Android WebSourceDao.queryAll/queryVisible 读取来源列表。
            // 涉及表：source。
            // 关键过滤：始终要求 is_deleted = 0；showAll=false 时额外要求 is_hide = 0。
            // 时间字段：created_date/updated_date 原样返回毫秒值，不做时区转换。
            // 返回字段用途：完整 SourceRecord 用于组装 WebSourceDto，排序仅按 source_order ASC。
            let sql = showAll
                ? "SELECT * FROM source WHERE is_deleted = 0 ORDER BY source_order ASC"
                : "SELECT * FROM source WHERE is_deleted = 0 AND is_hide = 0 ORDER BY source_order ASC"
            return try SourceRecord.fetchAll(db, sql: sql)
        }
        var result: [DesktopWebSourceSnapshot] = []
        result.reserveCapacity(records.count)
        for record in records {
            result.append(try await sourceSnapshot(record))
        }
        return result
    }

    /// 读取单个有效来源；不存在时返回 Android 40002 对应的分类错误。
    func source(id: Int64) async throws -> DesktopWebSourceSnapshot {
        let record = try await requireSource(id: id)
        return try await sourceSnapshot(record)
    }

    /// 按 Android 分步查询、插入、回读流程创建来源，不额外建立跨步骤事务。
    func createSource(name rawName: String) async throws -> DesktopWebSourceSnapshot {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("来源名称不能为空")
        }
        guard try await sourceNameCount(name: name, excluding: 0) == 0 else {
            throw DesktopWebCatalogRepositoryError.duplicate("来源名称已存在: \(name)")
        }
        let maxOrder = try await maximumSourceOrder()
        let createdAt = currentTimeMillis()
        let id = try await database.dbPool.write { db in
            // SQL 目的：插入 Android SourceService.createSource 构造的自定义来源。
            // 涉及表：source。
            // 关键过滤：无；主键由 SQLite 自增，is_hide/is_deleted 固定为 0，bookshelf_order 保持实体默认 -1。
            // 时间字段：created_date 使用服务调用时毫秒值；updated_date/last_sync_date 保持 Android BaseEntity 默认 0。
            // 副作用用途：新增来源并返回 rowid，source_order 为当前有效来源最大值加一。
            let sql = """
                INSERT INTO source (
                    name, source_order, bookshelf_order, is_hide,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, -1, 0, ?, 0, 0, 0)
                """
            try db.execute(sql: sql, arguments: [name, maxOrder + 1, createdAt])
            return db.lastInsertedRowID
        }
        return try await source(id: id)
    }

    /// 按可选字段依次更新名称与可见性，每条 SQL 独立写入并各自读取毫秒时钟。
    func updateSource(id: Int64, name rawName: String?, isHidden: Bool?) async throws -> DesktopWebSourceSnapshot {
        _ = try await requireSource(id: id)
        if let rawName {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("来源名称不能为空")
            }
            guard try await sourceNameCount(name: name, excluding: id) == 0 else {
                throw DesktopWebCatalogRepositoryError.duplicate("来源名称已存在: \(name)")
            }
            let updatedAt = currentTimeMillis()
            try await database.dbPool.write { db in
                // SQL 目的：按 Android WebSourceDao.rename 更新来源名称。
                // 涉及表：source。
                // 关键过滤：仅按 id 命中；服务层已先确认有效来源，但 DAO 本身不再过滤 is_deleted。
                // 时间字段：updated_date 写当前毫秒值，其他时间字段不变。
                // 副作用用途：保存 trim 后名称；若并发删除发生，Android 同样允许 UPDATE 命中已删除行。
                let sql = "UPDATE source SET name = ?, updated_date = ? WHERE id = ?"
                try db.execute(sql: sql, arguments: [name, updatedAt, id])
            }
        }
        if let isHidden {
            let updatedAt = currentTimeMillis()
            try await database.dbPool.write { db in
                // SQL 目的：按 Android WebSourceDao.updateVisibility 更新来源显隐。
                // 涉及表：source。
                // 关键过滤：仅按 id 命中，不额外过滤软删除状态。
                // 时间字段：updated_date 写当前毫秒值，其他时间字段不变。
                // 副作用用途：把 Bool 映射为 Room 使用的 1/0 is_hide 值。
                let sql = "UPDATE source SET is_hide = ?, updated_date = ? WHERE id = ?"
                try db.execute(sql: sql, arguments: [isHidden ? 1 : 0, updatedAt, id])
            }
        }
        return try await source(id: id)
    }

    /// 拒绝删除预置来源；自定义来源先迁移有效书籍，再软删除来源，保持 Android 非事务步骤顺序。
    func deleteSource(id: Int64) async throws {
        _ = try await requireSource(id: id)
        guard id > Self.presetSourceMaxID else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("预置来源不可删除，仅可隐藏")
        }
        let reassignAt = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：删除自定义来源前，把它关联的有效书籍回退到未知来源 1。
            // 涉及表：book。
            // 关键过滤：source_id = 待删来源且 book.is_deleted = 0；已删除书籍保持原 source_id。
            // 时间字段：updated_date 写当前毫秒值，其他字段不变。
            // 副作用用途：避免有效书籍继续引用即将软删除的来源；与后续来源软删除不组成跨语句事务。
            let sql = """
                UPDATE book
                SET source_id = ?, updated_date = ?
                WHERE source_id = ? AND is_deleted = 0
                """
            try db.execute(sql: sql, arguments: [Self.unknownSourceID, reassignAt, id])
        }
        let deleteAt = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：按 Android WebSourceDao.softDelete 标记自定义来源删除。
            // 涉及表：source。
            // 关键过滤：仅按 id 命中，服务层已确认它是有效且非预置来源。
            // 时间字段：updated_date 写当前毫秒值，last_sync_date 保持不变。
            // 副作用用途：保留同步 tombstone，同时从后续 Web 来源查询中移除。
            let sql = "UPDATE source SET is_deleted = 1, updated_date = ? WHERE id = ?"
            try db.execute(sql: sql, arguments: [deleteAt, id])
        }
    }

    /// 按输入下标逐条更新来源顺序；重复 ID 后写覆盖前写，不存在 ID 静默忽略。
    func reorderSources(ids: [Int64]) async throws {
        guard !ids.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("排序列表不能为空")
        }
        for (index, id) in ids.enumerated() {
            let updatedAt = currentTimeMillis()
            try await database.dbPool.write { db in
                // SQL 目的：按 Android WebSourceDao.updateOrder 写入单个来源排序下标。
                // 涉及表：source。
                // 关键过滤：仅按 id 命中；不校验软删除、预置身份或 ID 是否存在。
                // 时间字段：每次 DAO 调用各自写入当前毫秒 updated_date。
                // 副作用用途：保留输入重复项“最后一次出现获胜”和缺失 ID 静默忽略的行为。
                let sql = "UPDATE source SET source_order = ?, updated_date = ? WHERE id = ?"
                try db.execute(sql: sql, arguments: [index, updatedAt, id])
            }
        }
    }

    /// 读取 type=0 的全部有效标签或指定类型标签，并批量统计有效关系数量。
    func tags(type: Int) async throws -> [DesktopWebTagSnapshot] {
        // NOTE(ANDROID-WEB-005): Android Web 标签接口不按 user_id 隔离；基线阶段原样保留跨用户可见行为。
        try await database.dbPool.read { db in
            // SQL 目的：按 Android WebTagDao.queryTags 读取标签并同时统计两类有效关联。
            // 涉及表：tag、tag_note、tag_book；两个聚合子查询避免关系表笛卡尔积放大计数。
            // 关键过滤：tag.is_deleted = 0；type=0 返回全部，否则按 type 精确过滤；故意不按 user_id 过滤。
            // 时间字段：created_date 原样返回毫秒值；updated_date 不属于 WebTagFullDto。
            // 返回字段用途：标签列表的 id/name/type/order、noteCount/bookCount/createdTime，排序仅 tag_order ASC。
            let sql = """
                SELECT t.id,
                       t.name,
                       t.type,
                       t.tag_order,
                       t.created_date,
                       COALESCE(n.note_count, 0) AS note_count,
                       COALESCE(b.book_count, 0) AS book_count
                FROM tag t
                LEFT JOIN (
                    SELECT tag_id, COUNT(*) AS note_count
                    FROM tag_note
                    WHERE is_deleted = 0
                    GROUP BY tag_id
                ) n ON n.tag_id = t.id
                LEFT JOIN (
                    SELECT tag_id, COUNT(*) AS book_count
                    FROM tag_book
                    WHERE is_deleted = 0
                    GROUP BY tag_id
                ) b ON b.tag_id = t.id
                WHERE t.is_deleted = 0
                  AND (? = 0 OR t.type = ?)
                ORDER BY t.tag_order ASC
                """
            return try Row.fetchAll(db, sql: sql, arguments: [type, type]).map { row in
                guard let name: String = row["name"] else {
                    throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("标签名称为空")
                }
                return DesktopWebTagSnapshot(
                    id: row["id"],
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: Int(row["type"] as Int64),
                    order: Int(row["tag_order"] as Int64),
                    noteCount: Int(row["note_count"] as Int64),
                    bookCount: Int(row["book_count"] as Int64),
                    createdTime: row["created_date"]
                )
            }
        }
    }

    /// 创建标签；故意固定 user_id=1，保留 Android Web 当前跨用户缺陷作为一致性基线。
    func createTag(name rawName: String, type: Int) async throws -> DesktopWebTagMutationSnapshot {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("标签名称不能为空")
        }
        guard type == 1 || type == 2 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("标签类型无效")
        }
        guard try await tagNameCount(name: name, type: type, excluding: nil) == 0 else {
            throw DesktopWebCatalogRepositoryError.duplicate("标签名称已存在: \(name)")
        }
        let order = try await maximumTagOrder(type: type) + 1
        let createdAt = currentTimeMillis()
        let id = try await database.dbPool.write { db in
            // SQL 目的：插入 Android TagService.createTag 构造的标签。
            // 涉及表：tag，并通过 V44 外键引用 user.id=1。
            // 关键过滤：无；故意把 user_id 固定为 1，color/is_deleted 固定为 0。
            // 时间字段：created_date 使用当前毫秒；updated_date/last_sync_date 保持 BaseEntity 默认 0。
            // 副作用用途：复刻 Android Web 未使用当前 owner 的既有行为（ANDROID-WEB-005）。
            let sql = """
                INSERT INTO tag (
                    user_id, name, color, tag_order, type,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (1, ?, 0, ?, ?, ?, 0, 0, 0)
                """
            try db.execute(sql: sql, arguments: [name, order, type, createdAt])
            return db.lastInsertedRowID
        }
        return DesktopWebTagMutationSnapshot(id: id, name: name, type: type, order: order)
    }

    /// 更新任意 owner 的有效标签名称；判重同样不按 owner 过滤。
    func updateTag(id: Int64, name rawName: String) async throws -> DesktopWebTagMutationSnapshot {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("标签名称不能为空")
        }
        let tag = try await requireTag(id: id)
        guard try await tagNameCount(name: name, type: tag.type, excluding: id) == 0 else {
            throw DesktopWebCatalogRepositoryError.duplicate("标签名称已存在: \(name)")
        }
        let updatedAt = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：按 Android WebTagDao.updateName 更新标签名称。
            // 涉及表：tag。
            // 关键过滤：仅按 id 命中；故意不限制 user_id、type 或 is_deleted。
            // 时间字段：updated_date 写当前毫秒值，其他时间字段不变。
            // 副作用用途：保存 trim 后标签名，复刻 Web API 可编辑其他 owner 标签的行为。
            let sql = "UPDATE tag SET name = ?, updated_date = ? WHERE id = ?"
            try db.execute(sql: sql, arguments: [name, updatedAt, id])
        }
        return DesktopWebTagMutationSnapshot(id: id, name: name, type: tag.type, order: tag.order)
    }

    /// 按标签类型在一个事务中软删除对应关系与标签主记录。
    func deleteTag(id: Int64) async throws {
        let tag = try await requireTag(id: id)
        let updatedAt = currentTimeMillis()
        try await database.dbPool.write { db in
            let relationTable = tag.type == 1 ? "tag_note" : "tag_book"
            // SQL 目的：按标签类型软删除其当前有效关系。
            // 涉及表：type=1 使用 tag_note，其他类型使用 tag_book。
            // 关键过滤：tag_id 精确匹配且 is_deleted=0。
            // 时间字段：updated_date 与标签主记录共用同一毫秒值。
            // 副作用用途：关系和主记录任一步失败时整体回滚。
            try db.execute(
                sql: """
                    UPDATE \(relationTable)
                    SET is_deleted = 1, updated_date = ?
                    WHERE tag_id = ? AND is_deleted = 0
                    """,
                arguments: [updatedAt, id]
            )
            // SQL 目的：按 Android WebTagDao.softDelete 标记标签主记录删除。
            // 涉及表：tag。
            // 关键过滤：仅按 id 命中；服务层已确认有效，但故意不限制 owner/type。
            // 时间字段：updated_date 写当前毫秒，last_sync_date 保持不变。
            // 副作用用途：让标签和对应关系在同一事务中失效。
            let sql = "UPDATE tag SET is_deleted = 1, updated_date = ? WHERE id = ?"
            try db.execute(sql: sql, arguments: [updatedAt, id])
        }
    }

    /// 用同一毫秒值逐条更新标签顺序；重复 ID 后写覆盖前写，不存在 ID 静默忽略。
    func reorderTags(ids: [Int64]) async throws {
        guard !ids.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("排序列表不能为空")
        }
        let updatedAt = currentTimeMillis()
        for (index, id) in ids.enumerated() {
            try await database.dbPool.write { db in
                // SQL 目的：按 Android WebTagDao.updateOrder 写入单个标签排序下标。
                // 涉及表：tag。
                // 关键过滤：仅按 id 命中；故意不限制 owner、type 或 is_deleted。
                // 时间字段：同一 reorder 请求中的所有 UPDATE 共用一次 now 毫秒值。
                // 副作用用途：保留重复 ID 最后获胜、缺失 ID 静默忽略及跨 owner 排序能力。
                let sql = "UPDATE tag SET tag_order = ?, updated_date = ? WHERE id = ?"
                try db.execute(sql: sql, arguments: [index, updatedAt, id])
            }
        }
    }
}

private extension DesktopWebCatalogRepository {
    /// 读取有效来源实体，不存在时产生带 ID 的 Android 文案。
    func requireSource(id: Int64) async throws -> SourceRecord {
        let record = try await database.dbPool.read { db in
            // SQL 目的：按 Android WebSourceDao.findById 读取一个有效来源。
            // 涉及表：source。
            // 关键过滤：id 精确匹配且 is_deleted = 0。
            // 时间字段：完整 Record 原样读取，毫秒值不转换。
            // 返回字段用途：详情、更新和删除前置存在性检查。
            let sql = "SELECT * FROM source WHERE id = ? AND is_deleted = 0 LIMIT 1"
            return try SourceRecord.fetchOne(db, sql: sql, arguments: [id])
        }
        guard let record else {
            throw DesktopWebCatalogRepositoryError.notFound("来源不存在: \(id)")
        }
        return record
    }

    /// 统计同名有效来源，可按 ID 排除当前编辑对象。
    func sourceNameCount(name: String, excluding id: Int64) async throws -> Int {
        try await database.dbPool.read { db in
            // SQL 目的：按 Android WebSourceDao.countByName 判断来源重名。
            // 涉及表：source。
            // 关键过滤：name 完全匹配、is_deleted = 0 且 id != excludeId；大小写由 SQLite 默认 BINARY 决定。
            // 时间字段：不参与查询。
            // 返回字段用途：大于 0 时映射为 40003 DuplicateResourceException。
            let sql = "SELECT COUNT(*) FROM source WHERE name = ? AND is_deleted = 0 AND id != ?"
            return Int(try Int64.fetchOne(db, sql: sql, arguments: [name, id]) ?? 0)
        }
    }

    /// 读取有效来源最大 source_order，空表返回 0。
    func maximumSourceOrder() async throws -> Int {
        try await database.dbPool.read { db in
            // SQL 目的：按 Android WebSourceDao.queryMaxOrder 计算新来源顺序。
            // 涉及表：source。
            // 关键过滤：is_deleted = 0；隐藏来源仍参与最大值。
            // 时间字段：不参与查询。
            // 返回字段用途：NULL 归零后加一作为新增 source_order。
            let sql = "SELECT MAX(source_order) FROM source WHERE is_deleted = 0"
            return Int(try Int64.fetchOne(db, sql: sql) ?? 0)
        }
    }

    /// 把来源 Record 与有效书籍数量组合为 Data 层快照。
    func sourceSnapshot(_ record: SourceRecord) async throws -> DesktopWebSourceSnapshot {
        guard let id = record.id else {
            throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("来源主键为空")
        }
        let bookCount = try await database.dbPool.read { db in
            // SQL 目的：按 Android WebSourceDao.countBooks 统计来源下有效书籍。
            // 涉及表：book。
            // 关键过滤：source_id 精确匹配且 book.is_deleted = 0。
            // 时间字段：不参与统计。
            // 返回字段用途：WebSourceDto.bookCount；不限制 book.user_id。
            let sql = "SELECT COUNT(*) FROM book WHERE source_id = ? AND is_deleted = 0"
            return Int(try Int64.fetchOne(db, sql: sql, arguments: [id]) ?? 0)
        }
        return DesktopWebSourceSnapshot(
            id: id,
            name: record.name,
            order: Int(record.sourceOrder),
            isHidden: record.isHide != 0,
            isDefault: id <= Self.presetSourceMaxID,
            bookCount: bookCount,
            createdTime: record.createdDate,
            updatedTime: record.updatedDate
        )
    }

    /// 读取任意 owner 的有效标签与更新结果需要的类型/顺序。
    func requireTag(id: Int64) async throws -> (type: Int, order: Int) {
        // NOTE(ANDROID-WEB-005): Android Web 按 id 查找标签时不验证 user_id；基线阶段原样保留。
        let tag = try await database.dbPool.read { db -> (type: Int, order: Int)? in
            // SQL 目的：按 Android WebTagDao.findById 读取有效标签。
            // 涉及表：tag。
            // 关键过滤：id 精确匹配且 is_deleted = 0；故意不限制 user_id/type。
            // 时间字段：不参与查询。
            // 返回字段用途：更新时保留原 type/tag_order，删除时只做存在性检查。
            let sql = "SELECT type, tag_order FROM tag WHERE id = ? AND is_deleted = 0 LIMIT 1"
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [id]) else {
                return nil
            }
            return (Int(row["type"] as Int64), Int(row["tag_order"] as Int64))
        }
        guard let tag else {
            throw DesktopWebCatalogRepositoryError.notFound("标签不存在: \(id)")
        }
        return tag
    }

    /// 统计同类型同名有效标签，可选排除当前 ID，故意不按 owner 隔离。
    func tagNameCount(name: String, type: Int, excluding id: Int64?) async throws -> Int {
        // NOTE(ANDROID-WEB-005): 判重横跨所有 user_id，可能阻止不同用户使用同名标签；为双端基线原样保留。
        return try await database.dbPool.read { db in
            if let id {
                // SQL 目的：按 Android WebTagDao.countByNameExcludeId 检查编辑标签重名。
                // 涉及表：tag。
                // 关键过滤：name/type 完全匹配、id != 当前标签、is_deleted = 0；故意不限制 user_id。
                // 时间字段：不参与查询。
                // 返回字段用途：大于 0 时映射为 40003。
                let sql = """
                    SELECT COUNT(*) FROM tag
                    WHERE name = ? AND type = ? AND id != ? AND is_deleted = 0
                    """
                return Int(try Int64.fetchOne(db, sql: sql, arguments: [name, type, id]) ?? 0)
            }
            // SQL 目的：按 Android WebTagDao.countByName 检查新增标签重名。
            // 涉及表：tag。
            // 关键过滤：name/type 完全匹配且 is_deleted = 0；故意不限制 user_id。
            // 时间字段：不参与查询。
            // 返回字段用途：大于 0 时映射为 40003。
            let sql = "SELECT COUNT(*) FROM tag WHERE name = ? AND type = ? AND is_deleted = 0"
            return Int(try Int64.fetchOne(db, sql: sql, arguments: [name, type]) ?? 0)
        }
    }

    /// 读取指定类型有效标签的最大 tag_order，空集合返回 0。
    func maximumTagOrder(type: Int) async throws -> Int {
        // NOTE(ANDROID-WEB-005): 最大顺序横跨所有 owner，新增标签顺序受其他用户数据影响；基线阶段原样保留。
        try await database.dbPool.read { db in
            // SQL 目的：按 Android WebTagDao.getMaxOrder 计算新增标签排序值。
            // 涉及表：tag。
            // 关键过滤：type 精确匹配且 is_deleted = 0；故意不限制 user_id。
            // 时间字段：不参与查询。
            // 返回字段用途：IFNULL(MAX(tag_order), 0) 后加一。
            let sql = "SELECT IFNULL(MAX(tag_order), 0) FROM tag WHERE type = ? AND is_deleted = 0"
            return Int(try Int64.fetchOne(db, sql: sql, arguments: [type]) ?? 0)
        }
    }
}
