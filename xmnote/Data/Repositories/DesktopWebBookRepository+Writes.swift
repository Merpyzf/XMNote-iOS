/**
 * [INPUT]: 依赖 DesktopWebBookRepository、V44 书籍及 17 类关联表、可注入毫秒时钟与新增位置偏好
 * [OUTPUT]: 提供 Android BookService 删除、置顶与恢复书架的可观察数据库语义
 * [POS]: Data 层网页书籍写入扩展；Package 只经能力端口调用，不接触 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android WebBookPinResultDto 对应的 App 数据层快照。
nonisolated struct DesktopWebBookPinSnapshot: Equatable, Sendable {
    let id: Int64
    let isPinned: Bool
    let pinOrder: Int
}

nonisolated extension DesktopWebBookRepository {
    /// 先校验有效书籍，再在单一 GRDB 写事务内按 Android App Repository 顺序清理主记录和关联；取消不会中断已进入的同步事务。
    func deleteBook(id: Int64) async throws {
        _ = try await activeBookForMutation(id: id)
        // NOTE(ANDROID-WEB-008): Android Web 仅按书籍 ID 写入，不校验 owner；基线阶段保留跨 owner 删除。
        // NOTE(ANDROID-WEB-013): Android 级联删除会重写多类既有 tombstone 的 updated_date。
        try await database.dbPool.write { db in
            // SQL 目的：按 BookDao.deleteBook 软删除有效且非占位书籍主记录。
            // 涉及表：book。
            // 关键过滤：id 精确匹配、is_deleted = 0、id != 0；不校验 owner。
            // 时间字段：独立读取当前毫秒值写入 updated_date，保持 Android 每次 DAO 调用各自取时钟。
            // 副作用用途：这是 17 步删除事务的第一步，后续任一失败会由 GRDB 回滚整笔事务。
            try db.execute(
                sql: """
                    UPDATE book
                    SET updated_date = ?, is_deleted = 1
                    WHERE id = ? AND is_deleted = 0 AND id != 0
                    """,
                arguments: [currentTimeMillis(), id]
            )

            try softDeleteRows(
                db,
                table: "tag_book",
                predicate: "book_id = ?",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )

            // SQL 目的：按 NoteDao.queryNotesOrderByAsc 读取删除前仍有效的书摘，逐条清理 tag_note。
            // 涉及表：note。
            // 关键过滤：book_id 精确匹配且 is_deleted = 0；按 created_date 升序，不额外增加 ID tie-break。
            // 时间字段：只读取 created_date 用于排序，返回 note.id 供下一步逐条生成独立更新时间。
            // 副作用用途：严格保持 Android 针对每本有效书摘分别调用 TagNoteDao 的次数与顺序。
            let activeNoteIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM note
                    WHERE book_id = ? AND is_deleted = 0
                    ORDER BY created_date ASC
                    """,
                arguments: [id]
            )
            for noteID in activeNoteIDs {
                try softDeleteRows(
                    db,
                    table: "tag_note",
                    predicate: "note_id = ?",
                    matchingID: noteID,
                    updatedAt: currentTimeMillis()
                )
            }

            try softDeleteRows(
                db,
                table: "note",
                predicate: "book_id = ?",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "attach_image",
                predicate: "note_id IN (SELECT id FROM note WHERE book_id = ?)",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "category",
                predicate: "book_id = ?",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "category_image",
                predicate: "category_content_id IN (SELECT id FROM category_content WHERE book_id = ?)",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "category_content",
                predicate: "book_id = ?",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "review",
                predicate: "book_id = ?",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "review_image",
                predicate: "review_id IN (SELECT id FROM review WHERE book_id = ?)",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "chapter",
                predicate: "id != 0 AND book_id = ?",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "group_book",
                predicate: "book_id = ? AND is_deleted = 0",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "book_read_status_record",
                predicate: "book_id = ?",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "read_time_record",
                predicate: "book_id = ? AND is_deleted = 0",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "sort",
                predicate: "book_id = ?",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "check_in_record",
                predicate: "book_id = ? AND is_deleted = 0",
                matchingID: id,
                updatedAt: currentTimeMillis()
            )
            try softDeleteRows(
                db,
                table: "collection_book",
                predicate: "book_id = ?",
                matchingID: id,
                updatedAt: nil
            )
            try softDeleteRows(
                db,
                table: "read_plan",
                predicate: "book_id = ? AND is_deleted = 0",
                matchingID: id,
                updatedAt: nil
            )
        }
    }

    /// 幂等更新全局 pinned 字段；groupID 只在存在有效关系时改变 max pin_order 的计算作用域。
    func updateBookPin(
        id: Int64,
        pinned: Bool,
        groupID: Int64?
    ) async throws -> DesktopWebBookPinSnapshot {
        let book = try await activeBookForMutation(id: id)
        try await validateOptionalBookGroup(groupID)
        let currentPinned = book.pinned == 1
        if currentPinned == pinned {
            return DesktopWebBookPinSnapshot(
                id: id,
                isPinned: currentPinned,
                pinOrder: Int(book.pinOrder)
            )
        }

        // NOTE(ANDROID-WEB-008): Android 置顶写入不校验 owner。
        let effectiveGroupID = try await effectivePinGroupID(bookID: id, requestedGroupID: groupID)
        let pinOrder = pinned ? try await nextPinOrder(groupID: effectiveGroupID) : 0
        let updatedAt = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：按 WebBookDao.updatePinStatus 更新书籍全局置顶状态。
            // 涉及表：book。
            // 关键过滤：id 精确匹配、is_deleted = 0、id != 0；不校验 owner。
            // 时间字段：updated_date 写当前毫秒值。
            // 副作用用途：置顶写入作用域最大值 + 1，取消置顶同时把 pin_order 清零。
            try db.execute(
                sql: """
                    UPDATE book
                    SET pinned = ?, pin_order = ?, updated_date = ?
                    WHERE id = ? AND is_deleted = 0 AND id != 0
                    """,
                arguments: [pinned ? 1 : 0, pinOrder, updatedAt, id]
            )
        }
        return try await pinSnapshot(id: id)
    }

    /// 恢复任意软删除且非占位书籍；主记录和阅读状态历史在同一事务中提交。
    func addToBookshelf(id: Int64) async throws -> DesktopWebBookSnapshot {
        var book = try await bookIncludingDeleted(id: id)
        if book.isDeleted != 1 {
            guard let snapshot = try await projection.projectBookSnapshots([book]).first else {
                throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(id)")
            }
            return snapshot
        }

        // NOTE(ANDROID-WEB-008): Android 可按 ID 恢复其他 owner 的书籍。
        let newOrder = try await projection.topLevelBoundaryOrder(
            placeAtEnd: shouldPlaceNewBookAtEnd()
        )
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：按 WebBookDao.restoreToBookshelf 恢复软删除书籍到默认书架。
            // 涉及表：book。
            // 关键过滤：id 精确匹配且 id != 0；不限制原 is_deleted 或 owner。
            // 时间字段：状态变更、购买日期和 updated_date 共用同一毫秒值。
            // 副作用用途：设置在读状态、顶层 book_order；保留原标签、分组、置顶和进度字段。
            try db.execute(
                sql: """
                    UPDATE book
                    SET is_deleted = 0,
                        read_status_id = 2,
                        read_status_changed_date = ?,
                        purchase_date = ?,
                        book_order = ?,
                        updated_date = ?
                    WHERE id = ? AND id != 0
                    """,
                arguments: [now, now, newOrder, now, id]
            )
            var status = BookReadStatusRecordRecord()
            status.bookId = id
            status.readStatusId = 2
            status.changedDate = now
            status.createdDate = now
            try status.insert(db)
        }

        book.isDeleted = 0
        book.readStatusId = 2
        book.readStatusChangedDate = now
        book.purchaseDate = now
        book.bookOrder = newOrder
        book.updatedDate = now
        guard let snapshot = try await projection.projectBookSnapshots([book]).first else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(id)")
        }
        return snapshot
    }

    /// 读取有效且非占位书籍供写接口前置校验；读取任务可取消，尚未进入写事务时不会产生副作用。
    func activeBookForMutation(id: Int64) async throws -> BookRecord {
        let record = try await database.dbPool.read { db in
            // SQL 目的：复制 ActiveBookGuard.requireActiveBook 的写前校验。
            // 涉及表：book。
            // 关键过滤：id 精确匹配、is_deleted = 0、id != 0；不校验 owner。
            // 时间字段：原样读取；返回完整记录供幂等置顶判断。
            try BookRecord.fetchOne(
                db,
                sql: "SELECT * FROM book WHERE id = ? AND is_deleted = 0 AND id != 0",
                arguments: [id]
            )
        }
        guard let record else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(id)")
        }
        return record
    }

    /// 读取包括 tombstone 的非占位书籍，供 add-to-bookshelf 判定是否需要恢复。
    func bookIncludingDeleted(id: Int64) async throws -> BookRecord {
        let record = try await database.dbPool.read { db in
            // SQL 目的：复制 WebBookDao.findById 的恢复书架读取。
            // 涉及表：book。
            // 关键过滤：id 精确匹配且 id != 0，不过滤 is_deleted 或 owner。
            // 时间字段：全部原样读取，恢复后仅覆盖 Android 明确指定字段。
            try BookRecord.fetchOne(
                db,
                sql: "SELECT * FROM book WHERE id = ? AND id != 0",
                arguments: [id]
            )
        }
        guard let record else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(id)")
        }
        return record
    }

    /// 只在请求为正数且书籍存在对应有效关系时采用组内 pin_order 作用域。
    private func effectivePinGroupID(
        bookID: Int64,
        requestedGroupID: Int64?
    ) async throws -> Int64? {
        guard let requestedGroupID, requestedGroupID > 0 else { return nil }
        let count = try await database.dbPool.read { db in
            // SQL 目的：复制 WebBookDao.countActiveGroupBook 的置顶作用域判断。
            // 涉及表：group_book。
            // 关键过滤：book_id、group_id 精确匹配且关系 is_deleted = 0；不连接 group 主表。
            // 时间字段：无；返回计数是否大于零。
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM group_book
                    WHERE book_id = ? AND group_id = ? AND is_deleted = 0
                    """,
                arguments: [bookID, requestedGroupID]
            ) ?? 0
        }
        return count > 0 ? requestedGroupID : nil
    }

    /// 读取全局或目标分组最大 pin_order，并以 Kotlin Int 溢出规则追加一个位置。
    private func nextPinOrder(groupID: Int64?) async throws -> Int64 {
        let maximum = try await database.dbPool.read { db -> Int64 in
            if let groupID {
                // SQL 目的：复制 WebBookDao.queryMaxPinOrderInGroup 的目标分组置顶边界。
                // 涉及表：group_book JOIN book；子查询选每本书最早有效分组关系。
                // 关键过滤：目标 group_id、关系与书籍有效、非占位且 pinned = 1；不校验 group 主表或 owner。
                // 时间字段：created_date 只用于选择最早关系；返回 MAX(book.pin_order)。
                return try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT MAX(book.pin_order)
                        FROM group_book
                        JOIN book ON group_book.book_id = book.id
                        JOIN `group` ON group_book.group_id = `group`.id
                        WHERE group_book.group_id = ?
                          AND group_book.is_deleted = 0
                          AND `group`.is_deleted = 0
                          AND book.is_deleted = 0
                          AND book.id != 0
                          AND book.pinned = 1
                          AND group_book.id = (
                              SELECT gb2.id
                              FROM group_book gb2
                              WHERE gb2.book_id = book.id AND gb2.is_deleted = 0
                              ORDER BY gb2.created_date ASC, gb2.id ASC
                              LIMIT 1
                          )
                        """,
                    arguments: [groupID]
                ) ?? 0
            }
            // SQL 目的：读取顶层书籍与分组共享置顶序列的最大值。
            // 涉及表：book、group；关键过滤：各自主记录有效且 pinned=1；不校验 owner。
            // 返回字段用途：置顶书籍使用两类记录的共同最大值加一。
            let bookMaximum = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(pin_order) FROM book WHERE is_deleted = 0 AND pinned = 1"
            ) ?? 0
            let groupMaximum = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(pin_order) FROM `group` WHERE is_deleted = 0 AND pinned = 1"
            ) ?? 0
            return max(bookMaximum, groupMaximum)
        }
        let wrapped = Int32(truncatingIfNeeded: maximum) &+ 1
        return Int64(wrapped)
    }

    /// 回读置顶结果；Android DAO 更新后只返回 id、pinned 与 pin_order。
    private func pinSnapshot(id: Int64) async throws -> DesktopWebBookPinSnapshot {
        let snapshot = try await database.dbPool.read { db -> DesktopWebBookPinSnapshot? in
            // SQL 目的：复制 updateBookPin 写后 WebBookRepository.findById 的结果读取。
            // 涉及表：book。
            // 关键过滤：仅按 id 命中并排除占位书，不过滤删除状态或 owner。
            // 时间字段：无；只返回置顶结果需要的三列。
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, pinned, pin_order FROM book WHERE id = ? AND id != 0",
                arguments: [id]
            ) else {
                return nil
            }
            return DesktopWebBookPinSnapshot(
                id: row["id"],
                isPinned: (row["pinned"] as Int64) == 1,
                pinOrder: Int(row["pin_order"] as Int64)
            )
        }
        guard let snapshot else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(id)")
        }
        return snapshot
    }

    /// 执行 Android 多个 DAO 共用的软删除 SQL；table/predicate 仅由本文件常量调用，不接受外部输入。
    private func softDeleteRows(
        _ db: Database,
        table: String,
        predicate: String,
        matchingID: Int64,
        updatedAt: Int64?
    ) throws {
        // SQL 目的：按删除事务当前步骤软删除指定表中与 book/note 关联的行。
        // 涉及表：调用点固定为 tag_book、tag_note、note、图片、分类、书评、章节、分组、阅读记录、排序、打卡、书单或计划表。
        // 关键过滤：调用点提供 Android DAO 原始 predicate；部分 DAO 故意不限制 is_deleted，因而会重写既有 tombstone。
        // 时间字段：有 updatedAt 的 DAO 同步写 updated_date；collection_book/read_plan 按 Android 保持原时间。
        // 副作用用途：保持 BookRepository.deleteBook 的逐表顺序和单事务回滚边界。
        if let updatedAt {
            try db.execute(
                sql: "UPDATE \(table) SET updated_date = ?, is_deleted = 1 WHERE \(predicate)",
                arguments: [updatedAt, matchingID]
            )
        } else {
            try db.execute(
                sql: "UPDATE \(table) SET is_deleted = 1 WHERE \(predicate)",
                arguments: [matchingID]
            )
        }
    }
}
