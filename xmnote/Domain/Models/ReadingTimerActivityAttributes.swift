import ActivityKit
import Foundation

/**
 * [INPUT]: 依赖 ActivityKit 的 ActivityAttributes 与阅读计时状态语义
 * [OUTPUT]: 对外提供 ReadingTimerActivityAttributes，作为 App 与 Widget Extension 共享的 Live Activity 数据契约
 * [POS]: Domain/Models 层阅读计时系统状态模型，供 ActivityKit 创建、更新与 WidgetKit 渲染灵动岛/锁屏状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读计时 Live Activity 静态属性和动态状态，字段保持轻量，避免把 App 内表单状态泄露到系统界面。
struct ReadingTimerActivityAttributes: ActivityAttributes {
    /// Live Activity 动态内容状态；Widget 使用计时语义渲染正计时或倒计时，并读取封面快照渲染灵动岛身份信息。
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
