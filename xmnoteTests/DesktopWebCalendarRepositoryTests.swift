/**
 * [INPUT]: 依赖 AppDatabase.empty、GRDB Record 与 DesktopWebCalendarRepository
 * [OUTPUT]: 验证 2 条 Calendar API 的事件过滤、自然日、跨日计时、异常读完计数与汇总边界
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android Web 阅读日历当前可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct DesktopWebCalendarRepositoryTests {
    @Test
    func monthKeepsChronologicalBookOrderLimitAndDeletedBookReadDoneCount() async throws {
        let database = try AppDatabase.empty()
        let calendar = calendarTestCalendar()
        let repository = DesktopWebCalendarRepository(database: database, calendar: calendar)
        let day = try calendarTestDate(calendar, year: 2026, month: 7, day: 3)
        let reviewTime = calendarTestMillis(calendar, day, hour: 8)
        let noteTime = calendarTestMillis(calendar, day, hour: 9)
        let doneTime = calendarTestMillis(calendar, day, hour: 10)

        try calendarSeedBook(database, id: 11, name: "  Review Book  ", author: "  A  ", cover: "  /a  ")
        try calendarSeedBook(database, id: 12, name: "Note Book")
        try calendarSeedBook(database, id: 13, name: "Deleted", isDeleted: 1)
        try calendarSeedReview(database, id: 101, bookID: 11, time: reviewTime)
        try calendarSeedNote(database, id: 102, bookID: 12, time: noteTime)
        try calendarSeedReadDone(database, id: 103, bookID: 12, time: doneTime)
        try calendarSeedReadDone(database, id: 104, bookID: 13, time: doneTime)

        let limited = try await repository.month(
            monthMillis: calendarTestMillis(calendar, day, hour: 12),
            configuration: calendarConfiguration(dayEventCount: 1)
        )
        #expect(limited.year == 2026)
        #expect(limited.month == 7)
        #expect(limited.startDayOfWeek == 2)
        #expect(limited.totalDays == 31)
        #expect(limited.days.count == 31)
        let third = try #require(limited.days.first { $0.dayOfMonth == 3 })
        #expect(third.date == "2026-07-03")
        #expect(third.books.map(\.id) == [11])
        #expect(third.books.first?.name == "Review Book")
        #expect(third.books.first?.author == "A")
        #expect(third.books.first?.cover == "/a")
        #expect(third.books.first?.isContinuation == false)
        #expect(third.readDoneBookCount == 2)
        #expect(third.hasActivity)

        let withoutReviews = try await repository.month(
            monthMillis: calendarTestMillis(calendar, day, hour: 12),
            configuration: calendarConfiguration(excludeReview: true)
        )
        let filteredThird = try #require(withoutReviews.days.first { $0.dayOfMonth == 3 })
        #expect(filteredThird.books.map(\.id) == [12])
        #expect(filteredThird.readDoneBookCount == 2)
    }

    @Test
    func daySplitsCrossDayTimingAndAppendsReadDoneOnlyBooks() async throws {
        let database = try AppDatabase.empty()
        let calendar = calendarTestCalendar()
        let repository = DesktopWebCalendarRepository(database: database, calendar: calendar)
        let july3 = try calendarTestDate(calendar, year: 2026, month: 7, day: 3)
        let july4 = try calendarTestDate(calendar, year: 2026, month: 7, day: 4)

        try calendarSeedBook(database, id: 21, name: "Timer")
        try calendarSeedBook(database, id: 22, name: "Notes")
        try calendarSeedBook(database, id: 23, name: "Done Only")
        try calendarSeedReadTime(
            database,
            id: 201,
            bookID: 21,
            start: calendarTestMillis(calendar, july3, hour: 23),
            end: calendarTestMillis(calendar, july4, hour: 1),
            elapsedSeconds: 7_200
        )
        try calendarSeedReadTime(
            database,
            id: 202,
            bookID: 21,
            start: 0,
            end: 0,
            elapsedSeconds: 30,
            fuzzyDate: calendarTestMillis(calendar, july4, hour: 12)
        )
        try calendarSeedNote(database, id: 203, bookID: 21, time: calendarTestMillis(calendar, july4, hour: 7))
        try calendarSeedNote(database, id: 204, bookID: 22, time: calendarTestMillis(calendar, july4, hour: 8))
        try calendarSeedNote(database, id: 205, bookID: 22, time: calendarTestMillis(calendar, july4, hour: 9))
        try calendarSeedReview(database, id: 206, bookID: 21, time: calendarTestMillis(calendar, july4, hour: 10))
        try calendarSeedCheckIn(database, id: 207, bookID: 21, time: calendarTestMillis(calendar, july4, hour: 11))
        try calendarSeedReadDone(database, id: 208, bookID: 21, time: calendarTestMillis(calendar, july4, hour: 13))
        try calendarSeedReadDone(database, id: 209, bookID: 23, time: calendarTestMillis(calendar, july4, hour: 14))

        let summary = try await repository.day(
            dateMillis: calendarTestMillis(calendar, july4, hour: 18),
            configuration: calendarConfiguration(excludeReadDone: true)
        )
        #expect(summary.date == "2026-07-04")
        #expect(summary.details.map(\.book.id) == [21, 22, 23])
        let timer = try #require(summary.details.first { $0.book.id == 21 })
        #expect(timer.readingTime == 3_630)
        #expect(timer.noteCount == 1)
        #expect(timer.reviewCount == 1)
        #expect(timer.checkInCount == 1)
        #expect(timer.isReadDoneInToday)
        let notes = try #require(summary.details.first { $0.book.id == 22 })
        #expect(notes.noteCount == 2)
        #expect(!notes.isReadDoneInToday)
        let doneOnly = try #require(summary.details.first { $0.book.id == 23 })
        #expect(doneOnly.readingTime == 0)
        #expect(doneOnly.isReadDoneInToday)
        #expect(summary.totalReadingTime == 3_630)
        #expect(summary.totalNoteCount == 3)
    }

    @Test
    func monthRespectsAllSixEventFiltersButKeepsRawReadDoneCount() async throws {
        let database = try AppDatabase.empty()
        let calendar = calendarTestCalendar()
        let repository = DesktopWebCalendarRepository(database: database, calendar: calendar)
        let day = try calendarTestDate(calendar, year: 2026, month: 7, day: 8)

        for id in 31...36 {
            try calendarSeedBook(database, id: Int64(id), name: "Book \(id)")
        }
        try calendarSeedNote(
            database,
            id: 301,
            bookID: 31,
            time: calendarTestMillis(calendar, day, hour: 8)
        )
        try calendarSeedRelevant(
            database,
            id: 302,
            bookID: 32,
            time: calendarTestMillis(calendar, day, hour: 9)
        )
        try calendarSeedReview(
            database,
            id: 303,
            bookID: 33,
            time: calendarTestMillis(calendar, day, hour: 10)
        )
        try calendarSeedReadTime(
            database,
            id: 304,
            bookID: 34,
            start: 0,
            end: 0,
            elapsedSeconds: 60,
            fuzzyDate: calendarTestMillis(calendar, day, hour: 11)
        )
        try calendarSeedReadDone(
            database,
            id: 305,
            bookID: 35,
            time: calendarTestMillis(calendar, day, hour: 12)
        )
        try calendarSeedCheckIn(
            database,
            id: 306,
            bookID: 36,
            time: calendarTestMillis(calendar, day, hour: 13)
        )

        let all = try await repository.month(
            monthMillis: calendarTestMillis(calendar, day, hour: 0),
            configuration: calendarConfiguration()
        )
        let allDay = try #require(all.days.first { $0.dayOfMonth == 8 })
        #expect(allDay.books.map(\.id) == [31, 32, 33, 34, 35, 36])
        #expect(allDay.readDoneBookCount == 1)

        let configurations: [(DesktopWebCalendarConfiguration, Int64)] = [
            (calendarConfiguration(excludeNote: true), 31),
            (calendarConfiguration(excludeRelevant: true), 32),
            (calendarConfiguration(excludeReview: true), 33),
            (calendarConfiguration(excludeReadTime: true), 34),
            (calendarConfiguration(excludeReadDone: true), 35),
            (calendarConfiguration(excludeCheckIn: true), 36)
        ]
        for (configuration, excludedID) in configurations {
            let snapshot = try await repository.month(
                monthMillis: calendarTestMillis(calendar, day, hour: 0),
                configuration: configuration
            )
            let target = try #require(snapshot.days.first { $0.dayOfMonth == 8 })
            #expect(!target.books.map(\.id).contains(excludedID))
            #expect(target.readDoneBookCount == 1)
        }
    }

    @Test
    func monthAnchorsMidMonthInputAndKeepsJavaLongOverflowSemantics() async throws {
        let database = try AppDatabase.empty()
        let calendar = calendarTestCalendar()
        let repository = DesktopWebCalendarRepository(database: database, calendar: calendar)
        let july3 = try calendarTestDate(calendar, year: 2026, month: 7, day: 3)

        let midMonth = try await repository.month(
            monthMillis: calendarTestMillis(calendar, july3, hour: 0),
            configuration: calendarConfiguration()
        )
        #expect(midMonth.year == 2026)
        #expect(midMonth.month == 7)
        #expect(midMonth.days.count == 31)
        #expect(midMonth.days.first?.date == "2026-07-01")
        #expect(midMonth.days.last?.date == "2026-07-31")

        let maximum = try await repository.month(
            monthMillis: .max,
            configuration: calendarConfiguration()
        )
        #expect(maximum.year == 292_278_994)
        #expect(maximum.month == 8)
        #expect(maximum.startDayOfWeek == 4)
        #expect(maximum.totalDays == 31)
        #expect(maximum.days.first?.date == "292278994-08-17")
        #expect(maximum.days.dropFirst().first?.date == "292269055-12-04")
        #expect(maximum.days.last?.date == "292269054-01-02")

        let minimum = try await repository.month(
            monthMillis: .min,
            configuration: calendarConfiguration()
        )
        #expect(minimum.year == 292_269_055)
        #expect(minimum.month == 12)
        #expect(minimum.startDayOfWeek == 5)
        #expect(minimum.totalDays == 31)
        #expect(minimum.days.first?.date == "292269055-12-03")
        #expect(minimum.days.last?.date == "292269054-01-02")

        let maximumDay = try await repository.day(
            dateMillis: .max,
            configuration: calendarConfiguration()
        )
        let minimumDay = try await repository.day(
            dateMillis: .min,
            configuration: calendarConfiguration()
        )
        #expect(maximumDay.date == "292278994-08-17")
        #expect(minimumDay.date == "292269055-12-03")
        #expect(maximumDay.details.isEmpty)
        #expect(minimumDay.details.isEmpty)
    }
}

private func calendarTestCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = try! #require(TimeZone(secondsFromGMT: 8 * 3_600))
    calendar.firstWeekday = 2
    return calendar
}

private func calendarTestDate(
    _ calendar: Calendar,
    year: Int,
    month: Int,
    day: Int
) throws -> Date {
    try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
}

private func calendarTestMillis(
    _ calendar: Calendar,
    _ date: Date,
    hour: Int
) -> Int64 {
    let value = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
    return Int64(value.timeIntervalSince1970 * 1_000)
}

private func calendarConfiguration(
    excludeNote: Bool = false,
    excludeRelevant: Bool = false,
    excludeReview: Bool = false,
    excludeReadTime: Bool = false,
    excludeReadDone: Bool = false,
    excludeCheckIn: Bool = false,
    dayEventCount: Int = 6
) -> DesktopWebCalendarConfiguration {
    DesktopWebCalendarConfiguration(
        excludeNote: excludeNote,
        excludeRelevant: excludeRelevant,
        excludeReview: excludeReview,
        excludeReadTime: excludeReadTime,
        excludeReadDone: excludeReadDone,
        excludeCheckIn: excludeCheckIn,
        dayEventCount: dayEventCount
    )
}

private func calendarSeedBook(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    author: String = "",
    cover: String = "",
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: name,
            cover: cover,
            author: author,
            sourceId: 1,
            readStatusId: 1,
            createdDate: 1,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func calendarSeedNote(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    time: Int64
) throws {
    try database.dbPool.write { db in
        var record = NoteRecord(
            id: id,
            bookId: bookID,
            chapterId: 0,
            content: "fixture",
            createdDate: time
        )
        try record.insert(db)
    }
}

private func calendarSeedReview(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    time: Int64
) throws {
    try database.dbPool.write { db in
        var record = ReviewRecord(id: id, bookId: bookID, content: "fixture", createdDate: time)
        try record.insert(db)
    }
}

private func calendarSeedRelevant(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    time: Int64
) throws {
    try database.dbPool.write { db in
        let categoryID = id + 10_000
        var category = CategoryRecord(
            id: categoryID,
            bookId: bookID,
            title: "fixture",
            order: 0,
            isHide: 0,
            createdDate: time,
            updatedDate: time,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try category.insert(db)
        var record = CategoryContentRecord(
            id: id,
            categoryId: categoryID,
            bookId: bookID,
            title: "fixture",
            content: "fixture",
            contentBookId: 0,
            url: "",
            createdDate: time,
            updatedDate: time,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private func calendarSeedCheckIn(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    time: Int64
) throws {
    try database.dbPool.write { db in
        var record = CheckInRecordRecord(
            id: id,
            bookId: bookID,
            amount: 1,
            checkinDate: time,
            createdDate: time
        )
        try record.insert(db)
    }
}

private func calendarSeedReadDone(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    time: Int64
) throws {
    try database.dbPool.write { db in
        var record = BookReadStatusRecordRecord(
            id: id,
            bookId: bookID,
            readStatusId: 3,
            changedDate: time,
            createdDate: time
        )
        try record.insert(db)
    }
}

private func calendarSeedReadTime(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    start: Int64,
    end: Int64,
    elapsedSeconds: Int64,
    fuzzyDate: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = ReadTimeRecordRecord(
            id: id,
            bookId: bookID,
            startTime: start,
            endTime: end,
            elapsedSeconds: elapsedSeconds,
            status: 3,
            fuzzyReadDate: fuzzyDate,
            createdDate: fuzzyDate == 0 ? start : fuzzyDate
        )
        try record.insert(db)
    }
}
