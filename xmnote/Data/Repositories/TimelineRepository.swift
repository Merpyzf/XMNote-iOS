import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 TimelineEvent/TimelineSection/TimelineDayMarker 领域模型
 * [OUTPUT]: 对外提供 TimelineRepository（TimelineRepositoryProtocol 的 GRDB 实现，6 路事件查询 + 日历标记聚合）
 * [POS]: Data 层时间线仓储实现，对齐 Android TimelineRepository.getTimelineDataList 与 getCalendarSchemeData
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 时间线仓储实现，负责事件查询与日历标记聚合。
nonisolated struct TimelineRepository: TimelineRepositoryProtocol {
    private let databaseManager: DatabaseManager

    /// 注入数据库管理器，为时间线事件查询与日历标记聚合提供数据源。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    /// 查询指定毫秒时间戳范围内的事件列表，按分类过滤后按时间降序排列并按日分组。
    /// 对齐 Android TimelineRepository.getTimelineDataList：6 路独立查询 → Swift 侧合并排序分组。
    nonisolated func fetchTimelineEvents(
        startTimestamp: Int64,
        endTimestamp: Int64,
        category: TimelineEventCategory
    ) async throws -> [TimelineSection] {
        try await databaseManager.database.dbPool.read { db in
            try buildTimelineEvents(db, start: startTimestamp, end: endTimestamp, category: category)
        }
    }

    /// 聚合指定月份的日历标记（活跃天 + 阅读时长进度），供日历 cell 渲染。
    /// 日历标记始终按整月查询，不受时间范围设置影响。
    nonisolated func fetchCalendarMarkers(
        for monthStart: Date,
        category: TimelineEventCategory
    ) async throws -> [Date: TimelineDayMarker] {
        try await databaseManager.database.dbPool.read { db in
            try buildCalendarMarkers(db, monthStart: monthStart, category: category)
        }
    }
}

// MARK: - 共享格式化器

private extension TimelineRepository {
    nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}

// MARK: - 事件查询

private extension TimelineRepository {
    /// 按分类路由到 6 个事件查询方法，合并后按时间降序排列并按日分组。
    nonisolated func buildTimelineEvents(
        _ db: Database,
        start: Int64,
        end: Int64,
        category: TimelineEventCategory
    ) throws -> [TimelineSection] {
        var allEvents: [TimelineEvent] = []

        switch category {
        case .all:
            allEvents += try queryNoteEvents(db, start: start, end: end)
            allEvents += try queryReadTimingEvents(db, start: start, end: end)
            allEvents += try queryReadStatusEvents(db, start: start, end: end)
            allEvents += try queryRelevantEvents(db, start: start, end: end)
            allEvents += try queryReviewEvents(db, start: start, end: end)
            allEvents += try queryCheckInEvents(db, start: start, end: end)
        case .note:
            allEvents = try queryNoteEvents(db, start: start, end: end)
        case .readTiming:
            allEvents = try queryReadTimingEvents(db, start: start, end: end)
        case .readStatus:
            allEvents = try queryReadStatusEvents(db, start: start, end: end)
        case .relevant:
            allEvents = try queryRelevantEvents(db, start: start, end: end)
        case .review:
            allEvents = try queryReviewEvents(db, start: start, end: end)
        case .checkIn:
            allEvents = try queryCheckInEvents(db, start: start, end: end)
        }

        allEvents.sort { $0.timestamp > $1.timestamp }
        return groupByDay(allEvents)
    }

    // MARK: 书摘

    /// 查询指定时间范围内的书摘事件，并批量关联 attach_image 附图。
    /// 表: note JOIN book | 时间字段: note.created_date | 过滤: is_deleted=0
    /// 附图表: attach_image | 外键: note_id | 排序: id ASC
    nonisolated func queryNoteEvents(_ db: Database, start: Int64, end: Int64) throws -> [TimelineEvent] {
        let sql = """
            SELECT n.id, n.content, n.idea, n.created_date,
                   b.name, b.author, b.cover
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            WHERE n.is_deleted = 0 AND n.created_date BETWEEN ? AND ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])

        // 批量查询书摘附图。表: attach_image | 过滤: is_deleted=0, note_id IN (...) | 排序: id ASC
        let noteIds = rows.map { $0["id"] as Int64 }
        let imageMap = try batchFetchImages(
            db, table: "attach_image", foreignKey: "note_id",
            imageColumn: "image_url", ids: noteIds,
            orderClause: "id ASC"
        )

        return rows.map { row in
            let noteId = row["id"] as Int64
            return TimelineEvent(
                id: "note-\(noteId)",
                kind: .note(TimelineNoteEvent(
                    content: row["content"] as String? ?? "",
                    idea: row["idea"] as String? ?? "",
                    bookTitle: row["name"] as String? ?? "",
                    imageURLs: imageMap[noteId] ?? []
                )),
                timestamp: row["created_date"] as Int64,
                bookName: row["name"] as String? ?? "",
                bookAuthor: row["author"] as String? ?? "",
                bookCover: row["cover"] as String? ?? ""
            )
        }
    }

    // MARK: 阅读计时

    /// 查询指定时间范围内的阅读计时事件。
    /// 表: read_time_record JOIN book | 时间字段: CASE WHEN fuzzy_read_date!=0 THEN fuzzy_read_date ELSE start_time END
    /// 过滤: status=3（已完成）, is_deleted=0
    nonisolated func queryReadTimingEvents(_ db: Database, start: Int64, end: Int64) throws -> [TimelineEvent] {
        let sql = """
            SELECT r.id, r.start_time, r.end_time, r.elapsed_seconds, r.fuzzy_read_date,
                   b.name, b.author, b.cover
            FROM read_time_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0 AND r.status = 3
              AND (CASE WHEN r.fuzzy_read_date != 0 THEN r.fuzzy_read_date ELSE r.start_time END)
                  BETWEEN ? AND ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])
        return rows.map { row in
            let fuzzy = row["fuzzy_read_date"] as Int64
            let startTime = row["start_time"] as Int64
            let effectiveTimestamp = fuzzy != 0 ? fuzzy : startTime
            return TimelineEvent(
                id: "timing-\(row["id"] as Int64)",
                kind: .readTiming(TimelineReadTimingEvent(
                    elapsedSeconds: row["elapsed_seconds"] as Int64,
                    startTime: startTime,
                    endTime: row["end_time"] as Int64,
                    fuzzyReadDate: fuzzy
                )),
                timestamp: effectiveTimestamp,
                bookName: row["name"] as String? ?? "",
                bookAuthor: row["author"] as String? ?? "",
                bookCover: row["cover"] as String? ?? ""
            )
        }
    }

    // MARK: 阅读状态变更

    /// 查询指定时间范围内的阅读状态变更事件，并对每条记录子查询累计读完次数。
    /// 表: book_read_status_record JOIN book | 时间字段: changed_date | 过滤: is_deleted=0
    nonisolated func queryReadStatusEvents(_ db: Database, start: Int64, end: Int64) throws -> [TimelineEvent] {
        let sql = """
            SELECT s.id, s.read_status_id, s.changed_date, s.book_id,
                   b.name, b.author, b.cover, b.score
            FROM book_read_status_record s
            JOIN book b ON b.id = s.book_id AND b.is_deleted = 0
            WHERE s.is_deleted = 0 AND s.changed_date BETWEEN ? AND ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])

        let countSQL = """
            SELECT COUNT(*) FROM book_read_status_record
            WHERE is_deleted = 0 AND book_id = ? AND read_status_id = 3 AND changed_date <= ?
            """

        return try rows.map { row in
            let bookId = row["book_id"] as Int64
            let changedDate = row["changed_date"] as Int64
            let readDoneCount = try Int64.fetchOne(db, sql: countSQL, arguments: [bookId, changedDate]) ?? 0

            return TimelineEvent(
                id: "status-\(row["id"] as Int64)",
                kind: .readStatus(TimelineReadStatusEvent(
                    statusId: row["read_status_id"] as Int64,
                    readDoneCount: readDoneCount,
                    bookScore: row["score"] as Int64? ?? 0
                )),
                timestamp: changedDate,
                bookName: row["name"] as String? ?? "",
                bookAuthor: row["author"] as String? ?? "",
                bookCover: row["cover"] as String? ?? ""
            )
        }
    }

    // MARK: 相关内容

    /// 查询指定时间范围内的相关内容事件，content_book_id != 0 时映射为 .relevantBook。
    /// 表: category_content JOIN book LEFT JOIN category | 时间字段: created_date | 过滤: is_deleted=0
    /// 附图表: category_image | 外键: category_content_id | 排序: order ASC, id ASC
    nonisolated func queryRelevantEvents(_ db: Database, start: Int64, end: Int64) throws -> [TimelineEvent] {
        let sql = """
            SELECT cc.id, cc.title, cc.content, cc.url, cc.content_book_id, cc.created_date,
                   b.name, b.author, b.cover, cat.title AS category_title
            FROM category_content cc
            JOIN book b ON b.id = cc.book_id AND b.is_deleted = 0
            LEFT JOIN category cat ON cat.id = cc.category_id
            WHERE cc.is_deleted = 0 AND cc.created_date BETWEEN ? AND ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])

        // 批量查询相关内容图片。表: category_image | 过滤: is_deleted=0, category_content_id IN (...) | 排序: order ASC, id ASC
        let contentIds = rows.map { $0["id"] as Int64 }
        let imageMap = try batchFetchImages(
            db, table: "category_image", foreignKey: "category_content_id",
            imageColumn: "image", ids: contentIds,
            orderClause: "\"order\" ASC, id ASC"
        )

        // content_book_id != 0 的记录需要查关联书籍
        var bookCache: [Int64: (name: String, author: String, cover: String)] = [:]

        return try rows.map { row in
            let ccId = row["id"] as Int64
            let contentBookId = row["content_book_id"] as Int64? ?? 0
            let catTitle = row["category_title"] as String? ?? ""

            if contentBookId != 0 {
                if bookCache[contentBookId] == nil {
                    let bookSQL = "SELECT name, author, cover FROM book WHERE id = ? AND is_deleted = 0"
                    if let bookRow = try Row.fetchOne(db, sql: bookSQL, arguments: [contentBookId]) {
                        bookCache[contentBookId] = (
                            name: bookRow["name"] as String? ?? "",
                            author: bookRow["author"] as String? ?? "",
                            cover: bookRow["cover"] as String? ?? ""
                        )
                    }
                }
                let contentBook = bookCache[contentBookId]
                return TimelineEvent(
                    id: "relevant-book-\(ccId)",
                    kind: .relevantBook(TimelineRelevantBookEvent(
                        contentBookName: contentBook?.name ?? "",
                        contentBookAuthor: contentBook?.author ?? "",
                        contentBookCover: contentBook?.cover ?? "",
                        categoryTitle: catTitle
                    )),
                    timestamp: row["created_date"] as Int64,
                    bookName: row["name"] as String? ?? "",
                    bookAuthor: row["author"] as String? ?? "",
                    bookCover: row["cover"] as String? ?? ""
                )
            }

            return TimelineEvent(
                id: "relevant-\(ccId)",
                kind: .relevant(TimelineRelevantEvent(
                    title: row["title"] as String? ?? "",
                    content: row["content"] as String? ?? "",
                    url: row["url"] as String? ?? "",
                    categoryTitle: catTitle,
                    imageURLs: imageMap[ccId] ?? []
                )),
                timestamp: row["created_date"] as Int64,
                bookName: row["name"] as String? ?? "",
                bookAuthor: row["author"] as String? ?? "",
                bookCover: row["cover"] as String? ?? ""
            )
        }
    }

    // MARK: 书评

    /// 查询指定时间范围内的书评事件，并批量关联 review_image 图片。
    /// 表: review JOIN book | 时间字段: created_date | 过滤: is_deleted=0
    /// 附图表: review_image | 外键: review_id | 排序: order ASC, id ASC
    nonisolated func queryReviewEvents(_ db: Database, start: Int64, end: Int64) throws -> [TimelineEvent] {
        let sql = """
            SELECT rv.id, rv.title, rv.content, rv.created_date,
                   b.name, b.author, b.cover, b.score
            FROM review rv
            JOIN book b ON b.id = rv.book_id AND b.is_deleted = 0
            WHERE rv.is_deleted = 0 AND rv.created_date BETWEEN ? AND ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])

        // 批量查询书评图片。表: review_image | 过滤: is_deleted=0, review_id IN (...) | 排序: order ASC, id ASC
        let reviewIds = rows.map { $0["id"] as Int64 }
        let imageMap = try batchFetchImages(
            db, table: "review_image", foreignKey: "review_id",
            imageColumn: "image", ids: reviewIds,
            orderClause: "\"order\" ASC, id ASC"
        )

        return rows.map { row in
            let reviewId = row["id"] as Int64
            return TimelineEvent(
                id: "review-\(reviewId)",
                kind: .review(TimelineReviewEvent(
                    title: row["title"] as String? ?? "",
                    content: row["content"] as String? ?? "",
                    bookScore: row["score"] as Int64? ?? 0,
                    imageURLs: imageMap[reviewId] ?? []
                )),
                timestamp: row["created_date"] as Int64,
                bookName: row["name"] as String? ?? "",
                bookAuthor: row["author"] as String? ?? "",
                bookCover: row["cover"] as String? ?? ""
            )
        }
    }

    // MARK: 打卡

    /// 查询指定时间范围内的打卡事件。
    /// 表: check_in_record JOIN book | 时间字段: checkin_date | 过滤: is_deleted=0, checkin_date!=0
    nonisolated func queryCheckInEvents(_ db: Database, start: Int64, end: Int64) throws -> [TimelineEvent] {
        let sql = """
            SELECT ci.id, ci.amount, ci.checkin_date,
                   b.name, b.author, b.cover
            FROM check_in_record ci
            JOIN book b ON b.id = ci.book_id AND b.is_deleted = 0
            WHERE ci.is_deleted = 0 AND ci.checkin_date != 0 AND ci.checkin_date BETWEEN ? AND ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])
        return rows.map { row in
            TimelineEvent(
                id: "checkin-\(row["id"] as Int64)",
                kind: .checkIn(TimelineCheckInEvent(amount: row["amount"] as Int64? ?? 1)),
                timestamp: row["checkin_date"] as Int64,
                bookName: row["name"] as String? ?? "",
                bookAuthor: row["author"] as String? ?? "",
                bookCover: row["cover"] as String? ?? ""
            )
        }
    }
}

// MARK: - 日历标记

private extension TimelineRepository {
    /// 聚合指定月份的活跃天与阅读进度，组装为日历标记字典。
    /// 活跃天 = 该分类在该日有事件记录；进度 = 当日阅读秒数 / 每日目标秒数。
    nonisolated func buildCalendarMarkers(
        _ db: Database,
        monthStart: Date,
        category: TimelineEventCategory
    ) throws -> [Date: TimelineDayMarker] {
        let (startMs, endMs) = monthMillisRange(for: monthStart)

        // 聚合活跃天
        var activeDays = Set<String>()
        switch category {
        case .all:
            activeDays.formUnion(try queryActiveDays(db, table: "note", dateColumn: "created_date", start: startMs, end: endMs))
            activeDays.formUnion(try queryTimingActiveDays(db, start: startMs, end: endMs))
            activeDays.formUnion(try queryActiveDays(db, table: "book_read_status_record", dateColumn: "changed_date", start: startMs, end: endMs))
            activeDays.formUnion(try queryActiveDays(db, table: "category_content", dateColumn: "created_date", start: startMs, end: endMs))
            activeDays.formUnion(try queryActiveDays(db, table: "review", dateColumn: "created_date", start: startMs, end: endMs))
            activeDays.formUnion(try queryCheckinActiveDays(db, start: startMs, end: endMs))
        case .note:
            activeDays = try queryActiveDays(db, table: "note", dateColumn: "created_date", start: startMs, end: endMs)
        case .readTiming:
            activeDays = try queryTimingActiveDays(db, start: startMs, end: endMs)
        case .readStatus:
            activeDays = try queryActiveDays(db, table: "book_read_status_record", dateColumn: "changed_date", start: startMs, end: endMs)
        case .relevant:
            activeDays = try queryActiveDays(db, table: "category_content", dateColumn: "created_date", start: startMs, end: endMs)
        case .review:
            activeDays = try queryActiveDays(db, table: "review", dateColumn: "created_date", start: startMs, end: endMs)
        case .checkIn:
            activeDays = try queryCheckinActiveDays(db, start: startMs, end: endMs)
        }

        // 聚合阅读时长（所有分类都需要，进度环独立于分类筛选）
        let readSeconds = try aggregateReadSeconds(db, start: startMs, end: endMs)

        // 每日阅读目标：默认 3600 秒（1 小时），对齐 Android read_target type=1
        let dailyGoalSeconds = 3600

        // 组装标记字典
        let calendar = Calendar.current
        var result: [Date: TimelineDayMarker] = [:]
        let formatter = Self.dayFormatter

        let allDayKeys = activeDays.union(Set(readSeconds.keys))
        for dayKey in allDayKeys {
            guard let date = formatter.date(from: dayKey) else { continue }
            let normalized = calendar.startOfDay(for: date)
            let isActive = activeDays.contains(dayKey)
            let seconds = readSeconds[dayKey] ?? 0
            let progress = dailyGoalSeconds > 0 ? min(100, Int(seconds * 100 / Int64(dailyGoalSeconds))) : 0
            result[normalized] = TimelineDayMarker(
                isActive: isActive || seconds > 0,
                readingProgress: progress
            )
        }

        return result
    }

    /// 通用活跃天查询：按日期列 GROUP BY 日期字符串。
    /// - Parameters:
    ///   - table: 事件表名
    ///   - dateColumn: 毫秒时间戳列名
    nonisolated func queryActiveDays(
        _ db: Database,
        table: String,
        dateColumn: String,
        start: Int64,
        end: Int64
    ) throws -> Set<String> {
        let sql = """
            SELECT DATE(\(dateColumn) / 1000, 'unixepoch', 'localtime') AS day
            FROM \(table)
            WHERE is_deleted = 0 AND \(dateColumn) BETWEEN ? AND ?
            GROUP BY day
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])
        return Set(rows.compactMap { $0["day"] as String? })
    }

    /// 阅读计时活跃天查询（分精确与模糊两路）。
    /// 精确: fuzzy_read_date=0 时用 start_time；模糊: fuzzy_read_date!=0 时用 fuzzy_read_date。
    nonisolated func queryTimingActiveDays(_ db: Database, start: Int64, end: Int64) throws -> Set<String> {
        // 精确时间记录
        let exactSQL = """
            SELECT DATE(start_time / 1000, 'unixepoch', 'localtime') AS day
            FROM read_time_record
            WHERE is_deleted = 0 AND status = 3 AND fuzzy_read_date = 0
              AND start_time BETWEEN ? AND ?
            GROUP BY day
            """
        let exactRows = try Row.fetchAll(db, sql: exactSQL, arguments: [start, end])

        // 模糊时间记录
        let fuzzySQL = """
            SELECT DATE(fuzzy_read_date / 1000, 'unixepoch', 'localtime') AS day
            FROM read_time_record
            WHERE is_deleted = 0 AND status = 3 AND fuzzy_read_date != 0
              AND fuzzy_read_date BETWEEN ? AND ?
            GROUP BY day
            """
        let fuzzyRows = try Row.fetchAll(db, sql: fuzzySQL, arguments: [start, end])

        var result = Set(exactRows.compactMap { $0["day"] as String? })
        result.formUnion(fuzzyRows.compactMap { $0["day"] as String? })
        return result
    }

    /// 打卡活跃天查询，额外过滤 checkin_date != 0。
    nonisolated func queryCheckinActiveDays(_ db: Database, start: Int64, end: Int64) throws -> Set<String> {
        let sql = """
            SELECT DATE(checkin_date / 1000, 'unixepoch', 'localtime') AS day
            FROM check_in_record
            WHERE is_deleted = 0 AND checkin_date != 0 AND checkin_date BETWEEN ? AND ?
            GROUP BY day
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])
        return Set(rows.compactMap { $0["day"] as String? })
    }

    /// 按天聚合阅读时长（秒），精确与模糊两路合并。
    /// 返回 [dayKey: totalSeconds] 字典。
    nonisolated func aggregateReadSeconds(_ db: Database, start: Int64, end: Int64) throws -> [String: Int64] {
        // 精确时间记录
        let exactSQL = """
            SELECT DATE(start_time / 1000, 'unixepoch', 'localtime') AS day,
                   SUM(elapsed_seconds) AS total
            FROM read_time_record
            WHERE is_deleted = 0 AND status = 3 AND fuzzy_read_date = 0
              AND start_time BETWEEN ? AND ?
            GROUP BY day
            """
        let exactRows = try Row.fetchAll(db, sql: exactSQL, arguments: [start, end])

        // 模糊时间记录
        let fuzzySQL = """
            SELECT DATE(fuzzy_read_date / 1000, 'unixepoch', 'localtime') AS day,
                   SUM(elapsed_seconds) AS total
            FROM read_time_record
            WHERE is_deleted = 0 AND status = 3 AND fuzzy_read_date != 0
              AND fuzzy_read_date BETWEEN ? AND ?
            GROUP BY day
            """
        let fuzzyRows = try Row.fetchAll(db, sql: fuzzySQL, arguments: [start, end])

        var result: [String: Int64] = [:]
        for row in exactRows {
            guard let day = row["day"] as String? else { continue }
            result[day, default: 0] += row["total"] as Int64? ?? 0
        }
        for row in fuzzyRows {
            guard let day = row["day"] as String? else { continue }
            result[day, default: 0] += row["total"] as Int64? ?? 0
        }
        return result
    }
}

// MARK: - 图片批量查询

private extension TimelineRepository {
    /// 批量查询图片表，按外键分组返回 URL 列表。
    /// - Parameters:
    ///   - table: 图片表名（attach_image / review_image / category_image）
    ///   - foreignKey: 外键列名（note_id / review_id / category_content_id）
    ///   - imageColumn: 图片 URL 列名（image_url / image）
    ///   - ids: 外键 ID 集合
    ///   - orderClause: 排序子句
    /// - Returns: [外键ID: [图片URL]] 分组字典
    nonisolated func batchFetchImages(
        _ db: Database,
        table: String,
        foreignKey: String,
        imageColumn: String,
        ids: [Int64],
        orderClause: String
    ) throws -> [Int64: [String]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT \(foreignKey), \(imageColumn)
            FROM \(table)
            WHERE is_deleted = 0 AND \(foreignKey) IN (\(placeholders))
            ORDER BY \(orderClause)
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(ids))
        var result: [Int64: [String]] = [:]
        for row in rows {
            let fkId = row[foreignKey] as Int64
            let url = row[imageColumn] as String? ?? ""
            guard !url.isEmpty else { continue }
            result[fkId, default: []].append(url)
        }
        return result
    }
}

// MARK: - 工具方法

private extension TimelineRepository {
    /// 月首到月末的毫秒时间戳范围。
    nonisolated func monthMillisRange(for monthStart: Date) -> (start: Int64, end: Int64) {
        let calendar = Calendar.current
        let normalized = calendar.startOfDay(for: monthStart)
        let comps = calendar.dateComponents([.year, .month], from: normalized)
        let firstDay = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? normalized
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: firstDay) ?? firstDay
        let lastMoment = nextMonth.addingTimeInterval(-0.001)
        return (
            start: Int64(firstDay.timeIntervalSince1970 * 1000),
            end: Int64(lastMoment.timeIntervalSince1970 * 1000)
        )
    }

    /// 事件按日分组：timestamp → dayKey → TimelineSection，按日期降序排列。
    nonisolated func groupByDay(_ events: [TimelineEvent]) -> [TimelineSection] {
        let calendar = Calendar.current
        let formatter = Self.dayFormatter

        var grouped: [String: (date: Date, events: [TimelineEvent])] = [:]

        for event in events {
            let date = Date(timeIntervalSince1970: Double(event.timestamp) / 1000)
            let dayStart = calendar.startOfDay(for: date)
            let key = formatter.string(from: dayStart)
            grouped[key, default: (date: dayStart, events: [])].events.append(event)
        }

        return grouped
            .map { (key, value) in
                TimelineSection(
                    id: key,
                    date: value.date,
                    events: value.events.sorted { $0.timestamp > $1.timestamp }
                )
            }
            .sorted { $0.date > $1.date }
    }
}
