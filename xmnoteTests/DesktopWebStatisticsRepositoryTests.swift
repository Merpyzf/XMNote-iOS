/**
 * [INPUT]: 依赖 AppDatabase.empty、V44 GRDB Record 与 DesktopWebStatisticsRepository
 * [OUTPUT]: 验证 StatisticsController 20 条 API 的跨日统计、目标副作用、概览、图表、热力图及年度书单语义
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android StatisticsWebService/StatisticsRepository 当前可观察行为
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct DesktopWebStatisticsRepositoryTests {
    @Test
    func monthlyAndWeeklyReadingSplitAccurateRecordsButKeepFuzzyRecordsOnTheirDate() async throws {
        let fixture = try makeStatisticsFixture()
        try statisticsSeedBook(fixture.database, id: 101)
        try statisticsSeedReadRecord(
            fixture.database,
            id: 111,
            bookID: 101,
            start: statisticsMillis(2026, 7, 1, 23, 50),
            end: statisticsMillis(2026, 7, 2, 0, 10),
            seconds: 1_200
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 112,
            bookID: 101,
            fuzzyDate: statisticsMillis(2026, 7, 2, 12),
            seconds: 300
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 113,
            bookID: 101,
            fuzzyDate: statisticsMillis(2026, 7, 22, 12),
            seconds: 60
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 114,
            bookID: 101,
            fuzzyDate: statisticsMillis(2026, 7, 23, 12),
            seconds: 90
        )

        let monthly = try await fixture.repository.monthlyReading(year: 2026, month: 7)
        #expect(monthly.daysInMonth == 31)
        #expect(monthly.totalReadTime == 1_650)
        #expect(monthly.dailyReadingTimes.first { $0.day == 1 }?.readTime == 600)
        #expect(monthly.dailyReadingTimes.first { $0.day == 2 }?.readTime == 900)

        let weekly = try await fixture.repository.weeklyReading(weekStart: "2026-07-20")
        #expect(weekly.weekStart == "2026-07-20")
        #expect(weekly.weekEnd == "2026-07-26")
        #expect(weekly.totalReadTime == 150)
        #expect(weekly.currentStreak == 2)
        #expect(weekly.days.map(\.dayOfWeek) == Array(1...7))
    }

    @Test
    func rhythmUsesAccurateRecordsOnlyForSegmentsButIncludesFuzzyDurationInScopeTotal() async throws {
        let fixture = try makeStatisticsFixture()
        try statisticsSeedBook(fixture.database, id: 201)
        try statisticsSeedReadRecord(
            fixture.database,
            id: 211,
            bookID: 201,
            start: statisticsMillis(2026, 7, 23, 21, 5),
            end: statisticsMillis(2026, 7, 23, 21, 15),
            seconds: 600
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 212,
            bookID: 201,
            fuzzyDate: statisticsMillis(2026, 7, 23, 8),
            seconds: 300
        )

        let result = try await fixture.repository.readingRhythm(year: 2026, month: 7, weekStart: nil)
        #expect(result.totalReadTime == 600)
        #expect(result.scopeTotalReadTime == 900)
        #expect(result.accurateReadTime == 600)
        #expect(result.fuzzyReadTime == 300)
        #expect(result.peakSegmentIDs == ["night"])
        #expect(result.mostFrequentTime == "21:05")
        #expect(result.segments.first { $0.id == "night" }?.readTime == 600)
    }

    @Test
    func heatmapAssignsWholeRawCrossDayRecordToStartDateAndCombinesAllEventKinds() async throws {
        let fixture = try makeStatisticsFixture()
        try statisticsSeedBook(fixture.database, id: 301, status: 2)
        try statisticsSeedReadRecord(
            fixture.database,
            id: 311,
            bookID: 301,
            start: statisticsMillis(2026, 7, 1, 23, 50),
            end: statisticsMillis(2026, 7, 2, 0, 10),
            seconds: 1_200
        )
        for index in 0..<6 {
            try statisticsSeedNote(
                fixture.database,
                id: 320 + Int64(index),
                bookID: 301,
                created: statisticsMillis(2026, 7, 1, 10, index)
            )
        }
        try statisticsSeedCheckIn(
            fixture.database,
            id: 331,
            bookID: 301,
            amount: 2,
            date: statisticsMillis(2026, 7, 1, 9)
        )
        try statisticsSeedStatus(
            fixture.database,
            id: 341,
            bookID: 301,
            status: 5,
            changed: statisticsMillis(2026, 7, 1, 8)
        )

        let result = try await fixture.repository.heatmap(year: 2026, type: "all")
        let first = try #require(result.days.first { $0.date == "2026-07-01" })
        #expect(first.readTime == 1_200)
        #expect(first.noteCount == 6)
        #expect(first.checkInTime == 2_400)
        #expect(first.bookStates == [false, false, false, true, false])
        #expect(first.level == 2)
        #expect(result.days.first { $0.date == "2026-07-02" }?.readTime == 0)
        #expect(result.days.count == 365)
        #expect(result.startDate == "2026-01-01")
        #expect(result.endDate == "2026-12-31")
        #expect(result.yearRange == [2026])
    }

    @Test
    func heatmapKeepsDeletedCheckInRangeLeakAndExcludesFinalYearMilliseconds() async throws {
        let fixture = try makeStatisticsFixture()
        try statisticsSeedBook(fixture.database, id: 351)
        try statisticsSeedReadRecord(
            fixture.database,
            id: 350,
            bookID: 351,
            fuzzyDate: statisticsMillis(2026, 1, 1),
            seconds: 1_346
        )
        try statisticsSeedCheckIn(
            fixture.database,
            id: 352,
            bookID: 351,
            amount: 1,
            date: statisticsMillis(2025, 1, 2),
            isDeleted: 1
        )
        try statisticsSeedCheckIn(
            fixture.database,
            id: 353,
            bookID: 351,
            amount: 1,
            date: statisticsMillis(2026, 12, 31, 23, 59) + 59_500
        )

        let all = try await fixture.repository.heatmap(year: 0, type: "check_in")
        #expect(all.startDate == "2026-01-01")
        #expect(all.yearRange == [2026])
        #expect(all.days.first { $0.date == "2025-01-02" } == nil)

        let year = try await fixture.repository.heatmap(year: 2026, type: "check_in")
        #expect(year.days.first { $0.date == "2026-01-01" }?.readTime == 1_346)
        #expect(year.days.first { $0.date == "2026-12-31" }?.checkInTime == 1_200)
    }

    @Test
    func targetReadsDefaultsAndWritesKeepAndroidAuditAndGetSideEffectSemantics() async throws {
        let fixture = try makeStatisticsFixture(latestDailyTarget: 1_800)
        #expect(try await fixture.repository.readTarget(year: 2026) == .init(year: 2026, target: 12))

        let yearly = try await fixture.repository.setReadTarget(year: 2026, target: 365)
        #expect(yearly == .init(year: 2026, target: 365))
        #expect(try await fixture.repository.readTargets() == [.init(year: 2026, target: 365)])
        await expectStatisticsError(.invalidDateInput("year 必须大于 0")) {
            _ = try await fixture.repository.setReadTarget(year: -1, target: 1)
        }
        await expectStatisticsError(.invalidDateInput("年度阅读目标必须在 1 到 365 之间")) {
            _ = try await fixture.repository.setReadTarget(year: 2026, target: 0)
        }
        await expectStatisticsError(.invalidDateInput("年度阅读目标必须在 1 到 365 之间")) {
            _ = try await fixture.repository.setReadTarget(year: 2026, target: 366)
        }

        #expect(try await fixture.repository.yearlyGoalCelebration(year: 2026) == false)
        try await fixture.repository.markYearlyGoalCelebration(year: 2026)
        #expect(try await fixture.repository.yearlyGoalCelebration(year: 2026) == true)

        let daily = try await fixture.repository.dailyReadingTarget()
        #expect(daily.target == 1_800)
        #expect(daily.todayReadingTime == 0)
        let createdRows = try fixture.database.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT type, target, created_date, updated_date FROM read_target ORDER BY id"
            )
        }
        #expect(createdRows.count == 3)
        #expect(createdRows.allSatisfy { ($0["created_date"] as Int64) == 0 && ($0["updated_date"] as Int64) == 0 })

        #expect(try await fixture.repository.setDailyReadingTarget(0).target == 0)
        await expectStatisticsError(.negativeDailyTarget) {
            _ = try await fixture.repository.setDailyReadingTarget(-1)
        }
        await expectStatisticsError(.invalidYear) {
            _ = try await fixture.repository.yearlyGoalCelebration(year: 0)
        }
    }

    @Test
    func overviewCombinesMetricsCurrentStatusAndPreviousMonthComparison() async throws {
        let fixture = try makeStatisticsFixture()
        try statisticsSeedBook(
            fixture.database,
            id: 401,
            status: 3,
            statusChanged: statisticsMillis(2026, 7, 10),
            wordCount: 12_345,
            purchaseDate: statisticsMillis(2026, 7, 2),
            price: 10
        )
        try statisticsSeedStatus(
            fixture.database,
            id: 411,
            bookID: 401,
            status: 3,
            changed: statisticsMillis(2026, 7, 10)
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 412,
            bookID: 401,
            fuzzyDate: statisticsMillis(2026, 7, 3),
            seconds: 600
        )
        try statisticsSeedNote(
            fixture.database,
            id: 413,
            bookID: 401,
            created: statisticsMillis(2026, 7, 4)
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 414,
            bookID: 401,
            fuzzyDate: statisticsMillis(2026, 6, 3),
            seconds: 100
        )

        let result = try await fixture.repository.overview(year: 2026, month: 7, weekStart: nil)
        #expect(result.totalReadingTime == 600)
        #expect(result.readingDays == 2)
        #expect(result.noteCount == 1)
        #expect(result.readDoneBookCount == 1)
        #expect(result.totalWordCount == 12_345)
        #expect(result.purchaseBookCount == 1)
        #expect(result.statusDistribution == [.init(status: 3, label: "读完", count: 1, ratio: 1)])
        #expect(result.readingTimeTrendUnit == "日")
        #expect(result.readingTimeTrend.first { $0.label == 3 }?.value == 600)
        #expect(result.comparison?.mode == "month_over_month")
        #expect(result.comparison?.hasBaseline == true)
        #expect(result.comparison?.delta?.totalReadingTime == 500)
    }

    @Test
    func sevenChartsUseAndroidBucketsTotalsAndEligibilitySets() async throws {
        let fixture = try makeStatisticsFixture()
        try statisticsSeedSource(fixture.database, id: 9_901, name: "纸书", order: 1)
        try statisticsSeedBook(
            fixture.database,
            id: 501,
            status: 3,
            statusChanged: statisticsMillis(2026, 7, 10),
            sourceID: 9_901,
            wordCount: 12_000,
            purchaseDate: statisticsMillis(2026, 7, 2),
            price: 12.75
        )
        try statisticsSeedStatus(
            fixture.database,
            id: 511,
            bookID: 501,
            status: 3,
            changed: statisticsMillis(2026, 7, 10)
        )
        try statisticsSeedNote(
            fixture.database,
            id: 512,
            bookID: 501,
            created: statisticsMillis(2026, 7, 4)
        )
        try statisticsSeedTag(fixture.database, id: 521, name: "笔记标签", type: 1, order: 1)
        try statisticsSeedTag(fixture.database, id: 522, name: "书籍标签", type: 2, order: 1)
        try statisticsSeedTagNote(fixture.database, id: 531, tagID: 521, noteID: 512)
        try statisticsSeedTagBook(fixture.database, id: 532, tagID: 522, bookID: 501)

        let note = try await fixture.repository.noteCountChart(year: 2026, month: 7, weekStart: nil)
        #expect(note.unit == "日")
        #expect(note.total == "1条")
        #expect(note.items.first { $0.label == 4 }?.value == 1)
        let done = try await fixture.repository.readDoneChart(year: 2026, month: 7, weekStart: nil)
        #expect(done.total == "1本")
        #expect(done.items.first { $0.label == 10 }?.value == 1)
        let words = try await fixture.repository.wordCountChart(year: 2026, month: 7, weekStart: nil)
        #expect(words.total == "1.2万字")
        #expect(words.items.first { $0.label == 10 }?.value == 12_000)
        let purchase = try await fixture.repository.purchaseChart(year: 2026, month: 7, weekStart: nil)
        #expect(purchase.totalMoney == 12.75)
        #expect(purchase.totalCount == 1)
        #expect(purchase.items.first { $0.label == 2 }?.value == 12)
        #expect(purchase.countItems.first { $0.label == 2 }?.value == 1)

        let source = try await fixture.repository.bookSourceChart(year: 2026, month: 7, weekStart: nil)
        #expect(source.map(\.label) == ["纸书"])
        #expect(source.first?.ratio == 1)
        let noteTag = try await fixture.repository.noteTagChart(year: 2026, month: 7, weekStart: nil)
        #expect(noteTag.map(\.label) == ["笔记标签"])
        let bookTag = try await fixture.repository.bookTagChart(year: 2026, month: 7, weekStart: nil)
        #expect(bookTag.map(\.label) == ["书籍标签"])
    }

    @Test
    func noteTagAllCountsRelationsToDeletedNotesButRangeModeDoesNot() async throws {
        let fixture = try makeStatisticsFixture()
        try statisticsSeedBook(fixture.database, id: 601)
        try statisticsSeedNote(
            fixture.database,
            id: 611,
            bookID: 601,
            created: statisticsMillis(2026, 7, 1),
            isDeleted: 1
        )
        try statisticsSeedTag(fixture.database, id: 621, name: "残留关系", type: 1)
        try statisticsSeedTagNote(fixture.database, id: 631, tagID: 621, noteID: 611)

        // NOTE(ANDROID-WEB-058): 最新 Android 的 all 模式有意不连接 note，已删除书摘遗留关系仍会计入标签饼图。
        #expect(try await fixture.repository.noteTagChart(year: 0, month: 0, weekStart: nil).first?.count == 1)
        #expect(try await fixture.repository.noteTagChart(year: 2026, month: 7, weekStart: nil).isEmpty)
    }

    @Test
    func yearlyBooksDeduplicatesByBookAndUsesLatestDoneTimeDescending() async throws {
        let fixture = try makeStatisticsFixture()
        try statisticsSeedBook(fixture.database, id: 701, name: "A", status: 2)
        try statisticsSeedBook(
            fixture.database,
            id: 702,
            name: "B",
            status: 3,
            statusChanged: statisticsMillis(2026, 7, 20)
        )
        try statisticsSeedStatus(
            fixture.database,
            id: 711,
            bookID: 701,
            status: 3,
            changed: statisticsMillis(2026, 3, 1)
        )
        try statisticsSeedStatus(
            fixture.database,
            id: 712,
            bookID: 701,
            status: 3,
            changed: statisticsMillis(2026, 8, 1)
        )

        let result = try await fixture.repository.yearlyBooks(year: 2026)
        #expect(result.year == 2026)
        #expect(result.books.map { $0.book.id } == [701, 702])
        #expect(result.books.first?.readDoneTime == statisticsMillis(2026, 8, 1))
        #expect(result.years == [2026])
    }

    @Test
    func invalidDateInputsFailAtRepositoryBoundary() async throws {
        let fixture = try makeStatisticsFixture()
        await expectStatisticsError(.invalidDateInput("month 必须在 1 到 12 之间")) {
            _ = try await fixture.repository.monthlyReading(year: 2026, month: 13)
        }
        await expectStatisticsError(.invalidDateInput("Invalid date 'FEBRUARY 30'")) {
            _ = try await fixture.repository.weeklyReading(weekStart: "2026-02-30")
        }
        let messages: [(String, String)] = [
            ("not-a-date", "Text 'not-a-date' could not be parsed at index 0"),
            ("2026-13-01", "Invalid value for MonthOfYear (valid values 1 - 12): 13"),
            ("2026-7-1", "Text '2026-7-1' could not be parsed at index 5"),
            ("2026-07", "Text '2026-07' could not be parsed at index 7"),
            ("2026-07-01x", "Text '2026-07-01x' could not be parsed, unparsed text found at index 10"),
            ("2025-02-29", "Invalid date 'February 29' as '2025' is not a leap year")
        ]
        for (value, message) in messages {
            await expectStatisticsError(.invalidDateInput(message)) {
                _ = try await fixture.repository.weeklyReading(weekStart: value)
            }
        }
    }

    @Test
    func yearScopeClearsResidualMillisecondsAtBothCalendarBoundaries() async throws {
        let now = statisticsMillis(2026, 7, 23, 12) + 789
        let fixture = try makeStatisticsFixture(currentTimeMillis: now)
        try statisticsSeedBook(fixture.database, id: 801)
        try statisticsSeedReadRecord(
            fixture.database,
            id: 811,
            bookID: 801,
            fuzzyDate: statisticsMillis(2022, 1, 1),
            seconds: 100
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 812,
            bookID: 801,
            fuzzyDate: statisticsMillis(2022, 1, 1) + 789,
            seconds: 200
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 813,
            bookID: 801,
            fuzzyDate: statisticsMillis(2022, 12, 31, 23, 59) + 59_789,
            seconds: 300
        )
        try statisticsSeedReadRecord(
            fixture.database,
            id: 814,
            bookID: 801,
            fuzzyDate: statisticsMillis(2022, 12, 31, 23, 59) + 59_790,
            seconds: 400
        )

        let rhythm = try await fixture.repository.readingRhythm(year: 2022, month: 0, weekStart: nil)
        #expect(rhythm.fuzzyReadTime == 1_000)
    }
}

private struct StatisticsFixture {
    let database: AppDatabase
    let repository: DesktopWebStatisticsRepository
}

@MainActor
private func makeStatisticsFixture(
    latestDailyTarget: Int = 3_600,
    currentTimeMillis: Int64 = statisticsMillis(2026, 7, 23, 12)
) throws -> StatisticsFixture {
    let database = try AppDatabase.empty()
    let bookRepository = DesktopWebBookRepository(
        database: database,
        currentTimeMillis: { currentTimeMillis }
    )
    return StatisticsFixture(
        database: database,
        repository: DesktopWebStatisticsRepository(
            database: database,
            bookRepository: bookRepository,
            calendar: statisticsCalendar,
            currentTimeMillis: { currentTimeMillis },
            latestDailyTarget: { latestDailyTarget },
            saveLatestDailyTarget: { _ in }
        )
    )
}

private let statisticsCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "zh_CN")
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

private func statisticsMillis(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0
) -> Int64 {
    let date = statisticsCalendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
    return Int64(date.timeIntervalSince1970 * 1_000)
}

private func statisticsSeedBook(
    _ database: AppDatabase,
    id: Int64,
    name: String = "Book",
    status: Int64 = 1,
    statusChanged: Int64 = 0,
    sourceID: Int64 = 1,
    wordCount: Int64? = nil,
    purchaseDate: Int64 = 0,
    price: Double = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: name,
            rawName: name,
            cover: "cover",
            author: "Author",
            sourceId: sourceID,
            purchaseDate: purchaseDate,
            price: price,
            readStatusId: status,
            readStatusChangedDate: statusChanged,
            wordCount: wordCount,
            createdDate: statisticsMillis(2026, 1, 1),
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func statisticsSeedReadRecord(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    start: Int64 = 0,
    end: Int64 = 0,
    fuzzyDate: Int64 = 0,
    seconds: Int64,
    status: Int64 = 3,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = ReadTimeRecordRecord(
            id: id,
            bookId: bookID,
            startTime: start,
            endTime: end,
            elapsedSeconds: seconds,
            status: status,
            fuzzyReadDate: fuzzyDate,
            createdDate: start != 0 ? start : fuzzyDate,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func statisticsSeedNote(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    created: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = NoteRecord(
            id: id,
            bookId: bookID,
            content: "note",
            createdDate: created,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func statisticsSeedStatus(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    status: Int64,
    changed: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookReadStatusRecordRecord(
            id: id,
            bookId: bookID,
            readStatusId: status,
            changedDate: changed,
            createdDate: changed,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func statisticsSeedCheckIn(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    amount: Int64,
    date: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = CheckInRecordRecord(
            id: id,
            bookId: bookID,
            amount: amount,
            checkinDate: date,
            createdDate: date,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func statisticsSeedSource(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    order: Int64
) throws {
    try database.dbPool.write { db in
        var record = SourceRecord(id: id, name: name, sourceOrder: order, createdDate: 1)
        try record.insert(db)
    }
}

private func statisticsSeedTag(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    type: Int64,
    order: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = TagRecord(
            id: id,
            userId: 1,
            name: name,
            tagOrder: order,
            type: type,
            createdDate: 1
        )
        try record.insert(db)
    }
}

private func statisticsSeedTagNote(
    _ database: AppDatabase,
    id: Int64,
    tagID: Int64,
    noteID: Int64
) throws {
    try database.dbPool.write { db in
        var record = TagNoteRecord(id: id, tagId: tagID, noteId: noteID, createdDate: 1)
        try record.insert(db)
    }
}

private func statisticsSeedTagBook(
    _ database: AppDatabase,
    id: Int64,
    tagID: Int64,
    bookID: Int64
) throws {
    try database.dbPool.write { db in
        var record = TagBookRecord(id: id, bookId: bookID, tagId: tagID, createdDate: 1)
        try record.insert(db)
    }
}

@MainActor
private func expectStatisticsError(
    _ expected: DesktopWebStatisticsRepositoryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("预期错误：\(expected)")
    } catch let error as DesktopWebStatisticsRepositoryError {
        #expect(error == expected)
    } catch {
        Issue.record("错误类型不匹配：\(error)")
    }
}
