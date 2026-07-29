/**
 * [INPUT]: 依赖 AppDatabase.empty、V44 GRDB Record、DesktopWebSearchRepository 与 DesktopWebAPIAdapter
 * [OUTPUT]: 验证两条 Search API 的四域筛选、混合来源、软删除、分页溢出、投影与聚合降级
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android SearchService/Web*Repository 当前可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
import XMNoteWeb
@testable import xmnote

@MainActor
struct DesktopWebSearchRepositoryTests {
    @Test
    func bookSearchAppliesTagToBookshelfAndRelatedBookSources() async throws {
        let fixture = try makeSearchFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try searchSeedTag(fixture.database, id: 10_001, name: "Selected")
        try searchSeedBook(fixture.database, id: 10_011, name: "Match Shelf", order: 9)
        try searchSeedBook(fixture.database, id: 10_012, name: "Source")
        try searchSeedBook(
            fixture.database,
            id: 10_013,
            name: "Match Related New",
            updated: 50,
            isDeleted: 1
        )
        try searchSeedBook(
            fixture.database,
            id: 10_014,
            name: "Match Related Deleted",
            translator: "译者",
            pubDate: "2026",
            isDeleted: 1
        )
        try searchSeedTagBook(fixture.database, id: 10_021, bookID: 10_011, tagID: 10_001)
        try searchSeedTagBook(fixture.database, id: 10_022, bookID: 10_013, tagID: 10_001)
        try searchSeedCategory(fixture.database, id: 10_031, bookID: 0, title: "Global")
        try searchSeedRelevant(
            fixture.database,
            id: 10_041,
            categoryID: 10_031,
            sourceBookID: 10_012,
            contentBookID: 10_014,
            updated: 300
        )
        try searchSeedRelevant(
            fixture.database,
            id: 10_042,
            categoryID: 10_031,
            sourceBookID: 10_012,
            contentBookID: 10_013,
            updated: 200
        )
        try searchSeedRelevant(
            fixture.database,
            id: 10_043,
            categoryID: 10_031,
            sourceBookID: 10_012,
            contentBookID: 10_013,
            updated: 100
        )

        let page = try await fixture.repository.searchBooks(
            keyword: "Match",
            page: 1,
            pageSize: 2,
            tagID: 10_001
        )
        let books = searchBooks(page)
        #expect(books.map(\.book.id) == [10_011, 10_013])
        #expect(books.map(\.searchSource) == ["bookshelf", "related_content_book"])
        #expect(books[0].isInBookshelf)
        #expect(!books[0].fromRelatedContentBook)
        #expect(!books[1].isInBookshelf)
        #expect(books[1].fromRelatedContentBook)
        #expect(page.total == 2)
        #expect(page.totalPages == 1)

        let secondPage = try await fixture.repository.searchBooks(
            keyword: "Match",
            page: 2,
            pageSize: 2,
            tagID: 10_001
        )
        #expect(searchBooks(secondPage).isEmpty)

        let blank = try await fixture.repository.searchBooks(
            keyword: " \n",
            page: 1,
            pageSize: 20,
            tagID: 10_001
        )
        #expect(searchBooks(blank).map(\.book.id) == [10_011])
    }

    @Test
    func bookSearchKeepsExtremePaginationOverflowSafe() async throws {
        let fixture = try makeSearchFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try searchSeedBook(fixture.database, id: 11_001, name: "Book")

        let page = try await fixture.repository.searchBooks(
            keyword: "",
            page: 3,
            pageSize: Int(Int32.max),
            tagID: 0
        )
        #expect(searchBooks(page).isEmpty)
        #expect(page.total == 1)
    }

    @Test
    func noteSearchTreatsDeletedTagsAsAbsent() async throws {
        let fixture = try makeSearchFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try searchSeedBook(fixture.database, id: 12_001, name: "Active")
        try searchSeedBook(fixture.database, id: 12_002, name: "Deleted", isDeleted: 1)
        try searchSeedChapter(
            fixture.database,
            id: 12_011,
            bookID: 12_001,
            title: "Deleted Chapter",
            isDeleted: 1
        )
        try searchSeedTag(fixture.database, id: 12_021, name: "Deleted Tag", isDeleted: 1)
        try searchSeedNote(
            fixture.database,
            id: 12_031,
            bookID: 12_001,
            chapterID: 12_011,
            content: "Needle",
            idea: "Idea",
            created: 20
        )
        try searchSeedNote(
            fixture.database,
            id: 12_032,
            bookID: 12_001,
            content: "Other",
            created: 10
        )
        try searchSeedNote(
            fixture.database,
            id: 12_033,
            bookID: 12_002,
            content: "Needle hidden source",
            created: 30
        )
        try searchSeedNote(
            fixture.database,
            id: 12_034,
            bookID: 12_001,
            content: "Needle deleted note",
            created: 40,
            isDeleted: 1
        )
        try searchSeedTagNote(fixture.database, id: 12_041, noteID: 12_031, tagID: 12_021)
        try searchSeedNoteImage(fixture.database, id: 12_051, noteID: 12_031, url: "active-image")
        try searchSeedNoteImage(
            fixture.database,
            id: 12_052,
            noteID: 12_031,
            url: "deleted-image",
            isDeleted: 1
        )

        let tagPage = try await fixture.repository.searchNotes(
            keyword: "Needle",
            page: 1,
            pageSize: 20,
            bookID: 0,
            tagID: 12_021
        )
        let notes = searchNotes(tagPage)
        #expect(notes.isEmpty)

        #expect(
            searchNotes(
                try await fixture.repository.searchNotes(
                    keyword: "",
                    page: 1,
                    pageSize: 20,
                    bookID: 0,
                    tagID: DesktopWebSearchRepository.hasAnyTag
                )
            ).isEmpty
        )
        #expect(
            searchNotes(
                try await fixture.repository.searchNotes(
                    keyword: "",
                    page: 1,
                    pageSize: 20,
                    bookID: 0,
                    tagID: DesktopWebSearchRepository.noTag
                )
            ).map(\.id) == [12_031, 12_032]
        )
        #expect(
            searchNotes(
                try await fixture.repository.searchNotes(
                    keyword: "",
                    page: 1,
                    pageSize: 20,
                    bookID: 0,
                    tagID: DesktopWebSearchRepository.hasIdea
                )
            ).map(\.id) == [12_031]
        )
        #expect(
            searchNotes(
                try await fixture.repository.searchNotes(
                    keyword: "",
                    page: 1,
                    pageSize: 20,
                    bookID: 0,
                    tagID: DesktopWebSearchRepository.hasImage
                )
            ).map(\.id) == [12_031]
        )
    }

    @Test
    func reviewSearchFiltersDeletedSourcesAndUsesCreatedThenIDOrdering() async throws {
        let fixture = try makeSearchFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try searchSeedBook(fixture.database, id: 13_001, name: "Active")
        try searchSeedBook(fixture.database, id: 13_002, name: "Deleted", isDeleted: 1)
        try searchSeedReview(
            fixture.database,
            id: 13_011,
            bookID: 13_001,
            title: "Needle A",
            content: "Body",
            created: 20
        )
        try searchSeedReview(
            fixture.database,
            id: 13_012,
            bookID: 13_001,
            title: "Needle B",
            content: "Body",
            created: 20
        )
        try searchSeedReview(
            fixture.database,
            id: 13_013,
            bookID: 13_002,
            title: "Needle Hidden",
            content: "Body",
            created: 30
        )
        try searchSeedReviewImage(
            fixture.database,
            id: 13_021,
            reviewID: 13_011,
            url: "second",
            order: 2
        )
        try searchSeedReviewImage(
            fixture.database,
            id: 13_022,
            reviewID: 13_011,
            url: "first",
            order: 1
        )
        try searchSeedReviewImage(
            fixture.database,
            id: 13_023,
            reviewID: 13_011,
            url: "deleted",
            order: 0,
            isDeleted: 1
        )

        let page = try await fixture.repository.searchReviews(
            keyword: "needle",
            page: 1,
            pageSize: 1,
            bookID: 0
        )
        let reviews = searchReviews(page)
        #expect(reviews.map(\.id) == [13_011])
        #expect(reviews.first?.previewImageURLs == ["first", "second"])
        #expect(reviews.first?.book.name == "Active")
        #expect(reviews.first?.book.translator == nil)
        #expect(page.total == 2)
        #expect(page.totalPages == 2)

        let second = try await fixture.repository.searchReviews(
            keyword: "needle",
            page: 2,
            pageSize: 1,
            bookID: 0
        )
        #expect(searchReviews(second).map(\.id) == [13_012])
    }

    @Test
    func relevantSearchFiltersDeletedSourcesButKeepsAndroidDeletedCategoryBehavior() async throws {
        let fixture = try makeSearchFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        try searchSeedBook(fixture.database, id: 14_001, name: "Active Source")
        try searchSeedBook(fixture.database, id: 14_002, name: "Deleted Source", isDeleted: 1)
        try searchSeedBook(
            fixture.database,
            id: 14_003,
            name: "Deleted Content",
            translator: "Translator",
            pubDate: "2025",
            isDeleted: 1
        )
        try searchSeedCategory(
            fixture.database,
            id: 14_011,
            bookID: 0,
            title: "Deleted Category",
            isDeleted: 1
        )
        try searchSeedCategory(fixture.database, id: 14_012, bookID: 0, title: "Visible Category")
        try searchSeedRelevant(
            fixture.database,
            id: 14_021,
            categoryID: 14_011,
            sourceBookID: 14_001,
            contentBookID: 14_003,
            title: " ",
            content: "\n",
            url: nil,
            created: 30
        )
        try searchSeedRelevant(
            fixture.database,
            id: 14_022,
            categoryID: 14_012,
            sourceBookID: 14_001,
            title: "Needle data",
            content: "Body",
            url: "url",
            created: 20
        )
        try searchSeedRelevant(
            fixture.database,
            id: 14_023,
            categoryID: 14_012,
            sourceBookID: 14_002,
            title: "Needle hidden",
            created: 40
        )
        try searchSeedRelevantImage(
            fixture.database,
            id: 14_031,
            relevantID: 14_022,
            url: "second",
            order: 2
        )
        try searchSeedRelevantImage(
            fixture.database,
            id: 14_032,
            relevantID: 14_022,
            url: "first",
            order: 1
        )

        let all = try await fixture.repository.searchRelevant(
            keyword: " \n",
            page: 1,
            pageSize: 20,
            bookID: 0
        )
        let relevant = searchRelevant(all)
        #expect(relevant.map(\.id) == [14_021, 14_022])
        #expect(relevant[0].displayKind == "book")
        #expect(relevant[0].categoryTitle == nil)
        #expect(relevant[0].previewImageURLs.isEmpty)
        #expect(relevant[1].displayKind == "data")
        #expect(relevant[1].categoryTitle == "Visible Category")
        #expect(relevant[1].previewImageURLs == ["first", "second"])

        let filtered = try await fixture.repository.searchRelevant(
            keyword: "Needle",
            page: 1,
            pageSize: 20,
            bookID: 14_001
        )
        #expect(searchRelevant(filtered).map(\.id) == [14_022])
    }

    @Test
    func adapterAggregateKeepsEveryDomainFailureAsAnEmptyPage() async throws {
        let fixture = try makeSearchFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let adapter = DesktopWebAPIAdapter(
            repository: DesktopWebSettingsRepository(defaults: fixture.defaults),
            nativeActionBridge: DesktopWebNativeActionBridge(),
            defaults: fixture.defaults,
            isPremiumProvider: { true }
        )

        let result = await adapter.searchAggregate(
            keyword: "k",
            page: 3,
            pageSize: 7,
            bookID: 9,
            tagID: -1
        )
        #expect(result.book.items.isEmpty)
        #expect(result.note.items.isEmpty)
        #expect(result.relevant.items.isEmpty)
        #expect(result.review.items.isEmpty)
        #expect(result.book.pagination.page == 3)
        #expect(result.book.pagination.pageSize == 7)
        #expect(result.errors.book == "数据库尚未就绪")
        #expect(result.errors.note == "数据库尚未就绪")
        #expect(result.errors.relevant == "数据库尚未就绪")
        #expect(result.errors.review == "数据库尚未就绪")
    }
}

private struct SearchFixture {
    let database: AppDatabase
    let repository: DesktopWebSearchRepository
    let defaults: UserDefaults
    let suiteName: String
}

@MainActor
private func makeSearchFixture() throws -> SearchFixture {
    let database = try AppDatabase.empty()
    let suiteName = "DesktopWebSearchRepositoryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let book = DesktopWebBookRepository(database: database)
    let note = DesktopWebNoteRepository(database: database)
    let review = DesktopWebReviewRepository(
        database: database,
        draftStore: DesktopWebReviewDraftStore(defaults: defaults)
    )
    return SearchFixture(
        database: database,
        repository: DesktopWebSearchRepository(
            database: database,
            bookRepository: book,
            noteRepository: note,
            reviewRepository: review
        ),
        defaults: defaults,
        suiteName: suiteName
    )
}

private func searchBooks(_ page: DesktopWebSearchPageSnapshot) -> [DesktopWebSearchBookSnapshot] {
    page.items.compactMap { item in
        guard case .book(let value) = item else { return nil }
        return value
    }
}

private func searchNotes(_ page: DesktopWebSearchPageSnapshot) -> [DesktopWebSearchNoteSnapshot] {
    page.items.compactMap { item in
        guard case .note(let value) = item else { return nil }
        return value
    }
}

private func searchReviews(_ page: DesktopWebSearchPageSnapshot) -> [DesktopWebSearchReviewSnapshot] {
    page.items.compactMap { item in
        guard case .review(let value) = item else { return nil }
        return value
    }
}

private func searchRelevant(_ page: DesktopWebSearchPageSnapshot) -> [DesktopWebSearchRelevantSnapshot] {
    page.items.compactMap { item in
        guard case .relevant(let value) = item else { return nil }
        return value
    }
}

private func searchSeedBook(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    translator: String = "",
    pubDate: String = "",
    order: Int64 = 0,
    updated: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: name,
            cover: "cover-\(id)",
            author: "Author",
            translator: translator,
            pubDate: pubDate,
            press: "Press",
            sourceId: 1,
            bookOrder: order,
            readStatusId: 1,
            createdDate: 100,
            updatedDate: updated,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedTag(
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
            type: 3,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedTagBook(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    tagID: Int64
) throws {
    try database.dbPool.write { db in
        var record = TagBookRecord(id: id, bookId: bookID, tagId: tagID, createdDate: 100)
        try record.insert(db)
    }
}

private func searchSeedCategory(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    title: String,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = CategoryRecord(
            id: id,
            bookId: bookID,
            title: title,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedRelevant(
    _ database: AppDatabase,
    id: Int64,
    categoryID: Int64,
    sourceBookID: Int64,
    contentBookID: Int64 = 0,
    title: String? = nil,
    content: String? = nil,
    url: String? = nil,
    created: Int64 = 100,
    updated: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = CategoryContentRecord(
            id: id,
            categoryId: categoryID,
            bookId: sourceBookID,
            title: title,
            content: content,
            contentBookId: contentBookID,
            url: url,
            createdDate: created,
            updatedDate: updated,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedChapter(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    title: String,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = ChapterRecord(
            id: id,
            bookId: bookID,
            title: title,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedNote(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    chapterID: Int64 = 0,
    content: String,
    idea: String = "",
    created: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = NoteRecord(
            id: id,
            bookId: bookID,
            chapterId: chapterID,
            content: content,
            idea: idea,
            includeTime: 1,
            createdDate: created,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedTagNote(
    _ database: AppDatabase,
    id: Int64,
    noteID: Int64,
    tagID: Int64
) throws {
    try database.dbPool.write { db in
        var record = TagNoteRecord(id: id, tagId: tagID, noteId: noteID, createdDate: 100)
        try record.insert(db)
    }
}

private func searchSeedNoteImage(
    _ database: AppDatabase,
    id: Int64,
    noteID: Int64,
    url: String,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = AttachImageRecord(
            id: id,
            noteId: noteID,
            imageUrl: url,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedReview(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    title: String,
    content: String,
    created: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = ReviewRecord(
            id: id,
            bookId: bookID,
            title: title,
            content: content,
            createdDate: created,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedReviewImage(
    _ database: AppDatabase,
    id: Int64,
    reviewID: Int64,
    url: String,
    order: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = ReviewImageRecord(
            id: id,
            reviewId: reviewID,
            image: url,
            order: order,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func searchSeedRelevantImage(
    _ database: AppDatabase,
    id: Int64,
    relevantID: Int64,
    url: String,
    order: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = CategoryImageRecord(
            id: id,
            categoryContentId: relevantID,
            image: url,
            order: order,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

@MainActor
private func expectSearchError(
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
