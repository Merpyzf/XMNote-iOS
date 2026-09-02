import Foundation
import GRDB

/**
 * [INPUT]: 依赖 GRDB Database 与 book、note、read_status、source、read_time_record、tag_book 等表
 * [OUTPUT]: 对外提供 BookshelfBookAggregateQuery 与 BookshelfBookAggregateRow，生成首页书架多维度聚合所需的全量书籍行
 * [POS]: Data 层首页书架只读聚合查询协作者，隔离 BookRepository 中的全量书籍 SQL 映射逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 首页书架聚合查询的单书行，统一承载排序、分区、角标和列表辅助文案。
nonisolated struct BookshelfBookAggregateRow {
    let payload: BookshelfBookPayload
    let press: String
    let pubDateText: String
    let readStatusOrder: Int64
    let sourceOrder: Int64
    let sourceBookshelfOrder: Int64
    let sourceIsHidden: Bool
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
    let createdDate: Int64
    let modifiedDate: Int64
    let publishDate: Int64
    let readDoneDate: Int64
    let totalReadingTime: Int64
    let readingProgress: Double?
    let readingProgressText: String
    let bookmarkText: String
    let readStatusBadgeTitle: String
    let tags: [BookshelfBookListTag]
}

extension BookshelfBookAggregateRow {
    nonisolated var listItem: BookshelfBookListItem {
        BookshelfBookListItem(
            payload: payload,
            pinned: pinned,
            pubDateText: pubDateText,
            tags: tags,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            readDoneDate: readDoneDate,
            totalReadingTime: totalReadingTime,
            readingProgressText: readingProgressText,
            bookmarkText: bookmarkText,
            readStatusBadgeTitle: readStatusBadgeTitle
        )
    }

    nonisolated var bookshelfItem: BookshelfItem {
        BookshelfItem(
            id: .book(payload.id),
            pinned: pinned,
            pinOrder: pinOrder,
            sortOrder: sortOrder,
            sortMetadata: sortMetadata,
            bookListItem: listItem,
            content: .book(payload)
        )
    }

    nonisolated var sortMetadata: BookshelfItemSortMetadata {
        BookshelfItemSortMetadata(
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            publishDate: publishDate,
            noteCount: payload.noteCount,
            rating: payload.score,
            readDoneDate: readDoneDate,
            totalReadingTime: totalReadingTime,
            readingProgress: readingProgress,
            bookCount: 1
        )
    }
}

/// 首页书架标签聚合行，供标签维度与二级列表过滤复用。
nonisolated struct BookshelfTagInfo: Hashable {
    let id: Int64
    let name: String
    let order: Int64
}

/// 读取首页书架聚合需要的全量书籍行，保持查询与 UI 快照装配分离。
nonisolated enum BookshelfBookAggregateQuery {
    /// 查询所有有效书籍，作为非默认维度聚合的统一数据源。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchAllRows(_ db: Database) throws -> [BookshelfBookAggregateRow] {
        let tagsByBook = try fetchTagsByBook(db)
        let readDoneDatesByBook = try fetchLatestReadDoneDates(db)
        let readDoneCountsByBook = try fetchReadDoneCounts(db)
        let latestActivityDatesByBook = try fetchLatestActivityDates(db)

        // SQL 目的：读取所有有效书籍并补齐阅读状态、来源、评分、置顶排序、有效书摘数量、阅读时长与条件排序字段，供多维度聚合和二级列表复用。
        // 涉及表：book b；LEFT JOIN note n 统计有效书摘；LEFT JOIN read_status rs/source s 读取维度标题与排序字段；LEFT JOIN read_time_record 聚合已完成阅读秒数。
        // 关键过滤：b.is_deleted = 0、b.id != 0；n.is_deleted = 0；read_time_record.status = 3；rs/s 仅连接未软删除记录。
        // 时间字段单位：Android Room 表统一保存毫秒时间戳；read_time_record.elapsed_seconds 是秒，用于阅读时长展示。
        // 返回字段用途：Book payload 用于 UI 代表封面，order/pin/source/read_status 与创建、修改、出版、读完、阅读进度字段用于 Swift 层稳定聚合和二级列表排序。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.press, b.pub_date,
                   b.read_status_id,
                   COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(rs.read_status_order, 999999) AS read_status_order,
                   b.source_id,
                   COALESCE(s.name, '') AS source_name,
                   COALESCE(s.source_order, 999999) AS source_order,
                   COALESCE(s.bookshelf_order, 999999) AS source_bookshelf_order,
                   COALESCE(s.is_hide, 1) AS source_is_hide,
                   b.score, b.pinned, b.pin_order, b.book_order,
                   b.created_date, b.updated_date, b.read_status_changed_date, b.book_mark_modified_time,
                   b.read_position, b.current_position_unit, b.total_position, b.total_pagination,
                   COALESCE(rt.total_reading_time, 0) AS total_reading_time,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON n.book_id = b.id AND n.is_deleted = 0
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            LEFT JOIN (
                SELECT book_id, SUM(elapsed_seconds) AS total_reading_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND status = 3
                  AND book_id != 0
                GROUP BY book_id
            ) rt ON rt.book_id = b.id
            WHERE b.is_deleted = 0
              AND b.id != 0
            GROUP BY b.id
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let bookID: Int64 = row["id"]
            let readStatusID: Int64 = row["read_status_id"] ?? 0
            let readStatusName: String = row["read_status_name"] ?? ""
            let rawPubDate: String = row["pub_date"] ?? ""
            let readPosition: Double = row["read_position"] ?? 0.0
            let currentPositionUnit: Int64 = row["current_position_unit"] ?? 2
            let totalPosition: Int64 = row["total_position"] ?? 0
            let totalPagination: Int64 = row["total_pagination"] ?? 0
            let createdDate: Int64 = row["created_date"] ?? 0
            let updatedDate: Int64 = row["updated_date"] ?? 0
            let readStatusChangedDate: Int64 = row["read_status_changed_date"] ?? 0
            let bookmarkModifiedDate: Int64 = row["book_mark_modified_time"] ?? 0
            let readDoneDate = BookshelfBookPresentationFormatter.resolvedReadDoneDate(
                readStatusID: readStatusID,
                statusChangedDate: readStatusChangedDate,
                latestReadDoneDate: readDoneDatesByBook[bookID] ?? 0
            )
            let latestActivityDate = max(
                latestActivityDatesByBook[bookID] ?? 0,
                createdDate,
                updatedDate,
                readStatusChangedDate,
                bookmarkModifiedDate
            )
            let progress = BookshelfBookPresentationFormatter.readingProgress(
                readPosition: readPosition,
                currentPositionUnit: currentPositionUnit,
                totalPosition: totalPosition,
                totalPagination: totalPagination
            )
            let payload = BookshelfBookPayload(
                id: bookID,
                name: row["name"] ?? "",
                author: row["author"] ?? "",
                cover: row["cover"] ?? "",
                readStatusId: readStatusID,
                readStatusName: readStatusName,
                sourceId: row["source_id"] ?? 0,
                sourceName: row["source_name"] ?? "",
                press: row["press"] ?? "",
                score: row["score"] ?? 0,
                noteCount: row["note_count"] ?? 0
            )
            return BookshelfBookAggregateRow(
                payload: payload,
                press: row["press"] ?? "",
                pubDateText: BookshelfBookPresentationFormatter.normalizedPubDateText(from: rawPubDate),
                readStatusOrder: row["read_status_order"] ?? 999999,
                sourceOrder: row["source_order"] ?? 999999,
                sourceBookshelfOrder: row["source_bookshelf_order"] ?? 999999,
                sourceIsHidden: (row["source_is_hide"] as Int64? ?? 1) != 0,
                pinned: (row["pinned"] as Int64? ?? 0) != 0,
                pinOrder: row["pin_order"] ?? 0,
                sortOrder: row["book_order"] ?? 0,
                createdDate: createdDate,
                modifiedDate: latestActivityDate,
                publishDate: BookshelfBookPresentationFormatter.publishTimestamp(from: rawPubDate),
                readDoneDate: readDoneDate,
                totalReadingTime: row["total_reading_time"] ?? 0,
                readingProgress: progress,
                readingProgressText: BookshelfBookPresentationFormatter.readingProgressText(from: progress),
                bookmarkText: BookshelfBookPresentationFormatter.bookmarkText(
                    readPosition: readPosition,
                    currentPositionUnit: currentPositionUnit
                ),
                readStatusBadgeTitle: BookshelfBookPresentationFormatter.readStatusBadgeTitle(
                    readStatusID: readStatusID,
                    readStatusName: readStatusName,
                    readDoneCount: readDoneCountsByBook[bookID] ?? 0
                ),
                tags: (tagsByBook[bookID] ?? []).map {
                    BookshelfBookListTag(id: $0.id, name: $0.name, order: $0.order)
                }
            )
        }
    }

    /// 查询有效书籍标签关系，供标签维度构建聚合卡。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchTagsByBook(_ db: Database) throws -> [Int64: [BookshelfTagInfo]] {
        // SQL 目的：读取书籍标签关系，供首页标签维度按书籍聚合。
        // 涉及表：tag_book tb JOIN tag t。
        // 关键过滤：tb.is_deleted = 0、t.is_deleted = 0、t.type = 2（书籍标签）。
        // 返回字段用途：book_id 用于归并，tag_order 用于标签卡排序。
        let sql = """
            SELECT tb.book_id, t.id AS tag_id, COALESCE(t.name, '') AS tag_name, t.tag_order
            FROM tag_book tb
            JOIN tag t ON t.id = tb.tag_id
            WHERE tb.is_deleted = 0
              AND t.is_deleted = 0
              AND t.type = 2
            ORDER BY t.tag_order ASC, t.id ASC
            """
        var result: [Int64: [BookshelfTagInfo]] = [:]
        for row in try Row.fetchAll(db, sql: sql) {
            let bookID: Int64 = row["book_id"]
            let tagName: String = row["tag_name"] ?? ""
            let info = BookshelfTagInfo(
                id: row["tag_id"],
                name: tagName.isEmpty ? "未命名标签" : tagName,
                order: row["tag_order"] ?? 0
            )
            result[bookID, default: []].append(info)
        }
        return result
    }

    /// 查询每本书最近一次“读完”状态记录，供读完时间排序与列表辅助文案对齐 Android。
    /// - Throws: 数据库查询失败时抛出错误。
    private static func fetchLatestReadDoneDates(_ db: Database) throws -> [Int64: Int64] {
        // SQL 目的：按书籍聚合最近一次读完时间，优先于 book.read_status_changed_date 作为 Android `readDoneTime` 来源。
        // 涉及表：book_read_status_record。
        // 关键过滤：仅统计未软删除、book_id 非占位、read_status_id = 3（读完）的状态记录。
        // 时间字段单位：changed_date 为毫秒时间戳，直接返回给列表排序和日期格式化。
        // 返回字段用途：book_id 用于归并到 BookshelfBookAggregateRow，latest_read_done_date 用于读完时间排序与“未读完”兜底判断。
        let sql = """
            SELECT book_id, MAX(changed_date) AS latest_read_done_date
            FROM book_read_status_record
            WHERE is_deleted = 0
              AND book_id != 0
              AND read_status_id = ?
            GROUP BY book_id
            """
        var result: [Int64: Int64] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: [BookEntryReadingStatus.finished.rawValue]) {
            let bookID: Int64 = row["book_id"]
            result[bookID] = row["latest_read_done_date"] ?? 0
        }
        return result
    }

    /// 查询每本书历史读完次数，供阅读状态角标显示“N 刷 / N+1 刷中”。
    /// - Throws: 数据库查询失败时抛出错误。
    private static func fetchReadDoneCounts(_ db: Database) throws -> [Int64: Int64] {
        // SQL 目的：按书籍统计有效读完状态记录数，对齐 Android `batchQueryReadDoneCountOfBookSuspend`。
        // 涉及表：book_read_status_record。
        // 关键过滤：仅统计未软删除、book_id 非占位、read_status_id = 3（读完）的状态记录。
        // 时间字段单位：本查询不返回时间字段，仅返回计数。
        // 返回字段用途：read_done_count 用于构造列表封面阅读状态角标标题。
        let sql = """
            SELECT book_id, COUNT(*) AS read_done_count
            FROM book_read_status_record
            WHERE is_deleted = 0
              AND book_id != 0
              AND read_status_id = ?
            GROUP BY book_id
            """
        var result: [Int64: Int64] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: [BookEntryReadingStatus.finished.rawValue]) {
            let bookID: Int64 = row["book_id"]
            result[bookID] = row["read_done_count"] ?? 0
        }
        return result
    }

    /// 聚合 Android “最近修改”排序的关联活动时间。
    /// - Throws: 数据库查询失败时抛出错误。
    private static func fetchLatestActivityDates(_ db: Database) throws -> [Int64: Int64] {
        // SQL 目的：对齐 Android BookRepository.getAllDetailedBookList 的最近活动时间来源，按 book_id 汇总书摘、分类内容、书评、计时、打卡与书签更新时间。
        // 涉及表：note、category_content、review、read_time_record、check_in_record、book；各子查询通过 book_id 或 book.id 归并。
        // 关键过滤：book 子查询限定有效非占位书籍；其余子查询与 Android 当前 DAO 保持一致，不额外过滤 is_deleted，仅排除 book_id = 0。
        // 时间字段单位：所有 created_date/updated_date/book_mark_modified_time 均为毫秒时间戳；read_time_record 对齐 Android 使用 created_date。
        // 返回字段用途：latest_activity_date 用于二级列表修改时间排序、分区与 Item 辅助时间。
        let sql = """
            SELECT book_id, MAX(latest_at) AS latest_activity_date
            FROM (
                SELECT book_id,
                       MAX(CASE WHEN created_date > updated_date THEN created_date ELSE updated_date END) AS latest_at
                FROM note
                WHERE book_id != 0
                GROUP BY book_id
                UNION ALL
                SELECT book_id,
                       MAX(CASE WHEN created_date > updated_date THEN created_date ELSE updated_date END) AS latest_at
                FROM category_content
                WHERE book_id != 0
                GROUP BY book_id
                UNION ALL
                SELECT book_id,
                       MAX(CASE WHEN created_date > updated_date THEN created_date ELSE updated_date END) AS latest_at
                FROM review
                WHERE book_id != 0
                GROUP BY book_id
                UNION ALL
                SELECT book_id, MAX(created_date) AS latest_at
                FROM read_time_record
                WHERE book_id != 0
                GROUP BY book_id
                UNION ALL
                SELECT book_id,
                       MAX(CASE WHEN created_date > updated_date THEN created_date ELSE updated_date END) AS latest_at
                FROM check_in_record
                WHERE book_id != 0
                GROUP BY book_id
                UNION ALL
                SELECT id AS book_id, MAX(book_mark_modified_time) AS latest_at
                FROM book
                WHERE is_deleted = 0
                  AND id != 0
                  AND book_mark_modified_time != 0
                GROUP BY id
            )
            WHERE latest_at IS NOT NULL
            GROUP BY book_id
            """
        var result: [Int64: Int64] = [:]
        for row in try Row.fetchAll(db, sql: sql) {
            let bookID: Int64 = row["book_id"]
            result[bookID] = row["latest_activity_date"] ?? 0
        }
        return result
    }
}
