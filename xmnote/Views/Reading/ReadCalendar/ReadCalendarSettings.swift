import Foundation

/**
 * [INPUT]: 依赖 ReadCalendarEventType 提供事件类型枚举
 * [OUTPUT]: 对外提供 ReadCalendarSettings（阅读日历设置模型，UserDefaults 持久化）
 * [POS]: ReadCalendar 子功能设置状态，供 ViewModel 消费过滤参数与事件条数量上限
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 阅读日历设置

/// 阅读日历设置状态源，负责持久化事件过滤与交互偏好，不承担页面数据查询。
@MainActor
@Observable
/// 阅读日历设置状态容器，负责本地持久化与业务规则校验。
final class ReadCalendarSettings {
    var excludeReadTiming: Bool {
        didSet { save(excludeReadTiming, forKey: Self.keyReadTiming) }
    }
    var excludeNoteRecord: Bool {
        didSet { save(excludeNoteRecord, forKey: Self.keyNoteRecord) }
    }
    var excludeCheckIn: Bool {
        didSet { save(excludeCheckIn, forKey: Self.keyCheckIn) }
    }
    var dayEventCount: Int {
        didSet { save(dayEventCount, forKey: Self.keyDayEventCount) }
    }
    var isHapticsEnabled: Bool {
        didSet { save(isHapticsEnabled, forKey: Self.keyHapticsEnabled) }
    }
    var isStreakHintEnabled: Bool {
        didSet { save(isStreakHintEnabled, forKey: Self.keyStreakHintEnabled) }
    }

    /// 从 UserDefaults 恢复阅读日历筛选与交互配置，并应用默认值兜底。
    init() {
        let defaults = UserDefaults.standard
        self.excludeReadTiming = defaults.bool(forKey: Self.keyReadTiming)
        self.excludeNoteRecord = defaults.bool(forKey: Self.keyNoteRecord)
        self.excludeCheckIn = defaults.bool(forKey: Self.keyCheckIn)
        self.isHapticsEnabled = defaults.object(forKey: Self.keyHapticsEnabled) as? Bool ?? true
        self.isStreakHintEnabled = defaults.object(forKey: Self.keyStreakHintEnabled) as? Bool ?? true

        let stored = defaults.integer(forKey: Self.keyDayEventCount)
        self.dayEventCount = Self.dayEventCountRange.contains(stored) ? stored : Self.defaultDayEventCount
    }

    // MARK: - 排除集合

    var excludedEventTypes: Set<ReadCalendarEventType> {
        var result = Set<ReadCalendarEventType>()
        if excludeReadTiming { result.insert(.readTiming) }
        if excludeNoteRecord {
            result.insert(.note)
            result.insert(.relevant)
            result.insert(.review)
        }
        if excludeCheckIn { result.insert(.checkIn) }
        return result
    }

    /// 阅读行为判定规则：阅读计时和笔记记录至少保留一个
    var isReadBehaviorRuleValid: Bool {
        !(excludeReadTiming && excludeNoteRecord)
    }

    // MARK: - 常量

    static let dayEventCountRange = 4...10
    static let defaultDayEventCount = 6

    private static let keyReadTiming = "rcExcludeReadTiming"
    private static let keyNoteRecord = "rcExcludeNoteRecord"
    private static let keyCheckIn = "rcExcludeCheckIn"
    private static let keyDayEventCount = "rcDayEventCount"
    private static let keyHapticsEnabled = "rcHapticsEnabled"
    private static let keyStreakHintEnabled = "rcStreakHintEnabled"

    /// 执行save对应的数据处理步骤，并返回当前流程需要的结果。
    private func save(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// 执行save对应的数据处理步骤，并返回当前流程需要的结果。
    private func save(_ value: Int, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
