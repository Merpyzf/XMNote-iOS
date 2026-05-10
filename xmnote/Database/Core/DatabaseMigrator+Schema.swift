/**
 * [INPUT]: 依赖 GRDB DatabaseMigrator、RoomCanonicalSchemaV40 与 DatabaseSchema+Seed
 * [OUTPUT]: 对外提供 AppDatabase.migrator 与 Room canonical 迁移标识
 * [POS]: Database/Core 的迁移入口，被 AppDatabase.init 调用执行 Schema 创建
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - Room canonical v40 迁移
// 当前产品未正式上线，iOS 新库直接创建 Android Room v40 canonical schema，不再维护旧 iOS schema 补丁迁移。

extension AppDatabase {
    nonisolated static let roomSchemaMigrationIdentifier = "room-v40-schema"
    nonisolated static let roomSeedMigrationIdentifier = "room-v40-seed"

    nonisolated static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration(roomSchemaMigrationIdentifier) { db in
            try RoomCanonicalSchemaV40.createAllTables(db)
        }

        migrator.registerMigration(roomSeedMigrationIdentifier) { db in
            try seedInitialData(db)
        }

        return migrator
    }

    /// Android Room 备份库没有 GRDB 迁移表；仅补内部迁移标记，避免 iOS 打开恢复库时重复执行建表与 seed。
    nonisolated static func markRoomCanonicalMigrationsIfNeeded(_ db: Database) throws {
        let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard userVersion >= RoomCanonicalSchemaV40.databaseVersion else { return }

        if try db.tableExists("grdb_migrations") {
            return
        }

        try RoomCanonicalSchemaV40.validatePhysicalSchema(db)

        // SQL 目的：为 Android Room canonical 库补建 GRDB 内部迁移表，避免后续迁移器误判为空库。
        // 涉及表：grdb_migrations；副作用：只写 iOS 内部迁移标记，不修改任何业务表。
        try db.execute(sql: """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)
        """)
        try db.execute(
            sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
            arguments: [roomSchemaMigrationIdentifier]
        )
        try db.execute(
            sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
            arguments: [roomSeedMigrationIdentifier]
        )
    }
}
