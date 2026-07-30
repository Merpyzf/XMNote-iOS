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
}

private extension ReadingTimerLiveActivityControlTests {
    struct Harness {
        let dbPool: DatabasePool
        let repository: ReadingTimerRepository

        func insertBook(id: Int64, name: String) async throws {
            try await dbPool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO book (
                            id, name, author, cover, read_status_id,
                            current_position_unit, position_unit, read_position,
                            total_position, total_pagination, created_date,
                            updated_date, is_deleted
                        ) VALUES (?, ?, 'Barry Hines', '', 2, 1, 1, 0, 100, 100, 0, 0, 0)
                        """,
                    arguments: [id, name]
                )
            }
        }
    }

    static func makeHarness() throws -> Harness {
        let database = try AppDatabase.empty()
        let manager = DatabaseManager(database: database)
        return Harness(
            dbPool: database.dbPool,
            repository: ReadingTimerRepository(databaseManager: manager)
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
