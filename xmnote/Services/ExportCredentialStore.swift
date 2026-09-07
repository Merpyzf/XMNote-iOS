/**
 * [INPUT]: 依赖 Security Keychain Services 与 ExportCredential 稳定账户名，接收待保存的敏感字符串
 * [OUTPUT]: 对外提供 ExportCredentialStore actor，以 WhenUnlockedThisDeviceOnly 读写导出凭据并支持测试内存后端
 * [POS]: Services 层导出凭据唯一 owner；UserDefaults、ViewModel、生成器与日志不得持久化或打印明文凭据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Security

/// Keychain 操作失败，保留 OSStatus 便于安全地分类而不泄露凭据。
enum ExportCredentialStoreError: LocalizedError {
    case encodingFailed
    case keychain(OSStatus)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "凭据编码失败"
        case let .keychain(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串操作失败（\(status)）"
        case .verificationFailed:
            "凭据写入后校验失败"
        }
    }
}

/// 串行保护导出凭据；actor 不绑定主线程，调用任务取消不会中断已经提交给 Keychain 的原子读写。
actor ExportCredentialStore {
    enum Backend: Sendable {
        case keychain
        case memory
    }

    private let service: String
    private let backend: Backend
    private var memoryValues: [ExportCredential: String] = [:]

    init(
        service: String = "com.xmnote.export.credentials",
        backend: Backend = .keychain
    ) {
        self.service = service
        self.backend = backend
    }

    /// 保存并回读验证非空凭据；空字符串等价于删除，避免 Keychain 留下无意义项目。
    func set(_ rawValue: String, for credential: ExportCredential) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            try remove(credential)
            return
        }
        switch backend {
        case .memory:
            memoryValues[credential] = value
        case .keychain:
            guard let data = value.data(using: .utf8) else {
                throw ExportCredentialStoreError.encodingFailed
            }
            let query = baseQuery(for: credential)
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess {
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                ]
                let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard updateStatus == errSecSuccess else {
                    throw ExportCredentialStoreError.keychain(updateStatus)
                }
            } else if status == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let addStatus = SecItemAdd(attributes as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw ExportCredentialStoreError.keychain(addStatus)
                }
            } else {
                throw ExportCredentialStoreError.keychain(status)
            }
        }
        guard try self.value(for: credential) == value else {
            throw ExportCredentialStoreError.verificationFailed
        }
    }

    /// 读取单个凭据；不存在时返回 nil，其他 Keychain 错误原样抛出。
    func value(for credential: ExportCredential) throws -> String? {
        switch backend {
        case .memory:
            return memoryValues[credential]
        case .keychain:
            var query = baseQuery(for: credential)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else {
                throw ExportCredentialStoreError.keychain(status)
            }
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw ExportCredentialStoreError.encodingFailed
            }
            return value
        }
    }

    /// 删除一个凭据；不存在视为成功，保证迁移和断开连接操作幂等。
    func remove(_ credential: ExportCredential) throws {
        switch backend {
        case .memory:
            memoryValues.removeValue(forKey: credential)
        case .keychain:
            let status = SecItemDelete(baseQuery(for: credential) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ExportCredentialStoreError.keychain(status)
            }
        }
    }

    /// 检查凭据是否存在；读取失败按不存在处理，界面只据此显示连接状态，不暴露错误或明文。
    func contains(_ credential: ExportCredential) -> Bool {
        do {
            return try value(for: credential)?.isEmpty == false
        } catch {
            return false
        }
    }

    /// 生成只按服务与稳定账户名定位的通用密码查询。
    private func baseQuery(for credential: ExportCredential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue
        ]
    }
}
