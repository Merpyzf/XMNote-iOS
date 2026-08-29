import Foundation

/**
 * [INPUT]: 依赖 ReadCalendarEventType 与可注入 UserDefaults 提供事件类型和偏好存储
 * [OUTPUT]: 对外提供 ReadCalendarSettings、阅读行为设置项与读完标记配置（UserDefaults 持久化）
 * [POS]: ReadCalendar 子功能设置状态，统一约束六类事件过滤、读完标记与触感配置
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 阅读日历设置

/// 阅读日历可配置的六类行为，集中提供展示顺序与核心规则归属。
enum ReadCalendarBehaviorSetting: CaseIterable, Identifiable {
    case readTiming
    case note
    case relevant
    case review
    case readDone
    case checkIn

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .readTiming:
            "阅读计时"
        case .note:
            "书摘记录"
        case .relevant:
            "相关内容"
        case .review:
            "书评记录"
        case .readDone:
            "读完事件"
        case .checkIn:
            "阅读打卡"
        }
    }

    var isCoreBehavior: Bool {
        switch self {
        case .readTiming, .note, .relevant, .review:
            true
        case .readDone, .checkIn:
            false
        }
    }
}

/// 阅读日历设置状态源，负责持久化事件过滤与交互偏好，不承担页面数据查询。
@MainActor
@Observable
/// 阅读日历设置状态容器，负责本地持久化与业务规则校验。
final class ReadCalendarSettings {
    private let userDefaults: UserDefaults

    private(set) var excludeReadTiming: Bool {
        didSet { save(excludeReadTiming, forKey: Self.keyReadTiming) }
    }
    private(set) var excludeNote: Bool {
        didSet { save(excludeNote, forKey: Self.keyNote) }
    }
    private(set) var excludeRelevant: Bool {
        didSet { save(excludeRelevant, forKey: Self.keyRelevant) }
    }
    private(set) var excludeReview: Bool {
        didSet { save(excludeReview, forKey: Self.keyReview) }
    }
    private(set) var excludeReadDone: Bool {
        didSet { save(excludeReadDone, forKey: Self.keyReadDone) }
    }
    private(set) var excludeCheckIn: Bool {
        didSet { save(excludeCheckIn, forKey: Self.keyCheckIn) }
    }
    var dayEventCount: Int {
        didSet { save(dayEventCount, forKey: Self.keyDayEventCount) }
    }
    var isHapticsEnabled: Bool {
        didSet { save(isHapticsEnabled, forKey: Self.keyHapticsEnabled) }
    }
    var doneMarkerStyle: ReadCalendarDoneMarkerStyle {
        didSet { save(doneMarkerStyle.rawValue, forKey: Self.keyDoneMarkerStyle) }
    }
    var doneEmojiAssetName: String {
        didSet { save(doneEmojiAssetName, forKey: Self.keyDoneEmojiAssetName) }
    }

    /// 从 UserDefaults 恢复阅读日历筛选与交互配置，并应用默认值兜底。
    convenience init() {
        self.init(userDefaults: .standard)
    }

#if DEBUG
    /// 为隔离 Sheet 校准环境读取临时偏好 suite，避免预览操作改写正式设置。
    convenience init(sheetPreviewUserDefaults: UserDefaults) {
        self.init(userDefaults: sheetPreviewUserDefaults)
    }
#endif

    private init(userDefaults defaults: UserDefaults) {
        self.userDefaults = defaults
        let legacyExcludeNoteRecord = defaults.bool(forKey: Self.legacyKeyNoteRecord)
        var storedExcludeReadTiming = defaults.bool(forKey: Self.keyReadTiming)
        let storedExcludeNote = defaults.object(forKey: Self.keyNote) as? Bool ?? legacyExcludeNoteRecord
        let storedExcludeRelevant = defaults.object(forKey: Self.keyRelevant) as? Bool ?? legacyExcludeNoteRecord
        let storedExcludeReview = defaults.object(forKey: Self.keyReview) as? Bool ?? legacyExcludeNoteRecord

        if storedExcludeReadTiming && storedExcludeNote && storedExcludeRelevant && storedExcludeReview {
            storedExcludeReadTiming = false
            defaults.set(false, forKey: Self.keyReadTiming)
        }

        self.excludeReadTiming = storedExcludeReadTiming
        self.excludeNote = storedExcludeNote
        self.excludeRelevant = storedExcludeRelevant
        self.excludeReview = storedExcludeReview
        self.excludeReadDone = defaults.bool(forKey: Self.keyReadDone)
        self.excludeCheckIn = defaults.bool(forKey: Self.keyCheckIn)
        self.isHapticsEnabled = defaults.object(forKey: Self.keyHapticsEnabled) as? Bool ?? true
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

    /// 返回指定阅读行为当前是否参与日历统计与展示。
    func isBehaviorEnabled(_ behavior: ReadCalendarBehaviorSetting) -> Bool {
        switch behavior {
        case .readTiming:
            !excludeReadTiming
        case .note:
            !excludeNote
        case .relevant:
            !excludeRelevant
        case .review:
            !excludeReview
        case .readDone:
            !excludeReadDone
        case .checkIn:
            !excludeCheckIn
        }
    }

    /// 修改阅读行为开关；拒绝关闭最后一个核心行为，并保持持久化状态不变。
    @discardableResult
    func setBehavior(_ behavior: ReadCalendarBehaviorSetting, isEnabled: Bool) -> Bool {
        guard isBehaviorEnabled(behavior) != isEnabled else { return true }
        if !isEnabled,
           behavior.isCoreBehavior,
           enabledCoreBehaviorCount <= 1 {
            return false
        }

        let shouldExclude = !isEnabled
        switch behavior {
        case .readTiming:
            excludeReadTiming = shouldExclude
        case .note:
            excludeNote = shouldExclude
        case .relevant:
            excludeRelevant = shouldExclude
        case .review:
            excludeReview = shouldExclude
        case .readDone:
            excludeReadDone = shouldExclude
        case .checkIn:
            excludeCheckIn = shouldExclude
        }
        return true
    }

    /// 阅读行为判定规则：四类核心行为至少保留一个。
    var isReadBehaviorRuleValid: Bool {
        !(excludeReadTiming && excludeNote && excludeRelevant && excludeReview)
    }

    private var enabledCoreBehaviorCount: Int {
        ReadCalendarBehaviorSetting.allCases.lazy
            .filter(\.isCoreBehavior)
            .filter(isBehaviorEnabled)
            .count
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
    private static let keyDoneMarkerStyle = "rcDoneMarkerStyle"
    private static let keyDoneEmojiAssetName = "rcDoneEmojiAssetName"

    private func save(_ value: Bool, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }

    private func save(_ value: Int, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }

    private func save(_ value: String, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }
}

/// 阅读日历读完标记样式，对齐 Android 勾选与图案两种模式。
enum ReadCalendarDoneMarkerStyle: String, CaseIterable, Identifiable {
    case checkmark
    case emoji

    var id: String { rawValue }

    var title: String { self == .checkmark ? "对勾" : "Emoji" }
}
