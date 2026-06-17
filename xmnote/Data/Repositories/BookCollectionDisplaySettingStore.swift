/**
 * [INPUT]: 依赖 UserDefaults 持久化书单首页显示设置
 * [OUTPUT]: 对外提供 BookCollectionDisplaySettingStore，供 BookRepository 读取和保存书单显示偏好
 * [POS]: Data 层书单显示设置轻量持久化协作者，避免 ViewModel 直接访问 UserDefaults
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书单首页显示设置的本地轻量持久化入口，保持页面状态只经 Repository 获取本地偏好。
nonisolated struct BookCollectionDisplaySettingStore {
    static let shared = BookCollectionDisplaySettingStore()

    private let defaults: UserDefaults
    private let key = "book-collection.display.setting.v1"

    /// 注入 UserDefaults，默认使用标准容器。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取书单首页显示设置；缺失或解码失败时回退到默认值。
    func fetchSetting() -> BookCollectionDisplaySetting {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(BookCollectionDisplaySetting.self, from: data) else {
            return .defaultValue
        }
        return decoded
    }

    /// 保存书单首页显示设置。
    func save(_ setting: BookCollectionDisplaySetting) {
        guard let data = try? JSONEncoder().encode(setting) else { return }
        defaults.set(data, forKey: key)
    }
}
