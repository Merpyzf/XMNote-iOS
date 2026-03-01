import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 Heatmap 与阅读日历领域模型
 * [OUTPUT]: 对外提供 StatisticsRepository（StatisticsRepositoryProtocol 的 GRDB 实现，含阅读日历月度阅读时长排行与月度摘要聚合）
 * [POS]: Data 层统计仓储实现，聚合热力图与阅读日历月视图数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

nonisolated struct StatisticsRepository: StatisticsRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let calendar = Calendar.current

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    nonisolated func fetchHeatmapData(
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) async throws -> (days: [Date: HeatmapDay], earliestDate: Date?, latestDate: Date?) {
        try await databaseManager.database.dbPool.read { db in
            buildHeatmapData(db, year: year, dataType: dataType)
        }
    }

    nonisolated func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?) {
        let result = try await fetchHeatmapData(year: 0, dataType: .all)
        return (result.days, result.earliestDate)
    }

    nonisolated func fetchReadCalendarEarliestDate(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> Date? {
        try await databaseManager.database.dbPool.read { db in
            findReadCalendarEarliestDate(db, excludedEventTypes: excludedEventTypes)
        }
    }

    nonisolated func fetchReadCalendarMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData {
        try await databaseManager.database.dbPool.read { db in
            buildReadCalendarMonthData(db, monthStart: monthStart, excludedEventTypes: excludedEventTypes)
        }
    }
}

// MARK: - 共享格式化器

private extension StatisticsRepository {
    nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    nonisolated static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = .current
        return f
    }()
}

// MARK: - 聚合查询

private struct CheckInSummary {
    let count: Int
    let seconds: Int
}

private struct HeatmapDateRange {
    let start: Date
    let end: Date
}

private struct ReadCalendarDayBookRow {
    let day: Date
    let bookId: Int64
    let bookName: String
    let bookCover: String
    let firstEventTime: Int64
}

private struct ReadCalendarDurationRecordRow {
    let bookId: Int64
    let bookName: String
    let bookCover: String
    let startTime: Int64
    let endTime: Int64
    let elapsedSeconds: Int64
    let fuzzyReadDate: Int64
}

private struct ReadCalendarDurationAggregation {
    let readSecondsByBookId: [Int64: Int64]
    let bookMetaById: [Int64: (name: String, coverURL: String)]
    let totalReadSeconds: Int64
    let timeSlotReadSeconds: [ReadCalendarTimeSlot: Int]
}

private extension StatisticsRepository {

    /// 按统计维度与年份聚合热力图数据
    nonisolated func buildHeatmapData(
        _ db: Database,
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) -> (days: [Date: HeatmapDay], earliestDate: Date?, latestDate: Date?) {
        guard let dateRange = resolveDateRange(db, year: year, dataType: dataType) else {
            return ([:], nil, nil)
        }

        let millisRange = millisRangeForQuery(dateRange)
        let readMap = shouldQueryReadMap(dataType) ? aggregateReadSeconds(db, millisRange: millisRange) : [:]
        let noteMap = shouldQueryNoteMap(dataType) ? aggregateNoteCounts(db, millisRange: millisRange) : [:]
        let checkInMap = shouldQueryCheckInMap(dataType) ? aggregateCheckInSummary(db, millisRange: millisRange) : [:]
        let bookStateMap = aggregateBookStates(db, millisRange: millisRange)

        var days: [Date: HeatmapDay] = [:]
        var current = calendar.startOfDay(for: dateRange.start)
        let end = calendar.startOfDay(for: dateRange.end)

        while current <= end {
            let day = HeatmapDay(
                id: current,
                readSeconds: readMap[current] ?? 0,
                noteCount: noteMap[current] ?? 0,
                checkInCount: checkInMap[current]?.count ?? 0,
                checkInSeconds: checkInMap[current]?.seconds ?? 0,
                bookStates: bookStateMap[current] ?? []
            )
            if shouldInclude(day: day, dataType: dataType) {
                days[current] = day
            }
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }

        return (days, dateRange.start, dateRange.end)
    }

    nonisolated func resolveDateRange(
        _ db: Database,
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) -> HeatmapDateRange? {
        if year > 0 {
            return yearDateRange(year)
        }
        guard let earliest = findEarliestDate(db, dataType: dataType) else { return nil }
        let latest = calendar.startOfDay(for: Date())
        return HeatmapDateRange(start: earliest, end: latest)
    }

    nonisolated func yearDateRange(_ year: Int) -> HeatmapDateRange? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return nil
        }
        return HeatmapDateRange(
            start: calendar.startOfDay(for: start),
            end: calendar.startOfDay(for: end)
        )
    }

    nonisolated func millisRangeForQuery(_ dateRange: HeatmapDateRange) -> ClosedRange<Int64> {
        let startMs = Int64(calendar.startOfDay(for: dateRange.start).timeIntervalSince1970 * 1000)
        let endDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateRange.end))!
        let endMs = Int64(endDay.timeIntervalSince1970 * 1000) - 1
        return startMs...endMs
    }

    nonisolated func shouldQueryReadMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .readingTime || dataType == .all
    }

    nonisolated func shouldQueryNoteMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .noteCount || dataType == .all
    }

    nonisolated func shouldQueryCheckInMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .checkIn || dataType == .all
    }

    nonisolated func shouldInclude(day: HeatmapDay, dataType: HeatmapStatisticsDataType) -> Bool {
        if !day.bookStates.isEmpty { return true }
        switch dataType {
        case .noteCount:
            return day.noteCount > 0
        case .readingTime:
            return day.readSeconds > 0
        case .checkIn:
            return day.checkInCount > 0 || day.checkInSeconds > 0
        case .all:
            return day.readSeconds > 0 || day.noteCount > 0 || day.checkInCount > 0
        }
    }

    // MARK: - 最早记录日期

    nonisolated func findEarliestDate(_ db: Database, dataType: HeatmapStatisticsDataType) -> Date? {
        let readSql = """
            SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
            FROM read_time_record WHERE is_deleted = 0
            """
        let noteSql = "SELECT MIN(created_date) FROM note WHERE is_deleted = 0"
        let checkInSql = "SELECT MIN(checkin_date) FROM check_in_record WHERE is_deleted = 0 AND checkin_date != 0"
        let statusSql = "SELECT MIN(changed_date) FROM book_read_status_record WHERE is_deleted = 0 AND changed_date != 0"

        let queries: [String]
        switch dataType {
        case .readingTime:
            queries = [readSql, statusSql]
        case .noteCount:
            queries = [noteSql, statusSql]
        case .checkIn:
            queries = [checkInSql, statusSql]
        case .all:
            queries = [readSql, noteSql, checkInSql, statusSql]
        }

        let timestamps: [Int64] = queries.compactMap { sql in
            guard let value = try? Int64.fetchOne(db, sql: sql), value > 0 else { return nil }
            return value
        }

        guard let earliest = timestamps.min() else { return nil }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: Double(earliest) / 1000))
    }

    // MARK: - 阅读时长聚合

    /// 按天 SUM(elapsed_seconds)，处理 fuzzyReadDate 双时间源
    nonisolated func aggregateReadSeconds(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
        let sql = """
            SELECT DATE(
                CASE WHEN fuzzy_read_date != 0
                    THEN fuzzy_read_date / 1000
                    ELSE start_time / 1000
                END,
                'unixepoch', 'localtime'
            ) AS day,
            SUM(elapsed_seconds) AS total
            FROM read_time_record
            WHERE is_deleted = 0
              AND (CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END) BETWEEN ? AND ?
            GROUP BY day
            """
        return queryDayAggregation(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )
    }

    // MARK: - 笔记数聚合

    /// 按天 COUNT(note)
    nonisolated func aggregateNoteCounts(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
        let sql = """
            SELECT DATE(created_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS total
            FROM note
            WHERE is_deleted = 0
              AND created_date BETWEEN ? AND ?
            GROUP BY day
            """
        return queryDayAggregation(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )
    }

    // MARK: - 打卡聚合

    /// 按天聚合打卡次数与时长（amount * 20 分钟）
    nonisolated func aggregateCheckInSummary(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: CheckInSummary] {
        let sql = """
            SELECT DATE(checkin_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS checkin_count,
                   COALESCE(SUM(amount * 1200), 0) AS checkin_seconds
            FROM check_in_record
            WHERE is_deleted = 0 AND checkin_date != 0
              AND checkin_date BETWEEN ? AND ?
            GROUP BY day
            """
        return queryDayCheckInSummary(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )
    }

    // MARK: - 阅读状态聚合

    nonisolated func aggregateBookStates(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Set<HeatmapBookState>] {
        let sql = """
            SELECT DATE(changed_date / 1000, 'unixepoch', 'localtime') AS day,
                   read_status_id
            FROM book_read_status_record
            WHERE is_deleted = 0
              AND changed_date != 0
              AND changed_date BETWEEN ? AND ?
            ORDER BY changed_date ASC
            """
        guard let rows = try? Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        ) else { return [:] }

        var result: [Date: Set<HeatmapBookState>] = [:]
        for row in rows {
            guard let dayStr: String = row["day"],
                  let statusId: Int64 = row["read_status_id"],
                  let date = Self.dayFormatter.date(from: dayStr),
                  let state = HeatmapBookState(rawValue: Int(statusId)) else { continue }
            let day = calendar.startOfDay(for: date)
            result[day, default: []].insert(state)
        }
        return result
    }

    // MARK: - 通用日期聚合

    /// 执行 day+total 聚合 SQL，返回 [Date: Int] 字典
    nonisolated func queryDayAggregation(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments()
    ) -> [Date: Int] {
        guard let rows = try? Row.fetchAll(db, sql: sql, arguments: arguments) else { return [:] }

        var result: [Date: Int] = [:]
        for row in rows {
            guard let dayStr: String = row["day"],
                  let total: Int = row["total"],
                  let date = Self.dayFormatter.date(from: dayStr) else { continue }
            result[calendar.startOfDay(for: date)] = total
        }
        return result
    }

    /// 执行打卡聚合 SQL，返回 [Date: CheckInSummary] 字典
    nonisolated func queryDayCheckInSummary(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = StatementArguments()
    ) -> [Date: CheckInSummary] {
        guard let rows = try? Row.fetchAll(db, sql: sql, arguments: arguments) else { return [:] }

        var result: [Date: CheckInSummary] = [:]
        for row in rows {
            guard let dayStr: String = row["day"],
                  let count: Int = row["checkin_count"],
                  let seconds: Int = row["checkin_seconds"],
                  let date = Self.dayFormatter.date(from: dayStr) else { continue }
            result[calendar.startOfDay(for: date)] = CheckInSummary(
                count: count,
                seconds: seconds
            )
        }
        return result
    }

    // MARK: - 阅读日历

    nonisolated func buildReadCalendarMonthData(
        _ db: Database,
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> ReadCalendarMonthData {
        let normalizedMonthStart = normalizeToMonthStart(monthStart)
        guard let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: normalizedMonthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonthStart) else {
            return .empty(for: normalizedMonthStart)
        }

        let queryRange = millisRangeForQuery(HeatmapDateRange(start: normalizedMonthStart, end: monthEnd))
        let dayBookRows = fetchReadCalendarDayBookRows(db, millisRange: queryRange, excludedEventTypes: excludedEventTypes)
        let readDoneMap = fetchReadDoneCountByDay(db, millisRange: queryRange)
        let readDoneBookIdsByDay = fetchReadDoneBookIdsByDay(db, millisRange: queryRange)
        let monthMillisRange = queryRange
        let durationRecords = excludedEventTypes.contains(.readTiming)
            ? []
            : fetchReadCalendarDurationRecords(
                db,
                monthStart: normalizedMonthStart,
                nextMonthStart: nextMonthStart
            )
        let durationAggregation = aggregateReadCalendarDuration(
            records: durationRecords,
            monthMillisRange: monthMillisRange
        )

        var dayBookMap: [Date: [ReadCalendarDayBook]] = [:]
        for row in dayBookRows {
            let book = ReadCalendarDayBook(
                id: row.bookId,
                name: row.bookName,
                coverURL: row.bookCover,
                firstEventTime: row.firstEventTime,
                isReadDoneOnThisDay: readDoneBookIdsByDay[row.day]?.contains(row.bookId) == true
            )
            dayBookMap[row.day, default: []].append(book)
        }

        var days: [Date: ReadCalendarDay] = [:]
        let dayKeys = Set(dayBookMap.keys).union(readDoneMap.keys)
        for day in dayKeys {
            let books = (dayBookMap[day] ?? []).sorted {
                if $0.firstEventTime != $1.firstEventTime {
                    return $0.firstEventTime < $1.firstEventTime
                }
                return $0.id < $1.id
            }
            days[day] = ReadCalendarDay(
                date: day,
                books: books,
                readDoneCount: readDoneMap[day] ?? 0
            )
        }

        let readingDurationTopBooks = buildReadCalendarMonthlyDurationTopBooks(
            aggregation: durationAggregation
        )
        let monthSummary = buildReadCalendarMonthSummary(
            excludedEventTypes: excludedEventTypes,
            dayBookRows: dayBookRows,
            monthMillisRange: monthMillisRange,
            durationAggregation: durationAggregation,
            db: db
        )

        return ReadCalendarMonthData(
            monthStart: normalizedMonthStart,
            days: days,
            readingDurationTopBooks: readingDurationTopBooks,
            summary: monthSummary
        )
    }

    nonisolated func normalizeToMonthStart(_ date: Date) -> Date {
        let base = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month], from: base)
        guard let monthStart = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) else {
            return base
        }
        return calendar.startOfDay(for: monthStart)
    }

    nonisolated func fetchReadCalendarDayBookRows(
        _ db: Database,
        millisRange: ClosedRange<Int64>,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> [ReadCalendarDayBookRow] {
        let fragments = buildEventFragments(excludedEventTypes: excludedEventTypes)
        guard !fragments.isEmpty else { return [] }

        let unionAll = fragments.map(\.sql).joined(separator: "\n\n                UNION ALL\n\n")
        let sql = """
            WITH raw_events AS (
                \(unionAll)
            ),
            merged AS (
                SELECT day, book_id, MIN(first_event_time) AS first_event_time
                FROM raw_events
                GROUP BY day, book_id
            )
            SELECT merged.day AS day,
                   merged.book_id AS book_id,
                   merged.first_event_time AS first_event_time,
                   b.name AS book_name,
                   b.cover AS book_cover
            FROM merged
            JOIN book b ON b.id = merged.book_id AND b.is_deleted = 0
            ORDER BY merged.day ASC, merged.first_event_time ASC, merged.book_id ASC
            """

        var args: [Int64] = []
        for fragment in fragments {
            args.append(contentsOf: fragment.args(millisRange))
        }

        guard let rows = try? Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) else {
            return []
        }

        var result: [ReadCalendarDayBookRow] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let dayStr: String = row["day"],
                  let bookId: Int64 = row["book_id"],
                  let firstEventTime: Int64 = row["first_event_time"],
                  let bookName: String = row["book_name"],
                  let date = Self.dayFormatter.date(from: dayStr) else { continue }
            let day = calendar.startOfDay(for: date)
            let bookCover: String = row["book_cover"] ?? ""
            result.append(ReadCalendarDayBookRow(
                day: day,
                bookId: bookId,
                bookName: bookName,
                bookCover: bookCover,
                firstEventTime: firstEventTime
            ))
        }
        return result
    }

    nonisolated func fetchReadDoneCountByDay(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
        let sql = """
            SELECT DATE(changed_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS total
            FROM book_read_status_record
            WHERE is_deleted = 0
              AND read_status_id = 3
              AND changed_date != 0
              AND changed_date BETWEEN ? AND ?
            GROUP BY day
            """
        return queryDayAggregation(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )
    }

    nonisolated func fetchReadDoneBookIdsByDay(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Set<Int64>] {
        let sql = """
            SELECT DATE(changed_date / 1000, 'unixepoch', 'localtime') AS day,
                   book_id AS book_id
            FROM book_read_status_record
            WHERE is_deleted = 0
              AND read_status_id = 3
              AND changed_date != 0
              AND book_id != 0
              AND changed_date BETWEEN ? AND ?
            GROUP BY day, book_id
            """
        guard let rows = try? Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        ) else {
            return [:]
        }

        var result: [Date: Set<Int64>] = [:]
        for row in rows {
            guard let dayStr: String = row["day"],
                  let bookId: Int64 = row["book_id"],
                  let date = Self.dayFormatter.date(from: dayStr) else { continue }
            let day = calendar.startOfDay(for: date)
            result[day, default: []].insert(bookId)
        }
        return result
    }

    nonisolated func fetchReadCalendarDurationRecords(
        _ db: Database,
        monthStart: Date,
        nextMonthStart: Date
    ) -> [ReadCalendarDurationRecordRow] {
        let monthStartMs = Int64(calendar.startOfDay(for: monthStart).timeIntervalSince1970 * 1000)
        let nextMonthStartMs = Int64(calendar.startOfDay(for: nextMonthStart).timeIntervalSince1970 * 1000)
        let monthEndMs = nextMonthStartMs - 1

        let sql = """
            SELECT r.book_id AS book_id,
                   b.name AS book_name,
                   b.cover AS book_cover,
                   r.start_time AS start_time,
                   r.end_time AS end_time,
                   r.elapsed_seconds AS elapsed_seconds,
                   r.fuzzy_read_date AS fuzzy_read_date
            FROM read_time_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND r.status = 3
              AND r.book_id != 0
              AND r.elapsed_seconds > 0
              AND (
                (r.fuzzy_read_date != 0 AND r.fuzzy_read_date BETWEEN ? AND ?)
                OR
                (r.fuzzy_read_date = 0 AND r.end_time >= ? AND r.start_time <= ?)
              )
            """

        guard let rows = try? Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments([monthStartMs, monthEndMs, monthStartMs, monthEndMs])
        ) else {
            return []
        }

        var records: [ReadCalendarDurationRecordRow] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            guard let bookId: Int64 = row["book_id"],
                  let bookName: String = row["book_name"],
                  let startTime: Int64 = row["start_time"],
                  let endTime: Int64 = row["end_time"],
                  let elapsedSeconds: Int64 = row["elapsed_seconds"],
                  let fuzzyReadDate: Int64 = row["fuzzy_read_date"] else {
                continue
            }
            let bookCover: String = row["book_cover"] ?? ""
            records.append(
                ReadCalendarDurationRecordRow(
                    bookId: bookId,
                    bookName: bookName,
                    bookCover: bookCover,
                    startTime: startTime,
                    endTime: endTime,
                    elapsedSeconds: elapsedSeconds,
                    fuzzyReadDate: fuzzyReadDate
                )
            )
        }
        return records
    }

    nonisolated func aggregateReadCalendarDuration(
        records: [ReadCalendarDurationRecordRow],
        monthMillisRange: ClosedRange<Int64>
    ) -> ReadCalendarDurationAggregation {
        var readSecondsByBookId: [Int64: Int64] = [:]
        var bookMetaById: [Int64: (name: String, coverURL: String)] = [:]
        var totalReadSeconds: Int64 = 0
        var timeSlotReadSeconds: [ReadCalendarTimeSlot: Int] = [:]
        for record in records {
            bookMetaById[record.bookId] = (record.bookName, record.bookCover)
            let dayBuckets = splitReadDurationByDay(
                startTime: record.startTime,
                endTime: record.endTime,
                elapsedSeconds: record.elapsedSeconds,
                fuzzyReadDate: record.fuzzyReadDate
            )
            var secondsInMonthForRecord: Int64 = 0
            for (day, seconds) in dayBuckets {
                let dayMs = Int64(day.timeIntervalSince1970 * 1000)
                guard monthMillisRange.contains(dayMs) else { continue }
                secondsInMonthForRecord += seconds
                readSecondsByBookId[record.bookId, default: 0] += seconds
            }

            guard secondsInMonthForRecord > 0 else { continue }
            totalReadSeconds += secondsInMonthForRecord

            if record.fuzzyReadDate == 0 {
                let startDate = Date(timeIntervalSince1970: Double(record.startTime) / 1000)
                let startDayMs = Int64(calendar.startOfDay(for: startDate).timeIntervalSince1970 * 1000)
                if monthMillisRange.contains(startDayMs) {
                    let hour = calendar.component(.hour, from: startDate)
                    let slot = readCalendarTimeSlot(forHour: hour)
                    timeSlotReadSeconds[slot, default: 0] += Int(secondsInMonthForRecord)
                }
            }
        }

        return ReadCalendarDurationAggregation(
            readSecondsByBookId: readSecondsByBookId,
            bookMetaById: bookMetaById,
            totalReadSeconds: totalReadSeconds,
            timeSlotReadSeconds: timeSlotReadSeconds
        )
    }

    nonisolated func buildReadCalendarMonthlyDurationTopBooks(
        aggregation: ReadCalendarDurationAggregation,
        limit: Int = 10
    ) -> [ReadCalendarMonthlyDurationBook] {
        aggregation.readSecondsByBookId.compactMap { bookId, seconds -> ReadCalendarMonthlyDurationBook? in
            guard seconds > 0, let meta = aggregation.bookMetaById[bookId] else { return nil }
            return ReadCalendarMonthlyDurationBook(
                bookId: bookId,
                name: meta.name,
                coverURL: meta.coverURL,
                readSeconds: Int(seconds)
            )
        }
        .sorted { lhs, rhs in
            if lhs.readSeconds != rhs.readSeconds { return lhs.readSeconds > rhs.readSeconds }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.bookId < rhs.bookId
        }
        .prefix(limit)
        .map { $0 }
    }

    nonisolated func buildReadCalendarMonthSummary(
        excludedEventTypes: Set<ReadCalendarEventType>,
        dayBookRows: [ReadCalendarDayBookRow],
        monthMillisRange: ClosedRange<Int64>,
        durationAggregation: ReadCalendarDurationAggregation,
        db: Database
    ) -> ReadCalendarMonthSummary {
        let uniqueReadBookCount = Set(dayBookRows.map(\.bookId)).count
        let finishedBookCount = excludedEventTypes.contains(.readDone)
            ? 0
            : fetchReadDoneDistinctBookCount(db, millisRange: monthMillisRange)
        let noteCount = excludedEventTypes.contains(.note)
            ? 0
            : fetchMonthlyNoteCount(db, millisRange: monthMillisRange)
        let totalReadSeconds = excludedEventTypes.contains(.readTiming) ? 0 : Int(durationAggregation.totalReadSeconds)
        let timeSlotReadSeconds = excludedEventTypes.contains(.readTiming) ? [:] : durationAggregation.timeSlotReadSeconds

        return ReadCalendarMonthSummary(
            uniqueReadBookCount: uniqueReadBookCount,
            finishedBookCount: finishedBookCount,
            noteCount: noteCount,
            totalReadSeconds: totalReadSeconds,
            timeSlotReadSeconds: timeSlotReadSeconds
        )
    }

    nonisolated func fetchReadDoneDistinctBookCount(_ db: Database, millisRange: ClosedRange<Int64>) -> Int {
        let sql = """
            SELECT COUNT(DISTINCT book_id)
            FROM book_read_status_record
            WHERE is_deleted = 0
              AND read_status_id = 3
              AND changed_date != 0
              AND book_id != 0
              AND changed_date BETWEEN ? AND ?
            """
        return (try? Int.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )) ?? 0
    }

    nonisolated func fetchMonthlyNoteCount(_ db: Database, millisRange: ClosedRange<Int64>) -> Int {
        let sql = """
            SELECT COUNT(*)
            FROM note
            WHERE is_deleted = 0
              AND created_date BETWEEN ? AND ?
            """
        return (try? Int.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )) ?? 0
    }

    nonisolated func readCalendarTimeSlot(forHour hour: Int) -> ReadCalendarTimeSlot {
        switch hour {
        case 5..<12:
            return .morning
        case 12..<18:
            return .afternoon
        case 18..<24:
            return .evening
        default:
            return .lateNight
        }
    }

    /// 对齐 Android ReadTimeRecord.splitCrossDayRecords：
    /// - fuzzy 记录不拆分，整条归属到 fuzzy_read_date 当天
    /// - 精确记录按 start_time/end_time 跨天拆段，并按 wall-time 比例分配 elapsed_seconds
    nonisolated func splitReadDurationByDay(
        startTime: Int64,
        endTime: Int64,
        elapsedSeconds: Int64,
        fuzzyReadDate: Int64
    ) -> [(Date, Int64)] {
        guard elapsedSeconds > 0 else { return [] }

        if fuzzyReadDate != 0 {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(fuzzyReadDate) / 1000))
            return [(day, elapsedSeconds)]
        }

        let startMillis = startTime
        let endMillis = endTime > startTime ? endTime : startTime + elapsedSeconds * 1000
        let startDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(startMillis) / 1000))
        let endDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(endMillis) / 1000))

        if startDate == endDate {
            return [(startDate, elapsedSeconds)]
        }

        let wallTimeTotalMs = max(1, endMillis - startMillis)
        let elapsedSecondsTotal = elapsedSeconds
        var allocatedSeconds: Int64 = 0
        var result: [(Date, Int64)] = []
        var currentMillis = startMillis
        var cursorDate = startDate

        while cursorDate <= endDate && allocatedSeconds < elapsedSecondsTotal {
            guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: cursorDate) else { break }

            let startOfDayMs = Int64(cursorDate.timeIntervalSince1970 * 1000)
            let endOfDayMs = Int64(nextDayStart.timeIntervalSince1970 * 1000) - 1
            let segmentStart = max(currentMillis, startOfDayMs)
            let segmentEnd = min(endMillis, endOfDayMs)
            if segmentStart >= segmentEnd {
                cursorDate = nextDayStart
                continue
            }

            let segmentWallTimeMs = segmentEnd - segmentStart
            let segmentRatio = Double(segmentWallTimeMs) / Double(wallTimeTotalMs)
            var segmentSeconds = Int64((segmentRatio * Double(elapsedSecondsTotal)).rounded())
            if allocatedSeconds + segmentSeconds > elapsedSecondsTotal {
                segmentSeconds = elapsedSecondsTotal - allocatedSeconds
            }
            if segmentSeconds > 0 {
                allocatedSeconds += segmentSeconds
                result.append((cursorDate, segmentSeconds))
            }

            currentMillis = segmentEnd + 1
            cursorDate = nextDayStart
        }

        return result
    }

    nonisolated func findReadCalendarEarliestDate(
        _ db: Database,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> Date? {
        let typeQueryMap: [(ReadCalendarEventType, String)] = [
            (.readTiming, """
                SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
                FROM read_time_record
                WHERE is_deleted = 0
                """),
            (.note, "SELECT MIN(created_date) FROM note WHERE is_deleted = 0"),
            (.relevant, "SELECT MIN(created_date) FROM category_content WHERE is_deleted = 0"),
            (.review, "SELECT MIN(created_date) FROM review WHERE is_deleted = 0"),
            (.checkIn, "SELECT MIN(checkin_date) FROM check_in_record WHERE is_deleted = 0 AND checkin_date != 0"),
            (.readDone, """
                SELECT MIN(changed_date)
                FROM book_read_status_record
                WHERE is_deleted = 0
                  AND changed_date != 0
                  AND read_status_id = 3
                """)
        ]

        let queries = typeQueryMap
            .filter { !excludedEventTypes.contains($0.0) }
            .map(\.1)

        guard !queries.isEmpty else { return nil }

        let timestamps = queries.compactMap { sql -> Int64? in
            guard let value = try? Int64.fetchOne(db, sql: sql), value > 0 else { return nil }
            return value
        }
        guard let earliest = timestamps.min() else { return nil }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: Double(earliest) / 1000))
    }

    // MARK: - SQL 事件片段动态组装

    nonisolated struct EventSQLFragment {
        let eventType: ReadCalendarEventType
        let sql: String
        let args: (ClosedRange<Int64>) -> [Int64]
    }

    nonisolated static let allEventFragments: [EventSQLFragment] = [
        EventSQLFragment(
            eventType: .readTiming,
            sql: """
                SELECT DATE(
                    CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date / 1000 ELSE start_time / 1000 END,
                    'unixepoch', 'localtime'
                ) AS day,
                book_id AS book_id,
                MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END) AS first_event_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND book_id != 0
                  AND (CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END) BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .note,
            sql: """
                SELECT DATE(created_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(created_date) AS first_event_time
                FROM note
                WHERE is_deleted = 0
                  AND book_id != 0
                  AND created_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .relevant,
            sql: """
                SELECT DATE(created_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(created_date) AS first_event_time
                FROM category_content
                WHERE is_deleted = 0
                  AND book_id != 0
                  AND created_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .review,
            sql: """
                SELECT DATE(created_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(created_date) AS first_event_time
                FROM review
                WHERE is_deleted = 0
                  AND book_id != 0
                  AND created_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .checkIn,
            sql: """
                SELECT DATE(checkin_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(checkin_date) AS first_event_time
                FROM check_in_record
                WHERE is_deleted = 0
                  AND checkin_date != 0
                  AND book_id != 0
                  AND checkin_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .readDone,
            sql: """
                SELECT DATE(changed_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(changed_date) AS first_event_time
                FROM book_read_status_record
                WHERE is_deleted = 0
                  AND changed_date != 0
                  AND read_status_id = 3
                  AND book_id != 0
                  AND changed_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        )
    ]

    nonisolated func buildEventFragments(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> [EventSQLFragment] {
        Self.allEventFragments.filter { !excludedEventTypes.contains($0.eventType) }
    }
}
