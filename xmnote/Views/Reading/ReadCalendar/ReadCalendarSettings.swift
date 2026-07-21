import Foundation

/**
 * [INPUT]: 依赖 ReadCalendarEventType 提供事件类型枚举
 * [OUTPUT]: 对外提供 ReadCalendarSettings 与读完标记配置（UserDefaults 持久化）
 * [POS]: ReadCalendar 子功能设置状态，供 ViewModel 消费六类事件过滤、标记与交互配置
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
    var excludeNote: Bool {
        didSet { save(excludeNote, forKey: Self.keyNote) }
    }
    var excludeRelevant: Bool {
        didSet { save(excludeRelevant, forKey: Self.keyRelevant) }
    }
    var excludeReview: Bool {
        didSet { save(excludeReview, forKey: Self.keyReview) }
    }
    var excludeReadDone: Bool {
        didSet { save(excludeReadDone, forKey: Self.keyReadDone) }
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
    var doneMarkerStyle: ReadCalendarDoneMarkerStyle {
        didSet { save(doneMarkerStyle.rawValue, forKey: Self.keyDoneMarkerStyle) }
    }
    var doneEmojiAssetName: String {
        didSet { save(doneEmojiAssetName, forKey: Self.keyDoneEmojiAssetName) }
    }

    /// 从 UserDefaults 恢复阅读日历筛选与交互配置，并应用默认值兜底。
    init() {
        let defaults = UserDefaults.standard
        self.excludeReadTiming = defaults.bool(forKey: Self.keyReadTiming)
        let legacyExcludeNoteRecord = defaults.bool(forKey: Self.legacyKeyNoteRecord)
        self.excludeNote = defaults.object(forKey: Self.keyNote) as? Bool ?? legacyExcludeNoteRecord
        self.excludeRelevant = defaults.object(forKey: Self.keyRelevant) as? Bool ?? legacyExcludeNoteRecord
        self.excludeReview = defaults.object(forKey: Self.keyReview) as? Bool ?? legacyExcludeNoteRecord
        self.excludeReadDone = defaults.bool(forKey: Self.keyReadDone)
        self.excludeCheckIn = defaults.bool(forKey: Self.keyCheckIn)
        self.isHapticsEnabled = defaults.object(forKey: Self.keyHapticsEnabled) as? Bool ?? true
        self.isStreakHintEnabled = defaults.object(forKey: Self.keyStreakHintEnabled) as? Bool ?? true
        self.doneMarkerStyle = ReadCalendarDoneMarkerStyle(
            rawValue: defaults.string(forKey: Self.keyDoneMarkerStyle) ?? ""
        ) ?? .emoji
        let storedEmoji = defaults.string(forKey: Self.keyDoneEmojiAssetName) ?? ""
        self.doneEmojiAssetName = Self.doneEmojiAssetNames.contains(storedEmoji)
            ? storedEmoji
            : Self.defaultDoneEmojiAssetName

        let stored = defaults.integer(forKey: Self.keyDayEventCount)
        self.dayEventCount = Self.dayEventCountRange.contains(stored) ? stored : Self.defaultDayEventCount
    }

    // MARK: - 排除集合

    var excludedEventTypes: Set<ReadCalendarEventType> {
        var result = Set<ReadCalendarEventType>()
        if excludeReadTiming { result.insert(.readTiming) }
        if excludeNote { result.insert(.note) }
        if excludeRelevant { result.insert(.relevant) }
        if excludeReview { result.insert(.review) }
        if excludeReadDone { result.insert(.readDone) }
        if excludeCheckIn { result.insert(.checkIn) }
        return result
    }

    /// 阅读行为判定规则：阅读计时和笔记记录至少保留一个
    var isReadBehaviorRuleValid: Bool {
        !(excludeReadTiming && excludeNote && excludeRelevant && excludeReview)
    }

    // MARK: - 常量

    static let dayEventCountRange = 4...10
    static let defaultDayEventCount = 6
    static let doneEmojiAssetNames = [
        "ReadCalendarDonePartyPopper",
        "ReadCalendarDoneConfettiBall",
        "ReadCalendarDoneGlowingStar",
        "ReadCalendarDonePartyingFace",
        "ReadCalendarDoneSmilingFaceWithHearts",
        "ReadCalendarDoneEyes",
        "ReadCalendarDoneBlossom",
        "ReadCalendarDoneCherryBlossom",
        "ReadCalendarDoneBouquet",
        "ReadCalendarDoneLollipop",
        "ReadCalendarDoneTriangularFlag",
        "ReadCalendarDoneBalloon"
    ]
    static let defaultDoneEmojiAssetName = "ReadCalendarDonePartyPopper"

    private static let keyReadTiming = "rcExcludeReadTiming"
    private static let legacyKeyNoteRecord = "rcExcludeNoteRecord"
    private static let keyNote = "rcExcludeNote"
    private static let keyRelevant = "rcExcludeRelevant"
    private static let keyReview = "rcExcludeReview"
    private static let keyReadDone = "rcExcludeReadDone"
    private static let keyCheckIn = "rcExcludeCheckIn"
    private static let keyDayEventCount = "rcDayEventCount"
    private static let keyHapticsEnabled = "rcHapticsEnabled"
    private static let keyStreakHintEnabled = "rcStreakHintEnabled"
    private static let keyDoneMarkerStyle = "rcDoneMarkerStyle"
    private static let keyDoneEmojiAssetName = "rcDoneEmojiAssetName"

    private func save(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func save(_ value: Int, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func save(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// 阅读日历读完标记样式，对齐 Android 勾选与图案两种模式。
enum ReadCalendarDoneMarkerStyle: String, CaseIterable, Identifiable {
    case checkmark
    case emoji

    var id: String { rawValue }

    var title: String { self == .checkmark ? "勾选" : "图案" }
}
