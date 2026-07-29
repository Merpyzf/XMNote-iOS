/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebChapterRoutes 与可观测 ChapterPort stub
 * [OUTPUT]: 验证 17 条章节 API 的路径参数、在线查询、导入请求、响应形状、nil 包络与会员写门禁
 * [POS]: XMNoteWeb Package 章节路由单元测试，锁定 Android ChapterController 全量 HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebChapterRoutesTests {
    @Test
    func chapterReadsReturnTreeLastUsedAndStarredShapes() async throws {
        let port = ChapterPortStub()
        try await withChapterAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/books/7/chapters", method: .get) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [[String: Any]])
                #expect(data.first?["title"] as? String == "父章节")
                #expect(data.first?["descendantNoteCount"] as? Int == 3)
                let children = try #require(data.first?["children"] as? [[String: Any]])
                #expect(children.first?["pathTitles"] as? [String] == ["父章节", "子章节"])
            }
            try await client.execute(
                uri: "/api/v1/books/8/chapters/last-used",
                method: .get
            ) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [String: Any])
                #expect(data["parentTitle"] as? String == "父章节")
                #expect(data["isStarred"] as? Bool == true)
            }
            try await client.execute(uri: "/api/v1/chapters/starred", method: .get) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [[String: Any]])
                let book = try #require(data.first?["book"] as? [String: Any])
                #expect(book["cover"] as? String == "/api/v1/books/7/cover")
                #expect(data.first?["noteCount"] as? Int == 3)
            }
        }
        #expect(await port.readBookIDs == [7, 8])
    }

    @Test
    func createUpdateStarAndBatchCreateDecodeAndroidContracts() async throws {
        let port = ChapterPortStub()
        try await withChapterAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/7/chapters",
                method: .post,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"title":" 新章节 "}"#)
            ) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [String: Any])
                #expect(data["parentId"] as? Int == 0)
            }
            try await client.execute(
                uri: "/api/v1/chapters/9",
                method: .put,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"title":"改名"}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/chapters/9/starred",
                method: .put,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"isStarred":true}"#)
            ) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [String: Any])
                #expect(data["isStarred"] as? Bool == true)
            }
            try await client.execute(
                uri: "/api/v1/books/7/chapters/batch",
                method: .post,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"titles":["A"," ","B"],"parentId":9}"#)
            ) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [String: Any])
                let created = try #require(data["created"] as? [[String: Any]])
                #expect(created.count == 1)
            }
        }
        #expect(await port.createCall == ChapterCreateCall(bookID: 7, title: " 新章节 ", parentID: nil))
        #expect(await port.updateCall == ChapterUpdateCall(id: 9, title: "改名"))
        #expect(await port.starCall == ChapterStarCall(id: 9, isStarred: true))
        #expect(
            await port.batchCreateCall
                == ChapterBatchCreateCall(bookID: 7, titles: ["A", " ", "B"], parentID: 9)
        )
    }

    @Test
    func deleteReorderAndMoveRoutesPreserveRawArrays() async throws {
        let port = ChapterPortStub()
        try await withChapterAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/chapters/9", method: .delete) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["data"] == nil)
            }
            try await client.execute(
                uri: "/api/v1/chapters/batch-delete",
                method: .post,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"ids":[9,999,9]}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/7/chapters/order",
                method: .put,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"ids":[2,1]}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/chapters/5/children/order",
                method: .put,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"ids":[4,3]}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/chapters/move-to-parent",
                method: .put,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"chapterIds":[3,3,-1],"parentId":5}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/chapters/move-out",
                method: .put,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"chapterIds":[3,4]}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        #expect(await port.deletedID == 9)
        #expect(await port.batchDeleteIDs == [9, 999, 9])
        #expect(await port.parentOrderCall == ChapterOrderCall(scopeID: 7, ids: [2, 1]))
        #expect(await port.childOrderCall == ChapterOrderCall(scopeID: 5, ids: [4, 3]))
        #expect(await port.moveToParentCall == ChapterMoveCall(ids: [3, 3, -1], parentID: 5))
        #expect(await port.moveOutIDs == [3, 4])
    }

    @Test
    func malformedBodyAndReadOnlyGateStopWritesBeforePortCall() async throws {
        let port = ChapterPortStub()
        try await withChapterAPI(port: port, gate: ChapterGateStub(isReadOnly: true)) { client in
            try await client.execute(uri: "/api/v1/books/7/chapters", method: .get) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/7/chapters",
                method: .post,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"title":"blocked"}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 40009)
            }
        }
        #expect(await port.createCall == nil)

        let malformedPort = ChapterPortStub()
        try await withChapterAPI(port: malformedPort) { client in
            try await client.execute(
                uri: "/api/v1/chapters/9/starred",
                method: .put,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"isStarred":"yes"}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
            }
        }
        #expect(await malformedPort.starCall == nil)
    }

    @Test
    func onlineSearchCatalogAndImportRoutesPreserveAndroidParametersAndGateBothImportWrites() async throws {
        let port = ChapterPortStub()
        try await withChapterAPI(port: port, gate: ChapterGateStub(isReadOnly: true)) { client in
            try await client.execute(
                uri: "/api/v1/books/7/chapters/online/search?keyword=%E4%B9%A6%20%E5%90%8D",
                method: .get
            ) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [[String: Any]])
                #expect(data.first?["doubanId"] as? Int == 42)
                #expect(data.first?["hasCatalog"] as? Bool == true)
            }
            try await client.execute(
                uri: "/api/v1/books/7/chapters/online-catalog?doubanId=42",
                method: .get
            ) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [String: Any])
                #expect(data["source"] as? String == "wenqu")
                #expect(data["catalog"] as? String == "第一章\n第二章")
            }
            try await client.execute(
                uri: "/api/v1/books/7/chapters/import-preview",
                method: .post,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"catalog":"第一章\n  子章"}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
                #expect(envelope["code"] as? Int == 40009)
            }
            try await client.execute(
                uri: "/api/v1/books/7/chapters/import-commit",
                method: .post,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"catalog":"第一章","selectedKeys":["p-0-0"]}"#)
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 40009)
            }
        }
        #expect(await port.onlineSearchCall == ChapterOnlineSearchCall(bookID: 7, keyword: "书 名"))
        #expect(await port.onlineCatalogCall == ChapterOnlineCatalogCall(bookID: 7, doubanID: 42))
        #expect(await port.previewCall == nil)
        #expect(await port.commitCall == nil)

        let fallbackPort = ChapterPortStub()
        try await withChapterAPI(port: fallbackPort) { client in
            try await client.execute(
                uri: "/api/v1/books/8/chapters/online-catalog?doubanId=0",
                method: .get
            ) { response in
                let envelope = try chapterEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/8/chapters/import-commit",
                method: .post,
                headers: [.contentType: "application/json"],
                body: chapterBody(#"{"catalog":"第一章","selectedKeys":["p-0-0"]}"#)
            ) { response in
                let data = try #require(chapterEnvelope(response)["data"] as? [String: Any])
                #expect(data["created"] as? Int == 1)
            }
        }
        #expect(await fallbackPort.onlineCatalogCall == ChapterOnlineCatalogCall(bookID: 8, doubanID: nil))
        #expect(
            await fallbackPort.commitCall
                == ChapterCommitCall(bookID: 8, catalog: "第一章", selectedKeys: ["p-0-0"])
        )
    }

    private func withChapterAPI(
        port: ChapterPortStub,
        gate: ChapterGateStub = ChapterGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, chapter: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebChapterRoutes.definitions)
        )
        DesktopWebChapterRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct ChapterCreateCall: Equatable, Sendable {
    let bookID: Int64
    let title: String
    let parentID: Int64?
}

private struct ChapterUpdateCall: Equatable, Sendable {
    let id: Int64
    let title: String
}

private struct ChapterStarCall: Equatable, Sendable {
    let id: Int64
    let isStarred: Bool
}

private struct ChapterBatchCreateCall: Equatable, Sendable {
    let bookID: Int64
    let titles: [String]
    let parentID: Int64?
}

private struct ChapterOrderCall: Equatable, Sendable {
    let scopeID: Int64
    let ids: [Int64]
}

private struct ChapterMoveCall: Equatable, Sendable {
    let ids: [Int64]
    let parentID: Int64
}

private struct ChapterOnlineSearchCall: Equatable, Sendable {
    let bookID: Int64
    let keyword: String
}

private struct ChapterOnlineCatalogCall: Equatable, Sendable {
    let bookID: Int64
    let doubanID: Int?
}

private struct ChapterPreviewCall: Equatable, Sendable {
    let bookID: Int64
    let catalog: String
}

private struct ChapterCommitCall: Equatable, Sendable {
    let bookID: Int64
    let catalog: String
    let selectedKeys: [String]
}

private actor ChapterGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) {
        self.isReadOnly = isReadOnly
    }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor ChapterPortStub: DesktopWebChapterPort {
    private(set) var readBookIDs: [Int64] = []
    private(set) var createCall: ChapterCreateCall?
    private(set) var updateCall: ChapterUpdateCall?
    private(set) var starCall: ChapterStarCall?
    private(set) var deletedID: Int64?
    private(set) var batchDeleteIDs: [Int64]?
    private(set) var parentOrderCall: ChapterOrderCall?
    private(set) var childOrderCall: ChapterOrderCall?
    private(set) var moveToParentCall: ChapterMoveCall?
    private(set) var moveOutIDs: [Int64]?
    private(set) var batchCreateCall: ChapterBatchCreateCall?
    private(set) var onlineSearchCall: ChapterOnlineSearchCall?
    private(set) var onlineCatalogCall: ChapterOnlineCatalogCall?
    private(set) var previewCall: ChapterPreviewCall?
    private(set) var commitCall: ChapterCommitCall?

    func chapters(bookID: Int64) async throws -> [DesktopWebChapterFull] {
        readBookIDs.append(bookID)
        let child = DesktopWebChapterFull(
            id: 2,
            title: "子章节",
            order: 0,
            noteCount: 2,
            children: [],
            parentId: 1,
            level: 2,
            pathTitles: ["父章节", "子章节"],
            directNoteCount: 2,
            descendantNoteCount: 2,
            isStarred: false
        )
        return [
            DesktopWebChapterFull(
                id: 1,
                title: "父章节",
                order: 0,
                noteCount: 1,
                children: [child],
                parentId: 0,
                level: 1,
                pathTitles: ["父章节"],
                directNoteCount: 1,
                descendantNoteCount: 3,
                isStarred: true
            )
        ]
    }

    func lastUsedChapter(bookID: Int64) async throws -> DesktopWebChapter? {
        readBookIDs.append(bookID)
        return chapterFixture()
    }

    func starredChapterGroups() async throws -> [DesktopWebStarredChapterGroup] {
        [
            DesktopWebStarredChapterGroup(
                book: DesktopWebChapterBook(
                    id: 7,
                    name: "书",
                    cover: "/api/v1/books/7/cover",
                    author: "作者",
                    press: "出版社"
                ),
                chapters: [starredFixture()],
                chapterCount: 1,
                noteCount: 3,
                latestUpdatedTime: 100
            )
        ]
    }

    func createChapter(
        bookID: Int64,
        request: DesktopWebChapterCreateRequest
    ) async throws -> DesktopWebChapterResult {
        createCall = ChapterCreateCall(bookID: bookID, title: request.title, parentID: request.parentId)
        return DesktopWebChapterResult(id: 10, title: request.title, parentId: request.parentId ?? 0, order: 1)
    }

    func updateChapter(
        id: Int64,
        request: DesktopWebChapterUpdateRequest
    ) async throws -> DesktopWebChapterResult {
        updateCall = ChapterUpdateCall(id: id, title: request.title)
        return DesktopWebChapterResult(id: id, title: request.title, parentId: 0, order: 1)
    }

    func updateChapterStarred(
        id: Int64,
        request: DesktopWebChapterStarredRequest
    ) async throws -> DesktopWebChapter {
        starCall = ChapterStarCall(id: id, isStarred: request.isStarred)
        return chapterFixture()
    }

    func deleteChapter(id: Int64) async throws { deletedID = id }

    func batchDeleteChapters(_ request: DesktopWebChapterIDsRequest) async throws {
        batchDeleteIDs = request.ids
    }

    func reorderParentChapters(bookID: Int64, request: DesktopWebChapterIDsRequest) async throws {
        parentOrderCall = ChapterOrderCall(scopeID: bookID, ids: request.ids)
    }

    func reorderChildChapters(parentID: Int64, request: DesktopWebChapterIDsRequest) async throws {
        childOrderCall = ChapterOrderCall(scopeID: parentID, ids: request.ids)
    }

    func moveChaptersToParent(_ request: DesktopWebChapterMoveToParentRequest) async throws {
        moveToParentCall = ChapterMoveCall(ids: request.chapterIds, parentID: request.parentId)
    }

    func moveChaptersOut(_ request: DesktopWebChapterMoveOutRequest) async throws {
        moveOutIDs = request.chapterIds
    }

    func batchCreateChapters(
        bookID: Int64,
        request: DesktopWebChapterBatchCreateRequest
    ) async throws -> DesktopWebChapterBatchResult {
        batchCreateCall = ChapterBatchCreateCall(
            bookID: bookID,
            titles: request.titles,
            parentID: request.parentId
        )
        return DesktopWebChapterBatchResult(
            created: [DesktopWebChapterResult(id: 11, title: "A", parentId: request.parentId ?? 0, order: 1)]
        )
    }

    func searchOnlineChapterCandidates(
        bookID: Int64,
        keyword: String
    ) async throws -> [DesktopWebOnlineChapterCandidate] {
        onlineSearchCall = ChapterOnlineSearchCall(bookID: bookID, keyword: keyword)
        return [
            DesktopWebOnlineChapterCandidate(
                title: "书名",
                author: "作者",
                publisher: "出版社",
                pubDate: "2024",
                cover: "cover",
                doubanId: 42,
                hasCatalog: true
            )
        ]
    }

    func onlineChapterCatalog(
        bookID: Int64,
        doubanID: Int?
    ) async throws -> DesktopWebOnlineChapterCatalog {
        onlineCatalogCall = ChapterOnlineCatalogCall(bookID: bookID, doubanID: doubanID)
        return DesktopWebOnlineChapterCatalog(
            doubanId: doubanID ?? 42,
            title: "书名",
            catalog: "第一章\n第二章"
        )
    }

    func previewChapterImport(
        bookID: Int64,
        request: DesktopWebChapterImportPreviewRequest
    ) async throws -> DesktopWebChapterImportPreview {
        previewCall = ChapterPreviewCall(bookID: bookID, catalog: request.catalog)
        return DesktopWebChapterImportPreview(
            items: [
                DesktopWebChapterImportNode(
                    key: "p-0-0",
                    title: "第一章",
                    depth: 0,
                    duplicate: false,
                    selected: true,
                    children: [
                        DesktopWebChapterImportNode(
                            key: "p-0-0-1-0",
                            title: "子章",
                            depth: 1,
                            duplicate: false,
                            selected: true,
                            children: []
                        )
                    ]
                )
            ],
            totalCount: 2,
            selectableCount: 2,
            duplicateCount: 0,
            selectedCount: 2
        )
    }

    func commitChapterImport(
        bookID: Int64,
        request: DesktopWebChapterImportCommitRequest
    ) async throws -> DesktopWebChapterImportCommitResult {
        commitCall = ChapterCommitCall(
            bookID: bookID,
            catalog: request.catalog,
            selectedKeys: request.selectedKeys
        )
        return DesktopWebChapterImportCommitResult(created: 1, skipped: 0, duplicated: 0)
    }

    private func chapterFixture() -> DesktopWebChapter {
        DesktopWebChapter(
            id: 9,
            title: "子章节",
            parentTitle: "父章节",
            parentId: 1,
            level: 2,
            pathTitles: ["父章节", "子章节"],
            isStarred: true
        )
    }

    private func starredFixture() -> DesktopWebStarredChapter {
        DesktopWebStarredChapter(
            id: 9,
            title: "子章节",
            parentTitle: "父章节",
            parentId: 1,
            level: 2,
            pathTitles: ["父章节", "子章节"],
            order: 0,
            noteCount: 2,
            directNoteCount: 2,
            descendantNoteCount: 2,
            updatedTime: 100,
            ancestorIds: [1],
            isStarred: true
        )
    }
}

private func chapterBody(_ value: String) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
    buffer.writeString(value)
    return buffer
}

private func chapterEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
    )
}
