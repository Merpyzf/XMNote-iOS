import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebAPIContractTests {
    @Test
    func successEnvelopeMatchesAndroidHeadersAndFloatingPointLexemes() async throws {
        let gate = RequestGateStub(isAuthorized: true, isReadOnly: false)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/floating-contract") { _, _ in
                try DesktopWebAPIResponse.success(FloatingPointPayload(
                    position: 0,
                    price: 12,
                    ratio: 1,
                    readPosition: 0,
                    totalMoney: 0
                ))
            }
        } test: { client in
            try await client.execute(uri: "/api/v1/floating-contract", method: .get) { response in
                let body = String(buffer: response.body)
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
                #expect(body.contains(#""position":0.0"#))
                #expect(body.contains(#""price":12.0"#))
                #expect(body.contains(#""ratio":1.0"#))
                #expect(body.contains(#""readPosition":0.0"#))
                #expect(body.contains(#""totalMoney":0.0"#))
            }
        }
    }

    @Test
    func writeResponseDoesNotAddCacheControl() async throws {
        let gate = RequestGateStub(isAuthorized: true, isReadOnly: false)
        try await withAPI(gate: gate) { router in
            router.post("/api/v1/write-cache-contract") { _, _ in
                try DesktopWebAPIResponse.success(["accepted": true])
            }
        } test: { client in
            try await client.execute(
                uri: "/api/v1/write-cache-contract",
                method: .post
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == nil)
            }
        }
    }

    @Test
    func unauthorizedRequestReturnsAndroidBusinessError() async throws {
        let gate = RequestGateStub(isAuthorized: false, isReadOnly: false)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/books") { _, _ in
                try DesktopWebAPIResponse.success(["unexpected": true])
            }
        } test: { client in
            try await client.execute(uri: "/api/v1/books", method: .get) { response in
                let envelope = try decodeEnvelope(response)
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
                #expect(response.headers[.cacheControl] == "private")
                #expect(envelope.code == 40005)
                #expect(envelope.message == unauthorizedMessage)
                #expect(envelope.isDataMissingOrNull)
            }
        }
    }

    @Test
    func accessCodeIsTrimmedBeforeAuthorization() async throws {
        let gate = RequestGateStub(isAuthorized: true, isReadOnly: false)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/books") { _, _ in
                try DesktopWebAPIResponse.success(["accepted": true])
            }
        } test: { client in
            try await client.execute(
                uri: "/api/v1/books",
                method: .get,
                headers: [.init("X-XMNote-Access-Code")!: "  abc123  "]
            ) { response in
                let envelope = try decodeEnvelope(response)
                #expect(envelope.code == 200)
                #expect(await gate.lastAccessCode() == "abc123")
            }
        }
    }

    @Test
    func accessStatusAndCoverProxyBypassAuthorization() async throws {
        let gate = RequestGateStub(isAuthorized: false, isReadOnly: false)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/settings/access-auth") { _, _ in
                try DesktopWebAPIResponse.success(["enabled": true])
            }
            router.get("/api/v1/book-covers/proxy/example") { _, _ in
                "image"
            }
        } test: { client in
            try await client.execute(uri: "/api/v1/settings/access-auth", method: .get) { response in
                let envelope = try decodeEnvelope(response)
                #expect(envelope.code == 200)
            }
            try await client.execute(uri: "/api/v1/book-covers/proxy/example", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "image")
            }
        }
    }

    @Test
    func readOnlyMembershipBlocksOnlyCoreWrites() async throws {
        let gate = RequestGateStub(isAuthorized: true, isReadOnly: true)
        try await withAPI(gate: gate) { router in
            router.post("/api/v1/books") { _, _ in
                try DesktopWebAPIResponse.success(["unexpected": true])
            }
            router.get("/api/v1/books") { _, _ in
                try DesktopWebAPIResponse.success(["allowed": true])
            }
            router.put("/api/v1/settings/web") { _, _ in
                try DesktopWebAPIResponse.success(Optional<Bool>.none)
            }
            router.post("/api/v1/bookshelf/items/query") { _, _ in
                try DesktopWebAPIResponse.success(["allowed": true])
            }
            router.post("/api/v1/books/:bookId/chapters/import-preview") { _, _ in
                try DesktopWebAPIResponse.success(["unexpected": true])
            }
        } test: { client in
            try await client.execute(uri: "/api/v1/books", method: .post) { response in
                let envelope = try decodeEnvelope(response)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
                #expect(envelope.code == 40009)
                #expect(envelope.message == readOnlyMessage)
            }
            try await client.execute(uri: "/api/v1/books", method: .get) { response in
                let envelope = try decodeEnvelope(response)
                #expect(envelope.code == 200)
            }
            try await client.execute(uri: "/api/v1/settings/web", method: .put) { response in
                let envelope = try decodeEnvelope(response)
                #expect(envelope.code == 200)
            }
            try await client.execute(uri: "/api/v1/bookshelf/items/query", method: .post) { response in
                let envelope = try decodeEnvelope(response)
                #expect(envelope.code == 200)
            }
            try await client.execute(
                uri: "/api/v1/books/7/chapters/import-preview",
                method: .post
            ) { response in
                let envelope = try decodeEnvelope(response)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
                #expect(envelope.code == 40009)
                #expect(envelope.message == readOnlyMessage)
            }
        }
    }

    @Test
    func preflightMatchesObservedAndroidHeadersAndBody() async throws {
        let gate = RequestGateStub(isAuthorized: false, isReadOnly: true)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/settings/web") { _, _ in "unexpected" }
        } test: { client in
            try await client.execute(
                uri: "/api/v1/settings/web",
                method: .options,
                headers: [
                    .origin: "http://example.test",
                    .accessControlRequestMethod: "GET",
                    .accessControlRequestHeaders: "X-XMNote-Access-Code, Content-Type"
                ]
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "OK")
                #expect(response.headers[.accessControlAllowOrigin] == "http://example.test")
                #expect(response.headers[.accessControlAllowMethods] == "GET")
                #expect(
                    response.headers[.accessControlAllowHeaders]
                        == "X-XMNote-Access-Code, Content-Type"
                )
                #expect(response.headers[.accessControlAllowCredentials] == "true")
                #expect(response.headers[.accessControlMaxAge] == "1800")
                #expect(response.headers[.allow] == "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, TRACE")
                #expect(response.headers[.vary] == "Origin")
                #expect(response.headers[.cacheControl] == nil)
            }
        }
    }

    @Test
    func preflightWithoutRequestedMethodUsesAndroidDefaultsOnlyForRegisteredPath() async throws {
        let gate = RequestGateStub(isAuthorized: false, isReadOnly: true)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/settings/web") { _, _ in "unexpected" }
        } test: { client in
            try await client.execute(
                uri: "/api/v1/settings/web",
                method: .options,
                headers: [.origin: "http://example.test"]
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "OK")
                #expect(
                    response.headers[.accessControlAllowMethods]
                        == "GET, POST, PUT, DELETE, PATCH, OPTIONS"
                )
            }

            try await client.execute(
                uri: "/api/v1/not-implemented",
                method: .options,
                headers: [.origin: "http://example.test"]
            ) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.accessControlAllowOrigin] == nil)
            }
        }
    }

    @Test
    func corsHeadersAreAppliedToBusinessErrors() async throws {
        let gate = RequestGateStub(isAuthorized: false, isReadOnly: false)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/books") { _, _ in "unexpected" }
        } test: { client in
            try await client.execute(
                uri: "/api/v1/books",
                method: .get,
                headers: [.origin: "http://example.test"]
            ) { response in
                let envelope = try decodeEnvelope(response)
                #expect(envelope.code == 40005)
                #expect(response.headers[.accessControlAllowOrigin] == "http://example.test")
                #expect(response.headers[.accessControlAllowCredentials] == "true")
                #expect(response.headers[.vary] == "Origin")
            }
        }
    }

    @Test
    func classifiedAndHTTPErrorUseAndroidEnvelope() async throws {
        let gate = RequestGateStub(isAuthorized: true, isReadOnly: false)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/duplicate") { _, _ -> Response in
                throw DesktopWebAPIError(code: 40003, message: "资源已存在")
            }
            router.get("/api/v1/missing") { _, _ -> Response in
                throw HTTPError(.notFound, message: "资源不存在")
            }
            router.get("/api/v1/numeric/:id") { _, context in
                let value = try context.parameters.require("id", as: Int64.self)
                return try DesktopWebAPIResponse.success(value)
            }
        } test: { client in
            try await client.execute(uri: "/api/v1/duplicate", method: .get) { response in
                let envelope = try decodeEnvelope(response)
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
                #expect(envelope.code == 40003)
                #expect(envelope.message == "资源已存在")
            }
            try await client.execute(uri: "/api/v1/missing", method: .get) { response in
                let envelope = try decodeEnvelope(response)
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
                #expect(envelope.code == 40002)
                #expect(envelope.message == "资源不存在")
            }
            try await client.execute(
                uri: "/api/v1/numeric/not-a-number",
                method: .get
            ) { response in
                let envelope = try decodeEnvelope(response)
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == DesktopWebAPIResponse.jsonContentType)
                #expect(envelope.code == 40001)
                #expect(envelope.message == #"For input string: "not-a-number""#)
            }
        }
    }

    @Test
    func routerWithoutAPIDependenciesKeepsUnknownAPIAsReal404() async throws {
        let router = Router()
        let app = Application(responder: router.buildResponder())

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/v1/not-implemented", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func routerWithPartialAPIDependenciesKeepsUnimplementedAPIAsReal404() async throws {
        let gate = RequestGateStub(isAuthorized: false, isReadOnly: true)
        try await withAPI(gate: gate) { router in
            router.get("/api/v1/settings/web") { _, _ in "implemented" }
        } test: { client in
            try await client.execute(uri: "/api/v1/not-implemented", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(await gate.authorizationCheckCount() == 0)
            }
        }
    }

    private func withAPI(
        gate: RequestGateStub,
        configure: (Router<BasicRequestContext>) -> Void,
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        router.middlewares.add(DesktopWebCachePolicyMiddleware())
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: DesktopWebAPIDependencies(requestGate: gate),
            routeMatcher: DesktopWebAPIRouteMatcher(routes: Self.testRouteDefinitions)
        )
        configure(router)
        let app = Application(responder: router.buildResponder())
        try await app.test(.router, test)
    }

    private func decodeEnvelope(_ response: TestResponse) throws -> ErrorEnvelope {
        try JSONDecoder().decode(ErrorEnvelope.self, from: Data(response.body.readableBytesView))
    }

    private var unauthorizedMessage: String {
        "访问未授权，请在电脑端输入正确的访问授权码，或在手机「网页端-访问安全」中关闭访问授权码后重试。"
    }

    private var readOnlyMessage: String {
        "网页端当前仅支持浏览。开通高级版后，可在电脑上创建、编辑、整理书籍与笔记。"
    }

    private static let testRouteDefinitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/floating-contract"),
        .init(.get, "/api/v1/books"),
        .init(.post, "/api/v1/books"),
        .init(.get, "/api/v1/settings/access-auth"),
        .init(.get, "/api/v1/book-covers/proxy/{bookId}"),
        .init(.put, "/api/v1/settings/web"),
        .init(.post, "/api/v1/bookshelf/items/query"),
        .init(.post, "/api/v1/books/{bookId}/chapters/import-preview"),
        .init(.get, "/api/v1/duplicate"),
        .init(.get, "/api/v1/missing"),
        .init(.get, "/api/v1/numeric/{id}"),
        .init(.get, "/api/v1/settings/web")
    ]
}

private struct FloatingPointPayload: Encodable {
    let position: Double
    let price: Double
    let ratio: Double
    let readPosition: Double
    let totalMoney: Float
}

private struct ErrorEnvelope: Decodable {
    let code: Int
    let message: String
    let isDataMissingOrNull: Bool

    private enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        if container.contains(.data) {
            isDataMissingOrNull = try container.decodeNil(forKey: .data)
        } else {
            isDataMissingOrNull = true
        }
    }
}

private actor RequestGateStub: DesktopWebRequestGatePort {
    private let isAuthorized: Bool
    private let isReadOnly: Bool
    private var receivedAccessCode: String?
    private var authorizationChecks = 0

    init(isAuthorized: Bool, isReadOnly: Bool) {
        self.isAuthorized = isAuthorized
        self.isReadOnly = isReadOnly
    }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool {
        authorizationChecks += 1
        receivedAccessCode = accessCode
        return isAuthorized
    }

    func isDesktopReadOnly() async -> Bool {
        isReadOnly
    }

    func lastAccessCode() -> String? {
        receivedAccessCode
    }

    func authorizationCheckCount() -> Int {
        authorizationChecks
    }
}
