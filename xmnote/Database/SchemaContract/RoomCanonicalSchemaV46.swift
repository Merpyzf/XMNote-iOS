/**
 * [INPUT]: 依赖 Android Room 导出的 v46 schema JSON 与 GRDB Database 执行 v45→v46 来源字典迁移和物理校验
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaV46，作为 Readest 内置来源与跨端恢复的 Room 物理 schema 合同
 * [POS]: Database/SchemaContract 的 Room v46 事实源适配器，被迁移与恢复 staging 校验流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room v46 物理结构合同，保持 v45 schema 并将 Readest 注册为 ID 28 的内置来源。
nonisolated enum RoomCanonicalSchemaV46 {
    nonisolated static let databaseVersion = 46
    nonisolated static let identityHash = "4e076c66571412594ff567eae85b68fc"
    nonisolated static let schemaResourceName = "RoomSchemaV46"

    private nonisolated static let readestSourceID: Int64 = 28
    private nonisolated static let unknownSourceID: Int64 = 1
    private nonisolated static let readestSourceName = "Readest"

    /// 按 Room v46 JSON 创建全部实体表、索引、room_master_table，并写入 user_version=46。
    nonisolated static func createAllTables(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createAllTables(
            db,
            schema: try loadSchema(),
            databaseVersion: databaseVersion,
            identityHash: identityHash
        )
    }

    /// 在 Room v45 数据库上移动冲突来源及书籍引用，并插入 Android v46 的 Readest 内置来源。
    nonisolated static func migrateFromV45(_ db: Database) throws {
        try createBookSourceBackup(db)
        try parkAffectedBooksAtUnknownSource(db)
        try shiftConflictingSourceIDs(db)
        try restoreShiftedBookSourceIDs(db)
        try insertReadestSource(db)
        try dropBookSourceBackup(db)
        try createRoomMasterTable(db)

        // SQL 目的：写入 SQLite user_version=46，标记 v45→v46 来源数据迁移完成。
        // 涉及表：无；副作用：更新数据库版本号为 Android v46。
        try db.execute(sql: "PRAGMA user_version = \(databaseVersion)")
    }

    /// 写入 Room v46 identity hash；调用方必须先确保实际表结构与来源迁移均达到 v46。
    nonisolated static func createRoomMasterTable(_ db: Database) throws {
        try RoomCanonicalSchemaSupport.createRoomMasterTable(db, identityHash: identityHash)
    }

    /// 判断数据库当前写入的 Room identity hash 是否为 v46 可接受值。
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

private extension RoomCanonicalSchemaV46 {
    /// 暂存所有受来源 ID 迁移影响的书籍和旧来源 ID，供外键安全恢复。
    nonisolated static func createBookSourceBackup(_ db: Database) throws {
        // SQL 目的：创建 Android v46 等价的连接级临时表，保存受影响书籍的旧来源 ID。
        // 涉及表：临时表 readest_source_book_backup；book_id 为主键，source_id 保存迁移前值。
        // 关键过滤：无；副作用：只创建临时表，不修改业务数据。
        try db.execute(sql: """
            CREATE TEMP TABLE readest_source_book_backup (
                book_id INTEGER PRIMARY KEY NOT NULL,
                source_id INTEGER NOT NULL
            )
            """)

        // SQL 目的：备份全部来源 ID 大于等于 28 的书籍引用，避免来源主键移动后丢失映射。
        // 涉及表：book、readest_source_book_backup；按 book.id 写入一对一备份。
        // 关键过滤：source_id >= 28；不排除软删除书籍，严格对齐 Android MIGRATION_45_46。
        // 时间字段：不读取、不转换；副作用：向临时表写入受影响书籍映射。
        try db.execute(
            sql: """
                INSERT INTO readest_source_book_backup(book_id, source_id)
                SELECT id, source_id
                FROM book
                WHERE source_id >= ?
                """,
            arguments: [readestSourceID]
        )
    }

    /// 将受影响书籍暂挂到未知来源，保证后续来源主键更新不破坏外键。
    nonisolated static func parkAffectedBooksAtUnknownSource(_ db: Database) throws {
        // SQL 目的：在移动来源主键前把受影响书籍暂时改挂到 Android 固定未知来源 ID 1。
        // 涉及表：book、readest_source_book_backup；通过 book_id 精确定位备份集合。
        // 关键过滤：仅处理已进入临时表的书籍；不排除软删除记录。
        // 时间字段：不修改 updated_date/last_sync_date；副作用：临时改写 book.source_id。
        try db.execute(
            sql: """
                UPDATE book
                SET source_id = ?
                WHERE id IN (
                    SELECT book_id
                    FROM readest_source_book_backup
                )
                """,
            arguments: [unknownSourceID]
        )
    }

    /// 按 ID 降序将占用 28 及以上编号的来源整体后移一位，避免唯一主键碰撞。
    nonisolated static func shiftConflictingSourceIDs(_ db: Database) throws {
        // SQL 目的：读取全部与 Readest 固定 ID 冲突的来源主键，并按降序提供安全迁移顺序。
        // 涉及表：source；返回字段：id。
        // 关键过滤：id >= 28；不排除软删除来源，严格对齐 Android MIGRATION_45_46。
        let sourceIDs = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM source WHERE id >= ? ORDER BY id DESC",
            arguments: [readestSourceID]
        )

        for sourceID in sourceIDs {
            // SQL 目的：逐项将来源主键加一，降序执行以避免连续 ID 的唯一约束冲突。
            // 涉及表：source；book 引用已在前一步暂存到未知来源。
            // 关键过滤：id 精确匹配；时间字段不修改；副作用：更新 source 主键。
            try db.execute(
                sql: "UPDATE source SET id = ? WHERE id = ?",
                arguments: [sourceID + 1, sourceID]
            )
        }
    }

    /// 按临时表记录把书籍恢复到后移一位的新来源 ID。
    nonisolated static func restoreShiftedBookSourceIDs(_ db: Database) throws {
        // SQL 目的：恢复受影响书籍的来源引用，并将迁移前来源 ID 加一映射到新主键。
        // 涉及表：book、readest_source_book_backup；通过 book.id 与临时表 book_id 关联。
        // 关键过滤：仅更新临时表内书籍；不排除软删除记录。
        // 时间字段：不修改 updated_date/last_sync_date；副作用：写回最终 book.source_id。
        try db.execute(sql: """
            UPDATE book
            SET source_id = (
                SELECT source_id + 1
                FROM readest_source_book_backup
                WHERE book_id = book.id
            )
            WHERE id IN (
                SELECT book_id
                FROM readest_source_book_backup
            )
            """)
    }

    /// 按 Android v46 字段默认值插入 Readest，并追加到当前有效来源排序末尾。
    nonisolated static func insertReadestSource(_ db: Database) throws {
        // SQL 目的：计算有效来源当前最大 source_order，空集合回退 -1，供 Readest 追加排序。
        // 涉及表：source；关键过滤：is_deleted = 0；返回字段：最大来源排序值。
        let maximumSourceOrder = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(source_order), -1) FROM source WHERE is_deleted = 0"
        ) ?? -1

        // SQL 目的：计算有效来源当前最大 bookshelf_order，空集合回退 -1，供 Readest 追加排序。
        // 涉及表：source；关键过滤：is_deleted = 0；返回字段：最大书架排序值。
        let maximumBookshelfOrder = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(bookshelf_order), -1) FROM source WHERE is_deleted = 0"
        ) ?? -1
        let createdAt = Int64(Date().timeIntervalSince1970 * 1_000)

        // SQL 目的：插入 Android v46 新增的 Readest 内置来源，固定占用 ID 28。
        // 涉及表：source；source_order/bookshelf_order 取有效来源当前最大值加一。
        // 关键过滤：无；时间字段 created_date 写当前 Unix 毫秒，updated_date/last_sync_date 固定 0。
        // 副作用：新增有效且可见的 Readest 来源，不修改其他来源业务字段。
        try db.execute(
            sql: """
                INSERT INTO source (
                    id, name, source_order, bookshelf_order, is_hide,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, 0, ?, 0, 0, 0)
                """,
            arguments: [
                readestSourceID,
                readestSourceName,
                maximumSourceOrder + 1,
                maximumBookshelfOrder + 1,
                createdAt
            ]
        )
    }

    /// 删除迁移临时表，避免同一连接后续操作误读过期映射。
    nonisolated static func dropBookSourceBackup(_ db: Database) throws {
        // SQL 目的：迁移成功后清理连接级临时备份表。
        // 涉及表：readest_source_book_backup；副作用：删除临时表，不影响业务表。
        try db.execute(sql: "DROP TABLE readest_source_book_backup")
    }
}
