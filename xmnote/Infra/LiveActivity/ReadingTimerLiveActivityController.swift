import ActivityKit
import Foundation
import OSLog

/**
 * [INPUT]: 依赖 ActivityKit 管理 ReadingTimerActivityAttributes，依赖 ReadingTimerSession 提供计时状态快照
 * [OUTPUT]: 对外提供 ReadingTimerLiveActivityController，封装阅读计时 Live Activity 的开始、更新与结束
 * [POS]: Infra/LiveActivity 系统桥接层，被 ReadingTimerViewModel 调用以同步锁屏与灵动岛状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
/// 阅读计时 Live Activity 控制器，负责把 App 内计时状态投射到锁屏与灵动岛。
final class ReadingTimerLiveActivityController {
    static let shared = ReadingTimerLiveActivityController()

    private let logger = Logger(subsystem: "com.merpyzf.xmnote", category: "ReadingTimerLiveActivity")
    private let coverSnapshotStore: ReadingTimerLiveActivityCoverSnapshotStore

    private init() {
        coverSnapshotStore = ReadingTimerLiveActivityCoverSnapshotStore.shared
    }

    /// 用户明确开始阅读后创建 Live Activity；若系统关闭 Live Activities 或已有同记录活动，则退化为静默无操作。
    /// 并发语义：方法固定在 MainActor；ActivityKit 请求失败只影响系统状态展示，不回滚 App 内计时记录。
    func start(session: ReadingTimerSession, elapsedSeconds: Int64) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity(for: session.id) == nil else {
            await update(session: session, elapsedSeconds: elapsedSeconds)
            return
        }

        let bookCoverURL = normalizedCoverURLString(from: session.book.coverURL)
        let bookCoverSnapshotName = await coverSnapshotStore.prepareSnapshotName(
            bookId: session.book.id,
            coverURLString: bookCoverURL
        )
        let attributes = ReadingTimerActivityAttributes(
            recordId: session.id,
            bookId: session.book.id,
            bookName: session.book.name,
            author: session.book.author,
            bookCoverURL: bookCoverURL
        )
        let content = ActivityContent(
            state: makeState(
                session: session,
                elapsedSeconds: elapsedSeconds,
                bookCoverSnapshotName: bookCoverSnapshotName
            ),
            staleDate: nil
        )
        do {
            _ = try Activity<ReadingTimerActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            return
        }
    }

    /// 更新当前阅读计时 Live Activity；恢复或前台刷新时若活动已存在则只更新，不主动新建。
    /// 并发语义：ActivityKit 更新异步执行；失败时忽略，下一次状态变化会再次尝试同步。
    func update(session: ReadingTimerSession, elapsedSeconds: Int64) async {
        let startedAt = Date()
        guard let activity = activity(for: session.id) else { return }
        let currentState = activity.content.state
        let coverURLString = normalizedCoverURLString(from: session.book.coverURL)
        let canSkipBeforeCoverPreparation = currentState.bookCoverSnapshotName != nil || coverURLString == nil
        if canSkipBeforeCoverPreparation {
            let proposedState = makeState(
                session: session,
                elapsedSeconds: elapsedSeconds,
                bookCoverSnapshotName: currentState.bookCoverSnapshotName,
                controlSource: currentState
            )
            if Self.shouldSkipStandardUpdate(current: currentState, proposed: proposedState) {
                logger.notice("Skip Live Activity standard update because visual state is unchanged. recordId=\(session.id, privacy: .public), status=\(session.status.rawValue, privacy: .public), totalMs=\(Self.millisecondsString(since: startedAt), privacy: .public)")
                return
            }
        }
        let bookCoverSnapshotName = await coverSnapshotStore.prepareSnapshotName(
            bookId: session.book.id,
            coverURLString: coverURLString
        )
        let coverPreparedAt = Date()
        let nextState = makeState(
            session: session,
            elapsedSeconds: elapsedSeconds,
            bookCoverSnapshotName: bookCoverSnapshotName,
            controlSource: currentState
        )
        if Self.shouldSkipStandardUpdate(current: currentState, proposed: nextState) {
            logger.notice("Skip Live Activity standard update after cover preparation because visual state is unchanged. recordId=\(session.id, privacy: .public), status=\(session.status.rawValue, privacy: .public), coverMs=\(Self.millisecondsString(from: startedAt, to: coverPreparedAt), privacy: .public), totalMs=\(Self.millisecondsString(since: startedAt), privacy: .public)")
            return
        }
        let content = ActivityContent(
            state: nextState,
            staleDate: nil
        )
        await activity.update(content)
        logger.notice("Live Activity standard update finished. recordId=\(session.id, privacy: .public), status=\(session.status.rawValue, privacy: .public), coverMs=\(Self.millisecondsString(from: startedAt, to: coverPreparedAt), privacy: .public), totalMs=\(Self.millisecondsString(since: startedAt), privacy: .public)")
    }

    /// 响应灵动岛控制按钮时快速更新系统界面，沿用当前封面快照以避免图片准备阻塞按钮反馈。
    /// 并发语义：方法运行在 MainActor，只向 ActivityKit 推送显示状态；数据库真相由调用方继续落库并在成功或失败后校准。
    func updateForControl(
        session: ReadingTimerSession,
        elapsedSeconds: Int64,
        action: ReadingTimerLiveActivityControlAction? = nil,
        reason: String
    ) async {
        let startedAt = Date()
        guard let activity = activity(for: session.id) else {
            logger.info("Skip Live Activity control update because activity is missing. recordId=\(session.id, privacy: .public), status=\(session.status.rawValue, privacy: .public), reason=\(reason, privacy: .public)")
            return
        }
        let currentState = activity.content.state
        let currentSnapshotName = currentState.bookCoverSnapshotName
        let content = ActivityContent(
            state: makeState(
                session: session,
                elapsedSeconds: elapsedSeconds,
                bookCoverSnapshotName: currentSnapshotName,
                controlSource: currentState,
                controlEvent: action
            ),
            staleDate: nil
        )
        await activity.update(content)
        logger.notice("Live Activity control update finished. recordId=\(session.id, privacy: .public), status=\(session.status.rawValue, privacy: .public), reason=\(reason, privacy: .public), preservedCover=\(currentSnapshotName != nil, privacy: .public), totalMs=\(Self.millisecondsString(since: startedAt), privacy: .public)")
    }

    /// 在数据库读取前根据当前 Activity state 先推进按钮视觉状态，让暂停/继续图标立即响应用户点击。
    /// 并发语义：方法运行在 MainActor；只读写 ActivityKit 当前动态状态，不访问数据库，调用方负责随后落库并按真实状态校准或回滚。
    func updateForControlAction(
        recordId: Int64,
        action: ReadingTimerLiveActivityControlAction,
        reason: String
    ) async -> (
        previous: ReadingTimerActivityAttributes.ContentState,
        applied: ReadingTimerActivityAttributes.ContentState
    )? {
        let startedAt = Date()
        guard let activity = activity(for: recordId) else {
            logger.info("Skip Live Activity immediate control update because activity is missing. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), reason=\(reason, privacy: .public)")
            return nil
        }
        let previousState = activity.content.state
        let now = Date()
        guard let appliedState = Self.immediateState(
            from: previousState,
            action: action,
            at: now
        ) else {
            logger.info("Skip Live Activity immediate control update because transition is invalid. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), status=\(previousState.status, privacy: .public), reason=\(reason, privacy: .public)")
            return nil
        }

        let content = ActivityContent(state: appliedState, staleDate: nil)
        await activity.update(content)
        logger.notice("Live Activity immediate control update finished. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), fromStatus=\(previousState.status, privacy: .public), toStatus=\(appliedState.status, privacy: .public), reason=\(reason, privacy: .public), totalMs=\(Self.millisecondsString(since: startedAt), privacy: .public)")
        return (previousState, appliedState)
    }

    /// 恢复一次预更新前的 Activity state，用于数据库准备失败等无法读取真实状态的兜底路径。
    /// 并发语义：方法运行在 MainActor；只恢复调用方传入的 ActivityKit 状态，不修改数据库。
    func restoreControlState(
        recordId: Int64,
        state: ReadingTimerActivityAttributes.ContentState,
        reason: String
    ) async {
        let startedAt = Date()
        guard let activity = activity(for: recordId) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
        logger.notice("Live Activity control state restored. recordId=\(recordId, privacy: .public), status=\(state.status, privacy: .public), reason=\(reason, privacy: .public), totalMs=\(Self.millisecondsString(since: startedAt), privacy: .public)")
    }

    /// 结束指定记录对应的 Live Activity；保存和放弃都会立即移除系统状态，避免用户看到过期计时。
    /// 并发语义：结束请求异步发送；即使系统已清理活动也不会抛给业务层。
    func end(recordId: Int64, finalSession: ReadingTimerSession? = nil, elapsedSeconds: Int64 = 0) async {
        guard let activity = activity(for: recordId) else { return }
        if let finalSession {
            let bookCoverSnapshotName = await coverSnapshotStore.prepareSnapshotName(
                bookId: finalSession.book.id,
                coverURLString: normalizedCoverURLString(from: finalSession.book.coverURL)
            )
            let content = ActivityContent(
                state: makeState(
                    session: finalSession,
                    elapsedSeconds: elapsedSeconds,
                    bookCoverSnapshotName: bookCoverSnapshotName
                ),
                staleDate: nil
            )
            await activity.end(content, dismissalPolicy: .immediate)
        } else {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func activity(for recordId: Int64) -> Activity<ReadingTimerActivityAttributes>? {
        Activity<ReadingTimerActivityAttributes>.activities.first { activity in
            activity.attributes.recordId == recordId
        }
    }

    private func makeState(
        session: ReadingTimerSession,
        elapsedSeconds: Int64,
        bookCoverSnapshotName: String?,
        controlSource: ReadingTimerActivityAttributes.ContentState? = nil,
        controlEvent: ReadingTimerLiveActivityControlAction? = nil
    ) -> ReadingTimerActivityAttributes.ContentState {
        let statusText: String
        switch session.status {
        case .running:
            statusText = "running"
        case .paused:
            statusText = "paused"
        case .stoppedPendingSave:
            statusText = "pendingSave"
        case .finished:
            statusText = "finished"
        }
        let now = Date()
        let displaySeconds = Self.displaySeconds(for: session, elapsedSeconds: elapsedSeconds)
        let timerDate = session.countdownSeconds > 0
            ? now.addingTimeInterval(Double(max(0, displaySeconds)))
            : now.addingTimeInterval(-Double(max(0, displaySeconds)))
        let previousRevision = controlSource?.effectiveControlRevision ?? 0
        let controlRevision = controlEvent == nil ? previousRevision : previousRevision + 1
        return ReadingTimerActivityAttributes.ContentState(
            status: statusText,
            elapsedSeconds: displaySeconds,
            elapsedText: Self.elapsedText(seconds: displaySeconds),
            isCountdown: session.countdownSeconds > 0,
            timerStartDate: timerDate,
            bookCoverSnapshotName: bookCoverSnapshotName,
            updatedAt: now,
            controlRevision: controlRevision,
            lastControlAction: controlEvent?.rawValue ?? controlSource?.lastControlAction,
            controlRequestedAt: controlEvent == nil ? controlSource?.controlRequestedAt : now
        )
    }

    private func normalizedCoverURLString(from rawURL: String?) -> String? {
        guard let rawURL,
              let url = XMImageRequestBuilder.normalizedURL(from: rawURL) else {
            return nil
        }
        return url.absoluteString
    }

    private static func elapsedText(seconds: Int64) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%lld:%02lld:%02lld", hours, minutes, secs)
        }
        return String(format: "%02lld:%02lld", minutes, secs)
    }

    private static func displaySeconds(for session: ReadingTimerSession, elapsedSeconds: Int64) -> Int64 {
        guard session.countdownSeconds > 0 else {
            return max(0, elapsedSeconds)
        }
        return max(0, session.countdownSeconds - min(max(0, elapsedSeconds), session.countdownSeconds))
    }

    private static func immediateState(
        from state: ReadingTimerActivityAttributes.ContentState,
        action: ReadingTimerLiveActivityControlAction,
        at now: Date
    ) -> ReadingTimerActivityAttributes.ContentState? {
        let displaySeconds = displaySeconds(from: state, at: now)
        let status: String
        switch action {
        case .pause:
            guard state.isRunning else { return nil }
            status = "paused"
        case .resume:
            guard state.isPaused else { return nil }
            status = "running"
        case .stop:
            guard state.isRunning || state.isPaused else { return nil }
            status = "pendingSave"
        }
        return ReadingTimerActivityAttributes.ContentState(
            status: status,
            elapsedSeconds: displaySeconds,
            elapsedText: elapsedText(seconds: displaySeconds),
            isCountdown: state.isCountdown,
            timerStartDate: timerDate(
                displaySeconds: displaySeconds,
                isCountdown: state.isCountdown,
                at: now
            ),
            bookCoverSnapshotName: state.bookCoverSnapshotName,
            updatedAt: now,
            controlRevision: state.effectiveControlRevision + 1,
            lastControlAction: action.rawValue,
            controlRequestedAt: now
        )
    }

    private static func displaySeconds(
        from state: ReadingTimerActivityAttributes.ContentState,
        at now: Date
    ) -> Int64 {
        guard state.isRunning else {
            return max(0, state.elapsedSeconds)
        }
        let interval = state.isCountdown
            ? state.timerStartDate.timeIntervalSince(now)
            : now.timeIntervalSince(state.timerStartDate)
        return max(0, Int64(interval.rounded(.down)))
    }

    private static func timerDate(displaySeconds: Int64, isCountdown: Bool, at now: Date) -> Date {
        if isCountdown {
            return now.addingTimeInterval(Double(max(0, displaySeconds)))
        }
        return now.addingTimeInterval(-Double(max(0, displaySeconds)))
    }

    private static func shouldSkipStandardUpdate(
        current: ReadingTimerActivityAttributes.ContentState,
        proposed: ReadingTimerActivityAttributes.ContentState
    ) -> Bool {
        guard current.status == proposed.status,
              current.isCountdown == proposed.isCountdown,
              current.bookCoverSnapshotName == proposed.bookCoverSnapshotName,
              current.effectiveControlRevision == proposed.effectiveControlRevision else {
            return false
        }
        let currentDisplaySeconds = displaySeconds(from: current, at: proposed.updatedAt)
        return abs(currentDisplaySeconds - proposed.elapsedSeconds) <= 1
    }

    private static func millisecondsString(since date: Date) -> String {
        millisecondsString(from: date, to: Date())
    }

    private static func millisecondsString(from startDate: Date, to endDate: Date) -> String {
        String(format: "%.1f", endDate.timeIntervalSince(startDate) * 1000)
    }
}
