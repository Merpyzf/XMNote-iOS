/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的阅读事件与书籍表，以及 Android 对齐的日历筛选配置
 * [OUTPUT]: 对外提供 CalendarController 月视图与单日汇总的数据快照
 * [POS]: Data 层网页阅读日历专用仓储；独立复刻 Android ReadCalendarRepository 经典月历路径
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 阅读日历筛选快照；由 App 设置适配层读取，Repository 不直接依赖 UserDefaults。
nonisolated struct DesktopWebCalendarConfiguration: Sendable, Equatable {
    let excludeNote: Bool
    let excludeRelevant: Bool
    let excludeReview: Bool
    let excludeReadTime: Bool
    let excludeReadDone: Bool
    let excludeCheckIn: Bool
    let dayEventCount: Int
}

/// WebCalendarBookDto 在 Data 层的无框架投影。
nonisolated struct DesktopWebCalendarBookSnapshot: Sendable, Equatable {
    let id: Int64
    let name: String
    let cover: String
    let author: String
    let isContinuation: Bool

    /// 返回仅更新连续阅读标记的不可变副本。
    func withContinuation() -> Self {
        .init(
            id: id,
            name: name,
            cover: cover,
            author: author,
            isContinuation: true
        )
    }
}

/// WebCalendarDayDto 在 Data 层的日粒度投影。
nonisolated struct DesktopWebCalendarDaySnapshot: Sendable, Equatable {
    let dayOfMonth: Int
    let date: String
    let books: [DesktopWebCalendarBookSnapshot]
    let readDoneBookCount: Int
    let hasActivity: Bool
}

/// WebCalendarMonthDto 在 Data 层的月粒度投影。
nonisolated struct DesktopWebCalendarMonthSnapshot: Sendable, Equatable {
    let year: Int
    let month: Int
    let days: [DesktopWebCalendarDaySnapshot]
    let startDayOfWeek: Int
    let totalDays: Int
}

/// WebDailyReadingDetailDto 在 Data 层的单书日汇总投影。
nonisolated struct DesktopWebDailyReadingDetailSnapshot: Sendable, Equatable {
    let book: DesktopWebCalendarBookSnapshot
    let readingTime: Int
    let noteCount: Int
    let reviewCount: Int
    let checkInCount: Int
    let isReadDoneInToday: Bool
}

/// WebDailyReadingSummaryDto 在 Data 层的单日汇总投影。
nonisolated struct DesktopWebDailyReadingSummarySnapshot: Sendable, Equatable {
    let date: String
    let details: [DesktopWebDailyReadingDetailSnapshot]
    let totalReadingTime: Int
    let totalNoteCount: Int
}

/// 使用独立 SQL 复刻 Android CalendarWebService 与 ReadCalendarRepository 的经典月历行为。
nonisolated struct DesktopWebCalendarRepository: Sendable {
    struct JavaCalendarComponents: Sendable {
        let astronomicalYear: Int64
        let displayYear: Int
        let month: Int
        let day: Int
    }

    private struct CalendarEvent: Sendable {
        let book: DesktopWebCalendarBookSnapshot
        let eventTime: Int64
        let insertionOrder: Int
    }

    private struct ReadTimeRow: Sendable {
        let bookID: Int64
        let startTime: Int64
        let endTime: Int64
        let elapsedSeconds: Int64
        let fuzzyReadDate: Int64
    }

    private let database: AppDatabase
    private let calendar: Calendar

    /// 固定数据库与本地时区日历；所有查询在 GRDB 连接池执行，调用取消不会改变只读快照。
    init(database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    /// 返回目标月份的全部自然日，并按设置截取每天展示的书籍数量。
    func month(
        monthMillis: Int64,
        configuration: DesktopWebCalendarConfiguration
    ) async throws -> DesktopWebCalendarMonthSnapshot {
        if Self.requiresJavaExtremeCalendar(monthMillis) {
            return javaExtremeMonth(monthMillis: monthMillis)
        }
        let inputDate = Self.date(fromMillis: monthMillis)
        let monthStart = normalizeMonthStart(inputDate)
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return DesktopWebCalendarMonthSnapshot(
                year: calendar.component(.year, from: inputDate),
                month: calendar.component(.month, from: inputDate),
                days: [],
                startDayOfWeek: 0,
                totalDays: 0
            )
        }

        let range = Self.millis(from: monthStart)...(Self.millis(from: nextMonth) - 1)
        let events = try await fetchEvents(range: range, configuration: configuration)
        let eventBooksByDay = booksByDay(events)
        let firstReturnedDay = monthStart
        let lastReturnedDay = calendar.date(
            byAdding: .day,
            value: dayRange.count - 1,
            to: firstReturnedDay
        ) ?? firstReturnedDay
        let returnedEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: lastReturnedDay
        ).map { Self.millis(from: $0) - 1 } ?? Self.millis(from: lastReturnedDay)
        let returnedRange = Self.millis(from: firstReturnedDay)...returnedEnd
        let rawReadDoneCounts = try await fetchRawReadDoneCounts(range: returnedRange)
        let displayLimit = max(0, configuration.dayEventCount)
        var days: [DesktopWebCalendarDaySnapshot] = []
        days.reserveCapacity(dayRange.count)

        for dayOffset in 0..<dayRange.count {
            guard let dayStart = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: firstReturnedDay
            ) else { continue }
            let dayOfMonth = calendar.component(.day, from: dayStart)
            let books = Array((eventBooksByDay[dayStart] ?? []).prefix(displayLimit))
            days.append(
                DesktopWebCalendarDaySnapshot(
                    dayOfMonth: dayOfMonth,
                    date: formatDay(dayStart),
                    books: books,
                    readDoneBookCount: rawReadDoneCounts[dayStart] ?? 0,
                    hasActivity: !books.isEmpty
                )
            )
        }

        let weekday = calendar.component(.weekday, from: monthStart)
        return DesktopWebCalendarMonthSnapshot(
            year: calendar.component(.year, from: inputDate),
            month: calendar.component(.month, from: inputDate),
            days: days,
            startDayOfWeek: (weekday + 5) % 7,
            totalDays: dayRange.count
        )
    }

    /// 聚合指定日期的书籍、阅读时长、书摘、书评、打卡与读完状态。
    func day(
        dateMillis: Int64,
        configuration: DesktopWebCalendarConfiguration
    ) async throws -> DesktopWebDailyReadingSummarySnapshot {
        if Self.requiresJavaExtremeCalendar(dateMillis) {
            return DesktopWebDailyReadingSummarySnapshot(
                date: Self.javaDateString(dateMillis, timeZone: calendar.timeZone),
                details: [],
                totalReadingTime: 0,
                totalNoteCount: 0
            )
        }
        let date = Self.date(fromMillis: dateMillis)
        let dayStart = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: normalizeMonthStart(date)) else {
            return DesktopWebDailyReadingSummarySnapshot(
                date: formatDay(dayStart),
                details: [],
                totalReadingTime: 0,
                totalNoteCount: 0
            )
        }

        let monthStart = normalizeMonthStart(date)
        let monthRange = Self.millis(from: monthStart)...(Self.millis(from: nextMonth) - 1)
        let dayRange = Self.millis(from: dayStart)...(Self.millis(from: nextDay) - 1)
        let monthEvents = try await fetchEvents(range: monthRange, configuration: configuration)
        var books = booksByDay(monthEvents)[dayStart] ?? []
        let completion = try await fetchReadDoneBooks(range: dayRange)
        let existingIDs = Set(books.map(\.id))
        books.append(
            contentsOf: completion.books
                .filter { !existingIDs.contains($0.id) }
                .sorted {
                    let lhsTime = completion.latestTimeByBookID[$0.id] ?? Int64.min
                    let rhsTime = completion.latestTimeByBookID[$1.id] ?? Int64.min
                    if lhsTime != rhsTime { return lhsTime > rhsTime }
                    return $0.id < $1.id
                }
        )

        let aggregates = try await fetchDayAggregates(bookIDs: books.map(\.id), range: dayRange)
        let details = books.map { book in
            DesktopWebDailyReadingDetailSnapshot(
                book: DesktopWebCalendarBookSnapshot(
                    id: book.id,
                    name: book.name,
                    cover: book.cover,
                    author: book.author,
                    isContinuation: false
                ),
                readingTime: aggregates.readingTimeByBookID[book.id] ?? 0,
                noteCount: aggregates.noteCountByBookID[book.id] ?? 0,
                reviewCount: aggregates.reviewCountByBookID[book.id] ?? 0,
                checkInCount: aggregates.checkInCountByBookID[book.id] ?? 0,
                isReadDoneInToday: completion.latestTimeByBookID[book.id] != nil
            )
        }
        return DesktopWebDailyReadingSummarySnapshot(
            date: formatDay(dayStart),
            details: details,
            totalReadingTime: details.reduce(0) { $0 &+ $1.readingTime },
            totalNoteCount: details.reduce(0) { $0 &+ $1.noteCount }
        )
    }

    /// 在 Foundation Calendar 可表示范围外复刻 Java GregorianCalendar，包括 Long 加日溢出。
    private func javaExtremeMonth(
        monthMillis: Int64
    ) -> DesktopWebCalendarMonthSnapshot {
        let input = Self.javaComponents(monthMillis, timeZone: calendar.timeZone)
        let totalDays = Self.javaMonthDayCount(input)
        var days: [DesktopWebCalendarDaySnapshot] = []
        days.reserveCapacity(totalDays)
        var cursor = monthMillis
        for _ in 0..<totalDays {
            let components = Self.javaComponents(cursor, timeZone: calendar.timeZone)
            days.append(
                DesktopWebCalendarDaySnapshot(
                    dayOfMonth: components.day,
                    date: Self.javaDateString(components),
                    books: [],
                    readDoneBookCount: 0,
                    hasActivity: false
                )
            )
            cursor = cursor &+ Self.millisecondsPerDay
        }
        let firstDay = Self.javaDaysSinceEpoch(
            astronomicalYear: input.astronomicalYear,
            month: input.month,
            day: 1
        )
        return DesktopWebCalendarMonthSnapshot(
            year: input.displayYear,
            month: input.month,
            days: days,
            startDayOfWeek: Int(Self.floorMod(firstDay + 3, 7)),
            totalDays: totalDays
        )
    }
}

private nonisolated extension DesktopWebCalendarRepository {
    struct DayAggregates: Sendable {
        let readingTimeByBookID: [Int64: Int]
        let noteCountByBookID: [Int64: Int]
        let reviewCountByBookID: [Int64: Int]
        let checkInCountByBookID: [Int64: Int]
    }

    /// 合并启用的六类阅读事件，并以 Android 的稳定时间顺序保留同日首次书籍出现位置。
    private func fetchEvents(
        range: ClosedRange<Int64>,
        configuration: DesktopWebCalendarConfiguration
    ) async throws -> [CalendarEvent] {
        try await database.dbPool.read { db in
            var events: [CalendarEvent] = []
            var insertionOrder = 0

            func appendRows(_ rows: [Row], timeColumn: String) {
                for row in rows {
                    guard let book = calendarBook(from: row),
                          let eventTime: Int64 = row[timeColumn] else { continue }
                    events.append(
                        CalendarEvent(
                            book: book,
                            eventTime: eventTime,
                            insertionOrder: insertionOrder
                        )
                    )
                    insertionOrder += 1
                }
            }

            if !configuration.excludeNote {
                // SQL 目的：读取月范围内有效书摘事件并补全有效书籍元数据。
                // 涉及表：note INNER JOIN book；按 created_date 升序。
                // 关键过滤：两表未软删除、book_id != 0、毫秒时间位于闭区间。
                // 返回字段：书籍 DTO 基础字段与事件时间，供日历首次出现顺序使用。
                appendRows(
                    try Row.fetchAll(
                        db,
                        sql: """
                            SELECT b.id, b.name, b.cover, b.author, n.created_date AS event_time
                            FROM note n
                            JOIN book b ON b.id = n.book_id
                            WHERE n.book_id != 0
                              AND n.is_deleted = 0 AND b.is_deleted = 0
                              AND n.created_date BETWEEN ? AND ?
                            ORDER BY n.created_date ASC
                            """,
                        arguments: [range.lowerBound, range.upperBound]
                    ),
                    timeColumn: "event_time"
                )
            }

            if !configuration.excludeRelevant {
                // SQL 目的：读取月范围内有效相关内容事件并补全有效书籍元数据。
                // 涉及表：category_content INNER JOIN book；按 created_date 升序。
                // 关键过滤：两表未软删除、book_id != 0、毫秒时间位于闭区间。
                // 返回字段：书籍 DTO 基础字段与事件时间。
                appendRows(
                    try Row.fetchAll(
                        db,
                        sql: """
                            SELECT b.id, b.name, b.cover, b.author, c.created_date AS event_time
                            FROM category_content c
                            JOIN book b ON b.id = c.book_id
                            WHERE c.book_id != 0
                              AND c.is_deleted = 0 AND b.is_deleted = 0
                              AND c.created_date BETWEEN ? AND ?
                            ORDER BY c.created_date ASC
                            """,
                        arguments: [range.lowerBound, range.upperBound]
                    ),
                    timeColumn: "event_time"
                )
            }

            if !configuration.excludeReview {
                // SQL 目的：读取月范围内有效书评事件并补全有效书籍元数据。
                // 涉及表：review INNER JOIN book；按 created_date 升序。
                // 关键过滤：两表未软删除、book_id != 0、毫秒时间位于闭区间。
                // 返回字段：书籍 DTO 基础字段与事件时间。
                appendRows(
                    try Row.fetchAll(
                        db,
                        sql: """
                            SELECT b.id, b.name, b.cover, b.author, r.created_date AS event_time
                            FROM review r
                            JOIN book b ON b.id = r.book_id
                            WHERE r.book_id != 0
                              AND r.is_deleted = 0 AND b.is_deleted = 0
                              AND r.created_date BETWEEN ? AND ?
                            ORDER BY r.created_date ASC
                            """,
                        arguments: [range.lowerBound, range.upperBound]
                    ),
                    timeColumn: "event_time"
                )
            }

            if !configuration.excludeReadTime {
                // SQL 目的：读取与月份相交的精确阅读计时，随后按本地自然日拆分。
                // 涉及表：read_time_record INNER JOIN book。
                // 关键过滤：有效完成记录、fuzzy_read_date = 0、区间重叠、有效非占位书。
                // 时间字段：start_time/end_time 为毫秒，elapsed_seconds 按 wall-time 比例分配。
                let accurateRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT b.id, b.name, b.cover, b.author,
                               r.start_time, r.end_time, r.elapsed_seconds, r.fuzzy_read_date
                        FROM read_time_record r
                        JOIN book b ON b.id = r.book_id
                        WHERE r.book_id != 0
                          AND r.is_deleted = 0 AND r.status = 3
                          AND r.fuzzy_read_date = 0
                          AND r.start_time <= ? AND r.end_time >= ?
                          AND b.is_deleted = 0
                        ORDER BY r.start_time ASC
                        """,
                    arguments: [range.upperBound, range.lowerBound]
                )
                for row in accurateRows {
                    guard let book = calendarBook(from: row),
                          let readTime = readTimeRow(from: row) else { continue }
                    for segment in split(readTime) where range.contains(segment.time) {
                        events.append(
                            CalendarEvent(
                                book: book,
                                eventTime: segment.time,
                                insertionOrder: insertionOrder
                            )
                        )
                        insertionOrder += 1
                    }
                }

                // SQL 目的：读取月份内的模糊阅读计时并补全有效书籍元数据。
                // 涉及表：read_time_record INNER JOIN book。
                // 关键过滤：有效完成记录、fuzzy_read_date != 0 且位于毫秒闭区间。
                // 返回字段：fuzzy_read_date 作为事件日期，不拆分 elapsed_seconds。
                appendRows(
                    try Row.fetchAll(
                        db,
                        sql: """
                            SELECT b.id, b.name, b.cover, b.author,
                                   r.fuzzy_read_date AS event_time
                            FROM read_time_record r
                            JOIN book b ON b.id = r.book_id
                            WHERE r.book_id != 0
                              AND r.is_deleted = 0 AND r.status = 3
                              AND r.fuzzy_read_date != 0
                              AND r.fuzzy_read_date BETWEEN ? AND ?
                              AND b.is_deleted = 0
                            ORDER BY r.fuzzy_read_date ASC
                            """,
                        arguments: [range.lowerBound, range.upperBound]
                    ),
                    timeColumn: "event_time"
                )
            }

            if !configuration.excludeReadDone {
                // SQL 目的：读取月份内进入“读完”状态的事件并补全有效书籍元数据。
                // 涉及表：book_read_status_record INNER JOIN book。
                // 关键过滤：状态 3、两表未软删除、book_id != 0、changed_date 位于闭区间。
                // 返回字段：changed_date 作为日历事件时间；重复读完记录全部参与排序。
                appendRows(
                    try Row.fetchAll(
                        db,
                        sql: """
                            SELECT b.id, b.name, b.cover, b.author, r.changed_date AS event_time
                            FROM book_read_status_record r
                            JOIN book b ON b.id = r.book_id
                            WHERE r.book_id != 0
                              AND r.read_status_id = 3
                              AND r.is_deleted = 0 AND b.is_deleted = 0
                              AND r.changed_date BETWEEN ? AND ?
                            ORDER BY r.changed_date ASC
                            """,
                        arguments: [range.lowerBound, range.upperBound]
                    ),
                    timeColumn: "event_time"
                )
            }

            if !configuration.excludeCheckIn {
                // SQL 目的：读取月份内有效打卡事件并补全有效书籍元数据。
                // 涉及表：check_in_record INNER JOIN book；按 checkin_date 升序。
                // 关键过滤：两表未软删除、book_id != 0、毫秒时间位于闭区间。
                // 返回字段：书籍 DTO 基础字段与事件时间。
                appendRows(
                    try Row.fetchAll(
                        db,
                        sql: """
                            SELECT b.id, b.name, b.cover, b.author, c.checkin_date AS event_time
                            FROM check_in_record c
                            JOIN book b ON b.id = c.book_id
                            WHERE c.book_id != 0
                              AND c.is_deleted = 0 AND b.is_deleted = 0
                              AND c.checkin_date BETWEEN ? AND ?
                            ORDER BY c.checkin_date ASC
                            """,
                        arguments: [range.lowerBound, range.upperBound]
                    ),
                    timeColumn: "event_time"
                )
            }

            return events.sorted {
                if $0.eventTime != $1.eventTime { return $0.eventTime < $1.eventTime }
                return $0.insertionOrder < $1.insertionOrder
            }
        }
    }

    /// 按本地日期分桶，并复刻同一自然周内相邻日期的连续阅读标记与行对齐。
    private func booksByDay(_ events: [CalendarEvent]) -> [Date: [DesktopWebCalendarBookSnapshot]] {
        var result: [Date: [DesktopWebCalendarBookSnapshot]] = [:]
        var seen: [Date: Set<Int64>] = [:]
        for event in events {
            let day = calendar.startOfDay(for: Self.date(fromMillis: event.eventTime))
            if seen[day, default: []].insert(event.book.id).inserted {
                result[day, default: []].append(
                    DesktopWebCalendarBookSnapshot(
                        id: event.book.id,
                        name: event.book.name,
                        cover: event.book.cover,
                        author: event.book.author,
                        isContinuation: false
                    )
                )
            }
        }
        let orderedDays = result.keys.sorted()
        guard orderedDays.count > 1 else { return result }
        for index in 0..<(orderedDays.count - 1) {
            let day = orderedDays[index]
            let nextDay = orderedDays[index + 1]
            guard calendar.dateComponents([.day], from: day, to: nextDay).day == 1,
                  calendar.component(.weekOfYear, from: day) == calendar.component(.weekOfYear, from: nextDay),
                  calendar.component(.yearForWeekOfYear, from: day)
                    == calendar.component(.yearForWeekOfYear, from: nextDay),
                  var currentBooks = result[day],
                  var nextBooks = result[nextDay] else {
                continue
            }
            for bookIndex in currentBooks.indices {
                guard let nextIndex = nextBooks.firstIndex(where: { $0.id == currentBooks[bookIndex].id }) else {
                    continue
                }
                currentBooks[bookIndex] = currentBooks[bookIndex].withContinuation()
                nextBooks[nextIndex] = nextBooks[nextIndex].withContinuation()
                if bookIndex < nextBooks.count, bookIndex != nextIndex {
                    nextBooks.swapAt(bookIndex, nextIndex)
                }
            }
            result[day] = currentBooks
            result[nextDay] = nextBooks
        }
        return result
    }

    /// 统计原始读完记录数；故意不连接 book，以复刻删除书籍仍进入月历计数的行为。
    func fetchRawReadDoneCounts(range: ClosedRange<Int64>) async throws -> [Date: Int] {
        try await database.dbPool.read { db in
            // SQL 目的：读取月份内全部有效读完记录，随后按本地自然日计数。
            // 涉及表：book_read_status_record；故意不关联 book。
            // 关键过滤：read_status_id = 3、记录未软删除、book_id != 0、changed_date 位于闭区间。
            // 副作用：无；返回原始 changed_date 以复刻 DateUtil 本地时区分桶。
            let times = try Int64.fetchAll(
                db,
                sql: """
                    SELECT changed_date
                    FROM book_read_status_record
                    WHERE is_deleted = 0
                      AND read_status_id = 3
                      AND book_id != 0
                      AND changed_date BETWEEN ? AND ?
                    """,
                arguments: [range.lowerBound, range.upperBound]
            )
            // NOTE(ANDROID-WEB-023): Android 月历计数包含已删除/缺失书籍的读完记录，但 books 与 day 详情会排除它们。
            return times.reduce(into: [Date: Int]()) { partial, time in
                let day = calendar.startOfDay(for: Self.date(fromMillis: time))
                partial[day, default: 0] += 1
            }
        }
    }

    /// 返回当天有效读完书籍及其最后一次记录时间，供 day 接口补齐仅有读完事件的书籍。
    func fetchReadDoneBooks(
        range: ClosedRange<Int64>
    ) async throws -> (books: [DesktopWebCalendarBookSnapshot], latestTimeByBookID: [Int64: Int64]) {
        try await database.dbPool.read { db in
            // SQL 目的：读取当天至少有一条读完记录的有效书籍，并计算每书最后读完时间。
            // 涉及表：book INNER JOIN book_read_status_record。
            // 关键过滤：书籍和记录未软删除、非占位书、状态 3、changed_date 位于闭区间。
            // 返回字段：书籍 DTO 基础字段与 MAX(changed_date)，供缺省书籍排序和状态标记。
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT b.id, b.name, b.cover, b.author,
                           MAX(r.changed_date) AS latest_time
                    FROM book b
                    JOIN book_read_status_record r ON r.book_id = b.id
                    WHERE b.id != 0 AND b.is_deleted = 0
                      AND r.is_deleted = 0 AND r.read_status_id = 3
                      AND r.changed_date BETWEEN ? AND ?
                    GROUP BY b.id
                    """,
                arguments: [range.lowerBound, range.upperBound]
            )
            let pairs = rows.compactMap { row -> (DesktopWebCalendarBookSnapshot, Int64)? in
                guard let book = calendarBook(from: row),
                      let latest: Int64 = row["latest_time"] else { return nil }
                return (book, latest)
            }
            return (
                pairs.map(\.0),
                Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1) })
            )
        }
    }

    /// 一次读取当天四类计数，阅读计时仍在 Swift 中按 Android 跨日比例规则拆分。
    func fetchDayAggregates(
        bookIDs: [Int64],
        range: ClosedRange<Int64>
    ) async throws -> DayAggregates {
        guard !bookIDs.isEmpty else {
            return DayAggregates(
                readingTimeByBookID: [:],
                noteCountByBookID: [:],
                reviewCountByBookID: [:],
                checkInCountByBookID: [:]
            )
        }
        return try await database.dbPool.read { db in
            let uniqueIDs = Array(Set(bookIDs))
            let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
            let countArguments = StatementArguments(uniqueIDs + [range.lowerBound, range.upperBound])

            // SQL 目的：按书统计当天有效书摘数量。
            // 涉及表：note；不连接 book，与 Android getNoteCountOfBookInRange 一致。
            // 关键过滤：指定书 ID、未软删除、created_date 位于本地日毫秒闭区间。
            // 返回字段：book_id 与 COUNT(*)，供 WebDailyReadingDetailDto.noteCount。
            let noteRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT book_id, COUNT(*) AS value
                    FROM note
                    WHERE book_id IN (\(placeholders))
                      AND is_deleted = 0 AND created_date BETWEEN ? AND ?
                    GROUP BY book_id
                    """,
                arguments: countArguments
            )

            // SQL 目的：按书统计当天有效书评数量。
            // 涉及表：review；不连接 book，与 Android getReviewCountOfBookInRange 一致。
            // 关键过滤：指定书 ID、未软删除、created_date 位于本地日毫秒闭区间。
            // 返回字段：book_id 与 COUNT(*)，供 WebDailyReadingDetailDto.reviewCount。
            let reviewRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT book_id, COUNT(*) AS value
                    FROM review
                    WHERE book_id IN (\(placeholders))
                      AND is_deleted = 0 AND created_date BETWEEN ? AND ?
                    GROUP BY book_id
                    """,
                arguments: countArguments
            )

            // SQL 目的：按书统计当天有效打卡次数。
            // 涉及表：check_in_record；不连接 book，与 Android getCheckInCountOfBookInRange 一致。
            // 关键过滤：指定书 ID、未软删除、checkin_date 位于本地日毫秒闭区间。
            // 返回字段：book_id 与 COUNT(*)，供 WebDailyReadingDetailDto.checkInCount。
            let checkInRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT book_id, COUNT(*) AS value
                    FROM check_in_record
                    WHERE book_id IN (\(placeholders))
                      AND is_deleted = 0 AND checkin_date BETWEEN ? AND ?
                    GROUP BY book_id
                    """,
                arguments: countArguments
            )

            // SQL 目的：读取指定书籍全部有效完成计时，供 Android splitCrossDayRecords 规则拆分后取当天片段。
            // 涉及表：read_time_record；不连接 book。
            // 关键过滤：指定书 ID、未软删除、status = 3；时间过滤在拆分后完成。
            // 时间字段：start_time/end_time/fuzzy_read_date 为毫秒，elapsed_seconds 为秒。
            let readRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT book_id, start_time, end_time, elapsed_seconds, fuzzy_read_date
                    FROM read_time_record
                    WHERE book_id IN (\(placeholders))
                      AND is_deleted = 0 AND status = 3
                    ORDER BY start_time ASC
                    """,
                arguments: StatementArguments(uniqueIDs)
            )
            var readingTimeByBookID: [Int64: Int] = [:]
            for row in readRows {
                guard let record = readTimeRow(from: row) else { continue }
                let seconds = split(record)
                    .filter { range.contains($0.time) }
                    .reduce(Int64(0)) { $0 &+ $1.seconds }
                if seconds != 0 {
                    let current = readingTimeByBookID[record.bookID] ?? 0
                    readingTimeByBookID[record.bookID] = current &+ Int(truncatingIfNeeded: seconds)
                }
            }
            return DayAggregates(
                readingTimeByBookID: readingTimeByBookID,
                noteCountByBookID: countMap(noteRows),
                reviewCountByBookID: countMap(reviewRows),
                checkInCountByBookID: countMap(checkInRows)
            )
        }
    }

    func calendarBook(from row: Row) -> DesktopWebCalendarBookSnapshot? {
        guard let id: Int64 = row["id"] else { return nil }
        return DesktopWebCalendarBookSnapshot(
            id: id,
            name: (row["name"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            cover: (row["cover"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            author: (row["author"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            isContinuation: false
        )
    }

    private func readTimeRow(from row: Row) -> ReadTimeRow? {
        let explicitBookID: Int64? = row["book_id"]
        let joinedBookID: Int64? = row["id"]
        guard let bookID = explicitBookID ?? joinedBookID,
              let startTime: Int64 = row["start_time"],
              let endTime: Int64 = row["end_time"],
              let elapsedSeconds: Int64 = row["elapsed_seconds"],
              let fuzzyReadDate: Int64 = row["fuzzy_read_date"] else { return nil }
        return ReadTimeRow(
            bookID: bookID,
            startTime: startTime,
            endTime: endTime,
            elapsedSeconds: elapsedSeconds,
            fuzzyReadDate: fuzzyReadDate
        )
    }

    /// 逐毫秒复刻 Android ReadTimeRecord.splitCrossDayRecords 的正时长分配与分段起点。
    private func split(_ record: ReadTimeRow) -> [(time: Int64, seconds: Int64)] {
        if record.fuzzyReadDate != 0 {
            return [(record.fuzzyReadDate, record.elapsedSeconds)]
        }
        let startDate = Self.date(fromMillis: record.startTime)
        let endDate = Self.date(fromMillis: record.endTime)
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        if startDay == endDay {
            return [(record.startTime, record.elapsedSeconds)]
        }

        let wallTimeTotal = record.endTime - record.startTime
        guard wallTimeTotal != 0 else { return [] }
        var allocated: Int64 = 0
        var currentMillis = record.startTime
        var cursor = startDay
        var result: [(Int64, Int64)] = []
        while cursor <= endDay && allocated < record.elapsedSeconds {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let startOfDay = Self.millis(from: cursor)
            let endOfDay = Self.millis(from: nextDay) - 1
            let segmentStart = max(currentMillis, startOfDay)
            let segmentEnd = min(record.endTime, endOfDay)
            if segmentStart < segmentEnd {
                let ratio = Double(segmentEnd - segmentStart) / Double(wallTimeTotal)
                var seconds = Int64((ratio * Double(record.elapsedSeconds)).rounded())
                if allocated + seconds > record.elapsedSeconds {
                    seconds = record.elapsedSeconds - allocated
                }
                allocated += seconds
                result.append((segmentStart, seconds))
                currentMillis = segmentEnd + 1
            }
            cursor = nextDay
        }
        return result
    }

    func countMap(_ rows: [Row]) -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id: Int64 = row["book_id"], let value: Int64 = row["value"] else {
                return nil
            }
            return (id, Int(truncatingIfNeeded: value))
        })
    }

    func normalizeMonthStart(_ date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components).map(calendar.startOfDay(for:))
            ?? calendar.startOfDay(for: date)
    }

    func formatDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(fromMillis millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1_000)
    }

    static func millis(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    static let millisecondsPerDay: Int64 = 86_400_000
    static let foundationUpperBoundMillis: Int64 = 253_402_300_799_999
    static let foundationLowerBoundMillis: Int64 = -62_135_596_800_000
    static let gregorianCutoverDaysSinceEpoch: Int64 = -141_427

    static func requiresJavaExtremeCalendar(_ millis: Int64) -> Bool {
        millis > foundationUpperBoundMillis || millis < foundationLowerBoundMillis
    }

    /// 把任意 Long 毫秒转换为 Java GregorianCalendar 的混合公历/儒略历字段。
    static func javaComponents(
        _ millis: Int64,
        timeZone: TimeZone
    ) -> JavaCalendarComponents {
        var days = floorDiv(millis, millisecondsPerDay)
        var millisOfDay = floorMod(millis, millisecondsPerDay)
        let offsetMillis = Int64(timeZone.secondsFromGMT()) * 1_000
        millisOfDay += offsetMillis
        if millisOfDay >= millisecondsPerDay {
            days += millisOfDay / millisecondsPerDay
            millisOfDay %= millisecondsPerDay
        } else if millisOfDay < 0 {
            let borrowedDays = floorDiv(millisOfDay, millisecondsPerDay)
            days += borrowedDays
            millisOfDay -= borrowedDays * millisecondsPerDay
        }

        let fields: (year: Int64, month: Int64, day: Int64)
        if days >= gregorianCutoverDaysSinceEpoch {
            fields = gregorianDate(daysSinceEpoch: days)
        } else {
            fields = julianDate(daysSinceEpoch: days)
        }
        let displayYear = fields.year > 0 ? fields.year : 1 - fields.year
        return JavaCalendarComponents(
            astronomicalYear: fields.year,
            displayYear: Int(truncatingIfNeeded: displayYear),
            month: Int(fields.month),
            day: Int(fields.day)
        )
    }

    static func javaDateString(
        _ millis: Int64,
        timeZone: TimeZone
    ) -> String {
        javaDateString(javaComponents(millis, timeZone: timeZone))
    }

    static func javaDateString(_ components: JavaCalendarComponents) -> String {
        String(
            format: "%04lld-%02d-%02d",
            Int64(components.displayYear),
            components.month,
            components.day
        )
    }

    static func javaMonthDayCount(_ components: JavaCalendarComponents) -> Int {
        switch components.month {
        case 2:
            let year = components.astronomicalYear
            let isLeap: Bool
            if javaDaysSinceEpoch(
                astronomicalYear: year,
                month: 1,
                day: 1
            ) >= gregorianCutoverDaysSinceEpoch {
                isLeap = floorMod(year, 4) == 0
                    && (floorMod(year, 100) != 0 || floorMod(year, 400) == 0)
            } else {
                isLeap = floorMod(year, 4) == 0
            }
            return isLeap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    static func javaDaysSinceEpoch(
        astronomicalYear: Int64,
        month: Int,
        day: Int
    ) -> Int64 {
        if astronomicalYear > 1582
            || (astronomicalYear == 1582 && month >= 10) {
            return gregorianDaysSinceEpoch(
                year: astronomicalYear,
                month: Int64(month),
                day: Int64(day)
            )
        }
        return julianDayNumber(
            year: astronomicalYear,
            month: Int64(month),
            day: Int64(day)
        ) - 2_440_588
    }

    static func gregorianDate(
        daysSinceEpoch: Int64
    ) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = daysSinceEpoch + 719_468
        let era = floorDiv(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        var year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        if month <= 2 {
            year += 1
        }
        return (year, month, day)
    }

    static func julianDate(
        daysSinceEpoch: Int64
    ) -> (year: Int64, month: Int64, day: Int64) {
        let julianDay = 2_440_588 + daysSinceEpoch
        let c = julianDay + 32_082
        let d = floorDiv(4 * c + 3, 1_461)
        let e = c - floorDiv(1_461 * d, 4)
        let monthPrime = floorDiv(5 * e + 2, 153)
        let day = e - floorDiv(153 * monthPrime + 2, 5) + 1
        let month = monthPrime + 3 - 12 * floorDiv(monthPrime, 10)
        let year = d - 4_800 + floorDiv(monthPrime, 10)
        return (year, month, day)
    }

    static func gregorianDaysSinceEpoch(
        year inputYear: Int64,
        month: Int64,
        day: Int64
    ) -> Int64 {
        var year = inputYear
        if month <= 2 {
            year -= 1
        }
        let era = floorDiv(year, 400)
        let yearOfEra = year - era * 400
        let monthPrime = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * monthPrime + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func julianDayNumber(
        year: Int64,
        month: Int64,
        day: Int64
    ) -> Int64 {
        let a = floorDiv(14 - month, 12)
        let shiftedYear = year + 4_800 - a
        let shiftedMonth = month + 12 * a - 3
        return day
            + floorDiv(153 * shiftedMonth + 2, 5)
            + 365 * shiftedYear
            + floorDiv(shiftedYear, 4)
            - 32_083
    }

    static func floorDiv(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let quotient = lhs / rhs
        let remainder = lhs % rhs
        return remainder < 0 ? quotient - 1 : quotient
    }

    static func floorMod(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let remainder = lhs % rhs
        return remainder < 0 ? remainder + rhs : remainder
    }
}
