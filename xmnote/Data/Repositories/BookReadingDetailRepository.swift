/**
 * [INPUT]: 依赖 DatabaseManager、GRDB、BookReadStatusMutation、ObservationStream 与阅读详情领域模型
 * [OUTPUT]: 对外提供 BookReadingDetailRepository，产出 Android 对齐的单书阅读分析并负责评分/进度/状态写入
 * [POS]: Data 层单书阅读详情业务真相源，集中收敛跨表统计、跨日计时和偏好持久化
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 单书阅读详情仓储；观察闭包在数据库读连接执行，页面取消迭代后底层 GRDB 观察随之终止。
nonisolated struct BookReadingDetailRepository: BookReadingDetailRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let settingStore: BookReadingDetailSettingStore
    private let calendar: Calendar

    /// 注入共享数据库与偏好存储。
    init(
        databaseManager: DatabaseManager,
        settingStore: BookReadingDetailSettingStore = BookReadingDetailSettingStore()
    ) {
        self.databaseManager = databaseManager
        self.settingStore = settingStore
        self.calendar = Calendar.current
    }

    /// 观察单书完整快照；GRDB 会追踪闭包访问到的全部业务表，任一相关写入都会重新聚合。
    func observeSnapshot(bookID: Int64) -> AsyncThrowingStream<BookReadingDetailSnapshot?, Error> {
        let calendar = calendar
        return ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try Self.buildSnapshot(db, bookID: bookID, calendar: calendar)
        }
    }

    /// 按 Android BookDao.rating 过滤有效书籍并更新业务评分。
    func updateRating(bookID: Int64, score: Int64) async throws {
        let normalized = min(max(score, 0), 50)
        let now = Self.currentMilliseconds()
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：更新单本有效书籍的 0...50 评分。
            // 涉及表：book。
            // 关键过滤：id 精确匹配且 is_deleted=0，对齐 Android BookDao.rating。
            // 时间字段：updated_date 写当前毫秒时间戳，不涉及时区换算。
            // 副作用用途：触发阅读详情观察流刷新页头评分。
            try db.execute(
                sql: "UPDATE book SET score = ?, updated_date = ? WHERE id = ? AND is_deleted = 0",
                arguments: [normalized, now, bookID]
            )
        }
    }

    /// 按 position_unit 写回百分比、位置或页码，并同步 Android 的书签修改时间。
    func updateProgress(bookID: Int64, input: BookReadingProgressInput) async throws {
        let now = Self.currentMilliseconds()
        try await databaseManager.database.dbPool.write { db in
            guard let book = try BookRecord
                .filter(Column("id") == bookID && Column("is_deleted") == 0)
                .fetchOne(db) else {
                throw BookReadingDetailRepositoryError.bookNotFound
            }

            let current = max(0, input.currentValue)
            switch book.positionUnit {
            case 0:
                // SQL 目的：更新百分比制书籍的当前阅读进度。
                // 涉及表：book。
                // 关键过滤：id 精确匹配且 is_deleted=0。
                // 时间字段：updated_date/book_mark_modified_time 均写当前毫秒时间戳。
                // 副作用用途：同步书架进度与阅读详情分析。
                try db.execute(
                    sql: """
                        UPDATE book
                        SET read_position = ?, current_position_unit = position_unit,
                            updated_date = ?, book_mark_modified_time = ?
                        WHERE id = ? AND is_deleted = 0
                        """,
                    arguments: [min(current, 100), now, now, bookID]
                )
            case 1:
                let total = max(0, input.totalValue ?? book.totalPosition)
                // SQL 目的：更新位置制电子书的当前位置与总位置。
                // 涉及表：book。
                // 关键过滤：id 精确匹配且 is_deleted=0。
                // 时间字段：updated_date/book_mark_modified_time 均写当前毫秒时间戳。
                // 副作用用途：按 Android updateBookTotalPosition 同步阅读进度。
                try db.execute(
                    sql: """
                        UPDATE book
                        SET read_position = ?, total_position = ?, current_position_unit = position_unit,
                            updated_date = ?, book_mark_modified_time = ?
                        WHERE id = ? AND is_deleted = 0
                        """,
                    arguments: [current, total, now, now, bookID]
                )
            default:
                let total = max(0, input.totalValue ?? book.totalPagination)
                // SQL 目的：更新页码制书籍的当前页与总页数。
                // 涉及表：book。
                // 关键过滤：id 精确匹配且 is_deleted=0。
                // 时间字段：updated_date/book_mark_modified_time 均写当前毫秒时间戳。
                // 副作用用途：按 Android updateBookPagination 同步阅读进度。
                try db.execute(
                    sql: """
                        UPDATE book
                        SET read_position = ?, total_pagination = ?, current_position_unit = position_unit,
                            updated_date = ?, book_mark_modified_time = ?
                        WHERE id = ? AND is_deleted = 0
                        """,
                    arguments: [current, total, now, now, bookID]
                )
            }
        }
    }

    /// 使用共享状态写入协作者复刻 Android 最新同状态合并、读完推进进度及年度书单副作用。
    func updateReadingStatus(bookID: Int64, statusID: Int64, changedAt: Date) async throws {
        let now = Self.currentMilliseconds()
        let changedAtMillis = Int64(changedAt.timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
            try BookReadStatusMutation.updateBookReadStatus(
                db,
                bookID: bookID,
                statusID: statusID,
                changedAt: changedAtMillis,
                updatedAt: now,
                finishedRatingScore: nil
            )
        }
    }

    func fetchSetting() -> BookReadingDetailSetting { settingStore.fetchSetting() }
    func saveSetting(_ setting: BookReadingDetailSetting) { settingStore.saveSetting(setting) }
    func fetchShareSetting() -> BookReadingDetailShareSetting { settingStore.fetchShareSetting() }
    func saveShareSetting(_ setting: BookReadingDetailShareSetting) { settingStore.saveShareSetting(setting) }
}

private extension BookReadingDetailRepository {
    /// 在同一数据库快照中读取并聚合详情，避免页头、分析和图表跨事务互相漂移。
    nonisolated static func buildSnapshot(
        _ db: Database,
        bookID: Int64,
        calendar: Calendar
    ) throws -> BookReadingDetailSnapshot? {
        guard let book = try BookRecord
            .filter(Column("id") == bookID && Column("is_deleted") == 0 && Column("id") != 0)
            .fetchOne(db), let resolvedID = book.id else {
            return nil
        }

        let statusOptions = try ReadStatusRecord
            .filter(Column("is_deleted") == 0)
            .order(Column("read_status_order"), Column("id"))
            .fetchAll(db)
            .map { BookReadingStatusOption(id: $0.id, title: $0.name) }
        let statusNames = Dictionary(uniqueKeysWithValues: statusOptions.map { ($0.id, $0.title) })

        let notes = try NoteRecord
            .filter(Column("book_id") == bookID && Column("is_deleted") == 0)
            .order(Column("created_date"))
            .fetchAll(db)
        let relevant = try CategoryContentRecord
            .filter(Column("book_id") == bookID && Column("is_deleted") == 0)
            .order(Column("created_date"))
            .fetchAll(db)
        let reviews = try ReviewRecord
            .filter(Column("book_id") == bookID && Column("is_deleted") == 0)
            .order(Column("created_date"))
            .fetchAll(db)
        let timings = try ReadTimeRecordRecord
            .filter(
                Column("book_id") == bookID &&
                Column("is_deleted") == 0 &&
                Column("status") == 3
            )
            .order(Column("start_time"), Column("fuzzy_read_date"), Column("id"))
            .fetchAll(db)
        // Android getReadingDayCountAndLastReadingDate/getBookRealStartReadingDate intentionally do not
        // filter check_in_record.is_deleted; preserve that exact analytics behavior here.
        let allCheckIns = try CheckInRecordRecord
            .filter(Column("book_id") == bookID)
            .order(Column("checkin_date"))
            .fetchAll(db)
        let validCheckIns = allCheckIns.filter { $0.isDeleted == 0 }
        let statusRecords = try BookReadStatusRecordRecord
            .filter(Column("book_id") == bookID && Column("is_deleted") == 0)
            .order(Column("id").desc, Column("changed_date").desc)
            .fetchAll(db)
        let sourceName = try SourceRecord
            .filter(Column("id") == book.sourceId && Column("is_deleted") == 0)
            .fetchOne(db)?.name ?? ""
        let groupRelations = try GroupBookRecord
            .filter(Column("book_id") == bookID && Column("is_deleted") == 0)
            .order(Column("id"))
            .fetchAll(db)
        var groupNames: [String] = []
        for relation in groupRelations {
            guard let group = try GroupRecord
                .filter(Column("id") == relation.groupId && Column("is_deleted") == 0)
                .fetchOne(db),
                  let name = group.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            groupNames.append(name)
        }
        let tagRelations = try TagBookRecord
            .filter(Column("book_id") == bookID && Column("is_deleted") == 0)
            .order(Column("id"))
            .fetchAll(db)
        var tagNames: [String] = []
        for relation in tagRelations {
            guard let tag = try TagRecord
                .filter(Column("id") == relation.tagId && Column("is_deleted") == 0)
                .fetchOne(db),
                  let name = tag.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            tagNames.append(name)
        }

        let splitDurations = splitTimingDurations(timings, calendar: calendar)
        var activityDays = Set<Date>()
        var actualStartCandidates: [Int64] = []

        func appendContentDate(_ value: Int64) {
            guard value > 0 else { return }
            activityDays.insert(day(for: value, calendar: calendar))
            actualStartCandidates.append(value)
        }

        notes.forEach { appendContentDate($0.createdDate) }
        relevant.forEach { appendContentDate($0.createdDate) }
        reviews.forEach { appendContentDate($0.createdDate) }
        allCheckIns.forEach {
            guard $0.checkinDate > 0 else { return }
            activityDays.insert(day(for: $0.checkinDate, calendar: calendar))
            actualStartCandidates.append($0.checkinDate)
        }
        for timing in timings {
            let start = timing.fuzzyReadDate != 0 ? timing.fuzzyReadDate : timing.startTime
            if start > 0 { actualStartCandidates.append(start) }
            if timing.fuzzyReadDate != 0 {
                activityDays.insert(day(for: timing.fuzzyReadDate, calendar: calendar))
            } else if timing.startTime > 0 {
                let end = timing.startTime + max(0, timing.elapsedSeconds) * 1_000
                var cursor = day(for: timing.startTime, calendar: calendar)
                let endDay = day(for: end, calendar: calendar)
                while cursor <= endDay {
                    activityDays.insert(cursor)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
                    cursor = next
                }
            }
        }
        for status in statusRecords where status.readStatusId == 3 && status.changedDate > 0 {
            activityDays.insert(day(for: status.changedDate, calendar: calendar))
        }

        let totalReadingSeconds = timings.reduce(Int64.zero) { $0 + max(0, $1.elapsedSeconds) }
        let statusStart = statusRecords
            .filter { $0.readStatusId == 2 && $0.changedDate > 0 }
            .map(\.changedDate)
            .min() ?? (book.readStatusId == 2 && book.readStatusChangedDate > 0 ? book.readStatusChangedDate : 0)
        let progress = makeProgress(book)

        var heatmapDays: [Date: HeatmapDay] = [:]
        let noteCounts = Dictionary(grouping: notes, by: { day(for: $0.createdDate, calendar: calendar) })
            .mapValues(\.count)
        let validCheckInsByDay = Dictionary(grouping: validCheckIns, by: { day(for: $0.checkinDate, calendar: calendar) })
        var statesByDay: [Date: Set<HeatmapBookState>] = [:]
        for record in statusRecords where record.changedDate > 0 {
            guard let state = HeatmapBookState(rawValue: Int(record.readStatusId)) else { continue }
            statesByDay[day(for: record.changedDate, calendar: calendar), default: []].insert(state)
        }
        let heatmapKeys = Set(noteCounts.keys)
            .union(splitDurations.keys)
            .union(validCheckInsByDay.keys)
            .union(statesByDay.keys)
        for date in heatmapKeys {
            let checkIns = validCheckInsByDay[date] ?? []
            heatmapDays[date] = HeatmapDay(
                id: date,
                readSeconds: Int(splitDurations[date] ?? 0),
                noteCount: noteCounts[date] ?? 0,
                checkInCount: checkIns.count,
                checkInSeconds: checkIns.reduce(0) { $0 + Int($1.amount) * 20 * 60 },
                bookStates: statesByDay[date] ?? []
            )
        }

        let createdDay = book.createdDate > 0 ? day(for: book.createdDate, calendar: calendar) : nil
        let earliestTiming = timings.compactMap { timing -> Date? in
            let value = timing.fuzzyReadDate != 0 ? timing.fuzzyReadDate : timing.startTime
            return value > 0 ? day(for: value, calendar: calendar) : nil
        }.min()
        let earliestCheckIn = validCheckIns.compactMap { $0.checkinDate > 0 ? day(for: $0.checkinDate, calendar: calendar) : nil }.min()
        let earliest = [createdDay, earliestTiming, earliestCheckIn].compactMap { $0 }.min()

        let latestActivity = heatmapKeys.max()
        let latest: Date
        if book.readStatusId == 3, book.readStatusChangedDate > 0 {
            latest = max(day(for: book.readStatusChangedDate, calendar: calendar), latestActivity ?? .distantPast)
        } else {
            latest = calendar.startOfDay(for: Date())
        }

        let history = makeStatusHistory(
            statusRecords,
            statusNames: statusNames,
            bookCreatedAt: book.createdDate
        )

        let domainBook = BookReadingDetailBook(
            id: resolvedID,
            name: book.name,
            coverURL: book.cover,
            author: book.author,
            translator: book.translator,
            isbn: book.isbn,
            publicationDate: book.pubDate,
            press: book.press,
            summary: book.summary,
            score: book.score,
            bookType: book.type,
            currentPositionUnit: book.currentPositionUnit,
            positionUnit: book.positionUnit,
            readPosition: book.readPosition,
            totalPosition: book.totalPosition,
            totalPagination: book.totalPagination,
            readStatusID: book.readStatusId,
            readStatusName: statusDisplayName(
                statusID: book.readStatusId,
                fallbackName: statusNames[book.readStatusId] ?? fallbackStatusName(book.readStatusId),
                readDoneCount: statusRecords.filter { $0.readStatusId == 3 }.count
            ),
            readStatusChangedAt: book.readStatusChangedDate,
            sourceName: sourceName,
            groupNames: groupNames,
            tagNames: tagNames,
            wordCount: book.wordCount,
            price: book.price,
            createdAt: book.createdDate
        )
        let analytics = BookReadingAnalytics(
            readingDayCount: activityDays.count,
            lastReadingAt: activityDays.max().map { Int64($0.timeIntervalSince1970 * 1_000) },
            progress: progress,
            totalReadingSeconds: totalReadingSeconds,
            actualStartAt: actualStartCandidates.min(),
            statusStartAt: statusStart > 0 ? statusStart : nil,
            noteCount: notes.count,
            ideaCount: notes.filter { !$0.idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        )

        return BookReadingDetailSnapshot(
            book: domainBook,
            heatmapDays: heatmapDays,
            heatmapEarliestDate: earliest,
            heatmapLatestDate: latest,
            analytics: analytics,
            monthlyDurations: makeMonths(splitDurations, calendar: calendar),
            statusHistory: history,
            statusOptions: statusOptions
        )
    }

    nonisolated static func makeProgress(_ book: BookRecord) -> BookReadingProgress {
        switch book.positionUnit {
        case 0:
            return BookReadingProgress(
                unit: 0,
                currentValue: book.readPosition,
                totalValue: nil,
                fraction: min(max(book.readPosition / 100, 0), 1)
            )
        case 1:
            return BookReadingProgress(
                unit: 1,
                currentValue: book.readPosition,
                totalValue: book.totalPosition,
                fraction: book.totalPosition > 0 ? book.readPosition / Double(book.totalPosition) : nil
            )
        default:
            return BookReadingProgress(
                unit: 2,
                currentValue: book.readPosition,
                totalValue: book.totalPagination,
                fraction: book.totalPagination > 0 ? book.readPosition / Double(book.totalPagination) : nil
            )
        }
    }

    /// 将精确计时按本地自然日边界切分；模糊计时完整归入 fuzzy_read_date 所在日。
    nonisolated static func splitTimingDurations(
        _ records: [ReadTimeRecordRecord],
        calendar: Calendar
    ) -> [Date: Int64] {
        var values: [Date: Int64] = [:]
        for record in records where record.elapsedSeconds > 0 {
            if record.fuzzyReadDate != 0 {
                values[day(for: record.fuzzyReadDate, calendar: calendar), default: 0] += record.elapsedSeconds
                continue
            }
            guard record.startTime > 0 else { continue }
            var cursor = Date(timeIntervalSince1970: Double(record.startTime) / 1_000)
            var remaining = record.elapsedSeconds
            while remaining > 0 {
                let dateKey = calendar.startOfDay(for: cursor)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dateKey) else { break }
                let secondsToBoundary = max(1, Int64(nextDay.timeIntervalSince(cursor).rounded(.up)))
                let segment = min(remaining, secondsToBoundary)
                values[dateKey, default: 0] += segment
                remaining -= segment
                cursor = nextDay
            }
        }
        return values
    }

    nonisolated static func makeMonths(
        _ durations: [Date: Int64],
        calendar: Calendar
    ) -> [BookReadingMonthDuration] {
        let groups = Dictionary(grouping: durations.keys) { date in
            DateComponents(
                year: calendar.component(.year, from: date),
                month: calendar.component(.month, from: date)
            )
        }
        return groups.map { components, dates in
            BookReadingMonthDuration(
                year: components.year ?? 0,
                month: components.month ?? 0,
                days: dates.sorted().map { BookReadingDailyDuration(date: $0, seconds: durations[$0] ?? 0) }
            )
        }
        .sorted { lhs, rhs in
            lhs.year == rhs.year ? lhs.month > rhs.month : lhs.year > rhs.year
        }
    }

    nonisolated static func makeStatusHistory(
        _ records: [BookReadStatusRecordRecord],
        statusNames: [Int64: String],
        bookCreatedAt: Int64
    ) -> [BookReadingStatusHistoryItem] {
        var items = records.map {
            BookReadingStatusHistoryItem(
                recordID: $0.id,
                statusID: $0.readStatusId,
                statusName: statusNames[$0.readStatusId] ?? fallbackStatusName($0.readStatusId),
                changedAt: $0.changedDate,
                isSyntheticShelfNode: false
            )
        }
        .sorted { lhs, rhs in
            lhs.changedAt == rhs.changedAt
                ? (lhs.recordID ?? 0) > (rhs.recordID ?? 0)
                : lhs.changedAt > rhs.changedAt
        }

        let oldest = items.last
        let shelfDate = oldest?.statusID == 2 ? (oldest?.changedAt ?? bookCreatedAt) : bookCreatedAt
        items.append(
            BookReadingStatusHistoryItem(
                recordID: nil,
                statusID: 0,
                statusName: "加入书架",
                changedAt: shelfDate,
                isSyntheticShelfNode: true
            )
        )
        return items
    }

    nonisolated static func fallbackStatusName(_ statusID: Int64) -> String {
        switch statusID {
        case 1: "想读"
        case 2: "在读"
        case 3: "读完"
        case 4: "弃读"
        case 5: "搁置"
        default: "未设置"
        }
    }

    /// 将 Android Book.readingStatusName 的多刷语义映射到页头状态文本。
    nonisolated static func statusDisplayName(
        statusID: Int64,
        fallbackName: String,
        readDoneCount: Int
    ) -> String {
        if statusID == 3, readDoneCount > 1 {
            return "\(readDoneCount) 刷"
        }
        if statusID == 2, readDoneCount >= 1 {
            return "\(readDoneCount + 1) 刷中"
        }
        return fallbackName
    }

    nonisolated static func day(for milliseconds: Int64, calendar: Calendar) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    nonisolated static func currentMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

/// 阅读详情写入错误，供页面映射为可感知反馈。
enum BookReadingDetailRepositoryError: LocalizedError {
    case bookNotFound

    var errorDescription: String? { "书籍不存在或已被删除" }
}
