/**
 * [INPUT]: 依赖 Android Room 导出的 v47 schema JSON 与 GRDB Database 执行 v46→v47 排序作用域数据迁移和物理校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV47，作为书摘列表章节排序与跨端恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v47 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v47 物理结构合同，保持 v46 schema 并拆分书摘列表与目录页的章节排序状态。
nonisolated enum RoomCanonicalSchemaV47 {
    nonisolated static let databaseVersion = 47
    nonisolated static let identityHash = "4e076c66571412594ff567eae85b68fc"
    nonisolated static let schemaResourceName = "RoomSchemaV47"

    private nonisolated static let chapterContentType: Int64 = 1
    private nonisolated static let bookNotesChapterContentType: Int64 = 6

    /// 按 Room v47 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=47。
    nonisolated static func createAllTables(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createAllTables(
            db,
            schema: try loadSchema(),
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }

    /// 在 Room v46 数据库上复制最新目录排序规则，作为书摘列表独立章节排序的初始值。
    nonisolated static func migrateFromV46(_ db: Database) throws {
        let migratedAt = Int64(Date().timeIntervalSince1970 * 1_000)

        // SQL 目的：复刻 Android MIGRATION_46_47，为书摘列表建立独立的章节排序作用域。
        // 涉及表：sort；legacy/candidate 读取目录页 type=1，target 检查书摘列表章节 type=6。
        // 关键过滤：仅复制有效 type=1；同书重复记录按 updated_date DESC、id DESC 取最新；已有有效 type=6 时整书跳过。
        // 时间字段：created_date/updated_date 使用同一个迁移时刻的 Unix 毫秒；last_sync_date 固定 0。
        // 副作用：为命中书籍普通插入一条有效 type=6 排序记录；已删除 type=6 不阻止新记录，不修改任何历史记录。
        try db.execute(
            sql: """
                INSERT INTO sort (
                    book_id, type, "order",
                    created_date, updated_date, last_sync_date, is_deleted
                )
                SELECT
                    legacy.book_id, ?, legacy."order",
                    ?, ?, 0, 0
                FROM sort AS legacy
                WHERE legacy.type = ?
                  AND legacy.is_deleted = 0
                  AND legacy.id = (
                      SELECT candidate.id
                      FROM sort AS candidate
                      WHERE candidate.book_id = legacy.book_id
                        AND candidate.type = ?
                        AND candidate.is_deleted = 0
                      ORDER BY candidate.updated_date DESC, candidate.id DESC
                      LIMIT 1
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM sort AS target
                      WHERE target.book_id = legacy.book_id
                        AND target.type = ?
                        AND target.is_deleted = 0
                  )
                """,
            arguments: [
                bookNotesChapterContentType,
                migratedAt,
                migratedAt,
                chapterContentType,
                chapterContentType,
                bookNotesChapterContentType
            ]
        )

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=47，标记 v46→v47 排序作用域数据迁移完成。
        // 涉及表：无；副作用：更新数据库版本号为 Android v47。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v47 identity hash；调用方必须先确保实际表结构与排序数据迁移均达到 v47。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createRoomMasterTable(db, identityHash: identityHash)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v47 可接受值。
    nonisolated static func hasValidIdentityHash(_ db: Database) throws -> Bool {
        try RoomCanonicalSchemaSupport.hasValidIdentityHash(db, identityHash: identityHash)
    }

    /// 校验当前数据库是否与 Android Room v47 物理 schema 合同一致。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.validatePhysicalSchema(
            db,
            schema: try loadSchema(),
            identityHash: identityHash,
            versionLabel: "Room v47"
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

    /// 加载并校验随应用打包的 Android Room v47 schema JSON。
    nonisolated static func loadSchema() throws -> RoomDatabaseSchema {
        try RoomCanonicalSchemaSupport.loadSchema(
            resourceName: schemaResourceName,
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }
}
