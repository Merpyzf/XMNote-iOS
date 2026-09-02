/**
 * [INPUT]: 依赖 BookRepository、分组/标签/来源管理 Repository、GRDB 临时数据库与 BookAlignment 安全例外合同
 * [OUTPUT]: 锁定批量移出/删除/整理/排序的事务回滚、关系物理删除、串行幂等与 Android 当前确定性成功语义
 * [POS]: xmnoteTests/BookAlignment Repository 安全合同补充测试，不复刻 Android 部分提交、软删除或并发重复
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct BookAlignmentRepositorySafetyContractTests {
    @Test
    func a01MovingTwoBooksOutRollsBackBothWhenSecondRelationDeleteFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let groupID: Int64 = 101_100
        let firstBookID: Int64 = 101_001
        let secondBookID: Int64 = 101_002

        try await harness.write { db in
            try Self.insertGroup(db, id: groupID, name: "移出晚失败分组", order: 5)
            try Self.insertBook(
                db,
                id: firstBookID,
                name: "移出晚失败第一本",
                order: 31,
                pinned: 1,
                pinOrder: 301,
                updatedDate: 1_301
            )
            try Self.insertBook(
                db,
                id: secondBookID,
                name: "移出晚失败第二本",
                order: 32,
                pinned: 1,
                pinOrder: 302,
                updatedDate: 1_302
            )
            try Self.insertGroupBook(db, id: 101_201, groupID: groupID, bookID: firstBookID)
            try Self.insertGroupBook(db, id: 101_202, groupID: groupID, bookID: secondBookID)

            // SQL 目的：在第二本书的 group_book 物理删除处制造稳定晚失败。
            // 涉及表：group_book；关键过滤：OLD.group_id/book_id 精确命中本用例关系。
            // 时间字段：不参与；副作用用途：证明 iOS 外层批量移出事务不会保留第一本前缀写入。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_moveout_delete
                    BEFORE DELETE ON group_book
                    WHEN OLD.group_id = \(groupID)
                     AND OLD.book_id = \(secondBookID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced second move-out relation failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.moveBooksOutOfGroup(
                bookIDs: [firstBookID, secondBookID],
                placement: .end
            )
        }

        let bookRows = try await harness.read { db in
            // SQL 目的：读取失败后两本书的排序、置顶与更新时间，确认全部保持 S2。
            // 涉及表：book；关键过滤：两个合成 book id，不过滤 is_deleted。
            // 时间字段：updated_date 必须保持原值；返回用途：排除取消置顶或重排的部分提交。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, book_order, pinned, pin_order, updated_date
                    FROM book
                    WHERE id IN (?, ?)
                    ORDER BY id
                    """,
                arguments: [firstBookID, secondBookID]
            )
        }
        #expect(bookRows.map { $0["book_order"] as Int64 } == [31, 32])
        #expect(bookRows.map { $0["pinned"] as Int64 } == [1, 1])
        #expect(bookRows.map { $0["pin_order"] as Int64 } == [301, 302])
        #expect(bookRows.map { $0["updated_date"] as Int64 } == [1_301, 1_302])
        #expect(try await harness.groupBookIDs(groupID: groupID) == [firstBookID, secondBookID])
    }

    @Test
    func a02DeletingTwoBooksRollsBackFirstCompleteGraphWhenSecondBookDeleteFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let firstBookID: Int64 = 102_001
        let secondBookID: Int64 = 102_002
        let tagID: Int64 = 102_100

        try await harness.write { db in
            try Self.insertBook(db, id: firstBookID, name: "批量删书第一本", order: 1)
            try Self.insertBook(db, id: secondBookID, name: "批量删书第二本", order: 2)
            try Self.insertTag(db, id: tagID, name: "批量删书关系标签", order: 1)
            try Self.insertTagBook(db, id: 102_201, tagID: tagID, bookID: firstBookID)
            try Self.insertTagBook(db, id: 102_202, tagID: tagID, bookID: secondBookID)

            // SQL 目的：在第二本主记录物理删除前中止，确保第一本完整数据图已走过删除路径。
            // 涉及表：book；关键过滤：OLD.id 精确命中第二本合成书。
            // 时间字段：不参与；副作用用途：验证整批 hardDeleteBookGraph 共用事务并完整回滚。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_book_delete
                    BEFORE DELETE ON book
                    WHEN OLD.id = \(secondBookID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced second book delete failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.deleteBooks([firstBookID, secondBookID])
        }

        let state = try await harness.read { db in
            // SQL 目的：统计失败后两本书与各自标签关系的全部物理行。
            // 涉及表：book、tag_book；关键过滤：两个合成 book id，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：第一本书及其关系也必须恢复，禁止部分硬删除。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM book WHERE id IN (?, ?)) AS book_count,
                        (SELECT COUNT(*) FROM tag_book WHERE book_id IN (?, ?)) AS relation_count,
                        (SELECT COUNT(*) FROM book WHERE id IN (?, ?) AND is_deleted != 0) AS tombstone_count
                    """,
                arguments: [
                    firstBookID, secondBookID,
                    firstBookID, secondBookID,
                    firstBookID, secondBookID
                ]
            )
        }
        let row = try #require(state)
        #expect((row["book_count"] as Int?) == 2)
        #expect((row["relation_count"] as Int?) == 2)
        #expect((row["tombstone_count"] as Int?) == 0)
    }

    @Test
    func a02BatchDeleteRejectsStaleSelectionBeforeDeletingAnyActiveBook() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let activeBookID: Int64 = 102_011
        let staleBookID: Int64 = 102_012

        try await harness.write { db in
            try Self.insertBook(db, id: activeBookID, name: "批量删书有效项", order: 1)
            try Self.insertBook(
                db,
                id: staleBookID,
                name: "批量删书失效项",
                order: 2,
                isDeleted: 1
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.deleteBooks([activeBookID, staleBookID])
        }

        let rows = try await harness.read { db in
            // SQL 目的：确认批量预校验失败后，有效项与历史失效项都没有被物理删除。
            // 涉及表：book；关键过滤：两个合成业务 ID，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：证明失败发生在任何级联写入之前。
            try Row.fetchAll(
                db,
                sql: "SELECT id, is_deleted FROM book WHERE id IN (?, ?) ORDER BY id",
                arguments: [activeBookID, staleBookID]
            )
        }
        #expect(rows.map { $0["id"] as Int64 } == [activeBookID, staleBookID])
        #expect(rows.map { $0["is_deleted"] as Int64 } == [0, 1])
    }

    @Test
    func a03BatchSourceRollsBackFirstBookWhenSecondUpdateFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let firstBookID: Int64 = 103_001
        let secondBookID: Int64 = 103_002
        let targetSourceID: Int64 = 103_100

        try await harness.write { db in
            try Self.insertSource(db, id: targetSourceID, name: "批量目标来源", order: 90)
            try Self.insertBook(
                db,
                id: firstBookID,
                name: "来源晚失败第一本",
                order: 1,
                sourceID: 1,
                updatedDate: 2_001
            )
            try Self.insertBook(
                db,
                id: secondBookID,
                name: "来源晚失败第二本",
                order: 2,
                sourceID: 1,
                updatedDate: 2_002
            )

            // SQL 目的：在批量来源处理第二本时中止 source_id 更新。
            // 涉及表：book；关键过滤：OLD.id 精确命中第二本且 NEW.source_id 为目标来源。
            // 时间字段：不参与；副作用用途：证明第一本来源前缀写入由共同事务回滚。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_source_update
                    BEFORE UPDATE OF source_id ON book
                    WHEN OLD.id = \(secondBookID)
                     AND NEW.source_id = \(targetSourceID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced second source update failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.batchSetBooksSource(
                bookIDs: [firstBookID, secondBookID],
                sourceID: targetSourceID
            )
        }

        let rows = try await harness.read { db in
            // SQL 目的：读取失败后两本书的来源和业务更新时间字段。
            // 涉及表：book；关键过滤：两个合成 book id。
            // 时间字段：updated_date 必须保持 S2；返回用途：锁定批量来源原子性。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_id, updated_date
                    FROM book
                    WHERE id IN (?, ?)
                    ORDER BY id
                    """,
                arguments: [firstBookID, secondBookID]
            )
        }
        #expect(rows.map { $0["source_id"] as Int64 } == [1, 1])
        #expect(rows.map { $0["updated_date"] as Int64 } == [2_001, 2_002])
    }
}

@MainActor
extension BookAlignmentRepositorySafetyContractTests {
    @Test
    func a03SingleTagReplacementRollsBackPhysicalRemovalWhenSecondInsertFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let bookID: Int64 = 104_001
        let oldTagID: Int64 = 104_100
        let firstTargetTagID: Int64 = 104_101
        let secondTargetTagID: Int64 = 104_102
        let oldRelationID: Int64 = 104_200

        try await harness.write { db in
            try Self.insertBook(db, id: bookID, name: "单本标签晚失败", order: 1)
            try Self.insertTag(db, id: oldTagID, name: "旧标签", order: 1)
            try Self.insertTag(db, id: firstTargetTagID, name: "目标标签一", order: 2)
            try Self.insertTag(db, id: secondTargetTagID, name: "目标标签二", order: 3)
            try Self.insertTagBook(db, id: oldRelationID, tagID: oldTagID, bookID: bookID)

            // SQL 目的：让单本替换先物理删除旧关系、插入第一目标关系，再在第二目标关系处失败。
            // 涉及表：tag_book；关键过滤：NEW.book_id/tag_id 精确命中第二目标关系。
            // 时间字段：不参与；副作用用途：证明删除与全部插入位于同一 Repository 事务。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_single_tag_insert
                    BEFORE INSERT ON tag_book
                    WHEN NEW.book_id = \(bookID)
                     AND NEW.tag_id = \(secondTargetTagID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced second single-tag insert failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.mutateBooksTags(
                bookIDs: [bookID],
                tagIDs: [firstTargetTagID, secondTargetTagID],
                mode: .replace
            )
        }

        let rows = try await harness.tagRelationRows(bookIDs: [bookID])
        #expect(rows.map(\.id) == [oldRelationID])
        #expect(rows.map(\.tagID) == [oldTagID])
        #expect(rows.map(\.isDeleted) == [0])
    }

    @Test
    func a03MultiBookTagAppendRollsBackFirstInsertWhenSecondBookFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let firstBookID: Int64 = 105_001
        let secondBookID: Int64 = 105_002
        let firstOldTagID: Int64 = 105_100
        let secondOldTagID: Int64 = 105_101
        let targetTagID: Int64 = 105_102

        try await harness.write { db in
            try Self.insertBook(db, id: firstBookID, name: "多本标签晚失败一", order: 1)
            try Self.insertBook(db, id: secondBookID, name: "多本标签晚失败二", order: 2)
            try Self.insertTag(db, id: firstOldTagID, name: "多本旧标签一", order: 1)
            try Self.insertTag(db, id: secondOldTagID, name: "多本旧标签二", order: 2)
            try Self.insertTag(db, id: targetTagID, name: "多本目标标签", order: 3)
            try Self.insertTagBook(db, id: 105_200, tagID: firstOldTagID, bookID: firstBookID)
            try Self.insertTagBook(db, id: 105_201, tagID: secondOldTagID, bookID: secondBookID)

            // SQL 目的：在多本追加处理第二本目标关系时中止 INSERT。
            // 涉及表：tag_book；关键过滤：NEW.book_id/tag_id 精确命中第二本目标关系。
            // 时间字段：不参与；副作用用途：证明第一本已经插入的目标关系也随整批回滚。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_multi_tag_insert
                    BEFORE INSERT ON tag_book
                    WHEN NEW.book_id = \(secondBookID)
                     AND NEW.tag_id = \(targetTagID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced second multi-tag insert failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.mutateBooksTags(
                bookIDs: [firstBookID, secondBookID],
                tagIDs: [targetTagID],
                mode: .add
            )
        }

        let rows = try await harness.tagRelationRows(bookIDs: [firstBookID, secondBookID])
        #expect(rows.map(\.bookID) == [firstBookID, secondBookID])
        #expect(rows.map(\.tagID) == [firstOldTagID, secondOldTagID])
        #expect(rows.map(\.isDeleted) == [0, 0])
    }

    @Test
    func a03A04A09TagInputsNormalizeEmptyBranchesAndNeverAccumulateTombstones() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let duplicateBookID: Int64 = 106_001
        let emptySingleBookID: Int64 = 106_002
        let emptyMultiBookA: Int64 = 106_003
        let emptyMultiBookB: Int64 = 106_004
        let repeatedBookID: Int64 = 106_005
        let oldTagID: Int64 = 106_100
        let replacementTagA: Int64 = 106_101
        let replacementTagB: Int64 = 106_102

        try await harness.write { db in
            for (index, bookID) in [
                duplicateBookID,
                emptySingleBookID,
                emptyMultiBookA,
                emptyMultiBookB,
                repeatedBookID
            ].enumerated() {
                try Self.insertBook(
                    db,
                    id: bookID,
                    name: "标签分支书 \(index)",
                    order: Int64(index)
                )
            }
            try Self.insertTag(db, id: oldTagID, name: "分支旧标签", order: 1)
            try Self.insertTag(db, id: replacementTagA, name: "替换标签 A", order: 2)
            try Self.insertTag(db, id: replacementTagB, name: "替换标签 B", order: 3)
            for (index, bookID) in [
                duplicateBookID,
                emptySingleBookID,
                emptyMultiBookA,
                emptyMultiBookB,
                repeatedBookID
            ].enumerated() {
                try Self.insertTagBook(
                    db,
                    id: Int64(106_200 + index),
                    tagID: oldTagID,
                    bookID: bookID
                )
            }
        }

        try await harness.bookRepository.mutateBooksTags(
            bookIDs: [duplicateBookID, duplicateBookID],
            tagIDs: [replacementTagA, replacementTagA],
            mode: .replace
        )
        try await harness.bookRepository.mutateBooksTags(
            bookIDs: [emptySingleBookID],
            tagIDs: [],
            mode: .replace
        )
        try await harness.bookRepository.mutateBooksTags(
            bookIDs: [emptyMultiBookA, emptyMultiBookB],
            tagIDs: [],
            mode: .add
        )
        try await harness.bookRepository.mutateBooksTags(
            bookIDs: [repeatedBookID],
            tagIDs: [replacementTagA],
            mode: .replace
        )
        try await harness.bookRepository.mutateBooksTags(
            bookIDs: [repeatedBookID],
            tagIDs: [replacementTagB],
            mode: .replace
        )
        try await harness.bookRepository.mutateBooksTags(
            bookIDs: [repeatedBookID],
            tagIDs: [replacementTagA],
            mode: .replace
        )

        let rows = try await harness.tagRelationRows(
            bookIDs: [
                duplicateBookID,
                emptySingleBookID,
                emptyMultiBookA,
                emptyMultiBookB,
                repeatedBookID
            ]
        )
        #expect(rows.filter { $0.bookID == duplicateBookID }.map(\.tagID) == [replacementTagA])
        #expect(rows.filter { $0.bookID == emptySingleBookID }.isEmpty)
        #expect(rows.filter { $0.bookID == emptyMultiBookA }.map(\.tagID) == [oldTagID])
        #expect(rows.filter { $0.bookID == emptyMultiBookB }.map(\.tagID) == [oldTagID])
        #expect(rows.filter { $0.bookID == repeatedBookID }.map(\.tagID) == [replacementTagA])
        #expect(rows.allSatisfy { $0.isDeleted == 0 })
    }
}

private extension BookAlignmentRepositorySafetyContractTests {
    nonisolated static func insertBook(
        _ db: Database,
        id: Int64,
        name: String,
        order: Int64,
        pinned: Int64 = 0,
        pinOrder: Int64 = 0,
        sourceID: Int64 = 1,
        readStatusID: Int64 = 1,
        score: Int64 = 0,
        author: String = "",
        press: String = "",
        updatedDate: Int64 = 0,
        isDeleted: Int64 = 0
    ) throws {
        var record = BookRecord()
        record.id = id
        record.userId = 1
        record.name = name
        record.rawName = name
        record.author = author
        record.press = press
        record.sourceId = sourceID
        record.readStatusId = readStatusID
        record.totalPosition = 100
        record.totalPagination = 100
        record.bookOrder = order
        record.pinned = pinned
        record.pinOrder = pinOrder
        record.score = score
        record.createdDate = 100
        record.updatedDate = updatedDate
        record.isDeleted = isDeleted
        try record.insert(db)
    }

    nonisolated static func insertGroup(
        _ db: Database,
        id: Int64,
        name: String,
        order: Int64
    ) throws {
        var record = GroupRecord()
        record.id = id
        record.userId = 1
        record.name = name
        record.groupOrder = order
        record.createdDate = 100
        try record.insert(db)
    }

    nonisolated static func insertGroupBook(
        _ db: Database,
        id: Int64,
        groupID: Int64,
        bookID: Int64
    ) throws {
        var record = GroupBookRecord()
        record.id = id
        record.groupId = groupID
        record.bookId = bookID
        record.createdDate = 100
        try record.insert(db)
    }

    nonisolated static func insertTag(
        _ db: Database,
        id: Int64,
        name: String,
        order: Int64,
        updatedDate: Int64 = 0
    ) throws {
        var record = TagRecord()
        record.id = id
        record.userId = 1
        record.name = name
        record.tagOrder = order
        record.type = TagManagementScope.book.rawValue
        record.createdDate = 100
        record.updatedDate = updatedDate
        record.lastSyncDate = 0
        try record.insert(db)
    }

    nonisolated static func insertTagBook(
        _ db: Database,
        id: Int64,
        tagID: Int64,
        bookID: Int64
    ) throws {
        var record = TagBookRecord()
        record.id = id
        record.tagId = tagID
        record.bookId = bookID
        record.createdDate = 100
        try record.insert(db)
    }

    nonisolated static func insertSource(
        _ db: Database,
        id: Int64,
        name: String,
        order: Int64,
        bookshelfOrder: Int64? = nil,
        updatedDate: Int64 = 0
    ) throws {
        var record = SourceRecord()
        record.id = id
        record.name = name
        record.sourceOrder = order
        record.bookshelfOrder = bookshelfOrder ?? order
        record.createdDate = 100
        record.updatedDate = updatedDate
        record.lastSyncDate = 0
        try record.insert(db)
    }

    nonisolated static func insertReadStatus(
        _ db: Database,
        id: Int64,
        name: String,
        order: Int64,
        updatedDate: Int64 = 0
    ) throws {
        var record = ReadStatusRecord()
        record.id = id
        record.name = name
        record.readStatusOrder = order
        record.createdDate = 100
        record.updatedDate = updatedDate
        record.lastSyncDate = 0
        try record.insert(db)
    }

    nonisolated static func insertCollection(
        _ db: Database,
        id: Int64,
        title: String
    ) throws {
        var record = CollectionRecord()
        record.id = id
        record.title = title
        record.order = 1
        record.isAnnual = 0
        record.createdDate = 100
        try record.insert(db)
    }

    nonisolated static func insertAuthor(
        _ db: Database,
        id: Int64,
        name: String,
        updatedDate: Int64
    ) throws {
        var record = AuthorRecord()
        record.id = id
        record.name = name
        record.createdDate = 100
        record.updatedDate = updatedDate
        try record.insert(db)
    }

    nonisolated static func insertPress(
        _ db: Database,
        id: Int64,
        name: String,
        updatedDate: Int64
    ) throws {
        var record = PressRecord()
        record.id = id
        record.name = name
        record.createdDate = 100
        record.updatedDate = updatedDate
        try record.insert(db)
    }
}

private struct BookAlignmentTagRelationState: Sendable {
    let id: Int64
    let bookID: Int64
    let tagID: Int64
    let isDeleted: Int64
}

private struct BookAlignmentContributorBookState: Sendable {
    let author: String
    let press: String
    let updatedDate: Int64
    let isDeleted: Int64
}

@MainActor
private final class BookAlignmentSafetyHarness {
    let workingDirectoryURL: URL
    let database: AppDatabase
    let bookRepository: BookRepository

    private init(workingDirectoryURL: URL, database: AppDatabase) {
        self.workingDirectoryURL = workingDirectoryURL
        self.database = database
        bookRepository = BookRepository(databaseManager: DatabaseManager(database: database))
    }

    static func make() throws -> BookAlignmentSafetyHarness {
        let workingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmnote-book-safety-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workingDirectoryURL,
                withIntermediateDirectories: true
            )
            let databaseURL = workingDirectoryURL.appendingPathComponent("contract.db")
            let database = try AppDatabase(path: databaseURL.path)
            return BookAlignmentSafetyHarness(
                workingDirectoryURL: workingDirectoryURL,
                database: database
            )
        } catch {
            try? FileManager.default.removeItem(at: workingDirectoryURL)
            throw error
        }
    }

    func write(_ updates: (Database) throws -> Void) async throws {
        try await database.dbPool.write { db in
            try updates(db)
        }
    }

    func read<Value>(_ value: (Database) throws -> Value) async throws -> Value {
        try await database.dbPool.read { db in
            try value(db)
        }
    }

    func groupBookIDs(groupID: Int64) async throws -> [Int64] {
        try await read { db in
            // SQL 目的：读取指定分组的全部有效书籍关系。
            // 涉及表：group_book；关键过滤：group_id 精确匹配且 is_deleted = 0。
            // 时间字段：不参与；返回用途：验证移组/移出失败回滚及成功关系硬删除。
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT book_id
                    FROM group_book
                    WHERE group_id = ?
                      AND is_deleted = 0
                    ORDER BY book_id
                    """,
                arguments: [groupID]
            )
        }
    }

    func bookContributorRows(bookIDs: [Int64]) async throws -> [BookAlignmentContributorBookState] {
        guard !bookIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ", ")
        return try await read { db in
            // SQL 目的：读取批量作者/出版社操作后的书籍字段与更新时间。
            // 涉及表：book；关键过滤：id 为合成测试集合，不按 is_deleted 过滤。
            // 时间字段：updated_date 用于验证同一命令共享时间；返回用途：区分有效书与历史 tombstone 边界。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT author, press, updated_date, is_deleted
                    FROM book
                    WHERE id IN (\(placeholders))
                    ORDER BY id
                    """,
                arguments: StatementArguments(bookIDs)
            ).map { row in
                BookAlignmentContributorBookState(
                    author: row["author"] ?? "",
                    press: row["press"] ?? "",
                    updatedDate: row["updated_date"] ?? 0,
                    isDeleted: row["is_deleted"] ?? 0
                )
            }
        }
    }

    func contributorRowsDigest() async throws -> [String] {
        try await read { db in
            // SQL 目的：生成作者和出版社资料表的稳定摘要，证明书籍字段批量修改没有资料表副作用。
            // 涉及表：author、press；关键过滤：无，按类型与 id 稳定排序。
            // 时间字段：摘要包含 updated_date；返回用途：比较命令前后资料记录身份、名称、更新时间与删除状态。
            try String.fetchAll(
                db,
                sql: """
                    SELECT 'author:' || id || ':' || name || ':' || updated_date || ':' || is_deleted AS digest
                    FROM author
                    UNION ALL
                    SELECT 'press:' || id || ':' || name || ':' || updated_date || ':' || is_deleted AS digest
                    FROM press
                    ORDER BY digest
                    """
            )
        }
    }

    func tagRelationRows(bookIDs: [Int64]) async throws -> [BookAlignmentTagRelationState] {
        guard !bookIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ", ")
        return try await read { db in
            // SQL 目的：读取指定书籍的全部 tag_book 物理行，显式暴露 tombstone。
            // 涉及表：tag_book；关键过滤：book_id 为合成测试集合，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：验证标签替换、追加、回滚与重复执行后的物理状态。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, book_id, tag_id, is_deleted
                    FROM tag_book
                    WHERE book_id IN (\(placeholders))
                    ORDER BY book_id, tag_id, id
                    """,
                arguments: StatementArguments(bookIDs)
            ).map { row in
                BookAlignmentTagRelationState(
                    id: row["id"],
                    bookID: row["book_id"],
                    tagID: row["tag_id"],
                    isDeleted: row["is_deleted"]
                )
            }
        }
    }

    func bookOrders(ids: [Int64]) async throws -> [Int64: Int64] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try await read { db in
            // SQL 目的：读取目标书籍的物理 book_order，不依赖 UI 排序投影。
            // 涉及表：book；关键过滤：id 为合成测试集合，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：验证排序失败后每个稳定 ID 的原值。
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, book_order FROM book WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["id"] as Int64, row["book_order"] as Int64)
            })
        }
    }

    func groupOrder(id: Int64) async throws -> Int64? {
        try await read { db in
            // SQL 目的：读取混排目标分组的 group_order 原值。
            // 涉及表：group；关键过滤：id 精确匹配，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：证明先于失败项写入的分组排序也被回滚。
            try Int64.fetchOne(
                db,
                sql: "SELECT group_order FROM `group` WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func statusHistoryCount(bookIDs: [Int64]) async throws -> Int {
        guard !bookIDs.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ", ")
        return try await read { db in
            // SQL 目的：统计目标书籍的全部阅读状态历史物理行。
            // 涉及表：book_read_status_record；关键过滤：book_id 为合成测试集合，不过滤 is_deleted。
            // 时间字段：不参与计数；返回用途：验证状态批量晚失败不会留下历史前缀。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book_read_status_record WHERE book_id IN (\(placeholders))",
                arguments: StatementArguments(bookIDs)
            ) ?? 0
        }
    }

    func collectionRelationCount(bookIDs: [Int64]) async throws -> Int {
        guard !bookIDs.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ", ")
        return try await read { db in
            // SQL 目的：统计目标书籍的全部书单关系物理行。
            // 涉及表：collection_book；关键过滤：book_id 为合成测试集合，不过滤 is_deleted。
            // 时间字段：不参与计数；返回用途：验证读完年度书单副作用在批量晚失败后完整回滚。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM collection_book WHERE book_id IN (\(placeholders))",
                arguments: StatementArguments(bookIDs)
            ) ?? 0
        }
    }

    func annualCollectionCount() async throws -> Int {
        try await read { db in
            // SQL 目的：统计有效年度书单，用于比较状态批量写入前后的集合实体数量。
            // 涉及表：collection；关键过滤：is_annual = 1 且 is_deleted = 0。
            // 时间字段：不参与；返回用途：证明失败事务未留下新建年度书单。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM collection WHERE is_annual = 1 AND is_deleted = 0"
            ) ?? 0
        }
    }

    func cleanup() {
        database.interrupt()
        try? database.close()
        try? FileManager.default.removeItem(at: workingDirectoryURL)
    }
}

@MainActor
extension BookAlignmentRepositorySafetyContractTests {
    @Test
    func a05MixedBookGroupSortRollsBackPrefixWhenLaterBookUpdateFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let prefixBookID: Int64 = 109_001
        let failingBookID: Int64 = 109_002
        let suffixBookID: Int64 = 109_003
        let prefixGroupID: Int64 = 109_100

        try await harness.write { db in
            try Self.insertBook(db, id: prefixBookID, name: "混排前缀书", order: 100, updatedDate: 5_001)
            try Self.insertBook(db, id: failingBookID, name: "混排失败书", order: 102, updatedDate: 5_002)
            try Self.insertBook(db, id: suffixBookID, name: "混排后缀书", order: 103, updatedDate: 5_003)
            try Self.insertGroup(db, id: prefixGroupID, name: "混排前缀组", order: 101)

            // SQL 目的：在 Book→Group 两项已更新后，于第三项 book_order UPDATE 处中止。
            // 涉及表：book；关键过滤：OLD.id 精确命中失败书。
            // 时间字段：不参与；副作用用途：验证 Book/Group 混排写入使用共同事务且错误向上传播。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_mixed_sort_book
                    BEFORE UPDATE OF book_order ON book
                    WHEN OLD.id = \(failingBookID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced mixed sort failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.updateBookshelfOrder([
                BookshelfOrderItem(id: .book(prefixBookID), isPinned: false),
                BookshelfOrderItem(id: .group(prefixGroupID), isPinned: false),
                BookshelfOrderItem(id: .book(failingBookID), isPinned: false),
                BookshelfOrderItem(id: .book(suffixBookID), isPinned: false)
            ])
        }

        let bookOrders = try await harness.bookOrders(ids: [prefixBookID, failingBookID, suffixBookID])
        #expect(bookOrders == [prefixBookID: 100, failingBookID: 102, suffixBookID: 103])
        let groupOrder = try await harness.groupOrder(id: prefixGroupID)
        #expect(groupOrder == 101)
    }

    @Test
    func a05GroupBookSortRollsBackAllOrdersWhenSecondUpdateFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let groupID: Int64 = 110_100
        let bookA: Int64 = 110_001
        let bookB: Int64 = 110_002
        let bookC: Int64 = 110_003

        try await harness.write { db in
            try Self.insertGroup(db, id: groupID, name: "组内排序晚失败", order: 1)
            for (index, bookID) in [bookA, bookB, bookC].enumerated() {
                try Self.insertBook(
                    db,
                    id: bookID,
                    name: "组内排序书 \(index)",
                    order: Int64(11 + index),
                    updatedDate: Int64(6_001 + index)
                )
                try Self.insertGroupBook(
                    db,
                    id: Int64(110_200 + index),
                    groupID: groupID,
                    bookID: bookID
                )
            }

            // SQL 目的：让组内目标顺序的第一本先更新，再在第二本 book_order 处中止。
            // 涉及表：book；关键过滤：OLD.id 精确命中第二本。
            // 时间字段：不参与；副作用用途：同时覆盖 Android Rx/suspend owner 在 iOS 汇聚到单事务后的回滚合同。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_group_sort_book
                    BEFORE UPDATE OF book_order ON book
                    WHEN OLD.id = \(bookB)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced group sort failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.updateBooksInGroupOrder(
                groupID: groupID,
                orderedBookIDs: [bookC, bookB, bookA]
            )
        }

        #expect(try await harness.bookOrders(ids: [bookA, bookB, bookC]) == [
            bookA: 11,
            bookB: 12,
            bookC: 13
        ])
        #expect(try await harness.groupBookIDs(groupID: groupID) == [bookA, bookB, bookC])
    }

    @Test
    func a05ReadStatusSortRollsBackPrefixAndKeepsUpdatedDateWhenSecondUpdateFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let prefixID: Int64 = 114_101
        let failingID: Int64 = 114_102
        let suffixID: Int64 = 114_103

        try await harness.write { db in
            try Self.insertReadStatus(
                db,
                id: prefixID,
                name: "状态排序前缀",
                order: 410,
                updatedDate: 8_001
            )
            try Self.insertReadStatus(
                db,
                id: failingID,
                name: "状态排序失败项",
                order: 411,
                updatedDate: 8_002
            )
            try Self.insertReadStatus(
                db,
                id: suffixID,
                name: "状态排序后缀",
                order: 412,
                updatedDate: 8_003
            )

            // SQL 目的：在第二条 read_status_order 写入处制造稳定晚失败。
            // 涉及表：read_status；关键过滤：OLD.id 精确命中失败项。
            // 时间字段：不参与；副作用用途：证明第一条排序写入由 Repository 事务完整回滚。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_status_sort
                    BEFORE UPDATE OF read_status_order ON read_status
                    WHEN OLD.id = \(failingID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced read-status sort failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.updateBookshelfAggregateOrder(
                context: .readStatus,
                orderedIDs: [prefixID, failingID, suffixID]
            )
        }

        let rows = try await harness.read { db in
            // SQL 目的：读取晚失败后三条状态的排序与业务更新时间字段。
            // 涉及表：read_status；关键过滤：三个合成状态 id。
            // 时间字段：updated_date 必须保持原值；返回用途：验证零前缀提交。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT read_status_order, updated_date
                    FROM read_status
                    WHERE id IN (?, ?, ?)
                    ORDER BY id
                    """,
                arguments: [prefixID, failingID, suffixID]
            )
        }
        #expect(rows.map { $0["read_status_order"] as Int64 } == [410, 411, 412])
        #expect(rows.map { $0["updated_date"] as Int64 } == [8_001, 8_002, 8_003])
    }

    @Test
    func a05TagSortRollsBackPrefixAndKeepsUpdatedDateWhenSecondUpdateFails() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let prefixID: Int64 = 115_101
        let failingID: Int64 = 115_102
        let suffixID: Int64 = 115_103

        try await harness.write { db in
            try Self.insertTag(
                db,
                id: prefixID,
                name: "标签排序前缀",
                order: 510,
                updatedDate: 9_001
            )
            try Self.insertTag(
                db,
                id: failingID,
                name: "标签排序失败项",
                order: 511,
                updatedDate: 9_002
            )
            try Self.insertTag(
                db,
                id: suffixID,
                name: "标签排序后缀",
                order: 512,
                updatedDate: 9_003
            )

            // SQL 目的：在第二条书籍标签 tag_order 写入处制造稳定晚失败。
            // 涉及表：tag；关键过滤：OLD.id 精确命中失败项且测试数据 type = 2。
            // 时间字段：不参与；副作用用途：证明第一条排序写入由 Repository 事务完整回滚。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_tag_sort
                    BEFORE UPDATE OF tag_order ON tag
                    WHEN OLD.id = \(failingID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced tag sort failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.updateBookshelfAggregateOrder(
                context: .tag,
                orderedIDs: [prefixID, failingID, suffixID]
            )
        }

        let rows = try await harness.read { db in
            // SQL 目的：读取晚失败后三条书籍标签的排序与业务更新时间字段。
            // 涉及表：tag；关键过滤：三个合成 tag id，不过滤 is_deleted。
            // 时间字段：updated_date 必须保持原值；返回用途：验证零前缀提交。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT tag_order, updated_date
                    FROM tag
                    WHERE id IN (?, ?, ?)
                    ORDER BY id
                    """,
                arguments: [prefixID, failingID, suffixID]
            )
        }
        #expect(rows.map { $0["tag_order"] as Int64 } == [510, 511, 512])
        #expect(rows.map { $0["updated_date"] as Int64 } == [9_001, 9_002, 9_003])
    }

    @Test
    func a05SourceSortWritesOnlyBookshelfOrderAndRepositoryRefreshReadsThatOrder() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let sourceA: Int64 = 116_101
        let sourceB: Int64 = 116_102
        let bookA: Int64 = 116_001
        let bookB: Int64 = 116_002

        try await harness.write { db in
            try Self.insertSource(
                db,
                id: sourceA,
                name: "来源书架顺序 A",
                order: 10,
                bookshelfOrder: 80,
                updatedDate: 10_001
            )
            try Self.insertSource(
                db,
                id: sourceB,
                name: "来源书架顺序 B",
                order: 90,
                bookshelfOrder: 20,
                updatedDate: 10_002
            )
            try Self.insertBook(db, id: bookA, name: "来源 A 的书", order: 1, sourceID: sourceA)
            try Self.insertBook(db, id: bookB, name: "来源 B 的书", order: 2, sourceID: sourceB)
        }

        let beforeRows = try await harness.read(BookshelfBookAggregateQuery.fetchAllRows)
        let beforeGroups = harness.bookRepository.makeSourceGroups(
            from: beforeRows,
            setting: BookshelfDisplaySetting(sortCriteria: .custom)
        )
        #expect(beforeGroups.compactMap(\.orderID) == [sourceB, sourceA])

        try await harness.bookRepository.updateBookshelfAggregateOrder(
            context: .source,
            orderedIDs: [sourceA, sourceB]
        )

        let rows = try await harness.read { db in
            // SQL 目的：读取来源书架排序成功后的两个独立顺序字段和业务更新时间。
            // 涉及表：source；关键过滤：两个合成 source id。
            // 时间字段：updated_date 必须保持原值；返回用途：证明仅 bookshelf_order 变化。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT source_order, bookshelf_order, updated_date
                    FROM source
                    WHERE id IN (?, ?)
                    ORDER BY id
                    """,
                arguments: [sourceA, sourceB]
            )
        }
        #expect(rows.map { $0["source_order"] as Int64 } == [10, 90])
        #expect(rows.map { $0["bookshelf_order"] as Int64 } == [0, 1])
        #expect(rows.map { $0["updated_date"] as Int64 } == [10_001, 10_002])

        let afterRows = try await harness.read(BookshelfBookAggregateQuery.fetchAllRows)
        let afterGroups = harness.bookRepository.makeSourceGroups(
            from: afterRows,
            setting: BookshelfDisplaySetting(sortCriteria: .custom)
        )
        #expect(afterGroups.compactMap(\.orderID) == [sourceA, sourceB])
    }

    @Test
    func a05SourceSortRollsBackBookshelfOrderAndKeepsDictionaryAndUpdatedDate() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let prefixID: Int64 = 117_101
        let failingID: Int64 = 117_102
        let suffixID: Int64 = 117_103

        try await harness.write { db in
            try Self.insertSource(
                db,
                id: prefixID,
                name: "来源排序前缀",
                order: 610,
                bookshelfOrder: 410,
                updatedDate: 11_001
            )
            try Self.insertSource(
                db,
                id: failingID,
                name: "来源排序失败项",
                order: 611,
                bookshelfOrder: 411,
                updatedDate: 11_002
            )
            try Self.insertSource(
                db,
                id: suffixID,
                name: "来源排序后缀",
                order: 612,
                bookshelfOrder: 412,
                updatedDate: 11_003
            )

            // SQL 目的：在第二条 bookshelf_order 写入处制造稳定晚失败。
            // 涉及表：source；关键过滤：OLD.id 精确命中失败项。
            // 时间字段：不参与；副作用用途：证明前缀书架顺序写入由 Repository 事务完整回滚。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_source_sort
                    BEFORE UPDATE OF bookshelf_order ON source
                    WHEN OLD.id = \(failingID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced source sort failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.updateBookshelfAggregateOrder(
                context: .source,
                orderedIDs: [prefixID, failingID, suffixID]
            )
        }

        let rows = try await harness.read { db in
            // SQL 目的：读取晚失败后三条来源的书架顺序、字典顺序与业务更新时间字段。
            // 涉及表：source；关键过滤：三个合成 source id，不过滤 is_deleted。
            // 时间字段：updated_date 必须保持原值；返回用途：验证零前缀提交且不串写 source_order。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT bookshelf_order, source_order, updated_date
                    FROM source
                    WHERE id IN (?, ?, ?)
                    ORDER BY id
                    """,
                arguments: [prefixID, failingID, suffixID]
            )
        }
        #expect(rows.map { $0["bookshelf_order"] as Int64 } == [410, 411, 412])
        #expect(rows.map { $0["source_order"] as Int64 } == [610, 611, 612])
        #expect(rows.map { $0["updated_date"] as Int64 } == [11_001, 11_002, 11_003])
    }

    @Test
    func a06MoveOutToStartPreservesInputOrderWithoutTombstones() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let groupID: Int64 = 111_100
        let anchorBookID: Int64 = 111_000
        let bookA: Int64 = 111_001
        let bookB: Int64 = 111_002
        let bookC: Int64 = 111_003

        try await harness.write { db in
            try Self.insertBook(db, id: anchorBookID, name: "默认书架锚点", order: 50)
            try Self.insertGroup(db, id: groupID, name: "批量移出顺序组", order: 60)
            for (index, bookID) in [bookA, bookB, bookC].enumerated() {
                try Self.insertBook(
                    db,
                    id: bookID,
                    name: "移出顺序书 \(index)",
                    order: Int64(70 + index),
                    pinned: 1,
                    pinOrder: Int64(index + 1)
                )
                try Self.insertGroupBook(
                    db,
                    id: Int64(111_200 + index),
                    groupID: groupID,
                    bookID: bookID
                )
            }
        }

        try await harness.bookRepository.moveBooksOutOfGroup(
            bookIDs: [bookA, bookB, bookC],
            placement: .start
        )

        let orderedIDs = try await harness.read { db in
            // SQL 目的：按最终 book_order 读取三本被移出书，锁定批量命令保持输入顺序。
            // 涉及表：book；关键过滤：三个合成 book id 且有效。
            // 时间字段：不参与排序；返回用途：验证一次读取边界后连续分配 A→B→C。
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM book
                    WHERE id IN (?, ?, ?)
                      AND is_deleted = 0
                    ORDER BY book_order, id
                    """,
                arguments: [bookA, bookB, bookC]
            )
        }
        #expect(orderedIDs == [bookA, bookB, bookC])
        #expect(try await harness.groupBookIDs(groupID: groupID).isEmpty)

        let remainingRelations = try await harness.read { db in
            // SQL 目的：统计移出后三本书的全部 group_book 物理行，禁止以 tombstone 模拟关系移除。
            // 涉及表：group_book；关键过滤：三个合成 book id，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：锁定已批准的关系硬删除安全例外。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM group_book WHERE book_id IN (?, ?, ?)",
                arguments: [bookA, bookB, bookC]
            ) ?? 0
        }
        #expect(remainingRelations == 0)
    }

    @Test
    func a07BatchModifyAuthorAndPressUpdatesOnlyActiveBooksWithoutChangingContributorRecords() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let activeBookA: Int64 = 112_001
        let activeBookB: Int64 = 112_002
        let deletedBookID: Int64 = 112_003
        let authorA = "批量旧作者甲"
        let authorB = "批量旧作者乙"
        let targetAuthor = "批量目标作者"
        let pressA = "批量旧出版社甲"
        let pressB = "批量旧出版社乙"
        let targetPress = "批量目标出版社"

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: activeBookA,
                name: "批量修改有效书甲",
                order: 1,
                author: authorA,
                press: pressA,
                updatedDate: 7_001
            )
            try Self.insertBook(
                db,
                id: activeBookB,
                name: "批量修改有效书乙",
                order: 2,
                author: authorB,
                press: pressB,
                updatedDate: 7_002,
            )
            try Self.insertBook(
                db,
                id: deletedBookID,
                name: "批量修改历史墓碑书",
                order: 3,
                author: authorA,
                press: pressA,
                updatedDate: 7_003,
                isDeleted: 1
            )
            try Self.insertAuthor(db, id: 112_101, name: authorA, updatedDate: 8_001)
            try Self.insertAuthor(db, id: 112_102, name: authorB, updatedDate: 8_002)
            try Self.insertAuthor(db, id: 112_103, name: targetAuthor, updatedDate: 8_003)
            try Self.insertPress(db, id: 112_201, name: pressA, updatedDate: 9_001)
            try Self.insertPress(db, id: 112_202, name: pressB, updatedDate: 9_002)
            try Self.insertPress(db, id: 112_203, name: targetPress, updatedDate: 9_003)
        }

        let contributorRowsBefore = try await harness.contributorRowsDigest()
        try await harness.bookRepository.batchModifyBooksAuthor(
            sourceNames: [authorA, authorB, authorA, targetAuthor],
            newName: targetAuthor
        )

        let authorRows = try await harness.bookContributorRows(bookIDs: [activeBookA, activeBookB, deletedBookID])
        #expect(authorRows.map { $0.author } == [targetAuthor, targetAuthor, authorA])
        #expect(authorRows[0].updatedDate > 7_002)
        #expect(authorRows[0].updatedDate == authorRows[1].updatedDate)
        #expect(authorRows[2].updatedDate == 7_003)

        try await harness.bookRepository.batchModifyBooksPress(
            sourceNames: [pressA, pressB, pressA, targetPress],
            newName: targetPress
        )

        let rows = try await harness.bookContributorRows(bookIDs: [activeBookA, activeBookB, deletedBookID])
        #expect(rows.map(\.author) == [targetAuthor, targetAuthor, authorA])
        #expect(rows.map(\.press) == [targetPress, targetPress, pressA])
        #expect(rows[0].updatedDate > 7_002)
        #expect(rows[0].updatedDate == rows[1].updatedDate)
        #expect(rows[2].updatedDate == 7_003)
        #expect(rows.map(\.isDeleted) == [0, 0, 1])
        #expect(try await harness.contributorRowsDigest() == contributorRowsBefore)
    }

    @Test
    func a07BatchModifyAuthorAndPressRollsBackWhenALaterSourceHasNoActiveBooks() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let bookID: Int64 = 112_011
        let author = "回滚作者"
        let press = "回滚出版社"

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: bookID,
                name: "作者出版社晚失败回滚书",
                order: 1,
                author: author,
                press: press,
                updatedDate: 7_011
            )
        }

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.batchModifyBooksAuthor(
                sourceNames: [author, "不存在作者"],
                newName: "不应提交作者"
            )
        }
        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.batchModifyBooksPress(
                sourceNames: [press, "不存在出版社"],
                newName: "不应提交出版社"
            )
        }

        let row = try await harness.read { db in
            // SQL 目的：读取有效书与历史 tombstone 书的作者、出版社及业务更新时间。
            // 涉及表：book；关键过滤：合成 book id，不按 is_deleted 过滤。
            // 时间字段：晚失败后 updated_date 必须保持 S2；返回用途：证明两个批量命令均完整回滚。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT author, press, updated_date
                    FROM book
                    WHERE id = ?
                    """,
                arguments: [bookID]
            )
        }
        let finalRow = try #require(row)
        #expect((finalRow["author"] as String?) == author)
        #expect((finalRow["press"] as String?) == press)
        #expect((finalRow["updated_date"] as Int64?) == 7_011)
    }

    @Test
    func a08SerialCollectionRetriesRemainIdempotentWithoutCreatingTombstones() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let collectionID: Int64 = 113_100
        let bookID: Int64 = 113_001

        try await harness.write { db in
            try Self.insertBook(db, id: bookID, name: "书单串行幂等书", order: 1)
            try Self.insertCollection(db, id: collectionID, title: "书单串行幂等")
        }

        try await harness.bookRepository.addBooks(
            [bookID, bookID],
            toCollection: collectionID
        )
        try await harness.bookRepository.addBooks(
            [bookID],
            toCollection: collectionID
        )

        let rows = try await harness.read { db in
            // SQL 目的：读取串行重复加入后的全部业务键关系，包含潜在 tombstone。
            // 涉及表：collection_book；关键过滤：collection_id/book_id 精确匹配，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：证明 Repository 串行重试只保留一条有效关系。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT is_deleted
                    FROM collection_book
                    WHERE collection_id = ?
                      AND book_id = ?
                    ORDER BY id
                    """,
                arguments: [collectionID, bookID]
            )
        }
        #expect(rows.count == 1)
        let relation = try #require(rows.first)
        #expect((relation["is_deleted"] as Int64?) == 0)
    }
}

@MainActor
extension BookAlignmentRepositorySafetyContractTests {
    @Test
    func a03SourceDeletionPhysicallyCommitsOnSuccessAndFullyRollsBackOnLateFailure() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let successSourceID: Int64 = 107_100
        let failingSourceID: Int64 = 107_101
        let successBookA: Int64 = 107_001
        let successBookB: Int64 = 107_002
        let failingBookA: Int64 = 107_003
        let failingBookB: Int64 = 107_004

        try await harness.write { db in
            try Self.insertSource(db, id: successSourceID, name: "成功删除来源", order: 100)
            try Self.insertSource(db, id: failingSourceID, name: "晚失败来源", order: 101)
            try Self.insertBook(db, id: successBookA, name: "成功迁移一", order: 1, sourceID: successSourceID, updatedDate: 3_001)
            try Self.insertBook(db, id: successBookB, name: "成功迁移二", order: 2, sourceID: successSourceID, updatedDate: 3_002)
            try Self.insertBook(db, id: failingBookA, name: "失败回滚一", order: 3, sourceID: failingSourceID, updatedDate: 3_003)
            try Self.insertBook(db, id: failingBookB, name: "失败回滚二", order: 4, sourceID: failingSourceID, updatedDate: 3_004)
        }

        let repository = SourceManagementRepository(
            databaseManager: DatabaseManager(database: harness.database)
        )
        try await repository.deleteSources(sourceIDs: [successSourceID])

        let successState = try await harness.read { db in
            // SQL 目的：核对成功删来源后的来源物理行与两本书引用。
            // 涉及表：source、book；关键过滤：成功来源及其两本合成书。
            // 时间字段：读取 book.updated_date，证明同一删除命令使用一个时间点；返回用途：锁定纠错后的来源迁移语义。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM source WHERE id = ?) AS source_count,
                        (SELECT COUNT(*) FROM book WHERE id IN (?, ?) AND source_id = 1) AS fallback_count,
                        (SELECT MIN(updated_date) FROM book WHERE id IN (?, ?)) AS updated_min,
                        (SELECT MAX(updated_date) FROM book WHERE id IN (?, ?)) AS updated_max
                    """,
                arguments: [
                    successSourceID,
                    successBookA, successBookB,
                    successBookA, successBookB,
                    successBookA, successBookB
                ]
            )
        }
        let successRow = try #require(successState)
        #expect((successRow["source_count"] as Int?) == 0)
        #expect((successRow["fallback_count"] as Int?) == 2)
        let updatedMin = try #require(successRow["updated_min"] as Int64?)
        let updatedMax = try #require(successRow["updated_max"] as Int64?)
        #expect(updatedMin > 3_002)
        #expect(updatedMin == updatedMax)

        try await harness.write { db in
            // SQL 目的：在失败来源主记录物理删除处中止，发生在书籍引用迁移之后。
            // 涉及表：source；关键过滤：OLD.id 精确命中失败来源。
            // 时间字段：不参与；副作用用途：验证引用迁移与来源删除共享同一事务。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_source_delete
                    BEFORE DELETE ON source
                    WHEN OLD.id = \(failingSourceID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced source delete failure');
                    END
                    """
            )
        }

        await #expect(throws: (any Error).self) {
            try await repository.deleteSources(sourceIDs: [failingSourceID])
        }

        let failureState = try await harness.read { db in
            // SQL 目的：核对晚失败后来源与两本书引用仍完整保持 S2。
            // 涉及表：source、book；关键过滤：失败来源及其两本合成书。
            // 时间字段：updated_date 必须保持原值；返回用途：排除引用迁移的部分提交。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM source WHERE id = ? AND is_deleted = 0) AS source_count,
                        (SELECT COUNT(*) FROM book WHERE id IN (?, ?) AND source_id = ?) AS retained_count,
                        (SELECT SUM(updated_date) FROM book WHERE id IN (?, ?)) AS updated_sum
                    """,
                arguments: [
                    failingSourceID,
                    failingBookA, failingBookB, failingSourceID,
                    failingBookA, failingBookB
                ]
            )
        }
        let failureRow = try #require(failureState)
        #expect((failureRow["source_count"] as Int?) == 1)
        #expect((failureRow["retained_count"] as Int?) == 2)
        #expect((failureRow["updated_sum"] as Int64?) == 6_007)
    }

    @Test
    func a03StatusAndRatingRollBackBooksHistoryAndAnnualRelationsOnSecondBookFailure() async throws {
        let harness = try BookAlignmentSafetyHarness.make()
        defer { harness.cleanup() }
        let firstBookID: Int64 = 108_001
        let secondBookID: Int64 = 108_002
        let thirdBookID: Int64 = 108_003
        let changedAt: Int64 = 1_700_000_200_000

        try await harness.write { db in
            try Self.insertBook(db, id: firstBookID, name: "状态晚失败一", order: 1, readStatusID: 2, score: 11, updatedDate: 4_001)
            try Self.insertBook(db, id: secondBookID, name: "状态晚失败二", order: 2, readStatusID: 2, score: 12, updatedDate: 4_002)
            try Self.insertBook(db, id: thirdBookID, name: "状态晚失败三", order: 3, readStatusID: 2, score: 13, updatedDate: 4_003)

            // SQL 目的：在第二本已写状态、历史与读完位置后，于评分 UPDATE 处制造晚失败。
            // 涉及表：book；关键过滤：OLD.id 精确命中第二本且 NEW.score 为目标评分。
            // 时间字段：不参与 trigger；副作用用途：验证书、历史和年度书单副作用共同回滚。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_rating_update
                    BEFORE UPDATE OF score ON book
                    WHEN OLD.id = \(secondBookID)
                     AND NEW.score = 47
                    BEGIN
                        SELECT RAISE(ABORT, 'forced second rating failure');
                    END
                    """
            )
        }
        let annualCountBefore = try await harness.annualCollectionCount()

        await #expect(throws: (any Error).self) {
            try await harness.bookRepository.batchSetBookReadStatus(
                bookIDs: [firstBookID, secondBookID, thirdBookID],
                input: BookshelfBatchReadStatusInput(
                    statusID: BookEntryReadingStatus.finished.rawValue,
                    changedAt: changedAt,
                    ratingScore: 47
                )
            )
        }

        let rows = try await harness.read { db in
            // SQL 目的：读取失败后三本书的当前状态、评分、进度和更新时间。
            // 涉及表：book；关键过滤：三个合成 book id。
            // 时间字段：read_status_changed_date/updated_date 均须保持 S2；返回用途：排除第一本和第二本前缀写入。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, read_status_id, read_status_changed_date, score,
                           current_position_unit, read_position, updated_date
                    FROM book
                    WHERE id IN (?, ?, ?)
                    ORDER BY id
                    """,
                arguments: [firstBookID, secondBookID, thirdBookID]
            )
        }
        #expect(rows.map { $0["read_status_id"] as Int64 } == [2, 2, 2])
        #expect(rows.map { $0["read_status_changed_date"] as Int64 } == [0, 0, 0])
        #expect(rows.map { $0["score"] as Int64 } == [11, 12, 13])
        #expect(rows.map { $0["read_position"] as Double } == [0, 0, 0])
        #expect(rows.map { $0["updated_date"] as Int64 } == [4_001, 4_002, 4_003])
        #expect(try await harness.statusHistoryCount(bookIDs: [firstBookID, secondBookID, thirdBookID]) == 0)
        #expect(try await harness.collectionRelationCount(bookIDs: [firstBookID, secondBookID, thirdBookID]) == 0)
        #expect(try await harness.annualCollectionCount() == annualCountBefore)
    }
}
