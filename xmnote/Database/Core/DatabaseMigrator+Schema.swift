/**
 * [INPUT]: 依赖 GRDB DatabaseMigrator、RoomCanonicalSchemaV40/RoomCanonicalSchemaV41 与 DatabaseSchema+Seed
 * [OUTPUT]: 对外提供 AppDatabase.migrator 与 Room canonical 迁移标识
 * [POS]: Database/Core 的迁移入口，被 AppDatabase.init 调用执行 Schema 创建
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - Room canonical v41 迁移
// iOS 新库先创建 Android Room v40 canonical schema，再执行 Android 40→41 等价补丁，保证旧 v40 库与新 v41 库共用同一升级路径。

extension AppDatabase {
    nonisolated static let roomSchemaMigrationIdentifier = "room-v40-schema"
    nonisolated static let roomSeedMigrationIdentifier = "room-v40-seed"
    nonisolated static let roomV41MigrationIdentifier = "room-v41-schema"

    nonisolated static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration(roomSchemaMigrationIdentifier) { db in
            try RoomCanonicalSchemaV40.createAllTables(db)
        }

        migrator.registerMigration(roomSeedMigrationIdentifier) { db in
            try seedInitialData(db)
        }

        migrator.registerMigration(roomV41MigrationIdentifier) { db in
            try RoomCanonicalSchemaV41.migrateFromV40(db)
        }

        return migrator
    }

    /// Android Room 备份库没有 GRDB 迁移表；仅补内部迁移标记，避免 iOS 打开恢复库时重复执行建表、seed 或 v41 补丁。
    nonisolated static func markRoomCanonicalMigrationsIfNeeded(_ db: Database) throws {
        let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard userVersion >= RoomCanonicalSchemaV40.databaseVersion else { return }

        if try db.tableExists("grdb_migrations") {
            return
        }

        if userVersion >= RoomCanonicalSchemaV41.databaseVersion {
            try RoomCanonicalSchemaV41.validatePhysicalSchema(db)
        } else {
            try RoomCanonicalSchemaV40.validatePhysicalSchema(db)
        }

        // SQL 目的：为 Android Room canonical 库补建 GRDB 内部迁移表，避免后续迁移器误判为空库。
        // 涉及表：grdb_migrations；副作用：只写 iOS 内部迁移标记，不修改任何业务表。
        try db.execute(sql: """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)
        """)
        try markMigration(roomSchemaMigrationIdentifier, in: db)
        try markMigration(roomSeedMigrationIdentifier, in: db)
        if userVersion >= RoomCanonicalSchemaV41.databaseVersion {
            try markMigration(roomV41MigrationIdentifier, in: db)
        }
    }

    private nonisolated static func markMigration(_ identifier: String, in db: Database) throws {
        // SQL 目的：写入 GRDB 内部迁移标记，避免对已由 Android Room 创建的 schema 重复执行 iOS 迁移。
        // 涉及表：grdb_migrations；关键字段：identifier；副作用：仅补内部标记，不修改业务表。
        try db.execute(
            sql: "INSERT OR IGNORE INTO grdb_migrations (identifier) VALUES (?)",
            arguments: [identifier]
        )
    }
}
