/**
 * [INPUT]: 依赖 AIConfigurationStore 提供类型化 AI 配置快照，依赖 Foundation 编解码 iOS 专属偏好 sidecar
 * [OUTPUT]: 对外提供 IOSUserDefaultsBackupCoordinator 与版本化 IOSPreferencesBackupEnvelope
 * [POS]: Services 层 iOS UserDefaults 备份白名单协调器，只登记明确允许进入归档的偏好域
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// iOS 专属偏好备份信封；Android 无需读取，新增 section 必须显式扩展字段与恢复策略。
nonisolated struct IOSPreferencesBackupEnvelope: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let aiConfiguration: IOSAIConfigurationBackupSection?

    init(aiConfiguration: IOSAIConfigurationBackupSection?) {
        self.formatVersion = Self.currentFormatVersion
        self.aiConfiguration = aiConfiguration
    }
}

/// AI 配置白名单 section v1；字段稳定独立于 UserDefaults 的物理 key，禁止退化为任意字典导出。
nonisolated struct IOSAIConfigurationBackupSection: Codable, Equatable, Sendable {
    static let currentSectionVersion = 1

    let sectionVersion: Int
    let isEnabled: Bool
    let provider: AIProvider
    let deepSeekModelID: String
    let siliconFlowModelID: String
    let prompts: AIPromptConfiguration
    let deepSeekAPIKey: String
    let siliconFlowAPIKey: String

    init(snapshot: AIConfigurationPreferenceSnapshot) {
        let normalized = snapshot.normalized
        self.sectionVersion = Self.currentSectionVersion
        self.isEnabled = normalized.configuration.isEnabled
        self.provider = normalized.configuration.provider
        self.deepSeekModelID = normalized.configuration.deepSeekModelID
        self.siliconFlowModelID = normalized.configuration.siliconFlowModelID
        self.prompts = normalized.configuration.prompts
        self.deepSeekAPIKey = normalized.deepSeekAPIKey
        self.siliconFlowAPIKey = normalized.siliconFlowAPIKey
    }

    var preferenceSnapshot: AIConfigurationPreferenceSnapshot {
        AIConfigurationPreferenceSnapshot(
            configuration: AIConfiguration(
                isEnabled: isEnabled,
                provider: provider,
                deepSeekModelID: deepSeekModelID,
                siliconFlowModelID: siliconFlowModelID,
                prompts: prompts
            ),
            deepSeekAPIKey: deepSeekAPIKey,
            siliconFlowAPIKey: siliconFlowAPIKey
        )
    }
}

/// iOS 偏好白名单协调器；Actor 串行化备份快照与恢复写入，避免同一 AI 配置并发交叉覆盖。
actor IOSUserDefaultsBackupCoordinator {
    static let shared = IOSUserDefaultsBackupCoordinator(configurationStore: .shared)

    static let archiveFileName = "xmnote_ios_preferences.json"
    static let maximumArchiveSize = 1_048_576

    private let configurationStore: AIConfigurationStore

    /// 注入 AI 配置存储；首个白名单域出现前不引入动态注册或反射式 UserDefaults 遍历。
    init(configurationStore: AIConfigurationStore) {
        self.configurationStore = configurationStore
    }

    /// 获取一个一致的 AI 快照并编码为 sidecar；调用任务取消时底层迁移不会提交半份配置。
    func makeArchiveData() async throws -> Data {
        let snapshot = try await configurationStore.makeBackupSnapshot()
        try Task.checkCancellation()
        let envelope = IOSPreferencesBackupEnvelope(
            aiConfiguration: IOSAIConfigurationBackupSection(snapshot: snapshot)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumArchiveSize else {
            throw IOSPreferencesBackupError.payloadTooLarge
        }
        return data
    }

    /// 在数据库成功恢复后整组应用 AI section；section 缺失时保留当前设备配置并返回 false。
    func restore(_ envelope: IOSPreferencesBackupEnvelope) async throws -> Bool {
        guard let section = envelope.aiConfiguration else { return false }
        guard section.sectionVersion == IOSAIConfigurationBackupSection.currentSectionVersion else {
            throw IOSPreferencesBackupError.unsupportedSectionVersion
        }
        try await configurationStore.restoreBackupSnapshot(section.preferenceSnapshot)
        return true
    }

    /// 对解压后的 sidecar 执行尺寸、JSON 与信封版本校验；任何错误都不得携带 API Key 内容。
    nonisolated static func decodeArchiveData(_ data: Data) throws -> IOSPreferencesBackupEnvelope {
        guard data.count <= maximumArchiveSize else {
            throw IOSPreferencesBackupError.payloadTooLarge
        }
        let envelope: IOSPreferencesBackupEnvelope
        do {
            envelope = try JSONDecoder().decode(IOSPreferencesBackupEnvelope.self, from: data)
        } catch {
            throw IOSPreferencesBackupError.invalidPayload
        }
        guard envelope.formatVersion == IOSPreferencesBackupEnvelope.currentFormatVersion else {
            throw IOSPreferencesBackupError.unsupportedFormatVersion
        }
        if let section = envelope.aiConfiguration,
           section.sectionVersion != IOSAIConfigurationBackupSection.currentSectionVersion {
            throw IOSPreferencesBackupError.unsupportedSectionVersion
        }
        return envelope
    }
}

/// iOS 偏好 sidecar 错误；只暴露结构语义，禁止附带原始 JSON 或敏感字段。
private nonisolated enum IOSPreferencesBackupError: LocalizedError, Sendable {
    case payloadTooLarge
    case invalidPayload
    case unsupportedFormatVersion
    case unsupportedSectionVersion

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            "iOS 设置备份内容超过 1 MiB 限制"
        case .invalidPayload:
            "iOS 设置备份格式无效"
        case .unsupportedFormatVersion, .unsupportedSectionVersion:
            "iOS 设置备份来自较新版本"
        }
    }
}
