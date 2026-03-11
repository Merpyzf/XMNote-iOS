import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct ReadingDashboardRepositoryTests {
    @Test
    func dailyGoalFallsBackFromTodayToLatestThenDefault() async throws {
        let harness = try Self.makeHarness()
        let referenceDate = Self.date(2026, 3, 10, hour: 9)

        let defaultSnapshot = try await harness.firstSnapshot(referenceDate: referenceDate)
        #expect(defaultSnapshot.dailyGoal.targetSeconds == 3600)
        #expect(defaultSnapshot.dailyGoal.readSeconds == 0)

        try await harness.write { db in
            try Self.insertDailyGoal(db, date: Self.date(2026, 3, 9, hour: 8), targetSeconds: 1800)
        }

        let fallbackSnapshot = try await harness.firstSnapshot(referenceDate: referenceDate)
        #expect(fallbackSnapshot.dailyGoal.targetSeconds == 1800)

        try await harness.write { db in
            try Self.insertDailyGoal(db, date: referenceDate, targetSeconds: 2400)
            try Self.insertReadRecord(
                db,
                bookId: 0,
                at: Self.date(2026, 3, 10, hour: 10),
                elapsedSeconds: 900
            )
        }

        let todaySnapshot = try await harness.firstSnapshot(referenceDate: referenceDate)
        #expect(todaySnapshot.dailyGoal.targetSeconds == 2400)
        #expect(todaySnapshot.dailyGoal.readSeconds == 900)
    }

    @Test
    func recentBooksDeduplicateAcrossSourcesAndSortByLatestActivity() async throws {
        let harness = try Self.makeHarness()
        let referenceDate = Self.date(2026, 3, 10, hour: 9)

        try await harness.write { db in
            try Self.insertBook(db, id: 1_001, name: "第一本", readStatusId: BookReadingStatus.reading.rawValue)
            try Self.insertBook(db, id: 1_002, name: "第二本", readStatusId: BookReadingStatus.reading.rawValue)
            try Self.insertBook(db, id: 1_003, name: "第三本", readStatusId: BookReadingStatus.reading.rawValue, bookmarkModifiedTime: Self.millis(Self.date(2026, 3, 9, hour: 22)))

            try Self.insertNote(db, bookId: 1_001, createdAt: Self.date(2026, 3, 8, hour: 9))
            try Self.insertReview(db, bookId: 1_001, createdAt: Self.date(2026, 3, 9, hour: 12))
            try Self.insertReadRecord(db, bookId: 1_001, at: Self.date(2026, 3, 9, hour: 14), elapsedSeconds: 600)

            try Self.insertCategoryContent(db, bookId: 1_002, createdAt: Self.date(2026, 3, 9, hour: 11))
            try Self.insertCheckInRecord(db, bookId: 1_002, checkInAt: Self.date(2026, 3, 10, hour: 8))
            try Self.insertNote(db, bookId: 1_002, createdAt: Self.date(2026, 3, 8, hour: 8))
        }

        let snapshot = try await harness.firstSnapshot(referenceDate: referenceDate)
        let books = snapshot.recentBooks.prefix(3)

        #expect(Array(books.map(\.id)) == [1_002, 1_003, 1_001])
        #expect(Set(books.map(\.id)).count == 3)
        #expect(books[0].latestActivityAt == Self.millis(Self.date(2026, 3, 10, hour: 8)))
        #expect(books[2].latestActivityAt == Self.millis(Self.date(2026, 3, 9, hour: 14)))
    }

    @Test
    func resumeBookSkipsReadDoneAndAbandonStatuses() async throws {
        let harness = try Self.makeHarness()
        let referenceDate = Self.date(2026, 3, 10, hour: 9)

        try await harness.write { db in
            try Self.insertBook(db, id: 1_010, name: "已读书", readStatusId: BookReadingStatus.readDone.rawValue)
            try Self.insertBook(db, id: 1_011, name: "弃读书", readStatusId: BookReadingStatus.abandon.rawValue)
            try Self.insertBook(db, id: 1_012, name: "正在读", readStatusId: BookReadingStatus.reading.rawValue)

            try Self.insertReadRecord(db, bookId: 1_010, at: Self.date(2026, 3, 10, hour: 12), elapsedSeconds: 300)
            try Self.insertReadRecord(db, bookId: 1_011, at: Self.date(2026, 3, 10, hour: 11), elapsedSeconds: 300)
            try Self.insertReadRecord(db, bookId: 1_012, at: Self.date(2026, 3, 10, hour: 10), elapsedSeconds: 300)
        }

        let snapshot = try await harness.firstSnapshot(referenceDate: referenceDate)
        #expect(snapshot.resumeBook?.id == 1_012)
        #expect(snapshot.resumeBook?.name == "正在读")
    }

    @Test
    func yearSummaryCombinesBookTableAndStatusHistorySources() async throws {
        let harness = try Self.makeHarness()
        let referenceDate = Self.date(2026, 12, 20, hour: 9)

        try await harness.write { db in
            try Self.insertYearlyGoal(db, year: 2026, targetCount: 15)

            try Self.insertBook(
                db,
                id: 1_020,
                name: "表内已读",
                readStatusId: BookReadingStatus.readDone.rawValue,
                readStatusChangedDate: Self.millis(Self.date(2026, 5, 10, hour: 9))
            )
            try Self.insertBook(
                db,
                id: 1_021,
                name: "历史已读",
                readStatusId: BookReadingStatus.reading.rawValue,
                readStatusChangedDate: Self.millis(Self.date(2026, 1, 5, hour: 9))
            )
            try Self.insertBook(
                db,
                id: 1_022,
                name: "去年已读",
                readStatusId: BookReadingStatus.readDone.rawValue,
                readStatusChangedDate: Self.millis(Self.date(2025, 12, 31, hour: 23))
            )

            try Self.insertReadStatusRecord(
                db,
                bookId: 1_021,
                statusId: BookReadingStatus.readDone.rawValue,
                changedAt: Self.date(2026, 10, 1, hour: 8)
            )
            try Self.insertReadStatusRecord(
                db,
                bookId: 1_021,
                statusId: BookReadingStatus.readDone.rawValue,
                changedAt: Self.date(2024, 10, 1, hour: 8)
            )

            try Self.insertReadRecord(db, bookId: 1_020, at: Self.date(2026, 5, 1, hour: 20), elapsedSeconds: 1200)
            try Self.insertReadRecord(db, bookId: 1_021, at: Self.date(2026, 10, 2, hour: 20), elapsedSeconds: 600)
            try Self.insertReadRecord(db, bookId: 1_022, at: Self.date(2025, 12, 1, hour: 20), elapsedSeconds: 500)
        }

        let snapshot = try await harness.firstSnapshot(referenceDate: referenceDate)
        let summary = snapshot.yearSummary

        #expect(summary.targetCount == 15)
        #expect(summary.readCount == 2)
        #expect(summary.books.map(\.id) == [1_021, 1_020])
        #expect(summary.books.first?.totalReadSeconds == 600)
        #expect(summary.books.first?.readDoneCount == 2)
    }

    @Test
    func trendMetricsKeepFixedWindowsAndFillMissingPeriodsWithZero() async throws {
        let harness = try Self.makeHarness()
        let referenceDate = Self.date(2026, 3, 10, hour: 9)

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: 1_031,
                name: "二月读完",
                readStatusId: BookReadingStatus.readDone.rawValue,
                readStatusChangedDate: Self.millis(Self.date(2026, 2, 5, hour: 10))
            )

            try Self.insertReadRecord(
                db,
                bookId: 1_031,
                at: Self.date(2026, 3, 10, hour: 8),
                elapsedSeconds: 600
            )
            try Self.insertNote(
                db,
                bookId: 1_031,
                createdAt: Self.date(2026, 3, 9, hour: 7)
            )
        }

        let snapshot = try await harness.firstSnapshot(referenceDate: referenceDate)
        let metrics = Dictionary(uniqueKeysWithValues: snapshot.trends.map { ($0.kind, $0) })

        let readingMetric = try #require(metrics[.readingDuration])
        #expect(readingMetric.points.count == 7)
        #expect(readingMetric.points.map(\.value) == [0, 0, 0, 0, 0, 0, 600])

        let noteMetric = try #require(metrics[.noteCount])
        #expect(noteMetric.points.count == 7)
        #expect(noteMetric.points.map(\.value) == [0, 0, 0, 0, 0, 1, 0])

        let readDoneMetric = try #require(metrics[.readDoneCount])
        #expect(readDoneMetric.points.count == 7)
        #expect(readDoneMetric.points.map(\.label) == ["9月", "10月", "11月", "12月", "1月", "2月", "3月"])
        #expect(readDoneMetric.points.map(\.value) == [0, 0, 0, 0, 0, 1, 0])
    }
}

private extension ReadingDashboardRepositoryTests {
    struct Harness {
        let dbPool: DatabasePool
        let repository: ReadingDashboardRepository

        func write(_ updates: (Database) throws -> Void) async throws {
            try await dbPool.write { db in
                try updates(db)
            }
        }

        func firstSnapshot(referenceDate: Date) async throws -> ReadingDashboardSnapshot {
            var iterator = repository.observeDashboard(referenceDate: referenceDate).makeAsyncIterator()
            guard let snapshot = try await iterator.next() else {
                throw SnapshotError.missingInitialSnapshot
            }
            return snapshot
        }
    }

    enum SnapshotError: Error {
        case missingInitialSnapshot
    }

    static func makeHarness() throws -> Harness {
        let database = try AppDatabase.empty()
        let manager = DatabaseManager(database: database)
        return Harness(
            dbPool: database.dbPool,
            repository: ReadingDashboardRepository(databaseManager: manager)
        )
    }

    static func insertBook(
        _ db: Database,
        id: Int64,
        name: String,
        readStatusId: Int64,
        readStatusChangedDate: Int64 = 0,
        bookmarkModifiedTime: Int64 = 0
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO book (
                    id, name, cover, read_status_id, read_status_changed_date,
                    current_position_unit, read_position, total_position, total_pagination,
                    book_mark_modified_time, created_date, updated_date, is_deleted
                ) VALUES (?, ?, '', ?, ?, 1, 0, 100, 100, ?, 0, 0, 0)
                """,
            arguments: [id, name, readStatusId, readStatusChangedDate, bookmarkModifiedTime]
        )
    }

    static func insertDailyGoal(_ db: Database, date: Date, targetSeconds: Int) throws {
        let timestamp = millis(Calendar.current.startOfDay(for: date))
        try db.execute(
            sql: """
                INSERT INTO read_target (time, target, type, created_date, updated_date, is_deleted)
                VALUES (?, ?, 1, 0, 0, 0)
                """,
            arguments: [timestamp, targetSeconds]
        )
    }

    static func insertYearlyGoal(_ db: Database, year: Int, targetCount: Int) throws {
        try db.execute(
            sql: """
                INSERT INTO read_target (time, target, type, created_date, updated_date, is_deleted)
                VALUES (?, ?, 0, 0, 0, 0)
                """,
            arguments: [year, targetCount]
        )
    }

    static func insertReadRecord(_ db: Database, bookId: Int64, at date: Date, elapsedSeconds: Int) throws {
        let timestamp = millis(date)
        try db.execute(
            sql: """
                INSERT INTO read_time_record (
                    book_id, start_time, end_time, elapsed_seconds, status,
                    fuzzy_read_date, created_date, updated_date, is_deleted
                ) VALUES (?, ?, ?, ?, 3, ?, ?, ?, 0)
                """,
            arguments: [bookId, timestamp, timestamp + 1_000, elapsedSeconds, timestamp, timestamp, timestamp]
        )
    }

    static func insertNote(_ db: Database, bookId: Int64, createdAt date: Date) throws {
        let timestamp = millis(date)
        try db.execute(
            sql: """
                INSERT INTO note (book_id, content, idea, position, created_date, updated_date, is_deleted)
                VALUES (?, '', '', '', ?, ?, 0)
                """,
            arguments: [bookId, timestamp, timestamp]
        )
    }

    static func insertReview(_ db: Database, bookId: Int64, createdAt date: Date) throws {
        let timestamp = millis(date)
        try db.execute(
            sql: """
                INSERT INTO review (book_id, title, content, created_date, updated_date, is_deleted)
                VALUES (?, '', '', ?, ?, 0)
                """,
            arguments: [bookId, timestamp, timestamp]
        )
    }

    static func insertCategoryContent(_ db: Database, bookId: Int64, createdAt date: Date) throws {
        let timestamp = millis(date)
        try db.execute(
            sql: """
                INSERT INTO category_content (
                    category_id, book_id, title, content, content_book_id,
                    created_date, updated_date, is_deleted
                ) VALUES (0, ?, '', '', 0, ?, ?, 0)
                """,
            arguments: [bookId, timestamp, timestamp]
        )
    }

    static func insertCheckInRecord(_ db: Database, bookId: Int64, checkInAt date: Date) throws {
        let timestamp = millis(date)
        try db.execute(
            sql: """
                INSERT INTO check_in_record (
                    book_id, amount, position, position_unit, remark,
                    checkin_date, created_date, updated_date, is_deleted
                ) VALUES (?, 0, '', 0, '', ?, ?, ?, 0)
                """,
            arguments: [bookId, timestamp, timestamp, timestamp]
        )
    }

    static func insertReadStatusRecord(_ db: Database, bookId: Int64, statusId: Int64, changedAt date: Date) throws {
        let timestamp = millis(date)
        try db.execute(
            sql: """
                INSERT INTO book_read_status_record (
                    book_id, read_status_id, changed_date, created_date, updated_date, is_deleted
                ) VALUES (?, ?, ?, ?, ?, 0)
                """,
            arguments: [bookId, statusId, timestamp, timestamp, timestamp]
        )
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
