import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 Heatmap 与阅读日历领域模型
 * [OUTPUT]: 对外提供 StatisticsRepository，统一 Android 对齐的跨日拆分、全局最早日期、自然月/年度范围、环比、书籍贡献与排行聚合
 * [POS]: Data 层统计仓储实现，聚合热力图与阅读日历月年数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// StatisticsRepository 统一承接热力图、阅读日历和月度/年度统计聚合查询。
nonisolated struct StatisticsRepository: StatisticsRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let calendar: Calendar

    /// 注入数据库管理器，为热力图与阅读日历统计查询提供数据源。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        self.calendar = Calendar.current
    }

    /// 为一次统计读取固定本地日历快照，避免跨日拆分期间时区设置变化造成边界混用。
    private init(databaseManager: DatabaseManager, calendar: Calendar) {
        self.databaseManager = databaseManager
        self.calendar = calendar
    }

    /// 拉取指定年份和统计维度的热力图数据，供阅读统计页渲染年视图。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchHeatmapData(
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) async throws -> (days: [Date: HeatmapDay], earliestDate: Date?, latestDate: Date?) {
        let worker = StatisticsRepository(databaseManager: databaseManager, calendar: Calendar.current)
        return try await databaseManager.database.dbPool.read { db in
            worker.buildHeatmapData(db, year: year, dataType: dataType)
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
        let worker = StatisticsRepository(databaseManager: databaseManager, calendar: Calendar.current)
        return try await databaseManager.database.dbPool.read { db in
            try worker.findReadCalendarEarliestDate(db, excludedEventTypes: excludedEventTypes)
        }
    }

    /// 聚合单月阅读日历数据（每天书目、完成数、时长与摘要），供月视图页面渲染。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchReadCalendarMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData {
        try await fetchReadCalendarMonthData(
            monthStart: monthStart,
            excludedEventTypes: excludedEventTypes,
            excludedBookIDs: []
        )
    }

    /// 聚合单月数据并在原始事件进入统计前排除指定书籍，供分享预览复用完整统计口径。
    nonisolated func fetchReadCalendarMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>,
        excludedBookIDs: Set<Int64>
    ) async throws -> ReadCalendarMonthData {
        let worker = StatisticsRepository(databaseManager: databaseManager, calendar: Calendar.current)
        return try await databaseManager.database.dbPool.read { db in
            try worker.buildReadCalendarMonthData(
                db,
                monthStart: monthStart,
                excludedEventTypes: excludedEventTypes,
                excludedBookIDs: excludedBookIDs
            )
        }
    }

    /// 聚合年度阅读时长排行，供阅读统计页“年度 Top 书籍”模块展示。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchReadCalendarYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int
    ) async throws -> [ReadCalendarMonthlyDurationBook] {
        try await fetchReadCalendarYearTopBooks(
            year: year,
            excludedEventTypes: excludedEventTypes,
            limit: limit,
            includedMonthStarts: nil,
            excludedBookIDs: []
        )
    }

    /// 聚合年度有效月份内的阅读时长排行，并在聚合前应用书籍排除。
    nonisolated func fetchReadCalendarYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int,
        includedMonthStarts: Set<Date>?,
        excludedBookIDs: Set<Int64>
    ) async throws -> [ReadCalendarMonthlyDurationBook] {
        guard !excludedEventTypes.contains(.readTiming) else { return [] }
        guard limit > 0 else { return [] }
        let worker = StatisticsRepository(databaseManager: databaseManager, calendar: Calendar.current)
        return try await databaseManager.database.dbPool.read { db in
            try worker.buildReadCalendarYearTopBooks(
                db,
                year: year,
                limit: limit,
                includedMonthStarts: includedMonthStarts,
                excludedBookIDs: excludedBookIDs
            )
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
    let amount: Int
    let seconds: Int
}

nonisolated private struct HeatmapDateRange {
    let start: Date
    let end: Date
}

nonisolated private struct ReadCalendarDayBookRow {
    let day: Date
    let bookId: Int64
    let bookName: String
    let bookCover: String
    let firstEventTime: Int64
    let lastEventTime: Int64
    let isReadDoneOnThisDay: Bool
}

nonisolated private struct ReadCalendarRawEvent {
    let eventType: ReadCalendarEventType
    let bookId: Int64
    let bookName: String
    let bookCover: String
    let eventTime: Int64
    let checkInAmount: Int
}

nonisolated private struct ReadCalendarDurationDaySegment {
    let day: Date
    let eventTime: Int64
    let seconds: Int64
}

nonisolated private struct ReadCalendarDayAccumulator {
    var readSeconds = 0
    var noteCount = 0
    var contentActivityCount = 0
    var checkInCount = 0
    var checkInAmount = 0
    var readDoneCount = 0
}

nonisolated private struct ReadCalendarDayBookAccumulator {
    let bookName: String
    let bookCover: String
    var firstEventTime: Int64
    var lastEventTime: Int64
    var isReadDoneOnThisDay: Bool
}

nonisolated private struct ReadCalendarDurationRecordRow {
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
    let readSecondsByDay: [Date: Int]
    let bookMetaById: [Int64: (name: String, coverURL: String)]
    let firstEventTimeByBookId: [Int64: Int64]
    let totalReadSeconds: Int64
    let timeSlotReadSeconds: [ReadCalendarTimeSlot: Int]
    let firstEventTimeBySlot: [ReadCalendarTimeSlot: Int64]
}

/// 阅读计时按天拆分工具，对齐 Android `ReadTimeRecord.splitCrossDayRecords` 的统计口径。
nonisolated enum ReadTimingDurationSplitter {
    /// 将一条完成的阅读计时拆分到本地自然日；fuzzy 记录整条归属到 fuzzy 日期。
    static func splitByDay(
        startTime: Int64,
        endTime: Int64,
        elapsedSeconds: Int64,
        fuzzyReadDate: Int64,
        calendar: Calendar = .current
    ) -> [(day: Date, seconds: Int64)] {
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
        var allocatedSeconds: Int64 = 0
        var result: [(day: Date, seconds: Int64)] = []
        var currentMillis = startMillis
        var cursorDate = startDate

        while cursorDate <= endDate && allocatedSeconds < elapsedSeconds {
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
            var segmentSeconds = Int64((segmentRatio * Double(elapsedSeconds)).rounded())
            if allocatedSeconds + segmentSeconds > elapsedSeconds {
                segmentSeconds = elapsedSeconds - allocatedSeconds
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

    /// 将本地自然日转为毫秒时间戳，供区间过滤复用。
    static func dayMillis(_ day: Date) -> Int64 {
        Int64(day.timeIntervalSince1970 * 1000)
    }
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

    /// 按天汇总阅读时长，处理 fuzzyReadDate 双时间源与精确记录跨日拆分。
    /// 时区约定：SQL 使用 SQLite 'localtime' 修饰符，与 Swift 侧 `Calendar.current.startOfDay` 保持一致——
    /// 两端均依赖设备时区，确保日期边界对齐。若设备时区在运行期变更，已缓存数据可能出现偏移。
    nonisolated func aggregateReadSeconds(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: Int] {
        // SQL 目的：读取区间内参与热力图阅读时长聚合的原始记录，随后在 Swift 侧按 Android 口径拆分跨日精确计时。
        // 关联关系：JOIN book 排除已删除书籍，避免孤立记录进入统计。
        // 时间语义：fuzzy 记录按 fuzzy_read_date 归属；非 fuzzy 记录按 [start_time, end_time] 与区间重叠读取。
        // 过滤条件：status = 3、r.is_deleted = 0、book_id != 0、elapsed_seconds > 0，并限制在输入毫秒区间内。
        let records = fetchReadDurationRows(db, millisRange: millisRange)
        var result: [Date: Int] = [:]
        for record in records {
            let dayBuckets = ReadTimingDurationSplitter.splitByDay(
                startTime: record.startTime,
                endTime: record.endTime,
                elapsedSeconds: record.elapsedSeconds,
                fuzzyReadDate: record.fuzzyReadDate,
                calendar: calendar
            )
            for (day, seconds) in dayBuckets {
                let dayMs = ReadTimingDurationSplitter.dayMillis(day)
                guard millisRange.contains(dayMs) else { continue }
                result[day, default: 0] += Int(seconds)
            }
        }
        return result
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

    /// 按天聚合相关内容与书评数量，供阅读日历热力口径使用。
    nonisolated func aggregateContentActivityCounts(
        _ db: Database,
        millisRange: ClosedRange<Int64>,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> [Date: Int] {
        var result: [Date: Int] = [:]
        if !excludedEventTypes.contains(.relevant) {
            // SQL 目的：按本地自然日统计有效书籍下的相关内容数量。
            // 涉及表：category_content JOIN book。
            // 关键过滤：两表 is_deleted=0、created_date 位于目标毫秒闭区间。
            // 时间字段：created_date 通过 unixepoch/localtime 分桶。
            // 返回字段用途：参与阅读日历内容活动热力等级。
            let relevantSQL = """
                SELECT DATE(c.created_date / 1000, 'unixepoch', 'localtime') AS day,
                       COUNT(*) AS total
                FROM category_content c
                JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
                WHERE c.is_deleted = 0
                  AND c.created_date BETWEEN ? AND ?
                GROUP BY day
                """
            mergeDayCounts(
                queryDayAggregation(
                    db,
                    sql: relevantSQL,
                    arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
                ),
                into: &result
            )
        }

        if !excludedEventTypes.contains(.review) {
            // SQL 目的：按本地自然日统计有效书籍下的书评数量。
            // 涉及表：review JOIN book。
            // 关键过滤：两表 is_deleted=0、created_date 位于目标毫秒闭区间。
            // 时间字段：created_date 通过 unixepoch/localtime 分桶。
            // 返回字段用途：与相关内容合并为 Android contentActivityCount。
            let reviewSQL = """
                SELECT DATE(r.created_date / 1000, 'unixepoch', 'localtime') AS day,
                       COUNT(*) AS total
                FROM review r
                JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                WHERE r.is_deleted = 0
                  AND r.created_date BETWEEN ? AND ?
                GROUP BY day
                """
            mergeDayCounts(
                queryDayAggregation(
                    db,
                    sql: reviewSQL,
                    arguments: StatementArguments([millisRange.lowerBound, millisRange.upperBound])
                ),
                into: &result
            )
        }
        return result
    }

    /// 累加两个按日计数字典，保持日期键归一化结果。
    nonisolated func mergeDayCounts(_ source: [Date: Int], into target: inout [Date: Int]) {
        for (day, count) in source {
            target[day, default: 0] += count
        }
    }

    // MARK: - 打卡聚合

    /// 按天聚合打卡次数与时长（amount * 20 分钟）
    nonisolated func aggregateCheckInSummary(_ db: Database, millisRange: ClosedRange<Int64>) -> [Date: CheckInSummary] {
        // SQL 目的：按“本地日”统计有效书籍下的打卡次数与打卡时长（amount * 1200 秒）。
        // 过滤条件：排除软删除、默认占位书与 checkin_date=0 的无效记录。
        let sql = """
            SELECT DATE(c.checkin_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS checkin_count,
                   COALESCE(SUM(c.amount), 0) AS checkin_amount,
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
                  let amount: Int = row["checkin_amount"],
                  let seconds: Int = row["checkin_seconds"],
                  let date = Self.dayFormatter.date(from: dayStr) else { continue }
            result[calendar.startOfDay(for: date)] = CheckInSummary(
                count: count,
                amount: amount,
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
        excludedEventTypes: Set<ReadCalendarEventType>,
        excludedBookIDs: Set<Int64>,
        includesComparison: Bool = true
    ) throws -> ReadCalendarMonthData {
        let normalizedMonthStart = normalizeToMonthStart(monthStart)
        guard let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: normalizedMonthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonthStart) else {
            return .empty(for: normalizedMonthStart)
        }

        let queryRange = millisRangeForQuery(
            HeatmapDateRange(start: normalizedMonthStart, end: monthEnd)
        )
        let rawEvents = try fetchReadCalendarRawEvents(
            db,
            millisRange: queryRange,
            excludedEventTypes: excludedEventTypes
        ).filter { !excludedBookIDs.contains($0.bookId) }
        let durationRecords = excludedEventTypes.contains(.readTiming)
            ? []
            : try fetchReadCalendarDurationRecords(
                db,
                millisRange: queryRange
            ).filter { !excludedBookIDs.contains($0.bookId) }
        let durationAggregation = aggregateReadCalendarDuration(
            records: durationRecords,
            monthMillisRange: queryRange
        )

        var dayAggregates: [Date: ReadCalendarDayAccumulator] = [:]
        var dayBookAggregates: [Date: [Int64: ReadCalendarDayBookAccumulator]] = [:]
        var readDoneBookIDs = Set<Int64>()
        var monthlyNoteCount = 0
        var monthlyCheckInCount = 0

        for event in rawEvents {
            let eventDate = Date(timeIntervalSince1970: Double(event.eventTime) / 1000)
            let day = calendar.startOfDay(for: eventDate)
            var aggregate = dayAggregates[day, default: ReadCalendarDayAccumulator()]
            switch event.eventType {
            case .readTiming:
                break
            case .note:
                aggregate.noteCount += 1
                monthlyNoteCount += 1
            case .relevant, .review:
                aggregate.contentActivityCount += 1
            case .checkIn:
                aggregate.checkInCount += 1
                aggregate.checkInAmount += event.checkInAmount
                monthlyCheckInCount += 1
            case .readDone:
                aggregate.readDoneCount += 1
                readDoneBookIDs.insert(event.bookId)
            }
            dayAggregates[day] = aggregate

            var bookAggregate = dayBookAggregates[day]?[event.bookId]
                ?? ReadCalendarDayBookAccumulator(
                    bookName: event.bookName,
                    bookCover: event.bookCover,
                    firstEventTime: event.eventTime,
                    lastEventTime: event.eventTime,
                    isReadDoneOnThisDay: false
                )
            bookAggregate.firstEventTime = min(bookAggregate.firstEventTime, event.eventTime)
            bookAggregate.lastEventTime = max(bookAggregate.lastEventTime, event.eventTime)
            if event.eventType == .readDone {
                bookAggregate.isReadDoneOnThisDay = true
            }
            dayBookAggregates[day, default: [:]][event.bookId] = bookAggregate
        }

        for record in durationRecords {
            let segments = splitReadDurationSegmentsByDay(
                startTime: record.startTime,
                endTime: record.endTime,
                elapsedSeconds: record.elapsedSeconds,
                fuzzyReadDate: record.fuzzyReadDate
            )
            for segment in segments {
                let dayMillis = Int64(segment.day.timeIntervalSince1970 * 1000)
                guard queryRange.contains(dayMillis) else { continue }

                var aggregate = dayAggregates[segment.day, default: ReadCalendarDayAccumulator()]
                aggregate.readSeconds += Int(segment.seconds)
                dayAggregates[segment.day] = aggregate

                var bookAggregate = dayBookAggregates[segment.day]?[record.bookId]
                    ?? ReadCalendarDayBookAccumulator(
                        bookName: record.bookName,
                        bookCover: record.bookCover,
                        firstEventTime: segment.eventTime,
                        lastEventTime: segment.eventTime,
                        isReadDoneOnThisDay: false
                    )
                bookAggregate.firstEventTime = min(bookAggregate.firstEventTime, segment.eventTime)
                bookAggregate.lastEventTime = max(bookAggregate.lastEventTime, segment.eventTime)
                dayBookAggregates[segment.day, default: [:]][record.bookId] = bookAggregate
            }
        }

        var dayBookRows: [ReadCalendarDayBookRow] = []
        for (day, booksByID) in dayBookAggregates {
            for (bookID, aggregate) in booksByID {
                dayBookRows.append(
                    ReadCalendarDayBookRow(
                        day: day,
                        bookId: bookID,
                        bookName: aggregate.bookName,
                        bookCover: aggregate.bookCover,
                        firstEventTime: aggregate.firstEventTime,
                        lastEventTime: aggregate.lastEventTime,
                        isReadDoneOnThisDay: aggregate.isReadDoneOnThisDay
                    )
                )
            }
        }

        var days: [Date: ReadCalendarDay] = [:]
        let dayKeys = Set(dayBookAggregates.keys).union(dayAggregates.keys)
        for day in dayKeys {
            let books = (dayBookAggregates[day] ?? [:]).map { bookID, aggregate in
                ReadCalendarDayBook(
                    id: bookID,
                    name: aggregate.bookName,
                    coverURL: aggregate.bookCover,
                    firstEventTime: aggregate.firstEventTime,
                    lastEventTime: aggregate.lastEventTime,
                    isReadDoneOnThisDay: aggregate.isReadDoneOnThisDay
                )
            }.sorted {
                if $0.lastEventTime != $1.lastEventTime {
                    return $0.lastEventTime > $1.lastEventTime
                }
                if $0.firstEventTime != $1.firstEventTime {
                    return $0.firstEventTime > $1.firstEventTime
                }
                return $0.id < $1.id
            }
            let aggregate = dayAggregates[day, default: ReadCalendarDayAccumulator()]
            days[day] = ReadCalendarDay(
                date: day,
                books: books,
                readDoneCount: aggregate.readDoneCount,
                readSeconds: aggregate.readSeconds,
                noteCount: aggregate.noteCount,
                contentActivityCount: aggregate.contentActivityCount,
                checkInCount: aggregate.checkInCount,
                checkInAmount: aggregate.checkInAmount,
                checkInSeconds: aggregate.checkInAmount * 1_200
            )
        }

        let readingDurationTopBooks = buildReadCalendarMonthlyDurationTopBooks(
            aggregation: durationAggregation
        )
        let bookContributions = buildReadCalendarBookContributions(
            dayBookRows: dayBookRows,
            durationAggregation: durationAggregation
        )
        let baseSummary = buildReadCalendarMonthSummary(
            excludedEventTypes: excludedEventTypes,
            dayBookRows: dayBookRows,
            activeDates: Set(dayKeys),
            monthStart: normalizedMonthStart,
            durationAggregation: durationAggregation,
            finishedBookCount: readDoneBookIDs.count,
            noteCount: monthlyNoteCount,
            checkInCount: monthlyCheckInCount
        )
        let baseData = ReadCalendarMonthData(
            monthStart: normalizedMonthStart,
            days: days,
            readingDurationTopBooks: readingDurationTopBooks,
            bookContributions: bookContributions,
            summary: baseSummary
        )

        guard includesComparison,
              let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: normalizedMonthStart) else {
            return baseData
        }
        let previousData = try buildReadCalendarMonthData(
            db,
            monthStart: previousMonthStart,
            excludedEventTypes: excludedEventTypes,
            excludedBookIDs: excludedBookIDs,
            includesComparison: false
        )
        return ReadCalendarMonthData(
            monthStart: baseData.monthStart,
            days: baseData.days,
            readingDurationTopBooks: baseData.readingDurationTopBooks,
            bookContributions: baseData.bookContributions,
            summary: baseData.summary.applyingComparison(
                ReadCalendarSummaryComparisonSnapshot.make(days: previousData.days, calendar: calendar)
            )
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

    /// 读取阅读日历非计时原始事件；读完状态合并历史记录与书籍当前快照并按书籍+时间去重。
    nonisolated func fetchReadCalendarRawEvents(
        _ db: Database,
        millisRange: ClosedRange<Int64>,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) throws -> [ReadCalendarRawEvent] {
        let fragments = buildRawEventFragments(excludedEventTypes: excludedEventTypes)
        guard !fragments.isEmpty else { return [] }

        let unionAll = fragments.map(\.sql).joined(separator: "\n\n                UNION ALL\n\n")
        // SQL 目的：合并笔记、相关内容、书评、打卡和规范化读完事件为原始事件流。
        // 关联关系：外层 JOIN book 统一过滤已删除书籍并补全名称/封面。
        // 关键规则：读完事件内部使用 UNION 合并历史记录与 book 当前快照，按 book_id + event_time 去重。
        // 时间字段：全部保持 Android 毫秒时间戳，日期分桶在 Swift 侧使用同一 Calendar.current 快照完成。
        let sql = """
            WITH raw_events AS (
                \(unionAll)
            )
            SELECT raw_events.event_type AS event_type,
                   raw_events.book_id AS book_id,
                   raw_events.event_time AS event_time,
                   raw_events.checkin_amount AS checkin_amount,
                   COALESCE(b.name, '') AS book_name,
                   COALESCE(b.cover, '') AS book_cover
            FROM raw_events
            JOIN book b ON b.id = raw_events.book_id AND b.is_deleted = 0
            ORDER BY raw_events.event_time ASC, raw_events.book_id ASC, raw_events.event_type ASC
            """

        var args: [Int64] = []
        for fragment in fragments {
            args.append(contentsOf: fragment.args(millisRange))
        }

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        var result: [ReadCalendarRawEvent] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let rawType: String = row["event_type"],
                  let eventType = readCalendarEventType(rawValue: rawType),
                  let bookId: Int64 = row["book_id"],
                  let eventTime: Int64 = row["event_time"],
                  let bookName: String = row["book_name"] else { continue }
            result.append(
                ReadCalendarRawEvent(
                    eventType: eventType,
                    bookId: bookId,
                    bookName: bookName,
                    bookCover: row["book_cover"] ?? "",
                    eventTime: eventTime,
                    checkInAmount: row["checkin_amount"] ?? 0
                )
            )
        }
        return result
    }

    /// 读取月份范围内的阅读时长原始记录，供月度时长排行与摘要计算。
    nonisolated func fetchReadCalendarDurationRecords(
        _ db: Database,
        monthStart: Date,
        nextMonthStart: Date
    ) throws -> [ReadCalendarDurationRecordRow] {
        let monthStartMs = Int64(calendar.startOfDay(for: monthStart).timeIntervalSince1970 * 1000)
        let nextMonthStartMs = Int64(calendar.startOfDay(for: nextMonthStart).timeIntervalSince1970 * 1000)
        let monthEndMs = nextMonthStartMs - 1

        // SQL 目的：读取某月份参与阅读时长排行/总结的原始阅读记录。
        // 关联关系：JOIN book 补全书名与封面，同时排除已删除书籍。
        // 时间语义：fuzzy 记录按 fuzzy_read_date 判定；非 fuzzy 记录按 [start_time, end_time] 与月份区间重叠判定。
        // 跨月安全：区间重叠条件可能匹配跨月记录，但 splitReadDurationByDay 按天拆分后仅累计落在月份内的天数，不会双重计数。
        // 过滤条件：status=3、book_id!=0 且记录未软删除；零时长完成记录仍贡献活动书籍。
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
              AND (
                (r.fuzzy_read_date != 0 AND r.fuzzy_read_date BETWEEN ? AND ?)
                OR
                (r.fuzzy_read_date = 0 AND r.end_time >= ? AND r.start_time <= ?)
            )
            ORDER BY CASE WHEN r.fuzzy_read_date != 0 THEN r.fuzzy_read_date ELSE r.start_time END ASC,
                     CASE WHEN r.fuzzy_read_date = 0 THEN 0 ELSE 1 END ASC,
                     r.id ASC
            """

        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments([monthStartMs, monthEndMs, monthStartMs, monthEndMs])
        )

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
    ) throws -> [ReadCalendarDurationRecordRow] {
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
              AND (
                (r.fuzzy_read_date != 0 AND r.fuzzy_read_date BETWEEN ? AND ?)
                OR
                (r.fuzzy_read_date = 0 AND r.end_time >= ? AND r.start_time <= ?)
            )
            ORDER BY CASE WHEN r.fuzzy_read_date != 0 THEN r.fuzzy_read_date ELSE r.start_time END ASC,
                     CASE WHEN r.fuzzy_read_date = 0 THEN 0 ELSE 1 END ASC,
                     r.id ASC
            """

        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments([
                millisRange.lowerBound,
                millisRange.upperBound,
                millisRange.lowerBound,
                millisRange.upperBound
            ])
        )

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

    /// 读取指定区间内所有可能贡献阅读秒数的原始记录，供跨日拆分统计复用。
    nonisolated func fetchReadDurationRows(
        _ db: Database,
        millisRange: ClosedRange<Int64>
    ) -> [ReadCalendarDurationRecordRow] {
        (try? fetchReadCalendarDurationRecords(db, millisRange: millisRange)) ?? []
    }

    /// 基于全年阅读时长聚合年度 Top 书籍列表。
    nonisolated func buildReadCalendarYearTopBooks(
        _ db: Database,
        year: Int,
        limit: Int,
        includedMonthStarts: Set<Date>?,
        excludedBookIDs: Set<Int64>
    ) throws -> [ReadCalendarMonthlyDurationBook] {
        guard let dateRange = yearDateRange(year) else { return [] }
        let yearMillisRange = millisRangeForQuery(dateRange)
        let records = try fetchReadCalendarDurationRecords(db, millisRange: yearMillisRange)
            .filter { !excludedBookIDs.contains($0.bookId) }
        guard !records.isEmpty else { return [] }

        var readSecondsByBookId: [Int64: Int64] = [:]
        var bookMetaById: [Int64: (name: String, coverURL: String)] = [:]
        var firstEventTimeByBookId: [Int64: Int64] = [:]
        let currentMonthStart = normalizeToMonthStart(Date())
        let normalizedIncludedMonths = includedMonthStarts.map { starts in
            Set(starts.map(normalizeToMonthStart))
        }

        for record in records {
            bookMetaById[record.bookId] = (record.bookName, record.bookCover)
            let daySegments = splitReadDurationSegmentsByDay(
                startTime: record.startTime,
                endTime: record.endTime,
                elapsedSeconds: record.elapsedSeconds,
                fuzzyReadDate: record.fuzzyReadDate
            )
            for segment in daySegments where segment.seconds > 0 {
                let dayMs = Int64(segment.day.timeIntervalSince1970 * 1000)
                guard yearMillisRange.contains(dayMs) else { continue }
                let monthStart = normalizeToMonthStart(segment.day)
                guard monthStart <= currentMonthStart else { continue }
                if let normalizedIncludedMonths, !normalizedIncludedMonths.contains(monthStart) {
                    continue
                }
                readSecondsByBookId[record.bookId, default: 0] += segment.seconds
                firstEventTimeByBookId[record.bookId] = min(
                    firstEventTimeByBookId[record.bookId] ?? segment.eventTime,
                    segment.eventTime
                )
            }
        }

        let aggregation = ReadCalendarDurationAggregation(
            readSecondsByBookId: readSecondsByBookId,
            readSecondsByDay: [:],
            bookMetaById: bookMetaById,
            firstEventTimeByBookId: firstEventTimeByBookId,
            totalReadSeconds: 0,
            timeSlotReadSeconds: [:],
            firstEventTimeBySlot: [:]
        )
        return buildReadCalendarMonthlyDurationTopBooks(aggregation: aggregation, limit: limit)
    }

    /// 把阅读记录拆分并汇总到月份维度，输出总时长、时段分布和书籍时长映射。
    nonisolated func aggregateReadCalendarDuration(
        records: [ReadCalendarDurationRecordRow],
        monthMillisRange: ClosedRange<Int64>
    ) -> ReadCalendarDurationAggregation {
        var readSecondsByBookId: [Int64: Int64] = [:]
        var readSecondsByDay: [Date: Int] = [:]
        var bookMetaById: [Int64: (name: String, coverURL: String)] = [:]
        var firstEventTimeByBookId: [Int64: Int64] = [:]
        var totalReadSeconds: Int64 = 0
        var timeSlotReadSeconds: [ReadCalendarTimeSlot: Int] = [:]
        var firstEventTimeBySlot: [ReadCalendarTimeSlot: Int64] = [:]
        for record in records {
            bookMetaById[record.bookId] = (record.bookName, record.bookCover)
            let daySegments = splitReadDurationSegmentsByDay(
                startTime: record.startTime,
                endTime: record.endTime,
                elapsedSeconds: record.elapsedSeconds,
                fuzzyReadDate: record.fuzzyReadDate
            )
            var secondsInMonthForRecord: Int64 = 0
            for segment in daySegments {
                let dayMs = Int64(segment.day.timeIntervalSince1970 * 1000)
                guard monthMillisRange.contains(dayMs) else { continue }
                secondsInMonthForRecord += segment.seconds
                guard segment.seconds > 0 else { continue }
                readSecondsByBookId[record.bookId, default: 0] += segment.seconds
                readSecondsByDay[segment.day, default: 0] += Int(segment.seconds)
                firstEventTimeByBookId[record.bookId] = min(
                    firstEventTimeByBookId[record.bookId] ?? segment.eventTime,
                    segment.eventTime
                )

                let eventDate = Date(timeIntervalSince1970: Double(segment.eventTime) / 1000)
                let hour = calendar.component(.hour, from: eventDate)
                let slot = readCalendarTimeSlot(forHour: hour)
                timeSlotReadSeconds[slot, default: 0] += Int(segment.seconds)
                firstEventTimeBySlot[slot] = min(
                    firstEventTimeBySlot[slot] ?? segment.eventTime,
                    segment.eventTime
                )
            }

            guard secondsInMonthForRecord > 0 else { continue }
            totalReadSeconds += secondsInMonthForRecord
        }

        return ReadCalendarDurationAggregation(
            readSecondsByBookId: readSecondsByBookId,
            readSecondsByDay: readSecondsByDay,
            bookMetaById: bookMetaById,
            firstEventTimeByBookId: firstEventTimeByBookId,
            totalReadSeconds: totalReadSeconds,
            timeSlotReadSeconds: timeSlotReadSeconds,
            firstEventTimeBySlot: firstEventTimeBySlot
        )
    }

    /// 汇总周期内全部活跃书籍的阅读秒数与活跃天数，供分享筛选使用完整集合。
    nonisolated func buildReadCalendarBookContributions(
        dayBookRows: [ReadCalendarDayBookRow],
        durationAggregation: ReadCalendarDurationAggregation
    ) -> [ReadCalendarBookContribution] {
        var activeDaysByBookId: [Int64: Set<Date>] = [:]
        var metadataByBookId = durationAggregation.bookMetaById
        for row in dayBookRows {
            activeDaysByBookId[row.bookId, default: []].insert(row.day)
            metadataByBookId[row.bookId] = (row.bookName, row.bookCover)
        }

        let bookIDs = Set(activeDaysByBookId.keys).union(durationAggregation.readSecondsByBookId.keys)
        return bookIDs.compactMap { bookID -> ReadCalendarBookContribution? in
            guard let metadata = metadataByBookId[bookID] else { return nil }
            return ReadCalendarBookContribution(
                bookId: bookID,
                name: metadata.name,
                coverURL: metadata.coverURL,
                readSeconds: Int(durationAggregation.readSecondsByBookId[bookID] ?? 0),
                activeDays: activeDaysByBookId[bookID]?.count ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.readSeconds != rhs.readSeconds { return lhs.readSeconds > rhs.readSeconds }
            if lhs.activeDays != rhs.activeDays { return lhs.activeDays > rhs.activeDays }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.bookId < rhs.bookId
        }
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
            let lhsFirst = aggregation.firstEventTimeByBookId[lhs.bookId] ?? .max
            let rhsFirst = aggregation.firstEventTimeByBookId[rhs.bookId] ?? .max
            if lhsFirst != rhsFirst { return lhsFirst < rhsFirst }
            return lhs.bookId < rhs.bookId
        }
        .prefix(limit)
        .map { $0 }
    }

    /// 构建阅读日历月度摘要，包括读书覆盖、读完本数、笔记数与阅读时段分布。
    nonisolated func buildReadCalendarMonthSummary(
        excludedEventTypes: Set<ReadCalendarEventType>,
        dayBookRows: [ReadCalendarDayBookRow],
        activeDates: Set<Date>,
        monthStart: Date,
        durationAggregation: ReadCalendarDurationAggregation,
        finishedBookCount: Int,
        noteCount: Int,
        checkInCount: Int
    ) -> ReadCalendarMonthSummary {
        let uniqueReadBookCount = Set(dayBookRows.map(\.bookId)).count
        let totalReadSeconds = excludedEventTypes.contains(.readTiming) ? 0 : Int(durationAggregation.totalReadSeconds)
        let timeSlotReadSeconds = excludedEventTypes.contains(.readTiming) ? [:] : durationAggregation.timeSlotReadSeconds
        let totalDays = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        let longestStreak = calculateLongestStreak(activeDates)
        let peakCandidate = timeSlotReadSeconds.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let lhsFirst = durationAggregation.firstEventTimeBySlot[lhs.key] ?? .max
            let rhsFirst = durationAggregation.firstEventTimeBySlot[rhs.key] ?? .max
            return lhsFirst > rhsFirst
        }
        let peak = (peakCandidate?.value ?? 0) > 0 ? peakCandidate : nil
        let peakRatio = totalReadSeconds > 0 && peak != nil
            ? Int((Double(peak?.value ?? 0) / Double(totalReadSeconds) * 100).rounded())
            : nil

        return ReadCalendarMonthSummary(
            activeDays: activeDates.count,
            totalDays: totalDays,
            longestStreak: longestStreak,
            uniqueReadBookCount: uniqueReadBookCount,
            finishedBookCount: finishedBookCount,
            noteCount: noteCount,
            checkInCount: checkInCount,
            totalReadSeconds: totalReadSeconds,
            timeSlotReadSeconds: timeSlotReadSeconds,
            peakTimeSlot: peak?.key,
            peakTimeSlotRatio: peakRatio
        )
    }

    /// 计算月份活跃日期的最长连续天数。
    nonisolated func calculateLongestStreak(_ activeDates: Set<Date>) -> Int {
        let sortedDates = activeDates
            .map { calendar.startOfDay(for: $0) }
            .sorted()
        guard !sortedDates.isEmpty else { return 0 }

        var longest = 1
        var current = 1
        for index in 1..<sortedDates.count {
            let previous = sortedDates[index - 1]
            let expected = calendar.date(byAdding: .day, value: 1, to: previous)
            if expected == sortedDates[index] {
                current += 1
                longest = max(longest, current)
            } else if sortedDates[index] != previous {
                current = 1
            }
        }
        return longest
    }

    /// 把小时映射到阅读日历的时间段标签，用于月度时段分布统计。
    nonisolated func readCalendarTimeSlot(forHour hour: Int) -> ReadCalendarTimeSlot {
        switch hour {
        case 5..<12:
            return .morning
        case 12..<18:
            return .afternoon
        case 18..<23:
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
        splitReadDurationSegmentsByDay(
            startTime: startTime,
            endTime: endTime,
            elapsedSeconds: elapsedSeconds,
            fuzzyReadDate: fuzzyReadDate
        ).map { ($0.day, $0.seconds) }
    }

    /// 按 Android 跨日拆分算法返回每日计时事件；每个精确分段以分段开始时间参与书籍排序与时段统计。
    nonisolated func splitReadDurationSegmentsByDay(
        startTime: Int64,
        endTime: Int64,
        elapsedSeconds: Int64,
        fuzzyReadDate: Int64
    ) -> [ReadCalendarDurationDaySegment] {
        if fuzzyReadDate != 0 {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(fuzzyReadDate) / 1000))
            return [ReadCalendarDurationDaySegment(day: day, eventTime: fuzzyReadDate, seconds: elapsedSeconds)]
        }

        let startMillis = startTime
        let endMillis = endTime
        let startDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(startMillis) / 1000))
        let endDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(endMillis) / 1000))

        if startDate == endDate {
            return [ReadCalendarDurationDaySegment(day: startDate, eventTime: startMillis, seconds: elapsedSeconds)]
        }

        // Android 的跨日拆分在总时长为零时不生成分段；单日和模糊零时长记录已在上方保留。
        guard elapsedSeconds > 0 else { return [] }

        let wallTimeTotalMs = max(1, endMillis - startMillis)
        let elapsedSecondsTotal = elapsedSeconds
        var allocatedSeconds: Int64 = 0
        var result: [ReadCalendarDurationDaySegment] = []
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
            allocatedSeconds += segmentSeconds
            result.append(
                ReadCalendarDurationDaySegment(
                    day: cursorDate,
                    eventTime: segmentStart,
                    seconds: segmentSeconds
                )
            )

            currentMillis = segmentEnd + 1
            cursorDate = nextDayStart
        }

        return result
    }

    /// 按 Android 全局统计来源计算最早日期；阅读日历展示筛选不得改变可回溯下界。
    nonisolated func findReadCalendarEarliestDate(
        _ db: Database,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) throws -> Date? {
        _ = excludedEventTypes
        // SQL 目的：逐项复刻 Android StatisticsRepository.getEarliestStatisticsTimestamp 的六类来源。
        // 关联与过滤：书籍创建/状态/购买仅取有效非占位书；笔记关联有效书；计时遵循 status=3；打卡沿用 Android DAO 的全表最早值。
        // 时间字段：全部为毫秒时间戳，0 值在 Swift 聚合时忽略。
        // 返回字段用途：决定阅读日历与分享月份选择器的全局下界，不受展示筛选影响。
        let queries = [
            """
                SELECT MIN(b.created_date)
                FROM book b
                WHERE b.is_deleted = 0 AND b.id != 0 AND b.created_date != 0
                """,
            """
                SELECT MIN(b.read_status_changed_date)
                FROM book b
                WHERE b.is_deleted = 0 AND b.id != 0 AND b.read_status_changed_date != 0
                """,
            """
                SELECT MIN(n.created_date)
                FROM note n
                JOIN book b ON b.id = n.book_id
                WHERE b.is_deleted = 0 AND n.is_deleted = 0 AND n.created_date != 0
                """,
            """
                SELECT MIN(CASE WHEN r.fuzzy_read_date != 0 THEN r.fuzzy_read_date ELSE r.start_time END)
                FROM read_time_record r
                WHERE r.is_deleted = 0
                  AND r.status = 3
                  AND r.book_id != 0
                """,
            """
                SELECT MIN(b.purchase_date)
                FROM book b
                WHERE b.is_deleted = 0 AND b.id != 0 AND b.purchase_date != 0
                """,
            """
                SELECT MIN(c.checkin_date)
                FROM check_in_record c
                WHERE c.checkin_date != 0
                """
        ]

        var timestamps: [Int64] = []
        for sql in queries {
            if let value = try Int64.fetchOne(db, sql: sql), value > 0 {
                timestamps.append(value)
            }
        }
        guard let earliest = timestamps.min() else { return calendar.startOfDay(for: Date()) }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: Double(earliest) / 1000))
    }

    // MARK: - SQL 事件片段动态组装

    /// RawEventSQLFragment 把单类原始事件查询封装成可组合片段，便于按排除设置拼接查询。
    nonisolated struct RawEventSQLFragment {
        let eventType: ReadCalendarEventType
        let sql: String
        let args: (ClosedRange<Int64>) -> [Int64]
    }

    nonisolated static let allRawEventFragments: [RawEventSQLFragment] = [
        RawEventSQLFragment(
            eventType: .note,
            // SQL 目的：抽取有效笔记创建事件；外层统一校验关联书籍。
            // 时间字段：created_date 为 Android 毫秒时间戳，不在 SQL 内做时区换算。
            sql: """
                SELECT 'note' AS event_type,
                       n.book_id AS book_id,
                       n.created_date AS event_time,
                       0 AS checkin_amount
                FROM note n
                WHERE n.is_deleted = 0
                  AND n.book_id != 0
                  AND n.created_date BETWEEN ? AND ?
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        RawEventSQLFragment(
            eventType: .relevant,
            // SQL 目的：抽取有效相关内容创建事件；外层统一校验关联书籍。
            // 时间字段：created_date 为 Android 毫秒时间戳，不在 SQL 内做时区换算。
            sql: """
                SELECT 'relevant' AS event_type,
                       c.book_id AS book_id,
                       c.created_date AS event_time,
                       0 AS checkin_amount
                FROM category_content c
                WHERE c.is_deleted = 0
                  AND c.book_id != 0
                  AND c.created_date BETWEEN ? AND ?
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        RawEventSQLFragment(
            eventType: .review,
            // SQL 目的：抽取有效书评创建事件；外层统一校验关联书籍。
            // 时间字段：created_date 为 Android 毫秒时间戳，不在 SQL 内做时区换算。
            sql: """
                SELECT 'review' AS event_type,
                       r.book_id AS book_id,
                       r.created_date AS event_time,
                       0 AS checkin_amount
                FROM review r
                WHERE r.is_deleted = 0
                  AND r.book_id != 0
                  AND r.created_date BETWEEN ? AND ?
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        RawEventSQLFragment(
            eventType: .checkIn,
            // SQL 目的：抽取有效打卡事件及 amount，供每日打卡次数、数量和时长聚合。
            // 时间字段：checkin_date 为 Android 毫秒时间戳，不在 SQL 内做时区换算。
            sql: """
                SELECT 'checkIn' AS event_type,
                       c.book_id AS book_id,
                       c.checkin_date AS event_time,
                       c.amount AS checkin_amount
                FROM check_in_record c
                WHERE c.is_deleted = 0
                  AND c.checkin_date != 0
                  AND c.book_id != 0
                  AND c.checkin_date BETWEEN ? AND ?
                """,
            args: { [$0.lowerBound, $0.upperBound] }
        ),
        RawEventSQLFragment(
            eventType: .readDone,
            // SQL 目的：构建规范化读完事件，合并状态历史与 book 当前快照。
            // 关键过滤：两路均要求 read_status_id=3、时间有效且落在目标闭区间；UNION 按 book_id+event_time 去重。
            // 时间字段：changed_date/read_status_changed_date 均为 Android 毫秒时间戳。
            sql: """
                SELECT 'readDone' AS event_type,
                       completed.book_id AS book_id,
                       completed.event_time AS event_time,
                       0 AS checkin_amount
                FROM (
                    SELECT r.book_id AS book_id,
                           r.changed_date AS event_time
                    FROM book_read_status_record r
                    WHERE r.is_deleted = 0
                      AND r.changed_date > 0
                      AND r.read_status_id = 3
                      AND r.book_id != 0
                      AND r.changed_date BETWEEN ? AND ?
                    UNION
                    SELECT b.id AS book_id,
                           b.read_status_changed_date AS event_time
                    FROM book b
                    WHERE b.is_deleted = 0
                      AND b.id != 0
                      AND b.read_status_id = 3
                      AND b.read_status_changed_date > 0
                      AND b.read_status_changed_date BETWEEN ? AND ?
                ) completed
                """,
            args: { [$0.lowerBound, $0.upperBound, $0.lowerBound, $0.upperBound] }
        )
    ]

    /// 按事件筛选配置拼装非计时原始事件；计时记录需先执行跨日拆分，因此由独立查询处理。
    nonisolated func buildRawEventFragments(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) -> [RawEventSQLFragment] {
        Self.allRawEventFragments.filter { !excludedEventTypes.contains($0.eventType) }
    }

    /// 将 SQL 事件类型标识映射为领域枚举，未知值视为异常数据并跳过。
    nonisolated func readCalendarEventType(rawValue: String) -> ReadCalendarEventType? {
        switch rawValue {
        case "note": .note
        case "relevant": .relevant
        case "review": .review
        case "checkIn": .checkIn
        case "readDone": .readDone
        default: nil
        }
    }
}
