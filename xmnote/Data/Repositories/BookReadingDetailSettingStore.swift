/**
 * [INPUT]: 依赖 Foundation UserDefaults 与阅读详情偏好领域模型
 * [OUTPUT]: 对外提供 BookReadingDetailSettingStore，持久化页面与长图分享开关
 * [POS]: Data 层轻量偏好存储，不承载数据库业务数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 阅读详情偏好存储；解码失败时回退 Android 对齐的全开启默认值。
nonisolated struct BookReadingDetailSettingStore {
    private let defaults: UserDefaults
    private let settingKey = "bookReadingDetail.setting.v1"
    private let shareSettingKey = "bookReadingDetail.shareSetting.v1"

    /// 注入偏好容器，生产默认使用标准 UserDefaults。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取页面偏好。
    func fetchSetting() -> BookReadingDetailSetting {
        guard let data = defaults.data(forKey: settingKey),
              let value = try? JSONDecoder().decode(BookReadingDetailSetting.self, from: data) else {
            return BookReadingDetailSetting()
        }
        return value
    }

    /// 保存页面偏好；编码失败不覆盖已有值。
    func saveSetting(_ setting: BookReadingDetailSetting) {
        guard let data = try? JSONEncoder().encode(setting) else { return }
        defaults.set(data, forKey: settingKey)
    }

    /// 读取长图分享偏好。
    func fetchShareSetting() -> BookReadingDetailShareSetting {
        guard let data = defaults.data(forKey: shareSettingKey),
              let value = try? JSONDecoder().decode(BookReadingDetailShareSetting.self, from: data) else {
            return BookReadingDetailShareSetting()
        }
        return value
    }

    /// 保存长图分享偏好；编码失败不覆盖已有值。
    func saveShareSetting(_ setting: BookReadingDetailShareSetting) {
        guard let data = try? JSONEncoder().encode(setting) else { return }
        defaults.set(data, forKey: shareSettingKey)
    }
}
