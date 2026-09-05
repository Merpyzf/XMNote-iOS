/**
 * [INPUT]: 依赖 Security Keychain 与三联专属 UserDefaults 键
 * [OUTPUT]: 提供三联登录恢复、记住偏好及已验证凭证保存
 * [POS]: Services 的三联凭证存储边界，仅由 NoteImportRepository 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Security

/// 在独立 actor 上串行访问凭证，避免 Keychain 阻塞主线程；单次读写不挂起，关闭记住与登录保存不会交错。
actor LifeWeekCredentialStore {
    private let defaults = UserDefaults.standard
    private let service = (Bundle.main.bundleIdentifier ?? "XMNote") + ".lifeweek.import"
    private let phoneKey = "lifeWeekPhoneNumber"
    private let legacyPasswordKey = "lifeWeekPassword"
    private let rememberKey = "lifeWeekRemembersPassword"

    /// 在 actor executor 上恢复一次快照；迁移失败保留旧数据，不将 Keychain 错误当作记录不存在。
    func load() -> LifeWeekLoginState {
        var state = LifeWeekLoginState(
            phoneNumber: defaults.string(forKey: phoneKey) ?? "",
            remembersPassword: remembersPassword
        )
        guard state.remembersPassword else {
            do {
                try setRemembersPassword(false)
            } catch {
                state.storageMessage = "未能移除已保存的密码，请重试。"
            }
            return state
        }
        let legacyPassword = defaults.string(forKey: legacyPasswordKey) ?? ""
        do {
            if let credential = try readCredential() {
                state.phoneNumber = credential.phoneNumber
                state.password = credential.password
            } else if !legacyPassword.isEmpty {
                let credential = Credential(phoneNumber: state.phoneNumber, password: legacyPassword)
                try writeCredential(credential)
                state.password = legacyPassword
            }
            defaults.removeObject(forKey: legacyPasswordKey)
        } catch {
            state.password = legacyPassword
            state.storageMessage = "暂时无法安全读取或保存密码，请稍后重试。"
        }
        return state
    }

    /// 在 actor executor 上原子更新偏好；关闭先删除已存密码，失败时不提交开关状态，也不清空页面输入。
    func setRemembersPassword(_ enabled: Bool) throws {
        if !enabled {
            let status = SecItemDelete(keychainQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.keychain(status)
            }
            defaults.removeObject(forKey: legacyPasswordKey)
        }
        defaults.set(enabled, forKey: rememberKey)
    }

    /// 只接收服务端已验证的凭证；actor 内无挂起点，使用执行时的最新偏好，保存失败不覆盖旧有效记录。
    func saveAuthenticated(phoneNumber: String, password: String) -> String? {
        do {
            if remembersPassword {
                try writeCredential(Credential(phoneNumber: phoneNumber, password: password))
                defaults.removeObject(forKey: legacyPasswordKey)
            }
            defaults.set(phoneNumber, forKey: phoneKey)
            return nil
        } catch {
            return "未能记住密码，本次仍可导入。请稍后重试。"
        }
    }

    private var remembersPassword: Bool {
        defaults.object(forKey: rememberKey) as? Bool ?? true
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "remembered-login",
            kSecAttrSynchronizable as String: false
        ]
    }

    /// 读取本功能唯一凭证项；不存在才返回 nil，权限、格式及设备锁定错误保持可区分。
    private func readCredential() throws -> Credential? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = result as? Data else { throw CredentialError.invalidData }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    /// 原子替换唯一凭证的数据，不先删除旧项；只允许解锁时访问且不参与跨设备同步。
    private func writeCredential(_ credential: Credential) throws {
        let values: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credential),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(keychainQuery as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = keychainQuery.merging(values) { _, new in new }
            let insertStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw CredentialError.keychain(insertStatus) }
        } else if status != errSecSuccess {
            throw CredentialError.keychain(status)
        }
    }

    /// 以同一 Keychain 数据项绑定账号和密码，避免新手机号配到旧密码。
    private struct Credential: Codable, Sendable {
        let phoneNumber: String
        let password: String
    }

    /// 错误仅携带系统状态码，不包含凭证或请求地址。
    private enum CredentialError: Error {
        case keychain(OSStatus)
        case invalidData
    }
}
