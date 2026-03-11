import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 ObservationStream 桥接数据库观察流，依赖 ReadingDashboardSnapshot 领域模型
 * [OUTPUT]: 对外提供 ReadingDashboardRepository（ReadingDashboardRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层在读首页聚合仓储实现，统一封装首页仪表盘读取与阅读目标写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

nonisolated struct ReadingDashboardRepository: ReadingDashboardRepositoryProtocol {
    private let dbPool: DatabasePool
    private let calendar = Calendar.current

    private enum Defaults {
        static let dailyGoalSeconds = 3600
        static let yearlyTargetCount = 12
        static let trendDayWindow = 7
        static let trendMonthWindow = 7
        static let recentBookLimit = 12
    }

    /// 注入数据库管理器，供首页 observation 与目标写入复用同一数据源。
    init(databaseManager: DatabaseManager) {
        self.dbPool = databaseManager.database.dbPool
    }

    /// 持续观察指定参考日期的首页仪表盘快照，数据库变更后自动推送最新聚合结果。
    nonisolated func observeDashboard(referenceDate: Date) -> AsyncThrowingStream<ReadingDashboardSnapshot, Error> {
        let normalizedReferenceDate = calendar.startOfDay(for: referenceDate)
        return ObservationStream.make(in: dbPool) { db in
            try buildDashboardSnapshot(db, referenceDate: normalizedReferenceDate)
        }
    }

    /// 更新指定日期的每日阅读目标；业务意图是让首页目标卡立刻回写到 read_target(type=1)。
    /// 前置条件：seconds > 0。
    /// 副作用：插入或更新当天阅读目标记录。
    /// 失败语义：数据库写入失败时抛出底层错误。
    nonisolated func updateDailyReadingGoal(seconds: Int, for date: Date) async throws {
        let clampedSeconds = max(1, seconds)
        let dayStart = calendar.startOfDay(for: date)
        let dayStartMillis = Int64(dayStart.timeIntervalSince1970 * 1000)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try await dbPool.write { db in
            let existingId = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM read_target
                    WHERE is_deleted = 0 AND type = 1 AND time = ?
                    ORDER BY id DESC
                    LIMIT 1
                    """,
                arguments: [dayStartMillis]
            )

            if let existingId {
                try db.execute(
                    sql: """
                        UPDATE read_target
                        SET target = ?, updated_date = ?
                        WHERE id = ?
                        """,
                    arguments: [clampedSeconds, now, existingId]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO read_target (time, target, type, created_date, updated_date, last_sync_date, is_deleted)
                        VALUES (?, ?, 1, ?, ?, 0, 0)
                        """,
                    arguments: [dayStartMillis, clampedSeconds, now, now]
                )
            }
        }
    }

    /// 更新指定年份的年度阅读目标；业务意图是让年度摘要卡和年度列表共用同一目标真相源。
    /// 前置条件：count > 0。
    /// 副作用：插入或更新年度阅读目标记录。
    /// 失败语义：数据库写入失败时抛出底层错误。
    nonisolated func updateYearlyReadGoal(count: Int, forYear year: Int) async throws {
        let clampedCount = max(1, count)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try await dbPool.write { db in
            let existingId = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM read_target
                    WHERE is_deleted = 0 AND type = 0 AND time = ?
                    ORDER BY id DESC
                    LIMIT 1
                    """,
                arguments: [year]
            )

            if let existingId {
                try db.execute(
                    sql: """
                        UPDATE read_target
                        SET target = ?, updated_date = ?
                        WHERE id = ?
                        """,
                    arguments: [clampedCount, now, existingId]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO read_target (time, target, type, created_date, updated_date, last_sync_date, is_deleted)
                        VALUES (?, ?, 0, ?, ?, 0, 0)
                        """,
                    arguments: [year, clampedCount, now, now]
                )
            }
        }
    }
}

private extension ReadingDashboardRepository {
    enum RepositoryError: LocalizedError {
        case invalidDateRange

        var errorDescription: String? {
            switch self {
            case .invalidDateRange: "日期范围计算失败"
            }
        }
    }

    struct DashboardBookRow {
        let id: Int64
        let name: String
        let coverURL: String
        let readPosition: Double
        let totalPosition: Int64
        let totalPagination: Int64
        let currentPositionUnit: Int64
        let readStatusId: Int64
    }

    struct TrendPointRow {
        let label: String
        let value: Int
    }

    /// 组装首页快照，统一收口阅读目标、趋势卡、继续阅读、最近在读与年度摘要。
    func buildDashboardSnapshot(_ db: Database, referenceDate: Date) throws -> ReadingDashboardSnapshot {
        let normalizedReferenceDate = calendar.startOfDay(for: referenceDate)
        let year = calendar.component(.year, from: normalizedReferenceDate)
        let dailyGoal = try fetchDailyGoal(db, referenceDate: normalizedReferenceDate)
        let trends = try buildTrendMetrics(db, referenceDate: normalizedReferenceDate)
        let resumeBook = try fetchResumeBook(db)
        let recentBooks = try fetchRecentBooks(db, limit: Defaults.recentBookLimit)
        let yearSummary = try fetchYearSummary(db, year: year)

        return ReadingDashboardSnapshot(
            referenceDate: normalizedReferenceDate,
            trends: trends,
            dailyGoal: dailyGoal,
            resumeBook: resumeBook,
            recentBooks: recentBooks,
            yearSummary: yearSummary
        )
    }

    /// 读取今日阅读目标，缺省链路对齐 Android：今日记录 > 最近一次目标 > 1 小时。
    func fetchDailyGoal(_ db: Database, referenceDate: Date) throws -> ReadingDailyGoal {
        let dayRange = dayMillisRange(for: referenceDate)
        let readSeconds = try fetchReadSeconds(db, millisRange: dayRange)

        let dayStartMillis = Int64(referenceDate.timeIntervalSince1970 * 1000)
        let target = try Int.fetchOne(
            db,
            sql: """
                SELECT target
                FROM read_target
                WHERE is_deleted = 0 AND type = 1 AND time = ?
                ORDER BY id DESC
                LIMIT 1
                """,
            arguments: [dayStartMillis]
        ) ?? fetchLatestDailyGoal(db) ?? Defaults.dailyGoalSeconds

        return ReadingDailyGoal(
            readSeconds: readSeconds,
            targetSeconds: max(1, target)
        )
    }

    /// 读取最近一次每日阅读目标，供无当日记录时回退。
    func fetchLatestDailyGoal(_ db: Database) -> Int? {
        try? Int.fetchOne(
            db,
            sql: """
                SELECT target
                FROM read_target
                WHERE is_deleted = 0 AND type = 1
                ORDER BY time DESC, id DESC
                LIMIT 1
                """
        )
    }

    /// 构建首页三张趋势卡：阅读时长、书摘数、已读书籍数。
    func buildTrendMetrics(_ db: Database, referenceDate: Date) throws -> [ReadingTrendMetric] {
        let readingPoints = try fetchRecentReadDurationPoints(db, referenceDate: referenceDate)
        let notePoints = try fetchRecentNoteCountPoints(db, referenceDate: referenceDate)
        let readDonePoints = try fetchRecentReadDoneMonthPoints(db, referenceDate: referenceDate)

        let readingTotal = try fetchTotalReadSeconds(db)
        let noteTotal = try fetchTotalNoteCount(db)
        let readDoneTotal = try fetchTotalReadDoneCount(db)

        return [
            ReadingTrendMetric(
                kind: .readingDuration,
                title: "阅读时长",
                totalValue: readingTotal,
                points: readingPoints.map { .init(id: $0.label, label: $0.label, value: $0.value) }
            ),
            ReadingTrendMetric(
                kind: .noteCount,
                title: "书摘数量",
                totalValue: noteTotal,
                points: notePoints.map { .init(id: $0.label, label: $0.label, value: $0.value) }
            ),
            ReadingTrendMetric(
                kind: .readDoneCount,
                title: "已读书籍",
                totalValue: readDoneTotal,
                points: readDonePoints.map { .init(id: $0.label, label: $0.label, value: $0.value) }
            )
        ]
    }

    /// 继续阅读入口：最近一次计时对应且当前未进入“读完/弃读”的书。
    func fetchResumeBook(_ db: Database) throws -> ReadingResumeBook? {
        let sql = """
            SELECT b.id, b.name, b.cover, b.read_position, b.total_position, b.total_pagination,
                   b.current_position_unit, b.read_status_id
            FROM read_time_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND b.id != 0
              AND b.read_status_id NOT IN (?, ?)
            ORDER BY r.created_date DESC
            LIMIT 1
            """
        guard let row = try Row.fetchOne(
            db,
            sql: sql,
            arguments: [BookReadingStatus.readDone.rawValue, BookReadingStatus.abandon.rawValue]
        ) else {
            return nil
        }

        let book = decodeDashboardBookRow(row)
        return ReadingResumeBook(
            id: book.id,
            name: book.name,
            coverURL: book.coverURL,
            progressPercent: readingProgressPercent(for: book)
        )
    }

    /// 最近在读按六路行为并集聚合，并按每本书最近活动时间倒序。
    func fetchRecentBooks(_ db: Database, limit: Int) throws -> [ReadingRecentBook] {
        let sql = """
            WITH recent_activity AS (
                SELECT book_id, MAX(created_date) AS latest_at
                FROM note
                WHERE is_deleted = 0 AND book_id != 0
                GROUP BY book_id

                UNION ALL

                SELECT book_id, MAX(created_date) AS latest_at
                FROM category_content
                WHERE is_deleted = 0 AND book_id != 0
                GROUP BY book_id

                UNION ALL

                SELECT book_id, MAX(created_date) AS latest_at
                FROM review
                WHERE is_deleted = 0 AND book_id != 0
                GROUP BY book_id

                UNION ALL

                SELECT book_id,
                       MAX(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END) AS latest_at
                FROM read_time_record
                WHERE is_deleted = 0 AND book_id != 0
                GROUP BY book_id

                UNION ALL

                SELECT book_id, MAX(checkin_date) AS latest_at
                FROM check_in_record
                WHERE is_deleted = 0 AND book_id != 0 AND checkin_date != 0
                GROUP BY book_id

                UNION ALL

                SELECT id AS book_id, MAX(book_mark_modified_time) AS latest_at
                FROM book
                WHERE is_deleted = 0 AND id != 0 AND book_mark_modified_time != 0
                GROUP BY id
            )
            SELECT b.id, b.name, b.cover, b.read_position, b.total_position, b.total_pagination,
                   b.current_position_unit, b.read_status_id,
                   MAX(ra.latest_at) AS latest_at
            FROM recent_activity ra
            JOIN book b ON b.id = ra.book_id AND b.is_deleted = 0
            GROUP BY b.id
            ORDER BY latest_at DESC, b.id DESC
            LIMIT ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [limit])
        return rows.map { row in
            let book = decodeDashboardBookRow(row)
            return ReadingRecentBook(
                id: book.id,
                name: book.name,
                coverURL: book.coverURL,
                latestActivityAt: row["latest_at"] ?? 0,
                progressPercent: readingProgressPercent(for: book)
            )
        }
    }

    /// 年度摘要：目标值 + 年度已读列表。
    func fetchYearSummary(_ db: Database, year: Int) throws -> ReadingYearSummary {
        let targetCount = try Int.fetchOne(
            db,
            sql: """
                SELECT target
                FROM read_target
                WHERE is_deleted = 0 AND type = 0 AND time = ?
                ORDER BY id DESC
                LIMIT 1
                """,
            arguments: [year]
        ) ?? Defaults.yearlyTargetCount

        let books = try fetchYearReadBooks(db, year: year)
        return ReadingYearSummary(
            year: year,
            targetCount: max(1, targetCount),
            readCount: books.count,
            books: books
        )
    }

    /// 年度已读列表同时覆盖 book 表和状态历史表，避免漏掉历史读完记录。
    func fetchYearReadBooks(_ db: Database, year: Int) throws -> [ReadingYearReadBook] {
        let yearRange = try yearMillisRange(year: year)
        let bookIds = try fetchYearReadBookIds(db, millisRange: yearRange)
        guard !bookIds.isEmpty else { return [] }

        return try bookIds.compactMap { bookId in
            let infoRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, name, cover, read_status_id, read_status_changed_date
                    FROM book
                    WHERE id = ? AND is_deleted = 0
                    """,
                arguments: [bookId]
            )
            guard let infoRow else { return nil }

            let latestReadDoneChangedDate = try Int64.fetchOne(
                db,
                sql: """
                    SELECT MAX(changed_date)
                    FROM book_read_status_record
                    WHERE is_deleted = 0
                      AND book_id = ?
                      AND read_status_id = ?
                      AND changed_date BETWEEN ? AND ?
                    """,
                arguments: [bookId, BookReadingStatus.readDone.rawValue, yearRange.lowerBound, yearRange.upperBound]
            ) ?? 0

            let bookReadStatusId: Int64 = infoRow["read_status_id"] ?? 0
            let bookChangedDate: Int64 = infoRow["read_status_changed_date"] ?? 0
            let effectiveChangedDate = if bookReadStatusId == BookReadingStatus.readDone.rawValue || latestReadDoneChangedDate == 0 {
                max(bookChangedDate, latestReadDoneChangedDate)
            } else {
                latestReadDoneChangedDate
            }

            let totalReadSeconds = try fetchTotalReadSecondsOfBook(db, bookId: bookId)
            let readDoneCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM book_read_status_record
                    WHERE is_deleted = 0
                      AND book_id = ?
                      AND read_status_id = ?
                    """,
                arguments: [bookId, BookReadingStatus.readDone.rawValue]
            ) ?? 0

            return ReadingYearReadBook(
                id: bookId,
                name: infoRow["name"] ?? "",
                coverURL: infoRow["cover"] ?? "",
                readStatusChangedDate: effectiveChangedDate,
                totalReadSeconds: totalReadSeconds,
                readDoneCount: readDoneCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.readStatusChangedDate != rhs.readStatusChangedDate {
                return lhs.readStatusChangedDate > rhs.readStatusChangedDate
            }
            return lhs.id > rhs.id
        }
    }

    /// 提取年度已读书籍 ID，并集语义对齐 Android。
    func fetchYearReadBookIds(_ db: Database, millisRange: ClosedRange<Int64>) throws -> [Int64] {
        let fromBookTable = try Int64.fetchAll(
            db,
            sql: """
                SELECT id
                FROM book
                WHERE is_deleted = 0
                  AND id != 0
                  AND read_status_id = ?
                  AND read_status_changed_date BETWEEN ? AND ?
                """,
            arguments: [BookReadingStatus.readDone.rawValue, millisRange.lowerBound, millisRange.upperBound]
        )
        let fromStatusHistory = try Int64.fetchAll(
            db,
            sql: """
                SELECT DISTINCT book_id
                FROM book_read_status_record
                WHERE is_deleted = 0
                  AND book_id != 0
                  AND read_status_id = ?
                  AND changed_date BETWEEN ? AND ?
                """,
            arguments: [BookReadingStatus.readDone.rawValue, millisRange.lowerBound, millisRange.upperBound]
        )

        return Array(Set(fromBookTable).union(fromStatusHistory)).sorted()
    }

    /// 读取某本书的历史累计阅读时长。
    func fetchTotalReadSecondsOfBook(_ db: Database, bookId: Int64) throws -> Int {
        let total = try Int64.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(elapsed_seconds), 0)
                FROM read_time_record
                WHERE is_deleted = 0
                  AND book_id = ?
                  AND status = 3
                """,
            arguments: [bookId]
        ) ?? 0
        return Int(total)
    }

    /// 最近 7 天阅读时长趋势。
    func fetchRecentReadDurationPoints(_ db: Database, referenceDate: Date) throws -> [TrendPointRow] {
        try buildRecentDayPoints(referenceDate: referenceDate, window: Defaults.trendDayWindow) { day in
            try fetchReadSeconds(db, millisRange: dayMillisRange(for: day))
        }
    }

    /// 最近 7 天书摘数量趋势。
    func fetchRecentNoteCountPoints(_ db: Database, referenceDate: Date) throws -> [TrendPointRow] {
        try buildRecentDayPoints(referenceDate: referenceDate, window: Defaults.trendDayWindow) { day in
            let range = dayMillisRange(for: day)
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM note
                    WHERE is_deleted = 0
                      AND created_date BETWEEN ? AND ?
                    """,
                arguments: [range.lowerBound, range.upperBound]
            ) ?? 0
        }
    }

    /// 最近 7 个月已读书籍趋势。
    func fetchRecentReadDoneMonthPoints(_ db: Database, referenceDate: Date) throws -> [TrendPointRow] {
        let monthStarts = try recentMonthStarts(referenceDate: referenceDate, window: Defaults.trendMonthWindow)
        return try monthStarts.map { monthStart in
            let range = try monthMillisRange(for: monthStart)
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM book
                    WHERE is_deleted = 0
                      AND read_status_id = ?
                      AND read_status_changed_date BETWEEN ? AND ?
                    """,
                arguments: [BookReadingStatus.readDone.rawValue, range.lowerBound, range.upperBound]
            ) ?? 0
            return TrendPointRow(
                label: monthLabel(for: monthStart),
                value: count
            )
        }
    }

    /// 总阅读时长。
    func fetchTotalReadSeconds(_ db: Database) throws -> Int {
        Int(
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(elapsed_seconds), 0)
                    FROM read_time_record
                    WHERE is_deleted = 0
                      AND status = 3
                    """
            ) ?? 0
        )
    }

    /// 总书摘数。
    func fetchTotalNoteCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM note
                WHERE is_deleted = 0
                """
        ) ?? 0
    }

    /// 当前已读书籍总数，对齐 Android 当前口径。
    func fetchTotalReadDoneCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM book
                WHERE is_deleted = 0
                  AND read_status_id = ?
                """,
            arguments: [BookReadingStatus.readDone.rawValue]
        ) ?? 0
    }

    /// 读取某个时间区间内的阅读时长，兼容 fuzzy 与精确计时双时间源。
    func fetchReadSeconds(_ db: Database, millisRange: ClosedRange<Int64>) throws -> Int {
        let total = try Int64.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(elapsed_seconds), 0)
                FROM read_time_record
                WHERE is_deleted = 0
                  AND status = 3
                  AND (
                    (fuzzy_read_date != 0 AND fuzzy_read_date BETWEEN ? AND ?)
                    OR
                    (fuzzy_read_date = 0 AND start_time BETWEEN ? AND ?)
                  )
                """,
            arguments: [
                millisRange.lowerBound, millisRange.upperBound,
                millisRange.lowerBound, millisRange.upperBound
            ]
        ) ?? 0
        return Int(total)
    }

    /// 计算首页封面卡进度百分比，语义对齐 Android RecentReadingBookListAdapter。
    func readingProgressPercent(for book: DashboardBookRow) -> Double? {
        switch book.currentPositionUnit {
        case 1:
            guard book.totalPosition > 0 else { return nil }
            return min(100, max(0, book.readPosition / Double(book.totalPosition) * 100))
        case 2:
            guard book.totalPagination > 0 else { return nil }
            return min(100, max(0, book.readPosition / Double(book.totalPagination) * 100))
        default:
            guard book.readPosition > 0 else { return nil }
            return min(100, max(0, book.readPosition))
        }
    }

    /// 从统一书籍查询行解码首页书籍元数据。
    func decodeDashboardBookRow(_ row: Row) -> DashboardBookRow {
        DashboardBookRow(
            id: row["id"] ?? 0,
            name: row["name"] ?? "",
            coverURL: row["cover"] ?? "",
            readPosition: row["read_position"] ?? 0,
            totalPosition: row["total_position"] ?? 0,
            totalPagination: row["total_pagination"] ?? 0,
            currentPositionUnit: row["current_position_unit"] ?? 0,
            readStatusId: row["read_status_id"] ?? 0
        )
    }

    /// 构建最近 N 天点列，保证空值日期也保留占位。
    func buildRecentDayPoints(
        referenceDate: Date,
        window: Int,
        value: (Date) throws -> Int
    ) throws -> [TrendPointRow] {
        try recentDayStarts(referenceDate: referenceDate, window: window).map { day in
            TrendPointRow(
                label: dayLabel(for: day),
                value: try value(day)
            )
        }
    }

    /// 最近 N 天起始日数组，按时间正序输出。
    func recentDayStarts(referenceDate: Date, window: Int) throws -> [Date] {
        guard window > 0 else { return [] }
        return try (0..<window).map { offset in
            guard let date = calendar.date(byAdding: .day, value: -(window - 1 - offset), to: referenceDate) else {
                throw RepositoryError.invalidDateRange
            }
            return calendar.startOfDay(for: date)
        }
    }

    /// 最近 N 个月首日数组，按时间正序输出。
    func recentMonthStarts(referenceDate: Date, window: Int) throws -> [Date] {
        guard window > 0 else { return [] }
        let currentMonthStart = try monthStart(for: referenceDate)
        return try (0..<window).map { offset in
            guard let month = calendar.date(byAdding: .month, value: -(window - 1 - offset), to: currentMonthStart) else {
                throw RepositoryError.invalidDateRange
            }
            return try monthStart(for: month)
        }
    }

    /// 读取自然日毫秒区间。
    func dayMillisRange(for date: Date) -> ClosedRange<Int64> {
        let dayStart = calendar.startOfDay(for: date)
        let start = Int64(dayStart.timeIntervalSince1970 * 1000)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let end = Int64(nextDay.timeIntervalSince1970 * 1000) - 1
        return start...end
    }

    /// 读取自然年毫秒区间。
    func yearMillisRange(year: Int) throws -> ClosedRange<Int64> {
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let nextYearStart = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            throw RepositoryError.invalidDateRange
        }
        let start = Int64(calendar.startOfDay(for: yearStart).timeIntervalSince1970 * 1000)
        let end = Int64(calendar.startOfDay(for: nextYearStart).timeIntervalSince1970 * 1000) - 1
        return start...end
    }

    /// 读取自然月毫秒区间。
    func monthMillisRange(for monthStart: Date) throws -> ClosedRange<Int64> {
        let normalizedMonthStart = try self.monthStart(for: monthStart)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: normalizedMonthStart) else {
            throw RepositoryError.invalidDateRange
        }
        let start = Int64(normalizedMonthStart.timeIntervalSince1970 * 1000)
        let end = Int64(calendar.startOfDay(for: nextMonth).timeIntervalSince1970 * 1000) - 1
        return start...end
    }

    /// 归一到月份首日。
    func monthStart(for date: Date) throws -> Date {
        guard let normalized = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else {
            throw RepositoryError.invalidDateRange
        }
        return calendar.startOfDay(for: normalized)
    }

    /// 首页日标签文案，使用中文短日期避免额外宽度占用。
    func dayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    /// 首页月标签文案，使用 `M月` 简写。
    func monthLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月"
        return formatter.string(from: date)
    }
}
