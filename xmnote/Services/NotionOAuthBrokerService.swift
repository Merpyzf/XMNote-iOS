/**
 * [INPUT]: 依赖 AuthenticationServices、CryptoKit、Bundle 中默认空的 Broker 配置及 ExportCredentialStore
 * [OUTPUT]: 对外提供 NotionOAuthBrokerService，通过一次性交付密钥完成 OAuth 并把 token 原子写入 Keychain owner
 * [POS]: Services 层 Notion OAuth Broker 边界；客户端不持有 integration secret，ViewModel 不接触 token
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum NotionOAuthBrokerError: LocalizedError {
    case missingConfiguration
    case invalidResponse
    case authorizationCancelled
    case exchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "Notion OAuth Broker 尚未配置"
        case .invalidResponse: "Notion OAuth Broker 返回了无效响应"
        case .authorizationCancelled: "Notion 授权已取消"
        case let .exchangeFailed(message): message
        }
    }
}

/// Broker 授权只在用户点击连接时运行；随机 delivery secret 从不写入磁盘或日志。
@MainActor
final class NotionOAuthBrokerService: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated static let connectionKeyDefaultsKey = "export.notion.connection_key"
    nonisolated static let dataInstanceIDDefaultsKey = "export.notion.data_instance_id"

    private let bundle: Bundle
    private let session: URLSession
    private let credentialStore: ExportCredentialStore
    private let defaults: UserDefaults
    private var authenticationSession: ASWebAuthenticationSession?

    init(
        bundle: Bundle = .main,
        session: URLSession = .shared,
        credentialStore: ExportCredentialStore,
        defaults: UserDefaults = .standard
    ) {
        self.bundle = bundle
        self.session = session
        self.credentialStore = credentialStore
        self.defaults = defaults
    }

    /// 完成 start → 系统授权 → redeem → Keychain 回读校验 → acknowledge；任一步失败都不清理旧有效连接。
    func connect() async throws {
        let baseURL = configuredString("NotionOAuthBrokerBaseURL")
        let callbackScheme = configuredString("NotionOAuthCallbackScheme")
        guard let base = URL(string: baseURL), !callbackScheme.isEmpty else {
            throw NotionOAuthBrokerError.missingConfiguration
        }
        let secret = try Self.randomSecret()
        let challenge = Self.sha256Hex(secret)
        let start = try await post(
            base: base,
            path: "api/front/v1/notion/oauth/start",
            body: ["deliveryChallenge": challenge]
        )
        guard let exchangeID = start["exchangeId"] as? String,
              let authorizationText = start["authorizationUrl"] as? String,
              let authorizationURL = URL(string: authorizationText) else {
            throw NotionOAuthBrokerError.invalidResponse
        }
        try await authorize(url: authorizationURL, callbackScheme: callbackScheme)

        var tokenBundle: [String: Any]?
        for _ in 0..<30 {
            try Task.checkCancellation()
            let response = try await post(
                base: base,
                path: "api/front/v1/notion/oauth/redeem",
                body: ["exchangeId": exchangeID, "deliverySecret": secret]
            )
            let status = response["exchangeStatus"] as? String ?? ""
            if status == "ready" || status == "delivered" {
                tokenBundle = response
                break
            }
            if ["denied", "failed", "expired"].contains(status) {
                throw NotionOAuthBrokerError.exchangeFailed(
                    response["message"] as? String ?? "Notion 授权交换失败"
                )
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        guard let tokenBundle,
              let accessToken = tokenBundle["accessToken"] as? String, !accessToken.isEmpty,
              let refreshToken = tokenBundle["refreshToken"] as? String, !refreshToken.isEmpty,
              let botID = tokenBundle["botId"] as? String, !botID.isEmpty,
              let workspaceID = tokenBundle["workspaceId"] as? String, !workspaceID.isEmpty else {
            throw NotionOAuthBrokerError.invalidResponse
        }

        try await credentialStore.set(accessToken, for: .notionAccessToken)
        do {
            try await credentialStore.set(refreshToken, for: .notionRefreshToken)
        } catch {
            try? await credentialStore.remove(.notionAccessToken)
            throw error
        }
        defaults.set("\(botID):\(workspaceID)", forKey: Self.connectionKeyDefaultsKey)
        if defaults.string(forKey: Self.dataInstanceIDDefaultsKey)?.isEmpty != false {
            defaults.set(UUID().uuidString.lowercased(), forKey: Self.dataInstanceIDDefaultsKey)
        }
        _ = try? await post(
            base: base,
            path: "api/front/v1/notion/oauth/ack",
            body: ["exchangeId": exchangeID, "deliverySecret": secret]
        )
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let activeWindow = (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)) {
            return activeWindow
        }
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return ASPresentationAnchor()
        }
        if #available(iOS 26.0, *) {
            return ASPresentationAnchor(windowScene: windowScene)
        }
        return ASPresentationAnchor()
    }

    private func authorize(url: URL, callbackScheme: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let value = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] _, error in
                self?.authenticationSession = nil
                if let authenticationError = error as? ASWebAuthenticationSessionError,
                   authenticationError.code == .canceledLogin {
                    continuation.resume(throwing: NotionOAuthBrokerError.authorizationCancelled)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            value.presentationContextProvider = self
            value.prefersEphemeralWebBrowserSession = true
            authenticationSession = value
            if !value.start() {
                authenticationSession = nil
                continuation.resume(throwing: NotionOAuthBrokerError.invalidResponse)
            }
        }
    }

    private func post(base: URL, path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionOAuthBrokerError.invalidResponse
        }
        if let code = object["code"] as? Int, code != 200 {
            throw NotionOAuthBrokerError.exchangeFailed(
                object["message"] as? String ?? "Notion OAuth Broker 请求失败"
            )
        }
        return object
    }

    private func configuredString(_ key: String) -> String {
        (bundle.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NotionOAuthBrokerError.invalidResponse
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
