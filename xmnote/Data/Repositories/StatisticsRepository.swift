import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 Heatmap 与阅读日历领域模型
 * [OUTPUT]: 对外提供 StatisticsRepository（StatisticsRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层统计仓储实现，聚合热力图与阅读日历月视图数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct StatisticsRepository: StatisticsRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let calendar = Calendar.current

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func fetchHeatmapData(
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) async throws -> (days: [Date: HeatmapDay], earliestDate: Date?, latestDate: Date?) {
        try await databaseManager.database.dbPool.read { db in
            buildHeatmapData(db, year: year, dataType: dataType)
        }
    }

    func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?) {
        let result = try await fetchHeatmapData(year: 0, dataType: .all)
        return (result.days, result.earliestDate)
    }

    func fetchReadCalendarEarliestDate() async throws -> Date? {
        try await databaseManager.database.dbPool.read { db in
            findReadCalendarEarliestDate(db)
        }
    }

    func fetchReadCalendarMonthData(monthStart: Date) async throws -> ReadCalendarMonthData {
        try await databaseManager.database.dbPool.read { db in
            buildReadCalendarMonthData(db, monthStart: monthStart)
        }
    }
}

// MARK: - 共享格式化器

private extension StatisticsRepository {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static let monthFormatter: DateFormatter = {
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

private extension StatisticsRepository {

    /// 按统计维度与年份聚合热力图数据
    func buildHeatmapData(
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

    func resolveDateRange(
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

    func yearDateRange(_ year: Int) -> HeatmapDateRange? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return nil
        }
        return HeatmapDateRange(
            start: calendar.startOfDay(for: start),
            end: calendar.startOfDay(for: end)
        )
    }

    func millisRangeForQuery(_ dateRange: HeatmapDateRange) -> ClosedRange<Int64> {
        let startMs = Int64(calendar.startOfDay(for: dateRange.start).timeIntervalSince1970 * 1000)
        let endDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateRange.end))!
        let endMs = Int64(endDay.timeIntervalSince1970 * 1000) - 1
        return startMs...endMs
    }

    func shouldQueryReadMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .readingTime || dataType == .all
    }

    func shouldQueryNoteMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .noteCount || dataType == .all
    }

    func shouldQueryCheckInMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .checkIn || dataType == .all
    }

    func shouldInclude(day: HeatmapDay, dataType: HeatmapStatisticsDataType) -> Bool {
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

    func findEarliestDate(_ db: Database, dataType: HeatmapStatisticsDataType) -> Date? {
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
    func aggregateReadSeconds(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
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
    func aggregateNoteCounts(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
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
    func aggregateCheckInSummary(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: CheckInSummary] {
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

    func aggregateBookStates(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Set<HeatmapBookState>] {
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
    func queryDayAggregation(
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
    func queryDayCheckInSummary(
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

    func buildReadCalendarMonthData(_ db: Database, monthStart: Date) -> ReadCalendarMonthData {
        let normalizedMonthStart = normalizeToMonthStart(monthStart)
        guard let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: normalizedMonthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonthStart) else {
            return .empty(for: normalizedMonthStart)
        }

        let queryRange = millisRangeForQuery(HeatmapDateRange(start: normalizedMonthStart, end: monthEnd))
        let dayBookRows = fetchReadCalendarDayBookRows(db, millisRange: queryRange)
        let readDoneMap = fetchReadDoneCountByDay(db, millisRange: queryRange)

        var dayBookMap: [Date: [ReadCalendarDayBook]] = [:]
        for row in dayBookRows {
            let book = ReadCalendarDayBook(
                id: row.bookId,
                name: row.bookName,
                coverURL: row.bookCover,
                firstEventTime: row.firstEventTime
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

        return ReadCalendarMonthData(monthStart: normalizedMonthStart, days: days)
    }

    func normalizeToMonthStart(_ date: Date) -> Date {
        let base = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month], from: base)
        guard let monthStart = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) else {
            return base
        }
        return calendar.startOfDay(for: monthStart)
    }

    func fetchReadCalendarDayBookRows(_ db: Database, millisRange: ClosedRange<Int64>) -> [ReadCalendarDayBookRow] {
        let sql = """
            WITH raw_events AS (
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

                UNION ALL

                SELECT DATE(created_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(created_date) AS first_event_time
                FROM note
                WHERE is_deleted = 0
                  AND book_id != 0
                  AND created_date BETWEEN ? AND ?
                GROUP BY day, book_id

                UNION ALL

                SELECT DATE(created_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(created_date) AS first_event_time
                FROM category_content
                WHERE is_deleted = 0
                  AND book_id != 0
                  AND created_date BETWEEN ? AND ?
                GROUP BY day, book_id

                UNION ALL

                SELECT DATE(created_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(created_date) AS first_event_time
                FROM review
                WHERE is_deleted = 0
                  AND book_id != 0
                  AND created_date BETWEEN ? AND ?
                GROUP BY day, book_id

                UNION ALL

                SELECT DATE(checkin_date / 1000, 'unixepoch', 'localtime') AS day,
                       book_id AS book_id,
                       MIN(checkin_date) AS first_event_time
                FROM check_in_record
                WHERE is_deleted = 0
                  AND checkin_date != 0
                  AND book_id != 0
                  AND checkin_date BETWEEN ? AND ?
                GROUP BY day, book_id

                UNION ALL

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

        let args: [Int64] = [
            millisRange.lowerBound, millisRange.upperBound,
            millisRange.lowerBound, millisRange.upperBound,
            millisRange.lowerBound, millisRange.upperBound,
            millisRange.lowerBound, millisRange.upperBound,
            millisRange.lowerBound, millisRange.upperBound,
            millisRange.lowerBound, millisRange.upperBound
        ]

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

    func fetchReadDoneCountByDay(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
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

    func findReadCalendarEarliestDate(_ db: Database) -> Date? {
        let queries: [String] = [
            """
            SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
            FROM read_time_record
            WHERE is_deleted = 0
            """,
            "SELECT MIN(created_date) FROM note WHERE is_deleted = 0",
            "SELECT MIN(created_date) FROM category_content WHERE is_deleted = 0",
            "SELECT MIN(created_date) FROM review WHERE is_deleted = 0",
            "SELECT MIN(checkin_date) FROM check_in_record WHERE is_deleted = 0 AND checkin_date != 0",
            """
            SELECT MIN(changed_date)
            FROM book_read_status_record
            WHERE is_deleted = 0
              AND changed_date != 0
              AND read_status_id = 3
            """
        ]

        let timestamps = queries.compactMap { sql -> Int64? in
            guard let value = try? Int64.fetchOne(db, sql: sql), value > 0 else { return nil }
            return value
        }
        guard let earliest = timestamps.min() else { return nil }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: Double(earliest) / 1000))
    }
}
