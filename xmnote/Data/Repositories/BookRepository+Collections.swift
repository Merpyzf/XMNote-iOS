/**
 * [INPUT]: 依赖 GRDB Database、CollectionRecord、CollectionBookRecord 与书架展示模型，读取和写入 Android 对齐的书单数据
 * [OUTPUT]: 为 BookRepository 补充书单列表、详情、创建、编辑、删除、排序、书单书籍元信息、收藏理由与年度一致性修复能力
 * [POS]: Data 层书单迁移协作者，集中封装 collection / collection_book 的跨端数据语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import SwiftSoup

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

    /// 物理删除手动书单及其全部关系，并清理失去最后引用的占位书。
    nonisolated func deleteBookCollection(_ db: Database, collectionID: Int64) throws {
        guard try isActiveManualCollection(db, collectionID: collectionID) else {
            throw BookshelfBatchWriteError.invalidCollection
        }
        // SQL 目的：在删除书单关系前读取其引用书籍，供关系删除后清理无引用占位书。
        // 涉及表：collection_book。
        // 关键过滤：collection_id 精确匹配；同时覆盖历史 tombstone 关系。
        // 时间字段：不参与查询。
        // 返回字段用途：候选 book.id 仅用于占位书引用闭包清理。
        let referencedBookIDs = try Int64.fetchAll(
            db,
            sql: "SELECT DISTINCT book_id FROM collection_book WHERE collection_id = ? AND book_id > 0",
            arguments: [collectionID]
        )

        // SQL 目的：物理删除该书单下全部关系，为删除 collection 父记录解除外键约束。
        // 涉及表：collection_book。
        // 关键过滤：collection_id 精确匹配；同时清理历史 tombstone。
        // 时间字段：物理删除不更新时间字段。
        try db.execute(
            sql: """
                DELETE FROM collection_book
                WHERE collection_id = ?
                """,
            arguments: [collectionID]
        )

        // SQL 目的：在关系已清理后物理删除目标手动书单。
        // 涉及表：collection。
        // 关键过滤：id 精确匹配且 is_annual = 0；年度书单仍受保护。
        // 时间字段：物理删除不更新时间字段。
        // 副作用用途：完成手动书单不可恢复删除。
        try db.execute(
            sql: "DELETE FROM collection WHERE id = ? AND is_annual = 0",
            arguments: [collectionID]
        )

        for bookID in referencedBookIDs {
            try deleteReferencePlaceholderIfUnreferenced(db, bookID: bookID)
        }
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

    /// 从书单内物理移除 relation，并清理失去最后引用的占位书。
    nonisolated func removeBooksFromCollection(
        _ db: Database,
        collectionBookIDs: [Int64]
    ) throws {
        for id in normalizedPositiveIDs(collectionBookIDs) {
            // SQL 目的：读取待删除书单关系的 book_id，供删除后清理无引用占位书。
            // 涉及表：collection_book。
            // 关键过滤：id 精确匹配。
            // 时间字段：不参与查询。
            // 返回字段用途：候选 book.id 只用于引用闭包清理。
            let bookID = try Int64.fetchOne(
                db,
                sql: "SELECT book_id FROM collection_book WHERE id = ? LIMIT 1",
                arguments: [id]
            )

            // SQL 目的：物理删除单条书单关系。
            // 涉及表：collection_book。
            // 关键过滤：id 精确匹配；同时允许清理历史 tombstone 关系。
            // 时间字段：物理删除不更新时间字段。
            try db.execute(
                sql: "DELETE FROM collection_book WHERE id = ?",
                arguments: [id]
            )
            if let bookID {
                try deleteReferencePlaceholderIfUnreferenced(db, bookID: bookID)
            }
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

    /// 编辑书单内收藏理由，保留 relation 与 book，不改 collection 本体。
    nonisolated func updateCollectionBookRecommend(
        _ db: Database,
        collectionBookID: Int64,
        recommend: String
    ) throws {
        let normalized = recommend.trimmingCharacters(in: .whitespacesAndNewlines)
        // SQL 目的：更新书单内收藏理由，复刻 Android relation update 会刷新 updated_date 的语义。
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

    /// 编辑书单内单本书籍元信息与 relation 收藏理由，保留阅读状态、排序、归属和软删除状态。
    nonisolated func updateCollectionBookMetadata(
        _ db: Database,
        input: BookCollectionBookMetadataEditInput
    ) throws {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.collectionBookID > 0, input.bookID > 0 else {
            throw BookshelfBatchWriteError.invalidBook
        }
        guard !title.isEmpty else {
            throw BookshelfBatchWriteError.invalidName("书籍")
        }

        // SQL 目的：校验书单 relation 仍有效、所属 collection 未删除且 relation.book_id 与输入 bookID 完全一致。
        // 涉及表：collection_book cb INNER JOIN collection c INNER JOIN book b。
        // 关键过滤：cb.id/cb.book_id 精确匹配、cb.is_deleted = 0、c.is_deleted = 0、b.id != 0；不限制 b.is_deleted，以支持占位书与普通书。
        // 时间字段：不读取时间字段。
        // 返回字段用途：存在记录才允许继续更新 book 与 collection_book，防止跨 relation 误写。
        let relationBookID = try Int64.fetchOne(
            db,
            sql: """
                SELECT cb.book_id
                FROM collection_book cb
                INNER JOIN collection c ON c.id = cb.collection_id
                INNER JOIN book b ON b.id = cb.book_id
                WHERE cb.id = ?
                  AND cb.book_id = ?
                  AND cb.is_deleted = 0
                  AND c.is_deleted = 0
                  AND b.id != 0
                LIMIT 1
                """,
            arguments: [input.collectionBookID, input.bookID]
        )
        guard relationBookID == input.bookID else {
            throw BookshelfBatchWriteError.invalidBook
        }

        let now = timestampMillis()
        let author = input.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let press = input.press.trimmingCharacters(in: .whitespacesAndNewlines)
        let pubDate = input.pubDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let coverURL = input.coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let recommend = input.recommend.trimmingCharacters(in: .whitespacesAndNewlines)

        // SQL 目的：更新书单编辑页允许修改的书籍元信息，对齐 Android EditCollectionBookActivity 写回 Book.name/author/press/pubDate/cover。
        // 涉及表：book。
        // 关键过滤：id 精确匹配且 id != 0；不限制 is_deleted，保留占位书 is_deleted = 1 与普通书 is_deleted = 0 的状态。
        // 时间字段：updated_date 写入当前 Unix epoch 毫秒值，不做时区换算；created_date/last_sync_date/read_status_changed_date 不变。
        // 副作用用途：刷新书单详情、书架/搜索等读取 book 元信息的展示，但不改变 raw_name、阅读状态、进度、排序或归属。
        try db.execute(
            sql: """
                UPDATE book
                SET name = ?,
                    author = ?,
                    press = ?,
                    pub_date = ?,
                    cover = ?,
                    updated_date = ?
                WHERE id = ?
                  AND id != 0
                """,
            arguments: [title, author, press, pubDate, coverURL, now, input.bookID]
        )

        // SQL 目的：更新同一书单 relation 的收藏理由，对齐 Android upsertManualCollectionBook 同时更新 CollectionBook.recommend。
        // 涉及表：collection_book。
        // 关键过滤：id 与 book_id 精确匹配且 is_deleted = 0。
        // 时间字段：updated_date 写入当前 Unix epoch 毫秒值，不做时区换算；created_date/last_sync_date 不变。
        // 副作用用途：刷新书单详情中的收藏理由/年度点评，不改变 collection_id、order 或 relation 软删除状态。
        try db.execute(
            sql: """
                UPDATE collection_book
                SET recommend = ?,
                    updated_date = ?
                WHERE id = ?
                  AND book_id = ?
                  AND is_deleted = 0
                """,
            arguments: [recommend, now, input.collectionBookID, input.bookID]
        )
    }

    /// 将本地书与占位书草稿写入指定手动书单，保持 relation 去重与草稿占位落库在同一事务内完成。
    nonisolated func addBookSelectionsToCollection(
        _ db: Database,
        selections: [BookCollectionBookSelectionInput],
        collectionID: Int64
    ) throws {
        guard !selections.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try isActiveManualCollection(db, collectionID: collectionID) else {
            throw BookshelfBatchWriteError.invalidCollection
        }

        for selection in selections {
            switch selection {
            case .localBook(let id):
                try addBooksToCollection(db, bookIDs: [id], collectionID: collectionID)
            case .placeholder(let draft):
                guard try !hasActiveCollectionBookRelation(
                    db,
                    title: draft.title,
                    author: draft.author,
                    collectionID: collectionID
                ) else {
                    continue
                }
                let bookID = try insertCollectionPlaceholderBook(db, draft: draft)
                try insertCollectionBookRelationIfNeeded(
                    db,
                    bookID: bookID,
                    collectionID: collectionID,
                    recommend: draft.recommend
                )
            }
        }
    }

    /// 将书单占位书恢复为有效书架书籍，并按 Android `addBookToRead` 语义切到在读状态。
    nonisolated func restoreCollectionPlaceholderBook(_ db: Database, bookID: Int64) throws {
        guard bookID > 0 else { throw BookshelfBatchWriteError.emptySelection }
        guard try isPlaceholderBook(db, bookID: bookID) else {
            throw BookshelfBatchWriteError.invalidBook
        }

        let now = timestampMillis()
        let order = try maxDefaultBookshelfOrder(db) + 1
        // SQL 目的：把 Android 书单占位书恢复为书架有效书，并放到默认书架尾部。
        // 涉及表：book。
        // 关键过滤：id 精确匹配、is_deleted = 1、id != 0。
        // 时间字段：updated_date/read_status_changed_date/purchase_date 写入当前毫秒。
        // 副作用用途：让占位书可进入书架、详情和阅读状态相关列表。
        try db.execute(
            sql: """
                UPDATE book
                SET is_deleted = 0,
                    book_order = ?,
                    read_status_id = ?,
                    read_status_changed_date = ?,
                    purchase_date = ?,
                    updated_date = ?
                WHERE id = ?
                  AND is_deleted = 1
                  AND id != 0
                """,
            arguments: [order, BookEntryReadingStatus.reading.rawValue, now, now, now, bookID]
        )
        try BookReadStatusMutation.updateBookReadStatus(
            db,
            bookID: bookID,
            statusID: BookEntryReadingStatus.reading.rawValue,
            changedAt: now,
            updatedAt: now,
            finishedRatingScore: nil
        )
    }

    /// 更新年度书单本体说明，年度标题、年份和成员仍由系统维护。
    nonisolated func updateAnnualBookCollectionDescription(
        _ db: Database,
        collectionID: Int64,
        description: String
    ) throws {
        let normalized = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try isActiveAnnualCollection(db, collectionID: collectionID) else {
            throw BookshelfBatchWriteError.invalidCollection
        }
        // SQL 目的：仅更新年度书单简介字段，对齐 Android 年度编辑页允许 desc 写入但禁用标题的语义。
        // 涉及表：collection。
        // 关键过滤：id 精确匹配、is_deleted = 0、is_annual = 1。
        // 时间字段：updated_date 写入当前毫秒。
        // 副作用用途：刷新年度详情 Header 的年度说明。
        try db.execute(
            sql: """
                UPDATE collection
                SET `desc` = ?,
                    updated_date = ?
                WHERE id = ?
                  AND is_deleted = 0
                  AND is_annual = 1
                """,
            arguments: [normalized, timestampMillis(), collectionID]
        )
    }

    /// 保存微信读书导入预览；同标题与简介的有效书单已存在时复用，避免重复导入产生重复书单。
    nonisolated func saveWereadBookCollectionImport(
        _ db: Database,
        preview: BookCollectionImportPreview
    ) throws -> Int64 {
        guard !preview.books.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        let title = preview.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "微信读书书单"
            : preview.title
        let description = preview.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let collectionID = try fetchActiveCollectionID(
            db,
            title: title,
            description: description
        ) ?? createBookCollection(
            db,
            input: BookCollectionFormInput(title: title, description: description)
        )
        let selections = preview.books.map { BookCollectionBookSelectionInput.placeholder($0.placeholderDraft) }
        try addBookSelectionsToExistingCollection(db, selections: selections, collectionID: collectionID)
        return collectionID
    }

    /// 抓取并解析微信读书书单页面，返回导入预览；解析阶段不写入数据库。
    func parseWereadBookCollectionImportPreview(link: String) async throws -> BookCollectionImportPreview {
        let url = try Self.normalizedWereadCollectionURL(from: link)
        let result = try await WebHTMLFetchService.shared.fetchHTML(
            WebHTMLFetchRequest(url: url, channel: .automatic, sessionScope: .sharedDefault)
        )
        return try Self.parseWereadCollectionHTML(result.html, sourceURL: result.finalURL.absoluteString)
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
        let finishedCount = isAnnual
            ? books.count
            : books.filter { $0.book.readStatusId == BookEntryReadingStatus.finished.rawValue }.count
        let yearValue: Int64 = row["year"] ?? 0
        return BookCollectionListItem(
            id: collectionID,
            title: row["title"] ?? "",
            description: row["description"] ?? "",
            kind: isAnnual ? .annual : .manual,
            order: row["order"] ?? 0,
            year: isAnnual ? Int(yearValue) : nil,
            bookCount: books.count,
            finishedCount: finishedCount,
            targetReadCount: isAnnual ? try fetchReadTarget(db, year: yearValue) : nil,
            representativeCovers: books.prefix(5).map(\.book.cover)
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
        // 返回字段用途：构建书单详情书籍行、简介预览、收藏理由和 relation 写入目标。
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
                   COALESCE(b.summary, '') AS book_summary,
                   b.is_deleted AS book_is_deleted,
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
            summary: row["book_summary"] ?? "",
            summaryPlainText: "",
            recommend: row["recommend"] ?? "",
            isPlaceholder: (row["book_is_deleted"] as Int64? ?? 0) != 0,
            order: row["relation_order"] ?? 0,
            createdDate: row["relation_created_date"] ?? 0,
            updatedDate: row["relation_updated_date"] ?? 0
        )
    }

    nonisolated func isActiveAnnualCollection(_ db: Database, collectionID: Int64) throws -> Bool {
        // SQL 目的：确认年度说明更新目标仍是有效年度书单。
        // 涉及表：collection。
        // 关键过滤：id 精确匹配、is_deleted = 0、is_annual = 1。
        // 时间字段：不参与。
        // 返回字段用途：阻止手动书单误走年度说明入口。
        let sql = """
            SELECT COUNT(*)
            FROM collection
            WHERE id = ?
              AND is_deleted = 0
              AND is_annual = 1
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [collectionID]) ?? 0) > 0
    }

    nonisolated func isPlaceholderBook(_ db: Database, bookID: Int64) throws -> Bool {
        // SQL 目的：确认目标书籍仍是书单占位书。
        // 涉及表：book。
        // 关键过滤：id 精确匹配、is_deleted = 1、id != 0。
        // 时间字段：不参与。
        // 返回字段用途：恢复占位书前做状态校验，避免重复恢复。
        let sql = """
            SELECT COUNT(*)
            FROM book
            WHERE id = ?
              AND is_deleted = 1
              AND id != 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [bookID]) ?? 0) > 0
    }

    nonisolated func insertCollectionPlaceholderBook(
        _ db: Database,
        draft: BookCollectionPlaceholderBookDraft
    ) throws -> Int64 {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BookshelfBatchWriteError.invalidName("书籍") }
        let now = timestampMillis()
        let bookType = draft.preferredBookType ?? .paper
        let progressUnit = draft.preferredProgressUnit ?? (bookType == .paper ? .pagination : .position)
        var record = BookRecord(
            id: nil,
            userId: try DatabaseOwnerResolver.resolveOwnerID(in: db),
            doubanId: Int64(draft.doubanId ?? 0),
            name: title,
            rawName: draft.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : draft.rawTitle,
            cover: draft.coverURL,
            author: draft.author,
            authorIntro: "",
            translator: draft.translator,
            isbn: draft.isbn,
            pubDate: draft.pubDate,
            press: draft.press,
            summary: draft.summary,
            readPosition: 0,
            totalPosition: 0,
            totalPagination: Int64(draft.totalPages ?? 0),
            type: bookType.rawValue,
            currentPositionUnit: progressUnit.rawValue,
            positionUnit: progressUnit.rawValue,
            sourceId: DatabaseOwnerResolver.defaultSourceID,
            purchaseDate: 0,
            price: 0,
            bookOrder: 0,
            pinned: 0,
            pinOrder: 0,
            readStatusId: BookEntryReadingStatus.wantRead.rawValue,
            readStatusChangedDate: 0,
            score: 0,
            catalog: "",
            bookMarkModifiedTime: 0,
            wordCount: draft.totalWordCount.map(Int64.init),
            createdDate: now,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 1
        )
        try record.insert(db)
        return record.id ?? db.lastInsertedRowID
    }

    nonisolated func insertCollectionBookRelationIfNeeded(
        _ db: Database,
        bookID: Int64,
        collectionID: Int64,
        recommend: String
    ) throws {
        guard try !hasActiveCollectionBookRelationMatchingBookIdentity(
            db,
            bookID: bookID,
            collectionID: collectionID
        ) else {
            return
        }
        let now = timestampMillis()
        var relation = CollectionBookRecord(
            id: nil,
            collectionId: collectionID,
            bookId: bookID,
            recommend: recommend.trimmingCharacters(in: .whitespacesAndNewlines),
            order: try nextCollectionBookOrder(db, collectionID: collectionID),
            createdDate: now,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try relation.insert(db)
    }

    /// 按 Android `collection_id + book.name + book.author` 口径判断书单内是否已有同一本业务书籍。
    nonisolated func hasActiveCollectionBookRelation(
        _ db: Database,
        title: String,
        author: String,
        collectionID: Int64
    ) throws -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return false }

        // SQL 目的：复刻 Android CollectionBookDao.queryBook(id, name, author)，以书名+作者而非 book_id 判断同一书单内是否已存在该书。
        // 涉及表：collection_book INNER JOIN book。
        // 关键过滤：collection_id 精确匹配、relation 未删除、book.name/book.author 与输入精确匹配。
        // 时间字段：不参与。
        // 返回字段用途：已有有效关系时跳过新增 relation 与占位书落库，保留原 recommend/order。
        let sql = """
            SELECT cb.id
            FROM collection_book cb
            INNER JOIN book b ON b.id = cb.book_id
            WHERE cb.collection_id = ?
              AND cb.is_deleted = 0
              AND b.name = ?
              AND b.author = ?
            LIMIT 1
            """
        return try Int64.fetchOne(
            db,
            sql: sql,
            arguments: [collectionID, normalizedTitle, normalizedAuthor]
        ) != nil
    }

    /// 读取候选书自身的书名与作者，并按 Android 书名+作者口径判断目标书单是否已有等价关系。
    nonisolated func hasActiveCollectionBookRelationMatchingBookIdentity(
        _ db: Database,
        bookID: Int64,
        collectionID: Int64
    ) throws -> Bool {
        guard bookID > 0 else { return false }

        // SQL 目的：本地书加入书单前，用候选 book 的 name/author 与现有 relation 关联 book 比对，复刻 Android 同名同作者去重策略。
        // 涉及表：book candidate、collection_book cb、book existing。
        // 关键过滤：candidate.id 精确匹配，cb.collection_id 精确匹配且 cb.is_deleted = 0，existing.name/author 与 candidate.name/author 完全一致。
        // 时间字段：不参与。
        // 返回字段用途：目标书单已有同名同作者书籍时跳过新增 relation，即使 book_id 不同。
        let sql = """
            SELECT cb.id
            FROM book candidate
            INNER JOIN book existing
                ON existing.name = candidate.name
               AND existing.author = candidate.author
            INNER JOIN collection_book cb
                ON cb.book_id = existing.id
            WHERE candidate.id = ?
              AND cb.collection_id = ?
              AND cb.is_deleted = 0
            LIMIT 1
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [bookID, collectionID]) != nil
    }

    /// 查找与 Android `CollectionDao.query(title, desc)` 相同口径的有效书单，用于微信读书重复导入复用。
    nonisolated func fetchActiveCollectionID(
        _ db: Database,
        title: String,
        description: String
    ) throws -> Int64? {
        // SQL 目的：按 Android 微信读书导入路径复用同标题与简介的有效书单，避免重复导入报错或创建副本。
        // 涉及表：collection。
        // 关键过滤：title/desc 精确匹配且 is_deleted = 0；不额外排除年度书单，保持 Android CollectionDao.query 原始口径。
        // 时间字段：不参与。
        // 返回字段用途：存在记录时作为导入目标 collection_id。
        try Int64.fetchOne(
            db,
            sql: """
                SELECT id
                FROM collection
                WHERE title = ?
                  AND `desc` = ?
                  AND is_deleted = 0
                LIMIT 1
                """,
            arguments: [
                title.trimmingCharacters(in: .whitespacesAndNewlines),
                description.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        )
    }

    /// 将导入或远端草稿加入已存在书单；调用方负责限定业务入口，关系去重按 Android 书名+作者口径执行。
    nonisolated func addBookSelectionsToExistingCollection(
        _ db: Database,
        selections: [BookCollectionBookSelectionInput],
        collectionID: Int64
    ) throws {
        guard !selections.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try collectionRow(db, collectionID: collectionID) != nil else {
            throw BookshelfBatchWriteError.invalidCollection
        }

        for selection in selections {
            switch selection {
            case .localBook(let id):
                try addBooksToCollection(db, bookIDs: [id], collectionID: collectionID)
            case .placeholder(let draft):
                guard try !hasActiveCollectionBookRelation(
                    db,
                    title: draft.title,
                    author: draft.author,
                    collectionID: collectionID
                ) else {
                    continue
                }
                let bookID = try insertCollectionPlaceholderBook(db, draft: draft)
                try insertCollectionBookRelationIfNeeded(
                    db,
                    bookID: bookID,
                    collectionID: collectionID,
                    recommend: draft.recommend
                )
            }
        }
    }

    nonisolated func nextCollectionBookOrder(_ db: Database, collectionID: Int64) throws -> Int64 {
        // SQL 目的：读取当前书单 relation 最大 order，新加入占位书追加到末尾。
        // 涉及表：collection_book。
        // 关键过滤：collection_id 精确匹配且 is_deleted = 0。
        // 时间字段：不参与。
        // 返回字段用途：新 relation order = max + 1，空书单从 0 开始。
        let maxOrder = try Int64.fetchOne(
            db,
            sql: """
                SELECT MAX(`order`)
                FROM collection_book
                WHERE collection_id = ?
                  AND is_deleted = 0
                """,
            arguments: [collectionID]
        ) ?? -1
        return maxOrder + 1
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

    nonisolated static func normalizedWereadCollectionURL(from rawValue: String) throws -> URL {
        let candidates = rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "，。,.<>[]()（）")) }
        guard let url = candidates.compactMap({ URL(string: $0) }).first(where: { url in
            WereadCollectionLinkExtractor.isSupportedWereadURL(url)
        }) else {
            throw BookCollectionWereadImportError.invalidLink
        }
        return url
    }

    nonisolated static func parseWereadCollectionHTML(
        _ html: String,
        sourceURL: String
    ) throws -> BookCollectionImportPreview {
        let document = try SwiftSoup.parse(html)
        let title = try firstText(
            in: document,
            selectors: [".booklist_header_title", ".wr_bookListHeader_title", "title"]
        )
        let description = try firstText(
            in: document,
            selectors: [".booklist_header_desc", ".wr_bookListHeader_desc", ".booklist_header_intro"]
        )
        let nodes = try document.select(".booklist_books li, .wr_bookList li, li.booklist_book")
        var books: [BookCollectionImportPreviewBook] = []
        for node in nodes.array() {
            let bookTitle = try firstText(
                in: node,
                selectors: [".booklist_book_title", ".wr_bookList_item_title", ".title"]
            )
            guard !bookTitle.isEmpty else { continue }
            let author = try firstText(
                in: node,
                selectors: [".booklist_book_author", ".wr_bookList_item_author", ".author"]
            )
            let recommend = try firstText(
                in: node,
                selectors: [".booklist_book_description_content", ".booklist_book_description", ".wr_bookList_item_desc"]
            )
            let coverURL = try firstAttribute(
                in: node,
                selectors: ["img"],
                attributes: ["src", "data-src", "data-original"]
            )
            books.append(
                BookCollectionImportPreviewBook(
                    title: bookTitle,
                    author: author,
                    coverURL: coverURL,
                    recommend: recommend
                )
            )
        }
        guard !books.isEmpty else {
            throw BookCollectionWereadImportError.noBooks
        }
        return BookCollectionImportPreview(
            sourceURL: sourceURL,
            title: title.isEmpty ? "微信读书书单" : title,
            description: description,
            books: books
        )
    }

    nonisolated static func firstText(
        in element: Element,
        selectors: [String]
    ) throws -> String {
        for selector in selectors {
            if let candidate = try element.select(selector).first() {
                let text = try candidate.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    nonisolated static func firstAttribute(
        in element: Element,
        selectors: [String],
        attributes: [String]
    ) throws -> String {
        for selector in selectors {
            for node in try element.select(selector).array() {
                for attribute in attributes {
                    let value = try node.attr(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        return value
                    }
                }
            }
        }
        return ""
    }
}

private enum BookCollectionWereadImportError: LocalizedError {
    case invalidLink
    case noBooks

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "请粘贴有效的微信读书书单链接"
        case .noBooks:
            return "没有解析到书单书籍，请确认链接可以正常访问"
        }
    }
}
