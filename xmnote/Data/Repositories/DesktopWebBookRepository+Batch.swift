/**
 * [INPUT]: 依赖 DesktopWebBookRepository、V44 书籍/标签/分组关系表、单书删除与状态副作用 helper
 * [OUTPUT]: 提供 Android BookService 七条批量删除、置顶、更新、标签和分组写入语义
 * [POS]: Data 层网页书籍批量写扩展；逐接口保留 Android 的事务或部分提交边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated extension DesktopWebBookRepository {
    /// 按首次出现顺序去重后逐本执行 17 步删除事务；缺失和已删除记录静默跳过。
    func batchDeleteBooks(ids: [Int64]) async throws {
        for id in distinctBookIDs(ids) {
            guard try await bookForBatchMutation(id: id) != nil else { continue }
            try await deleteBook(id: id)
        }
    }

    /// 按原始请求顺序逐本置顶或取消置顶；每本书独立提交且重复 ID 幂等跳过。
    func batchPinBooks(ids: [Int64], pinned: Bool, groupID: Int64?) async throws {
        for id in ids {
            guard let book = try await bookForBatchMutation(id: id) else { continue }
            guard (book.pinned == 1) != pinned else { continue }
            _ = try await updateBookPin(id: id, pinned: pinned, groupID: groupID)
        }
    }

    /// 按 Android 当前校验顺序，在一个事务中批量更新主表、状态、分组和追加标签。
    func batchUpdateBooks(_ input: DesktopWebBookBatchUpdateInput) async throws {
        try await validateOptionalBookGroup(input.groupID)
        if let sourceID = input.sourceID {
            try await requireActiveBookSource(sourceID)
        }
        let normalizedAddTagIDs = try await normalizeActiveBookTagIDs(input.addTagIDs)
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            for id in input.ids {
                guard var book = try activeBookForBatchMutation(db, id: id) else { continue }
                var changed = false
                var statusSideEffectsChanged = false

                if let readStatus = input.readStatus, book.readStatusId != Int64(readStatus) {
                    book.readStatusId = Int64(readStatus)
                    book.readStatusChangedDate = input.readStatusChangedTime ?? now
                    changed = true
                    statusSideEffectsChanged = true
                }
                if let changedTime = input.readStatusChangedTime,
                   book.readStatusChangedDate != changedTime {
                    book.readStatusChangedDate = changedTime
                    changed = true
                    statusSideEffectsChanged = true
                }
                if let sourceID = input.sourceID, book.sourceId != sourceID {
                    book.sourceId = sourceID
                    changed = true
                }
                if changed {
                    book.updatedDate = now
                    try updateWebBook(db, book: book)
                }
                if statusSideEffectsChanged {
                    try syncReadStatusSideEffectsInTransaction(
                        db,
                        book: &book,
                        changedTime: book.readStatusChangedDate
                    )
                }
                try normalizeBookGroupRelations(
                    db,
                    bookID: id,
                    requestedGroupID: input.groupID,
                    now: now
                )
                for tagID in normalizedAddTagIDs ?? [] {
                    let exists = (try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM tag_book
                            WHERE book_id = ? AND tag_id = ? AND is_deleted = 0
                            """,
                        arguments: [id, tagID]
                    ) ?? 0) > 0
                    if exists { continue }
                    try BookRelationWriter.insertTag(
                        db,
                        bookID: id,
                        tagID: tagID,
                        createdAt: now
                    )
                }
            }
        }
    }

    /// 规范化 ID、mode 与标签后，在一个事务中 append 或 replace 多本书的标签集合。
    func batchSetBookTags(
        ids: [Int64],
        tagIDs: [Int64],
        mode rawMode: String
    ) async throws {
        let normalizedIDs = try normalizedPositiveBookIDs(ids)
        let lowercasedMode = rawMode.lowercased()
        let mode = lowercasedMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "append"
            : lowercasedMode
        guard mode == "append" || mode == "replace" else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("mode 仅支持 append 或 replace")
        }
        let normalizedTagIDs = Array(Set(tagIDs.filter { $0 > 0 })).sorted()
        // NOTE(ANDROID-WEB-005): Android 的标签存在性校验不限制 owner，允许关联其他用户的有效标签。
        guard try await activeTagsExist(normalizedTagIDs) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分标签不存在")
        }
        if mode == "append" && normalizedTagIDs.isEmpty { return }

        let now = currentTimeMillis()
        let existingTagMap = try await activeTagMap(bookIDs: normalizedIDs)
        try await database.dbPool.write { db in
            for id in normalizedIDs {
                guard try activeBookForBatchMutation(db, id: id) != nil else { continue }
                let current = existingTagMap[id] ?? []
                let final = mode == "append"
                    ? Array(Set(current + normalizedTagIDs)).sorted()
                    : normalizedTagIDs
                if current == final { continue }
                try hardDeleteBatchTags(db, bookID: id)
                for tagID in final {
                    try BookRelationWriter.insertTag(
                        db,
                        bookID: id,
                        tagID: tagID,
                        createdAt: now
                    )
                }
            }
        }
    }

    /// 按首个条目顺序、最后一个同 ID 载荷归一化后，原子精确替换每本书的标签集合。
    func batchReplaceBookTags(_ rawItems: [DesktopWebBookBatchReplaceTagsItemInput]) async throws {
        let items = try normalizedReplaceTagItems(rawItems)
        let ids = items.map(\.id)
        let allTagIDs = Array(Set(items.flatMap(\.tagIDs))).sorted()
        // NOTE(ANDROID-WEB-005): 精确替换沿用跨 owner 标签校验与关系查询，后续需统一业务 owner 边界。
        guard try await activeTagsExist(allTagIDs) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分标签不存在")
        }
        for id in ids where try await bookForBatchMutation(id: id) == nil {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分书籍不存在")
        }

        let now = currentTimeMillis()
        let existingTagMap = try await activeTagMap(bookIDs: ids)
        try await database.dbPool.write { db in
            for item in items {
                let current = existingTagMap[item.id] ?? []
                if current == item.tagIDs { continue }
                try hardDeleteBatchTags(db, bookID: item.id)
                for tagID in item.tagIDs {
                    try BookRelationWriter.insertTag(
                        db,
                        bookID: item.id,
                        tagID: tagID,
                        createdAt: now
                    )
                }
            }
        }
    }

    /// 在一个事务中逐本取消置顶、移除全部旧关系、追加目标组尾部并更新排序。
    func batchMoveToGroup(
        ids: [Int64],
        targetGroupID: Int64,
        sourceGroupID: Int64?
    ) async throws {
        guard targetGroupID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("分组不存在")
        }
        try await validateOptionalBookGroup(targetGroupID)
        try await validateOptionalBookGroup(sourceGroupID ?? 0)
        let normalizedIDs = distinctBookIDs(ids)
        try await database.dbPool.write { db in
            for id in normalizedIDs {
                guard try activeBookForBatchMutation(db, id: id) != nil else { continue }
                if (sourceGroupID ?? 0) == targetGroupID { continue }
                let now = currentTimeMillis()
                // SQL 目的：在迁入目标分组前取消当前书籍置顶状态。
                // 涉及表：book；只更新有效且非占位书籍。
                // 时间字段：updated_date 使用当前 Unix 毫秒时间。
                // 副作用用途：与后续关系重建和排序更新处于同一批量事务。
                try db.execute(
                    sql: """
                        UPDATE book SET pinned = 0, pin_order = 0, updated_date = ?
                        WHERE id = ? AND is_deleted = 0 AND id != 0
                        """,
                    arguments: [now, id]
                )
                // SQL 目的：读取目标分组首关系书籍中的最大排序值，以便追加到组尾。
                // 涉及表与关联：group_book 连接 book，并以每本书最早的有效关系限定其主分组。
                // 关键过滤：关系与书籍均有效、排除占位书籍；不校验目标 group 主记录。
                // 返回字段：MAX(book_order)，空分组回退为 0；排序使用数据库原始 Int32 溢出语义。
                let maximum = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT MAX(book.book_order)
                        FROM group_book
                        JOIN book ON group_book.book_id = book.id
                        WHERE group_book.group_id = ?
                          AND group_book.is_deleted = 0
                          AND book.is_deleted = 0
                          AND book.id != 0
                          AND group_book.id = (
                              SELECT gb2.id FROM group_book gb2
                              WHERE gb2.book_id = book.id AND gb2.is_deleted = 0
                              ORDER BY gb2.created_date ASC, gb2.id ASC
                              LIMIT 1
                          )
                        """,
                    arguments: [targetGroupID]
                ) ?? 0
                let targetOrder = Int64(Int32(truncatingIfNeeded: maximum) &+ 1)
                // SQL 目的：物理删除该书全部分组关系，为 v48 唯一目标关系重建腾出业务键。
                // 涉及表：group_book；不限制来源分组、owner 或历史删除状态。
                // 时间字段：物理删除不写时间字段；副作用用途：同一事务内随后插入新的目标分组关系。
                try db.execute(
                    sql: "DELETE FROM group_book WHERE book_id = ?",
                    arguments: [id]
                )
                try BookRelationWriter.insertGroup(
                    db,
                    groupID: targetGroupID,
                    bookID: id,
                    createdAt: now
                )
                // SQL 目的：把书籍排序更新为刚计算的目标组尾序号。
                // 涉及表：book；按 id 更新，不额外复查 owner 或删除状态。
                // 时间字段：updated_date 使用当前 Unix 毫秒时间。
                // 副作用用途：完成迁组事务中的最终排序落盘。
                try db.execute(
                    sql: "UPDATE book SET book_order = ?, updated_date = ? WHERE id = ?",
                    arguments: [targetOrder, now, id]
                )
            }
        }
    }

    /// 按头尾策略调整遍历顺序，在一个事务中取消置顶、移关系并更新全部目标书籍排序。
    func batchMoveOut(ids: [Int64], placeAtEnd: Bool) async throws {
        let orderedIDs = placeAtEnd ? ids : Array(ids.reversed())
        try await database.dbPool.write { db in
            for id in orderedIDs {
                guard try activeBookForBatchMutation(db, id: id) != nil else { continue }
                let now = currentTimeMillis()
                // SQL 目的：在移出分组事务中取消目标书籍置顶。
                // 涉及表：book；只更新有效非占位记录。
                // 时间字段：updated_date 使用本书共享 now 毫秒。
                // 副作用用途：与关系及排序更新共同回滚。
                try db.execute(
                    sql: """
                        UPDATE book SET pinned = 0, pin_order = 0, updated_date = ?
                        WHERE id = ? AND is_deleted = 0 AND id != 0
                        """,
                    arguments: [now, id]
                )
                let order = try topLevelBoundaryOrder(db, placeAtEnd: placeAtEnd)
                // SQL 目的：物理删除书籍全部分组关系。
                // 涉及表：group_book；不限制来源分组或历史删除状态。
                // 时间字段：物理删除不写时间字段；副作用用途：与排序更新共同提交。
                try db.execute(
                    sql: "DELETE FROM group_book WHERE book_id = ?",
                    arguments: [id]
                )
                // SQL 目的：写入刚计算的顶层排序值。
                // 涉及表：book；DAO 只按 id，不复查删除状态或 owner。
                // 时间字段：updated_date 使用本书共享 now 毫秒。
                // 副作用用途：保持向头部移动时逆序遍历后的请求顺序。
                try db.execute(
                    sql: "UPDATE book SET book_order = ?, updated_date = ? WHERE id = ?",
                    arguments: [order, now, id]
                )
            }
        }
    }
}

nonisolated extension DesktopWebBookRepository {
    /// 查询有效非占位书籍；批量接口把缺失与已删除统一视为可跳过 nil。
    func bookForBatchMutation(id: Int64) async throws -> BookRecord? {
        try await database.dbPool.read { db in
            try activeBookForBatchMutation(db, id: id)
        }
    }

    /// 在既有连接内执行批量路径的有效书籍判断。
    func activeBookForBatchMutation(_ db: Database, id: Int64) throws -> BookRecord? {
        // SQL 目的：复制 WebBookRepository.findById 后的有效状态判断。
        // 涉及表：book。
        // 关键过滤：id 精确匹配、id != 0 且有效；故意不按 owner 过滤。
        // 返回字段用途：无效记录由各批量接口静默跳过或统一报错。
        try BookRecord.fetchOne(
            db,
            sql: "SELECT * FROM book WHERE id = ? AND id != 0 AND is_deleted = 0",
            arguments: [id]
        )
    }

    /// 保留首次出现顺序去重，复制 Kotlin distinct。
    func distinctBookIDs(_ ids: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// 过滤非正数并保序去重；无有效 ID 时使用 Android 固定错误。
    func normalizedPositiveBookIDs(_ ids: [Int64]) throws -> [Int64] {
        let normalized = distinctBookIDs(ids).filter { $0 > 0 }
        guard !normalized.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("ids 不能为空")
        }
        return normalized
    }

    /// 按首个 ID 顺序、最后一次载荷归一化批量替换条目。
    func normalizedReplaceTagItems(
        _ items: [DesktopWebBookBatchReplaceTagsItemInput]
    ) throws -> [DesktopWebBookBatchReplaceTagsItemInput] {
        var order: [Int64] = []
        var values: [Int64: DesktopWebBookBatchReplaceTagsItemInput] = [:]
        for item in items where item.id > 0 {
            if values[item.id] == nil { order.append(item.id) }
            values[item.id] = DesktopWebBookBatchReplaceTagsItemInput(
                id: item.id,
                tagIDs: Array(Set(item.tagIDs.filter { $0 > 0 })).sorted()
            )
        }
        guard !order.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("items 不能为空")
        }
        return order.compactMap { values[$0] }
    }

    /// 校验全部标签主记录有效；不按 owner 隔离。
    func activeTagsExist(_ tagIDs: [Int64]) async throws -> Bool {
        if tagIDs.isEmpty { return true }
        return try await database.dbPool.read { db in
            let placeholders = Array(repeating: "?", count: tagIDs.count).joined(separator: ",")
            // SQL 目的：复制 countExistingTags 对批量标签输入的整体有效性校验。
            // 涉及表：tag。
            // 关键过滤：ID 集合且 is_deleted = 0；故意不按 owner 或类型过滤。
            // 返回字段用途：数量必须与去重后的请求标签数完全一致。
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM tag WHERE id IN (\(placeholders)) AND is_deleted = 0",
                arguments: StatementArguments(tagIDs)
            ) ?? 0
            return count == tagIDs.count
        }
    }

    /// 以 Android 500 条分块读取有效标签主记录对应的有效关系，并按 ID 去重排序。
    func activeTagMap(bookIDs: [Int64]) async throws -> [Int64: [Int64]] {
        if bookIDs.isEmpty { return [:] }
        return try await database.dbPool.read { db in
            var values: [Int64: [Int64]] = [:]
            for chunk in bookIDs.chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                // SQL 目的：复制 batchQueryTags，仅把有效标签主记录纳入当前集合。
                // 涉及表：tag_book INNER JOIN tag。
                // 关键过滤：book_id 分块、关系与标签均有效；不按 owner 过滤。
                // 返回字段用途：append/replace 的幂等比较基线。
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT tag_book.book_id, tag.id
                        FROM tag_book
                        INNER JOIN tag ON tag_book.tag_id = tag.id
                        WHERE tag_book.book_id IN (\(placeholders))
                          AND tag_book.is_deleted = 0
                          AND tag.is_deleted = 0
                        """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    values[row["book_id"] as Int64, default: []].append(row["id"] as Int64)
                }
            }
            return values.mapValues { Array(Set($0)).sorted() }
        }
    }

    /// 在标签批量事务内物理删除一本书全部标签关系。
    func hardDeleteBatchTags(_ db: Database, bookID: Int64) throws {
        // SQL 目的：为标签集合替换物理清理全部现存关系。
        // 涉及表：tag_book。
        // 关键过滤：book_id 精确匹配；包括旧备份 tombstone 与指向已删除标签的残留关系。
        // 时间字段：物理删除不写时间字段；副作用用途：随后按最终标签集合重建 v48 唯一关系。
        try db.execute(
            sql: "DELETE FROM tag_book WHERE book_id = ?",
            arguments: [bookID]
        )
    }

    /// 读取顶层书籍与分组共享边界并按 Kotlin Int 溢出规则向指定方向扩一位。
    func topLevelBoundaryOrder(placeAtEnd: Bool) async throws -> Int64 {
        let boundary = try await database.dbPool.read { db -> Int64 in
            let aggregate = placeAtEnd ? "MAX" : "MIN"
            // SQL 目的：读取有效未分组书籍与有效分组的共享顶层排序边界。
            // 涉及表：book、group_book、group。
            // 关键过滤：书籍有效非占位且无有效关系；分组有效；不按 owner 过滤。
            // 返回字段用途：移出分组时向尾部 +1 或头部 -1。
            let book = try Int64.fetchOne(
                db,
                sql: """
                    SELECT \(aggregate)(book_order) FROM book
                    WHERE is_deleted = 0 AND id != 0
                      AND id NOT IN (
                          SELECT gb.book_id
                          FROM group_book gb
                          INNER JOIN `group` g ON g.id = gb.group_id
                          WHERE gb.is_deleted = 0 AND g.is_deleted = 0
                      )
                    """
            ) ?? 0
            let group = try Int64.fetchOne(
                db,
                sql: "SELECT \(aggregate)(group_order) FROM `group` WHERE is_deleted = 0"
            ) ?? 0
            return placeAtEnd ? max(book, group) : min(book, group)
        }
        let delta: Int32 = placeAtEnd ? 1 : -1
        return Int64(Int32(truncatingIfNeeded: boundary) &+ delta)
    }

    /// 在现有写事务连接内读取有效顶层书籍与分组的共享排序边界。
    func topLevelBoundaryOrder(_ db: Database, placeAtEnd: Bool) throws -> Int64 {
        let aggregate = placeAtEnd ? "MAX" : "MIN"
        // SQL 目的：读取没有任何有效分组主记录关系的有效书籍排序边界。
        // 涉及表：book、group_book、group；关系必须与有效 group 主记录连接。
        // 返回字段用途：与有效分组边界合并后向头尾扩展一位。
        let book = try Int64.fetchOne(
            db,
            sql: """
                SELECT \(aggregate)(book_order) FROM book
                WHERE is_deleted = 0 AND id != 0
                  AND id NOT IN (
                      SELECT gb.book_id
                      FROM group_book gb
                      INNER JOIN `group` g ON g.id = gb.group_id
                      WHERE gb.is_deleted = 0 AND g.is_deleted = 0
                  )
                """
        ) ?? 0
        // SQL 目的：读取有效分组排序边界；涉及表：group；关键过滤：is_deleted=0。
        let group = try Int64.fetchOne(
            db,
            sql: "SELECT \(aggregate)(group_order) FROM `group` WHERE is_deleted = 0"
        ) ?? 0
        let boundary = placeAtEnd ? max(book, group) : min(book, group)
        let delta: Int32 = placeAtEnd ? 1 : -1
        return Int64(Int32(truncatingIfNeeded: boundary) &+ delta)
    }

    /// 查询某标签关系是否已有效存在；不连接标签主表。
    func hasActiveTagBook(bookID: Int64, tagID: Int64) async throws -> Bool {
        try await database.dbPool.read { db in
            // SQL 目的：复制 countActiveTagBook 的追加幂等判断。
            // 涉及表：tag_book。
            // 关键过滤：book_id、tag_id 且关系有效；不验证 tag 主记录。
            // 返回字段用途：已有关系时跳过本次 addTagIds。
            (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM tag_book
                    WHERE book_id = ? AND tag_id = ? AND is_deleted = 0
                    """,
                arguments: [bookID, tagID]
            ) ?? 0) > 0
        }
    }
}

private nonisolated extension Array {
    /// 以固定上限切分数组，复制 Android Web Repository 对大 IN 查询的 500 条分块。
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
