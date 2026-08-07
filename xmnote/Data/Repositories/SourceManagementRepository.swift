/**
 * [INPUT]: 依赖 DatabaseManager、GRDB、ObservationStream 与 SourceRecord，按 Android SourceRepository/SourceDao 语义执行书籍来源管理读写
 * [OUTPUT]: 对外提供 SourceManagementRepository（SourceManagementRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层书籍来源管理仓储实现，统一封装“我的 > 书籍来源”的来源列表、增改删与排序写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 书籍来源管理仓储实现，严格对齐 Android 书籍来源管理页的数据写入与查询语义。
struct SourceManagementRepository: SourceManagementRepositoryProtocol {
    private let databaseManager: DatabaseManager

    /// 注入数据库管理器，供来源管理读写复用当前数据库连接池。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    /// 观察我的来源与默认来源快照；数据库中来源或关联书籍变更后自动刷新。
    func observeSourceManagementSnapshot() -> AsyncThrowingStream<SourceManagementSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchSnapshot(db)
        }
    }

    /// 新建我的来源，按 Android SourceRepository.add 语义写入默认字段。
    func createSource(named name: String) async throws {
        let normalizedName = try validatedName(name)
        try await databaseManager.database.dbPool.write { db in
            guard try !isDuplicateSourceName(db, name: normalizedName, excludingSourceID: 0) else {
                throw SourceManagementRepositoryError.duplicateName
            }
            let nextOrder = try nextSourceOrder(db)
            var record = SourceRecord(
                id: nil,
                name: normalizedName,
                sourceOrder: nextOrder,
                bookshelfOrder: -1,
                isHide: 0,
                createdDate: timestampMillis(),
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
        }
    }

    /// 编辑我的来源名称；Android 管理页走 Room @Update，会写入 updated_date 并保留来源排序与隐藏字段。
    func updateSource(sourceID: Int64, name: String) async throws {
        let normalizedName = try validatedName(name)
        try await databaseManager.database.dbPool.write { db in
            guard let existing = try fetchActiveSource(db, sourceID: sourceID) else {
                throw SourceManagementRepositoryError.invalidSource
            }
            guard !isDefaultSourceID(sourceID) else {
                throw SourceManagementRepositoryError.defaultSourceReadonly
            }
            guard try !isDuplicateSourceName(db, name: normalizedName, excludingSourceID: sourceID) else {
                throw SourceManagementRepositoryError.duplicateName
            }
            try updateSourceUsingAndroidManageSemantics(
                db,
                existing: existing,
                normalizedName: normalizedName
            )
        }
    }

    /// 删除我的来源；每个来源保持独立事务，先迁移关联书籍到“未知”再软删除来源。
    func deleteSources(sourceIDs: [Int64]) async throws {
        let uniqueIDs = uniquePositiveIDs(sourceIDs)
        guard !uniqueIDs.isEmpty else { throw SourceManagementRepositoryError.emptySelection }

        for sourceID in uniqueIDs {
            try await databaseManager.database.dbPool.write { db in
                guard try fetchActiveSource(db, sourceID: sourceID) != nil else {
                    throw SourceManagementRepositoryError.invalidSource
                }
                guard !isDefaultSourceID(sourceID) else {
                    throw SourceManagementRepositoryError.defaultSourceReadonly
                }
                try ensureUnknownSource(db, excludingSourceID: sourceID)
                try migrateBooksToUnknownSource(db, sourceID: sourceID)
                try softDeleteSource(db, sourceID: sourceID)
            }
        }
    }

    /// 按当前我的来源展示顺序写入 source_order，并更新 updated_date。
    func updateSourceOrder(sourceIDs: [Int64], scope: SourceManagementScope) async throws {
        guard scope == .mine else { throw SourceManagementRepositoryError.defaultSourceReadonly }
        let orderedIDs = uniquePositiveIDs(sourceIDs)
        try await databaseManager.database.dbPool.write { db in
            let validIDs = try fetchOrderedActiveSourceIDs(db, scope: scope)
            guard orderedIDs.count == validIDs.count, Set(orderedIDs) == Set(validIDs) else {
                throw SourceManagementRepositoryError.invalidOrder
            }
            for (index, sourceID) in orderedIDs.enumerated() {
                try updateSourceOrder(db, sourceID: sourceID, order: index, updatedAt: timestampMillis())
            }
        }
    }
}

private extension SourceManagementRepository {
    enum Constants {
        static let sourceNameMaxLength = 100
        static let unknownSourceID: Int64 = 1
        static let unknownSourceName = "未知"
        static let defaultSourceIDRange: ClosedRange<Int64> = 1...27
    }

    nonisolated func fetchSnapshot(_ db: Database) throws -> SourceManagementSnapshot {
        var mineSources: [SourceManagementItem] = []
        var defaultSources: [SourceManagementItem] = []

        for item in try fetchSources(db) {
            if item.isAppDefault {
                defaultSources.append(item)
            } else {
                mineSources.append(item)
            }
        }
        return SourceManagementSnapshot(mineSources: mineSources, defaultSources: defaultSources)
    }

    nonisolated func fetchSources(_ db: Database) throws -> [SourceManagementItem] {
        // SQL 目的：读取有效来源并统计每个来源关联的有效书籍数量。
        // 涉及表：source LEFT JOIN book，book 仅通过 source_id 关联来源。
        // 关键过滤：source.is_deleted = 0；关联数量只统计 book.is_deleted = 0，对齐 Android SourceDao.queryBookCount，不额外排除 book.id = 0。
        // 时间字段：本查询不读取时间作为展示值；排序严格使用 Android source_order ASC。
        // 返回字段用途：id/name/source_order/bookshelf_order/is_hide 供列表展示、编辑全列更新与排序写回，book_count 供删除确认和行内说明。
        let sql = """
            SELECT s.id,
                   s.name,
                   s.source_order,
                   s.bookshelf_order,
                   s.is_hide,
                   COUNT(b.id) AS book_count
            FROM source s
            LEFT JOIN book b
                   ON b.source_id = s.id
                  AND b.is_deleted = 0
            WHERE s.is_deleted = 0
            GROUP BY s.id
            ORDER BY s.source_order ASC, s.id ASC
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let sourceID: Int64 = row["id"] ?? 0
            return SourceManagementItem(
                id: sourceID,
                name: row["name"] ?? "",
                sourceOrder: row["source_order"] ?? 0,
                bookshelfOrder: row["bookshelf_order"] ?? -1,
                isHidden: (row["is_hide"] ?? Int64(0)) != 0,
                isAppDefault: isDefaultSourceID(sourceID),
                associatedBookCount: row["book_count"] ?? 0
            )
        }
    }

    nonisolated func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceManagementRepositoryError.invalidName }
        guard trimmed.count <= Constants.sourceNameMaxLength else {
            throw SourceManagementRepositoryError.invalidNameLength(maxLength: Constants.sourceNameMaxLength)
        }
        return trimmed
    }

    nonisolated func isDuplicateSourceName(
        _ db: Database,
        name: String,
        excludingSourceID: Int64
    ) throws -> Bool {
        // SQL 目的：按 Android SourceDao.queryCountByName 判断来源名称是否已存在。
        // 涉及表：source。
        // 关键过滤：name 完全匹配、is_deleted = 0，并排除当前 source id。
        // 时间字段：不参与判重。
        // 返回字段用途：只需是否存在任意一条有效记录。
        let sql = """
            SELECT COUNT(*)
            FROM source
            WHERE name = ?
              AND is_deleted = 0
              AND id != ?
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [name, excludingSourceID]) ?? 0) > 0
    }

    nonisolated func nextSourceOrder(_ db: Database) throws -> Int64 {
        // SQL 目的：读取有效来源中的最大 source_order，供新增来源追加到末尾。
        // 涉及表：source。
        // 关键过滤：is_deleted = 0，对齐 Android SourceDao.queryMaxOrder。
        // 时间字段：不参与计算。
        // 返回字段用途：返回 max + 1；没有来源时按 Android Elvis 0 再 +1 的行为得到 1。
        let sql = """
            SELECT MAX(source_order)
            FROM source
            WHERE is_deleted = 0
            """
        return (try Int64.fetchOne(db, sql: sql) ?? 0) + 1
    }

    nonisolated func fetchActiveSource(_ db: Database, sourceID: Int64) throws -> SourceRecord? {
        // SQL 目的：读取待编辑/删除的有效来源，避免对已删除来源执行写入。
        // 涉及表：source。
        // 关键过滤：id 精确匹配且 is_deleted = 0。
        // 时间字段：读取完整 Record 用于编辑全列更新时保留 source_order/bookshelf_order/is_hide/created_date。
        // 返回字段用途：返回 SourceRecord 或 nil。
        let sql = """
            SELECT *
            FROM source
            WHERE id = ?
              AND is_deleted = 0
            LIMIT 1
            """
        return try SourceRecord.fetchOne(db, sql: sql, arguments: [sourceID])
    }

    nonisolated func updateSourceUsingAndroidManageSemantics(
        _ db: Database,
        existing: SourceRecord,
        normalizedName: String
    ) throws {
        guard let sourceID = existing.id else { throw SourceManagementRepositoryError.invalidSource }

        // SQL 目的：按 Android 书籍来源管理 SourceDao.update(@Update) 的全列更新语义提交来源名称变更。
        // 涉及表：source。
        // 关键过滤：仅按 id 精确命中；调用前已确认目标为有效且非默认来源。
        // 时间字段：created_date 保留原值，updated_date 写当前毫秒，last_sync_date 写 0，复刻 SourceModelMapper 编辑路径。
        // 副作用用途：更新 name，同时保留 source_order/bookshelf_order/is_hide 并把 is_deleted 维持为 0。
        let sql = """
            UPDATE source
            SET name = ?,
                source_order = ?,
                bookshelf_order = ?,
                is_hide = ?,
                created_date = ?,
                updated_date = ?,
                last_sync_date = 0,
                is_deleted = 0
            WHERE id = ?
            """
        try db.execute(
            sql: sql,
            arguments: [
                normalizedName,
                existing.sourceOrder,
                existing.bookshelfOrder,
                existing.isHide,
                existing.createdDate,
                timestampMillis(),
                sourceID
            ]
        )
    }

    nonisolated func ensureUnknownSource(_ db: Database, excludingSourceID: Int64) throws {
        // SQL 目的：删除来源前确保 Android 默认“未知”来源可作为迁移目标。
        // 涉及表：source。
        // 关键过滤：INSERT OR IGNORE 只补齐 id = 1；随后只在删除目标不是 1 时恢复 is_deleted = 0。
        // 时间字段：补齐记录时 created_date 使用当前毫秒，updated_date/last_sync_date 为 0。
        // 副作用用途：避免历史库中“未知”来源缺失或被软删除导致书籍迁移失败。
        let insertSQL = """
            INSERT OR IGNORE INTO source (id, name, source_order, bookshelf_order, is_hide, created_date, updated_date, last_sync_date, is_deleted)
            VALUES (?, ?, 0, -1, 0, ?, 0, 0, 0)
            """
        try db.execute(
            sql: insertSQL,
            arguments: [Constants.unknownSourceID, Constants.unknownSourceName, timestampMillis()]
        )

        let restoreSQL = """
            UPDATE source
            SET name = ?,
                is_deleted = 0
            WHERE id = ?
              AND id != ?
            """
        try db.execute(
            sql: restoreSQL,
            arguments: [Constants.unknownSourceName, Constants.unknownSourceID, excludingSourceID]
        )
    }

    nonisolated func migrateBooksToUnknownSource(_ db: Database, sourceID: Int64) throws {
        // SQL 目的：删除来源前把该来源下的有效书籍迁移到 Android 默认“未知”来源。
        // 涉及表：book。
        // 关键过滤：source_id = ? 且 is_deleted = 0，对齐 Android BookDao.updateOldSourceToNew，不额外排除 book.id = 0。
        // 时间字段：Android 迁移来源不更新 book.updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：避免有效书籍继续引用已软删除的来源。
        let sql = """
            UPDATE book
            SET source_id = ?
            WHERE source_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [Constants.unknownSourceID, sourceID])
    }

    nonisolated func softDeleteSource(_ db: Database, sourceID: Int64) throws {
        // SQL 目的：软删除来源主记录。
        // 涉及表：source。
        // 关键过滤：按 id 精确命中，对齐 Android SourceDao.delete。
        // 时间字段：Android 来源删除不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：从来源管理和来源维度入口中移除该来源。
        let sql = """
            UPDATE source
            SET is_deleted = 1
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [sourceID])
    }

    nonisolated func fetchOrderedActiveSourceIDs(_ db: Database, scope: SourceManagementScope) throws -> [Int64] {
        let predicate: String
        switch scope {
        case .mine:
            predicate = "id NOT BETWEEN \(Constants.defaultSourceIDRange.lowerBound) AND \(Constants.defaultSourceIDRange.upperBound)"
        case .appDefault:
            predicate = "id BETWEEN \(Constants.defaultSourceIDRange.lowerBound) AND \(Constants.defaultSourceIDRange.upperBound)"
        }

        // SQL 目的：读取当前范围有效来源的展示顺序，用于校验拖拽提交是否仍覆盖全量列表。
        // 涉及表：source。
        // 关键过滤：is_deleted = 0，并按默认来源 ID 范围拆分我的来源/默认来源。
        // 时间字段：不读取时间；后续 updateSourceOrder 会逐条写 updated_date。
        // 返回字段用途：返回按 source_order ASC 排列的来源 id 列表。
        let sql = """
            SELECT id
            FROM source
            WHERE is_deleted = 0
              AND \(predicate)
            ORDER BY source_order ASC, id ASC
            """
        return try Int64.fetchAll(db, sql: sql)
    }

    nonisolated func updateSourceOrder(
        _ db: Database,
        sourceID: Int64,
        order: Int,
        updatedAt: Int64
    ) throws {
        // SQL 目的：写入来源管理页手动排序后的 source_order。
        // 涉及表：source。
        // 关键过滤：按 id 精确命中且 is_deleted = 0；调用前已校验只排序我的来源。
        // 时间字段：updated_date 写当前毫秒，对齐 Android SourceDao.updateOrderSync；last_sync_date 不更新。
        // 副作用用途：调整来源维度展示顺序并让同步层可感知排序变更。
        let sql = """
            UPDATE source
            SET source_order = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [Int64(order), updatedAt, sourceID])
    }

    nonisolated func isDefaultSourceID(_ sourceID: Int64) -> Bool {
        Constants.defaultSourceIDRange.contains(sourceID)
    }

    nonisolated func uniquePositiveIDs(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { id in
            guard id > 0, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    nonisolated func timestampMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
