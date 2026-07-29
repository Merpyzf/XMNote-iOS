/**
 * [INPUT]: 依赖 AppDatabase.empty、GRDB Record 与 DesktopWebGroupRepository 可注入时钟
 * [OUTPUT]: 验证 8 条 Group API 对应的查询、排序、写入、软删除和异常边界
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android Web 分组路径的可观察数据库语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import GRDB
import Testing
import XMNoteWeb
@testable import xmnote

@MainActor
struct DesktopWebGroupRepositoryTests {
    @Test
    func groupListOrdersCountsPagesAndCrossesOwnersLikeAndroid() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebGroupRepository(database: database)
        try groupSeedUser(database, id: 2)
        try groupSeedGroup(database, id: 101, userID: 1, name: "A", order: 5)
        try groupSeedGroup(database, id: 102, userID: 2, name: "B", order: 1, pinned: 1, pinOrder: 2)
        try groupSeedBook(database, id: 201, order: 1)
        try groupSeedBook(database, id: 202, order: 2)
        try groupSeedRelation(database, id: 301, groupID: 101, bookID: 201, createdDate: 10)
        try groupSeedRelation(database, id: 302, groupID: 102, bookID: 201, createdDate: 20)
        try groupSeedRelation(database, id: 303, groupID: 102, bookID: 202, createdDate: 30)

        let firstPage = try await repository.groups(page: 1, pageSize: 1)
        #expect(firstPage.items.map(\.id) == [102])
        #expect(firstPage.items.first?.bookCount == 1)
        #expect(firstPage.total == 2)
        #expect(firstPage.totalPages == 2)

        let secondPage = try await repository.groups(page: 2, pageSize: 1)
        #expect(secondPage.items.map(\.id) == [101])
        #expect(secondPage.items.first?.bookCount == 1)
    }

    @Test
    func createGroupTrimsAllowsDuplicatesAndHardcodesUserOne() async throws {
        let database = try AppDatabase.empty()
        let clock = GroupMillisClock(start: 1_000)
        let repository = DesktopWebGroupRepository(database: database, currentTimeMillis: clock.now)
        try groupSeedUser(database, id: 2)
        try groupSeedGroup(database, id: 101, userID: 2, name: "Duplicate", order: -3)
        try groupSeedBook(database, id: 201, order: -5)

        let created = try await repository.createGroup(name: "  Duplicate  ")
        #expect(created.name == "Duplicate")
        #expect(created.order == -6)
        #expect(created.createdTime == 1_000)
        let createdID = created.id
        let stored = try await database.dbPool.read { db in
            try GroupRecord.fetchOne(db, key: createdID)
        }
        #expect(stored?.userId == 1)
        #expect(stored?.updatedDate == 0)
        #expect(stored?.lastSyncDate == 0)

        await expectGroupCatalogError(.invalidArgument("分组名称不能为空")) {
            _ = try await repository.createGroup(name: " \n ")
        }
    }

    @Test
    func updateGroupAllowsDuplicateNameAndMutatesOtherOwner() async throws {
        let database = try AppDatabase.empty()
        let clock = GroupMillisClock(start: 2_000)
        let repository = DesktopWebGroupRepository(database: database, currentTimeMillis: clock.now)
        try groupSeedUser(database, id: 2)
        try groupSeedGroup(database, id: 101, userID: 2, name: "Other", order: 4)
        try groupSeedGroup(database, id: 102, userID: 1, name: "Taken", order: 5)

        let updated = try await repository.updateGroup(id: 101, name: "  Taken  ")
        #expect(updated.name == "Taken")
        let stored = try await database.dbPool.read { db in
            try GroupRecord.fetchOne(db, key: 101)
        }
        #expect(stored?.userId == 2)
        #expect(stored?.updatedDate == 2_000)

        await expectGroupCatalogError(.notFound("分组不存在: 999")) {
            _ = try await repository.updateGroup(id: 999, name: "x")
        }
    }

    @Test
    func groupPinIsIdempotentAndUsesGroupOnlyCrossOwnerMaximum() async throws {
        let database = try AppDatabase.empty()
        let clock = GroupMillisClock(start: 3_000)
        let repository = DesktopWebGroupRepository(database: database, currentTimeMillis: clock.now)
        try groupSeedUser(database, id: 2)
        try groupSeedGroup(database, id: 101, userID: 1, name: "A", order: 1)
        try groupSeedGroup(database, id: 102, userID: 2, name: "B", order: 2, pinned: 1, pinOrder: 9)
        try groupSeedBook(database, id: 201, order: 0, pinned: 1, pinOrder: 99)

        let pinned = try await repository.updateGroupPin(id: 101, pinned: true)
        #expect(pinned.isPinned)
        #expect(pinned.pinOrder == 10)
        let unchanged = try await repository.updateGroupPin(id: 101, pinned: true)
        #expect(unchanged == pinned)
        let updatedDate = try await database.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT updated_date FROM `group` WHERE id = 101")
        }
        #expect(updatedDate == 3_000)

        try groupSeedGroup(
            database,
            id: 103,
            userID: 1,
            name: "Max",
            order: 3,
            pinned: 1,
            pinOrder: Int64(Int32.max)
        )
        try groupSeedGroup(database, id: 104, userID: 1, name: "Wrap", order: 4)
        let wrapped = try await repository.updateGroupPin(id: 104, pinned: true)
        #expect(wrapped.pinOrder == Int(Int32.min))
        let wrappedUpdatedDate = try await database.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT updated_date FROM `group` WHERE id = 104")
        }
        #expect(wrappedUpdatedDate == 3_001)
    }

    @Test
    func reorderGroupsKeepsDuplicatesMissingIDsAndOneTimestamp() async throws {
        let database = try AppDatabase.empty()
        let clock = GroupMillisClock(start: 4_000)
        let repository = DesktopWebGroupRepository(database: database, currentTimeMillis: clock.now)
        try groupSeedGroup(database, id: 101, userID: 1, name: "A", order: 10)
        try groupSeedGroup(database, id: 102, userID: 1, name: "B", order: 11)

        try await repository.reorderGroups(ids: [101, 999, 102, 101])
        let values = try await database.dbPool.read { db -> [(Int64, Int64, Int64)] in
            try Row.fetchAll(
                db,
                sql: "SELECT id, group_order, updated_date FROM `group` WHERE id IN (101, 102) ORDER BY id"
            ).map { ($0["id"], $0["group_order"], $0["updated_date"]) }
        }
        #expect(values[0] == (101, 3, 4_000))
        #expect(values[1] == (102, 2, 4_000))
        await expectGroupCatalogError(.invalidArgument("排序列表不能为空")) {
            try await repository.reorderGroups(ids: [])
        }
    }

    @Test
    func reorderGroupBooksNormalizesValidatesAndWritesAtomically() async throws {
        let database = try AppDatabase.empty()
        let clock = GroupMillisClock(start: 5_000)
        let repository = DesktopWebGroupRepository(database: database, currentTimeMillis: clock.now)
        try groupSeedGroup(database, id: 101, userID: 1, name: "A", order: 1)
        try groupSeedBook(database, id: 201, order: 8)
        try groupSeedBook(database, id: 202, order: 9)
        try groupSeedBook(database, id: 203, order: 10)
        try groupSeedRelation(database, id: 301, groupID: 101, bookID: 201, createdDate: 10)
        try groupSeedRelation(database, id: 302, groupID: 101, bookID: 202, createdDate: 11)

        try await repository.reorderGroupBooks(groupID: 101, ids: [202, 202, -1, 201])
        let values = try await database.dbPool.read { db -> [(Int64, Int64, Int64)] in
            try Row.fetchAll(
                db,
                sql: "SELECT id, book_order, updated_date FROM book WHERE id IN (201, 202) ORDER BY id"
            ).map { ($0["id"], $0["book_order"], $0["updated_date"]) }
        }
        #expect(values[0] == (201, 1, 5_000))
        #expect(values[1] == (202, 0, 5_000))

        try await repository.reorderGroupBooks(groupID: 999, ids: [])
        await expectGroupCatalogError(.invalidArgument("分组不存在")) {
            try await repository.reorderGroupBooks(groupID: 0, ids: [])
        }
        await expectGroupCatalogError(.invalidArgument("部分书籍不属于当前分组")) {
            try await repository.reorderGroupBooks(groupID: 101, ids: [203])
        }
    }

    @Test
    func deleteGroupMovesBooksInAndroidOrderAndSoftDeletesAllRelations() async throws {
        let database = try AppDatabase.empty()
        let clock = GroupMillisClock(start: 6_000)
        let repository = DesktopWebGroupRepository(database: database, currentTimeMillis: clock.now)
        try groupSeedGroup(database, id: 101, userID: 1, name: "Delete", order: 10)
        try groupSeedGroup(database, id: 102, userID: 1, name: "Other", order: 20)
        try groupSeedBook(database, id: 201, order: 1, pinned: 1, pinOrder: 5)
        try groupSeedBook(database, id: 202, order: 4)
        try groupSeedBook(database, id: 203, order: 100)
        try groupSeedRelation(database, id: 301, groupID: 101, bookID: 201, createdDate: 10)
        try groupSeedRelation(database, id: 302, groupID: 101, bookID: 202, createdDate: 11)
        try groupSeedRelation(database, id: 303, groupID: 102, bookID: 201, createdDate: 12)

        try await repository.deleteGroup(id: 101, placeAtEnd: false)
        let state = try await database.dbPool.read { db -> (Int64, Int64, Int64, Int64, Int64) in
            let firstOrder = try Int64.fetchOne(db, sql: "SELECT book_order FROM book WHERE id = 201") ?? -99
            let secondOrder = try Int64.fetchOne(db, sql: "SELECT book_order FROM book WHERE id = 202") ?? -99
            let firstPinned = try Int64.fetchOne(db, sql: "SELECT pinned FROM book WHERE id = 201") ?? -99
            let activeRelations = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM group_book WHERE book_id IN (201, 202) AND is_deleted = 0") ?? -99
            let groupDeleted = try Int64.fetchOne(db, sql: "SELECT is_deleted FROM `group` WHERE id = 101") ?? -99
            return (firstOrder, secondOrder, firstPinned, activeRelations, groupDeleted)
        }
        #expect(state == (8, 9, 0, 0, 1))
        let timestamps = try await database.dbPool.read { db -> (Int64, Int64, Int64) in
            let group = try Int64.fetchOne(db, sql: "SELECT updated_date FROM `group` WHERE id = 101") ?? -1
            let first = try Int64.fetchOne(db, sql: "SELECT updated_date FROM book WHERE id = 201") ?? -1
            let second = try Int64.fetchOne(db, sql: "SELECT updated_date FROM book WHERE id = 202") ?? -1
            return (group, first, second)
        }
        #expect(timestamps == (6_000, 6_002, 6_001))
    }

    @Test
    func groupBooksReturnsFullAggregatesAndAndroidStableSort() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebGroupRepository(database: database)
        try groupSeedGroup(database, id: 101, userID: 1, name: "A", order: 1)
        try groupSeedBook(database, id: 201, name: "Pinned", order: 3, pinned: 1, pinOrder: 8)
        try groupSeedBook(
            database,
            id: 202,
            name: "  Notes  ",
            order: 1,
            score: 0,
            author: "  Author  ",
            readStatus: 3,
            readStatusChangedDate: 700,
            purchaseDate: 100,
            price: 12.5,
            wordCount: 1_000
        )
        try groupSeedBook(database, id: 203, name: "Rated", order: 2, score: 50, createdDate: 200)
        try groupSeedRelation(database, id: 301, groupID: 101, bookID: 201, createdDate: 10)
        try groupSeedRelation(database, id: 302, groupID: 101, bookID: 202, createdDate: 11)
        try groupSeedRelation(database, id: 303, groupID: 101, bookID: 203, createdDate: 12)
        try groupSeedTag(database, id: 401, name: "Tag")
        try groupSeedTagBook(database, id: 402, tagID: 401, bookID: 202)
        try groupSeedNote(database, id: 501, bookID: 202, createdDate: 600, updatedDate: 800)
        try groupSeedReadTime(database, id: 601, bookID: 202, seconds: 60)
        try groupSeedReadDone(database, id: 701, bookID: 202, changedDate: 900)

        let page = try await repository.booksInGroup(
            id: 101,
            page: 1,
            pageSize: 20,
            sortBy: "rating",
            sortOrder: "asc"
        )
        #expect(page.items.map(\.id) == [201, 203, 202])
        #expect(page.total == 3)
        let notes = try #require(page.items.first { $0.id == 202 })
        #expect(notes.name == "Notes")
        #expect(notes.author == "Author")
        #expect(notes.sourceName == "未知")
        #expect(notes.noteCount == 1)
        #expect(notes.totalReadingTime == 60)
        #expect(notes.readDoneCount == 1)
        #expect(notes.readDoneTime == 900)
        #expect(notes.groups == [DesktopWebNamedSnapshot(id: 101, name: "A")])
        #expect(notes.tags == [DesktopWebNamedSnapshot(id: 401, name: "Tag")])
        #expect(notes.purchaseDate == 100)
        #expect(notes.price == 12.5)
        #expect(notes.wordCount == 1_000)
        #expect(notes.lastModifiedTime == nil)

        let modified = try await repository.booksInGroup(
            id: 101,
            page: 1,
            pageSize: 20,
            sortBy: "modify_time",
            sortOrder: "desc"
        )
        #expect(modified.items.map(\.id) == [201, 202, 203])
        #expect(modified.items.first { $0.id == 202 }?.lastModifiedTime == 800)

        await expectGroupCatalogError(.invalidArgument("分组不存在")) {
            _ = try await repository.booksInGroup(
                id: 999,
                page: 1,
                pageSize: 20,
                sortBy: "custom",
                sortOrder: "desc"
            )
        }
    }

    @Test
    func invalidGroupsFailAndExtremePaginationRemainsOverflowSafe() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebGroupRepository(database: database)
        try groupSeedGroup(database, id: 101, userID: 1, name: "A", order: 1)
        for index in 1...5 {
            try groupSeedBook(
                database,
                id: Int64(200 + index),
                order: Int64(index)
            )
        }
        try groupSeedRelation(database, id: 301, groupID: 101, bookID: 201, createdDate: 10)
        try groupSeedRelation(database, id: 302, groupID: 101, bookID: 202, createdDate: 11)

        for invalidGroupID in [Int64(0), -1, 999] {
            await expectGroupCatalogError(.invalidArgument("分组不存在")) {
                _ = try await repository.booksInGroup(
                    id: invalidGroupID,
                    page: 1,
                    pageSize: 20,
                    sortBy: "custom",
                    sortOrder: "desc"
                )
            }
        }

        let extreme = try await repository.booksInGroup(
            id: 101,
            page: Int(Int32.max),
            pageSize: Int(Int32.max),
            sortBy: "custom",
            sortOrder: "desc"
        )
        #expect(extreme.total == 2)
        #expect(extreme.items.isEmpty)

        await expectGroupCatalogError(.invalidArgument("分组不存在")) {
            _ = try await repository.booksInGroup(
                id: 0,
                page: 3,
                pageSize: Int(Int32.max),
                sortBy: "custom",
                sortOrder: "desc"
            )
        }
    }

    @Test
    func adapterMapsGroupPageAndSignsRemoteCoverLikeAndroid() async throws {
        let suiteName = "DesktopWebGroupRepositoryTests.Adapter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = DesktopWebSettingsRepository(defaults: defaults)
        let database = try AppDatabase.empty()
        try groupSeedGroup(database, id: 101, userID: 1, name: "A", order: 1)
        let remoteCover = "https://example.com/cover.png"
        try groupSeedBook(database, id: 201, order: 1, cover: remoteCover)
        try groupSeedRelation(database, id: 301, groupID: 101, bookID: 201, createdDate: 10)
        let now: Int64 = 10_000
        let adapter = DesktopWebAPIAdapter(
            repository: settings,
            nativeActionBridge: DesktopWebNativeActionBridge(),
            isPremiumProvider: { true },
            currentTimeMillis: { now }
        )
        adapter.configure(database: database)

        await settings.setAccessAuthEnabled(false)
        let unsigned = try await adapter.booksInGroup(
            id: 101,
            page: 1,
            pageSize: 20,
            sortBy: "custom",
            sortOrder: "desc"
        )
        #expect(unsigned.pagination.total == 1)
        #expect(unsigned.items.first?.cover == "/api/v1/book-covers/proxy/201")

        try await settings.setAccessCode("abc12345")
        await settings.setAccessAuthEnabled(true)
        let signed = try await adapter.booksInGroup(
            id: 101,
            page: 1,
            pageSize: 20,
            sortBy: "custom",
            sortOrder: "desc"
        )
        let expires = now + 60 * 60 * 1_000
        let payload = "201|\(remoteCover)|\(expires)"
        let key = SymmetricKey(data: Data("abc12345".utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        #expect(
            signed.items.first?.cover
                == "/api/v1/book-covers/proxy/201?expires=\(expires)&sig=\(signature)"
        )

        let groups = try await adapter.groups(page: 1, pageSize: 20)
        #expect(groups.items == [
            DesktopWebGroup(
                id: 101,
                name: "A",
                isPinned: false,
                pinOrder: 0,
                order: 1,
                bookCount: 1,
                createdTime: 100
            )
        ])
    }
}

private final class GroupMillisClock: @unchecked Sendable {
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
private func expectGroupCatalogError(
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

private func groupSeedUser(_ database: AppDatabase, id: Int64) throws {
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

private func groupSeedGroup(
    _ database: AppDatabase,
    id: Int64,
    userID: Int64,
    name: String,
    order: Int64,
    pinned: Int64 = 0,
    pinOrder: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = GroupRecord(
            id: id,
            userId: userID,
            name: name,
            groupOrder: order,
            pinned: pinned,
            pinOrder: pinOrder,
            createdDate: 100,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func groupSeedBook(
    _ database: AppDatabase,
    id: Int64,
    name: String? = nil,
    order: Int64,
    pinned: Int64 = 0,
    pinOrder: Int64 = 0,
    score: Int64 = 0,
    author: String = "",
    readStatus: Int64 = 1,
    readStatusChangedDate: Int64 = 0,
    purchaseDate: Int64 = 0,
    price: Double = 0,
    wordCount: Int64? = nil,
    createdDate: Int64 = 100,
    cover: String = ""
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: name ?? "Book \(id)",
            cover: cover,
            author: author,
            sourceId: 1,
            purchaseDate: purchaseDate,
            price: price,
            bookOrder: order,
            pinned: pinned,
            pinOrder: pinOrder,
            readStatusId: readStatus,
            readStatusChangedDate: readStatusChangedDate,
            score: score,
            wordCount: wordCount,
            createdDate: createdDate,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func groupSeedRelation(
    _ database: AppDatabase,
    id: Int64,
    groupID: Int64,
    bookID: Int64,
    createdDate: Int64
) throws {
    try database.dbPool.write { db in
        var record = GroupBookRecord(
            id: id,
            groupId: groupID,
            bookId: bookID,
            createdDate: createdDate,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func groupSeedTag(_ database: AppDatabase, id: Int64, name: String) throws {
    try database.dbPool.write { db in
        var record = TagRecord(id: id, userId: 1, name: name, color: 0, tagOrder: 1, type: 2)
        try record.insert(db)
    }
}

private func groupSeedTagBook(
    _ database: AppDatabase,
    id: Int64,
    tagID: Int64,
    bookID: Int64
) throws {
    try database.dbPool.write { db in
        var record = TagBookRecord(id: id, bookId: bookID, tagId: tagID)
        try record.insert(db)
    }
}

private func groupSeedNote(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    createdDate: Int64,
    updatedDate: Int64
) throws {
    try database.dbPool.write { db in
        var record = NoteRecord(
            id: id,
            bookId: bookID,
            chapterId: 0,
            content: "fixture",
            createdDate: createdDate,
            updatedDate: updatedDate
        )
        try record.insert(db)
    }
}

private func groupSeedReadTime(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    seconds: Int64
) throws {
    try database.dbPool.write { db in
        var record = ReadTimeRecordRecord(
            id: id,
            bookId: bookID,
            elapsedSeconds: seconds,
            status: 3,
            createdDate: 500
        )
        try record.insert(db)
    }
}

private func groupSeedReadDone(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    changedDate: Int64
) throws {
    try database.dbPool.write { db in
        var record = BookReadStatusRecordRecord(
            id: id,
            bookId: bookID,
            readStatusId: 3,
            changedDate: changedDate,
            createdDate: changedDate
        )
        try record.insert(db)
    }
}
