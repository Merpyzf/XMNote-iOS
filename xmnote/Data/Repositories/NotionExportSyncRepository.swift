/**
 * [INPUT]: 依赖 AppDatabase、GRDB 与 Android Room v45 的 Notion page/block/operation Record
 * [OUTPUT]: 对外提供 NotionExportSyncRepository，完成页面映射、Block 映射、恢复日志及原子收尾事务
 * [POS]: Data/Repositories 的 Notion 导出恢复状态 owner；远端 Service 只编排协议，不直接读写同步表
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 严格复刻 Android NotionSyncDao 的事务边界，避免远端非事务写入完成前提前切换正式映射。
nonisolated struct NotionExportSyncRepository: Sendable {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// 按连接、数据源和书籍唯一键读取持续同步页面。
    func findPage(connectionKey: String, dataSourceID: String, bookID: Int64) async throws -> NotionPageSyncRecord? {
        try await database.dbPool.read { db in
            // SQL 目的：查找一本书在当前 Notion 连接和数据源中的唯一托管页面。
            // 涉及表：notion_page_sync；无关联表。
            // 关键过滤：connection_key、data_source_id、book_id 精确匹配，唯一索引保证最多一行。
            // 时间字段：不参与过滤；返回毫秒时间戳和远端 ISO 时间原值。
            // 返回字段用途：决定复用、恢复、冲突处理或提示重建。
            try NotionPageSyncRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM notion_page_sync
                    WHERE connection_key = ?
                      AND data_source_id = ?
                      AND book_id = ?
                    LIMIT 1
                    """,
                arguments: [connectionKey, dataSourceID, bookID]
            )
        }
    }

    /// 新建页面映射；唯一键冲突按 Android ABORT 语义向上抛出。
    func insertPage(_ page: NotionPageSyncRecord) async throws -> Int64 {
        try await database.dbPool.write { db in
            let stored = page
            try stored.insert(db, onConflict: .abort)
            return stored.id ?? db.lastInsertedRowID
        }
    }

    /// 原子接管远端索引找回的页面，并可同时建立已验证内容指纹对应的顶层 Block 映射。
    func insertRecoveredPage(
        _ page: NotionPageSyncRecord,
        recoveredBlock: NotionBlockSyncRecord?
    ) async throws -> Int64 {
        try await insertRecoveredPage(
            page,
            recoveredBlocks: recoveredBlock.map { [$0] } ?? []
        )
    }

    /// 原子接管远端页面及其全部已验证内容单元，避免页面映射与 Block 映射之间出现半恢复状态。
    func insertRecoveredPage(
        _ page: NotionPageSyncRecord,
        recoveredBlocks: [NotionBlockSyncRecord]
    ) async throws -> Int64 {
        try await database.dbPool.write { db in
            let storedPage = page
            try storedPage.insert(db, onConflict: .abort)
            let pageSyncID = storedPage.id ?? db.lastInsertedRowID
            for var recoveredBlock in recoveredBlocks {
                recoveredBlock.pageSyncId = pageSyncID
                _ = try Self.upsertBlock(recoveredBlock, db: db)
            }
            return pageSyncID
        }
    }

    /// 更新完整页面同步基线。
    func updatePage(_ page: NotionPageSyncRecord) async throws {
        try await database.dbPool.write { db in
            try page.update(db)
        }
    }

    /// 删除页面映射，并由 v45 外键级联清理 Block 与操作日志。
    func deletePage(id: Int64) async throws {
        try await database.dbPool.write { db in
            // SQL 目的：删除失效的 Notion 托管页面本地映射。
            // 涉及表：notion_page_sync；notion_block_sync、notion_sync_operation 由外键 ON DELETE CASCADE 清理。
            // 关键过滤：页面映射主键精确匹配。
            // 时间字段：无。
            // 副作用：后续导出必须重新解析或在用户确认后重建页面。
            try db.execute(sql: "DELETE FROM notion_page_sync WHERE id = ?", arguments: [id])
        }
    }

    /// 原子递增冲突次数，保留远端用户编辑的审计事实。
    func incrementConflictCount(pageSyncID: Int64) async throws {
        try await database.dbPool.write { db in
            try Self.incrementConflictCount(pageSyncID: pageSyncID, db: db)
        }
    }

    /// 按 Android 自增主键顺序返回页面的全部正式 Block 映射。
    func blocks(pageSyncID: Int64) async throws -> [NotionBlockSyncRecord] {
        try await database.dbPool.read { db in
            // SQL 目的：恢复页面内全部独立内容单元的远端 Block 映射。
            // 涉及表：notion_block_sync；通过 page_sync_id 归属 notion_page_sync。
            // 关键过滤：page_sync_id 精确匹配，按 id 保持首次同步顺序。
            // 时间字段：不参与排序；last_sync_date 为毫秒。
            // 返回字段用途：差量同步、删除保留和冲突指纹比较。
            try NotionBlockSyncRecord.fetchAll(
                db,
                sql: "SELECT * FROM notion_block_sync WHERE page_sync_id = ? ORDER BY id",
                arguments: [pageSyncID]
            )
        }
    }

    /// 读取页面内一个稳定 unit_key 的正式映射。
    func findBlock(pageSyncID: Int64, unitKey: String) async throws -> NotionBlockSyncRecord? {
        try await database.dbPool.read { db in
            // SQL 目的：按稳定内容单元键定位一个 Notion Block 映射。
            // 涉及表：notion_block_sync。
            // 关键过滤：page_sync_id 与 unit_key 精确匹配；组合唯一索引保证最多一行。
            // 时间字段：无。
            // 返回字段用途：决定新建、替换、跳过或冲突保留。
            try NotionBlockSyncRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM notion_block_sync
                    WHERE page_sync_id = ? AND unit_key = ?
                    LIMIT 1
                    """,
                arguments: [pageSyncID, unitKey]
            )
        }
    }

    /// 以 SQLite REPLACE 语义保存 Block 映射，与 Android OnConflictStrategy.REPLACE 一致。
    func upsertBlock(_ block: NotionBlockSyncRecord) async throws -> Int64 {
        try await database.dbPool.write { db in
            try Self.upsertBlock(block, db: db)
        }
    }

    /// 删除一个正式 Block 映射；远端删除必须先完成或被恢复日志确认。
    func deleteBlock(id: Int64) async throws {
        try await database.dbPool.write { db in
            try Self.deleteBlock(id: id, db: db)
        }
    }

    /// 清空页面的正式 Block 映射，用于已记录初始化/重建操作后的恢复准备。
    func deleteBlocks(pageSyncID: Int64) async throws {
        try await database.dbPool.write { db in
            try Self.deleteBlocks(pageSyncID: pageSyncID, db: db)
        }
    }

    /// 按创建时间返回尚未完成的远端写入操作。
    func operations(pageSyncID: Int64) async throws -> [NotionSyncOperationRecord] {
        try await database.dbPool.read { db in
            // SQL 目的：恢复页面尚未完成的 Notion 非事务远端写入。
            // 涉及表：notion_sync_operation；通过 page_sync_id 归属 notion_page_sync。
            // 关键过滤：page_sync_id 精确匹配，按 created_date 升序重放。
            // 时间字段：created_date/updated_date/source_updated_date 均为 Unix 毫秒。
            // 返回字段用途：应用启动或再次导出时继续同一操作，避免重复页面或 Block。
            try NotionSyncOperationRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM notion_sync_operation
                    WHERE page_sync_id = ?
                    ORDER BY created_date
                    """,
                arguments: [pageSyncID]
            )
        }
    }

    /// 按 operation_id 使用 REPLACE 语义保存恢复日志。
    func upsertOperation(_ operation: NotionSyncOperationRecord) async throws {
        try await database.dbPool.write { db in
            try operation.save(db, onConflict: .replace)
        }
    }

    /// 删除已经完成并切换正式映射的恢复日志。
    func deleteOperation(operationID: String) async throws {
        try await database.dbPool.write { db in
            try Self.deleteOperation(operationID: operationID, db: db)
        }
    }

    /// 删除同类恢复日志，用于一页只保留一个初始化或重建意图。
    func deleteOperations(pageSyncID: Int64, operationType: String) async throws {
        try await database.dbPool.write { db in
            // SQL 目的：清理页面同一类型的旧恢复日志。
            // 涉及表：notion_sync_operation。
            // 关键过滤：page_sync_id、operation_type 精确匹配。
            // 时间字段：无。
            // 副作用：只保留调用方随后写入的当前恢复意图。
            try db.execute(
                sql: "DELETE FROM notion_sync_operation WHERE page_sync_id = ? AND operation_type = ?",
                arguments: [pageSyncID, operationType]
            )
        }
    }

    /// 原子完成普通替换：删除旧映射、写入新映射、最后删除操作日志。
    func completeReplacement(
        operationID: String,
        oldBlockID: Int64?,
        newBlock: NotionBlockSyncRecord
    ) async throws {
        try await database.dbPool.write { db in
            if let oldBlockID { try Self.deleteBlock(id: oldBlockID, db: db) }
            _ = try Self.upsertBlock(newBlock, db: db)
            try Self.deleteOperation(operationID: operationID, db: db)
        }
    }

    /// 原子完成冲突替换，并只在正式映射切换成功时递增冲突数。
    func completeConflictReplacement(
        operationID: String,
        pageSyncID: Int64,
        oldBlockID: Int64?,
        newBlock: NotionBlockSyncRecord
    ) async throws {
        try await database.dbPool.write { db in
            if let oldBlockID { try Self.deleteBlock(id: oldBlockID, db: db) }
            _ = try Self.upsertBlock(newBlock, db: db)
            try Self.incrementConflictCount(pageSyncID: pageSyncID, db: db)
            try Self.deleteOperation(operationID: operationID, db: db)
        }
    }

    /// 原子完成页面初始化，将一组已确认的远端 Block 映射一次性转正。
    func completeInitialization(
        operationID: String,
        newBlocks: [NotionBlockSyncRecord]
    ) async throws {
        try await database.dbPool.write { db in
            for block in newBlocks { _ = try Self.upsertBlock(block, db: db) }
            try Self.deleteOperation(operationID: operationID, db: db)
        }
    }

    /// 原子完成保留式删除：移除正式映射、记录一次冲突，再删除日志。
    func completePreservedDeletion(
        operationID: String,
        pageSyncID: Int64,
        oldBlockID: Int64
    ) async throws {
        try await database.dbPool.write { db in
            try Self.deleteBlock(id: oldBlockID, db: db)
            try Self.incrementConflictCount(pageSyncID: pageSyncID, db: db)
            try Self.deleteOperation(operationID: operationID, db: db)
        }
    }

    /// 原子准备已找回页面：清空旧 Block、只保留当前初始化日志并更新页面基线。
    func prepareRecoveredPage(
        page: NotionPageSyncRecord,
        initializationOperation: NotionSyncOperationRecord
    ) async throws {
        guard let pageID = page.id else { return }
        try await database.dbPool.write { db in
            try Self.deleteBlocks(pageSyncID: pageID, db: db)
            // SQL 目的：恢复页面前删除除当前初始化操作外的过期日志。
            // 涉及表：notion_sync_operation。
            // 关键过滤：同一 page_sync_id 且 operation_id 不等于当前操作。
            // 时间字段：无。
            // 副作用：下一次恢复只会继续唯一的初始化操作。
            try db.execute(
                sql: "DELETE FROM notion_sync_operation WHERE page_sync_id = ? AND operation_id != ?",
                arguments: [pageID, initializationOperation.operationId]
            )
            try page.update(db)
            try initializationOperation.save(db, onConflict: .replace)
        }
    }

    /// 当页面指纹与本地快照完全一致时，原子重建缺失的 Block 映射并清除不再适用的恢复日志。
    func replaceRecoveredBlockMapping(_ block: NotionBlockSyncRecord) async throws {
        try await replaceRecoveredBlockMappings([block])
    }

    /// 当页面级指纹与冻结快照一致时，原子恢复全部内容单元映射，禁止只恢复整页占位后丢失细粒度冲突边界。
    func replaceRecoveredBlockMappings(_ blocks: [NotionBlockSyncRecord]) async throws {
        guard let pageSyncID = blocks.first?.pageSyncId,
              blocks.allSatisfy({ $0.pageSyncId == pageSyncID }) else { return }
        try await database.dbPool.write { db in
            try Self.deleteBlocks(pageSyncID: pageSyncID, db: db)
            // SQL 目的：远端索引已证明页面正文等于本次冻结快照时，清除旧的未完成操作。
            // 涉及表：notion_sync_operation，通过 page_sync_id 归属 notion_page_sync。
            // 关键过滤：page_sync_id 精确匹配。
            // 时间字段：无。
            // 副作用：恢复后的逐内容单元 Block 映射成为唯一后续替换与冲突判断基线。
            try db.execute(
                sql: "DELETE FROM notion_sync_operation WHERE page_sync_id = ?",
                arguments: [pageSyncID]
            )
            for block in blocks { _ = try Self.upsertBlock(block, db: db) }
        }
    }

    private static func upsertBlock(_ block: NotionBlockSyncRecord, db: Database) throws -> Int64 {
        let stored = block
        try stored.save(db, onConflict: .replace)
        return stored.id ?? db.lastInsertedRowID
    }

    private static func deleteBlock(id: Int64, db: Database) throws {
        // SQL 目的：删除已经被远端替换或保留删除的正式 Block 映射。
        // 涉及表：notion_block_sync。
        // 关键过滤：自增主键精确匹配。
        // 时间字段：无。
        // 副作用：后续同步不再把旧远端 Block 当作当前托管内容。
        try db.execute(sql: "DELETE FROM notion_block_sync WHERE id = ?", arguments: [id])
    }

    private static func deleteBlocks(pageSyncID: Int64, db: Database) throws {
        // SQL 目的：清空页面全部正式 Block 映射，为初始化或重建恢复让路。
        // 涉及表：notion_block_sync。
        // 关键过滤：page_sync_id 精确匹配。
        // 时间字段：无。
        // 副作用：仅恢复日志仍描述尚未转正的远端写入。
        try db.execute(sql: "DELETE FROM notion_block_sync WHERE page_sync_id = ?", arguments: [pageSyncID])
    }

    private static func incrementConflictCount(pageSyncID: Int64, db: Database) throws {
        // SQL 目的：原子记录一次远端用户内容与本地导出发生的冲突。
        // 涉及表：notion_page_sync。
        // 关键过滤：页面映射主键精确匹配。
        // 时间字段：无。
        // 副作用：conflict_count 加一并随页面元数据继续同步。
        try db.execute(
            sql: "UPDATE notion_page_sync SET conflict_count = conflict_count + 1 WHERE id = ?",
            arguments: [pageSyncID]
        )
    }

    private static func deleteOperation(operationID: String, db: Database) throws {
        // SQL 目的：删除已完整确认的 Notion 远端操作恢复日志。
        // 涉及表：notion_sync_operation。
        // 关键过滤：operation_id 主键精确匹配。
        // 时间字段：无。
        // 副作用：再次导出不会重复执行该远端写入。
        try db.execute(
            sql: "DELETE FROM notion_sync_operation WHERE operation_id = ?",
            arguments: [operationID]
        )
    }
}
