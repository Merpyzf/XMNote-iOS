import Foundation
import GRDB
import SwiftSoup

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 UserDefaults 保存最近搜索词，依赖 GlobalSearchModels 承载四类本地搜索结果，依赖 SwiftSoup 执行 HTML 纯文本归一化
 * [OUTPUT]: 对外提供 GlobalSearchRepository（GlobalSearchRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层全局搜索仓储实现，对齐 Android 全局搜索的书籍、书摘、相关与书评检索能力
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 全局搜索仓储实现，负责聚合 Android 对齐的四类本地检索结果。
struct GlobalSearchRepository: GlobalSearchRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let userDefaults: UserDefaults

    private enum Keys {
        static let recentQueries = "global_search_recent_queries"
    }

    /// 注入数据库管理器，供全局搜索读取当前本地库快照。
    init(databaseManager: DatabaseManager, userDefaults: UserDefaults = .standard) {
        self.databaseManager = databaseManager
        self.userDefaults = userDefaults
    }

    /// 执行一次只读全局搜索；方法运行在调用方任务中，底层 GRDB read 闭包负责数据库线程切换。
    func search(keyword: String) async throws -> GlobalSearchSnapshot {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKeyword.isEmpty else {
            return .empty
        }

        return try await databaseManager.database.dbPool.read { db in
            let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
            guard ownerID > 0 else {
                return GlobalSearchSnapshot(
                    keyword: normalizedKeyword,
                    books: [],
                    notes: [],
                    relevants: [],
                    reviews: []
                )
            }

            return GlobalSearchSnapshot(
                keyword: normalizedKeyword,
                books: try searchBooks(db, keyword: normalizedKeyword, ownerID: ownerID),
                notes: try searchNotes(db, keyword: normalizedKeyword, ownerID: ownerID),
                relevants: try searchRelevantItems(db, keyword: normalizedKeyword, ownerID: ownerID),
                reviews: try searchReviews(db, keyword: normalizedKeyword, ownerID: ownerID)
            )
        }
    }

    /// 读取最近全局搜索词，默认按最近使用顺序返回。
    func fetchRecentQueries() -> [String] {
        userDefaults.stringArray(forKey: Keys.recentQueries) ?? []
    }

    /// 保存最近全局搜索词，最多保留 8 条并去重。
    func saveRecentQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var queries = fetchRecentQueries().filter {
            $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }
        queries.insert(trimmed, at: 0)
        userDefaults.set(Array(queries.prefix(8)), forKey: Keys.recentQueries)
    }
}

// MARK: - Category Queries

private extension GlobalSearchRepository {
    /// 查询本地书籍结果，字段范围在 Android 书名/作者/出版社/ISBN 基础上补齐 iOS 阅读资产字段。
    nonisolated func searchBooks(_ db: Database, keyword: String, ownerID: Int64) throws -> [GlobalSearchResult] {
        let likeKeyword = Self.likeKeyword(keyword)
        // SQL 目的：按关键词搜索本地有效书籍，承接 Android 全局搜索中的 BOOK 分类，并补齐阅读状态、来源、进度、最近阅读和书籍标签。
        // 涉及表：book b LEFT JOIN read_status/source；tag_book/tag 子查询聚合书籍标签；read_time_record 子查询聚合最近阅读时间。
        // 关键过滤：限定当前 owner、排除 Android 占位书 id=0、排除软删除记录；匹配 b.name/translator/author/press/isbn 以及书籍标签 t.name。
        // 时间字段：book.created_date/updated_date/read_status_changed_date、read_time_record start/end/fuzzy/weread/created_date 均为 Android 毫秒值；latest_read_date 只用于“最近阅读”辅助文案。
        // 返回字段用途：构建书籍搜索结果行、字段级筛选依据与书籍详情导航目标。
        let sql = """
            SELECT b.id, b.name, b.cover, b.author, b.translator, b.press, b.isbn,
                   b.created_date, b.updated_date, b.read_status_changed_date,
                   b.read_position, b.current_position_unit, b.total_position, b.total_pagination,
                   COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(s.name, '') AS source_name,
                   (
                       SELECT GROUP_CONCAT(tag_name, char(31))
                       FROM (
                           SELECT t.name AS tag_name
                           FROM tag_book tb
                           JOIN tag t ON t.id = tb.tag_id
                                     AND t.is_deleted = 0
                                     AND t.type = 2
                           WHERE tb.book_id = b.id
                             AND tb.is_deleted = 0
                           ORDER BY t.tag_order ASC, t.id ASC
                       )
                   ) AS tag_names,
                   (
                       SELECT MAX(
                           CASE
                               WHEN r.weread_read_date > 0 THEN r.weread_read_date
                               WHEN r.fuzzy_read_date > 0 THEN r.fuzzy_read_date
                               WHEN r.end_time > 0 THEN r.end_time
                               WHEN r.start_time > 0 THEN r.start_time
                               ELSE r.created_date
                           END
                       )
                       FROM read_time_record r
                       WHERE r.book_id = b.id
                         AND r.is_deleted = 0
                   ) AS latest_read_date
            FROM book b
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            WHERE b.user_id = ?
              AND b.is_deleted = 0
              AND b.id != 0
              AND (
                  b.name LIKE ? COLLATE NOCASE
                  OR b.translator LIKE ? COLLATE NOCASE
                  OR b.author LIKE ? COLLATE NOCASE
                  OR b.press LIKE ? COLLATE NOCASE
                  OR b.isbn LIKE ? COLLATE NOCASE
                  OR EXISTS (
                      SELECT 1
                      FROM tag_book tb
                      JOIN tag t ON t.id = tb.tag_id
                                AND t.is_deleted = 0
                                AND t.type = 2
                      WHERE tb.book_id = b.id
                        AND tb.is_deleted = 0
                        AND t.name LIKE ? COLLATE NOCASE
                  )
              )
            ORDER BY b.id DESC
        """
        return try Row.fetchAll(
            db,
            sql: sql,
            arguments: [ownerID, likeKeyword, likeKeyword, likeKeyword, likeKeyword, likeKeyword, likeKeyword]
        ).map { row in
            let bookID = row["id"] as Int64? ?? 0
            let title = Self.displayText(row["name"] as String?, fallback: "未命名书籍")
            let author = row["author"] as String? ?? ""
            let press = row["press"] as String? ?? ""
            let translator = row["translator"] as String? ?? ""
            let isbn = row["isbn"] as String? ?? ""
            let tagNames = Self.splitList(row["tag_names"] as String?)
            let subtitle = Self.joinedMetadata([author, press, translator, isbn])
            let coverURL = Self.nilIfBlank(row["cover"] as String?)
            let createdDate = row["created_date"] as Int64? ?? 0
            let progress = BookshelfBookPresentationFormatter.readingProgress(
                readPosition: row["read_position"] as Double? ?? 0,
                currentPositionUnit: row["current_position_unit"] as Int64? ?? 2,
                totalPosition: row["total_position"] as Int64? ?? 0,
                totalPagination: row["total_pagination"] as Int64? ?? 0
            )
            let bookDisplay = GlobalSearchBookDisplay(
                title: title,
                coverURL: coverURL,
                author: author,
                translator: translator,
                press: press,
                isbn: isbn,
                dateText: Self.formatDate(createdDate),
                readStatusName: row["read_status_name"] as String? ?? "",
                sourceName: row["source_name"] as String? ?? "",
                progressText: BookshelfBookPresentationFormatter.readingProgressText(from: progress),
                recentReadText: Self.recentReadText(row["latest_read_date"] as Int64? ?? 0),
                tagNames: tagNames
            )
            return GlobalSearchResult(
                id: "book-\(bookID)",
                category: .book,
                target: .bookDetail(bookId: bookID),
                display: .book(bookDisplay),
                title: title,
                subtitle: subtitle,
                snippet: "",
                coverURL: coverURL,
                timestamp: createdDate,
                matchedFields: Self.matchedFields(
                    [
                        ("书名", title),
                        ("作者", author),
                        ("译者", translator),
                        ("出版社", press),
                        ("ISBN", isbn),
                        ("标签", Self.joinedMetadata(tagNames))
                    ],
                    keyword: keyword
                )
            )
        }
    }

    /// 查询书摘结果，先用 SQL 命中正文、想法、书名与标签，再按去 HTML 纯文本二次过滤。
    nonisolated func searchNotes(_ db: Database, keyword: String, ownerID: Int64) throws -> [GlobalSearchResult] {
        let likeKeyword = Self.likeKeyword(keyword)
        // SQL 目的：按关键词搜索有效书摘正文、想法、所属书名与标签，承接 Android 全局搜索中的 NOTE 分类。
        // 涉及表：note INNER JOIN book，并通过 attach_image、tag_note、tag 子查询补齐卡片附图和标签。
        // 关键过滤：限定当前 owner、排除占位/软删除书籍、排除软删除书摘；匹配 note.content/note.idea、book.name 或有效笔记标签 t.name。
        // 时间字段：读取 note.created_date 仅用于 UI 辅助排序/展示；时间戳为 Android 毫秒值。
        // 返回字段用途：构建书摘搜索结果行、字段级筛选依据与内容查看器导航目标。
        let sql = """
            SELECT n.id, n.book_id, n.content, n.idea, n.position, n.position_unit, n.include_time, n.created_date,
                   b.name AS book_name, b.cover AS book_cover,
                   (
                       SELECT GROUP_CONCAT(image_url, char(31))
                       FROM (
                           SELECT ai.image_url AS image_url
                           FROM attach_image ai
                           WHERE ai.note_id = n.id
                             AND ai.is_deleted = 0
                           ORDER BY ai.id ASC
                       )
                   ) AS image_urls,
                   (
                       SELECT GROUP_CONCAT(tag_name, char(31))
                       FROM (
                           SELECT t.name AS tag_name
                           FROM tag_note tn
                           JOIN tag t ON t.id = tn.tag_id
                                     AND t.is_deleted = 0
                                     AND t.type = 1
                           WHERE tn.note_id = n.id
                             AND tn.is_deleted = 0
                           ORDER BY t.tag_order ASC, tn.id ASC
                       )
                   ) AS tag_names
            FROM note n
            JOIN book b ON b.id = n.book_id
                       AND b.user_id = ?
                       AND b.id != 0
                       AND b.is_deleted = 0
            WHERE n.is_deleted = 0
              AND (
                  n.content LIKE ? COLLATE NOCASE
                  OR n.idea LIKE ? COLLATE NOCASE
                  OR b.name LIKE ? COLLATE NOCASE
                  OR EXISTS (
                      SELECT 1
                      FROM tag_note tn
                      JOIN tag t ON t.id = tn.tag_id
                                AND t.is_deleted = 0
                                AND t.type = 1
                      WHERE tn.note_id = n.id
                        AND tn.is_deleted = 0
                        AND t.name LIKE ? COLLATE NOCASE
                  )
              )
            ORDER BY n.id DESC
        """
        return try Row.fetchAll(
            db,
            sql: sql,
            arguments: [ownerID, likeKeyword, likeKeyword, likeKeyword, likeKeyword]
        ).compactMap { row in
            let contentPlainText = Self.plainText(row["content"] as String? ?? "")
            let ideaPlainText = Self.plainText(row["idea"] as String? ?? "")
            let tagNames = Self.splitList(row["tag_names"] as String?)
            let bookTitle = Self.displayText(row["book_name"] as String?, fallback: "未知书籍")
            guard Self.contains(contentPlainText, keyword: keyword)
                    || Self.contains(ideaPlainText, keyword: keyword)
                    || Self.contains(bookTitle, keyword: keyword)
                    || Self.contains(Self.joinedMetadata(tagNames), keyword: keyword) else {
                return nil
            }

            let noteID = row["id"] as Int64? ?? 0
            let bookID = row["book_id"] as Int64? ?? 0
            let snippetSource = Self.preferredSnippetSource(
                primary: contentPlainText,
                secondary: ideaPlainText,
                keyword: keyword
            )
            let createdDate = row["created_date"] as Int64? ?? 0
            let noteDisplay = GlobalSearchNoteDisplay(
                content: Self.snippet(from: contentPlainText, keyword: keyword),
                idea: Self.snippet(from: ideaPlainText, keyword: keyword),
                imageURLs: Self.splitList(row["image_urls"] as String?),
                tagNames: tagNames,
                bookTitle: bookTitle,
                dateText: Self.formatDate(createdDate)
            )
            return GlobalSearchResult(
                id: "note-\(noteID)",
                category: .note,
                target: .noteViewer(noteId: noteID, bookId: bookID),
                display: .note(noteDisplay),
                title: bookTitle,
                subtitle: Self.noteFooterText(
                    position: row["position"] as String? ?? "",
                    positionUnit: row["position_unit"] as Int64? ?? 0,
                    includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                    createdDate: createdDate
                ),
                snippet: Self.snippet(from: snippetSource, keyword: keyword),
                coverURL: Self.nilIfBlank(row["book_cover"] as String?),
                timestamp: createdDate,
                matchedFields: Self.matchedFields(
                    [
                        ("正文", contentPlainText),
                        ("想法", ideaPlainText),
                        ("书名", bookTitle),
                        ("标签", Self.joinedMetadata(tagNames))
                    ],
                    keyword: keyword
                )
            )
        }
    }

    /// 查询相关内容与相关书籍结果，并按 category_content.id 去重。
    nonisolated func searchRelevantItems(_ db: Database, keyword: String, ownerID: Int64) throws -> [GlobalSearchResult] {
        let relatedBookResults = try searchRelevantBooks(db, keyword: keyword, ownerID: ownerID)
        let textResults = try searchRelevantText(db, keyword: keyword, ownerID: ownerID)
        return Self.uniqueResults(relatedBookResults + textResults)
    }

    /// 查询相关文本内容，保留 Android 对 title/content 的二次纯文本过滤，并补齐书名与分类命中。
    nonisolated func searchRelevantText(_ db: Database, keyword: String, ownerID: Int64) throws -> [GlobalSearchResult] {
        let likeKeyword = Self.likeKeyword(keyword)
        // SQL 目的：按关键词搜索相关内容标题、正文、所属书名与分类，承接 Android 全局搜索中的 RELEVANT 文本内容。
        // 涉及表：category_content INNER JOIN book LEFT JOIN category，并通过 category_image 子查询补齐卡片附图。
        // 关键过滤：限定来源书属于当前 owner 且有效、排除 category_content 软删除；仅保留 content_book_id=0 的普通相关内容，匹配 title/content、book.name 或 category.title。
        // 时间字段：读取 category_content.created_date 作为搜索结果辅助排序/展示，单位为 Android 毫秒值。
        // 返回字段用途：构建相关内容结果行、字段级筛选依据与相关详情导航目标。
        let sql = """
            SELECT cc.id, cc.book_id, cc.category_id, cc.title, cc.content, cc.content_book_id, cc.created_date,
                   b.name AS book_name, b.cover AS book_cover,
                   COALESCE(cat.title, '') AS category_title,
                   (
                       SELECT GROUP_CONCAT(image, char(31))
                       FROM (
                           SELECT ci.image AS image
                           FROM category_image ci
                           WHERE ci.category_content_id = cc.id
                             AND ci.is_deleted = 0
                           ORDER BY ci."order" ASC, ci.id ASC
                       )
                   ) AS image_urls
            FROM category_content cc
            JOIN book b ON b.id = cc.book_id
                       AND b.user_id = ?
                       AND b.id != 0
                       AND b.is_deleted = 0
            LEFT JOIN category cat ON cat.id = cc.category_id AND cat.is_deleted = 0
            WHERE cc.is_deleted = 0
              AND cc.content_book_id = 0
              AND (
                  cc.title LIKE ? COLLATE NOCASE
                  OR cc.content LIKE ? COLLATE NOCASE
                  OR b.name LIKE ? COLLATE NOCASE
                  OR cat.title LIKE ? COLLATE NOCASE
              )
            ORDER BY cc.id DESC
        """
        return try Row.fetchAll(
            db,
            sql: sql,
            arguments: [ownerID, likeKeyword, likeKeyword, likeKeyword, likeKeyword]
        ).compactMap { row in
            let titlePlainText = Self.plainText(row["title"] as String? ?? "")
            let contentPlainText = Self.plainText(row["content"] as String? ?? "")
            let categoryTitle = row["category_title"] as String? ?? ""
            let bookTitle = Self.displayText(row["book_name"] as String?, fallback: "未知书籍")
            guard Self.contains(titlePlainText, keyword: keyword)
                    || Self.contains(contentPlainText, keyword: keyword)
                    || Self.contains(bookTitle, keyword: keyword)
                    || Self.contains(categoryTitle, keyword: keyword) else {
                return nil
            }

            let contentID = row["id"] as Int64? ?? 0
            let title = Self.displayText(titlePlainText, fallback: "相关内容")
            let snippetSource = Self.preferredSnippetSource(
                primary: contentPlainText,
                secondary: titlePlainText,
                keyword: keyword
            )
            let createdDate = row["created_date"] as Int64? ?? 0
            let relevantDisplay = GlobalSearchRelevantContentDisplay(
                title: title,
                content: Self.snippet(from: snippetSource, keyword: keyword),
                imageURLs: Self.splitList(row["image_urls"] as String?),
                categoryTitle: categoryTitle,
                bookTitle: bookTitle,
                dateText: Self.formatDate(createdDate)
            )
            return GlobalSearchResult(
                id: "relevant-\(contentID)",
                category: .relevant,
                target: .relevantDetail(contentId: contentID),
                display: .relevantContent(relevantDisplay),
                title: title,
                subtitle: Self.joinedMetadata([bookTitle, categoryTitle]),
                snippet: Self.snippet(from: snippetSource, keyword: keyword),
                coverURL: Self.nilIfBlank(row["book_cover"] as String?),
                timestamp: createdDate,
                matchedFields: Self.matchedFields(
                    [
                        ("标题", titlePlainText),
                        ("内容", contentPlainText),
                        ("书名", bookTitle),
                        ("分类", categoryTitle)
                    ],
                    keyword: keyword
                )
            )
        }
    }

    /// 查询相关书籍卡，按 Android category_id=1 与书籍字段匹配语义实现。
    nonisolated func searchRelevantBooks(_ db: Database, keyword: String, ownerID: Int64) throws -> [GlobalSearchResult] {
        let likeKeyword = Self.likeKeyword(keyword)
        // SQL 目的：按关键词搜索“相关书籍”卡片，承接 Android searchBookCategoryContent 的 RELEVANT_BOOK 语义，并补齐相关书籍的阅读资产字段。
        // 涉及表：category_content INNER JOIN book(source_book) INNER JOIN book(related_book) LEFT JOIN read_status/source；tag_book/tag 与 read_time_record 子查询补齐标签和最近阅读。
        // 关键过滤：category_content.category_id=1、content_book_id!=0、主记录有效、来源书与相关书均属于当前 owner 且可导航；匹配相关书 name/author/translator/press/isbn。
        // 时间字段：读取 category_content.created_date 作为结果时间；read_time_record 各时间字段按 Android 毫秒值聚合为 latest_read_date。
        // 返回字段用途：构建相关书籍结果行与书籍详情导航目标。
        let sql = """
            SELECT cc.id, cc.book_id, cc.content_book_id, cc.created_date,
                   source_book.name AS source_book_name,
                   related_book.name AS related_book_name,
                   related_book.cover AS related_book_cover,
                   related_book.author AS related_book_author,
                   related_book.translator AS related_book_translator,
                   related_book.press AS related_book_press,
                   related_book.isbn AS related_book_isbn,
                   related_book.read_position AS related_book_read_position,
                   related_book.current_position_unit AS related_book_current_position_unit,
                   related_book.total_position AS related_book_total_position,
                   related_book.total_pagination AS related_book_total_pagination,
                   COALESCE(related_rs.name, '') AS related_read_status_name,
                   COALESCE(related_source.name, '') AS related_source_name,
                   (
                       SELECT GROUP_CONCAT(tag_name, char(31))
                       FROM (
                           SELECT t.name AS tag_name
                           FROM tag_book tb
                           JOIN tag t ON t.id = tb.tag_id
                                     AND t.is_deleted = 0
                                     AND t.type = 2
                           WHERE tb.book_id = related_book.id
                             AND tb.is_deleted = 0
                           ORDER BY t.tag_order ASC, t.id ASC
                       )
                   ) AS related_tag_names,
                   (
                       SELECT MAX(
                           CASE
                               WHEN r.weread_read_date > 0 THEN r.weread_read_date
                               WHEN r.fuzzy_read_date > 0 THEN r.fuzzy_read_date
                               WHEN r.end_time > 0 THEN r.end_time
                               WHEN r.start_time > 0 THEN r.start_time
                               ELSE r.created_date
                           END
                       )
                       FROM read_time_record r
                       WHERE r.book_id = related_book.id
                         AND r.is_deleted = 0
                   ) AS related_latest_read_date
            FROM category_content cc
            JOIN book source_book ON source_book.id = cc.book_id
                                 AND source_book.user_id = ?
                                 AND source_book.id != 0
                                 AND source_book.is_deleted = 0
            JOIN book related_book ON related_book.id = cc.content_book_id
                                  AND related_book.user_id = ?
                                  AND related_book.id != 0
                                  AND related_book.is_deleted = 0
            LEFT JOIN read_status related_rs ON related_rs.id = related_book.read_status_id AND related_rs.is_deleted = 0
            LEFT JOIN source related_source ON related_source.id = related_book.source_id AND related_source.is_deleted = 0
            WHERE cc.category_id = 1
              AND cc.is_deleted = 0
              AND cc.content_book_id != 0
              AND (
                  related_book.name LIKE ? COLLATE NOCASE
                  OR related_book.author LIKE ? COLLATE NOCASE
                  OR related_book.translator LIKE ? COLLATE NOCASE
                  OR related_book.press LIKE ? COLLATE NOCASE
                  OR related_book.isbn LIKE ? COLLATE NOCASE
              )
            ORDER BY cc.id DESC
        """
        return try Row.fetchAll(
            db,
            sql: sql,
            arguments: [ownerID, ownerID, likeKeyword, likeKeyword, likeKeyword, likeKeyword, likeKeyword]
        ).map { row in
            let contentID = row["id"] as Int64? ?? 0
            let bookID = row["content_book_id"] as Int64? ?? 0
            let title = Self.displayText(row["related_book_name"] as String?, fallback: "相关书籍")
            let sourceBookTitle = Self.displayText(row["source_book_name"] as String?, fallback: "未知书籍")
            let author = row["related_book_author"] as String? ?? ""
            let translator = row["related_book_translator"] as String? ?? ""
            let press = row["related_book_press"] as String? ?? ""
            let isbn = row["related_book_isbn"] as String? ?? ""
            let tagNames = Self.splitList(row["related_tag_names"] as String?)
            let coverURL = Self.nilIfBlank(row["related_book_cover"] as String?)
            let createdDate = row["created_date"] as Int64? ?? 0
            let progress = BookshelfBookPresentationFormatter.readingProgress(
                readPosition: row["related_book_read_position"] as Double? ?? 0,
                currentPositionUnit: row["related_book_current_position_unit"] as Int64? ?? 2,
                totalPosition: row["related_book_total_position"] as Int64? ?? 0,
                totalPagination: row["related_book_total_pagination"] as Int64? ?? 0
            )
            let bookDisplay = GlobalSearchBookDisplay(
                title: title,
                coverURL: coverURL,
                author: author,
                translator: translator,
                press: press,
                isbn: isbn,
                dateText: Self.formatDate(createdDate),
                readStatusName: row["related_read_status_name"] as String? ?? "",
                sourceName: row["related_source_name"] as String? ?? "",
                progressText: BookshelfBookPresentationFormatter.readingProgressText(from: progress),
                recentReadText: Self.recentReadText(row["related_latest_read_date"] as Int64? ?? 0),
                tagNames: tagNames
            )
            let relevantBookDisplay = GlobalSearchRelevantBookDisplay(
                book: bookDisplay,
                sourceBookTitle: sourceBookTitle
            )
            return GlobalSearchResult(
                id: "relevant-book-\(contentID)",
                category: .relevant,
                target: .relevantBook(contentId: contentID, bookId: bookID),
                display: .relevantBook(relevantBookDisplay),
                title: title,
                subtitle: Self.joinedMetadata([sourceBookTitle, "相关书籍"]),
                snippet: Self.joinedMetadata([author, translator, press, isbn]),
                coverURL: coverURL,
                timestamp: createdDate,
                matchedFields: Self.matchedFields(
                    [
                        ("书名", title),
                        ("作者", author),
                        ("译者", translator),
                        ("出版社", press),
                        ("ISBN", isbn),
                        ("标签", Self.joinedMetadata(tagNames))
                    ],
                    keyword: keyword
                )
            )
        }
    }

    /// 查询书评结果，先用 SQL 命中标题、正文与所属书名，再按去 HTML 纯文本二次过滤。
    nonisolated func searchReviews(_ db: Database, keyword: String, ownerID: Int64) throws -> [GlobalSearchResult] {
        let likeKeyword = Self.likeKeyword(keyword)
        // SQL 目的：按关键词搜索有效书评标题、正文与所属书名，承接 Android 全局搜索中的 REVIEW 分类。
        // 涉及表：review INNER JOIN book，并通过 review_image 子查询补齐卡片附图。
        // 关键过滤：限定所属书当前 owner 且有效、排除软删除书评；匹配 review.title/review.content 或 book.name。
        // 时间字段：读取 review.created_date 作为搜索结果辅助排序/展示，单位为 Android 毫秒值。
        // 返回字段用途：构建书评搜索结果行、字段级筛选依据与书评详情导航目标。
        let sql = """
            SELECT rv.id, rv.book_id, rv.title, rv.content, rv.created_date,
                   b.name AS book_name, b.cover AS book_cover,
                   (
                       SELECT GROUP_CONCAT(image, char(31))
                       FROM (
                           SELECT ri.image AS image
                           FROM review_image ri
                           WHERE ri.review_id = rv.id
                             AND ri.is_deleted = 0
                           ORDER BY ri."order" ASC, ri.id ASC
                       )
                   ) AS image_urls
            FROM review rv
            JOIN book b ON b.id = rv.book_id
                       AND b.user_id = ?
                       AND b.id != 0
                       AND b.is_deleted = 0
            WHERE rv.is_deleted = 0
              AND (
                  rv.title LIKE ? COLLATE NOCASE
                  OR rv.content LIKE ? COLLATE NOCASE
                  OR b.name LIKE ? COLLATE NOCASE
              )
            ORDER BY rv.id DESC
        """
        return try Row.fetchAll(
            db,
            sql: sql,
            arguments: [ownerID, likeKeyword, likeKeyword, likeKeyword]
        ).compactMap { row in
            let titlePlainText = Self.plainText(row["title"] as String? ?? "")
            let contentPlainText = Self.plainText(row["content"] as String? ?? "")
            let bookTitle = Self.displayText(row["book_name"] as String?, fallback: "未知书籍")
            guard Self.contains(titlePlainText, keyword: keyword)
                    || Self.contains(contentPlainText, keyword: keyword)
                    || Self.contains(bookTitle, keyword: keyword) else {
                return nil
            }

            let reviewID = row["id"] as Int64? ?? 0
            let title = Self.displayText(titlePlainText, fallback: "书评")
            let snippetSource = Self.preferredSnippetSource(
                primary: contentPlainText,
                secondary: titlePlainText,
                keyword: keyword
            )
            let createdDate = row["created_date"] as Int64? ?? 0
            let reviewDisplay = GlobalSearchReviewDisplay(
                title: title,
                content: Self.snippet(from: snippetSource, keyword: keyword),
                imageURLs: Self.splitList(row["image_urls"] as String?),
                bookTitle: bookTitle,
                dateText: Self.formatDate(createdDate)
            )
            return GlobalSearchResult(
                id: "review-\(reviewID)",
                category: .review,
                target: .reviewDetail(reviewId: reviewID),
                display: .review(reviewDisplay),
                title: title,
                subtitle: bookTitle,
                snippet: Self.snippet(from: snippetSource, keyword: keyword),
                coverURL: Self.nilIfBlank(row["book_cover"] as String?),
                timestamp: createdDate,
                matchedFields: Self.matchedFields(
                    [
                        ("标题", titlePlainText),
                        ("正文", contentPlainText),
                        ("书名", bookTitle)
                    ],
                    keyword: keyword
                )
            )
        }
    }
}

// MARK: - Mapping Helpers

private extension GlobalSearchRepository {
    nonisolated static func likeKeyword(_ keyword: String) -> String {
        "%\(keyword)%"
    }

    nonisolated static func nilIfBlank(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    nonisolated static func displayText(_ text: String?, fallback: String) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    nonisolated static func joinedMetadata(_ values: [String]) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    nonisolated static func preferredSnippetSource(primary: String, secondary: String, keyword: String) -> String {
        if contains(primary, keyword: keyword) {
            return primary
        }
        if contains(secondary, keyword: keyword) {
            return secondary
        }
        return primary.isEmpty ? secondary : primary
    }

    nonisolated static func splitList(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text
            .split(separator: "\u{1F}")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func plainText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        let parsed = (try? SwiftSoup.parse(html).text()) ?? html
        return parsed.collapsingInternalWhitespace()
    }

    nonisolated static func contains(_ text: String, keyword: String) -> Bool {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !trimmedKeyword.isEmpty else { return false }
        return text.range(
            of: trimmedKeyword,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: text.startIndex..<text.endIndex,
            locale: .current
        ) != nil
    }

    nonisolated static func matchedFields(_ pairs: [(String, String)], keyword: String) -> [String] {
        var seen = Set<String>()
        return pairs.compactMap { label, value in
            guard contains(value, keyword: keyword), !seen.contains(label) else {
                return nil
            }
            seen.insert(label)
            return label
        }
    }

    nonisolated static func snippet(from text: String, keyword: String, maximumLength: Int = 92) -> String {
        let normalized = text.collapsingInternalWhitespace()
        guard normalized.count > maximumLength else {
            return normalized
        }
        guard let range = normalized.range(
            of: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            options: [.caseInsensitive, .diacriticInsensitive],
            range: normalized.startIndex..<normalized.endIndex,
            locale: .current
        ) else {
            return String(normalized.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }

        let leadingContext = 24
        let trailingContext = maximumLength - leadingContext
        let start = normalized.index(range.lowerBound, offsetBy: -leadingContext, limitedBy: normalized.startIndex) ?? normalized.startIndex
        let end = normalized.index(range.lowerBound, offsetBy: trailingContext, limitedBy: normalized.endIndex) ?? normalized.endIndex
        let prefix = start > normalized.startIndex ? "…" : ""
        let suffix = end < normalized.endIndex ? "…" : ""
        return prefix + normalized[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    nonisolated static func noteFooterText(
        position: String,
        positionUnit: Int64,
        includeTime: Bool,
        createdDate: Int64
    ) -> String {
        var parts: [String] = []
        if let positionText = NotePositionUnitFormatter.footerText(position: position, unit: positionUnit) {
            parts.append(positionText)
        }
        if includeTime, createdDate > 0 {
            parts.append(formatDate(createdDate))
        }
        return joinedMetadata(parts)
    }

    nonisolated static func recentReadText(_ timestamp: Int64) -> String {
        let dateText = formatDate(timestamp)
        return dateText.isEmpty ? "" : "最近 \(dateText)"
    }

    nonisolated static func formatDate(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    nonisolated static func uniqueResults(_ results: [GlobalSearchResult]) -> [GlobalSearchResult] {
        var seen = Set<String>()
        var unique: [GlobalSearchResult] = []
        for result in results {
            let key: String
            switch result.target {
            case .relevantDetail(let contentId), .relevantBook(let contentId, _):
                key = "relevant-\(contentId)"
            default:
                key = result.id
            }
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(result)
        }
        return unique
    }
}

private extension String {
    nonisolated func collapsingInternalWhitespace() -> String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
