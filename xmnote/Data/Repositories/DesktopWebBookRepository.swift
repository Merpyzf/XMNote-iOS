/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 V44 书籍、内容、阅读行为与关联表，以及共享 WebBookDto 投影
 * [OUTPUT]: 对外提供 Android BookService 书籍查询及写入基础语义
 * [POS]: Data 层网页书籍专用仓储；不复用 App 页面查询，也不让 XMNoteWeb 接触 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android WebBookStatsDto 对应的数据库业务快照。
struct DesktopWebBookStatsSnapshot: Equatable, Sendable {
    let total: Int
    let reading: Int
    let want: Int
    let read: Int
    let dropped: Int
    let hold: Int
}

/// Package BookCreateRequest 到 Data 层的无框架输入，保持 Kotlin Int/Float 字段宽度。
nonisolated struct DesktopWebBookCreateInput: Sendable {
    let name: String
    let rawName: String?
    let author: String?
    let cover: String?
    let authorIntro: String?
    let translator: String?
    let summary: String?
    let isbn: String?
    let press: String?
    let pubDate: String?
    let doubanID: Int?
    let readStatus: Int
    let readStatusChangedTime: Int64?
    let score: Int?
    let type: Int?
    let positionUnit: Int?
    let readPosition: Double?
    let totalPosition: Int?
    let totalPagination: Int?
    let sourceID: Int64?
    let purchaseDate: Int64?
    let price: Float?
    let wordCount: Int64?
    let catalog: String?
    let tagIDs: [Int64]?
    let groupID: Int64?
    let isDeleted: Bool?
    let creationMode: String?
}

/// Package BookUpdateRequest 到 Data 层的无框架局部更新输入。
nonisolated struct DesktopWebBookUpdateInput: Sendable {
    let name: String?
    let rawName: String?
    let author: String?
    let cover: String?
    let authorIntro: String?
    let translator: String?
    let summary: String?
    let isbn: String?
    let press: String?
    let pubDate: String?
    let doubanID: Int?
    let readStatus: Int?
    let readStatusChangedTime: Int64?
    let score: Int?
    let type: Int?
    let positionUnit: Int?
    let readPosition: Double?
    let totalPosition: Int?
    let totalPagination: Int?
    let sourceID: Int64?
    let purchaseDate: Int64?
    let price: Float?
    let wordCount: Int64?
    let clearWordCount: Bool?
    let catalog: String?
    let tagIDs: [Int64]?
    let groupID: Int64?
}

/// Package BookBatchUpdateRequest 到 Data 层的无框架批量局部更新输入。
nonisolated struct DesktopWebBookBatchUpdateInput: Sendable {
    let ids: [Int64]
    let readStatus: Int?
    let readStatusChangedTime: Int64?
    let sourceID: Int64?
    let groupID: Int64?
    let addTagIDs: [Int64]?
}

/// Package 批量精确替换标签条目到 Data 层的无框架输入。
nonisolated struct DesktopWebBookBatchReplaceTagsItemInput: Sendable {
    let id: Int64
    let tagIDs: [Int64]
}

/// 使用独立 SQL 复刻 Android WebBookRepository 的只读书籍路径。
nonisolated struct DesktopWebBookRepository: Sendable {
    // NOTE(ANDROID-WEB-008): Android Book Web/App 查询未统一按 user_id 隔离；基线阶段保留跨 owner 可见行为。
    private struct RecentReadDatabaseRow: Sendable {
        let bookID: Int64
        let recentReadTime: Int64
    }

    let database: AppDatabase
    let projection: DesktopWebGroupRepository
    let currentTimeMillis: @Sendable () -> Int64
    let shouldPlaceNewBookAtEnd: @Sendable () -> Bool

    /// 固定同一数据库、毫秒时钟和新增位置偏好；写入在 GRDB 连接池内串行执行，调用取消不会回滚已提交步骤。
    init(
        database: AppDatabase,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        shouldPlaceNewBookAtEnd: @escaping @Sendable () -> Bool = {
            (UserDefaults.standard.object(forKey: "newAddBookPosition") as? Int ?? 0) == 1
        }
    ) {
        self.database = database
        self.currentTimeMillis = currentTimeMillis
        self.shouldPlaceNewBookAtEnd = shouldPlaceNewBookAtEnd
        projection = DesktopWebGroupRepository(
            database: database,
            currentTimeMillis: currentTimeMillis
        )
    }

    /// 统计全部有效且非占位书籍，并把未知阅读状态只计入 total。
    func stats() async throws -> DesktopWebBookStatsSnapshot {
        try await database.dbPool.read { db in
            // SQL 目的：按 WebBookDao.queryBookCountByStatus/countAllBooks 汇总书架阅读状态。
            // 涉及表：book。
            // 关键过滤：is_deleted = 0 且 id != 0；故意不按 user_id 过滤。
            // 时间字段：无。
            // 返回字段用途：WebBookStatsDto；状态 1...5 之外的记录只进入 total。
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT read_status_id, COUNT(*) AS status_count
                    FROM book
                    WHERE is_deleted = 0 AND id != 0
                    GROUP BY read_status_id
                    """
            )
            let counts = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["read_status_id"] as Int64, row["status_count"] as Int64)
            })
            let total = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book WHERE is_deleted = 0 AND id != 0"
            ) ?? 0
            return DesktopWebBookStatsSnapshot(
                total: Int(total),
                reading: Int(counts[2] ?? 0),
                want: Int(counts[1] ?? 0),
                read: Int(counts[3] ?? 0),
                dropped: Int(counts[4] ?? 0),
                hold: Int(counts[5] ?? 0)
            )
        }
    }

    /// 查询有效且非占位书籍详情；不存在和已软删除使用同一 Android 404 业务错误。
    func book(id: Int64) async throws -> DesktopWebBookSnapshot {
        let record = try await database.dbPool.read { db in
            // SQL 目的：按 ActiveBookGuard + WebBookDao.findById 查询有效书籍详情。
            // 涉及表：book。
            // 关键过滤：id 精确匹配、id != 0、is_deleted = 0；故意不按 user_id 过滤。
            // 时间字段：原样交给完整 DTO 投影。
            // 返回字段用途：GET /api/v1/books/{id}。
            try BookRecord.fetchOne(
                db,
                sql: "SELECT * FROM book WHERE id = ? AND id != 0 AND is_deleted = 0",
                arguments: [id]
            )
        }
        guard let record else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(id)")
        }
        guard let snapshot = try await projection.projectBookSnapshots([record]).first else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(id)")
        }
        return snapshot
    }

    /// 按六类最近行为的合并时间倒序读取在读书籍，并返回行为时间字段。
    func recentReadBooks(
        page: Int,
        pageSize: Int
    ) async throws -> DesktopWebPagedSnapshot<DesktopWebBookSnapshot> {
        let rows = try await recentReadRows()
        let offset = safeOffset(page: page, pageSize: pageSize)
        let pageRows = offset >= rows.count
            ? []
            : Array(rows[offset..<min(rows.count, offset + min(pageSize, rows.count - offset))])
        let ids = pageRows.map(\.bookID)
        let books = try await activeBooks(ids: ids)
        let times = Dictionary(uniqueKeysWithValues: pageRows.map { ($0.bookID, $0.recentReadTime) })
        let items = try await projection.projectBookSnapshots(books, recentReadTimes: times)
        let total = Int64(rows.count)
        return DesktopWebPagedSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: total,
            totalPages: Self.totalPages(total: total, pageSize: pageSize)
        )
    }

    /// 返回最近创建有效书摘的有效书籍；没有匹配项时返回 nil。
    func lastNoteBook() async throws -> DesktopWebBookSnapshot? {
        let id = try await database.dbPool.read { db in
            // SQL 目的：按 WebBookDao.queryLastNoteBookId 查询最近创建书摘所属书籍。
            // 涉及表：note INNER JOIN book。
            // 关键过滤：书摘和书籍有效、book.id != 0；只按 note.created_date 倒序。
            // 时间字段：created_date 原样比较毫秒值，不使用 updated_date。
            // 返回字段用途：快速书摘默认书籍；没有有效书摘时返回 nil。
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT b.id
                    FROM note n
                    INNER JOIN book b ON n.book_id = b.id
                    WHERE n.is_deleted = 0
                      AND b.is_deleted = 0
                      AND b.id != 0
                    ORDER BY n.created_date DESC
                    LIMIT 1
                    """
            )
        }
        guard let id else { return nil }
        return try await book(id: id)
    }

    /// 按 pin_order 升序分页读取置顶书籍，保留该专用接口与普通列表的排序差异。
    func pinnedBooks(
        page: Int,
        pageSize: Int
    ) async throws -> DesktopWebPagedSnapshot<DesktopWebBookSnapshot> {
        let offset = safeOffset(page: page, pageSize: pageSize)
        let result = try await database.dbPool.read { db -> ([Int64], Int64) in
            // SQL 目的：按 WebBookDao.queryPinnedBookIds/countPinnedBooks 分页读取置顶书籍。
            // 涉及表：book。
            // 关键过滤：有效、id != 0、pinned = 1；故意不按 user_id 过滤。
            // 时间字段：无。
            // 返回字段用途：ID 按 pin_order ASC 保序，随后投影完整 WebBookDto。
            let ids = try Int64.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM book
                    WHERE is_deleted = 0 AND id != 0 AND pinned = 1
                    ORDER BY pin_order ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [pageSize, offset]
            )
            let total = try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book WHERE is_deleted = 0 AND id != 0 AND pinned = 1"
            ) ?? 0
            return (ids, total)
        }
        let items = try await projection.projectBookSnapshots(try await activeBooks(ids: result.0))
        return DesktopWebPagedSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: result.1,
            totalPages: Self.totalPages(total: result.1, pageSize: pageSize)
        )
    }

    /// 读取未分组且非置顶书籍，按 Android 普通列表规则先全量排序再分页。
    func ungroupedBooks(
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPagedSnapshot<DesktopWebBookSnapshot> {
        let books = try await database.dbPool.read { db in
            // SQL 目的：按 BookFilter(ungroupedOnly=true, excludePinned=true) 读取全量候选。
            // 涉及表：book，并用 group_book NOT EXISTS 判断是否未分组。
            // 关键过滤：book 有效、id != 0、pinned = 0，不存在任意有效分组关系；不按 owner 过滤。
            // 时间字段：无。
            // 返回字段用途：内存执行 Android 全字段排序后分页。
            try BookRecord.fetchAll(
                db,
                sql: """
                    SELECT b.*
                    FROM book b
                    WHERE b.is_deleted = 0
                      AND b.id != 0
                      AND b.pinned = 0
                      AND NOT EXISTS (
                          SELECT 1
                          FROM group_book gb
                          INNER JOIN `group` g ON g.id = gb.group_id
                          WHERE gb.book_id = b.id
                            AND gb.is_deleted = 0
                            AND g.is_deleted = 0
                      )
                    ORDER BY b.pinned DESC, b.pin_order ASC
                    """
            )
        }
        let sorted = try await sortedBooks(books, sortBy: sortBy, sortOrder: sortOrder)
        let offset = safeOffset(page: page, pageSize: pageSize)
        let pageBooks = offset >= sorted.count
            ? []
            : Array(sorted[offset..<min(sorted.count, offset + min(pageSize, sorted.count - offset))])
        let modifiedTimes = sortBy == "modify_time"
            ? try await projection.lastModifiedTimes(for: pageBooks)
            : [:]
        let items = try await projection.projectBookSnapshots(
            pageBooks,
            lastModifiedTimes: modifiedTimes
        )
        let total = Int64(sorted.count)
        return DesktopWebPagedSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: total,
            totalPages: Self.totalPages(total: total, pageSize: pageSize)
        )
    }

    /// 查询 Android 最近在读 CTE 的完整候选集；各内容来源仍各自只贡献最近 20 本。
    private func recentReadRows() async throws -> [RecentReadDatabaseRow] {
        try await database.dbPool.read { db in
            // SQL 目的：复刻 WebBookDao.queryRecentReadBooks/countRecentReadBooks 的最近行为合并。
            // 涉及表：note、category_content、review、read_time_record、check_in_record、book。
            // 关键过滤：仅有效且 read_status_id = 2 的书籍；前五类行为各取最近 20 本，书签不限量。
            // 时间字段：计时按 fuzzy/weread/end/start/created 优先级，打卡按 checkin/created；均为毫秒。
            // 返回字段用途：按每本书最大行为时间倒序生成分页和 recentReadTime。
            let sql = """
                WITH recent_sources AS (
                    SELECT n.book_id, n.latest_time
                    FROM (
                        SELECT n.book_id, MAX(n.created_date) AS latest_time
                        FROM note n
                        INNER JOIN book b ON b.id = n.book_id
                        WHERE n.is_deleted = 0 AND b.is_deleted = 0 AND b.id != 0 AND b.read_status_id = 2
                        GROUP BY n.book_id ORDER BY latest_time DESC LIMIT 20
                    ) n
                    UNION ALL
                    SELECT c.book_id, c.latest_time
                    FROM (
                        SELECT c.book_id, MAX(c.created_date) AS latest_time
                        FROM category_content c
                        INNER JOIN book b ON b.id = c.book_id
                        WHERE c.is_deleted = 0 AND b.is_deleted = 0 AND b.id != 0 AND b.read_status_id = 2
                        GROUP BY c.book_id ORDER BY latest_time DESC LIMIT 20
                    ) c
                    UNION ALL
                    SELECT r.book_id, r.latest_time
                    FROM (
                        SELECT r.book_id, MAX(r.created_date) AS latest_time
                        FROM review r
                        INNER JOIN book b ON b.id = r.book_id
                        WHERE r.is_deleted = 0 AND b.is_deleted = 0 AND b.id != 0 AND b.read_status_id = 2
                        GROUP BY r.book_id ORDER BY latest_time DESC LIMIT 20
                    ) r
                    UNION ALL
                    SELECT rt.book_id, rt.latest_time
                    FROM (
                        SELECT rt.book_id,
                               MAX(CASE
                                   WHEN rt.fuzzy_read_date != 0 THEN rt.fuzzy_read_date
                                   WHEN rt.weread_read_date != 0 THEN rt.weread_read_date
                                   WHEN rt.end_time != 0 THEN rt.end_time
                                   WHEN rt.start_time != 0 THEN rt.start_time
                                   ELSE rt.created_date
                               END) AS latest_time
                        FROM read_time_record rt
                        INNER JOIN book b ON b.id = rt.book_id
                        WHERE rt.is_deleted = 0 AND b.is_deleted = 0 AND b.id != 0 AND b.read_status_id = 2
                        GROUP BY rt.book_id ORDER BY latest_time DESC LIMIT 20
                    ) rt
                    UNION ALL
                    SELECT ck.book_id, ck.latest_time
                    FROM (
                        SELECT ck.book_id,
                               MAX(CASE WHEN ck.checkin_date != 0 THEN ck.checkin_date ELSE ck.created_date END) AS latest_time
                        FROM check_in_record ck
                        INNER JOIN book b ON b.id = ck.book_id
                        WHERE ck.is_deleted = 0 AND b.is_deleted = 0 AND b.id != 0 AND b.read_status_id = 2
                        GROUP BY ck.book_id ORDER BY latest_time DESC LIMIT 20
                    ) ck
                    UNION ALL
                    SELECT b.id AS book_id, b.book_mark_modified_time AS latest_time
                    FROM book b
                    WHERE b.is_deleted = 0 AND b.id != 0 AND b.read_status_id = 2
                      AND b.book_mark_modified_time != 0
                )
                SELECT book_id, MAX(latest_time) AS recent_read_time
                FROM recent_sources
                GROUP BY book_id
                ORDER BY recent_read_time DESC
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                RecentReadDatabaseRow(
                    bookID: row["book_id"],
                    recentReadTime: row["recent_read_time"]
                )
            }
        }
    }

    /// 批量读取有效书籍并恢复输入 ID 顺序，模拟 Android queryBooksByIds 后的 mapNotNull。
    func activeBooks(ids: [Int64]) async throws -> [BookRecord] {
        guard !ids.isEmpty else { return [] }
        var recordsByID: [Int64: BookRecord] = [:]
        for chunk in ids.chunkedForDesktopWeb(maxCount: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let records = try await database.dbPool.read { db in
                // SQL 目的：按 WebBookDao.queryBooksByIds 批量回读有效书籍。
                // 涉及表：book。
                // 关键过滤：ID 位于当前分块且 is_deleted = 0；Android 此查询不额外排除 id = 0。
                // 时间字段：全部原样返回。
                // 返回字段用途：调用方按原始 ID 顺序重组完整 DTO。
                try BookRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM book WHERE id IN (\(placeholders)) AND is_deleted = 0",
                    arguments: StatementArguments(chunk)
                )
            }
            for record in records {
                if let id = record.id { recordsByID[id] = record }
            }
        }
        return ids.compactMap { recordsByID[$0] }
    }

    /// 复刻普通书籍列表的置顶优先及十类内存排序；这里用于未分组接口并供后续列表复用。
    func sortedBooks(
        _ books: [BookRecord],
        sortBy: String,
        sortOrder: String
    ) async throws -> [BookRecord] {
        let ids = books.compactMap(\.id)
        let noteCounts = sortBy == "note_count"
            ? try await projection.aggregateMap(table: "note", value: "COUNT(*)", bookIDs: ids)
            : [:]
        let readingTimes = sortBy == "total_reading_time"
            ? try await projection.aggregateMap(
                table: "read_time_record",
                value: "SUM(elapsed_seconds)",
                bookIDs: ids,
                extraCondition: "AND status = 3"
            )
            : [:]
        let rawDoneTimes = sortBy == "read_done_time"
            ? try await projection.aggregateMap(
                table: "book_read_status_record",
                value: "MAX(changed_date)",
                bookIDs: ids,
                extraCondition: "AND read_status_id = 3"
            )
            : [:]
        let modifiedTimes = sortBy == "modify_time"
            ? try await projection.lastModifiedTimes(for: books)
            : [:]
        let doneTimes: [Int64: Int64] = Dictionary(uniqueKeysWithValues: books.compactMap { book in
            guard let id = book.id else { return nil }
            return (id, projection.resolvedReadDoneTime(book: book, recordedTimes: rawDoneTimes))
        })
        let ascending = sortOrder == "asc"
        let baseIndex = Dictionary(uniqueKeysWithValues: books.enumerated().compactMap { index, book in
            book.id.map { ($0, index) }
        })
        let pinned = books.filter { $0.pinned == 1 }.sorted {
            if $0.pinOrder != $1.pinOrder { return $0.pinOrder > $1.pinOrder }
            return (baseIndex[$0.id ?? 0] ?? 0) < (baseIndex[$1.id ?? 0] ?? 0)
        }
        let regular = books.filter { $0.pinned != 1 }

        let sortedRegular: [BookRecord]
        switch sortBy {
        case "custom":
            sortedRegular = regular.sorted {
                if $0.bookOrder != $1.bookOrder {
                    return ascending ? $0.bookOrder > $1.bookOrder : $0.bookOrder < $1.bookOrder
                }
                return ascending ? ($0.id ?? 0) > ($1.id ?? 0) : ($0.id ?? 0) < ($1.id ?? 0)
            }
        case "create_time":
            sortedRegular = sortByLong(regular, ascending: ascending) { $0.createdDate }
        case "modify_time":
            sortedRegular = sortByLong(regular, ascending: ascending) { modifiedTimes[$0.id ?? 0] ?? 0 }
        case "name":
            let keyedBooks = regular.map { book in
                (book: book, comparableName: comparableName(book.name))
            }
            sortedRegular = keyedBooks.sorted {
                if $0.comparableName != $1.comparableName {
                    return ascending
                        ? $0.comparableName < $1.comparableName
                        : $0.comparableName > $1.comparableName
                }
                if $0.book.createdDate != $1.book.createdDate {
                    return ascending
                        ? $0.book.createdDate < $1.book.createdDate
                        : $0.book.createdDate > $1.book.createdDate
                }
                return ascending
                    ? ($0.book.id ?? 0) < ($1.book.id ?? 0)
                    : ($0.book.id ?? 0) > ($1.book.id ?? 0)
            }.map(\.book)
        case "publish_date":
            let withDate = regular.filter { projection.publishTimestamp($0.pubDate) != 0 }
            let withoutDate = regular.filter { projection.publishTimestamp($0.pubDate) == 0 }
            sortedRegular = sortByLong(withDate, ascending: ascending) {
                projection.publishTimestamp($0.pubDate)
            } + sortByLong(withoutDate, ascending: ascending) { $0.createdDate }
        case "note_count":
            if ascending {
                let withNotes = regular.filter { (noteCounts[$0.id ?? 0] ?? 0) > 0 }
                let withoutNotes = regular.filter { (noteCounts[$0.id ?? 0] ?? 0) <= 0 }
                sortedRegular = sortByLong(withNotes, ascending: true) {
                    noteCounts[$0.id ?? 0] ?? 0
                } + sortByLong(withoutNotes, ascending: true) { $0.createdDate }
            } else {
                sortedRegular = sortByLong(regular, ascending: false) {
                    noteCounts[$0.id ?? 0] ?? 0
                }
            }
        case "rating":
            if ascending {
                let rated = regular.filter { $0.score > 0 }
                let unrated = regular.filter { $0.score <= 0 }
                sortedRegular = sortByLong(rated, ascending: true) { $0.score }
                    + sortByLong(unrated, ascending: true) { $0.createdDate }
            } else {
                sortedRegular = sortByLong(regular, ascending: false) { $0.score }
            }
        case "read_done_time":
            let done = regular.filter { (doneTimes[$0.id ?? 0] ?? 0) > 0 }
            let unfinished = regular.filter { (doneTimes[$0.id ?? 0] ?? 0) == 0 }
            sortedRegular = sortByLong(done, ascending: ascending) { doneTimes[$0.id ?? 0] ?? 0 }
                + sortByLong(unfinished, ascending: ascending) { $0.createdDate }
        case "total_reading_time":
            if ascending {
                let withTime = regular.filter { (readingTimes[$0.id ?? 0] ?? 0) > 0 }
                let withoutTime = regular.filter { (readingTimes[$0.id ?? 0] ?? 0) <= 0 }
                sortedRegular = sortByLong(withTime, ascending: true) {
                    readingTimes[$0.id ?? 0] ?? 0
                } + sortByLong(withoutTime, ascending: true) { $0.createdDate }
            } else {
                sortedRegular = sortByLong(regular, ascending: false) {
                    readingTimes[$0.id ?? 0] ?? 0
                }
            }
        case "reading_progress":
            let withProgress = regular.filter { projection.readingProgress($0) > 0 }
            let withoutProgress = regular.filter { projection.readingProgress($0) <= 0 }
            sortedRegular = sortByDouble(withProgress, ascending: ascending) {
                projection.readingProgress($0)
            } + sortByLong(withoutProgress, ascending: ascending) { $0.createdDate }
        default:
            sortedRegular = sortByLong(regular, ascending: false) { $0.bookOrder }
        }
        return pinned + sortedRegular
    }

    private func sortByLong(
        _ books: [BookRecord],
        ascending: Bool,
        value: (BookRecord) -> Int64
    ) -> [BookRecord] {
        books.sorted {
            let left = value($0)
            let right = value($1)
            if left != right { return ascending ? left < right : left > right }
            if $0.createdDate != $1.createdDate {
                return ascending ? $0.createdDate < $1.createdDate : $0.createdDate > $1.createdDate
            }
            return ascending ? ($0.id ?? 0) < ($1.id ?? 0) : ($0.id ?? 0) > ($1.id ?? 0)
        }
    }

    private func sortByDouble(
        _ books: [BookRecord],
        ascending: Bool,
        value: (BookRecord) -> Double
    ) -> [BookRecord] {
        books.sorted {
            let left = value($0)
            let right = value($1)
            if left != right { return ascending ? left < right : left > right }
            if $0.createdDate != $1.createdDate {
                return ascending ? $0.createdDate < $1.createdDate : $0.createdDate > $1.createdDate
            }
            return ascending ? ($0.id ?? 0) < ($1.id ?? 0) : ($0.id ?? 0) > ($1.id ?? 0)
        }
    }

    private func comparableName(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).map { character in
            let isChinese = character.unicodeScalars.allSatisfy {
                (0x4E00...0x9FFF).contains(Int($0.value))
            }
            guard isChinese else { return String(character).uppercased() }
            return String(character)
                .applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)?
                .uppercased() ?? String(character).uppercased()
        }.joined()
    }

    private func safeOffset(page: Int, pageSize: Int) -> Int {
        let value = (max(1, page) - 1).multipliedReportingOverflow(by: max(1, pageSize))
        return value.overflow ? Int.max : value.partialValue
    }

    private static func totalPages(total: Int64, pageSize: Int) -> Int {
        guard total > 0 else { return 0 }
        let divisor = Int64(pageSize)
        return Int(total / divisor + (total % divisor == 0 ? 0 : 1))
    }
}

nonisolated private extension Array {
    /// 按 Android Repository 的 SQLite IN 分块上限切分书籍查询。
    func chunkedForDesktopWeb(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [self] }
        return stride(from: 0, to: count, by: maxCount).map { start in
            Array(self[start..<Swift.min(start + maxCount, count)])
        }
    }
}
