/**
 * [INPUT]: 依赖 Android Room 导出的 v42 schema JSON 与 GRDB Database 执行 v41 升级和物理校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV42，作为 Android Room v42 备份恢复与迁移分派合同
 * [POS]: Database/SchemaContract 的 Room v42 schema 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v42 物理结构合同，覆盖书籍微信读书原始 bookId 字段与 Room identity hash 校验。
nonisolated enum RoomCanonicalSchemaV42 {
    nonisolated static let databaseVersion = 42
    nonisolated static let identityHash = "4e0d2220f86e560a5ca24defac2ceefe"
    nonisolated static let schemaResourceName = "RoomSchemaV42"

    /// 按 Room v42 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=42。
    nonisolated static func createAllTables(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createAllTables(
            db,
            schema: try loadSchema(),
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }

    /// 在已具备 Room v41 物理结构的数据库上执行 Android 41→42 等价迁移。
    nonisolated static func migrateFromV41(_ db: Database) throws {
        let existingColumns = Set(try RoomCanonicalSchemaSupport.columnNames(in: "book", db: db))
        if !existingColumns.contains("weread_book_id") {
            // SQL 目的：执行 Android 41→42 书籍字段补丁，补齐微信读书原始 bookId。
            // 涉及表：book；关键字段：weread_book_id；副作用：旧书默认写入空字符串，满足 Room NOT NULL DEFAULT 语义。
            try db.execute(sql: "ALTER TABLE book ADD COLUMN weread_book_id TEXT NOT NULL DEFAULT ''")
        }

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=42，标记 v41→v42 schema 迁移已完成。
        // 涉及表：无；副作用：更新数据库版本号为 Android v42。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v42 identity hash；调用方必须先确保实际表结构已经 canonical。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createRoomMasterTable(db, identityHash: identityHash)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v42 可接受值。
    nonisolated static func hasValidIdentityHash(_ db: Database) throws -> Bool {
        try RoomCanonicalSchemaSupport.hasValidIdentityHash(db, identityHash: identityHash)
    }

    /// 校验当前数据库是否与 Android Room v42 物理 schema 合同一致；只读校验，不修复、不改业务表。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.validatePhysicalSchema(
            db,
            schema: try loadSchema(),
            identityHash: identityHash,
            versionLabel: "Room v42"
        )
    }

    /// 校验当前数据库的外键关系闭包是否完整；用于 staging 整理后阻断仍不可安全识别的备份。
    nonisolated static func assertForeignKeyIntegrity(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.assertForeignKeyCheckIsEmpty(db)
    }

    /// 校验当前数据库是否与 Android Room v42 物理 schema 合同一致，并且数据外键闭包完整。
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
