/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebSearchRoutes 与可观测 SearchPort stub
 * [OUTPUT]: 验证 SearchController 两条 API 的参数归一化、异构编码、聚合降级和错误包络
 * [POS]: XMNoteWeb Package 搜索路由单元测试，锁定 Android v46 SearchController HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebSearchRoutesTests {
    @Test
    func singleSearchNormalizesTypeAndPaginationWithoutTrimmingKeyword() async throws {
        let port = SearchPortStub()
        try await withSearchAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/search?type=NoTe&keyword=%20key%20&page=0&pageSize=0&bookId=-7&tagId=-3",
                method: .get
            ) { response in
                let data = try #require(searchEnvelope(response)["data"] as? [String: Any])
                let items = try #require(data["items"] as? [[String: Any]])
                let item = try #require(items.first)
                let pagination = try #require(data["pagination"] as? [String: Any])
                #expect(item["id"] as? Int == 42)
                #expect(item["title"] as? String == "书评")
                #expect(item["review"] == nil)
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 1)
            }
        }

        #expect(
            await port.singleCall
                == SearchCall(
                    type: .note,
                    keyword: " key ",
                    page: 1,
                    pageSize: 1,
                    bookID: -7,
                    tagID: -3
                )
        )
    }

    @Test
    func aggregateSearchPreservesFourPagesAndOmitsSuccessfulErrorKeys() async throws {
        let port = SearchPortStub()
        await port.setAggregateError(message: "note failed")
        try await withSearchAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/search/aggregate?keyword=k&page=2&pageSize=3&bookId=7&tagId=9",
                method: .get
            ) { response in
                let data = try #require(searchEnvelope(response)["data"] as? [String: Any])
                let book = try #require(data["book"] as? [String: Any])
                let note = try #require(data["note"] as? [String: Any])
                let errors = try #require(data["errors"] as? [String: Any])
                #expect((book["items"] as? [[String: Any]])?.count == 1)
                #expect((note["items"] as? [[String: Any]])?.isEmpty == true)
                #expect(errors["note"] as? String == "note failed")
                #expect(errors["book"] == nil)
                #expect(errors["review"] == nil)
                #expect(errors["relevant"] == nil)
            }
        }

        #expect(
            await port.aggregateCall
                == SearchAggregateCall(keyword: "k", page: 2, pageSize: 3, bookID: 7, tagID: 9)
        )
    }

    @Test
    func missingMalformedAndInvalidParametersFailBeforeCallingPort() async throws {
        let port = SearchPortStub()
        try await withSearchAPI(port: port) { client in
            let cases: [(String, Int, String?)] = [
                (
                    "/api/v1/search",
                    40001,
                    "Missing param [type] for method parameter."
                ),
                (
                    "/api/v1/search?type=book",
                    40001,
                    "Missing param [keyword] for method parameter."
                ),
                (
                    "/api/v1/search?type=unknown&keyword=k",
                    40001,
                    "Invalid search type: unknown. Allowed: book, note, review, relevant"
                ),
                (
                    "/api/v1/search?type=book&keyword=k&page=2147483648",
                    40001,
                    "For input string: \"2147483648\""
                ),
                (
                    "/api/v1/search?type=book&keyword=k&bookId=oops",
                    40001,
                    "For input string: \"oops\""
                ),
                (
                    "/api/v1/search/aggregate?page=1",
                    40001,
                    "Missing param [keyword] for method parameter."
                )
            ]
            for (uri, code, message) in cases {
                try await client.execute(uri: uri, method: .get) { response in
                    let envelope = try searchEnvelope(response)
                    #expect(envelope["code"] as? Int == code)
                    #expect(envelope["msg"] as? String == message)
                }
            }
        }

        #expect(await port.singleCall == nil)
        #expect(await port.aggregateCall == nil)
    }

    @Test
    func readOnlyGateDoesNotBlockSearchReadsAndPortErrorsKeepBusinessEnvelope() async throws {
        let port = SearchPortStub()
        await port.setSingleError(DesktopWebAPIError(code: 40001, message: "搜索失败"))
        try await withSearchAPI(
            port: port,
            gate: SearchGateStub(isReadOnly: true)
        ) { client in
            try await client.execute(
                uri: "/api/v1/search?type=book&keyword=k",
                method: .get
            ) { response in
                let envelope = try searchEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "搜索失败")
            }
            try await client.execute(
                uri: "/api/v1/search/aggregate?keyword=k",
                method: .get
            ) { response in
                let envelope = try searchEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }

        #expect(await port.singleCall?.type == .book)
        #expect(await port.aggregateCall?.keyword == "k")
    }

    private func withSearchAPI(
        port: SearchPortStub,
        gate: SearchGateStub = SearchGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, search: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebSearchRoutes.definitions)
        )
        DesktopWebSearchRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct SearchCall: Equatable, Sendable {
    let type: DesktopWebSearchType
    let keyword: String
    let page: Int
    let pageSize: Int
    let bookID: Int64
    let tagID: Int64
}

private struct SearchAggregateCall: Equatable, Sendable {
    let keyword: String
    let page: Int
    let pageSize: Int
    let bookID: Int64
    let tagID: Int64
}

private actor SearchGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) { self.isReadOnly = isReadOnly }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor SearchPortStub: DesktopWebSearchPort {
    private(set) var singleCall: SearchCall?
    private(set) var aggregateCall: SearchAggregateCall?
    private var singleError: Error?
    private var aggregateErrorMessage: String?

    func setSingleError(_ error: Error) { singleError = error }
    func setAggregateError(message: String) { aggregateErrorMessage = message }

    func search(
        type: DesktopWebSearchType,
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async throws -> DesktopWebSearchPage {
        singleCall = SearchCall(
            type: type,
            keyword: keyword,
            page: page,
            pageSize: pageSize,
            bookID: bookID,
            tagID: tagID
        )
        if let singleError { throw singleError }
        return samplePage(page: page, pageSize: pageSize)
    }

    func searchAggregate(
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async -> DesktopWebSearchAggregateResult {
        aggregateCall = SearchAggregateCall(
            keyword: keyword,
            page: page,
            pageSize: pageSize,
            bookID: bookID,
            tagID: tagID
        )
        let populated = samplePage(page: page, pageSize: pageSize)
        let note = aggregateErrorMessage == nil
            ? populated
            : DesktopWebSearchPage.empty(page: page, pageSize: pageSize)
        return DesktopWebSearchAggregateResult(
            book: populated,
            note: note,
            relevant: populated,
            review: populated,
            errors: DesktopWebSearchAggregateErrors(note: aggregateErrorMessage)
        )
    }

    private func samplePage(page: Int, pageSize: Int) -> DesktopWebSearchPage {
        let book = DesktopWebSearchSimpleBook(
            id: 7,
            name: "书",
            cover: "cover",
            author: "作者",
            press: "出版社"
        )
        return DesktopWebSearchPage(
            items: [
                .review(
                    DesktopWebSearchReview(
                        id: 42,
                        title: "书评",
                        content: "内容",
                        createdTime: 100,
                        book: book,
                        previewImages: [.init(url: "image")]
                    )
                )
            ],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
        )
    }
}

private func searchEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
}
