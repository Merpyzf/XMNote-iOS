import Foundation
import GRDB

/**
 * [INPUT]: 依赖 GRDB Database 与 book、note、chapter、read_status、source 表读取书籍展示数据
 * [OUTPUT]: 对外提供 BookReadQuery（书籍卡片、书籍选择、书籍详情、目录与书摘只读查询）
 * [POS]: Data 层书籍只读查询协作者，承接 BookRepository 的无副作用读取映射逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍只读查询助手，隔离列表、选择器、详情页和书摘读取映射。
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

    /// 查询指定书籍详情数据，供详情页头部信息区、资料分区与目录分区渲染。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchBook(_ db: Database, bookId: Int64) throws -> BookDetail? {
        // SQL 目的：读取单本书资料详情，并补充阅读状态、来源名称与有效书摘总数。
        // 涉及表：book b LEFT JOIN read_status rs LEFT JOIN source s；子查询统计 note 表有效记录。
        // 关键过滤：按 bookId 精确命中，排除软删除书籍与占位书 b.id = 0。
        // 时间字段：pub_date 为 Android 原始文本字段，仅展示不转时区；note.created_date 不在此查询排序。
        // 返回字段用途：构建头部、资料属性、简介、作者简介与书摘数量。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.press,
                   b.author_intro, b.translator, b.isbn, b.pub_date,
                   b.summary, b.source_id,
                   COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(s.name, '') AS source_name,
                   (SELECT COUNT(*) FROM note n
                    WHERE n.book_id = b.id AND n.is_deleted = 0) AS note_count
            FROM book b
            LEFT JOIN read_status rs ON b.read_status_id = rs.id
            LEFT JOIN source s ON b.source_id = s.id
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
        let readStatusName: String = row["read_status_name"] ?? ""
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
            noteCount: row["note_count"] ?? 0,
            readStatusName: readStatusName,
            summary: row["summary"] ?? "",
            authorIntro: row["author_intro"] ?? "",
            attributes: attributes,
            chapters: try fetchBookDetailChapters(db, bookId: bookId)
        )
    }

    /// 查询书籍目录条目，供详情页资料区按层级展示。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchBookDetailChapters(_ db: Database, bookId: Int64) throws -> [BookDetailChapter] {
        // SQL 目的：读取指定书籍下的有效目录章节，并保留 Android v41 章节层级字段。
        // 涉及表：chapter。
        // 关键过滤：book_id 精确命中，chapter.is_deleted = 0；空标题不在 SQL 层过滤，交给映射阶段丢弃。
        // 时间字段：不参与排序；排序按 parent_id/chapter_order/source_order/id 保持 Android 章节组织顺序。
        // 返回字段用途：构建详情页目录分区的标题、缩进层级与稳定 ID。
        let sql = """
            SELECT id,
                   COALESCE(title, '') AS title,
                   chapter_level,
                   parent_id,
                   chapter_order,
                   source_order
            FROM chapter
            WHERE book_id = ?
              AND is_deleted = 0
            ORDER BY parent_id ASC, chapter_order ASC, source_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookId]).compactMap { row in
            let title = (row["title"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let rawLevel: Int64 = row["chapter_level"] ?? 0
            let parentID: Int64 = row["parent_id"] ?? 0
            return BookDetailChapter(
                id: row["id"],
                title: title,
                level: rawLevel > 0 ? rawLevel : (parentID == 0 ? 1 : 2),
                order: row["chapter_order"] ?? 0
            )
        }
    }

    /// 查询书籍下的书摘列表，供详情页“书摘时间线”模块展示。
    /// - Throws: 数据库查询失败时抛出错误。
    static func fetchNotes(_ db: Database, bookId: Int64) throws -> [NoteExcerpt] {
        // SQL 目的：拉取书籍下的书摘列表（详情页时间倒序）。
        // 涉及表：note。
        // 关键过滤：限定 book_id 且排除软删除 note。
        // 时间字段：created_date 为 Android 毫秒时间戳，按 DESC 排序；不做时区转换。
        // 返回字段用途：保留富文本内容、想法、位置与 include_time，供详情页渲染。
        let sql = """
            SELECT id, content, idea, position, position_unit,
                   include_time, created_date
            FROM note
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY created_date DESC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [bookId])

        return rows.map { row in
            NoteExcerpt(
                id: row["id"],
                content: row["content"] ?? "",
                idea: row["idea"] ?? "",
                position: row["position"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                createdDate: row["created_date"] ?? 0
            )
        }
    }

    /// 组装详情页资料属性，空字段不生成空壳。
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
