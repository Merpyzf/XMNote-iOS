import Foundation
import GRDB

/**
 * [INPUT]: 依赖 GRDB Database、BookContentSortQuery 与 book/note/chapter/attach_image/tag/tag_note/category/category_content/review/read_status/book_read_status_record/source/sort/read_time_record 表读取书籍展示数据
 * [OUTPUT]: 对外提供 BookReadQuery（书籍卡片、选择、工作台详情、目录及按持久化规则排序的单书四域只读查询）
 * [POS]: Data 层书籍只读查询协作者，承接 BookRepository 的无副作用读取映射逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍只读查询助手，隔离列表、选择器、书籍工作台和书摘读取映射。
nonisolated enum BookReadQuery {
    /// 查询书架页需要的书籍卡片数据，并补齐每本书的有效笔记数量。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchBooks(_ db: Database) throws -> [BookItem] {
        // SQL 目的：读取书架列表并附带每本书的有效笔记数。
        // 涉及表：book b LEFT JOIN note n；b.id -> n.book_id。
        // 关键过滤：仅保留未删除且非占位书籍，note 仅统计 n.is_deleted = 0。
        // 时间字段：本查询不读取时间字段；排序使用 pinned、pin_order 与 book_order。
        // 返回字段用途：构建旧书架页 BookItem 卡片数据与笔记数量。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover,
                   b.read_status_id, b.pinned, b.pin_order, b.book_order,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON b.id = n.book_id AND n.is_deleted = 0
            WHERE b.is_deleted = 0
              AND b.id != 0
            GROUP BY b.id
            ORDER BY b.pinned DESC, b.pin_order ASC, b.book_order ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)

        return rows.map { row in
            BookItem(
                id: row["id"],
                name: row["name"] ?? "",
                author: row["author"] ?? "",
                cover: row["cover"] ?? "",
                readStatusId: row["read_status_id"] ?? 0,
                noteCount: row["note_count"] ?? 0,
                pinned: (row["pinned"] as Int64? ?? 0) != 0
            )
        }
    }

    /// 查询书籍选择流需要的本地书籍列表，并按最近编辑优先排序。
    static func fetchPickerBooks(_ db: Database, matching query: String) throws -> [BookPickerBook] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // SQL 目的：读取本地可选书籍列表，供通用书籍选择流本地搜索与回显。
        // 涉及表：book。
        // 关键过滤：仅保留未软删除且非占位书籍；若存在 query，则匹配 name/author/press/isbn。
        // 时间字段：updated_date 为 Android 毫秒时间戳，按 DESC 对齐最近编辑优先；不做时区转换。
        // 返回字段用途：构建 BookPickerBook 的标题、作者、出版社、封面与进度单位。
        let baseSQL = """
            SELECT id, name, author, press, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE is_deleted = 0
              AND id != 0
            """
        let sql: String
        let arguments: StatementArguments
        if trimmedQuery.isEmpty {
            sql = baseSQL + "\nORDER BY updated_date DESC, id DESC"
            arguments = []
        } else {
            sql = baseSQL + """

                AND (
                    name LIKE ?
                    OR author LIKE ?
                    OR press LIKE ?
                    OR isbn LIKE ?
                )
                ORDER BY updated_date DESC, id DESC
                """
            let pattern = "%\(trimmedQuery)%"
            arguments = [pattern, pattern, pattern, pattern]
        }
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(mapPickerBook)
    }

    /// 查询单本本地书籍详情，供创建成功后的回填与默认已选恢复。
    static func fetchPickerBook(_ db: Database, bookId: Int64) throws -> BookPickerBook? {
        // SQL 目的：按主键读取单本本地书籍，供创建成功后回填到书籍选择流。
        // 涉及表：book。
        // 关键过滤：限定 id 精确命中，排除软删除书籍与占位书。
        // 时间字段：不读取时间字段。
        // 返回字段用途：返回 title/author/press/cover 与位置字段供选择行和回填使用。
        let sql = """
            SELECT id, name, author, press, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE id = ? AND is_deleted = 0 AND id != 0
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookId]) else {
            return nil
        }
        return mapPickerBook(row)
    }

    /// 查询指定书籍详情数据，供书籍工作台头部信息区与四域内容渲染。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchBook(_ db: Database, bookId: Int64) throws -> BookDetail? {
        // SQL 目的：读取单本书资料详情，并补充阅读状态、读完次数、来源、评分、进度、四域内容数量与累计阅读时长。
        // 涉及表：book b LEFT JOIN read_status rs LEFT JOIN source s；book_read_status_record/note/category_content/review 子查询统计有效状态记录与内容，read_time_record 子查询按 book_id 聚合阅读秒数。
        // 关键过滤：按 bookId 精确命中，排除软删除书籍与占位书 b.id = 0；读完次数与阅读记录严格使用 Android 已完成口径 read_status_id/status = 3、is_deleted = 0、book_id 匹配。
        // 时间字段：pub_date 为 Android 原始文本字段，仅展示不转时区；read_time_record.elapsed_seconds 为秒，直接聚合且不做时区换算。
        // 返回字段用途：构建首屏书籍身份、阅读概览、资料属性、简介、作者简介与书摘数量。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.press, b.score,
                   b.author_intro, b.translator, b.isbn, b.pub_date,
                   b.summary, b.source_id, b.score, b.read_status_id,
                   b.read_position, b.current_position_unit,
                   b.total_position, b.total_pagination,
                   COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(s.name, '') AS source_name,
                   COALESCE(rt.total_reading_time, 0) AS total_reading_time,
                   (SELECT COUNT(*) FROM book_read_status_record bsr
                    WHERE bsr.book_id = b.id
                      AND bsr.is_deleted = 0
                      AND bsr.read_status_id = 3) AS read_done_count,
                   (SELECT COUNT(*) FROM note n
                    WHERE n.book_id = b.id AND n.is_deleted = 0) AS note_count,
                   (SELECT COUNT(*) FROM category_content cc
                    WHERE cc.book_id = b.id AND cc.is_deleted = 0) AS related_count,
                   (SELECT COUNT(*) FROM review rv
                    WHERE rv.book_id = b.id AND rv.is_deleted = 0) AS review_count
            FROM book b
            LEFT JOIN read_status rs ON b.read_status_id = rs.id
            LEFT JOIN source s ON b.source_id = s.id
            LEFT JOIN (
                SELECT book_id, SUM(elapsed_seconds) AS total_reading_time
                FROM read_time_record
                WHERE status = 3 AND is_deleted = 0 AND book_id != 0
                GROUP BY book_id
            ) rt ON rt.book_id = b.id
            WHERE b.id = ? AND b.is_deleted = 0 AND b.id != 0
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookId]) else {
            return nil
        }

        let author: String = row["author"] ?? ""
        let press: String = row["press"] ?? ""
        let translator: String = row["translator"] ?? ""
        let pubDate: String = row["pub_date"] ?? ""
        let isbn: String = row["isbn"] ?? ""
        let sourceName: String = row["source_name"] ?? ""
        let readStatusID: Int64 = row["read_status_id"] ?? 0
        let readStatusName: String = row["read_status_name"] ?? ""
        let readDoneCount: Int64 = row["read_done_count"] ?? 0
        let readStatusBadgeTitle = BookshelfBookPresentationFormatter.readStatusBadgeTitle(
            readStatusID: readStatusID,
            readStatusName: readStatusName,
            readDoneCount: readDoneCount
        )
        let readPosition: Double = row["read_position"] ?? 0
        let currentPositionUnit: Int64 = row["current_position_unit"] ?? 0
        let totalPosition: Int64 = row["total_position"] ?? 0
        let totalPagination: Int64 = row["total_pagination"] ?? 0
        let progress = BookshelfBookPresentationFormatter.readingProgress(
            readPosition: readPosition,
            currentPositionUnit: currentPositionUnit,
            totalPosition: totalPosition,
            totalPagination: totalPagination
        )
        let attributes = makeBookDetailAttributes(
            author: author,
            translator: translator,
            press: press,
            pubDate: pubDate,
            isbn: isbn,
            sourceName: sourceName,
            readStatusName: readStatusName
        )

        return BookDetail(
            id: row["id"],
            name: row["name"] ?? "",
            author: author,
            cover: row["cover"] ?? "",
            press: press,
            score: row["score"] ?? 0,
            noteCount: row["note_count"] ?? 0,
            relatedCount: row["related_count"] ?? 0,
            reviewCount: row["review_count"] ?? 0,
            readStatusID: readStatusID,
            readStatusName: readStatusName,
            readStatusBadgeTitle: readStatusBadgeTitle,
            totalReadingSeconds: row["total_reading_time"] ?? 0,
            readingProgressFraction: progress.map { min(max($0 / 100, 0), 1) },
            readingProgressText: BookshelfBookPresentationFormatter.readingProgressText(from: progress),
            bookmarkText: BookshelfBookPresentationFormatter.bookmarkText(
                readPosition: readPosition,
                currentPositionUnit: currentPositionUnit
            ),
            summary: row["summary"] ?? "",
            authorIntro: row["author_intro"] ?? "",
            attributes: attributes,
            chapters: try fetchBookDetailChapters(db, bookId: bookId)
        )
    }

    /// 查询书籍目录条目，供书籍工作台目录域按层级展示。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchBookDetailChapters(_ db: Database, bookId: Int64) throws -> [BookDetailChapter] {
        // SQL 目的：读取指定书籍下的有效目录章节，并保留 Android v41 章节层级、收藏与有效书摘数量。
        // 涉及表：chapter c LEFT JOIN note n；c.id -> n.chapter_id。
        // 关键过滤：book_id 精确命中，chapter.is_deleted = 0；空标题不在 SQL 层过滤，交给映射阶段丢弃。
        // 时间字段：不参与排序；排序按 parent_id/chapter_order/source_order/id 保持 Android 章节组织顺序。
        // 返回字段用途：构建书籍工作台目录域的标题、缩进层级与稳定 ID。
        let sql = """
            SELECT c.id,
                   COALESCE(c.title, '') AS title,
                   c.chapter_level,
                   c.parent_id,
                   c.chapter_order,
                   c.source_order,
                   c.is_starred,
                   COUNT(n.id) AS note_count
            FROM chapter c
            LEFT JOIN note n ON n.chapter_id = c.id AND n.is_deleted = 0
            WHERE c.book_id = ?
              AND c.is_deleted = 0
            GROUP BY c.id
            ORDER BY c.parent_id ASC, c.chapter_order ASC, c.source_order ASC, c.id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookId]).compactMap { row in
            let title = (row["title"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let rawLevel: Int64 = row["chapter_level"] ?? 0
            let parentID: Int64 = row["parent_id"] ?? 0
            return BookDetailChapter(
                id: row["id"],
                parentID: parentID,
                title: title,
                level: rawLevel > 0 ? rawLevel : (parentID == 0 ? 1 : 2),
                order: row["chapter_order"] ?? 0,
                isStarred: (row["is_starred"] as Int64? ?? 0) != 0,
                noteCount: row["note_count"] ?? 0
            )
        }
    }

    /// 查询书籍下的书摘列表，按 `sort(book_id, type=NOTE)` 当前规则提供稳定顺序。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchNotes(_ db: Database, bookId: Int64) throws -> [NoteExcerpt] {
        // SQL 目的：拉取书籍下全部有效书摘，补齐章节、图片、标签及 Android 持久化排序所需字段。
        // 涉及表：note INNER JOIN book LEFT JOIN chapter；附图与标签随后分批读取。
        // 关键过滤：note.book_id 精确命中，书籍与书摘均有效且排除系统根书。
        // 时间字段：created_date 为 Android 毫秒时间戳，不在 SQL 层转换；最终顺序仅由 BookContentSortRule 决定。
        // 返回字段用途：构建原生工作台目录分组、书摘正文、图片、标签与查看器相邻顺序。
        let sql = """
            SELECT n.id, n.chapter_id, n.content, n.idea, n.position, n.position_unit,
                   n.include_time, n.created_date,
                   COALESCE(n.weread_range, '') AS weread_range,
                   b.source_id,
                   COALESCE(c.title, '') AS chapter_title,
                   COALESCE(c.chapter_order, 0) AS chapter_order,
                   COALESCE(c.chapter_level, 0) AS chapter_level
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
            LEFT JOIN chapter c ON c.id = n.chapter_id AND c.is_deleted = 0
            WHERE n.book_id = ? AND n.is_deleted = 0
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [bookId])
        let noteIDs: [Int64] = rows.map { $0["id"] }
        let imageURLsByNoteID = try fetchNoteImageURLs(db, noteIDs: noteIDs)
        let tagNamesByNoteID = try fetchNoteTagNames(db, noteIDs: noteIDs)
        let rule = try BookContentSortQuery.fetchRule(db, bookID: bookId, type: .notes)
        let sortedRows = BookContentSortQuery.sortedNoteRows(rows, rule: rule)

        return sortedRows.map { row in
            let noteID: Int64 = row["id"]
            return NoteExcerpt(
                id: noteID,
                chapterID: row["chapter_id"] ?? 0,
                chapterTitle: row["chapter_title"] ?? "",
                chapterOrder: row["chapter_order"] ?? 0,
                chapterLevel: row["chapter_level"] ?? 0,
                content: row["content"] ?? "",
                idea: row["idea"] ?? "",
                imageURLs: imageURLsByNoteID[noteID, default: []],
                tagNames: tagNamesByNoteID[noteID, default: []],
                position: row["position"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                createdDate: row["created_date"] ?? 0
            )
        }
    }

    /// 批量读取书摘附图，避免列表观察流产生逐条查询。
    private static func fetchNoteImageURLs(
        _ db: Database,
        noteIDs: [Int64]
    ) throws -> [Int64: [String]] {
        guard !noteIDs.isEmpty else { return [:] }
        var result: [Int64: [String]] = [:]
        for lowerBound in stride(from: 0, to: noteIDs.count, by: 400) {
            let upperBound = min(lowerBound + 400, noteIDs.count)
            let batch = Array(noteIDs[lowerBound..<upperBound])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            // SQL 目的：分批读取当前书籍全部书摘的有效附图，避免 500 条书摘超过 SQLite 变量上限。
            // 涉及表：attach_image。
            // 关键过滤：每批最多 400 个有效 note id，且显式过滤 attach_image.is_deleted = 0。
            // 时间字段：不读取时间字段；按 attach_image.id ASC 保持 Android 图片顺序。
            // 返回字段用途：按 note_id 聚合成 NoteExcerpt.imageURLs，GRDB 观察同时覆盖附图变化。
            let sql = """
                SELECT note_id, image_url
                FROM attach_image
                WHERE note_id IN (\(placeholders))
                  AND is_deleted = 0
                ORDER BY note_id ASC, id ASC
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(batch))
            for row in rows {
                let noteID: Int64 = row["note_id"]
                let imageURL = (row["image_url"] as String? ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !imageURL.isEmpty else { continue }
                result[noteID, default: []].append(imageURL)
            }
        }
        return result
    }

    /// 批量读取书摘标签，关系与标签均遵循 Android 软删除和类型语义。
    private static func fetchNoteTagNames(
        _ db: Database,
        noteIDs: [Int64]
    ) throws -> [Int64: [String]] {
        guard !noteIDs.isEmpty else { return [:] }
        var result: [Int64: [String]] = [:]
        for lowerBound in stride(from: 0, to: noteIDs.count, by: 400) {
            let upperBound = min(lowerBound + 400, noteIDs.count)
            let batch = Array(noteIDs[lowerBound..<upperBound])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            // SQL 目的：分批读取当前书籍全部有效书摘标签，避免 500 条书摘超过 SQLite 变量上限。
            // 涉及表：tag_note tn INNER JOIN tag t，tn.tag_id -> t.id。
            // 关键过滤：每批最多 400 个 note id；关系与标签均过滤软删除；仅保留 tag.type = 1。
            // 时间字段：不读取时间字段；按 tag_order ASC、tag_note.id ASC 对齐 Android 标签顺序。
            // 返回字段用途：按 note_id 聚合成 NoteExcerpt.tagNames，GRDB 观察同时覆盖关系与标签变化。
            let sql = """
                SELECT tn.note_id, t.name
                FROM tag_note tn
                JOIN tag t ON t.id = tn.tag_id
                          AND t.is_deleted = 0
                          AND t.type = 1
                WHERE tn.note_id IN (\(placeholders))
                  AND tn.is_deleted = 0
                ORDER BY tn.note_id ASC, t.tag_order ASC, tn.id ASC
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(batch))
            for row in rows {
                let noteID: Int64 = row["note_id"]
                let tagName = (row["name"] as String? ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tagName.isEmpty else { continue }
                result[noteID, default: []].append(tagName)
            }
        }
        return result
    }

    /// 查询单本书下可见相关分类，范围严格对齐 Android 的全局分类或当前书籍私有分类。
    static func fetchRelatedCategories(_ db: Database, bookId: Int64) throws -> [BookRelatedCategory] {
        // SQL 目的：读取相关内容创建与筛选可用的未隐藏分类。
        // 涉及表：category。
        // 关键过滤：只允许 book_id = 0 的全局分类或当前 book_id 私有分类，排除软删除与隐藏项。
        // 时间字段：不读取时间字段；按 Android category.order ASC、id ASC 稳定排序。
        // 返回字段用途：构建相关域分组、筛选与创建前分类选择。
        let sql = """
            SELECT id, COALESCE(title, '') AS title, `order`
            FROM category
            WHERE (book_id = 0 OR book_id = ?)
              AND is_deleted = 0
              AND is_hide = 0
            ORDER BY `order` ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookId]).compactMap { row in
            let title = (row["title"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return BookRelatedCategory(
                id: row["id"],
                title: title,
                order: row["order"] ?? 0
            )
        }
    }

    /// 查询单本书下全部有效相关记录，普通内容与关联书籍保持 Android 同表语义。
    static func fetchRelated(_ db: Database, bookId: Int64) throws -> [BookRelatedExcerpt] {
        // SQL 目的：读取指定书籍的相关内容，并补齐分类与可选关联书籍的展示信息。
        // 涉及表：category_content cc LEFT JOIN category cat LEFT JOIN book linked_book。
        // 关键过滤：cc.book_id 精确命中且 cc.is_deleted = 0；关联书籍仅在其未删除时映射展示。
        // 时间字段：created_date 为 Android 毫秒时间戳，不做时区转换；分类内遵循持久化时间升/降序。
        // 返回字段用途：构建相关域按类别分组的普通内容行和关联书籍行。
        let rule = try BookContentSortQuery.fetchRule(db, bookID: bookId, type: .related)
        let direction = rule == .createdDateAscending ? "ASC" : "DESC"
        let sql = """
            SELECT cc.id, cc.category_id, cc.title, cc.content, cc.url,
                   cc.content_book_id, cc.created_date,
                   COALESCE(cat.title, '') AS category_title,
                   COALESCE(cat.`order`, 0) AS category_order,
                   COALESCE(linked_book.name, '') AS linked_book_title,
                   COALESCE(linked_book.author, '') AS linked_book_author,
                   COALESCE(linked_book.cover, '') AS linked_book_cover,
                   COALESCE(linked_book.is_deleted, 0) AS linked_book_is_deleted
            FROM category_content cc
            LEFT JOIN category cat ON cat.id = cc.category_id AND cat.is_deleted = 0
            LEFT JOIN book linked_book ON linked_book.id = cc.content_book_id
            WHERE cc.book_id = ? AND cc.is_deleted = 0
            ORDER BY category_order ASC, cc.created_date \(direction), cc.id \(direction)
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookId]).map { row in
            BookRelatedExcerpt(
                id: row["id"],
                categoryID: row["category_id"] ?? 0,
                categoryTitle: row["category_title"] ?? "",
                title: row["title"] ?? "",
                content: row["content"] ?? "",
                url: row["url"] ?? "",
                linkedBookID: row["content_book_id"] ?? 0,
                linkedBookTitle: row["linked_book_title"] ?? "",
                linkedBookAuthor: row["linked_book_author"] ?? "",
                linkedBookCover: row["linked_book_cover"] ?? "",
                isLinkedBookPlaceholder: (row["linked_book_is_deleted"] as Int64? ?? 0) != 0,
                createdDate: row["created_date"] ?? 0
            )
        }
    }

    /// 查询单本书下全部有效书评，按创建时间倒序输出。
    static func fetchReviews(_ db: Database, bookId: Int64) throws -> [BookReviewExcerpt] {
        // SQL 目的：读取指定书籍下的有效书评列表。
        // 涉及表：review。
        // 关键过滤：review.book_id 精确命中且 is_deleted = 0。
        // 时间字段：created_date 为 Android 毫秒时间戳，不做时区转换；遵循持久化时间升/降序。
        // 返回字段用途：构建书评域标题优先的高密度列表。
        let rule = try BookContentSortQuery.fetchRule(db, bookID: bookId, type: .reviews)
        let direction = rule == .createdDateAscending ? "ASC" : "DESC"
        let sql = """
            SELECT id, title, content, created_date
            FROM review
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY created_date \(direction), id \(direction)
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookId]).map { row in
            BookReviewExcerpt(
                id: row["id"],
                title: row["title"] ?? "",
                content: row["content"] ?? "",
                createdDate: row["created_date"] ?? 0
            )
        }
    }

    /// 组装书籍工作台资料属性，空字段不生成空壳。
    private static func makeBookDetailAttributes(
        author: String,
        translator: String,
        press: String,
        pubDate: String,
        isbn: String,
        sourceName: String,
        readStatusName: String
    ) -> [BookDetailAttribute] {
        [
            makeBookDetailAttribute(.author, value: author),
            makeBookDetailAttribute(.translator, value: translator),
            makeBookDetailAttribute(.press, value: press),
            makeBookDetailAttribute(.pubDate, value: pubDate),
            makeBookDetailAttribute(.isbn, value: isbn),
            makeBookDetailAttribute(.source, value: sourceName),
            makeBookDetailAttribute(.readStatus, value: readStatusName)
        ]
        .compactMap { $0 }
    }

    /// 创建非空详情属性。
    private static func makeBookDetailAttribute(
        _ kind: BookDetailAttributeKind,
        value: String
    ) -> BookDetailAttribute? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return BookDetailAttribute(kind: kind, value: trimmed)
    }

    private static func mapPickerBook(_ row: Row) -> BookPickerBook {
        BookPickerBook(
            id: row["id"],
            title: row["name"] ?? "",
            author: row["author"] ?? "",
            press: row["press"] ?? "",
            coverURL: row["cover"] ?? "",
            positionUnit: row["position_unit"] ?? 0,
            totalPosition: row["total_position"] ?? 0,
            totalPagination: row["total_pagination"] ?? 0
        )
    }
}
