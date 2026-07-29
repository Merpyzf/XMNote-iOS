/**
 * [INPUT]: 依赖 AppDatabase.empty、GRDB Record 与 DesktopWebRelatedRepository
 * [OUTPUT]: 验证 18 条 Related API 的类别、排序、列表、CRUD、批量与 Android 缺陷兼容边界
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android RelatedService/WebRelatedRepository 当前可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct DesktopWebRelatedRepositoryTests {
    @Test
    func globalCategoryQueryLeaksBookCategoriesAndAppliesAndroidCounts() async throws {
        let fixture = try makeRelatedFixture()
        try relatedSeedBook(fixture.database, id: 101, name: "One")
        try relatedSeedBook(fixture.database, id: 102, name: "Two")
        try relatedSeedCategory(fixture.database, id: 111, bookID: 0, title: "Global", order: 1)
        try relatedSeedCategory(fixture.database, id: 112, bookID: 101, title: "Local", order: 2)
        try relatedSeedCategory(fixture.database, id: 113, bookID: 102, title: "Hidden", order: 3, isHidden: 1)
        try relatedSeedCategory(fixture.database, id: 114, bookID: 101, title: "Deleted", order: 4, isDeleted: 1)
        try relatedSeedNote(fixture.database, id: 121, categoryID: 111, bookID: 101, title: "A")
        try relatedSeedNote(fixture.database, id: 122, categoryID: 111, bookID: 102, title: "B")
        try relatedSeedNote(fixture.database, id: 123, categoryID: 112, bookID: 101, title: "C")
        try relatedSeedNote(fixture.database, id: 124, categoryID: 112, bookID: 102, title: "Cross-scope")

        // NOTE(ANDROID-WEB-047): 最新 Android “全局”接口有意不加 book_id=0 条件，书内类别也会返回；旧审核项为误报。
        let visible = try await fixture.repository.globalCategories(includeHidden: false)
        #expect(visible.map(\.id).contains(111))
        #expect(visible.map(\.id).contains(112))
        #expect(!visible.map(\.id).contains(113))
        #expect(!visible.map(\.id).contains(114))
        #expect(visible.first { $0.id == 111 }?.contentCount == 2)
        #expect(visible.first { $0.id == 112 }?.contentCount == 1)

        let all = try await fixture.repository.globalCategories(includeHidden: true)
        #expect(all.map(\.id).contains(113))
        let bookCategories = try await fixture.repository.categories(
            bookID: 101,
            includeHidden: true
        )
        #expect(bookCategories.first { $0.id == 111 }?.contentCount == 1)
        #expect(bookCategories.first { $0.id == 112 }?.contentCount == 1)
        await expectRelatedError(.invalidArgument("书籍不存在: 999")) {
            _ = try await fixture.repository.categories(bookID: 999, includeHidden: true)
        }
    }

    @Test
    func categoryCreateAndUpdateKeepDuplicateAndScopeAsymmetries() async throws {
        let fixture = try makeRelatedFixture(now: 8_000)
        try relatedSeedBook(fixture.database, id: 201, name: "One")
        try relatedSeedBook(fixture.database, id: 202, name: "Two")
        try relatedSeedCategory(fixture.database, id: 211, bookID: 0, title: "Shared", order: 20)
        try relatedSeedCategory(fixture.database, id: 212, bookID: 201, title: "Local", order: 30)
        try relatedSeedCategory(fixture.database, id: 213, bookID: 202, title: "Target", order: 40)

        await expectRelatedError(.invalidArgument("类别已存在")) {
            _ = try await fixture.repository.createCategory(
                bookID: 201,
                input: .init(title: "Shared", order: nil, scope: nil)
            )
        }
        let created = try await fixture.repository.createCategory(
            bookID: 201,
            input: .init(title: "  New  ", order: -9, scope: " GLOBAL ")
        )
        #expect(created.bookID == 0)
        #expect(created.title == "New")
        #expect(created.order == 0)
        #expect(created.createdTime == 8_000)

        // Android 更新不做同名检查，且 scope 变化只移动类别自身。
        let updated = try await fixture.repository.updateCategory(
            id: 212,
            input: .init(title: "Target", order: -3, scope: "book", bookID: 202)
        )
        #expect(updated.bookID == 202)
        #expect(updated.title == "Target")
        #expect(updated.order == 0)
        #expect(try relatedFetchCategory(fixture.database, id: 213)?.title == "Target")

        try relatedSeedCategory(fixture.database, id: 299, bookID: 0, title: "书籍", order: 50)
        await expectRelatedError(.invalidArgument("系统默认类别不支持重命名")) {
            _ = try await fixture.repository.updateCategory(
                id: 299,
                input: .init(title: "Books", order: nil, scope: nil, bookID: nil)
            )
        }
        await expectRelatedError(.invalidArgument("系统默认类别不支持修改作用域")) {
            _ = try await fixture.repository.updateCategory(
                id: 299,
                input: .init(title: nil, order: nil, scope: "book", bookID: 201)
            )
        }
        let hidden = try await fixture.repository.updateCategoryVisibility(id: 299, isHidden: true)
        #expect(hidden.isHidden)
    }

    @Test
    func categoryDeleteUsesPhysicalCrossScopeOperationsAndCanPartiallyCommit() async throws {
        let fixture = try makeRelatedFixture()
        try relatedSeedBook(fixture.database, id: 301, name: "One")
        try relatedSeedBook(fixture.database, id: 302, name: "Two")
        try relatedSeedCategory(fixture.database, id: 311, bookID: 0, title: "书籍")
        try relatedSeedNote(fixture.database, id: 321, categoryID: 311, bookID: 301, title: "Default")

        try await fixture.repository.deleteCategory(id: 311)
        #expect(try relatedFetchCategory(fixture.database, id: 311) != nil)
        #expect(try relatedFetchNote(fixture.database, id: 321) == nil)

        try relatedSeedCategory(fixture.database, id: 312, bookID: 301, title: "Same")
        try relatedSeedCategory(fixture.database, id: 313, bookID: 302, title: "Same")
        try relatedSeedNote(fixture.database, id: 322, categoryID: 312, bookID: 301, title: "First")
        try relatedSeedNote(fixture.database, id: 323, categoryID: 313, bookID: 302, title: "Second")
        try relatedSeedImage(fixture.database, id: 331, noteID: 323, url: "keeps-parent")

        // NOTE(ANDROID-WEB-049): 最新 Android 仍按同名跨书籍逐项物理删除且没有共同事务；本测试锁定这一共享历史语义。
        do {
            try await fixture.repository.deleteCategory(id: 312)
            Issue.record("预期 category_image 外键阻止第二个同名类别删除")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(try relatedFetchCategory(fixture.database, id: 312) == nil)
        #expect(try relatedFetchNote(fixture.database, id: 322) == nil)
        #expect(try relatedFetchCategory(fixture.database, id: 313) != nil)
        #expect(try relatedFetchNote(fixture.database, id: 323) != nil)
    }

    @Test
    func categoryReorderRequiresExactSetAndRollsBackOnFailure() async throws {
        let fixture = try makeRelatedFixture(now: 9_000)
        try relatedClearCategories(fixture.database)
        try relatedSeedBook(fixture.database, id: 401, name: "Book")
        try relatedSeedCategory(fixture.database, id: 411, bookID: 0, title: "G", order: 10)
        try relatedSeedCategory(fixture.database, id: 412, bookID: 401, title: "L", order: 11)

        await expectRelatedError(.invalidArgument("类别排序参数不完整")) {
            try await fixture.repository.reorderCategories(bookID: 401, ids: [411, 411])
        }
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_related_reorder
                    BEFORE UPDATE OF `order` ON category
                    WHEN NEW.id = 412
                    BEGIN SELECT RAISE(ABORT, 'boom'); END
                    """
            )
        }
        do {
            try await fixture.repository.reorderCategories(bookID: 401, ids: [411, 412])
            Issue.record("预期第二个类别更新失败")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(try relatedFetchCategory(fixture.database, id: 411)?.order == 10)
        #expect(try relatedFetchCategory(fixture.database, id: 412)?.order == 11)
    }

    @Test
    func sortRuleDefaultsAndUpdatesActiveRowsPlusTombstones() async throws {
        let fixture = try makeRelatedFixture(now: 10_000)
        try relatedSeedBook(fixture.database, id: 501, name: "Book")
        #expect(try await fixture.repository.sortRule(bookID: 501) == .init(sortBy: "create_time", sortOrder: "asc"))
        try relatedSeedSort(fixture.database, id: 511, bookID: 501, order: 1, isDeleted: 0)
        try relatedSeedSort(fixture.database, id: 512, bookID: 501, order: 1, isDeleted: 1)

        #expect(
            try await fixture.repository.updateSortRule(
                bookID: 501,
                sortBy: "CREATE_TIME",
                sortOrder: "DESC"
            ) == .init(sortBy: "create_time", sortOrder: "desc")
        )
        let rows = try relatedFetchSorts(fixture.database, bookID: 501)
        #expect(rows.map(\.order) == [2, 2])
        #expect(rows.map(\.updatedDate) == [10_000, 10_000])
        #expect(rows.map(\.isDeleted) == [0, 1])

        await expectRelatedError(.invalidArgument("相关内容排序仅支持 create_time")) {
            _ = try await fixture.repository.updateSortRule(bookID: 501, sortBy: "title", sortOrder: "asc")
        }
    }

    @Test
    func localAndAllListsRequireActiveParentsAndUsePositiveEmptyPageSize() async throws {
        let fixture = try makeRelatedFixture()
        try relatedSeedBook(fixture.database, id: 601, name: "Deleted", isDeleted: 1)
        try relatedSeedBook(fixture.database, id: 602, name: "Empty")
        try relatedSeedCategory(fixture.database, id: 611, bookID: 601, title: "Gone", isDeleted: 1)
        try relatedSeedNote(fixture.database, id: 621, categoryID: 611, bookID: 601, title: "Later ID", created: 1)
        try relatedSeedNote(fixture.database, id: 622, categoryID: 611, bookID: 601, title: "Earlier Time", created: -99)

        await expectRelatedError(.invalidArgument("书籍不存在: 601")) {
            _ = try await fixture.repository.relatedNotes(
                bookID: 601,
                page: 1,
                pageSize: 20,
                filter: relatedFilter(sortBy: "create_time", sortOrder: "desc")
            )
        }
        await expectRelatedError(.invalidArgument("书籍不存在: 601")) {
            _ = try await fixture.repository.allRelatedNotes(
                bookID: 601,
                filter: relatedFilter(keyword: "earlier", sortBy: "title", sortOrder: "asc")
            )
        }
        let empty = try await fixture.repository.allRelatedNotes(
            bookID: 602,
            filter: relatedFilter()
        )
        #expect(empty.page == 1)
        #expect(empty.pageSize == 1)
        #expect(empty.totalPages == 0)
    }

    @Test
    func globalListFiltersDeletedSourceButIncludesDeletedContentBookAndUnfilteredTotal() async throws {
        let fixture = try makeRelatedFixture()
        try relatedSeedBook(fixture.database, id: 701, name: "Active", translator: "T", pubDate: "2026")
        try relatedSeedBook(fixture.database, id: 702, name: "Deleted Source", isDeleted: 1)
        try relatedSeedBook(fixture.database, id: 703, name: "Deleted Content", isDeleted: 1)
        try relatedSeedCategory(fixture.database, id: 711, bookID: 0, title: "Global")
        try relatedSeedNote(fixture.database, id: 721, categoryID: 711, bookID: 701, title: "One", contentBookID: 703)
        try relatedSeedNote(fixture.database, id: 722, categoryID: 711, bookID: 701, title: "Two")
        try relatedSeedNote(fixture.database, id: 723, categoryID: 711, bookID: 702, title: "Hidden")

        let result = try await fixture.repository.globalRelatedNotes(
            page: 4,
            pageSize: 20,
            filter: .init(
                bookID: 0,
                categoryID: 0,
                keyword: "",
                sortBy: "create_time",
                sortOrder: "desc",
                sortMode: "random",
                excludeIDs: [722, 722, -1]
            )
        )
        #expect(result.items.map(\.note.id) == [721])
        #expect(result.total == 2)
        #expect(result.items.first?.book.name == "Active")
        #expect(result.items.first?.book.translator == "T")
        #expect(result.items.first?.note.contentBook?.name == "Deleted Content")
        #expect(result.items.first?.note.contentBook?.isDeleted == true)
    }

    @Test
    func createAndUpdateNormalizePayloadAndRequireActiveResources() async throws {
        let fixture = try makeRelatedFixture(now: 11_000)
        try relatedSeedBook(fixture.database, id: 801, name: "Source")
        try relatedSeedBook(fixture.database, id: 802, name: "Content")
        try relatedSeedBook(fixture.database, id: 803, name: "Moved Scope")
        try relatedSeedBook(fixture.database, id: 804, name: "Deleted", isDeleted: 1)
        try relatedSeedCategory(fixture.database, id: 811, bookID: 801, title: "Local")
        try relatedSeedCategory(fixture.database, id: 812, bookID: 801, title: "Other")

        let created = try await fixture.repository.createRelatedNote(input: .init(
            bookID: 801,
            categoryID: 811,
            title: "  Title  ",
            content: " <mark data-color=\"#FDFBCA\">C</mark><script>X</script> ",
            url: " url ",
            imageURLs: [" a ", " ", "b"],
            uploadedTicketIDs: nil,
            contentBookID: 802,
            createdTime: 123
        ))
        #expect(created.title == "Title")
        #expect(created.content == "<mark style=\"background-color:-132150\">C</mark>&lt;script>X&lt;/script>")
        #expect(created.url == "url")
        #expect(created.images.map(\.url) == ["a", "b"])
        #expect(created.contentBook?.isDeleted == nil)
        #expect(created.createdTime == 123)

        try await fixture.database.dbPool.write { db in
            try db.execute(sql: "UPDATE category SET book_id = 803, is_deleted = 1 WHERE id = 811")
        }
        await expectRelatedError(.invalidArgument("笔记类别不存在: 811")) {
            _ = try await fixture.repository.updateRelatedNote(
                id: created.id,
                input: .init(
                    categoryID: nil,
                    title: " Next ",
                    content: nil,
                    url: nil,
                    imageURLs: nil,
                    uploadedTicketIDs: nil,
                    contentBookID: -5,
                    createdTime: 0
                )
            )
        }
        #expect(try relatedFetchNote(fixture.database, id: created.id)?.title == "Title")

        await expectRelatedError(.invalidArgument("书籍不存在: 804")) {
            _ = try await fixture.repository.createRelatedNote(input: .init(
                bookID: 804,
                categoryID: 812,
                title: "Deleted source",
                content: nil,
                url: "https://example.com",
                imageURLs: nil,
                uploadedTicketIDs: nil,
                contentBookID: 0,
                createdTime: nil
            ))
        }

        await expectRelatedError(.invalidArgument("笔记内容不能为空")) {
            _ = try await fixture.repository.createRelatedNote(input: .init(
                bookID: 801,
                categoryID: 812,
                title: " ",
                content: "",
                url: nil,
                imageURLs: [" "],
                uploadedTicketIDs: nil,
                contentBookID: 0,
                createdTime: nil
            ))
        }
    }

    @Test
    func deleteAndBatchDeleteUseOneTransactionAndPreserveExistingTombstones() async throws {
        let fixture = try makeRelatedFixture(now: 12_000)
        try relatedSeedBook(fixture.database, id: 901, name: "Book")
        try relatedSeedCategory(fixture.database, id: 911, bookID: 901, title: "Local")
        try relatedSeedNote(fixture.database, id: 921, categoryID: 911, bookID: 901, title: "One")
        try relatedSeedImage(fixture.database, id: 931, noteID: 921, url: "active")
        try relatedSeedImage(fixture.database, id: 932, noteID: 921, url: "old", updated: 1, isDeleted: 1)

        try await fixture.repository.deleteRelatedNote(id: 921)
        #expect(try relatedFetchNote(fixture.database, id: 921)?.isDeleted == 1)
        #expect(try relatedFetchImages(fixture.database, noteID: 921).map(\.isDeleted) == [1, 1])
        #expect(try relatedFetchImages(fixture.database, noteID: 921).map(\.updatedDate) == [12_000, 1])

        try relatedSeedNote(fixture.database, id: 922, categoryID: 911, bookID: 901, title: "Two")
        try relatedSeedNote(fixture.database, id: 923, categoryID: 911, bookID: 901, title: "Already", isDeleted: 1)
        try relatedSeedImage(fixture.database, id: 933, noteID: 922, url: "two")
        try relatedSeedImage(fixture.database, id: 934, noteID: 923, url: "already", updated: 2, isDeleted: 1)
        try await fixture.repository.batchDeleteRelatedNotes(ids: [922, 923, 922, -1])
        #expect(try relatedFetchNote(fixture.database, id: 922)?.isDeleted == 1)
        #expect(try relatedFetchImages(fixture.database, noteID: 923).first?.updatedDate == 2)
    }

    @Test
    func batchCategoryMoveValidatesAllRowsBeforeAtomicUpdate() async throws {
        let fixture = try makeRelatedFixture(now: 13_000)
        try relatedSeedBook(fixture.database, id: 1_001, name: "One")
        try relatedSeedBook(fixture.database, id: 1_002, name: "Two")
        try relatedSeedCategory(fixture.database, id: 1_011, bookID: 0, title: "Global")
        try relatedSeedCategory(fixture.database, id: 1_012, bookID: 1_001, title: "Local")
        try relatedSeedNote(fixture.database, id: 1_021, categoryID: 1_011, bookID: 1_001, title: "One")
        try relatedSeedNote(fixture.database, id: 1_022, categoryID: 1_011, bookID: 1_002, title: "Two")

        await expectRelatedError(.invalidArgument("类别不属于部分笔记所在书籍")) {
            try await fixture.repository.batchUpdateRelatedNotesCategory(
                ids: [1_021, 1_022],
                categoryID: 1_012
            )
        }
        #expect(try relatedFetchNote(fixture.database, id: 1_021)?.categoryId == 1_011)
        #expect(try relatedFetchNote(fixture.database, id: 1_022)?.categoryId == 1_011)

        try await fixture.repository.batchUpdateRelatedNotesCategory(
            ids: [1_021, 1_022, 1_021],
            categoryID: 1_011
        )
        #expect(try relatedFetchNote(fixture.database, id: 1_021)?.updatedDate == 13_000)
        await expectRelatedError(.invalidArgument("部分笔记不存在: 9999")) {
            try await fixture.repository.batchUpdateRelatedNotesCategory(
                ids: [1_021, 9_999],
                categoryID: 1_011
            )
        }
    }
}

private struct RelatedFixture {
    let database: AppDatabase
    let repository: DesktopWebRelatedRepository
}

@MainActor
private func makeRelatedFixture(now: Int64 = 7_000) throws -> RelatedFixture {
    let database = try AppDatabase.empty()
    return RelatedFixture(
        database: database,
        repository: DesktopWebRelatedRepository(database: database, currentTimeMillis: { now })
    )
}

private func relatedFilter(
    categoryID: Int64 = 0,
    keyword: String = "",
    sortBy: String = "create_time",
    sortOrder: String = "desc"
) -> DesktopWebRelatedNoteFilterInput {
    .init(categoryID: categoryID, keyword: keyword, sortBy: sortBy, sortOrder: sortOrder)
}

private func relatedSeedBook(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    translator: String = "",
    pubDate: String = "",
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: name,
            cover: "cover",
            author: "Author",
            translator: translator,
            pubDate: pubDate,
            press: "Press",
            sourceId: 1,
            readStatusId: 1,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func relatedClearCategories(_ database: AppDatabase) throws {
    try database.dbPool.write { db in
        try db.execute(sql: "DELETE FROM category")
    }
}

private func relatedSeedCategory(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    title: String,
    order: Int64 = 0,
    isHidden: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = CategoryRecord(
            id: id,
            bookId: bookID,
            title: title,
            order: order,
            isHide: isHidden,
            createdDate: 100,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func relatedSeedNote(
    _ database: AppDatabase,
    id: Int64,
    categoryID: Int64,
    bookID: Int64,
    title: String,
    content: String = "",
    contentBookID: Int64 = 0,
    created: Int64 = 100,
    updated: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = CategoryContentRecord(
            id: id,
            categoryId: categoryID,
            bookId: bookID,
            title: title,
            content: content,
            contentBookId: contentBookID,
            url: "",
            createdDate: created,
            updatedDate: updated,
            lastSyncDate: 0,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func relatedSeedImage(
    _ database: AppDatabase,
    id: Int64,
    noteID: Int64,
    url: String,
    updated: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = CategoryImageRecord(
            id: id,
            categoryContentId: noteID,
            image: url,
            order: 0,
            createdDate: 100,
            updatedDate: updated,
            lastSyncDate: 0,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func relatedSeedSort(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    order: Int64,
    isDeleted: Int64
) throws {
    try database.dbPool.write { db in
        var record = SortRecord(
            id: id,
            bookId: bookID,
            type: 3,
            order: order,
            createdDate: 100,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func relatedFetchCategory(_ database: AppDatabase, id: Int64) throws -> CategoryRecord? {
    try database.dbPool.read { db in try CategoryRecord.fetchOne(db, key: id) }
}

private func relatedFetchNote(_ database: AppDatabase, id: Int64) throws -> CategoryContentRecord? {
    try database.dbPool.read { db in try CategoryContentRecord.fetchOne(db, key: id) }
}

private func relatedFetchImages(_ database: AppDatabase, noteID: Int64) throws -> [CategoryImageRecord] {
    try database.dbPool.read { db in
        try CategoryImageRecord
            .filter(Column("category_content_id") == noteID)
            .order(Column("id"))
            .fetchAll(db)
    }
}

private func relatedFetchSorts(_ database: AppDatabase, bookID: Int64) throws -> [SortRecord] {
    try database.dbPool.read { db in
        try SortRecord
            .filter(Column("book_id") == bookID && Column("type") == 3)
            .order(Column("id"))
            .fetchAll(db)
    }
}

@MainActor
private func expectRelatedError(
    _ expected: DesktopWebCatalogRepositoryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("预期错误：\(expected)")
    } catch let error as DesktopWebCatalogRepositoryError {
        #expect(error == expected)
    } catch {
        Issue.record("错误类型不匹配：\(error)")
    }
}
