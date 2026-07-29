import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebSettingsRoutesTests {
    @Test
    func getWebSettingsReturnsAndroidEnvelope() async throws {
        let port = SettingsPortStub()
        try await withSettingsAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/settings/web", method: .get) { response in
                let json = try decodeJSONObject(response)
                #expect(response.status == .ok)
                #expect(json["code"] as? Int == 200)
                #expect(json["msg"] as? String == "success")
                let data = try #require(json["data"] as? [String: Any])
                #expect(data["theme"] as? String == "system")
            }
        }
    }

    @Test
    func getAccessAuthBypassesAuthorizationAndReturnsHeaderName() async throws {
        let port = SettingsPortStub()
        let gate = SettingsRequestGateStub(isAuthorized: false, isReadOnly: false)
        try await withSettingsAPI(port: port, gate: gate) { client in
            try await client.execute(uri: "/api/v1/settings/access-auth", method: .get) { response in
                let data = try envelopeData(response)
                #expect(data["enabled"] as? Bool == true)
                #expect(data["headerName"] as? String == "X-XMNote-Access-Code")
                #expect(await gate.authorizationCheckCount() == 0)
            }
        }
    }

    @Test
    func getExportSettingsPreservesCredentialFields() async throws {
        let port = SettingsPortStub()
        try await withSettingsAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/settings/export", method: .get) { response in
                let data = try envelopeData(response)
                #expect(data["lastTarget"] as? String == "markdown")
                #expect(data["yuqueToken"] as? String == "fixture-secret")
            }
        }
    }

    @Test
    func getMembershipReturnsInjectedCapability() async throws {
        let port = SettingsPortStub()
        try await withSettingsAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/settings/membership", method: .get) { response in
                let data = try envelopeData(response)
                #expect(data["isPremium"] as? Bool == false)
                #expect(data["desktopReadOnly"] as? Bool == true)
                #expect(data["canWriteCoreData"] as? Bool == false)
                #expect(data["upgradeActionAvailable"] as? Bool == true)
            }
        }
    }

    @Test
    func updateWebSettingsPassesPartialJSONObjectAndOmitsNilData() async throws {
        let port = SettingsPortStub()
        try await withSettingsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/settings/web",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"display":{"noteMaxLines":9}}"#)
            ) { response in
                let json = try decodeJSONObject(response)
                #expect(json["code"] as? Int == 200)
                #expect(json["data"] == nil)
                let patch = await port.lastWebPatch()
                #expect(
                    patch == .object([
                        "display": .object(["noteMaxLines": .integer(9)])
                    ])
                )
            }
        }
    }

    @Test
    func updateWebSettingsReturnsAndroidClassifiedFailure() async throws {
        let port = SettingsPortStub(shouldFailWebUpdate: true)
        try await withSettingsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/settings/web",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"display":{"noteMaxLines":9}}"#)
            ) { response in
                let json = try decodeJSONObject(response)
                #expect(response.status == .ok)
                #expect(json["code"] as? Int == 400)
                #expect(json["msg"] as? String == "设置更新失败: fixture failure")
                #expect(json["data"] == nil)
            }
        }
    }

    @Test
    func updateExportSettingsReturnsAndroidClassifiedFailure() async throws {
        let port = SettingsPortStub(shouldFailExportUpdate: true)
        try await withSettingsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/settings/export",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"lastTarget":"pdf"}"#)
            ) { response in
                let json = try decodeJSONObject(response)
                #expect(response.status == .ok)
                #expect(json["code"] as? Int == 400)
                #expect(json["msg"] as? String == "导出设置更新失败: fixture failure")
                #expect(json["data"] == nil)
            }
        }
    }

    @Test
    func updateExportSettingsPassesPartialJSONObjectAndOmitsNilData() async throws {
        let port = SettingsPortStub()
        try await withSettingsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/settings/export",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody(#"{"lastTarget":"pdf","includePage":false}"#)
            ) { response in
                let json = try decodeJSONObject(response)
                #expect(json["code"] as? Int == 200)
                #expect(json["data"] == nil)
                let patch = await port.lastExportPatch()
                #expect(
                    patch == .object([
                        "lastTarget": .string("pdf"),
                        "includePage": .boolean(false)
                    ])
                )
            }
        }
    }

    @Test
    func openPremiumUpgradeReturnsNativeActionResult() async throws {
        let port = SettingsPortStub()
        try await withSettingsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/native/actions/open-vip-upgrade",
                method: .post
            ) { response in
                let data = try envelopeData(response)
                #expect(data["accepted"] as? Bool == true)
                #expect(data["message"] == nil)
                #expect(await port.openPremiumCallCount() == 1)
            }
        }
    }

    @Test
    func openPremiumUpgradePreservesAndroidRejectedResult() async throws {
        let port = SettingsPortStub(
            nativeActionResult: DesktopWebNativeActionResult(
                accepted: false,
                message: "当前已开通高级版"
            )
        )
        try await withSettingsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/native/actions/open-vip-upgrade",
                method: .post
            ) { response in
                let data = try envelopeData(response)
                #expect(data["accepted"] as? Bool == false)
                #expect(data["message"] as? String == "当前已开通高级版")
            }
        }
    }

    @Test
    func malformedUpdateBodyReturnsAndroidBadRequestEnvelope() async throws {
        let port = SettingsPortStub()
        try await withSettingsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/settings/web",
                method: .put,
                headers: [.contentType: "application/json"],
                body: jsonBody("{")
            ) { response in
                let json = try decodeJSONObject(response)
                #expect(response.status == .ok)
                #expect(json["code"] as? Int == 40001)
                #expect(json["data"] == nil)
                #expect(await port.lastWebPatch() == nil)
            }
        }
    }

    private func withSettingsAPI(
        port: SettingsPortStub,
        gate: SettingsRequestGateStub = SettingsRequestGateStub(
            isAuthorized: true,
            isReadOnly: false
        ),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        router.middlewares.add(DesktopWebCachePolicyMiddleware())
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, settings: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebSettingsRoutes.definitions)
        )
        DesktopWebSettingsRoutes(port: port).register(on: router)
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

    private func jsonBody(_ string: String) -> ByteBuffer {
        ByteBuffer(bytes: string.utf8)
    }
}

private struct SettingsFixtureError: LocalizedError {
    var errorDescription: String? { "fixture failure" }
}

private actor SettingsRequestGateStub: DesktopWebRequestGatePort {
    private let isAuthorized: Bool
    private let isReadOnly: Bool
    private var authorizationChecks = 0

    init(isAuthorized: Bool, isReadOnly: Bool) {
        self.isAuthorized = isAuthorized
        self.isReadOnly = isReadOnly
    }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool {
        authorizationChecks += 1
        return isAuthorized
    }

    func isDesktopReadOnly() async -> Bool {
        isReadOnly
    }

    func authorizationCheckCount() -> Int {
        authorizationChecks
    }
}

private actor SettingsPortStub: DesktopWebSettingsPort {
    private let shouldFailWebUpdate: Bool
    private let shouldFailExportUpdate: Bool
    private let nativeActionResult: DesktopWebNativeActionResult
    private var webPatch: DesktopWebJSONValue?
    private var exportPatch: DesktopWebJSONValue?
    private var premiumCalls = 0

    init(
        shouldFailWebUpdate: Bool = false,
        shouldFailExportUpdate: Bool = false,
        nativeActionResult: DesktopWebNativeActionResult = DesktopWebNativeActionResult(accepted: true)
    ) {
        self.shouldFailWebUpdate = shouldFailWebUpdate
        self.shouldFailExportUpdate = shouldFailExportUpdate
        self.nativeActionResult = nativeActionResult
    }

    func webSettings() async throws -> DesktopWebJSONValue {
        .object(["theme": .string("system")])
    }

    func updateWebSettings(_ patch: DesktopWebJSONValue) async throws {
        webPatch = patch
        if shouldFailWebUpdate {
            throw SettingsFixtureError()
        }
    }

    func accessAuthSettings() async -> DesktopWebAccessAuthSettings {
        DesktopWebAccessAuthSettings(enabled: true, headerName: "X-XMNote-Access-Code")
    }

    func exportSettings() async throws -> DesktopWebJSONValue {
        .object([
            "lastTarget": .string("markdown"),
            "yuqueToken": .string("fixture-secret")
        ])
    }

    func updateExportSettings(_ patch: DesktopWebJSONValue) async throws {
        exportPatch = patch
        if shouldFailExportUpdate {
            throw SettingsFixtureError()
        }
    }

    func membershipCapability() async -> DesktopWebMembershipCapability {
        DesktopWebMembershipCapability(
            isPremium: false,
            desktopReadOnly: true,
            canWriteCoreData: false,
            upgradeActionAvailable: true
        )
    }

    func openPremiumUpgrade() async -> DesktopWebNativeActionResult {
        premiumCalls += 1
        return nativeActionResult
    }

    func lastWebPatch() -> DesktopWebJSONValue? {
        webPatch
    }

    func lastExportPatch() -> DesktopWebJSONValue? {
        exportPatch
    }

    func openPremiumCallCount() -> Int {
        premiumCalls
    }
}
