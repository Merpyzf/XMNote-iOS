/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 V44 book、read_time_record 表与可注入毫秒时钟
 * [OUTPUT]: 对外提供 Android ReadTimeWebService/ReadingRecordWebService 的计时创建与记录 CRUD 能力
 * [POS]: Data 层网页阅读记录专用仓储；独立复刻 Android Web 路径，不让 XMNoteWeb 接触 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// WebReadingRecordDto 的 Data 层投影。
nonisolated struct DesktopWebReadingRecordSnapshot: Sendable, Equatable {
    let id: Int64
    let bookID: Int64
    let mode: String
    let startTime: Int64
    let endTime: Int64
    let fuzzyReadDate: Int64
    let elapsedSeconds: Int64
    let countdownSeconds: Int64
    let pausedDurationMillis: Int64
    let position: Double
    let recordedPositionUnit: Int?
    let insight: String
    let createdTime: Int64
    let updatedTime: Int64
}

/// CreateReadingSessionDto 的 Data 层无框架输入。
nonisolated struct DesktopWebReadingSessionInput: Sendable, Equatable {
    let bookID: Int64
    let startTime: Int64
    let endTime: Int64
    let elapsedSeconds: Int64
    let countdownSeconds: Int64
    let pausedDurationMillis: Int64
    let position: Double?
    let recordedPositionUnit: Int?
    let insight: String?
    let confirmedLongDuration: Bool
}

/// UpsertReadingRecordRequest 的 Data 层无框架输入。
nonisolated struct DesktopWebReadingRecordInput: Sendable, Equatable {
    let mode: String
    let startTime: Int64?
    let endTime: Int64?
    let fuzzyReadDate: Int64?
    let elapsedSeconds: Int64
    let position: Double?
    let recordedPositionUnit: Int?
    let insight: String?
}

/// 使用独立 SQL 复刻 Android 两个阅读记录 Web Service 及 ReadTimingRepository 副作用。
nonisolated struct DesktopWebReadingRecordRepository: Sendable {
    private static let finishedStatus: Int64 = 3
    private static let longDurationThresholdSeconds: Int64 = 8 * 60 * 60

    private let database: AppDatabase
    private let currentTimeMillis: @Sendable () -> Int64

    /// 注入固定数据库和时钟；读写经 GRDB 连接池隔离，写事务不会因调用任务取消而撤销已提交结果。
    init(
        database: AppDatabase,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.database = database
        self.currentTimeMillis = currentTimeMillis
    }

    /// 保存网页直接提交的完成态计时，并在写入前校验起止时间、有效时长与暂停/倒计时约束。
    func createReadingSession(_ input: DesktopWebReadingSessionInput) async throws -> Int64 {
        let now = currentTimeMillis()
        guard input.startTime > 0, input.endTime > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("开始时间和结束时间不能为空")
        }
        guard input.startTime < input.endTime else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("开始时间必须早于结束时间")
        }
        guard input.endTime <= now else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("结束时间不能晚于当前时间")
        }
        guard input.elapsedSeconds > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("阅读时长必须大于 0")
        }
        guard input.countdownSeconds >= 0, input.pausedDurationMillis >= 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("倒计时和暂停时长不能为负数")
        }
        let wallDurationMillis = input.endTime - input.startTime
        let maxElapsedSeconds = Int64(ceil(Double(wallDurationMillis) / 1_000))
        guard input.elapsedSeconds <= maxElapsedSeconds else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("阅读时长不能超过起止时间范围")
        }
        guard input.pausedDurationMillis <= wallDurationMillis else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("暂停时长不能超过起止时间范围")
        }
        let elapsedMillis = input.elapsedSeconds.multipliedReportingOverflow(by: 1_000)
        guard !elapsedMillis.overflow,
              elapsedMillis.partialValue <= wallDurationMillis + 999 - input.pausedDurationMillis else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("阅读时长与暂停时长不符合起止时间范围")
        }
        guard input.countdownSeconds == 0 || input.elapsedSeconds <= input.countdownSeconds else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("阅读时长不能超过倒计时设定")
        }
        if input.elapsedSeconds > Self.longDurationThresholdSeconds,
           !input.confirmedLongDuration {
            throw DesktopWebCatalogRepositoryError.invalidArgument("阅读时长超过 8 小时，请确认后再保存")
        }
        let book = try await activeBook(input.bookID)
        let normalized = try Self.normalizedPosition(
            book: book,
            position: input.position,
            recordedPositionUnit: input.recordedPositionUnit,
            existing: nil
        )
        var record = ReadTimeRecordRecord()
        record.bookId = input.bookID
        record.startTime = input.startTime
        record.endTime = input.endTime
        record.elapsedSeconds = input.elapsedSeconds
        record.countdownSeconds = input.countdownSeconds
        record.pausedDurationMillis = input.pausedDurationMillis
        record.position = normalized.position
        record.recordedPositionUnit = normalized.unit.map(Int64.init)
        record.insight = Self.kotlinTrimmed(input.insight ?? "")
        record.status = Self.finishedStatus
        record.createdDate = currentTimeMillis()
        return try await insertAndAdvanceBook(record)
    }

    /// 查询完成态记录并在内存中复刻 Kotlin compareBy/reversed 的三字段排序。
    func readingRecords(bookID: Int64, sortOrder: String) async throws -> [DesktopWebReadingRecordSnapshot] {
        _ = try await activeBook(bookID)
        let records = try await database.dbPool.read { db in
            try ReadTimeRecordRecord
                .filter(Column("book_id") == bookID)
                .filter(Column("is_deleted") == 0)
                .filter(Column("status") == Self.finishedStatus)
                .fetchAll(db)
        }
        let sorted = records.sorted { left, right in
            let comparison = Self.compare(left, right)
            return sortOrder == "asc" ? comparison < 0 : comparison > 0
        }
        return sorted.compactMap(Self.snapshot)
    }

    /// 读取属于指定书籍的有效完成态记录，避免普通接口接管进行中或暂停中的活动计时。
    func readingRecord(bookID: Int64, recordID: Int64) async throws -> DesktopWebReadingRecordSnapshot {
        _ = try await activeBook(bookID)
        let record = try await ownedRecord(bookID: bookID, recordID: recordID)
        guard let snapshot = Self.snapshot(record) else {
            throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("阅读记录主键缺失")
        }
        return snapshot
    }

    /// 创建精确或模糊记录，并与书籍进度更新放入同一事务。
    func createReadingRecord(
        bookID: Int64,
        input: DesktopWebReadingRecordInput
    ) async throws -> DesktopWebReadingRecordSnapshot {
        let book = try await activeBook(bookID)
        let record = try Self.makeRecord(
            bookID: bookID,
            book: book,
            input: input,
            existing: nil,
            now: currentTimeMillis()
        )
        let id = try await insertAndAdvanceBook(record)
        return try await readingRecord(bookID: bookID, recordID: id)
    }

    /// 全量更新记录；原创建时间保留，位置缺失仍按 Android 语义清零。
    func updateReadingRecord(
        bookID: Int64,
        recordID: Int64,
        input: DesktopWebReadingRecordInput
    ) async throws -> DesktopWebReadingRecordSnapshot {
        let book = try await activeBook(bookID)
        let existing = try await ownedRecord(bookID: bookID, recordID: recordID)
        let now = currentTimeMillis()
        var replacement = try Self.makeRecord(
            bookID: bookID,
            book: book,
            input: input,
            existing: existing,
            now: now
        )
        replacement.id = recordID
        replacement.createdDate = existing.createdDate
        replacement.updatedDate = now
        let storedReplacement = replacement
        try await database.dbPool.write { db in
            try storedReplacement.update(db)
            try Self.advanceBookIfNeeded(db: db, book: book, position: storedReplacement.position, now: now)
        }
        return try await readingRecord(bookID: bookID, recordID: recordID)
    }

    /// 软删除属于指定书籍的有效完成态记录；活动计时由专用状态机管理。
    func deleteReadingRecord(bookID: Int64, recordID: Int64) async throws {
        _ = try await activeBook(bookID)
        _ = try await ownedRecord(bookID: bookID, recordID: recordID)
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            // 目的：软删除精确记录；表：read_time_record；过滤：主键（归属和有效性已在同方法前置校验）；
            // 时间：updated_date 使用注入的 Unix 毫秒；副作用：保留同步 tombstone。
            try db.execute(
                sql: "UPDATE read_time_record SET updated_date = ?, is_deleted = 1 WHERE id = ?",
                arguments: [now, recordID]
            )
        }
    }
}

private extension DesktopWebReadingRecordRepository {
    nonisolated struct PositionPayload {
        let position: Double
        let unit: Int?
    }

    /// 读取有效书籍；只校验删除态，不引入 owner 过滤。
    func activeBook(_ bookID: Int64) async throws -> BookRecord {
        guard let book = try await database.dbPool.read({ db in
            try BookRecord.fetchOne(db, key: bookID)
        }), book.isDeleted == 0 else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在")
        }
        // NOTE(ANDROID-WEB-008): Android 阅读记录仍只按 book ID 定位，不校验 user owner。
        return book
    }

    /// 按主键读取有效、完成态且归属匹配的记录。
    func ownedRecord(bookID: Int64, recordID: Int64) async throws -> ReadTimeRecordRecord {
        guard let record = try await database.dbPool.read({ db in
            try ReadTimeRecordRecord.fetchOne(db, key: recordID)
        }),
        record.bookId == bookID,
        record.isDeleted == 0,
        record.status == Self.finishedStatus else {
            throw DesktopWebCatalogRepositoryError.notFound("阅读记录不存在")
        }
        return record
    }

    /// 原子插入记录并在正进度前移时同步书籍 current_position_unit/read_position。
    func insertAndAdvanceBook(_ input: ReadTimeRecordRecord) async throws -> Int64 {
        let now = currentTimeMillis()
        return try await database.dbPool.write { db in
            var record = input
            if record.createdDate == 0 {
                record.createdDate = now
            }
            try record.insert(db)
            try Self.advanceBookIfNeeded(
                db: db,
                book: try BookRecord.fetchOne(db, key: record.bookId) ?? BookRecord(),
                position: record.position,
                now: now
            )
            guard let id = record.id else {
                throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("阅读记录主键缺失")
            }
            return id
        }
    }

    /// 构造 Android 精确/模糊记录；输入为全量 upsert 而非字段 Patch。
    nonisolated static func makeRecord(
        bookID: Int64,
        book: BookRecord,
        input: DesktopWebReadingRecordInput,
        existing: ReadTimeRecordRecord?,
        now: Int64
    ) throws -> ReadTimeRecordRecord {
        let position = try normalizedPosition(
            book: book,
            position: input.position,
            recordedPositionUnit: input.recordedPositionUnit,
            existing: existing
        )
        let mode = kotlinTrimmed(input.mode).lowercased()
        var record = ReadTimeRecordRecord()
        record.bookId = bookID
        record.position = position.position
        record.recordedPositionUnit = position.unit.map(Int64.init)
        record.insight = kotlinTrimmed(input.insight ?? "")
        record.status = finishedStatus
        switch mode {
        case "accurate":
            guard let start = input.startTime, start > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("开始时间不能为空")
            }
            guard let end = input.endTime, end > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("结束时间不能为空")
            }
            guard start < end else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("开始时间必须早于结束时间")
            }
            guard end <= now else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("结束时间不能晚于当前时间")
            }
            let wallSeconds = (end - start) / 1_000
            guard wallSeconds > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("阅读时长必须大于 0")
            }
            record.startTime = start
            record.endTime = end
            record.elapsedSeconds = wallSeconds
        case "fuzzy":
            guard let fuzzyDate = input.fuzzyReadDate, fuzzyDate > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("阅读日期不能为空")
            }
            let endOfToday = Calendar.current.dateInterval(of: .day, for: Date(timeIntervalSince1970: Double(now) / 1_000))
                .map { Int64($0.end.timeIntervalSince1970 * 1_000) - 1 }
                ?? now
            guard fuzzyDate <= endOfToday else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("阅读日期不能晚于今天")
            }
            guard input.elapsedSeconds > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("阅读时长必须大于 0")
            }
            record.fuzzyReadDate = fuzzyDate
            record.elapsedSeconds = input.elapsedSeconds
        default:
            throw DesktopWebCatalogRepositoryError.invalidArgument("不支持的阅读记录类型")
        }
        return record
    }

    /// 复刻 Android 对可选位置单位、已有记录保留判断及三类上限的处理。
    nonisolated static func normalizedPosition(
        book: BookRecord,
        position: Double?,
        recordedPositionUnit: Int?,
        existing: ReadTimeRecordRecord?
    ) throws -> PositionPayload {
        let requestedUnit: Int?
        switch recordedPositionUnit {
        case nil:
            requestedUnit = nil
        case 0, 1, 2:
            requestedUnit = recordedPositionUnit
        default:
            throw DesktopWebCatalogRepositoryError.invalidArgument("阅读位置单位不正确")
        }
        guard let position else {
            return PositionPayload(position: 0, unit: nil)
        }
        guard position.isFinite, position >= 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("阅读位置格式不正确")
        }
        if let existing,
           (requestedUnit == nil || existing.recordedPositionUnit == requestedUnit.map(Int64.init)),
           abs(existing.position - position) < 0.0001 {
            return PositionPayload(position: position, unit: existing.recordedPositionUnit.map(Int.init))
        }
        let effectiveUnit = requestedUnit ?? Int(book.positionUnit)
        switch effectiveUnit {
        case 1 where book.totalPosition != 0:
            guard position > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("页码应大于0页")
            }
            guard position <= Double(book.totalPosition) else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("页码应小于总页码(\(book.totalPosition)页)")
            }
        case 2 where book.totalPagination != 0:
            guard position > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("页码应大于0页")
            }
            guard position <= Double(book.totalPagination) else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("页码应小于总页码(\(book.totalPagination)页)")
            }
        case 0:
            guard position >= 0, position <= 100 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("进度值应在[0,100]区间内")
            }
        default:
            break
        }
        return PositionPayload(position: position, unit: effectiveUnit)
    }

    /// 仅当位置非零且严格前移时更新书籍，保留 Android 的 1e-10 零值容差。
    nonisolated static func advanceBookIfNeeded(
        db: Database,
        book: BookRecord,
        position: Double,
        now: Int64
    ) throws {
        guard abs(position) >= 1e-10, position > book.readPosition, let bookID = book.id else { return }
        // 目的：同步阅读记录带来的书籍最新进度；表：book；关联：记录的 book_id；过滤：有效非占位书籍；
        // 时间：updated_date 使用同一事务的 Unix 毫秒；副作用：current_position_unit 跟随书籍 position_unit。
        try db.execute(
            sql: """
                UPDATE book
                SET current_position_unit = position_unit, read_position = ?, updated_date = ?
                WHERE id = ? AND is_deleted = 0 AND id != 0
                """,
            arguments: [position, now, bookID]
        )
    }

    /// Kotlin compareBy(startReadTime, createdDateTime, id) 的三值比较。
    nonisolated static func compare(_ left: ReadTimeRecordRecord, _ right: ReadTimeRecordRecord) -> Int {
        let leftValues = [startReadTime(left), left.createdDate, left.id ?? 0]
        let rightValues = [startReadTime(right), right.createdDate, right.id ?? 0]
        for index in leftValues.indices {
            if leftValues[index] < rightValues[index] { return -1 }
            if leftValues[index] > rightValues[index] { return 1 }
        }
        return 0
    }

    nonisolated static func startReadTime(_ record: ReadTimeRecordRecord) -> Int64 {
        record.fuzzyReadDate == 0 ? record.startTime : record.fuzzyReadDate
    }

    nonisolated static func snapshot(_ record: ReadTimeRecordRecord) -> DesktopWebReadingRecordSnapshot? {
        guard let id = record.id else { return nil }
        return DesktopWebReadingRecordSnapshot(
            id: id,
            bookID: record.bookId,
            mode: record.fuzzyReadDate == 0 ? "accurate" : "fuzzy",
            startTime: record.startTime,
            endTime: record.endTime,
            fuzzyReadDate: record.fuzzyReadDate,
            elapsedSeconds: record.elapsedSeconds,
            countdownSeconds: record.countdownSeconds,
            pausedDurationMillis: record.pausedDurationMillis,
            position: record.position,
            recordedPositionUnit: record.recordedPositionUnit.map(Int.init),
            insight: record.insight,
            createdTime: record.createdDate,
            updatedTime: record.updatedDate
        )
    }

    nonisolated static func kotlinTrimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
