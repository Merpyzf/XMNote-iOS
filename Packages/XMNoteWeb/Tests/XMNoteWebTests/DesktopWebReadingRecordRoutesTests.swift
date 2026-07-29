/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebReadingRecordRoutes 与可观测 ReadingRecordPort stub
 * [OUTPUT]: 验证 6 条阅读计时/记录 API 的默认值、路径、响应、错误包络与会员写门禁
 * [POS]: XMNoteWeb Package 阅读记录路由单元测试，锁定 Android 两个 Controller 的全量 HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebReadingRecordRoutesTests {
    @Test
    func timerSessionAppliesKotlinDefaultsAndReturnsCreatedID() async throws {
        let port = ReadingRecordPortStub()
        try await withReadingRecordAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/reading-timer/sessions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: readingRecordBody(
                    #"{"bookId":7,"startTime":1000,"endTime":2000,"elapsedSeconds":1}"#
                )
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
                #expect((envelope["data"] as? [String: Any])?["id"] as? Int == 91)
            }
        }
        #expect(
            await port.session
                == DesktopWebReadingSessionCreateRequest(
                    bookId: 7,
                    startTime: 1_000,
                    endTime: 2_000,
                    elapsedSeconds: 1
                )
        )
    }

    @Test
    func listAndDetailPreserveAndroidSortFallbackAndFullDTO() async throws {
        let port = ReadingRecordPortStub()
        try await withReadingRecordAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/7/reading-records?sortOrder=SIDEWAYS",
                method: .get
            ) { response in
                let data = try #require(readingRecordEnvelope(response)["data"] as? [[String: Any]])
                #expect(data.first?["mode"] as? String == "accurate")
                #expect(data.first?["countdownSeconds"] as? Int == 9)
                #expect(data.first?["recordedPositionUnit"] as? Int == 2)
            }
            try await client.execute(
                uri: "/api/v1/books/8/reading-records/42",
                method: .get
            ) { response in
                let data = try #require(readingRecordEnvelope(response)["data"] as? [String: Any])
                #expect(data["id"] as? Int == 42)
                #expect(data["bookId"] as? Int == 8)
                #expect(data["insight"] as? String == "感想")
                #expect(data["updatedTime"] as? Int == 20)
            }
        }
        #expect(await port.listCall == ReadingRecordListCall(bookID: 7, sortOrder: "desc"))
        #expect(await port.detailCall == ReadingRecordKey(bookID: 8, recordID: 42))
    }

    @Test
    func readPathsAndSortQueryPreserveAndServerBoundarySemantics() async throws {
        let port = ReadingRecordPortStub()
        try await withReadingRecordAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/%2B7/reading-records?sortOrder=asc&sortOrder=desc",
                method: .get
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            #expect(await port.listCall == ReadingRecordListCall(bookID: 7, sortOrder: "desc"))

            try await client.execute(
                uri: "/api/v1/books/7/reading-records?unused=1&sortOrder=asc&sortOrder=desc",
                method: .get
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            #expect(await port.listCall == ReadingRecordListCall(bookID: 7, sortOrder: "asc"))

            try await client.execute(
                uri: "/api/v1/books/7/reading-records/9223372036854775808",
                method: .get
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(
                    envelope["msg"] as? String
                        == #"For input string: "9223372036854775808""#
                )
            }
        }
    }

    @Test
    func recordCreateUpdateAndDeleteForwardRawContracts() async throws {
        let port = ReadingRecordPortStub()
        let body = #"{"mode":" fuzzy ","fuzzyReadDate":123,"elapsedSeconds":60,"position":12.5,"recordedPositionUnit":0,"insight":" note "}"#
        try await withReadingRecordAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/books/7/reading-records",
                method: .post,
                headers: [.contentType: "application/json"],
                body: readingRecordBody(body)
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/7/reading-records/42",
                method: .put,
                headers: [.contentType: "application/json"],
                body: readingRecordBody(body)
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/7/reading-records/42",
                method: .delete
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
                #expect(envelope["data"] == nil)
            }
        }
        let expected = DesktopWebReadingRecordUpsertRequest(
            mode: " fuzzy ",
            fuzzyReadDate: 123,
            elapsedSeconds: 60,
            position: 12.5,
            recordedPositionUnit: 0,
            insight: " note "
        )
        #expect(await port.createCall == ReadingRecordWriteCall(bookID: 7, request: expected))
        #expect(
            await port.updateCall
                == ReadingRecordUpdateCall(bookID: 7, recordID: 42, request: expected)
        )
        #expect(await port.deleteCall == ReadingRecordKey(bookID: 7, recordID: 42))
    }

    @Test
    func malformedBodyPathAndPortErrorUseAndroidEnvelope() async throws {
        let port = ReadingRecordPortStub()
        await port.setDetailError(DesktopWebAPIError(code: 40002, message: "阅读记录不存在"))
        try await withReadingRecordAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/reading-timer/sessions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: readingRecordBody(#"{"bookId":"bad"}"#)
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
            }
            try await client.execute(
                uri: "/api/v1/books/not-a-number/reading-records",
                method: .get
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
            }
            try await client.execute(
                uri: "/api/v1/books/7/reading-records/42",
                method: .get
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 40002)
                #expect(envelope["msg"] as? String == "阅读记录不存在")
            }
        }
        #expect(await port.session == nil)
        #expect(await port.listCall == nil)
    }

    @Test
    func readOnlyGateAllowsReadsAndBlocksAllFourWritesBeforePort() async throws {
        let port = ReadingRecordPortStub()
        try await withReadingRecordAPI(
            port: port,
            gate: ReadingRecordGateStub(isReadOnly: true)
        ) { client in
            try await client.execute(uri: "/api/v1/books/7/reading-records", method: .get) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/7/reading-records/42",
                method: .get
            ) { response in
                let envelope = try readingRecordEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            let writes: [(String, HTTPRequest.Method, String?)] = [
                (
                    "/api/v1/reading-timer/sessions",
                    .post,
                    #"{"bookId":7,"startTime":1,"endTime":2,"elapsedSeconds":1}"#
                ),
                (
                    "/api/v1/books/7/reading-records",
                    .post,
                    #"{"mode":"fuzzy","fuzzyReadDate":1,"elapsedSeconds":1}"#
                ),
                (
                    "/api/v1/books/7/reading-records/42",
                    .put,
                    #"{"mode":"fuzzy","fuzzyReadDate":1,"elapsedSeconds":1}"#
                ),
                ("/api/v1/books/7/reading-records/42", .delete, nil)
            ]
            for (uri, method, body) in writes {
                try await client.execute(
                    uri: uri,
                    method: method,
                    headers: body == nil ? [:] : [.contentType: "application/json"],
                    body: body.map(readingRecordBody)
                ) { response in
                    let envelope = try readingRecordEnvelope(response)
                    #expect(envelope["code"] as? Int == 40009)
                }
            }
        }
        #expect(await port.listCall == ReadingRecordListCall(bookID: 7, sortOrder: "desc"))
        #expect(await port.detailCall == ReadingRecordKey(bookID: 7, recordID: 42))
        #expect(await port.session == nil)
        #expect(await port.createCall == nil)
        #expect(await port.updateCall == nil)
        #expect(await port.deleteCall == nil)
    }

    private func withReadingRecordAPI(
        port: ReadingRecordPortStub,
        gate: ReadingRecordGateStub = ReadingRecordGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, readingRecord: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebReadingRecordRoutes.definitions)
        )
        DesktopWebReadingRecordRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct ReadingRecordListCall: Equatable, Sendable {
    let bookID: Int64
    let sortOrder: String
}

private struct ReadingRecordKey: Equatable, Sendable {
    let bookID: Int64
    let recordID: Int64
}

private struct ReadingRecordWriteCall: Equatable, Sendable {
    let bookID: Int64
    let request: DesktopWebReadingRecordUpsertRequest
}

private struct ReadingRecordUpdateCall: Equatable, Sendable {
    let bookID: Int64
    let recordID: Int64
    let request: DesktopWebReadingRecordUpsertRequest
}

private actor ReadingRecordGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) { self.isReadOnly = isReadOnly }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor ReadingRecordPortStub: DesktopWebReadingRecordPort {
    private(set) var session: DesktopWebReadingSessionCreateRequest?
    private(set) var listCall: ReadingRecordListCall?
    private(set) var detailCall: ReadingRecordKey?
    private(set) var createCall: ReadingRecordWriteCall?
    private(set) var updateCall: ReadingRecordUpdateCall?
    private(set) var deleteCall: ReadingRecordKey?
    private var detailError: Error?

    func setDetailError(_ error: Error) { detailError = error }

    func createReadingSession(_ request: DesktopWebReadingSessionCreateRequest) async throws -> Int64 {
        session = request
        return 91
    }

    func readingRecords(bookID: Int64, sortOrder: String) async throws -> [DesktopWebReadingRecord] {
        listCall = ReadingRecordListCall(bookID: bookID, sortOrder: sortOrder)
        return [sampleRecord(id: 41, bookID: bookID)]
    }

    func readingRecord(bookID: Int64, recordID: Int64) async throws -> DesktopWebReadingRecord {
        detailCall = ReadingRecordKey(bookID: bookID, recordID: recordID)
        if let detailError { throw detailError }
        return sampleRecord(id: recordID, bookID: bookID)
    }

    func createReadingRecord(
        bookID: Int64,
        request: DesktopWebReadingRecordUpsertRequest
    ) async throws -> DesktopWebReadingRecord {
        createCall = ReadingRecordWriteCall(bookID: bookID, request: request)
        return sampleRecord(id: 42, bookID: bookID)
    }

    func updateReadingRecord(
        bookID: Int64,
        recordID: Int64,
        request: DesktopWebReadingRecordUpsertRequest
    ) async throws -> DesktopWebReadingRecord {
        updateCall = ReadingRecordUpdateCall(bookID: bookID, recordID: recordID, request: request)
        return sampleRecord(id: recordID, bookID: bookID)
    }

    func deleteReadingRecord(bookID: Int64, recordID: Int64) async throws {
        deleteCall = ReadingRecordKey(bookID: bookID, recordID: recordID)
    }

    private func sampleRecord(id: Int64, bookID: Int64) -> DesktopWebReadingRecord {
        DesktopWebReadingRecord(
            id: id,
            bookId: bookID,
            mode: "accurate",
            startTime: 1,
            endTime: 2,
            fuzzyReadDate: 0,
            elapsedSeconds: 1,
            countdownSeconds: 9,
            pausedDurationMillis: 10,
            position: 12.5,
            recordedPositionUnit: 2,
            insight: "感想",
            createdTime: 10,
            updatedTime: 20
        )
    }
}

private func readingRecordBody(_ value: String) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
    buffer.writeString(value)
    return buffer
}

private func readingRecordEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
}
