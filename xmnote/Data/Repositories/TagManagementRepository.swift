/**
 * [INPUT]: 依赖 DatabaseManager、GRDB、ObservationStream 与 TagRecord，按 Android 标签业务语义和 iOS 全局硬删除约束执行标签管理读写
 * [OUTPUT]: 对外提供 TagManagementRepository（TagManagementRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层标签管理仓储实现，统一封装标签管理页与业务标签选择器共用的书摘/书籍标签列表、增改删与排序写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 标签管理仓储实现，严格对齐 Android 标签管理页的数据写入与查询语义。
struct TagManagementRepository: TagManagementRepositoryProtocol {
    private let databaseManager: DatabaseManager

    /// 注入数据库管理器，供标签管理读写复用当前数据库连接池。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    /// 观察书摘与书籍标签快照；数据库中标签或关联关系变更后自动刷新。
    func observeTagManagementSnapshot() -> AsyncThrowingStream<TagManagementSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchSnapshot(db)
        }
    }

    /// 新建标签；新增 tag_order 固定为 Android Int.MAX_VALUE，时间字段保持 Android 管理页实际写入的 0。
    func createTag(named name: String, scope: TagManagementScope) async throws {
        let normalizedName = try validatedName(name)
        try await databaseManager.database.dbPool.write { db in
            guard try !isDuplicateTagName(db, name: normalizedName, scope: scope) else {
                throw TagManagementRepositoryError.duplicateName
            }
            let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
            var record = TagRecord(
                id: nil,
                userId: ownerID,
                name: normalizedName,
                color: 0,
                tagOrder: 2_147_483_647,
                type: scope.rawValue,
                createdDate: 0,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
        }
        try await normalizeTagOrder(scope: scope)
    }

    /// 编辑标签名称；Android TagManage 走 Room @Update，实际会把时间字段按 mapper 结果覆盖为 0。
    func updateTag(tagID: Int64, name: String, scope: TagManagementScope) async throws {
        let normalizedName = try validatedName(name)
        try await databaseManager.database.dbPool.write { db in
            guard try !isDuplicateTagName(
                db,
                name: normalizedName,
                scope: scope,
                excludingTagID: tagID
            ) else {
                throw TagManagementRepositoryError.duplicateName
            }
            guard let existing = try fetchActiveTag(db, tagID: tagID, scope: scope) else {
                throw TagManagementRepositoryError.invalidTag
            }
            let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
            try updateTagUsingAndroidManageSemantics(
                db,
                existing: existing,
                ownerID: ownerID,
                normalizedName: normalizedName,
                scope: scope
            )
        }
        try await normalizeTagOrder(scope: scope)
    }

    /// 物理删除标签及全部关系；批量删除保持每个标签单独事务，避免单项失败回滚其它已完成项。
    func deleteTags(tagIDs: [Int64], scope: TagManagementScope) async throws {
        let uniqueIDs = uniquePositiveIDs(tagIDs)
        guard !uniqueIDs.isEmpty else { throw TagManagementRepositoryError.emptySelection }

        for tagID in uniqueIDs {
            try await databaseManager.database.dbPool.write { db in
                guard try fetchActiveTag(db, tagID: tagID, scope: scope) != nil else {
                    throw TagManagementRepositoryError.invalidTag
                }
                try hardDeleteTagRelations(db, tagID: tagID)
                try hardDeleteTag(db, tagID: tagID, scope: scope)
            }
        }
        try await normalizeTagOrder(scope: scope)
    }

    /// 写入标签排序；每条 UPDATE 按 Android DAO 更新 updated_date 与 tag_order。
    func updateTagOrder(tagIDs: [Int64], scope: TagManagementScope) async throws {
        let orderedIDs = uniquePositiveIDs(tagIDs)
        try await databaseManager.database.dbPool.write { db in
            for (index, tagID) in orderedIDs.enumerated() {
                try updateTagOrder(db, tagID: tagID, order: index, updatedAt: timestampMillis())
            }
        }
    }
}

private extension TagManagementRepository {
    nonisolated func fetchSnapshot(_ db: Database) throws -> TagManagementSnapshot {
        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        return TagManagementSnapshot(
            noteTags: try fetchTags(db, ownerID: ownerID, scope: .note),
            bookTags: try fetchTags(db, ownerID: ownerID, scope: .book)
        )
    }

    nonisolated func fetchTags(_ db: Database, ownerID: Int64, scope: TagManagementScope) throws -> [TagManagementItem] {
        let relationTable = relationTableName(for: scope)
        let countAlias = scope == .note ? "note_count" : "book_count"

        // SQL 目的：读取指定 owner 与类型下的有效标签，并统计其有效关联数量。
        // 涉及表：tag 与当前范围对应的关联表（tag_note 或 tag_book），LEFT JOIN 只统计关联表 is_deleted = 0 的记录。
        // 关键过滤：tag.user_id = 当前 owner、tag.type = Android TagType、tag.is_deleted = 0。
        // 时间字段：本查询不读取时间作为展示值；排序严格使用 Android 的 tag_order ASC。
        // 返回字段用途：id/name/color/tag_order 供列表展示和编辑全列更新，count 供关联数量展示。
        let sql = """
            SELECT t.id,
                   t.name,
                   t.color,
                   t.tag_order,
                   COUNT(r.id) AS \(countAlias)
            FROM tag t
            LEFT JOIN \(relationTable) r
                   ON t.id = r.tag_id
                  AND r.is_deleted = 0
            WHERE t.user_id = ?
              AND t.type = ?
              AND t.is_deleted = 0
            GROUP BY t.id
            ORDER BY t.tag_order ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [ownerID, scope.rawValue]).map { row in
            TagManagementItem(
                id: row["id"],
                name: row["name"] ?? "",
                color: row["color"] ?? 0,
                order: row["tag_order"] ?? 0,
                associatedCount: row[countAlias] ?? 0
            )
        }
    }

    func normalizeTagOrder(scope: TagManagementScope) async throws {
        try await databaseManager.database.dbPool.write { db in
            let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
            let orderedIDs = try fetchOrderedActiveTagIDs(db, ownerID: ownerID, scope: scope)
            for (index, tagID) in orderedIDs.enumerated() {
                try updateTagOrder(db, tagID: tagID, order: index, updatedAt: timestampMillis())
            }
        }
    }

    nonisolated func fetchOrderedActiveTagIDs(_ db: Database, ownerID: Int64, scope: TagManagementScope) throws -> [Int64] {
        // SQL 目的：读取当前范围有效标签的展示顺序，用于复刻 Android 列表刷新后的 updateOrder 归一化副作用。
        // 涉及表：tag。
        // 关键过滤：user_id = 当前 owner、type = 当前范围、is_deleted = 0。
        // 时间字段：不读取时间；后续 updateTagOrder 会逐条写 updated_date。
        // 返回字段用途：返回按 tag_order ASC 排列的标签 id 列表。
        let sql = """
            SELECT id
            FROM tag
            WHERE user_id = ?
              AND type = ?
              AND is_deleted = 0
            ORDER BY tag_order ASC
            """
        return try Int64.fetchAll(db, sql: sql, arguments: [ownerID, scope.rawValue])
    }

    nonisolated func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 100
        guard !trimmed.isEmpty else { throw TagManagementRepositoryError.invalidName }
        guard trimmed.count <= maxLength else {
            throw TagManagementRepositoryError.invalidNameLength(maxLength: maxLength)
        }
        return trimmed
    }

    nonisolated func isDuplicateTagName(
        _ db: Database,
        name: String,
        scope: TagManagementScope,
        excludingTagID: Int64? = nil
    ) throws -> Bool {
        // SQL 目的：按 Android TagDao.queryTagByTitle 判断指定类型标签名称是否已存在。
        // 涉及表：tag。
        // 关键过滤：name 完全匹配、type = 当前范围、is_deleted = 0；编辑时额外排除当前标签自身。
        // 时间字段：不参与判重。
        // 返回字段用途：只需是否存在任意一条有效记录。
        if let excludingTagID {
            let sql = """
                SELECT id
                FROM tag
                WHERE name = ?
                  AND type = ?
                  AND is_deleted = 0
                  AND id != ?
                LIMIT 1
                """
            return try Int64.fetchOne(
                db,
                sql: sql,
                arguments: [name, scope.rawValue, excludingTagID]
            ) != nil
        }

        let sql = """
            SELECT id
            FROM tag
            WHERE name = ?
              AND type = ?
              AND is_deleted = 0
            LIMIT 1
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [name, scope.rawValue]) != nil
    }

    nonisolated func fetchActiveTag(_ db: Database, tagID: Int64, scope: TagManagementScope) throws -> TagRecord? {
        // SQL 目的：读取待编辑/删除的有效标签，避免对已删除或类型不匹配标签执行写入。
        // 涉及表：tag。
        // 关键过滤：id 精确匹配、type = 当前范围、is_deleted = 0。
        // 时间字段：读取完整 Record 仅用于编辑全列更新时保留 color/tag_order 等非名称字段。
        // 返回字段用途：返回 TagRecord 或 nil。
        let sql = """
            SELECT *
            FROM tag
            WHERE id = ?
              AND type = ?
              AND is_deleted = 0
            LIMIT 1
            """
        return try TagRecord.fetchOne(db, sql: sql, arguments: [tagID, scope.rawValue])
    }

    nonisolated func updateTagUsingAndroidManageSemantics(
        _ db: Database,
        existing: TagRecord,
        ownerID: Int64,
        normalizedName: String,
        scope: TagManagementScope
    ) throws {
        guard let tagID = existing.id else { throw TagManagementRepositoryError.invalidTag }

        // SQL 目的：按 Android 标签管理 TagDao.update(@Update) 的全列更新语义提交标签名称变更。
        // 涉及表：tag。
        // 关键过滤：仅按 id 精确命中；调用前已确认目标为当前范围的有效标签。
        // 时间字段：created_date/updated_date/last_sync_date 写 0，复刻 Android TagModelMapper 未写回 BaseEntity 时间字段的实际落库结果。
        // 副作用用途：更新 name，同时保留 color/tag_order/type 并把 is_deleted 维持为 0。
        let sql = """
            UPDATE tag
            SET user_id = ?,
                name = ?,
                color = ?,
                tag_order = ?,
                type = ?,
                created_date = 0,
                updated_date = 0,
                last_sync_date = 0,
                is_deleted = 0
            WHERE id = ?
            """
        try db.execute(
            sql: sql,
            arguments: [ownerID, normalizedName, existing.color, existing.tagOrder, scope.rawValue, tagID]
        )
    }

    nonisolated func hardDeleteTagRelations(_ db: Database, tagID: Int64) throws {
        // SQL 目的：物理解除待删除标签与全部书摘的关系，先清子表以满足 NO ACTION 外键。
        // 涉及表：tag_note。
        // 关键过滤：tag_id = ?，同时清理有效关系与历史兼容记录。
        // 时间字段：物理删除不写时间字段。
        // 副作用用途：删除标签前解除其与书摘的全部关联。
        try db.execute(sql: "DELETE FROM tag_note WHERE tag_id = ?", arguments: [tagID])

        // SQL 目的：物理解除待删除标签与全部书籍的关系，兼容恢复数据中可能存在的跨类型引用。
        // 涉及表：tag_book。
        // 关键过滤：tag_id = ?，同时清理有效关系与历史兼容记录。
        // 时间字段：物理删除不写时间字段。
        // 副作用用途：确保 tag 主记录可在 NO ACTION 外键约束下安全删除。
        try db.execute(sql: "DELETE FROM tag_book WHERE tag_id = ?", arguments: [tagID])
    }

    nonisolated func hardDeleteTag(_ db: Database, tagID: Int64, scope: TagManagementScope) throws {
        // SQL 目的：物理删除已经解除全部引用的标签主记录。
        // 涉及表：tag。
        // 关键过滤：id 与 type 同时精确匹配，避免错误范围删除同名或其它类型标签。
        // 时间字段：物理删除不写时间字段。
        // 副作用用途：彻底移除用户删除的标签，不创建 tombstone。
        try db.execute(
            sql: "DELETE FROM tag WHERE id = ? AND type = ?",
            arguments: [tagID, scope.rawValue]
        )
        guard db.changesCount == 1 else {
            throw TagManagementRepositoryError.invalidTag
        }
    }

    nonisolated func updateTagOrder(
        _ db: Database,
        tagID: Int64,
        order: Int,
        updatedAt: Int64
    ) throws {
        // SQL 目的：写入标签管理列表的手动排序下标。
        // 涉及表：tag。
        // 关键过滤：仅按 id 精确命中，对齐 Android TagDao.updateTagOrderSync。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持不变。
        // 副作用用途：对齐 Android updateTagOrderSync，更新 tag_order 并产生同步可感知的更新时间。
        let sql = """
            UPDATE tag
            SET updated_date = ?,
                tag_order = ?
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [updatedAt, order, tagID])
    }

    nonisolated func relationTableName(for scope: TagManagementScope) -> String {
        switch scope {
        case .note:
            return "tag_note"
        case .book:
            return "tag_book"
        }
    }

    nonisolated func uniquePositiveIDs(_ ids: [Int64]) -> [Int64] {
        ids.reduce(into: [Int64]()) { result, id in
            guard id > 0, !result.contains(id) else { return }
            result.append(id)
        }
    }

    nonisolated func timestampMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
