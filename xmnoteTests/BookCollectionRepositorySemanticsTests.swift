import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct BookCollectionRepositorySemanticsTests {
    @Test
    func manualCollectionSummaryCountsPlaceholderAndDeletedBooksLikeAndroidManualJoin() async throws {
        let harness = try Self.makeHarness()
        let collectionID: Int64 = 91_001
        let deletedBookID: Int64 = 91_101

        try await harness.write { db in
            try Self.insertCollection(db, id: collectionID, title: "手动书单", order: 0, isAnnual: 0, year: 0)
            try Self.insertBook(db, id: deletedBookID, isDeleted: 1)
            try Self.insertCollectionBook(db, collectionID: collectionID, bookID: deletedBookID, order: 0)
            try Self.insertCollectionBook(db, collectionID: collectionID, bookID: 0, order: 1)
        }

        let summaries = try await harness.repository.fetchManualBookCollections()
        let summary = try #require(summaries.first { $0.id == collectionID })

        #expect(summary.bookCount == 2)
    }

    @Test
    func addBooksToCollectionAllowsExistingDeletedBookRowsAndKeepsActiveDuplicates() async throws {
        let harness = try Self.makeHarness()
        let collectionID: Int64 = 92_001
        let activeBookID: Int64 = 92_101
        let deletedBookID: Int64 = 92_102

        try await harness.write { db in
            try Self.insertCollection(db, id: collectionID, title: "可加入书单", order: 0, isAnnual: 0, year: 0)
            try Self.insertBook(db, id: activeBookID, isDeleted: 0)
            try Self.insertBook(db, id: deletedBookID, isDeleted: 1)
            try Self.insertCollectionBook(
                db,
                collectionID: collectionID,
                bookID: activeBookID,
                recommend: "保留推荐语",
                order: 12,
                createdDate: 101,
                updatedDate: 202
            )
        }

        try await harness.repository.addBooks([activeBookID, deletedBookID, activeBookID], toCollection: collectionID)

        let activeRelation = try #require(try await harness.collectionBook(collectionID: collectionID, bookID: activeBookID))
        #expect(activeRelation.recommend == "保留推荐语")
        #expect(activeRelation.order == 12)
        #expect(activeRelation.createdDate == 101)
        #expect(activeRelation.updatedDate == 202)

        let deletedRelation = try #require(try await harness.collectionBook(collectionID: collectionID, bookID: deletedBookID))
        #expect(deletedRelation.recommend == "")
        #expect(deletedRelation.order == Int64(Int32.max))
        #expect(deletedRelation.updatedDate == 0)
        #expect(deletedRelation.isDeleted == 0)
    }

    @Test
    func annualSyncDeletesOutdatedRelationWithoutTimestampAndCreatesMissingYearRelation() async throws {
        let harness = try Self.makeHarness()
        let bookID: Int64 = 93_101
        let outdatedCollectionID: Int64 = 93_201
        let targetCollectionID: Int64 = 93_202
        let changedDate = try Self.millis(year: 2024, month: 5, day: 6)

        try await harness.write { db in
            try Self.insertBook(db, id: bookID, readStatusID: BookEntryReadingStatus.finished.rawValue, readStatusChangedDate: changedDate, isDeleted: 0)
            try Self.insertCollection(db, id: outdatedCollectionID, title: "2023 年阅读书单", order: 2023, isAnnual: 1, year: 2023)
            try Self.insertCollection(db, id: targetCollectionID, title: "2024 年阅读书单", order: 2024, isAnnual: 1, year: 2024)
            try Self.insertCollectionBook(
                db,
                collectionID: outdatedCollectionID,
                bookID: bookID,
                order: 0,
                createdDate: 301,
                updatedDate: 777
            )
            try Self.insertReadStatusRecord(db, bookID: bookID, changedDate: changedDate)
            try AnnualCollectionSync.syncAfterReadHistoryChanged(db, bookID: bookID)
        }

        let outdatedRelation = try #require(try await harness.collectionBook(collectionID: outdatedCollectionID, bookID: bookID, includeDeleted: true))
        #expect(outdatedRelation.isDeleted == 1)
        #expect(outdatedRelation.updatedDate == 777)

        let targetRelation = try #require(try await harness.collectionBook(collectionID: targetCollectionID, bookID: bookID))
        #expect(targetRelation.recommend == "")
        #expect(targetRelation.order == 0)
        #expect(targetRelation.updatedDate == 0)
        #expect(targetRelation.isDeleted == 0)
    }

    @Test
    func collectionAndRelationOrderingAndRecommendRefreshAndroidAlignedTimestamps() async throws {
        let harness = try Self.makeHarness()
        let firstCollectionID: Int64 = 94_001
        let secondCollectionID: Int64 = 94_002
        let thirdCollectionID: Int64 = 94_003
        let firstBookID: Int64 = 94_101
        let secondBookID: Int64 = 94_102
        let thirdBookID: Int64 = 94_103

        try await harness.write { db in
            try Self.insertCollection(db, id: firstCollectionID, title: "第一书单", order: 10, isAnnual: 0, year: 0)
            try Self.insertCollection(db, id: secondCollectionID, title: "第二书单", order: 20, isAnnual: 0, year: 0)
            try Self.insertCollection(db, id: thirdCollectionID, title: "第三书单", order: 30, isAnnual: 0, year: 0)
            try Self.insertBook(db, id: firstBookID, isDeleted: 0)
            try Self.insertBook(db, id: secondBookID, isDeleted: 0)
            try Self.insertBook(db, id: thirdBookID, isDeleted: 0)
            try Self.insertCollectionBook(db, collectionID: firstCollectionID, bookID: firstBookID, order: 10)
            try Self.insertCollectionBook(db, collectionID: firstCollectionID, bookID: secondBookID, order: 20)
            try Self.insertCollectionBook(db, collectionID: firstCollectionID, bookID: thirdBookID, order: 30)
        }

        try await harness.repository.updateManualBookCollectionOrder([thirdCollectionID, firstCollectionID])

        let collectionStates = try await harness.collectionStates([firstCollectionID, secondCollectionID, thirdCollectionID])
        #expect(collectionStates[thirdCollectionID]?.order == 0)
        #expect(collectionStates[firstCollectionID]?.order == 1)
        #expect(collectionStates[secondCollectionID]?.order == 2)
        #expect(collectionStates.values.allSatisfy { $0.updatedDate > 0 })

        let relationStates = try await harness.collectionBookStates(collectionID: firstCollectionID)
        let firstRelation = try #require(relationStates.first { $0.bookID == firstBookID })
        let secondRelation = try #require(relationStates.first { $0.bookID == secondBookID })
        let thirdRelation = try #require(relationStates.first { $0.bookID == thirdBookID })

        try await harness.repository.updateBooksInCollectionOrder(
            collectionID: firstCollectionID,
            relationIDs: [thirdRelation.id, firstRelation.id]
        )

        let reorderedRelations = try await harness.collectionBookStates(collectionID: firstCollectionID)
        let reorderedFirst = try #require(reorderedRelations.first { $0.bookID == firstBookID })
        let reorderedSecond = try #require(reorderedRelations.first { $0.bookID == secondBookID })
        let reorderedThird = try #require(reorderedRelations.first { $0.bookID == thirdBookID })
        #expect(reorderedThird.order == 0)
        #expect(reorderedFirst.order == 1)
        #expect(reorderedSecond.order == 2)
        #expect(reorderedRelations.allSatisfy { $0.updatedDate > 0 })

        try await harness.repository.updateCollectionBookRecommend(
            collectionBookID: reorderedSecond.id,
            recommend: "  推荐排序后保留  "
        )

        let recommendedRelation = try #require(try await harness.collectionBookByID(reorderedSecond.id))
        #expect(recommendedRelation.recommend == "推荐排序后保留")
        #expect(recommendedRelation.updatedDate > 0)
    }
}

private extension BookCollectionRepositorySemanticsTests {
    struct Harness {
        let dbPool: DatabasePool
        let repository: BookRepository

        func write(_ updates: (Database) throws -> Void) async throws {
            try await dbPool.write { db in
                try updates(db)
            }
        }

        func collectionBook(
            collectionID: Int64,
            bookID: Int64,
            includeDeleted: Bool = false
        ) async throws -> CollectionBookState? {
            try await dbPool.read { db in
                let deletionPredicate = includeDeleted ? "" : "AND is_deleted = 0"
                // SQL 目的：读取指定书籍与书单关系的推荐语、排序与时间戳，用于验证 Android relation 写入副作用。
                // 涉及表：collection_book。
                // 关键过滤：collection_id/book_id 精确匹配；默认仅取有效关系，includeDeleted 用于验证软删除后的时间戳。
                // 时间字段：读取 created_date/updated_date 原值，确认去重与软删除路径不会误改时间。
                // 返回字段：recommend、order、created_date、updated_date、is_deleted。
                return try Row.fetchOne(
                    db,
                    sql: """
                        SELECT recommend, `order`, created_date, updated_date, is_deleted
                        FROM collection_book
                        WHERE collection_id = ?
                          AND book_id = ?
                          \(deletionPredicate)
                        ORDER BY id ASC
                        LIMIT 1
                        """,
                    arguments: [collectionID, bookID]
                ).map {
                    CollectionBookState(
                        recommend: $0["recommend"],
                        order: $0["order"],
                        createdDate: $0["created_date"],
                        updatedDate: $0["updated_date"],
                        isDeleted: $0["is_deleted"]
                    )
                }
            }
        }

        func collectionStates(_ collectionIDs: [Int64]) async throws -> [Int64: CollectionState] {
            try await dbPool.read { db in
                guard !collectionIDs.isEmpty else { return [:] }
                // SQL 目的：读取指定手动书单排序、更新时间与软删除状态，用于验证 Android 排序写入副作用。
                // 涉及表：collection。
                // 关键过滤：id IN 入参列表；不额外排除软删除，方便测试直接观察写入结果。
                // 时间字段：updated_date 原值用于验证排序路径会刷新时间戳。
                // 返回字段：id、order、updated_date、is_deleted。
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, `order`, updated_date, is_deleted
                        FROM collection
                        WHERE id IN \(BookCollectionRepositorySemanticsTests.sqlIDList(collectionIDs))
                        """,
                    arguments: StatementArguments(collectionIDs)
                )
                return Dictionary(
                    uniqueKeysWithValues: rows.map { row in
                        let id: Int64 = row["id"]
                        return (
                            id,
                            CollectionState(
                                order: row["order"],
                                updatedDate: row["updated_date"],
                                isDeleted: row["is_deleted"]
                            )
                        )
                    }
                )
            }
        }

        func collectionBookStates(collectionID: Int64) async throws -> [CollectionBookStateWithID] {
            try await dbPool.read { db in
                // SQL 目的：读取书单内全部有效 relation 的 ID、书籍、推荐语、排序与时间戳，用于验证排序和推荐语写入副作用。
                // 涉及表：collection_book。
                // 关键过滤：collection_id 精确匹配且 is_deleted = 0。
                // 时间字段：updated_date 原值用于验证排序与推荐语路径会刷新时间戳。
                // 返回字段：id、book_id、recommend、order、updated_date、is_deleted。
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, book_id, recommend, `order`, updated_date, is_deleted
                        FROM collection_book
                        WHERE collection_id = ?
                          AND is_deleted = 0
                        ORDER BY id ASC
                        """,
                    arguments: [collectionID]
                ).map { row in
                    CollectionBookStateWithID(
                        id: row["id"],
                        bookID: row["book_id"],
                        recommend: row["recommend"],
                        order: row["order"],
                        updatedDate: row["updated_date"],
                        isDeleted: row["is_deleted"]
                    )
                }
            }
        }

        func collectionBookByID(_ id: Int64) async throws -> CollectionBookStateWithID? {
            try await dbPool.read { db in
                // SQL 目的：按 relation id 读取推荐语、排序与时间戳，用于验证推荐语编辑后的最终写入结果。
                // 涉及表：collection_book。
                // 关键过滤：id 精确匹配；不排除软删除，避免测试误掩盖写入目标。
                // 时间字段：updated_date 原值用于验证推荐语路径会刷新时间戳。
                // 返回字段：id、book_id、recommend、order、updated_date、is_deleted。
                try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, book_id, recommend, `order`, updated_date, is_deleted
                        FROM collection_book
                        WHERE id = ?
                        LIMIT 1
                        """,
                    arguments: [id]
                ).map { row in
                    CollectionBookStateWithID(
                        id: row["id"],
                        bookID: row["book_id"],
                        recommend: row["recommend"],
                        order: row["order"],
                        updatedDate: row["updated_date"],
                        isDeleted: row["is_deleted"]
                    )
                }
            }
        }
    }

    struct CollectionState {
        let order: Int64
        let updatedDate: Int64
        let isDeleted: Int64
    }

    struct CollectionBookState {
        let recommend: String
        let order: Int64
        let createdDate: Int64
        let updatedDate: Int64
        let isDeleted: Int64
    }

    struct CollectionBookStateWithID {
        let id: Int64
        let bookID: Int64
        let recommend: String
        let order: Int64
        let updatedDate: Int64
        let isDeleted: Int64
    }

    nonisolated static func sqlIDList(_ ids: [Int64]) -> String {
        "(" + Array(repeating: "?", count: ids.count).joined(separator: ", ") + ")"
    }

    static func makeHarness() throws -> Harness {
        let database = try AppDatabase.empty()
        let manager = DatabaseManager(database: database)
        return Harness(
            dbPool: database.dbPool,
            repository: BookRepository(databaseManager: manager)
        )
    }

    static func insertCollection(
        _ db: Database,
        id: Int64,
        title: String,
        order: Int64,
        isAnnual: Int64,
        year: Int64
    ) throws {
        // SQL 目的：插入测试书单记录，覆盖手动书单与年度书单两类路径。
        // 涉及表：collection。
        // 关键过滤：无查询过滤；通过 is_annual/year 入参构造不同业务类型。
        // 时间字段：fixture 固定 created_date=1、updated_date=0，避免干扰待测写入。
        // 副作用用途：为 collection_book 外键与 Repository 查询提供父记录。
        try db.execute(
            sql: """
                INSERT INTO collection (
                    id, title, `desc`, `order`, is_annual, year,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, '', ?, ?, ?, 1, 0, 0, 0)
                """,
            arguments: [id, title, order, isAnnual, year]
        )
    }

    static func insertCollectionBook(
        _ db: Database,
        collectionID: Int64,
        bookID: Int64,
        recommend: String = "",
        order: Int64,
        createdDate: Int64 = 1,
        updatedDate: Int64 = 0
    ) throws {
        // SQL 目的：插入测试书单书籍关系，模拟 Android 可能保留的有效 relation。
        // 涉及表：collection_book。
        // 关键过滤：无查询过滤；collection_id/book_id 由入参决定。
        // 时间字段：created_date/updated_date 使用入参固定，便于验证去重与软删除是否保留时间。
        // 副作用用途：为书单统计、去重和年度同步测试提供关系行。
        try db.execute(
            sql: """
                INSERT INTO collection_book (
                    collection_id, book_id, recommend, `order`,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, ?, ?, 0, 0)
                """,
            arguments: [collectionID, bookID, recommend, order, createdDate, updatedDate]
        )
    }

    static func insertBook(
        _ db: Database,
        id: Int64,
        readStatusID: Int64 = 1,
        readStatusChangedDate: Int64 = 0,
        isDeleted: Int64
    ) throws {
        // SQL 目的：插入可控状态的测试书籍，覆盖有效书、软删除书与年度同步读完快照。
        // 涉及表：book。
        // 关键过滤：无查询过滤；通过 is_deleted 与 read_status_id 入参构造目标状态。
        // 时间字段：read_status_changed_date 使用入参模拟读完年份；updated_date/last_sync_date 固定为 0。
        // 副作用用途：为 collection_book 外键、手动统计和 AnnualCollectionSync 提供真实 book 行。
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
                    1, 1, 2, 0, 0, 0,
                    0, 0, 0, ?, ?,
                    0, '', 0, NULL, 0, 0,
                    0, ?
                )
                """,
            arguments: [
                id,
                "书单测试书 \(id)",
                "书单测试书 \(id)",
                readStatusID,
                readStatusChangedDate,
                isDeleted
            ]
        )
    }

    static func insertReadStatusRecord(
        _ db: Database,
        bookID: Int64,
        changedDate: Int64
    ) throws {
        // SQL 目的：插入有效读完历史，驱动年度书单同步计算目标年份。
        // 涉及表：book_read_status_record。
        // 关键过滤：无查询过滤；read_status_id 固定为读完状态。
        // 时间字段：changed_date 为毫秒时间戳，AnnualCollectionSync 按自然年解析。
        // 副作用用途：验证年度关系补全与过期关系软删除。
        try db.execute(
            sql: """
                INSERT INTO book_read_status_record (
                    book_id, read_status_id, changed_date,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, 0, 0, 0, 0)
                """,
            arguments: [bookID, BookEntryReadingStatus.finished.rawValue, changedDate]
        )
    }

    static func millis(year: Int, month: Int, day: Int) throws -> Int64 {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        let date = try #require(components.date)
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
