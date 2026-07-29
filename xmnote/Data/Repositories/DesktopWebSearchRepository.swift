/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 V44 book、note、review、category_content 及其展示关联表，并复用 Web 专用书籍/书摘/书评投影
 * [OUTPUT]: 对外提供 Android SearchService 的四域异构分页与书籍混合来源语义
 * [POS]: Data 层网页搜索专用仓储；独立复刻 Android Web 路径，不让 XMNoteWeb 接触 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// SearchType 在 App Data 层的无框架输入。
nonisolated enum DesktopWebSearchDomain: String, Sendable {
    case book
    case note
    case review
    case relevant
}

/// 搜索轻量书籍快照；可选元数据控制响应是否出现 translator/pubDate/isDeleted。
nonisolated struct DesktopWebSearchSimpleBookSnapshot: Sendable, Equatable {
    let id: Int64
    let name: String
    let cover: String
    let author: String
    let press: String
    let translator: String?
    let pubDate: String?
    let isDeleted: Bool?
}

/// 书籍搜索项附带 Android 混合来源标识。
nonisolated struct DesktopWebSearchBookSnapshot: Sendable, Equatable {
    let book: DesktopWebBookSnapshot
    let searchSource: String
    let isInBookshelf: Bool
    let fromRelatedContentBook: Bool
}

/// WebNoteDto 在 Data 层的搜索投影。
nonisolated struct DesktopWebSearchNoteSnapshot: Sendable, Equatable {
    let id: Int64
    let content: String
    let idea: String?
    let createdTime: Int64
    let isIncludeTime: Bool
    let book: DesktopWebSearchSimpleBookSnapshot
    let chapter: String?
    let tags: [DesktopWebNoteTagSnapshot]
    let previewImageURLs: [String]
}

/// WebReviewDto 在 Data 层的搜索投影。
nonisolated struct DesktopWebSearchReviewSnapshot: Sendable, Equatable {
    let id: Int64
    let title: String
    let content: String
    let createdTime: Int64
    let book: DesktopWebSearchSimpleBookSnapshot
    let previewImageURLs: [String]
}

/// WebRelevantDto 在 Data 层的搜索投影。
nonisolated struct DesktopWebSearchRelevantSnapshot: Sendable, Equatable {
    let id: Int64
    let title: String
    let content: String
    let url: String?
    let createdTime: Int64
    let book: DesktopWebSearchSimpleBookSnapshot
    let categoryTitle: String?
    let displayKind: String
    let previewImageURLs: [String]
    let contentBook: DesktopWebSearchSimpleBookSnapshot?
}

/// 四类搜索结果的 Data 层异构容器。
nonisolated enum DesktopWebSearchItemSnapshot: Sendable, Equatable {
    case book(DesktopWebSearchBookSnapshot)
    case note(DesktopWebSearchNoteSnapshot)
    case review(DesktopWebSearchReviewSnapshot)
    case relevant(DesktopWebSearchRelevantSnapshot)
}

/// Android PageResult<Any> 在 Data 层的无框架分页快照。
nonisolated struct DesktopWebSearchPageSnapshot: Sendable, Equatable {
    let items: [DesktopWebSearchItemSnapshot]
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
}

/// 复刻 Android SearchService，并复用现有 Web DTO 投影而不调用 App UI 搜索模型。
nonisolated struct DesktopWebSearchRepository: Sendable {
    static let noTag: Int64 = -1
    static let hasIdea: Int64 = -2
    static let hasImage: Int64 = -3
    static let hasAnyTag: Int64 = -4

    let database: AppDatabase
    let bookRepository: DesktopWebBookRepository
    let noteRepository: DesktopWebNoteRepository
    let reviewRepository: DesktopWebReviewRepository

    /// 固定同一数据库及 Web 专用投影；所有方法只读，任务取消不会产生持久化副作用。
    init(
        database: AppDatabase,
        bookRepository: DesktopWebBookRepository,
        noteRepository: DesktopWebNoteRepository,
        reviewRepository: DesktopWebReviewRepository
    ) {
        self.database = database
        self.bookRepository = bookRepository
        self.noteRepository = noteRepository
        self.reviewRepository = reviewRepository
    }

    /// 按 Android SearchType 分派查询；四域保持各自 SQL、过滤和投影差异。
    func search(
        domain: DesktopWebSearchDomain,
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async throws -> DesktopWebSearchPageSnapshot {
        switch domain {
        case .book:
            try await searchBooks(keyword: keyword, page: page, pageSize: pageSize, tagID: tagID)
        case .note:
            try await searchNotes(
                keyword: keyword,
                page: page,
                pageSize: pageSize,
                bookID: bookID,
                tagID: tagID
            )
        case .review:
            try await searchReviews(keyword: keyword, page: page, pageSize: pageSize, bookID: bookID)
        case .relevant:
            try await searchRelevant(keyword: keyword, page: page, pageSize: pageSize, bookID: bookID)
        }
    }
}

nonisolated extension DesktopWebSearchRepository {
    func searchBooks(
        keyword: String,
        page: Int,
        pageSize: Int,
        tagID: Int64
    ) async throws -> DesktopWebSearchPageSnapshot {
        // NOTE(ANDROID-WEB-056): Android 为混合去重先投影所有匹配书籍，再做请求分页，数据量大时成本无上限。
        let bookshelfPage = try await bookRepository.books(
            page: 1,
            pageSize: Int(Int32.max),
            filter: DesktopWebBookFilterSnapshot(
                keyword: keyword,
                status: 0,
                groupID: 0,
                tagIDs: tagID > 0 ? [tagID] : [],
                tagMode: "or",
                sourceIDs: []
            ),
            sortBy: "custom",
            sortOrder: "desc"
        )
        let bookshelf = bookshelfPage.items.map {
            DesktopWebSearchBookSnapshot(
                book: $0,
                searchSource: "bookshelf",
                isInBookshelf: !$0.isDeleted,
                fromRelatedContentBook: false
            )
        }
        let bookshelfIDs = Set(bookshelf.map { $0.book.id })

        let relatedRecords = try await relatedContentBookRecords(keyword: keyword, tagID: tagID)
        let relatedProjected = try await bookRepository.projection.projectBookSnapshots(relatedRecords)
        let related = relatedProjected.compactMap { snapshot -> DesktopWebSearchBookSnapshot? in
            guard !bookshelfIDs.contains(snapshot.id) else { return nil }
            return DesktopWebSearchBookSnapshot(
                book: snapshot,
                searchSource: "related_content_book",
                isInBookshelf: !snapshot.isDeleted,
                fromRelatedContentBook: true
            )
        }
        let merged = bookshelf + related
        let offset = try Self.arrayOffset(page: page, pageSize: pageSize)
        let pageItems: [DesktopWebSearchBookSnapshot]
        if offset >= merged.count {
            pageItems = []
        } else {
            pageItems = Array(merged[offset..<min(merged.count, offset + min(pageSize, merged.count - offset))])
        }
        return DesktopWebSearchPageSnapshot(
            items: pageItems.map(DesktopWebSearchItemSnapshot.book),
            page: page,
            pageSize: pageSize,
            total: merged.count,
            totalPages: Self.totalPages(total: merged.count, pageSize: pageSize)
        )
    }

    func relatedContentBookRecords(keyword: String, tagID: Int64) async throws -> [BookRecord] {
        guard !Self.isKotlinBlank(keyword) else { return [] }
        let orderedIDs = try await database.dbPool.read { db -> [Int64] in
            // SQL 目的：复刻 WebRelevantRepository.searchContentBooks 的相关内容书匹配与顺序。
            // 涉及表：category_content、来源 book、内容 book。
            // 关键过滤：内容和来源书有效、content_book_id>0；正 tagId 同时约束内容书有效标签；匹配名称/作者/译者/出版社。
            // 时间字段：按 category_content.updated_date DESC、id DESC 排序。
            // 返回字段用途：按首次出现顺序去重 content_book_id，随后投影完整 WebBookDto。
            let records = try CategoryContentRecord.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM category_content c
                    INNER JOIN book source_book ON c.book_id = source_book.id
                    INNER JOIN book content_book ON c.content_book_id = content_book.id
                    WHERE c.is_deleted = 0
                      AND source_book.is_deleted = 0
                      AND c.content_book_id > 0
                      AND (
                        ? <= 0 OR EXISTS (
                          SELECT 1 FROM tag_book tb
                          INNER JOIN tag t ON t.id = tb.tag_id
                          WHERE tb.book_id = content_book.id
                            AND tb.tag_id = ?
                            AND tb.is_deleted = 0
                            AND t.is_deleted = 0
                        )
                      )
                      AND (
                        content_book.name LIKE '%' || ? || '%'
                        OR content_book.author LIKE '%' || ? || '%'
                        OR content_book.translator LIKE '%' || ? || '%'
                        OR content_book.press LIKE '%' || ? || '%'
                      )
                    ORDER BY c.updated_date DESC, c.id DESC
                    """,
                arguments: [tagID, tagID, keyword, keyword, keyword, keyword]
            )
            var seen: Set<Int64> = []
            return records.compactMap { record in
                guard record.contentBookId > 0, seen.insert(record.contentBookId).inserted else {
                    return nil
                }
                return record.contentBookId
            }
        }
        guard !orderedIDs.isEmpty else { return [] }
        let recordsByID = try await database.dbPool.read { db -> [Int64: BookRecord] in
            var result: [Int64: BookRecord] = [:]
            for ids in orderedIDs.chunkedForDesktopWebSearch(maxCount: 500) {
                let records = try BookRecord.filter(ids.contains(Column("id"))).fetchAll(db)
                for record in records {
                    if let id = record.id { result[id] = record }
                }
            }
            return result
        }
        return orderedIDs.compactMap { recordsByID[$0] }
    }
}

nonisolated extension DesktopWebSearchRepository {
    func searchNotes(
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async throws -> DesktopWebSearchPageSnapshot {
        var conditions = ["n.is_deleted = 0", "b.is_deleted = 0"]
        var arguments: [DatabaseValue] = []
        if !Self.isKotlinBlank(keyword) {
            conditions.append("(n.content LIKE '%' || ? || '%' OR n.idea LIKE '%' || ? || '%')")
            arguments.append(contentsOf: [keyword.databaseValue, keyword.databaseValue])
        }
        if bookID != 0 {
            conditions.append("n.book_id = ?")
            arguments.append(bookID.databaseValue)
        }
        if tagID != 0 {
            switch tagID {
            case Self.noTag:
                conditions.append(
                    """
                    NOT EXISTS (
                      SELECT 1 FROM tag_note tn
                      INNER JOIN tag t ON t.id = tn.tag_id
                      WHERE tn.note_id = n.id AND tn.is_deleted = 0 AND t.is_deleted = 0
                    )
                    """
                )
            case Self.hasAnyTag:
                conditions.append(
                    """
                    EXISTS (
                      SELECT 1 FROM tag_note tn
                      INNER JOIN tag t ON t.id = tn.tag_id
                      WHERE tn.note_id = n.id AND tn.is_deleted = 0 AND t.is_deleted = 0
                    )
                    """
                )
            case Self.hasIdea:
                conditions.append("n.idea IS NOT NULL AND trim(n.idea) != ''")
            case Self.hasImage:
                conditions.append(
                    "EXISTS (SELECT 1 FROM attach_image ai WHERE ai.note_id = n.id AND ai.is_deleted = 0)"
                )
            default:
                conditions.append(
                    """
                    EXISTS (
                      SELECT 1 FROM tag_note tn
                      INNER JOIN tag t ON t.id = tn.tag_id
                      WHERE tn.note_id = n.id AND tn.is_deleted = 0
                        AND t.is_deleted = 0 AND tn.tag_id = ?
                    )
                    """
                )
                arguments.append(tagID.databaseValue)
            }
        }
        let offset = Self.sqlOffset(page: page, pageSize: pageSize)
        let whereClause = conditions.joined(separator: " AND ")
        let queryArguments = arguments
        let result = try await database.dbPool.read { db -> ([NoteRecord], Int) in
            // NOTE(ANDROID-WEB-008): 搜索只过滤来源书 tombstone，不按 book.user_id 隔离。
            // SQL 目的：复刻 WebNoteRepository.searchNotes 的搜索页。
            // 涉及表：note INNER JOIN book，按筛选使用 tag_note/attach_image EXISTS。
            // 关键过滤：书摘和书有效、可选 LIKE/bookId/tagId；标签关系与主记录均须有效。
            // 时间字段：created_date DESC；同值没有次级排序。
            // 返回字段用途：WebNoteDto 结果与未分页总数。
            let items = try NoteRecord.fetchAll(
                db,
                sql: """
                    SELECT n.* FROM note n
                    INNER JOIN book b ON n.book_id = b.id
                    WHERE \(whereClause)
                    ORDER BY n.created_date DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments(queryArguments + [pageSize.databaseValue, offset.databaseValue])
            )
            let total = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM note n
                    INNER JOIN book b ON n.book_id = b.id
                    WHERE \(whereClause)
                    """,
                arguments: StatementArguments(queryArguments)
            ) ?? 0
            return (items, total)
        }
        let noteIDs = result.0.compactMap(\.id)
        let chapterIDs = Self.distinct(result.0.map(\.chapterId)).filter { $0 != 0 }
        let context = try await database.dbPool.read { db -> ([ChapterRecord], [Int64: BookRecord]) in
            // SQL 目的：复刻 WebNoteDao.batchQueryChapters；故意包含已软删除章节。
            // 涉及表：chapter。
            // 关键过滤：仅 id IN，不过滤 is_deleted。
            // 时间字段：无。
            // 返回字段用途：搜索项 chapter 标题。
            let chapters = chapterIDs.isEmpty
                ? []
                : try ChapterRecord.filter(chapterIDs.contains(Column("id"))).fetchAll(db)
            let bookIDs = Self.distinct(result.0.map(\.bookId))
            let books = try BookRecord
                .filter(bookIDs.contains(Column("id")) && Column("is_deleted") == 0)
                .fetchAll(db)
            return (
                chapters,
                Dictionary(uniqueKeysWithValues: books.compactMap { book in book.id.map { ($0, book) } })
            )
        }
        let projected = try await noteRepository.projectBookNotes(result.0, chapterRecords: context.0)
        let projectedByID = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
        let items = result.0.compactMap { record -> DesktopWebSearchItemSnapshot? in
            guard let id = record.id,
                  noteIDs.contains(id),
                  let note = projectedByID[id],
                  let book = context.1[record.bookId] else { return nil }
            return .note(
                DesktopWebSearchNoteSnapshot(
                    id: id,
                    content: note.content,
                    idea: note.idea,
                    createdTime: note.createdTime,
                    isIncludeTime: note.isIncludeTime,
                    book: Self.simpleBook(book, includesMetadata: false),
                    chapter: note.chapter?.title,
                    tags: note.tags,
                    previewImageURLs: note.images.map(\.url)
                )
            )
        }
        return Self.page(items: items, page: page, pageSize: pageSize, total: result.1)
    }

    func searchReviews(
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64
    ) async throws -> DesktopWebSearchPageSnapshot {
        var conditions = ["r.is_deleted = 0", "b.is_deleted = 0"]
        var arguments: [DatabaseValue] = []
        if !Self.isKotlinBlank(keyword) {
            conditions.append("(r.title LIKE '%' || ? || '%' OR r.content LIKE '%' || ? || '%')")
            arguments.append(contentsOf: [keyword.databaseValue, keyword.databaseValue])
        }
        if bookID != 0 {
            conditions.append("r.book_id = ?")
            arguments.append(bookID.databaseValue)
        }
        let offset = Self.sqlOffset(page: page, pageSize: pageSize)
        let whereClause = conditions.joined(separator: " AND ")
        let queryArguments = arguments
        let result = try await database.dbPool.read { db -> ([ReviewRecord], Int) in
            // NOTE(ANDROID-WEB-008): 搜索只过滤来源书 tombstone，不按 book.user_id 隔离。
            // SQL 目的：复刻 WebReviewRepository.searchReviews。
            // 涉及表：review INNER JOIN book。
            // 关键过滤：书评/书有效、可选 title/content LIKE 与 bookId。
            // 时间字段：created_date DESC，并以 review.id ASC 次序稳定同值结果。
            // 返回字段用途：WebReviewDto 搜索页与总数。
            let items = try ReviewRecord.fetchAll(
                db,
                sql: """
                    SELECT r.* FROM review r
                    INNER JOIN book b ON r.book_id = b.id
                    WHERE \(whereClause)
                    ORDER BY r.created_date DESC, r.id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments(queryArguments + [pageSize.databaseValue, offset.databaseValue])
            )
            let total = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM review r
                    INNER JOIN book b ON r.book_id = b.id
                    WHERE \(whereClause)
                    """,
                arguments: StatementArguments(queryArguments)
            ) ?? 0
            return (items, total)
        }
        let projected = try await reviewRepository.globalSnapshots(result.0)
        let items = projected.map { value in
            DesktopWebSearchItemSnapshot.review(
                DesktopWebSearchReviewSnapshot(
                    id: value.id,
                    title: value.title,
                    content: value.content,
                    createdTime: value.createdTime,
                    book: DesktopWebSearchSimpleBookSnapshot(
                        id: value.book.id,
                        name: value.book.name,
                        cover: value.book.cover,
                        author: value.book.author,
                        press: value.book.press,
                        translator: nil,
                        pubDate: nil,
                        isDeleted: nil
                    ),
                    previewImageURLs: value.images.map(\.url)
                )
            )
        }
        return Self.page(items: items, page: page, pageSize: pageSize, total: result.1)
    }

    func searchRelevant(
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64
    ) async throws -> DesktopWebSearchPageSnapshot {
        var conditions = ["c.is_deleted = 0", "b.is_deleted = 0"]
        var arguments: [DatabaseValue] = []
        if !Self.isKotlinBlank(keyword) {
            conditions.append("(c.title LIKE '%' || ? || '%' OR c.content LIKE '%' || ? || '%')")
            arguments.append(contentsOf: [keyword.databaseValue, keyword.databaseValue])
        }
        if bookID != 0 {
            conditions.append("c.book_id = ?")
            arguments.append(bookID.databaseValue)
        }
        let offset = Self.sqlOffset(page: page, pageSize: pageSize)
        let whereClause = conditions.joined(separator: " AND ")
        let queryArguments = arguments
        let result = try await database.dbPool.read { db -> ([CategoryContentRecord], Int) in
            // NOTE(ANDROID-WEB-008): 搜索只过滤来源书 tombstone，不按 book.user_id 隔离。
            // SQL 目的：复刻 WebRelevantRepository.searchRelevant。
            // 涉及表：category_content INNER JOIN 来源 book。
            // 关键过滤：内容/来源书有效、可选 title/content LIKE 与 bookId；不连接 category 或内容 book。
            // 时间字段：created_date DESC；同值没有次级排序。
            // 返回字段用途：WebRelevantDto 搜索页与总数。
            let items = try CategoryContentRecord.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM category_content c
                    INNER JOIN book b ON c.book_id = b.id
                    WHERE \(whereClause)
                    ORDER BY c.created_date DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments(queryArguments + [pageSize.databaseValue, offset.databaseValue])
            )
            let total = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM category_content c
                    INNER JOIN book b ON c.book_id = b.id
                    WHERE \(whereClause)
                    """,
                arguments: StatementArguments(queryArguments)
            ) ?? 0
            return (items, total)
        }
        let itemIDs = result.0.compactMap(\.id)
        let sourceBookIDs = Self.distinct(result.0.map(\.bookId))
        let contentBookIDs = Self.distinct(result.0.map(\.contentBookId)).filter { $0 > 0 }
        let categoryIDs = Self.distinct(result.0.map(\.categoryId))
        let context = try await database.dbPool.read { db -> (
            sourceBooks: [Int64: BookRecord],
            contentBooks: [Int64: BookRecord],
            categories: [Int64: CategoryRecord],
            images: [Int64: [String]]
        ) in
            let sources = try BookRecord
                .filter(sourceBookIDs.contains(Column("id")) && Column("is_deleted") == 0)
                .fetchAll(db)
            let contentBooks = contentBookIDs.isEmpty
                ? []
                : try BookRecord.filter(contentBookIDs.contains(Column("id"))).fetchAll(db)
            let categories = categoryIDs.isEmpty
                ? []
                : try CategoryRecord
                    .filter(categoryIDs.contains(Column("id")) && Column("is_deleted") == 0)
                    .fetchAll(db)
            let images = itemIDs.isEmpty
                ? []
                : try CategoryImageRecord
                    .filter(itemIDs.contains(Column("category_content_id")) && Column("is_deleted") == 0)
                    .order(Column("order").asc)
                    .fetchAll(db)
            return (
                Dictionary(uniqueKeysWithValues: sources.compactMap { book in book.id.map { ($0, book) } }),
                Dictionary(uniqueKeysWithValues: contentBooks.compactMap { book in book.id.map { ($0, book) } }),
                Dictionary(uniqueKeysWithValues: categories.compactMap { category in
                    category.id.map { ($0, category) }
                }),
                Dictionary(grouping: images, by: \.categoryContentId).mapValues { $0.map(\.image) }
            )
        }
        let items = result.0.compactMap { record -> DesktopWebSearchItemSnapshot? in
            guard let id = record.id, let sourceBook = context.sourceBooks[record.bookId] else { return nil }
            let title = record.title ?? ""
            let content = record.content ?? ""
            let url = record.url
            let isBookKind = record.contentBookId > 0
                && Self.isKotlinBlank(title)
                && Self.isKotlinBlank(content)
                && Self.isKotlinBlank(url ?? "")
            return .relevant(
                DesktopWebSearchRelevantSnapshot(
                    id: id,
                    title: title,
                    content: content,
                    url: url,
                    createdTime: record.createdDate,
                    book: Self.simpleBook(sourceBook, includesMetadata: false),
                    categoryTitle: context.categories[record.categoryId]?.title,
                    displayKind: isBookKind ? "book" : "data",
                    previewImageURLs: context.images[id] ?? [],
                    contentBook: context.contentBooks[record.contentBookId].map {
                        Self.simpleBook($0, includesMetadata: true)
                    }
                )
            )
        }
        return Self.page(items: items, page: page, pageSize: pageSize, total: result.1)
    }
}

private nonisolated extension DesktopWebSearchRepository {
    static func page(
        items: [DesktopWebSearchItemSnapshot],
        page: Int,
        pageSize: Int,
        total: Int
    ) -> DesktopWebSearchPageSnapshot {
        DesktopWebSearchPageSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: total,
            totalPages: totalPages(total: total, pageSize: pageSize)
        )
    }

    static func simpleBook(
        _ book: BookRecord,
        includesMetadata: Bool
    ) -> DesktopWebSearchSimpleBookSnapshot {
        DesktopWebSearchSimpleBookSnapshot(
            id: book.id ?? 0,
            name: book.name,
            cover: book.cover,
            author: book.author,
            press: book.press,
            translator: includesMetadata ? book.translator : nil,
            pubDate: includesMetadata ? book.pubDate : nil,
            isDeleted: includesMetadata ? book.isDeleted == 1 : nil
        )
    }

    static func totalPages(total: Int, pageSize: Int) -> Int {
        total == 0 ? 0 : Int(ceil(Double(total) / Double(pageSize)))
    }

    static func sqlOffset(page: Int, pageSize: Int) -> Int {
        let normalizedPage = max(page, 1)
        let normalizedPageSize = max(pageSize, 1)
        let result = (normalizedPage - 1).multipliedReportingOverflow(by: normalizedPageSize)
        return result.overflow ? Int.max : result.partialValue
    }

    static func arrayOffset(page: Int, pageSize: Int) throws -> Int {
        sqlOffset(page: page, pageSize: pageSize)
    }

    static func distinct(_ values: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func isKotlinBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value <= 0x20 || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}

private nonisolated extension Array {
    func chunkedForDesktopWebSearch(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maxCount).map { start in
            Array(self[start..<Swift.min(count, start + maxCount)])
        }
    }
}
