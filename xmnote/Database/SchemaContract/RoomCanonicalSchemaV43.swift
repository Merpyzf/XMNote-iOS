/**
 * [INPUT]: 依赖 Android Room 导出的 v43 schema JSON 与 GRDB Database 执行 v42 升级和物理校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV43，作为当前 iOS/Android 双向恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v43 schema 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v43 物理结构合同，覆盖章节星标字段与 Room identity hash 校验。
nonisolated enum RoomCanonicalSchemaV43 {
    nonisolated static let databaseVersion = 43
    nonisolated static let identityHash = "24d3737f9e3495337a4fbe9d9b3ac68f"
    nonisolated static let schemaResourceName = "RoomSchemaV43"

    /// 按 Room v43 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=43。
    nonisolated static func createAllTables(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createAllTables(
            db,
            schema: try loadSchema(),
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }

    /// 在已具备 Room v42 物理结构的数据库上执行 Android 42→43 等价迁移。
    nonisolated static func migrateFromV42(_ db: Database) throws {
        let existingColumns = Set(try RoomCanonicalSchemaSupport.columnNames(in: "chapter", db: db))
        if !existingColumns.contains("is_starred") {
            // SQL 目的：执行 Android 42→43 章节字段补丁，补齐章节星标状态。
            // 涉及表：chapter；关键字段：is_starred；副作用：旧章节默认未星标，符合 Android Room 默认值。
            try db.execute(sql: "ALTER TABLE chapter ADD COLUMN is_starred INTEGER NOT NULL DEFAULT 0")
        }

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=43，标记 v42→v43 schema 迁移已完成。
        // 涉及表：无；副作用：更新数据库版本号为 Android v43。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v43 identity hash；调用方必须先确保实际表结构已经 canonical。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createRoomMasterTable(db, identityHash: identityHash)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v43 可接受值。
    nonisolated static func hasValidIdentityHash(_ db: Database) throws -> Bool {
        try RoomCanonicalSchemaSupport.hasValidIdentityHash(db, identityHash: identityHash)
    }

    /// 校验当前数据库是否与 Android Room v43 物理 schema 合同一致；只读校验，不修复、不改业务表。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.validatePhysicalSchema(
            db,
            schema: try loadSchema(),
            identityHash: identityHash,
            versionLabel: "Room v43"
        )
    }

    /// 校验当前数据库的外键关系闭包是否完整；用于 staging 整理后阻断仍不可安全识别的备份。
    nonisolated static func assertForeignKeyIntegrity(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.assertForeignKeyCheckIsEmpty(db)
    }

    /// 校验当前数据库是否与 Android Room v43 物理 schema 合同一致，并且数据外键闭包完整。
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
