/**
 * [INPUT]: 依赖 Android Room 导出的 v45 schema JSON 与 GRDB Database 执行 v44→v45 结构迁移和物理校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV45，作为 Notion 同步映射表的跨端物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v45 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v45 物理结构合同，新增 Notion 页面、Block 和恢复操作三张同步表。
nonisolated enum RoomCanonicalSchemaV45 {
    nonisolated static let databaseVersion = 45
    nonisolated static let identityHash = "c3cabdc4132a8a9e7845cc467c360b77"
    nonisolated static let schemaResourceName = "RoomSchemaV45"

    /// 按 Room v45 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=45。
    nonisolated static func createAllTables(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createAllTables(
            db,
            schema: try loadSchema(),
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }

    /// 在 Room v44 数据库上创建 Android v45 的三张 Notion 同步表和六个索引。
    nonisolated static func migrateFromV44(_ db: Database) throws {
        // SQL 目的：创建一本书在一个 Notion 数据源中的持续同步页面映射。
        // 涉及表：notion_page_sync；无外键；唯一键约束由后续索引提供。
        // 时间字段：first_sync_date/last_sync_date 均保存 Unix 毫秒；不做时区转换。
        // 副作用：只新增空表，不读取或修改既有业务数据。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS notion_page_sync (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                connection_key TEXT NOT NULL,
                data_source_id TEXT NOT NULL,
                scope TEXT NOT NULL,
                book_id INTEGER NOT NULL,
                sync_id TEXT NOT NULL,
                page_id TEXT NOT NULL,
                page_url TEXT NOT NULL,
                status TEXT NOT NULL,
                conflict_count INTEGER NOT NULL,
                first_sync_date INTEGER NOT NULL,
                last_sync_date INTEGER NOT NULL
            )
            """)

        // SQL 目的：保证一个连接、数据源、范围和书籍只对应一个持续同步页面。
        // 涉及表：notion_page_sync；关键字段：connection_key、data_source_id、scope、book_id。
        // 副作用：新增唯一索引，不改业务行。
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS
            index_notion_page_sync_connection_key_data_source_id_scope_book_id
            ON notion_page_sync(connection_key, data_source_id, scope, book_id)
            """)

        // SQL 目的：加速通过稳定同步 ID 定位 Notion 页面映射。
        // 涉及表：notion_page_sync；关键字段：sync_id。
        // 副作用：新增普通索引，不改业务行。
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS index_notion_page_sync_sync_id
            ON notion_page_sync(sync_id)
            """)

        // SQL 目的：保证一个远端 Notion page_id 只归属一个本地页面映射。
        // 涉及表：notion_page_sync；关键字段：page_id。
        // 副作用：新增唯一索引，不改业务行。
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS index_notion_page_sync_page_id
            ON notion_page_sync(page_id)
            """)

        // SQL 目的：创建可独立进行冲突判断的 Notion 内容单元映射。
        // 涉及表：notion_block_sync；page_sync_id 级联引用 notion_page_sync.id。
        // 时间字段：source_updated_date/last_sync_date 保存 Unix 毫秒；不做时区转换。
        // 副作用：新增空表；删除页面映射时级联删除 Block 映射。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS notion_block_sync (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                page_sync_id INTEGER NOT NULL,
                unit_key TEXT NOT NULL,
                content_type TEXT NOT NULL,
                source_id INTEGER NOT NULL,
                source_updated_date INTEGER NOT NULL,
                source_fingerprint TEXT NOT NULL,
                remote_fingerprint TEXT NOT NULL,
                block_ids_json TEXT NOT NULL,
                anchor_key TEXT NOT NULL,
                deletable INTEGER NOT NULL,
                state TEXT NOT NULL,
                last_sync_date INTEGER NOT NULL,
                FOREIGN KEY(page_sync_id) REFERENCES notion_page_sync(id)
                    ON UPDATE NO ACTION ON DELETE CASCADE
            )
            """)

        // SQL 目的：加速按页面映射读取全部 Notion Block 同步单元。
        // 涉及表：notion_block_sync；关键字段：page_sync_id。
        // 副作用：新增普通索引，不改业务行。
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS index_notion_block_sync_page_sync_id
            ON notion_block_sync(page_sync_id)
            """)

        // SQL 目的：保证同一 Notion 页面内的业务 unit_key 唯一。
        // 涉及表：notion_block_sync；关键字段：page_sync_id、unit_key。
        // 副作用：新增唯一索引，不改业务行。
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS index_notion_block_sync_page_sync_id_unit_key
            ON notion_block_sync(page_sync_id, unit_key)
            """)

        // SQL 目的：记录 Notion 非事务远端写入的本地恢复操作。
        // 涉及表：notion_sync_operation；page_sync_id 级联引用 notion_page_sync.id。
        // 时间字段：source_updated_date/created_date/updated_date 保存 Unix 毫秒；不做时区转换。
        // 副作用：新增空表；删除页面映射时级联删除未完成恢复操作。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS notion_sync_operation (
                operation_id TEXT PRIMARY KEY NOT NULL,
                page_sync_id INTEGER NOT NULL,
                unit_key TEXT NOT NULL,
                operation_type TEXT NOT NULL,
                state TEXT NOT NULL,
                old_block_ids_json TEXT NOT NULL,
                new_block_ids_json TEXT NOT NULL,
                blocks_json TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                source_updated_date INTEGER NOT NULL,
                created_date INTEGER NOT NULL,
                updated_date INTEGER NOT NULL,
                FOREIGN KEY(page_sync_id) REFERENCES notion_page_sync(id)
                    ON UPDATE NO ACTION ON DELETE CASCADE
            )
            """)

        // SQL 目的：加速按页面映射查找待恢复的 Notion 同步操作。
        // 涉及表：notion_sync_operation；关键字段：page_sync_id。
        // 副作用：新增普通索引，不改业务行。
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS index_notion_sync_operation_page_sync_id
            ON notion_sync_operation(page_sync_id)
            """)

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=45，标记 v44→v45 schema 迁移完成。
        // 涉及表：无；副作用：更新数据库版本号为 Android v45。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v45 identity hash；调用方必须先确保实际表结构已达到 v45。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createRoomMasterTable(db, identityHash: identityHash)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v45。
    nonisolated static func hasValidIdentityHash(_ db: Database) throws -> Bool {
        try RoomCanonicalSchemaSupport.hasValidIdentityHash(db, identityHash: identityHash)
    }

    /// 校验当前数据库是否与 Android Room v45 物理 schema 合同一致。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.validatePhysicalSchema(
            db,
            schema: try loadSchema(),
            identityHash: identityHash,
            versionLabel: "Room v45"
        )
    }

    /// 校验当前数据库的外键关系闭包是否完整。
    nonisolated static func assertForeignKeyIntegrity(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.assertForeignKeyCheckIsEmpty(db)
    }

    /// 校验物理结构和数据外键闭包。
    nonisolated static func validateExistingDatabase(_ db: Database) throws {
        try validatePhysicalSchema(db)
        try assertForeignKeyIntegrity(db)
    }

    /// 加载并校验随应用打包的 Android Room v45 schema JSON。
    nonisolated static func loadSchema() throws -> RoomDatabaseSchema {
        try RoomCanonicalSchemaSupport.loadSchema(
            resourceName: schemaResourceName,
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }
}
