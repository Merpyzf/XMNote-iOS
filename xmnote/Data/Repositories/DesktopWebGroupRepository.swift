/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 Room v48 group、group_book、book 表与可注入毫秒时钟
 * [OUTPUT]: 对外提供 Android GroupService/BookService 分组路径可观察语义的专用仓储
 * [POS]: Data 层网页分组仓储；与 App 书架写用例隔离，由 DesktopWebAPIAdapter 映射为 Package DTO
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 分组列表及写操作的数据库业务快照，不让 Data 层反向依赖 XMNoteWeb。
nonisolated struct DesktopWebGroupSnapshot: Equatable, Sendable {
    let id: Int64
    let name: String
    let isPinned: Bool
    let pinOrder: Int
    let order: Int
    let bookCount: Int
    let createdTime: Int64
}

/// 通用分页快照，避免 App Data 层依赖 Package 的分页 DTO。
nonisolated struct DesktopWebPagedSnapshot<Item: Sendable>: Sendable {
    let items: [Item]
    let page: Int
    let pageSize: Int
    let total: Int64
    let totalPages: Int
}

/// 完整书籍投影中的轻量名称引用。
nonisolated struct DesktopWebNamedSnapshot: Equatable, Sendable {
    let id: Int64
    let name: String
}

/// Android WebBookDto 对应的数据库业务快照；cover 暂保留原值，由 Adapter 应用访问码代理规则。
nonisolated struct DesktopWebBookSnapshot: Equatable, Sendable {
    let id: Int64
    let name: String
    let rawName: String
    let cover: String
    let author: String
    let authorIntro: String
    let translator: String
    let summary: String
    let isbn: String
    let press: String
    let pubDate: String
    let doubanId: Int?
    let readStatus: Int
    let readStatusChangedTime: Int64
    let recentReadTime: Int64?
    let readDoneCount: Int
    let score: Int
    let readPosition: Double
    let totalPosition: Int
    let totalPagination: Int
    let currentPositionUnit: Int
    let positionUnit: Int
    let type: Int
    let sourceId: Int64
    let sourceName: String
    let purchaseDate: Int64?
    let price: Double?
    let isPinned: Bool
    let pinOrder: Int
    let order: Int
    let wordCount: Int64?
    let totalReadingTime: Int64
    let createdTime: Int64
    let updatedTime: Int64
    let lastModifiedTime: Int64?
    let noteCount: Int
    let reviewCount: Int
    let relevantCount: Int
    let readDoneTime: Int64?
    let bookmarkModifiedTime: Int64?
    let groups: [DesktopWebNamedSnapshot]
    let tags: [DesktopWebNamedSnapshot]
    let isDeleted: Bool
}

/// 使用独立 SQL 复刻 Android WebGroupRepository/WebBookRepository 的分组路径。
nonisolated struct DesktopWebGroupRepository: Sendable {
    let database: AppDatabase
    let currentTimeMillis: @Sendable () -> Int64

    /// 注入固定数据库和时钟；除 Android 明确使用 withTransaction 的排序外，不扩大事务边界。
    init(
        database: AppDatabase,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.database = database
        self.currentTimeMillis = currentTimeMillis
    }

    /// 分页读取有效分组；故意不按 user_id 过滤，并按置顶、置顶序号、倒序手动序号排列。
    func groups(page: Int, pageSize: Int) async throws -> DesktopWebPagedSnapshot<DesktopWebGroupSnapshot> {
        // NOTE(ANDROID-WEB-006): Android Web 分组接口不按 user_id 隔离；基线阶段保留跨 owner 可见行为。
        let offset = safeOffset(page: page, pageSize: pageSize)
        return try await database.dbPool.read { db in
            // SQL 目的：按 WebBookDao.queryGroupsPaged 查询分组及每组有效书籍数量。
            // 涉及表：`group`、group_book、book；计数只接受每本书最早的有效分组关系。
            // 关键过滤：group/book/relation 均有效，故意不按 user_id 过滤；分页使用 Android 归一化结果。
            // 时间字段：created_date 原样返回毫秒值，不做时区转换。
            // 返回字段用途：WebGroupListDto 列表，排序为 pinned DESC、pin_order ASC、group_order DESC。
            let sql = """
                SELECT g.id,
                       g.name,
                       g.group_order,
                       g.pinned,
                       g.pin_order,
                       g.created_date,
                       (
                           SELECT COUNT(*)
                           FROM group_book gb
                           INNER JOIN book b ON gb.book_id = b.id
                           WHERE gb.group_id = g.id
                             AND gb.is_deleted = 0
                             AND b.is_deleted = 0
                             AND gb.id = (
                                 SELECT gb2.id
                                 FROM group_book gb2
                                 WHERE gb2.book_id = b.id
                                   AND gb2.is_deleted = 0
                                 ORDER BY gb2.created_date ASC, gb2.id ASC
                                 LIMIT 1
                             )
                       ) AS book_count
                FROM `group` g
                WHERE g.is_deleted = 0
                ORDER BY g.pinned DESC, g.pin_order ASC, g.group_order DESC
                LIMIT ? OFFSET ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [pageSize, offset])
            let total = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM `group` WHERE is_deleted = 0"
            ) ?? 0
            return DesktopWebPagedSnapshot(
                items: rows.map(Self.groupSnapshot),
                page: page,
                pageSize: pageSize,
                total: total,
                totalPages: Self.totalPages(total: total, pageSize: pageSize)
            )
        }
    }

    /// 查询完整组内书籍，排序和 DTO 聚合由同一专用仓储执行。
    func booksInGroup(
        id: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPagedSnapshot<DesktopWebBookSnapshot> {
        try await pagedBooksInGroup(
            id: id,
            page: page,
            pageSize: pageSize,
            sortBy: sortBy,
            sortOrder: sortOrder
        )
    }

    /// 创建固定归属 user 1 的分组，新顺序取未分组书籍和分组最小值再减一。
    func createGroup(name rawName: String) async throws -> DesktopWebGroupSnapshot {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("分组名称不能为空")
        }
        // NOTE(ANDROID-WEB-006): Android Web 创建分组固定写入 user_id=1；一致性阶段不改用当前 owner。
        let order = try await database.dbPool.read { db in
            // SQL 目的：计算 WebGroupRepository.calcNewGroupOrder 使用的默认书架最小位置。
            // 涉及表：book、group_book、`group`。
            // 关键过滤：书籍/分组有效，book.id != 0，未分组书籍排除任意有效关系；故意不按 owner 过滤。
            // 返回字段用途：两个 MIN 空值各回退 0，取更小值后减一作为新分组 group_order。
            let bookSQL = """
                SELECT MIN(book_order)
                FROM book
                WHERE is_deleted = 0
                  AND id != 0
                  AND id NOT IN (
                      SELECT book_id
                      FROM group_book
                      WHERE is_deleted = 0
                  )
                """
            let groupSQL = "SELECT MIN(group_order) FROM `group` WHERE is_deleted = 0"
            let bookOrder = try Int64.fetchOne(db, sql: bookSQL) ?? 0
            let groupOrder = try Int64.fetchOne(db, sql: groupSQL) ?? 0
            return min(bookOrder, groupOrder) - 1
        }
        let createdAt = currentTimeMillis()
        let id = try await database.dbPool.write { db in
            // SQL 目的：插入 GroupService.createGroup 构造的默认分组。
            // 涉及表：`group`，通过外键引用 user.id=1。
            // 关键过滤：无；允许重名，pinned/pin_order/is_deleted 固定为 0。
            // 时间字段：created_date 使用当前毫秒，updated_date/last_sync_date 保持 BaseEntity 默认 0。
            // 副作用用途：复刻 Android Web 固定 owner 和自增主键行为。
            let sql = """
                INSERT INTO `group` (
                    user_id, name, group_order, pinned, pin_order,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (1, ?, ?, 0, 0, ?, 0, 0, 0)
                """
            try db.execute(sql: sql, arguments: [name, order, createdAt])
            return db.lastInsertedRowID
        }
        return DesktopWebGroupSnapshot(
            id: id,
            name: name,
            isPinned: false,
            pinOrder: 0,
            order: Int(order),
            bookCount: 0,
            createdTime: createdAt
        )
    }

    /// 更新有效分组名称；Android Web 不做重名检查，也不限制 owner。
    func updateGroup(id: Int64, name rawName: String) async throws -> DesktopWebGroupSnapshot {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("分组名称不能为空")
        }
        let group = try await requireGroup(id: id)
        let updatedAt = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：按 WebGroupDao.updateName 更新分组名称。
            // 涉及表：`group`。
            // 关键过滤：仅按 id 命中；服务层已先确认有效记录，但 DAO 不再限制 is_deleted 或 owner。
            // 时间字段：updated_date 写当前毫秒值。
            // 副作用用途：保存 trim 后名称；允许与其他有效分组重名。
            try db.execute(
                sql: "UPDATE `group` SET name = ?, updated_date = ? WHERE id = ?",
                arguments: [name, updatedAt, id]
            )
        }
        return DesktopWebGroupSnapshot(
            id: group.id,
            name: name,
            isPinned: group.isPinned,
            pinOrder: group.pinOrder,
            order: group.order,
            bookCount: try await countBooks(inGroup: id),
            createdTime: group.createdTime
        )
    }

    /// 在单一事务中删除分组；每本书先移回默认书架，再物理清理关系并软删除主记录。
    func deleteGroup(id: Int64, placeAtEnd: Bool) async throws {
        _ = try await requireGroup(id: id)
        let finalDeleteAt = currentTimeMillis()
        let bookIDs = try await orderedGroupBookIDsForDeletion(groupID: id)
        let orderedIDs = placeAtEnd ? bookIDs : Array(bookIDs.reversed())
        try await database.dbPool.write { db in
            for bookID in orderedIDs where try isActiveBook(id: bookID, db: db) {
                try moveBookOutOfGroup(
                    id: bookID,
                    placeAtEnd: placeAtEnd,
                    db: db
                )
            }
            // SQL 目的：物理删除该分组剩余的全部关系。
            // 涉及表：group_book。
            // 关键过滤：group_id 精确匹配，同时清理历史失效行。
            // 时间字段：关系物理删除不写时间。
            // 副作用用途：释放 v48 book_id 唯一键；与书籍移动、分组删除同事务提交。
            try db.execute(sql: "DELETE FROM group_book WHERE group_id = ?", arguments: [id])

            // SQL 目的：按 WebGroupDao.softDelete 软删除分组主记录。
            // 涉及表：`group`。
            // 关键过滤：仅按 id 命中，不再过滤 owner 或当前删除状态。
            // 时间字段：复用 finalDeleteAt，可能早于逐本移出时产生的时间戳。
            // 副作用用途：让分组从有效查询中消失；任一步失败时整个删除事务回滚。
            try db.execute(
                sql: "UPDATE `group` SET is_deleted = 1, updated_date = ? WHERE id = ?",
                arguments: [finalDeleteAt, id]
            )
        }
    }

    /// 幂等更新分组置顶状态；置顶序号只在分组表内部递增。
    func updateGroupPin(id: Int64, pinned: Bool) async throws -> DesktopWebGroupSnapshot {
        let group = try await requireGroup(id: id)
        guard group.isPinned != pinned else { return group }
        let pinOrder: Int64
        if pinned {
            // NOTE(ANDROID-WEB-015): Web 只看分组最大值；App 会把书籍与分组合并为同一顶层置顶序列。
            let maximum = try await database.dbPool.read { db in
                // SQL 目的：读取全部有效置顶分组的最大 pin_order。
                // 涉及表：`group`。
                // 关键过滤：is_deleted = 0 且 pinned = 1；不包含置顶书籍，也不按 owner 过滤。
                // 返回字段用途：新置顶分组追加到当前分组置顶序列尾部。
                try Int64.fetchOne(
                    db,
                    sql: "SELECT MAX(pin_order) FROM `group` WHERE is_deleted = 0 AND pinned = 1"
                ) ?? 0
            }
            pinOrder = Int64(Int32(truncatingIfNeeded: maximum) &+ 1)
        } else {
            pinOrder = 0
        }
        let updatedAt = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：按 WebGroupDao.updatePinStatus 更新置顶状态。
            // 涉及表：`group`。
            // 关键过滤：仅按 id 命中；服务层已确认有效记录。
            // 时间字段：updated_date 写当前毫秒值。
            // 副作用用途：置顶写 max+1，取消置顶同时把 pin_order 清零。
            let sql = """
                UPDATE `group`
                SET pinned = ?, pin_order = ?, updated_date = ?
                WHERE id = ?
                """
            try db.execute(sql: sql, arguments: [pinned ? 1 : 0, pinOrder, updatedAt, id])
        }
        return try await requireGroup(id: id)
    }

    /// 用同一毫秒值逐项更新分组排序；重复 ID 后写覆盖前写，不存在 ID 静默忽略。
    func reorderGroups(ids: [Int64]) async throws {
        guard !ids.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("排序列表不能为空")
        }
        let updatedAt = currentTimeMillis()
        for (index, id) in ids.enumerated() {
            try await database.dbPool.write { db in
                // SQL 目的：按 WebGroupDao.updateOrder 写入单个分组排序下标。
                // 涉及表：`group`。
                // 关键过滤：仅按 id 命中；不校验有效状态、owner 或 ID 是否存在。
                // 时间字段：同一请求中的全部更新复用 updatedAt。
                // 副作用用途：保留重复 ID 最后一次出现获胜的 Android 行为。
                try db.execute(
                    sql: "UPDATE `group` SET group_order = ?, updated_date = ? WHERE id = ?",
                    arguments: [index, updatedAt, id]
                )
            }
        }
    }

    /// 验证规范化后的 ID 均属于指定分组，再在单一事务中写入连续 book_order。
    func reorderGroupBooks(groupID: Int64, ids: [Int64]) async throws {
        guard groupID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("分组不存在")
        }
        var seen: Set<Int64> = []
        let normalized = ids.filter { $0 > 0 && seen.insert($0).inserted }
        guard !normalized.isEmpty else { return }

        let existing = Set(try await activeBookIDs(inGroup: groupID))
        guard normalized.allSatisfy(existing.contains) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分书籍不属于当前分组")
        }
        let updatedAt = currentTimeMillis()
        try await database.dbPool.write { db in
            for (index, id) in normalized.enumerated() {
                // SQL 目的：按 WebBookRepository.reorderGroupBooks 写入组内书籍顺序。
                // 涉及表：book；groupID 只用于写前归属校验，不参与 UPDATE。
                // 关键过滤：仅按 book.id 命中，不再次限制有效状态或分组关系。
                // 时间字段：同一事务内全部书籍复用 updatedAt。
                // 副作用用途：把去重且为正数的输入按下标写成连续 book_order。
                try db.execute(
                    sql: "UPDATE book SET book_order = ?, updated_date = ? WHERE id = ?",
                    arguments: [index, updatedAt, id]
                )
            }
        }
    }

    /// 读取有效分组及当前有效书籍计数；故意不做 owner 隔离。
    func requireGroup(id: Int64) async throws -> DesktopWebGroupSnapshot {
        let snapshot = try await database.dbPool.read { db -> DesktopWebGroupSnapshot? in
            // SQL 目的：按 WebGroupDao.findById 读取有效分组，并补齐 Web DTO 所需书籍计数。
            // 涉及表：`group`、group_book、book。
            // 关键过滤：group.id 精确匹配且有效；计数沿用每本书最早有效关系规则；不按 owner 过滤。
            // 时间字段：created_date 原样返回毫秒值。
            // 返回字段用途：分组编辑、删除、置顶前置校验及响应。
            let sql = """
                SELECT g.id,
                       g.name,
                       g.group_order,
                       g.pinned,
                       g.pin_order,
                       g.created_date,
                       (
                           SELECT COUNT(*)
                           FROM group_book gb
                           INNER JOIN book b ON gb.book_id = b.id
                           WHERE gb.group_id = g.id
                             AND gb.is_deleted = 0
                             AND b.is_deleted = 0
                             AND gb.id = (
                                 SELECT gb2.id
                                 FROM group_book gb2
                                 WHERE gb2.book_id = b.id
                                   AND gb2.is_deleted = 0
                                 ORDER BY gb2.created_date ASC, gb2.id ASC
                                 LIMIT 1
                             )
                       ) AS book_count
                FROM `group` g
                WHERE g.id = ? AND g.is_deleted = 0
                """
            return try Row.fetchOne(db, sql: sql, arguments: [id]).map(Self.groupSnapshot)
        }
        guard let snapshot else {
            throw DesktopWebCatalogRepositoryError.notFound("分组不存在: \(id)")
        }
        return snapshot
    }

    private func countBooks(inGroup id: Int64) async throws -> Int {
        return try await database.dbPool.read { db in
            // SQL 目的：按 WebBookDao.countBooksInGroup 统计分组有效书籍。
            // 涉及表：book、group_book。
            // 关键过滤：书籍与关系有效、group_id 匹配，并只接受每本书最早的有效分组关系。
            // 返回字段用途：更新分组名称后的 WebGroupListDto.bookCount。
            let sql = """
                SELECT COUNT(*)
                FROM book b
                INNER JOIN group_book gb ON b.id = gb.book_id
                WHERE b.is_deleted = 0
                  AND gb.is_deleted = 0
                  AND gb.group_id = ?
                  AND gb.id = (
                      SELECT gb2.id
                      FROM group_book gb2
                      WHERE gb2.book_id = b.id AND gb2.is_deleted = 0
                      ORDER BY gb2.created_date ASC, gb2.id ASC
                      LIMIT 1
                  )
                """
            return try Int.fetchOne(db, sql: sql, arguments: [id]) ?? 0
        }
    }

    private func activeBookIDs(inGroup id: Int64) async throws -> [Int64] {
        try await database.dbPool.read { db in
            // SQL 目的：按 WebBookDao.queryBookIdsInGroup 读取当前分组可参与排序的书籍 ID。
            // 涉及表：book、group_book。
            // 关键过滤：书籍/关系有效、group_id 匹配，且关系必须是该书最早的有效关系。
            // 返回字段用途：reorderGroupBooks 的归属校验；顺序按 book_order ASC。
            let sql = """
                SELECT b.id
                FROM book b
                INNER JOIN group_book gb ON b.id = gb.book_id
                WHERE b.is_deleted = 0
                  AND gb.is_deleted = 0
                  AND gb.group_id = ?
                  AND gb.id = (
                      SELECT gb2.id
                      FROM group_book gb2
                      WHERE gb2.book_id = b.id AND gb2.is_deleted = 0
                      ORDER BY gb2.created_date ASC, gb2.id ASC
                      LIMIT 1
                  )
                ORDER BY b.book_order ASC
                """
            return try Int64.fetchAll(db, sql: sql, arguments: [id])
        }
    }

    private func orderedGroupBookIDsForDeletion(groupID: Int64) async throws -> [Int64] {
        let books = try await baseBooks(inGroup: groupID)
        let pinned = books.filter { $0.pinned == 1 }.sorted {
            if $0.pinOrder != $1.pinOrder { return $0.pinOrder > $1.pinOrder }
            if $0.bookOrder != $1.bookOrder { return $0.bookOrder < $1.bookOrder }
            return ($0.id ?? 0) < ($1.id ?? 0)
        }
        let regular = books.filter { $0.pinned != 1 }.sorted {
            if $0.bookOrder != $1.bookOrder { return $0.bookOrder < $1.bookOrder }
            return ($0.id ?? 0) < ($1.id ?? 0)
        }
        return (pinned + regular).compactMap(\.id)
    }

    private func isActiveBook(id: Int64, db: Database) throws -> Bool {
        // SQL 目的：按 WebBookDao.findById 后的 Service 条件确认书籍仍有效。
        // 涉及表：book。
        // 关键过滤：id 精确匹配且 id != 0；这里合并 Service 的 is_deleted == 0 判断。
        // 返回字段用途：删除分组事务中跳过缺失或已删除书籍。
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM book WHERE id = ? AND id != 0 AND is_deleted = 0)",
            arguments: [id]
        ) ?? false
    }

    private func moveBookOutOfGroup(
        id: Int64,
        placeAtEnd: Bool,
        db: Database
    ) throws {
        let updatedAt = currentTimeMillis()
        // SQL 目的：移出分组前取消书籍置顶。
        // 涉及表：book。
        // 关键过滤：id 匹配、书籍有效且 id != 0。
        // 时间字段：updated_date 写本书移动流程的同一毫秒值。
        // 副作用用途：清空 pinned/pin_order；与后续关系和排序写入同事务。
        let pinSQL = """
            UPDATE book
            SET pinned = 0, pin_order = 0, updated_date = ?
            WHERE id = ? AND is_deleted = 0 AND id != 0
            """
        try db.execute(sql: pinSQL, arguments: [updatedAt, id])

        let boundaryOrder = try topLevelBoundaryOrder(
            placeAtEnd: placeAtEnd,
            db: db
        )

        // SQL 目的：物理移除该书的全部分组关系。
        // 涉及表：group_book。
        // 关键过滤：book_id 精确匹配，同时清理历史失效行，不只删除当前分组关系。
        // 时间字段：关系物理删除不写时间。
        // 副作用用途：让书籍回到默认书架；与取消置顶、排序更新同事务。
        try db.execute(sql: "DELETE FROM group_book WHERE book_id = ?", arguments: [id])

        // SQL 目的：把移出分组书籍放到默认书架边界位置。
        // 涉及表：book。
        // 关键过滤：仅按 id 命中；边界值在关系仍有效时已预先计算。
        // 时间字段：复用本书移动流程的 updatedAt。
        // 副作用用途：placeAtEnd=true 写最大值+1，否则写最小值-1。
        try db.execute(
            sql: "UPDATE book SET book_order = ?, updated_date = ? WHERE id = ?",
            arguments: [boundaryOrder, updatedAt, id]
        )
    }

    func topLevelBoundaryOrder(placeAtEnd: Bool) async throws -> Int64 {
        try await database.dbPool.read { db in
            try topLevelBoundaryOrder(placeAtEnd: placeAtEnd, db: db)
        }
    }

    private func topLevelBoundaryOrder(
        placeAtEnd: Bool,
        db: Database
    ) throws -> Int64 {
        // SQL 目的：读取默认书架未分组有效书籍的排序边界。
        // 涉及表：book、group_book。
        // 关键过滤：book 有效且 id != 0，并排除任意有效分组关系；当前待移书仍有关系，故不污染边界。
        // 返回字段用途：与有效分组边界合并后加一或减一；空集合回退 0。
        let aggregate = placeAtEnd ? "MAX" : "MIN"
        let bookSQL = """
            SELECT \(aggregate)(book_order)
            FROM book
            WHERE is_deleted = 0
              AND id != 0
              AND id NOT IN (
                  SELECT gb.book_id
                  FROM group_book gb
                  INNER JOIN `group` g ON g.id = gb.group_id
                  WHERE gb.is_deleted = 0 AND g.is_deleted = 0
              )
            """
        // SQL 目的：读取有效分组的排序边界，与顶层书籍共享默认书架排序空间。
        // 涉及表：`group`。
        // 关键过滤：is_deleted = 0；不按 owner 过滤。
        // 返回字段用途：与 book 边界取 max/min 后向外扩展一个位置。
        let groupSQL = "SELECT \(aggregate)(group_order) FROM `group` WHERE is_deleted = 0"
        let bookBoundary = try Int64.fetchOne(db, sql: bookSQL) ?? 0
        let groupBoundary = try Int64.fetchOne(db, sql: groupSQL) ?? 0
        return placeAtEnd
            ? max(bookBoundary, groupBoundary) + 1
            : min(bookBoundary, groupBoundary) - 1
    }

    func baseBooks(inGroup id: Int64) async throws -> [BookRecord] {
        guard id > 0, (try? await requireGroup(id: id)) != nil else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("分组不存在")
        }
        return try await database.dbPool.read { db in
            // SQL 目的：按 WebBookRepository.queryAllBooksForSection 读取指定分组全部有效书籍。
            // 涉及表：book、group_book EXISTS 子查询。
            // 关键过滤：服务层已确认目标分组有效；book.is_deleted = 0、id != 0 且关系有效。
            // 返回字段用途：Swift 层执行 Android BookService 的稳定排序、分页和完整 DTO 聚合。
            return try BookRecord.fetchAll(
                db,
                sql: """
                    SELECT b.*
                    FROM book b
                    WHERE b.is_deleted = 0
                      AND b.id != 0
                      AND EXISTS (
                          SELECT 1
                          FROM group_book gb
                          WHERE gb.book_id = b.id
                            AND gb.is_deleted = 0
                            AND gb.group_id = ?
                      )
                    """,
                arguments: [id]
            )
        }.sorted {
            if $0.bookOrder != $1.bookOrder { return $0.bookOrder < $1.bookOrder }
            return ($0.id ?? 0) < ($1.id ?? 0)
        }
    }

    private static func groupSnapshot(_ row: Row) -> DesktopWebGroupSnapshot {
        DesktopWebGroupSnapshot(
            id: row["id"],
            name: (row["name"] as String?) ?? "",
            isPinned: (row["pinned"] as Int64) == 1,
            pinOrder: Int(row["pin_order"] as Int64),
            order: Int(row["group_order"] as Int64),
            bookCount: Int(row["book_count"] as Int64),
            createdTime: row["created_date"]
        )
    }

    private func safeOffset(page: Int, pageSize: Int) -> Int {
        let value = (Int64(max(1, page)) - 1) * Int64(max(1, pageSize))
        return Int(min(value, Int64(Int32.max)))
    }

    static func totalPages(total: Int64, pageSize: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((total + Int64(pageSize) - 1) / Int64(pageSize))
    }
}
