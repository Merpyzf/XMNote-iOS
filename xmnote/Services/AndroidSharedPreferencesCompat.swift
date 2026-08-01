/**
 * [INPUT]: 依赖 Foundation/UserDefaults 保存 Android 兼容偏好键，并提供 SharedPreferences XML 序列化
 * [OUTPUT]: 对外提供 AndroidSharedPreferencesCompat、ReadingTimerStartPreference 与 ReadingTimerSettingsStore，集中维护跨端计时偏好
 * [POS]: Services 兼容桥接层，被阅读计时启动、设置、Repository 与 BackupArchiveService 共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 阅读计时默认启动方式，数值语义严格对齐 Android `timingWay`：-1 每次询问、-2 正计时、正数为倒计时秒数。
nonisolated enum ReadingTimerStartPreference: Equatable, Sendable {
    case askEveryTime
    case countUp
    case countdown(seconds: Int64)

    /// 将 Android 兼容整数映射为安全业务值，非法值回退到每次询问。
    init(androidValue: Int64) {
        switch androidValue {
        case -2:
            self = .countUp
        case 1...:
            self = .countdown(seconds: androidValue)
        default:
            self = .askEveryTime
        }
    }

    var androidValue: Int64 {
        switch self {
        case .askEveryTime:
            return -1
        case .countUp:
            return -2
        case .countdown(let seconds):
            return max(1, seconds)
        }
    }
}

@MainActor
@Observable
/// 应用级计时设置状态，变更后立即写入 Android 同名偏好键，供启动页和跨端备份共享。
final class ReadingTimerSettingsStore {
    private(set) var preference: ReadingTimerStartPreference
    private let defaults: UserDefaults

    /// 从 Android 兼容偏好键恢复默认启动方式，未配置时保持“每次询问”。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedValue = (defaults.object(forKey: AndroidSharedPreferencesCompat.timingWayKey) as? NSNumber)?
            .int64Value ?? -1
        self.preference = ReadingTimerStartPreference(androidValue: storedValue)
    }

    /// 更新默认启动方式并同步持久化。
    func setPreference(_ preference: ReadingTimerStartPreference) {
        self.preference = preference
        defaults.set(preference.androidValue, forKey: AndroidSharedPreferencesCompat.timingWayKey)
    }
}

/// Android SharedPreferences 兼容桥，负责维护跨端恢复所需的最小偏好快照。
nonisolated enum AndroidSharedPreferencesCompat {
    static let fileName = "com.merpyzf.xmnote_preferences.xml"
    static let pendingTimingRecordIdKey = "pending_timing_record_id"
    static let timingWayKey = "timingWay"
    static let selectedCloudBackupServiceKey = "currCloudBackupService"

    /// 将未完成计时记录 ID 写入 Android 同名 pending key，供备份恢复到 Android 后触发冷启动恢复。
    static func setPendingTimingRecordId(_ recordId: Int64, defaults: UserDefaults = .standard) {
        guard recordId > 0 else {
            clearPendingTimingRecordId(defaults: defaults)
            return
        }
        defaults.set(recordId, forKey: pendingTimingRecordIdKey)
    }

    /// 清理 pending key；传入 expectedRecordId 时只清理同一条记录，避免误删后续新会话线索。
    static func clearPendingTimingRecordId(expectedRecordId: Int64? = nil, defaults: UserDefaults = .standard) {
        if let expectedRecordId,
           pendingTimingRecordId(defaults: defaults) != expectedRecordId {
            return
        }
        defaults.removeObject(forKey: pendingTimingRecordIdKey)
    }

    /// 读取当前 pending record id，缺省为 0，与 Android `SpSettingHelper#getPendingTimingRecordId` 对齐。
    static func pendingTimingRecordId(defaults: UserDefaults = .standard) -> Int64 {
        if let value = defaults.object(forKey: pendingTimingRecordIdKey) as? NSNumber {
            return value.int64Value
        }
        return 0
    }

    /// 生成 Android 可识别的 SharedPreferences XML；pending id 使用数据库扫描结果兜底，避免导出陈旧 key。
    static func makeXMLData(
        pendingTimingRecordId: Int64,
        defaults: UserDefaults = .standard
    ) -> Data {
        var lines = [
            "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>",
            "<map>"
        ]
        if pendingTimingRecordId > 0 {
            lines.append("    <long name=\"\(pendingTimingRecordIdKey)\" value=\"\(pendingTimingRecordId)\" />")
        }
        if let selectedProvider = defaults.object(forKey: selectedCloudBackupServiceKey) as? NSNumber {
            lines.append("    <int name=\"\(selectedCloudBackupServiceKey)\" value=\"\(selectedProvider.intValue)\" />")
        }
        let timingWay = (defaults.object(forKey: timingWayKey) as? NSNumber)?.int64Value ?? -1
        lines.append("    <int name=\"\(timingWayKey)\" value=\"\(timingWay)\" />")
        lines.append("</map>")
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }
}
