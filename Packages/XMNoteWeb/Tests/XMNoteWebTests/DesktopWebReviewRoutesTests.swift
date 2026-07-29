/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebReviewRoutes 与可观测 ReviewPort stub
 * [OUTPUT]: 验证 11 条书评 API 的查询归一化、草稿、排序、CRUD、错误包络与会员写门禁
 * [POS]: XMNoteWeb Package 书评路由单元测试，锁定 Android ReviewController 全量 HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebReviewRoutesTests {
    @Test
    func globalListNormalizesAndroidQueriesAndReturnsFullShape() async throws {
        let port = ReviewPortStub()
        try await withReviewAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/reviews?page=0&pageSize=0&keyword=%20key%20&bookId=7&sortBy=WORD_COUNT&sortOrder=ASC&sortMode=random&excludeIds=3,x,-1,3",
                method: .get
            ) { response in
                let data = try #require(reviewEnvelope(response)["data"] as? [String: Any])
                let pagination = try #require(data["pagination"] as? [String: Any])
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 1)
                let item = try #require((data["items"] as? [[String: Any]])?.first)
                #expect(item["title"] as? String == "标题")
                #expect((item["book"] as? [String: Any])?["name"] as? String == "书")
            }
        }
        #expect(
            await port.globalCall
                == ReviewGlobalCall(
                    page: 1,
                    pageSize: 1,
                    filter: DesktopWebGlobalReviewFilter(
                        keyword: " key ",
                        bookID: 7,
                        sortBy: "word_count",
                        sortOrder: "asc",
                        sortMode: "random",
                        excludeIDs: [3, -1, 3]
                    )
                )
        )
    }

    @Test
    func draftRoutesApplyReviewIDDefaultAndPreserveUpsertFields() async throws {
        let port = ReviewPortStub()
        try await withReviewAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/reviews/drafts", method: .get) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(
                    envelope["msg"] as? String
                        == "Missing param [bookId] for method parameter."
                )
            }
            try await client.execute(uri: "/api/v1/reviews/drafts?bookId=7", method: .get) { response in
                let data = try #require(reviewEnvelope(response)["data"] as? [String: Any])
                #expect(data["reviewId"] as? Int == 0)
            }
            try await client.execute(
                uri: "/api/v1/reviews/drafts",
                method: .put,
                headers: [.contentType: "application/json"],
                body: reviewBody(#"{"bookId":7,"reviewId":9,"title":" T ","imageUrls":[" a "],"createdTime":123,"savedTimeMillis":456}"#)
            ) { response in
                let data = try #require(reviewEnvelope(response)["data"] as? [String: Any])
                #expect(data["savedTimeMillis"] as? Int == 456)
            }
            try await client.execute(
                uri: "/api/v1/reviews/drafts?bookId=7&reviewId=9",
                method: .delete
            ) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["data"] == nil)
            }
        }
        #expect(await port.draftRead == ReviewDraftKey(bookID: 7, reviewID: 0))
        #expect(await port.draftUpsert?.title == " T ")
        #expect(await port.draftUpsert?.imageUrls == [" a "])
        #expect(await port.draftDelete == ReviewDraftKey(bookID: 7, reviewID: 9))
    }

    @Test
    func bookListAndSortRoutesNormalizeFallbacks() async throws {
        let port = ReviewPortStub()
        try await withReviewAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/7/reviews?page=2&pageSize=3&sortBy=bad&sortOrder=bad",
                method: .get
            ) { response in
                let data = try #require(reviewEnvelope(response)["data"] as? [String: Any])
                #expect((data["items"] as? [[String: Any]])?.first?["wordCount"] as? Int == 4)
            }
            try await client.execute(uri: "/api/v1/books/7/reviews/sort-rule", method: .get) { response in
                let data = try #require(reviewEnvelope(response)["data"] as? [String: Any])
                #expect(data["sortOrder"] as? String == "asc")
            }
            try await client.execute(
                uri: "/api/v1/books/7/reviews/sort-rule",
                method: .put,
                headers: [.contentType: "application/json"],
                body: reviewBody(#"{"sortBy":"WORD_COUNT","sortOrder":"ASC"}"#)
            ) { response in
                let data = try #require(reviewEnvelope(response)["data"] as? [String: Any])
                #expect(data["sortBy"] as? String == "create_time")
                #expect(data["sortOrder"] as? String == "asc")
            }
        }
        #expect(await port.bookCall == ReviewBookCall(bookID: 7, page: 2, pageSize: 3, sortBy: "create_time", sortOrder: "desc"))
        #expect(await port.sortReadID == 7)
        #expect(await port.sortWrite == ReviewSortCall(bookID: 7, sortBy: "word_count", sortOrder: "asc"))
    }

    @Test
    func detailCreateUpdateAndDeleteDecodeAndroidContracts() async throws {
        let port = ReviewPortStub()
        try await withReviewAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/reviews/42", method: .get) { response in
                let data = try #require(reviewEnvelope(response)["data"] as? [String: Any])
                #expect(data["id"] as? Int == 42)
            }
            try await client.execute(
                uri: "/api/v1/reviews",
                method: .post,
                headers: [.contentType: "application/json"],
                body: reviewBody(#"{"bookId":7,"title":"T","content":"<b>C</b>","imageUrls":["u"],"createdTime":123}"#)
            ) { response in
                let data = try #require(reviewEnvelope(response)["data"] as? [String: Any])
                #expect((data["images"] as? [[String: Any]])?.first?["id"] as? Int == 0)
            }
            try await client.execute(
                uri: "/api/v1/reviews/42",
                method: .put,
                headers: [.contentType: "application/json"],
                body: reviewBody(#"{"title":"U","imageUrls":[]}"#)
            ) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(uri: "/api/v1/reviews/42", method: .delete) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["data"] == nil)
            }
        }
        #expect(await port.detailID == 42)
        #expect(await port.created?.bookId == 7)
        #expect(await port.updatedID == 42)
        #expect(await port.updated?.imageUrls == [])
        #expect(await port.deletedID == 42)
    }

    @Test
    func malformedQueriesBodiesAndPortErrorsUseAndroidEnvelope() async throws {
        let port = ReviewPortStub()
        await port.setDetailError(DesktopWebAPIError(code: 40002, message: "书评不存在: 9"))
        await port.setDraftReadError(DesktopWebAPIError(code: 40001, message: "bookId 必须大于 0"))
        await port.setSortWriteError(
            DesktopWebAPIError(
                code: 40001,
                message: "不支持的书评排序规则: word_count_desc"
            )
        )
        try await withReviewAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/reviews?page=oops", method: .get) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "For input string: \"oops\"")
            }
            try await client.execute(uri: "/api/v1/reviews/drafts", method: .get) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
            }
            try await client.execute(uri: "/api/v1/reviews/drafts?bookId=0", method: .get) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
            try await client.execute(
                uri: "/api/v1/books/7/reviews/sort-rule",
                method: .put,
                headers: [.contentType: "application/json"],
                body: reviewBody(#"{"sortBy":"word_count","sortOrder":"desc"}"#)
            ) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "不支持的书评排序规则: word_count_desc")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
            try await client.execute(
                uri: "/api/v1/reviews",
                method: .post,
                headers: [.contentType: "application/json"],
                body: reviewBody(#"{"bookId":"bad"}"#)
            ) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
            }
            try await client.execute(uri: "/api/v1/reviews/9", method: .get) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 40002)
                #expect(envelope["msg"] as? String == "书评不存在: 9")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
        }
        #expect(await port.globalCall == nil)
        #expect(await port.created == nil)
    }

    @Test
    func readOnlyGateAllowsReadsAndBlocksEveryReviewWriteBeforePort() async throws {
        let port = ReviewPortStub()
        try await withReviewAPI(port: port, gate: ReviewGateStub(isReadOnly: true)) { client in
            try await client.execute(uri: "/api/v1/reviews/42", method: .get) { response in
                let envelope = try reviewEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            let writes: [(String, HTTPRequest.Method, String?)] = [
                ("/api/v1/reviews", .post, #"{"bookId":7,"title":"T"}"#),
                ("/api/v1/reviews/42", .put, #"{"title":"U"}"#),
                ("/api/v1/reviews/42", .delete, nil),
                ("/api/v1/reviews/drafts", .put, #"{"bookId":7,"title":"D"}"#),
                ("/api/v1/reviews/drafts?bookId=7", .delete, nil),
                ("/api/v1/books/7/reviews/sort-rule", .put, #"{}"#)
            ]
            for (uri, method, body) in writes {
                try await client.execute(
                    uri: uri,
                    method: method,
                    headers: body == nil ? [:] : [.contentType: "application/json"],
                    body: body.map(reviewBody)
                ) { response in
                    let envelope = try reviewEnvelope(response)
                    #expect(envelope["code"] as? Int == 40009)
                }
            }
        }
        #expect(await port.detailID == 42)
        #expect(await port.created == nil)
        #expect(await port.updated == nil)
        #expect(await port.deletedID == nil)
        #expect(await port.draftUpsert == nil)
        #expect(await port.draftDelete == nil)
        #expect(await port.sortWrite == nil)
    }

    private func withReviewAPI(
        port: ReviewPortStub,
        gate: ReviewGateStub = ReviewGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, review: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebReviewRoutes.definitions)
        )
        DesktopWebReviewRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct ReviewGlobalCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
    let filter: DesktopWebGlobalReviewFilter
}

private struct ReviewBookCall: Equatable, Sendable {
    let bookID: Int64
    let page: Int
    let pageSize: Int
    let sortBy: String
    let sortOrder: String
}

private struct ReviewDraftKey: Equatable, Sendable {
    let bookID: Int64
    let reviewID: Int64
}

private struct ReviewSortCall: Equatable, Sendable {
    let bookID: Int64
    let sortBy: String
    let sortOrder: String
}

private actor ReviewGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) { self.isReadOnly = isReadOnly }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor ReviewPortStub: DesktopWebReviewPort {
    private(set) var globalCall: ReviewGlobalCall?
    private(set) var draftRead: ReviewDraftKey?
    private(set) var draftUpsert: DesktopWebReviewDraftUpsertRequest?
    private(set) var draftDelete: ReviewDraftKey?
    private(set) var bookCall: ReviewBookCall?
    private(set) var sortReadID: Int64?
    private(set) var sortWrite: ReviewSortCall?
    private(set) var detailID: Int64?
    private(set) var created: DesktopWebReviewCreateRequest?
    private(set) var updatedID: Int64?
    private(set) var updated: DesktopWebReviewUpdateRequest?
    private(set) var deletedID: Int64?
    private var detailError: Error?
    private var draftReadError: Error?
    private var sortWriteError: Error?

    func setDetailError(_ error: Error) { detailError = error }
    func setDraftReadError(_ error: Error) { draftReadError = error }
    func setSortWriteError(_ error: Error) { sortWriteError = error }

    func globalReviews(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalReviewFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalReview> {
        globalCall = ReviewGlobalCall(page: page, pageSize: pageSize, filter: filter)
        return DesktopWebPageResult(
            items: [
                DesktopWebGlobalReview(
                    id: 42,
                    title: "标题",
                    content: "正文",
                    createdTime: 10,
                    updatedTime: 20,
                    images: [DesktopWebReviewImage(id: 5, url: "u")],
                    book: DesktopWebReviewBook(id: 7, name: "书", cover: "c", author: "a", press: "p")
                )
            ],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
        )
    }

    func reviewDraft(bookID: Int64, reviewID: Int64) async throws -> DesktopWebReviewDraft? {
        draftRead = ReviewDraftKey(bookID: bookID, reviewID: reviewID)
        if let draftReadError { throw draftReadError }
        return DesktopWebReviewDraft(
            bookId: bookID,
            reviewId: reviewID,
            title: "D",
            content: "C",
            imageUrls: [],
            createdTime: nil,
            savedTimeMillis: 1
        )
    }

    func upsertReviewDraft(_ request: DesktopWebReviewDraftUpsertRequest) async throws -> DesktopWebReviewDraft {
        draftUpsert = request
        return DesktopWebReviewDraft(
            bookId: request.bookId,
            reviewId: request.reviewId,
            title: request.title ?? "",
            content: request.content ?? "",
            imageUrls: request.imageUrls ?? [],
            createdTime: request.createdTime,
            savedTimeMillis: request.savedTimeMillis ?? 1
        )
    }

    func deleteReviewDraft(bookID: Int64, reviewID: Int64) async throws {
        draftDelete = ReviewDraftKey(bookID: bookID, reviewID: reviewID)
    }

    func bookReviews(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBookReview> {
        bookCall = ReviewBookCall(
            bookID: bookID,
            page: page,
            pageSize: pageSize,
            sortBy: sortBy,
            sortOrder: sortOrder
        )
        return DesktopWebPageResult(
            items: [sampleReview(id: 42)],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
        )
    }

    func bookReviewSortRule(bookID: Int64) async throws -> DesktopWebReviewSortRule {
        sortReadID = bookID
        return DesktopWebReviewSortRule(sortBy: "create_time", sortOrder: "asc")
    }

    func updateBookReviewSortRule(
        bookID: Int64,
        request: DesktopWebReviewSortRuleUpdateRequest
    ) async throws -> DesktopWebReviewSortRule {
        sortWrite = ReviewSortCall(bookID: bookID, sortBy: request.sortBy, sortOrder: request.sortOrder)
        if let sortWriteError { throw sortWriteError }
        return DesktopWebReviewSortRule(sortBy: "create_time", sortOrder: request.sortOrder)
    }

    func review(id: Int64) async throws -> DesktopWebBookReview {
        detailID = id
        if let detailError { throw detailError }
        return sampleReview(id: id)
    }

    func createReview(_ request: DesktopWebReviewCreateRequest) async throws -> DesktopWebBookReview {
        created = request
        return sampleReview(id: 42)
    }

    func updateReview(id: Int64, request: DesktopWebReviewUpdateRequest) async throws -> DesktopWebBookReview {
        updatedID = id
        updated = request
        return sampleReview(id: id)
    }

    func deleteReview(id: Int64) async throws { deletedID = id }

    private func sampleReview(id: Int64) -> DesktopWebBookReview {
        DesktopWebBookReview(
            id: id,
            title: "标题",
            content: "正文",
            wordCount: 4,
            createdTime: 10,
            updatedTime: 20,
            images: [DesktopWebReviewImage(id: 0, url: "u")]
        )
    }
}

private func reviewBody(_ value: String) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
    buffer.writeString(value)
    return buffer
}

private func reviewEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
}
