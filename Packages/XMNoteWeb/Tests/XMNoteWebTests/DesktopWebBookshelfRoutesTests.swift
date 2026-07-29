/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebBookshelfRoutes 与可观测 BookshelfPort stub
 * [OUTPUT]: 验证 7 条书架 API 的默认值、参数归一化、原始载荷、只读 POST 与写门禁
 * [POS]: XMNoteWeb Package 书架路由单元测试，锁定 Android BookshelfController HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebBookshelfRoutesTests {
    @Test
    func listAndSortedRoutesPreserveDefaultsAndNormalizeSorts() async throws {
        let port = BookshelfPortStub()
        try await withBookshelfAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/bookshelf?keyword=%20A%20", method: .get) {
                let pagination = try #require(try bookshelfDataObject($0)["pagination"] as? [String: Any])
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/bookshelf/sorted?page=0&pageSize=0&sortBy=BAD&sortOrder=BAD"
                    + "&groupSortBy=name&groupSortOrder=ASC&groupEnableSection=TRUE",
                method: .get
            ) { response in
                let pagination = try #require(
                    try bookshelfDataObject(response)["pagination"] as? [String: Any]
                )
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 1)
            }
        }
        #expect(
            await port.listCall
                == BookshelfListCall(
                    page: 1,
                    pageSize: 200,
                    keyword: " A ",
                    groupSortBy: "custom",
                    groupSortOrder: "desc",
                    groupEnableSection: false
                )
        )
        #expect(
            await port.sortedCall
                == BookshelfSortedCall(
                    page: 1,
                    pageSize: 1,
                    keyword: "",
                    sortBy: "custom",
                    sortOrder: "desc",
                    groupSortBy: "name",
                    groupSortOrder: "asc",
                    groupEnableSection: true
                )
        )
    }

    @Test
    func listPreservesAndServerFormAndFirstDuplicateKeyDefect() async throws {
        let port = BookshelfPortStub()
        try await withBookshelfAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/bookshelf?page=1&page=2",
                method: .get
            ) { response in
                let envelope = try bookshelfEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == #"For input string: "1page=2""#)
            }
            try await client.execute(
                uri: "/api/v1/bookshelf?unused=1&page=2&page=3"
                    + "&pageSize=2&keyword=Android+Gradle&groupEnableSection=TRUE",
                method: .get
            ) { response in
                _ = try bookshelfDataObject(response)
            }
        }
        #expect(
            await port.listCall
                == BookshelfListCall(
                    page: 2,
                    pageSize: 2,
                    keyword: "Android Gradle",
                    groupSortBy: "custom",
                    groupSortOrder: "desc",
                    groupEnableSection: true
                )
        )
    }

    @Test
    func manifestAndPinnedMetaNormalizeLayoutAndUnusedSortParameters() async throws {
        let port = BookshelfPortStub()
        try await withBookshelfAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/bookshelf/manifest", method: .get) { response in
                let items = try #require(try bookshelfEnvelope(response)["data"] as? [[String: Any]])
                #expect(items.first?["type"] as? String == "book")
            }
            try await client.execute(
                uri: "/api/v1/bookshelf/pinned-groups/meta?sortBy=NAME&sortOrder=ASC"
                    + "&enableSection=true&groupSortBy=bad&groupSortOrder=bad"
                    + "&groupEnableSection=true&layout=LIST",
                method: .get
            ) { response in
                let data = try bookshelfDataObject(response)
                #expect((data["groups"] as? [Any])?.isEmpty == true)
                #expect((data["bookIds"] as? [Any])?.isEmpty == true)
            }
        }
        #expect(await port.manifestCallCount == 1)
        #expect(
            await port.metaCall
                == BookshelfMetaCall(
                    sortBy: "name",
                    sortOrder: "asc",
                    enableSection: true,
                    groupSortBy: "custom",
                    groupSortOrder: "desc",
                    groupEnableSection: true,
                    layout: "list"
                )
        )
    }

    @Test
    func queryItemsUsesKotlinDefaultsAndRemainsAvailableInReadOnlyMode() async throws {
        let port = BookshelfPortStub()
        try await withBookshelfAPI(
            port: port,
            gate: BookshelfGateStub(isReadOnly: true)
        ) { client in
            try await client.execute(
                uri: "/api/v1/bookshelf/items/query",
                method: .post,
                headers: [.contentType: "application/json"],
                body: bookshelfBody(#"{"items":[{"type":"BOOK","id":0},{"type":"book","id":7}]}"#)
            ) { response in
                let envelope = try bookshelfEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        #expect(
            await port.queryCall
                == DesktopWebBookshelfItemsQueryRequest(
                    items: [
                        DesktopWebBookshelfItemRef(type: "BOOK", id: 0),
                        DesktopWebBookshelfItemRef(type: "book", id: 7)
                    ]
                )
        )
    }

    @Test
    func moveAndReorderPreserveRawReferencesAndOmitNilData() async throws {
        let port = BookshelfPortStub()
        try await withBookshelfAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/bookshelf/move",
                method: .post,
                headers: [.contentType: "application/json"],
                body: bookshelfBody(
                    #"{"movedItems":[{"type":"book","id":2},{"type":"book","id":2}],"anchorItem":{"type":"group","id":9},"placement":"after"}"#
                )
            ) { response in
                let envelope = try bookshelfEnvelope(response)
                #expect(envelope["data"] == nil)
            }
            try await client.execute(
                uri: "/api/v1/bookshelf/order",
                method: .put,
                headers: [.contentType: "application/json"],
                body: bookshelfBody(
                    #"{"items":[{"type":"unknown","id":1},{"type":"book","id":0},{"type":"book","id":0}]}"#
                )
            ) { response in
                let envelope = try bookshelfEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        #expect(
            await port.moveCall
                == DesktopWebBookshelfMoveRequest(
                    movedItems: [
                        DesktopWebBookshelfItemRef(type: "book", id: 2),
                        DesktopWebBookshelfItemRef(type: "book", id: 2)
                    ],
                    anchorItem: DesktopWebBookshelfItemRef(type: "group", id: 9),
                    placement: "after"
                )
        )
        #expect(
            await port.reorderCall
                == DesktopWebBookshelfReorderRequest(
                    items: [
                        DesktopWebBookshelfItemRef(type: "unknown", id: 1),
                        DesktopWebBookshelfItemRef(type: "book", id: 0),
                        DesktopWebBookshelfItemRef(type: "book", id: 0)
                    ]
                )
        )
    }

    @Test
    func readOnlyGateBlocksMoveAndReorderBeforePortCalls() async throws {
        let port = BookshelfPortStub()
        try await withBookshelfAPI(
            port: port,
            gate: BookshelfGateStub(isReadOnly: true)
        ) { client in
            try await client.execute(
                uri: "/api/v1/bookshelf/move",
                method: .post,
                headers: [.contentType: "application/json"],
                body: bookshelfBody(#"{"movedItems":[],"placement":"end"}"#)
            ) { response in
                let envelope = try bookshelfEnvelope(response)
                #expect(envelope["code"] as? Int == 40009)
            }
            try await client.execute(
                uri: "/api/v1/bookshelf/order",
                method: .put,
                headers: [.contentType: "application/json"],
                body: bookshelfBody(#"{"items":[]}"#)
            ) { response in
                let envelope = try bookshelfEnvelope(response)
                #expect(envelope["code"] as? Int == 40009)
            }
        }
        #expect(await port.moveCall == nil)
        #expect(await port.reorderCall == nil)
    }

    private func withBookshelfAPI(
        port: BookshelfPortStub,
        gate: BookshelfGateStub = BookshelfGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, bookshelf: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebBookshelfRoutes.definitions)
        )
        DesktopWebBookshelfRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct BookshelfListCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
    let keyword: String
    let groupSortBy: String
    let groupSortOrder: String
    let groupEnableSection: Bool
}

private struct BookshelfSortedCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
    let keyword: String
    let sortBy: String
    let sortOrder: String
    let groupSortBy: String
    let groupSortOrder: String
    let groupEnableSection: Bool
}

private struct BookshelfMetaCall: Equatable, Sendable {
    let sortBy: String
    let sortOrder: String
    let enableSection: Bool
    let groupSortBy: String
    let groupSortOrder: String
    let groupEnableSection: Bool
    let layout: String
}

private actor BookshelfGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) {
        self.isReadOnly = isReadOnly
    }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor BookshelfPortStub: DesktopWebBookshelfPort {
    private(set) var listCall: BookshelfListCall?
    private(set) var sortedCall: BookshelfSortedCall?
    private(set) var manifestCallCount = 0
    private(set) var metaCall: BookshelfMetaCall?
    private(set) var queryCall: DesktopWebBookshelfItemsQueryRequest?
    private(set) var moveCall: DesktopWebBookshelfMoveRequest?
    private(set) var reorderCall: DesktopWebBookshelfReorderRequest?

    func bookshelf(
        page: Int,
        pageSize: Int,
        keyword: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebPageResult<DesktopWebBookshelfItem> {
        listCall = BookshelfListCall(
            page: page,
            pageSize: pageSize,
            keyword: keyword,
            groupSortBy: groupSortBy,
            groupSortOrder: groupSortOrder,
            groupEnableSection: groupEnableSection
        )
        return emptyPage(page: page, pageSize: pageSize)
    }

    func sortedBookshelf(
        page: Int,
        pageSize: Int,
        keyword: String,
        sortBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebPageResult<DesktopWebBookshelfItem> {
        sortedCall = BookshelfSortedCall(
            page: page,
            pageSize: pageSize,
            keyword: keyword,
            sortBy: sortBy,
            sortOrder: sortOrder,
            groupSortBy: groupSortBy,
            groupSortOrder: groupSortOrder,
            groupEnableSection: groupEnableSection
        )
        return emptyPage(page: page, pageSize: pageSize)
    }

    func bookshelfManifest() async throws -> [DesktopWebBookshelfManifestItem] {
        manifestCallCount += 1
        return [
            DesktopWebBookshelfManifestItem(
                type: "book",
                id: 1,
                isPinned: false,
                pinOrder: 0,
                order: 1
            )
        ]
    }

    func bookshelfPinnedGroupsMeta(
        sortBy: String,
        sortOrder: String,
        enableSection: Bool,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool,
        layout: String
    ) async throws -> DesktopWebBookshelfPinnedGroupsMeta {
        metaCall = BookshelfMetaCall(
            sortBy: sortBy,
            sortOrder: sortOrder,
            enableSection: enableSection,
            groupSortBy: groupSortBy,
            groupSortOrder: groupSortOrder,
            groupEnableSection: groupEnableSection,
            layout: layout
        )
        return DesktopWebBookshelfPinnedGroupsMeta(groups: [], bookIds: [])
    }

    func queryBookshelfItems(
        _ request: DesktopWebBookshelfItemsQueryRequest
    ) async throws -> [DesktopWebBookshelfItem] {
        queryCall = request
        return []
    }

    func moveBookshelfItems(_ request: DesktopWebBookshelfMoveRequest) async throws {
        moveCall = request
    }

    func reorderBookshelf(_ request: DesktopWebBookshelfReorderRequest) async throws {
        reorderCall = request
    }

    private func emptyPage(
        page: Int,
        pageSize: Int
    ) -> DesktopWebPageResult<DesktopWebBookshelfItem> {
        DesktopWebPageResult(
            items: [],
            pagination: DesktopWebPagination(
                page: page,
                pageSize: pageSize,
                total: 0,
                totalPages: 0
            )
        )
    }
}

private func bookshelfBody(_ value: String) -> ByteBuffer {
    ByteBuffer(bytes: value.utf8)
}

private func bookshelfEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
    )
}

private func bookshelfDataObject(_ response: TestResponse) throws -> [String: Any] {
    try #require(try bookshelfEnvelope(response)["data"] as? [String: Any])
}
