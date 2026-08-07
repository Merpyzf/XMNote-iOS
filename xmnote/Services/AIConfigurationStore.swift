/**
 * [INPUT]: 依赖 Foundation/UserDefaults 保存非敏感 AI 设置，依赖 Security Keychain 保存各供应商 API Key
 * [OUTPUT]: 对外提供 AIConfigurationStore，异步读取配置快照、更新配置与安全凭据
 * [POS]: Services 层 AI 配置存储边界，被 AIRepository 独占使用，禁止 ViewModel 直接访问 UserDefaults 或 Keychain
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Security

/// AI 配置存储 Actor；非敏感字段进入 UserDefaults，明文密钥只经 Keychain 读写。
actor AIConfigurationStore {
    static let shared = AIConfigurationStore()

    private enum Keys {
        static let configuration = "ai.configuration.v1"
    }

    private let defaults: UserDefaults
    private let keychain: AIKeychainStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 注入本地偏好与 Keychain 存储；生产默认使用标准偏好域和当前 App 专属 service。
    init(
        defaults: UserDefaults = .standard,
        keychain: AIKeychainStore = AIKeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// 读取非敏感设置并仅汇总各供应商是否存在密钥，不把明文凭据暴露给设置页。
    func fetchSnapshot() async throws -> AIConfigurationSnapshot {
        let configuration = decodedConfiguration().normalized
        var providersWithStoredKey = Set<AIProvider>()
        for provider in AIProvider.allCases {
            if try await keychain.containsAPIKey(for: provider) {
                providersWithStoredKey.insert(provider)
            }
        }
        return AIConfigurationSnapshot(
            configuration: configuration,
            providersWithStoredKey: providersWithStoredKey
        )
    }

    /// 保存设置；`apiKey=nil` 表示保留当前供应商已有密钥，非空值写入 Keychain 后再提交非敏感配置。
    func save(_ configuration: AIConfiguration, apiKey: String?) async throws {
        let normalized = configuration.normalized
        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try await keychain.saveAPIKey(trimmed, for: normalized.provider)
            }
        }
        let data = try encoder.encode(normalized)
        defaults.set(data, forKey: Keys.configuration)
    }

    /// 读取当前供应商请求所需凭据；该明文只在 Repository 发起请求时短暂存在。
    func credential(for provider: AIProvider) async throws -> String? {
        try await keychain.apiKey(for: provider)
    }

    /// 删除指定供应商密钥，不影响另一供应商的模型和凭据。
    func deleteCredential(for provider: AIProvider) async throws {
        try await keychain.deleteAPIKey(for: provider)
    }

    private func decodedConfiguration() -> AIConfiguration {
        guard let data = defaults.data(forKey: Keys.configuration),
              let configuration = try? decoder.decode(AIConfiguration.self, from: data) else {
            return .androidAlignedDefault
        }
        return configuration
    }
}

/// Keychain 适配器；Security API 为同步阻塞调用，所有查询均移到 utility detached task。
actor AIKeychainStore {
    private let service: String

    /// 使用 bundle identifier 派生专属 Keychain service，避免与其他凭据命名空间碰撞。
    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.xmnote")\u{2e}ai.credentials") {
        self.service = service
    }

    /// 判断供应商凭据是否存在；不会把明文返回给设置页。
    func containsAPIKey(for provider: AIProvider) async throws -> Bool {
        try await apiKey(for: provider) != nil
    }

    /// 从 Keychain 读取 API Key；`SecItemCopyMatching` 在后台 utility task 执行并支持父任务取消。
    func apiKey(for provider: AIProvider) async throws -> String? {
        let service = service
        let account = provider.rawValue
        do {
            return try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try Self.readAPIKey(service: service, account: account)
            }.value
        } catch let error as AIKeychainError {
            throw AIRepositoryError.credentialStore(error.localizedDescription)
        }
    }

    /// 写入或原位更新 API Key；使用仅本机、解锁时可访问级别，凭据不随备份迁移。
    func saveAPIKey(_ apiKey: String, for provider: AIProvider) async throws {
        let service = service
        let account = provider.rawValue
        do {
            try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                try Self.writeAPIKey(apiKey, service: service, account: account)
            }.value
        } catch let error as AIKeychainError {
            throw AIRepositoryError.credentialStore(error.localizedDescription)
        }
    }

    /// 删除供应商 API Key；不存在时按幂等成功处理。
    func deleteAPIKey(for provider: AIProvider) async throws {
        let service = service
        let account = provider.rawValue
        do {
            try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                try Self.removeAPIKey(service: service, account: account)
            }.value
        } catch let error as AIKeychainError {
            throw AIRepositoryError.credentialStore(error.localizedDescription)
        }
    }

    private nonisolated static func readAPIKey(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AIKeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw AIKeychainError.invalidStoredValue
        }
        return value
    }

    private nonisolated static func writeAPIKey(
        _ apiKey: String,
        service: String,
        account: String
    ) throws {
        guard let data = apiKey.data(using: .utf8) else {
            throw AIKeychainError.invalidStoredValue
        }
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let addQuery: [String: Any] = identityQuery.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw AIKeychainError.unexpectedStatus(addStatus)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identityQuery as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw AIKeychainError.unexpectedStatus(updateStatus)
        }
    }

    private nonisolated static func removeAPIKey(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIKeychainError.unexpectedStatus(status)
        }
    }
}

/// Security OSStatus 到业务错误的窄适配，禁止记录或拼接密钥内容。
private enum AIKeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidStoredValue

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain 状态码 \(status)"
        case .invalidStoredValue:
            return "Keychain 中的凭据不是有效文本"
        }
    }
}
