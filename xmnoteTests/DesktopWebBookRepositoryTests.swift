/**
 * [INPUT]: 依赖 AppDatabase.empty、GRDB Record、DesktopWebBookRepository 与 DesktopWebAPIAdapter
 * [OUTPUT]: 验证 19 条 Book 与 7 条 Bookshelf API 的查询、混排及写事务边界和 Adapter 映射
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android Web 书籍与书架当前批次的可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
import XMNoteWeb
@testable import xmnote

@MainActor
struct DesktopWebBookRepositoryTests {
    @Test
    func statsCountsUnknownStatusAcrossOwnersButExcludesDeletedAndPlaceholder() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedUser(database, id: 2)
        try bookSeedReadStatus(database, id: 99)
        try bookSeedBook(database, id: 101, readStatus: 1)
        try bookSeedBook(database, id: 102, readStatus: 2)
        try bookSeedBook(database, id: 103, readStatus: 2)
        try bookSeedBook(database, id: 104, readStatus: 3)
        try bookSeedBook(database, id: 105, readStatus: 4)
        try bookSeedBook(database, id: 106, readStatus: 5)
        try bookSeedBook(database, id: 107, userID: 2, readStatus: 99)
        try bookSeedBook(database, id: 108, readStatus: 2, isDeleted: 1)

        let stats = try await repository.stats()
        #expect(stats == DesktopWebBookStatsSnapshot(
            total: 7,
            reading: 2,
            want: 1,
            read: 1,
            dropped: 1,
            hold: 1
        ))
    }

    @Test
    func detailReturnsCrossOwnerFullProjectionAndRejectsDeletedOrMissing() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedUser(database, id: 2)
        try bookSeedBook(
            database,
            id: 201,
            userID: 2,
            name: "  Detail  ",
            author: "  Author  ",
            readStatus: 3,
            readStatusChangedDate: 700,
            updatedDate: 400
        )
        try bookSeedBook(database, id: 202, isDeleted: 1)
        try bookSeedNote(database, id: 301, bookID: 201, createdDate: 500, updatedDate: 800)

        let detail = try await repository.book(id: 201)
        #expect(detail.id == 201)
        #expect(detail.name == "Detail")
        #expect(detail.author == "Author")
        #expect(detail.sourceName == "未知")
        #expect(detail.noteCount == 1)
        #expect(detail.readDoneTime == 700)
        #expect(detail.lastModifiedTime == nil)

        await expectBookCatalogError(.notFound("书籍不存在: 202")) {
            _ = try await repository.book(id: 202)
        }
        await expectBookCatalogError(.notFound("书籍不存在: 999")) {
            _ = try await repository.book(id: 999)
        }
    }

    @Test
    func mainListCombinesFiltersKeepsDuplicateAndAndTrustsDeletedTargets() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(database, id: 301, isDeleted: 0)
        try bookSeedGroup(database, id: 302, isDeleted: 1)
        try bookSeedTag(database, id: 401, name: "Tag A")
        try bookSeedTag(database, id: 402, name: "Tag B")
        try bookSeedTag(database, id: 403, name: "Deleted", isDeleted: 1)
        try bookSeedBook(database, id: 201, name: "Alpha", order: 2, readStatus: 2)
        try bookSeedBook(database, id: 202, name: "Alpha", order: 1, readStatus: 2)
        try bookSeedBook(database, id: 203, name: "Deleted Tag", readStatus: 2)
        try bookSeedBook(database, id: 204, name: "Deleted Group", readStatus: 2)
        try bookSeedGroupRelation(database, id: 501, groupID: 301, bookID: 201)
        try bookSeedGroupRelation(database, id: 502, groupID: 301, bookID: 202)
        try bookSeedGroupRelation(database, id: 503, groupID: 302, bookID: 204)
        try bookSeedTagRelation(database, id: 601, tagID: 401, bookID: 201)
        try bookSeedTagRelation(database, id: 602, tagID: 402, bookID: 201)
        try bookSeedTagRelation(database, id: 603, tagID: 401, bookID: 202)
        try bookSeedTagRelation(database, id: 604, tagID: 403, bookID: 203)

        let combined = try await repository.books(
            page: 1,
            pageSize: 20,
            filter: bookFilter(
                keyword: "Alpha",
                status: 2,
                groupID: 301,
                tagIDs: [401, 402],
                tagMode: "and",
                sourceIDs: [1]
            ),
            sortBy: "custom",
            sortOrder: "desc"
        )
        #expect(combined.items.map(\.id) == [201])

        let duplicateAnd = try await repository.books(
            page: 1,
            pageSize: 20,
            filter: bookFilter(tagIDs: [401, 401], tagMode: "and"),
            sortBy: "custom",
            sortOrder: "desc"
        )
        #expect(duplicateAnd.items.isEmpty)

        let deletedTag = try await repository.books(
            page: 1,
            pageSize: 20,
            filter: bookFilter(tagIDs: [403]),
            sortBy: "custom",
            sortOrder: "desc"
        )
        #expect(deletedTag.items.isEmpty)

        let deletedGroup = try await repository.books(
            page: 1,
            pageSize: 20,
            filter: bookFilter(groupID: 302),
            sortBy: "custom",
            sortOrder: "asc"
        )
        #expect(deletedGroup.items.isEmpty)
    }

    @Test
    func positiveGroupListUsesGroupCustomOrderRegardlessOfRequestedDirection() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(database, id: 301, isDeleted: 0)
        try bookSeedBook(database, id: 201, order: 9)
        try bookSeedBook(database, id: 202, order: 2)
        try bookSeedBook(database, id: 203, order: 1, pinned: 1, pinOrder: 4)
        try bookSeedGroupRelation(database, id: 501, groupID: 301, bookID: 201)
        try bookSeedGroupRelation(database, id: 502, groupID: 301, bookID: 202)
        try bookSeedGroupRelation(database, id: 503, groupID: 301, bookID: 203)

        let page = try await repository.books(
            page: 1,
            pageSize: 20,
            filter: bookFilter(groupID: 301),
            sortBy: "custom",
            sortOrder: "asc"
        )
        #expect(page.items.map(\.id) == [203, 202, 201])
    }

    @Test
    func topLevelSectionsMergePinnedGroupsExcludeTheirBooksAndBuildPreview() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        let january2024: Int64 = 1_704_067_200_000
        try bookSeedGroup(
            database,
            id: 301,
            isDeleted: 0,
            name: "Pinned Group",
            pinned: 1,
            pinOrder: 7
        )
        try bookSeedBook(
            database,
            id: 201,
            name: "Inside",
            cover: "https://example.com/inside.jpg",
            createdDate: january2024
        )
        try bookSeedBook(
            database,
            id: 202,
            name: "Pinned Book",
            pinned: 1,
            pinOrder: 8,
            createdDate: january2024
        )
        try bookSeedBook(database, id: 203, name: "Regular", createdDate: january2024)
        try bookSeedGroupRelation(database, id: 501, groupID: 301, bookID: 201)

        let result = try await repository.bookSections(
            filter: bookFilter(),
            sectionBy: "create_time",
            sortOrder: "desc",
            groupSortBy: "custom",
            groupSortOrder: "desc",
            groupEnableSection: false
        )
        #expect(result.total == 3)
        #expect(result.sections.map(\.title) == ["置顶", "2024 年 01 月"])
        #expect(result.sections[0].books.map(\.id) == [202])
        #expect(result.sections[0].groups.map(\.id) == [301])
        #expect(result.sections[0].count == 2)
        #expect(result.sections[0].groups[0].bookCount == 1)
        #expect(result.sections[0].groups[0].previewBooks.map(\.bookID) == [201])
        #expect(result.sections[0].groups[0].previewBooks.first?.cover == "https://example.com/inside.jpg")
        #expect(result.sections[1].books.map(\.id) == [203])
    }

    @Test
    func groupedSectionsKeepPinnedSectionAndSpecialSectionLast() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(database, id: 301, isDeleted: 0)
        try bookSeedBook(database, id: 201, name: "Beta", pubDate: "2023-1", order: 2)
        try bookSeedBook(database, id: 202, name: "No Date", pubDate: "", order: 1)
        try bookSeedBook(
            database,
            id: 203,
            name: "Pinned",
            pubDate: "2024-1",
            order: 3,
            pinned: 1,
            pinOrder: 9
        )
        try bookSeedGroupRelation(database, id: 501, groupID: 301, bookID: 201)
        try bookSeedGroupRelation(database, id: 502, groupID: 301, bookID: 202)
        try bookSeedGroupRelation(database, id: 503, groupID: 301, bookID: 203)

        let result = try await repository.bookSections(
            filter: bookFilter(groupID: 301),
            sectionBy: "publish_date",
            sortOrder: "desc",
            groupSortBy: "custom",
            groupSortOrder: "desc",
            groupEnableSection: false
        )
        #expect(result.total == 3)
        #expect(result.sections.map(\.title) == ["置顶", "2023 年", "无出版日期"])
        #expect(result.sections.map { $0.books.map(\.id) } == [[203], [201], [202]])
        #expect(result.sections.allSatisfy { $0.groups.isEmpty })

        try bookSeedBook(database, id: 204, name: "   ", order: 4)
        try bookSeedGroupRelation(database, id: 504, groupID: 301, bookID: 204)
        let nameSections = try await repository.bookSections(
            filter: bookFilter(groupID: 301),
            sectionBy: "name",
            sortOrder: "asc",
            groupSortBy: "custom",
            groupSortOrder: "desc",
            groupEnableSection: false
        )
        #expect(nameSections.total == 4)
        #expect(nameSections.sections.flatMap(\.books).map(\.id).contains(204) == false)
    }

    @Test
    func recentReadMergesSourcesUsesAndroidTimePriorityAndPages() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedBook(database, id: 201, readStatus: 2, bookmarkModifiedTime: 1_000)
        try bookSeedBook(database, id: 202, readStatus: 2)
        try bookSeedBook(database, id: 203, readStatus: 2)
        try bookSeedBook(database, id: 204, readStatus: 1)
        try bookSeedBook(database, id: 205, readStatus: 2, isDeleted: 1)
        try bookSeedNote(database, id: 301, bookID: 201, createdDate: 500)
        try bookSeedReadTime(
            database,
            id: 401,
            bookID: 202,
            fuzzyDate: 700,
            wereadDate: 800,
            endTime: 900,
            startTime: 950,
            createdDate: 990
        )
        try bookSeedCheckIn(
            database,
            id: 501,
            bookID: 203,
            checkinDate: 600,
            createdDate: 850
        )
        try bookSeedNote(database, id: 302, bookID: 204, createdDate: 2_000)
        try bookSeedNote(database, id: 303, bookID: 205, createdDate: 3_000)

        let first = try await repository.recentReadBooks(page: 1, pageSize: 2)
        #expect(first.items.map(\.id) == [201, 202])
        #expect(first.items.map(\.recentReadTime) == [1_000, 700])
        #expect(first.total == 3)
        #expect(first.totalPages == 2)

        let second = try await repository.recentReadBooks(page: 2, pageSize: 2)
        #expect(second.items.map(\.id) == [203])
        #expect(second.items.first?.recentReadTime == 600)
    }

    @Test
    func lastNoteBookUsesCreatedDateOnlyAndReturnsNilWithoutMatch() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedBook(database, id: 201)
        try bookSeedBook(database, id: 202)
        try bookSeedBook(database, id: 203, isDeleted: 1)
        try bookSeedNote(database, id: 301, bookID: 201, createdDate: 100, updatedDate: 9_000)
        try bookSeedNote(database, id: 302, bookID: 202, createdDate: 200, updatedDate: 0)
        try bookSeedNote(database, id: 303, bookID: 203, createdDate: 500)
        try bookSeedNote(database, id: 304, bookID: 201, createdDate: 600, isDeleted: 1)

        #expect(try await repository.lastNoteBook()?.id == 202)

        let emptyDatabase = try AppDatabase.empty()
        let emptyRepository = DesktopWebBookRepository(database: emptyDatabase)
        #expect(try await emptyRepository.lastNoteBook() == nil)
    }

    @Test
    func pinnedUsesPinOrderAscendingAndPaginatesOnlyActivePinnedBooks() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedBook(database, id: 201, pinned: 1, pinOrder: 8)
        try bookSeedBook(database, id: 202, pinned: 1, pinOrder: 2)
        try bookSeedBook(database, id: 203, pinned: 0, pinOrder: 1)
        try bookSeedBook(database, id: 204, pinned: 1, pinOrder: 0, isDeleted: 1)

        let first = try await repository.pinnedBooks(page: 1, pageSize: 1)
        #expect(first.items.map(\.id) == [202])
        #expect(first.total == 2)
        #expect(first.totalPages == 2)

        let second = try await repository.pinnedBooks(page: 2, pageSize: 1)
        #expect(second.items.map(\.id) == [201])
    }

    @Test
    func ungroupedExcludesAnyActiveRelationAndPinnedButCrossesOwners() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedUser(database, id: 2)
        try bookSeedGroup(database, id: 301, isDeleted: 1)
        try bookSeedBook(database, id: 201, order: 3)
        try bookSeedBook(database, id: 202, order: 1)
        try bookSeedBook(database, id: 203, order: 2)
        try bookSeedBook(database, id: 204, order: 0, pinned: 1)
        try bookSeedBook(database, id: 205, userID: 2, order: 0)
        try bookSeedGroupRelation(database, id: 401, groupID: 301, bookID: 202)
        try bookSeedGroupRelation(database, id: 402, groupID: 301, bookID: 203, isDeleted: 1)

        let page = try await repository.ungroupedBooks(
            page: 1,
            pageSize: 20,
            sortBy: "custom",
            sortOrder: "desc"
        )
        #expect(page.items.map(\.id) == [205, 202, 203, 201])
        #expect(page.total == 4)
        #expect(page.items.allSatisfy { $0.lastModifiedTime == nil })
    }

    @Test
    func ungroupedSortBucketsMatchAndroidAndModifyTimeIsConditional() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedBook(database, id: 201, order: 1, score: 0, createdDate: 100)
        try bookSeedBook(database, id: 202, order: 2, score: 20, createdDate: 200)
        try bookSeedBook(database, id: 203, order: 3, score: 10, createdDate: 300)
        try bookSeedNote(database, id: 301, bookID: 201, createdDate: 400, updatedDate: 900)

        let rating = try await repository.ungroupedBooks(
            page: 1,
            pageSize: 20,
            sortBy: "rating",
            sortOrder: "asc"
        )
        #expect(rating.items.map(\.id) == [203, 202, 201])
        #expect(rating.items.allSatisfy { $0.lastModifiedTime == nil })

        let modified = try await repository.ungroupedBooks(
            page: 1,
            pageSize: 20,
            sortBy: "modify_time",
            sortOrder: "desc"
        )
        #expect(modified.items.map(\.id) == [201, 203, 202])
        #expect(modified.items.first?.lastModifiedTime == 900)
        #expect(modified.items.dropFirst().allSatisfy { $0.lastModifiedTime != nil })
    }

    @Test
    func publishDateAcceptsOnlyAndroidYearMonthPattern() throws {
        let repository = DesktopWebGroupRepository(database: try AppDatabase.empty())

        #expect(repository.publishTimestamp("2024-1") > 0)
        #expect(repository.publishTimestamp("2024-01-extra") > 0)
        #expect(repository.publishTimestamp("2024-001") == 0)
        #expect(repository.publishTimestamp("2024-01-") == 0)
        #expect(repository.publishTimestamp("2024-13") == 0)
    }

    @Test
    func publishDateSortKeepsValidPreEpochBooksInTopLevelAndGroupLists() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(database, id: 301, isDeleted: 0)
        try bookSeedBook(database, id: 201, pubDate: "1960-01", createdDate: 100)
        try bookSeedBook(database, id: 202, pubDate: "", createdDate: 200)
        try bookSeedBook(database, id: 203, pubDate: "2024-01", createdDate: 300)
        try bookSeedGroupRelation(database, id: 401, groupID: 301, bookID: 201)
        try bookSeedGroupRelation(database, id: 402, groupID: 301, bookID: 202)
        try bookSeedGroupRelation(database, id: 403, groupID: 301, bookID: 203)

        let topLevel = try await repository.books(
            page: 1,
            pageSize: 20,
            filter: bookFilter(),
            sortBy: "publish_date",
            sortOrder: "asc"
        )
        #expect(topLevel.total == 3)
        #expect(Set(topLevel.items.map(\.id)) == [201, 202, 203])

        let grouped = try await repository.books(
            page: 1,
            pageSize: 20,
            filter: bookFilter(groupID: 301),
            sortBy: "publish_date",
            sortOrder: "asc"
        )
        #expect(grouped.total == 3)
        #expect(Set(grouped.items.map(\.id)) == [201, 202, 203])
    }

    @Test
    func deleteBookSoftDeletesCascadeInAndroidOrderAndRewritesSelectedTombstones() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 1_000)
        let repository = DesktopWebBookRepository(
            database: database,
            currentTimeMillis: clock.now
        )
        try bookSeedBook(database, id: 701)
        try bookSeedDeleteCascade(database, bookID: 701)

        try await repository.deleteBook(id: 701)

        #expect(try bookDeletionState(database, table: "book", id: 701) == BookDeletionState(1, 1_000))
        #expect(try bookDeletionState(database, table: "tag_book", id: 711) == BookDeletionState(1, 1_001))
        #expect(try bookDeletionState(database, table: "tag_note", id: 713) == BookDeletionState(1, 1_002))
        #expect(try bookDeletionState(database, table: "tag_note", id: 714) == BookDeletionState(0, 7))
        #expect(try bookDeletionState(database, table: "note", id: 712) == BookDeletionState(1, 1_003))
        #expect(try bookDeletionState(database, table: "note", id: 715) == BookDeletionState(1, 1_003))
        #expect(try bookDeletionState(database, table: "attach_image", id: 716) == BookDeletionState(1, 1_004))
        #expect(try bookDeletionState(database, table: "category", id: 717) == BookDeletionState(1, 1_005))
        #expect(try bookDeletionState(database, table: "category_image", id: 719) == BookDeletionState(1, 1_006))
        #expect(try bookDeletionState(database, table: "category_content", id: 718) == BookDeletionState(1, 1_007))
        #expect(try bookDeletionState(database, table: "review", id: 720) == BookDeletionState(1, 1_008))
        #expect(try bookDeletionState(database, table: "review_image", id: 721) == BookDeletionState(1, 1_009))
        #expect(try bookDeletionState(database, table: "chapter", id: 722) == BookDeletionState(1, 1_010))
        #expect(try bookDeletionState(database, table: "group_book", id: 724) == BookDeletionState(1, 1_011))
        #expect(try bookDeletionState(database, table: "group_book", id: 725) == BookDeletionState(1, 0))
        #expect(
            try bookDeletionState(database, table: "book_read_status_record", id: 726)
                == BookDeletionState(1, 1_012)
        )
        #expect(try bookDeletionState(database, table: "read_time_record", id: 727) == BookDeletionState(1, 1_013))
        #expect(try bookDeletionState(database, table: "read_time_record", id: 728) == BookDeletionState(1, 7))
        #expect(try bookDeletionState(database, table: "sort", id: 729) == BookDeletionState(1, 1_014))
        #expect(try bookDeletionState(database, table: "check_in_record", id: 730) == BookDeletionState(1, 1_015))
        #expect(try bookDeletionState(database, table: "check_in_record", id: 731) == BookDeletionState(1, 7))
        #expect(try bookDeletionState(database, table: "collection_book", id: 733) == BookDeletionState(1, 7))
        #expect(try bookDeletionState(database, table: "read_plan", id: 734) == BookDeletionState(1, 7))

        await expectBookCatalogError(.notFound("书籍不存在: 701")) {
            try await repository.deleteBook(id: 701)
        }
        await expectBookCatalogError(.notFound("书籍不存在: 999")) {
            try await repository.deleteBook(id: 999)
        }
    }

    @Test
    func deleteBookRollsBackAllSeventeenStepsWhenLateCascadeFails() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedBook(database, id: 741)
        try bookSeedTag(database, id: 742, name: "rollback")
        try bookSeedTagRelation(database, id: 743, tagID: 742, bookID: 741)
        try await database.dbPool.write { db in
            var plan = ReadPlanRecord(id: 744, bookId: 741, updatedDate: 7)
            try plan.insert(db)
            // SQL 目的：仅在测试中让删除事务最后一步失败，以验证前序主表与关系表更新全部回滚。
            // 涉及表：read_plan；触发器只匹配 fixture 书籍 741。
            // 关键过滤：UPDATE 且 OLD.book_id = 741；无时间换算。
            // 副作用用途：RAISE(ABORT) 模拟晚期 DAO 写入异常。
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_book_delete_fixture
                    BEFORE UPDATE ON read_plan
                    WHEN OLD.book_id = 741
                    BEGIN
                        SELECT RAISE(ABORT, 'fixture delete failure');
                    END
                    """
            )
        }

        do {
            try await repository.deleteBook(id: 741)
            Issue.record("预期删除事务在 read_plan 步骤失败")
        } catch {
            #expect(error is DatabaseError)
        }

        #expect(try bookDeletionState(database, table: "book", id: 741).isDeleted == 0)
        #expect(try bookDeletionState(database, table: "tag_book", id: 743).isDeleted == 0)
        #expect(try bookDeletionState(database, table: "read_plan", id: 744).isDeleted == 0)
    }

    @Test
    func pinBookRequiresActiveGroupIsIdempotentAndWrapsKotlinInt() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 2_000)
        let repository = DesktopWebBookRepository(
            database: database,
            currentTimeMillis: clock.now
        )
        try bookSeedGroup(database, id: 801, isDeleted: 0)
        try bookSeedBook(database, id: 802, pinned: 1, pinOrder: 7)
        try bookSeedBook(database, id: 803)
        try bookSeedGroupRelation(database, id: 804, groupID: 801, bookID: 802)
        try bookSeedGroupRelation(database, id: 805, groupID: 801, bookID: 803)

        let pinned = try await repository.updateBookPin(id: 803, pinned: true, groupID: 801)
        #expect(pinned == DesktopWebBookPinSnapshot(id: 803, isPinned: true, pinOrder: 8))
        #expect(try bookMutationState(database, id: 803).updatedDate == 2_000)

        let unchanged = try await repository.updateBookPin(id: 803, pinned: true, groupID: 801)
        #expect(unchanged == pinned)
        #expect(try bookMutationState(database, id: 803).updatedDate == 2_000)

        let unpinned = try await repository.updateBookPin(id: 803, pinned: false, groupID: 801)
        #expect(unpinned == DesktopWebBookPinSnapshot(id: 803, isPinned: false, pinOrder: 0))
        #expect(try bookMutationState(database, id: 803).updatedDate == 2_001)

        try bookSeedGroup(database, id: 810, isDeleted: 1)
        await expectBookCatalogError(.invalidArgument("分组不存在")) {
            _ = try await repository.updateBookPin(id: 803, pinned: true, groupID: 810)
        }
        #expect(try bookMutationState(database, id: 803).pinned == 0)

        try bookSeedGroup(database, id: 809, isDeleted: 0, pinned: 1, pinOrder: 500)
        try bookSeedBook(database, id: 806, pinned: 1, pinOrder: 12)
        try bookSeedBook(database, id: 807)
        let global = try await repository.updateBookPin(id: 807, pinned: true, groupID: nil)
        #expect(global.pinOrder == 501)
        #expect(try bookMutationState(database, id: 807).updatedDate == 2_002)

        try bookSeedBook(database, id: 810, pinned: 1, pinOrder: Int64(Int32.max))
        try bookSeedBook(database, id: 811)
        let wrapped = try await repository.updateBookPin(id: 811, pinned: true, groupID: nil)
        #expect(wrapped.pinOrder == Int(Int32.min))
        #expect(try bookMutationState(database, id: 811).updatedDate == 2_003)

        try bookSeedBook(database, id: 812, isDeleted: 1)
        await expectBookCatalogError(.notFound("书籍不存在: 812")) {
            _ = try await repository.updateBookPin(id: 812, pinned: true, groupID: nil)
        }
        await expectBookCatalogError(.notFound("书籍不存在: 999")) {
            _ = try await repository.updateBookPin(id: 999, pinned: true, groupID: nil)
        }
    }

    @Test
    func addToBookshelfRestoresBoundaryFieldsAndRollsBackLateFailure() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 3_000)
        let startRepository = DesktopWebBookRepository(
            database: database,
            currentTimeMillis: clock.now,
            shouldPlaceNewBookAtEnd: { false }
        )
        try bookSeedBook(database, id: 901, order: 99, pinned: 1, pinOrder: 4, readStatus: 5, isDeleted: 1)
        try bookSeedBook(database, id: 902, order: -4)
        try bookSeedGroup(database, id: 903, isDeleted: 0, order: -10)
        try bookSeedGroupRelation(database, id: 904, groupID: 903, bookID: 901)

        let restored = try await startRepository.addToBookshelf(id: 901)
        #expect(restored.id == 901)
        #expect(restored.readStatus == 2)
        #expect(restored.isPinned)
        let restoredState = try bookMutationState(database, id: 901)
        #expect(restoredState.isDeleted == 0)
        #expect(restoredState.readStatusID == 2)
        #expect(restoredState.readStatusChangedDate == 3_000)
        #expect(restoredState.purchaseDate == 3_000)
        #expect(restoredState.bookOrder == -11)
        #expect(restoredState.pinned == 1)
        #expect(restoredState.pinOrder == 4)
        #expect(restoredState.updatedDate == 3_000)
        #expect(
            try bookStatusRows(database, bookID: 901)
                == [BookStatusRow(readStatusID: 2, changedDate: 3_000, createdDate: 3_000)]
        )

        _ = try await startRepository.addToBookshelf(id: 901)
        #expect(
            try bookStatusRows(database, bookID: 901)
                == [BookStatusRow(readStatusID: 2, changedDate: 3_000, createdDate: 3_000)]
        )
        #expect(try bookMutationState(database, id: 901).updatedDate == 3_000)

        try bookSeedBook(database, id: 905, order: 99, isDeleted: 1)
        try bookSeedBook(database, id: 906, order: 20)
        try bookSeedGroup(database, id: 907, isDeleted: 0, order: 30)
        let endRepository = DesktopWebBookRepository(
            database: database,
            currentTimeMillis: clock.now,
            shouldPlaceNewBookAtEnd: { true }
        )
        _ = try await endRepository.addToBookshelf(id: 905)
        #expect(try bookMutationState(database, id: 905).bookOrder == 31)
        #expect(try bookMutationState(database, id: 905).updatedDate == 3_001)

        try bookSeedBook(database, id: 908, isDeleted: 1)
        try await database.dbPool.write { db in
            // SQL 目的：只阻断 fixture 书籍的阅读状态插入，验证 Web 恢复事务不会留下部分完成。
            // 涉及表：book_read_status_record；匹配 NEW.book_id = 908。
            // 关键过滤：INSERT 且目标书籍为 908；无时间换算。
            // 副作用用途：RAISE(ABORT) 模拟事务后半段失败。
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_book_restore_status_fixture
                    BEFORE INSERT ON book_read_status_record
                    WHEN NEW.book_id = 908
                    BEGIN
                        SELECT RAISE(ABORT, 'fixture status failure');
                    END
                    """
            )
        }
        do {
            _ = try await startRepository.addToBookshelf(id: 908)
            Issue.record("预期阅读状态记录插入失败")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(try bookMutationState(database, id: 908).isDeleted == 1)
        #expect(try bookStatusRows(database, bookID: 908).isEmpty)

        await expectBookCatalogError(.notFound("书籍不存在: 999")) {
            _ = try await startRepository.addToBookshelf(id: 999)
        }
    }

    @Test
    func createBookPersistsTrimmedFieldsCatalogStatusAnnualTagsAndGroupInOneTransaction() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 10_000)
        let repository = DesktopWebBookRepository(
            database: database,
            currentTimeMillis: clock.now,
            shouldPlaceNewBookAtEnd: { true }
        )
        try bookSeedGroup(database, id: 1_001, isDeleted: 0)
        try bookSeedTag(database, id: 1_002, name: "标签 A")
        try bookSeedTag(database, id: 1_003, name: "标签 B")
        try bookSeedBook(database, id: 1_004, order: 8)
        try bookSeedGroupRelation(database, id: 1_005, groupID: 1_001, bookID: 1_004)
        let finishedAt: Int64 = 1_704_067_200_000

        let result = try await repository.createBook(
            bookCreateInput(
                name: "  新书  ",
                rawName: "   ",
                author: "  作者  ",
                cover: "  cover  ",
                translator: "  译者  ",
                isbn: "  ISBN  ",
                press: "  出版社  ",
                pubDate: "  2024-01  ",
                readStatus: 3,
                readStatusChangedTime: finishedAt,
                type: 1,
                positionUnit: 1,
                readPosition: 5,
                totalPosition: 50,
                totalPagination: -9,
                catalog: "根章节\u{00A0}  \n  子章节\u{200D}  ",
                tagIDs: [1_002, 1_003, 1_002],
                groupID: 1_001
            )
        )

        let record = try bookRecord(database, id: result.id)
        #expect(result.name == "新书")
        #expect(result.readStatus == 3)
        #expect(result.readPosition == 50)
        #expect(record.rawName == "新书")
        #expect(record.author == "作者")
        #expect(record.cover == "  cover  ")
        #expect(record.translator == "译者")
        #expect(record.isbn == "ISBN")
        #expect(record.press == "出版社")
        #expect(record.pubDate == "2024-01")
        #expect(record.type == 1)
        #expect(record.positionUnit == 1)
        #expect(record.currentPositionUnit == 1)
        #expect(record.readPosition == 50)
        #expect(record.totalPosition == 50)
        #expect(record.totalPagination == 0)
        #expect(record.bookOrder == 9)
        #expect(record.catalog.isEmpty)
        #expect(record.bookMarkModifiedTime == 10_000)
        #expect(
            try bookChapterRows(database, bookID: result.id) == [
                BookChapterRow(title: "根章节", parentID: 0, level: 1, sourcePath: "根章节"),
                BookChapterRow(
                    title: "子章节",
                    parentID: try #require(bookChapterRows(database, bookID: result.id).first?.id),
                    level: 2,
                    sourcePath: "根章节 / 子章节"
                )
            ]
        )
        #expect(try bookTagIDs(database, bookID: result.id) == [1_002, 1_003])
        #expect(try bookGroupIDs(database, bookID: result.id) == [1_001])
        #expect(
            try bookStatusRows(database, bookID: result.id)
                == [BookStatusRow(readStatusID: 3, changedDate: finishedAt, createdDate: 10_003)]
        )
        #expect(
            try bookAnnualRows(database, bookID: result.id)
                == [BookAnnualRow(title: "2024年阅读书单", year: 2024)]
        )
    }

    @Test
    func createBookRejectsInvalidInputsAndRollsBackCatalog() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(
            database: database,
            shouldPlaceNewBookAtEnd: { true }
        )
        try bookSeedBook(database, id: 1_101, name: "重复", author: "作者")

        await expectBookCatalogError(.invalidArgument("书名不能为空")) {
            _ = try await repository.createBook(bookCreateInput(name: "   "))
        }
        await expectBookCatalogError(.duplicate("书籍已存在")) {
            _ = try await repository.createBook(bookCreateInput(name: "重复", author: "作者"))
        }
        await expectBookCatalogError(.invalidArgument("仅 creationMode=related_hidden 时允许 isDeleted=true")) {
            _ = try await repository.createBook(bookCreateInput(name: "隐藏失败", isDeleted: true))
        }
        await expectBookCatalogError(.invalidArgument("当前书籍类型不支持所选进度类型")) {
            _ = try await repository.createBook(
                bookCreateInput(name: "单位失败", type: 0, positionUnit: 1)
            )
        }
        let beforeCatalogFailure = try activeBookCount(database)
        await expectBookCatalogError(.invalidArgument("章节层级不能超过 5 层")) {
            _ = try await repository.createBook(
                bookCreateInput(name: "目录失败", catalog: "          六级章节")
            )
        }
        #expect(try activeBookCount(database) == beforeCatalogFailure)

        let beforeNegativeGroup = try activeBookCount(database)
        await expectBookCatalogError(.invalidArgument("分组不存在")) {
            _ = try await repository.createBook(
                bookCreateInput(name: "负分组", groupID: -7)
            )
        }
        #expect(try activeBookCount(database) == beforeNegativeGroup)
    }

    @Test
    func updateBookKeepsOmittedBookmarkWriteAndSynchronizesStatusAnnualTagsAndPrimaryGroup() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 20_000)
        let repository = DesktopWebBookRepository(database: database, currentTimeMillis: clock.now)
        try bookSeedGroup(database, id: 1_201, isDeleted: 0)
        try bookSeedGroup(database, id: 1_202, isDeleted: 0)
        try bookSeedTag(database, id: 1_203, name: "旧标签")
        try bookSeedTag(database, id: 1_204, name: "新标签")
        try bookSeedBook(
            database,
            id: 1_205,
            name: "更新前",
            type: 1,
            currentPositionUnit: 1,
            positionUnit: 1,
            readPosition: 10,
            totalPosition: 80,
            readStatus: 2,
            readStatusChangedDate: 100,
            bookmarkModifiedTime: 77,
            wordCount: 9
        )
        try bookSeedStatus(database, id: 1_206, bookID: 1_205, readStatus: 2, changedDate: 100)
        try bookSeedTagRelation(database, id: 1_207, tagID: 1_203, bookID: 1_205)
        try bookSeedGroupRelation(database, id: 1_208, groupID: 1_201, bookID: 1_205)
        try bookSeedGroupRelation(database, id: 1_209, groupID: 1_202, bookID: 1_205)
        let finishedAt: Int64 = 1_704_067_200_000

        let result = try await repository.updateBook(
            id: 1_205,
            input: bookUpdateInput(
                name: "   ",
                readStatus: 3,
                readStatusChangedTime: finishedAt,
                positionUnit: 1,
                readPosition: 5,
                totalPosition: 100,
                clearWordCount: true,
                tagIDs: [1_204, 1_204],
                groupID: 1_202
            )
        )

        let record = try bookRecord(database, id: 1_205)
        #expect(result.name.isEmpty)
        #expect(result.readPosition == 100)
        #expect(record.name.isEmpty)
        #expect(record.readStatusId == 3)
        #expect(record.readStatusChangedDate == finishedAt)
        #expect(record.readPosition == 100)
        #expect(record.totalPosition == 100)
        #expect(record.wordCount == nil)
        #expect(record.bookMarkModifiedTime == 20_000)
        #expect(
            try bookStatusRows(database, bookID: 1_205) == [
                BookStatusRow(readStatusID: 2, changedDate: 100, createdDate: 100),
                BookStatusRow(readStatusID: 3, changedDate: finishedAt, createdDate: 20_001)
            ]
        )
        #expect(try bookTagIDs(database, bookID: 1_205) == [1_204])
        #expect(try bookGroupIDs(database, bookID: 1_205) == [1_202])
        #expect(
            try bookAnnualRows(database, bookID: 1_205)
                == [BookAnnualRow(title: "2024年阅读书单", year: 2024)]
        )
    }

    @Test
    func updateBookRejectsBoundariesBeforeAnyWrite() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(database, id: 1_301, isDeleted: 0)
        try bookSeedTag(database, id: 1_302, name: "旧标签")
        try bookSeedTag(database, id: 1_303, name: "新标签")
        try bookSeedBook(database, id: 1_304, name: "目标")
        try bookSeedBook(database, id: 1_305, name: "重复")
        try bookSeedBook(database, id: 1_306, name: "已删除", isDeleted: 1)
        try bookSeedTagRelation(database, id: 1_307, tagID: 1_302, bookID: 1_304)
        try bookSeedGroupRelation(database, id: 1_308, groupID: 1_301, bookID: 1_304)

        await expectBookCatalogError(.duplicate("书籍已存在")) {
            _ = try await repository.updateBook(
                id: 1_304,
                input: bookUpdateInput(name: "重复")
            )
        }
        await expectBookCatalogError(.notFound("书籍不存在: 1306")) {
            _ = try await repository.updateBook(id: 1_306, input: bookUpdateInput())
        }
        await expectBookCatalogError(.notFound("书籍不存在: 9999")) {
            _ = try await repository.updateBook(id: 9_999, input: bookUpdateInput())
        }
        await expectBookCatalogError(.invalidArgument("当前书籍类型不支持所选进度类型")) {
            _ = try await repository.updateBook(
                id: 1_304,
                input: bookUpdateInput(name: "不应落库", type: 0, positionUnit: 1)
            )
        }
        #expect(try bookRecord(database, id: 1_304).name == "目标")

        await expectBookCatalogError(.invalidArgument("分组不存在")) {
            _ = try await repository.updateBook(
                id: 1_304,
                input: bookUpdateInput(
                    name: "不应提交",
                    tagIDs: [1_303],
                    groupID: 999
                )
            )
        }
        #expect(try bookRecord(database, id: 1_304).name == "目标")
        #expect(try bookTagIDs(database, bookID: 1_304) == [1_302])
        #expect(try bookGroupIDs(database, bookID: 1_304) == [1_301])
    }

    @Test
    func batchDeleteDistinctlySkipsMissingAndDeletedBooks() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 30_000)
        let repository = DesktopWebBookRepository(database: database, currentTimeMillis: clock.now)
        try bookSeedBook(database, id: 1_401)
        try bookSeedBook(database, id: 1_402, updatedDate: 7, isDeleted: 1)

        try await repository.batchDeleteBooks(ids: [1_401, 1_401, 1_402, 9_999])

        #expect(try bookDeletionState(database, table: "book", id: 1_401) == BookDeletionState(1, 30_000))
        #expect(try bookDeletionState(database, table: "book", id: 1_402) == BookDeletionState(1, 7))
    }

    @Test
    func batchDeleteCommitsEarlierBooksWhenLaterPerBookTransactionFails() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedBook(database, id: 1_411)
        try bookSeedBook(database, id: 1_412)
        try await database.dbPool.write { db in
            // SQL 目的：只阻断第二本书删除事务的主表步骤，验证前一本独立事务不会回滚。
            // 涉及表：book。
            // 关键过滤：UPDATE、目标 id=1412 且进入删除状态；无时间换算。
            // 副作用用途：模拟批量循环中后续书籍删除失败。
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_second_batch_delete_fixture
                    BEFORE UPDATE ON book
                    WHEN OLD.id = 1412 AND NEW.is_deleted = 1
                    BEGIN
                        SELECT RAISE(ABORT, 'fixture batch delete failure');
                    END
                    """
            )
        }

        do {
            try await repository.batchDeleteBooks(ids: [1_411, 1_412])
            Issue.record("预期第二本书删除失败")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(try bookRecord(database, id: 1_411).isDeleted == 1)
        #expect(try bookRecord(database, id: 1_412).isDeleted == 0)
    }

    @Test
    func batchPinPreservesRawOrderSkipsInvalidAndRequiresActiveGroup() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 31_000)
        let repository = DesktopWebBookRepository(database: database, currentTimeMillis: clock.now)
        try bookSeedGroup(database, id: 1_421, isDeleted: 0)
        try bookSeedBook(database, id: 1_422, pinned: 1, pinOrder: 5)
        try bookSeedBook(database, id: 1_423)
        try bookSeedBook(database, id: 1_424)
        try bookSeedBook(database, id: 1_425, isDeleted: 1)
        try bookSeedGroupRelation(database, id: 1_426, groupID: 1_421, bookID: 1_422)
        try bookSeedGroupRelation(database, id: 1_427, groupID: 1_421, bookID: 1_423)
        try bookSeedGroupRelation(database, id: 1_428, groupID: 1_421, bookID: 1_424)

        try await repository.batchPinBooks(
            ids: [1_423, 1_423, 9_999, 1_425, 1_424],
            pinned: true,
            groupID: 1_421
        )
        #expect(try bookRecord(database, id: 1_423).pinOrder == 6)
        #expect(try bookRecord(database, id: 1_424).pinOrder == 7)
        #expect(try bookRecord(database, id: 1_425).pinned == 0)

        try await repository.batchPinBooks(ids: [1_423, 1_424], pinned: false, groupID: 1_421)
        #expect(try bookRecord(database, id: 1_423).pinOrder == 0)
        #expect(try bookRecord(database, id: 1_424).pinOrder == 0)
    }

    @Test
    func batchUpdateSynchronizesStatusSourceGroupAndTagsWhileSkippingInvalidBooks() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 32_000)
        let repository = DesktopWebBookRepository(database: database, currentTimeMillis: clock.now)
        try bookSeedGroup(database, id: 1_431, isDeleted: 0)
        try bookSeedTag(database, id: 1_432, name: "追加标签")
        try bookSeedBook(
            database,
            id: 1_433,
            readPosition: 2,
            totalPagination: 80,
            readStatus: 2,
            readStatusChangedDate: 100
        )
        try bookSeedBook(database, id: 1_434, isDeleted: 1)
        try bookSeedGroupRelation(database, id: 1_435, groupID: 1_431, bookID: 1_433)
        let finishedAt: Int64 = 1_704_067_200_000

        try await repository.batchUpdateBooks(
            DesktopWebBookBatchUpdateInput(
                ids: [1_433, 1_433, 1_434, 9_999],
                readStatus: 3,
                readStatusChangedTime: finishedAt,
                sourceID: 2,
                groupID: 0,
                addTagIDs: [1_432, 1_432]
            )
        )

        let record = try bookRecord(database, id: 1_433)
        #expect(record.readStatusId == 3)
        #expect(record.readStatusChangedDate == finishedAt)
        #expect(record.readPosition == 80)
        #expect(record.sourceId == 2)
        #expect(try bookGroupIDs(database, bookID: 1_433).isEmpty)
        #expect(try bookTagIDs(database, bookID: 1_433) == [1_432])
        #expect(try bookStatusRows(database, bookID: 1_433).count == 1)
        #expect(try bookAnnualRows(database, bookID: 1_433).map(\.year) == [2024])
    }

    @Test
    func batchUpdateRejectsInvalidTagsBeforeAnyWrite() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(database, id: 1_441, isDeleted: 0)
        try bookSeedBook(database, id: 1_442)
        try bookSeedGroupRelation(database, id: 1_443, groupID: 1_441, bookID: 1_442)
        try await database.dbPool.write { db in
            // SQL 目的：阻断批量更新的标签插入，兜底验证预校验不会触发任何写入。
            // 涉及表：tag_book。
            // 关键过滤：INSERT 且 NEW.tag_id = 999；无时间换算。
            // 副作用用途：若预校验失效则立即暴露非预期数据库错误。
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_batch_update_tag_fixture
                    BEFORE INSERT ON tag_book
                    WHEN NEW.tag_id = 999
                    BEGIN
                        SELECT RAISE(ABORT, 'fixture batch update tag failure');
                    END
                    """
            )
        }

        await expectBookCatalogError(.invalidArgument("部分标签不存在")) {
            try await repository.batchUpdateBooks(
                DesktopWebBookBatchUpdateInput(
                    ids: [1_442],
                    readStatus: nil,
                    readStatusChangedTime: nil,
                    sourceID: 2,
                    groupID: 0,
                    addTagIDs: [999]
                )
            )
        }
        #expect(try bookRecord(database, id: 1_442).sourceId == 1)
        #expect(try bookGroupIDs(database, bookID: 1_442) == [1_441])
    }

    @Test
    func batchSetTagsNormalizesAppendReplaceAndRejectsInvalidInputs() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedTag(database, id: 1_451, name: "标签 A")
        try bookSeedTag(database, id: 1_452, name: "标签 B")
        try bookSeedTag(database, id: 1_453, name: "已删除标签", isDeleted: 1)
        try bookSeedBook(database, id: 1_454, updatedDate: 55)
        try bookSeedBook(database, id: 1_455, isDeleted: 1)
        try bookSeedTagRelation(database, id: 1_456, tagID: 1_451, bookID: 1_454)

        try await repository.batchSetBookTags(
            ids: [1_454, 1_454, -1, 9_999, 1_455],
            tagIDs: [1_452, 1_452, 0, -1],
            mode: "APPEND"
        )
        #expect(try bookTagIDs(database, bookID: 1_454) == [1_451, 1_452])
        #expect(try bookRecord(database, id: 1_454).updatedDate == 55)

        try await repository.batchSetBookTags(ids: [1_454], tagIDs: [], mode: "replace")
        #expect(try bookTagIDs(database, bookID: 1_454).isEmpty)
        #expect(try bookRecord(database, id: 1_454).updatedDate == 55)

        await expectBookCatalogError(.invalidArgument("ids 不能为空")) {
            try await repository.batchSetBookTags(ids: [0, -1], tagIDs: [], mode: "append")
        }
        await expectBookCatalogError(.invalidArgument("mode 仅支持 append 或 replace")) {
            try await repository.batchSetBookTags(ids: [1_454], tagIDs: [], mode: " append ")
        }
        await expectBookCatalogError(.invalidArgument("部分标签不存在")) {
            try await repository.batchSetBookTags(ids: [1_454], tagIDs: [1_453], mode: "replace")
        }
    }

    @Test
    func batchSetTagsRollsBackAllBooksWhenLaterInsertFails() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedTag(database, id: 1_461, name: "旧标签")
        try bookSeedTag(database, id: 1_462, name: "新标签")
        try bookSeedBook(database, id: 1_463)
        try bookSeedBook(database, id: 1_464)
        try bookSeedTagRelation(database, id: 1_465, tagID: 1_461, bookID: 1_463)
        try bookSeedTagRelation(database, id: 1_466, tagID: 1_461, bookID: 1_464)
        try await database.dbPool.write { db in
            // SQL 目的：在第二本书插入新标签时中止整批事务。
            // 涉及表：tag_book。
            // 关键过滤：INSERT 且 book_id=1464、tag_id=1462；无时间换算。
            // 副作用用途：验证第一本书的关系替换也会回滚。
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_late_batch_set_tag_fixture
                    BEFORE INSERT ON tag_book
                    WHEN NEW.book_id = 1464 AND NEW.tag_id = 1462
                    BEGIN
                        SELECT RAISE(ABORT, 'fixture late tag failure');
                    END
                    """
            )
        }
        do {
            try await repository.batchSetBookTags(
                ids: [1_463, 1_464],
                tagIDs: [1_462],
                mode: "replace"
            )
            Issue.record("预期第二本书标签插入失败")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(try bookTagIDs(database, bookID: 1_463) == [1_461])
        #expect(try bookTagIDs(database, bookID: 1_464) == [1_461])
    }

    @Test
    func batchReplaceTagsUsesLastDuplicatePayloadAndValidatesAllBeforeWriting() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedTag(database, id: 1_471, name: "标签 A")
        try bookSeedTag(database, id: 1_472, name: "标签 B")
        try bookSeedBook(database, id: 1_473, updatedDate: 77)
        try bookSeedBook(database, id: 1_474, updatedDate: 88)
        try bookSeedTagRelation(database, id: 1_475, tagID: 1_471, bookID: 1_473)

        try await repository.batchReplaceBookTags([
            DesktopWebBookBatchReplaceTagsItemInput(id: 1_473, tagIDs: [1_471]),
            DesktopWebBookBatchReplaceTagsItemInput(id: 1_474, tagIDs: [1_471, 1_471]),
            DesktopWebBookBatchReplaceTagsItemInput(id: 1_473, tagIDs: [1_472, 1_472, -1])
        ])
        #expect(try bookTagIDs(database, bookID: 1_473) == [1_472])
        #expect(try bookTagIDs(database, bookID: 1_474) == [1_471])
        #expect(try bookRecord(database, id: 1_473).updatedDate == 77)
        #expect(try bookRecord(database, id: 1_474).updatedDate == 88)

        await expectBookCatalogError(.invalidArgument("部分书籍不存在")) {
            try await repository.batchReplaceBookTags([
                DesktopWebBookBatchReplaceTagsItemInput(id: 1_473, tagIDs: []),
                DesktopWebBookBatchReplaceTagsItemInput(id: 9_999, tagIDs: [])
            ])
        }
        #expect(try bookTagIDs(database, bookID: 1_473) == [1_472])
        await expectBookCatalogError(.invalidArgument("items 不能为空")) {
            try await repository.batchReplaceBookTags([
                DesktopWebBookBatchReplaceTagsItemInput(id: 0, tagIDs: [1_471])
            ])
        }
    }

    @Test
    func batchMoveToDeletedGroupIsRejectedBeforeWrites() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 33_000)
        let repository = DesktopWebBookRepository(database: database, currentTimeMillis: clock.now)
        try bookSeedGroup(database, id: 1_481, isDeleted: 1)
        try bookSeedGroup(database, id: 1_482, isDeleted: 0)
        try bookSeedBook(database, id: 1_483, order: 5)
        try bookSeedBook(database, id: 1_484, pinned: 1, pinOrder: 8)
        try bookSeedBook(database, id: 1_485, pinned: 1, pinOrder: 9)
        try bookSeedGroupRelation(database, id: 1_486, groupID: 1_481, bookID: 1_483)
        try bookSeedGroupRelation(database, id: 1_487, groupID: 1_482, bookID: 1_484)
        try bookSeedGroupRelation(database, id: 1_488, groupID: 1_482, bookID: 1_485)

        await expectBookCatalogError(.invalidArgument("分组不存在")) {
            try await repository.batchMoveToGroup(
                ids: [1_484, 1_484, 9_999, 1_485],
                targetGroupID: 1_481,
                sourceGroupID: 1_482
            )
        }
        #expect(try bookGroupIDs(database, bookID: 1_484) == [1_482])
        #expect(try bookGroupIDs(database, bookID: 1_485) == [1_482])
        #expect(try bookRecord(database, id: 1_484).bookOrder == 0)
        #expect(try bookRecord(database, id: 1_485).bookOrder == 0)
        #expect(try bookRecord(database, id: 1_484).pinned == 1)
        #expect(try bookRecord(database, id: 1_485).pinned == 1)
    }

    @Test
    func batchMoveToGroupRollsBackEarlierBooksWhenLaterInsertFails() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(database, id: 1_501, isDeleted: 0)
        try bookSeedGroup(database, id: 1_502, isDeleted: 0)
        try bookSeedBook(database, id: 1_503, order: 10, pinned: 1, pinOrder: 2)
        try bookSeedBook(database, id: 1_504, order: 11, pinned: 1, pinOrder: 3)
        try bookSeedGroupRelation(database, id: 1_505, groupID: 1_501, bookID: 1_503)
        try bookSeedGroupRelation(database, id: 1_506, groupID: 1_501, bookID: 1_504)
        try await database.dbPool.write { db in
            // SQL 目的：在第二本书建立目标关系时中止移组事务。
            // 涉及表：group_book。
            // 关键过滤：INSERT、book_id=1504、group_id=1502；无时间换算。
            // 副作用用途：验证第一本书的取消置顶、关系和排序全部回滚。
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_late_move_group_fixture
                    BEFORE INSERT ON group_book
                    WHEN NEW.book_id = 1504 AND NEW.group_id = 1502
                    BEGIN
                        SELECT RAISE(ABORT, 'fixture late move failure');
                    END
                    """
            )
        }
        do {
            try await repository.batchMoveToGroup(
                ids: [1_503, 1_504],
                targetGroupID: 1_502,
                sourceGroupID: 1_501
            )
            Issue.record("预期第二本书移组失败")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(try bookGroupIDs(database, bookID: 1_503) == [1_501])
        #expect(try bookGroupIDs(database, bookID: 1_504) == [1_501])
        #expect(try bookRecord(database, id: 1_503).pinned == 1)
        #expect(try bookRecord(database, id: 1_504).pinned == 1)
    }

    @Test
    func batchMoveOutPreservesRequestedHeadTailOrderAndLateFailureState() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 34_000)
        let repository = DesktopWebBookRepository(database: database, currentTimeMillis: clock.now)
        try bookSeedGroup(database, id: 1_511, isDeleted: 0, order: 20)
        try bookSeedBook(database, id: 1_512, order: 10)
        try bookSeedBook(database, id: 1_513, order: 1, pinned: 1, pinOrder: 2)
        try bookSeedBook(database, id: 1_514, order: 2, pinned: 1, pinOrder: 3)
        try bookSeedGroupRelation(database, id: 1_515, groupID: 1_511, bookID: 1_513)
        try bookSeedGroupRelation(database, id: 1_516, groupID: 1_511, bookID: 1_514)

        try await repository.batchMoveOut(ids: [1_513, 1_514], placeAtEnd: true)
        #expect(try bookRecord(database, id: 1_513).bookOrder == 21)
        #expect(try bookRecord(database, id: 1_514).bookOrder == 22)
        #expect(try bookGroupIDs(database, bookID: 1_513).isEmpty)
        #expect(try bookGroupIDs(database, bookID: 1_514).isEmpty)

        try bookSeedGroup(database, id: 1_517, isDeleted: 0, order: -20)
        try bookSeedBook(database, id: 1_518, order: 3, pinned: 1, pinOrder: 4)
        try bookSeedBook(database, id: 1_519, order: 4, pinned: 1, pinOrder: 5)
        try bookSeedGroupRelation(database, id: 1_520, groupID: 1_517, bookID: 1_518)
        try bookSeedGroupRelation(database, id: 1_521, groupID: 1_517, bookID: 1_519)
        try await repository.batchMoveOut(ids: [1_518, 1_519], placeAtEnd: false)
        #expect(try bookRecord(database, id: 1_518).bookOrder == -22)
        #expect(try bookRecord(database, id: 1_519).bookOrder == -21)

        try bookSeedBook(database, id: 1_522, order: 9, pinned: 1, pinOrder: 6)
        try bookSeedGroupRelation(database, id: 1_523, groupID: 1_511, bookID: 1_522)
        try await database.dbPool.write { db in
            // SQL 目的：只在第四步改变目标书籍 book_order 时失败。
            // 涉及表：book。
            // 关键过滤：UPDATE、id=1522 且 NEW.book_order != OLD.book_order；无时间换算。
            // 副作用用途：验证整个移出事务在排序失败时回滚。
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_move_out_order_fixture
                    BEFORE UPDATE ON book
                    WHEN OLD.id = 1522 AND NEW.book_order != OLD.book_order
                    BEGIN
                        SELECT RAISE(ABORT, 'fixture move out order failure');
                    END
                    """
            )
        }
        do {
            try await repository.batchMoveOut(ids: [1_522], placeAtEnd: true)
            Issue.record("预期移出排序写入失败")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(try bookRecord(database, id: 1_522).pinned == 1)
        #expect(try bookRecord(database, id: 1_522).bookOrder == 9)
        #expect(try bookGroupIDs(database, bookID: 1_522) == [1_511])
    }

    @Test
    func bookshelfManifestMixesPinnedAndRegularItemsAcrossOwners() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedUser(database, id: 2)
        try bookSeedBook(database, id: 1_601, name: "Pinned", order: 9, pinned: 1, pinOrder: 5)
        try bookSeedBook(database, id: 1_602, name: "Top", order: 3)
        try bookSeedBook(database, id: 1_603, name: "Grouped", order: 0)
        try bookSeedGroup(
            database,
            id: 1_604,
            userID: 2,
            isDeleted: 0,
            pinned: 1,
            pinOrder: 5,
            order: 9
        )
        try bookSeedGroup(database, id: 1_605, isDeleted: 0, order: 2)
        try bookSeedGroupRelation(database, id: 1_606, groupID: 1_605, bookID: 1_603)

        let manifest = try await repository.bookshelfManifest()
        #expect(manifest.map { "\($0.type)-\($0.id)" } == [
            "book-1601",
            "group-1604",
            "group-1605",
            "book-1602"
        ])
        #expect(manifest.map(\.order) == [9, 9, 2, 3])
    }

    @Test
    func bookshelfFiltersTrimmedKeywordPagesManifestAndBuildsOrderedPreviews() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedBook(database, id: 1_611, name: "Alpha Top", order: 1)
        try bookSeedBook(database, id: 1_612, name: "Other Top", order: 3)
        try bookSeedBook(database, id: 1_613, name: "Group Regular", cover: "regular", order: 2)
        try bookSeedBook(
            database,
            id: 1_614,
            name: "Group Pinned",
            cover: "pinned",
            order: 8,
            pinned: 1,
            pinOrder: 7
        )
        try bookSeedGroup(database, id: 1_615, isDeleted: 0, name: "Alpha Group", order: 2)
        try bookSeedGroupRelation(database, id: 1_616, groupID: 1_615, bookID: 1_613)
        try bookSeedGroupRelation(database, id: 1_617, groupID: 1_615, bookID: 1_614)

        let firstPage = try await repository.bookshelf(
            page: 1,
            pageSize: 1,
            keyword: "  Alpha  ",
            groupSortBy: "custom",
            groupSortOrder: "desc",
            groupEnableSection: false
        )
        #expect(firstPage.total == 2)
        #expect(firstPage.totalPages == 2)
        #expect(firstPage.items.map(\.type) == ["book"])
        #expect(firstPage.items.first?.book?.id == 1_611)

        let secondPage = try await repository.bookshelf(
            page: 2,
            pageSize: 1,
            keyword: "Alpha",
            groupSortBy: "custom",
            groupSortOrder: "desc",
            groupEnableSection: false
        )
        let group = try #require(secondPage.items.first?.group)
        #expect(group.id == 1_615)
        #expect(group.bookCount == 2)
        #expect(group.previewBooks.map(\.bookID) == [1_614, 1_613])
        #expect(group.previewBooks.map(\.cover) == ["pinned", "regular"])
    }

    @Test
    func sortedBookshelfKeepsPinnedGroupsExcludesTheirBooksAndExpandsOtherGroups() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(
            database,
            id: 1_621,
            isDeleted: 0,
            name: "Pinned Group",
            pinned: 1,
            pinOrder: 10
        )
        try bookSeedBook(database, id: 1_622, name: "Hidden In Pinned", createdDate: 900)
        try bookSeedGroupRelation(database, id: 1_623, groupID: 1_621, bookID: 1_622)
        try bookSeedBook(
            database,
            id: 1_624,
            name: "Pinned Book",
            pinned: 1,
            pinOrder: 8,
            createdDate: 800
        )
        try bookSeedGroup(database, id: 1_625, isDeleted: 0, name: "Regular Group")
        try bookSeedBook(database, id: 1_626, name: "Expanded", createdDate: 700)
        try bookSeedGroupRelation(database, id: 1_627, groupID: 1_625, bookID: 1_626)
        try bookSeedBook(database, id: 1_628, name: "Top Regular", createdDate: 600)

        let result = try await repository.sortedBookshelf(
            page: 1,
            pageSize: 20,
            keyword: "",
            sortBy: "create_time",
            sortOrder: "desc",
            groupSortBy: "custom",
            groupSortOrder: "desc",
            groupEnableSection: false
        )
        #expect(result.items.map { item in
            item.type == "group" ? item.group?.id : item.book?.id
        } == [1_621, 1_624, 1_626, 1_628])
        #expect(!result.items.contains { $0.book?.id == 1_622 })
        #expect(!result.items.contains { $0.group?.id == 1_625 })
    }

    @Test
    func pinnedGroupsMetaIgnoresTopLevelSortAndHonorsGridSectionPreviewRules() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(
            database,
            id: 1_631,
            isDeleted: 0,
            pinned: 1,
            pinOrder: 2
        )
        try bookSeedBook(database, id: 1_632, name: "", order: 1)
        try bookSeedBook(database, id: 1_633, name: "Visible", order: 2)
        try bookSeedGroupRelation(database, id: 1_634, groupID: 1_631, bookID: 1_632)
        try bookSeedGroupRelation(database, id: 1_635, groupID: 1_631, bookID: 1_633)

        let grid = try await repository.bookshelfPinnedGroupsMeta(
            sortBy: "rating",
            sortOrder: "asc",
            enableSection: true,
            groupSortBy: "name",
            groupSortOrder: "asc",
            groupEnableSection: true,
            layout: "grid"
        )
        #expect(grid.groups.first?.previewBooks.map(\.bookID) == [1_633])
        #expect(grid.bookIDs == [1_633])

        let list = try await repository.bookshelfPinnedGroupsMeta(
            sortBy: "custom",
            sortOrder: "desc",
            enableSection: false,
            groupSortBy: "name",
            groupSortOrder: "asc",
            groupEnableSection: true,
            layout: "list"
        )
        #expect(list.bookIDs == [1_633, 1_632])
    }

    @Test
    func queryBookshelfItemsRejectsReferencesOutsideCurrentManifest() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebBookRepository(database: database)
        try bookSeedGroup(database, id: 1_641, isDeleted: 0)
        try bookSeedBook(database, id: 1_642, name: "Grouped")
        try bookSeedGroupRelation(database, id: 1_643, groupID: 1_641, bookID: 1_642)

        await expectBookCatalogError(.invalidArgument("书架项目与当前清单不一致")) {
            _ = try await repository.queryBookshelfItems(
                itemRefs: [
                    DesktopWebBookshelfItemRefInput(type: "book", id: 0),
                    DesktopWebBookshelfItemRefInput(type: "book", id: 1_642),
                    DesktopWebBookshelfItemRefInput(type: "BOOK", id: 1_642),
                    DesktopWebBookshelfItemRefInput(type: "book", id: 1_642),
                    DesktopWebBookshelfItemRefInput(type: "group", id: 999)
                ],
                groupSortBy: "custom",
                groupSortOrder: "desc",
                groupEnableSection: false
            )
        }
    }

    @Test
    func moveBookshelfUsesCurrentOrderForMovedSetAndRollsBackInvalidPlacement() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 40_000)
        let repository = DesktopWebBookRepository(database: database, currentTimeMillis: clock.now)
        try bookSeedBook(database, id: 1_651, order: 0, pinned: 1, pinOrder: 9)
        try bookSeedBook(database, id: 1_652, order: 1)
        try bookSeedGroup(database, id: 1_653, isDeleted: 0, order: 2)
        try bookSeedBook(database, id: 1_654, order: 3)

        try await repository.moveBookshelfItems(
            movedItems: [
                DesktopWebBookshelfItemRefInput(type: "book", id: 1_654),
                DesktopWebBookshelfItemRefInput(type: "book", id: 1_652)
            ],
            anchorItem: DesktopWebBookshelfItemRefInput(type: "group", id: 1_653),
            placement: "after"
        )
        #expect(try bookRecord(database, id: 1_651).bookOrder == 0)
        #expect(try bookGroupOrder(database, id: 1_653) == 1)
        #expect(try bookRecord(database, id: 1_652).bookOrder == 2)
        #expect(try bookRecord(database, id: 1_654).bookOrder == 3)

        let before = try bookRecord(database, id: 1_652).bookOrder
        await expectBookCatalogError(
            .invalidArgument("Unsupported bookshelf move placement: middle")
        ) {
            try await repository.moveBookshelfItems(
                movedItems: [DesktopWebBookshelfItemRefInput(type: "book", id: 1_652)],
                anchorItem: nil,
                placement: "middle"
            )
        }
        #expect(try bookRecord(database, id: 1_652).bookOrder == before)
    }

    @Test
    func reorderBookshelfRejectsRowsOutsideCurrentManifest() async throws {
        let database = try AppDatabase.empty()
        let clock = BookMillisClock(start: 41_000)
        let repository = DesktopWebBookRepository(database: database, currentTimeMillis: clock.now)
        try bookSeedBook(database, id: 1_661, order: 10, isDeleted: 1)
        try bookSeedBook(database, id: 1_662, order: 11)
        try bookSeedGroup(database, id: 1_663, isDeleted: 0)
        try bookSeedGroupRelation(database, id: 1_664, groupID: 1_663, bookID: 1_662)
        try bookSeedGroup(database, id: 1_665, isDeleted: 1, order: 12)

        await expectBookCatalogError(.invalidArgument("书架项目与当前清单不一致")) {
            try await repository.reorderBookshelf([
                DesktopWebBookshelfItemRefInput(type: "unknown", id: 1_661),
                DesktopWebBookshelfItemRefInput(type: "book", id: 1_661),
                DesktopWebBookshelfItemRefInput(type: "book", id: 1_662),
                DesktopWebBookshelfItemRefInput(type: "book", id: 0),
                DesktopWebBookshelfItemRefInput(type: "book", id: 1_661),
                DesktopWebBookshelfItemRefInput(type: "group", id: 1_665)
            ])
        }
        #expect(try bookRecord(database, id: 1_661).bookOrder == 10)
        #expect(try bookRecord(database, id: 1_662).bookOrder == 11)
        #expect(try bookRecord(database, id: 0).bookOrder == 0)
        #expect(try bookGroupOrder(database, id: 1_665) == 12)
    }

    @Test
    func adapterMapsBookPortsAndClassifiesMissingBook() async throws {
        let suiteName = "DesktopWebBookRepositoryTests.Adapter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let database = try AppDatabase.empty()
        try bookSeedBook(database, id: 201, name: "Adapter")
        let adapter = DesktopWebAPIAdapter(
            repository: DesktopWebSettingsRepository(defaults: defaults),
            nativeActionBridge: DesktopWebNativeActionBridge(),
            isPremiumProvider: { true }
        )
        adapter.configure(database: database)

        #expect(try await adapter.bookStats().total == 1)
        #expect(try await adapter.book(id: 201).name == "Adapter")
        #expect(try await adapter.lastNoteBook() == nil)
        #expect(try await adapter.bookshelfManifest().map(\.id) == [201])
        #expect(
            try await adapter.queryBookshelfItems(
                DesktopWebBookshelfItemsQueryRequest(
                    items: [DesktopWebBookshelfItemRef(type: "book", id: 201)]
                )
            ).first?.book?.name == "Adapter"
        )
        let created = try await adapter.createBook(DesktopWebBookCreateRequest(name: "Adapter Created"))
        #expect(created.name == "Adapter Created")
        let updated = try await adapter.updateBook(
            id: created.id,
            request: DesktopWebBookUpdateRequest(name: "Adapter Updated")
        )
        #expect(updated.name == "Adapter Updated")
        let pin = try await adapter.updateBookPin(
            id: 201,
            request: DesktopWebBookPinRequest(pinned: true, groupId: nil)
        )
        #expect(pin == DesktopWebBookPinResult(id: 201, isPinned: true, pinOrder: 1))
        try await adapter.deleteBook(id: 201)
        #expect(try await adapter.addToBookshelf(id: 201).id == 201)
        do {
            _ = try await adapter.book(id: 999)
            Issue.record("预期缺失书籍返回 40002")
        } catch let error as DesktopWebAPIError {
            #expect(error.code == 40002)
            #expect(error.message == "书籍不存在: 999")
        }
    }
}

private final class BookMillisClock: @unchecked Sendable {
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

private struct BookDeletionState: Equatable {
    let isDeleted: Int64
    let updatedDate: Int64

    init(_ isDeleted: Int64, _ updatedDate: Int64) {
        self.isDeleted = isDeleted
        self.updatedDate = updatedDate
    }
}

private struct BookMutationState: Equatable {
    let isDeleted: Int64
    let readStatusID: Int64
    let readStatusChangedDate: Int64
    let purchaseDate: Int64
    let bookOrder: Int64
    let pinned: Int64
    let pinOrder: Int64
    let updatedDate: Int64
}

private struct BookStatusRow: Equatable {
    let readStatusID: Int64
    let changedDate: Int64
    let createdDate: Int64
}

private struct BookChapterRow: Equatable {
    let id: Int64
    let title: String
    let parentID: Int64
    let level: Int64
    let sourcePath: String

    init(
        id: Int64 = 0,
        title: String,
        parentID: Int64,
        level: Int64,
        sourcePath: String
    ) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.level = level
        self.sourcePath = sourcePath
    }

    static func == (lhs: BookChapterRow, rhs: BookChapterRow) -> Bool {
        lhs.title == rhs.title
            && lhs.parentID == rhs.parentID
            && lhs.level == rhs.level
            && lhs.sourcePath == rhs.sourcePath
    }
}

private struct BookAnnualRow: Equatable {
    let title: String
    let year: Int64
}

private enum BookTestFixtureError: Error {
    case missingBook(Int64)
}

@MainActor
private func expectBookCatalogError(
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

private func bookDeletionState(
    _ database: AppDatabase,
    table: String,
    id: Int64
) throws -> BookDeletionState {
    try database.dbPool.read { db in
        // SQL 目的：读取删除测试指定 fixture 行的软删除与更新时间结果。
        // 涉及表：调用方只传入本测试文件固定的 V44 表名。
        // 关键过滤：主键 id 精确匹配；时间字段按原始毫秒值断言。
        // 返回字段用途：验证 Android 多 DAO 删除顺序、tombstone 重写与过滤差异。
        let row = try Row.fetchOne(
            db,
            sql: "SELECT is_deleted, updated_date FROM \(table) WHERE id = ?",
            arguments: [id]
        )
        return BookDeletionState(
            try #require(row?["is_deleted"] as Int64?),
            try #require(row?["updated_date"] as Int64?)
        )
    }
}

private func bookMutationState(_ database: AppDatabase, id: Int64) throws -> BookMutationState {
    try database.dbPool.read { db in
        // SQL 目的：读取书籍置顶或恢复书架后的全部关键字段。
        // 涉及表：book。
        // 关键过滤：主键 id 精确匹配；所有时间字段均保持毫秒单位。
        // 返回字段用途：锁定 Web 写接口只覆盖的字段以及必须保留的置顶状态。
        let fetched = try Row.fetchOne(
            db,
            sql: """
                SELECT is_deleted, read_status_id, read_status_changed_date, purchase_date,
                       book_order, pinned, pin_order, updated_date
                FROM book
                WHERE id = ?
                """,
            arguments: [id]
        )
        let row = try #require(fetched)
        return BookMutationState(
            isDeleted: row["is_deleted"],
            readStatusID: row["read_status_id"],
            readStatusChangedDate: row["read_status_changed_date"],
            purchaseDate: row["purchase_date"],
            bookOrder: row["book_order"],
            pinned: row["pinned"],
            pinOrder: row["pin_order"],
            updatedDate: row["updated_date"]
        )
    }
}

private func bookStatusRows(_ database: AppDatabase, bookID: Int64) throws -> [BookStatusRow] {
    try database.dbPool.read { db in
        // SQL 目的：读取恢复书架为目标书籍追加的阅读状态历史。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id 精确匹配；按 id 升序保证稳定比较，时间保持毫秒单位。
        // 返回字段用途：验证幂等恢复不重复插入，以及第二次提交失败后的部分完成状态。
        try Row.fetchAll(
            db,
            sql: """
                SELECT read_status_id, changed_date, created_date
                FROM book_read_status_record
                WHERE book_id = ?
                ORDER BY id ASC
                """,
            arguments: [bookID]
        ).map { row in
            BookStatusRow(
                readStatusID: row["read_status_id"],
                changedDate: row["changed_date"],
                createdDate: row["created_date"]
            )
        }
    }
}

private func bookRecord(_ database: AppDatabase, id: Int64) throws -> BookRecord {
    try database.dbPool.read { db in
        // SQL 目的：读取创建或更新测试目标书籍的完整持久化快照。
        // 涉及表：book。
        // 关键过滤：主键 id 精确匹配；时间、进度和文本字段均原样返回。
        // 返回字段用途：核对 WebBookDao 精确写列及遗漏的书签时间。
        guard let record = try BookRecord.fetchOne(
            db,
            sql: "SELECT * FROM book WHERE id = ?",
            arguments: [id]
        ) else {
            throw BookTestFixtureError.missingBook(id)
        }
        return record
    }
}

private func activeBookCount(_ database: AppDatabase) throws -> Int {
    try database.dbPool.read { db in
        // SQL 目的：统计目录解析失败前后的有效非占位书籍数量。
        // 涉及表：book。
        // 关键过滤：id != 0 且 is_deleted = 0；无时间换算。
        // 返回字段用途：证明创建事务回滚主表插入。
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM book WHERE id != 0 AND is_deleted = 0"
        ) ?? 0
    }
}

private func bookChapterRows(_ database: AppDatabase, bookID: Int64) throws -> [BookChapterRow] {
    try database.dbPool.read { db in
        // SQL 目的：读取创建接口由 catalog 解析出的有效章节树。
        // 涉及表：chapter。
        // 关键过滤：book_id 精确匹配且有效；按 id 保持插入顺序。
        // 返回字段用途：核对标题清洗、父子关系、层级与 source_path。
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, title, parent_id, chapter_level, source_path
                FROM chapter
                WHERE book_id = ? AND is_deleted = 0
                ORDER BY id ASC
                """,
            arguments: [bookID]
        ).map { row in
            BookChapterRow(
                id: row["id"],
                title: row["title"],
                parentID: row["parent_id"],
                level: row["chapter_level"],
                sourcePath: row["source_path"] ?? ""
            )
        }
    }
}

private func bookTagIDs(_ database: AppDatabase, bookID: Int64) throws -> [Int64] {
    try database.dbPool.read { db in
        // SQL 目的：读取目标书籍当前有效标签关系的原始 ID 序列。
        // 涉及表：tag_book。
        // 关键过滤：book_id 精确匹配且有效；按关系 id 保持请求插入顺序。
        // 返回字段用途：验证重复 tagIds 不被 Web 创建/更新路径归一化。
        try Int64.fetchAll(
            db,
            sql: "SELECT tag_id FROM tag_book WHERE book_id = ? AND is_deleted = 0 ORDER BY id ASC",
            arguments: [bookID]
        )
    }
}

private func bookGroupIDs(_ database: AppDatabase, bookID: Int64) throws -> [Int64] {
    try database.dbPool.read { db in
        // SQL 目的：读取目标书籍当前有效分组关系。
        // 涉及表：group_book。
        // 关键过滤：book_id 精确匹配且有效；按关系 id 保持 Android 主关系顺序。
        // 返回字段用途：验证创建正数分组与更新关系归一化。
        try Int64.fetchAll(
            db,
            sql: "SELECT group_id FROM group_book WHERE book_id = ? AND is_deleted = 0 ORDER BY id ASC",
            arguments: [bookID]
        )
    }
}

private func bookGroupOrder(_ database: AppDatabase, id: Int64) throws -> Int64 {
    try database.dbPool.read { db in
        // SQL 目的：读取书架移动/重排测试指定分组的原始手动序号。
        // 涉及表：group。
        // 关键过滤：主键 id 精确匹配，不过滤删除状态或 owner。
        // 返回字段用途：锁定 WebBookDao.updateGroupOrder 的越界写入与事务回滚。
        try #require(
            try Int64.fetchOne(
                db,
                sql: "SELECT group_order FROM `group` WHERE id = ?",
                arguments: [id]
            )
        )
    }
}

private func bookAnnualRows(_ database: AppDatabase, bookID: Int64) throws -> [BookAnnualRow] {
    try database.dbPool.read { db in
        // SQL 目的：读取目标书籍当前有效年度书单关系及 Web 风格标题。
        // 涉及表：collection_book INNER JOIN collection。
        // 关键过滤：关系与书单有效、book_id 匹配且 is_annual = 1。
        // 时间字段：year 为自然年整数；不做时区换算。
        // 返回字段用途：验证读完状态同步创建无空格标题的年度书单。
        try Row.fetchAll(
            db,
            sql: """
                SELECT collection.title, collection.year
                FROM collection_book
                INNER JOIN collection ON collection_book.collection_id = collection.id
                WHERE collection_book.book_id = ?
                  AND collection_book.is_deleted = 0
                  AND collection.is_deleted = 0
                  AND collection.is_annual = 1
                ORDER BY collection.year ASC
                """,
            arguments: [bookID]
        ).map { row in
            BookAnnualRow(title: row["title"], year: row["year"])
        }
    }
}

private func bookSeedDeleteCascade(_ database: AppDatabase, bookID: Int64) throws {
    try bookSeedTag(database, id: 710, name: "cascade")
    try bookSeedTagRelation(
        database,
        id: 711,
        tagID: 710,
        bookID: bookID,
        updatedDate: 7,
        isDeleted: 1
    )
    try bookSeedNote(database, id: 712, bookID: bookID, createdDate: 10)
    try bookSeedNote(database, id: 715, bookID: bookID, createdDate: 20, updatedDate: 7, isDeleted: 1)
    try bookSeedGroup(database, id: 723, isDeleted: 0)
    try bookSeedGroupRelation(database, id: 724, groupID: 723, bookID: bookID)
    try bookSeedGroupRelation(database, id: 725, groupID: 723, bookID: bookID, isDeleted: 1)

    try database.dbPool.write { db in
        var activeNoteTag = TagNoteRecord(
            id: 713,
            tagId: 710,
            noteId: 712,
            updatedDate: 7,
            isDeleted: 1
        )
        try activeNoteTag.insert(db)
        var deletedNoteTag = TagNoteRecord(
            id: 714,
            tagId: 710,
            noteId: 715,
            updatedDate: 7
        )
        try deletedNoteTag.insert(db)
        var attachment = AttachImageRecord(
            id: 716,
            noteId: 712,
            imageUrl: "fixture",
            updatedDate: 7
        )
        try attachment.insert(db)
        var category = CategoryRecord(
            id: 717,
            bookId: bookID,
            title: "fixture",
            updatedDate: 7
        )
        try category.insert(db)
        var content = CategoryContentRecord(
            id: 718,
            categoryId: 717,
            bookId: bookID,
            title: "fixture",
            updatedDate: 7
        )
        try content.insert(db)
        var categoryImage = CategoryImageRecord(
            id: 719,
            categoryContentId: 718,
            image: "fixture",
            updatedDate: 7
        )
        try categoryImage.insert(db)
        var review = ReviewRecord(
            id: 720,
            bookId: bookID,
            title: "fixture",
            updatedDate: 7
        )
        try review.insert(db)
        var reviewImage = ReviewImageRecord(
            id: 721,
            reviewId: 720,
            image: "fixture",
            updatedDate: 7
        )
        try reviewImage.insert(db)
        var chapter = ChapterRecord(
            id: 722,
            bookId: bookID,
            title: "fixture",
            updatedDate: 7
        )
        try chapter.insert(db)
        var status = BookReadStatusRecordRecord(
            id: 726,
            bookId: bookID,
            readStatusId: 2,
            updatedDate: 7,
            isDeleted: 1
        )
        try status.insert(db)
        var activeReadTime = ReadTimeRecordRecord(
            id: 727,
            bookId: bookID,
            updatedDate: 7
        )
        try activeReadTime.insert(db)
        var deletedReadTime = ReadTimeRecordRecord(
            id: 728,
            bookId: bookID,
            updatedDate: 7,
            isDeleted: 1
        )
        try deletedReadTime.insert(db)
        var sort = SortRecord(id: 729, bookId: bookID, updatedDate: 7, isDeleted: 1)
        try sort.insert(db)
        var activeCheckIn = CheckInRecordRecord(
            id: 730,
            bookId: bookID,
            updatedDate: 7
        )
        try activeCheckIn.insert(db)
        var deletedCheckIn = CheckInRecordRecord(
            id: 731,
            bookId: bookID,
            updatedDate: 7,
            isDeleted: 1
        )
        try deletedCheckIn.insert(db)
        var collection = CollectionRecord(id: 732, title: "fixture")
        try collection.insert(db)
        var collectionBook = CollectionBookRecord(
            id: 733,
            collectionId: 732,
            bookId: bookID,
            updatedDate: 7
        )
        try collectionBook.insert(db)
        var plan = ReadPlanRecord(id: 734, bookId: bookID, updatedDate: 7)
        try plan.insert(db)
    }
}

private func bookSeedUser(_ database: AppDatabase, id: Int64) throws {
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

private func bookSeedReadStatus(_ database: AppDatabase, id: Int64) throws {
    try database.dbPool.write { db in
        var record = ReadStatusRecord(
            id: id,
            name: "Unknown \(id)",
            readStatusOrder: id,
            createdDate: 0,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func bookSeedSource(_ database: AppDatabase, id: Int64, name: String) throws {
    try database.dbPool.write { db in
        var record = SourceRecord(
            id: id,
            name: name,
            sourceOrder: id,
            bookshelfOrder: id,
            isHide: 0,
            createdDate: 100,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func bookSeedBook(
    _ database: AppDatabase,
    id: Int64,
    userID: Int64 = 1,
    name: String? = nil,
    rawName: String = "",
    author: String = "",
    translator: String = "",
    isbn: String = "",
    press: String = "",
    pubDate: String = "",
    cover: String = "",
    type: Int64 = 0,
    currentPositionUnit: Int64 = 2,
    positionUnit: Int64 = 2,
    readPosition: Double = 0,
    totalPosition: Int64 = 0,
    totalPagination: Int64 = 0,
    purchaseDate: Int64 = 0,
    price: Double = 0,
    order: Int64 = 0,
    pinned: Int64 = 0,
    pinOrder: Int64 = 0,
    score: Int64 = 0,
    readStatus: Int64 = 1,
    readStatusChangedDate: Int64 = 0,
    bookmarkModifiedTime: Int64 = 0,
    wordCount: Int64? = nil,
    createdDate: Int64 = 100,
    updatedDate: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: userID,
            name: name ?? "Book \(id)",
            rawName: rawName,
            cover: cover,
            author: author,
            translator: translator,
            isbn: isbn,
            pubDate: pubDate,
            press: press,
            readPosition: readPosition,
            totalPosition: totalPosition,
            totalPagination: totalPagination,
            type: type,
            currentPositionUnit: currentPositionUnit,
            positionUnit: positionUnit,
            sourceId: 1,
            purchaseDate: purchaseDate,
            price: price,
            bookOrder: order,
            pinned: pinned,
            pinOrder: pinOrder,
            readStatusId: readStatus,
            readStatusChangedDate: readStatusChangedDate,
            score: score,
            bookMarkModifiedTime: bookmarkModifiedTime,
            wordCount: wordCount,
            createdDate: createdDate,
            updatedDate: updatedDate,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func bookSeedStatus(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    readStatus: Int64,
    changedDate: Int64
) throws {
    try database.dbPool.write { db in
        var record = BookReadStatusRecordRecord(
            id: id,
            bookId: bookID,
            readStatusId: readStatus,
            changedDate: changedDate,
            createdDate: 100,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func bookSeedNote(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    createdDate: Int64,
    updatedDate: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = NoteRecord(
            id: id,
            bookId: bookID,
            chapterId: 0,
            content: "fixture",
            createdDate: createdDate,
            updatedDate: updatedDate,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func bookSeedReadTime(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    fuzzyDate: Int64,
    wereadDate: Int64,
    endTime: Int64,
    startTime: Int64,
    createdDate: Int64
) throws {
    try database.dbPool.write { db in
        var record = ReadTimeRecordRecord(
            id: id,
            bookId: bookID,
            startTime: startTime,
            endTime: endTime,
            fuzzyReadDate: fuzzyDate,
            wereadReadDate: wereadDate,
            createdDate: createdDate
        )
        try record.insert(db)
    }
}

private func bookSeedCheckIn(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    checkinDate: Int64,
    createdDate: Int64
) throws {
    try database.dbPool.write { db in
        var record = CheckInRecordRecord(
            id: id,
            bookId: bookID,
            checkinDate: checkinDate,
            createdDate: createdDate
        )
        try record.insert(db)
    }
}

private func bookSeedGroup(
    _ database: AppDatabase,
    id: Int64,
    userID: Int64 = 1,
    isDeleted: Int64,
    name: String? = nil,
    pinned: Int64 = 0,
    pinOrder: Int64 = 0,
    order: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = GroupRecord(
            id: id,
            userId: userID,
            name: name ?? "Group \(id)",
            groupOrder: order,
            pinned: pinned,
            pinOrder: pinOrder,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func bookSeedTag(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = TagRecord(
            id: id,
            userId: 1,
            name: name,
            color: 0,
            tagOrder: 0,
            type: 2,
            createdDate: 100,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func bookSeedTagRelation(
    _ database: AppDatabase,
    id: Int64,
    tagID: Int64,
    bookID: Int64,
    updatedDate: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = TagBookRecord(
            id: id,
            bookId: bookID,
            tagId: tagID,
            createdDate: 100,
            updatedDate: updatedDate,
            lastSyncDate: 0,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func bookCreateInput(
    name: String,
    rawName: String? = nil,
    author: String? = nil,
    cover: String? = nil,
    translator: String? = nil,
    isbn: String? = nil,
    press: String? = nil,
    pubDate: String? = nil,
    readStatus: Int = 1,
    readStatusChangedTime: Int64? = nil,
    type: Int? = nil,
    positionUnit: Int? = nil,
    readPosition: Double? = nil,
    totalPosition: Int? = nil,
    totalPagination: Int? = nil,
    catalog: String? = nil,
    tagIDs: [Int64]? = nil,
    groupID: Int64? = nil,
    isDeleted: Bool? = nil,
    creationMode: String? = nil
) -> DesktopWebBookCreateInput {
    DesktopWebBookCreateInput(
        name: name,
        rawName: rawName,
        author: author,
        cover: cover,
        authorIntro: nil,
        translator: translator,
        summary: nil,
        isbn: isbn,
        press: press,
        pubDate: pubDate,
        doubanID: nil,
        readStatus: readStatus,
        readStatusChangedTime: readStatusChangedTime,
        score: nil,
        type: type,
        positionUnit: positionUnit,
        readPosition: readPosition,
        totalPosition: totalPosition,
        totalPagination: totalPagination,
        sourceID: nil,
        purchaseDate: nil,
        price: nil,
        wordCount: nil,
        catalog: catalog,
        tagIDs: tagIDs,
        groupID: groupID,
        isDeleted: isDeleted,
        creationMode: creationMode
    )
}

private func bookUpdateInput(
    name: String? = nil,
    readStatus: Int? = nil,
    readStatusChangedTime: Int64? = nil,
    type: Int? = nil,
    positionUnit: Int? = nil,
    readPosition: Double? = nil,
    totalPosition: Int? = nil,
    clearWordCount: Bool? = nil,
    tagIDs: [Int64]? = nil,
    groupID: Int64? = nil
) -> DesktopWebBookUpdateInput {
    DesktopWebBookUpdateInput(
        name: name,
        rawName: nil,
        author: nil,
        cover: nil,
        authorIntro: nil,
        translator: nil,
        summary: nil,
        isbn: nil,
        press: nil,
        pubDate: nil,
        doubanID: nil,
        readStatus: readStatus,
        readStatusChangedTime: readStatusChangedTime,
        score: nil,
        type: type,
        positionUnit: positionUnit,
        readPosition: readPosition,
        totalPosition: totalPosition,
        totalPagination: nil,
        sourceID: nil,
        purchaseDate: nil,
        price: nil,
        wordCount: nil,
        clearWordCount: clearWordCount,
        catalog: nil,
        tagIDs: tagIDs,
        groupID: groupID
    )
}

private func bookFilter(
    keyword: String = "",
    status: Int = 0,
    groupID: Int64 = 0,
    tagIDs: [Int64] = [],
    tagMode: String = "or",
    sourceIDs: [Int64] = []
) -> DesktopWebBookFilterSnapshot {
    DesktopWebBookFilterSnapshot(
        keyword: keyword,
        status: status,
        groupID: groupID,
        tagIDs: tagIDs,
        tagMode: tagMode,
        sourceIDs: sourceIDs
    )
}

private func bookSeedGroupRelation(
    _ database: AppDatabase,
    id: Int64,
    groupID: Int64,
    bookID: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = GroupBookRecord(
            id: id,
            groupId: groupID,
            bookId: bookID,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}
