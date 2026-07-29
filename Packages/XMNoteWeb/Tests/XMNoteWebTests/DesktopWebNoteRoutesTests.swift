/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebNoteRoutes 与可观测 NotePort stub
 * [OUTPUT]: 验证 15 条书摘 API 的查询归一化、CRUD/批量请求、响应形状、错误包络与会员写门禁
 * [POS]: XMNoteWeb Package 书摘路由单元测试，锁定 Android NoteController 全量 HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebNoteRoutesTests {
    @Test
    func bookReadsNormalizePaginationTagsAndLegacySort() async throws {
        let port = NotePortStub()
        try await withNoteAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/7/notes?page=0&pageSize=0&chapterId=9&tagIds=3,-1,3,x&tagMode=AND&sortBy=page_index&sortOrder=ASC",
                method: .get
            ) { response in
                let data = try #require(noteEnvelope(response)["data"] as? [String: Any])
                let pagination = try #require(data["pagination"] as? [String: Any])
                #expect(pagination["page"] as? Int == 1)
                #expect(pagination["pageSize"] as? Int == 1)
                let items = try #require(data["items"] as? [[String: Any]])
                #expect(items.first?["content"] as? String == "正文")
                let counts = try #require(data["chapterNoteCounts"] as? [[String: Any]])
                #expect(counts.first?["chapterId"] as? Int == 9)
            }
            try await client.execute(uri: "/api/v1/books/7/note-tags", method: .get) { response in
                let data = try #require(noteEnvelope(response)["data"] as? [[String: Any]])
                #expect(data.first?["section"] as? String == "default")
            }
            try await client.execute(uri: "/api/v1/books/7/notes/sort-rule", method: .get) { response in
                let data = try #require(noteEnvelope(response)["data"] as? [String: Any])
                #expect(data["sortBy"] as? String == "position")
            }
        }
        #expect(
            await port.bookListCall
                == NoteBookListCall(
                    bookID: 7,
                    page: 1,
                    pageSize: 1,
                    filter: DesktopWebBookNoteFilter(
                        chapterID: 9,
                        tagID: 0,
                        tagIDs: [3],
                        tagMode: "and",
                        sortBy: "position",
                        sortOrder: "asc"
                    )
                )
        )
        #expect(await port.bookTagFilterID == 7)
        #expect(await port.sortReadID == 7)
    }

    @Test
    func globalReadsPreserveRawCommaListsAndReturnFullShape() async throws {
        let port = NotePortStub()
        try await withNoteAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/notes?page=2&pageSize=3&keyword=%20key%20&bookId=4&bookIds=8,-1,8,x&tagId=-4&tagIds=2,-1,2&tagMode=bad&sortBy=bad&sortOrder=bad&sortMode=random&excludeIds=5,-1,5",
                method: .get
            ) { response in
                let data = try #require(noteEnvelope(response)["data"] as? [String: Any])
                let items = try #require(data["items"] as? [[String: Any]])
                let book = try #require(items.first?["book"] as? [String: Any])
                #expect(book["name"] as? String == "书")
                let chapter = try #require(items.first?["chapter"] as? [String: Any])
                #expect(chapter["parentTitle"] == nil)
            }
            try await client.execute(uri: "/api/v1/note-tags/filters", method: .get) { response in
                let data = try #require(noteEnvelope(response)["data"] as? [[String: Any]])
                #expect(data.first?["name"] as? String == "全部书摘")
            }
            try await client.execute(uri: "/api/v1/notes/42", method: .get) { response in
                let data = try #require(noteEnvelope(response)["data"] as? [String: Any])
                #expect(data["id"] as? Int == 42)
            }
        }
        #expect(
            await port.globalCall
                == NoteGlobalCall(
                    page: 2,
                    pageSize: 3,
                    filter: DesktopWebGlobalNoteFilter(
                        keyword: " key ",
                        bookID: 4,
                        bookIDs: [8, -1, 8],
                        tagID: -4,
                        tagIDs: [2, -1, 2],
                        tagMode: "or",
                        sortBy: "create_time",
                        sortOrder: "desc",
                        sortMode: "random",
                        excludeIDs: [5, -1, 5]
                    )
                )
        )
        #expect(await port.globalFiltersRead)
        #expect(await port.detailID == 42)
    }

    @Test
    func createUpdateDeleteAndSortDecodeAndroidBodies() async throws {
        let port = NotePortStub()
        try await withNoteAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/notes",
                method: .post,
                headers: [.contentType: "application/json"],
                body: noteBody(#"{"bookId":7,"chapterId":9,"content":"<b>A</b>","tagIds":[3,3],"imageUrls":["u"],"createdTime":123}"#)
            ) { response in
                let data = try #require(noteEnvelope(response)["data"] as? [String: Any])
                let images = try #require(data["images"] as? [[String: Any]])
                #expect(images.first?["id"] as? Int == 0)
            }
            try await client.execute(
                uri: "/api/v1/notes/42",
                method: .put,
                headers: [.contentType: "application/json"],
                body: noteBody(#"{"idea":"想法","tagIds":[],"imageUrls":[]}"#)
            ) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(uri: "/api/v1/notes/42", method: .delete) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["data"] == nil)
            }
            try await client.execute(
                uri: "/api/v1/books/7/notes/sort-rule",
                method: .put,
                headers: [.contentType: "application/json"],
                body: noteBody(#"{"sortBy":"page_index","sortOrder":"ASC"}"#)
            ) { response in
                let data = try #require(noteEnvelope(response)["data"] as? [String: Any])
                #expect(data["sortOrder"] as? String == "asc")
            }
        }
        #expect(await port.created?.bookId == 7)
        #expect(await port.created?.tagIds == [3, 3])
        #expect(await port.updatedID == 42)
        #expect(await port.updated?.tagIds == [])
        #expect(await port.deletedID == 42)
        #expect(await port.sortWrite == NoteSortCall(bookID: 7, sortBy: "position", sortOrder: "asc"))
    }

    @Test
    func batchRoutesPreserveRawArraysRulesAndDraft() async throws {
        let port = NotePortStub()
        try await withNoteAPI(port: port) { client in
            let calls: [(String, String)] = [
                ("batch-delete", #"{"ids":[2,2,-1]}"#),
                ("batch-move-chapter", #"{"ids":[2,3],"chapterId":9}"#),
                ("batch-set-tags", #"{"ids":[2],"tagIds":[4,4],"mode":"replace"}"#),
                ("batch-move-book", #"{"ids":[2,3],"targetBookId":8}"#)
            ]
            for (route, body) in calls {
                try await client.execute(
                    uri: "/api/v1/notes/\(route)",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: noteBody(body)
                ) { response in
                    let envelope = try noteEnvelope(response)
                    #expect(envelope["code"] as? Int == 200)
                }
            }
            try await client.execute(
                uri: "/api/v1/notes/batch-merge",
                method: .post,
                headers: [.contentType: "application/json"],
                body: noteBody(#"{"ids":[2,3],"orderedIds":[3,2],"contentMergeRule":"follow","merged":{"positionUnit":99,"imageUrls":["u"]}}"#)
            ) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        #expect(await port.batchDelete == [2, 2, -1])
        #expect(await port.moveChapter == NoteMoveChapterCall(ids: [2, 3], chapterID: 9))
        #expect(await port.setTags == NoteSetTagsCall(ids: [2], tagIDs: [4, 4], mode: "replace"))
        #expect(await port.moveBook == NoteMoveBookCall(ids: [2, 3], bookID: 8))
        #expect(await port.merged?.orderedIds == [3, 2])
        #expect(await port.merged?.contentMergeRule == "follow")
        #expect(await port.merged?.merged?.positionUnit == 99)
    }

    @Test
    func conflictsMalformedQueriesAndBodiesReturn40001WithoutPortCalls() async throws {
        let port = NotePortStub()
        try await withNoteAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/7/notes?tagId=3&tagIds=4",
                method: .get
            ) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "tagId 与 tagIds 不能同时传入")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
            try await client.execute(uri: "/api/v1/notes?page=oops", method: .get) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "For input string: \"oops\"")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
            try await client.execute(
                uri: "/api/v1/notes/batch-move-book",
                method: .post,
                headers: [.contentType: "application/json"],
                body: noteBody(#"{"ids":"bad","targetBookId":8}"#)
            ) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
            }
        }
        #expect(await port.bookListCall == nil)
        #expect(await port.globalCall == nil)
        #expect(await port.moveBook == nil)
    }

    @Test
    func noteDetailNotFoundUsesAndroidControllerErrorHeaders() async throws {
        let port = NotePortStub(
            detailError: DesktopWebAPIError(code: 40002, message: "笔记不存在: 42")
        )
        try await withNoteAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/notes/42", method: .get) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 40002)
                #expect(envelope["msg"] as? String == "笔记不存在: 42")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
        }
        #expect(await port.detailID == 42)
    }

    @Test
    func readOnlyGateAllowsReadsAndStopsEveryWriteBeforePort() async throws {
        let port = NotePortStub()
        try await withNoteAPI(port: port, gate: NoteGateStub(isReadOnly: true)) { client in
            try await client.execute(uri: "/api/v1/notes/42", method: .get) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/notes",
                method: .post,
                headers: [.contentType: "application/json"],
                body: noteBody(#"{"bookId":7,"content":"A"}"#)
            ) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 40009)
            }
            try await client.execute(uri: "/api/v1/notes/42", method: .delete) { response in
                let envelope = try noteEnvelope(response)
                #expect(envelope["code"] as? Int == 40009)
            }
        }
        #expect(await port.detailID == 42)
        #expect(await port.created == nil)
        #expect(await port.deletedID == nil)
    }

    private func withNoteAPI(
        port: NotePortStub,
        gate: NoteGateStub = NoteGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, note: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebNoteRoutes.definitions)
        )
        DesktopWebNoteRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct NoteBookListCall: Equatable, Sendable {
    let bookID: Int64
    let page: Int
    let pageSize: Int
    let filter: DesktopWebBookNoteFilter
}

private struct NoteGlobalCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
    let filter: DesktopWebGlobalNoteFilter
}

private struct NoteSortCall: Equatable, Sendable {
    let bookID: Int64
    let sortBy: String
    let sortOrder: String
}

private struct NoteMoveChapterCall: Equatable, Sendable {
    let ids: [Int64]
    let chapterID: Int64
}

private struct NoteSetTagsCall: Equatable, Sendable {
    let ids: [Int64]
    let tagIDs: [Int64]
    let mode: String
}

private struct NoteMoveBookCall: Equatable, Sendable {
    let ids: [Int64]
    let bookID: Int64
}

private actor NoteGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) { self.isReadOnly = isReadOnly }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor NotePortStub: DesktopWebNotePort {
    private let detailError: DesktopWebAPIError?
    private(set) var bookListCall: NoteBookListCall?
    private(set) var bookTagFilterID: Int64?
    private(set) var sortReadID: Int64?
    private(set) var sortWrite: NoteSortCall?
    private(set) var globalCall: NoteGlobalCall?
    private(set) var globalFiltersRead = false
    private(set) var detailID: Int64?
    private(set) var created: DesktopWebNoteCreateRequest?
    private(set) var updatedID: Int64?
    private(set) var updated: DesktopWebNoteUpdateRequest?
    private(set) var deletedID: Int64?
    private(set) var batchDelete: [Int64]?
    private(set) var moveChapter: NoteMoveChapterCall?
    private(set) var setTags: NoteSetTagsCall?
    private(set) var moveBook: NoteMoveBookCall?
    private(set) var merged: DesktopWebNoteBatchMergeRequest?

    init(detailError: DesktopWebAPIError? = nil) {
        self.detailError = detailError
    }

    func bookNotes(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        filter: DesktopWebBookNoteFilter
    ) async throws -> DesktopWebBookNotesPage {
        bookListCall = NoteBookListCall(bookID: bookID, page: page, pageSize: pageSize, filter: filter)
        return DesktopWebBookNotesPage(
            items: [noteFixture()],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1),
            chapterNoteCounts: [DesktopWebBookNoteChapterCount(chapterId: 9, noteCount: 1)]
        )
    }

    func bookNoteTagFilters(bookID: Int64) async throws -> [DesktopWebNoteTagFilter] {
        bookTagFilterID = bookID
        return [filterFixture()]
    }

    func bookNoteSortRule(bookID: Int64) async throws -> DesktopWebNoteSortRule {
        sortReadID = bookID
        return DesktopWebNoteSortRule(sortBy: "position", sortOrder: "asc")
    }

    func updateBookNoteSortRule(
        bookID: Int64,
        request: DesktopWebNoteSortRuleUpdateRequest
    ) async throws -> DesktopWebNoteSortRule {
        sortWrite = NoteSortCall(bookID: bookID, sortBy: request.sortBy, sortOrder: request.sortOrder)
        return DesktopWebNoteSortRule(sortBy: request.sortBy, sortOrder: request.sortOrder)
    }

    func globalNotes(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalNote> {
        globalCall = NoteGlobalCall(page: page, pageSize: pageSize, filter: filter)
        return DesktopWebPageResult(
            items: [globalFixture()],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 1, totalPages: 1)
        )
    }

    func globalNoteTagFilters() async throws -> [DesktopWebNoteTagFilter] {
        globalFiltersRead = true
        return [filterFixture()]
    }

    func note(id: Int64) async throws -> DesktopWebBookNote {
        detailID = id
        if let detailError {
            throw detailError
        }
        return noteFixture(id: id)
    }

    func createNote(_ request: DesktopWebNoteCreateRequest) async throws -> DesktopWebNoteResult {
        created = request
        return resultFixture()
    }

    func updateNote(id: Int64, request: DesktopWebNoteUpdateRequest) async throws -> DesktopWebNoteResult {
        updatedID = id
        updated = request
        return resultFixture()
    }

    func deleteNote(id: Int64) async throws { deletedID = id }

    func batchDeleteNotes(_ request: DesktopWebNoteIDsRequest) async throws { batchDelete = request.ids }

    func batchMoveNotesToChapter(_ request: DesktopWebNoteBatchMoveChapterRequest) async throws {
        moveChapter = NoteMoveChapterCall(ids: request.ids, chapterID: request.chapterId)
    }

    func batchSetNoteTags(_ request: DesktopWebNoteBatchSetTagsRequest) async throws {
        setTags = NoteSetTagsCall(ids: request.ids, tagIDs: request.tagIds, mode: request.mode)
    }

    func batchMoveNotesToBook(_ request: DesktopWebNoteBatchMoveBookRequest) async throws {
        moveBook = NoteMoveBookCall(ids: request.ids, bookID: request.targetBookId)
    }

    func batchMergeNotes(_ request: DesktopWebNoteBatchMergeRequest) async throws -> DesktopWebNoteResult {
        merged = request
        return resultFixture()
    }

    private func noteFixture(id: Int64 = 42) -> DesktopWebBookNote {
        DesktopWebBookNote(
            id: id,
            content: "正文",
            idea: "想法",
            position: "12",
            positionUnit: 1,
            isIncludeTime: true,
            createdTime: 100,
            updatedTime: 200,
            chapter: chapterFixture(parentTitle: "父章节"),
            tags: [DesktopWebNoteTag(id: 3, name: "标签")],
            images: [DesktopWebNoteImage(id: 6, url: "u")]
        )
    }

    private func globalFixture() -> DesktopWebGlobalNote {
        DesktopWebGlobalNote(
            id: 42,
            content: "正文",
            idea: nil,
            position: nil,
            positionUnit: 1,
            createdTime: 100,
            updatedTime: 200,
            isIncludeTime: true,
            chapter: chapterFixture(parentTitle: nil),
            tags: [],
            images: [],
            book: DesktopWebNoteBook(id: 7, name: "书", cover: "c", author: "a", press: "p")
        )
    }

    private func chapterFixture(parentTitle: String?) -> DesktopWebChapter {
        DesktopWebChapter(
            id: 9,
            title: "章节",
            parentTitle: parentTitle,
            parentId: 0,
            level: 1,
            pathTitles: ["章节"],
            isStarred: false
        )
    }

    private func filterFixture() -> DesktopWebNoteTagFilter {
        DesktopWebNoteTagFilter(id: 0, name: "全部书摘", noteCount: 1, section: "default")
    }

    private func resultFixture() -> DesktopWebNoteResult {
        DesktopWebNoteResult(
            id: 42,
            bookId: 7,
            chapterId: 9,
            content: "正文",
            idea: nil,
            position: nil,
            positionUnit: 1,
            createdTime: 100,
            updatedTime: 200,
            tags: [],
            images: [DesktopWebNoteImage(id: 0, url: "u")]
        )
    }
}

private func noteBody(_ value: String) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
    buffer.writeString(value)
    return buffer
}

private func noteEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
}
