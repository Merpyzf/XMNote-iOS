/**
 * [INPUT]: 依赖 AppDatabase、RoomCanonicalSchemaV44/V45、GRDB 与临时 SQLite 数据库
 * [OUTPUT]: 验证 v45 新库、v44→v45、Android v45 恢复、v46 拒绝、seed、导入 Hash 与 Notion 外键级联
 * [POS]: iOS 数据库迁移集成测试，锁定 Android Room v45 最终物理合同
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

struct RoomCanonicalSchemaV45Tests {
    @Test
    func freshDatabaseUsesAndroidRoomV45ContractAndSafeSeed() throws {
        let databaseURL = temporaryDatabaseURL("room_v45_fresh")
        defer { removeDatabaseArtifacts(at: databaseURL) }
        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 45)
            #expect(try RoomCanonicalSchemaV45.hasValidIdentityHash(db))
            try RoomCanonicalSchemaV45.validateExistingDatabase(db)
            #expect(try RoomCanonicalSchemaV45.loadSchema().entities.count == 39)
            #expect(try db.tableExists("notion_page_sync"))
            #expect(try db.tableExists("notion_block_sync"))
            #expect(try db.tableExists("notion_sync_operation"))
            #expect(try db.tableExists("note_import_hash"))

            #expect(try WhiteNoiseRecord.fetchCount(db) == 5)
            #expect(try ImageRecord.fetchCount(db) == 31)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image WHERE pro = 0") == 4)

            let defaultBook = try Row.fetchOne(
                db,
                sql: """
                    SELECT user_id, source_id, read_status_id, pinned
                    FROM book
                    WHERE id = 0
                    """
            )
            #expect((defaultBook?["user_id"] as Int64?) == 1)
            #expect((defaultBook?["source_id"] as Int64?) == 0)
            #expect((defaultBook?["read_status_id"] as Int64?) == 1)
            #expect((defaultBook?["pinned"] as Int64?) == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user WHERE id = 1") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source WHERE id = 0") == 1)
        }
    }

    @Test
    func androidRoomV44DatabaseMigratesToV45() throws {
        let databaseURL = temporaryDatabaseURL("room_v44_to_v45")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV44.createAllTables(db)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 45)
            try RoomCanonicalSchemaV45.validateExistingDatabase(db)
            #expect(try migrationMarkerCount(AppDatabase.roomV45MigrationIdentifier, db: db) == 1)
            #expect(try db.tableExists("note_import_hash"))
        }
    }

    @Test
    func androidRoomV45DatabaseWithoutGRDBMarkersOpensWithoutReapplyingSeed() throws {
        let databaseURL = temporaryDatabaseURL("room_v45_restore")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV45.createAllTables(db)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 45)
            #expect(try migrationMarkerCount(AppDatabase.roomSeedMigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV45MigrationIdentifier, db: db) == 1)
            #expect(try UserRecord.fetchCount(db) == 0)
            try RoomCanonicalSchemaV45.validateExistingDatabase(db)
        }
    }

    @Test
    func databaseNewerThanV45IsRejected() throws {
        let databaseURL = temporaryDatabaseURL("room_v46_rejected")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV45.createAllTables(db)
            // SQL 目的：构造未来版本 Room fixture，验证恢复兼容上限拒绝 user_version=46。
            // 涉及表：无；副作用：只更新测试临时数据库版本号。
            try db.execute(sql: "PRAGMA user_version = 46")
        }

        #expect(throws: RoomCanonicalSchemaError.self) {
            _ = try AppDatabase(path: databaseURL.path)
        }
    }

    @Test
    func noteImportHashIgnoresDuplicateCompositeKeyAndSupportsPhysicalDelete() throws {
        let databaseURL = temporaryDatabaseURL("room_v45_note_import_hash")
        defer { removeDatabaseArtifacts(at: databaseURL) }
        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.write { db in
            try NoteImportHashRecord(bookId: 7, contentHash: "same", noteId: 11).insert(db)
            try NoteImportHashRecord(bookId: 7, contentHash: "same", noteId: 12).insert(db)

            #expect(try NoteImportHashRecord.fetchCount(db) == 1)
            #expect(try NoteImportHashRecord.fetchOne(db)?.noteId == 11)

            // SQL 目的：验证 Android NoteImportHashDao 的物理删除语义，不引入 is_deleted。
            // 涉及表：note_import_hash；关键过滤：note_id 精确匹配。
            try db.execute(sql: "DELETE FROM note_import_hash WHERE note_id = ?", arguments: [11])
            #expect(try NoteImportHashRecord.fetchCount(db) == 0)
        }
    }

    @Test
    func deletingPageSyncCascadesBlockAndOperationRows() throws {
        let databaseURL = temporaryDatabaseURL("room_v45_notion_cascade")
        defer { removeDatabaseArtifacts(at: databaseURL) }
        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.write { db in
            let page = NotionPageSyncRecord(
                id: 1,
                connectionKey: "connection",
                dataSourceId: "source",
                bookId: 7,
                syncId: "sync",
                pageId: "page",
                pageUrl: "https://example.invalid/page",
                status: "active",
                conflictCount: 0,
                firstSyncDate: 1_000,
                lastSyncDate: 2_000,
                metadataFingerprint: "metadata",
                contentFingerprint: "content",
                remoteLastEditedTime: "remote-time",
                lastExportedTitle: "title"
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

private extension RoomCanonicalSchemaV45Tests {
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
