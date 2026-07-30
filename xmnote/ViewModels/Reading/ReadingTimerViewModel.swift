import Foundation
import Observation

/**
 * [INPUT]: 依赖 ReadingTimerRepositoryProtocol 提供阅读计时记录读写，依赖 ReadingTimerSession 领域模型承接恢复与保存状态
 * [OUTPUT]: 对外提供 ReadingTimerViewModel（实时计时、暂停/继续/停止、保存/放弃与恢复编排）
 * [POS]: ViewModels/Reading 的阅读计时状态中枢，被 ReadingTimerView、结束确认 Sheet 与场景生命周期回调消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
/// 阅读计时状态中枢，负责 App 内计时展示、状态持久化和未完成记录恢复。
final class ReadingTimerViewModel {
    /// 计时页加载模式，区分普通书籍入口、精确记录入口与全局恢复入口。
    enum BootstrapMode: Equatable {
        case book(Int64)
        case record(recordId: Int64, fallbackBookId: Int64?)
        case recoverLatest
    }

    var bookContext: ReadingTimerBookContext?
    var activeSession: ReadingTimerSession?
    var pendingRecoverySession: ReadingTimerSession?
    var elapsedSeconds: Int64 = 0
    var pausedDurationMillis: Int64 = 0
    var status: ReadingTimerRecordStatus?
    var isLoading = false
    var isWriting = false
    var errorMessage: String?
    var shouldPresentRecoveryPrompt = false
    var shouldPresentFinishSheet = false
    var shouldPresentCountdownCompletionAlert = false

    private let repository: any ReadingTimerRepositoryProtocol
    private let notificationScheduler: ReadingTimerCountdownNotificationScheduler
    private let tickIntervalNanoseconds: UInt64 = 1_000_000_000
    private let snapshotPersistInterval: TimeInterval = 15
    private var bootstrapMode: BootstrapMode?
    private var baseElapsedSeconds: Int64 = 0
    private var runningAnchorDate: Date?
    private var pauseAnchorDate: Date?
    private var tickerTask: Task<Void, Never>?
    private var snapshotPersistTask: Task<Void, Never>?
    private var lastSnapshotPersistDate: Date?
    private var isCompletingCountdown = false

    /// 注入阅读计时仓储，等待页面触发 bootstrap 后再读取或创建计时记录。
    init(
        repository: any ReadingTimerRepositoryProtocol,
        notificationScheduler: ReadingTimerCountdownNotificationScheduler? = nil
    ) {
        self.repository = repository
        self.notificationScheduler = notificationScheduler ?? .shared
    }

    var isIdle: Bool {
        status == nil
    }

    var isRunning: Bool {
        status == .running
    }

    var isPaused: Bool {
        status == .paused
    }

    var isStoppedPendingSave: Bool {
        status == .stoppedPendingSave
    }

    var canStart: Bool {
        bookContext != nil && activeSession == nil && pendingRecoverySession == nil && !isWriting
    }

    var canPause: Bool {
        status == .running && activeSession != nil && !isWriting
    }

    var canResume: Bool {
        status == .paused && activeSession != nil && !isWriting
    }

    var canStop: Bool {
        (status == .running || status == .paused) && activeSession != nil && !isWriting
    }

    var needsLongDurationConfirmation: Bool {
        elapsedSeconds > 8 * 60 * 60
    }

    var isCountdownMode: Bool {
        activeSession?.countdownSeconds ?? 0 > 0
    }

    var displaySeconds: Int64 {
        guard let session = activeSession, session.countdownSeconds > 0 else {
            return elapsedSeconds
        }
        return max(0, session.countdownSeconds - min(elapsedSeconds, session.countdownSeconds))
    }

    var timerDisplayTitle: String {
        guard isCountdownMode else { return "已阅读" }
        return isStoppedPendingSave ? "计时结束" : "剩余时间"
    }

    var secondaryTimerText: String? {
        guard isCountdownMode else { return nil }
        return "已阅读 \(ReadDurationFormatter.format(seconds: elapsedSeconds))"
    }

    /// 初始化指定入口；同书未完成记录直接恢复，异书未完成记录才进入冲突提示。
    /// 并发语义：方法运行在 MainActor；Repository 异步读取可被任务取消，取消后不写回状态。
    func bootstrap(_ mode: BootstrapMode) async {
        bootstrapMode = mode
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await resolveBootstrap(mode, at: Date())
        } catch {
            errorMessage = "阅读计时加载失败：\(error.localizedDescription)"
        }
    }

    /// 开始一本书的阅读计时；创建成功后立即进入运行态并启动前台 tick。
    /// 并发语义：创建记录期间禁用重复点击；状态写回 MainActor，取消时不会留下额外 UI 状态。
    func start(countdownSeconds: Int64 = 0) async {
        guard let bookId = bookContext?.id, canStart else { return }
        guard countdownSeconds >= 0 else {
            errorMessage = "阅读时长无效"
            return
        }
        isWriting = true
        errorMessage = nil
        defer { isWriting = false }

        do {
            let now = Date()
            let session = try await repository.createSession(
                bookId: bookId,
                startAt: now,
                countdownSeconds: countdownSeconds
            )
            applyActiveSession(session, calibratedAt: now)
            await ReadingTimerLiveActivityController.shared.start(
                session: session,
                elapsedSeconds: elapsedSeconds
            )
        } catch {
            errorMessage = "开始阅读失败：\(error.localizedDescription)"
        }
    }

    /// 暂停当前运行中的计时，并把已读秒数立即持久化。
    /// 并发语义：先在 MainActor 计算当前展示时长，再通过 Repository 写入；写入失败时保留原运行态并提示错误。
    func pause() async {
        guard canPause, let session = activeSession else { return }
        let now = Date()
        let currentElapsed = currentElapsedSeconds(at: now)
        let currentPaused = currentPausedDurationMillis(at: now)
        await writeImmediateSnapshot(
            recordId: session.id,
            status: .paused,
            elapsedSeconds: currentElapsed,
            pausedDurationMillis: currentPaused,
            expectedStatuses: [.running],
            interruptAt: now,
            endAt: nil,
            failureMessage: "暂停失败"
        )
    }

    /// 继续暂停中的计时；暂停累计毫秒数会在继续瞬间补齐。
    /// 并发语义：恢复操作会取消后台快照写入，避免旧运行态快照覆盖继续后的状态。
    func resume() async {
        guard canResume, let session = activeSession else { return }
        let now = Date()
        let currentPaused = currentPausedDurationMillis(at: now)
        await writeImmediateSnapshot(
            recordId: session.id,
            status: .running,
            elapsedSeconds: elapsedSeconds,
            pausedDurationMillis: currentPaused,
            expectedStatuses: [.paused],
            interruptAt: now,
            endAt: nil,
            failureMessage: "继续失败"
        )
    }

    /// 结束当前计时并进入待保存状态；记录不会进入统计，直到用户保存确认。
    /// 并发语义：停止时会计算当前阅读时长和暂停累计，再写入 `status = 2`；成功后停止 tick 并拉起保存 Sheet。
    func stopForSave() async {
        guard canStop, let session = activeSession else { return }
        let now = Date()
        let currentElapsed = currentElapsedSeconds(at: now)
        let currentPaused = currentPausedDurationMillis(at: now)
        await writeImmediateSnapshot(
            recordId: session.id,
            status: .stoppedPendingSave,
            elapsedSeconds: currentElapsed,
            pausedDurationMillis: currentPaused,
            expectedStatuses: [.running, .paused],
            interruptAt: now,
            endAt: now,
            failureMessage: "结束计时失败"
        )
        if status == .stoppedPendingSave {
            shouldPresentFinishSheet = true
        }
    }

    /// 保存结束确认信息，将记录推进为完成状态并进入现有统计消费口径。
    /// 并发语义：保存期间关闭 tick 并禁用重复提交；Repository 负责事务内更新记录、位置和读完状态。
    func saveFinishedRecord(position: Double?, insight: String, markReadDone: Bool) async {
        guard let session = activeSession else { return }
        let now = session.endTime ?? Date()
        let finalElapsed = max(1, elapsedSeconds)
        let finalPaused = currentPausedDurationMillis(at: Date())
        isWriting = true
        errorMessage = nil
        defer { isWriting = false }

        do {
            stopTicker()
            snapshotPersistTask?.cancel()
            let input = ReadingTimerFinishInput(
                recordId: session.id,
                endAt: now,
                elapsedSeconds: finalElapsed,
                pausedDurationMillis: finalPaused,
                position: position,
                insight: insight,
                markReadDone: markReadDone
            )
            let finished = try await repository.finishSession(input)
            applyFinishedSession(finished)
            notificationScheduler.cancelCompletion(recordId: session.id)
            NotificationCenter.default.post(name: .readingTimerRecordsDidChange, object: nil)
            await ReadingTimerLiveActivityController.shared.end(
                recordId: session.id,
                finalSession: finished,
                elapsedSeconds: finalElapsed
            )
            shouldPresentFinishSheet = false
        } catch {
            errorMessage = "保存阅读记录失败：\(error.localizedDescription)"
        }
    }

    /// 放弃当前或待恢复的未完成计时，使用软删除避免进入统计。
    /// 并发语义：删除期间取消 tick 和后台快照；成功后恢复到当前书籍的 idle 状态。
    @discardableResult
    func discardCurrentSession() async -> Bool {
        guard let recordId = activeSession?.id ?? pendingRecoverySession?.id else { return false }
        isWriting = true
        errorMessage = nil
        defer { isWriting = false }

        do {
            stopTicker()
            snapshotPersistTask?.cancel()
            try await repository.discardSession(recordId: recordId)
            clearActiveSession(keepingBookContext: true)
            notificationScheduler.cancelCompletion(recordId: recordId)
            Task {
                await ReadingTimerLiveActivityController.shared.end(recordId: recordId)
            }
            return true
        } catch {
            errorMessage = "放弃本次计时失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 用户确认恢复未完成计时后继续展示对应状态。
    /// 并发语义：方法在 MainActor 捕获待恢复会话快照，再用独立 Task 同步 Live Activity；同步失败不影响页面接管。
    func acceptRecovery() {
        guard let pendingRecoverySession else { return }
        let session = pendingRecoverySession
        shouldPresentRecoveryPrompt = false
        applyRecoveredSession(
            session,
            at: Date(),
            presentsPendingSave: session.status == .stoppedPendingSave
        )
        let syncedElapsedSeconds = elapsedSeconds
        Task {
            await ReadingTimerLiveActivityController.shared.start(
                session: session,
                elapsedSeconds: syncedElapsedSeconds
            )
        }
    }

    /// 关闭冲突提示但保留未完成记录，适用于用户返回原页面后再处理。
    func postponeRecoveryPrompt() {
        shouldPresentRecoveryPrompt = false
    }

    /// 返回异书冲突来源前清空当前页面的待恢复快照，保留数据库中的真实未完成计时。
    func clearRecoveryConflictBeforeReturn() {
        pendingRecoverySession = nil
        shouldPresentRecoveryPrompt = false
    }

    /// App 即将进入后台或非活跃状态时持久化当前运行快照。
    /// 并发语义：该方法由场景生命周期调用；只写当前 ViewModel 管理的未完成记录，失败时保留错误给前台恢复后展示。
    func persistBeforeSuspension() async {
        guard let session = activeSession, status?.isUnfinished == true else { return }
        let now = Date()
        do {
            let snapshot = try await repository.updateSessionSnapshot(
                ReadingTimerSnapshotInput(
                    recordId: session.id,
                    status: status ?? .running,
                    elapsedSeconds: currentElapsedSeconds(at: now),
                    pausedDurationMillis: currentPausedDurationMillis(at: now),
                    expectedStatuses: [status ?? .running],
                    interruptAt: now,
                    endAt: status == .stoppedPendingSave ? (activeSession?.endTime ?? now) : nil
                )
            )
            applyActiveSession(snapshot, calibratedAt: now)
            await ReadingTimerLiveActivityController.shared.update(
                session: snapshot,
                elapsedSeconds: elapsedSeconds
            )
        } catch ReadingTimerError.staleSessionState {
            await refreshSessionAfterStaleWrite(recordId: session.id)
        } catch {
            errorMessage = "计时状态保存失败：\(error.localizedDescription)"
        }
    }

    /// App 回到前台后重新读取数据库中的记录并做时间戳校准。
    /// 并发语义：优先恢复当前 recordId；新深链页尚无 activeSession 时，会按 bootstrapMode 重新解析入口。
    func refreshAfterResume() async {
        do {
            if let recordId = activeSession?.id {
                try await refreshActiveSession(recordId: recordId, at: Date())
                return
            }
            if let pendingRecordId = pendingRecoverySession?.id {
                if let session = try await repository.fetchSession(recordId: pendingRecordId),
                   session.status.isUnfinished {
                    pendingRecoverySession = session
                    shouldPresentRecoveryPrompt = true
                } else {
                    pendingRecoverySession = nil
                    shouldPresentRecoveryPrompt = false
                }
                return
            }
            if let bootstrapMode {
                try await resolveBootstrap(bootstrapMode, at: Date())
            }
        } catch {
            errorMessage = "计时状态恢复失败：\(error.localizedDescription)"
        }
    }
}

private extension ReadingTimerViewModel {
    /// 解析计时页入口并把 UI 对齐到数据库中唯一真实的未完成记录。
    /// 并发语义：运行在 MainActor；Repository 读取完成前若外层任务取消，后续状态写回由调用任务自然终止。
    func resolveBootstrap(_ mode: BootstrapMode, at date: Date) async throws {
        switch mode {
        case .book(let bookId):
            let context = try await repository.fetchBookContext(bookId: bookId)
            bookContext = context
            if let active = try await repository.fetchActiveSession() {
                if active.book.id == bookId {
                    applyRecoveredSession(
                        active,
                        at: date,
                        presentsPendingSave: active.status == .stoppedPendingSave
                    )
                    await syncRecoveredLiveActivity(active)
                } else {
                    presentRecoveryConflict(active)
                }
            } else {
                clearActiveSession(keepingBookContext: true)
            }
        case .record(let recordId, let fallbackBookId):
            if let session = try await repository.fetchSession(recordId: recordId),
               session.status.isUnfinished {
                applyRecoveredSession(
                    session,
                    at: date,
                    presentsPendingSave: session.status == .stoppedPendingSave
                )
                await syncRecoveredLiveActivity(session)
            } else {
                await fallbackToBookIdle(fallbackBookId: fallbackBookId)
                errorMessage = "这段计时已结束或不可用"
            }
        case .recoverLatest:
            if let active = try await repository.fetchActiveSession() {
                applyRecoveredSession(
                    active,
                    at: date,
                    presentsPendingSave: active.status == .stoppedPendingSave
                )
                await syncRecoveredLiveActivity(active)
            } else {
                clearActiveSession(keepingBookContext: false)
            }
        }
    }

    /// 精确记录入口失效时回退到书籍 idle 态，避免重新创建 0 秒假会话。
    /// 并发语义：运行在 MainActor；fallback 书籍读取失败时只清空会话，不向外抛出二次错误。
    func fallbackToBookIdle(fallbackBookId: Int64?) async {
        if let fallbackBookId,
           let context = try? await repository.fetchBookContext(bookId: fallbackBookId) {
            bookContext = context
            clearActiveSession(keepingBookContext: true)
        } else {
            clearActiveSession(keepingBookContext: false)
        }
    }

    /// 展示异书计时冲突，不接管当前页面书籍上下文。
    func presentRecoveryConflict(_ session: ReadingTimerSession) {
        let currentBook = bookContext
        stopTicker()
        snapshotPersistTask?.cancel()
        snapshotPersistTask = nil
        activeSession = nil
        pendingRecoverySession = session
        shouldPresentRecoveryPrompt = true
        shouldPresentFinishSheet = false
        status = nil
        elapsedSeconds = 0
        pausedDurationMillis = 0
        baseElapsedSeconds = 0
        runningAnchorDate = nil
        pauseAnchorDate = nil
        lastSnapshotPersistDate = nil
        bookContext = currentBook
    }

    /// 将未完成记录应用到页面，并根据时间戳校准运行中时长。
    func applyRecoveredSession(
        _ session: ReadingTimerSession,
        at date: Date,
        presentsPendingSave: Bool = false
    ) {
        bookContext = session.book
        shouldPresentRecoveryPrompt = false
        applyActiveSession(session, calibratedAt: date)
        if session.status == .stoppedPendingSave {
            shouldPresentFinishSheet = presentsPendingSave || shouldPresentFinishSheet
        } else {
            shouldPresentFinishSheet = false
        }
    }

    /// 应用当前有效会话；运行态会启动 tick，暂停/待保存会停止 tick。
    func applyActiveSession(_ session: ReadingTimerSession, calibratedAt date: Date) {
        activeSession = session
        pendingRecoverySession = nil
        bookContext = session.book
        status = session.status
        pausedDurationMillis = session.pausedDurationMillis
        shouldPresentCountdownCompletionAlert = false

        switch session.status {
        case .running:
            baseElapsedSeconds = calibratedElapsedSeconds(for: session, at: date)
            elapsedSeconds = baseElapsedSeconds
            runningAnchorDate = date
            pauseAnchorDate = nil
            if countdownHasCompleted(session, elapsedSeconds: baseElapsedSeconds) {
                stopTicker()
                Task { [weak self] in
                    await self?.completeCountdownIfNeeded(for: session, at: date)
                }
            } else {
                startTicker()
                Task { [weak self] in
                    await self?.scheduleCountdownNotificationIfNeeded(for: session, at: date)
                }
            }
        case .paused:
            stopTicker()
            baseElapsedSeconds = session.elapsedSeconds
            elapsedSeconds = session.elapsedSeconds
            runningAnchorDate = nil
            pauseAnchorDate = session.interruptTime ?? date
            notificationScheduler.cancelCompletion(recordId: session.id)
        case .stoppedPendingSave:
            stopTicker()
            baseElapsedSeconds = session.elapsedSeconds
            elapsedSeconds = session.elapsedSeconds
            runningAnchorDate = nil
            pauseAnchorDate = nil
            notificationScheduler.cancelCompletion(recordId: session.id)
        case .finished:
            applyFinishedSession(session)
        }
    }

    /// 应用已完成记录并停止所有运行态任务。
    func applyFinishedSession(_ session: ReadingTimerSession) {
        stopTicker()
        snapshotPersistTask?.cancel()
        snapshotPersistTask = nil
        notificationScheduler.cancelCompletion(recordId: session.id)
        activeSession = session
        pendingRecoverySession = nil
        shouldPresentRecoveryPrompt = false
        shouldPresentFinishSheet = false
        shouldPresentCountdownCompletionAlert = false
        bookContext = session.book
        status = .finished
        baseElapsedSeconds = session.elapsedSeconds
        elapsedSeconds = session.elapsedSeconds
        pausedDurationMillis = session.pausedDurationMillis
        runningAnchorDate = nil
        pauseAnchorDate = nil
    }

    /// 清空当前会话；保留书籍上下文可让用户立即重新开始同一本书。
    func clearActiveSession(keepingBookContext: Bool) {
        let currentBook = bookContext
        stopTicker()
        snapshotPersistTask?.cancel()
        snapshotPersistTask = nil
        activeSession = nil
        pendingRecoverySession = nil
        shouldPresentRecoveryPrompt = false
        shouldPresentFinishSheet = false
        shouldPresentCountdownCompletionAlert = false
        status = nil
        elapsedSeconds = 0
        pausedDurationMillis = 0
        baseElapsedSeconds = 0
        runningAnchorDate = nil
        pauseAnchorDate = nil
        lastSnapshotPersistDate = nil
        bookContext = keepingBookContext ? currentBook : nil
    }

    /// 写入暂停/继续/停止等用户触发的即时快照。
    func writeImmediateSnapshot(
        recordId: Int64,
        status targetStatus: ReadingTimerRecordStatus,
        elapsedSeconds targetElapsedSeconds: Int64,
        pausedDurationMillis targetPausedDurationMillis: Int64,
        expectedStatuses: [ReadingTimerRecordStatus],
        interruptAt: Date,
        endAt: Date?,
        failureMessage: String
    ) async {
        snapshotPersistTask?.cancel()
        isWriting = true
        errorMessage = nil
        defer { isWriting = false }

        do {
            let snapshot = try await repository.updateSessionSnapshot(
                ReadingTimerSnapshotInput(
                    recordId: recordId,
                    status: targetStatus,
                    elapsedSeconds: targetElapsedSeconds,
                    pausedDurationMillis: targetPausedDurationMillis,
                    expectedStatuses: expectedStatuses,
                    interruptAt: interruptAt,
                    endAt: endAt
                )
            )
            applyActiveSession(snapshot, calibratedAt: interruptAt)
            lastSnapshotPersistDate = interruptAt
            await ReadingTimerLiveActivityController.shared.update(
                session: snapshot,
                elapsedSeconds: targetElapsedSeconds
            )
        } catch ReadingTimerError.staleSessionState {
            await refreshSessionAfterStaleWrite(recordId: recordId)
        } catch {
            errorMessage = "\(failureMessage)：\(error.localizedDescription)"
        }
    }

    /// 旧快照命中 0 行时重新读取数据库，让 UI 以真实状态为准。
    /// 并发语义：运行在 MainActor；读取失败才暴露错误，成功刷新不再追加交互提示。
    func refreshSessionAfterStaleWrite(recordId: Int64) async {
        do {
            try await refreshActiveSession(recordId: recordId, at: Date())
        } catch {
            errorMessage = "计时状态刷新失败：\(error.localizedDescription)"
        }
    }

    /// 按 recordId 重新读取未完成记录；记录完成或删除时清空本页会话并移除 Live Activity。
    /// 并发语义：运行在 MainActor；Live Activity 同步失败不会影响数据库真相刷新。
    func refreshActiveSession(recordId: Int64, at date: Date) async throws {
        if let session = try await repository.fetchSession(recordId: recordId),
           session.status.isUnfinished {
            applyRecoveredSession(session, at: date)
            await ReadingTimerLiveActivityController.shared.update(
                session: session,
                elapsedSeconds: elapsedSeconds
            )
        } else {
            clearActiveSession(keepingBookContext: true)
            await ReadingTimerLiveActivityController.shared.end(recordId: recordId)
        }
    }

    /// 恢复入口成功接管会话后同步系统展示；Activity 不存在时允许重建，但数据库仍是唯一真相。
    /// 并发语义：运行在 MainActor；ActivityKit 失败会在控制器内吞掉，不回滚 ViewModel 状态。
    func syncRecoveredLiveActivity(_ session: ReadingTimerSession) async {
        guard session.status.isUnfinished else { return }
        await ReadingTimerLiveActivityController.shared.start(
            session: session,
            elapsedSeconds: elapsedSeconds
        )
    }

    /// 启动每秒 tick；tick 只负责展示刷新和低频快照持久化。
    /// 并发语义：tickerTask 由 MainActor 创建，页面状态切换时通过 stopTicker 取消，取消后不再写回展示秒数。
    func startTicker() {
        stopTicker()
        let interval = tickIntervalNanoseconds
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.handleTick()
            }
        }
    }

    /// 停止展示 tick。
    func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    /// 每秒刷新展示时长，并按 15 秒节流持久化运行态快照。
    func handleTick() {
        guard status == .running, let session = activeSession else { return }
        let now = Date()
        elapsedSeconds = currentElapsedSeconds(at: now)
        if countdownHasCompleted(session, elapsedSeconds: elapsedSeconds) {
            Task { [weak self] in
                await self?.completeCountdownIfNeeded(for: session, at: now)
            }
            return
        }
        persistRunningSnapshotIfNeeded(at: now)
    }

    /// 低频保存运行态快照，降低杀进程恢复时的校准距离。
    /// 并发语义：后台快照任务只允许一个在途；若状态前置条件失效，会回到 MainActor 重新读取数据库真相。
    func persistRunningSnapshotIfNeeded(at date: Date) {
        guard let session = activeSession, status == .running else { return }
        guard snapshotPersistTask == nil || snapshotPersistTask?.isCancelled == true else { return }
        guard lastSnapshotPersistDate.map({ date.timeIntervalSince($0) >= snapshotPersistInterval }) ?? true else {
            return
        }

        let targetElapsed = currentElapsedSeconds(at: date)
        let targetPaused = currentPausedDurationMillis(at: date)
        let repository = repository
        lastSnapshotPersistDate = date
        snapshotPersistTask = Task { [weak self] in
            do {
                let snapshot = try await repository.updateSessionSnapshot(
                    ReadingTimerSnapshotInput(
                        recordId: session.id,
                        status: .running,
                        elapsedSeconds: targetElapsed,
                        pausedDurationMillis: targetPaused,
                        expectedStatuses: [.running],
                        interruptAt: date
                    )
                )
                await MainActor.run { [weak self] in
                    guard let self, self.activeSession?.id == snapshot.id, self.status == .running else { return }
                    self.activeSession = snapshot
                    self.pausedDurationMillis = snapshot.pausedDurationMillis
                    self.snapshotPersistTask = nil
                }
                await ReadingTimerLiveActivityController.shared.update(
                    session: snapshot,
                    elapsedSeconds: targetElapsed
                )
            } catch ReadingTimerError.staleSessionState {
                await MainActor.run { [weak self] in
                    self?.snapshotPersistTask = nil
                }
                await self?.refreshSessionAfterStaleWrite(recordId: session.id)
            } catch {
                await MainActor.run { [weak self] in
                    self?.snapshotPersistTask = nil
                }
            }
        }
    }

    /// 计算当前展示时长，运行中用锚点补上前台流逝时间。
    func currentElapsedSeconds(at date: Date) -> Int64 {
        guard status == .running, let runningAnchorDate else {
            return elapsedSeconds(for: activeSession, rawElapsedSeconds: elapsedSeconds)
        }
        let delta = max(0, Int64(date.timeIntervalSince(runningAnchorDate)))
        return elapsedSeconds(for: activeSession, rawElapsedSeconds: baseElapsedSeconds + delta)
    }

    /// 计算当前暂停累计，暂停中需要补上本次暂停已经流逝的毫秒。
    func currentPausedDurationMillis(at date: Date) -> Int64 {
        let base = activeSession?.pausedDurationMillis ?? pausedDurationMillis
        guard status == .paused, let pauseAnchorDate else {
            return base
        }
        let deltaMillis = max(0, Int64(date.timeIntervalSince(pauseAnchorDate) * 1000))
        return base + deltaMillis
    }

    /// 根据数据库快照校准运行中时长；后台或进程重启后不依赖持续 tick。
    func calibratedElapsedSeconds(for session: ReadingTimerSession, at date: Date) -> Int64 {
        guard session.status == .running else {
            return elapsedSeconds(for: session, rawElapsedSeconds: session.elapsedSeconds)
        }
        let anchor = session.interruptTime ?? session.updatedDate ?? session.startTime ?? date
        let delta = max(0, Int64(date.timeIntervalSince(anchor)))
        return elapsedSeconds(for: session, rawElapsedSeconds: session.elapsedSeconds + delta)
    }

    func elapsedSeconds(for session: ReadingTimerSession?, rawElapsedSeconds: Int64) -> Int64 {
        let elapsed = max(0, rawElapsedSeconds)
        guard let countdownSeconds = session?.countdownSeconds, countdownSeconds > 0 else {
            return elapsed
        }
        return min(elapsed, countdownSeconds)
    }

    func countdownHasCompleted(_ session: ReadingTimerSession, elapsedSeconds: Int64) -> Bool {
        session.countdownSeconds > 0 && elapsedSeconds >= session.countdownSeconds
    }

    /// 倒计时到点后自动停止并进入待保存状态，前台给出系统弹窗，后台依赖已调度的本地通知提醒用户。
    /// 并发语义：方法运行在 MainActor，并通过 isCompletingCountdown 防止同一秒内 tick、恢复校准和后台刷新重复写入。
    func completeCountdownIfNeeded(for session: ReadingTimerSession, at date: Date) async {
        guard activeSession?.id == session.id,
              status == .running,
              countdownHasCompleted(session, elapsedSeconds: currentElapsedSeconds(at: date)),
              !isCompletingCountdown else {
            return
        }
        isCompletingCountdown = true
        defer { isCompletingCountdown = false }

        stopTicker()
        snapshotPersistTask?.cancel()
        await writeImmediateSnapshot(
            recordId: session.id,
            status: .stoppedPendingSave,
            elapsedSeconds: session.countdownSeconds,
            pausedDurationMillis: currentPausedDurationMillis(at: date),
            expectedStatuses: [.running],
            interruptAt: date,
            endAt: date,
            failureMessage: "倒计时结束处理失败"
        )
        if status == .stoppedPendingSave {
            shouldPresentCountdownCompletionAlert = true
            notificationScheduler.cancelCompletion(recordId: session.id)
        }
    }

    /// 同步倒计时本地通知；暂停、停止和非倒计时记录不保留完成提醒。
    /// 并发语义：通知权限请求与调度异步执行，失败不影响数据库计时状态。
    func scheduleCountdownNotificationIfNeeded(for session: ReadingTimerSession, at date: Date) async {
        guard session.status == .running, session.countdownSeconds > 0 else {
            notificationScheduler.cancelCompletion(recordId: session.id)
            return
        }
        let remainingSeconds = max(0, session.countdownSeconds - calibratedElapsedSeconds(for: session, at: date))
        guard remainingSeconds > 0 else {
            notificationScheduler.cancelCompletion(recordId: session.id)
            return
        }
        await notificationScheduler.scheduleCompletion(
            recordId: session.id,
            bookTitle: session.book.name,
            remainingSeconds: remainingSeconds
        )
    }
}
