import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct BookReadingDetailRepositoryTests {
    @Test
    func crossDayTimingUsesAndroidWallClockRatioForHeatmapMonthsAndReadingDays() async throws {
        let harness = try Self.makeHarness()
        let bookID: Int64 = 9_001
        let start = Self.date(2026, 1, 31, hour: 23)
        let end = Self.date(2026, 2, 1, hour: 1)

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: bookID,
                name: "跨月计时",
                createdAt: Self.date(2026, 1, 1),
                readStatusId: 2,
                readStatusChangedAt: Self.date(2026, 1, 1)
            )
            try Self.insertAccurateTiming(
                db,
                bookID: bookID,
                start: start,
                end: end,
                elapsedSeconds: 3_600
            )
        }

        let snapshot = try #require(try await harness.firstSnapshot(bookID: bookID))
        let january = Self.day(2026, 1, 31)
        let february = Self.day(2026, 2, 1)

        #expect(snapshot.analytics.readingDayCount == 2)
        #expect(snapshot.analytics.totalReadingSeconds == 3_600)
        #expect(snapshot.heatmapDays[january]?.readSeconds == 1_800)
        #expect(snapshot.heatmapDays[february]?.readSeconds == 1_800)
        #expect(snapshot.monthlyDurations.map(\.totalSeconds) == [1_800, 1_800])
        #expect(snapshot.monthlyDurations.map(\.month) == [2, 1])
    }

    @Test
    func analyticsUnifiesActiveContentSplitTimingsAllCheckInsAndReadDoneDates() async throws {
        let harness = try Self.makeHarness()
        let bookID: Int64 = 9_010
        let unrelatedBookID: Int64 = 9_011

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: bookID,
                name: "多源活动",
                createdAt: Self.date(2026, 1, 1),
                readStatusId: 3,
                readStatusChangedAt: Self.date(2026, 2, 3)
            )
            try Self.insertBook(
                db,
                id: unrelatedBookID,
                name: "隔离书籍",
                createdAt: Self.date(2026, 1, 1),
                readStatusId: 2,
                readStatusChangedAt: Self.date(2026, 1, 1)
            )

            try Self.insertCheckIn(db, bookID: bookID, at: Self.date(2026, 1, 2), isDeleted: true)
            try Self.insertNote(db, bookID: bookID, at: Self.date(2026, 1, 5), idea: "有效想法")
            try Self.insertNote(db, bookID: bookID, at: Self.date(2026, 1, 6), isDeleted: true)
            try Self.insertRelevant(db, bookID: bookID, at: Self.date(2026, 1, 5))
            try Self.insertReview(db, bookID: bookID, at: Self.date(2026, 1, 7))
            try Self.insertFuzzyTiming(db, bookID: bookID, at: Self.date(2026, 1, 8), elapsedSeconds: 120)
            try Self.insertAccurateTiming(
                db,
                bookID: bookID,
                start: Self.date(2026, 1, 31, hour: 23),
                end: Self.date(2026, 2, 1, hour: 1),
                elapsedSeconds: 3_600
            )
            try Self.insertStatus(db, bookID: bookID, statusID: 3, at: Self.date(2026, 2, 3))

            try Self.insertNote(db, bookID: unrelatedBookID, at: Self.date(2026, 2, 10), idea: "不得串入")
            try Self.insertFuzzyTiming(
                db,
                bookID: unrelatedBookID,
                at: Self.date(2026, 2, 10),
                elapsedSeconds: 9_999
            )
        }

        let snapshot = try #require(try await harness.firstSnapshot(bookID: bookID))

        #expect(snapshot.analytics.readingDayCount == 7)
        #expect(snapshot.analytics.lastReadingAt == Self.millis(Self.day(2026, 2, 3)))
        #expect(snapshot.analytics.actualStartAt == Self.millis(Self.date(2026, 1, 2)))
        #expect(snapshot.analytics.totalReadingSeconds == 3_720)
        #expect(snapshot.analytics.noteCount == 1)
        #expect(snapshot.analytics.ideaCount == 1)
        #expect(snapshot.heatmapDays[Self.day(2026, 1, 2)] == nil)
        #expect(snapshot.heatmapDays[Self.day(2026, 1, 5)]?.noteCount == 1)
        #expect(snapshot.heatmapDays[Self.day(2026, 2, 10)] == nil)
    }

    @Test
    func finishedHeatmapBoundaryIncludesNewestDeletedCheckInButNotItsMark() async throws {
        let harness = try Self.makeHarness()
        let bookID: Int64 = 9_020

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: bookID,
                name: "已读边界",
                createdAt: Self.date(2026, 1, 1),
                readStatusId: 3,
                readStatusChangedAt: Self.date(2026, 2, 1)
            )
            try Self.insertCheckIn(db, bookID: bookID, at: Self.date(2026, 1, 20), isDeleted: false)
            try Self.insertCheckIn(db, bookID: bookID, at: Self.date(2026, 3, 3), isDeleted: true)
        }

        let snapshot = try #require(try await harness.firstSnapshot(bookID: bookID))

        #expect(snapshot.heatmapLatestDate == Self.day(2026, 3, 3))
        #expect(snapshot.heatmapDays[Self.day(2026, 1, 20)]?.checkInCount == 1)
        #expect(snapshot.heatmapDays[Self.day(2026, 3, 3)] == nil)
    }

    @Test
    func emptyBookKeepsAnalyticsAndMonthlyDataEmpty() async throws {
        let harness = try Self.makeHarness()
        let bookID: Int64 = 9_030

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: bookID,
                name: "空数据",
                createdAt: Self.date(2026, 4, 1),
                readStatusId: 1,
                readStatusChangedAt: Self.date(2026, 4, 1)
            )
        }

        let snapshot = try #require(try await harness.firstSnapshot(bookID: bookID))

        #expect(snapshot.analytics.readingDayCount == 0)
        #expect(snapshot.analytics.lastReadingAt == nil)
        #expect(snapshot.analytics.actualStartAt == nil)
        #expect(snapshot.analytics.totalReadingSeconds == 0)
        #expect(snapshot.analytics.noteCount == 0)
        #expect(snapshot.monthlyDurations.isEmpty)
    }
}

private extension BookReadingDetailRepositoryTests {
    struct Harness {
        let dbPool: DatabasePool
        let repository: BookReadingDetailRepository

        func write(_ updates: (Database) throws -> Void) async throws {
            try await dbPool.write { db in
                try updates(db)
            }
        }

        @MainActor
        func firstSnapshot(bookID: Int64) async throws -> BookReadingDetailSnapshot? {
            var iterator = repository.observeSnapshot(bookID: bookID).makeAsyncIterator()
            return try await iterator.next() ?? nil
        }
    }

    static func makeHarness() throws -> Harness {
        let database = try AppDatabase.empty()
        return Harness(
            dbPool: database.dbPool,
            repository: BookReadingDetailRepository(
                databaseManager: DatabaseManager(database: database),
                calendar: calendar
            )
        )
    }

    static func insertBook(
        _ db: Database,
        id: Int64,
        name: String,
        createdAt: Date,
        readStatusId: Int64,
        readStatusChangedAt: Date
    ) throws {
        // SQL 目的：为阅读详情仓储测试创建一条最小有效书籍记录。
        // 涉及表：book。
        // 关键过滤：测试使用显式 id，所有记录均为未删除。
        // 时间字段：created_date/read_status_changed_date 为本地场景对应的 Unix 毫秒。
        // 返回字段用途：为单书快照、进度与热力图区间提供基准数据。
        try db.execute(
            sql: """
                INSERT INTO book (
                    id, user_id, douban_id, name, cover,
                    current_position_unit, position_unit, read_position,
                    total_position, total_pagination, type, source_id,
                    purchase_date, price, book_order, score, book_mark_modified_time,
                    read_status_id, read_status_changed_date, pinned, pin_order,
                    created_date, updated_date, last_sync_date, is_deleted, weread_book_id
                ) VALUES (
                    ?, 1, 0, ?, '',
                    1, 1, 0,
                    100, 100, 1, 0,
                    0, 0, 0, 0, 0,
                    ?, ?, 0, 0,
                    ?, ?, 0, 0, ''
                )
                """,
            arguments: [
                id,
                name,
                readStatusId,
                millis(readStatusChangedAt),
                millis(createdAt),
                millis(createdAt)
            ]
        )
    }

    static func insertAccurateTiming(
        _ db: Database,
        bookID: Int64,
        start: Date,
        end: Date,
        elapsedSeconds: Int64
    ) throws {
        // SQL 目的：创建带真实起止时钟的精确计时，以验证 Android 跨日比例分摊。
        // 涉及表：read_time_record。
        // 关键过滤：status=3、is_deleted=0，fuzzy_read_date=0 表示精确计时。
        // 时间字段：start_time/end_time 为 Unix 毫秒，elapsed_seconds 为实际阅读秒数。
        // 返回字段用途：驱动阅读天数、热力图、月度统计与总时长断言。
        try db.execute(
            sql: """
                INSERT INTO read_time_record (
                    book_id, start_time, end_time, interrupt_time, elapsed_seconds,
                    countdown_seconds, paused_duration_millis, paused, position,
                    status, fuzzy_read_date, weread_read_date, insight,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (
                    ?, ?, ?, 0, ?,
                    0, 0, 0, 0,
                    3, 0, 0, '',
                    ?, ?, 0, 0
                )
                """,
            arguments: [bookID, millis(start), millis(end), elapsedSeconds, millis(start), millis(end)]
        )
    }

    static func insertFuzzyTiming(
        _ db: Database,
        bookID: Int64,
        at date: Date,
        elapsedSeconds: Int64
    ) throws {
        let timestamp = millis(date)
        // SQL 目的：创建整段归属单日的模糊计时记录。
        // 涉及表：read_time_record。
        // 关键过滤：status=3、is_deleted=0，fuzzy_read_date 非零。
        // 时间字段：fuzzy_read_date 为 Unix 毫秒，elapsed_seconds 为阅读秒数。
        // 返回字段用途：验证模糊计时不参与跨日分摊且计入统计。
        try db.execute(
            sql: """
                INSERT INTO read_time_record (
                    book_id, start_time, end_time, interrupt_time, elapsed_seconds,
                    countdown_seconds, paused_duration_millis, paused, position,
                    status, fuzzy_read_date, weread_read_date, insight,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (
                    ?, 0, 0, 0, ?,
                    0, 0, 0, 0,
                    3, ?, 0, '',
                    ?, ?, 0, 0
                )
                """,
            arguments: [bookID, elapsedSeconds, timestamp, timestamp, timestamp]
        )
    }

    static func insertNote(
        _ db: Database,
        bookID: Int64,
        at date: Date,
        idea: String = "",
        isDeleted: Bool = false
    ) throws {
        let timestamp = millis(date)
        // SQL 目的：创建有效或删除态书摘，验证数量、想法与活动日过滤。
        // 涉及表：note。
        // 关键过滤：book_id 精确归属，is_deleted 由测试场景指定。
        // 时间字段：created_date/updated_date 为 Unix 毫秒。
        // 返回字段用途：驱动书摘、想法、阅读天数与热力图断言。
        try db.execute(
            sql: """
                INSERT INTO note (
                    book_id, chapter_id, content, idea, position, position_unit,
                    include_time, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, 0, '', ?, '', 0, 0, ?, ?, 0, ?)
                """,
            arguments: [bookID, idea, timestamp, timestamp, isDeleted ? 1 : 0]
        )
    }

    static func insertRelevant(_ db: Database, bookID: Int64, at date: Date) throws {
        let timestamp = millis(date)
        // SQL 目的：创建相关内容活动源，验证阅读天数按自然日去重。
        // 涉及表：category_content。
        // 关键过滤：book_id 精确归属且 is_deleted=0。
        // 时间字段：created_date/updated_date 为 Unix 毫秒。
        // 返回字段用途：仅参与真实开始时间与阅读日聚合。
        try db.execute(
            sql: """
                INSERT INTO category_content (
                    category_id, book_id, title, content, content_book_id,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (1, ?, '', '', 0, ?, ?, 0, 0)
                """,
            arguments: [bookID, timestamp, timestamp]
        )
    }

    static func insertReview(_ db: Database, bookID: Int64, at date: Date) throws {
        let timestamp = millis(date)
        // SQL 目的：创建书评活动源，验证阅读天数和真实开始时间口径。
        // 涉及表：review。
        // 关键过滤：book_id 精确归属且 is_deleted=0。
        // 时间字段：created_date/updated_date 为 Unix 毫秒。
        // 返回字段用途：参与活动日聚合但不计入书摘数量。
        try db.execute(
            sql: """
                INSERT INTO review (
                    book_id, title, content, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, '', '', ?, ?, 0, 0)
                """,
            arguments: [bookID, timestamp, timestamp]
        )
    }

    static func insertCheckIn(
        _ db: Database,
        bookID: Int64,
        at date: Date,
        isDeleted: Bool
    ) throws {
        let timestamp = millis(date)
        // SQL 目的：创建签到记录，覆盖分析口径不滤删除、热力图标记过滤删除的差异。
        // 涉及表：check_in_record。
        // 关键过滤：book_id 精确归属，is_deleted 由测试场景指定。
        // 时间字段：checkin_date/created_date/updated_date 为 Unix 毫秒。
        // 返回字段用途：驱动阅读日、真实开始、热力图边界和标记断言。
        try db.execute(
            sql: """
                INSERT INTO check_in_record (
                    book_id, amount, position, position_unit, remark,
                    checkin_date, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, 1, '', 0, '', ?, ?, ?, 0, ?)
                """,
            arguments: [bookID, timestamp, timestamp, timestamp, isDeleted ? 1 : 0]
        )
    }

    static func insertStatus(_ db: Database, bookID: Int64, statusID: Int64, at date: Date) throws {
        let timestamp = millis(date)
        // SQL 目的：创建阅读状态历史，验证读完日期参与活动日和热力图状态标记。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id/status_id 精确归属且 is_deleted=0。
        // 时间字段：changed_date/created_date/updated_date 为 Unix 毫秒。
        // 返回字段用途：驱动阅读天数、上次阅读日期和状态热力图断言。
        try db.execute(
            sql: """
                INSERT INTO book_read_status_record (
                    book_id, read_status_id, changed_date, created_date, updated_date,
                    last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, ?, 0, 0)
                """,
            arguments: [bookID, statusID, timestamp, timestamp, timestamp]
        )
    }

    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.startOfDay(for: date(year, month, day))
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }()
}
