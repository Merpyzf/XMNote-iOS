/**
 * [INPUT]: 依赖 Android Room 导出的 v44 schema JSON 与 GRDB Database 执行 v43 数据清理和物理校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV44，作为当前 iOS/Android 双向恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v44 schema 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v44 物理结构合同，覆盖空书哨兵关联脏数据清理与 Room identity hash 校验。
nonisolated enum RoomCanonicalSchemaV44 {
    nonisolated static let databaseVersion = 44
    nonisolated static let identityHash = "24d3737f9e3495337a4fbe9d9b3ac68f"
    nonisolated static let schemaResourceName = "RoomSchemaV44"

    /// 按 Room v44 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=44。
    nonisolated static func createAllTables(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createAllTables(
            db,
            schema: try loadSchema(),
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }

    /// 在已具备 Room v43 物理结构的数据库上执行 Android 43→44 等价迁移。
    nonisolated static func migrateFromV43(_ db: Database) throws {
        try softDeleteInvalidBookRelations(in: "book_read_status_record", db: db)
        try softDeleteInvalidBookRelations(in: "collection_book", db: db)
        try softDeleteInvalidBookRelations(in: "read_time_record", db: db)

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=44，标记 v43→v44 数据迁移已完成。
        // 涉及表：无；副作用：更新数据库版本号为 Android v44。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v44 identity hash；调用方必须先确保实际表结构已经 canonical。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createRoomMasterTable(db, identityHash: identityHash)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v44 可接受值。
    nonisolated static func hasValidIdentityHash(_ db: Database) throws -> Bool {
        try RoomCanonicalSchemaSupport.hasValidIdentityHash(db, identityHash: identityHash)
    }

    /// 校验当前数据库是否与 Android Room v44 物理 schema 合同一致；只读校验，不修复、不改业务表。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.validatePhysicalSchema(
            db,
            schema: try loadSchema(),
            identityHash: identityHash,
            versionLabel: "Room v44"
        )
    }

    /// 校验当前数据库的外键关系闭包是否完整；用于 staging 整理后阻断仍不可安全识别的备份。
    nonisolated static func assertForeignKeyIntegrity(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.assertForeignKeyCheckIsEmpty(db)
    }

    /// 校验当前数据库是否与 Android Room v44 物理 schema 合同一致，并且数据外键闭包完整。
    nonisolated static func validateExistingDatabase(_ db: Database) throws {
        try validatePhysicalSchema(db)
        try assertForeignKeyIntegrity(db)
    }

    /// 加载并校验随应用打包的 Android Room v44 schema JSON。
    nonisolated static func loadSchema() throws -> RoomDatabaseSchema {
        try RoomCanonicalSchemaSupport.loadSchema(
            resourceName: schemaResourceName,
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }
}

private extension RoomCanonicalSchemaV44 {
    /// 按 Android v44 规则软删除仍指向空书哨兵的有效关联记录；迁移器负责提供事务边界与失败回滚。
    nonisolated static func softDeleteInvalidBookRelations(in table: String, db: Database) throws {
        // SQL 目的：清理历史空书哨兵 book_id=0 及其他非正数书籍 ID 产生的有效关联脏记录。
        // 涉及表：book_read_status_record、collection_book 或 read_time_record；无跨表关联，表名只来自本类型内部常量。
        // 关键过滤：仅处理 is_deleted=0 且 book_id<=0 的记录；已软删除记录及正常书籍关联保持不变。
        // 时间处理：updated_date 使用 SQLite 当前 UTC Unix 秒乘 1000，与 Android MIGRATION_43_44 的毫秒时间戳完全一致。
        // 副作用：将命中记录的 is_deleted 置为 1 并刷新 updated_date，不删除 book.id=0 哨兵记录。
        try db.execute(sql: """
            UPDATE \(table)
            SET is_deleted = 1,
                updated_date = strftime('%s', 'now') * 1000
            WHERE is_deleted = 0
                AND book_id <= 0
            """)
    }
}
