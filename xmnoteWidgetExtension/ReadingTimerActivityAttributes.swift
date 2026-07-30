import ActivityKit
import Foundation

/**
 * [INPUT]: 依赖 ActivityKit 的 ActivityAttributes，与 App Target 的 ReadingTimerActivityAttributes 字段保持一致
 * [OUTPUT]: 对外提供 Widget Extension 内部使用的 ReadingTimerActivityAttributes
 * [POS]: Widget Extension 的 Live Activity 数据契约，供 ActivityConfiguration 匹配 App 创建的阅读计时活动
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// Widget Extension 内的阅读计时 Live Activity 数据契约，必须与 App Target 同名同字段。
struct ReadingTimerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let status: String
        /// 系统界面直接展示的秒数：正计时为已读时长，倒计时为剩余时长。
        let elapsedSeconds: Int64
        let elapsedText: String
        let isCountdown: Bool
        let timerStartDate: Date
        let bookCoverSnapshotName: String?
        let updatedAt: Date
        /// 灵动岛控制按钮的视觉版本号；Widget 仅用它区分真实控制事件，避免普通计时刷新重复触发按钮动画。
        let controlRevision: Int64?
        let lastControlAction: String?
        let controlRequestedAt: Date?

        var isRunning: Bool { status == "running" }
        var isPaused: Bool { status == "paused" }
        var isPendingSave: Bool { status == "pendingSave" }
        var effectiveControlRevision: Int64 { controlRevision ?? 0 }
    }

    let recordId: Int64
    let bookId: Int64
    let bookName: String
    let author: String
    let bookCoverURL: String?
}
