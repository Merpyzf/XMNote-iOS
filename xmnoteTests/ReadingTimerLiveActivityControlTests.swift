import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct ReadingTimerLiveActivityControlTests {
    @Test
    func reducerPausesRunningSessionWithElapsedDelta() throws {
        let base = Self.date(seconds: 1_000)
        let session = Self.session(
            status: .running,
            elapsedSeconds: 120,
            pausedDurationMillis: 4_000,
            startTime: base,
            interruptTime: base.addingTimeInterval(20),
            updatedDate: base.addingTimeInterval(18)
        )

        let target = try #require(
            ReadingTimerLiveActivityControlReducer.targetSnapshot(
                for: session,
                action: .pause,
                at: base.addingTimeInterval(35)
            )
        )

        #expect(target.status == .paused)
        #expect(target.elapsedSeconds == 135)
        #expect(target.pausedDurationMillis == 4_000)
        #expect(target.expectedStatuses == [.running])
        #expect(target.endAt == nil)
    }

    @Test
    func reducerResumesPausedSessionAndAccumulatesPausedDuration() throws {
        let base = Self.date(seconds: 2_000)
        let pauseAnchor = base.addingTimeInterval(12)
        let session = Self.session(
            status: .paused,
            elapsedSeconds: 240,
            pausedDurationMillis: 7_000,
            startTime: base,
            interruptTime: pauseAnchor,
            updatedDate: pauseAnchor
        )

        let target = try #require(
            ReadingTimerLiveActivityControlReducer.targetSnapshot(
                for: session,
                action: .resume,
                at: pauseAnchor.addingTimeInterval(8)
            )
        )

        #expect(target.status == .running)
        #expect(target.elapsedSeconds == 240)
        #expect(target.pausedDurationMillis == 15_000)
        #expect(target.expectedStatuses == [.paused])
        #expect(target.endAt == nil)
    }

    @Test
    func reducerStopsRunningSessionAndSetsEndTime() throws {
        let base = Self.date(seconds: 3_000)
        let now = base.addingTimeInterval(45)
        let session = Self.session(
            status: .running,
            elapsedSeconds: 60,
            pausedDurationMillis: 0,
            startTime: base,
            interruptTime: base.addingTimeInterval(30),
            updatedDate: base.addingTimeInterval(20)
        )

        let target = try #require(
            ReadingTimerLiveActivityControlReducer.targetSnapshot(
                for: session,
                action: .stop,
                at: now
            )
        )

        #expect(target.status == .stoppedPendingSave)
        #expect(target.elapsedSeconds == 75)
        #expect(target.pausedDurationMillis == 0)
        #expect(target.expectedStatuses == [.running, .paused])
        #expect(target.endAt == now)
    }

    @Test
    func reducerStopsPausedSessionWithoutAddingReadingElapsed() throws {
        let base = Self.date(seconds: 4_000)
        let pauseAnchor = base.addingTimeInterval(40)
        let now = pauseAnchor.addingTimeInterval(6)
        let session = Self.session(
            status: .paused,
            elapsedSeconds: 300,
            pausedDurationMillis: 9_000,
            startTime: base,
            interruptTime: pauseAnchor,
            updatedDate: pauseAnchor
        )

        let target = try #require(
            ReadingTimerLiveActivityControlReducer.targetSnapshot(
                for: session,
                action: .stop,
                at: now
            )
        )

        #expect(target.status == .stoppedPendingSave)
        #expect(target.elapsedSeconds == 300)
        #expect(target.pausedDurationMillis == 15_000)
        #expect(target.expectedStatuses == [.running, .paused])
        #expect(target.endAt == now)
    }

    @Test
    func reducerRejectsInvalidTransitions() {
        let pausedSession = Self.session(status: .paused)
        let stoppedSession = Self.session(status: .stoppedPendingSave)
        let finishedSession = Self.session(status: .finished)
        let now = Self.date(seconds: 5_000)

        #expect(ReadingTimerLiveActivityControlReducer.targetSnapshot(for: pausedSession, action: .pause, at: now) == nil)
        #expect(ReadingTimerLiveActivityControlReducer.targetSnapshot(for: stoppedSession, action: .resume, at: now) == nil)
        #expect(ReadingTimerLiveActivityControlReducer.targetSnapshot(for: finishedSession, action: .stop, at: now) == nil)
    }

    @Test
    func repositoryAcceptsReducerPauseResumeAndStopSnapshots() async throws {
        let harness = try Self.makeHarness()
        let startAt = Self.date(seconds: 10_000)
        try await harness.insertBook(id: 9_001, name: "A Kestrel for a Knave")
        let created = try await harness.repository.createSession(bookId: 9_001, startAt: startAt, countdownSeconds: 0)

        let pauseTarget = try #require(
            ReadingTimerLiveActivityControlReducer.targetSnapshot(
                for: created,
                action: .pause,
                at: startAt.addingTimeInterval(25)
            )
        )
        let paused = try await harness.repository.updateSessionSnapshot(Self.input(from: created, target: pauseTarget))
        #expect(paused.status == .paused)
        #expect(paused.elapsedSeconds == 25)
        #expect(paused.pausedDurationMillis == 0)

        let resumeTarget = try #require(
            ReadingTimerLiveActivityControlReducer.targetSnapshot(
                for: paused,
                action: .resume,
                at: startAt.addingTimeInterval(35)
            )
        )
        let resumed = try await harness.repository.updateSessionSnapshot(Self.input(from: paused, target: resumeTarget))
        #expect(resumed.status == .running)
        #expect(resumed.elapsedSeconds == 25)
        #expect(resumed.pausedDurationMillis == 10_000)

        let stopTarget = try #require(
            ReadingTimerLiveActivityControlReducer.targetSnapshot(
                for: resumed,
                action: .stop,
                at: startAt.addingTimeInterval(50)
            )
        )
        let stopped = try await harness.repository.updateSessionSnapshot(Self.input(from: resumed, target: stopTarget))
        #expect(stopped.status == .stoppedPendingSave)
        #expect(stopped.elapsedSeconds == 40)
        #expect(stopped.pausedDurationMillis == 10_000)
        #expect(stopped.endTime == stopTarget.endAt)
    }

    @Test
    func repositoryResumesStoppedSessionByAddingStoppedGapToPausedDuration() async throws {
        let harness = try Self.makeHarness()
        let startAt = Self.date(seconds: 20_000)
        try await harness.insertBook(id: 9_002, name: "The Summer Book")
        let created = try await harness.repository.createSession(
            bookId: 9_002,
            startAt: startAt,
            countdownSeconds: 0
        )
        let stoppedAt = startAt.addingTimeInterval(50)
        let stopped = try await harness.repository.updateSessionSnapshot(
            ReadingTimerSnapshotInput(
                recordId: created.id,
                status: .stoppedPendingSave,
                elapsedSeconds: 40,
                pausedDurationMillis: 10_000,
                expectedStatuses: [.running],
                interruptAt: stoppedAt,
                endAt: stoppedAt
            )
        )

        let resumed = try await harness.repository.resumeStoppedSession(
            recordId: stopped.id,
            resumedAt: stoppedAt.addingTimeInterval(25)
        )

        #expect(resumed.status == .running)
        #expect(resumed.startTime == startAt)
        #expect(resumed.endTime == nil)
        #expect(resumed.elapsedSeconds == 40)
        #expect(resumed.pausedDurationMillis == 35_000)
        #expect(!resumed.isPaused)
    }

    @Test
    func repositoryRejectsContinuingCompletedCountdown() async throws {
        let harness = try Self.makeHarness()
        let startAt = Self.date(seconds: 30_000)
        try await harness.insertBook(id: 9_003, name: "Foster")
        let created = try await harness.repository.createSession(
            bookId: 9_003,
            startAt: startAt,
            countdownSeconds: 30
        )
        let stoppedAt = startAt.addingTimeInterval(30)
        _ = try await harness.repository.updateSessionSnapshot(
            ReadingTimerSnapshotInput(
                recordId: created.id,
                status: .stoppedPendingSave,
                elapsedSeconds: 30,
                pausedDurationMillis: 0,
                expectedStatuses: [.running],
                interruptAt: stoppedAt,
                endAt: stoppedAt
            )
        )

        do {
            _ = try await harness.repository.resumeStoppedSession(
                recordId: created.id,
                resumedAt: stoppedAt.addingTimeInterval(10)
            )
            Issue.record("已完成倒计时不应恢复为运行态")
        } catch ReadingTimerError.staleSessionState {
            // 预期：Repository 层拒绝越过倒计时目标。
        }
    }

    @Test
    func repositoryResetsPauseHistoryWhenFinishTimeRangeIsEdited() async throws {
        let harness = try Self.makeHarness()
        let startAt = Self.date(seconds: 40_000)
        try await harness.insertBook(id: 9_004, name: "Small Things Like These")
        let created = try await harness.repository.createSession(
            bookId: 9_004,
            startAt: startAt,
            countdownSeconds: 0
        )
        let stoppedAt = startAt.addingTimeInterval(120)
        _ = try await harness.repository.updateSessionSnapshot(
            ReadingTimerSnapshotInput(
                recordId: created.id,
                status: .stoppedPendingSave,
                elapsedSeconds: 90,
                pausedDurationMillis: 30_000,
                expectedStatuses: [.running],
                interruptAt: stoppedAt,
                endAt: stoppedAt
            )
        )

        let finished = try await harness.repository.finishSession(
            ReadingTimerFinishInput(
                recordId: created.id,
                targetBookId: 9_004,
                startAt: startAt.addingTimeInterval(10),
                endAt: startAt.addingTimeInterval(70),
                measuredElapsedSeconds: 90,
                measuredPausedDurationMillis: 30_000,
                didEditTimeRange: true,
                position: nil,
                insight: "",
                markReadDone: false
            )
        )

        #expect(finished.status == .finished)
        #expect(finished.elapsedSeconds == 60)
        #expect(finished.pausedDurationMillis == 0)
        #expect(!finished.isPaused)
    }

    @Test
    func repositoryTreatsStoppedSessionAsUnfinishedAndRejectsSecondSession() async throws {
        let harness = try Self.makeHarness()
        let startAt = Self.date(seconds: 50_000)
        try await harness.insertBook(id: 9_005, name: "The Uncommon Reader")
        try await harness.insertBook(id: 9_006, name: "Stoner")
        let created = try await harness.repository.createSession(
            bookId: 9_005,
            startAt: startAt,
            countdownSeconds: 0
        )
        _ = try await harness.repository.updateSessionSnapshot(
            ReadingTimerSnapshotInput(
                recordId: created.id,
                status: .stoppedPendingSave,
                elapsedSeconds: 20,
                pausedDurationMillis: 0,
                expectedStatuses: [.running],
                interruptAt: startAt.addingTimeInterval(20),
                endAt: startAt.addingTimeInterval(20)
            )
        )

        let active = try await harness.repository.fetchActiveSession()
        #expect(active?.id == created.id)
        #expect(active?.status == .stoppedPendingSave)

        do {
            _ = try await harness.repository.createSession(
                bookId: 9_006,
                startAt: startAt.addingTimeInterval(30),
                countdownSeconds: 0
            )
            Issue.record("停止待保存记录未处理前不应创建第二段计时")
        } catch ReadingTimerError.activeSessionExists {
            // 预期：STOP 仍属于未完成状态。
        }
    }

    @Test
    func systemHandoffPersistsExactRouteAndConsumesOnce() throws {
        let harness = try Self.makeHarness()

        ReadingTimerSystemHandoff.save(
            recordId: 7_001,
            bookId: 8_001,
            defaults: harness.userDefaults
        )

        let consumedURL = ReadingTimerSystemHandoff.consumeURL(defaults: harness.userDefaults)
        #expect(consumedURL?.absoluteString == "xmnote://reading-timer/8001?recordId=7001")
        #expect(ReadingTimerSystemHandoff.consumeURL(defaults: harness.userDefaults) == nil)
    }
}

private extension ReadingTimerLiveActivityControlTests {
    struct Harness {
        let dbPool: DatabasePool
        let repository: ReadingTimerRepository
        let userDefaults: UserDefaults

        func insertBook(id: Int64, name: String) async throws {
            try await dbPool.write { db in
                // SQL 目的：插入完整 Android v45 schema 的有效测试书籍，供阅读计时外键与读书状态写入使用。
                // 涉及表：book；user/source/read_status 引用 empty database 的 seed 数据。
                // 关键过滤：无查询过滤；id 由测试用例传入，is_deleted = 0。
                // 时间字段：创建、更新、同步与状态变更时间固定为 0，不参与本组断言。
                // 副作用用途：为计时记录创建、恢复与完成事务提供真实书籍行。
                try db.execute(
                    sql: """
                        INSERT INTO book (
                            id, user_id, douban_id, name, raw_name, cover, author, author_intro, translator,
                            isbn, pub_date, press, summary, read_position, total_position, total_pagination,
                            type, current_position_unit, position_unit, source_id, purchase_date, price,
                            book_order, pinned, pin_order, read_status_id, read_status_changed_date,
                            score, catalog, book_mark_modified_time, word_count, created_date, updated_date,
                            last_sync_date, is_deleted
                        ) VALUES (
                            ?, 1, 0, ?, ?, '', 'Barry Hines', '', '',
                            '', '', '', '', 0, 100, 100,
                            1, 1, 1, 0, 0, 0,
                            0, 0, 0, 2, 0,
                            0, '', 0, NULL, 0, 0,
                            0, 0
                        )
                        """,
                    arguments: [id, name, name]
                )
            }
        }
    }

    static func makeHarness() throws -> Harness {
        let database = try AppDatabase.empty()
        let manager = DatabaseManager(database: database)
        let suiteName = "ReadingTimerLiveActivityControlTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Harness(
            dbPool: database.dbPool,
            repository: ReadingTimerRepository(
                databaseManager: manager,
                userDefaults: userDefaults
            ),
            userDefaults: userDefaults
        )
    }

    static func input(
        from session: ReadingTimerSession,
        target: ReadingTimerLiveActivityControlTarget
    ) -> ReadingTimerSnapshotInput {
        ReadingTimerSnapshotInput(
            recordId: session.id,
            status: target.status,
            elapsedSeconds: target.elapsedSeconds,
            pausedDurationMillis: target.pausedDurationMillis,
            expectedStatuses: target.expectedStatuses,
            interruptAt: target.interruptAt,
            endAt: target.endAt
        )
    }

    static func session(
        status: ReadingTimerRecordStatus,
        elapsedSeconds: Int64 = 0,
        pausedDurationMillis: Int64 = 0,
        startTime: Date? = date(seconds: 1_000),
        interruptTime: Date? = nil,
        updatedDate: Date? = nil
    ) -> ReadingTimerSession {
        ReadingTimerSession(
            id: 1,
            book: ReadingTimerBookContext(
                id: 9_001,
                name: "A Kestrel for a Knave",
                author: "Barry Hines",
                coverURL: "",
                readStatusId: 2,
                readPosition: 0,
                totalPosition: 100,
                totalPagination: 100,
                currentPositionUnit: 1,
                positionUnit: 1
            ),
            startTime: startTime,
            endTime: nil,
            interruptTime: interruptTime,
            elapsedSeconds: elapsedSeconds,
            countdownSeconds: 0,
            pausedDurationMillis: pausedDurationMillis,
            isPaused: status == .paused,
            status: status,
            position: 0,
            recordedPositionUnit: nil,
            fuzzyReadDate: nil,
            insight: "",
            createdDate: startTime,
            updatedDate: updatedDate
        )
    }

    nonisolated static func date(seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
