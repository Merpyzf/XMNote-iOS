import Foundation
import GRDB

/**
 * [INPUT]: 依赖 GRDB Database、阅读状态历史、book 快照、collection 与 collection_book 表
 * [OUTPUT]: 对外提供 AnnualCollectionSync（读完年份重算、年度书单创建、年度书单关系物理增删）
 * [POS]: Data 层年度书单同步协作者，封装阅读状态变更后的归档关系副作用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 年度书单同步助手，复刻 Android `updateCollectionCauseReadStatusChanged` 的关系维护规则。
nonisolated enum AnnualCollectionSync {
    /// 按当前读完历史重算指定书籍所属年度书单关系。
    static func syncAfterReadHistoryChanged(_ db: Database, bookID: Int64) throws {
        let linkedCollections = try fetchLinkedAnnualCollections(db, bookID: bookID)
        let readDoneYears = try fetchCompletedReadDoneYears(db, bookID: bookID)

        for collection in linkedCollections where !readDoneYears.contains(collection.year) {
            try hardDeleteAnnualRelation(db, bookID: bookID, collectionID: collection.id)
        }

        let linkedYears = Set(linkedCollections.map(\.year))
        for year in readDoneYears.sorted() where !linkedYears.contains(year) {
            try ensureBookInAnnualCollection(db, bookID: bookID, year: year)
        }
    }

    /// 查询当前书籍已关联的有效年度书单。
    static func fetchLinkedAnnualCollections(
        _ db: Database,
        bookID: Int64
    ) throws -> [(id: Int64, year: Int)] {
        // SQL 目的：查询指定书籍当前有效年度书单关系，用于移除不再属于读完年份的关系。
        // 涉及表：collection_book cb 与 collection c；cb.collection_id -> c.id。
        // 关键过滤：cb.book_id 精确匹配、两表 is_deleted = 0、c.is_annual = 1。
        // 返回字段用途：collection.id 用于软删关系，year 用于与读完年份集合比对；时间字段不参与。
        let sql = """
            SELECT c.id, c.year
            FROM collection_book cb
            JOIN collection c ON c.id = cb.collection_id
            WHERE cb.book_id = ?
              AND cb.is_deleted = 0
              AND c.is_deleted = 0
              AND c.is_annual = 1
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookID]).compactMap { row in
            guard let id: Int64 = row["id"] else { return nil }
            let yearValue: Int64 = row["year"] ?? 0
            guard yearValue > 0 else { return nil }
            return (id: id, year: Int(yearValue))
        }
    }

    /// 查询状态历史与 book 快照共同形成的读完年份集合。
    static func fetchCompletedReadDoneYears(_ db: Database, bookID: Int64) throws -> Set<Int> {
        let timestamps = try fetchCompletedReadDoneTimestamps(db, bookID: bookID)
        let calendar = Calendar.current
        return Set(timestamps.compactMap { timestamp in
            guard timestamp > 0 else { return nil }
            return calendar.dateComponents([.year], from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)).year
        })
    }

    /// 查询指定书籍的全部读完事件毫秒时间戳，并追加 book 表当前读完快照兜底。
    static func fetchCompletedReadDoneTimestamps(_ db: Database, bookID: Int64) throws -> Set<Int64> {
        // SQL 目的：读取指定书籍全部有效读完历史时间。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id 精确匹配、read_status_id = 3、changed_date > 0、is_deleted = 0。
        // 时间字段：changed_date 为本地毫秒时间戳，按 Calendar.current 计算自然年。
        // 返回字段用途：生成年度书单年份集合。
        let historySQL = """
            SELECT changed_date
            FROM book_read_status_record
            WHERE book_id = ?
              AND read_status_id = ?
              AND changed_date > 0
              AND is_deleted = 0
            """
        var timestamps = Set(try Int64.fetchAll(db, sql: historySQL, arguments: [bookID, BookEntryReadingStatus.finished.rawValue]))

        // SQL 目的：追加 book 表当前读完状态快照，兼容 Android appendCompletedReadDoneSnapshotIfNeeded。
        // 涉及表：book。
        // 关键过滤：id 精确匹配、read_status_id = 3、read_status_changed_date > 0、is_deleted = 0。
        // 时间字段：read_status_changed_date 为本地毫秒时间戳，按 Calendar.current 计算自然年。
        // 返回字段用途：当历史表缺失但 book 当前为读完时，仍能进入年度书单。
        let snapshotSQL = """
            SELECT read_status_changed_date
            FROM book
            WHERE id = ?
              AND read_status_id = ?
              AND read_status_changed_date > 0
              AND is_deleted = 0
              AND id != 0
            LIMIT 1
            """
        if let snapshot = try Int64.fetchOne(db, sql: snapshotSQL, arguments: [bookID, BookEntryReadingStatus.finished.rawValue]) {
            timestamps.insert(snapshot)
        }
        return timestamps
    }

    /// 物理删除指定书籍与指定年度书单的关系，不产生同步墓碑。
    static func hardDeleteAnnualRelation(
        _ db: Database,
        bookID: Int64,
        collectionID: Int64
    ) throws {
        // SQL 目的：移除书籍不再属于的年度书单关系。
        // 涉及表：collection_book。
        // 关键过滤：book_id 与 collection_id 精确匹配，且关系仍有效。
        // 时间字段：物理删除不写 updated_date；副作用用途：当读完年份变化或取消读完时，年度书单不再显示该书且不遗留 tombstone。
        let sql = """
            DELETE FROM collection_book
            WHERE book_id = ?
              AND collection_id = ?
            """
        try db.execute(sql: sql, arguments: [bookID, collectionID])
    }

    /// 确保指定书籍存在于目标年度书单中，缺失年度书单时先创建。
    static func ensureBookInAnnualCollection(
        _ db: Database,
        bookID: Int64,
        year: Int
    ) throws {
        let collectionID = try fetchAnnualCollectionID(db, year: year) ?? createAnnualCollection(db, year: year)
        guard try !hasCollectionBookRelation(db, bookID: bookID, collectionID: collectionID) else { return }

        // SQL 目的：重新建立年度关系前物理清理旧备份遗留的同键 tombstone，避免重试形成重复业务关系。
        // 涉及表：collection_book。
        // 关键过滤：book_id 与 collection_id 精确匹配；有效关系已由上方 guard 排除。
        // 时间字段：物理删除不写时间字段；副作用用途：让后续插入成为该业务键唯一现存关系。
        try db.execute(
            sql: "DELETE FROM collection_book WHERE book_id = ? AND collection_id = ?",
            arguments: [bookID, collectionID]
        )

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try BookRelationWriter.insertCollectionBook(
            db,
            collectionID: collectionID,
            bookID: bookID,
            createdAt: now
        )
    }

    /// 查询指定年份的有效年度书单 ID。
    static func fetchAnnualCollectionID(_ db: Database, year: Int) throws -> Int64? {
        // SQL 目的：查询指定年份已有的有效年度书单。
        // 涉及表：collection。
        // 关键过滤：is_annual = 1、year 精确匹配、is_deleted = 0。
        // 返回字段用途：返回 collection.id 供 collection_book 插入关系；时间字段不参与。
        let sql = """
            SELECT id
            FROM collection
            WHERE is_annual = 1
              AND year = ?
              AND is_deleted = 0
            LIMIT 1
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [year])
    }

    /// 创建指定年份年度书单，并返回新主键。
    static func createAnnualCollection(_ db: Database, year: Int) throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var collection = CollectionRecord(
            id: nil,
            title: "\(year) 年阅读书单",
            desc: "",
            order: Int64(year),
            isAnnual: 1,
            year: Int64(year),
            createdDate: now,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try collection.insert(db)
        return collection.id ?? db.lastInsertedRowID
    }

    /// 判断指定书籍与书单的有效关系是否已经存在。
    static func hasCollectionBookRelation(
        _ db: Database,
        bookID: Int64,
        collectionID: Int64
    ) throws -> Bool {
        // SQL 目的：避免重复插入同一书籍与年度书单的有效关系。
        // 涉及表：collection_book。
        // 关键过滤：book_id、collection_id 精确匹配，且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与。
        let sql = """
            SELECT COUNT(*)
            FROM collection_book
            WHERE book_id = ?
              AND collection_id = ?
              AND is_deleted = 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [bookID, collectionID]) ?? 0) > 0
    }
}
