/**
 * [INPUT]: 依赖默认空的 Notion OAuth Broker 配置、URLSession 与 ExportCredentialStore 中的 Token Bundle
 * [OUTPUT]: 对外提供 NotionOAuthTokenRefresher，在明确 401 后通过一次性交付协议轮换并回读校验 Access/Refresh Token
 * [POS]: Services 层 Notion 令牌刷新 owner；不接触书籍内容、页面载荷、UserDefaults 或客户端 secret
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import Security

/// 刷新 actor 串行合并同一失效 Token 的并发 401；网络等待可取消，Keychain 写入完成后才对调用方发布新 Token。
actor NotionOAuthTokenRefresher {
    private let bundle: Bundle
    private let session: URLSession
    private let credentialStore: ExportCredentialStore

    init(
        bundle: Bundle = .main,
        session: URLSession = .shared,
        credentialStore: ExportCredentialStore
    ) {
        self.bundle = bundle
        self.session = session
        self.credentialStore = credentialStore
    }

    /// 仅刷新仍为当前值的被拒绝 Token；并发请求发现已有更新时直接复用，确保每一轮 401 最多交换一次。
    func refreshAccessToken(rejectedAccessToken: String) async throws -> String {
        let currentAccessToken = try await credentialStore.value(for: .notionAccessToken) ?? ""
        if !currentAccessToken.isEmpty, currentAccessToken != rejectedAccessToken {
            return currentAccessToken
        }
        let currentRefreshToken = try await credentialStore.value(for: .notionRefreshToken) ?? ""
        guard !currentAccessToken.isEmpty, !currentRefreshToken.isEmpty else {
            throw NotionOAuthBrokerError.exchangeFailed("Notion 授权已失效，请重新连接")
        }
        let baseURLText = configuredString("NotionOAuthBrokerBaseURL")
        guard let baseURL = URL(string: baseURLText) else {
            throw NotionOAuthBrokerError.missingConfiguration
        }

        let requestID = UUID().uuidString.lowercased()
        let deliverySecret = try Self.randomSecret()
        let response = try await post(
            base: baseURL,
            path: "api/front/v1/notion/oauth/refresh",
            body: [
                "refreshRequestId": requestID,
                "refreshToken": currentRefreshToken,
                "deliveryChallenge": Self.sha256Hex(deliverySecret)
            ]
        )
        let refreshStatus = response["exchangeStatus"] as? String ?? ""
        guard ["pending", "exchanging", "ready", "delivered"].contains(refreshStatus) else {
            throw NotionOAuthBrokerError.exchangeFailed(
                response["message"] as? String ?? "Notion 令牌刷新失败，请重新连接"
            )
        }

        var tokenBundle: [String: Any]?
        for _ in 0..<30 {
            try Task.checkCancellation()
            let redeemed = try await post(
                base: baseURL,
                path: "api/front/v1/notion/oauth/redeem",
                body: ["exchangeId": requestID, "deliverySecret": deliverySecret]
            )
            let status = redeemed["exchangeStatus"] as? String ?? ""
            if status == "ready" || status == "delivered" {
                tokenBundle = redeemed
                break
            }
            if ["denied", "failed", "expired"].contains(status) {
                throw NotionOAuthBrokerError.exchangeFailed(
                    redeemed["message"] as? String ?? "Notion 令牌刷新失败，请重新连接"
                )
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        guard let tokenBundle,
              let newAccessToken = tokenBundle["accessToken"] as? String,
              !newAccessToken.isEmpty,
              let newRefreshToken = tokenBundle["refreshToken"] as? String,
              !newRefreshToken.isEmpty else {
            throw NotionOAuthBrokerError.invalidResponse
        }

        // 两个 Keychain 项无法组成系统事务；先写 Refresh，再写 Access，第二步失败时回滚旧 Refresh，
        // 因此任何可见 Access Token 都始终有一枚与它匹配的 Refresh Token。
        try await credentialStore.set(newRefreshToken, for: .notionRefreshToken)
        do {
            try await credentialStore.set(newAccessToken, for: .notionAccessToken)
        } catch {
            try? await credentialStore.set(currentRefreshToken, for: .notionRefreshToken)
            throw error
        }
        guard try await credentialStore.value(for: .notionAccessToken) == newAccessToken,
              try await credentialStore.value(for: .notionRefreshToken) == newRefreshToken else {
            try? await credentialStore.set(currentRefreshToken, for: .notionRefreshToken)
            try? await credentialStore.set(currentAccessToken, for: .notionAccessToken)
            throw ExportCredentialStoreError.verificationFailed
        }
        _ = try? await post(
            base: baseURL,
            path: "api/front/v1/notion/oauth/ack",
            body: ["exchangeId": requestID, "deliverySecret": deliverySecret]
        )
        return newAccessToken
    }

    private func post(base: URL, path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionOAuthBrokerError.invalidResponse
        }
        guard (200...299).contains(http.statusCode), (object["code"] as? Int ?? 200) == 200 else {
            if object["code"] as? Int == 2102 {
                try? await credentialStore.remove(.notionAccessToken)
                try? await credentialStore.remove(.notionRefreshToken)
            }
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
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
