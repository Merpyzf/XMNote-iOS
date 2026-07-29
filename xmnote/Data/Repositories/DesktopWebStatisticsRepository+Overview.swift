/**
 * [INPUT]: 依赖 DesktopWebStatisticsRepository 的时间范围/图表能力与 V44 阅读行为、书籍状态表
 * [OUTPUT]: 提供 Android StatisticsWebService overview 的指标、分布、趋势和环比快照
 * [POS]: Data 层网页统计仓储概览扩展；统一完读事件与 Android 阅读天数口径
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated struct DesktopWebStatisticsOverviewSnapshot: Sendable, Equatable {
    struct Status: Sendable, Equatable {
        let status: Int
        let label: String
        let count: Int
        let ratio: Double
    }

    struct Delta: Sendable, Equatable {
        let totalReadingTime: Int
        let readingDays: Int
        let noteCount: Int
        let readDoneBookCount: Int
        let totalWordCount: Int64
        let purchaseBookCount: Int
    }

    struct Comparison: Sendable, Equatable {
        let mode: String
        let label: String
        let hasBaseline: Bool
        let delta: Delta?
    }

    let totalReadingTime: Int
    let readingDays: Int
    let noteCount: Int
    let readDoneBookCount: Int
    let totalWordCount: Int64
    let purchaseBookCount: Int
    let statusDistribution: [Status]
    let readingTimeTrend: [DesktopWebStatisticsTrendSnapshot]
    let readingTimeTrendUnit: String
    let comparison: Comparison?
}

nonisolated extension DesktopWebStatisticsRepository {
    struct OverviewMetrics: Sendable, Equatable {
        let totalReadingTime: Int64
        let readingDays: Int
        let noteCount: Int64
        let readDoneBookCount: Int64
        let totalWordCount: Int64
        let purchaseBookCount: Int

        var hasData: Bool {
            totalReadingTime > 0 || readingDays > 0 || noteCount > 0
                || readDoneBookCount > 0 || totalWordCount > 0 || purchaseBookCount > 0
        }
    }

    struct ReadDoneEvent: Sendable, Hashable {
        let bookID: Int64
        let time: Int64
    }

    struct StatusEvent: Sendable, Equatable {
        let bookID: Int64
        let status: Int
        let time: Int64
    }

    /// 返回当前范围六项概览，并在年/月/周范围存在基线数据时附带差值。
    func overview(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebStatisticsOverviewSnapshot {
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        let metrics = try await overviewMetrics(scope: scope)
        let statuses = try await statusDistribution(scope: scope)
        let trend = try await readingTimeTrend(scope: scope)
        let comparisonScope = try comparisonScope(year: year, month: month, weekStart: weekStart)
        let comparison: DesktopWebStatisticsOverviewSnapshot.Comparison?
        if let comparisonScope {
            let baseline = try await overviewMetrics(scope: comparisonScope.scope)
            comparison = .init(
                mode: comparisonScope.mode,
                label: comparisonScope.label,
                hasBaseline: baseline.hasData,
                delta: baseline.hasData ? .init(
                    totalReadingTime: kotlinInt(metrics.totalReadingTime - baseline.totalReadingTime),
                    readingDays: metrics.readingDays - baseline.readingDays,
                    noteCount: kotlinInt(metrics.noteCount - baseline.noteCount),
                    readDoneBookCount: kotlinInt(metrics.readDoneBookCount - baseline.readDoneBookCount),
                    totalWordCount: metrics.totalWordCount - baseline.totalWordCount,
                    purchaseBookCount: metrics.purchaseBookCount - baseline.purchaseBookCount
                ) : nil
            )
        } else {
            comparison = nil
        }
        return DesktopWebStatisticsOverviewSnapshot(
            totalReadingTime: kotlinInt(metrics.totalReadingTime),
            readingDays: metrics.readingDays,
            noteCount: kotlinInt(metrics.noteCount),
            readDoneBookCount: kotlinInt(metrics.readDoneBookCount),
            totalWordCount: metrics.totalWordCount,
            purchaseBookCount: metrics.purchaseBookCount,
            statusDistribution: statuses,
            readingTimeTrend: trend.items,
            readingTimeTrendUnit: trend.unit,
            comparison: comparison
        )
    }

    /// 合并有效书籍历史完读事件与当前 READ_DONE 快照，并按 bookId/time 去重。
    func completedReadDoneEvents() async throws -> [ReadDoneEvent] {
        try await database.dbPool.read { db in
            // SQL 目的：复刻 BookRepository.getCompletedReadDoneEventTimesByBookIdSync。
            // 涉及表：book_read_status_record、book；历史记录只接受仍存在书籍，当前快照作为缺失历史的补充。
            // 关键过滤：READ_DONE=3、时间>0、书籍和历史记录未删除；UNION 后按 book/time 去重。
            // 时间字段：changed_date/read_status_changed_date 均为毫秒。
            // 返回字段用途：概览、年度范围、读完图表和年度目标完成判断。
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT book_id, done_time FROM (
                        SELECT r.book_id AS book_id, r.changed_date AS done_time
                        FROM book_read_status_record r
                        JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                        WHERE r.is_deleted = 0 AND r.read_status_id = 3
                          AND r.book_id > 0 AND r.changed_date > 0
                        UNION
                        SELECT b.id AS book_id, b.read_status_changed_date AS done_time
                        FROM book b
                        WHERE b.is_deleted = 0 AND b.id > 0 AND b.read_status_id = 3
                          AND b.read_status_changed_date > 0
                    )
                    ORDER BY book_id, done_time
                    """
            )
            return rows.map { ReadDoneEvent(bookID: $0["book_id"], time: $0["done_time"]) }
        }
    }

    /// 读取仍存在书籍的全部有效状态历史，供热力图以外的完读字数和来源/标签统计复用。
    func activeStatusEvents() async throws -> [StatusEvent] {
        try await database.dbPool.read { db in
            // SQL 目的：复刻 BookReadStatusRecordDao.queryAllOfActiveBooks。
            // 涉及表：book_read_status_record、book；排除软删除书籍与状态记录。
            // 时间字段：changed_date 毫秒值原样返回。
            // 返回字段用途：完读字数、热力图状态、来源/标签范围筛选。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT r.book_id, r.read_status_id, r.changed_date
                    FROM book_read_status_record r
                    JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                    WHERE r.is_deleted = 0
                    """
            ).map {
                StatusEvent(
                    bookID: $0["book_id"], status: Int($0["read_status_id"] as Int64),
                    time: $0["changed_date"]
                )
            }
        }
    }

    func kotlinInt(_ value: Int64) -> Int {
        Int(Int32(truncatingIfNeeded: value))
    }
}

private nonisolated extension DesktopWebStatisticsRepository {
    struct ComparisonScope: Sendable {
        let mode: String
        let label: String
        let scope: TimeScope
    }

    func overviewMetrics(scope: TimeScope) async throws -> OverviewMetrics {
        async let records = readRecords()
        async let doneEvents = completedReadDoneEvents()
        async let statusEvents = activeStatusEvents()
        let allRecords = try await records
        let scopedRecords = scope.isAll ? allRecords : allRecords.filter { scope.start...scope.end ~= $0.eventTime }
        let totalReadTime = scope.isAll
            ? try await database.dbPool.read { db in
                // SQL 目的：复刻 queryTotalReadingTime，直接求原始已完成记录秒数总和。
                // 涉及表：read_time_record；过滤 status=3、未删除、非占位书籍。
                // 时间字段：不使用；elapsed_seconds 为秒。
                // 返回字段用途：all-time totalReadingTime，避免跨日拆分舍入改变总数。
                try Int64.fetchOne(
                    db,
                    sql: "SELECT SUM(elapsed_seconds) FROM read_time_record WHERE status = 3 AND is_deleted = 0 AND book_id != 0"
                ) ?? 0
            }
            : scopedRecords.reduce(0) { $0 + $1.elapsedSeconds }
        let readingDays = try await readingDayCount(scope: scope, records: scopedRecords)
        let noteCount = try await database.dbPool.read { db in
            // SQL 目的：复刻 NoteDao.queryTotalNoteCount/queryNoteCountInRange。
            // 涉及表：note、book；只统计仍存在书籍下的有效书摘。
            // 时间字段：范围模式按 note.created_date 毫秒闭区间筛选。
            // 返回字段用途：overview.noteCount。
            let condition = scope.isAll ? "" : " AND n.created_date BETWEEN ? AND ?"
            let arguments: StatementArguments = scope.isAll ? [] : [scope.start, scope.end]
            return try Int64.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM note n JOIN book b ON b.id = n.book_id
                    WHERE n.is_deleted = 0 AND b.is_deleted = 0\(condition)
                    """,
                arguments: arguments
            ) ?? 0
        }
        let events = try await doneEvents
        let readDoneCount = Int64(Set(events.filter { scope.isAll || scope.start...scope.end ~= $0.time }.map(\.bookID)).count)
        let exactWordCount = try await readDoneWordCount(
            statusEvents: try await statusEvents,
            scope: scope
        )
        let wordCount = exactWordCount
        let purchaseCount = try await database.dbPool.read { db in
            // SQL 目的：复刻 queryAllPurchaseBooks/queryPurchaseBooksInRange 的列表数量。
            // 涉及表：book；仅有效非占位、price>0 且 purchase_date!=0 的购入记录。
            // 时间字段：范围模式按 purchase_date 毫秒闭区间筛选。
            // 返回字段用途：overview.purchaseBookCount。
            let condition = scope.isAll ? "" : " AND purchase_date BETWEEN ? AND ?"
            let arguments: StatementArguments = scope.isAll ? [] : [scope.start, scope.end]
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM book
                    WHERE is_deleted = 0 AND id != 0 AND price > 0 AND purchase_date != 0\(condition)
                    """,
                arguments: arguments
            ) ?? 0
        }
        return OverviewMetrics(
            totalReadingTime: totalReadTime,
            readingDays: readingDays,
            noteCount: noteCount,
            readDoneBookCount: readDoneCount,
            totalWordCount: wordCount,
            purchaseBookCount: purchaseCount
        )
    }

    func readingDayCount(scope: TimeScope, records: [ReadRecord]) async throws -> Int {
        let timestamps = try await database.dbPool.read { db -> [Int64] in
            // SQL 目的：复刻阅读天数聚合的 note/relevant/review/check-in 四类 BaseEntity 输入。
            // 涉及表：note/book、category_content、review、check_in_record。
            // 关键过滤：note 要求有效书籍；其余三类仅按各 DAO 自身 is_deleted 过滤。
            // 时间字段：均使用 created_date，打卡使用 checkin_date；范围为毫秒闭区间。
            // 返回字段用途：与阅读计时 eventTime 合并后按本地日期去重。
            let rangeCondition: (String) -> String = { column in
                scope.isAll ? "" : " AND \(column) BETWEEN \(scope.start) AND \(scope.end)"
            }
            let sql = """
                SELECT n.created_date AS event_time FROM note n JOIN book b ON b.id = n.book_id
                    WHERE n.is_deleted = 0 AND b.is_deleted = 0\(rangeCondition("n.created_date"))
                UNION ALL SELECT created_date FROM category_content
                    WHERE is_deleted = 0\(rangeCondition("created_date"))
                UNION ALL SELECT created_date FROM review
                    WHERE is_deleted = 0\(rangeCondition("created_date"))
                UNION ALL SELECT checkin_date FROM check_in_record
                    WHERE is_deleted = 0\(rangeCondition("checkin_date"))
                """
            return try Int64.fetchAll(db, sql: sql)
        }
        let all = timestamps + records.map(\.eventTime)
        return Set(all.map { timestamp in
            dateString(Date(timeIntervalSince1970: Double(timestamp) / 1_000))
        }).count
    }

    func readDoneWordCount(statusEvents: [StatusEvent], scope: TimeScope) async throws -> Int64 {
        let ids = Set(statusEvents.filter {
            $0.status == 3 && (scope.isAll || scope.start...scope.end ~= $0.time)
        }.map(\.bookID))
        guard !ids.isEmpty else { return 0 }
        return try await database.dbPool.read { db in
            // SQL 目的：复刻 getReadWordCountDataOverview 的已完读书籍字数求和。
            // 涉及表：book；bookId 来自有效历史 READ_DONE 状态，不使用当前快照兜底。
            // 关键过滤：有效书籍且 word_count>0，同一书籍只求和一次。
            // 返回字段用途：overview.totalWordCount。
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return try Int64.fetchOne(
                db,
                sql: "SELECT SUM(word_count) FROM book WHERE is_deleted = 0 AND id IN (\(placeholders)) AND word_count > 0",
                arguments: StatementArguments(ids)
            ) ?? 0
        }
    }

    func statusDistribution(scope: TimeScope) async throws -> [DesktopWebStatisticsOverviewSnapshot.Status] {
        // NOTE(ANDROID-WEB-063): 范围模式按书籍“当前状态更新时间”筛当前快照，不还原该范围内的历史状态。
        let counts: [Int: Int] = try await database.dbPool.read { db in
            // SQL 目的：复刻 getBookStatusPieChartData 的当前书籍快照分布。
            // 涉及表：book；all 模式取全部有效非占位书籍，范围模式按 read_status_changed_date 筛选。
            // 返回字段用途：overview.statusDistribution，未知状态不计入分母。
            let condition = scope.isAll ? "" : " AND read_status_changed_date BETWEEN ? AND ?"
            let arguments: StatementArguments = scope.isAll ? [] : [scope.start, scope.end]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT read_status_id, COUNT(*) AS value FROM book
                    WHERE is_deleted = 0 AND id != 0\(condition)
                    GROUP BY read_status_id
                    """,
                arguments: arguments
            )
            return Dictionary(uniqueKeysWithValues: rows.map {
                (Int($0["read_status_id"] as Int64), Int($0["value"] as Int64))
            })
        }
        let order = [1, 2, 3, 5, 4]
        let labels = [1: "想读", 2: "在读", 3: "读完", 4: "弃读", 5: "搁置"]
        let total = order.reduce(0) { $0 + (counts[$1] ?? 0) }
        guard total > 0 else { return [] }
        return order.compactMap { status in
            guard let count = counts[status], count > 0 else { return nil }
            return .init(
                status: status,
                label: labels[status] ?? "",
                count: count,
                ratio: Double(Float(count) / Float(total))
            )
        }
    }

    func overviewWordCountRoundTrip(_ count: Int64) -> Int64 {
        let formatted: String
        if count >= 10_000 {
            formatted = String(format: "%.1f", Double(count) / 10_000)
            return Int64((Double(formatted) ?? 0) * 10_000)
        }
        if count >= 1_000 {
            formatted = String(format: "%.1f", Double(count) / 1_000)
            return Int64((Double(formatted) ?? 0) * 1_000)
        }
        return count
    }

    func comparisonScope(year: Int, month: Int, weekStart: String?) throws -> ComparisonScope? {
        if year == 0, month == 0, weekStart == nil { return nil }
        if let weekStart {
            let current = try parseDate(weekStart)
            guard let start = calendar.date(byAdding: .day, value: -7, to: current),
                  let end = calendar.date(byAdding: .day, value: 7, to: start) else {
                throw DesktopWebStatisticsRepositoryError.invalidDate
            }
            return ComparisonScope(
                mode: "week_over_week", label: "比上周",
                scope: TimeScope(start: millis(start), end: millis(end) - 1, isAll: false)
            )
        }
        if month > 0, year > 0 {
            guard let current = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let previous = calendar.date(byAdding: .month, value: -1, to: current) else {
                throw DesktopWebStatisticsRepositoryError.invalidDate
            }
            let range = try monthRange(
                year: calendar.component(.year, from: previous),
                month: calendar.component(.month, from: previous)
            )
            return ComparisonScope(
                mode: "month_over_month", label: "比上个月",
                scope: TimeScope(start: range.lowerBound, end: range.upperBound, isAll: false)
            )
        }
        guard year > 1 else { return nil }
        let range = try yearRange(year - 1)
        return ComparisonScope(
            mode: "year_over_year", label: "比上年度",
            scope: TimeScope(start: range.lowerBound, end: range.upperBound, isAll: false)
        )
    }
}
