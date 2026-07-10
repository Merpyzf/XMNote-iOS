/**
 * [INPUT]: 依赖 UserDefaults 持久化关联应用配置
 * [OUTPUT]: 对外提供 ExternalAppIntegrationSettingStore，供 ExternalAppIntegrationRepository 读取和保存三方 API 配置
 * [POS]: Data 层关联应用配置轻量持久化协作者，避免 ViewModel 直接访问 UserDefaults
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 关联应用配置的本地持久化入口，对齐 Android SharedPreferences 的轻量配置语义。
nonisolated struct ExternalAppIntegrationSettingStore {
    static let shared = ExternalAppIntegrationSettingStore()
    static let didChangeNotification = Notification.Name("ExternalAppIntegrationSettingStore.didChange")

    private let defaults: UserDefaults
    private let key = "external-app.integration.settings.v1"

    /// 注入 UserDefaults，默认使用标准容器。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取关联应用配置；缺失或解码失败时返回空配置。
    func fetchSettings() -> ExternalAppIntegrationSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ExternalAppIntegrationSettings.self, from: data) else {
            return .empty
        }
        return decoded.normalized
    }

    /// 保存关联应用配置；空字符串表示清空指定目标。
    func save(_ settings: ExternalAppIntegrationSettings) throws {
        do {
            let data = try JSONEncoder().encode(settings.normalized)
            defaults.set(data, forKey: key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        } catch {
            throw ExternalAppIntegrationError.persistenceFailure(message: error.localizedDescription)
        }
    }

    /// 观察关联应用配置变化，供保活的书摘回顾页实时更新“发送到”入口。
    func observeChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: Self.didChangeNotification) {
                    guard !Task.isCancelled else { return }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
