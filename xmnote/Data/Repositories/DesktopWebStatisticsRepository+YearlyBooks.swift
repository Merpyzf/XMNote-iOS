/**
 * [INPUT]: 依赖 DesktopWebStatisticsRepository、DesktopWebBookRepository 完整投影与 V44 完读事件表
 * [OUTPUT]: 提供 Android yearly-books 的轻量书籍快照、最新完读时间和年份范围
 * [POS]: Data 层网页统计仓储年度书单扩展；复用 Web 书籍聚合但不读取详情大字段到 HTTP 合同
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated extension DesktopWebStatisticsRepository {
    /// 合并历史与当前完读事件，按最新完读时间倒序投影年度书单。
    func yearlyBooks(year: Int) async throws -> (year: Int, books: [DesktopWebYearlyBookSnapshot], years: [Int]) {
        let range = try yearRange(year)
        let doneRows: [(bookID: Int64, doneTime: Int64)] = try await database.dbPool.read { db in
            // SQL 目的：复刻 WebBookDao.queryYearlyBooks 的 UNION、MAX 和排序。
            // 涉及表：book_read_status_record、book；历史和当前快照均要求 READ_DONE=3 且时间在年度闭区间。
            // 关键过滤：最终书籍有效、非占位、doneTime>0；同书取范围内最新完读时间。
            // 时间字段：changed_date/read_status_changed_date 毫秒值原样返回。
            // 返回字段用途：年度书单顺序及 readDoneTime/readStatusChangedTime 覆盖值。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT b.id AS book_id, MAX(done.done_time) AS done_time
                    FROM (
                        SELECT book_id, changed_date AS done_time
                        FROM book_read_status_record
                        WHERE is_deleted = 0 AND read_status_id = 3
                          AND changed_date BETWEEN ? AND ?
                        UNION ALL
                        SELECT id AS book_id, read_status_changed_date AS done_time
                        FROM book
                        WHERE is_deleted = 0 AND id != 0 AND read_status_id = 3
                          AND read_status_changed_date BETWEEN ? AND ?
                    ) done
                    JOIN book b ON b.id = done.book_id
                    WHERE b.is_deleted = 0 AND b.id != 0 AND done.done_time > 0
                    GROUP BY b.id
                    ORDER BY done_time DESC, b.id DESC
                    """,
                arguments: [range.lowerBound, range.upperBound, range.lowerBound, range.upperBound]
            ).map { ($0["book_id"], $0["done_time"]) }
        }
        guard !doneRows.isEmpty else {
            return (year, [], try await statisticsYears())
        }
        let ids = doneRows.map(\.bookID)
        let records: [BookRecord] = try await database.dbPool.read { db in
            // SQL 目的：按年度完读 ID 批量读取有效书籍主记录。
            // 涉及表：book；不在此读取 summary/catalog 等 HTTP 不需要字段以外的关联表。
            // 返回字段用途：交由共享 WebBookDto 投影补齐来源、标签、分组和统计计数。
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return try BookRecord.fetchAll(
                db,
                sql: "SELECT * FROM book WHERE is_deleted = 0 AND id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
        let projected = try await bookRepository.projection.projectBookSnapshots(records)
        let byID = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
        let books = doneRows.compactMap { row in
            byID[row.bookID].map { DesktopWebYearlyBookSnapshot(book: $0, readDoneTime: row.doneTime) }
        }
        return (year, books, try await statisticsYears())
    }
}
