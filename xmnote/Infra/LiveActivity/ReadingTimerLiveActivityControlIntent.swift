import AppIntents
import Foundation
import OSLog

/**
 * [INPUT]: 依赖 AppIntents/ActivityKit 的 LiveActivityIntent，依赖 ReadingTimerRepository 写入未完成计时快照
 * [OUTPUT]: 对外提供 ReadingTimerLiveActivityControlIntent，让灵动岛按钮暂停、继续或停止当前阅读计时，并在提交后通知根 Coordinator 调和
 * [POS]: Infra/LiveActivity 的系统交互入口，被阅读计时 Live Activity 的 Widget 按钮触发并在 App 进程内落库、结束状态面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 灵动岛计时控制按钮的业务动作，保持为轻量枚举以便 Widget 和 App 共同编码。
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

/// 灵动岛展开态的阅读计时控制 Intent，所有写入都经 Repository 保持数据库为唯一事实源。
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

    /// 响应系统按钮点击并把暂停、继续、停止写入数据库。
    /// 并发语义：系统会在 App 进程中运行 LiveActivityIntent；方法固定到 MainActor 创建数据库管理器，写入由 Repository 串到 GRDB，失败时静默保留原状态等待 App 前台恢复。
    @MainActor
    func perform() async throws -> some IntentResult {
        await ReadingTimerLiveActivityControlPerformer.performControl(
            recordId: recordId,
            action: action,
            at: Date()
        )
        return .result()
    }
}

/// 灵动岛暂停按钮的独立 Intent，避免展开态按钮在暂停/继续切换时复用旧参数。
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

    /// 暂停当前阅读计时并写入数据库。
    /// 并发语义：系统在 App 进程内执行，方法固定到 MainActor 后委托共享 performer 串行落库。
    @MainActor
    func perform() async throws -> some IntentResult {
        await ReadingTimerLiveActivityControlPerformer.performControl(
            recordId: recordId,
            action: .pause,
            at: Date()
        )
        return .result()
    }
}

/// 灵动岛继续按钮的独立 Intent，确保暂停态切回运行态时不会沿用暂停按钮的 AppIntent 参数。
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

    /// 继续当前阅读计时并补齐暂停累计时长。
    /// 并发语义：系统在 App 进程内执行，方法固定到 MainActor 后委托共享 performer 串行落库。
    @MainActor
    func perform() async throws -> some IntentResult {
        await ReadingTimerLiveActivityControlPerformer.performControl(
            recordId: recordId,
            action: .resume,
            at: Date()
        )
        return .result()
    }
}

/// 灵动岛停止按钮的独立 Intent，把当前计时推进到待保存状态。
struct ReadingTimerStopLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "结束阅读计时"
    static var description = IntentDescription("结束当前阅读计时并等待保存。")
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

    /// 结束当前阅读计时并写入待保存快照。
    /// 并发语义：系统在 App 进程内执行，方法固定到 MainActor 后委托共享 performer 串行落库。
    @MainActor
    func perform() async throws -> some IntentResult {
        await ReadingTimerLiveActivityControlPerformer.performControl(
            recordId: recordId,
            action: .stop,
            at: Date()
        )
        return .result()
    }
}

private enum ReadingTimerLiveActivityControlPerformer {
    private static let logger = Logger(subsystem: "com.merpyzf.xmnote", category: "ReadingTimerLiveActivityControlIntent")

    @MainActor
    static func performControl(
        recordId rawRecordId: String,
        action: ReadingTimerLiveActivityControlAction,
        at now: Date
    ) async {
        let startedAt = Date()
        guard let recordId = Int64(rawRecordId) else {
            logger.error("Reject Live Activity control because recordId is invalid. rawRecordId=\(rawRecordId, privacy: .public), action=\(action.rawValue, privacy: .public)")
            return
        }

        let immediateVisualUpdate = await ReadingTimerLiveActivityController.shared.updateForControlAction(
            recordId: recordId,
            action: action,
            reason: "preflight-\(action.rawValue)"
        )
        var repository: ReadingTimerRepository?
        do {
            logger.notice("Start Live Activity control. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public)")
            let databaseManager = try DatabaseManager()
            repository = ReadingTimerRepository(databaseManager: databaseManager)
            logger.notice("Live Activity control database prepared. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")

            guard let repository else { return }
            guard let session = try await repository.fetchSession(recordId: recordId),
                  session.status.isUnfinished else {
                logger.info("Skip control action because session is missing or finished. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
                if immediateVisualUpdate != nil {
                    await reconcileAfterFailedOptimisticUpdate(
                        recordId: recordId,
                        action: action,
                        repository: repository,
                        startedAt: startedAt
                    )
                }
                return
            }
            logger.notice("Live Activity control session fetched. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), status=\(session.status.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")

            let target = ReadingTimerLiveActivityControlReducer.targetSnapshot(for: session, action: action, at: now)
            guard let target else {
                logger.info("Skip invalid control transition. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), status=\(session.status.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
                if immediateVisualUpdate != nil {
                    await ReadingTimerLiveActivityController.shared.updateForControl(
                        session: session,
                        elapsedSeconds: session.elapsedSeconds,
                        reason: "reconcile-invalid-\(action.rawValue)"
                    )
                }
                return
            }
            logger.notice("Live Activity control target resolved. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), targetStatus=\(target.status.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")

            if immediateVisualUpdate == nil {
                await ReadingTimerLiveActivityController.shared.updateForControl(
                    session: session.applyingLiveActivityControlTarget(target, updatedAt: now),
                    elapsedSeconds: target.elapsedSeconds,
                    action: action,
                    reason: "optimistic-\(action.rawValue)"
                )
                logger.notice("Live Activity control optimistic update requested after database fetch. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), targetStatus=\(target.status.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
            } else {
                logger.notice("Live Activity control immediate visual update already applied. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), targetStatus=\(target.status.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
            }

            let snapshot = try await repository.updateSessionSnapshot(
                ReadingTimerSnapshotInput(
                    recordId: session.id,
                    status: target.status,
                    elapsedSeconds: target.elapsedSeconds,
                    pausedDurationMillis: target.pausedDurationMillis,
                    expectedStatuses: target.expectedStatuses,
                    interruptAt: target.interruptAt,
                    endAt: target.endAt
                )
            )
            logger.notice("Live Activity control database committed. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), status=\(target.status.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
            if snapshot.status == .stoppedPendingSave {
                await ReadingTimerLiveActivityController.shared.end(recordId: recordId)
            } else {
                if let immediateVisualUpdate,
                   shouldSkipCommitVisualUpdate(
                    appliedState: immediateVisualUpdate.applied,
                    session: snapshot,
                    elapsedSeconds: target.elapsedSeconds
                   ) {
                    logger.notice("Skip commit Live Activity update because immediate visual state already matches committed state. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), status=\(target.status.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
                } else {
                    await ReadingTimerLiveActivityController.shared.updateForControl(
                        session: snapshot,
                        elapsedSeconds: target.elapsedSeconds,
                        reason: "commit-\(action.rawValue)"
                    )
                }
            }
            NotificationCenter.default.post(
                name: .readingTimerSessionDidChange,
                object: NSNumber(value: recordId)
            )
            logger.notice("Applied Live Activity control. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), status=\(target.status.rawValue, privacy: .public), totalMs=\(millisecondsString(since: startedAt), privacy: .public)")
        } catch {
            logger.error("Failed to perform Live Activity control. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), immediateApplied=\(immediateVisualUpdate != nil, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            if let immediateVisualUpdate {
                if let repository {
                    await reconcileAfterFailedOptimisticUpdate(
                        recordId: recordId,
                        action: action,
                        repository: repository,
                        startedAt: startedAt
                    )
                } else {
                    await ReadingTimerLiveActivityController.shared.restoreControlState(
                        recordId: recordId,
                        state: immediateVisualUpdate.previous,
                        reason: "rollback-\(action.rawValue)"
                    )
                }
            }
            return
        }
    }

    private static func shouldSkipCommitVisualUpdate(
        appliedState: ReadingTimerActivityAttributes.ContentState,
        session: ReadingTimerSession,
        elapsedSeconds: Int64
    ) -> Bool {
        guard appliedState.status == statusText(for: session.status),
              appliedState.isCountdown == (session.countdownSeconds > 0) else {
            return false
        }
        let displaySeconds = displaySeconds(for: session, elapsedSeconds: elapsedSeconds)
        return abs(appliedState.elapsedSeconds - displaySeconds) <= 1
    }

    private static func reconcileAfterFailedOptimisticUpdate(
        recordId: Int64,
        action: ReadingTimerLiveActivityControlAction,
        repository: ReadingTimerRepository,
        startedAt: Date
    ) async {
        do {
            guard let latestSession = try await repository.fetchSession(recordId: recordId) else {
                await ReadingTimerLiveActivityController.shared.end(recordId: recordId)
                logger.notice("Ended Live Activity after failed optimistic control because session disappeared. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
                return
            }
            guard latestSession.status.isUnfinished else {
                await ReadingTimerLiveActivityController.shared.end(
                    recordId: recordId,
                    finalSession: latestSession,
                    elapsedSeconds: latestSession.elapsedSeconds
                )
                logger.notice("Ended Live Activity after failed optimistic control because session finished. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
                return
            }
            await ReadingTimerLiveActivityController.shared.updateForControl(
                session: latestSession,
                elapsedSeconds: latestSession.elapsedSeconds,
                reason: "reconcile-\(action.rawValue)"
            )
            logger.notice("Reconciled Live Activity after failed optimistic control. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), status=\(latestSession.status.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public)")
        } catch {
            logger.error("Failed to reconcile Live Activity after optimistic control failure. recordId=\(recordId, privacy: .public), action=\(action.rawValue, privacy: .public), elapsedMs=\(millisecondsString(since: startedAt), privacy: .public), error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func millisecondsString(since date: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(date) * 1000)
    }

    private static func displaySeconds(for session: ReadingTimerSession, elapsedSeconds: Int64) -> Int64 {
        guard session.countdownSeconds > 0 else {
            return max(0, elapsedSeconds)
        }
        return max(0, session.countdownSeconds - min(max(0, elapsedSeconds), session.countdownSeconds))
    }

    private static func statusText(for status: ReadingTimerRecordStatus) -> String {
        switch status {
        case .running:
            return "running"
        case .paused:
            return "paused"
        case .stoppedPendingSave:
            return "pendingSave"
        case .finished:
            return "finished"
        }
    }
}

private extension ReadingTimerSession {
    /// 生成灵动岛乐观反馈用的会话副本，只改变计时控制会影响的未完成快照字段。
    func applyingLiveActivityControlTarget(
        _ target: ReadingTimerLiveActivityControlTarget,
        updatedAt: Date
    ) -> ReadingTimerSession {
        ReadingTimerSession(
            id: id,
            book: book,
            startTime: startTime,
            endTime: target.endAt ?? endTime,
            interruptTime: target.interruptAt,
            elapsedSeconds: target.elapsedSeconds,
            countdownSeconds: countdownSeconds,
            pausedDurationMillis: target.pausedDurationMillis,
            isPaused: target.status == .paused,
            status: target.status,
            position: position,
            recordedPositionUnit: recordedPositionUnit,
            fuzzyReadDate: fuzzyReadDate,
            insight: insight,
            createdDate: createdDate,
            updatedDate: updatedAt
        )
    }
}
