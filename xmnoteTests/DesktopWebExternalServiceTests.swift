/**
 * [INPUT]: 依赖 DesktopWeb AI/在线搜索/上传服务、可控 URLProtocol、S3 Stub 与隔离 UserDefaults
 * [OUTPUT]: 验证 7 条外部网络与上传 API 的 Android 请求合同、排序、票据归属、额度及清理副作用
 * [POS]: iOS App 外部 Web 能力单元测试；路由测试之外锁定 Adapter 的真实业务实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Nuke
import Testing
import UIKit
import XMNoteWeb
@testable import xmnote

@MainActor
struct DesktopWebExternalServiceTests {
    @Test
    func aiConfigUsesAndroidShapeAndPatchOnlyTouchesPresentFields() async throws {
        let defaults = isolatedDefaults()
        defaults.set("secret", forKey: "deepSeekAPIKey")
        defaults.set("custom-model", forKey: "deepSeekLLMModel")
        let service = DesktopWebAIService(defaults: defaults, session: stubSession())

        let initial = try #require(try await service.aiConfig().objectValue)
        #expect(initial["isEnabled"]?.booleanValue == false)
        #expect(initial["provider"]?.integerValue == 0)
        #expect(initial["deepSeek"]?.objectValue?["apiKey"]?.stringValue == "secret")
        #expect(initial["deepSeek"]?.objectValue?["model"]?.stringValue == "custom-model")
        #expect(initial["models"]?.objectValue?["siliconFlow"]?.arrayValue?.count == 3)
        #expect(initial["prompts"]?.objectValue?.count == 3)
        let autoTagSystem = initial["prompts"]?.objectValue?["autoTag"]?
            .objectValue?["system"]?.stringValue
        #expect(autoTagSystem?.hasPrefix("\n") == true)
        #expect(autoTagSystem?.hasSuffix("\n") == true)

        try await service.updateAIConfig(.object([
            "isEnabled": .boolean(true),
            "siliconFlow": .object(["model": .string("Qwen/Test")])
        ]))
        let updated = try #require(try await service.aiConfig().objectValue)
        #expect(updated["isEnabled"]?.booleanValue == true)
        #expect(updated["deepSeek"]?.objectValue?["apiKey"]?.stringValue == "secret")
        #expect(updated["siliconFlow"]?.objectValue?["model"]?.stringValue == "Qwen/Test")
    }

    @Test
    func aiProxyPreservesProviderURLHeadersBodyAndUpstreamStatus() async throws {
        let defaults = isolatedDefaults()
        defaults.set("ON", forKey: "LLMIsEnable")
        defaults.set(1, forKey: "LLMClient")
        defaults.set(" silicon-secret ", forKey: "siliconFlowAPIKey")
        let requestBody = Data(#"{"model":"fixture","stream":false}"#.utf8)
        URLProtocolFixture.install(forHost: "api.siliconflow.cn") { request in
            #expect(request.url?.absoluteString == "https://api.siliconflow.cn/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer  silicon-secret ")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(requestBodyData(request) == requestBody)
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"error":{"message":"limited"}}"#.utf8)
            )
        }
        let service = DesktopWebAIService(defaults: defaults, session: stubSession())

        let response = try await service.chatCompletions(body: requestBody)
        #expect(response.statusCode == 429)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(response.bufferedBody == Data(#"{"error":{"message":"limited"}}"#.utf8))
    }

    @Test
    func aiProxyRejectsUnknownProviderAndMissingKeyWithoutNetwork() async throws {
        let defaults = isolatedDefaults()
        let service = DesktopWebAIService(defaults: defaults, session: stubSession())

        let disabled = try await service.chatCompletions(body: Data("{}".utf8))
        #expect(disabled.statusCode == 403)
        #expect(disabled.headers["Content-Type"] == "application/json")
        #expect(disabled.bufferedBodyString?.contains("AI 功能已关闭") == true)

        defaults.set("ON", forKey: "LLMIsEnable")
        defaults.set(9, forKey: "LLMClient")
        let unknown = try await service.chatCompletions(body: Data("{}".utf8))
        #expect(unknown.statusCode == 400)
        #expect(unknown.bufferedBodyString?.contains("未知的 AI 服务商") == true)

        defaults.set(0, forKey: "LLMClient")
        let missing = try await service.chatCompletions(body: Data("{}".utf8))
        #expect(missing.statusCode == 400)
        #expect(missing.headers["Content-Type"] == "application/json")
        #expect(
            missing.bufferedBody
                == Data(#"{"error":{"message":"API Key 未配置","type":"invalid_request_error"}}"#.utf8)
        )
    }

    @Test
    func onlineSearchSendsRawKeywordAndMapsSortDateAndCatalog() async throws {
        URLProtocolFixture.install(forHost: "wenqu.annatarhe.cn") { request in
            guard let requestURL = request.url,
                  let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
                throw ExternalServiceFixtureError.invalidURL
            }
            #expect(components.path == "/api/v1/books/search")
            #expect(components.queryItems?.first(where: { $0.name == "query" })?.value == " Swift ")
            #expect(components.queryItems?.first(where: { $0.name == "page" })?.value == "1")
            #expect(components.queryItems?.first(where: { $0.name == "limit" })?.value == "50")
            #expect(
                request.value(forHTTPHeaderField: "X-Simple-Check")
                    == "500ae25e22b5de1b6c44a7d78908e7b7cc63f97b55ea9cdc50aa8fcd84b1fcba"
            )
            let data = Data("""
            {
              "books": [
                {
                  "title": "Other",
                  "author": "",
                  "press": null,
                  "pubdate": "2024-01-02T03:04:05Z",
                  "image": null,
                  "isbn": null,
                  "summary": null,
                  "authorIntro": null,
                  "catalog": " 第一章\\n\\u00a0\\n第\\u200b二章 "
                },
                {
                  "title": " Swift ",
                  "author": "Author",
                  "press": "Press",
                  "pubdate": "notTaTdate",
                  "image": "cover",
                  "isbn": "isbn",
                  "summary": "summary",
                  "authorIntro": "intro",
                  "catalog": ""
                }
              ]
            }
            """.utf8)
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        let service = DesktopWebOnlineBookService(session: stubSession())

        let books = try await service.searchOnlineBooks(keyword: " Swift ")
        #expect(books.map(\.title) == [" Swift ", "Other"])
        #expect(books[0].pubDate == "notTaTdate")
        #expect(books[1].pubDate == "2024-01")
        #expect(books[1].publisher == "")
        #expect(books[1].catalog == "第一章\n第二章")
    }

    @Test
    func onlineSearchUsesAndroidFuzzywuzzyReplacementCost() async throws {
        URLProtocolFixture.install(
            forHost: "wenqu.annatarhe.cn",
            queryValue: "活着"
        ) { request in
            let data = Data(
                """
                {
                  "books": [
                    {
                      "title": "活着再见",
                      "author": "邵雪城"
                    },
                    {
                      "title": "聂绀弩还活着",
                      "author": "《聂绀弩还活着》编辑小组等合编",
                      "pubdate": "2018-11-20T00:00:00Z"
                    }
                  ]
                }
                """.utf8
            )
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data
            )
        }
        let service = DesktopWebOnlineBookService(session: stubSession())

        let books = try await service.searchOnlineBooks(keyword: "活着")

        #expect(books.map(\.title) == ["聂绀弩还活着", "活着再见"])
        #expect(books[0].pubDate == "2018-11")
    }

    @Test
    func bookCoverProxyCoalescesRequestsAndReusesTwentyFourHourCache() async throws {
        let database = try AppDatabase.empty()
        let coverURL = "https://8.8.8.8/\(UUID().uuidString).png"
        try seedExternalBook(database, id: 101, cover: coverURL)
        let requestCount = LockedCounter()
        let png = fixturePNG()
        URLProtocolFixture.install(forHost: "8.8.8.8") { request in
            requestCount.increment()
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/jpeg"]
                )!,
                png
            )
        }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopWebBookCoverServiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settings = DesktopWebSettingsRepository(defaults: isolatedDefaults())
        await settings.setAccessAuthEnabled(false)
        var pipelineConfiguration = ImagePipeline.Configuration()
        pipelineConfiguration.imageCache = nil
        pipelineConfiguration.dataCache = nil
        let service = DesktopWebBookCoverService(
            repository: DesktopWebBookRepository(database: database),
            settingsRepository: settings,
            session: stubSession(),
            imagePipeline: ImagePipeline(configuration: pipelineConfiguration),
            cacheDirectory: cacheDirectory,
            currentTimeMillis: { 1_700_000_000_000 }
        )

        async let first = service.proxiedBookCover(
            bookID: 101,
            expires: nil,
            signature: nil
        )
        async let second = service.proxiedBookCover(
            bookID: 101,
            expires: nil,
            signature: nil
        )
        let (firstResponse, secondResponse) = try await (first, second)
        let responses = [firstResponse, secondResponse]
        #expect(responses.allSatisfy { $0.statusCode == 200 })
        #expect(responses.allSatisfy { $0.headers["Content-Type"] == "image/png" })
        #expect(responses.allSatisfy { $0.bufferedBody == png })
        #expect(requestCount.value == 1)

        let cached = try await service.proxiedBookCover(
            bookID: 101,
            expires: nil,
            signature: nil
        )
        #expect(cached.bufferedBody == png)
        #expect(requestCount.value == 1)
    }

    @Test
    func bookCoverProxyRejectsPrivateAddressBeforeNetwork() async throws {
        let database = try AppDatabase.empty()
        try seedExternalBook(database, id: 102, cover: "http://127.0.0.1/cover.png")
        let settings = DesktopWebSettingsRepository(defaults: isolatedDefaults())
        await settings.setAccessAuthEnabled(false)
        let service = DesktopWebBookCoverService(
            repository: DesktopWebBookRepository(database: database),
            settingsRepository: settings,
            session: stubSession()
        )

        await expectWebError(code: 403, message: "不支持访问内网地址") {
            _ = try await service.proxiedBookCover(
                bookID: 102,
                expires: nil,
                signature: nil
            )
        }
    }

    @Test
    func uploadTicketsEnforceOwnershipParseURLObjectKeyAndRetryCleanup() async throws {
        let defaults = isolatedDefaults()
        defaults.set("account-A", forKey: "account")
        defaults.set("2", forKey: "noteImageUploadLimit")
        let clock = MillisecondClock(1_700_000_000_000)
        let upload = UploadRepositoryStub(
            result: .init(
                objectKey: "ignored-by-web-service",
                remoteURL: URL(string: "https://example.com/folder/note%20image.png")!
            )
        )
        let service = DesktopWebUploadService(
            configRepository: ConfigRepositoryStub(id: 1),
            uploadRepository: upload,
            defaults: defaults,
            isPremiumProvider: { false },
            currentTimeMillis: { clock.value }
        )
        let reserved = try await service.reserveNoteImageTickets(count: 0)
        let ticket = try #require(reserved.tickets.first)
        #expect(reserved.tickets.count == 1)
        #expect(reserved.remaining == 1)

        defaults.set("account-B", forKey: "account")
        await expectWebError(code: 40_008, message: "上传凭证无效，请重新上传") {
            _ = try await service.uploadNoteImage(
                ticketID: ticket.ticketId,
                file: .init(fileName: "note.png", contentType: "image/png", data: fixturePNG())
            )
        }

        defaults.set("account-A", forKey: "account")
        let uploaded = try await service.uploadNoteImage(
            ticketID: ticket.ticketId,
            file: .init(fileName: "note.png", contentType: "image/png", data: fixturePNG())
        )
        #expect(upload.prefixes == ["web_note"])
        #expect(uploaded.url == "https://example.com/folder/note%20image.png")

        defaults.set("account-B", forKey: "account")
        do {
            try service.commitUploadedTickets([ticket.ticketId], imageURLs: [uploaded.url])
            Issue.record("跨账号提交票据应失败")
        } catch let error as DesktopWebAPIError {
            #expect(error.code == 40_008)
            #expect(error.message == "上传凭证无效，请重新上传")
        }

        defaults.set("account-A", forKey: "account")
        upload.remainingDeleteFailures = 1
        try await service.releaseNoteImageTickets([ticket.ticketId])
        #expect(upload.deletedPaths == ["folder/note%20image.png"])

        clock.advance(by: 30_000)
        _ = try await service.reserveNoteImageTickets(count: 1)
        #expect(upload.deletedPaths == ["folder/note%20image.png", "folder/note%20image.png"])
    }

    @Test
    func quotaFailuresPersistRateHitsAndCustomConfigHasNoRemainingField() async throws {
        let defaults = isolatedDefaults()
        defaults.set("0", forKey: "noteImageUploadLimit")
        let clock = MillisecondClock(1_700_000_000_000)
        let upload = UploadRepositoryStub()
        let limited = DesktopWebUploadService(
            configRepository: ConfigRepositoryStub(id: 1),
            uploadRepository: upload,
            defaults: defaults,
            currentTimeMillis: { clock.value }
        )
        for _ in 0 ..< 30 {
            await expectWebError(code: 40_007, message: "今日图片上传额度已用完，请升级会员或切换自定义 COS") {
                _ = try await limited.reserveNoteImageTickets(count: 1)
            }
        }
        await expectWebError(code: 40_006, message: "图片上传过于频繁，请稍后再试") {
            _ = try await limited.reserveNoteImageTickets(count: 1)
        }

        let custom = DesktopWebUploadService(
            configRepository: ConfigRepositoryStub(id: 9),
            uploadRepository: upload,
            defaults: isolatedDefaults(),
            currentTimeMillis: { clock.value }
        )
        let result = try await custom.reserveNoteImageTickets(count: 1)
        #expect(result.remaining == nil)
    }

    @Test
    func uploadValidationAndExpiredTicketPreserveAndroidErrors() async throws {
        let defaults = isolatedDefaults()
        defaults.set("8", forKey: "noteImageUploadLimit")
        let clock = MillisecondClock(1_700_000_000_000)
        let upload = UploadRepositoryStub()
        let service = DesktopWebUploadService(
            configRepository: ConfigRepositoryStub(id: 1),
            uploadRepository: upload,
            defaults: defaults,
            currentTimeMillis: { clock.value }
        )
        let expired = try #require(
            try await service.reserveNoteImageTickets(count: 1).tickets.first
        )
        clock.advance(by: 10 * 60 * 1_000)
        await expectWebError(code: 40_008, message: "上传凭证已失效，请重新上传") {
            _ = try await service.uploadNoteImage(
                ticketID: expired.ticketId,
                file: .init(fileName: "note.png", contentType: "image/png", data: fixturePNG())
            )
        }

        let ticket = try #require(
            try await service.reserveNoteImageTickets(count: 1).tickets.first
        )
        await expectWebError(code: 40_001, message: "仅支持 JPEG、PNG、GIF、WebP 格式的图片") {
            _ = try await service.uploadNoteImage(
                ticketID: ticket.ticketId,
                file: .init(fileName: "note.bin", contentType: "image/png", data: Data("not-image".utf8))
            )
        }
        await expectWebError(code: 40_001, message: "仅支持图片文件上传") {
            _ = try await service.uploadNoteImage(
                ticketID: ticket.ticketId,
                file: .init(fileName: "note.png", contentType: "text/plain", data: fixturePNG())
            )
        }
        var oversized = Data([0xff, 0xd8, 0xff])
        oversized.append(Data(repeating: 0, count: 10 * 1_024 * 1_024))
        await expectWebError(code: 40_001, message: "文件大小不能超过 10MB") {
            _ = try await service.uploadNoteImage(
                ticketID: ticket.ticketId,
                file: .init(fileName: "large.jpg", contentType: "image/jpeg", data: oversized)
            )
        }
    }

    @Test
    func successfulTicketCommitConsumesQuotaAndCoverUsesDedicatedPrefix() async throws {
        let defaults = isolatedDefaults()
        defaults.set("2", forKey: "noteImageUploadLimit")
        let clock = MillisecondClock(1_700_000_000_000)
        let upload = UploadRepositoryStub()
        let service = DesktopWebUploadService(
            configRepository: ConfigRepositoryStub(id: 1),
            uploadRepository: upload,
            defaults: defaults,
            currentTimeMillis: { clock.value }
        )
        let ticket = try #require(
            try await service.reserveNoteImageTickets(count: 1).tickets.first
        )
        let uploaded = try await service.uploadNoteImage(
            ticketID: ticket.ticketId,
            file: .init(fileName: "note.png", contentType: "image/png", data: fixturePNG())
        )
        try service.commitUploadedTickets([ticket.ticketId], imageURLs: [uploaded.url])
        await expectWebError(code: 40_008, message: "上传凭证已失效，请重新上传") {
            try service.commitUploadedTickets([ticket.ticketId], imageURLs: [uploaded.url])
        }

        let finalReservation = try await service.reserveNoteImageTickets(count: 1)
        #expect(finalReservation.remaining == 0)
        await expectWebError(code: 40_007, message: "今日图片上传额度已用完，请升级会员或切换自定义 COS") {
            _ = try await service.reserveNoteImageTickets(count: 1)
        }

        let cover = try await service.uploadBookCover(
            file: .init(fileName: "cover.png", contentType: "image/png", data: fixturePNG())
        )
        #expect(cover.url == "https://example.com/fixture.png")
        #expect(upload.prefixes == ["web_note", "web_cover"])
    }

    @Test
    func terminalTicketsArePrunedAfterAndroidThreeDayRetention() async throws {
        let defaults = isolatedDefaults()
        defaults.set("5", forKey: "noteImageUploadLimit")
        let clock = MillisecondClock(1_700_000_000_000)
        let service = DesktopWebUploadService(
            configRepository: ConfigRepositoryStub(id: 1),
            uploadRepository: UploadRepositoryStub(),
            defaults: defaults,
            currentTimeMillis: { clock.value }
        )
        let released = try #require(
            try await service.reserveNoteImageTickets(count: 1).tickets.first
        )
        try await service.releaseNoteImageTickets([released.ticketId])
        clock.advance(by: 3 * 24 * 60 * 60 * 1_000 + 1)
        let current = try #require(
            try await service.reserveNoteImageTickets(count: 1).tickets.first
        )

        let storeData = try #require(
            defaults.data(forKey: "desktopWeb.noteImageUploadRiskControl")
        )
        let store = try #require(
            JSONSerialization.jsonObject(with: storeData) as? [String: Any]
        )
        let tickets = try #require(store["tickets"] as? [String: Any])
        #expect(tickets[released.ticketId] == nil)
        #expect(tickets[current.ticketId] != nil)
        #expect(tickets.count == 1)
    }
}

private final class URLProtocolFixture: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func install(
        forHost host: String,
        queryValue: String? = nil,
        _ value: @escaping Handler
    ) {
        lock.withLock { handlers[key(host: host, queryValue: queryValue)] = value }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try Self.lock.withLock {
                let host = request.url?.host ?? ""
                let queryValue = request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first(where: { $0.name == "query" })?
                        .value
                }
                return try #require(
                    Self.handlers[Self.key(host: host, queryValue: queryValue)]
                        ?? Self.handlers[Self.key(host: host, queryValue: nil)]
                )
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

    private static func key(host: String, queryValue: String?) -> String {
        "\(host)|\(queryValue ?? "*")"
    }
}

private enum ExternalServiceFixtureError: Error {
    case invalidURL
}

private final class ConfigRepositoryStub: S3ConfigRepositoryProtocol, @unchecked Sendable {
    private let config: S3Config

    init(id: Int64) {
        config = S3Config(
            id: id,
            bucket: "bucket",
            secretId: "id",
            secretKey: "key",
            region: "region",
            isUsing: true,
            isBundledDefault: id == 1
        )
    }

    func fetchConfigs() async throws -> [S3Config] { [config] }
    func fetchCurrentConfig() async throws -> S3Config? { config }
    func saveConfig(_ input: S3ConfigFormInput, editingConfig: S3Config?) async throws -> S3Config {
        _ = (input, editingConfig)
        return config
    }
    func delete(_: S3Config) async throws {}
    func select(_: S3Config) async throws {}
    func testConnection(_: S3ConfigFormInput) async throws {}
}

private final class UploadRepositoryStub: S3UploadRepositoryProtocol, @unchecked Sendable {
    var prefixes: [String] = []
    var deletedPaths: [String] = []
    var remainingDeleteFailures = 0
    let result: S3UploadResult

    init(result: S3UploadResult = .init(
        objectKey: "fixture.png",
        remoteURL: URL(string: "https://example.com/fixture.png")!
    )) {
        self.result = result
    }

    func stageImageData(_ data: Data, preferredFileExtension: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(preferredFileExtension)
        try data.write(to: url)
        return url
    }

    func discardStagedFile(at localURL: URL) async {
        try? FileManager.default.removeItem(at: localURL)
    }

    func isStagedFileAvailable(at localURL: URL) async -> Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    func uploadFile(
        localURL _: URL,
        prefix: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> S3UploadResult {
        prefixes.append(prefix)
        progress?(1)
        return result
    }

    func uploadFile(
        localURL _: URL,
        objectKey: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> S3UploadResult {
        prefixes.append(objectKey)
        progress?(1)
        return result
    }

    func testCurrentConfiguration() async throws {}

    func deleteObject(path: String) async throws {
        deletedPaths.append(path)
        if remainingDeleteFailures > 0 {
            remainingDeleteFailures -= 1
            throw S3StorageError.serviceError(code: nil, message: "fixture delete failure")
        }
    }

    func cancelCurrentUpload() {}
}

private final class MillisecondClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int64

    init(_ value: Int64) {
        storage = value
    }

    var value: Int64 {
        lock.withLock { storage }
    }

    func advance(by amount: Int64) {
        lock.withLock { storage += amount }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private extension DesktopWebJSONValue {
    var arrayValue: [DesktopWebJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

private extension DesktopWebRawHTTPResponse {
    var bufferedBody: Data? {
        guard case .data(let value) = body else { return nil }
        return value
    }

    var bufferedBodyString: String? {
        bufferedBody.flatMap { String(data: $0, encoding: .utf8) }
    }
}

private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "DesktopWebExternalServiceTests.\(UUID().uuidString)")!
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolFixture.self]
    return URLSession(configuration: configuration)
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

@MainActor
private func fixturePNG() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
    return renderer.pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
}

private func seedExternalBook(
    _ database: AppDatabase,
    id: Int64,
    cover: String
) throws {
    try database.dbPool.write { db in
        var book = BookRecord()
        book.id = id
        book.userId = 1
        book.name = "封面测试"
        book.rawName = "封面测试"
        book.cover = cover
        book.sourceId = 1
        book.readStatusId = 1
        book.createdDate = 1
        book.updatedDate = 1
        try book.insert(db)
    }
}

private func expectWebError(
    code: Int,
    message: String,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("预期 DesktopWebAPIError(\(code), \(message))")
    } catch let error as DesktopWebAPIError {
        #expect(error.code == code)
        #expect(error.message == message)
    } catch {
        Issue.record("错误类型不符: \(error)")
    }
}
