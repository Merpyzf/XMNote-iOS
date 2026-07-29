/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebGroupRoutes 与可观测 GroupPort stub
 * [OUTPUT]: 验证 8 条分组 API 的参数归一化、响应合同、写门禁和路由分派
 * [POS]: XMNoteWeb Package 分组路由单元测试，锁定 Android GroupController 的 HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebGroupRoutesTests {
    @Test
    func groupListNormalizesPaginationAndReturnsAndroidPage() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/groups?page=0&pageSize=0", method: .get) { response in
                let data = try groupEnvelopeObject(response)
                let pagination = try #require(data["pagination"] as? [String: Any])
                let items = try #require(data["items"] as? [[String: Any]])
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 1)
                #expect(items.first?["name"] as? String == "默认分组")
            }
        }
        #expect(await port.lastGroupPage() == GroupPageCall(page: 1, pageSize: 1))
    }

    @Test
    func groupBooksNormalizesSortAndReturnsCompleteBookShape() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/groups/7/books?page=2&pageSize=3&sortBy=BAD&sortOrder=BAD",
                method: .get
            ) { response in
                let data = try groupEnvelopeObject(response)
                let items = try #require(data["items"] as? [[String: Any]])
                let book = try #require(items.first)
                #expect(book["id"] as? Int == 11)
                #expect(book["sourceName"] as? String == "未知")
                #expect(book["searchSource"] as? String == "bookshelf")
                #expect(book["isInBookshelf"] as? Bool == true)
                #expect(book["fromRelatedContentBook"] as? Bool == false)
            }
        }
        #expect(
            await port.lastBooksCall()
                == GroupBooksCall(id: 7, page: 2, pageSize: 3, sortBy: "custom", sortOrder: "desc")
        )
    }

    @Test
    func invalidPaginationReturnsAndroidBadRequestBeforePortCall() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/groups?page=bad", method: .get) { response in
                let envelope = try groupDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == #"For input string: "bad""#)
            }
        }
        #expect(await port.lastGroupPage() == nil)
    }

    @Test
    func queryBindingPreservesAndroidEmptyPlusDuplicateAndBareKeySemantics() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/groups?page=&pageSize=", method: .get) {
                response in
                _ = try groupEnvelopeObject(response)
            }
            #expect(await port.lastGroupPage() == GroupPageCall(page: 1, pageSize: 20))

            try await client.execute(uri: "/api/v1/groups?page=%2B2", method: .get) {
                response in
                _ = try groupEnvelopeObject(response)
            }
            #expect(await port.lastGroupPage() == GroupPageCall(page: 2, pageSize: 20))

            try await client.execute(uri: "/api/v1/groups?page=+2", method: .get) { response in
                let envelope = try groupDecodeJSONObject(response)
                #expect(envelope["msg"] as? String == #"For input string: " 2""#)
            }
            try await client.execute(uri: "/api/v1/groups?page=1&page=2", method: .get) {
                response in
                let envelope = try groupDecodeJSONObject(response)
                #expect(envelope["msg"] as? String == #"For input string: "1page=2""#)
            }

            try await client.execute(uri: "/api/v1/groups?page&page=2", method: .get) {
                response in
                _ = try groupEnvelopeObject(response)
            }
            #expect(await port.lastGroupPage() == GroupPageCall(page: 2, pageSize: 20))
        }
    }

    @Test
    func groupBookPathAndSortBindingPreserveAndroidFormSemantics() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/groups/%2B7/books?sortBy=name&sortBy=custom&sortOrder=asc&sortOrder=desc",
                method: .get
            ) { response in
                _ = try groupEnvelopeObject(response)
            }
            #expect(
                await port.lastBooksCall()
                    == GroupBooksCall(
                        id: 7,
                        page: 1,
                        pageSize: 20,
                        sortBy: "custom",
                        sortOrder: "asc"
                    )
            )

            try await client.execute(
                uri: "/api/v1/groups/7/books?sortBy=name&sortOrder=asc&sortOrder=desc",
                method: .get
            ) { response in
                _ = try groupEnvelopeObject(response)
            }
            #expect(
                await port.lastBooksCall()
                    == GroupBooksCall(
                        id: 7,
                        page: 1,
                        pageSize: 20,
                        sortBy: "name",
                        sortOrder: "asc"
                    )
            )

            try await client.execute(
                uri: "/api/v1/groups/7/books?sortOrder=asc&sortBy=name&sortBy=custom",
                method: .get
            ) { response in
                _ = try groupEnvelopeObject(response)
            }
            #expect(
                await port.lastBooksCall()
                    == GroupBooksCall(
                        id: 7,
                        page: 1,
                        pageSize: 20,
                        sortBy: "name",
                        sortOrder: "asc"
                    )
            )

            try await client.execute(
                uri: "/api/v1/groups/7/books?sortBy&sortBy=name&sortOrder&sortOrder=asc",
                method: .get
            ) { response in
                _ = try groupEnvelopeObject(response)
            }
            #expect(
                await port.lastBooksCall()
                    == GroupBooksCall(
                        id: 7,
                        page: 1,
                        pageSize: 20,
                        sortBy: "name",
                        sortOrder: "asc"
                    )
            )
        }
    }

    @Test
    func createAndUpdateGroupDecodeRequiredNames() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/groups",
                method: .post,
                headers: [.contentType: "application/json"],
                body: groupJSONBody(#"{"name":" 新分组 "}"#)
            ) { response in
                let data = try groupEnvelopeObject(response)
                #expect(data["id"] as? Int == 7)
            }
            try await client.execute(
                uri: "/api/v1/groups/7",
                method: .put,
                headers: [.contentType: "application/json"],
                body: groupJSONBody(#"{"name":"重命名"}"#)
            ) { response in
                let data = try groupEnvelopeObject(response)
                #expect(data["name"] as? String == "重命名")
            }
        }
        #expect(await port.lastCreate() == DesktopWebGroupCreateRequest(name: " 新分组 "))
        #expect(await port.lastUpdate() == GroupUpdateCall(id: 7, name: "重命名"))
    }

    @Test
    func deleteGroupUsesAndroidBooleanParsingAndOmitsData() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/groups/7?placeAtEnd=TRUE", method: .delete) { response in
                let envelope = try groupDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
                #expect(envelope["data"] == nil)
            }
        }
        #expect(await port.lastDelete() == GroupDeleteCall(id: 7, placeAtEnd: true))
    }

    @Test
    func updateGroupPinDecodesPathAndPinnedFlag() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/groups/7/pin",
                method: .put,
                headers: [.contentType: "application/json"],
                body: groupJSONBody(#"{"pinned":true}"#)
            ) { response in
                let data = try groupEnvelopeObject(response)
                #expect(data["isPinned"] as? Bool == true)
            }
        }
        #expect(await port.lastPin() == GroupPinCall(id: 7, pinned: true))
    }

    @Test
    func reorderGroupsPreservesDuplicateAndMissingIDs() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/groups/order",
                method: .put,
                headers: [.contentType: "application/json"],
                body: groupJSONBody(#"{"ids":[7,999,7]}"#)
            ) { response in
                let envelope = try groupDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        #expect(await port.lastGroupOrder() == [7, 999, 7])
    }

    @Test
    func reorderGroupBooksPassesRawIDsAndGroupID() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/groups/7/books/order",
                method: .put,
                headers: [.contentType: "application/json"],
                body: groupJSONBody(#"{"ids":[11,11,-1,12]}"#)
            ) { response in
                let envelope = try groupDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        #expect(await port.lastBookOrder() == GroupBookOrderCall(groupID: 7, ids: [11, 11, -1, 12]))
    }

    @Test
    func readOnlyGateBlocksGroupWritesButAllowsReads() async throws {
        let port = GroupPortStub()
        try await withGroupAPI(port: port, gate: GroupGateStub(isReadOnly: true)) { client in
            try await client.execute(uri: "/api/v1/groups", method: .get) { response in
                let envelope = try groupDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/groups",
                method: .post,
                headers: [.contentType: "application/json"],
                body: groupJSONBody(#"{"name":"blocked"}"#)
            ) { response in
                let envelope = try groupDecodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40009)
            }
        }
        #expect(await port.lastCreate() == nil)
    }

    private func withGroupAPI(
        port: GroupPortStub,
        gate: GroupGateStub = GroupGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, group: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebGroupRoutes.definitions)
        )
        DesktopWebGroupRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct GroupPageCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
}

private struct GroupBooksCall: Equatable, Sendable {
    let id: Int64
    let page: Int
    let pageSize: Int
    let sortBy: String
    let sortOrder: String
}

private struct GroupUpdateCall: Equatable, Sendable {
    let id: Int64
    let name: String
}

private struct GroupDeleteCall: Equatable, Sendable {
    let id: Int64
    let placeAtEnd: Bool
}

private struct GroupPinCall: Equatable, Sendable {
    let id: Int64
    let pinned: Bool
}

private struct GroupBookOrderCall: Equatable, Sendable {
    let groupID: Int64
    let ids: [Int64]
}

private actor GroupGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) {
        self.isReadOnly = isReadOnly
    }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor GroupPortStub: DesktopWebGroupPort {
    private var groupPage: GroupPageCall?
    private var booksCall: GroupBooksCall?
    private var createRequest: DesktopWebGroupCreateRequest?
    private var updateCall: GroupUpdateCall?
    private var deleteCall: GroupDeleteCall?
    private var pinCall: GroupPinCall?
    private var groupOrder: [Int64]?
    private var bookOrder: GroupBookOrderCall?

    func groups(page: Int, pageSize: Int) async throws -> DesktopWebPageResult<DesktopWebGroup> {
        groupPage = GroupPageCall(page: page, pageSize: pageSize)
        return DesktopWebPageResult(
            items: [groupFixture()],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
        )
    }

    func booksInGroup(
        id: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        booksCall = GroupBooksCall(
            id: id,
            page: page,
            pageSize: pageSize,
            sortBy: sortBy,
            sortOrder: sortOrder
        )
        return DesktopWebPageResult(
            items: [bookFixture()],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
        )
    }

    func createGroup(_ request: DesktopWebGroupCreateRequest) async throws -> DesktopWebGroup {
        createRequest = request
        return groupFixture(name: request.name)
    }

    func updateGroup(
        id: Int64,
        request: DesktopWebGroupUpdateRequest
    ) async throws -> DesktopWebGroup {
        updateCall = GroupUpdateCall(id: id, name: request.name)
        return groupFixture(name: request.name)
    }

    func deleteGroup(id: Int64, placeAtEnd: Bool) async throws {
        deleteCall = GroupDeleteCall(id: id, placeAtEnd: placeAtEnd)
    }

    func updateGroupPin(
        id: Int64,
        request: DesktopWebGroupPinRequest
    ) async throws -> DesktopWebGroup {
        pinCall = GroupPinCall(id: id, pinned: request.pinned)
        return groupFixture(isPinned: request.pinned)
    }

    func reorderGroups(_ request: DesktopWebOrderRequest) async throws {
        groupOrder = request.ids
    }

    func reorderGroupBooks(groupID: Int64, request: DesktopWebOrderRequest) async throws {
        bookOrder = GroupBookOrderCall(groupID: groupID, ids: request.ids)
    }

    func lastGroupPage() -> GroupPageCall? { groupPage }
    func lastBooksCall() -> GroupBooksCall? { booksCall }
    func lastCreate() -> DesktopWebGroupCreateRequest? { createRequest }
    func lastUpdate() -> GroupUpdateCall? { updateCall }
    func lastDelete() -> GroupDeleteCall? { deleteCall }
    func lastPin() -> GroupPinCall? { pinCall }
    func lastGroupOrder() -> [Int64]? { groupOrder }
    func lastBookOrder() -> GroupBookOrderCall? { bookOrder }

    private func groupFixture(
        name: String = "默认分组",
        isPinned: Bool = false
    ) -> DesktopWebGroup {
        DesktopWebGroup(
            id: 7,
            name: name,
            isPinned: isPinned,
            pinOrder: isPinned ? 2 : 0,
            order: 3,
            bookCount: 1,
            createdTime: 10
        )
    }

    private func bookFixture() -> DesktopWebBook {
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
            groups: [DesktopWebBookGroup(id: 7, name: "默认分组")],
            tags: [],
            isDeleted: false
        )
    }
}

private func groupDecodeJSONObject(_ response: TestResponse) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView))
    return try #require(value as? [String: Any])
}

private func groupEnvelopeObject(_ response: TestResponse) throws -> [String: Any] {
    let envelope = try groupDecodeJSONObject(response)
    #expect(envelope["code"] as? Int == 200)
    return try #require(envelope["data"] as? [String: Any])
}

private func groupJSONBody(_ string: String) -> ByteBuffer {
    ByteBuffer(bytes: string.utf8)
}
