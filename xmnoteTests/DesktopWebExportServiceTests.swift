/**
 * [INPUT]: 依赖 AppDatabase.empty、DesktopWebExportService、隔离设置和可控 URLProtocol
 * [OUTPUT]: 验证 4 条导出 API 的空范围、平台枚举、本地文件及四类远端目标合同
 * [POS]: iOS App Web 导出编排单元测试；锁定 Android NoteExportWebService 的关键可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
import XMNoteWeb
@testable import xmnote

@MainActor
struct DesktopWebExportServiceTests {
    @Test
    func emptyRemoteScopeReturnsZeroBeforeCredentialValidation() async throws {
        let fixture = try makeExportFixture()
        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [],
            target: "yuque",
            content: .init(note: true, relevant: true, review: true)
        ))
        #expect(result == .init(total: 0, successCount: 0, failCount: 0, failedItems: []))
    }

    @Test
    func siYuanListUsesAndroidSortFallbackAndBlankNameFallback() async throws {
        let fixture = try makeExportFixture()
        try await updateExportSettings(fixture.settings, [
            "siyuanIp": "127.0.0.1",
            "siyuanPort": "6806",
            "siyuanToken": "token"
        ])
        ExportURLProtocolFixture.install(forHost: "127.0.0.1") { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:6806/api/notebook/lsNotebooks")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token token")
            return response(
                request,
                status: 200,
                json: """
                {
                  "code": 0,
                  "data": {
                    "notebooks": [
                      {"id":"2000-two","name":" B ","sort":0},
                      {"id":"1000-one","name":"   ","sort":0},
                      {"id":"fixed","name":"A","sort":5}
                    ]
                  }
                }
                """
            )
        }

        let values = try await fixture.service.siYuanNotebooks()
        #expect(values.map(\.id) == ["fixed", "1000-one", "2000-two"])
        #expect(values.map(\.name) == ["A", "1000-one", "B"])
    }

    @Test
    func localMarkdownUsesTimestampedEscapedNameAndAndroidTextShape() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        let result = try await fixture.service.exportNotesLocally(.init(
            bookIds: [101],
            target: "markdown",
            content: .init(note: true, relevant: false, review: false)
        ))

        #expect(result.mediaType == "text/markdown")
        #expect(result.fileName.hasPrefix("A_B_书摘_"))
        #expect(result.fileName.hasSuffix(".md"))
        let text = try #require(String(data: result.data, encoding: .utf8))
        #expect(text.contains("<center><font size=4>《A:B》</font></center>"))
        #expect(text.contains("<center><font color='#6e6e6e' size=2>1 条书摘</font></center>"))
        #expect(text.contains("原文<br>第二行"))
        #expect(text.contains("> 想法"))
        #expect(text.contains("<font color='#6e6e6e' size=2> 页码：12 | 2023-11-15 06:13:20 </font>"))
    }

    @Test
    func yuqueCreatesMissingRepoWithFormBodyThenUploadsDocument() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        try await updateExportSettings(fixture.settings, ["yuqueToken": "token"])
        let recorder = ExportRequestRecorder()
        ExportURLProtocolFixture.install(forHost: "www.yuque.com") { request in
            let index = recorder.append(request)
            switch index {
            case 0:
                return response(request, status: 200, json: #"{"data":{"id":42}}"#)
            case 1:
                return response(request, status: 200, json: #"{"data":[]}"#)
            case 2:
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
                let body = requestBodyData(request) ?? Data()
                let text = String(decoding: body, as: UTF8.self)
                #expect(text.contains("name=%E7%BA%B8%E9%97%B4%E4%B9%A6%E6%91%98"))
                #expect(text.contains("description=%E4%BB%8E%E7%BA%B8%E9%97%B4%E4%B9%A6%E6%91%98%E5%AF%BC%E5%87%BA%E7%9A%84%E8%AF%BB%E4%B9%A6%E7%AC%94%E8%AE%B0"))
                return response(request, status: 200, json: #"{"data":{"id":99}}"#)
            case 3:
                #expect(request.url?.path == "/api/v2/repos/99/docs")
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
                let text = String(decoding: requestBodyData(request) ?? Data(), as: UTF8.self)
                #expect(text.contains("format=markdown"))
                #expect(text.contains("title=A%3AB_%E4%B9%A6%E6%91%98_"))
                let decoded = text.removingPercentEncoding ?? text
                #expect(decoded.contains(#"<img src=""#))
                #expect(decoded.contains(#"<img>"#))
                #expect(decoded.contains("原文<br>第二行"))
                return response(request, status: 200, json: #"{"data":{"id":1}}"#)
            default:
                Issue.record("出现未预期的语雀请求: \(request.url?.absoluteString ?? "")")
                return response(request, status: 500, json: "{}")
            }
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "yuque",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.total == 1)
        #expect(result.successCount == 1)
        #expect(result.failCount == 0)
        #expect(recorder.count == 4)
    }

    @Test
    func notionValidatesOrCreatesDatabaseThenUploadsAndroidBlockJSON() async throws {
        let fixture = try makeExportFixture(seedBook: true, noteCount: 60)
        try await updateExportSettings(fixture.settings, [
            "notionToken": "token",
            "notionPageId": "parent-page"
        ])
        let recorder = ExportRequestRecorder()
        ExportURLProtocolFixture.install(forHost: "api.notion.com") { request in
            let index = recorder.append(request)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2022-06-28")
            switch index {
            case 0:
                #expect(request.httpMethod == "GET")
                #expect(request.url?.path == "/v1/databases")
                return response(request, status: 404, json: #"{"message":"not found"}"#)
            case 1:
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/v1/databases")
                let body = try #require(requestJSONObject(request))
                #expect((body["parent"] as? [String: Any])?["page_id"] as? String == "parent-page")
                #expect((body["icon"] as? [String: Any])?["emoji"] as? String == "📔")
                #expect(((body["properties"] as? [String: Any])?["Page"] as? [String: Any])?["title"] != nil)
                return response(request, status: 200, json: #"{"id":"database-1"}"#)
            case 2, 3, 4:
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/v1/pages")
                let body = try #require(requestJSONObject(request))
                #expect((body["parent"] as? [String: Any])?["database_id"] as? String == "database-1")
                #expect((body["icon"] as? [String: Any])?["emoji"] as? String == "📖")
                let properties = try #require(body["properties"] as? [String: Any])
                let page = try #require(properties["Page"] as? [String: Any])
                let titleItems = try #require(page["title"] as? [[String: Any]])
                let title = ((titleItems.first?["text"] as? [String: Any])?["content"] as? String) ?? ""
                #expect(title.hasSuffix("-\(index - 1)"))
                let children = try #require(body["children"] as? [[String: Any]])
                #expect(children.count <= 100)
                if index == 2 {
                    #expect(children.first?["type"] as? String == "heading_2")
                    #expect(children.contains { $0["type"] as? String == "callout" })
                }
                return response(request, status: 200, json: #"{"id":"page"}"#)
            default:
                Issue.record("出现未预期的 Notion 请求: \(request.url?.absoluteString ?? "")")
                return response(request, status: 500, json: "{}")
            }
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "notion",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.successCount == 1)
        #expect(result.failCount == 0)
        #expect(recorder.count == 5)
        #expect(await fixture.settings.notionDatabaseID() == "database-1")
    }

    @Test
    func siYuanUsesDivBlocksAndRawLineBreaks() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        try await updateExportSettings(fixture.settings, [
            "siyuanIp": "127.0.0.3",
            "siyuanPort": "6806",
            "siyuanToken": "token",
            "siyuanNotebookId": "notebook"
        ])
        ExportURLProtocolFixture.install(forHost: "127.0.0.3") { request in
            #expect(request.url?.path == "/api/filetree/createDocWithMd")
            let body = try #require(requestJSONObject(request))
            #expect(body["notebook"] as? String == "notebook")
            let markdown = try #require(body["markdown"] as? String)
            #expect(markdown.contains("<div>\n<center><img"))
            #expect(markdown.contains("<div><center><font color='#6e6e6e' size=2>1 条书摘</font></center></div>"))
            #expect(markdown.contains("原文\n第二行"))
            #expect(!markdown.contains("原文<br>第二行"))
            return response(request, status: 200, json: #"{"code":0,"data":{"id":"doc"}}"#)
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "siyuan",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.successCount == 1)
        #expect(result.failCount == 0)
    }

    @Test
    func obsidianUsesRawMarkdownAndAppendsBookTags() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        try await updateExportSettings(fixture.settings, [
            "obsidianIp": "127.0.0.4",
            "obsidianApiKey": "key",
            "obsidianDirName": "导出",
            "obsidianExportTags": true
        ])
        ExportURLProtocolFixture.install(forHost: "127.0.0.4") { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path.hasPrefix("/vault/") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
            let markdown = String(decoding: requestBodyData(request) ?? Data(), as: UTF8.self)
            #expect(markdown.contains("原文\n第二行"))
            #expect(!markdown.contains("原文<br>第二行"))
            #expect(markdown.hasSuffix("\n#Web 标签"))
            return response(request, status: 200, json: "{}")
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "obsidian",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.successCount == 1)
        #expect(result.failCount == 0)
    }
}

@MainActor
private struct ExportFixture {
    let service: DesktopWebExportService
    let settings: DesktopWebSettingsRepository
}

@MainActor
private func makeExportFixture(
    seedBook: Bool = false,
    noteCount: Int = 1
) throws -> ExportFixture {
    let database = try AppDatabase.empty()
    if seedBook {
        try database.dbPool.write { db in
            var book = BookRecord()
            book.id = 101
            book.userId = 1
            book.name = "A:B"
            book.rawName = "A:B"
            book.author = "作者"
            book.sourceId = 1
            book.readStatusId = 1
            book.positionUnit = 1
            book.createdDate = 1_700_000_000_000
            book.updatedDate = 1_700_000_000_000
            try book.insert(db)

            for index in 0..<noteCount {
                var note = NoteRecord()
                note.id = Int64(201 + index)
                note.bookId = 101
                note.content = "原文<br>第二行"
                note.idea = "想法"
                note.position = "12"
                note.positionUnit = 1
                note.includeTime = 1
                note.createdDate = 1_700_000_000_000 + Int64(index)
                note.updatedDate = 1_700_000_000_000 + Int64(index)
                try note.insert(db)
            }

            var tag = TagRecord()
            tag.id = 301
            tag.userId = 1
            tag.name = "Web 标签"
            tag.type = 2
            tag.createdDate = 1_700_000_000_000
            tag.updatedDate = 1_700_000_000_000
            try tag.insert(db)

            var relation = TagBookRecord()
            relation.id = 401
            relation.bookId = 101
            relation.tagId = 301
            relation.createdDate = 1_700_000_000_000
            relation.updatedDate = 1_700_000_000_000
            try relation.insert(db)
        }
    }
    let defaults = UserDefaults(suiteName: "DesktopWebExportServiceTests.\(UUID().uuidString)")!
    let settings = DesktopWebSettingsRepository(defaults: defaults)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExportURLProtocolFixture.self]
    let service = DesktopWebExportService(
        repository: DesktopWebExportRepository(database: database, defaults: defaults),
        settingsRepository: settings,
        session: URLSession(configuration: configuration),
        currentTimeMillis: { 1_700_000_000_000 }
    )
    return ExportFixture(service: service, settings: settings)
}

private func updateExportSettings(
    _ repository: DesktopWebSettingsRepository,
    _ object: [String: Any]
) async throws {
    try await repository.updateExportSettingsData(JSONSerialization.data(withJSONObject: object))
}

private final class ExportURLProtocolFixture: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func install(forHost host: String, _ value: @escaping Handler) {
        lock.withLock { handlers[host] = value }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try Self.lock.withLock {
                try #require(Self.handlers[request.url?.host ?? ""])
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ExportRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) -> Int {
        lock.withLock {
            requests.append(request)
            return requests.count - 1
        }
    }

    var count: Int { lock.withLock { requests.count } }
}

private func response(
    _ request: URLRequest,
    status: Int,
    json: String
) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://fixture.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!,
        Data(json.utf8)
    )
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 4_096)
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private func requestJSONObject(_ request: URLRequest) -> [String: Any]? {
    guard let data = requestBodyData(request) else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
