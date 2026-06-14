/**
 * [INPUT]: 依赖 GRDB Database、CollectionRecord、CollectionBookRecord 与书架展示模型，读取和写入 Android 对齐的书单数据
 * [OUTPUT]: 为 BookRepository 补充书单列表、详情、创建、编辑、删除、排序、推荐语与年度一致性修复能力
 * [POS]: Data 层书单迁移协作者，集中封装 collection / collection_book 的跨端数据语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

extension BookRepository {
    /// 读取书单列表快照，并分别按 Android 手动 order 升序与年度 year 降序输出。
    nonisolated func fetchBookCollectionListSnapshot(_ db: Database) throws -> BookCollectionListSnapshot {
        let rows = try collectionRows(db)
        let items = try rows.compactMap { row in
            try makeCollectionListItem(db, row: row)
        }
        return BookCollectionListSnapshot(
            manualCollections: items
                .filter { $0.kind == .manual }
                .sorted { lhs, rhs in lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order },
            annualCollections: items
                .filter { $0.kind == .annual && $0.bookCount > 0 }
                .sorted { lhs, rhs in (lhs.year ?? 0) == (rhs.year ?? 0) ? lhs.id < rhs.id : (lhs.year ?? 0) > (rhs.year ?? 0) }
        )
    }

    /// 读取单个书单列表项，供创建后回填 UI 使用。
    nonisolated func fetchBookCollectionListItem(
        _ db: Database,
        collectionID: Int64
    ) throws -> BookCollectionListItem? {
        guard let row = try collectionRow(db, collectionID: collectionID) else { return nil }
        return try makeCollectionListItem(db, row: row)
    }

    /// 读取单个书单详情；手动书单按 relation order 展示，年度书单按读完时间倒序展示。
    nonisolated func fetchBookCollectionDetail(
        _ db: Database,
        collectionID: Int64
    ) throws -> BookCollectionDetail? {
        guard let row = try collectionRow(db, collectionID: collectionID) else { return nil }
        let isAnnual = (row["is_annual"] as Int64? ?? 0) != 0
        let books = try fetchCollectionBooks(db, collectionID: collectionID, isAnnual: isAnnual)
        return BookCollectionDetail(
            id: collectionID,
            title: row["title"] ?? "",
            description: row["description"] ?? "",
            kind: isAnnual ? .annual : .manual,
            order: row["order"] ?? 0,
            year: isAnnual ? Int(row["year"] as Int64? ?? 0) : nil,
            targetReadCount: isAnnual ? try fetchReadTarget(db, year: row["year"] ?? 0) : nil,
            books: books
        )
    }

    /// 扫描当前有效书籍，补齐或移除年度书单关系，保持 Android 首次迁移修复语义。
    nonisolated func repairAnnualBookCollections(_ db: Database) throws {
        // SQL 目的：读取所有有效真实书籍，逐本按读完历史重算年度书单关系。
        // 涉及表：book。
        // 关键过滤：is_deleted = 0 且 id != 0；占位书籍不参与年度书单同步。
        // 时间字段：read_status_changed_date 由 AnnualCollectionSync 内部读取。
        // 返回字段用途：book id 作为年度关系修复输入。
        let bookIDs = try Int64.fetchAll(
            db,
            sql: """
                SELECT id
                FROM book
                WHERE is_deleted = 0
                  AND id != 0
                """
        )
        for bookID in bookIDs {
            try AnnualCollectionSync.syncAfterReadHistoryChanged(db, bookID: bookID)
        }
    }

    /// 按 Android saveCollection 语义创建手动书单，desc 参与重名判定。
    nonisolated func createBookCollection(
        _ db: Database,
        input: BookCollectionFormInput
    ) throws -> Int64 {
        let title = try validatedCollectionTitle(input.title)
        let description = input.description.trimmingCharacters(in: .whitespacesAndNewlines)

        // SQL 目的：按 Android CollectionDao.query(title, desc) 查重。
        // 涉及表：collection。
        // 关键过滤：title/desc 精确匹配且 is_deleted = 0；不额外排除年度书单，保持 Android 原始口径。
        // 返回字段用途：存在重复时阻断创建。
        let duplicateSQL = """
            SELECT id
            FROM collection
            WHERE title = ?
              AND `desc` = ?
              AND is_deleted = 0
            LIMIT 1
            """
        if try Int64.fetchOne(db, sql: duplicateSQL, arguments: [title, description]) != nil {
            throw BookshelfBatchWriteError.duplicateName("要创建的书单已经存在了")
        }

        let order = try minCollectionOrder(db) - 1
        let now = timestampMillis()
        var record = CollectionRecord(
            id: nil,
            title: title,
            desc: description,
            order: order,
            isAnnual: 0,
            year: 0,
            createdDate: now,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
        return record.id ?? db.lastInsertedRowID
    }

    /// 编辑手动书单标题与简介，保留 order/year/is_annual 并更新 updated_date。
    nonisolated func updateBookCollection(
        _ db: Database,
        collectionID: Int64,
        input: BookCollectionFormInput
    ) throws {
        let title = try validatedCollectionTitle(input.title)
        let description = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try isActiveManualCollection(db, collectionID: collectionID) else {
            throw BookshelfBatchWriteError.invalidCollection
        }

        // SQL 目的：更新手动书单标题与简介，复刻 Android CollectionModelMapper 编辑路径会刷新 updated_date 的语义。
        // 涉及表：collection。
        // 关键过滤：id 精确匹配、is_deleted = 0、is_annual = 0。
        // 时间字段：updated_date 写入当前毫秒；created_date/last_sync_date 不变。
        // 副作用用途：触发书单列表与详情观察流刷新。
        try db.execute(
            sql: """
                UPDATE collection
                SET title = ?,
                    `desc` = ?,
                    updated_date = ?
                WHERE id = ?
                  AND is_deleted = 0
                  AND is_annual = 0
                """,
            arguments: [title, description, timestampMillis(), collectionID]
        )
    }

    /// 删除手动书单；collection 本体不更新时间戳，relation 按 Android deleteByCollectionId 更新时间戳。
    nonisolated func deleteBookCollection(_ db: Database, collectionID: Int64) throws {
        guard try isActiveManualCollection(db, collectionID: collectionID) else {
            throw BookshelfBatchWriteError.invalidCollection
        }
        let now = timestampMillis()
        // SQL 目的：软删除手动书单本体，保持 Android CollectionDao.delete 不刷新 updated_date 的语义。
        // 涉及表：collection。
        // 关键过滤：id 精确匹配、is_deleted = 0、is_annual = 0。
        // 时间字段：不更新 updated_date。
        try db.execute(
            sql: """
                UPDATE collection
                SET is_deleted = 1
                WHERE id = ?
                  AND is_deleted = 0
                  AND is_annual = 0
                """,
            arguments: [collectionID]
        )

        // SQL 目的：软删除该书单下全部有效关系，复刻 Android deleteByCollectionId 会刷新 relation updated_date 的语义。
        // 涉及表：collection_book。
        // 关键过滤：collection_id 精确匹配且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒。
        try db.execute(
            sql: """
                UPDATE collection_book
                SET is_deleted = 1,
                    updated_date = ?
                WHERE collection_id = ?
                  AND is_deleted = 0
                """,
            arguments: [now, collectionID]
        )
    }

    /// 按传入顺序更新手动书单 order，更新时间戳与 Android updateCollectionOrder 保持一致。
    nonisolated func updateManualBookCollectionOrder(
        _ db: Database,
        collectionIDs: [Int64]
    ) throws {
        let ids = normalizedPositiveIDs(collectionIDs)
        guard !ids.isEmpty else { return }
        let validIDs = try fetchManualCollectionIDs(db)
        let validSet = Set(validIDs)
        let ordered = ids.filter { validSet.contains($0) } + validIDs.filter { !ids.contains($0) }
        let now = timestampMillis()
        for (index, id) in ordered.enumerated() {
            // SQL 目的：写入手动书单排序，复刻 Android updateCollectionOrder 经 mapper 更新 updated_date 的语义。
            // 涉及表：collection。
            // 关键过滤：id 精确匹配、is_deleted = 0、is_annual = 0。
            // 时间字段：updated_date 写入当前毫秒。
            try db.execute(
                sql: """
                    UPDATE collection
                    SET `order` = ?,
                        updated_date = ?
                    WHERE id = ?
                      AND is_deleted = 0
                      AND is_annual = 0
                    """,
                arguments: [Int64(index), now, id]
            )
        }
    }

    /// 从书单内移除 relation，保持 Android deleteSync 不更新时间戳的语义。
    nonisolated func removeBooksFromCollection(
        _ db: Database,
        collectionBookIDs: [Int64]
    ) throws {
        for id in normalizedPositiveIDs(collectionBookIDs) {
            // SQL 目的：软删除单条书单关系，复刻 Android deleteSync(id) 不刷新 updated_date。
            // 涉及表：collection_book。
            // 关键过滤：id 精确匹配且 is_deleted = 0。
            // 时间字段：不更新 updated_date。
            try db.execute(
                sql: """
                    UPDATE collection_book
                    SET is_deleted = 1
                    WHERE id = ?
                      AND is_deleted = 0
                    """,
                arguments: [id]
            )
        }
    }

    /// 按书单内最终顺序更新 relation order，并刷新 relation updated_date。
    nonisolated func updateBooksInCollectionOrder(
        _ db: Database,
        collectionID: Int64,
        relationIDs: [Int64]
    ) throws {
        let ids = normalizedPositiveIDs(relationIDs)
        guard !ids.isEmpty else { return }
        let validIDs = try fetchCollectionBookRelationIDs(db, collectionID: collectionID)
        let validSet = Set(validIDs)
        let ordered = ids.filter { validSet.contains($0) } + validIDs.filter { !ids.contains($0) }
        let now = timestampMillis()
        for (index, id) in ordered.enumerated() {
            // SQL 目的：写入书单内书籍排序，复刻 Android updateCollection 中 relation update 会刷新 updated_date 的语义。
            // 涉及表：collection_book。
            // 关键过滤：id 与 collection_id 精确匹配且 is_deleted = 0。
            // 时间字段：updated_date 写入当前毫秒。
            try db.execute(
                sql: """
                    UPDATE collection_book
                    SET `order` = ?,
                        updated_date = ?
                    WHERE id = ?
                      AND collection_id = ?
                      AND is_deleted = 0
                    """,
                arguments: [Int64(index), now, id, collectionID]
            )
        }
    }

    /// 编辑书单内推荐语，保留 relation 与 book，不改 collection 本体。
    nonisolated func updateCollectionBookRecommend(
        _ db: Database,
        collectionBookID: Int64,
        recommend: String
    ) throws {
        let normalized = recommend.trimmingCharacters(in: .whitespacesAndNewlines)
        // SQL 目的：更新书单内推荐语，复刻 Android relation update 会刷新 updated_date 的语义。
        // 涉及表：collection_book。
        // 关键过滤：id 精确匹配且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒。
        try db.execute(
            sql: """
                UPDATE collection_book
                SET recommend = ?,
                    updated_date = ?
                WHERE id = ?
                  AND is_deleted = 0
                """,
            arguments: [normalized, timestampMillis(), collectionBookID]
        )
    }
}

private extension BookRepository {
    nonisolated func collectionRows(_ db: Database) throws -> [Row] {
        // SQL 目的：读取全部有效书单元信息，后续按 is_annual 拆分手动与年度列表。
        // 涉及表：collection。
        // 关键过滤：is_deleted = 0。
        // 时间字段：created_date/updated_date 不参与列表排序。
        // 返回字段用途：构建书单列表项和详情头部。
        try Row.fetchAll(
            db,
            sql: """
                SELECT id,
                       COALESCE(title, '') AS title,
                       COALESCE(`desc`, '') AS description,
                       `order`,
                       is_annual,
                       year
                FROM collection
                WHERE is_deleted = 0
                """
        )
    }

    nonisolated func collectionRow(_ db: Database, collectionID: Int64) throws -> Row? {
        // SQL 目的：读取指定有效书单元信息。
        // 涉及表：collection。
        // 关键过滤：id 精确匹配且 is_deleted = 0。
        // 返回字段用途：构建详情头部与写入权限判断。
        try Row.fetchOne(
            db,
            sql: """
                SELECT id,
                       COALESCE(title, '') AS title,
                       COALESCE(`desc`, '') AS description,
                       `order`,
                       is_annual,
                       year
                FROM collection
                WHERE id = ?
                  AND is_deleted = 0
                LIMIT 1
                """,
            arguments: [collectionID]
        )
    }

    nonisolated func makeCollectionListItem(
        _ db: Database,
        row: Row
    ) throws -> BookCollectionListItem? {
        let collectionID: Int64 = row["id"]
        let isAnnual = (row["is_annual"] as Int64? ?? 0) != 0
        let books = try fetchCollectionBooks(db, collectionID: collectionID, isAnnual: isAnnual)
        let yearValue: Int64 = row["year"] ?? 0
        return BookCollectionListItem(
            id: collectionID,
            title: row["title"] ?? "",
            description: row["description"] ?? "",
            kind: isAnnual ? .annual : .manual,
            order: row["order"] ?? 0,
            year: isAnnual ? Int(yearValue) : nil,
            bookCount: books.count,
            finishedCount: books.filter { $0.book.readStatusId == BookEntryReadingStatus.finished.rawValue }.count,
            targetReadCount: isAnnual ? try fetchReadTarget(db, year: yearValue) : nil,
            representativeCovers: books.prefix(4).map(\.book.cover)
        )
    }

    nonisolated func fetchCollectionBooks(
        _ db: Database,
        collectionID: Int64,
        isAnnual: Bool
    ) throws -> [BookCollectionBookItem] {
        // SQL 目的：读取书单内有效 relation 与书籍展示字段；手动书单不排除软删除书籍，保持 Android queryMineCollectionBookList 口径。
        // 涉及表：collection_book cb INNER JOIN book b，LEFT JOIN read_status/source/read_time_record/book_read_status_record/note。
        // 关键过滤：cb.collection_id 精确匹配、cb.is_deleted = 0；年度书单额外要求 b.is_deleted = 0。
        // 时间字段：cb.created_date/updated_date 用于保留 relation 元信息；读完历史用于列表徽标和年度排序。
        // 返回字段用途：构建书单详情书籍行、推荐语和 relation 写入目标。
        let annualBookPredicate = isAnnual ? "AND b.is_deleted = 0" : ""
        let orderClause = isAnnual
            ? "resolved_read_done_date DESC, cb.id ASC"
            : "cb.`order` ASC, cb.id ASC"
        let sql = """
            WITH read_done AS (
                SELECT book_id,
                       MAX(changed_date) AS latest_read_done_date,
                       COUNT(id) AS read_done_count
                FROM book_read_status_record
                WHERE read_status_id = ?
                  AND changed_date > 0
                  AND is_deleted = 0
                GROUP BY book_id
            ),
            reading_time AS (
                SELECT book_id, SUM(elapsed_seconds) AS total_reading_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND status = 3
                  AND book_id != 0
                GROUP BY book_id
            )
            SELECT cb.id AS relation_id,
                   cb.collection_id,
                   cb.recommend,
                   cb.`order` AS relation_order,
                   cb.created_date AS relation_created_date,
                   cb.updated_date AS relation_updated_date,
                   b.id AS book_id,
                   COALESCE(b.name, '') AS book_name,
                   COALESCE(b.author, '') AS book_author,
                   COALESCE(b.cover, '') AS book_cover,
                   b.read_status_id,
                   COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(s.name, '') AS source_name,
                   COALESCE(b.press, '') AS press,
                   COALESCE(b.pub_date, '') AS pub_date,
                   b.score,
                   b.created_date AS book_created_date,
                   b.updated_date AS book_updated_date,
                   b.read_status_changed_date,
                   b.read_position,
                   b.current_position_unit,
                   b.total_position,
                   b.total_pagination,
                   COALESCE(rd.latest_read_done_date, 0) AS latest_read_done_date,
                   COALESCE(rd.read_done_count, 0) AS raw_read_done_count,
                   COALESCE(rt.total_reading_time, 0) AS total_reading_time,
                   (
                       SELECT COUNT(n.id)
                       FROM note n
                       WHERE n.book_id = b.id
                         AND n.is_deleted = 0
                   ) AS note_count,
                   CASE
                       WHEN b.read_status_id = ? OR COALESCE(rd.latest_read_done_date, 0) = 0
                       THEN MAX(b.read_status_changed_date, COALESCE(rd.latest_read_done_date, 0))
                       ELSE COALESCE(rd.latest_read_done_date, 0)
                   END AS resolved_read_done_date
            FROM collection_book cb
            INNER JOIN book b ON b.id = cb.book_id
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            LEFT JOIN read_done rd ON rd.book_id = b.id
            LEFT JOIN reading_time rt ON rt.book_id = b.id
            WHERE cb.collection_id = ?
              AND cb.is_deleted = 0
              \(annualBookPredicate)
            ORDER BY \(orderClause)
            """
        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: [
                BookEntryReadingStatus.finished.rawValue,
                BookEntryReadingStatus.finished.rawValue,
                collectionID
            ]
        )
        var seenBookIDs = Set<Int64>()
        var items: [BookCollectionBookItem] = []
        for row in rows {
            let bookID: Int64 = row["book_id"]
            guard !seenBookIDs.contains(bookID) else { continue }
            seenBookIDs.insert(bookID)
            items.append(makeCollectionBookItem(row))
        }
        return items
    }

    nonisolated func makeCollectionBookItem(_ row: Row) -> BookCollectionBookItem {
        let readStatusID: Int64 = row["read_status_id"] ?? 0
        let rawReadDoneCount: Int64 = row["raw_read_done_count"] ?? 0
        let readDoneCount = rawReadDoneCount == 0 && readStatusID == BookEntryReadingStatus.finished.rawValue
            ? 1
            : rawReadDoneCount
        let progress = BookshelfBookPresentationFormatter.readingProgress(
            readPosition: row["read_position"] ?? 0.0,
            currentPositionUnit: row["current_position_unit"] ?? 0,
            totalPosition: row["total_position"] ?? 0,
            totalPagination: row["total_pagination"] ?? 0
        )
        let book = BookshelfBookListItem(
            id: row["book_id"],
            title: row["book_name"] ?? "",
            author: row["book_author"] ?? "",
            cover: row["book_cover"] ?? "",
            readStatusId: readStatusID,
            readStatusName: row["read_status_name"] ?? "",
            readStatusBadgeTitle: BookshelfBookPresentationFormatter.readStatusBadgeTitle(
                readStatusID: readStatusID,
                readStatusName: row["read_status_name"] ?? "",
                readDoneCount: readDoneCount
            ),
            sourceName: row["source_name"] ?? "",
            press: row["press"] ?? "",
            pubDateText: BookshelfBookPresentationFormatter.normalizedPubDateText(from: row["pub_date"] ?? ""),
            score: row["score"] ?? 0,
            noteCount: row["note_count"] ?? 0,
            pinned: false,
            createdDate: row["book_created_date"] ?? 0,
            modifiedDate: row["book_updated_date"] ?? 0,
            readDoneDate: row["resolved_read_done_date"] ?? 0,
            totalReadingTime: row["total_reading_time"] ?? 0,
            readingProgressText: BookshelfBookPresentationFormatter.readingProgressText(from: progress),
            bookmarkText: BookshelfBookPresentationFormatter.bookmarkText(
                readPosition: row["read_position"] ?? 0.0,
                currentPositionUnit: row["current_position_unit"] ?? 0
            )
        )
        return BookCollectionBookItem(
            id: row["relation_id"],
            collectionID: row["collection_id"],
            book: book,
            recommend: row["recommend"] ?? "",
            order: row["relation_order"] ?? 0,
            createdDate: row["relation_created_date"] ?? 0,
            updatedDate: row["relation_updated_date"] ?? 0
        )
    }

    nonisolated func fetchReadTarget(_ db: Database, year: Int64) throws -> Int? {
        guard year > 0 else { return nil }
        // SQL 目的：读取指定年份的年度阅读目标书籍数。
        // 涉及表：read_target。
        // 关键过滤：time = 年份、type = 0、is_deleted = 0。
        // 返回字段用途：年度书单目标达成展示。
        return try Int.fetchOne(
            db,
            sql: """
                SELECT target
                FROM read_target
                WHERE time = ?
                  AND type = 0
                  AND is_deleted = 0
                LIMIT 1
                """,
            arguments: [year]
        )
    }

    nonisolated func minCollectionOrder(_ db: Database) throws -> Int64 {
        // SQL 目的：读取全部有效书单最小 order，新建手动书单插入到最前。
        // 涉及表：collection。
        // 关键过滤：is_deleted = 0；Android queryMinCollectionOrder 不区分年度/手动。
        try Int64.fetchOne(db, sql: "SELECT MIN(`order`) FROM collection WHERE is_deleted = 0") ?? 0
    }

    nonisolated func fetchManualCollectionIDs(_ db: Database) throws -> [Int64] {
        // SQL 目的：读取当前有效手动书单 ID 顺序，用于排序写入补齐遗漏项。
        // 涉及表：collection。
        // 关键过滤：is_deleted = 0、is_annual = 0。
        try Int64.fetchAll(
            db,
            sql: """
                SELECT id
                FROM collection
                WHERE is_deleted = 0
                  AND is_annual = 0
                ORDER BY `order` ASC, id ASC
                """
        )
    }

    nonisolated func fetchCollectionBookRelationIDs(
        _ db: Database,
        collectionID: Int64
    ) throws -> [Int64] {
        // SQL 目的：读取书单内当前有效 relation ID 顺序，用于排序写入补齐遗漏项。
        // 涉及表：collection_book。
        // 关键过滤：collection_id 精确匹配且 is_deleted = 0。
        try Int64.fetchAll(
            db,
            sql: """
                SELECT id
                FROM collection_book
                WHERE collection_id = ?
                  AND is_deleted = 0
                ORDER BY `order` ASC, id ASC
                """,
            arguments: [collectionID]
        )
    }

    nonisolated func validatedCollectionTitle(_ rawValue: String) throws -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw BookshelfBatchWriteError.invalidName("书单")
        }
        guard normalized.count <= BookshelfManagementLimits.collectionNameMaxLength else {
            throw BookshelfBatchWriteError.invalidNameLength(
                target: "书单",
                maxLength: BookshelfManagementLimits.collectionNameMaxLength
            )
        }
        return normalized
    }
}
