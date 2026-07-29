/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 V44 category、category_content、category_image、book、sort 表与可注入毫秒时钟
 * [OUTPUT]: 对外提供 Android RelatedService 的类别、相关内容列表、详情与排序基础能力
 * [POS]: Data 层网页相关内容专用仓储；独立复刻 Android Web 路径，不让 XMNoteWeb 接触 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// WebRelatedCategoryDto 的 Data 层投影。
nonisolated struct DesktopWebRelatedCategorySnapshot: Sendable, Equatable {
    let id: Int64
    let bookID: Int64
    let scope: String
    let title: String
    let order: Int64
    let isHidden: Bool
    let contentCount: Int
    let isSystemDefault: Bool
    let createdTime: Int64
    let updatedTime: Int64
}

/// WebBookSimpleDto 的 Data 层相关内容投影；封面代理留给 App Adapter。
nonisolated struct DesktopWebRelatedBookSnapshot: Sendable, Equatable {
    let id: Int64
    let name: String
    let cover: String
    let author: String
    let press: String
    let translator: String?
    let publicationDate: String?
    let isDeleted: Bool?
}

/// WebRelatedImageDto 的 Data 层投影。
nonisolated struct DesktopWebRelatedImageSnapshot: Sendable, Equatable {
    let id: Int64
    let url: String
    let order: Int
}

/// WebRelatedNoteDto 的 Data 层投影。
nonisolated struct DesktopWebRelatedNoteSnapshot: Sendable, Equatable {
    let id: Int64
    let bookID: Int64
    let categoryID: Int64
    let categoryTitle: String
    let title: String
    let content: String
    let url: String
    let contentBookID: Int64
    let contentBook: DesktopWebRelatedBookSnapshot?
    let images: [DesktopWebRelatedImageSnapshot]
    let createdTime: Int64
    let updatedTime: Int64
}

/// WebGlobalRelevantDto 的 Data 层投影。
nonisolated struct DesktopWebGlobalRelatedNoteSnapshot: Sendable, Equatable {
    let note: DesktopWebRelatedNoteSnapshot
    let book: DesktopWebRelatedBookSnapshot
}

/// RelatedController 的分页结果投影。
nonisolated struct DesktopWebRelatedPageSnapshot<Item: Sendable & Equatable>: Sendable, Equatable {
    let items: [Item]
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
}

/// WebRelatedSortRuleDto 的 Data 层投影。
nonisolated struct DesktopWebRelatedSortRuleSnapshot: Sendable, Equatable {
    let sortBy: String
    let sortOrder: String
}

/// Package 书内筛选到 Data 层的无框架输入。
nonisolated struct DesktopWebRelatedNoteFilterInput: Sendable, Equatable {
    let categoryID: Int64
    let keyword: String
    let sortBy: String
    let sortOrder: String
}

/// Package 全局筛选到 Data 层的无框架输入。
nonisolated struct DesktopWebGlobalRelatedNoteFilterInput: Sendable, Equatable {
    let bookID: Int64
    let categoryID: Int64
    let keyword: String
    let sortBy: String
    let sortOrder: String
    let sortMode: String
    let excludeIDs: [Int64]
}

/// Package 创建类别请求到 Data 层的无框架输入。
nonisolated struct DesktopWebRelatedCategoryCreateInput: Sendable, Equatable {
    let title: String
    let order: Int64?
    let scope: String?
}

/// Package 更新类别请求到 Data 层的无框架输入。
nonisolated struct DesktopWebRelatedCategoryUpdateInput: Sendable, Equatable {
    let title: String?
    let order: Int64?
    let scope: String?
    let bookID: Int64?
}

/// Package 创建相关内容请求到 Data 层的无框架输入。
nonisolated struct DesktopWebRelatedNoteCreateInput: Sendable, Equatable {
    let bookID: Int64
    let categoryID: Int64
    let title: String?
    let content: String?
    let url: String?
    let imageURLs: [String]?
    let uploadedTicketIDs: [String]?
    let contentBookID: Int64?
    let createdTime: Int64?
}

/// Package 更新相关内容请求到 Data 层的无框架输入。
nonisolated struct DesktopWebRelatedNoteUpdateInput: Sendable, Equatable {
    let categoryID: Int64?
    let title: String?
    let content: String?
    let url: String?
    let imageURLs: [String]?
    let uploadedTicketIDs: [String]?
    let contentBookID: Int64?
    let createdTime: Int64?
}

/// 使用独立 SQL 复刻 Android WebRelatedRepository、WebRelevantRepository、RelatedService 与 SortRepository。
nonisolated struct DesktopWebRelatedRepository: Sendable {
    static let relatedContentType: Int64 = 3
    static let ascCreated: Int64 = 1
    static let descCreated: Int64 = 2
    static let defaultCategoryTitles: Set<String> = ["书籍", "电影", "音乐", "地点", "人物", "事件"]

    let database: AppDatabase
    let currentTimeMillis: @Sendable () -> Int64
    let commitUploadedTickets: @Sendable ([String]?, [String]) throws -> Void

    /// 固定数据库、时钟与上传票据提交器；读请求由 DatabasePool 快照隔离，写入边界按 Android 逐方法保留。
    init(
        database: AppDatabase,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        commitUploadedTickets: @escaping @Sendable ([String]?, [String]) throws -> Void = { _, _ in }
    ) {
        self.database = database
        self.currentTimeMillis = currentTimeMillis
        self.commitUploadedTickets = commitUploadedTickets
    }

    /// 读取 Android queryGlobalCategories 的全部有效类别；该 SQL 未限定 book_id，故保留跨书籍结果。
    func globalCategories(includeHidden: Bool) async throws -> [DesktopWebRelatedCategorySnapshot] {
        try await database.dbPool.read { db in
            // NOTE(ANDROID-WEB-047): Android 的“全局类别”SQL 未过滤 book_id=0，会返回所有书内类别。
            // SQL 目的：复刻 WebRelatedDao.queryGlobalCategories 的类别集合。
            // 涉及表：category；无关联表。
            // 关键过滤：仅 is_deleted=0；includeHidden 在读取后按 is_hide 过滤。
            // 时间字段：created_date/updated_date 为 Android 毫秒值，原样返回。
            // 返回字段：category 完整记录，按 order 升序。
            let categories = try CategoryRecord.fetchAll(
                db,
                sql: "SELECT * FROM category WHERE is_deleted = 0 ORDER BY `order` ASC"
            ).filter { includeHidden || $0.isHide == 0 }
            return try categories.map { category in
                try categorySnapshot(db, category: category)
            }.sorted { $0.order < $1.order }
        }
    }

    /// 验证来源书籍后读取全局类别与指定 book_id 类别。
    func categories(bookID: Int64, includeHidden: Bool) async throws -> [DesktopWebRelatedCategorySnapshot] {
        try await ensureActiveBookExists(id: bookID)
        return try await database.dbPool.read { db in
            // NOTE(ANDROID-WEB-008): Android Web 只按 book_id 定位，不校验书籍 owner。
            // SQL 目的：读取指定书籍可用的全局与书内类别。
            // 涉及表：category；无书籍 JOIN。
            // 关键过滤：(book_id=0 OR book_id=?)、is_deleted=0；隐藏过滤在内存完成。
            // 时间字段：created_date/updated_date 为 Android 毫秒值，原样返回。
            // 返回字段：category 完整记录，按 order 升序。
            let records = try CategoryRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM category
                    WHERE (book_id = 0 OR book_id = ?) AND is_deleted = 0
                    ORDER BY `order` ASC
                    """,
                arguments: [bookID]
            ).filter { includeHidden || $0.isHide == 0 }
            return try records.map {
                try categorySnapshot(db, category: $0, contentBookID: bookID)
            }
                .sorted { $0.order < $1.order }
        }
    }

    /// 分页读取指定书籍内容；保持 Android 不 JOIN book/category 的可见性边界。
    func relatedNotes(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        filter: DesktopWebRelatedNoteFilterInput
    ) async throws -> DesktopWebRelatedPageSnapshot<DesktopWebRelatedNoteSnapshot> {
        try await ensureActiveBookExists(id: bookID)
        let keyword = Self.kotlinTrimmed(filter.keyword)
        let offset = Self.safeOffset(page: page, pageSize: pageSize)
        let result = try await database.dbPool.read { db -> ([CategoryContentRecord], Int) in
            let query = Self.bookRelatedQuery(
                bookID: bookID,
                categoryID: filter.categoryID,
                keyword: keyword
            )
            let order = Self.orderClause(sortBy: filter.sortBy, sortOrder: filter.sortOrder)

            // SQL 目的：分页读取指定 book_id 的有效 category_content。
            // 涉及表：category_content、来源 book、所属 category。
            // 关键过滤：内容/来源书/类别有效、类别作用域合法、精确 book_id、可选类别与关键词。
            // 时间字段：仅参与 create/update 排序，单位为 Android 毫秒值。
            // 返回字段：category_content 完整记录，LIMIT/OFFSET 应用在 DTO 聚合前。
            let items = try CategoryContentRecord.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM category_content c
                    INNER JOIN book owner_book
                        ON owner_book.id = c.book_id AND owner_book.is_deleted = 0
                    INNER JOIN category owner_category
                        ON owner_category.id = c.category_id
                        AND owner_category.is_deleted = 0
                        AND (owner_category.book_id = 0 OR owner_category.book_id = c.book_id)
                    WHERE \(query.conditions.joined(separator: " AND "))
                    \(order)
                    LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments(query.arguments + [pageSize.databaseValue, offset.databaseValue])
            )

            // SQL 目的：计算同一书内筛选条件的原始总数。
            // 涉及表：category_content；与列表查询条件完全一致。
            // 关键过滤：不受 LIMIT/OFFSET 影响。
            // 时间字段：不参与计数。
            // 返回字段：COUNT(*)。
            let total = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM category_content c
                    INNER JOIN book owner_book
                        ON owner_book.id = c.book_id AND owner_book.is_deleted = 0
                    INNER JOIN category owner_category
                        ON owner_category.id = c.category_id
                        AND owner_category.is_deleted = 0
                        AND (owner_category.book_id = 0 OR owner_category.book_id = c.book_id)
                    WHERE \(query.conditions.joined(separator: " AND "))
                    """,
                arguments: StatementArguments(query.arguments)
            ) ?? 0
            return (items, total)
        }
        let items = try await relatedNoteSnapshots(result.0, includeBookMetadata: false)
        return DesktopWebRelatedPageSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: result.1,
            totalPages: Self.totalPages(total: result.1, pageSize: pageSize)
        )
    }

    /// 不分页读取指定书籍内容，空列表仍返回正的 pageSize。
    func allRelatedNotes(
        bookID: Int64,
        filter: DesktopWebRelatedNoteFilterInput
    ) async throws -> DesktopWebRelatedPageSnapshot<DesktopWebRelatedNoteSnapshot> {
        try await ensureActiveBookExists(id: bookID)
        let keyword = Self.kotlinTrimmed(filter.keyword)
        let records = try await database.dbPool.read { db in
            let query = Self.bookRelatedQuery(
                bookID: bookID,
                categoryID: filter.categoryID,
                keyword: keyword
            )
            let order = Self.orderClause(sortBy: filter.sortBy, sortOrder: filter.sortOrder)
            // SQL 目的：不分页读取指定书籍的全部筛选结果。
            // 涉及表：category_content、来源 book、所属 category。
            // 关键过滤：内容/来源书/类别有效、类别作用域合法、精确 book_id 与可选类别/关键词。
            // 时间字段：按请求 create/update 排序，原样返回毫秒值。
            // 返回字段：category_content 完整记录。
            return try CategoryContentRecord.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM category_content c
                    INNER JOIN book owner_book
                        ON owner_book.id = c.book_id AND owner_book.is_deleted = 0
                    INNER JOIN category owner_category
                        ON owner_category.id = c.category_id
                        AND owner_category.is_deleted = 0
                        AND (owner_category.book_id = 0 OR owner_category.book_id = c.book_id)
                    WHERE \(query.conditions.joined(separator: " AND "))
                    \(order)
                    """,
                arguments: StatementArguments(query.arguments)
            )
        }
        let items = try await relatedNoteSnapshots(records, includeBookMetadata: false)
        return DesktopWebRelatedPageSnapshot(
            items: items,
            page: 1,
            pageSize: max(items.count, 1),
            total: items.count,
            totalPages: items.isEmpty ? 0 : 1
        )
    }

    /// 查询全局相关内容；items 应用 excludeIds，total 刻意不应用。
    func globalRelatedNotes(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalRelatedNoteFilterInput
    ) async throws -> DesktopWebRelatedPageSnapshot<DesktopWebGlobalRelatedNoteSnapshot> {
        let keyword = Self.kotlinTrimmed(filter.keyword)
        let excludeIDs = Self.distinct(filter.excludeIDs).filter { $0 > 0 }
        let result = try await database.dbPool.read { db -> ([CategoryContentRecord], Int) in
            var itemConditions = ["c.is_deleted = 0", "b.is_deleted = 0"]
            var itemArguments: [DatabaseValue] = []
            var countConditions = itemConditions
            var countArguments: [DatabaseValue] = []
            if !keyword.isEmpty {
                let condition = "(c.title LIKE '%' || ? || '%' OR c.content LIKE '%' || ? || '%')"
                itemConditions.append(condition)
                countConditions.append(condition)
                itemArguments.append(contentsOf: [keyword.databaseValue, keyword.databaseValue])
                countArguments.append(contentsOf: [keyword.databaseValue, keyword.databaseValue])
            }
            if filter.bookID != 0 {
                itemConditions.append("c.book_id = ?")
                countConditions.append("c.book_id = ?")
                itemArguments.append(filter.bookID.databaseValue)
                countArguments.append(filter.bookID.databaseValue)
            }
            if filter.categoryID != 0 {
                itemConditions.append("c.category_id = ?")
                countConditions.append("c.category_id = ?")
                itemArguments.append(filter.categoryID.databaseValue)
                countArguments.append(filter.categoryID.databaseValue)
            }
            if !excludeIDs.isEmpty {
                itemConditions.append(
                    "c.id NOT IN (\(Array(repeating: "?", count: excludeIDs.count).joined(separator: ",")))"
                )
                itemArguments.append(contentsOf: excludeIDs.map(\.databaseValue))
            }
            let order = filter.sortMode == "random"
                ? "ORDER BY RANDOM()"
                : Self.orderClause(sortBy: filter.sortBy, sortOrder: filter.sortOrder)
            let offset = filter.sortMode == "random" ? 0 : Self.safeOffset(page: page, pageSize: pageSize)

            // NOTE(ANDROID-WEB-008): 来源书籍只校验删除态，不校验 owner。
            // SQL 目的：查询全局有效来源书籍下的相关内容页。
            // 涉及表：category_content INNER JOIN book。
            // 关键过滤：内容/来源书有效、可选 book/category/关键词、items 独有 excludeIds。
            // 时间字段：按 create/update 排序，随机模式改用 RANDOM()。
            // 返回字段：category_content 完整记录。
            let items = try CategoryContentRecord.fetchAll(
                db,
                sql: """
                    SELECT c.* FROM category_content c
                    INNER JOIN book b ON c.book_id = b.id
                    WHERE \(itemConditions.joined(separator: " AND "))
                    \(order)
                    LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments(itemArguments + [pageSize.databaseValue, offset.databaseValue])
            )

            // SQL 目的：计算全局相关内容总数。
            // 涉及表：category_content INNER JOIN book。
            // 关键过滤：与列表相同但故意不应用 excludeIds，保持 Android 随机刷新口径。
            // 时间字段：不参与计数。
            // 返回字段：COUNT(*)。
            let total = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM category_content c
                    INNER JOIN book b ON c.book_id = b.id
                    WHERE \(countConditions.joined(separator: " AND "))
                    """,
                arguments: StatementArguments(countArguments)
            ) ?? 0
            return (items, total)
        }
        let localItems = try await relatedNoteSnapshots(result.0, includeBookMetadata: true)
        let sourceBooks = try await booksByIDs(
            localItems.map(\.bookID),
            includeDeleted: false,
            includeMetadata: true
        )
        let items = localItems.compactMap { note -> DesktopWebGlobalRelatedNoteSnapshot? in
            guard let book = sourceBooks[note.bookID] else { return nil }
            return DesktopWebGlobalRelatedNoteSnapshot(note: note, book: book)
        }
        return DesktopWebRelatedPageSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: result.1,
            totalPages: Self.totalPages(total: result.1, pageSize: pageSize)
        )
    }

    /// 按 ID 读取来源书籍、类别及关联书籍均有效的内容。
    func relatedNote(id: Int64) async throws -> DesktopWebRelatedNoteSnapshot {
        let record = try await activeRelatedNote(id: id)
        return try await relatedNoteSnapshots([record], includeBookMetadata: false)[0]
    }

    /// 读取相关内容排序；缺失时沿用 Android 的创建时间升序默认值。
    func sortRule(bookID: Int64) async throws -> DesktopWebRelatedSortRuleSnapshot {
        let order = try await database.dbPool.read { db -> Int64? in
            // SQL 目的：读取指定书籍的相关内容排序设置。
            // 涉及表：sort；不关联 book。
            // 关键过滤：book_id、type=3、is_deleted=0。
            // 时间字段：不参与读取。
            // 返回字段：order 排序枚举。
            try Int64.fetchOne(
                db,
                sql: "SELECT `order` FROM sort WHERE book_id = ? AND type = ? AND is_deleted = 0",
                arguments: [bookID, Self.relatedContentType]
            )
        }
        return DesktopWebRelatedSortRuleSnapshot(
            sortBy: "create_time",
            sortOrder: order == Self.descCreated ? "desc" : "asc"
        )
    }
}

nonisolated extension DesktopWebRelatedRepository {
    /// 把查询记录补齐类别、内容书籍和图片；调用任务取消时只终止未开始的只读快照。
    func relatedNoteSnapshots(
        _ records: [CategoryContentRecord],
        includeBookMetadata: Bool
    ) async throws -> [DesktopWebRelatedNoteSnapshot] {
        guard !records.isEmpty else { return [] }
        return try await database.dbPool.read { db in
            // SQL 目的：为响应补齐当前有效类别标题。
            // 涉及表：category。
            // 关键过滤：is_deleted=0；缺失类别在 DTO 中回退空标题。
            // 时间字段：不参与查询。
            // 返回字段：category 完整记录。
            let categories = try CategoryRecord.fetchAll(
                db,
                sql: "SELECT * FROM category WHERE is_deleted = 0"
            ).reduce(into: [Int64: CategoryRecord]()) { result, category in
                if let id = category.id { result[id] = category }
            }
            let contentBookIDs = Self.distinct(records.map(\.contentBookId)).filter { $0 > 0 }
            let books = try Self.fetchBooks(
                db,
                ids: contentBookIDs,
                includeDeleted: true,
                includeMetadata: includeBookMetadata
            )
            let images = try Self.fetchImages(db, contentIDs: records.compactMap(\.id))
            return records.compactMap { record in
                guard let id = record.id else { return nil }
                return DesktopWebRelatedNoteSnapshot(
                    id: id,
                    bookID: record.bookId,
                    categoryID: record.categoryId,
                    categoryTitle: categories[record.categoryId]?.title ?? "",
                    title: record.title ?? "",
                    content: record.content ?? "",
                    url: record.url ?? "",
                    contentBookID: record.contentBookId,
                    contentBook: books[record.contentBookId],
                    images: images[id] ?? [],
                    createdTime: record.createdDate,
                    updatedTime: record.updatedDate
                )
            }
        }
    }

    /// 读取指定书籍投影；includeDeleted 控制 tombstone，includeMetadata 控制 Android 可选字段是否出现。
    func booksByIDs(
        _ ids: [Int64],
        includeDeleted: Bool,
        includeMetadata: Bool
    ) async throws -> [Int64: DesktopWebRelatedBookSnapshot] {
        try await database.dbPool.read { db in
            try Self.fetchBooks(
                db,
                ids: ids,
                includeDeleted: includeDeleted,
                includeMetadata: includeMetadata
            )
        }
    }

    /// 读取有效相关内容并验证来源书籍、类别作用域与关联书籍。
    func activeRelatedNote(id: Int64) async throws -> CategoryContentRecord {
        let record = try await database.dbPool.read { db in
            // SQL 目的：按主键读取有效相关内容。
            // 涉及表：category_content；不关联 book/category。
            // 关键过滤：id、is_deleted=0。
            // 时间字段：原样读取。
            // 返回字段：category_content 完整记录。
            try CategoryContentRecord.fetchOne(
                db,
                sql: "SELECT * FROM category_content WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            )
        }
        guard let record else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("笔记不存在: \(id)")
        }
        try await ensureActiveBookExists(id: record.bookId)
        guard let category = try? await activeCategory(id: record.categoryId) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("笔记类别不存在: \(record.categoryId)")
        }
        guard category.bookId == 0 || category.bookId == record.bookId else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("笔记类别不属于当前书籍")
        }
        if record.contentBookId > 0 {
            try await ensureContentBookExists(id: record.contentBookId)
        }
        return record
    }

    /// 验证来源书籍有效且不是占位记录。
    func ensureActiveBookExists(id: Int64) async throws {
        let exists = try await database.dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book WHERE id = ? AND id != 0 AND is_deleted = 0",
                arguments: [id]
            ) ?? 0
        }
        guard exists > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("书籍不存在: \(id)")
        }
    }

    /// 读取有效类别，否则返回 Android 业务错误。
    func activeCategory(id: Int64) async throws -> CategoryRecord {
        let record = try await database.dbPool.read { db in
            // SQL 目的：按主键读取有效相关类别。
            // 涉及表：category。
            // 关键过滤：id、is_deleted=0。
            // 时间字段：原样读取。
            // 返回字段：category 完整记录。
            try CategoryRecord.fetchOne(
                db,
                sql: "SELECT * FROM category WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            )
        }
        guard let record else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别不存在: \(id)")
        }
        return record
    }

    /// 计算类别响应；书内列表固定按请求书籍计数，类别管理页才按类别自身作用域计数。
    func categorySnapshot(
        _ db: Database,
        category: CategoryRecord,
        contentBookID: Int64? = nil
    ) throws -> DesktopWebRelatedCategorySnapshot {
        guard let id = category.id else {
            throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("类别编号无效")
        }
        let count: Int
        if let contentBookID {
            // SQL 目的：复刻 getRelatedCategories 对全局与书内类别统一限定当前请求书籍的计数。
            // 涉及表：category_content。
            // 关键过滤：请求 book_id、category_id、is_deleted=0，不使用 category.book_id 决定范围。
            // 时间字段：不参与计数。
            // 返回字段：COUNT(*)。
            count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM category_content
                    WHERE book_id = ? AND category_id = ? AND is_deleted = 0
                    """,
                arguments: [contentBookID, id]
            ) ?? 0
        } else if category.bookId == 0 {
            // SQL 目的：统计全局类别在所有书籍中的有效内容数。
            // 涉及表：category_content。
            // 关键过滤：category_id、is_deleted=0，不过滤 book_id。
            // 时间字段：不参与计数。
            // 返回字段：COUNT(*)。
            count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM category_content WHERE category_id = ? AND is_deleted = 0",
                arguments: [id]
            ) ?? 0
        } else {
            // SQL 目的：统计书内类别在其声明书籍中的有效内容数。
            // 涉及表：category_content。
            // 关键过滤：book_id、category_id、is_deleted=0。
            // 时间字段：不参与计数。
            // 返回字段：COUNT(*)。
            count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM category_content
                    WHERE book_id = ? AND category_id = ? AND is_deleted = 0
                    """,
                arguments: [category.bookId, id]
            ) ?? 0
        }
        let title = category.title ?? ""
        return DesktopWebRelatedCategorySnapshot(
            id: id,
            bookID: category.bookId,
            scope: category.bookId == 0 ? "global" : "book",
            title: title,
            order: category.order,
            isHidden: category.isHide == 1,
            contentCount: count,
            isSystemDefault: Self.defaultCategoryTitles.contains(title),
            createdTime: category.createdDate,
            updatedTime: category.updatedDate
        )
    }
}

nonisolated extension DesktopWebRelatedRepository {
    static func bookRelatedQuery(
        bookID: Int64,
        categoryID: Int64,
        keyword: String
    ) -> (conditions: [String], arguments: [DatabaseValue]) {
        var conditions = ["c.is_deleted = 0", "c.book_id = ?"]
        var arguments = [bookID.databaseValue]
        if categoryID > 0 {
            conditions.append("c.category_id = ?")
            arguments.append(categoryID.databaseValue)
        }
        if !keyword.isEmpty {
            conditions.append("(c.title LIKE '%' || ? || '%' OR c.content LIKE '%' || ? || '%')")
            arguments.append(contentsOf: [keyword.databaseValue, keyword.databaseValue])
        }
        return (conditions, arguments)
    }

    static func orderClause(sortBy: String, sortOrder: String) -> String {
        let direction = sortOrder == "asc" ? "ASC" : "DESC"
        let column: String
        switch sortBy {
        case "update_time":
            column = "c.updated_date"
        case "title":
            column = "c.title COLLATE NOCASE"
        default:
            column = "c.id"
        }
        return "ORDER BY \(column) \(direction)"
    }

    static func fetchBooks(
        _ db: Database,
        ids: [Int64],
        includeDeleted: Bool,
        includeMetadata: Bool
    ) throws -> [Int64: DesktopWebRelatedBookSnapshot] {
        let ids = distinct(ids).filter { $0 > 0 }
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let deletionFilter = includeDeleted ? "" : " AND is_deleted = 0"
        // SQL 目的：批量读取来源或内容书籍投影。
        // 涉及表：book。
        // 关键过滤：id IN；来源书模式追加 is_deleted=0，内容书模式包含 tombstone。
        // 时间字段：不参与查询。
        // 返回字段：WebBookSimpleDto 所需书籍字段。
        return try BookRecord.fetchAll(
            db,
            sql: "SELECT * FROM book WHERE id IN (\(placeholders))\(deletionFilter)",
            arguments: StatementArguments(ids)
        ).reduce(into: [Int64: DesktopWebRelatedBookSnapshot]()) { result, book in
            guard let id = book.id else { return }
            result[id] = DesktopWebRelatedBookSnapshot(
                id: id,
                name: book.name,
                cover: book.cover,
                author: book.author,
                press: book.press,
                translator: includeMetadata ? book.translator : nil,
                publicationDate: includeMetadata ? book.pubDate : nil,
                isDeleted: includeMetadata ? book.isDeleted == 1 : nil
            )
        }
    }

    static func fetchImages(
        _ db: Database,
        contentIDs: [Int64]
    ) throws -> [Int64: [DesktopWebRelatedImageSnapshot]] {
        let ids = distinct(contentIDs).filter { $0 > 0 }
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        // SQL 目的：批量补齐相关内容的有效图片。
        // 涉及表：category_image。
        // 关键过滤：category_content_id IN、is_deleted=0。
        // 时间字段：不参与查询。
        // 返回字段：图片主键、URL 与 order，按 order 升序。
        return try CategoryImageRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM category_image
                WHERE is_deleted = 0 AND category_content_id IN (\(placeholders))
                ORDER BY `order` ASC
                """,
            arguments: StatementArguments(ids)
        ).reduce(into: [Int64: [DesktopWebRelatedImageSnapshot]]()) { result, image in
            guard let id = image.id else { return }
            result[image.categoryContentId, default: []].append(
                DesktopWebRelatedImageSnapshot(
                    id: id,
                    url: image.image,
                    order: Int(truncatingIfNeeded: image.order)
                )
            )
        }
    }

    static func safeOffset(page: Int, pageSize: Int) -> Int {
        let result = (max(page, 1) - 1).multipliedReportingOverflow(by: max(pageSize, 1))
        return result.overflow ? Int.max : result.partialValue
    }

    static func totalPages(total: Int, pageSize: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int(ceil(Double(total) / Double(pageSize)))
    }

    static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func kotlinTrimmed(_ value: String) -> String {
        let scalars = value.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, scalars[start].value <= 0x20 {
            start = scalars.index(after: start)
        }
        while start < end {
            let previous = scalars.index(before: end)
            guard scalars[previous].value <= 0x20 else { break }
            end = previous
        }
        return String(scalars[start..<end])
    }

    static func isKotlinBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value <= 0x20 || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}
