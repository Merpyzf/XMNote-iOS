/**
 * [INPUT]: 依赖 Foundation 值类型与 Android 对齐的 read_time_record 状态语义
 * [OUTPUT]: 对外提供 ReadingTimerRecordStatus、ReadingTimerSession、ReadingTimerBookContext 与计时保存/补录输入模型
 * [POS]: Domain/Models 层阅读计时领域模型，被 Repository、ViewModel、页面与 Live Activity 状态编排共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 阅读计时记录状态，数值严格对齐 Android `ReadTimeRecordStatus` 与 `read_time_record.status`。
nonisolated enum ReadingTimerRecordStatus: Int64, CaseIterable, Codable, Hashable, Sendable {
    case running = 0
    case paused = 1
    case stoppedPendingSave = 2
    case finished = 3

    /// 未完成状态需要在 App 重启或回前台时提供恢复/放弃入口。
    var isUnfinished: Bool {
        switch self {
        case .running, .paused, .stoppedPendingSave:
            return true
        case .finished:
            return false
        }
    }

    /// 未完成状态集合，对应 Android 仍需恢复或处理的计时记录。
    static var unfinishedCases: [ReadingTimerRecordStatus] {
        [.running, .paused, .stoppedPendingSave]
    }
}

/// 阅读补录模式，面向 iOS 文案映射为“按日期记录 / 按开始结束记录”。
nonisolated enum ReadingTimerSupplementMode: String, Codable, Hashable, Sendable {
    case dateDuration
    case timeRange
}

/// 阅读计时书籍上下文，集中提供计时页、结束确认与补录页需要的书籍基础信息。
nonisolated struct ReadingTimerBookContext: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let author: String
    let coverURL: String
    let readStatusId: Int64
    let readPosition: Double
    let totalPosition: Int64
    let totalPagination: Int64
    let currentPositionUnit: Int64
    let positionUnit: Int64

    /// 当前书籍默认记录进度单位，缺省回退到页码，避免异常数据阻断保存链路。
    var resolvedPositionUnit: BookEntryProgressUnit {
        BookEntryProgressUnit(rawValue: positionUnit) ?? .pagination
    }
}

/// 阅读计时会话快照，承接 `read_time_record` 与关联书籍的当前状态。
nonisolated struct ReadingTimerSession: Identifiable, Equatable, Sendable {
    let id: Int64
    let book: ReadingTimerBookContext
    let startTime: Date?
    let endTime: Date?
    let interruptTime: Date?
    let elapsedSeconds: Int64
    let countdownSeconds: Int64
    let pausedDurationMillis: Int64
    let isPaused: Bool
    let status: ReadingTimerRecordStatus
    let position: Double
    let recordedPositionUnit: Int64?
    let fuzzyReadDate: Date?
    let insight: String
    let createdDate: Date?
    let updatedDate: Date?
}

/// 计时运行中持久化快照，供暂停、继续、停止和后台校准统一落库。
nonisolated struct ReadingTimerSnapshotInput: Sendable {
    let recordId: Int64
    let status: ReadingTimerRecordStatus
    let elapsedSeconds: Int64
    let pausedDurationMillis: Int64
    let expectedStatuses: [ReadingTimerRecordStatus]
    let interruptAt: Date?
    let endAt: Date?

    /// 生成一次运行状态写入，调用方必须声明可接受的原状态，避免旧快照覆盖更新后的状态机。
    init(
        recordId: Int64,
        status: ReadingTimerRecordStatus,
        elapsedSeconds: Int64,
        pausedDurationMillis: Int64,
        expectedStatuses: [ReadingTimerRecordStatus],
        interruptAt: Date?,
        endAt: Date? = nil
    ) {
        self.recordId = recordId
        self.status = status
        self.elapsedSeconds = elapsedSeconds
        self.pausedDurationMillis = pausedDurationMillis
        self.expectedStatuses = expectedStatuses
        self.interruptAt = interruptAt
        self.endAt = endAt
    }
}

/// 结束计时后的保存输入，负责把待保存记录推进到完成状态并写入补充信息。
nonisolated struct ReadingTimerFinishInput: Sendable {
    let recordId: Int64
    let endAt: Date
    let elapsedSeconds: Int64
    let pausedDurationMillis: Int64
    let position: Double?
    let insight: String
    let markReadDone: Bool

    /// 收口结束确认 Sheet 的保存字段，位置为空时不会修改书籍阅读位置。
    init(
        recordId: Int64,
        endAt: Date,
        elapsedSeconds: Int64,
        pausedDurationMillis: Int64,
        position: Double?,
        insight: String,
        markReadDone: Bool
    ) {
        self.recordId = recordId
        self.endAt = endAt
        self.elapsedSeconds = elapsedSeconds
        self.pausedDurationMillis = pausedDurationMillis
        self.position = position
        self.insight = insight
        self.markReadDone = markReadDone
    }
}

/// 阅读补录保存输入，支持日期 + 时长和精确开始/结束两种 Android 对齐写入模式。
nonisolated struct ReadingTimerSupplementInput: Sendable {
    let bookId: Int64
    let mode: ReadingTimerSupplementMode
    let readDate: Date?
    let startAt: Date?
    let endAt: Date?
    let elapsedSeconds: Int64
    let position: Double?
    let insight: String
    let markReadDone: Bool

    /// 收口补录页字段，Repository 会根据模式决定写入 `fuzzy_read_date` 还是 `start_time/end_time`。
    init(
        bookId: Int64,
        mode: ReadingTimerSupplementMode,
        readDate: Date?,
        startAt: Date?,
        endAt: Date?,
        elapsedSeconds: Int64,
        position: Double?,
        insight: String,
        markReadDone: Bool
    ) {
        self.bookId = bookId
        self.mode = mode
        self.readDate = readDate
        self.startAt = startAt
        self.endAt = endAt
        self.elapsedSeconds = elapsedSeconds
        self.position = position
        self.insight = insight
        self.markReadDone = markReadDone
    }
}

/// 阅读计时仓储错误，向 ViewModel 提供可本地化、可区分的业务失败原因。
nonisolated enum ReadingTimerError: LocalizedError, Equatable, Sendable {
    case bookNotFound
    case activeSessionExists
    case sessionNotFound
    case invalidDuration
    case invalidTimeRange
    case invalidReadPosition(String)
    case staleSessionState
    case unsupportedStatus(Int64)

    var errorDescription: String? {
        switch self {
        case .bookNotFound:
            return "未找到这本书"
        case .activeSessionExists:
            return "已有一段未完成的阅读计时"
        case .sessionNotFound:
            return "未找到这段阅读计时"
        case .invalidDuration:
            return "阅读时长无效"
        case .invalidTimeRange:
            return "开始时间和结束时间无效"
        case .invalidReadPosition(let message):
            return message
        case .staleSessionState:
            return "计时状态已变化，请以最新状态为准"
        case .unsupportedStatus(let status):
            return "暂不支持的计时状态：\(status)"
        }
    }
}

extension Notification.Name {
    /// 阅读计时记录完成、补录或放弃后发出，供 KeepAlive 页面刷新统计消费视图。
    static let readingTimerRecordsDidChange = Notification.Name("readingTimerRecordsDidChange")
}
