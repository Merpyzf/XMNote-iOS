/**
 * [INPUT]: 依赖 Android Room 导出的 v48 schema JSON 与 GRDB Database 执行 v47→v48 关系清理、去重和唯一索引迁移
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV48，作为书籍关系业务唯一性与跨端恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v48 事实源适配器，被迁移、恢复 staging 校验与书籍对齐测试调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v48 物理结构合同，为书单、标签和分组关系增加业务唯一约束。
nonisolated enum RoomCanonicalSchemaV48 {
    nonisolated static let databaseVersion = 48
    nonisolated static let identityHash = "cda5a591da1f57aca266af36255e5df7"
    nonisolated static let schemaResourceName = "RoomSchemaV48"

    /// 按 Room v48 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=48。
    nonisolated static func createAllTables(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createAllTables(
            db,
            schema: try loadSchema(),
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }

    /// 在 Room v47 数据库上物理清理关系 tombstone，稳定保留规范行并创建业务唯一索引。
    nonisolated static func migrateFromV47(_ db: Database) throws {
        // SQL 目的：清理三类关系表的历史软删除行，使后续唯一索引覆盖全部现存业务关系。
        // 涉及表：collection_book、tag_book、group_book。
        // 关键过滤：is_deleted != 0；时间字段：不参与；副作用：物理删除历史 tombstone。
        try db.execute(sql: "DELETE FROM collection_book WHERE is_deleted != 0")
        try db.execute(sql: "DELETE FROM tag_book WHERE is_deleted != 0")
        try db.execute(sql: "DELETE FROM group_book WHERE is_deleted != 0")

        // SQL 目的：同一书单与书籍业务键只保留最近更新、最近创建、主键最大的规范关系。
        // 涉及表：collection_book 自关联子查询。
        // 关键过滤：collection_id + book_id 相同；时间字段：updated_date/created_date 降序决定保留行。
        // 副作用：物理删除其余重复关系，完全复刻 Android MIGRATION_47_48。
        try db.execute(sql: """
            DELETE FROM collection_book
            WHERE id != (
                SELECT candidate.id
                FROM collection_book AS candidate
                WHERE candidate.collection_id = collection_book.collection_id
                  AND candidate.book_id = collection_book.book_id
                ORDER BY candidate.updated_date DESC,
                         candidate.created_date DESC,
                         candidate.id DESC
                LIMIT 1
            )
            """)

        // SQL 目的：同一书籍与标签业务键只保留最早创建、主键最小的规范关系。
        // 涉及表：tag_book 自关联子查询。
        // 关键过滤：book_id + tag_id 相同；时间字段：created_date 升序决定保留行。
        // 副作用：物理删除其余重复关系，完全复刻 Android MIGRATION_47_48。
        try db.execute(sql: """
            DELETE FROM tag_book
            WHERE id != (
                SELECT candidate.id
                FROM tag_book AS candidate
                WHERE candidate.book_id = tag_book.book_id
                  AND candidate.tag_id = tag_book.tag_id
                ORDER BY candidate.created_date ASC, candidate.id ASC
                LIMIT 1
            )
            """)

        // SQL 目的：一本书只保留最早创建、主键最小的一条分组归属关系。
        // 涉及表：group_book 自关联子查询。
        // 关键过滤：book_id 相同；时间字段：created_date 升序决定保留行。
        // 副作用：物理删除其余跨组或同组重复关系，完全复刻 Android MIGRATION_47_48。
        try db.execute(sql: """
            DELETE FROM group_book
            WHERE id != (
                SELECT candidate.id
                FROM group_book AS candidate
                WHERE candidate.book_id = group_book.book_id
                ORDER BY candidate.created_date ASC, candidate.id ASC
                LIMIT 1
            )
            """)

        // SQL 目的：为三类关系建立与 Android Room v48 同名、同列顺序的业务唯一索引。
        // 涉及表：collection_book、tag_book、group_book；关键过滤：无。
        // 时间字段：不参与；副作用：数据库层拒绝同一业务身份的重复现存关系。
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS index_collection_book_collection_id_book_id
            ON collection_book(collection_id, book_id)
            """)
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS index_tag_book_book_id_tag_id
            ON tag_book(book_id, tag_id)
            """)
        try db.execute(sql: "DROP INDEX IF EXISTS index_group_book_book_id")
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS index_group_book_book_id
            ON group_book(book_id)
            """)

        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=48，标记关系唯一性迁移完成。
        // 涉及表：无；时间字段：不参与；副作用：更新 Android/iOS 共用数据库版本号。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v48 identity hash；调用方必须先确保实际关系索引达到 v48。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createRoomMasterTable(db, identityHash: identityHash)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v48 可接受值。
    nonisolated static func hasValidIdentityHash(_ db: Database) throws -> Bool {
        try RoomCanonicalSchemaSupport.hasValidIdentityHash(db, identityHash: identityHash)
    }

    /// 校验当前数据库是否与 Android Room v48 物理 schema 合同一致。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.validatePhysicalSchema(
            db,
            schema: try loadSchema(),
            identityHash: identityHash,
            versionLabel: "Room v48"
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

    /// 加载并校验随应用打包的 Android Room v48 schema JSON。
    nonisolated static func loadSchema() throws -> RoomDatabaseSchema {
        try RoomCanonicalSchemaSupport.loadSchema(
            resourceName: schemaResourceName,
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }
}
