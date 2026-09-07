/**
 * [INPUT]: 依赖 UserDefaults、ExportSettingsSnapshot 与 ExportCredentialStore，兼容读取旧 Desktop Web 明文导出设置
 * [OUTPUT]: 对外提供非敏感设置持久化、Keychain 凭据读取与一次性旧明文迁移
 * [POS]: Data 层统一导出设置 owner；原生界面和 Desktop Web 通过 ExportRepository 间接访问
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 串行保护设置读改写和旧凭据迁移；actor 不绑定主线程，取消只影响调用方等待，不破坏已提交的持久化。
actor ExportSettingsStore {
    private enum Keys {
        static let settings = "export.settings.v2"
        static let legacyDesktopWebSettings = "desktopWeb.api.exportSettings"
        static let migrationCompleted = "export.credentials.migration.v2.completed"
        static let legacyNotionDatabaseID = "desktopWeb.api.notionDatabaseID"
    }

    private let defaults: UserDefaults
    private let credentialStore: ExportCredentialStore

    init(defaults: UserDefaults, credentialStore: ExportCredentialStore) {
        self.defaults = defaults
        self.credentialStore = credentialStore
    }

    /// 首次读取前迁移旧明文，再解码非敏感设置；无效数据回退 Android 默认值。
    func settings() async -> ExportSettingsSnapshot {
        await migrateLegacyCredentialsIfNeeded()
        guard let data = defaults.data(forKey: Keys.settings),
              let value = try? JSONDecoder().decode(ExportSettingsSnapshot.self, from: data) else {
            return .androidDefault
        }
        return normalized(value)
    }

    /// 只保存归一化后的非敏感快照；编码失败不会覆盖最后一次有效设置。
    func save(_ settings: ExportSettingsSnapshot) throws {
        let data = try JSONEncoder().encode(normalized(settings))
        defaults.set(data, forKey: Keys.settings)
    }

    /// 将敏感值交给 Keychain owner 保存，UserDefaults 永远不接收该值。
    func saveCredential(_ value: String, for credential: ExportCredential) async throws {
        try await credentialStore.set(value, for: credential)
    }

    /// 读取执行时凭据快照，调用者不得把返回值写入设置响应或日志。
    func credential(_ credential: ExportCredential) async throws -> String {
        try await credentialStore.value(for: credential) ?? ""
    }

    /// 返回是否已配置凭据，供界面和 Web 设置响应显示脱敏状态。
    func hasCredential(_ credential: ExportCredential) async -> Bool {
        await credentialStore.contains(credential)
    }

    /// 把旧明文写入 Keychain 并回读成功后才从旧 JSON 清除；旧 Notion token/page ID 不迁移并强制重新连接。
    private func migrateLegacyCredentialsIfNeeded() async {
        guard !defaults.bool(forKey: Keys.migrationCompleted) else { return }
        guard let data = defaults.data(forKey: Keys.legacyDesktopWebSettings),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            defaults.set(true, forKey: Keys.migrationCompleted)
            return
        }

        let mappings: [(String, ExportCredential)] = [
            ("yuqueToken", .yuqueToken),
            ("siyuanToken", .siYuanToken),
            ("obsidianApiKey", .obsidianAPIKey)
        ]
        var hasUnmigratedCredential = false
        for (legacyKey, credential) in mappings {
            let rawValue = (object[legacyKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawValue.isEmpty else {
                object[legacyKey] = ""
                continue
            }
            do {
                try await credentialStore.set(rawValue, for: credential)
                if try await credentialStore.value(for: credential) == rawValue {
                    object[legacyKey] = ""
                } else {
                    hasUnmigratedCredential = true
                }
            } catch {
                hasUnmigratedCredential = true
            }
        }

        object["notionToken"] = ""
        object["notionPageId"] = ""
        defaults.removeObject(forKey: Keys.legacyNotionDatabaseID)
        if JSONSerialization.isValidJSONObject(object),
           let sanitizedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            defaults.set(sanitizedData, forKey: Keys.legacyDesktopWebSettings)
        }
        if !hasUnmigratedCredential {
            defaults.set(true, forKey: Keys.migrationCompleted)
        }
    }

    /// 修复旧版本或外部写入造成的重复字段和不受支持目标，不改变用户剩余字段顺序。
    private func normalized(_ source: ExportSettingsSnapshot) -> ExportSettingsSnapshot {
        var value = source
        var seen = Set<ExportBookField>()
        value.bookFields = source.bookFields.filter { seen.insert($0.field).inserted }
        value.bookFields.append(contentsOf: ExportBookField.allCases
            .filter { !seen.contains($0) }
            .map { ExportBookFieldSelection(field: $0, isEnabled: true) })
        if !value.lastNoteTarget.supports(.noteExcerpt) { value.lastNoteTarget = .markdown }
        if !value.lastBookTarget.supports(.bookInformation) { value.lastBookTarget = .csv }
        value.siYuanPort = min(65_535, max(1, value.siYuanPort))
        return value
    }
}
