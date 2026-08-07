import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 ObservationStream 提供数据库观察流桥接，依赖通用内容查看领域模型完成跨类型映射
 * [OUTPUT]: 对外提供 ContentRepository（ContentRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层通用内容查看仓储实现，统一封装书摘/书评/相关内容的查看、编辑与硬删除事务，并对齐 Android 的相关书籍固定分类语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 通用内容查看仓储实现，负责 viewer feed、详情读取、编辑保存与硬删除事务。
struct ContentRepository: ContentRepositoryProtocol {
    private nonisolated static let relatedBookCategoryID: Int64 = 1

    private let databaseManager: DatabaseManager

    /// 注入数据库管理器，供内容查看与编辑链路复用同一数据源。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    /// 持续监听指定来源下的分页内容列表。
    func observeViewerItems(source: ContentViewerSourceContext) -> AsyncThrowingStream<[ContentViewerListItem], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            switch source {
            case .timeline(let startTimestamp, let endTimestamp, let filter):
                try buildTimelineViewerItems(
                    db,
                    startTimestamp: startTimestamp,
                    endTimestamp: endTimestamp,
                    filter: filter
                )
            case .bookNotes(let bookId):
                try fetchBookNoteViewerItems(db, bookId: bookId)
            case .noteReview(let noteIDs):
                try fetchNoteReviewViewerItems(db, noteIDs: noteIDs)
            }
        }
    }

    /// 按统一 itemID 拉取查看页完整详情。
    func fetchViewerDetail(itemID: ContentViewerItemID) async throws -> ContentViewerDetail? {
        try await databaseManager.database.dbPool.read { db in
            switch itemID {
            case .note(let noteId):
                try fetchNoteDetail(db, noteId: noteId).map(ContentViewerDetail.note)
            case .review(let reviewId):
                try fetchReviewDetail(db, reviewId: reviewId).map(ContentViewerDetail.review)
            case .relevant(let contentId):
                try fetchRelevantDetail(db, contentId: contentId).map(ContentViewerDetail.relevant)
            }
        }
    }

    /// 读取书评编辑草稿。
    func fetchReviewEditorDraft(reviewId: Int64) async throws -> ReviewEditorDraft? {
        try await databaseManager.database.dbPool.read { db in
            guard let detail = try fetchReviewDetail(db, reviewId: reviewId) else { return nil }
            return ReviewEditorDraft(
                reviewId: detail.reviewId,
                sourceBookId: detail.sourceBookId,
                bookTitle: detail.bookTitle,
                title: detail.title,
                contentHTML: detail.contentHTML,
                imageURLs: detail.imageURLs
            )
        }
    }

    /// 保存书评编辑草稿。
    func saveReviewEditorDraft(_ draft: ReviewEditorDraft) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await databaseManager.database.dbPool.write { db in
            try db.execute(
                // SQL 目的：更新单条书评的标题、HTML 正文与更新时间。
                // 涉及表：review。
                // 关键过滤：按 review.id 精确命中，且只更新 iOS/Android 共同定义的有效记录（is_deleted = 0）。
                // 副作用：不改动图片、book_id 与同步字段。
                sql: """
                    UPDATE review
                    SET title = ?, content = ?, updated_date = ?
                    WHERE id = ? AND is_deleted = 0
                """,
                arguments: [draft.title, draft.contentHTML, now, draft.reviewId]
            )
        }
    }

    /// 读取相关内容编辑草稿。
    func fetchRelevantEditorDraft(contentId: Int64) async throws -> RelevantEditorDraft? {
        try await databaseManager.database.dbPool.read { db in
            guard let detail = try fetchRelevantDetail(db, contentId: contentId) else { return nil }
            return RelevantEditorDraft(
                contentId: detail.contentId,
                sourceBookId: detail.sourceBookId,
                categoryId: detail.categoryId,
                bookTitle: detail.bookTitle,
                categoryTitle: detail.categoryTitle,
                title: detail.title,
                contentHTML: detail.contentHTML,
                url: detail.url,
                imageURLs: detail.imageURLs
            )
        }
    }

    /// 保存相关内容编辑草稿。
    func saveRelevantEditorDraft(_ draft: RelevantEditorDraft) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await databaseManager.database.dbPool.write { db in
            try db.execute(
                // SQL 目的：更新单条相关内容的标题、HTML 正文、链接与更新时间。
                // 涉及表：category_content。
                // 关键过滤：按主键精确命中，且排除 Android 已软删除记录（is_deleted = 0）。
                // 副作用：不触碰 category_id、content_book_id 与图片子表。
                sql: """
                    UPDATE category_content
                    SET title = ?, content = ?, url = ?, updated_date = ?
                    WHERE id = ? AND is_deleted = 0
                """,
                arguments: [draft.title, draft.contentHTML, draft.url, now, draft.contentId]
            )
        }
    }

    /// 读取相关书籍关系与关联目标书。
    func fetchRelatedBookRelationDraft(relationID: Int64) async throws -> RelatedBookRelationDraft? {
        try await databaseManager.database.dbPool.read { db in
            // SQL 目的：读取一条有效相关书籍关系及关联书籍的选书器回显字段。
            // 涉及表：category_content INNER JOIN book。
            // 关键过滤：relation 主键命中、is_deleted=0、content_book_id!=0，关联书籍也必须有效。
            // 时间字段：不读取时间字段；返回字段只用于构造编辑草稿。
            // 返回字段用途：回显来源书与关联目标书。
            let relationSQL = """
                SELECT cc.id, cc.book_id,
                       b.id AS content_book_id, b.name, b.author, b.press, b.cover,
                       b.position_unit, b.total_position, b.total_pagination
                FROM category_content cc
                JOIN book b ON b.id = cc.content_book_id AND b.is_deleted = 0
                WHERE cc.id = ? AND cc.is_deleted = 0 AND cc.content_book_id != 0
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: relationSQL, arguments: [relationID]) else { return nil }
            let sourceBookID: Int64 = row["book_id"]
            return RelatedBookRelationDraft(
                id: row["id"],
                sourceBookID: sourceBookID,
                contentBook: BookPickerBook(
                    id: row["content_book_id"],
                    title: row["name"] ?? "",
                    author: row["author"] ?? "",
                    press: row["press"] ?? "",
                    coverURL: row["cover"] ?? "",
                    positionUnit: row["position_unit"] ?? 0,
                    totalPosition: row["total_position"] ?? 0,
                    totalPagination: row["total_pagination"] ?? 0
                )
            )
        }
    }

    /// 保存相关书籍关系；按 Android AppConstant.Categories.BOOK 固定写入分类 ID 1。
    func saveRelatedBookRelationDraft(_ draft: RelatedBookRelationDraft) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：更新相关书籍关系的目标书，并固定写入 Android 定义的“书籍”分类 ID 1。
            // 涉及表：category_content；book/category 由子查询完成有效性校验。
            // 关键过滤：relation 主键、来源书、is_deleted=0，目标书与固定分类都必须有效。
            // 时间字段：updated_date 写当前毫秒时间戳。
            // 副作用用途：让时间线、当日记录和相关列表观察流同步关系变更。
            let sql = """
                UPDATE category_content
                SET content_book_id = ?, category_id = ?, updated_date = ?
                WHERE id = ? AND book_id = ? AND is_deleted = 0
                  AND EXISTS (SELECT 1 FROM book WHERE id = ? AND is_deleted = 0)
                  AND EXISTS (SELECT 1 FROM category WHERE id = ? AND is_deleted = 0)
                """
            try db.execute(
                sql: sql,
                arguments: [
                    draft.contentBook.id, Self.relatedBookCategoryID, now,
                    draft.id, draft.sourceBookID,
                    draft.contentBook.id,
                    Self.relatedBookCategoryID
                ]
            )
        }
    }

    /// 物理删除普通相关内容或相关书籍关系，并在最后引用移除后清理占位书。
    func deleteRelatedRelation(relationID: Int64) async throws {
        try await databaseManager.database.dbPool.write { db in
            try deleteRelevant(db, contentId: relationID)
        }
    }

    /// 删除指定内容，按 iOS 当前约定执行主记录与子记录的硬删除事务。
    func delete(itemID: ContentViewerItemID) async throws {
        try await databaseManager.database.dbPool.write { db in
            try db.inTransaction {
                switch itemID {
                case .note(let noteId):
                    try deleteNote(db, noteId: noteId)
                case .review(let reviewId):
                    try deleteReview(db, reviewId: reviewId)
                case .relevant(let contentId):
                    try deleteRelevant(db, contentId: contentId)
                }
                return .commit
            }
        }
    }
}

// MARK: - Feed Queries

private extension ContentRepository {
    /// 查询时间线来源下的内容分页列表，并统一按时间倒序输出。
    nonisolated func buildTimelineViewerItems(
        _ db: Database,
        startTimestamp: Int64,
        endTimestamp: Int64,
        filter: TimelineContentFilter
    ) throws -> [ContentViewerListItem] {
        switch filter {
        case .allContent:
            return try fetchTimelineMixedViewerItems(
                db,
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp
            )
        case .note:
            return try fetchTimelineNoteViewerItems(
                db,
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp
            )
        case .review:
            return try fetchTimelineReviewViewerItems(
                db,
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp
            )
        case .relevant:
            return try fetchTimelineRelevantViewerItems(
                db,
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp
            )
        }
    }

    /// 查询时间线范围内的混合 viewer 列表，在数据库内完成跨类型合并与稳定排序。
    nonisolated func fetchTimelineMixedViewerItems(
        _ db: Database,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> [ContentViewerListItem] {
        // SQL 目的：在数据库内完成书摘/书评/相关内容的混合聚合与稳定排序，避免内存侧二次排序开销。
        // 涉及表：note/review/category_content 与 book。
        // 关键过滤：三类内容统一限制 is_deleted=0 与 created_date 范围；相关内容额外排除 content_book_id != 0。
        // 排序：created_date DESC，再按 (id * 10 + type_rank) DESC，对齐既有 feedSortKey 语义。
        let sql = """
            SELECT item_type, item_id, source_book_id, book_title, timestamp
            FROM (
                SELECT
                    1 AS item_type,
                    n.id AS item_id,
                    n.book_id AS source_book_id,
                    b.name AS book_title,
                    n.created_date AS timestamp
                FROM note n
                JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
                WHERE n.is_deleted = 0
                  AND n.created_date BETWEEN ? AND ?

                UNION ALL

                SELECT
                    2 AS item_type,
                    rv.id AS item_id,
                    rv.book_id AS source_book_id,
                    b.name AS book_title,
                    rv.created_date AS timestamp
                FROM review rv
                JOIN book b ON b.id = rv.book_id AND b.is_deleted = 0
                WHERE rv.is_deleted = 0
                  AND rv.created_date BETWEEN ? AND ?

                UNION ALL

                SELECT
                    3 AS item_type,
                    cc.id AS item_id,
                    cc.book_id AS source_book_id,
                    b.name AS book_title,
                    cc.created_date AS timestamp
                FROM category_content cc
                JOIN book b ON b.id = cc.book_id AND b.is_deleted = 0
                WHERE cc.is_deleted = 0
                  AND cc.content_book_id = 0
                  AND cc.created_date BETWEEN ? AND ?
            )
            ORDER BY timestamp DESC, (item_id * 10 + item_type) DESC
        """

        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: [
                startTimestamp, endTimestamp,
                startTimestamp, endTimestamp,
                startTimestamp, endTimestamp
            ]
        )

        return rows.compactMap { row in
            let itemType = row["item_type"] as Int64? ?? 0
            let itemID = row["item_id"] as Int64? ?? 0
            let sourceBookId = row["source_book_id"] as Int64? ?? 0
            let bookTitle = row["book_title"] as String? ?? ""
            let timestamp = row["timestamp"] as Int64? ?? 0

            let id: ContentViewerItemID
            switch itemType {
            case 1:
                id = .note(itemID)
            case 2:
                id = .review(itemID)
            case 3:
                id = .relevant(itemID)
            default:
                return nil
            }

            return ContentViewerListItem(
                id: id,
                sourceBookId: sourceBookId,
                bookTitle: bookTitle,
                timestamp: timestamp
            )
        }
    }

    /// 查询时间线范围内的书摘 viewer 列表。
    nonisolated func fetchTimelineNoteViewerItems(
        _ db: Database,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> [ContentViewerListItem] {
        // SQL 目的：提取时间线中的书摘内容项，供通用查看器在“书摘/全部内容”来源下横向分页。
        // 涉及表：note INNER JOIN book。
        // 关键过滤：排除 note/book 的软删除记录，并按 created_date 命中当前时间范围。
        // 返回字段：note 主键、所属 book_id、书名、created_date。
        let sql = """
            SELECT n.id, n.book_id, n.created_date, b.name
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            WHERE n.is_deleted = 0 AND n.created_date BETWEEN ? AND ?
            ORDER BY n.created_date DESC, n.id DESC
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [startTimestamp, endTimestamp])
        return rows.map { row in
            ContentViewerListItem(
                id: .note(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["name"] ?? "",
                timestamp: row["created_date"]
            )
        }
    }

    /// 查询时间线范围内的书评 viewer 列表。
    nonisolated func fetchTimelineReviewViewerItems(
        _ db: Database,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> [ContentViewerListItem] {
        // SQL 目的：提取时间线中的书评内容项，供通用查看器在“书评/全部内容”来源下横向分页。
        // 涉及表：review INNER JOIN book。
        // 关键过滤：排除 review/book 的软删除记录，并按 created_date 命中当前时间范围。
        // 返回字段：review 主键、所属 book_id、书名、created_date。
        let sql = """
            SELECT rv.id, rv.book_id, rv.created_date, b.name
            FROM review rv
            JOIN book b ON b.id = rv.book_id AND b.is_deleted = 0
            WHERE rv.is_deleted = 0 AND rv.created_date BETWEEN ? AND ?
            ORDER BY rv.created_date DESC, rv.id DESC
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [startTimestamp, endTimestamp])
        return rows.map { row in
            ContentViewerListItem(
                id: .review(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["name"] ?? "",
                timestamp: row["created_date"]
            )
        }
    }

    /// 查询时间线范围内的相关内容 viewer 列表，仅保留真正的内容项，排除相关书籍。
    nonisolated func fetchTimelineRelevantViewerItems(
        _ db: Database,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> [ContentViewerListItem] {
        // SQL 目的：提取时间线中的相关内容项，供通用查看器在“相关/全部内容”来源下横向分页。
        // 涉及表：category_content INNER JOIN book。
        // 关键过滤：排除 category_content/book 的软删除记录，限制 created_date 范围，并显式剔除 content_book_id != 0 的相关书籍卡。
        // 返回字段：category_content 主键、所属 book_id、书名、created_date。
        let sql = """
            SELECT cc.id, cc.book_id, cc.created_date, b.name
            FROM category_content cc
            JOIN book b ON b.id = cc.book_id AND b.is_deleted = 0
            WHERE cc.is_deleted = 0
              AND cc.content_book_id = 0
              AND cc.created_date BETWEEN ? AND ?
            ORDER BY cc.created_date DESC, cc.id DESC
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [startTimestamp, endTimestamp])
        return rows.map { row in
            ContentViewerListItem(
                id: .relevant(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["name"] ?? "",
                timestamp: row["created_date"]
            )
        }
    }

    /// 查询书籍详情来源下的书摘 viewer 列表。
    nonisolated func fetchBookNoteViewerItems(_ db: Database, bookId: Int64) throws -> [ContentViewerListItem] {
        // SQL 目的：提取指定书籍下的全部有效书摘，供书籍详情进入通用查看器后横向分页。
        // 涉及表：note INNER JOIN book。
        // 关键过滤：按 book_id 精确命中，且排除 note/book 的软删除记录。
        // 排序：与 BookDetailView 当前列表保持一致，按 created_date DESC。
        let sql = """
            SELECT n.id, n.book_id, n.created_date, b.name
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            WHERE n.book_id = ? AND n.is_deleted = 0
            ORDER BY n.created_date DESC, n.id DESC
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [bookId])
        return rows.map { row in
            ContentViewerListItem(
                id: .note(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["name"] ?? "",
                timestamp: row["created_date"]
            )
        }
    }

    /// 查询书摘回顾来源下的 viewer 列表，按卡堆当前顺序输出。
    nonisolated func fetchNoteReviewViewerItems(_ db: Database, noteIDs: [Int64]) throws -> [ContentViewerListItem] {
        let ids = Self.uniquePositiveIDs(noteIDs)
        guard !ids.isEmpty else { return [] }

        // SQL 目的：按回顾卡堆当前 note_id 集合读取通用查看器分页项。
        // 涉及表：note LEFT JOIN book。
        // 关键过滤：限定 note.id IN 当前卡堆列表，并排除已软删除书摘；book 仅用于展示书名。
        // 排序：数据库仅批量取数，最终顺序在内存侧恢复为卡堆传入顺序。
        // 时间字段：created_date 为 Android 毫秒时间戳，读取阶段不做时区转换。
        // 返回字段用途：构建 ContentViewerListItem，让详情页继续复用 fetchViewerDetail 读取完整内容。
        let sql = """
            SELECT n.id, n.book_id, n.created_date, COALESCE(b.name, '') AS book_name
            FROM note n
            LEFT JOIN book b ON b.id = n.book_id
            WHERE n.id IN (\(Self.placeholders(count: ids.count)))
              AND n.is_deleted = 0
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(ids))
        let itemsByID: [Int64: ContentViewerListItem] = Dictionary(
            uniqueKeysWithValues: rows.map { row in
                let noteID: Int64 = row["id"]
                return (
                    noteID,
                    ContentViewerListItem(
                        id: .note(noteID),
                        sourceBookId: row["book_id"],
                        bookTitle: row["book_name"] ?? "",
                        timestamp: row["created_date"]
                    )
                )
            }
        )
        return ids.compactMap { itemsByID[$0] }
    }
}

// MARK: - Detail Queries

private extension ContentRepository {
    /// 读取单条书摘详情，并补齐章节、附图与标签。
    nonisolated func fetchNoteDetail(_ db: Database, noteId: Int64) throws -> NoteContentDetail? {
        // SQL 目的：按主键读取单条书摘完整详情。
        // 涉及表：note INNER JOIN book LEFT JOIN chapter。
        // 关键过滤：排除 note/book/chapter 的软删除记录；chapter 缺失时允许为空。
        // 返回字段：viewer 渲染与编辑跳转所需的正文、想法、位置、时间、书名与章节名。
        let sql = """
            SELECT n.id, n.book_id, n.content, n.idea, n.position, n.position_unit, n.include_time, n.created_date,
                   b.name AS book_name,
                   COALESCE(c.title, '') AS chapter_title
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            LEFT JOIN chapter c ON c.id = n.chapter_id AND c.is_deleted = 0
            WHERE n.id = ? AND n.is_deleted = 0
            LIMIT 1
        """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [noteId]) else { return nil }

        let imageURLs = try fetchImageURLs(
            db,
            table: "attach_image",
            foreignKey: "note_id",
            imageColumn: "image_url",
            parentID: noteId,
            orderClause: "id ASC"
        )
        let tagNames = try fetchNoteTagNames(db, noteId: noteId)

        return NoteContentDetail(
            noteId: row["id"],
            sourceBookId: row["book_id"],
            bookTitle: row["book_name"] ?? "",
            chapterTitle: row["chapter_title"] ?? "",
            contentHTML: Self.trimTrailingWhitespaceAndNewlines(row["content"] ?? ""),
            ideaHTML: Self.trimTrailingWhitespaceAndNewlines(row["idea"] ?? ""),
            position: row["position"] ?? "",
            positionUnit: row["position_unit"] ?? 0,
            includeTime: (row["include_time"] as Int64? ?? 1) != 0,
            createdDate: row["created_date"] ?? 0,
            imageURLs: imageURLs,
            tagNames: tagNames
        )
    }

    /// 读取单条书评详情，并补齐附图与书籍评分。
    nonisolated func fetchReviewDetail(_ db: Database, reviewId: Int64) throws -> ReviewContentDetail? {
        // SQL 目的：按主键读取单条书评完整详情。
        // 涉及表：review INNER JOIN book。
        // 关键过滤：排除 review/book 的软删除记录。
        // 返回字段：标题、HTML 正文、创建时间、所属书与书籍评分。
        let sql = """
            SELECT rv.id, rv.book_id, rv.title, rv.content, rv.created_date,
                   b.name AS book_name, b.score
            FROM review rv
            JOIN book b ON b.id = rv.book_id AND b.is_deleted = 0
            WHERE rv.id = ? AND rv.is_deleted = 0
            LIMIT 1
        """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [reviewId]) else { return nil }

        let imageURLs = try fetchImageURLs(
            db,
            table: "review_image",
            foreignKey: "review_id",
            imageColumn: "image",
            parentID: reviewId,
            orderClause: "\"order\" ASC, id ASC"
        )

        return ReviewContentDetail(
            reviewId: row["id"],
            sourceBookId: row["book_id"],
            bookTitle: row["book_name"] ?? "",
            title: row["title"] ?? "",
            contentHTML: Self.trimTrailingWhitespaceAndNewlines(row["content"] ?? ""),
            createdDate: row["created_date"] ?? 0,
            bookScore: row["score"] as Int64? ?? 0,
            imageURLs: imageURLs
        )
    }

    /// 读取单条相关内容详情，并补齐分类名与附图。
    nonisolated func fetchRelevantDetail(_ db: Database, contentId: Int64) throws -> RelevantContentDetail? {
        // SQL 目的：按主键读取单条相关内容完整详情。
        // 涉及表：category_content INNER JOIN book LEFT JOIN category。
        // 关键过滤：排除 category_content/book 的软删除记录，并剔除 content_book_id != 0 的相关书籍记录。
        // 返回字段：标题、HTML 正文、链接、分类名、所属书与创建时间。
        let sql = """
            SELECT cc.id, cc.book_id, cc.category_id, cc.title, cc.content, cc.url, cc.created_date,
                   b.name AS book_name,
                   COALESCE(cat.title, '') AS category_title
            FROM category_content cc
            JOIN book b ON b.id = cc.book_id AND b.is_deleted = 0
            LEFT JOIN category cat ON cat.id = cc.category_id AND cat.is_deleted = 0
            WHERE cc.id = ? AND cc.is_deleted = 0 AND cc.content_book_id = 0
            LIMIT 1
        """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [contentId]) else { return nil }

        let imageURLs = try fetchImageURLs(
            db,
            table: "category_image",
            foreignKey: "category_content_id",
            imageColumn: "image",
            parentID: contentId,
            orderClause: "\"order\" ASC, id ASC"
        )

        return RelevantContentDetail(
            contentId: row["id"],
            sourceBookId: row["book_id"],
            categoryId: row["category_id"] ?? 0,
            bookTitle: row["book_name"] ?? "",
            categoryTitle: row["category_title"] ?? "",
            title: row["title"] ?? "",
            contentHTML: Self.trimTrailingWhitespaceAndNewlines(row["content"] ?? ""),
            url: row["url"] ?? "",
            createdDate: row["created_date"] ?? 0,
            imageURLs: imageURLs
        )
    }
}

// MARK: - Delete Transactions

private extension ContentRepository {
    /// 硬删除书摘及其附图、标签关系。
    nonisolated func deleteNote(_ db: Database, noteId: Int64) throws {
        try db.execute(
            // SQL 目的：物理删除指定书摘关联的全部附图记录。
            // 涉及表：attach_image。
            // 关键过滤：按 note_id 精确命中；不追加 is_deleted 条件，确保 Android 遗留软删除子记录也被一并清理。
            sql: "DELETE FROM attach_image WHERE note_id = ?",
            arguments: [noteId]
        )
        try db.execute(
            // SQL 目的：物理删除指定书摘关联的全部标签关系。
            // 涉及表：tag_note。
            // 关键过滤：按 note_id 精确命中；不追加 is_deleted 条件，避免残留 tombstone 关系记录。
            sql: "DELETE FROM tag_note WHERE note_id = ?",
            arguments: [noteId]
        )
        try db.execute(
            // SQL 目的：物理删除指定书摘主记录。
            // 涉及表：note。
            // 关键过滤：按 id 精确命中；不追加 is_deleted 条件，允许清理 Android 端已软删除但仍驻留本地的主记录。
            sql: "DELETE FROM note WHERE id = ?",
            arguments: [noteId]
        )
    }

    /// 硬删除书评及其附图。
    nonisolated func deleteReview(_ db: Database, reviewId: Int64) throws {
        try db.execute(
            // SQL 目的：物理删除指定书评关联的全部附图记录。
            // 涉及表：review_image。
            // 关键过滤：按 review_id 精确命中；不追加 is_deleted 条件，统一清理活跃与 tombstone 子记录。
            sql: "DELETE FROM review_image WHERE review_id = ?",
            arguments: [reviewId]
        )
        try db.execute(
            // SQL 目的：物理删除指定书评主记录。
            // 涉及表：review。
            // 关键过滤：按 id 精确命中；不追加 is_deleted 条件，允许清理 Android 软删除残留记录。
            sql: "DELETE FROM review WHERE id = ?",
            arguments: [reviewId]
        )
    }

    /// 硬删除相关内容及其附图。
    nonisolated func deleteRelevant(_ db: Database, contentId: Int64) throws {
        // SQL 目的：在删除相关关系前读取可能引用的业务占位书 ID。
        // 涉及表：category_content。
        // 关键过滤：按关系主键精确命中；普通内容返回 0，相关书籍返回 content_book_id。
        // 时间字段：不读取时间字段。
        // 返回字段用途：关系删除后判断是否需要清理最后一个无引用占位书。
        let relatedBookID = try Int64.fetchOne(
            db,
            sql: "SELECT content_book_id FROM category_content WHERE id = ? LIMIT 1",
            arguments: [contentId]
        ) ?? 0
        try db.execute(
            // SQL 目的：物理删除指定相关内容关联的全部附图记录。
            // 涉及表：category_image。
            // 关键过滤：按 category_content_id 精确命中；不追加 is_deleted 条件，确保 tombstone 附图同步清理。
            sql: "DELETE FROM category_image WHERE category_content_id = ?",
            arguments: [contentId]
        )
        try db.execute(
            // SQL 目的：物理删除指定相关内容主记录。
            // 涉及表：category_content。
            // 关键过滤：按 id 精确命中；不追加 is_deleted 条件，允许清理 Android 软删除残留主记录。
            sql: "DELETE FROM category_content WHERE id = ?",
            arguments: [contentId]
        )
        if relatedBookID > 0 {
            try db.execute(
                // SQL 目的：物理删除失去最后一个真实引用的业务占位书。
                // 涉及表：book，反查 category_content 与 collection_book。
                // 关键过滤：仅处理 is_deleted=1 占位书；任一物理关系仍存在时保留。
                // 时间字段：不读取时间字段。
                // 副作用：最后引用移除后删除 book 主记录，不影响有效书籍。
                sql: """
                    DELETE FROM book
                    WHERE id = ? AND id != 0 AND is_deleted = 1
                      AND NOT EXISTS (SELECT 1 FROM category_content WHERE content_book_id = book.id)
                      AND NOT EXISTS (SELECT 1 FROM collection_book WHERE book_id = book.id)
                    """,
                arguments: [relatedBookID]
            )
        }
    }
}

// MARK: - Shared Helpers

private extension ContentRepository {
    /// 读取单个主记录的图片 URL 列表，保留 Android 查询顺序语义。
    nonisolated func fetchImageURLs(
        _ db: Database,
        table: String,
        foreignKey: String,
        imageColumn: String,
        parentID: Int64,
        orderClause: String
    ) throws -> [String] {
        // SQL 目的：读取指定主记录关联的有效图片 URL 列表。
        // 涉及表：attach_image / review_image / category_image。
        // 关键过滤：限定外键主记录，并显式保留 is_deleted = 0，避免 viewer 读到 Android 已软删除图片。
        // 排序：调用方按各表 Android 既有顺序传入。
        let sql = """
            SELECT \(imageColumn)
            FROM \(table)
            WHERE \(foreignKey) = ? AND is_deleted = 0
            ORDER BY \(orderClause)
        """
        return try String.fetchAll(db, sql: sql, arguments: [parentID])
    }

    /// 读取单条书摘的有效标签名列表。
    nonisolated func fetchNoteTagNames(_ db: Database, noteId: Int64) throws -> [String] {
        // SQL 目的：读取指定书摘的有效标签名列表。
        // 涉及表：tag_note INNER JOIN tag。
        // 关键过滤：同时要求 tag_note/tag 均为有效记录，并限制 tag.type = 1 保持与书摘标签页一致。
        // 排序：按 tag.tag_order ASC、tag_note.id ASC 对齐 Android。
        let sql = """
            SELECT t.name
            FROM tag_note tn
            JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0
            WHERE tn.note_id = ? AND tn.is_deleted = 0 AND t.type = 1
            ORDER BY t.tag_order ASC, tn.id ASC
        """
        return try String.fetchAll(db, sql: sql, arguments: [noteId])
    }

    /// 读取阶段统一清理尾部空白与换行，避免 viewer 页尾部出现额外空段。
    nonisolated static func trimTrailingWhitespaceAndNewlines(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var endIndex = text.endIndex
        while endIndex > text.startIndex {
            let previousIndex = text.index(before: endIndex)
            let scalar = text[previousIndex]
            guard scalar.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                break
            }
            endIndex = previousIndex
        }
        return String(text[..<endIndex])
    }

    nonisolated static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    nonisolated static func uniquePositiveIDs(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        var result: [Int64] = []
        result.reserveCapacity(ids.count)
        for id in ids where id > 0 && !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }
}
