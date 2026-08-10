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
        settingStore: BookReadingDetailSettingStore = BookReadingDetailSettingStore(),
        calendar: Calendar = .current
    ) {
        self.databaseManager = databaseManager
        self.settingStore = settingStore
        self.calendar = calendar
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

    /// 按 Android 两段式写入顺序先更新进度，再单独更新时间戳；第二段失败不会回滚已成功的进度。
    func updateProgress(bookID: Int64, input: BookReadingProgressInput) async throws {
        let book = try await databaseManager.database.dbPool.read { db in
            guard let book = try BookRecord
                .filter(Column("id") == bookID && Column("is_deleted") == 0 && Column("id") != 0)
                .fetchOne(db) else {
                throw BookReadingDetailRepositoryError.bookNotFound
            }
            return book
        }

        let now = Self.currentMilliseconds()
        let effectiveUnit = book.type == 0 ? Int64(2) : book.positionUnit
        try await databaseManager.database.dbPool.write { db in
            switch effectiveUnit {
            case 0:
                // SQL 目的：更新百分比制书籍的当前阅读进度。
                // 涉及表：book。
                // 关键过滤：id 精确匹配、is_deleted=0、id!=0，对齐 Android updateBookReadPosition。
                // 时间字段：updated_date 写当前毫秒时间戳；书签时间由后续独立写入完成。
                // 副作用用途：同步书架进度与阅读详情分析，不在仓储层改变已由页面校验的业务值。
                try db.execute(
                    sql: """
                        UPDATE book
                        SET read_position = ?, current_position_unit = position_unit,
                            updated_date = ?
                        WHERE id = ? AND is_deleted = 0 AND id != 0
                        """,
                    arguments: [input.currentValue, now, bookID]
                )
            case 1:
                guard let total = input.totalValue else {
                    throw BookReadingDetailRepositoryError.invalidProgress
                }
                // SQL 目的：更新位置制电子书的当前位置与总位置。
                // 涉及表：book。
                // 关键过滤：id 精确匹配、is_deleted=0、id!=0，对齐 Android updateBookReadTotalPosition。
                // 时间字段：updated_date 写当前毫秒时间戳；书签时间由后续独立写入完成。
                // 副作用用途：按 Android updateBookTotalPosition 同步阅读进度。
                try db.execute(
                    sql: """
                        UPDATE book
                        SET read_position = ?, total_position = ?, current_position_unit = position_unit,
                            updated_date = ?
                        WHERE id = ? AND is_deleted = 0 AND id != 0
                        """,
                    arguments: [input.currentValue, total, now, bookID]
                )
            default:
                guard let total = input.totalValue else {
                    throw BookReadingDetailRepositoryError.invalidProgress
                }
                // SQL 目的：更新页码制书籍的当前页与总页数。
                // 涉及表：book。
                // 关键过滤：id 精确匹配、is_deleted=0、id!=0，对齐 Android updateBookReadPagination。
                // 时间字段：updated_date 写当前毫秒时间戳；书签时间由后续独立写入完成。
                // 副作用用途：按 Android updateBookPagination 同步阅读进度。
                try db.execute(
                    sql: """
                        UPDATE book
                        SET read_position = ?, total_pagination = ?, current_position_unit = position_unit,
                            updated_date = ?
                        WHERE id = ? AND is_deleted = 0 AND id != 0
                        """,
                    arguments: [input.currentValue, total, now, bookID]
                )
            }
            guard db.changesCount > 0 else {
                throw BookReadingDetailRepositoryError.bookNotFound
            }
        }

        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：在进度写入完成后独立更新书签修改时间。
            // 涉及表：book。
            // 关键过滤：仅按 id 精确匹配，对齐 Android updateBookmarkModifiedTime，不附加 is_deleted/id!=0。
            // 时间字段：book_mark_modified_time 写当前 Unix 毫秒时间戳。
            // 副作用用途：更新书架最近进度排序；该写入与前一进度写入不处于同一事务。
            try db.execute(
                sql: "UPDATE book SET book_mark_modified_time = ? WHERE id = ?",
                arguments: [Self.currentMilliseconds(), bookID]
            )
        }
    }

    /// 追加状态历史；不复用全局“相同状态合并”入口，因为阅读详情明确要求每次追加形成独立记录。
    func addReadingStatus(bookID: Int64, statusID: Int64, changedAt: Date) async throws {
        let now = Self.currentMilliseconds()
        let changedAtMillis = Self.minuteMilliseconds(changedAt)
        try await databaseManager.database.dbPool.write { db in
            guard let bookState = try BookReadStatusMutation.fetchBookState(db, bookID: bookID) else {
                throw BookReadingDetailRepositoryError.bookNotFound
            }
            if let newest = try Self.fetchNewestStatus(db, bookID: bookID),
               newest.changedAt / 60_000 > changedAtMillis / 60_000 {
                throw BookReadingDetailRepositoryError.statusEarlierThanLatest(newest.changedAt)
            }

            try BookReadStatusMutation.insertBookReadStatusRecord(
                db,
                bookID: bookID,
                statusID: statusID,
                changedAt: changedAtMillis,
                createdAt: now
            )
            try Self.updateCurrentBookStatus(
                db,
                bookID: bookID,
                bookState: bookState,
                statusID: statusID,
                changedAt: changedAtMillis,
                updatedAt: now
            )
            try AnnualCollectionSync.syncAfterReadHistoryChanged(db, bookID: bookID)
        }
    }

    /// 精确更新目标历史，并以 created_date 最新的有效历史重新确定书籍当前状态。
    func updateReadingStatus(
        bookID: Int64,
        recordID: Int64,
        statusID: Int64,
        changedAt: Date
    ) async throws {
        let now = Self.currentMilliseconds()
        let changedAtMillis = Self.minuteMilliseconds(changedAt)
        try await databaseManager.database.dbPool.write { db in
            guard let bookState = try BookReadStatusMutation.fetchBookState(db, bookID: bookID) else {
                throw BookReadingDetailRepositoryError.bookNotFound
            }
            // SQL 目的：精确更新阅读详情中用户点选的状态历史。
            // 涉及表：book_read_status_record。
            // 关键过滤：id、book_id 精确匹配且 is_deleted=0，避免编辑串到其他书籍或墓碑记录。
            // 时间字段：changed_date 为用户选择的分钟精度毫秒，updated_date 为当前毫秒。
            // 副作用用途：保留原 created_date，供后续按创建时序选取当前状态。
            try db.execute(
                sql: """
                    UPDATE book_read_status_record
                    SET read_status_id = ?, changed_date = ?, updated_date = ?
                    WHERE id = ? AND book_id = ? AND is_deleted = 0
                    """,
                arguments: [statusID, changedAtMillis, now, recordID, bookID]
            )
            guard db.changesCount > 0 else {
                throw BookReadingDetailRepositoryError.statusNotFound
            }
            guard let current = try Self.fetchCurrentStatusByCreation(db, bookID: bookID) else {
                throw BookReadingDetailRepositoryError.statusNotFound
            }
            try Self.updateCurrentBookStatus(
                db,
                bookID: bookID,
                bookState: bookState,
                statusID: current.statusID,
                changedAt: current.changedAt,
                updatedAt: now
            )
            try AnnualCollectionSync.syncAfterReadHistoryChanged(db, bookID: bookID)
        }
    }

    /// 软删除目标状态，并把 book 当前状态回落到 changed_date 最新的剩余记录。
    func deleteReadingStatus(bookID: Int64, recordID: Int64) async throws {
        let now = Self.currentMilliseconds()
        try await databaseManager.database.dbPool.write { db in
            guard let bookState = try BookReadStatusMutation.fetchBookState(db, bookID: bookID) else {
                throw BookReadingDetailRepositoryError.bookNotFound
            }
            let count = try Self.fetchActiveStatusCount(db, bookID: bookID)
            guard count > 1 else {
                throw BookReadingDetailRepositoryError.cannotDeleteOnlyStatus
            }

            // SQL 目的：软删除阅读详情中用户确认删除的状态历史。
            // 涉及表：book_read_status_record。
            // 关键过滤：id、book_id 精确匹配且 is_deleted=0。
            // 时间字段：updated_date 写当前毫秒；is_deleted=1 保留同步墓碑。
            // 副作用用途：从时间线与统计查询移除记录，同时保留跨端同步语义。
            try db.execute(
                sql: """
                    UPDATE book_read_status_record
                    SET updated_date = ?, is_deleted = 1
                    WHERE id = ? AND book_id = ? AND is_deleted = 0
                    """,
                arguments: [now, recordID, bookID]
            )
            guard db.changesCount > 0 else {
                throw BookReadingDetailRepositoryError.statusNotFound
            }
            guard let current = try Self.fetchNewestStatus(db, bookID: bookID) else {
                throw BookReadingDetailRepositoryError.statusNotFound
            }
            try Self.updateCurrentBookStatus(
                db,
                bookID: bookID,
                bookState: bookState,
                statusID: current.statusID,
                changedAt: current.changedAt,
                updatedAt: now
            )
            try AnnualCollectionSync.syncAfterReadHistoryChanged(db, bookID: bookID)
        }
    }

    /// 读取庆祝追踪数据；目标缺失时在同一事务插入 Android 默认年度目标 12。
    func fetchCompletionTracker() async throws -> BookReadingCompletionTracker {
        let calendar = calendar
        return try await databaseManager.database.dbPool.write { db in
            let now = Date()
            let year = calendar.component(.year, from: now)
            let yearInterval = calendar.dateInterval(of: .year, for: now)
            let start = Int64((yearInterval?.start ?? now).timeIntervalSince1970 * 1_000)
            let end = Int64(((yearInterval?.end ?? now).timeIntervalSince1970 * 1_000).rounded(.down)) - 1
            let total = try Self.fetchCompletedBookCount(db)
            let currentYear = try Self.fetchCompletedBookCount(db, start: start, end: end)
            let target = try Self.fetchOrCreateAnnualTarget(db, year: year)
            return BookReadingCompletionTracker(
                totalCompletedBookCount: total,
                completedBookCountThisYear: currentYear,
                targetBookCountThisYear: target
            )
        }
    }

    func fetchSetting() -> BookReadingDetailSetting { settingStore.fetchSetting() }
    func saveSetting(_ setting: BookReadingDetailSetting) { settingStore.saveSetting(setting) }
    func fetchShareSetting() -> BookReadingDetailShareSetting { settingStore.fetchShareSetting() }
    func saveShareSetting(_ setting: BookReadingDetailShareSetting) { settingStore.saveShareSetting(setting) }
}

private extension BookReadingDetailRepository {
    /// 查询 id 语义上的最新有效状态，用于新增时间校验与删除后的当前状态回落。
    nonisolated static func fetchNewestStatus(
        _ db: Database,
        bookID: Int64
    ) throws -> (id: Int64, statusID: Int64, changedAt: Int64)? {
        // SQL 目的：查询指定书籍最新有效状态历史。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id 精确匹配、is_deleted=0；按 id DESC、changed_date DESC 对齐 Android DAO。
        // 时间字段：changed_date 为 Unix 毫秒，用于新增状态分钟级单调校验或回写 book 当前状态。
        // 返回字段用途：id 标识记录，read_status_id/changed_date 形成当前状态快照。
        let sql = """
            SELECT id, read_status_id, changed_date
            FROM book_read_status_record
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY id DESC, changed_date DESC
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else { return nil }
        return (row["id"], row["read_status_id"], row["changed_date"])
    }

    /// 查询 created_date 最新的状态，复刻 Android 编辑历史后重算当前状态的选择规则。
    nonisolated static func fetchCurrentStatusByCreation(
        _ db: Database,
        bookID: Int64
    ) throws -> (statusID: Int64, changedAt: Int64)? {
        // SQL 目的：编辑历史后按记录创建时序选出书籍当前状态。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id 精确匹配、is_deleted=0；created_date DESC 为 Android maxBy(createDate) 主规则，id DESC 仅消除并列不确定性。
        // 时间字段：created_date/changed_date 均为 Unix 毫秒，不做时区换算。
        // 返回字段用途：read_status_id/changed_date 回写 book 当前快照。
        let sql = """
            SELECT read_status_id, changed_date
            FROM book_read_status_record
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY created_date DESC, id DESC
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else { return nil }
        return (row["read_status_id"], row["changed_date"])
    }

    /// 查询有效状态数量，保护唯一历史不被删除。
    nonisolated static func fetchActiveStatusCount(_ db: Database, bookID: Int64) throws -> Int {
        // SQL 目的：删除前确认指定书籍至少保留一条阅读状态。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id 精确匹配、is_deleted=0。
        // 时间字段：无。
        // 返回字段用途：数量等于 1 时抛出 Android 同文案业务错误。
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM book_read_status_record WHERE book_id = ? AND is_deleted = 0",
            arguments: [bookID]
        ) ?? 0
    }

    /// 写回 book 当前状态，并在当前状态为读完时同步终点进度。
    nonisolated static func updateCurrentBookStatus(
        _ db: Database,
        bookID: Int64,
        bookState: (userID: Int64, positionUnit: Int64, totalPosition: Int64, totalPagination: Int64),
        statusID: Int64,
        changedAt: Int64,
        updatedAt: Int64
    ) throws {
        try BookReadStatusMutation.updateBookCurrentReadStatus(
            db,
            bookID: bookID,
            userID: bookState.userID,
            statusID: statusID,
            changedAt: changedAt,
            updatedAt: updatedAt
        )
        if statusID == 3 {
            try BookReadStatusMutation.markBookAsFinished(
                db,
                bookID: bookID,
                positionUnit: bookState.positionUnit,
                totalPosition: bookState.totalPosition,
                totalPagination: bookState.totalPagination,
                updatedAt: updatedAt
            )
        }
    }

    /// 查询历史状态与当前快照并集形成的累计读完书籍数，只接受仍有效的书籍。
    nonisolated static func fetchCompletedBookCount(
        _ db: Database,
        start: Int64? = nil,
        end: Int64? = nil
    ) throws -> Int {
        let rangePredicate: String
        let arguments: StatementArguments
        if let start, let end {
            rangePredicate = "AND completed_at >= ? AND completed_at <= ?"
            arguments = [start, end, start, end]
        } else {
            rangePredicate = "AND completed_at > 0"
            arguments = []
        }
        // SQL 目的：统计历史上或指定年份内至少读完过一次的有效书籍数。
        // 涉及表：book_read_status_record INNER JOIN book，与 book 当前状态快照 UNION 去重。
        // 关键过滤：两路均要求 book.is_deleted=0、book.id!=0、READ_DONE=3；历史记录额外要求 is_deleted=0。
        // 时间字段：completed_at 为 changed_date/read_status_changed_date Unix 毫秒，可选闭区间按本地自然年传入。
        // 返回字段用途：生成 Android CelebrationConfettiView.ReadingTracker 的累计和本年数量。
        let sql = """
            SELECT COUNT(DISTINCT book_id)
            FROM (
                SELECT r.book_id AS book_id, r.changed_date AS completed_at
                FROM book_read_status_record r
                JOIN book b ON b.id = r.book_id
                WHERE r.read_status_id = 3
                  AND r.is_deleted = 0
                  AND r.book_id != 0
                  AND b.is_deleted = 0
                  AND b.id != 0
                  \(rangePredicate)
                UNION
                SELECT b.id AS book_id, b.read_status_changed_date AS completed_at
                FROM book b
                WHERE b.read_status_id = 3
                  AND b.is_deleted = 0
                  AND b.id != 0
                  \(rangePredicate)
            ) completed_books
            """
        return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    /// 读取或创建当前年度读书目标，保持 Android 缺省 12 本和 read_target 字段默认语义。
    nonisolated static func fetchOrCreateAnnualTarget(_ db: Database, year: Int) throws -> Int {
        // SQL 目的：读取当前年份的读完书籍数量目标。
        // 涉及表：read_target。
        // 关键过滤：time=自然年、type=0、is_deleted=0，LIMIT 1 对齐 Android ReadTargetDao。
        // 时间字段：time 保存年份整数而非时间戳。
        // 返回字段用途：庆祝层显示年度完成进度。
        let query = "SELECT target FROM read_target WHERE time = ? AND type = 0 AND is_deleted = 0 LIMIT 1"
        if let target = try Int64.fetchOne(db, sql: query, arguments: [year]) {
            return Int(target)
        }
        var record = ReadTargetRecord(
            id: nil,
            time: Int64(year),
            target: 12,
            type: 0,
            createdDate: 0,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
        return 12
    }

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

        let statusOrder: [Int64] = [1, 2, 3, 5, 4]
        let statusOrderIndex = Dictionary(uniqueKeysWithValues: statusOrder.enumerated().map { ($0.element, $0.offset) })
        let statusOptions = try ReadStatusRecord
            .filter(Column("is_deleted") == 0)
            .fetchAll(db)
            .map { BookReadingStatusOption(id: $0.id, title: $0.name) }
            .filter { statusOrderIndex[$0.id] != nil }
            .sorted { (statusOrderIndex[$0.id] ?? .max) < (statusOrderIndex[$1.id] ?? .max) }
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
            .order(Column("created_date"), Column("id"))
            .fetchAll(db)
        var groupNames: [String] = []
        for relation in groupRelations {
            guard let group = try GroupRecord
                .filter(Column("id") == relation.groupId && Column("is_deleted") == 0)
                .fetchOne(db),
                  let name = group.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            groupNames.append(name)
            break
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

        let timingDaySlices = splitTimingDaySlices(timings, calendar: calendar)
        let splitDurations = Dictionary(grouping: timingDaySlices, by: \.date)
            .mapValues { slices in slices.reduce(Int64.zero) { $0 + $1.seconds } }
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
        }
        activityDays.formUnion(timingDaySlices.map(\.date))
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

        let latest: Date
        if book.readStatusId == 3, book.readStatusChangedDate > 0 {
            let latestNote = notes.compactMap { $0.createdDate > 0 ? day(for: $0.createdDate, calendar: calendar) : nil }.max()
            let latestTiming = timings.compactMap { timing -> Date? in
                let value = timing.fuzzyReadDate != 0 ? timing.fuzzyReadDate : timing.startTime
                return value > 0 ? day(for: value, calendar: calendar) : nil
            }.max()
            let latestCheckIn = allCheckIns.compactMap {
                $0.checkinDate > 0 ? day(for: $0.checkinDate, calendar: calendar) : nil
            }.max()
            latest = [
                day(for: book.readStatusChangedDate, calendar: calendar),
                latestNote,
                latestTiming,
                latestCheckIn
            ]
            .compactMap { $0 }
            .max() ?? day(for: book.readStatusChangedDate, calendar: calendar)
        } else {
            latest = calendar.startOfDay(for: Date())
        }

        let history = makeStatusHistory(
            statusRecords,
            statusNames: statusNames,
            bookCreatedAt: book.createdDate
        )

        let readDoneCountFromHistory = statusRecords.filter { $0.readStatusId == 3 }.count
        let readDoneCount = readDoneCountFromHistory == 0 && book.readStatusId == 3
            ? 1
            : readDoneCountFromHistory
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
                readDoneCount: readDoneCount
            ),
            readStatusChangedAt: book.readStatusChangedDate,
            readDoneCount: readDoneCount,
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

    /// Android 跨日分摊后的单日计时切片；零秒切片仍保留活动日语义。
    nonisolated struct TimingDaySlice {
        let date: Date
        let seconds: Int64
    }

    /// 将计时记录转换为 Android `splitCrossDayRecords` 同口径的自然日切片。
    nonisolated static func splitTimingDaySlices(
        _ records: [ReadTimeRecordRecord],
        calendar: Calendar
    ) -> [TimingDaySlice] {
        var slices: [TimingDaySlice] = []
        for record in records {
            if record.fuzzyReadDate != 0 {
                slices.append(
                    TimingDaySlice(
                        date: day(for: record.fuzzyReadDate, calendar: calendar),
                        seconds: max(0, record.elapsedSeconds)
                    )
                )
                continue
            }
            guard record.startTime > 0 else { continue }

            let startDate = Date(timeIntervalSince1970: Double(record.startTime) / 1_000)
            let endDate = Date(timeIntervalSince1970: Double(record.endTime) / 1_000)
            let startDay = calendar.startOfDay(for: startDate)
            let endDay = calendar.startOfDay(for: endDate)
            if record.endTime <= record.startTime || startDay == endDay {
                slices.append(TimingDaySlice(date: startDay, seconds: max(0, record.elapsedSeconds)))
                continue
            }

            let totalWallClockMillis = record.endTime - record.startTime
            let totalReadingSeconds = max(0, record.elapsedSeconds)
            guard totalReadingSeconds > 0, totalWallClockMillis > 0 else { continue }

            var cursorMillis = record.startTime
            var allocatedSeconds: Int64 = 0
            while cursorMillis <= record.endTime, allocatedSeconds < totalReadingSeconds {
                let cursorDate = Date(timeIntervalSince1970: Double(cursorMillis) / 1_000)
                let cursorDay = calendar.startOfDay(for: cursorDate)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursorDay) else { break }
                let nextDayMillis = Int64((nextDay.timeIntervalSince1970 * 1_000).rounded())
                let segmentEndMillis = min(record.endTime, nextDayMillis - 1)
                guard cursorMillis < segmentEndMillis else {
                    cursorMillis = nextDayMillis
                    continue
                }
                let segmentWallClockMillis = segmentEndMillis - cursorMillis
                let proportionalSeconds = Double(segmentWallClockMillis) / Double(totalWallClockMillis)
                    * Double(totalReadingSeconds)
                let roundedSeconds = Int64(floor(proportionalSeconds + 0.5))
                let segmentSeconds = min(roundedSeconds, totalReadingSeconds - allocatedSeconds)
                slices.append(TimingDaySlice(date: cursorDay, seconds: segmentSeconds))
                allocatedSeconds += segmentSeconds
                cursorMillis = segmentEndMillis + 1
            }
        }
        return slices
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

    /// 将状态时间截断到本地交互允许的分钟精度，避免隐藏秒值造成跨端排序差异。
    nonisolated static func minuteMilliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000) / 60_000 * 60_000
    }
}

/// 阅读详情写入错误，供页面映射为可感知反馈。
enum BookReadingDetailRepositoryError: LocalizedError {
    case bookNotFound
    case invalidProgress
    case statusNotFound
    case cannotDeleteOnlyStatus
    case statusEarlierThanLatest(Int64)

    var errorDescription: String? {
        switch self {
        case .bookNotFound:
            "书籍不存在或已被删除"
        case .invalidProgress:
            "阅读进度信息不完整"
        case .statusNotFound:
            "阅读状态不存在或已被删除"
        case .cannotDeleteOnlyStatus:
            "无法删除书籍仅有的阅读状态，请改为更新"
        case .statusEarlierThanLatest(let milliseconds):
            "新状态记录时间不能早于上一状态，上一状态时间：\(Self.statusDateFormatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)))"
        }
    }

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
