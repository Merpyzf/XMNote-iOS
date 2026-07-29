/**
 * [INPUT]: 依赖 AppDatabase、RoomCanonicalSchemaV44...V46、GRDB 与临时 SQLite 数据库
 * [OUTPUT]: 验证 v44→v45→v46、v45→v46、v46 直接恢复、v47 拒绝和 Notion 外键级联
 * [POS]: iOS 数据库迁移集成测试，锁定 Android Room v46 物理合同
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

struct RoomCanonicalSchemaV46Tests {
    @Test
    func freshDatabaseUsesAndroidRoomV46Contract() throws {
        let database = try AppDatabase.empty()
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 46)
            #expect(try RoomCanonicalSchemaV46.hasValidIdentityHash(db))
            try RoomCanonicalSchemaV46.validateExistingDatabase(db)
            #expect(try db.tableExists("notion_page_sync"))
            #expect(try db.tableExists("notion_block_sync"))
            #expect(try db.tableExists("notion_sync_operation"))
        }
    }

    @Test
    func androidRoomV44DatabaseMigratesThroughV45ToV46() throws {
        let databaseURL = temporaryDatabaseURL("room_v44_to_v46")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV44.createAllTables(db)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 46)
            try RoomCanonicalSchemaV46.validateExistingDatabase(db)
            #expect(try migrationMarkerCount(AppDatabase.roomV45MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV46MigrationIdentifier, db: db) == 1)
        }
    }

    @Test
    func v45MigrationAddsThreeNonNullEmptyBaselineFields() throws {
        let databaseURL = temporaryDatabaseURL("room_v45_to_v46")
        defer { removeDatabaseArtifacts(at: databaseURL) }
        let queue = try DatabaseQueue(path: databaseURL.path)

        try queue.write { db in
            try RoomCanonicalSchemaV45.createAllTables(db)
            // SQL 目的：插入 v45 页面映射 fixture，验证 v46 ALTER TABLE 对既有行写入 Android 默认值。
            // 涉及表：notion_page_sync；不含 v46 新字段。
            // 时间字段：first_sync_date/last_sync_date 使用固定 Unix 毫秒，避免动态测试值。
            // 副作用：只写测试临时数据库。
            try db.execute(sql: """
                INSERT INTO notion_page_sync (
                    id, connection_key, data_source_id, scope, book_id,
                    sync_id, page_id, page_url, status, conflict_count,
                    first_sync_date, last_sync_date
                ) VALUES (1, 'connection', 'source', 'book', 7,
                          'sync', 'page', 'https://example.invalid/page',
                          'active', 0, 1000, 2000)
                """)
            try RoomCanonicalSchemaV46.migrateFromV45(db)
        }

        try queue.read { db in
            #expect(try databaseVersion(db) == 46)
            try RoomCanonicalSchemaV46.validateExistingDatabase(db)
            let record = try NotionPageSyncRecord.fetchOne(db, key: 1)
            #expect(record?.sourceFingerprint == "")
            #expect(record?.remoteLastEditedTime == "")
            #expect(record?.lastExportedTitle == "")
        }
    }

    @Test
    func androidRoomV46DatabaseWithoutGRDBMarkersOpensWithoutReapplyingMigrations() throws {
        let databaseURL = temporaryDatabaseURL("room_v46_restore")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV46.createAllTables(db)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 46)
            #expect(try migrationMarkerCount(AppDatabase.roomV45MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV46MigrationIdentifier, db: db) == 1)
            try RoomCanonicalSchemaV46.validateExistingDatabase(db)
        }
    }

    @Test
    func databaseNewerThanV46IsRejected() throws {
        let databaseURL = temporaryDatabaseURL("room_v47_rejected")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV46.createAllTables(db)
            // SQL 目的：构造未来版本 Room fixture，验证恢复兼容上限拒绝 user_version=47。
            // 涉及表：无；副作用：只更新测试临时数据库版本号。
            try db.execute(sql: "PRAGMA user_version = 47")
        }

        #expect(throws: RoomCanonicalSchemaError.self) {
            _ = try AppDatabase(path: databaseURL.path)
        }
    }

    @Test
    func deletingPageSyncCascadesBlockAndOperationRows() throws {
        let database = try AppDatabase.empty()
        defer { try? database.close() }

        try database.dbPool.write { db in
            let page = NotionPageSyncRecord(
                id: 1,
                connectionKey: "connection",
                dataSourceId: "source",
                scope: "book",
                bookId: 7,
                syncId: "sync",
                pageId: "page",
                pageUrl: "https://example.invalid/page",
                status: "active",
                conflictCount: 0,
                firstSyncDate: 1_000,
                lastSyncDate: 2_000
            )
            try page.insert(db)
            let pageID: Int64 = 1

            let block = NotionBlockSyncRecord(
                id: 1,
                pageSyncId: pageID,
                unitKey: "note:1",
                contentType: "note",
                sourceId: 1,
                sourceUpdatedDate: 1_000,
                sourceFingerprint: "source",
                remoteFingerprint: "remote",
                blockIdsJson: "[]",
                anchorKey: "anchor",
                deletable: true,
                state: "active",
                lastSyncDate: 2_000
            )
            try block.insert(db)
            try NotionSyncOperationRecord(
                operationId: "operation",
                pageSyncId: pageID,
                unitKey: "note:1",
                operationType: "replace",
                state: "pending",
                oldBlockIdsJson: "[]",
                newBlockIdsJson: "[]",
                blocksJson: "[]",
                sourceFingerprint: "source",
                sourceUpdatedDate: 1_000,
                createdDate: 2_000,
                updatedDate: 2_000
            ).insert(db)

            try page.delete(db)

            #expect(try NotionBlockSyncRecord.fetchCount(db) == 0)
            #expect(try NotionSyncOperationRecord.fetchCount(db) == 0)
        }
    }
}

private extension RoomCanonicalSchemaV46Tests {
    func temporaryDatabaseURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)_\(UUID().uuidString).db")
    }

    func removeDatabaseArtifacts(at url: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(atPath: "\(url.path)-wal")
        try? fileManager.removeItem(atPath: "\(url.path)-shm")
    }

    func databaseVersion(_ db: Database) throws -> Int {
        // SQL 目的：读取临时数据库 Room user_version，验证迁移最终版本。
        // 涉及表：无；返回字段：PRAGMA user_version 单值。
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }

    func migrationMarkerCount(_ identifier: String, db: Database) throws -> Int {
        // SQL 目的：确认 Android 恢复库补齐了指定 GRDB 内部迁移标记。
        // 涉及表：grdb_migrations；关键过滤：identifier 精确匹配。
        // 副作用：无，只返回测试断言计数。
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
            arguments: [identifier]
        ) ?? 0
    }
}
