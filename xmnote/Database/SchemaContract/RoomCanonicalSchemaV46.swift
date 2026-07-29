/**
 * [INPUT]: 依赖 Android Room 导出的 v46 schema JSON 与 GRDB Database 执行 v45→v46 结构迁移和物理校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV46，作为当前 iOS/Android 双向恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v46 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v46 物理结构合同，为 Notion 页面同步增加页面级快速判断基线。
nonisolated enum RoomCanonicalSchemaV46 {
    nonisolated static let databaseVersion = 46
    nonisolated static let identityHash = "8019b8b1a1d40aaf04de2b601c403e7d"
    nonisolated static let schemaResourceName = "RoomSchemaV46"

    /// 按 Room v46 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=46。
    nonisolated static func createAllTables(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createAllTables(
            db,
            schema: try loadSchema(),
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }

    /// 在 Room v45 数据库上为 notion_page_sync 增加三个非空文本基线字段。
    nonisolated static func migrateFromV45(_ db: Database) throws {
        // SQL 目的：保存上次成功导出时的本地页面内容指纹，支持页面级快速跳过。
        // 涉及表：notion_page_sync；旧记录以空字符串表示尚无基线。
        // 副作用：为全部既有行写入默认空字符串，不修改其他业务字段。
        try db.execute(sql: """
            ALTER TABLE notion_page_sync
            ADD COLUMN source_fingerprint TEXT NOT NULL DEFAULT ''
            """)

        // SQL 目的：保存远端 Notion 页面最后编辑时间，用于快速冲突判断。
        // 涉及表：notion_page_sync；旧记录以空字符串表示尚未读取远端基线。
        // 时间字段：保留 Notion API 原始文本，不转为本地时区或 Unix 毫秒。
        // 副作用：为全部既有行写入默认空字符串。
        try db.execute(sql: """
            ALTER TABLE notion_page_sync
            ADD COLUMN remote_last_edited_time TEXT NOT NULL DEFAULT ''
            """)

        // SQL 目的：保存上次导出的标题，区分用户远端改名和本地标题变化。
        // 涉及表：notion_page_sync；旧记录以空字符串表示尚无标题基线。
        // 副作用：为全部既有行写入默认空字符串。
        try db.execute(sql: """
            ALTER TABLE notion_page_sync
            ADD COLUMN last_exported_title TEXT NOT NULL DEFAULT ''
            """)

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=46，标记 v45→v46 schema 迁移完成。
        // 涉及表：无；副作用：更新数据库版本号为 Android v46。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v46 identity hash；调用方必须先确保实际表结构已达到 v46。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createRoomMasterTable(db, identityHash: identityHash)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v46。
    nonisolated static func hasValidIdentityHash(_ db: Database) throws -> Bool {
        try RoomCanonicalSchemaSupport.hasValidIdentityHash(db, identityHash: identityHash)
    }

    /// 校验当前数据库是否与 Android Room v46 物理 schema 合同一致。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.validatePhysicalSchema(
            db,
            schema: try loadSchema(),
            identityHash: identityHash,
            versionLabel: "Room v46"
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

    /// 加载并校验随应用打包的 Android Room v46 schema JSON。
    nonisolated static func loadSchema() throws -> RoomDatabaseSchema {
        try RoomCanonicalSchemaSupport.loadSchema(
            resourceName: schemaResourceName,
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }
}
