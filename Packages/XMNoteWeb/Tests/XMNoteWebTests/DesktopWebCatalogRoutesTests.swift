import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebCatalogRoutesTests {
    @Test
    func sourceListPassesAndroidBooleanQueryAndReturnsEnvelope() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/sources", method: .get) { response in
                let data = try envelopeArray(response)
                #expect(data.count == 1)
                #expect(data.first?["name"] as? String == "未知来源")
            }
            try await client.execute(uri: "/api/v1/sources?showAll=TRUE", method: .get) { _ in }
        }
        #expect(await port.receivedShowAllValues() == [false, true])
    }

    @Test
    func sourceDetailDecodesPathParameter() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/sources/29", method: .get) { response in
                let data = try envelopeObject(response)
                #expect(data["id"] as? Int == 29)
                #expect(data["isDefault"] as? Bool == false)
            }
        }
        #expect(await port.lastSourceID() == 29)
    }

    @Test
    func createSourceDecodesRequiredName() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/sources",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"name":" Kindle "}"#)
            ) { response in
                let data = try envelopeObject(response)
                #expect(data["id"] as? Int == 29)
            }
        }
        #expect(await port.lastSourceCreate() == DesktopWebSourceCreateRequest(name: " Kindle "))
    }

    @Test
    func updateSourcePreservesOptionalFields() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/sources/29",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"isHidden":true}"#)
            ) { response in
                let data = try envelopeObject(response)
                #expect(data["isHidden"] as? Bool == true)
            }
        }
        #expect(
            await port.lastSourceUpdate()
                == SourceUpdateCall(
                    id: 29,
                    request: DesktopWebSourceUpdateRequest(name: nil, isHidden: true)
                )
        )
    }

    @Test
    func deleteSourceOmitsNilData() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/sources/29", method: .delete) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
                #expect(envelope["data"] == nil)
            }
        }
        #expect(await port.lastDeletedSourceID() == 29)
    }

    @Test
    func reorderSourcesPassesDuplicatesWithoutNormalization() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/sources/order",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"ids":[29,999,29]}"#)
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        #expect(await port.lastSourceOrder() == [29, 999, 29])
    }

    @Test
    func sourceBusinessErrorUsesAndroidCodeAndMessage() async throws {
        let port = CatalogPortStub(sourceError: DesktopWebAPIError(code: 40002, message: "来源不存在: 88"))
        try await withCatalogAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/sources/88", method: .get) { response in
                let envelope = try decodeJSONObject(response)
                #expect(response.status == .ok)
                #expect(envelope["code"] as? Int == 40002)
                #expect(envelope["msg"] as? String == "来源不存在: 88")
            }
        }
    }

    @Test
    func tagListUsesDefaultAndExplicitType() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/tags", method: .get) { response in
                let data = try envelopeArray(response)
                #expect(data.first?["noteCount"] as? Int == 2)
                #expect(data.first?["bookCount"] as? Int == 3)
            }
            try await client.execute(uri: "/api/v1/tags?type=2", method: .get) { _ in }
        }
        #expect(await port.receivedTagTypes() == [0, 2])
    }

    @Test
    func tagTypeQueryMatchesAndroidInt32AndFormDecodingBoundaries() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/tags?type=bad", method: .get) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == #"For input string: "bad""#)
            }
            try await client.execute(
                uri: "/api/v1/tags?type=2147483648",
                method: .get
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == #"For input string: "2147483648""#)
            }
            try await client.execute(uri: "/api/v1/tags?type=+1", method: .get) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == #"For input string: " 1""#)
            }
            try await client.execute(
                uri: "/api/v1/tags?type=1&type=2",
                method: .get
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == #"For input string: "1type=2""#)
            }
            try await client.execute(uri: "/api/v1/tags?type=", method: .get) { _ in }
            try await client.execute(uri: "/api/v1/tags?type=%2B1", method: .get) { _ in }
            try await client.execute(uri: "/api/v1/tags?type&type=2", method: .get) { _ in }
        }
        #expect(await port.receivedTagTypes() == [0, 1, 2])
    }

    @Test
    func createTagDecodesNameAndType() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/tags",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"name":" Swift ","type":2}"#)
            ) { response in
                let data = try envelopeObject(response)
                #expect(data["id"] as? Int == 41)
                #expect(data["type"] as? Int == 2)
            }
        }
        #expect(await port.lastTagCreate() == DesktopWebTagCreateRequest(name: " Swift ", type: 2))
    }

    @Test
    func updateTagDecodesPathAndRequiredName() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/tags/41",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"name":"iOS"}"#)
            ) { response in
                let data = try envelopeObject(response)
                #expect(data["name"] as? String == "iOS")
            }
        }
        #expect(
            await port.lastTagUpdate()
                == TagUpdateCall(id: 41, request: DesktopWebTagUpdateRequest(name: "iOS"))
        )
    }

    @Test
    func deleteTagAndReorderTagsPreserveAndroidPayloads() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/tags/41", method: .delete) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["data"] == nil)
            }
            try await client.execute(
                uri: "/api/v1/tags/order",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"ids":[41,1000,41]}"#)
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        #expect(await port.lastDeletedTagID() == 41)
        #expect(await port.lastTagOrder() == [41, 1000, 41])
    }

    @Test
    func malformedCatalogBodyReturnsBadRequestBeforePortCall() async throws {
        let port = CatalogPortStub()
        try await withCatalogAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/tags",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody("{")
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40001)
            }
        }
        #expect(await port.lastTagCreate() == nil)
    }

    @Test
    func readOnlyGateBlocksCatalogWritesButAllowsReads() async throws {
        let port = CatalogPortStub()
        let gate = CatalogGateStub(isReadOnly: true)
        try await withCatalogAPI(port: port, gate: gate) { client in
            try await client.execute(uri: "/api/v1/sources", method: .get) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/tags",
                method: .post,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"name":"blocked","type":1}"#)
            ) { response in
                let envelope = try decodeJSONObject(response)
                #expect(envelope["code"] as? Int == 40009)
            }
        }
        #expect(await port.lastTagCreate() == nil)
    }

    private func withCatalogAPI(
        port: CatalogPortStub,
        gate: CatalogGateStub = CatalogGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(
            requestGate: gate,
            source: port,
            tag: port
        )
        let definitions = DesktopWebSourceRoutes.definitions.union(DesktopWebTagRoutes.definitions)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: definitions)
        )
        DesktopWebSourceRoutes(port: port).register(on: router)
        DesktopWebTagRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private struct SourceUpdateCall: Equatable, Sendable {
    let id: Int64
    let request: DesktopWebSourceUpdateRequest
}

private struct TagUpdateCall: Equatable, Sendable {
    let id: Int64
    let request: DesktopWebTagUpdateRequest
}

private actor CatalogGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) {
        self.isReadOnly = isReadOnly
    }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }

    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor CatalogPortStub: DesktopWebSourcePort, DesktopWebTagPort {
    private let sourceError: DesktopWebAPIError?
    private var showAllValues: [Bool] = []
    private var sourceID: Int64?
    private var sourceCreate: DesktopWebSourceCreateRequest?
    private var sourceUpdate: SourceUpdateCall?
    private var deletedSourceID: Int64?
    private var sourceOrder: [Int64]?
    private var tagTypes: [Int] = []
    private var tagCreate: DesktopWebTagCreateRequest?
    private var tagUpdate: TagUpdateCall?
    private var deletedTagID: Int64?
    private var tagOrder: [Int64]?

    init(sourceError: DesktopWebAPIError? = nil) {
        self.sourceError = sourceError
    }

    func sources(showAll: Bool) async throws -> [DesktopWebSource] {
        showAllValues.append(showAll)
        return [sourceFixture(id: 1, isHidden: false)]
    }

    func source(id: Int64) async throws -> DesktopWebSource {
        sourceID = id
        if let sourceError { throw sourceError }
        return sourceFixture(id: id, isHidden: false)
    }

    func createSource(_ request: DesktopWebSourceCreateRequest) async throws -> DesktopWebSource {
        sourceCreate = request
        return sourceFixture(id: 29, isHidden: false)
    }

    func updateSource(
        id: Int64,
        request: DesktopWebSourceUpdateRequest
    ) async throws -> DesktopWebSource {
        sourceUpdate = SourceUpdateCall(id: id, request: request)
        return sourceFixture(id: id, isHidden: request.isHidden ?? false)
    }

    func deleteSource(id: Int64) async throws {
        deletedSourceID = id
    }

    func reorderSources(_ request: DesktopWebOrderRequest) async throws {
        sourceOrder = request.ids
    }

    func tags(type: Int) async throws -> [DesktopWebTag] {
        tagTypes.append(type)
        return [
            DesktopWebTag(
                id: 41,
                name: "fixture",
                type: type == 0 ? 1 : type,
                order: 4,
                noteCount: 2,
                bookCount: 3,
                createdTime: 10
            )
        ]
    }

    func createTag(_ request: DesktopWebTagCreateRequest) async throws -> DesktopWebTagResult {
        tagCreate = request
        return DesktopWebTagResult(id: 41, name: request.name, type: request.type, order: 4)
    }

    func updateTag(
        id: Int64,
        request: DesktopWebTagUpdateRequest
    ) async throws -> DesktopWebTagResult {
        tagUpdate = TagUpdateCall(id: id, request: request)
        return DesktopWebTagResult(id: id, name: request.name, type: 2, order: 4)
    }

    func deleteTag(id: Int64) async throws {
        deletedTagID = id
    }

    func reorderTags(_ request: DesktopWebOrderRequest) async throws {
        tagOrder = request.ids
    }

    func receivedShowAllValues() -> [Bool] { showAllValues }
    func lastSourceID() -> Int64? { sourceID }
    func lastSourceCreate() -> DesktopWebSourceCreateRequest? { sourceCreate }
    func lastSourceUpdate() -> SourceUpdateCall? { sourceUpdate }
    func lastDeletedSourceID() -> Int64? { deletedSourceID }
    func lastSourceOrder() -> [Int64]? { sourceOrder }
    func receivedTagTypes() -> [Int] { tagTypes }
    func lastTagCreate() -> DesktopWebTagCreateRequest? { tagCreate }
    func lastTagUpdate() -> TagUpdateCall? { tagUpdate }
    func lastDeletedTagID() -> Int64? { deletedTagID }
    func lastTagOrder() -> [Int64]? { tagOrder }

    private func sourceFixture(id: Int64, isHidden: Bool) -> DesktopWebSource {
        DesktopWebSource(
            id: id,
            name: id == 1 ? "未知来源" : "fixture",
            order: 3,
            isHidden: isHidden,
            isDefault: id <= 27,
            bookCount: 2,
            createdTime: 10,
            updatedTime: 20
        )
    }
}

private func decodeJSONObject(_ response: TestResponse) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView))
    return try #require(value as? [String: Any])
}

private func envelopeObject(_ response: TestResponse) throws -> [String: Any] {
    let envelope = try decodeJSONObject(response)
    #expect(envelope["code"] as? Int == 200)
    return try #require(envelope["data"] as? [String: Any])
}

private func envelopeArray(_ response: TestResponse) throws -> [[String: Any]] {
    let envelope = try decodeJSONObject(response)
    #expect(envelope["code"] as? Int == 200)
    return try #require(envelope["data"] as? [[String: Any]])
}

private func jsonBody(_ string: String) -> ByteBuffer {
    ByteBuffer(bytes: string.utf8)
}
