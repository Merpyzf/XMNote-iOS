import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct DesktopWebSourceRepositoryTests {
    @Test
    func listDetailVisibilityAndBookCountsMatchAndroid() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebCatalogRepository(database: database)
        try seedSource(database, id: 101, name: " 可见 ", order: 50, isHidden: false)
        try seedSource(database, id: 102, name: "隐藏", order: 51, isHidden: true)
        try seedBook(database, id: 201, sourceID: 101, isDeleted: false)
        try seedBook(database, id: 202, sourceID: 101, isDeleted: true)

        let visible = try await repository.sources(showAll: false)
        #expect(visible.contains { $0.id == 101 && $0.bookCount == 1 && !$0.isDefault })
        #expect(!visible.contains { $0.id == 102 })

        let all = try await repository.sources(showAll: true)
        #expect(all.contains { $0.id == 102 && $0.isHidden })
        let detail = try await repository.source(id: 101)
        #expect(detail.name == " 可见 ")
        #expect(detail.order == 50)
        #expect(detail.bookCount == 1)
        let readest = try await repository.source(id: 28)
        #expect(readest.isDefault)
    }

    @Test
    func createSourceTrimsValidatesAndUsesAndroidDefaults() async throws {
        let database = try AppDatabase.empty()
        let clock = TestMillisClock(start: 7_000)
        let repository = DesktopWebCatalogRepository(database: database, currentTimeMillis: clock.now)

        let created = try await repository.createSource(name: "  Calibre  ")
        #expect(created.name == "Calibre")
        #expect(created.order == 28)
        #expect(!created.isHidden)
        #expect(!created.isDefault)
        #expect(created.createdTime == 7_000)
        #expect(created.updatedTime == 0)

        let createdID = created.id
        let stored = try await database.dbPool.read { db in
            try SourceRecord.fetchOne(db, key: createdID)
        }
        #expect(stored?.bookshelfOrder == -1)
        #expect(stored?.lastSyncDate == 0)

        await expectCatalogError(.invalidArgument("来源名称不能为空")) {
            _ = try await repository.createSource(name: "  \n ")
        }
        await expectCatalogError(.duplicate("来源名称已存在: Calibre")) {
            _ = try await repository.createSource(name: "Calibre")
        }
    }

    @Test
    func updateSourceSupportsPartialFieldsAndAndroidErrors() async throws {
        let database = try AppDatabase.empty()
        let clock = TestMillisClock(start: 8_000)
        let repository = DesktopWebCatalogRepository(database: database, currentTimeMillis: clock.now)
        try seedSource(database, id: 101, name: "Old", order: 50, isHidden: false)
        try seedSource(database, id: 102, name: "Duplicate", order: 51, isHidden: false)

        let updated = try await repository.updateSource(id: 101, name: "  New  ", isHidden: true)
        #expect(updated.name == "New")
        #expect(updated.isHidden)
        #expect(updated.updatedTime == 8_001)

        let unchanged = try await repository.updateSource(id: 101, name: nil, isHidden: nil)
        #expect(unchanged == updated)

        await expectCatalogError(.duplicate("来源名称已存在: Duplicate")) {
            _ = try await repository.updateSource(id: 101, name: "Duplicate", isHidden: nil)
        }
        await expectCatalogError(.invalidArgument("来源名称不能为空")) {
            _ = try await repository.updateSource(id: 101, name: " ", isHidden: nil)
        }
        await expectCatalogError(.notFound("来源不存在: 999")) {
            _ = try await repository.updateSource(id: 999, name: "x", isHidden: nil)
        }
    }

    @Test
    func deleteSourceRejectsPresetReassignsOnlyActiveBooksAndSoftDeletes() async throws {
        let database = try AppDatabase.empty()
        let clock = TestMillisClock(start: 9_000)
        let repository = DesktopWebCatalogRepository(database: database, currentTimeMillis: clock.now)
        try seedSource(database, id: 101, name: "Custom", order: 50, isHidden: false)
        try seedBook(database, id: 201, sourceID: 101, isDeleted: false)
        try seedBook(database, id: 202, sourceID: 101, isDeleted: true)

        await expectCatalogError(.invalidArgument("预置来源不可删除，仅可隐藏")) {
            try await repository.deleteSource(id: 28)
        }
        try await repository.deleteSource(id: 101)

        let state = try await database.dbPool.read { db -> (Int64, Int64, Int64, Int64) in
            let activeSource = try Int64.fetchOne(db, sql: "SELECT source_id FROM book WHERE id = 201") ?? -1
            let deletedSource = try Int64.fetchOne(db, sql: "SELECT source_id FROM book WHERE id = 202") ?? -1
            let sourceDeleted = try Int64.fetchOne(db, sql: "SELECT is_deleted FROM source WHERE id = 101") ?? -1
            let sourceUpdated = try Int64.fetchOne(db, sql: "SELECT updated_date FROM source WHERE id = 101") ?? -1
            return (activeSource, deletedSource, sourceDeleted, sourceUpdated)
        }
        #expect(state.0 == 1)
        #expect(state.1 == 101)
        #expect(state.2 == 1)
        #expect(state.3 == 9_001)
        await expectCatalogError(.notFound("来源不存在: 101")) {
            _ = try await repository.source(id: 101)
        }
    }

    @Test
    func reorderSourcesKeepsDuplicatesMissingIDsAndPerItemTimestamps() async throws {
        let database = try AppDatabase.empty()
        let clock = TestMillisClock(start: 10_000)
        let repository = DesktopWebCatalogRepository(database: database, currentTimeMillis: clock.now)
        try seedSource(database, id: 101, name: "A", order: 50, isHidden: false)
        try seedSource(database, id: 102, name: "B", order: 51, isHidden: false)

        try await repository.reorderSources(ids: [101, 999, 102, 101])
        let rows = try await database.dbPool.read { db -> [(Int64, Int64, Int64)] in
            try Row.fetchAll(
                db,
                sql: "SELECT id, source_order, updated_date FROM source WHERE id IN (101, 102) ORDER BY id"
            ).map { row in
                (row["id"], row["source_order"], row["updated_date"])
            }
        }
        #expect(rows.count == 2)
        #expect(rows[0].1 == 3)
        #expect(rows[0].2 == 10_003)
        #expect(rows[1].1 == 2)
        #expect(rows[1].2 == 10_002)

        await expectCatalogError(.invalidArgument("排序列表不能为空")) {
            try await repository.reorderSources(ids: [])
        }
    }
}

@MainActor
struct DesktopWebTagRepositoryTests {
    @Test
    func listTagsMatchesTypeCountsTrimAndCrossOwnerBehavior() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebCatalogRepository(database: database)
        try seedUser(database, id: 2)
        try seedTag(database, id: 101, userID: 1, name: "  Note  ", type: 1, order: 2)
        try seedTag(database, id: 102, userID: 2, name: "  Book  ", type: 2, order: 1)
        let relations = try seedRelations(database, tagID: 101, bookID: 201, noteID: 301)
        try seedTagBook(database, id: 402, tagID: 101, bookID: relations.bookID, isDeleted: true)
        try seedTagNote(database, id: 502, tagID: 101, noteID: relations.noteID, isDeleted: true)

        let all = try await repository.tags(type: 0)
        #expect(all.map(\.id).contains(102))
        let noteTag = try #require(all.first { $0.id == 101 })
        #expect(noteTag.name == "Note")
        #expect(noteTag.noteCount == 1)
        #expect(noteTag.bookCount == 1)

        let books = try await repository.tags(type: 2)
        #expect(books.map(\.id).contains(102))
        #expect(!books.map(\.id).contains(101))
    }

    @Test
    func createTagValidatesTypeUsesCrossOwnerMaxAndHardcodesUserOne() async throws {
        let database = try AppDatabase.empty()
        let clock = TestMillisClock(start: 11_000)
        let repository = DesktopWebCatalogRepository(database: database, currentTimeMillis: clock.now)
        try seedUser(database, id: 2)
        try seedTag(database, id: 101, userID: 2, name: "Other", type: 2, order: 9)

        let created = try await repository.createTag(name: "  Swift  ", type: 2)
        #expect(created.name == "Swift")
        #expect(created.type == 2)
        #expect(created.order == 10)
        let createdID = created.id
        let stored = try await database.dbPool.read { db in
            try TagRecord.fetchOne(db, key: createdID)
        }
        #expect(stored?.userId == 1)
        #expect(stored?.createdDate == 11_000)
        #expect(stored?.updatedDate == 0)

        await expectCatalogError(.invalidArgument("标签名称不能为空")) {
            _ = try await repository.createTag(name: " ", type: 1)
        }
        await expectCatalogError(.invalidArgument("标签类型无效")) {
            _ = try await repository.createTag(name: "x", type: 3)
        }
        await expectCatalogError(.duplicate("标签名称已存在: Other")) {
            _ = try await repository.createTag(name: "Other", type: 2)
        }
    }

    @Test
    func updateTagCanMutateOtherOwnerAndUsesCrossOwnerDuplicateCheck() async throws {
        let database = try AppDatabase.empty()
        let clock = TestMillisClock(start: 12_000)
        let repository = DesktopWebCatalogRepository(database: database, currentTimeMillis: clock.now)
        try seedUser(database, id: 2)
        try seedTag(database, id: 101, userID: 2, name: "Other", type: 2, order: 7)
        try seedTag(database, id: 102, userID: 1, name: "Taken", type: 2, order: 8)

        let result = try await repository.updateTag(id: 101, name: "  Renamed  ")
        #expect(result == DesktopWebTagMutationSnapshot(id: 101, name: "Renamed", type: 2, order: 7))
        let stored = try await database.dbPool.read { db in
            try TagRecord.fetchOne(db, key: 101)
        }
        #expect(stored?.userId == 2)
        #expect(stored?.updatedDate == 12_000)

        await expectCatalogError(.duplicate("标签名称已存在: Taken")) {
            _ = try await repository.updateTag(id: 101, name: "Taken")
        }
        await expectCatalogError(.notFound("标签不存在: 999")) {
            _ = try await repository.updateTag(id: 999, name: "x")
        }
    }

    @Test
    func deleteTagSoftDeletesMainAndItsTypedRelationsInOneTransaction() async throws {
        let database = try AppDatabase.empty()
        let clock = TestMillisClock(start: 13_000)
        let repository = DesktopWebCatalogRepository(database: database, currentTimeMillis: clock.now)
        try seedTag(database, id: 101, userID: 1, name: "Note", type: 1, order: 1)
        _ = try seedRelations(database, tagID: 101, bookID: 201, noteID: 301)

        try await repository.deleteTag(id: 101)
        let state = try await database.dbPool.read { db -> (Int64, Int64, Int64, Int64, Int64, Int64) in
            let isDeleted = try Int64.fetchOne(db, sql: "SELECT is_deleted FROM tag WHERE id = 101") ?? -1
            let updated = try Int64.fetchOne(db, sql: "SELECT updated_date FROM tag WHERE id = 101") ?? -1
            let noteDeleted = try Int64.fetchOne(
                db,
                sql: "SELECT is_deleted FROM tag_note WHERE tag_id = 101"
            ) ?? -1
            let noteUpdated = try Int64.fetchOne(
                db,
                sql: "SELECT updated_date FROM tag_note WHERE tag_id = 101"
            ) ?? -1
            let bookRelations = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_book WHERE tag_id = 101") ?? -1
            let activeBookRelations = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM tag_book WHERE tag_id = 101 AND is_deleted = 0"
            ) ?? -1
            return (isDeleted, updated, noteDeleted, noteUpdated, bookRelations, activeBookRelations)
        }
        #expect(state == (1, 13_000, 1, 13_000, 1, 1))

        await expectCatalogError(.notFound("标签不存在: 101")) {
            try await repository.deleteTag(id: 101)
        }
    }

    @Test
    func reorderTagsCrossesOwnerAndTypeUsesOneTimestampAndLastDuplicateWins() async throws {
        let database = try AppDatabase.empty()
        let clock = TestMillisClock(start: 14_000)
        let repository = DesktopWebCatalogRepository(database: database, currentTimeMillis: clock.now)
        try seedUser(database, id: 2)
        try seedTag(database, id: 101, userID: 1, name: "A", type: 1, order: 10)
        try seedTag(database, id: 102, userID: 2, name: "B", type: 2, order: 11)

        try await repository.reorderTags(ids: [101, 999, 102, 101])
        let rows = try await database.dbPool.read { db -> [(Int64, Int64, Int64)] in
            try Row.fetchAll(
                db,
                sql: "SELECT id, tag_order, updated_date FROM tag WHERE id IN (101, 102) ORDER BY id"
            ).map { row in
                (row["id"], row["tag_order"], row["updated_date"])
            }
        }
        #expect(rows[0].1 == 3)
        #expect(rows[0].2 == 14_000)
        #expect(rows[1].1 == 2)
        #expect(rows[1].2 == 14_000)

        await expectCatalogError(.invalidArgument("排序列表不能为空")) {
            try await repository.reorderTags(ids: [])
        }
    }
}

private final class TestMillisClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(start: Int64) {
        value = start
    }

    func now() -> Int64 {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

@MainActor
private func expectCatalogError(
    _ expected: DesktopWebCatalogRepositoryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("预期抛出 \(expected)，实际成功")
    } catch let error as DesktopWebCatalogRepositoryError {
        #expect(error == expected)
    } catch {
        Issue.record("错误类型不匹配: \(error)")
    }
}

private func seedSource(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    order: Int64,
    isHidden: Bool
) throws {
    try database.dbPool.write { db in
        var record = SourceRecord(
            id: id,
            name: name,
            sourceOrder: order,
            bookshelfOrder: -1,
            isHide: isHidden ? 1 : 0,
            createdDate: 100,
            updatedDate: 200,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func seedUser(_ database: AppDatabase, id: Int64) throws {
    try database.dbPool.write { db in
        var record = UserRecord(
            id: id,
            userId: id,
            nickName: "User \(id)",
            gender: 0,
            phone: nil,
            createdDate: 0,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func seedBook(
    _ database: AppDatabase,
    id: Int64,
    sourceID: Int64,
    isDeleted: Bool
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: "Book \(id)",
            sourceId: sourceID,
            readStatusId: 1,
            isDeleted: isDeleted ? 1 : 0
        )
        try record.insert(db)
    }
}

private func seedTag(
    _ database: AppDatabase,
    id: Int64,
    userID: Int64,
    name: String,
    type: Int64,
    order: Int64
) throws {
    try database.dbPool.write { db in
        var record = TagRecord(
            id: id,
            userId: userID,
            name: name,
            color: 0,
            tagOrder: order,
            type: type,
            createdDate: 100,
            updatedDate: 200,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func seedRelations(
    _ database: AppDatabase,
    tagID: Int64,
    bookID: Int64,
    noteID: Int64
) throws -> (bookID: Int64, noteID: Int64) {
    try seedBook(database, id: bookID, sourceID: 1, isDeleted: false)
    try database.dbPool.write { db in
        var note = NoteRecord(
            id: noteID,
            bookId: bookID,
            chapterId: 0,
            content: "fixture"
        )
        try note.insert(db)
    }
    try seedTagBook(database, id: 401, tagID: tagID, bookID: bookID, isDeleted: false)
    try seedTagNote(database, id: 501, tagID: tagID, noteID: noteID, isDeleted: false)
    return (bookID, noteID)
}

private func seedTagBook(
    _ database: AppDatabase,
    id: Int64,
    tagID: Int64,
    bookID: Int64,
    isDeleted: Bool
) throws {
    try database.dbPool.write { db in
        var record = TagBookRecord(
            id: id,
            bookId: bookID,
            tagId: tagID,
            isDeleted: isDeleted ? 1 : 0
        )
        try record.insert(db)
    }
}

private func seedTagNote(
    _ database: AppDatabase,
    id: Int64,
    tagID: Int64,
    noteID: Int64,
    isDeleted: Bool
) throws {
    try database.dbPool.write { db in
        var record = TagNoteRecord(
            id: id,
            tagId: tagID,
            noteId: noteID,
            isDeleted: isDeleted ? 1 : 0
        )
        try record.insert(db)
    }
}
