/**
 * [INPUT]: 依赖 Foundation/UserDefaults 原子保存完整 AI 配置，依赖 Security 迁移并清理旧 Keychain 凭据
 * [OUTPUT]: 对外提供 AIConfigurationStore，异步读取、更新、备份和整组恢复 ai.configuration.v2
 * [POS]: Services 层 AI 配置存储边界，被 AIRepository 与 iOS 偏好备份协调器使用，禁止 ViewModel 直接访问持久化容器
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Security

/// AI 配置白名单快照；只承载产品明确允许进入 iOS 备份的完整 AI 配置。
nonisolated struct AIConfigurationPreferenceSnapshot: Equatable, Sendable {
    var configuration: AIConfiguration
    var deepSeekAPIKey: String
    var siliconFlowAPIKey: String

    /// 返回指定供应商密钥；空字符串表示该供应商未配置凭据。
    func apiKey(for provider: AIProvider) -> String {
        switch provider {
        case .deepSeek:
            deepSeekAPIKey
        case .siliconFlow:
            siliconFlowAPIKey
        }
    }

    /// 覆盖指定供应商密钥，保持另一供应商配置不变。
    mutating func setAPIKey(_ apiKey: String, for provider: AIProvider) {
        switch provider {
        case .deepSeek:
            deepSeekAPIKey = apiKey
        case .siliconFlow:
            siliconFlowAPIKey = apiKey
        }
    }

    var normalized: AIConfigurationPreferenceSnapshot {
        var result = self
        result.configuration = configuration.normalized
        result.deepSeekAPIKey = deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        result.siliconFlowAPIKey = siliconFlowAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.configuration.isEnabled,
           result.apiKey(for: result.configuration.provider).isEmpty {
            result.configuration.isEnabled = false
        }
        return result
    }
}

/// AI 配置存储 Actor；完整配置与两家凭据通过一次 UserDefaults 写入形成一致快照。
actor AIConfigurationStore {
    static let shared = AIConfigurationStore()

    private enum Keys {
        static let legacyConfiguration = "ai.configuration.v1"
        static let configuration = "ai.configuration.v2"
    }

    private let defaults: UserDefaults
    private let legacyKeychain: AIKeychainStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var hasAttemptedLegacyCleanup = false

    /// 注入本地偏好与 Keychain 存储；生产默认使用标准偏好域和当前 App 专属 service。
    init(
        defaults: UserDefaults = .standard,
        keychain: AIKeychainStore = AIKeychainStore()
    ) {
        self.defaults = defaults
        self.legacyKeychain = keychain
    }

    /// 读取 v2 配置并仅汇总各供应商是否存在密钥；首次调用会串行迁移 v1 与旧 Keychain，取消时不提交半份快照。
    func fetchSnapshot() async throws -> AIConfigurationSnapshot {
        let stored = try await loadOrMigrate().preferenceSnapshot
        return AIConfigurationSnapshot(
            configuration: stored.configuration,
            providersWithStoredKey: Set(
                AIProvider.allCases.filter { !stored.apiKey(for: $0).isEmpty }
            )
        )
    }

    /// 保存完整 v2 快照；`apiKey=nil` 保留当前供应商密钥，Actor 串行化避免配置与凭据交叉覆盖。
    func save(_ configuration: AIConfiguration, apiKey: String?) async throws {
        var stored = try await loadOrMigrate()
        stored.configuration = configuration.normalized
        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                stored.setAPIKey(trimmed, for: stored.configuration.provider)
            }
        }
        try persist(stored)
    }

    /// 读取当前供应商请求所需凭据；明文只在 Repository 发起请求时短暂存在，不进入日志或页面状态。
    func credential(for provider: AIProvider) async throws -> String? {
        let apiKey = try await loadOrMigrate().apiKey(for: provider)
        return apiKey.isEmpty ? nil : apiKey
    }

    /// 删除指定供应商密钥并提交新的完整 v2 快照，不影响另一供应商凭据。
    func deleteCredential(for provider: AIProvider) async throws {
        var stored = try await loadOrMigrate()
        stored.setAPIKey("", for: provider)
        try persist(stored)
    }

    /// 生成备份白名单所需一致快照；首次备份同样会完成 v1/Keychain 迁移。
    func makeBackupSnapshot() async throws -> AIConfigurationPreferenceSnapshot {
        try await loadOrMigrate().preferenceSnapshot
    }

    /// 整组替换 AI 配置；调用方须在数据库恢复成功后执行，写入成功后再清理遗留存储。
    func restoreBackupSnapshot(_ snapshot: AIConfigurationPreferenceSnapshot) async throws {
        let stored = StoredAIConfigurationV2(snapshot: snapshot.normalized)
        try persist(stored)
        await removeLegacyArtifacts()
        hasAttemptedLegacyCleanup = true
    }

    /// v2 键一旦存在便只读取 v2；即使内容异常也不回退旧凭据，防止已删除密钥复活。
    private func loadOrMigrate() async throws -> StoredAIConfigurationV2 {
        if let data = defaults.data(forKey: Keys.configuration) {
            guard let stored = try? decoder.decode(StoredAIConfigurationV2.self, from: data),
                  stored.formatVersion == StoredAIConfigurationV2.currentFormatVersion else {
                throw AIRepositoryError.credentialStore("AI 配置格式无法读取")
            }
            if !hasAttemptedLegacyCleanup {
                await removeLegacyArtifacts()
                hasAttemptedLegacyCleanup = true
            }
            return StoredAIConfigurationV2(snapshot: stored.preferenceSnapshot.normalized)
        }

        let legacyConfiguration = decodedLegacyConfiguration().normalized
        async let deepSeekKey = legacyKeychain.apiKey(for: .deepSeek)
        async let siliconFlowKey = legacyKeychain.apiKey(for: .siliconFlow)
        let migrated = StoredAIConfigurationV2(
            configuration: legacyConfiguration,
            deepSeekAPIKey: try await deepSeekKey ?? "",
            siliconFlowAPIKey: try await siliconFlowKey ?? ""
        )
        try Task.checkCancellation()
        try persist(migrated)
        await removeLegacyArtifacts()
        hasAttemptedLegacyCleanup = true
        return migrated
    }

    private func decodedLegacyConfiguration() -> AIConfiguration {
        guard let data = defaults.data(forKey: Keys.legacyConfiguration),
              let configuration = try? decoder.decode(AIConfiguration.self, from: data) else {
            return .androidAlignedDefault
        }
        return configuration
    }

    private func persist(_ stored: StoredAIConfigurationV2) throws {
        let normalized = StoredAIConfigurationV2(snapshot: stored.preferenceSnapshot.normalized)
        let data = try encoder.encode(normalized)
        defaults.set(data, forKey: Keys.configuration)
        guard defaults.data(forKey: Keys.configuration) == data else {
            throw AIRepositoryError.credentialStore("AI 配置无法写入本机偏好")
        }
    }

    /// 仅在 v2 已成功落盘后清理旧键与 Keychain；清理失败不回滚 v2，也不会触发旧凭据回读。
    private func removeLegacyArtifacts() async {
        defaults.removeObject(forKey: Keys.legacyConfiguration)
        for provider in AIProvider.allCases {
            try? await legacyKeychain.deleteAPIKey(for: provider)
        }
    }
}

/// `ai.configuration.v2` 的单值 Codable 载荷，确保配置与两家凭据只有一个提交点。
private nonisolated struct StoredAIConfigurationV2: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2

    let formatVersion: Int
    var configuration: AIConfiguration
    var deepSeekAPIKey: String
    var siliconFlowAPIKey: String

    init(
        configuration: AIConfiguration,
        deepSeekAPIKey: String,
        siliconFlowAPIKey: String
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.configuration = configuration
        self.deepSeekAPIKey = deepSeekAPIKey
        self.siliconFlowAPIKey = siliconFlowAPIKey
    }

    init(snapshot: AIConfigurationPreferenceSnapshot) {
        self.init(
            configuration: snapshot.configuration,
            deepSeekAPIKey: snapshot.deepSeekAPIKey,
            siliconFlowAPIKey: snapshot.siliconFlowAPIKey
        )
    }

    var preferenceSnapshot: AIConfigurationPreferenceSnapshot {
        AIConfigurationPreferenceSnapshot(
            configuration: configuration,
            deepSeekAPIKey: deepSeekAPIKey,
            siliconFlowAPIKey: siliconFlowAPIKey
        )
    }

    func apiKey(for provider: AIProvider) -> String {
        preferenceSnapshot.apiKey(for: provider)
    }

    mutating func setAPIKey(_ apiKey: String, for provider: AIProvider) {
        switch provider {
        case .deepSeek:
            deepSeekAPIKey = apiKey
        case .siliconFlow:
            siliconFlowAPIKey = apiKey
        }
    }
}

/// 旧 Keychain 只读/删除适配器；迁移完成后不再作为生产配置写入点。
actor AIKeychainStore {
    private let service: String

    /// 使用 bundle identifier 派生专属 Keychain service，避免与其他凭据命名空间碰撞。
    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.xmnote")\u{2e}ai.credentials") {
        self.service = service
    }

    /// 从旧 Keychain 读取 API Key；同步 Security 查询在 utility task 执行，父任务取消时迁移不会提交 v2。
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

    /// 删除旧供应商 Keychain 项；不存在按幂等成功，失败不暴露凭据内容。
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
