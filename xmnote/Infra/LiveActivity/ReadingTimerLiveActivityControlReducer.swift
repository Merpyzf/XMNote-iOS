import Foundation

/**
 * [INPUT]: 依赖 ReadingTimerSession 与 ReadingTimerLiveActivityControlAction，读取当前计时状态与操作时间
 * [OUTPUT]: 对外提供 ReadingTimerLiveActivityControlReducer，计算灵动岛控制按钮对应的下一次计时快照
 * [POS]: Infra/LiveActivity 的纯状态计算层，被 LiveActivityIntent 调用并由单元测试验证暂停、继续、结束状态迁移
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 灵动岛控制按钮落库前的目标快照，集中描述状态机迁移和并发保护条件。
nonisolated struct ReadingTimerLiveActivityControlTarget: Equatable, Sendable {
    let status: ReadingTimerRecordStatus
    let elapsedSeconds: Int64
    let pausedDurationMillis: Int64
    let expectedStatuses: [ReadingTimerRecordStatus]
    let interruptAt: Date
    let endAt: Date?
}

/// 阅读计时 Live Activity 交互的纯状态机，避免 Intent 直接夹带不可测试的时间计算。
nonisolated enum ReadingTimerLiveActivityControlReducer {
    /// 根据当前会话、按钮动作和系统时间生成下一次可落库快照。
    static func targetSnapshot(
        for session: ReadingTimerSession,
        action: ReadingTimerLiveActivityControlAction,
        at now: Date
    ) -> ReadingTimerLiveActivityControlTarget? {
        switch action {
        case .pause:
            guard session.status == .running else { return nil }
            return ReadingTimerLiveActivityControlTarget(
                status: .paused,
                elapsedSeconds: elapsedSeconds(for: session, at: now),
                pausedDurationMillis: pausedDurationMillis(for: session, at: now),
                expectedStatuses: [.running],
                interruptAt: now,
                endAt: nil
            )
        case .resume:
            guard session.status == .paused else { return nil }
            return ReadingTimerLiveActivityControlTarget(
                status: .running,
                elapsedSeconds: session.elapsedSeconds,
                pausedDurationMillis: pausedDurationMillis(for: session, at: now),
                expectedStatuses: [.paused],
                interruptAt: now,
                endAt: nil
            )
        case .stop:
            guard session.status == .running || session.status == .paused else { return nil }
            let elapsedSeconds = session.status == .running
                ? elapsedSeconds(for: session, at: now)
                : session.elapsedSeconds
            return ReadingTimerLiveActivityControlTarget(
                status: .stoppedPendingSave,
                elapsedSeconds: elapsedSeconds,
                pausedDurationMillis: pausedDurationMillis(for: session, at: now),
                expectedStatuses: [.running, .paused],
                interruptAt: now,
                endAt: now
            )
        }
    }

    private static func elapsedSeconds(for session: ReadingTimerSession, at now: Date) -> Int64 {
        guard session.status == .running else { return session.elapsedSeconds }
        let anchor = session.interruptTime ?? session.updatedDate ?? session.startTime ?? now
        let delta = max(0, Int64(now.timeIntervalSince(anchor)))
        let elapsedSeconds = session.elapsedSeconds + delta
        guard session.countdownSeconds > 0 else {
            return elapsedSeconds
        }
        return min(elapsedSeconds, session.countdownSeconds)
    }

    private static func pausedDurationMillis(for session: ReadingTimerSession, at now: Date) -> Int64 {
        guard session.status == .paused, let pauseAnchor = session.interruptTime else {
            return session.pausedDurationMillis
        }
        let deltaMillis = max(0, Int64(now.timeIntervalSince(pauseAnchor) * 1000))
        return session.pausedDurationMillis + deltaMillis
    }
}
