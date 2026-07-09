/**
 * [INPUT]: 依赖 Android Room 导出的 v44 schema JSON 与 GRDB Database 执行 v43 数据清理迁移和物理校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV44，作为当前 iOS/Android 双向恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v44 schema 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v44 物理结构合同，覆盖历史空书哨兵关系清理与 Room identity hash 校验。
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

    /// 在已具备 Room v43 物理结构的数据库上执行 Android 43→44 等价数据清理迁移。
    nonisolated static func migrateFromV43(_ db: Database) throws {
        for table in ["book_read_status_record", "collection_book", "read_time_record"] {
            try softDeleteInvalidBookRelations(in: table, db: db)
        }

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=44，标记 v43→v44 数据清理迁移已完成。
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

    nonisolated static func loadSchema() throws -> RoomDatabaseSchema {
        try RoomCanonicalSchemaSupport.loadSchema(
            resourceName: schemaResourceName,
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }
}

private extension RoomCanonicalSchemaV44 {
    nonisolated static func softDeleteInvalidBookRelations(in table: String, db: Database) throws {
        // SQL 目的：对齐 Android MIGRATION_43_44，软删除历史空书哨兵产生的活跃书籍关系脏记录。
        // 涉及表：book_read_status_record、collection_book、read_time_record；关键过滤：is_deleted=0 且 book_id<=0。
        // 时间字段：updated_date 使用 SQLite 当前 UTC 秒时间戳乘以 1000，与 Android strftime('%s','now') * 1000 语义一致。
        // 副作用：仅标记无效关系为软删除，不删除默认 book/category/chapter 根数据，不清理正数孤儿外键。
        try db.execute(sql: """
            UPDATE \(quote(table))
            SET is_deleted = 1,
                updated_date = CAST(strftime('%s', 'now') AS INTEGER) * 1000
            WHERE is_deleted = 0
              AND book_id <= 0
        """)
    }

    nonisolated static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
