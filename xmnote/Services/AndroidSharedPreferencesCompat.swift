/**
 * [INPUT]: 依赖 Foundation/UserDefaults 保存 Android 兼容偏好键，并提供 SharedPreferences XML 序列化
 * [OUTPUT]: 对外提供 AndroidSharedPreferencesCompat，集中维护跨端备份恢复所需的 Android 偏好文件名与 key
 * [POS]: Services 兼容桥接层，被 ReadingTimerRepository 与 BackupArchiveService 用于同步未完成计时恢复线索
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android SharedPreferences 兼容桥，负责维护跨端恢复所需的最小偏好快照。
nonisolated enum AndroidSharedPreferencesCompat {
    static let fileName = "com.merpyzf.xmnote_preferences.xml"
    static let pendingTimingRecordIdKey = "pending_timing_record_id"
    static let selectedCloudBackupServiceKey = "currCloudBackupService"

    /// 将运行/暂停中的计时记录 ID 写入 Android 同名 pending key，供备份恢复到 Android 后触发冷启动恢复。
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
        lines.append("</map>")
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }
}
