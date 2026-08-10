/**
 * [INPUT]: 依赖 DatabaseManager、GRDB、ObservationStream、GroupRecord 与 BookRepository 书架对齐 helper，按 Android GroupRepository/GroupDao 语义执行书籍分组管理读写
 * [OUTPUT]: 对外提供 BookGroupManagementRepository（BookGroupManagementRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层书籍分组管理仓储实现，统一封装“我的 > 书籍分组”的分组列表、增改删与排序写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 书籍分组管理仓储实现，严格对齐 Android 分组管理页的数据写入与查询语义。
struct BookGroupManagementRepository: BookGroupManagementRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let bookshelfHelper: BookRepository

    /// 注入数据库管理器，并复用 BookRepository 内部已对齐的书架排序、分组预览与移出书籍 helper。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        self.bookshelfHelper = BookRepository(databaseManager: databaseManager)
    }

    /// 观察有效书籍分组快照；分组、组书关系或书籍变化后自动刷新。
    func observeBookGroupManagementSnapshot() -> AsyncThrowingStream<BookGroupManagementSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchSnapshot(db)
        }
    }

    /// 新建分组；Android GroupManage 只校验空名和长度，不阻止同名分组。
    func createGroup(named name: String) async throws {
        let normalizedName = try validatedName(name)
        try await databaseManager.database.dbPool.write { db in
            let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
            var record = GroupRecord(
                id: nil,
                userId: ownerID,
                name: normalizedName,
                groupOrder: try bookshelfHelper.minDefaultBookshelfOrder(db) - 1,
                pinned: 0,
                pinOrder: 0,
                createdDate: bookshelfHelper.timestampMillis(),
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
        }
    }

    /// 重命名有效分组；不做同名拦截，避免偏离 Android GroupManage 页面语义。
    func updateGroup(groupID: Int64, name: String) async throws {
        let normalizedName = try validatedName(name)
        try await databaseManager.database.dbPool.write { db in
            guard try bookshelfHelper.isActiveGroup(db, groupID: groupID) else {
                throw BookGroupManagementRepositoryError.invalidGroup
            }
            try updateGroupName(
                db,
                groupID: groupID,
                name: normalizedName,
                updatedAt: bookshelfHelper.timestampMillis()
            )
        }
    }

    /// 批量删除分组；每个分组独立写事务，保持 Android 批量删除逐项处理的失败边界。
    func deleteGroups(groupIDs: [Int64], placement: GroupBooksPlacement) async throws {
        let uniqueIDs = uniquePositiveIDs(groupIDs)
        guard !uniqueIDs.isEmpty else { throw BookGroupManagementRepositoryError.emptySelection }

        for groupID in uniqueIDs {
            try await databaseManager.database.dbPool.write { db in
                do {
                    try bookshelfHelper.deleteGroup(db, groupID: groupID, placement: placement)
                } catch BookRepository.BookshelfBatchWriteError.invalidGroup {
                    throw BookGroupManagementRepositoryError.invalidGroup
                }
            }
        }
    }

    /// 按管理页最终顺序写入 group_order；对齐 Android GroupDao.updateGroupOrder，会同步更新 updated_date。
    func updateGroupOrder(groupIDs: [Int64]) async throws {
        let orderedIDs = uniquePositiveIDs(groupIDs)
        guard orderedIDs.count == groupIDs.count, !orderedIDs.isEmpty else {
            throw BookGroupManagementRepositoryError.staleOrder
        }

        try await databaseManager.database.dbPool.write { db in
            let activeIDs = try fetchActiveGroupIDs(db)
            guard orderedIDs.count == activeIDs.count, Set(orderedIDs) == Set(activeIDs) else {
                throw BookGroupManagementRepositoryError.staleOrder
            }
            for (index, groupID) in orderedIDs.enumerated() {
                try updateGroupOrder(
                    db,
                    groupID: groupID,
                    order: Int64(index),
                    updatedAt: bookshelfHelper.timestampMillis()
                )
            }
        }
    }
}

private extension BookGroupManagementRepository {
    nonisolated func fetchSnapshot(_ db: Database) throws -> BookGroupManagementSnapshot {
        let options = try bookshelfHelper.fetchMoveTargetGroups(db, excludingGroupID: nil)
        return BookGroupManagementSnapshot(
            groups: options.map { option in
                BookGroupManagementItem(
                    id: option.id,
                    name: option.title,
                    bookCount: option.bookCount,
                    representativeCovers: option.representativeCovers
                )
            }
        )
    }

    nonisolated func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 100
        guard !trimmed.isEmpty else { throw BookGroupManagementRepositoryError.invalidName }
        guard trimmed.count <= maxLength else {
            throw BookGroupManagementRepositoryError.invalidNameLength(maxLength: maxLength)
        }
        return trimmed
    }

    nonisolated func updateGroupName(
        _ db: Database,
        groupID: Int64,
        name: String,
        updatedAt: Int64
    ) throws {
        // SQL 目的：重命名有效书籍分组。
        // 涉及表：`group`。
        // 关键过滤：id = ? 且 is_deleted = 0，对齐 Android GroupDao.updateName。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新分组名称，并触发书架与分组管理观察流刷新。
        let sql = """
            UPDATE `group`
            SET updated_date = ?,
                name = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, name, groupID])
    }

    nonisolated func fetchActiveGroupIDs(_ db: Database) throws -> [Int64] {
        // SQL 目的：读取当前全部有效分组 id，校验拖拽排序提交是否仍覆盖完整列表。
        // 涉及表：`group`。
        // 关键过滤：is_deleted = 0。
        // 时间字段：不读取时间；后续排序写入逐条更新 updated_date。
        // 返回字段用途：用于防止列表已变化时把旧顺序写回数据库。
        let sql = """
            SELECT id
            FROM `group`
            WHERE is_deleted = 0
            ORDER BY group_order ASC
            """
        return try Int64.fetchAll(db, sql: sql)
    }

    nonisolated func updateGroupOrder(
        _ db: Database,
        groupID: Int64,
        order: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：写入分组管理页的手动排序下标。
        // 涉及表：`group`。
        // 关键过滤：仅按 id 精确命中，对齐 Android GroupDao.updateGroupOrder。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新 group_order 并产生同步可感知的更新时间。
        let sql = """
            UPDATE `group`
            SET updated_date = ?,
                group_order = ?
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [updatedAt, order, groupID])
    }

    nonisolated func uniquePositiveIDs(_ ids: [Int64]) -> [Int64] {
        ids.reduce(into: [Int64]()) { result, id in
            guard id > 0, !result.contains(id) else { return }
            result.append(id)
        }
    }
}
