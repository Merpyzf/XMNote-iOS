/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebBookRoutes 与可观测 BookPort stub
 * [OUTPUT]: 验证 19 条 Book API 的固定路径分派、组合筛选、单书/批量写请求解码与错误边界
 * [POS]: XMNoteWeb Package 书籍路由单元测试，锁定 Android BookController 当前查询及首批写接口合同
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebBookRoutesTests {
    @Test
    func statsReturnsAndroidShapeWithoutCallingDynamicDetail() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/stats", method: .get) { response in
                let data = try bookEnvelopeObject(response)
                #expect(data["total"] as? Int == 6)
                #expect(data["reading"] as? Int == 2)
                #expect(data["want"] as? Int == 1)
                #expect(data["read"] as? Int == 1)
                #expect(data["dropped"] as? Int == 1)
                #expect(data["hold"] as? Int == 1)
            }
        }
        #expect(await port.statsCallCount() == 1)
        #expect(await port.lastDetailID() == nil)
    }

    @Test
    func detailDecodesInt64PathAndReturnsCompleteBook() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/9223372036854775806", method: .get) { response in
                let data = try bookEnvelopeObject(response)
                #expect(data["id"] as? Int == 11)
                #expect(data["sourceName"] as? String == "未知")
                #expect(data["searchSource"] as? String == "bookshelf")
                #expect(data["isInBookshelf"] as? Bool == true)
            }
        }
        #expect(await port.lastDetailID() == 9_223_372_036_854_775_806)
    }

    @Test
    func detailPreservesAndServerPercentDecodingAndJavaLongError() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/%2B641", method: .get) { response in
                _ = try bookEnvelopeObject(response)
            }
            try await client.execute(
                uri: "/api/v1/books/9223372036854775808",
                method: .get
            ) { response in
                let envelope = try bookDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(
                    envelope["msg"] as? String
                        == #"For input string: "9223372036854775808""#
                )
            }
        }
        #expect(await port.lastDetailID() == 641)
    }

    @Test
    func mainListPreservesAndroidFilterParsingAndFlatFallbacks() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books?page=0&pageSize=0&keyword=%20A%20&status=-2&groupId=-3"
                    + "&tagIds=1,bad,-2,1&tagMode=AND&sourceIds=0,2,2,-1,3&sourceId=9"
                    + "&sortBy=BAD&sortOrder=ASC&sectionBy=none",
                method: .get
            ) { response in
                let data = try bookEnvelopeObject(response)
                let pagination = try #require(data["pagination"] as? [String: Any])
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 1)
            }
            try await client.execute(
                uri: "/api/v1/books?sourceIds=0,bad&sourceId=9",
                method: .get
            ) { response in
                _ = try bookEnvelopeObject(response)
            }
        }
        #expect(
            await port.mainListCallsSnapshot() == [
                BookMainListCall(
                    page: 1,
                    pageSize: 1,
                    filter: DesktopWebBookFilter(
                        keyword: " A ",
                        status: -2,
                        groupID: -3,
                        tagIDs: [1],
                        tagMode: "and",
                        sourceIDs: [2, 3]
                    ),
                    sortBy: "custom",
                    sortOrder: "asc"
                ),
                BookMainListCall(
                    page: 1,
                    pageSize: 20,
                    filter: DesktopWebBookFilter(
                        keyword: "",
                        status: 0,
                        groupID: 0,
                        tagIDs: [],
                        tagMode: "or",
                        sourceIDs: [9]
                    ),
                    sortBy: "custom",
                    sortOrder: "desc"
                )
            ]
        )
        #expect(await port.sectionCallsSnapshot().isEmpty)
    }

    @Test
    func mainListPreservesAndServerFormAndFirstDuplicateKeyDefect() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books?page=1&page=2",
                method: .get
            ) { response in
                let envelope = try bookDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == #"For input string: "1page=2""#)
            }
            try await client.execute(
                uri: "/api/v1/books?unused=1&page=2&page=3&keyword=Android+Gradle&pageSize=2",
                method: .get
            ) { response in
                _ = try bookEnvelopeObject(response)
            }
        }
        #expect(
            await port.mainListCallsSnapshot() == [
                BookMainListCall(
                    page: 2,
                    pageSize: 2,
                    filter: DesktopWebBookFilter(
                        keyword: "Android Gradle",
                        status: 0,
                        groupID: 0,
                        tagIDs: [],
                        tagMode: "or",
                        sourceIDs: []
                    ),
                    sortBy: "custom",
                    sortOrder: "desc"
                )
            ]
        )
    }

    @Test
    func mainListValidSectionUsesFullSectionContractAndGroupOptions() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books?sectionBy=READ_DONE_TIME&sortOrder=ASC"
                    + "&groupSortBy=NAME&groupSortOrder=BAD&groupEnableSection=TRUE",
                method: .get
            ) { response in
                let data = try bookEnvelopeObject(response)
                let sections = try #require(data["sections"] as? [[String: Any]])
                #expect(data["total"] as? Int == 2)
                #expect(sections.first?["title"] as? String == "置顶")
                #expect(sections.first?["count"] as? Int == 2)
                #expect((sections.first?["books"] as? [[String: Any]])?.count == 1)
                #expect((sections.first?["groups"] as? [[String: Any]])?.count == 1)
            }
        }
        #expect(await port.mainListCallsSnapshot().isEmpty)
        #expect(
            await port.sectionCallsSnapshot() == [
                BookSectionCall(
                    filter: DesktopWebBookFilter(
                        keyword: "",
                        status: 0,
                        groupID: 0,
                        tagIDs: [],
                        tagMode: "or",
                        sourceIDs: []
                    ),
                    sectionBy: "read_done_time",
                    sortOrder: "asc",
                    groupSortBy: "name",
                    groupSortOrder: "desc",
                    groupEnableSection: true
                )
            ]
        )
    }

    @Test
    func recentReadSupportsLegacyLimitAndPagedPrecedence() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/recent-read?limit=999", method: .get) { response in
                let data = try bookEnvelopeObject(response)
                let pagination = try #require(data["pagination"] as? [String: Any])
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/recent-read?page=0&pageSize=3&limit=9",
                method: .get
            ) { response in
                let data = try bookEnvelopeObject(response)
                let pagination = try #require(data["pagination"] as? [String: Any])
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 3)
            }
            try await client.execute(
                uri: "/api/v1/books/recent-read?page=2&pageSize=0&limit=9",
                method: .get
            ) { response in
                let data = try bookEnvelopeObject(response)
                let pagination = try #require(data["pagination"] as? [String: Any])
                #expect(pagination["page"] as? Int == 2)
                #expect(pagination["pageSize"] as? Int == 50)
            }
        }
        #expect(
            await port.recentCallsSnapshot()
                == [
                    BookPageCall(page: 1, pageSize: 200),
                    BookPageCall(page: 1, pageSize: 3),
                    BookPageCall(page: 2, pageSize: 50)
                ]
        )
    }

    @Test
    func lastNoteBookOmitsDataWhenPortReturnsNil() async throws {
        let port = BookPortStub(lastNote: nil)
        try await withBookAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/last-note-book", method: .get) { response in
                let envelope = try bookDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
                #expect(envelope["msg"] as? String == "success")
                #expect(envelope["data"] == nil)
            }
        }
        #expect(await port.lastNoteCallCount() == 1)
    }

    @Test
    func pinnedNormalizesPaginationAndRejectsMalformedInt() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/pinned?page=-4&pageSize=0", method: .get) { response in
                _ = try bookEnvelopeObject(response)
            }
            try await client.execute(uri: "/api/v1/books/pinned?page=bad", method: .get) { response in
                let envelope = try bookDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
            }
        }
        #expect(await port.pinnedCallsSnapshot() == [BookPageCall(page: 1, pageSize: 1)])
    }

    @Test
    func ungroupedNormalizesSortAndPreservesValidValues() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/ungrouped?page=2&pageSize=7&sortBy=BAD&sortOrder=BAD",
                method: .get
            ) { response in
                _ = try bookEnvelopeObject(response)
            }
            try await client.execute(
                uri: "/api/v1/books/ungrouped?sortBy=READING_PROGRESS&sortOrder=ASC",
                method: .get
            ) { response in
                _ = try bookEnvelopeObject(response)
            }
        }
        #expect(
            await port.ungroupedCallsSnapshot()
                == [
                    BookListCall(page: 2, pageSize: 7, sortBy: "custom", sortOrder: "desc"),
                    BookListCall(page: 1, pageSize: 20, sortBy: "reading_progress", sortOrder: "asc")
                ]
        )
    }

    @Test
    func deletePinAndAddToBookshelfForwardAndroidWriteContracts() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/51", method: .delete) { response in
                let envelope = try bookDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
                #expect(envelope["data"] == nil)
            }
            try await client.execute(
                uri: "/api/v1/books/52/pin",
                method: .put,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"pinned":true,"groupId":7}"#)
            ) { response in
                let data = try bookEnvelopeObject(response)
                #expect(data["id"] as? Int == 52)
                #expect(data["isPinned"] as? Bool == true)
                #expect(data["pinOrder"] as? Int == 8)
            }
            try await client.execute(
                uri: "/api/v1/books/53/add-to-bookshelf",
                method: .put
            ) { response in
                let data = try bookEnvelopeObject(response)
                #expect(data["id"] as? Int == 11)
            }
        }
        #expect(await port.deletedIDsSnapshot() == [51])
        #expect(
            await port.pinCallsSnapshot()
                == [BookPinCall(id: 52, request: DesktopWebBookPinRequest(pinned: true, groupId: 7))]
        )
        #expect(await port.restoredIDsSnapshot() == [53])
    }

    @Test
    func malformedPinBodyReturnsAndroidBadRequestBeforePortCall() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/52/pin",
                method: .put,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"groupId":7}"#)
            ) { response in
                let envelope = try bookDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
            }
        }
        #expect(await port.pinCallsSnapshot().isEmpty)
    }

    @Test
    func createAndUpdateDecodeCompleteAndroidContracts() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(
                    string: #"{"name":" 新书 ","tagIds":[3,3],"groupId":7,"price":12.5,"isDeleted":true,"creationMode":"related_hidden"}"#
                )
            ) { response in
                let data = try bookEnvelopeObject(response)
                #expect(data["id"] as? Int == 11)
            }
            try await client.execute(
                uri: "/api/v1/books/9223372036854775806",
                method: .put,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(
                    string: #"{"name":"","readStatus":3,"clearWordCount":true,"tagIds":[],"groupId":0}"#
                )
            ) { response in
                let data = try bookEnvelopeObject(response)
                #expect(data["name"] as? String == "书名")
            }
        }

        let creates = await port.createCallsSnapshot()
        #expect(creates.count == 1)
        #expect(creates.first?.name == " 新书 ")
        #expect(creates.first?.readStatus == 1)
        #expect(creates.first?.tagIds == [3, 3])
        #expect(creates.first?.price == 12.5)
        #expect(creates.first?.isDeleted == true)
        #expect(creates.first?.creationMode == "related_hidden")
        #expect(
            await port.updateCallsSnapshot() == [
                BookUpdateCall(
                    id: 9_223_372_036_854_775_806,
                    request: DesktopWebBookUpdateRequest(
                        name: "",
                        readStatus: 3,
                        clearWordCount: true,
                        tagIds: [],
                        groupId: 0
                    )
                )
            ]
        )
    }

    @Test
    func malformedCreateBodyReturnsAndroidBadRequestBeforePortCall() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"author":"缺少书名"}"#)
            ) { response in
                let envelope = try bookDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
            }
        }
        #expect(await port.createCallsSnapshot().isEmpty)
    }

    @Test
    func batchRoutesPreserveRawPayloadsAndKotlinDefaults() async throws {
        let port = BookPortStub()
        try await withBookAPI(port: port) { client in
            let requests: [(String, String)] = [
                ("/api/v1/books/batch-delete", #"{"ids":[1,1,-2]}"#),
                ("/api/v1/books/batch-pin", #"{"ids":[2],"pinned":true,"groupId":7}"#),
                (
                    "/api/v1/books/batch-update",
                    #"{"ids":[3,3],"readStatus":3,"readStatusChangedTime":9,"sourceId":4,"groupId":0,"addTagIds":[8,8]}"#
                ),
                ("/api/v1/books/batch-set-tags", #"{"ids":[4],"tagIds":[9,9]}"#),
                (
                    "/api/v1/books/batch-replace-tags",
                    #"{"items":[{"id":5,"tagIds":[10,10]},{"id":5,"tagIds":[]}]}"#
                ),
                (
                    "/api/v1/books/batch-move-to-group",
                    #"{"ids":[6,6],"targetGroupId":11,"sourceGroupId":7}"#
                ),
                ("/api/v1/books/batch-move-out", #"{"ids":[7,8]}"#)
            ]
            for item in requests {
                try await client.execute(
                    uri: item.0,
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: item.1)
                ) { response in
                    let envelope = try bookDecodeJSONObject(response)
                    #expect(envelope["code"] as? Int == 200)
                    #expect(envelope["data"] == nil)
                }
            }
        }

        #expect(
            await port.batchDeleteCallsSnapshot()
                == [DesktopWebBookBatchDeleteRequest(ids: [1, 1, -2])]
        )
        #expect(
            await port.batchPinCallsSnapshot()
                == [DesktopWebBookBatchPinRequest(ids: [2], pinned: true, groupId: 7)]
        )
        #expect(
            await port.batchUpdateCallsSnapshot() == [
                DesktopWebBookBatchUpdateRequest(
                    ids: [3, 3],
                    readStatus: 3,
                    readStatusChangedTime: 9,
                    sourceId: 4,
                    groupId: 0,
                    addTagIds: [8, 8]
                )
            ]
        )
        #expect(
            await port.batchSetTagCallsSnapshot()
                == [DesktopWebBookBatchSetTagsRequest(ids: [4], tagIds: [9, 9], mode: "append")]
        )
        #expect(
            await port.batchReplaceTagCallsSnapshot() == [
                DesktopWebBookBatchReplaceTagsRequest(
                    items: [
                        DesktopWebBookBatchReplaceTagsItemRequest(id: 5, tagIds: [10, 10]),
                        DesktopWebBookBatchReplaceTagsItemRequest(id: 5, tagIds: [])
                    ]
                )
            ]
        )
        #expect(
            await port.batchMoveToGroupCallsSnapshot() == [
                DesktopWebBookBatchMoveToGroupRequest(
                    ids: [6, 6],
                    targetGroupId: 11,
                    sourceGroupId: 7
                )
            ]
        )
        #expect(
            await port.batchMoveOutCallsSnapshot()
                == [DesktopWebBookBatchMoveOutRequest(ids: [7, 8], placeAtEnd: true)]
        )
    }

    private func withBookAPI(
        port: BookPortStub,
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(
            requestGate: BookGateStub(readOnly: false),
            book: port
        )
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebBookRoutes.definitions)
        )
        DesktopWebBookRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct BookPageCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
}

private struct BookListCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
    let sortBy: String
    let sortOrder: String
}

private struct BookMainListCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
    let filter: DesktopWebBookFilter
    let sortBy: String
    let sortOrder: String
}

private struct BookSectionCall: Equatable, Sendable {
    let filter: DesktopWebBookFilter
    let sectionBy: String
    let sortOrder: String
    let groupSortBy: String
    let groupSortOrder: String
    let groupEnableSection: Bool
}

private struct BookPinCall: Equatable, Sendable {
    let id: Int64
    let request: DesktopWebBookPinRequest
}

private struct BookUpdateCall: Equatable, Sendable {
    let id: Int64
    let request: DesktopWebBookUpdateRequest
}

private actor BookGateStub: DesktopWebRequestGatePort {
    let readOnly: Bool

    init(readOnly: Bool) {
        self.readOnly = readOnly
    }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { readOnly }
}

private actor BookPortStub: DesktopWebBookPort {
    private var statsCalls = 0
    private var detailID: Int64?
    private var mainListCalls: [BookMainListCall] = []
    private var sectionCalls: [BookSectionCall] = []
    private var recentCalls: [BookPageCall] = []
    private var lastNoteCalls = 0
    private var pinnedCalls: [BookPageCall] = []
    private var ungroupedCalls: [BookListCall] = []
    private var deletedIDs: [Int64] = []
    private var pinCalls: [BookPinCall] = []
    private var restoredIDs: [Int64] = []
    private var createCalls: [DesktopWebBookCreateRequest] = []
    private var updateCalls: [BookUpdateCall] = []
    private var batchDeleteCalls: [DesktopWebBookBatchDeleteRequest] = []
    private var batchPinCalls: [DesktopWebBookBatchPinRequest] = []
    private var batchUpdateCalls: [DesktopWebBookBatchUpdateRequest] = []
    private var batchSetTagCalls: [DesktopWebBookBatchSetTagsRequest] = []
    private var batchReplaceTagCalls: [DesktopWebBookBatchReplaceTagsRequest] = []
    private var batchMoveToGroupCalls: [DesktopWebBookBatchMoveToGroupRequest] = []
    private var batchMoveOutCalls: [DesktopWebBookBatchMoveOutRequest] = []
    private let lastNote: DesktopWebBook?

    init(lastNote: DesktopWebBook? = bookRouteFixture()) {
        self.lastNote = lastNote
    }

    func bookStats() async throws -> DesktopWebBookStats {
        statsCalls += 1
        return DesktopWebBookStats(total: 6, reading: 2, want: 1, read: 1, dropped: 1, hold: 1)
    }

    func book(id: Int64) async throws -> DesktopWebBook {
        detailID = id
        return bookRouteFixture()
    }

    func books(
        page: Int,
        pageSize: Int,
        filter: DesktopWebBookFilter,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        mainListCalls.append(
            BookMainListCall(
                page: page,
                pageSize: pageSize,
                filter: filter,
                sortBy: sortBy,
                sortOrder: sortOrder
            )
        )
        return bookRoutePage(page: page, pageSize: pageSize)
    }

    func bookSections(
        filter: DesktopWebBookFilter,
        sectionBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebBookSectionResult {
        sectionCalls.append(
            BookSectionCall(
                filter: filter,
                sectionBy: sectionBy,
                sortOrder: sortOrder,
                groupSortBy: groupSortBy,
                groupSortOrder: groupSortOrder,
                groupEnableSection: groupEnableSection
            )
        )
        let preview = DesktopWebGroupPreviewBook(bookId: 11, cover: "")
        let group = DesktopWebBookshelfGroup(
            id: 7,
            name: "分组",
            isPinned: true,
            pinOrder: 2,
            order: 3,
            bookCount: 1,
            createdTime: 10,
            covers: [""],
            previewBooks: [preview]
        )
        return DesktopWebBookSectionResult(
            sections: [
                DesktopWebBookSection(
                    title: "置顶",
                    count: 2,
                    books: [bookRouteFixture()],
                    groups: [group]
                )
            ],
            total: 2
        )
    }

    func recentReadBooks(
        page: Int,
        pageSize: Int
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        recentCalls.append(BookPageCall(page: page, pageSize: pageSize))
        return bookRoutePage(page: page, pageSize: pageSize)
    }

    func lastNoteBook() async throws -> DesktopWebBook? {
        lastNoteCalls += 1
        return lastNote
    }

    func pinnedBooks(page: Int, pageSize: Int) async throws -> DesktopWebPageResult<DesktopWebBook> {
        pinnedCalls.append(BookPageCall(page: page, pageSize: pageSize))
        return bookRoutePage(page: page, pageSize: pageSize)
    }

    func ungroupedBooks(
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        ungroupedCalls.append(
            BookListCall(page: page, pageSize: pageSize, sortBy: sortBy, sortOrder: sortOrder)
        )
        return bookRoutePage(page: page, pageSize: pageSize)
    }

    func deleteBook(id: Int64) async throws {
        deletedIDs.append(id)
    }

    func updateBookPin(
        id: Int64,
        request: DesktopWebBookPinRequest
    ) async throws -> DesktopWebBookPinResult {
        pinCalls.append(BookPinCall(id: id, request: request))
        return DesktopWebBookPinResult(id: id, isPinned: request.pinned, pinOrder: 8)
    }

    func addToBookshelf(id: Int64) async throws -> DesktopWebBook {
        restoredIDs.append(id)
        return bookRouteFixture()
    }

    func createBook(_ request: DesktopWebBookCreateRequest) async throws -> DesktopWebBook {
        createCalls.append(request)
        return bookRouteFixture()
    }

    func updateBook(
        id: Int64,
        request: DesktopWebBookUpdateRequest
    ) async throws -> DesktopWebBook {
        updateCalls.append(BookUpdateCall(id: id, request: request))
        return bookRouteFixture()
    }

    func batchDeleteBooks(_ request: DesktopWebBookBatchDeleteRequest) async throws {
        batchDeleteCalls.append(request)
    }

    func batchPinBooks(_ request: DesktopWebBookBatchPinRequest) async throws {
        batchPinCalls.append(request)
    }

    func batchUpdateBooks(_ request: DesktopWebBookBatchUpdateRequest) async throws {
        batchUpdateCalls.append(request)
    }

    func batchSetBookTags(_ request: DesktopWebBookBatchSetTagsRequest) async throws {
        batchSetTagCalls.append(request)
    }

    func batchReplaceBookTags(_ request: DesktopWebBookBatchReplaceTagsRequest) async throws {
        batchReplaceTagCalls.append(request)
    }

    func batchMoveToGroup(_ request: DesktopWebBookBatchMoveToGroupRequest) async throws {
        batchMoveToGroupCalls.append(request)
    }

    func batchMoveOut(_ request: DesktopWebBookBatchMoveOutRequest) async throws {
        batchMoveOutCalls.append(request)
    }

    func statsCallCount() -> Int { statsCalls }
    func lastDetailID() -> Int64? { detailID }
    func mainListCallsSnapshot() -> [BookMainListCall] { mainListCalls }
    func sectionCallsSnapshot() -> [BookSectionCall] { sectionCalls }
    func recentCallsSnapshot() -> [BookPageCall] { recentCalls }
    func lastNoteCallCount() -> Int { lastNoteCalls }
    func pinnedCallsSnapshot() -> [BookPageCall] { pinnedCalls }
    func ungroupedCallsSnapshot() -> [BookListCall] { ungroupedCalls }
    func deletedIDsSnapshot() -> [Int64] { deletedIDs }
    func pinCallsSnapshot() -> [BookPinCall] { pinCalls }
    func restoredIDsSnapshot() -> [Int64] { restoredIDs }
    func createCallsSnapshot() -> [DesktopWebBookCreateRequest] { createCalls }
    func updateCallsSnapshot() -> [BookUpdateCall] { updateCalls }
    func batchDeleteCallsSnapshot() -> [DesktopWebBookBatchDeleteRequest] { batchDeleteCalls }
    func batchPinCallsSnapshot() -> [DesktopWebBookBatchPinRequest] { batchPinCalls }
    func batchUpdateCallsSnapshot() -> [DesktopWebBookBatchUpdateRequest] { batchUpdateCalls }
    func batchSetTagCallsSnapshot() -> [DesktopWebBookBatchSetTagsRequest] { batchSetTagCalls }
    func batchReplaceTagCallsSnapshot() -> [DesktopWebBookBatchReplaceTagsRequest] {
        batchReplaceTagCalls
    }
    func batchMoveToGroupCallsSnapshot() -> [DesktopWebBookBatchMoveToGroupRequest] {
        batchMoveToGroupCalls
    }
    func batchMoveOutCallsSnapshot() -> [DesktopWebBookBatchMoveOutRequest] { batchMoveOutCalls }
}

private func bookRoutePage(page: Int, pageSize: Int) -> DesktopWebPageResult<DesktopWebBook> {
    DesktopWebPageResult(
        items: [bookRouteFixture()],
        pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
    )
}

private func bookRouteFixture() -> DesktopWebBook {
    DesktopWebBook(
        id: 11,
        name: "书名",
        rawName: "",
        cover: "",
        author: "作者",
        authorIntro: "",
        translator: "",
        summary: "",
        isbn: "",
        press: "",
        pubDate: "",
        doubanId: nil,
        readStatus: 2,
        readStatusChangedTime: 0,
        recentReadTime: 100,
        readDoneCount: 0,
        score: 0,
        readPosition: 0,
        totalPosition: 0,
        totalPagination: 0,
        currentPositionUnit: 2,
        positionUnit: 2,
        type: 0,
        sourceId: 1,
        sourceName: "未知",
        purchaseDate: nil,
        price: nil,
        isPinned: false,
        pinOrder: 0,
        order: 0,
        wordCount: nil,
        totalReadingTime: 0,
        createdTime: 10,
        updatedTime: 0,
        lastModifiedTime: nil,
        noteCount: 0,
        reviewCount: 0,
        relevantCount: 0,
        readDoneTime: nil,
        bookmarkModifiedTime: nil,
        groups: [],
        tags: [],
        isDeleted: false
    )
}

private func bookDecodeJSONObject(_ response: TestResponse) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView))
    return try #require(value as? [String: Any])
}

private func bookEnvelopeObject(_ response: TestResponse) throws -> [String: Any] {
    let envelope = try bookDecodeJSONObject(response)
    #expect(envelope["code"] as? Int == 200)
    return try #require(envelope["data"] as? [String: Any])
}
