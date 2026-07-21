import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager、StatisticsRepository、TimelineRepository 与阅读日历领域模型
 * [OUTPUT]: 对外提供 ReadCalendarRepository，统一日历聚合、当日汇总、单书时间线及打卡/计时写入
 * [POS]: Data 层阅读日历业务真相源，被阅读日历相关 ViewModel 通过协议依赖
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历专属仓储；日历与详情共用同一数据库快照和 Android 业务口径。
nonisolated struct ReadCalendarRepository: ReadCalendarRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let statisticsRepository: StatisticsRepository
    private let timelineRepository: TimelineRepository
    private let calendar: Calendar

    /// 注入共享数据库管理器，并组装现有统计与时间线查询协作者。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        self.statisticsRepository = StatisticsRepository(databaseManager: databaseManager)
        self.timelineRepository = TimelineRepository(databaseManager: databaseManager)
        self.calendar = Calendar.current
    }

    /// 读取启用事件源中的最早日期。
    nonisolated func fetchEarliestDate(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> Date? {
        try await statisticsRepository.fetchReadCalendarEarliestDate(
            excludedEventTypes: excludedEventTypes
        )
    }

    /// 读取指定月份的完整日历聚合。
    nonisolated func fetchMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData {
        try await statisticsRepository.fetchReadCalendarMonthData(
            monthStart: monthStart,
            excludedEventTypes: excludedEventTypes
        )
    }

    /// 读取指定年份的阅读时长排行。
    nonisolated func fetchYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int
    ) async throws -> [ReadCalendarMonthlyDurationBook] {
        try await statisticsRepository.fetchReadCalendarYearTopBooks(
            year: year,
            excludedEventTypes: excludedEventTypes,
            limit: limit
        )
    }

    /// 重新聚合指定自然日的书籍与行为指标。
    nonisolated func fetchDailySummary(for date: Date) async throws -> DailyReadingSummary {
        let dayRange = dayMillisRange(for: date)
        return try await databaseManager.database.dbPool.read { db in
            try buildDailySummary(db, date: date, dayRange: dayRange)
        }
    }

    /// 读取某书在指定自然日内的可管理事件，并按用户选择排序。
    nonisolated func fetchDailyBookRecords(
        for date: Date,
        bookID: Int64,
        filter: DailyReadingTimelineFilter,
        sortOrder: DailyReadingSortOrder
    ) async throws -> [DailyReadingRecord] {
        let dayRange = dayMillisRange(for: date)
        var events: [TimelineEvent] = []

        if filter != .readTiming {
            let category = timelineCategory(for: filter)
            let sections = try await timelineRepository.fetchTimelineEvents(
                startTimestamp: dayRange.lowerBound,
                endTimestamp: dayRange.upperBound,
                category: category
            )
            events = sections
                .flatMap(\.events)
                .filter { event in
                    guard event.sourceBookId == bookID else { return false }
                    if case .readStatus = event.kind { return false }
                    if case .readTiming = event.kind { return false }
                    return true
                }
        }

        if filter == .all || filter == .readTiming {
            let timingEvents = try await databaseManager.database.dbPool.read { db in
                try queryDailyTimingEvents(db, bookID: bookID, dayRange: dayRange)
            }
            events.append(contentsOf: timingEvents)
        }

        let ordered = events.sorted {
            if $0.timestamp != $1.timestamp {
                return sortOrder == .descending
                    ? $0.timestamp > $1.timestamp
                    : $0.timestamp < $1.timestamp
            }
            return sortOrder == .descending ? $0.id > $1.id : $0.id < $1.id
        }

        return ordered.compactMap { event in
            guard let recordID = recordID(for: event) else { return nil }
            return DailyReadingRecord(recordID: recordID, event: event)
        }
    }

    /// 保存打卡；新增路径按同书同日覆盖，编辑路径保留原打卡日期。
    nonisolated func saveCheckIn(_ draft: ReadCalendarCheckInDraft) async throws {
        guard draft.bookID > 0 else { throw ReadCalendarRepositoryError.invalidBook }
        guard (1...4).contains(draft.amount) else {
            throw ReadCalendarRepositoryError.invalidCheckInAmount
        }
        guard calendar.startOfDay(for: draft.date) <= calendar.startOfDay(for: Date()) else {
            throw ReadCalendarRepositoryError.futureDate
        }

        let now = Self.currentMilliseconds()
        let dayRange = dayMillisRange(for: draft.date)
        try await databaseManager.database.dbPool.write { db in
            guard try isValidBook(db, bookID: draft.bookID) else {
                throw ReadCalendarRepositoryError.invalidBook
            }

            if let recordID = draft.recordID {
                // SQL 目的：物理 schema 中更新一条有效打卡的书籍与阅读量。
                // 涉及表：check_in_record、book；book 只用于校验有效性。
                // 关键过滤：id 精确匹配且 is_deleted=0；日期字段保持原值，对齐 Android 编辑语义。
                // 时间字段：updated_date 写当前毫秒时间戳；无时区转换。
                // 副作用用途：更新三级时间线和当日汇总中的打卡指标。
                let sql = """
                    UPDATE check_in_record
                    SET book_id = ?, amount = ?, updated_date = ?
                    WHERE id = ? AND is_deleted = 0
                    """
                try db.execute(
                    sql: sql,
                    arguments: [draft.bookID, draft.amount, now, recordID]
                )
                guard db.changesCount > 0 else { throw ReadCalendarRepositoryError.recordNotFound }
                return
            }

            // SQL 目的：查找同书同日的有效打卡，决定新增还是覆盖。
            // 涉及表：check_in_record。
            // 关键过滤：book_id、checkin_date 日闭区间、is_deleted=0。
            // 时间字段：checkin_date 为本地自然日内毫秒时间戳。
            // 返回字段用途：复用 id，保持 Android 同日单书唯一打卡行为。
            let existingSQL = """
                SELECT id
                FROM check_in_record
                WHERE book_id = ?
                  AND is_deleted = 0
                  AND checkin_date BETWEEN ? AND ?
                ORDER BY id DESC
                LIMIT 1
                """
            if let existingID = try Int64.fetchOne(
                db,
                sql: existingSQL,
                arguments: [draft.bookID, dayRange.lowerBound, dayRange.upperBound]
            ) {
                // SQL 目的：覆盖同书同日打卡的阅读量，并对齐 Android 重打卡时重写创建时间的行为。
                // 涉及表：check_in_record。
                // 关键过滤：id 精确匹配且 is_deleted=0。
                // 时间字段：created_date/updated_date 均写当前毫秒；checkin_date 保持原日期。
                // 副作用用途：避免同书同日产生重复打卡。
                let updateSQL = """
                    UPDATE check_in_record
                    SET amount = ?, created_date = ?, updated_date = ?
                    WHERE id = ? AND is_deleted = 0
                    """
                try db.execute(sql: updateSQL, arguments: [draft.amount, now, now, existingID])
            } else {
                var record = CheckInRecordRecord(
                    bookId: draft.bookID,
                    amount: Int64(draft.amount),
                    position: "",
                    positionUnit: 0,
                    remark: "",
                    checkinDate: dayRange.lowerBound,
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try record.insert(db)
            }
        }
    }

    /// 更新计时记录；读完状态与计时修改在同一数据库事务内提交。
    nonisolated func updateTiming(_ draft: ReadCalendarTimingDraft) async throws {
        guard draft.bookID > 0 else { throw ReadCalendarRepositoryError.invalidBook }
        let nowDate = Date()
        let normalized: (start: Int64, end: Int64, fuzzy: Int64, elapsed: Int64)

        switch draft.kind {
        case .accurate:
            guard let startDate = draft.startDate,
                  let endDate = draft.endDate,
                  startDate < endDate else {
                throw ReadCalendarRepositoryError.invalidTimingRange
            }
            guard endDate <= nowDate else { throw ReadCalendarRepositoryError.futureDate }
            let elapsed = Int64(endDate.timeIntervalSince(startDate).rounded(.down))
            guard elapsed > 0 else { throw ReadCalendarRepositoryError.invalidTimingRange }
            normalized = (Self.milliseconds(startDate), Self.milliseconds(endDate), 0, elapsed)
        case .fuzzy:
            guard let fuzzyDate = draft.fuzzyDate, draft.elapsedSeconds > 0 else {
                throw ReadCalendarRepositoryError.invalidTimingRange
            }
            guard calendar.startOfDay(for: fuzzyDate) <= calendar.startOfDay(for: nowDate) else {
                throw ReadCalendarRepositoryError.futureDate
            }
            normalized = (0, 0, Self.milliseconds(calendar.startOfDay(for: fuzzyDate)), draft.elapsedSeconds)
        }

        let now = Self.currentMilliseconds()
        try await databaseManager.database.dbPool.write { db in
            guard try isValidBook(db, bookID: draft.bookID) else {
                throw ReadCalendarRepositoryError.invalidBook
            }
            // SQL 目的：更新已完成的阅读计时记录，覆盖精确/模糊两种时间语义及进度快照。
            // 涉及表：read_time_record、book；book 只用于前置有效性校验。
            // 关键过滤：记录 id 精确匹配、is_deleted=0；写入状态固定为 3（已完成）。
            // 时间字段：精确记录写 start/end 并清空 fuzzy；模糊记录反向处理；updated_date 为当前毫秒。
            // 副作用用途：刷新日历时长、当日汇总、排行与三级时间线。
            let sql = """
                UPDATE read_time_record
                SET book_id = ?,
                    start_time = ?,
                    end_time = ?,
                    elapsed_seconds = ?,
                    fuzzy_read_date = ?,
                    position = ?,
                    recorded_position_unit = ?,
                    insight = ?,
                    status = 3,
                    updated_date = ?
                WHERE id = ? AND is_deleted = 0
                """
            try db.execute(
                sql: sql,
                arguments: [
                    draft.bookID,
                    normalized.start,
                    normalized.end,
                    normalized.elapsed,
                    normalized.fuzzy,
                    draft.position,
                    draft.recordedPositionUnit,
                    draft.insight,
                    now,
                    draft.recordID
                ]
            )
            guard db.changesCount > 0 else { throw ReadCalendarRepositoryError.recordNotFound }

            if draft.shouldMarkReadDone {
                try appendReadDoneStatus(db, bookID: draft.bookID, changedAt: now)
            }
        }
    }

    /// 物理删除指定打卡记录。
    nonisolated func deleteCheckIn(recordID: Int64) async throws {
        try await physicallyDelete(
            table: CheckInRecordRecord.databaseTableName,
            recordID: recordID
        )
    }

    /// 物理删除指定阅读计时记录。
    nonisolated func deleteTiming(recordID: Int64) async throws {
        try await physicallyDelete(
            table: ReadTimeRecordRecord.databaseTableName,
            recordID: recordID
        )
    }
}

// MARK: - 当日聚合

private extension ReadCalendarRepository {
    nonisolated struct BookActivityAggregate {
        var firstEventTime: Int64 = .max
        var noteCount = 0
        var relevantCount = 0
        var reviewCount = 0
        var checkInCount = 0
        var readDoneCount = 0
        var readSeconds = 0

        mutating func merge(count: Int, firstEventTime: Int64, into keyPath: WritableKeyPath<Self, Int>) {
            self[keyPath: keyPath] += count
            self.firstEventTime = min(self.firstEventTime, firstEventTime)
        }
    }

    nonisolated struct CountAndFirst {
        let count: Int
        let firstEventTime: Int64
    }

    nonisolated struct DailyTimingRow {
        let id: Int64
        let bookID: Int64
        let startTime: Int64
        let endTime: Int64
        let elapsedSeconds: Int64
        let fuzzyReadDate: Int64
        let position: Double
        let recordedPositionUnit: Int64?
        let insight: String
        let bookName: String
        let bookAuthor: String
        let bookCover: String
    }

    /// 合并六类事件为当日书籍摘要，并保持首事件时间排序。
    nonisolated func buildDailySummary(
        _ db: Database,
        date: Date,
        dayRange: ClosedRange<Int64>
    ) throws -> DailyReadingSummary {
        var aggregates: [Int64: BookActivityAggregate] = [:]

        let noteMap = try queryCountAndFirst(
            db,
            sql: Self.noteDailyAggregateSQL,
            dayRange: dayRange
        )
        merge(noteMap, into: &aggregates, keyPath: \.noteCount)

        let relevantMap = try queryCountAndFirst(
            db,
            sql: Self.relevantDailyAggregateSQL,
            dayRange: dayRange
        )
        merge(relevantMap, into: &aggregates, keyPath: \.relevantCount)

        let reviewMap = try queryCountAndFirst(
            db,
            sql: Self.reviewDailyAggregateSQL,
            dayRange: dayRange
        )
        merge(reviewMap, into: &aggregates, keyPath: \.reviewCount)

        let checkInMap = try queryCountAndFirst(
            db,
            sql: Self.checkInDailyAggregateSQL,
            dayRange: dayRange
        )
        merge(checkInMap, into: &aggregates, keyPath: \.checkInCount)

        let readDoneMap = try queryCountAndFirst(
            db,
            sql: Self.readDoneDailyAggregateSQL,
            dayRange: dayRange
        )
        merge(readDoneMap, into: &aggregates, keyPath: \.readDoneCount)

        let timingRows = try queryDailyTimingRows(db, bookID: nil, dayRange: dayRange)
        for row in timingRows {
            let seconds = timingSeconds(row, in: dayRange)
            guard seconds > 0 else { continue }
            var aggregate = aggregates[row.bookID, default: BookActivityAggregate()]
            aggregate.readSeconds += Int(seconds)
            aggregate.firstEventTime = min(
                aggregate.firstEventTime,
                timingTimestamp(row, in: dayRange)
            )
            aggregates[row.bookID] = aggregate
        }

        let bookMetadata = try queryBookMetadata(db, bookIDs: Set(aggregates.keys))
        let books = aggregates.compactMap { bookID, aggregate -> DailyReadingBookSummary? in
            guard let metadata = bookMetadata[bookID] else { return nil }
            let firstEventTime = aggregate.firstEventTime == .max
                ? dayRange.lowerBound
                : aggregate.firstEventTime
            let book = ReadCalendarDayBook(
                id: bookID,
                name: metadata.name,
                coverURL: metadata.cover,
                firstEventTime: firstEventTime,
                isReadDoneOnThisDay: aggregate.readDoneCount > 0
            )
            return DailyReadingBookSummary(
                book: book,
                readSeconds: aggregate.readSeconds,
                noteCount: aggregate.noteCount,
                relevantCount: aggregate.relevantCount,
                reviewCount: aggregate.reviewCount,
                checkInCount: aggregate.checkInCount,
                readDoneCount: aggregate.readDoneCount
            )
        }
        .sorted {
            if $0.book.firstEventTime != $1.book.firstEventTime {
                return $0.book.firstEventTime < $1.book.firstEventTime
            }
            return $0.id < $1.id
        }

        return DailyReadingSummary(
            date: calendar.startOfDay(for: date),
            books: books,
            readSeconds: books.reduce(0) { $0 + $1.readSeconds },
            noteCount: books.reduce(0) { $0 + $1.noteCount },
            relevantCount: books.reduce(0) { $0 + $1.relevantCount },
            reviewCount: books.reduce(0) { $0 + $1.reviewCount },
            checkInCount: books.reduce(0) { $0 + $1.checkInCount },
            finishedBookCount: books.filter { $0.readDoneCount > 0 }.count
        )
    }

    /// 把单类事件聚合结果合并到每书摘要。
    nonisolated func merge(
        _ source: [Int64: CountAndFirst],
        into target: inout [Int64: BookActivityAggregate],
        keyPath: WritableKeyPath<BookActivityAggregate, Int>
    ) {
        for (bookID, value) in source {
            var aggregate = target[bookID, default: BookActivityAggregate()]
            aggregate.merge(
                count: value.count,
                firstEventTime: value.firstEventTime,
                into: keyPath
            )
            target[bookID] = aggregate
        }
    }

    /// 执行 book_id + count + first_event_time 聚合查询。
    nonisolated func queryCountAndFirst(
        _ db: Database,
        sql: String,
        dayRange: ClosedRange<Int64>
    ) throws -> [Int64: CountAndFirst] {
        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: [dayRange.lowerBound, dayRange.upperBound]
        )
        return rows.reduce(into: [:]) { result, row in
            let bookID: Int64 = row["book_id"]
            result[bookID] = CountAndFirst(
                count: row["total"] ?? 0,
                firstEventTime: row["first_event_time"] ?? dayRange.lowerBound
            )
        }
    }

    /// 批量读取有效书籍元数据，避免当日书籍逐条查询。
    nonisolated func queryBookMetadata(
        _ db: Database,
        bookIDs: Set<Int64>
    ) throws -> [Int64: (name: String, author: String, cover: String)] {
        guard !bookIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: bookIDs.count).joined(separator: ",")
        // SQL 目的：批量读取当日活动书籍的展示元数据。
        // 涉及表：book。
        // 关键过滤：id IN 输入集合、is_deleted=0、id!=0。
        // 时间字段：无。
        // 返回字段用途：构建当日汇总与时间线卡片的书名、作者和封面。
        let sql = """
            SELECT id, name, author, cover
            FROM book
            WHERE id IN (\(placeholders))
              AND is_deleted = 0
              AND id != 0
            """
        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments(Array(bookIDs))
        )
        return rows.reduce(into: [:]) { result, row in
            let bookID: Int64 = row["id"]
            result[bookID] = (
                name: row["name"] ?? "",
                author: row["author"] ?? "",
                cover: row["cover"] ?? ""
            )
        }
    }
}

// MARK: - 单书时间线

private extension ReadCalendarRepository {
    /// 把阅读日历筛选映射为现有 Timeline 查询类别。
    nonisolated func timelineCategory(
        for filter: DailyReadingTimelineFilter
    ) -> TimelineEventCategory {
        switch filter {
        case .all: .all
        case .note: .note
        case .relevant: .relevant
        case .review: .review
        case .checkIn: .checkIn
        case .readTiming: .readTiming
        }
    }

    /// 读取并切分指定书籍在目标自然日内的精确/模糊计时记录。
    nonisolated func queryDailyTimingEvents(
        _ db: Database,
        bookID: Int64,
        dayRange: ClosedRange<Int64>
    ) throws -> [TimelineEvent] {
        try queryDailyTimingRows(db, bookID: bookID, dayRange: dayRange).compactMap { row in
            let seconds = timingSeconds(row, in: dayRange)
            guard seconds > 0 else { return nil }
            let timestamp = timingTimestamp(row, in: dayRange)
            return TimelineEvent(
                id: "timing-\(row.id)",
                kind: .readTiming(TimelineReadTimingEvent(
                    elapsedSeconds: row.elapsedSeconds,
                    startTime: row.startTime,
                    endTime: row.endTime,
                    fuzzyReadDate: row.fuzzyReadDate,
                    position: row.position,
                    recordedPositionUnit: row.recordedPositionUnit,
                    insight: row.insight
                )),
                timestamp: timestamp,
                sourceBookId: row.bookID,
                bookName: row.bookName,
                bookAuthor: row.bookAuthor,
                bookCover: row.bookCover
            )
        }
    }

    /// 查询与目标自然日相交的已完成计时记录；精确记录使用区间重叠，模糊记录按日期归属。
    nonisolated func queryDailyTimingRows(
        _ db: Database,
        bookID: Int64?,
        dayRange: ClosedRange<Int64>
    ) throws -> [DailyTimingRow] {
        // SQL 目的：读取目标自然日内的模糊计时，以及与该日发生区间重叠的精确计时。
        // 涉及表：read_time_record JOIN book。
        // 关键过滤：记录/书籍 is_deleted=0、status=3、book_id!=0；可选限定单书。
        // 时间字段：fuzzy_read_date 按日闭区间；精确记录按 end_time >= dayStart 且 start_time <= dayEnd。
        // 返回字段用途：按日切分时长并构建当日汇总/三级时间线。
        let bookClause = bookID == nil ? "" : "AND r.book_id = ?"
        let sql = """
            SELECT r.id, r.book_id, r.start_time, r.end_time, r.elapsed_seconds, r.fuzzy_read_date,
                   r.position, r.recorded_position_unit, r.insight,
                   b.name, b.author, b.cover
            FROM read_time_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND r.status = 3
              AND r.book_id != 0
              \(bookClause)
              AND (
                (r.fuzzy_read_date != 0 AND r.fuzzy_read_date BETWEEN ? AND ?)
                OR
                (r.fuzzy_read_date = 0 AND r.end_time >= ? AND r.start_time <= ?)
              )
            """
        var arguments: [(any DatabaseValueConvertible)?] = []
        if let bookID { arguments.append(bookID) }
        arguments.append(contentsOf: [
            dayRange.lowerBound,
            dayRange.upperBound,
            dayRange.lowerBound,
            dayRange.upperBound
        ])
        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments(arguments)
        )
        return rows.map { row in
            DailyTimingRow(
                id: row["id"],
                bookID: row["book_id"],
                startTime: row["start_time"] ?? 0,
                endTime: row["end_time"] ?? 0,
                elapsedSeconds: row["elapsed_seconds"] ?? 0,
                fuzzyReadDate: row["fuzzy_read_date"] ?? 0,
                position: row["position"] ?? 0,
                recordedPositionUnit: row["recorded_position_unit"],
                insight: row["insight"] ?? "",
                bookName: row["name"] ?? "",
                bookAuthor: row["author"] ?? "",
                bookCover: row["cover"] ?? ""
            )
        }
    }

    /// 按 wall-time 占比分配跨日精确计时在目标日内的阅读秒数。
    nonisolated func timingSeconds(
        _ row: DailyTimingRow,
        in dayRange: ClosedRange<Int64>
    ) -> Int64 {
        guard row.elapsedSeconds > 0 else { return 0 }
        if row.fuzzyReadDate != 0 {
            return dayRange.contains(row.fuzzyReadDate) ? row.elapsedSeconds : 0
        }

        let effectiveEnd = row.endTime > row.startTime
            ? row.endTime
            : row.startTime + row.elapsedSeconds * 1_000
        let overlapStart = max(row.startTime, dayRange.lowerBound)
        let overlapEnd = min(effectiveEnd, dayRange.upperBound + 1)
        guard overlapEnd > overlapStart else { return 0 }
        let wallDuration = max(Int64(1), effectiveEnd - row.startTime)
        let overlapDuration = overlapEnd - overlapStart
        return min(
            row.elapsedSeconds,
            Int64((Double(overlapDuration) / Double(wallDuration) * Double(row.elapsedSeconds)).rounded())
        )
    }

    /// 计算计时记录在目标日时间线中的排序时间。
    nonisolated func timingTimestamp(
        _ row: DailyTimingRow,
        in dayRange: ClosedRange<Int64>
    ) -> Int64 {
        row.fuzzyReadDate != 0
            ? row.fuzzyReadDate
            : max(row.startTime, dayRange.lowerBound)
    }

    /// 提取不同事件类型的真实数据库主键。
    nonisolated func recordID(for event: TimelineEvent) -> Int64? {
        switch event.kind {
        case .note(let note): note.noteId
        case .review(let review): review.reviewId
        case .relevant(let relevant): relevant.contentId
        case .relevantBook:
            Int64(event.id.split(separator: "-").last ?? "")
        case .readTiming, .checkIn:
            Int64(event.id.split(separator: "-").last ?? "")
        case .readStatus:
            nil
        }
    }
}

// MARK: - 写入辅助

private extension ReadCalendarRepository {
    /// 校验目标书籍存在且未删除。
    nonisolated func isValidBook(_ db: Database, bookID: Int64) throws -> Bool {
        // SQL 目的：验证写入目标书籍有效。
        // 涉及表：book。
        // 关键过滤：id 精确匹配、is_deleted=0、id!=0。
        // 时间字段：无。
        // 返回字段用途：阻止打卡/计时写入已删除书籍或系统占位书。
        let sql = """
            SELECT EXISTS(
                SELECT 1 FROM book
                WHERE id = ? AND is_deleted = 0 AND id != 0
            )
            """
        return try Bool.fetchOne(db, sql: sql, arguments: [bookID]) ?? false
    }

    /// 追加读完状态并同步 book 当前状态、进度与年度书单。
    nonisolated func appendReadDoneStatus(
        _ db: Database,
        bookID: Int64,
        changedAt: Int64
    ) throws {
        guard let bookState = try BookReadStatusMutation.fetchBookState(db, bookID: bookID) else {
            throw ReadCalendarRepositoryError.invalidBook
        }
        // SQL 目的：读取最新有效阅读状态时间，阻止新状态早于上一状态。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id、is_deleted=0；按 changed_date/id 倒序。
        // 时间字段：changed_date 为毫秒，按分钟比较以对齐 Android。
        // 返回字段用途：执行状态历史单调性校验。
        let latestSQL = """
            SELECT changed_date
            FROM book_read_status_record
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY changed_date DESC, id DESC
            LIMIT 1
            """
        if let latest = try Int64.fetchOne(db, sql: latestSQL, arguments: [bookID]),
           latest / 60_000 > changedAt / 60_000 {
            throw ReadCalendarRepositoryError.invalidTimingRange
        }

        try BookReadStatusMutation.insertBookReadStatusRecord(
            db,
            bookID: bookID,
            statusID: 3,
            changedAt: changedAt,
            createdAt: changedAt
        )
        try BookReadStatusMutation.updateBookCurrentReadStatus(
            db,
            bookID: bookID,
            userID: bookState.userID,
            statusID: 3,
            changedAt: changedAt,
            updatedAt: changedAt
        )
        try BookReadStatusMutation.markBookAsFinished(
            db,
            bookID: bookID,
            positionUnit: bookState.positionUnit,
            totalPosition: bookState.totalPosition,
            totalPagination: bookState.totalPagination,
            updatedAt: changedAt
        )
        try AnnualCollectionSync.syncAfterReadHistoryChanged(db, bookID: bookID)
    }

    /// 执行限定表名的物理删除；表名只由内部常量传入，不接受外部输入。
    nonisolated func physicallyDelete(table: String, recordID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：物理删除指定阅读日历记录，遵守 iOS 已批准的硬删除规则。
            // 涉及表：调用方限定为 check_in_record 或 read_time_record。
            // 关键过滤：id 精确匹配；不创建 is_deleted tombstone。
            // 时间字段：无。
            // 副作用用途：立即移除日历、汇总与时间线中的记录。
            let sql = "DELETE FROM \(table) WHERE id = ?"
            try db.execute(sql: sql, arguments: [recordID])
            guard db.changesCount > 0 else { throw ReadCalendarRepositoryError.recordNotFound }
        }
    }
}

// MARK: - 日期与 SQL 常量

private extension ReadCalendarRepository {
    /// 生成本地自然日的毫秒闭区间。
    nonisolated func dayMillisRange(for date: Date) -> ClosedRange<Int64> {
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return Self.milliseconds(start)...(Self.milliseconds(next) - 1)
    }

    nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    nonisolated static func currentMilliseconds() -> Int64 {
        milliseconds(Date())
    }

    // SQL 目的：按书籍聚合目标日有效书摘数量与最早创建时间。
    // 涉及表：note JOIN book；过滤双方 is_deleted=0，created_date 为毫秒闭区间。
    // 返回字段用途：当日汇总书摘指标与排序。
    nonisolated static let noteDailyAggregateSQL = """
        SELECT n.book_id, COUNT(*) AS total, MIN(n.created_date) AS first_event_time
        FROM note n
        JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
        WHERE n.is_deleted = 0 AND n.created_date BETWEEN ? AND ?
        GROUP BY n.book_id
        """

    // SQL 目的：按书籍聚合目标日有效相关内容数量与最早创建时间。
    // 涉及表：category_content JOIN book；过滤双方 is_deleted=0，created_date 为毫秒闭区间。
    // 返回字段用途：当日汇总相关内容指标与排序。
    nonisolated static let relevantDailyAggregateSQL = """
        SELECT c.book_id, COUNT(*) AS total, MIN(c.created_date) AS first_event_time
        FROM category_content c
        JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
        WHERE c.is_deleted = 0 AND c.created_date BETWEEN ? AND ?
        GROUP BY c.book_id
        """

    // SQL 目的：按书籍聚合目标日有效书评数量与最早创建时间。
    // 涉及表：review JOIN book；过滤双方 is_deleted=0，created_date 为毫秒闭区间。
    // 返回字段用途：当日汇总书评指标与排序。
    nonisolated static let reviewDailyAggregateSQL = """
        SELECT r.book_id, COUNT(*) AS total, MIN(r.created_date) AS first_event_time
        FROM review r
        JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
        WHERE r.is_deleted = 0 AND r.created_date BETWEEN ? AND ?
        GROUP BY r.book_id
        """

    // SQL 目的：按书籍聚合目标日有效打卡数量与最早打卡时间。
    // 涉及表：check_in_record JOIN book；过滤双方 is_deleted=0，checkin_date 为毫秒闭区间。
    // 返回字段用途：当日汇总打卡指标与排序。
    nonisolated static let checkInDailyAggregateSQL = """
        SELECT c.book_id, COUNT(*) AS total, MIN(c.checkin_date) AS first_event_time
        FROM check_in_record c
        JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
        WHERE c.is_deleted = 0 AND c.checkin_date BETWEEN ? AND ?
        GROUP BY c.book_id
        """

    // SQL 目的：按书籍聚合目标日读完状态数量与最早变更时间。
    // 涉及表：book_read_status_record JOIN book；过滤双方 is_deleted=0、read_status_id=3。
    // 返回字段用途：当日汇总读完指标、封面标记与排序。
    nonisolated static let readDoneDailyAggregateSQL = """
        SELECT r.book_id, COUNT(*) AS total, MIN(r.changed_date) AS first_event_time
        FROM book_read_status_record r
        JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
        WHERE r.is_deleted = 0
          AND r.read_status_id = 3
          AND r.changed_date BETWEEN ? AND ?
        GROUP BY r.book_id
        """
}
