import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 HeatmapDay/HeatmapLevel 领域模型
 * [OUTPUT]: 对外提供 StatisticsRepository（StatisticsRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层统计仓储实现，聚合阅读时长/笔记数/打卡次数+时长为热力图数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct StatisticsRepository: StatisticsRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let calendar = Calendar.current

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?) {
        try await databaseManager.database.dbPool.read { db in
            buildHeatmapData(db)
        }
    }
}

// MARK: - 聚合查询

private struct CheckInSummary {
    let count: Int
    let seconds: Int
}

private extension StatisticsRepository {

    /// 三源聚合 → 热力图字典
    func buildHeatmapData(_ db: Database) -> (days: [Date: HeatmapDay], earliestDate: Date?) {
        let earliestDate = findEarliestDate(db)
        guard let earliest = earliestDate else {
            return ([:], nil)
        }

        let readMap = aggregateReadSeconds(db)
        let noteMap = aggregateNoteCounts(db)
        let checkInMap = aggregateCheckInSummary(db)

        let today = calendar.startOfDay(for: Date())
        var days: [Date: HeatmapDay] = [:]
        var current = calendar.startOfDay(for: earliest)

        while current <= today {
            let day = HeatmapDay(
                id: current,
                readSeconds: readMap[current] ?? 0,
                noteCount: noteMap[current] ?? 0,
                checkInCount: checkInMap[current]?.count ?? 0,
                checkInSeconds: checkInMap[current]?.seconds ?? 0
            )
            if day.readSeconds > 0 || day.noteCount > 0 || day.checkInCount > 0 {
                days[current] = day
            }
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }

        return (days, earliest)
    }

    // MARK: - 最早记录日期

    /// 三表取 MIN 时间戳，对齐 Android StatisticsRepository:407-430
    func findEarliestDate(_ db: Database) -> Date? {
        let queries = [
            """
            SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
            FROM read_time_record WHERE is_deleted = 0
            """,
            "SELECT MIN(created_date) FROM note WHERE is_deleted = 0",
            "SELECT MIN(checkin_date) FROM check_in_record WHERE is_deleted = 0 AND checkin_date != 0"
        ]

        let timestamps: [Int64] = queries.compactMap { sql in
            guard let value = try? Int64.fetchOne(db, sql: sql), value > 0 else { return nil }
            return value
        }

        guard let earliest = timestamps.min() else { return nil }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: Double(earliest) / 1000))
    }

    // MARK: - 阅读时长聚合

    /// 按天 SUM(elapsed_seconds)，处理 fuzzyReadDate 双时间源
    func aggregateReadSeconds(_ db: Database) -> [Date: Int] {
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
            GROUP BY day
            """
        return queryDayAggregation(db, sql: sql)
    }

    // MARK: - 笔记数聚合

    /// 按天 COUNT(note)
    func aggregateNoteCounts(_ db: Database) -> [Date: Int] {
        let sql = """
            SELECT DATE(created_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS total
            FROM note
            WHERE is_deleted = 0
            GROUP BY day
            """
        return queryDayAggregation(db, sql: sql)
    }

    // MARK: - 打卡聚合

    /// 按天聚合打卡次数与时长（amount * 20 分钟）
    func aggregateCheckInSummary(_ db: Database) -> [Date: CheckInSummary] {
        let sql = """
            SELECT DATE(checkin_date / 1000, 'unixepoch', 'localtime') AS day,
                   COUNT(*) AS checkin_count,
                   COALESCE(SUM(amount * 1200), 0) AS checkin_seconds
            FROM check_in_record
            WHERE is_deleted = 0 AND checkin_date != 0
            GROUP BY day
            """
        return queryDayCheckInSummary(db, sql: sql)
    }

    // MARK: - 通用日期聚合

    /// 执行 day+total 聚合 SQL，返回 [Date: Int] 字典
    func queryDayAggregation(_ db: Database, sql: String) -> [Date: Int] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        guard let rows = try? Row.fetchAll(db, sql: sql) else { return [:] }

        var result: [Date: Int] = [:]
        for row in rows {
            guard let dayStr: String = row["day"],
                  let total: Int = row["total"],
                  let date = formatter.date(from: dayStr) else { continue }
            result[calendar.startOfDay(for: date)] = total
        }
        return result
    }

    /// 执行打卡聚合 SQL，返回 [Date: CheckInSummary] 字典
    func queryDayCheckInSummary(_ db: Database, sql: String) -> [Date: CheckInSummary] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        guard let rows = try? Row.fetchAll(db, sql: sql) else { return [:] }

        var result: [Date: CheckInSummary] = [:]
        for row in rows {
            guard let dayStr: String = row["day"],
                  let count: Int = row["checkin_count"],
                  let seconds: Int = row["checkin_seconds"],
                  let date = formatter.date(from: dayStr) else { continue }
            result[calendar.startOfDay(for: date)] = CheckInSummary(
                count: count,
                seconds: seconds
            )
        }
        return result
    }
}
