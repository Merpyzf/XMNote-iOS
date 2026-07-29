import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebExternalRoutesTests {
    @Test
    func aiRoutesPreserveConfigPatchAndTransparentHTTPResponse() async throws {
        let port = ExternalPortStub()
        try await withExternalAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/ai/config", method: .get) { response in
                let data = try envelopeData(response)
                #expect(data["provider"] as? String == "deepseek")
                #expect(data["deepSeekApiKey"] as? String == "fixture-secret")
            }

            try await client.execute(
                uri: "/api/v1/ai/config",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"provider":"siliconflow","siliconFlowModel":"Qwen/Test"}"#)
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
                #expect(envelope["data"] == nil)
                #expect(
                    await port.lastAIConfigPatch() == .object([
                        "provider": .string("siliconflow"),
                        "siliconFlowModel": .string("Qwen/Test")
                    ])
                )
            }

            try await client.execute(
                uri: "/api/v1/ai/chat/completions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"messages":[{"role":"user","content":"你好"}],"stream":false}"#)
            ) { response in
                #expect(response.status.code == 201)
                #expect(response.headers[.contentType] == "application/json")
                #expect(String(buffer: response.body) == #"{"fixture":true}"#)
                #expect(await port.lastChatBody()?.contains(Data("你好".utf8)) == true)
            }
        }
    }

    @Test
    func malformedAIConfigUsesAndroidBusinessErrorEnvelope() async throws {
        let port = ExternalPortStub()
        let cases = [
            (
                body: "{",
                message: "请求体 JSON 格式错误"
            ),
            (
                body: "[]",
                message: "请求体 JSON 格式错误"
            ),
            (
                body: #"{"a":1,}"#,
                message: "请求体 JSON 格式错误"
            ),
            (
                body: "null",
                message: "请求体不能为空"
            )
        ]
        try await withExternalAPI(port: port) { client in
            for item in cases {
                try await client.execute(
                    uri: "/api/v1/ai/config",
                    method: .put,
                    headers: [.contentType: "application/json"],
                    body: jsonBody(item.body)
                ) { response in
                    let envelope = try decodeJSONObject(response)
                    #expect(response.status == .ok)
                    #expect(envelope["code"] as? Int == 40001)
                    #expect(envelope["msg"] as? String == item.message)
                    #expect(await port.lastAIConfigPatch() == nil)
                }
            }
        }
    }

    @Test
    func onlineSearchAndCoverProxyPreserveQueriesAndRawBytes() async throws {
        let port = ExternalPortStub()
        try await withExternalAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/search/online?keyword=Swift%20Book",
                method: .get
            ) { response in
                let data = try envelopeArray(response)
                let item = try #require(data.first as? [String: Any])
                #expect(item["title"] as? String == "Swift Book")
                #expect(await port.lastOnlineKeyword() == "Swift Book")
            }

            try await client.execute(
                uri: "/api/v1/book-covers/proxy/42?expires=123456&sig=fixture-signature",
                method: .get
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "image/png")
                #expect(Data(response.body.readableBytesView) == Data([0x89, 0x50, 0x4e, 0x47]))
                let request = await port.lastCoverRequest()
                #expect(request?.bookID == 42)
                #expect(request?.expires == 123_456)
                #expect(request?.signature == "fixture-signature")
            }

            try await client.execute(uri: "/api/v1/books/search/online", method: .get) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "Missing param [keyword] for method parameter.")
            }

            try await client.execute(
                uri: "/api/v1/book-covers/proxy/999999",
                method: .get
            ) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.contentType] == nil)
                #expect(String(buffer: response.body) == "书籍不存在")
            }
        }
    }

    @Test
    func exportRoutesCoverPlatformListsDownloadAndRemoteSummary() async throws {
        let port = ExternalPortStub()
        try await withExternalAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/export/platforms/siyuan/notebooks",
                method: .get
            ) { response in
                let item = try #require(try envelopeArray(response).first as? [String: Any])
                #expect(item["id"] as? String == "notebook-1")
                #expect(item["name"] as? String == "默认笔记本")
            }

            try await client.execute(
                uri: "/api/v1/export/platforms/obsidian/dirs",
                method: .get
            ) { response in
                let item = try #require(try envelopeArray(response).first as? [String: Any])
                #expect(item["id"] as? String == "XMNote")
            }

            let request = #"{"bookIds":[7],"target":"markdown","content":{"note":true,"relevant":false,"review":true}}"#
            try await client.execute(
                uri: "/api/v1/export/notes/local",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(request)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/markdown; charset=utf-8")
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(
                    response.headers[.init("Access-Control-Expose-Headers")!]
                        == "Content-Disposition, Content-Type, Cache-Control"
                )
                #expect(response.headers[.contentDisposition]?.contains("fixture.md") == true)
                #expect(String(buffer: response.body) == "# fixture")
                #expect(await port.lastLocalExport()?.bookIds == [7])
            }

            try await client.execute(
                uri: "/api/v1/export/notes/remote",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(request)
            ) { response in
                let data = try envelopeData(response)
                #expect(data["total"] as? Int == 1)
                #expect(data["successCount"] as? Int == 1)
                #expect(data["failCount"] as? Int == 0)
                #expect(await port.lastRemoteExport()?.target == "markdown")
            }
        }
    }

    @Test
    func importRoutesDecodeMultipartAndPreserveTaskLifecycle() async throws {
        let port = ExternalPortStub()
        try await withExternalAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/import/tasks",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody("{")
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(
                    envelope["msg"] as? String
                        == "Missing param [file] for method parameter."
                )
                #expect(response.headers[.cacheControl] == nil)
            }

            let create = multipartBody(
                fields: [:],
                files: [("file", "../fixture.txt", "text/plain", Data("book fixture".utf8))]
            )
            try await client.execute(
                uri: "/api/v1/import/tasks",
                method: .post,
                headers: [.contentType: create.contentType],
                body: create.body
            ) { response in
                let data = try envelopeData(response)
                #expect(data["taskId"] as? String == "task-1")
                #expect(data["status"] as? String == "parsing")
                let file = await port.lastImportFile()
                #expect(file?.fileName == "fixture.txt")
                #expect(file?.data == Data("book fixture".utf8))
            }

            try await client.execute(uri: "/api/v1/import/tasks/task-1", method: .get) { response in
                let data = try envelopeData(response)
                #expect(data["taskId"] as? String == "task-1")
                #expect(data["status"] as? String == "ready")
            }

            try await client.execute(
                uri: "/api/v1/import/tasks/task-1/commit",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"books":[{"index":0,"noteIndexes":[0,2],"targetBookId":99,"clearTargetBook":true}]}"#)
            ) { response in
                let data = try envelopeData(response)
                #expect(data["importedBookCount"] as? Int == 1)
                #expect(data["importedNoteCount"] as? Int == 2)
                let commit = await port.lastImportCommit()
                #expect(commit?.id == "task-1")
                #expect(commit?.request.books.first?.noteIndexes == [0, 2])
                #expect(commit?.request.books.first?.targetBookId == 99)
                #expect(commit?.request.books.first?.clearTargetBook == true)
            }

            try await client.execute(uri: "/api/v1/import/tasks/task-1", method: .delete) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
                #expect(envelope["data"] == nil)
                #expect(await port.lastDeletedImportID() == "task-1")
            }

            try await client.execute(uri: "/api/v1/import/tasks/task-1", method: .get) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "导入任务不存在或已过期")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }
        }
    }

    @Test
    func uploadRoutesApplyCountFloorAndDecodeBothMultipartShapes() async throws {
        let port = ExternalPortStub()
        try await withExternalAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/note-images/upload",
                method: .post
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "Missing param [ticketId] for method parameter.")
            }

            try await client.execute(
                uri: "/api/v1/book-covers/upload",
                method: .post
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "Missing param [file] for method parameter.")
            }

            try await client.execute(
                uri: "/api/v1/note-images/upload-tickets",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"count":0}"#)
            ) { response in
                let data = try envelopeData(response)
                let tickets = try #require(data["tickets"] as? [[String: Any]])
                #expect(tickets.first?["ticketId"] as? String == "ticket-1")
                #expect(data["remaining"] as? Int == 19)
                #expect(await port.lastReservedCount() == 1)
            }

            try await client.execute(
                uri: "/api/v1/note-images/upload-tickets",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"count":20}"#)
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40006)
                #expect(envelope["msg"] as? String == "图片上传过于频繁，请稍后再试")
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
            }

            let upload = multipartBody(
                fields: ["ticketId": " ticket-1 "],
                files: [("file", "note.png", "image/png", Data([1, 2, 3]))]
            )
            try await client.execute(
                uri: "/api/v1/note-images/upload",
                method: .post,
                headers: [.contentType: upload.contentType],
                body: upload.body
            ) { response in
                let data = try envelopeData(response)
                #expect(data["url"] as? String == "https://fixture.test/note.png")
                #expect(data["ticketId"] as? String == "ticket-1")
                let request = await port.lastNoteUpload()
                #expect(request?.ticketID == "ticket-1")
                #expect(request?.file.fileName == "note.png")
            }

            try await client.execute(
                uri: "/api/v1/note-images/upload-tickets/release",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"ticketIds":["ticket-1","ticket-2"]}"#)
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
                #expect((envelope["data"] as? [String: Any])?.isEmpty == true)
                #expect(await port.lastReleasedTickets() == ["ticket-1", "ticket-2"])
            }

            let cover = multipartBody(
                fields: [:],
                files: [("file", "cover.webp", "image/webp", Data([4, 5, 6]))]
            )
            try await client.execute(
                uri: "/api/v1/book-covers/upload",
                method: .post,
                headers: [.contentType: cover.contentType],
                body: cover.body
            ) { response in
                let data = try envelopeData(response)
                #expect(data["url"] as? String == "https://fixture.test/cover.webp")
                #expect(await port.lastCoverUpload()?.contentType == "image/webp")
            }
        }
    }

    private func withExternalAPI(
        port: ExternalPortStub,
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let gate = ExternalRequestGateStub()
        let dependencies = DesktopWebAPIDependencies(
            requestGate: gate,
            ai: port,
            onlineBook: port,
            bookCover: port,
            export: port,
            importTask: port,
            upload: port
        )
        let definitions = DesktopWebAIRoutes.definitions
            .union(DesktopWebExternalBookRoutes.definitions)
            .union(DesktopWebExportRoutes.definitions)
            .union(DesktopWebImportRoutes.definitions)
            .union(DesktopWebUploadRoutes.definitions)
        let router = Router()
        router.middlewares.add(DesktopWebCachePolicyMiddleware())
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: definitions)
        )
        DesktopWebAIRoutes(port: port).register(on: router)
        DesktopWebExternalBookRoutes(onlineBook: port, bookCover: port).register(on: router)
        DesktopWebExportRoutes(port: port).register(on: router)
        DesktopWebImportRoutes(port: port).register(on: router)
        DesktopWebUploadRoutes(port: port).register(on: router)
        let app = Application(responder: router.buildResponder())
        try await app.test(.router, test)
    }

    private func decodeJSONObject(_ response: TestResponse) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView))
        return try #require(value as? [String: Any])
    }

    private func envelopeData(_ response: TestResponse) throws -> [String: Any] {
        let envelope = try decodeJSONObject(response)
        #expect(envelope["code"] as? Int == 200)
        #expect(envelope["msg"] as? String == "success")
        return try #require(envelope["data"] as? [String: Any])
    }

    private func envelopeArray(_ response: TestResponse) throws -> [Any] {
        let envelope = try decodeJSONObject(response)
        #expect(envelope["code"] as? Int == 200)
        #expect(envelope["msg"] as? String == "success")
        return try #require(envelope["data"] as? [Any])
    }

    private func jsonBody(_ value: String) -> ByteBuffer {
        ByteBuffer(bytes: value.utf8)
    }

    private func multipartBody(
        fields: [String: String],
        files: [(name: String, fileName: String, contentType: String, data: Data)]
    ) -> (contentType: String, body: ByteBuffer) {
        let boundary = "XMNoteBoundary\(UUID().uuidString)"
        var data = Data()
        for (name, value) in fields {
            data.append(Data("--\(boundary)\r\n".utf8))
            data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            data.append(Data(value.utf8))
            data.append(Data("\r\n".utf8))
        }
        for file in files {
            data.append(Data("--\(boundary)\r\n".utf8))
            data.append(Data(
                "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.fileName)\"\r\n".utf8
            ))
            data.append(Data("Content-Type: \(file.contentType)\r\n\r\n".utf8))
            data.append(file.data)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return ("multipart/form-data; boundary=\(boundary)", ByteBuffer(bytes: data))
    }
}

private actor ExternalRequestGateStub: DesktopWebRequestGatePort {
    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { false }
}

private actor ExternalPortStub:
    DesktopWebAIPort,
    DesktopWebOnlineBookPort,
    DesktopWebBookCoverPort,
    DesktopWebExportPort,
    DesktopWebImportPort,
    DesktopWebUploadPort {
    private var aiPatch: DesktopWebJSONValue?
    private var chatBody: Data?
    private var onlineKeyword: String?
    private var coverRequest: (bookID: Int64, expires: Int64?, signature: String?)?
    private var localExport: DesktopWebNoteExportRequest?
    private var remoteExport: DesktopWebNoteExportRequest?
    private var importFile: DesktopWebUploadedFile?
    private var importCommit: (id: String, request: DesktopWebImportTaskCommitRequest)?
    private var deletedImportID: String?
    private var reservedCount: Int?
    private var noteUpload: (ticketID: String, file: DesktopWebUploadedFile)?
    private var releasedTickets: [String]?
    private var coverUpload: DesktopWebUploadedFile?

    func aiConfig() async throws -> DesktopWebJSONValue {
        .object([
            "provider": .string("deepseek"),
            "deepSeekApiKey": .string("fixture-secret")
        ])
    }

    func updateAIConfig(_ patch: DesktopWebJSONValue) async throws {
        aiPatch = patch
    }

    func chatCompletions(body: Data) async throws -> DesktopWebRawHTTPResponse {
        chatBody = body
        return .init(
            statusCode: 201,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"fixture":true}"#.utf8)
        )
    }

    func searchOnlineBooks(keyword: String) async throws -> [DesktopWebOnlineBook] {
        onlineKeyword = keyword
        return [
            .init(
                title: "Swift Book",
                author: "Fixture",
                publisher: "XMNote Press",
                pubDate: "2026",
                cover: "https://fixture.test/book.png",
                isbn: "9780000000000",
                summary: "summary",
                authorIntro: "intro",
                catalog: "catalog"
            )
        ]
    }

    func proxiedBookCover(
        bookID: Int64,
        expires: Int64?,
        signature: String?
    ) async throws -> DesktopWebRawHTTPResponse {
        if bookID == 999_999 {
            throw DesktopWebAPIError(code: 404, message: "书籍不存在")
        }
        coverRequest = (bookID, expires, signature)
        return .init(
            statusCode: 200,
            headers: ["Content-Type": "image/png", "Cache-Control": "public, max-age=86400"],
            body: Data([0x89, 0x50, 0x4e, 0x47])
        )
    }

    func siYuanNotebooks() async throws -> [DesktopWebExportPlatformOption] {
        [.init(id: "notebook-1", name: "默认笔记本")]
    }

    func obsidianDirectories() async throws -> [DesktopWebExportPlatformOption] {
        [.init(id: "XMNote", name: "XMNote")]
    }

    func exportNotesLocally(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebExportFile {
        localExport = request
        return .init(
            fileName: "fixture.md",
            mediaType: "text/markdown; charset=utf-8",
            data: Data("# fixture".utf8)
        )
    }

    func exportNotesRemotely(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebRemoteExportResult {
        remoteExport = request
        return .init(total: 1, successCount: 1, failCount: 0, failedItems: [])
    }

    func createImportTask(file: DesktopWebUploadedFile) async throws -> DesktopWebImportTaskCreateResponse {
        importFile = file
        return .init(taskId: "task-1", status: "parsing")
    }

    func importTask(id: String) async throws -> DesktopWebJSONValue {
        if deletedImportID == id {
            throw DesktopWebAPIError(code: 40001, message: "导入任务不存在或已过期")
        }
        return .object(["taskId": .string(id), "status": .string("ready")])
    }

    func commitImportTask(
        id: String,
        request: DesktopWebImportTaskCommitRequest
    ) async throws -> DesktopWebImportTaskCommitResponse {
        importCommit = (id, request)
        return .init(importedBookCount: 1, importedNoteCount: 2)
    }

    func deleteImportTask(id: String) async throws {
        deletedImportID = id
    }

    func reserveNoteImageTickets(count: Int) async throws -> DesktopWebUploadTicketReserveResult {
        if count == 20 {
            throw DesktopWebAPIError(code: 40006, message: "图片上传过于频繁，请稍后再试")
        }
        reservedCount = count
        return .init(
            tickets: [.init(ticketId: "ticket-1", expiresAt: 1_234_567)],
            remaining: 19
        )
    }

    func uploadNoteImage(
        ticketID: String,
        file: DesktopWebUploadedFile
    ) async throws -> DesktopWebNoteImageUploadResult {
        noteUpload = (ticketID, file)
        return .init(
            url: "https://fixture.test/note.png",
            ticketId: ticketID,
            expiresAt: 1_234_567
        )
    }

    func releaseNoteImageTickets(_ ticketIDs: [String]) async throws {
        releasedTickets = ticketIDs
    }

    func uploadBookCover(file: DesktopWebUploadedFile) async throws -> DesktopWebBookCoverUploadResult {
        coverUpload = file
        return .init(url: "https://fixture.test/cover.webp")
    }

    func lastAIConfigPatch() -> DesktopWebJSONValue? { aiPatch }
    func lastChatBody() -> Data? { chatBody }
    func lastOnlineKeyword() -> String? { onlineKeyword }
    func lastCoverRequest() -> (bookID: Int64, expires: Int64?, signature: String?)? { coverRequest }
    func lastLocalExport() -> DesktopWebNoteExportRequest? { localExport }
    func lastRemoteExport() -> DesktopWebNoteExportRequest? { remoteExport }
    func lastImportFile() -> DesktopWebUploadedFile? { importFile }
    func lastImportCommit() -> (id: String, request: DesktopWebImportTaskCommitRequest)? { importCommit }
    func lastDeletedImportID() -> String? { deletedImportID }
    func lastReservedCount() -> Int? { reservedCount }
    func lastNoteUpload() -> (ticketID: String, file: DesktopWebUploadedFile)? { noteUpload }
    func lastReleasedTickets() -> [String]? { releasedTickets }
    func lastCoverUpload() -> DesktopWebUploadedFile? { coverUpload }
}
