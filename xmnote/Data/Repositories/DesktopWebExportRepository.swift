/**
 * [INPUT]: 依赖 AppDatabase 与现有 Web Book/Note/Review/Related Repository 的 Android 对齐查询
 * [OUTPUT]: 对外提供全部/明确 ID/书单范围解析与单书完整章节、书摘、书评、关联笔记只读快照
 * [POS]: Data 层统一导出数据边界；原生与 Desktop Web 的导出 Service 均不直接访问 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated struct DesktopWebExportBundle: Sendable {
    let book: DesktopWebBookSnapshot
    let notes: [DesktopWebBookNoteSnapshot]
    let reviews: [DesktopWebBookReviewSnapshot]
    let related: [DesktopWebRelatedNoteSnapshot]
}

/// 组合已经逐接口对齐的 Web Repository，保证导出读取沿用同一软删除与排序语义。
nonisolated struct DesktopWebExportRepository: Sendable {
    private let database: AppDatabase
    private let bookRepository: DesktopWebBookRepository
    private let noteRepository: DesktopWebNoteRepository
    private let reviewRepository: DesktopWebReviewRepository
    private let relatedRepository: DesktopWebRelatedRepository
    private let chapterRepository: DesktopWebChapterRepository

    init(database: AppDatabase, defaults: UserDefaults = .standard) {
        self.database = database
        bookRepository = DesktopWebBookRepository(database: database)
        noteRepository = DesktopWebNoteRepository(database: database)
        reviewRepository = DesktopWebReviewRepository(
            database: database,
            draftStore: DesktopWebReviewDraftStore(defaults: defaults)
        )
        relatedRepository = DesktopWebRelatedRepository(database: database)
        chapterRepository = DesktopWebChapterRepository(database: database)
    }

    /// 返回 Android BookRepository.queryAllBookIdsSuspend 的原始查询顺序，并在调用完成时冻结该顺序。
    func allBookIDs() async throws -> [Int64] {
        try await database.dbPool.read { db in
            // SQL 目的：读取“未指定 bookIds”导出范围。
            // 涉及表：book。
            // 关键过滤：is_deleted=0 且排除 id=0 占位书籍；不按 owner 过滤以对齐 Android Web。
            // 时间字段：无。
            // 返回字段用途：本地/远端导出的单书迭代顺序。
            try Int64.fetchAll(db, sql: "SELECT id FROM book WHERE is_deleted = 0 AND id != 0")
        }
    }

    /// 按 collection_book.order、relation id 读取书单中的有效非占位书籍，并去除历史重复关系。
    func bookIDs(collectionID: Int64) async throws -> [Int64] {
        try await database.dbPool.read { db in
            // SQL 目的：冻结书单范围的实际书籍迭代顺序。
            // 涉及表：collection_book cb INNER JOIN collection c INNER JOIN book b。
            // 关键过滤：书单、关系与书籍均有效，排除 book.id=0 系统占位；按关系 order 与 id 保持书单顺序。
            // 时间字段：无。
            // 返回字段用途：原生与 Desktop Web 导出的一次性范围快照。
            let ids = try Int64.fetchAll(
                db,
                sql: """
                    SELECT cb.book_id
                    FROM collection_book cb
                    INNER JOIN collection c ON c.id = cb.collection_id
                    INNER JOIN book b ON b.id = cb.book_id
                    WHERE cb.collection_id = ?
                      AND cb.is_deleted = 0
                      AND c.is_deleted = 0
                      AND b.is_deleted = 0
                      AND b.id != 0
                    ORDER BY cb.`order` ASC, cb.id ASC
                    """,
                arguments: [collectionID]
            )
            var seen = Set<Int64>()
            return ids.filter { seen.insert($0).inserted }
        }
    }

    /// 读取有效书单名作为 CSV 文件名；不存在时回退通用名称，不改变范围查询失败语义。
    func collectionName(_ collectionID: Int64) async throws -> String {
        try await database.dbPool.read { db in
            // SQL 目的：读取书籍信息导出的 Android 文件名来源。
            // 涉及表：collection。
            // 关键过滤：id 精确匹配且书单有效。
            // 时间字段：无。
            // 返回字段用途：生成 `<书单名>.csv`，空名由文件名分配器回退。
            try String.fetchOne(
                db,
                sql: "SELECT name FROM collection WHERE id = ? AND is_deleted = 0",
                arguments: [collectionID]
            ) ?? "书籍信息"
        }
    }

    /// 解析导出范围；明确 ID 严格保留输入顺序，只去除无效、占位与重复项。
    func resolvedBookIDs(for scope: ExportScope) async throws -> [Int64] {
        switch scope {
        case .allBooks:
            return try await allBookIDs()
        case let .bookIDs(ids):
            var seen = Set<Int64>()
            return ids.filter { $0 != 0 && seen.insert($0).inserted }
        case let .collectionID(id):
            return try await bookIDs(collectionID: id)
        }
    }

    /// 读取单书的书摘、书评和相关内容，分别沿用 Android 当前书内排序设置。
    func bundle(bookID: Int64, includeReview: Bool, includeRelated: Bool) async throws -> DesktopWebExportBundle {
        let book = try await exportBook(id: bookID)
        let noteRule = try await noteRepository.bookNoteSortRule(bookID: bookID)
        let notes = try await noteRepository.bookNotes(
            bookID: bookID,
            page: 1,
            pageSize: 1_000_000,
            filter: .init(
                chapterID: 0,
                tagID: DesktopWebNoteRepository.noTagFilter,
                tagIDs: [],
                tagMode: "or",
                sortBy: noteRule.sortBy,
                sortOrder: noteRule.sortOrder
            )
        ).items
        let reviews: [DesktopWebBookReviewSnapshot]
        if includeReview {
            let rule = try await reviewRepository.bookReviewSortRule(bookID: bookID)
            reviews = try await reviewRepository.bookReviews(
                bookID: bookID,
                page: 1,
                pageSize: 1_000_000,
                sortBy: rule.sortBy,
                sortOrder: rule.sortOrder
            ).items
        } else {
            reviews = []
        }
        let related: [DesktopWebRelatedNoteSnapshot]
        if includeRelated {
            let rule = try await relatedRepository.sortRule(bookID: bookID)
            related = try await relatedRepository.allRelatedNotes(
                bookID: bookID,
                filter: .init(
                    categoryID: 0,
                    keyword: "",
                    sortBy: rule.sortBy,
                    sortOrder: rule.sortOrder
                )
            ).items
        } else {
            related = []
        }
        return .init(book: book, notes: notes, reviews: reviews, related: related)
    }

    /// 一次性读取全部书籍及其完整内容树；返回后生成器和 ViewModel 不再访问数据库。
    func snapshot(scope: ExportScope, selection: ExportContentSelection) async throws -> ExportSnapshot {
        let ids = try await resolvedBookIDs(for: scope)
        var books: [ExportBookSnapshot] = []
        books.reserveCapacity(ids.count)
        for id in ids {
            try Task.checkCancellation()
            async let bundleValue = bundle(
                bookID: id,
                includeReview: selection.includesReviews,
                includeRelated: selection.includesRelatedNotes
            )
            async let chapterTreeValue = chapterRepository.chapters(bookID: id)
            let (bundle, chapterTree) = try await (bundleValue, chapterTreeValue)
            books.append(ExportBookSnapshot(
                book: bundle.book,
                chapters: Self.flattenedChapters(chapterTree),
                notes: selection.includesNotes ? bundle.notes : [],
                reviews: bundle.reviews,
                relatedNotes: bundle.related
            ))
        }
        return ExportSnapshot(books: books)
    }

    /// 只读书名失败时按 Android safeBookName 回退到 ID 文案。
    func safeBookName(_ id: Int64) async -> String {
        (try? await bookRepository.book(id: id).name) ?? "ID:\(id)"
    }

    /// 在 Web 详情投影基础上补齐 Android getExportBook 的全部分组、最新阅读时间和历史读完兜底。
    private func exportBook(id: Int64) async throws -> DesktopWebBookSnapshot {
        let base = try await bookRepository.book(id: id)
        let auxiliary = try await database.dbPool.read { db -> ([DesktopWebNamedSnapshot], Int64) in
            // SQL 目的：读取 Android getExportBook 所需的全部有效分组与最新阅读时间。
            // 涉及表：group_book gb INNER JOIN `group` g，以及 read_time_record r。
            // 关键过滤：关系/分组/阅读记录有效并限定 book_id；分组按创建时间和 relation id，阅读时间按五字段优先级取最大。
            // 时间字段：fuzzy_read_date、weread_read_date、end_time、start_time、created_date 均为 epoch 毫秒，原样比较。
            // 返回字段用途：CSV/Notion 书籍信息字段及最新阅读日期。
            let groups = try Row.fetchAll(
                db,
                sql: """
                    SELECT g.id, g.name
                    FROM group_book gb
                    INNER JOIN `group` g ON g.id = gb.group_id
                    WHERE gb.book_id = ?
                      AND gb.is_deleted = 0
                      AND g.is_deleted = 0
                    ORDER BY gb.created_date ASC, gb.id ASC
                    """,
                arguments: [id]
            ).map { row in
                DesktopWebNamedSnapshot(id: row["id"], name: row["name"])
            }
            let newest = try Int64.fetchOne(
                db,
                sql: """
                    SELECT MAX(
                        CASE
                            WHEN fuzzy_read_date != 0 THEN fuzzy_read_date
                            WHEN weread_read_date != 0 THEN weread_read_date
                            WHEN end_time != 0 THEN end_time
                            WHEN start_time != 0 THEN start_time
                            ELSE created_date
                        END
                    )
                    FROM read_time_record
                    WHERE book_id = ? AND is_deleted = 0
                    """,
                arguments: [id]
            ) ?? 0
            return (groups, newest)
        }
        return DesktopWebBookSnapshot(
            id: base.id,
            name: base.name,
            rawName: base.rawName,
            cover: base.cover,
            author: base.author,
            authorIntro: base.authorIntro,
            translator: base.translator,
            summary: base.summary,
            isbn: base.isbn,
            press: base.press,
            pubDate: base.pubDate,
            doubanId: base.doubanId,
            readStatus: base.readStatus,
            readStatusChangedTime: base.readStatusChangedTime,
            recentReadTime: auxiliary.1 > 0 ? auxiliary.1 : nil,
            readDoneCount: base.readDoneCount == 0 && base.readStatus == 3 ? 1 : base.readDoneCount,
            score: base.score,
            readPosition: base.readPosition,
            totalPosition: base.totalPosition,
            totalPagination: base.totalPagination,
            currentPositionUnit: base.currentPositionUnit,
            positionUnit: base.positionUnit,
            type: base.type,
            sourceId: base.sourceId,
            sourceName: base.sourceName,
            purchaseDate: base.purchaseDate,
            price: base.price,
            isPinned: base.isPinned,
            pinOrder: base.pinOrder,
            order: base.order,
            wordCount: base.wordCount,
            totalReadingTime: base.totalReadingTime,
            createdTime: base.createdTime,
            updatedTime: base.updatedTime,
            lastModifiedTime: base.lastModifiedTime,
            noteCount: base.noteCount,
            reviewCount: base.reviewCount,
            relevantCount: base.relevantCount,
            readDoneTime: base.readDoneTime,
            bookmarkModifiedTime: base.bookmarkModifiedTime,
            groups: auxiliary.0,
            tags: base.tags,
            isDeleted: base.isDeleted
        )
    }

    /// 深度优先展平完整章节树，同时保留每个节点的完整祖先标题路径。
    private static func flattenedChapters(
        _ roots: [DesktopWebChapterFullSnapshot]
    ) -> [DesktopWebChapterSnapshot] {
        var result: [DesktopWebChapterSnapshot] = []
        func visit(_ value: DesktopWebChapterFullSnapshot) {
            result.append(DesktopWebChapterSnapshot(
                id: value.id,
                title: value.title,
                parentTitle: value.pathTitles.dropLast().last,
                parentID: value.parentID,
                level: value.level,
                pathTitles: value.pathTitles,
                isStarred: value.isStarred
            ))
            value.children.forEach(visit)
        }
        roots.forEach(visit)
        return result
    }
}
