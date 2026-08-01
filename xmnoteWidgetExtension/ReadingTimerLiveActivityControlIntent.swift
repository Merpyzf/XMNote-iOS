import AppIntents
import Foundation

/**
 * [INPUT]: 依赖 AppIntents/ActivityKit 的 LiveActivityIntent，依赖 Widget 按钮传入阅读计时记录 ID 与控制动作
 * [OUTPUT]: 对外提供 Widget Extension 可编码的 ReadingTimerLiveActivityControlIntent
 * [POS]: Widget Extension 的灵动岛交互声明，真实写入由 App Target 同名 Intent 在 App 进程中完成
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// Widget 侧的灵动岛计时控制动作声明，与 App Target 同名同 case 以保持系统交互编码一致。
nonisolated enum ReadingTimerLiveActivityControlAction: String, AppEnum, Sendable {
    case pause
    case resume
    case stop

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "阅读计时控制操作")
    }

    static var caseDisplayRepresentations: [ReadingTimerLiveActivityControlAction: DisplayRepresentation] {
        [
            .pause: DisplayRepresentation(title: "暂停"),
            .resume: DisplayRepresentation(title: "继续"),
            .stop: DisplayRepresentation(title: "结束")
        ]
    }
}

/// Widget 侧的按钮 Intent 声明，用于让 `Button(intent:)` 生成可点击的 Live Activity 控件。
struct ReadingTimerLiveActivityControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "控制阅读计时"
    static var description = IntentDescription("暂停、继续或结束当前阅读计时。")
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false

    @Parameter(title: "记录 ID")
    var recordId: String

    @Parameter(title: "操作")
    var action: ReadingTimerLiveActivityControlAction

    init() {
        recordId = ""
        action = .pause
    }

    init(recordId: Int64, action: ReadingTimerLiveActivityControlAction) {
        self.recordId = String(recordId)
        self.action = action
    }

    /// Widget Extension 仅提供交互元数据；采用 LiveActivityIntent 后系统会把真实执行交给 App 进程。
    /// 并发语义：该兜底实现不访问数据库、不修改状态，避免 Widget Extension 直接承担 Repository 写入职责。
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Widget 侧的暂停按钮 Intent 声明；真实数据库写入由 App Target 同名 Intent 执行。
struct ReadingTimerPauseLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "暂停阅读计时"
    static var description = IntentDescription("暂停当前阅读计时。")
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false

    @Parameter(title: "记录 ID")
    var recordId: String

    init() {
        recordId = ""
    }

    init(recordId: Int64) {
        self.recordId = String(recordId)
    }

    /// Widget Extension 仅提供交互元数据；采用 LiveActivityIntent 后系统会把真实执行交给 App 进程。
    /// 并发语义：该兜底实现不访问数据库、不修改状态，避免 Widget Extension 直接承担 Repository 写入职责。
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Widget 侧的继续按钮 Intent 声明；真实数据库写入由 App Target 同名 Intent 执行。
struct ReadingTimerResumeLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "继续阅读计时"
    static var description = IntentDescription("继续当前阅读计时。")
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false

    @Parameter(title: "记录 ID")
    var recordId: String

    init() {
        recordId = ""
    }

    init(recordId: Int64) {
        self.recordId = String(recordId)
    }

    /// Widget Extension 仅提供交互元数据；采用 LiveActivityIntent 后系统会把真实执行交给 App 进程。
    /// 并发语义：该兜底实现不访问数据库、不修改状态，避免 Widget Extension 直接承担 Repository 写入职责。
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Widget 侧的结束按钮 Intent 声明；真实数据库写入由 App Target 同名 Intent 执行。
struct ReadingTimerStopLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "结束阅读计时"
    static var description = IntentDescription("结束当前阅读计时并等待保存。")
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true

    @Parameter(title: "记录 ID")
    var recordId: String

    init() {
        recordId = ""
    }

    init(recordId: Int64) {
        self.recordId = String(recordId)
    }

    /// Widget Extension 仅提供交互元数据；采用 LiveActivityIntent 后系统会把真实执行交给 App 进程。
    /// 并发语义：该兜底实现不访问数据库、不修改状态，避免 Widget Extension 直接承担 Repository 写入职责。
    func perform() async throws -> some IntentResult {
        .result()
    }
}
