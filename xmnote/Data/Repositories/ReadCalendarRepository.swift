import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager、ObservationStream、StatisticsRepository、TimelineRepository 与阅读日历领域模型
 * [OUTPUT]: 对外提供 ReadCalendarRepository，统一日历筛选、变化信号、当日汇总、补录时间线映射、跨日计时分段及打卡/计时写入
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

    /// 将影响阅读日历和当日记录的数据库表变化桥接为无载荷事件，页面生命周期结束后由调用方取消。
    @MainActor func observeDailyReadingChanges() -> AsyncThrowingStream<Void, Error> {
        ObservationStream.makeChangeSignal(in: databaseManager.database.dbPool) { db in
            try dailyReadingDataFingerprint(db)
        }
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
        excludedEventTypes: Set<ReadCalendarEventType>,
        excludedBookIDs: Set<Int64>
    ) async throws -> ReadCalendarMonthData {
        try await statisticsRepository.fetchReadCalendarMonthData(
            monthStart: monthStart,
            excludedEventTypes: excludedEventTypes,
            excludedBookIDs: excludedBookIDs
        )
    }

    /// 读取指定年份的阅读时长排行。
    nonisolated func fetchYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int,
        includedMonthStarts: Set<Date>?,
        excludedBookIDs: Set<Int64>
    ) async throws -> [ReadCalendarMonthlyDurationBook] {
        try await statisticsRepository.fetchReadCalendarYearTopBooks(
            year: year,
            excludedEventTypes: excludedEventTypes,
            limit: limit,
            includedMonthStarts: includedMonthStarts,
            excludedBookIDs: excludedBookIDs
        )
    }

    /// 使用阅读日历当前事件筛选重新聚合指定自然日的书籍与行为指标。
    nonisolated func fetchDailySummary(
        for date: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> DailyReadingSummary {
        let dayRange = dayMillisRange(for: date)
        return try await databaseManager.database.dbPool.read { db in
            try buildDailySummary(
                db,
                date: date,
                dayRange: dayRange,
                excludedEventTypes: excludedEventTypes
            )
        }
    }

    /// 读取指定自然日的完整阅读轨迹；书籍候选始终来自全部事件，不继承月历展示筛选。
    nonisolated func fetchDailyTrajectory(
        for date: Date,
        selectedBookID: Int64?,
        filter: DailyReadingTimelineFilter,
        sortOrder: DailyReadingSortOrder
    ) async throws -> DailyReadingTrajectory {
        let dayRange = dayMillisRange(for: date)
        async let summaryTask = fetchDailySummary(for: date, excludedEventTypes: [])
        var events: [TimelineEvent] = []

        if filter != .readTiming, filter != .readDone {
            let category = timelineCategory(for: filter)
            let sections = try await timelineRepository.fetchTimelineEvents(
                startTimestamp: dayRange.lowerBound,
                endTimestamp: dayRange.upperBound,
                category: category
            )
            events = sections
                .flatMap(\.events)
                .filter { event in
                    if let selectedBookID, event.sourceBookId != selectedBookID { return false }
                    if case .readStatus = event.kind { return false }
                    if case .readTiming = event.kind { return false }
                    return true
                }
        }

        if filter == .all || filter == .readTiming {
            let timingEvents = try await databaseManager.database.dbPool.read { db in
                try queryDailyTimingEvents(db, bookID: selectedBookID, dayRange: dayRange)
            }
            events.append(contentsOf: timingEvents)
        }

        if filter == .all || filter == .readDone {
            let readDoneEvents = try await databaseManager.database.dbPool.read { db in
                try queryDailyReadDoneEvents(db, bookID: selectedBookID, dayRange: dayRange)
            }
            events.append(contentsOf: readDoneEvents)
        }

        let ordered = orderedDailyEvents(events, sortOrder: sortOrder)
        let summary = try await summaryTask
        let books = summary.books.sorted {
            if $0.book.firstEventTime != $1.book.firstEventTime {
                return $0.book.firstEventTime < $1.book.firstEventTime
            }
            return $0.id < $1.id
        }
        return DailyReadingTrajectory(
            date: calendar.startOfDay(for: date),
            books: books,
            records: ordered.map { event in
                DailyReadingRecord(recordID: recordID(for: event), event: event)
            }
        )
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

    /// 按 Android CheckInRecordDao.delete 语义物理删除指定打卡记录。
    nonisolated func deleteCheckIn(recordID: Int64) async throws {
        try await physicallyDeleteCheckIn(recordID: recordID)
    }

    /// 按 Android ReadTimeRecordDao.delete 语义软删除指定阅读计时记录。
    nonisolated func deleteTiming(recordID: Int64) async throws {
        try await softDeleteTiming(recordID: recordID)
    }
}

// MARK: - 当日聚合

private extension ReadCalendarRepository {
    /// SQL 目的：追踪会影响阅读日历、当日汇总、单书记录及其操作上下文的全部本地表变更。
    /// 涉及表：note、book、chapter、tag_note、tag、attach_image、category、category_content、category_image、review、review_image、read_time_record、check_in_record、book_read_status_record。
    /// 关键过滤：仅用于变化检测，不提前过滤 is_deleted；有效、软删除和物理删除变化均必须触发重新按 Android 口径查询。
    /// 时间字段：updated_date 沿用 Android 毫秒时间戳，仅参与指纹比较，不执行日期或时区转换。
    /// 返回字段用途：ValueObservation 发现指纹变化后通知二级、三级页面重查，避免子页面修改后显示旧快照。
    nonisolated func dailyReadingDataFingerprint(_ db: Database) throws -> String {
        let trackedTables = [
            NoteRecord.databaseTableName,
            BookRecord.databaseTableName,
            ChapterRecord.databaseTableName,
            TagNoteRecord.databaseTableName,
            TagRecord.databaseTableName,
            AttachImageRecord.databaseTableName,
            CategoryRecord.databaseTableName,
            CategoryContentRecord.databaseTableName,
            CategoryImageRecord.databaseTableName,
            ReviewRecord.databaseTableName,
            ReviewImageRecord.databaseTableName,
            ReadTimeRecordRecord.databaseTableName,
            CheckInRecordRecord.databaseTableName,
            BookReadStatusRecordRecord.databaseTableName
        ]
        let components = trackedTables.map { tableName in
            """
            (SELECT COUNT(*) || ':' || COALESCE(MAX(updated_date), 0) || ':' ||
                COALESCE(SUM(id + is_deleted), 0)
             FROM \(tableName.quotedDatabaseIdentifier))
            """
        }
        let sql = "SELECT \(components.joined(separator: " || '|' || ")) AS fingerprint"
        return try String.fetchOne(db, sql: sql) ?? ""
    }

    nonisolated struct BookActivityAggregate {
        var firstEventTime: Int64 = .max
        var lastEventTime: Int64 = .min
        var noteCount = 0
        var relevantCount = 0
        var reviewCount = 0
        var checkInCount = 0
        var readDoneCount = 0
        var readSeconds = 0

        mutating func merge(
            count: Int,
            firstEventTime: Int64,
            lastEventTime: Int64,
            into keyPath: WritableKeyPath<Self, Int>
        ) {
            self[keyPath: keyPath] += count
            self.firstEventTime = min(self.firstEventTime, firstEventTime)
            self.lastEventTime = max(self.lastEventTime, lastEventTime)
        }
    }

    nonisolated struct CountAndRange {
        let count: Int
        let firstEventTime: Int64
        let lastEventTime: Int64
    }

    nonisolated struct DailyTimingRow {
        let id: Int64
        let bookID: Int64
        let startTime: Int64
        let endTime: Int64
        let elapsedSeconds: Int64
        let fuzzyReadDate: Int64
        let createdDate: Int64
        let position: Double
        let recordedPositionUnit: Int64?
        let insight: String
        let bookName: String
        let bookAuthor: String
        let bookCover: String
    }

    nonisolated struct DailyTimingSegment {
        let elapsedSeconds: Int64
        let startTime: Int64
        let endTime: Int64
        let activityTime: Int64
        let timelineTime: Int64
    }

    /// 复刻 Android 二级页两阶段查询：筛选决定普通书籍集合，入选书籍指标按全部事件统计，读完快照始终补入。
    nonisolated func buildDailySummary(
        _ db: Database,
        date: Date,
        dayRange: ClosedRange<Int64>,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) throws -> DailyReadingSummary {
        let noteMap = try queryCountAndRange(db, sql: Self.noteDailyAggregateSQL, dayRange: dayRange)
        let relevantMap = try queryCountAndRange(db, sql: Self.relevantDailyAggregateSQL, dayRange: dayRange)
        let reviewMap = try queryCountAndRange(db, sql: Self.reviewDailyAggregateSQL, dayRange: dayRange)
        let checkInMap = try queryCountAndRange(db, sql: Self.checkInDailyAggregateSQL, dayRange: dayRange)
        let readDoneMap = try queryCountAndRange(db, sql: Self.readDoneDailyAggregateSQL, dayRange: dayRange)
        let timingRows = try queryDailyTimingRows(db, bookID: nil, dayRange: dayRange)

        var allMetrics: [Int64: BookActivityAggregate] = [:]
        merge(noteMap, into: &allMetrics, keyPath: \.noteCount)
        merge(relevantMap, into: &allMetrics, keyPath: \.relevantCount)
        merge(reviewMap, into: &allMetrics, keyPath: \.reviewCount)
        merge(checkInMap, into: &allMetrics, keyPath: \.checkInCount)
        merge(readDoneMap, into: &allMetrics, keyPath: \.readDoneCount)
        mergeTimingRows(timingRows, dayRange: dayRange, into: &allMetrics)

        var orderingMetrics: [Int64: BookActivityAggregate] = [:]

        if !excludedEventTypes.contains(.note) {
            merge(noteMap, into: &orderingMetrics, keyPath: \.noteCount)
        }
        if !excludedEventTypes.contains(.relevant) {
            merge(relevantMap, into: &orderingMetrics, keyPath: \.relevantCount)
        }
        if !excludedEventTypes.contains(.review) {
            merge(reviewMap, into: &orderingMetrics, keyPath: \.reviewCount)
        }
        if !excludedEventTypes.contains(.checkIn) {
            merge(checkInMap, into: &orderingMetrics, keyPath: \.checkInCount)
        }
        if !excludedEventTypes.contains(.readDone) {
            merge(readDoneMap, into: &orderingMetrics, keyPath: \.readDoneCount)
        }
        if !excludedEventTypes.contains(.readTiming) {
            mergeTimingRows(timingRows, dayRange: dayRange, into: &orderingMetrics)
        }

        let filteredBookIDs = orderingMetrics.keys.sorted {
            let lhs = orderingMetrics[$0] ?? BookActivityAggregate()
            let rhs = orderingMetrics[$1] ?? BookActivityAggregate()
            if lhs.lastEventTime != rhs.lastEventTime { return lhs.lastEventTime > rhs.lastEventTime }
            if lhs.firstEventTime != rhs.firstEventTime { return lhs.firstEventTime > rhs.firstEventTime }
            return $0 < $1
        }
        let readDoneOnlyBookIDs = readDoneMap.keys
            .filter { orderingMetrics[$0] == nil }
            .sorted {
                let lhs = readDoneMap[$0]
                let rhs = readDoneMap[$1]
                if lhs?.lastEventTime != rhs?.lastEventTime {
                    return (lhs?.lastEventTime ?? .min) > (rhs?.lastEventTime ?? .min)
                }
                return $0 < $1
            }
        let orderedBookIDs = filteredBookIDs + readDoneOnlyBookIDs
        let bookMetadata = try queryBookMetadata(db, bookIDs: Set(orderedBookIDs))
        let books = orderedBookIDs.compactMap { bookID -> DailyReadingBookSummary? in
            guard let aggregate = allMetrics[bookID],
                  let metadata = bookMetadata[bookID] else { return nil }
            let orderAggregate = orderingMetrics[bookID] ?? aggregate
            let firstEventTime = orderAggregate.firstEventTime == .max
                ? dayRange.lowerBound
                : orderAggregate.firstEventTime
            let lastEventTime = orderAggregate.lastEventTime == .min
                ? firstEventTime
                : orderAggregate.lastEventTime
            let book = ReadCalendarDayBook(
                id: bookID,
                name: metadata.name,
                coverURL: metadata.cover,
                firstEventTime: firstEventTime,
                lastEventTime: lastEventTime,
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

    /// 将当日计时分段并入目标聚合；零时长单日/模糊记录仍建立书籍成员关系。
    nonisolated func mergeTimingRows(
        _ rows: [DailyTimingRow],
        dayRange: ClosedRange<Int64>,
        into target: inout [Int64: BookActivityAggregate]
    ) {
        for row in rows {
            guard let segment = dailyTimingSegment(row, in: dayRange) else { continue }
            var aggregate = target[row.bookID, default: BookActivityAggregate()]
            aggregate.readSeconds += Int(segment.elapsedSeconds)
            aggregate.firstEventTime = min(aggregate.firstEventTime, segment.activityTime)
            aggregate.lastEventTime = max(aggregate.lastEventTime, segment.activityTime)
            target[row.bookID] = aggregate
        }
    }

    /// 把单类事件聚合结果合并到每书摘要。
    nonisolated func merge(
        _ source: [Int64: CountAndRange],
        into target: inout [Int64: BookActivityAggregate],
        keyPath: WritableKeyPath<BookActivityAggregate, Int>
    ) {
        for (bookID, value) in source {
            var aggregate = target[bookID, default: BookActivityAggregate()]
            aggregate.merge(
                count: value.count,
                firstEventTime: value.firstEventTime,
                lastEventTime: value.lastEventTime,
                into: keyPath
            )
            target[bookID] = aggregate
        }
    }

    /// 执行 book_id + count + 首末事件时间聚合查询。
    nonisolated func queryCountAndRange(
        _ db: Database,
        sql: String,
        dayRange: ClosedRange<Int64>
    ) throws -> [Int64: CountAndRange] {
        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: [dayRange.lowerBound, dayRange.upperBound]
        )
        return rows.reduce(into: [:]) { result, row in
            let bookID: Int64 = row["book_id"]
            result[bookID] = CountAndRange(
                count: row["total"] ?? 0,
                firstEventTime: row["first_event_time"] ?? dayRange.lowerBound,
                lastEventTime: row["last_event_time"] ?? dayRange.lowerBound
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

// MARK: - 当日阅读轨迹

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
        case .readDone: .readStatus
        }
    }

    /// 读取并切分目标自然日内的精确/模糊计时记录；bookID 为空时保留全部书籍。
    nonisolated func queryDailyTimingEvents(
        _ db: Database,
        bookID: Int64?,
        dayRange: ClosedRange<Int64>
    ) throws -> [TimelineEvent] {
        try queryDailyTimingRows(db, bookID: bookID, dayRange: dayRange).compactMap { row in
            guard let segment = dailyTimingSegment(row, in: dayRange) else { return nil }
            return TimelineEvent(
                id: "timing-\(row.id)",
                kind: .readTiming(TimelineReadTimingEvent(
                    elapsedSeconds: segment.elapsedSeconds,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    fuzzyReadDate: row.fuzzyReadDate,
                    position: row.position,
                    recordedPositionUnit: row.recordedPositionUnit,
                    insight: row.insight,
                    supplementedAt: row.fuzzyReadDate != 0 && row.createdDate > 0
                        ? row.createdDate
                        : nil
                )),
                timestamp: segment.timelineTime,
                sourceBookId: row.bookID,
                bookName: row.bookName,
                bookAuthor: row.bookAuthor,
                bookCover: row.bookCover
            )
        }
    }

    /// 读取目标自然日的读完里程碑，并用 book 当前快照补齐缺失的历史记录。
    nonisolated func queryDailyReadDoneEvents(
        _ db: Database,
        bookID: Int64?,
        dayRange: ClosedRange<Int64>
    ) throws -> [TimelineEvent] {
        let bookClause = bookID == nil ? "" : "AND completed.book_id = ?"
        // SQL 目的：合并读完历史与 book 当前快照，构建当天只读读完里程碑。
        // 涉及表：book_read_status_record、book；快照仅在同书同时间缺少历史记录时补入。
        // 关键过滤：有效书籍、read_status_id=3、changed_date/read_status_changed_date 位于目标自然日；可选限定单书。
        // 时间字段：全部保持 Android 毫秒时间戳，不在 SQL 内执行时区转换。
        // 返回字段用途：生成不可编辑、不可删除的读完时间线记录，并展示累计读完次数与评分。
        let sql = """
            WITH completed AS (
                SELECT r.id AS record_id, r.book_id, r.changed_date AS event_time
                FROM book_read_status_record r
                JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
                WHERE r.is_deleted = 0
                  AND r.read_status_id = 3
                  AND r.changed_date BETWEEN ? AND ?
                UNION ALL
                SELECT NULL AS record_id, b.id AS book_id, b.read_status_changed_date AS event_time
                FROM book b
                WHERE b.is_deleted = 0
                  AND b.id != 0
                  AND b.read_status_id = 3
                  AND b.read_status_changed_date BETWEEN ? AND ?
                  AND NOT EXISTS (
                      SELECT 1
                      FROM book_read_status_record r
                      WHERE r.is_deleted = 0
                        AND r.book_id = b.id
                        AND r.read_status_id = 3
                        AND r.changed_date = b.read_status_changed_date
                  )
            )
            SELECT completed.record_id, completed.book_id, completed.event_time,
                   b.name, b.author, b.cover, b.score,
                   MAX(1, (
                       SELECT COUNT(*)
                       FROM book_read_status_record history
                       WHERE history.is_deleted = 0
                         AND history.book_id = completed.book_id
                         AND history.read_status_id = 3
                         AND history.changed_date <= completed.event_time
                   )) AS read_done_count
            FROM completed
            JOIN book b ON b.id = completed.book_id AND b.is_deleted = 0
            WHERE 1 = 1
              \(bookClause)
            """
        var arguments: [(any DatabaseValueConvertible)?] = [
            dayRange.lowerBound,
            dayRange.upperBound,
            dayRange.lowerBound,
            dayRange.upperBound
        ]
        if let bookID { arguments.append(bookID) }
        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments(arguments)
        )
        return rows.map { row in
            let eventBookID: Int64 = row["book_id"]
            let eventTime: Int64 = row["event_time"]
            let recordID: Int64? = row["record_id"]
            let eventID = recordID.map { "status-\($0)" }
                ?? "status-snapshot-\(eventBookID)-\(eventTime)"
            return TimelineEvent(
                id: eventID,
                kind: .readStatus(TimelineReadStatusEvent(
                    statusId: 3,
                    readDoneCount: row["read_done_count"] ?? 1,
                    bookScore: row["score"] ?? 0
                )),
                timestamp: eventTime,
                sourceBookId: eventBookID,
                bookName: row["name"] ?? "",
                bookAuthor: row["author"] ?? "",
                bookCover: row["cover"] ?? ""
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
        // 时间字段：fuzzy_read_date 按日闭区间；精确记录按 end_time >= dayStart 且 start_time <= dayEnd；created_date 提供补录排序时刻。
        // 返回字段用途：按日切分时长，并以补录时分构建模糊记录的当日时间线位置。
        let bookClause = bookID == nil ? "" : "AND r.book_id = ?"
        let sql = """
            SELECT r.id, r.book_id, r.start_time, r.end_time, r.elapsed_seconds, r.fuzzy_read_date,
                   r.created_date, r.position, r.recorded_position_unit, r.insight,
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
                createdDate: row["created_date"] ?? 0,
                position: row["position"] ?? 0,
                recordedPositionUnit: row["recorded_position_unit"],
                insight: row["insight"] ?? "",
                bookName: row["name"] ?? "",
                bookAuthor: row["author"] ?? "",
                bookCover: row["cover"] ?? ""
            )
        }
    }

    /// 按 Android splitCrossDayRecords 生成精确计时分段；模糊记录以补录时分映射到目标自然日。
    nonisolated func dailyTimingSegment(
        _ row: DailyTimingRow,
        in dayRange: ClosedRange<Int64>
    ) -> DailyTimingSegment? {
        if row.fuzzyReadDate != 0 {
            guard dayRange.contains(row.fuzzyReadDate) else { return nil }
            return DailyTimingSegment(
                elapsedSeconds: row.elapsedSeconds,
                startTime: row.startTime,
                endTime: row.endTime,
                activityTime: row.fuzzyReadDate,
                timelineTime: normalizedSupplementedTimelineTime(
                    row.createdDate,
                    in: dayRange
                ) ?? dayRange.upperBound
            )
        }

        let startDay = calendar.startOfDay(
            for: Date(timeIntervalSince1970: Double(row.startTime) / 1_000)
        )
        let endDay = calendar.startOfDay(
            for: Date(timeIntervalSince1970: Double(row.endTime) / 1_000)
        )
        if startDay == endDay {
            guard dayRange.contains(row.startTime) else { return nil }
            return DailyTimingSegment(
                elapsedSeconds: row.elapsedSeconds,
                startTime: row.startTime,
                endTime: row.endTime,
                activityTime: row.startTime,
                timelineTime: row.endTime != 0 ? row.endTime : row.startTime
            )
        }

        guard row.elapsedSeconds > 0, row.endTime > row.startTime else { return nil }
        let wallTimeTotal = row.endTime - row.startTime
        var allocatedSeconds: Int64 = 0
        var currentMillis = row.startTime
        var cursorDay = startDay

        while cursorDay <= endDay, allocatedSeconds < row.elapsedSeconds {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursorDay) else { break }
            let dayStartMillis = Self.milliseconds(cursorDay)
            let dayEndMillis = Self.milliseconds(nextDay) - 1
            let segmentStart = max(currentMillis, dayStartMillis)
            let segmentEnd = min(row.endTime, dayEndMillis)
            if segmentStart < segmentEnd {
                let ratio = Double(segmentEnd - segmentStart) / Double(wallTimeTotal)
                var seconds = Int64((ratio * Double(row.elapsedSeconds)).rounded())
                seconds = min(seconds, row.elapsedSeconds - allocatedSeconds)
                allocatedSeconds += seconds
                if dayRange.contains(segmentStart) {
                    return DailyTimingSegment(
                        elapsedSeconds: seconds,
                        startTime: segmentStart,
                        endTime: segmentEnd,
                        activityTime: segmentStart,
                        timelineTime: segmentEnd != 0 ? segmentEnd : segmentStart
                    )
                }
                currentMillis = segmentEnd + 1
            }
            cursorDay = nextDay
        }
        return nil
    }

    /// 将补录创建时刻的本地时分映射到当前阅读日，避免改变模糊记录的日期归属。
    nonisolated func normalizedSupplementedTimelineTime(
        _ createdDate: Int64,
        in dayRange: ClosedRange<Int64>
    ) -> Int64? {
        guard createdDate > 0 else { return nil }

        let targetDate = Date(timeIntervalSince1970: Double(dayRange.lowerBound) / 1_000)
        let sourceDate = Date(timeIntervalSince1970: Double(createdDate) / 1_000)
        var components = calendar.dateComponents([.year, .month, .day], from: targetDate)
        let sourceTime = calendar.dateComponents([.hour, .minute, .second], from: sourceDate)
        components.hour = sourceTime.hour
        components.minute = sourceTime.minute
        components.second = sourceTime.second

        guard let normalizedDate = calendar.date(from: components) else { return nil }
        let normalizedMilliseconds = Self.milliseconds(normalizedDate)
        return min(dayRange.upperBound, max(dayRange.lowerBound, normalizedMilliseconds))
    }

    /// 按时间轴时刻排序，并让缺少补录创建时间的历史模糊记录稳定停留在列表末尾。
    nonisolated func orderedDailyEvents(
        _ events: [TimelineEvent],
        sortOrder: DailyReadingSortOrder
    ) -> [TimelineEvent] {
        events.sorted { lhs, rhs in
            let isLeftUnknown = hasUnknownSupplementedTime(lhs)
            let isRightUnknown = hasUnknownSupplementedTime(rhs)
            if isLeftUnknown != isRightUnknown {
                return !isLeftUnknown
            }
            if lhs.timestamp != rhs.timestamp {
                return sortOrder == .descending
                    ? lhs.timestamp > rhs.timestamp
                    : lhs.timestamp < rhs.timestamp
            }
            return sortOrder == .descending ? lhs.id > rhs.id : lhs.id < rhs.id
        }
    }

    /// 判断模糊计时是否缺少可用于时间线定位的真实补录创建时刻。
    nonisolated func hasUnknownSupplementedTime(_ event: TimelineEvent) -> Bool {
        guard case .readTiming(let timing) = event.kind,
              timing.fuzzyReadDate != 0 else {
            return false
        }
        return timing.supplementedAt == nil
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

    /// 物理删除打卡记录；Android 的按 ID 删除同样不生成 tombstone。
    nonisolated func physicallyDeleteCheckIn(recordID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：按 Android CheckInRecordDao.delete 语义物理删除指定打卡记录。
            // 涉及表：check_in_record。
            // 关键过滤：id 精确匹配；不创建 is_deleted tombstone。
            // 时间字段：无。
            // 副作用用途：立即移除日历、汇总与时间线中的打卡记录。
            try db.execute(
                sql: "DELETE FROM check_in_record WHERE id = ?",
                arguments: [recordID]
            )
            guard db.changesCount > 0 else { throw ReadCalendarRepositoryError.recordNotFound }
        }
    }

    /// 软删除阅读计时记录，保留同步链路消费的 is_deleted tombstone。
    nonisolated func softDeleteTiming(recordID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            let now = Self.currentMilliseconds()
            // SQL 目的：按 Android ReadTimeRecordDao.delete 语义软删除指定阅读计时记录。
            // 涉及表：read_time_record。
            // 关键过滤：id 精确匹配；重复请求仍更新同一记录，与 Android DAO 条件一致。
            // 时间字段：updated_date 写当前 Unix 毫秒时间戳。
            // 副作用用途：从有效日历、汇总和时间线查询移除记录，同时保留同步 tombstone。
            try db.execute(
                sql: "UPDATE read_time_record SET updated_date = ?, is_deleted = 1 WHERE id = ?",
                arguments: [now, recordID]
            )
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
        SELECT n.book_id, COUNT(*) AS total,
               MIN(n.created_date) AS first_event_time,
               MAX(n.created_date) AS last_event_time
        FROM note n
        JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
        WHERE n.is_deleted = 0 AND n.created_date BETWEEN ? AND ?
        GROUP BY n.book_id
        """

    // SQL 目的：按书籍聚合目标日有效相关内容数量与最早创建时间。
    // 涉及表：category_content JOIN book；过滤双方 is_deleted=0，created_date 为毫秒闭区间。
    // 返回字段用途：当日汇总相关内容指标与排序。
    nonisolated static let relevantDailyAggregateSQL = """
        SELECT c.book_id, COUNT(*) AS total,
               MIN(c.created_date) AS first_event_time,
               MAX(c.created_date) AS last_event_time
        FROM category_content c
        JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
        WHERE c.is_deleted = 0 AND c.created_date BETWEEN ? AND ?
        GROUP BY c.book_id
        """

    // SQL 目的：按书籍聚合目标日有效书评数量与最早创建时间。
    // 涉及表：review JOIN book；过滤双方 is_deleted=0，created_date 为毫秒闭区间。
    // 返回字段用途：当日汇总书评指标与排序。
    nonisolated static let reviewDailyAggregateSQL = """
        SELECT r.book_id, COUNT(*) AS total,
               MIN(r.created_date) AS first_event_time,
               MAX(r.created_date) AS last_event_time
        FROM review r
        JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
        WHERE r.is_deleted = 0 AND r.created_date BETWEEN ? AND ?
        GROUP BY r.book_id
        """

    // SQL 目的：按书籍聚合目标日有效打卡数量与最早打卡时间。
    // 涉及表：check_in_record JOIN book；过滤双方 is_deleted=0，checkin_date 为毫秒闭区间。
    // 返回字段用途：当日汇总打卡指标与排序。
    nonisolated static let checkInDailyAggregateSQL = """
        SELECT c.book_id, COUNT(*) AS total,
               MIN(c.checkin_date) AS first_event_time,
               MAX(c.checkin_date) AS last_event_time
        FROM check_in_record c
        JOIN book b ON b.id = c.book_id AND b.is_deleted = 0
        WHERE c.is_deleted = 0 AND c.checkin_date BETWEEN ? AND ?
        GROUP BY c.book_id
        """

    // SQL 目的：合并读完历史与 book 当前快照后，按书籍聚合目标日读完次数及首末时间。
    // 涉及表：book_read_status_record、book；过滤有效书籍、read_status_id=3，UNION 按书籍+时间去重。
    // 返回字段用途：当日汇总读完指标、封面标记与 Android 同源书籍集合排序。
    nonisolated static let readDoneDailyAggregateSQL = """
        WITH completed AS (
            SELECT r.book_id AS book_id, r.changed_date AS event_time
            FROM book_read_status_record r
            JOIN book b ON b.id = r.book_id AND b.is_deleted = 0
            WHERE r.is_deleted = 0
              AND r.read_status_id = 3
              AND r.changed_date BETWEEN ?1 AND ?2
            UNION
            SELECT b.id AS book_id, b.read_status_changed_date AS event_time
            FROM book b
            WHERE b.is_deleted = 0
              AND b.id != 0
              AND b.read_status_id = 3
              AND b.read_status_changed_date BETWEEN ?1 AND ?2
        )
        SELECT book_id, COUNT(*) AS total,
               MIN(event_time) AS first_event_time,
               MAX(event_time) AS last_event_time
        FROM completed
        GROUP BY book_id
        """
}
