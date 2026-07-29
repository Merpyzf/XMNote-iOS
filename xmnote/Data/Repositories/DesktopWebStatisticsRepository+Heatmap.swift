/**
 * [INPUT]: 依赖 DesktopWebStatisticsRepository 的日期/阅读记录能力与 V44 note、check_in_record、book_read_status_record 表
 * [OUTPUT]: 提供 Android 全量/年度热力图及年份范围快照
 * [POS]: Data 层网页统计仓储热力图扩展；保留完整自然日、状态标记和等级阈值
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated struct DesktopWebHeatmapSnapshot: Sendable, Equatable {
    struct Day: Sendable, Equatable {
        let date: String
        let readTime: Int
        let noteCount: Int
        let checkInTime: Int
        let bookStates: [Bool]
        let level: Int
    }

    let days: [Day]
    let startDate: String
    let endDate: String
    let yearRange: [Int]
    let earliestDate: String?
    let latestDate: String?
}

nonisolated extension DesktopWebStatisticsRepository {
    /// 聚合阅读时长、书摘、打卡和阅读状态；type 未知时按 Android 回退到三类最高等级。
    func heatmap(year: Int, type: String) async throws -> DesktopWebHeatmapSnapshot {
        let range: ClosedRange<Int64>
        if year == 0 {
            let start = try await heatmapStartTimestamp()
            range = start...currentTimeMillis()
        } else {
            range = try heatmapYearRange(year)
        }
        let startDate = calendar.startOfDay(
            for: Date(timeIntervalSince1970: Double(range.lowerBound) / 1_000)
        )
        let endDate = calendar.startOfDay(
            for: Date(timeIntervalSince1970: Double(range.upperBound) / 1_000)
        )
        var values: [Date: (read: Int, note: Int, checkIn: Int, states: [Bool])] = [:]
        var day = startDate
        while day <= endDate {
            values[day] = (0, 0, 0, Array(repeating: false, count: 5))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let records = try await rawReadRecords()
        for record in records where range ~= record.eventTime {
            let key = calendar.startOfDay(
                for: Date(timeIntervalSince1970: Double(record.eventTime) / 1_000)
            )
            if var value = values[key] {
                value.read += Int(record.elapsedSeconds)
                values[key] = value
            }
        }

        let databaseRows = try await heatmapDatabaseRows(range: range)
        for millis in databaseRows.notes {
            let key = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(millis) / 1_000))
            if var value = values[key] {
                value.note += 1
                values[key] = value
            }
        }
        for item in databaseRows.checkIns {
            let key = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(item.time) / 1_000))
            if var value = values[key] {
                value.checkIn += item.amount * 20 * 60
                values[key] = value
            }
        }
        for item in databaseRows.statuses where (1...5).contains(item.status) {
            let key = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(item.time) / 1_000))
            if var value = values[key] {
                let index = item.status == 5 ? 3 : (item.status == 4 ? 4 : item.status - 1)
                value.states[index] = true
                values[key] = value
            }
        }
        // NOTE(ANDROID-WEB-068): bookStates 受 Android App 私有偏好控制；仅数据库一致不足以保证两端响应一致。

        let days = values.keys.sorted(by: >).map { date -> DesktopWebHeatmapSnapshot.Day in
            let value = values[date]!
            let noteLevel = heatLevel(value.note, thresholds: (5, 10, 20))
            let readLevel = heatLevel(value.read, thresholds: (1_200, 2_400, 3_600))
            let checkInLevel = heatLevel(value.checkIn, thresholds: (1_200, 2_400, 3_600))
            let level: Int
            switch type {
            case "reading_time": level = readLevel
            case "note_count": level = noteLevel
            case "check_in": level = checkInLevel
            default: level = max(noteLevel, readLevel, checkInLevel)
            }
            return .init(
                date: dateString(date), readTime: value.read, noteCount: value.note,
                checkInTime: value.checkIn, bookStates: value.states, level: level
            )
        }
        let earliest = try await earliestStatisticsTimestamp()
        let now = currentTimeMillis()
        return DesktopWebHeatmapSnapshot(
            days: days,
            startDate: dateString(startDate),
            endDate: dateString(endDate),
            yearRange: try await statisticsYears(),
            earliestDate: dateString(Date(timeIntervalSince1970: Double(earliest) / 1_000)),
            latestDate: dateString(Date(timeIntervalSince1970: Double(now) / 1_000))
        )
    }

    /// 生成 Android getYearRange 的升序年份列表；没有任何统计事件时只返回当前年。
    func statisticsYears() async throws -> [Int] {
        let earliest = try await database.dbPool.read { db -> Int64? in
            // SQL 目的：合并年度统计涉及的完读、书籍、书摘、计时、购入和打卡最早时间。
            // 涉及表：book、book_read_status_record、note、read_time_record、check_in_record。
            // 关键过滤：书籍/书摘/计时按各自 Android DAO 过滤；打卡最早时间故意不筛软删除。
            // 返回字段用途：生成 oldestYear...currentYear。
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT MIN(value) FROM (
                        SELECT MIN(r.changed_date) AS value
                        FROM book_read_status_record r
                        JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                        WHERE r.is_deleted = 0 AND r.read_status_id = 3 AND r.changed_date > 0
                        UNION ALL SELECT MIN(read_status_changed_date) FROM book
                            WHERE is_deleted = 0 AND id != 0 AND read_status_id = 3 AND read_status_changed_date > 0
                        UNION ALL SELECT MIN(created_date) FROM book WHERE is_deleted = 0 AND id != 0 AND created_date > 0
                        UNION ALL SELECT MIN(read_status_changed_date) FROM book WHERE is_deleted = 0 AND id != 0 AND read_status_changed_date > 0
                        UNION ALL SELECT MIN(n.created_date) FROM note n JOIN book b ON b.id = n.book_id
                            WHERE n.is_deleted = 0 AND b.is_deleted = 0 AND n.created_date > 0
                        UNION ALL SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
                            FROM read_time_record WHERE is_deleted = 0 AND status = 3 AND book_id != 0
                        UNION ALL SELECT MIN(purchase_date) FROM book WHERE is_deleted = 0 AND id != 0 AND purchase_date > 0
                        UNION ALL SELECT MIN(checkin_date) FROM check_in_record
                            WHERE is_deleted = 0
                    ) WHERE value > 0
                    """
            )
        }
        let currentYear = dateComponent(.year, millis: currentTimeMillis())
        guard let earliest else { return [currentYear] }
        let firstYear = dateComponent(.year, millis: earliest)
        return firstYear <= currentYear ? Array(firstYear...currentYear) : []
    }
}

private nonisolated extension DesktopWebStatisticsRepository {
    struct HeatmapDatabaseRows: Sendable {
        struct CheckIn: Sendable { let time: Int64; let amount: Int }
        struct Status: Sendable { let time: Int64; let status: Int }
        let notes: [Int64]
        let checkIns: [CheckIn]
        let statuses: [Status]
    }

    func heatmapStartTimestamp() async throws -> Int64 {
        try await database.dbPool.read { db in
            // SQL 目的：复刻三类热力图起点的最小值，而非更宽泛的统计起点。
            // 涉及表：note、read_time_record、check_in_record、book_read_status_record、book。
            // 关键过滤：状态记录只消费仍存在的书籍；打卡最早 DAO 故意不筛删除。
            // 返回字段用途：year=0 热力图 startDate；无数据时回退当前时间。
            let value = try Int64.fetchOne(
                db,
                sql: """
                    SELECT MIN(value) FROM (
                        SELECT MIN(n.created_date) AS value FROM note n JOIN book b ON b.id = n.book_id
                            WHERE n.is_deleted = 0 AND b.is_deleted = 0 AND n.created_date > 0
                        UNION ALL SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
                            FROM read_time_record WHERE is_deleted = 0 AND status = 3 AND book_id != 0
                        UNION ALL SELECT MIN(checkin_date) FROM check_in_record
                            WHERE is_deleted = 0
                        UNION ALL SELECT MIN(r.changed_date) FROM book_read_status_record r
                            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                            WHERE r.is_deleted = 0 AND r.changed_date > 0
                    ) WHERE value > 0
                    """
            )
            return value ?? currentTimeMillis()
        }
    }

    func heatmapDatabaseRows(range: ClosedRange<Int64>) async throws -> HeatmapDatabaseRows {
        try await database.dbPool.read { db in
            // SQL 目的：读取热力图的书摘、打卡与书籍状态事件。
            // 涉及表：note/book、check_in_record、book_read_status_record/book。
            // 关键过滤：事件落在闭区间；note/status 关联有效书籍，check_in 对齐 DAO 仅筛自身删除态。
            // 时间字段：created_date/checkin_date/changed_date 均为毫秒。
            // 返回字段用途：按本地自然日聚合计数、20 分钟打卡量与五态布尔标记。
            let notes = try Int64.fetchAll(
                db,
                sql: """
                    SELECT n.created_date FROM note n JOIN book b ON b.id = n.book_id
                    WHERE n.is_deleted = 0 AND b.is_deleted = 0 AND n.created_date BETWEEN ? AND ?
                    """,
                arguments: [range.lowerBound, range.upperBound]
            )
            let checkIns = try Row.fetchAll(
                db,
                sql: "SELECT checkin_date, amount FROM check_in_record WHERE is_deleted = 0 AND checkin_date BETWEEN ? AND ?",
                arguments: [range.lowerBound, range.upperBound]
            ).map { HeatmapDatabaseRows.CheckIn(time: $0["checkin_date"], amount: Int($0["amount"] as Int64)) }
            let statuses = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.changed_date, r.read_status_id
                    FROM book_read_status_record r
                    JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                    WHERE r.is_deleted = 0 AND r.changed_date BETWEEN ? AND ?
                    """,
                arguments: [range.lowerBound, range.upperBound]
            ).map { HeatmapDatabaseRows.Status(time: $0["changed_date"], status: Int($0["read_status_id"] as Int64)) }
            return HeatmapDatabaseRows(notes: notes, checkIns: checkIns, statuses: statuses)
        }
    }

    func heatLevel(_ value: Int, thresholds: (Int, Int, Int)) -> Int {
        switch value {
        case 0: 0
        case ...thresholds.0: 1
        case ...thresholds.1: 2
        case ...thresholds.2: 3
        default: 4
        }
    }
}
