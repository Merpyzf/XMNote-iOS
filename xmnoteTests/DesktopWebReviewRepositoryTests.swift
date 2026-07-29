/**
 * [INPUT]: 依赖 AppDatabase.empty、GRDB Record、隔离 UserDefaults 与 DesktopWebReviewRepository
 * [OUTPUT]: 验证 11 条 Review API 的列表、草稿、排序、富文本、CRUD、软删除和 Android 缺陷兼容边界
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android Web 书评域当前可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct DesktopWebReviewRepositoryTests {
    @Test
    func globalListFiltersDeletedBooksAndKeepsRandomExclusionOutOfTotal() async throws {
        let fixture = try makeReviewFixture()
        try reviewSeedBook(fixture.database, id: 11, name: "Active", cover: "cover")
        try reviewSeedBook(fixture.database, id: 12, name: "Deleted", isDeleted: 1)
        try reviewSeedReview(fixture.database, id: 101, bookID: 11, title: "One", content: "Alpha", created: 10)
        try reviewSeedReview(fixture.database, id: 102, bookID: 11, title: "Two", content: "beta", created: 20)
        try reviewSeedReview(fixture.database, id: 103, bookID: 12, title: "Hidden", content: "Alpha", created: 30)
        try reviewSeedImage(fixture.database, id: 201, reviewID: 101, url: "image", order: 0)

        let wildcard = try await fixture.repository.globalReviews(
            page: 1,
            pageSize: 20,
            filter: reviewGlobalFilter(keyword: "%", sortOrder: "asc")
        )
        #expect(wildcard.items.map(\.id) == [101, 102])
        #expect(wildcard.items.first?.book.name == "Active")
        #expect(wildcard.items.first?.images == [.init(id: 201, url: "image")])

        let caseInsensitive = try await fixture.repository.globalReviews(
            page: 1,
            pageSize: 20,
            filter: reviewGlobalFilter(keyword: "ALPHA")
        )
        #expect(caseInsensitive.items.map(\.id) == [101])

        let random = try await fixture.repository.globalReviews(
            page: 4,
            pageSize: 20,
            filter: reviewGlobalFilter(sortMode: "random", excludeIDs: [101, 101, -1])
        )
        #expect(random.total == 2)
        #expect(random.items.map(\.id) == [102])
    }

    @Test
    func wordCountSortUsesTheSameVisibleUTF16LengthAsResponse() async throws {
        let fixture = try makeReviewFixture()
        try reviewSeedBook(fixture.database, id: 21, name: "Book")
        try reviewSeedReview(fixture.database, id: 211, bookID: 21, title: "", content: "<b>A</b>", created: 10)
        try reviewSeedReview(fixture.database, id: 212, bookID: 21, title: "", content: "BBBB", created: 20)
        try reviewSeedReview(fixture.database, id: 213, bookID: 21, title: "😀", content: "", created: 30)

        let page = try await fixture.repository.bookReviews(
            bookID: 21,
            page: 1,
            pageSize: 20,
            sortBy: "word_count",
            sortOrder: "desc"
        )
        #expect(page.items.prefix(2).map(\.id) == [212, 213])
        #expect(page.items.first { $0.id == 211 }?.wordCount == 1)
        #expect(page.items.first { $0.id == 212 }?.wordCount == 4)
        #expect(page.items.first { $0.id == 213 }?.wordCount == 2)
    }

    @Test
    func sortRuleDefaultsUpdatesAndBookListRejectsDeletedBook() async throws {
        let fixture = try makeReviewFixture(now: 9_000)
        try reviewSeedBook(fixture.database, id: 31, name: "Active")
        try reviewSeedBook(fixture.database, id: 32, name: "Deleted", isDeleted: 1)
        try reviewSeedReview(fixture.database, id: 311, bookID: 31, title: "A", created: 20)
        try reviewSeedReview(fixture.database, id: 312, bookID: 31, title: "B", created: 10)

        #expect(try await fixture.repository.bookReviewSortRule(bookID: 31) == .init(sortBy: "create_time", sortOrder: "asc"))
        let page = try await fixture.repository.bookReviews(
            bookID: 31,
            page: 1,
            pageSize: 1,
            sortBy: "create_time",
            sortOrder: "asc"
        )
        #expect(page.items.map(\.id) == [312])
        #expect(page.total == 2)
        #expect(page.totalPages == 2)

        await expectReviewError(.invalidArgument("不支持的书评排序规则: word_count_desc")) {
            _ = try await fixture.repository.updateBookReviewSortRule(
                bookID: 31,
                sortBy: "word_count",
                sortOrder: "desc"
            )
        }
        #expect(
            try await fixture.repository.updateBookReviewSortRule(
                bookID: 31,
                sortBy: "create_time",
                sortOrder: "desc"
            ) == .init(sortBy: "create_time", sortOrder: "desc")
        )
        let stored = try await fixture.database.dbPool.read { db in try SortRecord.fetchOne(db) }
        #expect(stored?.bookId == 31)
        #expect(stored?.type == 4)
        #expect(stored?.order == 2)
        #expect(stored?.createdDate == 9_000)
        #expect(stored?.updatedDate == 0)

        await expectReviewError(.notFound("书籍不存在: 32")) {
            _ = try await fixture.repository.bookReviews(
                bookID: 32,
                page: 1,
                pageSize: 20,
                sortBy: "create_time",
                sortOrder: "asc"
            )
        }
    }

    @Test
    func draftNormalizesPersistsClearsAndValidatesBooksConsistently() async throws {
        let fixture = try makeReviewFixture(now: 8_000)
        try reviewSeedBook(fixture.database, id: 41, name: "Book")

        await expectReviewError(.invalidArgument("书籍不存在: 999")) {
            _ = try await fixture.repository.reviewDraft(bookID: 999, reviewID: 0)
        }
        await expectReviewError(.invalidArgument("书籍不存在: 999")) {
            try await fixture.repository.deleteReviewDraft(bookID: 999, reviewID: 0)
        }
        await expectReviewError(.invalidArgument("书籍不存在: 999")) {
            _ = try await fixture.repository.upsertReviewDraft(
                reviewDraftInput(bookID: 999, title: "D")
            )
        }

        let saved = try await fixture.repository.upsertReviewDraft(.init(
            bookID: 41,
            reviewID: 7,
            title: "  Draft  ",
            content: "<mark data-color=\"#FDFBCA\">C</mark><script>X</script>",
            imageURLs: [" a ", " ", "b"],
            uploadedTicketIDs: ["ticket"],
            createdTime: -1,
            savedTimeMillis: -1
        ))
        #expect(saved.title == "Draft")
        #expect(saved.content == "<mark style=\"background-color:-132150\">C</mark>&lt;script>X&lt;/script>")
        #expect(saved.imageURLs == ["a", "b"])
        #expect(saved.createdTime == nil)
        #expect(saved.savedTimeMillis == 8_000)
        #expect(try await fixture.repository.reviewDraft(bookID: 41, reviewID: 7) == saved)

        let cleared = try await fixture.repository.upsertReviewDraft(.init(
            bookID: 41,
            reviewID: 7,
            title: " ",
            content: "",
            imageURLs: [" "],
            uploadedTicketIDs: nil,
            createdTime: nil,
            savedTimeMillis: 99
        ))
        #expect(cleared.savedTimeMillis == 99)
        #expect(try await fixture.repository.reviewDraft(bookID: 41, reviewID: 7) == nil)

        await expectReviewError(.invalidArgument("bookId 必须大于 0")) {
            _ = try await fixture.repository.reviewDraft(bookID: 0, reviewID: 0)
        }
        await expectReviewError(.invalidArgument("reviewId 不能小于 0")) {
            try await fixture.repository.deleteReviewDraft(bookID: 41, reviewID: -1)
        }

        let failingFixture = try makeReviewFixture(
            now: 8_100,
            commitUploadedTickets: { _, _ in throw ReviewFixtureError.ticketCommitFailed }
        )
        try reviewSeedBook(failingFixture.database, id: 42, name: "Ticket failure")
        // 票据提交失败时清理本轮草稿，保持偏好与上传票据状态一致。
        do {
            _ = try await failingFixture.repository.upsertReviewDraft(.init(
                bookID: 42,
                reviewID: 0,
                title: "Draft",
                content: nil,
                imageURLs: ["image"],
                uploadedTicketIDs: ["ticket"],
                createdTime: nil,
                savedTimeMillis: nil
            ))
            Issue.record("预期上传票据提交失败")
        } catch {
            #expect(error as? ReviewFixtureError == .ticketCommitFailed)
        }
        #expect(try await failingFixture.repository.reviewDraft(bookID: 42, reviewID: 0) == nil)
    }

    @Test
    func createCanonicalizesHTMLFiltersBlankImagesAndReturnsStoredIDs() async throws {
        let fixture = try makeReviewFixture(now: 9_000)
        try reviewSeedBook(fixture.database, id: 51, name: "Book")

        let result = try await fixture.repository.createReview(.init(
            bookID: 51,
            title: "  Title  ",
            content: "<mark data-color=\"#FDFBCA\">C</mark><script>X</script>",
            imageURLs: ["", "second"],
            uploadedTicketIDs: nil,
            createdTime: 123
        ))
        #expect(result.title == "Title")
        #expect(result.content == "<mark style=\"background-color:-132150\">C</mark>&lt;script>X&lt;/script>")
        #expect(result.createdTime == 123)
        #expect(result.images == [.init(id: 1, url: "second")])
        let storedImages = try reviewFetchImages(fixture.database, reviewID: result.id, activeOnly: true)
        #expect(storedImages.map(\.image) == ["second"])
        #expect(storedImages.compactMap(\.id) == result.images.map(\.id))

        await expectReviewError(.invalidArgument("请至少填写一项内容（标题、书评内容）")) {
            _ = try await fixture.repository.createReview(.init(
                bookID: 51,
                title: " ",
                content: "\n",
                imageURLs: ["image"],
                uploadedTicketIDs: nil,
                createdTime: nil
            ))
        }
    }

    @Test
    func detailAndUpdateRejectReviewUnderDeletedBook() async throws {
        let fixture = try makeReviewFixture(now: 9_500)
        try reviewSeedBook(fixture.database, id: 61, name: "Deleted", isDeleted: 1)
        try reviewSeedReview(fixture.database, id: 611, bookID: 61, title: "Old", content: "Body", created: 100)
        try reviewSeedImage(fixture.database, id: 621, reviewID: 611, url: "old", order: 0)

        await expectReviewError(.invalidArgument("书评不存在: 611")) {
            _ = try await fixture.repository.review(id: 611)
        }
        await expectReviewError(.invalidArgument("书评不存在: 611")) {
            _ = try await fixture.repository.updateReview(
                id: 611,
                input: .init(
                    title: " New ",
                    content: nil,
                    imageURLs: nil,
                    uploadedTicketIDs: ["ignored"],
                    createdTime: 0
                )
            )
        }
        #expect(try reviewFetch(fixture.database, id: 611)?.title == "Old")
        #expect(try reviewFetchImages(fixture.database, reviewID: 611, activeOnly: true).map(\.id) == [621])

        await expectReviewError(.invalidArgument("书评不存在: 999")) {
            _ = try await fixture.repository.updateReview(
                id: 999,
                input: .init(title: "X", content: nil, imageURLs: nil, uploadedTicketIDs: nil, createdTime: nil)
            )
        }
    }

    @Test
    func deleteRejectsReviewUnderDeletedBook() async throws {
        let fixture = try makeReviewFixture(now: 10_000)
        try reviewSeedBook(fixture.database, id: 71, name: "Deleted", isDeleted: 1)
        try reviewSeedReview(fixture.database, id: 711, bookID: 71, title: "T", created: 100)
        try reviewSeedImage(fixture.database, id: 721, reviewID: 711, url: "u", order: 0)

        await expectReviewError(.invalidArgument("书评不存在: 711")) {
            try await fixture.repository.deleteReview(id: 711)
        }
        let review = try reviewFetch(fixture.database, id: 711)
        let image = try #require(reviewFetchImages(fixture.database, reviewID: 711, activeOnly: false).first)
        #expect(review?.isDeleted == 0)
        #expect(review?.updatedDate == 0)
        #expect(image.isDeleted == 0)
        #expect(image.updatedDate == 0)
    }

    @Test
    func deleteMainRowFailureRollsBackImageDeletion() async throws {
        let fixture = try makeReviewFixture(now: 11_000)
        try reviewSeedBook(fixture.database, id: 81, name: "Book")
        try reviewSeedReview(fixture.database, id: 811, bookID: 81, title: "T", created: 100)
        try reviewSeedImage(fixture.database, id: 821, reviewID: 811, url: "u", order: 0)
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_review_delete
                    BEFORE UPDATE OF is_deleted ON review
                    WHEN NEW.id = 811 AND NEW.is_deleted = 1
                    BEGIN
                        SELECT RAISE(ABORT, 'boom');
                    END
                    """
            )
        }

        do {
            try await fixture.repository.deleteReview(id: 811)
            Issue.record("预期主记录触发器中止删除")
        } catch {
            #expect(error is DatabaseError)
        }
        #expect(try reviewFetch(fixture.database, id: 811)?.isDeleted == 0)
        let image = try #require(reviewFetchImages(fixture.database, reviewID: 811, activeOnly: false).first)
        #expect(image.isDeleted == 0)
        #expect(image.updatedDate == 0)
    }
}

private struct ReviewFixture {
    let database: AppDatabase
    let repository: DesktopWebReviewRepository
}

private enum ReviewFixtureError: Error, Equatable {
    case ticketCommitFailed
}

@MainActor
private func makeReviewFixture(
    now: Int64 = 7_000,
    commitUploadedTickets: @escaping @Sendable ([String]?, [String]) throws -> Void = { _, _ in }
) throws -> ReviewFixture {
    let database = try AppDatabase.empty()
    let defaults = try #require(UserDefaults(suiteName: "DesktopWebReviewRepositoryTests.\(UUID().uuidString)"))
    let store = DesktopWebReviewDraftStore(defaults: defaults)
    return ReviewFixture(
        database: database,
        repository: DesktopWebReviewRepository(
            database: database,
            draftStore: store,
            currentTimeMillis: { now },
            commitUploadedTickets: commitUploadedTickets
        )
    )
}

private func reviewGlobalFilter(
    keyword: String = "",
    bookID: Int64 = 0,
    sortBy: String = "create_time",
    sortOrder: String = "desc",
    sortMode: String = "latest",
    excludeIDs: [Int64] = []
) -> DesktopWebGlobalReviewFilterInput {
    .init(
        keyword: keyword,
        bookID: bookID,
        sortBy: sortBy,
        sortOrder: sortOrder,
        sortMode: sortMode,
        excludeIDs: excludeIDs
    )
}

private func reviewDraftInput(
    bookID: Int64,
    reviewID: Int64 = 0,
    title: String? = nil
) -> DesktopWebReviewDraftInput {
    .init(
        bookID: bookID,
        reviewID: reviewID,
        title: title,
        content: nil,
        imageURLs: nil,
        uploadedTicketIDs: nil,
        createdTime: nil,
        savedTimeMillis: nil
    )
}

private func reviewSeedBook(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    cover: String = "",
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: name,
            cover: cover,
            author: "Author",
            press: "Press",
            sourceId: 1,
            readStatusId: 1,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func reviewSeedReview(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    title: String,
    content: String = "",
    created: Int64,
    updated: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = ReviewRecord(
            id: id,
            bookId: bookID,
            title: title,
            content: content,
            createdDate: created,
            updatedDate: updated,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func reviewSeedImage(
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

private func reviewFetch(_ database: AppDatabase, id: Int64) throws -> ReviewRecord? {
    try database.dbPool.read { db in try ReviewRecord.fetchOne(db, key: id) }
}

private func reviewFetchImages(
    _ database: AppDatabase,
    reviewID: Int64,
    activeOnly: Bool
) throws -> [ReviewImageRecord] {
    try database.dbPool.read { db in
        var request = ReviewImageRecord.filter(Column("review_id") == reviewID)
        if activeOnly { request = request.filter(Column("is_deleted") == 0) }
        return try request.order(Column("id")).fetchAll(db)
    }
}

@MainActor
private func expectReviewError(
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
