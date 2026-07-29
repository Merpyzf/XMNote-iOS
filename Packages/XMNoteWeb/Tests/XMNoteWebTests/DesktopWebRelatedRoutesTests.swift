/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebRelatedRoutes 与可观测 RelatedPort stub
 * [OUTPUT]: 验证 18 条相关内容 API 的查询归一化、原始写入合同、错误包络与会员写门禁
 * [POS]: XMNoteWeb Package 相关内容路由单元测试，锁定 Android RelatedController 全量 HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebRelatedRoutesTests {
    @Test
    func categoryRoutesPreserveScopeVisibilityAndRawOrderIDs() async throws {
        let port = RelatedPortStub()
        try await withRelatedAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/related-categories?includeHidden=TRUE",
                method: .get
            ) { response in
                let data = try #require(relatedEnvelope(response)["data"] as? [[String: Any]])
                #expect(data.first?["scope"] as? String == "global")
                #expect(data.first?["isHide"] as? Bool == true)
                #expect(data.first?["contentCount"] as? Int == 2)
            }
            try await client.execute(
                uri: "/api/v1/books/7/related-categories?includeHidden=false",
                method: .get
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/7/related-categories",
                method: .post,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"title":" 分类 ","order":-2,"scope":" GLOBAL "}"#)
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/related-categories/9",
                method: .put,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"title":" 新名 ","order":3,"scope":"book","bookId":8}"#)
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/related-categories/9/visibility",
                method: .put,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"isHide":true}"#)
            ) { response in
                let data = try #require(relatedEnvelope(response)["data"] as? [String: Any])
                #expect(data["id"] as? Int == 9)
            }
            try await client.execute(
                uri: "/api/v1/books/7/related-categories/reorder",
                method: .post,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"ids":[9,9,-1,3]}"#)
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["data"] == nil)
            }
            try await client.execute(uri: "/api/v1/related-categories/9", method: .delete) {
                response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["data"] == nil)
            }
        }

        #expect(await port.globalIncludeHidden == true)
        #expect(await port.bookCategories == RelatedCategoryReadCall(bookID: 7, includeHidden: false))
        #expect(
            await port.categoryCreate
                == RelatedCategoryCreateCall(
                    bookID: 7,
                    request: DesktopWebRelatedCategoryCreateRequest(
                        title: " 分类 ",
                        order: -2,
                        scope: " GLOBAL "
                    )
                )
        )
        #expect(await port.categoryUpdateID == 9)
        #expect(await port.categoryUpdate?.bookId == 8)
        #expect(await port.categoryVisibility == RelatedVisibilityCall(id: 9, isHidden: true))
        #expect(await port.categoryReorder == RelatedReorderCall(bookID: 7, ids: [9, 9, -1, 3]))
        #expect(await port.categoryDeleteID == 9)
    }

    @Test
    func sortAndListRoutesApplyAndroidDefaultsAndFallbacks() async throws {
        let port = RelatedPortStub()
        try await withRelatedAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/7/related-notes/sort-rule", method: .get) {
                response in
                let data = try #require(relatedEnvelope(response)["data"] as? [String: Any])
                #expect(data["sortBy"] as? String == "create_time")
                #expect(data["sortOrder"] as? String == "asc")
            }
            try await client.execute(
                uri: "/api/v1/books/7/related-notes/sort-rule",
                method: .put,
                headers: [.contentType: "application/json"],
                body: relatedBody("{}")
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/7/related-notes?page=0&pageSize=0&categoryId=8&keyword=%20key%20&sortBy=MODIFY_TIME&sortOrder=SIDEWAYS",
                method: .get
            ) { response in
                let data = try #require(relatedEnvelope(response)["data"] as? [String: Any])
                let pagination = try #require(data["pagination"] as? [String: Any])
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 1)
            }
            try await client.execute(
                uri: "/api/v1/books/7/related-notes/all?sortBy=bad&sortOrder=ASC",
                method: .get
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/related-notes?page=-2&pageSize=-3&bookId=4&categoryId=5&keyword=k&sortBy=TITLE&sortOrder=ASC&sortMode=SIDEWAYS&excludeIds=3,x,-1,3,",
                method: .get
            ) { response in
                let data = try #require(relatedEnvelope(response)["data"] as? [String: Any])
                #expect((data["items"] as? [[String: Any]])?.first?["book"] as? [String: Any] != nil)
            }
        }

        #expect(await port.sortReadBookID == 7)
        #expect(
            await port.sortUpdate
                == RelatedSortCall(
                    bookID: 7,
                    request: DesktopWebRelatedSortRuleUpdateRequest()
                )
        )
        #expect(
            await port.bookList
                == RelatedBookListCall(
                    bookID: 7,
                    page: 1,
                    pageSize: 1,
                    filter: DesktopWebRelatedNoteFilter(
                        categoryID: 8,
                        keyword: " key ",
                        sortBy: "update_time",
                        sortOrder: "desc"
                    )
                )
        )
        #expect(
            await port.allList
                == RelatedAllListCall(
                    bookID: 7,
                    filter: DesktopWebRelatedNoteFilter(
                        categoryID: 0,
                        keyword: "",
                        sortBy: "create_time",
                        sortOrder: "asc"
                    )
                )
        )
        #expect(
            await port.globalList
                == RelatedGlobalListCall(
                    page: 1,
                    pageSize: 1,
                    filter: DesktopWebGlobalRelatedNoteFilter(
                        bookID: 4,
                        categoryID: 5,
                        keyword: "k",
                        sortBy: "title",
                        sortOrder: "asc",
                        sortMode: "latest",
                        excludeIDs: [3, -1, 3]
                    )
                )
        )
    }

    @Test
    func detailCreateUpdateDeleteAndBatchRoutesPreserveRawContracts() async throws {
        let port = RelatedPortStub()
        try await withRelatedAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/related-notes/42", method: .get) { response in
                let data = try #require(relatedEnvelope(response)["data"] as? [String: Any])
                #expect(data["categoryTitle"] as? String == "类别")
                #expect((data["images"] as? [[String: Any]])?.first?["order"] as? Int == 0)
            }
            try await client.execute(
                uri: "/api/v1/related-notes",
                method: .post,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"bookId":7,"categoryId":9,"title":" T ","content":"<b>C</b>","url":" u ","imageUrls":[" a "],"uploadedTicketIds":["ticket"],"contentBookId":8,"createdTime":123}"#)
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/related-notes/42",
                method: .put,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"categoryId":10,"title":" U ","imageUrls":[],"contentBookId":-1}"#)
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(uri: "/api/v1/related-notes/42", method: .delete) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["data"] == nil)
            }
            try await client.execute(
                uri: "/api/v1/related-notes/batch-delete",
                method: .post,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"ids":[42,42,-1]}"#)
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["data"] == nil)
            }
            try await client.execute(
                uri: "/api/v1/related-notes/batch-update-category",
                method: .post,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"ids":[42,43],"categoryId":10}"#)
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["data"] == nil)
            }
        }

        #expect(await port.detailID == 42)
        #expect(await port.created?.title == " T ")
        #expect(await port.created?.uploadedTicketIds == ["ticket"])
        #expect(await port.updatedID == 42)
        #expect(await port.updated?.imageUrls == [])
        #expect(await port.updated?.contentBookId == -1)
        #expect(await port.deletedID == 42)
        #expect(await port.batchDelete?.ids == [42, 42, -1])
        #expect(await port.batchCategory == DesktopWebRelatedNoteBatchUpdateCategoryRequest(ids: [42, 43], categoryId: 10))
    }

    @Test
    func malformedInputsAndPortErrorsUseAndroidEnvelopeBeforeCallingPort() async throws {
        let port = RelatedPortStub()
        await port.setDetailError(DesktopWebAPIError(code: 40002, message: "相关内容不存在: 9"))
        try await withRelatedAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/7/related-notes?page=oops",
                method: .get
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "For input string: \"oops\"")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
            try await client.execute(
                uri: "/api/v1/related-categories/9/visibility",
                method: .put,
                headers: [.contentType: "application/json"],
                body: relatedBody(#"{"isHide":"bad"}"#)
            ) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
            }
            try await client.execute(uri: "/api/v1/related-notes/9", method: .get) { response in
                let envelope = try relatedEnvelope(response)
                #expect(envelope["code"] as? Int == 40002)
                #expect(envelope["msg"] as? String == "相关内容不存在: 9")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
        }
        #expect(await port.bookList == nil)
        #expect(await port.categoryVisibility == nil)
    }

    @Test
    func readOnlyGateAllowsAllReadsAndBlocksEveryRelatedWriteBeforePort() async throws {
        let port = RelatedPortStub()
        try await withRelatedAPI(port: port, gate: RelatedGateStub(isReadOnly: true)) { client in
            let reads = [
                "/api/v1/related-categories",
                "/api/v1/books/7/related-categories",
                "/api/v1/books/7/related-notes/sort-rule",
                "/api/v1/books/7/related-notes",
                "/api/v1/books/7/related-notes/all",
                "/api/v1/related-notes",
                "/api/v1/related-notes/42"
            ]
            for uri in reads {
                try await client.execute(uri: uri, method: .get) { response in
                    let envelope = try relatedEnvelope(response)
                    #expect(envelope["code"] as? Int == 200)
                }
            }

            let writes: [(String, HTTPRequest.Method, String?)] = [
                ("/api/v1/books/7/related-categories", .post, #"{"title":"T"}"#),
                ("/api/v1/related-categories/9", .put, #"{"title":"U"}"#),
                ("/api/v1/related-categories/9/visibility", .put, #"{"isHide":true}"#),
                ("/api/v1/related-categories/9", .delete, nil),
                ("/api/v1/books/7/related-categories/reorder", .post, #"{"ids":[9]}"#),
                ("/api/v1/books/7/related-notes/sort-rule", .put, "{}"),
                ("/api/v1/related-notes", .post, #"{"bookId":7,"categoryId":9,"title":"T"}"#),
                ("/api/v1/related-notes/42", .put, #"{"title":"U"}"#),
                ("/api/v1/related-notes/42", .delete, nil),
                ("/api/v1/related-notes/batch-delete", .post, #"{"ids":[42]}"#),
                ("/api/v1/related-notes/batch-update-category", .post, #"{"ids":[42],"categoryId":9}"#)
            ]
            for (uri, method, body) in writes {
                try await client.execute(
                    uri: uri,
                    method: method,
                    headers: body == nil ? [:] : [.contentType: "application/json"],
                    body: body.map(relatedBody)
                ) { response in
                    let envelope = try relatedEnvelope(response)
                    #expect(envelope["code"] as? Int == 40009)
                }
            }
        }

        #expect(await port.globalIncludeHidden == false)
        #expect(await port.detailID == 42)
        #expect(await port.categoryCreate == nil)
        #expect(await port.categoryUpdate == nil)
        #expect(await port.categoryVisibility == nil)
        #expect(await port.categoryDeleteID == nil)
        #expect(await port.categoryReorder == nil)
        #expect(await port.sortUpdate == nil)
        #expect(await port.created == nil)
        #expect(await port.updated == nil)
        #expect(await port.deletedID == nil)
        #expect(await port.batchDelete == nil)
        #expect(await port.batchCategory == nil)
    }

    private func withRelatedAPI(
        port: RelatedPortStub,
        gate: RelatedGateStub = RelatedGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, related: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebRelatedRoutes.definitions)
        )
        DesktopWebRelatedRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct RelatedCategoryReadCall: Equatable, Sendable {
    let bookID: Int64
    let includeHidden: Bool
}

private struct RelatedCategoryCreateCall: Equatable, Sendable {
    let bookID: Int64
    let request: DesktopWebRelatedCategoryCreateRequest
}

private struct RelatedVisibilityCall: Equatable, Sendable {
    let id: Int64
    let isHidden: Bool
}

private struct RelatedReorderCall: Equatable, Sendable {
    let bookID: Int64
    let ids: [Int64]
}

private struct RelatedSortCall: Equatable, Sendable {
    let bookID: Int64
    let request: DesktopWebRelatedSortRuleUpdateRequest
}

private struct RelatedBookListCall: Equatable, Sendable {
    let bookID: Int64
    let page: Int
    let pageSize: Int
    let filter: DesktopWebRelatedNoteFilter
}

private struct RelatedAllListCall: Equatable, Sendable {
    let bookID: Int64
    let filter: DesktopWebRelatedNoteFilter
}

private struct RelatedGlobalListCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
    let filter: DesktopWebGlobalRelatedNoteFilter
}

private actor RelatedGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) { self.isReadOnly = isReadOnly }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor RelatedPortStub: DesktopWebRelatedPort {
    private(set) var globalIncludeHidden: Bool?
    private(set) var bookCategories: RelatedCategoryReadCall?
    private(set) var categoryCreate: RelatedCategoryCreateCall?
    private(set) var categoryUpdateID: Int64?
    private(set) var categoryUpdate: DesktopWebRelatedCategoryUpdateRequest?
    private(set) var categoryVisibility: RelatedVisibilityCall?
    private(set) var categoryDeleteID: Int64?
    private(set) var categoryReorder: RelatedReorderCall?
    private(set) var sortReadBookID: Int64?
    private(set) var sortUpdate: RelatedSortCall?
    private(set) var bookList: RelatedBookListCall?
    private(set) var allList: RelatedAllListCall?
    private(set) var globalList: RelatedGlobalListCall?
    private(set) var detailID: Int64?
    private(set) var created: DesktopWebRelatedNoteCreateRequest?
    private(set) var updatedID: Int64?
    private(set) var updated: DesktopWebRelatedNoteUpdateRequest?
    private(set) var deletedID: Int64?
    private(set) var batchDelete: DesktopWebRelatedNoteBatchDeleteRequest?
    private(set) var batchCategory: DesktopWebRelatedNoteBatchUpdateCategoryRequest?
    private var detailError: Error?

    func setDetailError(_ error: Error) { detailError = error }

    func globalRelatedCategories(includeHidden: Bool) async throws -> [DesktopWebRelatedCategory] {
        globalIncludeHidden = includeHidden
        return [sampleCategory(id: 1, scope: "global", isHidden: true)]
    }

    func relatedCategories(bookID: Int64, includeHidden: Bool) async throws -> [DesktopWebRelatedCategory] {
        bookCategories = RelatedCategoryReadCall(bookID: bookID, includeHidden: includeHidden)
        return [sampleCategory(id: 9, scope: "book", isHidden: false)]
    }

    func createRelatedCategory(
        bookID: Int64,
        request: DesktopWebRelatedCategoryCreateRequest
    ) async throws -> DesktopWebRelatedCategory {
        categoryCreate = RelatedCategoryCreateCall(bookID: bookID, request: request)
        return sampleCategory(id: 9, scope: "book", isHidden: false)
    }

    func updateRelatedCategory(
        id: Int64,
        request: DesktopWebRelatedCategoryUpdateRequest
    ) async throws -> DesktopWebRelatedCategory {
        categoryUpdateID = id
        categoryUpdate = request
        return sampleCategory(id: id, scope: request.scope ?? "book", isHidden: false)
    }

    func updateRelatedCategoryVisibility(
        id: Int64,
        request: DesktopWebRelatedCategoryVisibilityRequest
    ) async throws -> DesktopWebRelatedCategory {
        categoryVisibility = RelatedVisibilityCall(id: id, isHidden: request.isHide)
        return sampleCategory(id: id, scope: "book", isHidden: request.isHide)
    }

    func deleteRelatedCategory(id: Int64) async throws { categoryDeleteID = id }

    func reorderRelatedCategories(
        bookID: Int64,
        request: DesktopWebRelatedCategoryReorderRequest
    ) async throws {
        categoryReorder = RelatedReorderCall(bookID: bookID, ids: request.ids)
    }

    func relatedNoteSortRule(bookID: Int64) async throws -> DesktopWebRelatedSortRule {
        sortReadBookID = bookID
        return DesktopWebRelatedSortRule(sortBy: "create_time", sortOrder: "asc")
    }

    func updateRelatedNoteSortRule(
        bookID: Int64,
        request: DesktopWebRelatedSortRuleUpdateRequest
    ) async throws -> DesktopWebRelatedSortRule {
        sortUpdate = RelatedSortCall(bookID: bookID, request: request)
        return DesktopWebRelatedSortRule(sortBy: request.sortBy, sortOrder: request.sortOrder)
    }

    func relatedNotes(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        filter: DesktopWebRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebRelatedNote> {
        bookList = RelatedBookListCall(bookID: bookID, page: page, pageSize: pageSize, filter: filter)
        return relatedPage(page: page, pageSize: pageSize)
    }

    func allRelatedNotes(
        bookID: Int64,
        filter: DesktopWebRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebRelatedNote> {
        allList = RelatedAllListCall(bookID: bookID, filter: filter)
        return relatedPage(page: 1, pageSize: 1)
    }

    func globalRelatedNotes(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalRelatedNote> {
        globalList = RelatedGlobalListCall(page: page, pageSize: pageSize, filter: filter)
        return DesktopWebPageResult(
            items: [
                DesktopWebGlobalRelatedNote(
                    id: 42,
                    bookId: 7,
                    categoryId: 9,
                    categoryTitle: "类别",
                    title: "标题",
                    content: "正文",
                    url: "u",
                    contentBookId: 8,
                    contentBook: sampleBook(id: 8),
                    images: [DesktopWebRelatedImage(id: 1, url: "i", order: 0)],
                    createdTime: 10,
                    updatedTime: 20,
                    book: sampleBook(id: 7)
                )
            ],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
        )
    }

    func relatedNote(id: Int64) async throws -> DesktopWebRelatedNote {
        detailID = id
        if let detailError { throw detailError }
        return sampleNote(id: id)
    }

    func createRelatedNote(
        _ request: DesktopWebRelatedNoteCreateRequest
    ) async throws -> DesktopWebRelatedNote {
        created = request
        return sampleNote(id: 42)
    }

    func updateRelatedNote(
        id: Int64,
        request: DesktopWebRelatedNoteUpdateRequest
    ) async throws -> DesktopWebRelatedNote {
        updatedID = id
        updated = request
        return sampleNote(id: id)
    }

    func deleteRelatedNote(id: Int64) async throws { deletedID = id }

    func batchDeleteRelatedNotes(_ request: DesktopWebRelatedNoteBatchDeleteRequest) async throws {
        batchDelete = request
    }

    func batchUpdateRelatedNotesCategory(
        _ request: DesktopWebRelatedNoteBatchUpdateCategoryRequest
    ) async throws {
        batchCategory = request
    }

    private func sampleCategory(
        id: Int64,
        scope: String,
        isHidden: Bool
    ) -> DesktopWebRelatedCategory {
        DesktopWebRelatedCategory(
            id: id,
            bookId: scope == "global" ? 0 : 7,
            scope: scope,
            title: "类别",
            order: 0,
            isHide: isHidden,
            contentCount: 2,
            isSystemDefault: false,
            createdTime: 10,
            updatedTime: 20
        )
    }

    private func relatedPage(page: Int, pageSize: Int) -> DesktopWebPageResult<DesktopWebRelatedNote> {
        DesktopWebPageResult(
            items: [sampleNote(id: 42)],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
        )
    }

    private func sampleNote(id: Int64) -> DesktopWebRelatedNote {
        DesktopWebRelatedNote(
            id: id,
            bookId: 7,
            categoryId: 9,
            categoryTitle: "类别",
            title: "标题",
            content: "正文",
            url: "u",
            contentBookId: 8,
            contentBook: sampleBook(id: 8),
            images: [DesktopWebRelatedImage(id: 1, url: "i", order: 0)],
            createdTime: 10,
            updatedTime: 20
        )
    }

    private func sampleBook(id: Int64) -> DesktopWebRelatedBook {
        DesktopWebRelatedBook(
            id: id,
            name: "书",
            cover: "c",
            author: "a",
            press: "p",
            translator: "t",
            pubDate: "2026",
            isDeleted: false
        )
    }
}

private func relatedBody(_ value: String) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
    buffer.writeString(value)
    return buffer
}

private func relatedEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
}
