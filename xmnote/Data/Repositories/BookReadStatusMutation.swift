import Foundation
import GRDB

/**
 * [INPUT]: 依赖 GRDB Database、BookReadStatusRecordRecord 与 AnnualCollectionSync 执行阅读状态历史写入
 * [OUTPUT]: 对外提供 BookReadStatusMutation（新增书籍初始状态、单本阅读状态变更、读完进度与评分同步）
 * [POS]: Data 层书籍阅读状态写入协作者，封装状态历史、book 当前状态与年度书单副作用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍阅读状态写入助手，统一批量管理、编辑页与新增书的状态历史和年度书单副作用。
nonisolated enum BookReadStatusMutation {
    /// 新书创建后插入初始阅读状态历史，并按 Android 年度书单语义同步归档关系。
    static func insertInitialReadStatusAndSyncAnnual(
        _ db: Database,
        bookID: Int64,
        statusID: Int64,
        changedAt: Int64,
        createdAt: Int64
    ) throws {
        try insertBookReadStatusRecord(
            db,
            bookID: bookID,
            statusID: statusID,
            changedAt: changedAt,
            createdAt: createdAt
        )
        try AnnualCollectionSync.syncAfterReadHistoryChanged(db, bookID: bookID)
    }

    /// 按 Android `updateBookReadStatus` 语义更新单本书状态；读完状态会推进阅读位置并同步评分。
    static func updateBookReadStatus(
        _ db: Database,
        bookID: Int64,
        statusID: Int64,
        changedAt: Int64,
        updatedAt: Int64,
        finishedRatingScore: Int64?
    ) throws {
        guard let bookState = try fetchBookState(db, bookID: bookID) else { return }
        if let latestStatus = try fetchNewestReadStatusRecord(db, bookID: bookID),
           latestStatus.readStatusID == statusID {
            try updateNewestReadStatusRecord(
                db,
                recordID: latestStatus.id,
                changedAt: changedAt,
                updatedAt: updatedAt
            )
        } else {
            try insertBookReadStatusRecord(
                db,
                bookID: bookID,
                statusID: statusID,
                changedAt: changedAt,
                createdAt: updatedAt
            )
        }

        try updateBookCurrentReadStatus(
            db,
            bookID: bookID,
            userID: bookState.userID,
            statusID: statusID,
            changedAt: changedAt,
            updatedAt: updatedAt
        )

        if statusID == BookEntryReadingStatus.finished.rawValue {
            try markBookAsFinished(
                db,
                bookID: bookID,
                positionUnit: bookState.positionUnit,
                totalPosition: bookState.totalPosition,
                totalPagination: bookState.totalPagination,
                updatedAt: updatedAt
            )
            try updateBookRating(
                db,
                bookID: bookID,
                ratingScore: max(0, min(finishedRatingScore ?? 0, 50)),
                updatedAt: updatedAt
            )
        }

        try AnnualCollectionSync.syncAfterReadHistoryChanged(db, bookID: bookID)
    }

    /// 读取状态写入所需的书籍基础字段。
    static func fetchBookState(
        _ db: Database,
        bookID: Int64
    ) throws -> (userID: Int64, positionUnit: Int64, totalPosition: Int64, totalPagination: Int64)? {
        // SQL 目的：读取阅读状态写入所需的书籍用户与进度单位字段。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，跳过已删除书籍和占位书籍。
        // 返回字段用途：user_id 用于同步当前状态过滤；position_unit/total_position/total_pagination 用于读完时推进到终点。
        let sql = """
            SELECT user_id, position_unit, total_position, total_pagination
            FROM book
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else { return nil }
        return (
            userID: row["user_id"] ?? 0,
            positionUnit: row["position_unit"] ?? 0,
            totalPosition: row["total_position"] ?? 0,
            totalPagination: row["total_pagination"] ?? 0
        )
    }

    /// 读取单本书最新的有效阅读状态记录。
    static func fetchNewestReadStatusRecord(
        _ db: Database,
        bookID: Int64
    ) throws -> (id: Int64, readStatusID: Int64)? {
        // SQL 目的：读取单本书最新有效阅读状态记录，决定复用更新还是插入新记录。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id = ?、is_deleted = 0。
        // 时间字段：changed_date 为毫秒时间戳；排序按 id DESC 后 changed_date DESC，对齐 Android 最新记录口径。
        // 返回字段用途：id 用于更新最新记录，read_status_id 用于判断状态是否相同。
        let sql = """
            SELECT id, read_status_id
            FROM book_read_status_record
            WHERE book_id = ?
              AND is_deleted = 0
            ORDER BY id DESC, changed_date DESC
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else { return nil }
        return (id: row["id"], readStatusID: row["read_status_id"])
    }

    /// 最新记录状态相同时更新时间，不新增历史。
    static func updateNewestReadStatusRecord(
        _ db: Database,
        recordID: Int64,
        changedAt: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：当最新阅读状态与目标状态一致时，仅更新时间而不插入新历史。
        // 涉及表：book_read_status_record。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 时间字段：changed_date 写入用户选择的毫秒时间戳，updated_date 写入本次写入毫秒时间戳。
        // 副作用用途：复刻 Android updateBookReadStatus 中“最新同状态则更新”的历史合并语义。
        let sql = """
            UPDATE book_read_status_record
            SET changed_date = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [changedAt, updatedAt, recordID])
    }

    /// 插入一条新的阅读状态历史记录。
    static func insertBookReadStatusRecord(
        _ db: Database,
        bookID: Int64,
        statusID: Int64,
        changedAt: Int64,
        createdAt: Int64
    ) throws {
        var record = BookReadStatusRecordRecord(
            id: nil,
            bookId: bookID,
            readStatusId: statusID,
            changedDate: changedAt,
            createdDate: createdAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }

    /// 同步 book 表当前阅读状态字段。
    static func updateBookCurrentReadStatus(
        _ db: Database,
        bookID: Int64,
        userID: Int64,
        statusID: Int64,
        changedAt: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：同步 book 当前阅读状态字段，供书架状态维度与详情页直接读取。
        // 涉及表：book。
        // 关键过滤：id = ?、user_id = ?、is_deleted = 0、id != 0，对齐 Android updateBookReadStatus 的用户与有效书过滤。
        // 时间字段：read_status_changed_date 写入用户选择的毫秒时间戳，updated_date 写入本次写入毫秒时间戳。
        // 副作用用途：更新当前状态，使 Repository 观察流刷新。
        let sql = """
            UPDATE book
            SET updated_date = ?,
                read_status_id = ?,
                read_status_changed_date = ?
            WHERE id = ?
              AND user_id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, statusID, changedAt, bookID, userID])
    }

    /// 标记书籍阅读位置到当前进度单位的终点。
    static func markBookAsFinished(
        _ db: Database,
        bookID: Int64,
        positionUnit: Int64,
        totalPosition: Int64,
        totalPagination: Int64,
        updatedAt: Int64
    ) throws {
        let readPosition: Double?
        switch positionUnit {
        case BookEntryProgressUnit.progress.rawValue:
            readPosition = 100.0
        case BookEntryProgressUnit.position.rawValue where totalPosition != 0:
            readPosition = Double(totalPosition)
        case BookEntryProgressUnit.pagination.rawValue where totalPagination != 0:
            readPosition = Double(totalPagination)
        default:
            readPosition = nil
        }
        guard let readPosition else { return }

        // SQL 目的：标记读完时把当前阅读位置推进到终点，对齐 Android updateBookReadPositionSync。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0。
        // 时间字段：updated_date 写入本次写入毫秒时间戳；位置字段不涉及时区。
        // 副作用用途：更新 current_position_unit 与 read_position，使阅读进度排序和详情展示同步到终点。
        let sql = """
            UPDATE book
            SET current_position_unit = position_unit,
                read_position = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [readPosition, updatedAt, bookID])
    }

    /// 更新单本有效书籍评分。
    static func updateBookRating(
        _ db: Database,
        bookID: Int64,
        ratingScore: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：读完状态写入时同步评分，允许 0 分保存。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0。
        // 时间字段：updated_date 写入本次写入毫秒时间戳；score 为 0...50 的半星分值。
        // 副作用用途：让评分排序、评分维度与详情展示和 Android 批量读完语义一致。
        let sql = """
            UPDATE book
            SET score = ?,
                updated_date = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [max(0, min(ratingScore, 50)), updatedAt, bookID])
    }
}
