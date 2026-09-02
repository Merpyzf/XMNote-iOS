/**
 * [INPUT]: 依赖 AppDatabase、RoomCanonicalSchemaV44...V48、GRDB 与临时 SQLite 数据库
 * [OUTPUT]: 验证 v48 新库、v44...v47 升级、关系确定性去重、v49 拒绝、排序迁移、来源迁移与 seed
 * [POS]: iOS 数据库迁移集成测试，锁定 Android Room v48 最终物理合同与连续数据迁移
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

struct RoomCanonicalSchemaV48Tests {
    @Test
    func freshDatabaseUsesAndroidRoomV48ContractAndReadestSeed() throws {
        let databaseURL = temporaryDatabaseURL("room_v48_fresh")
        defer { removeDatabaseArtifacts(at: databaseURL) }
        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 48)
            #expect(try RoomCanonicalSchemaV48.hasValidIdentityHash(db))
            try RoomCanonicalSchemaV48.validateExistingDatabase(db)
            #expect(try RoomCanonicalSchemaV48.loadSchema().entities.count == 39)
            #expect(try migrationMarkerCount(AppDatabase.roomV47MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV48MigrationIdentifier, db: db) == 1)
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

            let readest = try #require(try SourceRecord.fetchOne(db, key: 28))
            #expect(readest.name == "Readest")
            #expect(readest.sourceOrder == 27)
            #expect(readest.bookshelfOrder == 0)
            #expect(readest.isHide == 0)
            #expect(readest.createdDate > 0)
            #expect(readest.updatedDate == 0)
            #expect(readest.lastSyncDate == 0)
            #expect(readest.isDeleted == 0)
        }
    }

    @Test
    @MainActor
    func sourceManagementProtectsReadestAsBuiltInSource() async throws {
        let databaseURL = temporaryDatabaseURL("room_v47_readest_protection")
        defer { removeDatabaseArtifacts(at: databaseURL) }
        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }
        let repository = SourceManagementRepository(
            databaseManager: DatabaseManager(database: database)
        )

        var capturedError: SourceManagementRepositoryError?
        do {
            try await repository.deleteSources(sourceIDs: [28])
        } catch let error as SourceManagementRepositoryError {
            capturedError = error
        }
        #expect(capturedError == .defaultSourceReadonly)
    }

    @Test
    func androidRoomV44DatabaseMigratesThroughV45AndV46ToV48() throws {
        let databaseURL = temporaryDatabaseURL("room_v44_to_v48")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV44.createAllTables(db)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 48)
            try RoomCanonicalSchemaV48.validateExistingDatabase(db)
            #expect(try migrationMarkerCount(AppDatabase.roomV45MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV46MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV47MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV48MigrationIdentifier, db: db) == 1)
            #expect(try db.tableExists("note_import_hash"))
            #expect(try SourceRecord.fetchOne(db, key: 28)?.name == "Readest")
        }
    }

    @Test
    func androidRoomV45DatabaseMovesConflictingSourcesAndAllBookReferences() throws {
        let databaseURL = temporaryDatabaseURL("room_v45_to_v46_sources")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV45.createAllTables(db)
            try insertRequiredReferences(db)
            try insertSource(db, id: 1, name: "未知", order: 0, bookshelfOrder: 0, isDeleted: 0)
            try insertSource(db, id: 27, name: "Readingo", order: 26, bookshelfOrder: 26, isDeleted: 0)
            try insertSource(db, id: 28, name: "用户来源 A", order: 27, bookshelfOrder: 27, isDeleted: 0)
            try insertSource(db, id: 29, name: "已删除来源", order: 29, bookshelfOrder: 29, isDeleted: 1)
            try insertSource(db, id: 31, name: "用户来源 B", order: 30, bookshelfOrder: 30, isDeleted: 0)
            try insertBook(db, id: 1, name: "书籍 A", sourceID: 28, isDeleted: 0)
            try insertBook(db, id: 2, name: "软删除书籍", sourceID: 31, isDeleted: 1)
            try insertBook(db, id: 3, name: "引用已删除来源", sourceID: 29, isDeleted: 0)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 48)
            try RoomCanonicalSchemaV48.validateExistingDatabase(db)
            #expect(try migrationMarkerCount(AppDatabase.roomV46MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV47MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV48MigrationIdentifier, db: db) == 1)

            let readest = try #require(try SourceRecord.fetchOne(db, key: 28))
            #expect(readest.name == "Readest")
            #expect(readest.sourceOrder == 31)
            #expect(readest.bookshelfOrder == 31)
            #expect(readest.isDeleted == 0)

            #expect(try SourceRecord.fetchOne(db, key: 29)?.name == "用户来源 A")
            #expect(try SourceRecord.fetchOne(db, key: 30)?.name == "已删除来源")
            #expect(try SourceRecord.fetchOne(db, key: 30)?.isDeleted == 1)
            #expect(try SourceRecord.fetchOne(db, key: 32)?.name == "用户来源 B")

            // SQL 目的：读取三本迁移 fixture 书籍的最终来源，覆盖正常、软删除和引用软删除来源三种数据。
            // 涉及表：book；关键过滤：按固定测试主键定位；返回字段：source_id。
            #expect(try Int64.fetchOne(db, sql: "SELECT source_id FROM book WHERE id = 1") == 29)
            #expect(try Int64.fetchOne(db, sql: "SELECT source_id FROM book WHERE id = 2") == 32)
            #expect(try Int64.fetchOne(db, sql: "SELECT source_id FROM book WHERE id = 3") == 30)

            // SQL 目的：确认 v46 迁移完成后已清理连接级临时备份表。
            // 涉及表：sqlite_temp_master；关键过滤：临时表名精确匹配；返回字段：对象数量。
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_temp_master WHERE name = 'readest_source_book_backup'") == 0)
        }
    }

    @Test
    func androidRoomV46DatabaseCopiesLatestActiveChapterRuleWithoutOverwritingTargetScope() throws {
        let databaseURL = temporaryDatabaseURL("room_v46_to_v47_sort_scope")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV46.createAllTables(db)
            try insertRequiredReferences(db)
            try insertSource(db, id: 1, name: "未知", order: 0, bookshelfOrder: 0, isDeleted: 0)
            for bookID in 1...4 {
                try insertBook(db, id: Int64(bookID), name: "书籍 \(bookID)", sourceID: 1, isDeleted: 0)
            }

            try insertSort(db, id: 101, bookID: 1, type: 1, order: 1, updatedDate: 10, isDeleted: 0)
            try insertSort(db, id: 102, bookID: 1, type: 1, order: 2, updatedDate: 20, isDeleted: 0)
            try insertSort(db, id: 103, bookID: 1, type: 6, order: 1, updatedDate: 30, isDeleted: 1)

            try insertSort(db, id: 201, bookID: 2, type: 1, order: 2, updatedDate: 20, isDeleted: 0)
            try insertSort(db, id: 202, bookID: 2, type: 6, order: 1, updatedDate: 30, isDeleted: 0)

            try insertSort(db, id: 401, bookID: 4, type: 1, order: 2, updatedDate: 40, isDeleted: 1)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 48)
            try RoomCanonicalSchemaV48.validateExistingDatabase(db)
            #expect(try migrationMarkerCount(AppDatabase.roomV47MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV48MigrationIdentifier, db: db) == 1)

            // SQL 目的：读取书籍 1 迁移生成的有效 type=6 排序记录，验证最新 type=1 被复制且删除目标不阻断。
            // 涉及表：sort；关键过滤：book_id=1、type=6、is_deleted=0；返回全部迁移字段。
            let migrated = try #require(try Row.fetchOne(
                db,
                sql: """
                    SELECT id, "order", created_date, updated_date, last_sync_date, is_deleted
                    FROM sort
                    WHERE book_id = 1 AND type = 6 AND is_deleted = 0
                    """
            ))
            #expect((migrated["id"] as Int64?) != 103)
            #expect((migrated["order"] as Int64?) == 2)
            #expect((migrated["created_date"] as Int64?) == (migrated["updated_date"] as Int64?))
            #expect((migrated["created_date"] as Int64? ?? 0) > 0)
            #expect((migrated["last_sync_date"] as Int64?) == 0)
            #expect((migrated["is_deleted"] as Int64?) == 0)

            // SQL 目的：确认书籍 2 的既有有效 type=6 记录保持原主键与规则，未被迁移覆盖或重复插入。
            // 涉及表：sort；关键过滤：book_id=2、type=6、is_deleted=0；返回记录数、主键与 order。
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sort WHERE book_id = 2 AND type = 6 AND is_deleted = 0") == 1)
            #expect(try Int64.fetchOne(db, sql: "SELECT id FROM sort WHERE book_id = 2 AND type = 6 AND is_deleted = 0") == 202)
            #expect(try Int64.fetchOne(db, sql: "SELECT \"order\" FROM sort WHERE book_id = 2 AND type = 6 AND is_deleted = 0") == 1)

            // SQL 目的：确认无 type=1 来源的书籍 3 和仅有已删除来源的书籍 4 不生成 type=6。
            // 涉及表：sort；关键过滤：book_id IN (3,4)、type=6、is_deleted=0；返回记录数。
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sort WHERE book_id IN (3, 4) AND type = 6 AND is_deleted = 0") == 0)
        }
    }

    @Test
    func androidRoomV46DatabaseWithoutGRDBMarkersMigratesToV48WithoutReapplyingSeed() throws {
        let databaseURL = temporaryDatabaseURL("room_v46_restore_to_v48")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV46.createAllTables(db)
            try insertSource(db, id: 28, name: "Readest", order: 27, bookshelfOrder: -1, isDeleted: 0)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 48)
            #expect(try migrationMarkerCount(AppDatabase.roomSeedMigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV45MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV46MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV47MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV48MigrationIdentifier, db: db) == 1)
            #expect(try UserRecord.fetchCount(db) == 0)
            #expect(try SourceRecord.fetchCount(db) == 1)
            #expect(try SourceRecord.fetchOne(db, key: 28)?.bookshelfOrder == -1)
            try RoomCanonicalSchemaV48.validateExistingDatabase(db)
        }
    }

    @Test
    func androidRoomV47DatabaseWithoutGRDBMarkersMigratesOnlyRelationsToV48() throws {
        let databaseURL = temporaryDatabaseURL("room_v47_restore")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV47.createAllTables(db)
            try insertRequiredReferences(db)
            try insertSource(db, id: 1, name: "未知", order: 0, bookshelfOrder: 0, isDeleted: 0)
            try insertBook(db, id: 1, name: "书籍", sourceID: 1, isDeleted: 0)
            try insertSort(db, id: 1, bookID: 1, type: 1, order: 2, updatedDate: 10, isDeleted: 0)
            try insertSort(db, id: 2, bookID: 1, type: 6, order: 1, updatedDate: 20, isDeleted: 1)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 48)
            #expect(try migrationMarkerCount(AppDatabase.roomSeedMigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV47MigrationIdentifier, db: db) == 1)
            #expect(try migrationMarkerCount(AppDatabase.roomV48MigrationIdentifier, db: db) == 1)
            #expect(try UserRecord.fetchCount(db) == 1)
            #expect(try SourceRecord.fetchCount(db) == 1)

            // SQL 目的：确认原生 Android v47 库只补迁移标记，不因已删除 type=6 再次执行 46→47 数据迁移。
            // 涉及表：sort；关键过滤：book_id=1、type=6；分别返回有效数与总数。
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sort WHERE book_id = 1 AND type = 6 AND is_deleted = 0") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sort WHERE book_id = 1 AND type = 6") == 1)
            try RoomCanonicalSchemaV48.validateExistingDatabase(db)
        }
    }

    @Test
    func androidRoomV47RelationDuplicatesMigrateDeterministicallyToV48() throws {
        let databaseURL = temporaryDatabaseURL("room_v47_relation_dedup_to_v48")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV47.createAllTables(db)
            try insertRequiredReferences(db)
            try insertSource(db, id: 1, name: "未知", order: 0, bookshelfOrder: 0, isDeleted: 0)
            try insertBook(db, id: 100, name: "关系书籍 A", sourceID: 1, isDeleted: 0)
            try insertBook(db, id: 101, name: "关系书籍 B", sourceID: 1, isDeleted: 0)

            // SQL 目的：创建关系迁移所需的最小有效书单、标签和分组父记录。
            // 涉及表：collection、tag、`group`；关键字段：固定测试主键；时间字段固定为 0。
            // 副作用：只写测试临时数据库。
            try db.execute(sql: """
                INSERT INTO collection (
                    id, title, desc, "order", is_annual, year,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES
                    (10, '书单 A', '', 0, 0, 0, 0, 0, 0, 0),
                    (11, '书单 B', '', 0, 0, 0, 0, 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO tag (
                    id, user_id, name, color, tag_order, type,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES
                    (200, 1, '标签 A', 0, 0, 0, 0, 0, 0, 0),
                    (201, 1, '标签 B', 0, 0, 0, 0, 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO `group` (
                    id, user_id, name, group_order, pinned, pin_order,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES
                    (300, 1, '分组 A', 0, 0, 0, 0, 0, 0, 0),
                    (301, 1, '分组 B', 0, 0, 0, 0, 0, 0, 0),
                    (302, 1, '分组 C', 0, 0, 0, 0, 0, 0, 0)
                """)

            // SQL 目的：构造与 Android Migration47To48Test 相同的有效重复与历史删除关系。
            // 涉及表：collection_book、tag_book、group_book；关键字段：固定业务键与主键。
            // 时间字段：显式设置 created_date/updated_date，用于验证规范行选择规则。
            try db.execute(sql: """
                INSERT INTO collection_book (
                    id, collection_id, book_id, recommend, "order",
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES
                    (1, 10, 100, '', 1, 10, 10, 0, 0),
                    (2, 10, 100, '', 2, 20, 30, 0, 0),
                    (3, 11, 101, '', 3, 30, 40, 0, 1)
                """)
            try db.execute(sql: """
                INSERT INTO tag_book (
                    id, book_id, tag_id, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES
                    (11, 100, 200, 10, 0, 0, 0),
                    (12, 100, 200, 20, 0, 0, 0),
                    (13, 101, 201, 30, 0, 0, 1)
                """)
            try db.execute(sql: """
                INSERT INTO group_book (
                    id, group_id, book_id, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES
                    (21, 300, 100, 10, 0, 0, 0),
                    (22, 301, 100, 20, 0, 0, 0),
                    (23, 302, 101, 30, 0, 0, 1)
                """)
        }

        let database = try AppDatabase(path: databaseURL.path)
        defer { try? database.close() }

        try database.dbPool.read { db in
            #expect(try databaseVersion(db) == 48)
            #expect(try Int64.fetchAll(db, sql: "SELECT id FROM collection_book ORDER BY id") == [2])
            #expect(try Int64.fetchAll(db, sql: "SELECT id FROM tag_book ORDER BY id") == [11])
            #expect(try Int64.fetchAll(db, sql: "SELECT id FROM group_book ORDER BY id") == [21])
            #expect(try Int64.fetchOne(db, sql: "SELECT \"order\" FROM collection_book WHERE id = 2") == 2)
            #expect(try isUniqueIndex("collection_book", named: "index_collection_book_collection_id_book_id", db: db))
            #expect(try isUniqueIndex("tag_book", named: "index_tag_book_book_id_tag_id", db: db))
            #expect(try isUniqueIndex("group_book", named: "index_group_book_book_id", db: db))
            try RoomCanonicalSchemaV48.validateExistingDatabase(db)
        }
    }

    @Test
    func databaseNewerThanV48IsRejected() throws {
        let databaseURL = temporaryDatabaseURL("room_v49_rejected")
        defer { removeDatabaseArtifacts(at: databaseURL) }

        try DatabaseQueue(path: databaseURL.path).write { db in
            try RoomCanonicalSchemaV48.createAllTables(db)
            // SQL 目的：构造未来版本 Room fixture，验证恢复兼容上限拒绝 user_version=49。
            // 涉及表：无；副作用：只更新测试临时数据库版本号。
            try db.execute(sql: "PRAGMA user_version = 49")
        }

        #expect(throws: RoomCanonicalSchemaError.self) {
            _ = try AppDatabase(path: databaseURL.path)
        }
    }

    @Test
    func noteImportHashIgnoresDuplicateCompositeKeyAndSupportsPhysicalDelete() throws {
        let databaseURL = temporaryDatabaseURL("room_v47_note_import_hash")
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
        let databaseURL = temporaryDatabaseURL("room_v47_notion_cascade")
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

private extension RoomCanonicalSchemaV48Tests {
    /// 判断目标表的指定索引是否存在且具备 UNIQUE 属性。
    func isUniqueIndex(_ table: String, named indexName: String, db: Database) throws -> Bool {
        guard ["collection_book", "tag_book", "group_book"].contains(table) else { return false }
        // SQL 目的：读取测试目标关系表的索引列表，验证 v48 业务唯一约束已落地。
        // 涉及表：SQLite schema 元数据；关键过滤：由调用方在固定白名单中选择关系表。
        // 返回字段：name 与 unique 标志；时间字段不参与。
        let rows = try Row.fetchAll(db, sql: "PRAGMA index_list(`\(table)`)")
        return rows.contains { row in
            let name: String = row["name"]
            let isUnique: Int = row["unique"]
            return name == indexName && isUnique == 1
        }
    }

    /// 插入 book 外键所需的最小用户与阅读状态根记录。
    func insertRequiredReferences(_ db: Database) throws {
        // SQL 目的：写入迁移 fixture 所需的默认用户根记录。
        // 涉及表：user；关键字段：id/user_id 固定为 1；时间字段固定 0。
        // 副作用：只写测试临时数据库。
        try db.execute(sql: """
            INSERT INTO user (
                id, user_id, nickName, gender, phone,
                created_date, updated_date, last_sync_date, is_deleted
            ) VALUES (1, 1, '', 0, '', 0, 0, 0, 0)
            """)

        // SQL 目的：写入迁移 fixture 所需的默认阅读状态根记录。
        // 涉及表：read_status；关键字段：id 固定为 1；时间字段固定 0。
        // 副作用：只写测试临时数据库。
        try db.execute(sql: """
            INSERT INTO read_status (
                id, name, read_status_order,
                created_date, updated_date, last_sync_date, is_deleted
            ) VALUES (1, '在读', 0, 0, 0, 0, 0)
            """)
    }

    /// 插入具有可控主键、排序和删除状态的来源迁移 fixture。
    func insertSource(
        _ db: Database,
        id: Int64,
        name: String,
        order: Int64,
        bookshelfOrder: Int64,
        isDeleted: Int64
    ) throws {
        // SQL 目的：构造连续、稀疏或软删除来源，验证 Android v46 主键移动与排序语义。
        // 涉及表：source；字段值由测试参数显式提供。
        // 时间字段：固定为 0；副作用：只写测试临时数据库。
        try db.execute(
            sql: """
                INSERT INTO source (
                    id, name, source_order, bookshelf_order, is_hide,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, 0, 0, 0, 0, ?)
                """,
            arguments: [id, name, order, bookshelfOrder, isDeleted]
        )
    }

    /// 插入最小字段完整的书籍迁移 fixture，并指定来源和软删除状态。
    func insertBook(
        _ db: Database,
        id: Int64,
        name: String,
        sourceID: Int64,
        isDeleted: Int64
    ) throws {
        // SQL 目的：构造指向待移动来源的书籍，验证 source 外键在 v46 迁移后保持业务映射。
        // 涉及表：book，并引用 user.id=1、read_status.id=1 与调用方指定 source.id。
        // 关键过滤：无；时间字段固定为 0；副作用：只写测试临时数据库。
        try db.execute(
            sql: """
                INSERT INTO book (
                    id, user_id, douban_id, weread_book_id, name, raw_name, cover, author,
                    author_intro, translator, isbn, pub_date, press, summary, read_position,
                    total_position, total_pagination, type, current_position_unit, position_unit,
                    source_id, purchase_date, price, book_order, pinned, pin_order,
                    read_status_id, read_status_changed_date, score, catalog,
                    book_mark_modified_time, word_count, created_date, updated_date,
                    last_sync_date, is_deleted
                ) VALUES (
                    ?, 1, 0, '', ?, ?, '', '',
                    '', '', '', '', '', '', 0,
                    0, 0, 0, 0, 0,
                    ?, 0, 0, 0, 0, 0,
                    1, 0, 0, '',
                    0, 0, 0, 0,
                    0, ?
                )
                """,
            arguments: [id, name, name, sourceID, isDeleted]
        )
    }

    /// 插入具有可控作用域、规则、时间和删除状态的排序迁移 fixture。
    func insertSort(
        _ db: Database,
        id: Int64,
        bookID: Int64,
        type: Int64,
        order: Int64,
        updatedDate: Int64,
        isDeleted: Int64
    ) throws {
        // SQL 目的：构造 46→47 排序作用域迁移所需的来源、既有目标及删除态记录。
        // 涉及表：sort，并引用调用方已创建的 book.id。
        // 关键字段：id/book_id/type/order/updated_date/is_deleted 由测试参数控制；其余时间字段固定 0。
        // 副作用：只写测试临时数据库。
        try db.execute(
            sql: """
                INSERT INTO sort (
                    id, book_id, type, "order",
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, 0, ?, 0, ?)
                """,
            arguments: [id, bookID, type, order, updatedDate, isDeleted]
        )
    }

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
