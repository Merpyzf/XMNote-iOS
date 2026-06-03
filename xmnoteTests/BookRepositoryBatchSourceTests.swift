import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct BookRepositoryBatchSourceTests {
    @Test
    func batchSetBooksSourceMatchesAndroidTimestampAndFilterSemantics() async throws {
        let harness = try Self.makeHarness()
        let sourceID: Int64 = 99_101
        let normalBookID: Int64 = 99_201
        let deletedBookID: Int64 = 99_202

        try await harness.write { db in
            try Self.insertSource(db, id: sourceID)
            try Self.insertBook(
                db,
                id: normalBookID,
                sourceID: 0,
                updatedDate: 1_001,
                lastSyncDate: 2_001,
                isDeleted: 0
            )
            try Self.insertBook(
                db,
                id: deletedBookID,
                sourceID: 0,
                updatedDate: 1_002,
                lastSyncDate: 2_002,
                isDeleted: 1
            )
            try Self.resetDefaultBookSource(
                db,
                updatedDate: 1_000,
                lastSyncDate: 2_000
            )
        }

        try await harness.repository.batchSetBooksSource(
            bookIDs: [normalBookID, deletedBookID, 0, normalBookID],
            sourceID: sourceID
        )

        let normalBook = try #require(try await harness.bookState(id: normalBookID))
        #expect(normalBook.sourceID == sourceID)
        #expect(normalBook.updatedDate == 1_001)
        #expect(normalBook.lastSyncDate == 2_001)

        let deletedBook = try #require(try await harness.bookState(id: deletedBookID))
        #expect(deletedBook.sourceID == sourceID)
        #expect(deletedBook.updatedDate == 1_002)
        #expect(deletedBook.lastSyncDate == 2_002)

        let defaultBook = try #require(try await harness.bookState(id: 0))
        #expect(defaultBook.sourceID == sourceID)
        #expect(defaultBook.updatedDate == 1_000)
        #expect(defaultBook.lastSyncDate == 2_000)
    }
}

private extension BookRepositoryBatchSourceTests {
    struct Harness {
        let dbPool: DatabasePool
        let repository: BookRepository

        func write(_ updates: (Database) throws -> Void) async throws {
            try await dbPool.write { db in
                try updates(db)
            }
        }

        func bookState(id: Int64) async throws -> BookSourceState? {
            try await dbPool.read { db in
                // SQL 目的：读取单本书籍的来源与同步时间字段，用于断言批量来源写入副作用。
                // 涉及表：book。
                // 关键过滤：仅按 id 定位测试书籍，覆盖正常书、软删除书与默认占位书。
                // 时间字段：直接读取毫秒时间戳原值，确认写入来源时不被改动。
                // 返回字段：source_id、updated_date、last_sync_date。
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT source_id, updated_date, last_sync_date
                        FROM book
                        WHERE id = ?
                        """,
                    arguments: [id]
                ).map {
                    BookSourceState(
                        sourceID: $0["source_id"],
                        updatedDate: $0["updated_date"],
                        lastSyncDate: $0["last_sync_date"]
                    )
                }
            }
        }
    }

    struct BookSourceState {
        let sourceID: Int64
        let updatedDate: Int64
        let lastSyncDate: Int64
    }

    static func makeHarness() throws -> Harness {
        let database = try AppDatabase.empty()
        let manager = DatabaseManager(database: database)
        return Harness(
            dbPool: database.dbPool,
            repository: BookRepository(databaseManager: manager)
        )
    }

    static func insertSource(_ db: Database, id: Int64) throws {
        // SQL 目的：插入有效来源，满足 Repository 的来源有效性校验。
        // 涉及表：source。
        // 关键过滤：无查询过滤；显式写入 is_deleted = 0 作为可选来源。
        // 时间字段：测试 fixture 固定为 0，不参与本用例断言。
        // 副作用用途：为 book.source_id 外键与 isActiveSource 校验提供目标来源。
        try db.execute(
            sql: """
                INSERT INTO source (
                    id, name, source_order, bookshelf_order, is_hide,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, 0, 0, 0, 0, 0, 0, 0)
                """,
            arguments: [id, "测试来源"]
        )
    }

    static func insertBook(
        _ db: Database,
        id: Int64,
        sourceID: Int64,
        updatedDate: Int64,
        lastSyncDate: Int64,
        isDeleted: Int64
    ) throws {
        // SQL 目的：插入可控状态的测试书籍，覆盖正常书与软删除书。
        // 涉及表：book。
        // 关键过滤：无查询过滤；通过 is_deleted 入参构造不同写入目标状态。
        // 时间字段：updated_date / last_sync_date 使用入参固定毫秒值，用于后续保持不变断言。
        // 副作用用途：提供批量来源写入的真实 book 行。
        try db.execute(
            sql: """
                INSERT INTO book (
                    id, user_id, douban_id, name, raw_name, cover, author, author_intro, translator,
                    isbn, pub_date, press, summary, read_position, total_position, total_pagination,
                    type, current_position_unit, position_unit, source_id, purchase_date, price,
                    book_order, pinned, pin_order, read_status_id, read_status_changed_date,
                    score, catalog, book_mark_modified_time, word_count, created_date, updated_date,
                    last_sync_date, is_deleted
                ) VALUES (
                    ?, 1, 0, ?, ?, '', '', '', '',
                    '', '', '', '', 0, 100, 100,
                    1, 1, 2, ?, 0, 0,
                    0, 0, 0, 1, 0,
                    0, '', 0, NULL, 0, ?,
                    ?, ?
                )
                """,
            arguments: [
                id,
                "批量来源测试书 \(id)",
                "批量来源测试书 \(id)",
                sourceID,
                updatedDate,
                lastSyncDate,
                isDeleted
            ]
        )
    }

    static func resetDefaultBookSource(
        _ db: Database,
        updatedDate: Int64,
        lastSyncDate: Int64
    ) throws {
        // SQL 目的：重置 seed 默认占位书 id = 0 的来源与时间字段，覆盖 Android 等价写入边界。
        // 涉及表：book。
        // 关键过滤：id = 0，仅定位默认占位书。
        // 时间字段：updated_date / last_sync_date 写入固定毫秒值，用于确认批量来源不改时间。
        // 副作用用途：让默认占位书进入本用例断言集合。
        try db.execute(
            sql: """
                UPDATE book
                SET source_id = 0,
                    updated_date = ?,
                    last_sync_date = ?
                WHERE id = 0
                """,
            arguments: [updatedDate, lastSyncDate]
        )
    }
}
