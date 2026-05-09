import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 Heatmap 与阅读日历领域模型
 * [OUTPUT]: 对外提供 StatisticsRepository（StatisticsRepositoryProtocol 的 GRDB 实现，含阅读日历月度阅读时长排行与月度摘要聚合）
 * [POS]: Data 层统计仓储实现，聚合热力图与阅读日历月视图数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// StatisticsRepository 统一承接热力图、阅读日历和月度/年度统计聚合查询。
nonisolated struct StatisticsRepository: StatisticsRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let calendar = Calendar.current

    /// 注入数据库管理器，为热力图与阅读日历统计查询提供数据源。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    /// 拉取指定年份和统计维度的热力图数据，供阅读统计页渲染年视图。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchHeatmapData(
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) async throws -> (days: [Date: HeatmapDay], earliestDate: Date?, latestDate: Date?) {
        try await databaseManager.database.dbPool.read { db in
            buildHeatmapData(db, year: year, dataType: dataType)
        }
    }

    /// 拉取全量时间范围的热力图数据，供需要跨年统计的入口使用。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?) {
        let result = try await fetchHeatmapData(year: 0, dataType: .all)
        return (result.days, result.earliestDate)
    }

    /// 读取阅读日历可展示的最早业务日期，供月份步进器计算下界。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchReadCalendarEarliestDate(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> Date? {
        try await databaseManager.database.dbPool.read { db in
            findReadCalendarEarliestDate(db, excludedEventTypes: excludedEventTypes)
        }
    }

    /// 聚合单月阅读日历数据（每天书目、完成数、时长与摘要），供月视图页面渲染。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchReadCalendarMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData {
        try await databaseManager.database.dbPool.read { db in
            buildReadCalendarMonthData(db, monthStart: monthStart, excludedEventTypes: excludedEventTypes)
        }
    }

    /// 聚合年度阅读时长排行，供阅读统计页“年度 Top 书籍”模块展示。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchReadCalendarYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int
    ) async throws -> [ReadCalendarMonthlyDurationBook] {
        guard !excludedEventTypes.contains(.readTiming) else { return [] }
        guard limit > 0 else { return [] }
        return try await databaseManager.database.dbPool.read { db in
            buildReadCalendarYearTopBooks(db, year: year, limit: limit)
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

    /// 计算热力图查询时间边界：指定年份走自然年，未指定年份取业务最早日期到今天。
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

    /// 生成指定年份的自然年日期范围（本地时区起止日）。
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

    /// 把按天的日期区间转换为数据库查询使用的毫秒闭区间。
    nonisolated func millisRangeForQuery(_ dateRange: HeatmapDateRange) -> ClosedRange<Int64> {
        let startMs = Int64(calendar.startOfDay(for: dateRange.start).timeIntervalSince1970 * 1000)
        let endDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateRange.end))!
        let endMs = Int64(endDay.timeIntervalSince1970 * 1000) - 1
        return startMs...endMs
    }

    /// 判断当前维度是否需要查询阅读时长数据。
    nonisolated func shouldQueryReadMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .readingTime || dataType == .all
    }

    /// 判断当前维度是否需要查询笔记计数数据。
    nonisolated func shouldQueryNoteMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .noteCount || dataType == .all
    }

    /// 判断当前维度是否需要查询打卡数据。
    nonisolated func shouldQueryCheckInMap(_ dataType: HeatmapStatisticsDataType) -> Bool {
        dataType == .checkIn || dataType == .all
    }

    /// 判断某一天是否应出现在热力图结果中，避免输出空白日期节点。
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

    /// 按统计维度查询最早业务日期，作为“全部数据”模式的起始边界。
    nonisolated func findEarliestDate(_ db: Database, dataType: HeatmapStatisticsDataType) -> Date? {
        // SQL 目的：读取阅读时长最早事件时间；fuzzy_read_date 优先，其次 start_time。
        // 过滤条件：排除软删除、未完成计时与默认占位书记录。
        let readSql = """
            SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
            FROM read_time_record
            WHERE is_deleted = 0
              AND status = 3
              AND book_id != 0
            """
        // SQL 目的：读取仍归属于有效书籍的 note 最早创建时间（毫秒时间戳）。
        let noteSql = """
            SELECT MIN(n.created_date)
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            WHERE n.is_deleted = 0
            """
        // SQL 目的：读取有效书籍下 check_in_record 最早打卡时间（忽略 0 值）。
        let checkInSql = """
            SELECT MIN(c.checkin_date)
            FROM check_in_record c
            JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
            WHERE c.is_deleted = 0
              AND c.checkin_date != 0
              AND c.book_id != 0
            """
        // SQL 目的：读取 book_read_status_record 最早状态变更时间，覆盖“仅状态变化”场景。
        let statusSql = """
            SELECT MIN(r.changed_date)
            FROM book_read_status_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND r.changed_date != 0
              AND r.book_id != 0
            """

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

    /// 按天 SUM(elapsed_seconds)，处理 fuzzyReadDate 双时间源。
    /// 时区约定：SQL 使用 SQLite 'localtime' 修饰符，与 Swift 侧 `Calendar.current.startOfDay` 保持一致——
    /// 两端均依赖设备时区，确保日期边界对齐。若设备时区在运行期变更，已缓存数据可能出现偏移。
    nonisolated func aggregateReadSeconds(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
        // SQL 目的：按“本地日”汇总阅读秒数，用于热力图阅读时长维度。
        // 时间语义：fuzzy_read_date 非 0 时按补录日期归属，否则按 start_time；均以 localtime 分桶。
        // 过滤条件：排除软删除、未完成计时与默认占位书，并限制在输入毫秒区间内。
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
              AND status = 3
              AND book_id != 0
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
        // SQL 目的：按“本地日”统计归属于有效书籍的笔记条数。
        // 过滤条件：统计 note/book 均未软删除且 created_date 位于目标区间的记录。
        let sql = """
            SELECT DATE(n.created_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS total
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            WHERE n.is_deleted = 0
              AND n.created_date BETWEEN ? AND ?
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
        // SQL 目的：按“本地日”统计有效书籍下的打卡次数与打卡时长（amount * 1200 秒）。
        // 过滤条件：排除软删除、默认占位书与 checkin_date=0 的无效记录。
        let sql = """
            SELECT DATE(c.checkin_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS checkin_count,
                   COALESCE(SUM(c.amount * 1200), 0) AS checkin_seconds
            FROM check_in_record c
            JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
            WHERE c.is_deleted = 0
              AND c.book_id != 0
              AND c.checkin_date != 0
              AND c.checkin_date BETWEEN ? AND ?
            GROUP BY day
            """
        return queryDayCheckInSummary(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )
    }

    // MARK: - 阅读状态聚合

    /// 聚合每日阅读状态变更集合，支持热力图展示“想读/在读/读完”等状态轨迹。
    nonisolated func aggregateBookStates(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Set<HeatmapBookState>] {
        // SQL 目的：按天收集有效书籍的阅读状态变更（read_status_id），用于“状态热力图”展示。
        // 输出字段：day + read_status_id；后续在 Swift 侧转为 Set<HeatmapBookState> 去重。
        let sql = """
            SELECT DATE(r.changed_date / 1000, 'unixepoch', 'localtime') AS day,
                   r.read_status_id
            FROM book_read_status_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND r.book_id != 0
              AND r.changed_date != 0
              AND r.changed_date BETWEEN ? AND ?
            ORDER BY r.changed_date ASC
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

    /// 构建阅读日历单月聚合结果，包含每日事件、阅读时长排行与月度摘要。
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
        let dayReadSecondsMap = excludedEventTypes.contains(.readTiming)
            ? [:]
            : aggregateReadSeconds(db, millisRange: monthMillisRange)
        let dayNoteCountMap = excludedEventTypes.contains(.note)
            ? [:]
            : aggregateNoteCounts(db, millisRange: monthMillisRange)
        let dayCheckInMap = excludedEventTypes.contains(.checkIn)
            ? [:]
            : aggregateCheckInSummary(db, millisRange: monthMillisRange)
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
        let dayKeys = Set(dayBookMap.keys)
            .union(readDoneMap.keys)
            .union(dayReadSecondsMap.keys)
            .union(dayNoteCountMap.keys)
            .union(dayCheckInMap.keys)
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
                readDoneCount: readDoneMap[day] ?? 0,
                readSeconds: dayReadSecondsMap[day] ?? 0,
                noteCount: dayNoteCountMap[day] ?? 0,
                checkInCount: dayCheckInMap[day]?.count ?? 0,
                checkInSeconds: dayCheckInMap[day]?.seconds ?? 0
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

    /// 把任意日期归一化到该月第一天 00:00，保证月度查询边界稳定。
    nonisolated func normalizeToMonthStart(_ date: Date) -> Date {
        let base = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month], from: base)
        guard let monthStart = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) else {
            return base
        }
        return calendar.startOfDay(for: monthStart)
    }

    /// 读取“天-书籍”维度的事件行，供阅读日历单元格渲染当日触发过行为的书目。
    nonisolated func fetchReadCalendarDayBookRows(
        _ db: Database,
        millisRange: ClosedRange<Int64>,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> [ReadCalendarDayBookRow] {
        let fragments = buildEventFragments(excludedEventTypes: excludedEventTypes)
        guard !fragments.isEmpty else { return [] }

        let unionAll = fragments.map(\.sql).joined(separator: "\n\n                UNION ALL\n\n")
        // SQL 目的：合并多事件来源（阅读时长/笔记/关联/书评/打卡/读完）为“按天-按书”事件视图。
        // CTE 说明：
        // - raw_events：拼接启用的事件片段（已按事件类型过滤）。
        // - merged：对 day + book_id 聚合取最早 first_event_time，供日历条排序。
        // 关联关系：JOIN book 过滤已删除书籍并补全名称/封面。
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

    /// 统计每天“读完”事件数量，供阅读日历显示当日读完本数。
    nonisolated func fetchReadDoneCountByDay(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
        // SQL 目的：统计每天“读完”事件次数（read_status_id = 3）。
        // 过滤条件：排除软删除、默认占位书、已删除书、changed_date=0 与区间外记录。
        let sql = """
            SELECT DATE(r.changed_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS total
            FROM book_read_status_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND r.read_status_id = 3
              AND r.changed_date != 0
              AND r.book_id != 0
              AND r.changed_date BETWEEN ? AND ?
            GROUP BY day
            """
        return queryDayAggregation(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )
    }

    /// 统计每天进入“读完”状态的书籍集合，用于给当日书目打“已读完”标记。
    nonisolated func fetchReadDoneBookIdsByDay(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Set<Int64>] {
        // SQL 目的：统计每天进入“读完”状态的有效书籍集合（day + book_id 去重）。
        // 用途：在日历单元中标记 isReadDoneOnThisDay。
        let sql = """
            SELECT DATE(r.changed_date / 1000, 'unixepoch', 'localtime') AS day,
                   r.book_id AS book_id
            FROM book_read_status_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND r.read_status_id = 3
              AND r.changed_date != 0
              AND r.book_id != 0
              AND r.changed_date BETWEEN ? AND ?
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

    /// 读取月份范围内的阅读时长原始记录，供月度时长排行与摘要计算。
    nonisolated func fetchReadCalendarDurationRecords(
        _ db: Database,
        monthStart: Date,
        nextMonthStart: Date
    ) -> [ReadCalendarDurationRecordRow] {
        let monthStartMs = Int64(calendar.startOfDay(for: monthStart).timeIntervalSince1970 * 1000)
        let nextMonthStartMs = Int64(calendar.startOfDay(for: nextMonthStart).timeIntervalSince1970 * 1000)
        let monthEndMs = nextMonthStartMs - 1

        // SQL 目的：读取某月份参与阅读时长排行/总结的原始阅读记录。
        // 关联关系：JOIN book 补全书名与封面，同时排除已删除书籍。
        // 时间语义：fuzzy 记录按 fuzzy_read_date 判定；非 fuzzy 记录按 [start_time, end_time] 与月份区间重叠判定。
        // 跨月安全：区间重叠条件可能匹配跨月记录，但 splitReadDurationByDay 按天拆分后仅累计落在月份内的天数，不会双重计数。
        // 过滤条件：status=3、book_id!=0、elapsed_seconds>0，且记录未软删除。
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

    /// 读取任意毫秒区间内的阅读时长原始记录，供年度排行等跨月统计复用。
    nonisolated func fetchReadCalendarDurationRecords(
        _ db: Database,
        millisRange: ClosedRange<Int64>
    ) -> [ReadCalendarDurationRecordRow] {
        // SQL 目的：按任意毫秒区间读取阅读时长原始记录（年度统计复用）。
        // 判定逻辑：fuzzy 与非 fuzzy 记录采用同一套“优先 fuzzy_read_date，否则区间重叠”的规则。
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
            arguments: StatementArguments([
                millisRange.lowerBound,
                millisRange.upperBound,
                millisRange.lowerBound,
                millisRange.upperBound
            ])
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

    /// 基于全年阅读时长聚合年度 Top 书籍列表。
    nonisolated func buildReadCalendarYearTopBooks(
        _ db: Database,
        year: Int,
        limit: Int
    ) -> [ReadCalendarMonthlyDurationBook] {
        guard let dateRange = yearDateRange(year) else { return [] }
        let yearMillisRange = millisRangeForQuery(dateRange)
        let records = fetchReadCalendarDurationRecords(db, millisRange: yearMillisRange)
        guard !records.isEmpty else { return [] }

        var readSecondsByBookId: [Int64: Int64] = [:]
        var bookMetaById: [Int64: (name: String, coverURL: String)] = [:]

        for record in records {
            bookMetaById[record.bookId] = (record.bookName, record.bookCover)
            let dayBuckets = splitReadDurationByDay(
                startTime: record.startTime,
                endTime: record.endTime,
                elapsedSeconds: record.elapsedSeconds,
                fuzzyReadDate: record.fuzzyReadDate
            )
            for (day, seconds) in dayBuckets {
                let dayMs = Int64(day.timeIntervalSince1970 * 1000)
                guard yearMillisRange.contains(dayMs) else { continue }
                readSecondsByBookId[record.bookId, default: 0] += seconds
            }
        }

        let aggregation = ReadCalendarDurationAggregation(
            readSecondsByBookId: readSecondsByBookId,
            bookMetaById: bookMetaById,
            totalReadSeconds: 0,
            timeSlotReadSeconds: [:]
        )
        return buildReadCalendarMonthlyDurationTopBooks(aggregation: aggregation, limit: limit)
    }

    /// 把阅读记录拆分并汇总到月份维度，输出总时长、时段分布和书籍时长映射。
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

    /// 基于聚合后的时长数据构建排行榜模型，按时长降序输出。
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

    /// 构建阅读日历月度摘要，包括读书覆盖、读完本数、笔记数与阅读时段分布。
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

    /// 统计区间内读完状态的去重书籍数，供月度摘要展示完成规模。
    nonisolated func fetchReadDoneDistinctBookCount(_ db: Database, millisRange: ClosedRange<Int64>) -> Int {
        // SQL 目的：统计区间内进入“读完”状态的去重有效书籍数，用于月度 summary.finishedBookCount。
        let sql = """
            SELECT COUNT(DISTINCT r.book_id)
            FROM book_read_status_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND r.read_status_id = 3
              AND r.changed_date != 0
              AND r.book_id != 0
              AND r.changed_date BETWEEN ? AND ?
            """
        return (try? Int.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )) ?? 0
    }

    /// 统计区间内有效笔记总数，供月度摘要展示笔记产出。
    nonisolated func fetchMonthlyNoteCount(_ db: Database, millisRange: ClosedRange<Int64>) -> Int {
        // SQL 目的：统计区间内归属于有效书籍的笔记总数，用于月度 summary.noteCount。
        let sql = """
            SELECT COUNT(*)
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            WHERE n.is_deleted = 0
              AND n.created_date BETWEEN ? AND ?
            """
        return (try? Int.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
        )) ?? 0
    }

    /// 把小时映射到阅读日历的时间段标签，用于月度时段分布统计。
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

    /// 按启用事件类型计算阅读日历最早日期，决定日历可回溯起点。
    nonisolated func findReadCalendarEarliestDate(
        _ db: Database,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> Date? {
        // SQL 目的：按事件类型分别计算“最早业务时间”，后续取最小值作为阅读日历起始边界。
        // 时间语义：所有字段均为毫秒时间戳；readDone 仅统计 read_status_id = 3。
        let typeQueryMap: [(ReadCalendarEventType, String)] = [
            (.readTiming, """
                SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
                FROM read_time_record
                WHERE is_deleted = 0
                  AND status = 3
                  AND book_id != 0
                """),
            (.note, """
                SELECT MIN(n.created_date)
                FROM note n
                JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
                WHERE n.is_deleted = 0
                """),
            (.relevant, """
                SELECT MIN(c.created_date)
                FROM category_content c
                JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
                WHERE c.is_deleted = 0
                """),
            (.review, """
                SELECT MIN(r.created_date)
                FROM review r
                JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                WHERE r.is_deleted = 0
                """),
            (.checkIn, """
                SELECT MIN(c.checkin_date)
                FROM check_in_record c
                JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
                WHERE c.is_deleted = 0
                  AND c.checkin_date != 0
                  AND c.book_id != 0
                """),
            (.readDone, """
                SELECT MIN(r.changed_date)
                FROM book_read_status_record r
                JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                WHERE r.is_deleted = 0
                  AND r.changed_date != 0
                  AND r.read_status_id = 3
                  AND r.book_id != 0
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

    /// EventSQLFragment 把单类事件查询封装成可组合片段，便于按排除类型动态拼接阅读日历统计 SQL。
    nonisolated struct EventSQLFragment {
        let eventType: ReadCalendarEventType
        let sql: String
        let args: (ClosedRange<Int64>) -> [Int64]
    }

    nonisolated static let allEventFragments: [EventSQLFragment] = [
        EventSQLFragment(
            eventType: .readTiming,
            // SQL 目的：抽取阅读计时事件，按 day + book_id 聚合最早发生时间。
            // 时间语义：优先 fuzzy_read_date（补录），否则 start_time；均按 localtime 折算日期。
            sql: """
                SELECT DATE(
                    CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date / 1000 ELSE start_time / 1000 END,
                    'unixepoch', 'localtime'
                ) AS day,
                book_id AS book_id,
                MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END) AS first_event_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND status = 3
                  AND book_id != 0
                  AND (CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END) BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .note,
            // SQL 目的：抽取有效书籍下的笔记创建事件，形成 day + book_id 级别事件流。
            sql: """
                SELECT DATE(n.created_date / 1000, 'unixepoch', 'localtime') AS day,
                       n.book_id AS book_id,
                       MIN(n.created_date) AS first_event_time
                FROM note n
                JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
                WHERE n.is_deleted = 0
                  AND n.book_id != 0
                  AND n.created_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .relevant,
            // SQL 目的：抽取有效书籍下的“相关内容”创建事件，纳入阅读日历行为判定。
            sql: """
                SELECT DATE(c.created_date / 1000, 'unixepoch', 'localtime') AS day,
                       c.book_id AS book_id,
                       MIN(c.created_date) AS first_event_time
                FROM category_content c
                JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
                WHERE c.is_deleted = 0
                  AND c.book_id != 0
                  AND c.created_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .review,
            // SQL 目的：抽取有效书籍下的书评创建事件，纳入阅读日历行为判定。
            sql: """
                SELECT DATE(r.created_date / 1000, 'unixepoch', 'localtime') AS day,
                       r.book_id AS book_id,
                       MIN(r.created_date) AS first_event_time
                FROM review r
                JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                WHERE r.is_deleted = 0
                  AND r.book_id != 0
                  AND r.created_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .checkIn,
            // SQL 目的：抽取有效书籍下的打卡事件（book_id 维度），统一并入日历事件流。
            sql: """
                SELECT DATE(c.checkin_date / 1000, 'unixepoch', 'localtime') AS day,
                       c.book_id AS book_id,
                       MIN(c.checkin_date) AS first_event_time
                FROM check_in_record c
                JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
                WHERE c.is_deleted = 0
                  AND c.checkin_date != 0
                  AND c.book_id != 0
                  AND c.checkin_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        EventSQLFragment(
            eventType: .readDone,
            // SQL 目的：抽取有效书籍下的“读完”状态事件（read_status_id = 3），用于行为流和完成标记。
            sql: """
                SELECT DATE(r.changed_date / 1000, 'unixepoch', 'localtime') AS day,
                       r.book_id AS book_id,
                       MIN(r.changed_date) AS first_event_time
                FROM book_read_status_record r
                JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                WHERE r.is_deleted = 0
                  AND r.changed_date != 0
                  AND r.read_status_id = 3
                  AND r.book_id != 0
                  AND r.changed_date BETWEEN ? AND ?
                GROUP BY day, book_id
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        )
    ]

    /// 按事件筛选配置动态拼装 SQL 片段，避免禁用事件参与日历查询。
    nonisolated func buildEventFragments(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> [EventSQLFragment] {
        Self.allEventFragments.filter { !excludedEventTypes.contains($0.eventType) }
    }
}
