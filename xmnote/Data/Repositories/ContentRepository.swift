import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库连接，依赖 UserDefaults 承接编辑自动草稿，依赖 ObservationStream 与通用内容领域模型完成跨层映射
 * [OUTPUT]: 对外提供 ContentRepository（ContentRepositoryProtocol 的 GRDB/UserDefaults 实现），包含相关书籍编辑与单书内容排序读写
 * [POS]: Data 层通用内容仓储实现，统一封装查看、编辑自动草稿、持久化排序与原子保存事务，并对齐 Android 的相关书籍固定分类语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 通用内容查看仓储实现，负责 viewer feed、详情读取、编辑保存与 Android 对齐的软删除事务。
struct ContentRepository: ContentRepositoryProtocol {
    private nonisolated static let relatedBookCategoryID: Int64 = 1

    private let databaseManager: DatabaseManager
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Int64

    /// 注入数据库与草稿存储，供内容查看、编辑恢复及最终保存复用同一仓储边界。
    init(
        databaseManager: DatabaseManager,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.databaseManager = databaseManager
        self.userDefaults = userDefaults
        self.now = now
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
            case .noteReviewDirectory:
                // Resolve a bounded directory page before observing business metadata.
                throw NoteReviewDirectoryError.unavailable
            case .noteExcerpts(let scope, let query, let sort, let randomSeed):
                try fetchNoteExcerptViewerItems(
                    db,
                    scope: scope,
                    query: query,
                    sort: sort,
                    randomSeed: randomSeed
                )
            case .chapterNotes(
                let bookID,
                let chapterID,
                let includeDescendants,
                let query,
                let sort,
                let randomSeed
            ):
                try fetchChapterNoteViewerItems(
                    db,
                    bookID: bookID,
                    chapterID: chapterID,
                    includeDescendants: includeDescendants,
                    query: query,
                    sort: sort,
                    randomSeed: randomSeed
                )
            case .relatedCategory(let scope, let query, let sort, let randomSeed):
                try fetchRelatedCategoryViewerItems(
                    db,
                    scope: scope,
                    query: query,
                    sort: sort,
                    randomSeed: randomSeed
                )
            case .allReviews(let query, let sort):
                try fetchAllReviewViewerItems(db, query: query, sort: sort)
            case .bookReviews(let bookId):
                try fetchBookReviewViewerItems(db, bookID: bookId)
            case .bookRelated(let bookId):
                try fetchBookRelevantViewerItems(db, bookID: bookId)
            }
        }
    }

    /// 持续监听指定书籍的书评、相关分区与新建分类候选；任一关联表变化都会重新发出完整快照。
    func observeBookContentWorkspace(bookID: Int64) -> AsyncThrowingStream<BookContentWorkspaceSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookContentWorkspace(db, bookID: bookID)
        }
    }

    /// 在一个数据库事务内插入或更新 `(book_id, type)` 排序偏好；写入后相关观察流自动重排。
    func updateBookContentSortRule(
        bookID: Int64,
        type: BookContentSortType,
        rule: BookContentSortRule
    ) async throws {
        guard bookID > 0 else { throw ContentRepositoryError.invalidBook }
        guard BookContentSortQuery.isRuleAllowed(rule, for: type) else {
            throw ContentRepositoryError.invalidContentSortRule
        }
        let now = now()
        try await databaseManager.database.dbPool.write { db in
                // SQL 目的：确认排序偏好的所属书仍是有效书架书，避免为占位书或失效主键制造孤立设置。
                // 涉及表：book。
                // 关键过滤：主键精确匹配、排除系统根书且 is_deleted=0。
                // 时间字段：不读取时间字段。
                // 返回字段用途：排序写入前的外键与业务有效性门闩。
                let bookSQL = """
                    SELECT id
                    FROM book
                    WHERE id = ? AND id != 0 AND is_deleted = 0
                    LIMIT 1
                    """
                guard try Int64.fetchOne(db, sql: bookSQL, arguments: [bookID]) != nil else {
                    throw ContentRepositoryError.bookNotFound
                }

                // SQL 目的：判断当前 `(book_id, type)` 是否已经存在有效排序记录。
                // 涉及表：sort。
                // 关键过滤：书籍与内容类型精确匹配且 is_deleted=0；兼容旧库可能存在的重复有效记录。
                // 时间字段：不读取时间字段。
                // 返回字段用途：选择插入新 Record 或更新全部有效历史重复项。
                let countSQL = """
                    SELECT COUNT(*)
                    FROM sort
                    WHERE book_id = ? AND type = ? AND is_deleted = 0
                    """
                let existingCount = try Int.fetchOne(
                    db,
                    sql: countSQL,
                    arguments: [bookID, type.rawValue]
                ) ?? 0

                if existingCount == 0 {
                    var record = SortRecord(
                        id: nil,
                        bookId: bookID,
                        type: type.rawValue,
                        order: rule.rawValue,
                        createdDate: now,
                        updatedDate: now,
                        lastSyncDate: 0,
                        isDeleted: 0
                    )
                    try record.insert(db)
                } else {
                    // SQL 目的：原子更新同书同类型的全部有效排序记录，复刻 Android DAO 的条件 UPDATE 语义。
                    // 涉及表：sort。
                    // 关键过滤：book_id/type 精确匹配且 is_deleted=0，不复活历史删除记录。
                    // 时间字段：updated_date 写入 Android 毫秒时间戳；created_date/last_sync_date 保持原值。
                    // 副作用：更新 order 并触发书摘、相关、书评观察流刷新顺序。
                    let updateSQL = """
                        UPDATE sort
                        SET "order" = ?, updated_date = ?
                        WHERE book_id = ? AND type = ? AND is_deleted = 0
                        """
                    try db.execute(
                        sql: updateSQL,
                        arguments: [rule.rawValue, now, bookID, type.rawValue]
                    )
                }
        }
    }

    /// 在系统“书籍”分类下建立本地书籍关系；事务内校验来源、目标、分类与重复关系。
    func addRelatedBook(sourceBookID: Int64, relatedBookID: Int64) async throws {
        guard sourceBookID > 0, relatedBookID > 0 else { throw ContentRepositoryError.invalidBook }
        guard sourceBookID != relatedBookID else { throw ContentRepositoryError.selfRelatedBook }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
                // SQL 目的：确认来源书和目标书都是当前书架中的有效本地书。
                // 涉及表：book。
                // 关键过滤：限定两个主键、排除系统根书与 is_deleted 非零占位书。
                // 时间字段：不读取时间字段。
                // 返回字段用途：写入前存在性门闩，必须同时命中两本不同书。
                let bookCountSQL = """
                    SELECT COUNT(*)
                    FROM book
                    WHERE id IN (?, ?) AND id != 0 AND is_deleted = 0
                    """
                let bookCount = try Int.fetchOne(
                    db,
                    sql: bookCountSQL,
                    arguments: [sourceBookID, relatedBookID]
                ) ?? 0
                guard bookCount == 2 else { throw ContentRepositoryError.bookNotFound }

                // SQL 目的：确认 Android 固定主键的系统“书籍”分类仍可承载相关书籍关系。
                // 涉及表：category。
                // 关键过滤：id=1、book_id=0 且分类有效；隐藏状态不影响既有关系写入语义。
                // 时间字段：不读取时间字段。
                // 返回字段用途：取得受保护 category.id 作为新关系外键。
                let categorySQL = """
                    SELECT id
                    FROM category
                    WHERE id = ? AND book_id = 0 AND is_deleted = 0
                    LIMIT 1
                    """
                guard try Int64.fetchOne(
                    db,
                    sql: categorySQL,
                    arguments: [Self.relatedBookCategoryID]
                ) != nil else {
                    throw ContentRepositoryError.relatedBookCategoryUnavailable
                }

                // SQL 目的：阻止同一来源书重复添加同一本相关书籍。
                // 涉及表：category_content。
                // 关键过滤：book_id/content_book_id 精确匹配且关系有效。
                // 时间字段：不读取时间字段。
                // 返回字段用途：重复写入门闩。
                let duplicateSQL = """
                    SELECT id
                    FROM category_content
                    WHERE book_id = ? AND content_book_id = ? AND is_deleted = 0
                    LIMIT 1
                    """
                guard try Int64.fetchOne(
                    db,
                    sql: duplicateSQL,
                    arguments: [sourceBookID, relatedBookID]
                ) == nil else {
                    throw ContentRepositoryError.relatedBookAlreadyExists
                }

                try db.execute(
                    // SQL 目的：为两本有效本地书建立物理相关关系。
                    // 涉及表：category_content。
                    // 关键字段：category_id 固定为系统“书籍”分类；book_id 为来源书；content_book_id 为目标书；文本字段保持空值。
                    // 时间字段：created_date 使用当前本地毫秒时间戳，updated_date/last_sync_date 初始为 0。
                    // 副作用：插入 is_deleted=0 的有效关系，后续由观察流实时刷新工作区。
                    sql: """
                        INSERT INTO category_content (
                            category_id, book_id, title, content, content_book_id, url,
                            created_date, updated_date, last_sync_date, is_deleted
                        ) VALUES (?, ?, '', '', ?, '', ?, 0, 0, 0)
                        """,
                    arguments: [Self.relatedBookCategoryID, sourceBookID, relatedBookID, now]
                )
        }
    }

    /// 保存在线相关书候选为引用占位书，并在同一事务建立系统“书籍”分类关系。
    func addRelatedBookPlaceholder(sourceBookID: Int64, seed: BookEditorSeed) async throws {
        guard sourceBookID > 0 else { throw ContentRepositoryError.invalidBook }
        let title = seed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ContentRepositoryError.invalidBook }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
                try ensureWritableBook(db, bookID: sourceBookID)
                let relatedBookID = try resolveOrInsertRelatedPlaceholder(
                    db,
                    seed: seed,
                    normalizedTitle: title,
                    now: now
                )
                guard relatedBookID != sourceBookID else { throw ContentRepositoryError.selfRelatedBook }

                // SQL 目的：确认系统“书籍”分类可用于在线候选关系。
                // 涉及表：category。
                // 关键过滤：固定主键、book_id=0、记录有效。
                // 时间字段：不读取时间字段。
                // 返回字段用途：写入 category_content 前的受保护外键门闩。
                let categorySQL = """
                    SELECT id FROM category
                    WHERE id = ? AND book_id = 0 AND is_deleted = 0
                    LIMIT 1
                    """
                guard try Int64.fetchOne(
                    db,
                    sql: categorySQL,
                    arguments: [Self.relatedBookCategoryID]
                ) != nil else {
                    throw ContentRepositoryError.relatedBookCategoryUnavailable
                }

                // SQL 目的：阻止同一来源书重复引用同一有效书或占位书。
                // 涉及表：category_content。
                // 关键过滤：book_id/content_book_id 精确匹配且关系有效。
                // 时间字段：不读取时间字段。
                // 返回字段用途：重复关系门闩。
                let duplicateSQL = """
                    SELECT id FROM category_content
                    WHERE book_id = ? AND content_book_id = ? AND is_deleted = 0
                    LIMIT 1
                    """
                guard try Int64.fetchOne(
                    db,
                    sql: duplicateSQL,
                    arguments: [sourceBookID, relatedBookID]
                ) == nil else {
                    throw ContentRepositoryError.relatedBookAlreadyExists
                }
                try db.execute(
                    // SQL 目的：建立来源书到在线候选占位书的相关关系。
                    // 涉及表：category_content。
                    // 关键字段：category_id 为系统“书籍”分类，content_book_id 指向有效书或 is_deleted=1 占位书。
                    // 时间字段：created_date 使用当前本地毫秒时间戳，其余同步时间初始为 0。
                    // 副作用：只创建关系，不把占位书改为有效书架书。
                    sql: """
                        INSERT INTO category_content (
                            category_id, book_id, title, content, content_book_id, url,
                            created_date, updated_date, last_sync_date, is_deleted
                        ) VALUES (?, ?, '', '', ?, '', ?, 0, 0, 0)
                        """,
                    arguments: [Self.relatedBookCategoryID, sourceBookID, relatedBookID, now]
                )
        }
    }

    /// 将仍被相关关系引用的占位书恢复到默认书架末尾，并补齐阅读状态历史。
    func restoreRelatedBookPlaceholder(bookID: Int64) async throws {
        guard bookID > 0 else { throw ContentRepositoryError.bookNotFound }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
                // SQL 目的：确认目标仍是被相关关系引用的业务占位书。
                // 涉及表：book、category_content。
                // 关键过滤：book.id 精确命中、is_deleted=1，且至少存在一个物理 content_book_id 引用。
                // 时间字段：不读取时间字段。
                // 返回字段用途：恢复写入门闩。
                let placeholderSQL = """
                    SELECT b.id
                    FROM book b
                    WHERE b.id = ? AND b.id != 0 AND b.is_deleted = 1
                      AND EXISTS (
                          SELECT 1 FROM category_content cc
                          WHERE cc.content_book_id = b.id
                      )
                    LIMIT 1
                    """
                guard try Int64.fetchOne(db, sql: placeholderSQL, arguments: [bookID]) != nil else {
                    throw ContentRepositoryError.bookNotFound
                }
                // SQL 目的：计算默认书架当前最大书籍顺序。
                // 涉及表：book。
                // 关键过滤：只统计有效非根书籍。
                // 时间字段：不读取时间字段。
                // 返回字段用途：恢复书籍追加到默认书架末尾。
                let maxOrderSQL = "SELECT COALESCE(MAX(book_order), -1) FROM book WHERE id != 0 AND is_deleted = 0"
                let nextOrder = (try Int64.fetchOne(db, sql: maxOrderSQL) ?? -1) + 1
                try db.execute(
                    // SQL 目的：把相关占位书恢复为有效书架书。
                    // 涉及表：book。
                    // 关键过滤：id 精确命中且 is_deleted=1。
                    // 时间字段：阅读状态、购买与更新时间写当前毫秒。
                    // 副作用：is_deleted=0 后可进入书架、详情与编辑链路，原相关关系保持不变。
                    sql: """
                        UPDATE book
                        SET is_deleted = 0,
                            book_order = ?,
                            read_status_id = ?,
                            read_status_changed_date = ?,
                            purchase_date = ?,
                            updated_date = ?
                        WHERE id = ? AND is_deleted = 1 AND id != 0
                        """,
                    arguments: [
                        nextOrder,
                        BookEntryReadingStatus.reading.rawValue,
                        now,
                        now,
                        now,
                        bookID
                    ]
                )
                guard db.changesCount > 0 else { throw ContentRepositoryError.bookNotFound }
                try BookReadStatusMutation.updateBookReadStatus(
                    db,
                    bookID: bookID,
                    statusID: BookEntryReadingStatus.reading.rawValue,
                    changedAt: now,
                    updatedAt: now,
                    finishedRatingScore: nil
                )
        }
    }

    /// 新建当前书私有或全部书共享分类；标题按 Android 十字符限制规范化。
    func createBookRelatedCategory(
        bookID: Int64,
        title: String,
        scope: BookContentCategoryScope
    ) async throws {
        let normalizedTitle = try Self.validatedCategoryTitle(title)
        guard bookID > 0 else { throw ContentRepositoryError.invalidBook }
        let ownerBookID: Int64 = scope == .allBooks ? 0 : bookID
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
                try ensureWritableBook(db, bookID: bookID)
                try ensureUniqueCategoryTitle(
                    db,
                    ownerBookID: ownerBookID,
                    title: normalizedTitle,
                    excludingID: nil
                )

                // SQL 目的：计算书内新分类默认顺序，使其位于当前可见全局/私有分类末尾。
                // 涉及表：category。
                // 关键过滤：只统计有效的全局分类与当前书籍私有分类。
                // 时间字段：不读取时间字段。
                // 返回字段用途：新分类 order=最大值+1。
                let nextOrderSQL = """
                    SELECT COALESCE(MAX("order"), -1) + 1
                    FROM category
                    WHERE is_deleted = 0 AND (book_id = 0 OR book_id = ?)
                    """
                let nextOrder = try Int64.fetchOne(db, sql: nextOrderSQL, arguments: [bookID]) ?? 0
                try db.execute(
                    // SQL 目的：插入当前书私有或全部书共享的自定义相关分类。
                    // 涉及表：category。
                    // 关键字段：book_id 按 scope 写当前书或 0，is_hide=0，order 追加到当前管理列表末尾。
                    // 时间字段：created_date 使用当前本地毫秒时间戳，updated_date/last_sync_date 初始为 0。
                    // 副作用：插入 is_deleted=0 分类，不创建空内容关系。
                    sql: """
                        INSERT INTO category (
                            book_id, title, "order", is_hide,
                            created_date, updated_date, last_sync_date, is_deleted
                        ) VALUES (?, ?, ?, 0, ?, 0, 0, 0)
                        """,
                    arguments: [ownerBookID, normalizedTitle, nextOrder, now]
                )
        }
    }

    /// 重命名当前书可管理的私有或全局自定义分类；六个固定种子分类不可修改。
    func renameBookRelatedCategory(bookID: Int64, categoryID: Int64, title: String) async throws {
        let normalizedTitle = try Self.validatedCategoryTitle(title)
        guard bookID > 0, categoryID > 0 else { throw ContentRepositoryError.categoryNotFound }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
                let ownerBookID = try manageableCategoryOwner(
                    db,
                    bookID: bookID,
                    categoryID: categoryID
                )
                try ensureUniqueCategoryTitle(
                    db,
                    ownerBookID: ownerBookID,
                    title: normalizedTitle,
                    excludingID: categoryID
                )
                try db.execute(
                    // SQL 目的：更新当前书可管理的私有或全局自定义分类标题。
                    // 涉及表：category。
                    // 关键过滤：主键和已校验 ownerBookID 同时命中且分类有效；固定默认种子已在前置门闩排除。
                    // 时间字段：updated_date 使用当前本地毫秒时间戳。
                    // 副作用：只修改标题与更新时间，保留内容、顺序和同步字段。
                    sql: """
                        UPDATE category
                        SET title = ?, updated_date = ?
                        WHERE id = ? AND book_id = ? AND is_deleted = 0
                        """,
                    arguments: [normalizedTitle, now, categoryID, ownerBookID]
                )
                guard db.changesCount > 0 else { throw ContentRepositoryError.categoryNotFound }
        }
    }

    /// 软删除当前书可管理的私有或全局自定义分类，并同步软删除所有书中的子内容。
    func deleteBookRelatedCategory(bookID: Int64, categoryID: Int64) async throws {
        guard bookID > 0, categoryID > 0 else { throw ContentRepositoryError.categoryNotFound }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
                _ = try manageableCategoryOwner(db, bookID: bookID, categoryID: categoryID)
                try db.execute(
                    // SQL 目的：软删除分类内有效相关内容的附图，对齐 Android CategoryImageDao。
                    // 涉及表：category_image，子查询 category_content。
                    // 关键过滤：子查询按 category_id 精确限定有效关系，附图本身也必须有效。
                    // 时间字段：updated_date 写当前 Unix 毫秒时间戳。
                    // 副作用：附图不再出现于有效查询，并保留可同步 tombstone。
                    sql: """
                        UPDATE category_image
                        SET updated_date = ?, is_deleted = 1
                        WHERE category_content_id IN (
                            SELECT id FROM category_content
                            WHERE category_id = ? AND is_deleted = 0
                        )
                          AND is_deleted = 0
                        """,
                    arguments: [now, categoryID]
                )
                try db.execute(
                    // SQL 目的：软删除自定义分类下的全部有效内容与相关书籍关系。
                    // 涉及表：category_content。
                    // 关键过滤：category_id 精确命中且 is_deleted = 0。
                    // 时间字段：updated_date 写当前 Unix 毫秒时间戳。
                    // 副作用：内容不再出现于有效查询，并保留可同步 tombstone。
                    sql: "UPDATE category_content SET updated_date = ?, is_deleted = 1 WHERE category_id = ? AND is_deleted = 0",
                    arguments: [now, categoryID]
                )
                try db.execute(
                    // SQL 目的：软删除已清空的私有或全局自定义分类主记录。
                    // 涉及表：category。
                    // 关键过滤：主键已通过可管理 owner 与固定种子保护门闩，只处理有效记录。
                    // 时间字段：updated_date 写当前 Unix 毫秒时间戳。
                    // 副作用：分类不再出现于有效查询，同时保留同步墓碑。
                    sql: "UPDATE category SET updated_date = ?, is_deleted = 1 WHERE id = ? AND is_deleted = 0",
                    arguments: [now, categoryID]
                )
                guard db.changesCount > 0 else { throw ContentRepositoryError.categoryNotFound }
        }
    }

    /// 切换固定默认分类隐藏状态；只允许 Android 六个种子分类，设置会跨书生效。
    func setDefaultBookRelatedCategoryHidden(categoryID: Int64, isHidden: Bool) async throws {
        guard categoryID >= 1, categoryID <= Self.defaultCategoryUpperBound else {
            throw ContentRepositoryError.categoryNotFound
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
            try db.execute(
                // SQL 目的：更新固定默认相关分类的隐藏状态。
                // 涉及表：category。
                // 关键过滤：主键限定 1...6、book_id=0 且记录有效，防止自定义分类误入。
                // 时间字段：updated_date 使用当前本地毫秒时间戳。
                // 副作用：is_hide 设置跨所有书生效；分类及其内容仍物理保留。
                sql: """
                    UPDATE category
                    SET is_hide = ?, updated_date = ?
                    WHERE id = ? AND id BETWEEN 1 AND ? AND book_id = 0 AND is_deleted = 0
                    """,
                arguments: [isHidden ? 1 : 0, now, categoryID, Self.defaultCategoryUpperBound]
            )
            guard db.changesCount > 0 else { throw ContentRepositoryError.categoryNotFound }
        }
    }

    /// 更新当前书管理列表最终顺序；全局分类 order 的变化会在所有书中复用。
    func updateBookRelatedCategoryOrder(bookID: Int64, categoryIDs: [Int64]) async throws {
        guard bookID > 0 else { throw ContentRepositoryError.invalidBook }
        let orderedIDs = Self.uniquePositiveIDs(categoryIDs)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        try await databaseManager.database.dbPool.write { db in
                // SQL 目的：读取当前书管理页全部有效分类主键，校验排序请求没有遗漏或越权 ID。
                // 涉及表：category。
                // 关键过滤：分类为全局或属于当前书籍且记录有效，隐藏分类同样保留在管理顺序中。
                // 排序：当前 order/id 只用于稳定错误诊断，最终顺序由调用参数决定。
                // 时间字段：不读取时间字段。
                // 返回字段用途：与 orderedIDs 做完整集合一致性校验。
                let currentSQL = """
                    SELECT id FROM category
                    WHERE (book_id = 0 OR book_id = ?) AND is_deleted = 0
                    ORDER BY "order" ASC, id ASC
                    """
                let currentIDs = try Int64.fetchAll(db, sql: currentSQL, arguments: [bookID])
                guard Set(currentIDs) == Set(orderedIDs), currentIDs.count == orderedIDs.count else {
                    throw ContentRepositoryError.invalidCategoryOrder
                }

                for (offset, categoryID) in orderedIDs.enumerated() {
                    try db.execute(
                        // SQL 目的：按最终拖动顺序写入单个当前管理列表分类 order。
                        // 涉及表：category。
                        // 关键过滤：id 必须已通过完整管理集合校验且分类有效。
                        // 时间字段：updated_date 统一使用本次事务毫秒时间戳。
                        // 副作用：仅更新 order 与 updated_date；手动排序成功由界面位置变化表达。
                        sql: """
                            UPDATE category
                            SET "order" = ?, updated_date = ?
                            WHERE id = ? AND is_deleted = 0
                            """,
                        arguments: [Int64(offset), now, categoryID]
                    )
                    guard db.changesCount > 0 else { throw ContentRepositoryError.invalidCategoryOrder }
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

    /// 按书评主键读取已有编辑草稿，供编辑态恢复正文与图片。
    func fetchReviewEditorDraft(reviewId: Int64) async throws -> ReviewEditorDraft? {
        try await databaseManager.database.dbPool.read { db in
            guard let detail = try fetchReviewDetail(db, reviewId: reviewId) else { return nil }
            return ReviewEditorDraft(
                reviewId: detail.reviewId,
                sourceBookId: detail.sourceBookId,
                bookTitle: detail.bookTitle,
                title: detail.title,
                contentHTML: detail.contentHTML,
                imageItems: detail.imageURLs.enumerated().map { index, remoteURL in
                    .existing(id: "review-\(detail.reviewId)-image-\(index)", remoteURL: remoteURL)
                }
            )
        }
    }

    /// 按新建/编辑模式生成书评草稿；新建态只读取有效所属书籍，不提前写库。
    func fetchReviewEditorDraft(mode: ReviewEditorMode) async throws -> ReviewEditorDraft? {
        switch mode {
        case .edit(let reviewID):
            return try await fetchReviewEditorDraft(reviewId: reviewID)
        case .create(let bookID):
            guard bookID > 0 else { throw ContentRepositoryError.invalidBook }
            return try await databaseManager.database.dbPool.read { db in
                // SQL 目的：为新建书评解析有效所属书籍的展示上下文。
                // 涉及表：book。
                // 关键过滤：按 book.id 精确命中，排除系统根、已删除及业务占位书。
                // 时间字段：不读取时间字段。
                // 返回字段用途：构建尚未落库的 ReviewEditorDraft。
                let sql = """
                    SELECT id, COALESCE(name, '') AS name
                    FROM book
                    WHERE id = ? AND id != 0 AND is_deleted = 0
                    LIMIT 1
                    """
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else {
                    throw ContentRepositoryError.bookNotFound
                }
                return ReviewEditorDraft(
                    reviewId: 0,
                    sourceBookId: row["id"],
                    bookTitle: row["name"] ?? "",
                    title: "",
                    contentHTML: "",
                    imageItems: []
                )
            }
        }
    }

    /// 读取精确书籍/书评身份下的自动保存草稿；损坏或身份不符的数据不会向上层暴露。
    func fetchReviewEditorAutoSaveDraft(
        sourceBookId: Int64,
        reviewId: Int64
    ) -> ReviewEditorAutoSaveDraft? {
        let key = Self.reviewAutoSaveStorageKey(sourceBookId: sourceBookId, reviewId: reviewId)
        guard let data = userDefaults.data(forKey: key) else { return nil }
        guard let draft = try? JSONDecoder().decode(ReviewEditorAutoSaveDraft.self, from: data),
              draft.matches(sourceBookId: sourceBookId, reviewId: reviewId) else {
            userDefaults.removeObject(forKey: key)
            return nil
        }
        return draft
    }

    /// 编码并写入书评自动保存草稿，键和值同时保留身份用于恢复时双重校验。
    func saveReviewEditorAutoSaveDraft(_ draft: ReviewEditorAutoSaveDraft) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(draft)
        } catch {
            throw ContentRepositoryError.autoSaveDraftEncodingFailed
        }
        userDefaults.set(
            data,
            forKey: Self.reviewAutoSaveStorageKey(
                sourceBookId: draft.sourceBookId,
                reviewId: draft.reviewId
            )
        )
    }

    /// 删除精确身份下的书评草稿；远端对象和暂存文件生命周期由图片仓储分别管理。
    func deleteReviewEditorAutoSaveDraft(sourceBookId: Int64, reviewId: Int64) {
        userDefaults.removeObject(
            forKey: Self.reviewAutoSaveStorageKey(
                sourceBookId: sourceBookId,
                reviewId: reviewId
            )
        )
    }

    /// 保存书评编辑草稿。
    func saveReviewEditorDraft(_ draft: ReviewEditorDraft) async throws {
        _ = try await saveReviewEditorDraft(draft, mode: .edit(reviewID: draft.reviewId))
    }

    /// 新建或更新书评并返回主键；主记录和有序图片子表在同一事务内原子提交。
    func saveReviewEditorDraft(_ draft: ReviewEditorDraft, mode: ReviewEditorMode) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let imageURLs = try Self.validatedEditorImageURLs(draft.imageItems)
        let savedReviewID = try await databaseManager.database.dbPool.write { db in
            var savedReviewID: Int64 = 0
                switch mode {
                case .create(let bookID):
                    guard bookID > 0, draft.sourceBookId == bookID else {
                        throw ContentRepositoryError.invalidBook
                    }
                    // SQL 目的：确认新建书评所属书籍仍为有效书架书籍。
                    // 涉及表：book。
                    // 关键过滤：按主键命中，排除系统根、已删除及业务占位书。
                    // 时间字段：不读取时间字段。
                    // 返回字段用途：只作为写入前存在性门闩。
                    let bookExistsSQL = "SELECT id FROM book WHERE id = ? AND id != 0 AND is_deleted = 0 LIMIT 1"
                    guard try Int64.fetchOne(db, sql: bookExistsSQL, arguments: [bookID]) != nil else {
                        throw ContentRepositoryError.bookNotFound
                    }
                    try db.execute(
                        // SQL 目的：插入一条有效书评主记录。
                        // 涉及表：review。
                        // 关键字段：book_id 来自已校验 mode；标题/正文来自草稿；同步字段按 Android 新记录默认值写入。
                        // 时间字段：created_date 使用当前本地毫秒时间戳，updated_date/last_sync_date 初始为 0。
                        // 副作用：新建 is_deleted=0 主记录，随后在同一事务写入 review_image。
                        sql: """
                            INSERT INTO review (
                                book_id, title, content, created_date, updated_date, last_sync_date, is_deleted
                            ) VALUES (?, ?, ?, ?, 0, 0, 0)
                            """,
                        arguments: [bookID, draft.title, draft.contentHTML, now]
                    )
                    savedReviewID = db.lastInsertedRowID
                case .edit(let reviewID):
                    guard reviewID > 0, draft.reviewId == reviewID else {
                        throw ContentRepositoryError.reviewNotFound
                    }
                    try deleteReviewImages(db, reviewID: reviewID, timestamp: now)
                    try db.execute(
                        // SQL 目的：更新单条书评的标题、HTML 正文与更新时间。
                        // 涉及表：review。
                        // 关键过滤：按 review.id 精确命中且记录有效。
                        // 时间字段：updated_date 使用当前本地毫秒时间戳。
                        // 副作用：不改动 book_id 与同步字段；旧图片已在本事务 child-first 删除，新图片随后重建。
                        sql: """
                            UPDATE review
                            SET title = ?, content = ?, updated_date = ?
                            WHERE id = ? AND is_deleted = 0
                            """,
                        arguments: [draft.title, draft.contentHTML, now, reviewID]
                    )
                    guard db.changesCount > 0 else { throw ContentRepositoryError.reviewNotFound }
                    savedReviewID = reviewID
                }
                try insertReviewImages(
                    db,
                    reviewID: savedReviewID,
                    imageURLs: imageURLs,
                    timestamp: now
                )
            return savedReviewID
        }
        let originalReviewID: Int64
        switch mode {
        case .create:
            originalReviewID = 0
        case .edit(let reviewID):
            originalReviewID = reviewID
        }
        deleteReviewEditorAutoSaveDraft(
            sourceBookId: draft.sourceBookId,
            reviewId: originalReviewID
        )
        return savedReviewID
    }

    /// 按相关内容主键读取已有编辑草稿，供编辑态恢复正文与图片。
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
                imageItems: detail.imageURLs.enumerated().map { index, remoteURL in
                    .existing(id: "relevant-\(detail.contentId)-image-\(index)", remoteURL: remoteURL)
                }
            )
        }
    }

    /// 按新建/编辑模式生成相关内容草稿；新建态要求分类为全局分类或属于目标书籍。
    func fetchRelevantEditorDraft(mode: RelevantEditorMode) async throws -> RelevantEditorDraft? {
        switch mode {
        case .edit(let contentID):
            return try await fetchRelevantEditorDraft(contentId: contentID)
        case .create(let bookID, let categoryID):
            guard bookID > 0, categoryID > 0 else { throw ContentRepositoryError.invalidRelevantContext }
            return try await databaseManager.database.dbPool.read { db in
                // SQL 目的：解析新建相关内容所需的有效书籍与分类上下文。
                // 涉及表：book INNER JOIN category（通过常量参数连接）。
                // 关键过滤：书籍有效；分类有效且未隐藏，并且是全局分类或属于当前书籍。
                // 时间字段：不读取时间字段。
                // 返回字段用途：构建尚未落库的 RelevantEditorDraft。
                let sql = """
                    SELECT b.id AS book_id, COALESCE(b.name, '') AS book_title,
                           cat.id AS category_id, COALESCE(cat.title, '') AS category_title
                    FROM book b
                    JOIN category cat ON cat.id = ?
                                     AND cat.is_deleted = 0
                                     AND cat.is_hide = 0
                                     AND (cat.book_id = 0 OR cat.book_id = b.id)
                    WHERE b.id = ? AND b.id != 0 AND b.is_deleted = 0
                    LIMIT 1
                    """
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [categoryID, bookID]) else {
                    throw ContentRepositoryError.invalidRelevantContext
                }
                return RelevantEditorDraft(
                    contentId: 0,
                    sourceBookId: row["book_id"],
                    categoryId: row["category_id"],
                    bookTitle: row["book_title"] ?? "",
                    categoryTitle: row["category_title"] ?? "",
                    title: "",
                    contentHTML: "",
                    url: "",
                    imageItems: []
                )
            }
        }
    }

    /// 读取精确书籍/分类/内容身份下的自动保存草稿；损坏或身份不符的数据会被移除。
    func fetchRelevantEditorAutoSaveDraft(
        sourceBookId: Int64,
        categoryId: Int64,
        contentId: Int64
    ) -> RelevantEditorAutoSaveDraft? {
        let key = Self.relevantAutoSaveStorageKey(
            sourceBookId: sourceBookId,
            categoryId: categoryId,
            contentId: contentId
        )
        guard let data = userDefaults.data(forKey: key) else { return nil }
        guard let draft = try? JSONDecoder().decode(RelevantEditorAutoSaveDraft.self, from: data),
              draft.matches(
                sourceBookId: sourceBookId,
                categoryId: categoryId,
                contentId: contentId
              ) else {
            userDefaults.removeObject(forKey: key)
            return nil
        }
        return draft
    }

    /// 编码并写入相关内容自动保存草稿，确保分类维度不会在同一本书内串用。
    func saveRelevantEditorAutoSaveDraft(_ draft: RelevantEditorAutoSaveDraft) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(draft)
        } catch {
            throw ContentRepositoryError.autoSaveDraftEncodingFailed
        }
        userDefaults.set(
            data,
            forKey: Self.relevantAutoSaveStorageKey(
                sourceBookId: draft.sourceBookId,
                categoryId: draft.categoryId,
                contentId: draft.contentId
            )
        )
    }

    /// 删除精确身份下的相关内容草稿；不会删除仍被数据库或其他草稿使用的远端图片。
    func deleteRelevantEditorAutoSaveDraft(
        sourceBookId: Int64,
        categoryId: Int64,
        contentId: Int64
    ) {
        userDefaults.removeObject(
            forKey: Self.relevantAutoSaveStorageKey(
                sourceBookId: sourceBookId,
                categoryId: categoryId,
                contentId: contentId
            )
        )
    }

    /// 保存相关内容编辑草稿。
    func saveRelevantEditorDraft(_ draft: RelevantEditorDraft) async throws {
        _ = try await saveRelevantEditorDraft(draft, mode: .edit(contentID: draft.contentId))
    }

    /// 新建或更新普通相关内容并返回主键；主记录和有序图片子表在同一事务内原子提交。
    func saveRelevantEditorDraft(_ draft: RelevantEditorDraft, mode: RelevantEditorMode) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let imageURLs = try Self.validatedEditorImageURLs(draft.imageItems)
        let savedContentID = try await databaseManager.database.dbPool.write { db in
            var savedContentID: Int64 = 0
                switch mode {
                case .create(let bookID, let categoryID):
                    guard bookID > 0,
                          categoryID > 0,
                          draft.sourceBookId == bookID,
                          draft.categoryId == categoryID else {
                        throw ContentRepositoryError.invalidRelevantContext
                    }
                    // SQL 目的：在新建相关内容前确认书籍与分类仍构成有效可写上下文。
                    // 涉及表：category INNER JOIN book。
                    // 关键过滤：书籍有效；分类有效、未隐藏，且为全局模板或属于当前书籍。
                    // 时间字段：不读取时间字段。
                    // 返回字段用途：仅作为插入前存在性门闩。
                    let contextSQL = """
                        SELECT cat.id
                        FROM category cat
                        JOIN book b ON b.id = ? AND b.id != 0 AND b.is_deleted = 0
                        WHERE cat.id = ?
                          AND cat.is_deleted = 0
                          AND cat.is_hide = 0
                          AND (cat.book_id = 0 OR cat.book_id = b.id)
                        LIMIT 1
                        """
                    guard try Int64.fetchOne(db, sql: contextSQL, arguments: [bookID, categoryID]) != nil else {
                        throw ContentRepositoryError.invalidRelevantContext
                    }
                    try db.execute(
                        // SQL 目的：插入一条普通相关内容主记录。
                        // 涉及表：category_content。
                        // 关键字段：category_id/book_id 来自已校验 mode，content_book_id=0 明确区分相关书籍关系。
                        // 时间字段：created_date 使用当前本地毫秒时间戳，updated_date/last_sync_date 初始为 0。
                        // 副作用：新建 is_deleted=0 主记录，随后在同一事务写入 category_image。
                        sql: """
                            INSERT INTO category_content (
                                category_id, book_id, title, content, content_book_id, url,
                                created_date, updated_date, last_sync_date, is_deleted
                            ) VALUES (?, ?, ?, ?, 0, ?, ?, 0, 0, 0)
                            """,
                        arguments: [categoryID, bookID, draft.title, draft.contentHTML, draft.url, now]
                    )
                    savedContentID = db.lastInsertedRowID
                case .edit(let contentID):
                    guard contentID > 0, draft.contentId == contentID else {
                        throw ContentRepositoryError.relevantNotFound
                    }
                    try deleteRelevantImages(db, contentID: contentID, timestamp: now)
                    try db.execute(
                        // SQL 目的：更新单条普通相关内容的标题、HTML 正文、链接与更新时间。
                        // 涉及表：category_content。
                        // 关键过滤：按主键精确命中、记录有效且 content_book_id=0，禁止误改相关书籍关系。
                        // 时间字段：updated_date 使用当前本地毫秒时间戳。
                        // 副作用：不触碰 category_id/book_id；旧图片已在本事务 child-first 删除，新图片随后重建。
                        sql: """
                            UPDATE category_content
                            SET title = ?, content = ?, url = ?, updated_date = ?
                            WHERE id = ? AND is_deleted = 0 AND content_book_id = 0
                            """,
                        arguments: [draft.title, draft.contentHTML, draft.url, now, contentID]
                    )
                    guard db.changesCount > 0 else { throw ContentRepositoryError.relevantNotFound }
                    savedContentID = contentID
                }
                try insertRelevantImages(
                    db,
                    contentID: savedContentID,
                    imageURLs: imageURLs,
                    timestamp: now
                )
            return savedContentID
        }
        let originalContentID: Int64
        switch mode {
        case .create:
            originalContentID = 0
        case .edit(let contentID):
            originalContentID = contentID
        }
        deleteRelevantEditorAutoSaveDraft(
            sourceBookId: draft.sourceBookId,
            categoryId: draft.categoryId,
            contentId: originalContentID
        )
        return savedContentID
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
                JOIN book b ON b.id = cc.content_book_id
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

    /// 按 Android 语义软删除普通相关内容或相关书籍关系及其附图。
    func deleteRelatedRelation(relationID: Int64) async throws {
        guard relationID > 0 else { throw ContentRepositoryError.relevantNotFound }
        try await databaseManager.database.dbPool.write { db in
            try deleteRelevant(db, contentId: relationID)
        }
    }

    /// 删除指定内容，在单一事务内按 Android 语义软删除主记录与子记录。
    func delete(itemID: ContentViewerItemID) async throws {
        try await databaseManager.database.dbPool.write { db in
            switch itemID {
            case .note(let noteId):
                try deleteNote(db, noteId: noteId)
            case .review(let reviewId):
                try deleteReview(db, reviewId: reviewId)
            case .relevant(let contentId):
                try deleteRelevant(db, contentId: contentId)
            }
        }
    }
}

/// 通用内容读取与编辑的业务错误。
nonisolated enum ContentRepositoryError: LocalizedError {
    case invalidBook
    case bookNotFound
    case reviewNotFound
    case invalidRelevantContext
    case relevantNotFound
    case selfRelatedBook
    case relatedBookAlreadyExists
    case relatedBookCategoryUnavailable
    case invalidCategoryTitle
    case categoryAlreadyExists
    case categoryNotFound
    case invalidCategoryOrder
    case invalidContentSortRule
    case editorImageUploadIncomplete
    case tooManyEditorImages
    case autoSaveDraftEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidBook: "请选择有效书籍"
        case .bookNotFound: "书籍不存在"
        case .reviewNotFound: "书评不存在"
        case .invalidRelevantContext: "书籍或相关分类不可用"
        case .relevantNotFound: "相关内容不存在"
        case .selfRelatedBook: "不能把当前书籍关联到自身"
        case .relatedBookAlreadyExists: "这本书已经在相关书籍中"
        case .relatedBookCategoryUnavailable: "系统“书籍”分类不可用"
        case .invalidCategoryTitle: "分类名称需为 1 至 10 个字符"
        case .categoryAlreadyExists: "同名相关分类已经存在"
        case .categoryNotFound: "相关分类不存在或不可编辑"
        case .invalidCategoryOrder: "分类列表已变化，请刷新后重试"
        case .invalidContentSortRule: "当前内容类型不支持这个排序方式"
        case .editorImageUploadIncomplete: "请等待所有图片上传成功后再保存"
        case .tooManyEditorImages: "最多只能保存 9 张图片"
        case .autoSaveDraftEncodingFailed: "自动草稿暂时无法保存"
        }
    }
}

// MARK: - Feed Queries

private extension ContentRepository {
    nonisolated static func reviewAutoSaveStorageKey(sourceBookId: Int64, reviewId: Int64) -> String {
        "review_draft_\(sourceBookId)_\(reviewId)"
    }

    nonisolated static func relevantAutoSaveStorageKey(
        sourceBookId: Int64,
        categoryId: Int64,
        contentId: Int64
    ) -> String {
        "relevant_draft_\(sourceBookId)_\(categoryId)_\(contentId)"
    }

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

    /// 聚合单本书的书评、相关分区与普通相关内容分类候选，保持 Android 目录顺序和内容倒序语义。
    nonisolated func fetchBookContentWorkspace(
        _ db: Database,
        bookID: Int64
    ) throws -> BookContentWorkspaceSnapshot {
        guard bookID > 0 else { return .empty }
        let sortPreferences = try BookContentSortQuery.fetchPreferences(db, bookID: bookID)

        // SQL 目的：读取指定书籍管理范围内的全局分类与书籍私有分类，包含隐藏项。
        // 涉及表：category。
        // 关键过滤：只保留有效且 book_id=0 或属于当前书籍的分类；is_hide 原样返回供管理页恢复。
        // 排序：按 Android category.order ASC，再按 id ASC 稳定兜底。
        // 时间字段：不读取时间字段。
        // 返回字段用途：构建完整管理快照；relatedSections 与 categoryOptions 再排除隐藏项，“书籍”分类不进入普通内容编辑候选。
        let categorySQL = """
            SELECT cat.id, COALESCE(cat.title, '') AS title, cat.book_id,
                   cat."order" AS category_order, cat.is_hide,
                   (SELECT COUNT(*)
                    FROM category_content cc
                    WHERE cc.category_id = cat.id
                      AND cc.book_id = ?
                      AND cc.is_deleted = 0) AS content_count
            FROM category cat
            WHERE cat.is_deleted = 0
              AND (cat.book_id = 0 OR cat.book_id = ?)
            ORDER BY cat."order" ASC, cat.id ASC
            """
        let categoryRows = try Row.fetchAll(db, sql: categorySQL, arguments: [bookID, bookID])
        let categories = categoryRows.map { row -> BookContentCategoryOption in
            let categoryID: Int64 = row["id"]
            let ownerBookID: Int64 = row["book_id"] ?? 0
            return BookContentCategoryOption(
                id: categoryID,
                title: row["title"] ?? "",
                order: row["category_order"] ?? 0,
                contentCount: Int(row["content_count"] as Int64? ?? 0),
                ownerBookID: ownerBookID,
                isHidden: (row["is_hide"] as Int64? ?? 0) != 0,
                isSystemDefault: ownerBookID == 0
                    && categoryID >= 1
                    && categoryID <= Self.defaultCategoryUpperBound,
                isRelatedBook: categoryID == Self.relatedBookCategoryID
            )
        }

        // SQL 目的：读取指定书籍的全部有效书评摘要，供详情工作区列表与 Viewer 首项定位。
        // 涉及表：review INNER JOIN book。
        // 关键过滤：按 review.book_id 精确命中，且来源书与书评均有效并排除系统根书。
        // 排序：按 sort(book_id,type=REVIEW) 的时间升/降序，并用 id 同向稳定兜底。
        // 时间字段：created_date 保持 Android 毫秒时间戳原值，不在数据库层做时区转换。
        // 返回字段用途：构建 BookContentReviewItem，正文 HTML 在 ViewModel 后台转换为纯文本预览。
        let reviewDirection = sortPreferences.reviews == .createdDateAscending ? "ASC" : "DESC"
        let reviewSQL = """
            SELECT rv.id, COALESCE(rv.title, '') AS title,
                   COALESCE(rv.content, '') AS content, rv.created_date
            FROM review rv
            JOIN book b ON b.id = rv.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE rv.book_id = ? AND rv.is_deleted = 0
            ORDER BY rv.created_date \(reviewDirection), rv.id \(reviewDirection)
            """
        let reviews = try Row.fetchAll(db, sql: reviewSQL, arguments: [bookID]).map { row in
            BookContentReviewItem(
                id: row["id"],
                title: row["title"] ?? "",
                contentHTML: row["content"] ?? "",
                createdDate: row["created_date"] ?? 0
            )
        }

        // SQL 目的：读取指定书籍下全部有效相关关系，并为相关书籍补齐书名、作者和封面。
        // 涉及表：category_content INNER JOIN category LEFT JOIN book（相关书籍）。
        // 关键过滤：关系属于当前书籍；分类有效且未隐藏；普通内容直接保留，相关书籍必须仍有被引用的 book 主记录。
        // 排序：分类顺序由后续 categoryRows 固定；分类内按 sort(book_id,type=RELEVANT) 时间方向，并以关系 id 同向稳定兜底。
        // 时间字段：created_date 保持 Android 毫秒时间戳原值。
        // 返回字段用途：构建普通内容 Viewer 入口或相关书籍 BookRoute 入口。
        let relatedDirection = sortPreferences.related == .createdDateAscending ? "ASC" : "DESC"
        let relatedSQL = """
            SELECT cc.id, cc.category_id, cc.content_book_id,
                   COALESCE(cc.title, '') AS content_title,
                   COALESCE(cc.content, '') AS content_html,
                   COALESCE(cc.url, '') AS content_url,
                   cc.created_date,
                   COALESCE(rb.name, '') AS related_book_name,
                   COALESCE(rb.author, '') AS related_book_author,
                   COALESCE(rb.cover, '') AS related_book_cover,
                   COALESCE(rb.is_deleted, 0) AS related_book_is_deleted
            FROM category_content cc
            JOIN category cat ON cat.id = cc.category_id
                             AND cat.is_deleted = 0
                             AND cat.is_hide = 0
            LEFT JOIN book rb ON rb.id = cc.content_book_id AND rb.id != 0
            WHERE cc.book_id = ?
              AND cc.is_deleted = 0
              AND (cc.content_book_id = 0 OR rb.id IS NOT NULL)
            ORDER BY cc.created_date \(relatedDirection), cc.id \(relatedDirection)
            """
        let relatedRows = try Row.fetchAll(db, sql: relatedSQL, arguments: [bookID])
        var relatedItemsByCategory: [Int64: [BookContentRelatedItem]] = [:]
        relatedItemsByCategory.reserveCapacity(categoryRows.count)
        for row in relatedRows {
            let relationID: Int64 = row["id"]
            let categoryID: Int64 = row["category_id"]
            let contentBookID: Int64 = row["content_book_id"] ?? 0
            let item: BookContentRelatedItem
            if contentBookID > 0 {
                item = BookContentRelatedItem(
                    id: relationID,
                    destination: .book(bookID: contentBookID),
                    title: row["related_book_name"] ?? "",
                    subtitle: row["related_book_author"] ?? "",
                    contentHTML: "",
                    coverURL: row["related_book_cover"] ?? "",
                    createdDate: row["created_date"] ?? 0,
                    isPlaceholder: (row["related_book_is_deleted"] as Int64? ?? 0) != 0
                )
            } else {
                item = BookContentRelatedItem(
                    id: relationID,
                    destination: .content(contentID: relationID),
                    title: row["content_title"] ?? "",
                    subtitle: row["content_url"] ?? "",
                    contentHTML: row["content_html"] ?? "",
                    coverURL: "",
                    createdDate: row["created_date"] ?? 0
                )
            }
            relatedItemsByCategory[categoryID, default: []].append(item)
        }

        let relatedSections = categories.compactMap { category -> BookContentRelatedSection? in
            guard !category.isHidden else { return nil }
            let categoryID = category.id
            guard let items = relatedItemsByCategory[categoryID], !items.isEmpty else { return nil }
            return BookContentRelatedSection(
                id: categoryID,
                title: category.title,
                items: items
            )
        }
        return BookContentWorkspaceSnapshot(
            reviews: reviews,
            relatedSections: relatedSections,
            categories: categories,
            sortPreferences: sortPreferences
        )
    }

    /// 查询书籍详情来源下的书摘 viewer 列表。
    nonisolated func fetchBookNoteViewerItems(_ db: Database, bookId: Int64) throws -> [ContentViewerListItem] {
        // SQL 目的：提取指定书籍下的全部有效书摘，供书籍详情进入通用查看器后横向分页。
        // 涉及表：note INNER JOIN book。
        // 关键过滤：按 book_id 精确命中，且排除 note/book 的软删除记录。
        // 排序：读取 sort(book_id,type=NOTE) 后复用 BookContentSortQuery，保证 Viewer 与工作区书摘顺序一致。
        let sql = """
            SELECT n.id, n.book_id, n.created_date, n.position, n.include_time,
                   COALESCE(n.weread_range, '') AS weread_range,
                   b.source_id, b.name
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            WHERE n.book_id = ? AND n.is_deleted = 0
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [bookId])
        let rule = try BookContentSortQuery.fetchRule(db, bookID: bookId, type: .notes)
        return BookContentSortQuery.sortedNoteRows(rows, rule: rule).map { row in
            ContentViewerListItem(
                id: .note(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["name"] ?? "",
                timestamp: row["created_date"]
            )
        }
    }

    /// 查询单本书下的全部有效书评，供工作区 Viewer 在编辑或删除后保持实时分页。
    nonisolated func fetchBookReviewViewerItems(_ db: Database, bookID: Int64) throws -> [ContentViewerListItem] {
        guard bookID > 0 else { return [] }
        // SQL 目的：读取指定书籍下的书评 Viewer 列表。
        // 涉及表：review INNER JOIN book。
        // 关键过滤：书评按 book_id 精确命中，书评和来源书均有效且排除系统根书。
        // 排序：按 sort(book_id,type=REVIEW) 的时间方向，并以 id 同向稳定兜底。
        // 时间字段：created_date 为 Android 毫秒时间戳，直接用于 Viewer 元信息。
        // 返回字段用途：构建可观察的书评分页顺序。
        let rule = try BookContentSortQuery.fetchRule(db, bookID: bookID, type: .reviews)
        let direction = rule == .createdDateAscending ? "ASC" : "DESC"
        let sql = """
            SELECT rv.id, rv.book_id, rv.created_date, COALESCE(b.name, '') AS book_title
            FROM review rv
            JOIN book b ON b.id = rv.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE rv.book_id = ? AND rv.is_deleted = 0
            ORDER BY rv.created_date \(direction), rv.id \(direction)
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookID]).map { row in
            ContentViewerListItem(
                id: .review(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["book_title"] ?? "",
                timestamp: row["created_date"] ?? 0
            )
        }
    }

    /// 查询单本书全部可见分类下的普通相关内容，顺序与原生工作台的持久化排序语义一致。
    nonisolated func fetchBookRelevantViewerItems(_ db: Database, bookID: Int64) throws -> [ContentViewerListItem] {
        guard bookID > 0 else { return [] }
        let rule = try BookContentSortQuery.fetchRule(db, bookID: bookID, type: .related)
        let direction = rule == .createdDateAscending ? "ASC" : "DESC"
        // SQL 目的：读取指定书籍全部可见分类下的普通相关内容，供原生工作台进入通用 Viewer 后分页。
        // 涉及表：category_content INNER JOIN category INNER JOIN book。
        // 关键过滤：来源书精确匹配；关系、分类与书籍均有效；分类未隐藏；排除 content_book_id != 0 的相关书籍关系。
        // 排序：分类按 Android `order`/id 稳定分区，分类内严格使用 sort(book_id,type=RELEVANT) 的持久化时间方向。
        // 时间字段：created_date 为 Android 毫秒时间戳，不做时区转换。
        // 返回字段用途：构建与工作台相邻顺序一致的相关内容 Viewer 列表。
        let sql = """
            SELECT cc.id, cc.book_id, cc.created_date, COALESCE(b.name, '') AS book_title
            FROM category_content cc
            JOIN category cat ON cat.id = cc.category_id
                             AND cat.is_deleted = 0
                             AND cat.is_hide = 0
            JOIN book b ON b.id = cc.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE cc.book_id = ?
              AND cc.content_book_id = 0
              AND cc.is_deleted = 0
            ORDER BY cat."order" ASC, cat.id ASC,
                     cc.created_date \(direction), cc.id \(direction)
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookID]).map { row in
            ContentViewerListItem(
                id: .relevant(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["book_title"] ?? "",
                timestamp: row["created_date"] ?? 0
            )
        }
    }

    /// 查询单本书指定分类下的普通相关内容；相关书籍始终由 BookRoute 进入详情。
    nonisolated func fetchBookRelatedViewerItems(
        _ db: Database,
        bookID: Int64,
        categoryID: Int64
    ) throws -> [ContentViewerListItem] {
        guard bookID > 0, categoryID > 0 else { return [] }
        // SQL 目的：读取指定书籍与分类下的普通相关内容 Viewer 列表。
        // 涉及表：category_content INNER JOIN category INNER JOIN book（来源书）。
        // 关键过滤：book_id/category_id 精确命中；仅保留 content_book_id=0 的普通内容；三张表记录均有效且分类未隐藏。
        // 排序：按 sort(book_id,type=RELEVANT) 的时间方向，并以关系 id 同向稳定兜底。
        // 时间字段：created_date 为 Android 毫秒时间戳，不做数据库层时区转换。
        // 返回字段用途：构建分类内普通相关内容的可观察分页顺序。
        let rule = try BookContentSortQuery.fetchRule(db, bookID: bookID, type: .related)
        let direction = rule == .createdDateAscending ? "ASC" : "DESC"
        let sql = """
            SELECT cc.id, cc.book_id, cc.created_date, COALESCE(b.name, '') AS book_title
            FROM category_content cc
            JOIN category cat ON cat.id = cc.category_id
                             AND cat.is_deleted = 0
                             AND cat.is_hide = 0
            JOIN book b ON b.id = cc.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE cc.book_id = ?
              AND cc.category_id = ?
              AND cc.content_book_id = 0
              AND cc.is_deleted = 0
            ORDER BY cc.created_date \(direction), cc.id \(direction)
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookID, categoryID]).map { row in
            ContentViewerListItem(
                id: .relevant(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["book_title"] ?? "",
                timestamp: row["created_date"] ?? 0
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

    /// 查询首页书摘范围下的完整 Viewer 顺序，搜索与 scope 始终使用 AND 组合。
    nonisolated func fetchNoteExcerptViewerItems(
        _ db: Database,
        scope: NoteExcerptScope,
        query: String,
        sort: NoteExcerptSortRule,
        randomSeed: Int64
    ) throws -> [ContentViewerListItem] {
        var predicates = ["n.is_deleted = 0"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        appendNoteScopePredicate(scope, predicates: &predicates, arguments: &arguments)
        appendNoteSearchPredicate(query, predicates: &predicates, arguments: &arguments)
        return try fetchScopedNoteViewerItems(
            db,
            predicates: predicates,
            arguments: arguments,
            sort: sort,
            randomSeed: randomSeed
        )
    }

    /// 查询章节及可选后代范围下的完整 Viewer 顺序。
    nonisolated func fetchChapterNoteViewerItems(
        _ db: Database,
        bookID: Int64,
        chapterID: Int64,
        includeDescendants: Bool,
        query: String,
        sort: NoteExcerptSortRule,
        randomSeed: Int64
    ) throws -> [ContentViewerListItem] {
        guard bookID > 0, chapterID >= 0 else { return [] }
        var predicates = ["n.is_deleted = 0", "n.book_id = ?"]
        var arguments: [(any DatabaseValueConvertible)?] = [bookID]
        if includeDescendants, chapterID > 0 {
            // SQL 目的：限定书摘属于目标章节或其任意层级有效后代章节。
            // 涉及表：chapter 递归 CTE；外层 note 通过 chapter_id 命中范围。
            // 关键过滤：递归限定同一本书且 chapter.is_deleted=0，循环脏数据由 UNION 去重终止。
            // 时间字段：不读取时间字段。
            // 返回字段用途：为星标章节入口生成与列表一致的 Viewer 范围。
            predicates.append("""
                n.chapter_id IN (
                    WITH RECURSIVE chapter_scope(id) AS (
                        SELECT id FROM chapter
                        WHERE id = ? AND book_id = ? AND is_deleted = 0
                        UNION
                        SELECT child.id
                        FROM chapter child
                        JOIN chapter_scope parent ON child.parent_id = parent.id
                        WHERE child.book_id = ? AND child.is_deleted = 0
                    )
                    SELECT id FROM chapter_scope
                )
                """)
            arguments.append(chapterID)
            arguments.append(bookID)
            arguments.append(bookID)
        } else {
            predicates.append("n.chapter_id = ?")
            arguments.append(chapterID)
        }
        appendNoteSearchPredicate(query, predicates: &predicates, arguments: &arguments)
        return try fetchScopedNoteViewerItems(
            db,
            predicates: predicates,
            arguments: arguments,
            sort: sort,
            randomSeed: randomSeed
        )
    }

    /// 执行统一书摘 Viewer 查询，确保时间与随机排序和二级列表使用同一规则。
    nonisolated func fetchScopedNoteViewerItems(
        _ db: Database,
        predicates: [String],
        arguments: [(any DatabaseValueConvertible)?],
        sort: NoteExcerptSortRule,
        randomSeed: Int64
    ) throws -> [ContentViewerListItem] {
        let direction = sort == .createdAscending ? "ASC" : "DESC"
        // SQL 目的：读取指定书摘范围的完整 Viewer 列表。
        // 涉及表：note INNER JOIN book；scope/search/章节条件由受控 predicates 注入。
        // 关键过滤：书摘和来源书籍均有效，排除系统根书籍。
        // 排序：时间模式按 created_date/id 同方向；随机模式先按 id，随后用 seed 稳定重排。
        // 时间字段：created_date 原样返回 Android 毫秒时间戳。
        // 返回字段用途：横向 Viewer 的完整 item 顺序。
        let sql = """
            SELECT n.id, n.book_id, n.created_date, COALESCE(b.name, '') AS book_title
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE \(predicates.joined(separator: "\n              AND "))
            ORDER BY \(sort == .random ? "n.id ASC" : "n.created_date \(direction), n.id \(direction)")
            """
        var items = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
            ContentViewerListItem(
                id: .note(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["book_title"] ?? "",
                timestamp: row["created_date"] ?? 0
            )
        }
        if sort == .random {
            items = Self.stablyShuffleViewerItems(items, seed: randomSeed)
        }
        return items
    }

    /// 查询相关分类下可进入通用 Viewer 的普通相关内容；相关书籍由 Book 路由处理。
    nonisolated func fetchRelatedCategoryViewerItems(
        _ db: Database,
        scope: RelatedCategoryScope,
        query: String,
        sort: RelatedContentSortRule,
        randomSeed: Int64
    ) throws -> [ContentViewerListItem] {
        var predicates = ["cc.is_deleted = 0", "cc.content_book_id = 0"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        if case .title(let title) = scope {
            predicates.append("cat.title = ? AND cat.is_hide = 0")
            arguments.append(title)
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            let pattern = "%\(Self.escapeLikePattern(keyword))%"
            predicates.append("""
                (COALESCE(cc.title, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(cc.content, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(cc.url, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
                """)
            for _ in 0..<3 { arguments.append(pattern) }
        }
        let direction = sort == .createdAscending ? "ASC" : "DESC"
        // SQL 目的：读取相关分类范围下的全部普通内容 Viewer 项。
        // 涉及表：category_content INNER JOIN category/source book。
        // 关键过滤：排除相关书籍关系，仅保留有效普通内容和有效来源书；标题 scope 精确匹配且隐藏分类不进入。
        // 排序：时间模式按 created_date/id；随机模式先按 id 后稳定重排。
        // 时间字段：created_date 为 Android 毫秒时间戳。
        // 返回字段用途：相关内容横向 Viewer 顺序。
        let sql = """
            SELECT cc.id, cc.book_id, cc.created_date, COALESCE(b.name, '') AS book_title
            FROM category_content cc
            JOIN category cat ON cat.id = cc.category_id AND cat.is_deleted = 0
            JOIN book b ON b.id = cc.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE \(predicates.joined(separator: "\n              AND "))
            ORDER BY \(sort == .random ? "cc.id ASC" : "cc.created_date \(direction), cc.id \(direction)")
            """
        var items = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
            ContentViewerListItem(
                id: .relevant(row["id"]),
                sourceBookId: row["book_id"],
                bookTitle: row["book_title"] ?? "",
                timestamp: row["created_date"] ?? 0
            )
        }
        if sort == .random {
            items = Self.stablyShuffleViewerItems(items, seed: randomSeed)
        }
        return items
    }

    /// 查询全量书评 Viewer 顺序；字数排序按去富文本后的可见正文长度计算。
    nonisolated func fetchAllReviewViewerItems(
        _ db: Database,
        query: String,
        sort: BookReviewSortRule
    ) throws -> [ContentViewerListItem] {
        // SQL 目的：读取全部有效书评与来源书，用于全量书评横向 Viewer。
        // 涉及表：review INNER JOIN book。
        // 关键过滤：书评/书籍有效且排除系统根书籍；搜索在内存用可见纯文本判定。
        // 排序：数据库仅按 id 提供稳定输入，最终按 request sort 统一排序。
        // 时间字段：created_date 为 Android 毫秒时间戳。
        // 返回字段用途：构建 Viewer 列表与可见正文排序键。
        let sql = """
            SELECT rv.id, rv.book_id, rv.created_date,
                   COALESCE(rv.title, '') AS title,
                   COALESCE(rv.content, '') AS content,
                   COALESCE(b.name, '') AS book_title
            FROM review rv
            JOIN book b ON b.id = rv.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE rv.is_deleted = 0
            ORDER BY rv.id ASC
            """
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries = try Row.fetchAll(db, sql: sql).compactMap { row -> (ContentViewerListItem, Int)? in
            let title = RichTextPlainTextExtractor.plainText(from: row["title"] ?? "")
            let content = RichTextPlainTextExtractor.plainText(from: row["content"] ?? "")
            if !keyword.isEmpty,
               !title.localizedCaseInsensitiveContains(keyword),
               !content.localizedCaseInsensitiveContains(keyword) {
                return nil
            }
            return (
                ContentViewerListItem(
                    id: .review(row["id"]),
                    sourceBookId: row["book_id"],
                    bookTitle: row["book_title"] ?? "",
                    timestamp: row["created_date"] ?? 0
                ),
                content.count
            )
        }
        entries.sort { lhs, rhs in
            let lhsID = Self.numericID(lhs.0.id)
            let rhsID = Self.numericID(rhs.0.id)
            switch sort {
            case .wordCountAscending:
                return lhs.1 == rhs.1 ? lhsID < rhsID : lhs.1 < rhs.1
            case .wordCountDescending:
                return lhs.1 == rhs.1 ? lhsID > rhsID : lhs.1 > rhs.1
            case .createdAscending:
                return lhs.0.timestamp == rhs.0.timestamp ? lhsID < rhsID : lhs.0.timestamp < rhs.0.timestamp
            case .createdDescending:
                return lhs.0.timestamp == rhs.0.timestamp ? lhsID > rhsID : lhs.0.timestamp > rhs.0.timestamp
            }
        }
        return entries.map(\.0)
    }

    nonisolated func appendNoteScopePredicate(
        _ scope: NoteExcerptScope,
        predicates: inout [String],
        arguments: inout [(any DatabaseValueConvertible)?]
    ) {
        switch scope {
        case .all:
            break
        case .untagged:
            predicates.append("""
                NOT EXISTS (
                    SELECT 1 FROM tag_note tn
                    JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
                    WHERE tn.note_id = n.id AND tn.is_deleted = 0
                )
                """)
        case .withIdea:
            predicates.append("trim(COALESCE(n.idea, '')) != ''")
        case .withImages:
            predicates.append("EXISTS (SELECT 1 FROM attach_image ai WHERE ai.note_id = n.id AND ai.is_deleted = 0)")
        case .tag(let id):
            predicates.append("""
                EXISTS (
                    SELECT 1 FROM tag_note tn
                    JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
                    WHERE tn.note_id = n.id AND tn.tag_id = ? AND tn.is_deleted = 0
                )
                """)
            arguments.append(id)
        case .book(let id):
            predicates.append("n.book_id = ?")
            arguments.append(id)
        }
    }

    nonisolated func appendNoteSearchPredicate(
        _ query: String,
        predicates: inout [String],
        arguments: inout [(any DatabaseValueConvertible)?]
    ) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let pattern = "%\(Self.escapeLikePattern(keyword))%"
        predicates.append("""
            (COALESCE(n.content, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
             OR COALESCE(n.idea, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
            """)
        arguments.append(pattern)
        arguments.append(pattern)
    }
}

// MARK: - Detail Queries

private extension ContentRepository {
    /// 读取有效书籍名称，供创建态编辑器建立最小上下文。
    nonisolated func fetchActiveBookTitle(_ db: Database, bookID: Int64) throws -> String? {
        // SQL 目的：读取创建书评或相关内容时的目标书名。
        // 涉及表：book。
        // 关键过滤：按 book.id 精确命中，排除软删除与占位书。
        // 时间字段：不读取时间字段。
        // 返回字段用途：创建态编辑器头部回显所属书籍。
        try String.fetchOne(
            db,
            sql: "SELECT name FROM book WHERE id = ? AND is_deleted = 0 AND id != 0",
            arguments: [bookID]
        )
    }

    /// 读取相关内容创建态所需的有效书籍与分类名称。
    nonisolated func fetchRelevantCreateContext(
        _ db: Database,
        bookID: Int64,
        categoryID: Int64
    ) throws -> (bookTitle: String, categoryTitle: String)? {
        // SQL 目的：校验相关内容创建目标，并读取所属书与分类标题。
        // 涉及表：book b INNER JOIN category cat。
        // 关键过滤：book/category 均未软删除，分类必须是全局分类 book_id=0 或当前书籍私有分类。
        // 时间字段：不读取时间字段。
        // 返回字段用途：防止向无效分类写入，并构建创建态编辑器上下文。
        let sql = """
            SELECT b.name AS book_title, COALESCE(cat.title, '') AS category_title
            FROM book b
            JOIN category cat ON cat.id = ? AND cat.is_deleted = 0
            WHERE b.id = ?
              AND b.is_deleted = 0
              AND b.id != 0
              AND (cat.book_id = 0 OR cat.book_id = b.id)
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [categoryID, bookID]) else {
            return nil
        }
        return (
            bookTitle: row["book_title"] ?? "",
            categoryTitle: row["category_title"] ?? ""
        )
    }

    /// 读取单条书摘详情，并补齐章节、附图与标签。
    nonisolated func fetchNoteDetail(_ db: Database, noteId: Int64) throws -> NoteContentDetail? {
        // SQL 目的：按主键读取单条书摘完整详情。
        // 涉及表：note INNER JOIN book LEFT JOIN chapter。
        // 关键过滤：排除 note/book/chapter 的软删除记录；chapter 缺失时允许为空。
        // 时间字段：created_date 保持 Android 毫秒时间戳原值，读取阶段不做时区转换。
        // 返回字段：viewer 渲染与编辑跳转字段，并携带 weread_book_id、章节来源与 weread_range 生成原文深链。
        let sql = """
            SELECT n.id, n.book_id, n.content, n.idea, n.position, n.position_unit, n.include_time, n.created_date,
                   COALESCE(n.weread_range, '') AS weread_range,
                   b.name AS book_name,
                   COALESCE(b.weread_book_id, '') AS weread_book_id,
                   COALESCE(c.title, '') AS chapter_title,
                   COALESCE(c.source_type, 0) AS chapter_source_type,
                   COALESCE(c.source_uid, '') AS chapter_source_uid
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
            tagNames: tagNames,
            weReadOriginalURL: WeReadOriginalURLBuilder.build(
                bookID: row["weread_book_id"] ?? "",
                chapterSourceType: row["chapter_source_type"] ?? 0,
                chapterUID: row["chapter_source_uid"] ?? "",
                range: row["weread_range"] ?? ""
            )
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

// MARK: - Editor Image Transactions

private extension ContentRepository {
    /// 校验编辑器图片全部上传成功并提取有序远端地址，防止上传中/失败条目被静默丢弃。
    nonisolated static func validatedEditorImageURLs(
        _ items: [ContentEditorImageItem]
    ) throws -> [String] {
        guard items.count <= ContentEditorImageItem.maximumCount else {
            throw ContentRepositoryError.tooManyEditorImages
        }
        return try items.map { item in
            guard item.uploadState == .success else {
                throw ContentRepositoryError.editorImageUploadIncomplete
            }
            let remoteURL = item.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !remoteURL.isEmpty else {
                throw ContentRepositoryError.editorImageUploadIncomplete
            }
            return remoteURL
        }
    }

    /// 在更新书评主记录前软删除全部旧图片，保留 Android 可同步的删除语义。
    nonisolated func deleteReviewImages(_ db: Database, reviewID: Int64, timestamp: Int64) throws {
        try db.execute(
            // SQL 目的：软删除书评原有全部有效图片子记录，为全量有序替换建立新集合。
            // 涉及表：review_image。
            // 关键过滤：按 review_id 精确命中且 is_deleted = 0。
            // 时间字段：updated_date 写本次保存的 Unix 毫秒时间戳。
            // 副作用：只更新图片关系状态，不删除远端对象。
            sql: "UPDATE review_image SET updated_date = ?, is_deleted = 1 WHERE review_id = ? AND is_deleted = 0",
            arguments: [timestamp, reviewID]
        )
    }

    /// 在书评主记录就绪后按当前拖拽顺序重建图片集合及连续 order。
    nonisolated func insertReviewImages(
        _ db: Database,
        reviewID: Int64,
        imageURLs: [String],
        timestamp: Int64
    ) throws {
        for (index, imageURL) in imageURLs.enumerated() {
            try db.execute(
                // SQL 目的：按编辑器最终顺序重建单条书评图片子记录。
                // 涉及表：review_image，review_id 外键指向同事务已存在的 review。
                // 关键字段：image 保存已上传远端地址，order 使用零基连续顺序，is_deleted 固定为 0。
                // 时间字段：created_date 使用本次保存的本地毫秒时间戳，updated_date/last_sync_date 初始为 0。
                // 副作用：插入新的物理图片关系，不复用历史软删除记录。
                sql: """
                    INSERT INTO review_image (
                        review_id, image, "order", created_date, updated_date, last_sync_date, is_deleted
                    ) VALUES (?, ?, ?, ?, 0, 0, 0)
                    """,
                arguments: [reviewID, imageURL, index, timestamp]
            )
        }
    }

    /// 在更新相关内容主记录前软删除全部旧图片，保留 Android 可同步的删除语义。
    nonisolated func deleteRelevantImages(_ db: Database, contentID: Int64, timestamp: Int64) throws {
        try db.execute(
            // SQL 目的：软删除普通相关内容原有全部有效图片子记录，为全量有序替换建立新集合。
            // 涉及表：category_image。
            // 关键过滤：按 category_content_id 精确命中且 is_deleted = 0。
            // 时间字段：updated_date 写本次保存的 Unix 毫秒时间戳。
            // 副作用：只更新图片关系状态，不删除远端对象。
            sql: "UPDATE category_image SET updated_date = ?, is_deleted = 1 WHERE category_content_id = ? AND is_deleted = 0",
            arguments: [timestamp, contentID]
        )
    }

    /// 在相关内容主记录就绪后按当前拖拽顺序重建图片集合及连续 order。
    nonisolated func insertRelevantImages(
        _ db: Database,
        contentID: Int64,
        imageURLs: [String],
        timestamp: Int64
    ) throws {
        for (index, imageURL) in imageURLs.enumerated() {
            try db.execute(
                // SQL 目的：按编辑器最终顺序重建单条相关内容图片子记录。
                // 涉及表：category_image，category_content_id 外键指向同事务已存在的 category_content。
                // 关键字段：image 保存已上传远端地址，order 使用零基连续顺序，is_deleted 固定为 0。
                // 时间字段：created_date 使用本次保存的本地毫秒时间戳，updated_date/last_sync_date 初始为 0。
                // 副作用：插入新的物理图片关系，不复用历史软删除记录。
                sql: """
                    INSERT INTO category_image (
                        category_content_id, image, "order", created_date, updated_date, last_sync_date, is_deleted
                    ) VALUES (?, ?, ?, ?, 0, 0, 0)
                    """,
                arguments: [contentID, imageURL, index, timestamp]
            )
        }
    }
}

// MARK: - Delete Transactions

private extension ContentRepository {
    /// 书摘删除对齐 Android NoteDeletionManager：物理删除导入哈希，软删除主记录、附图与标签关系。
    nonisolated func deleteNote(_ db: Database, noteId: Int64) throws {
        let updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        try db.execute(
            // SQL 目的：删除指定书摘的本地导入去重哈希；Android NoteDeletionManager 唯一物理删除的关联数据。
            // 涉及表：note_import_hash。
            // 关键过滤：按 note_id 精确命中，不触碰其他书摘哈希。
            // 时间字段：该表不维护删除时间。
            // 副作用：后续重新导入时不再把已删除书摘误判为仍存在。
            sql: "DELETE FROM note_import_hash WHERE note_id = ?",
            arguments: [noteId]
        )
        try db.execute(
            // SQL 目的：软删除指定书摘主记录，对齐 NoteDao.delete。
            // 涉及表：note。
            // 关键过滤：按 id 精确命中且仅更新有效记录。
            // 时间字段：updated_date 写同一删除事务的当前毫秒时间戳。
            // 副作用：保留同步 tombstone。
            sql: "UPDATE note SET updated_date = ?, is_deleted = 1 WHERE id = ? AND is_deleted = 0",
            arguments: [updatedAt, noteId]
        )
        try db.execute(
            // SQL 目的：软删除指定书摘全部有效附图，对齐 AttachImageDao.deleteImagesFromNote。
            // 涉及表：attach_image。
            // 关键过滤：按 note_id 精确命中有效记录。
            // 时间字段：updated_date 与主记录使用同一毫秒时间戳。
            // 副作用：保留图片关系 tombstone 供同步。
            sql: "UPDATE attach_image SET updated_date = ?, is_deleted = 1 WHERE note_id = ? AND is_deleted = 0",
            arguments: [updatedAt, noteId]
        )
        try db.execute(
            // SQL 目的：软删除指定书摘全部有效标签关系，对齐 TagNoteDao.deleteByNoteIdSync。
            // 涉及表：tag_note。
            // 关键过滤：按 note_id 精确命中有效记录。
            // 时间字段：updated_date 与主记录使用同一毫秒时间戳。
            // 副作用：保留标签关系 tombstone 供同步。
            sql: "UPDATE tag_note SET updated_date = ?, is_deleted = 1 WHERE note_id = ? AND is_deleted = 0",
            arguments: [updatedAt, noteId]
        )
    }

    /// 书评删除对齐 Android ReviewRepository：同事务软删除主记录与附图。
    nonisolated func deleteReview(_ db: Database, reviewId: Int64) throws {
        let updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        try db.execute(
            // SQL 目的：软删除指定书评主记录，对齐 ReviewDao.delete。
            // 涉及表：review。
            // 关键过滤：按 id 精确命中有效记录。
            // 时间字段：updated_date 写当前毫秒时间戳。
            // 副作用：保留书评 tombstone。
            sql: "UPDATE review SET updated_date = ?, is_deleted = 1 WHERE id = ? AND is_deleted = 0",
            arguments: [updatedAt, reviewId]
        )
        try db.execute(
            // SQL 目的：软删除指定书评全部有效附图，对齐 ReviewImageDao.deleteImagesOfReview。
            // 涉及表：review_image。
            // 关键过滤：按 review_id 精确命中有效记录。
            // 时间字段：updated_date 与主记录使用同一毫秒时间戳。
            // 副作用：保留图片关系 tombstone。
            sql: "UPDATE review_image SET updated_date = ?, is_deleted = 1 WHERE review_id = ? AND is_deleted = 0",
            arguments: [updatedAt, reviewId]
        )
    }

    /// 相关内容删除对齐 Android RelevantRepository：软删除主记录与附图。
    nonisolated func deleteRelevant(_ db: Database, contentId: Int64) throws {
        let updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        try db.execute(
            // SQL 目的：软删除指定普通相关内容或相关书籍关系，对齐 CategoryContentDao.update 路径。
            // 涉及表：category_content。
            // 关键过滤：按 id 精确命中有效记录。
            // 时间字段：Android mapper 保留原 updated_date，iOS 不额外改写。
            // 副作用：保留相关关系 tombstone。
            sql: "UPDATE category_content SET is_deleted = 1 WHERE id = ? AND is_deleted = 0",
            arguments: [contentId]
        )
        try db.execute(
            // SQL 目的：软删除指定相关内容全部有效附图，对齐 CategoryImageDao.deleteFromContent。
            // 涉及表：category_image。
            // 关键过滤：按 category_content_id 精确命中有效记录。
            // 时间字段：updated_date 写当前毫秒时间戳。
            // 副作用：保留图片关系 tombstone。
            sql: "UPDATE category_image SET updated_date = ?, is_deleted = 1 WHERE category_content_id = ? AND is_deleted = 0",
            arguments: [updatedAt, contentId]
        )
    }
}

// MARK: - Shared Helpers

private extension ContentRepository {
    /// Android 初始种子“书籍/电影/音乐/地点/人物/事件”的固定主键上界。
    nonisolated static var defaultCategoryUpperBound: Int64 { 6 }

    /// 清理并校验书内自定义分类标题，严格采用 Android 的十字符上限。
    nonisolated static func validatedCategoryTitle(_ title: String) throws -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 10 else {
            throw ContentRepositoryError.invalidCategoryTitle
        }
        return normalized
    }

    /// 复用同一在线书候选对应的有效书/占位书，未命中时创建最小 is_deleted=1 引用记录。
    nonisolated func resolveOrInsertRelatedPlaceholder(
        _ db: Database,
        seed: BookEditorSeed,
        normalizedTitle: String,
        now: Int64
    ) throws -> Int64 {
        // SQL 目的：按豆瓣 ID 或书名作者复用既有有效书/占位书，避免同一在线候选制造重复 book 主记录。
        // 涉及表：book。
        // 关键过滤：排除系统根；豆瓣 ID 有效时优先精确匹配，否则按 name/author 精确匹配；有效书优先于占位书。
        // 时间字段：不读取时间字段。
        // 返回字段用途：作为 category_content.content_book_id；未命中时继续插入占位书。
        let matchSQL = """
            SELECT id
            FROM book
            WHERE id != 0
              AND (
                  (? > 0 AND douban_id = ?)
                  OR (name = ? AND author = ?)
              )
            ORDER BY is_deleted ASC, id ASC
            LIMIT 1
            """
        let doubanID = Int64(seed.doubanId ?? 0)
        if let existingID = try Int64.fetchOne(
            db,
            sql: matchSQL,
            arguments: [doubanID, doubanID, normalizedTitle, seed.author]
        ) {
            return existingID
        }

        let bookType = seed.preferredBookType ?? .paper
        let progressUnit = seed.preferredProgressUnit ?? (bookType == .paper ? .pagination : .position)
        var record = BookRecord(
            id: nil,
            userId: try DatabaseOwnerResolver.resolveOwnerID(in: db),
            doubanId: doubanID,
            name: normalizedTitle,
            rawName: seed.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? normalizedTitle
                : seed.rawTitle,
            cover: seed.coverURL,
            author: seed.author,
            authorIntro: seed.authorIntro,
            translator: seed.translator,
            isbn: seed.isbn,
            pubDate: seed.pubDate,
            press: seed.press,
            summary: seed.summary,
            readPosition: 0,
            totalPosition: 0,
            totalPagination: Int64(seed.totalPages ?? 0),
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
            catalog: seed.catalog,
            bookMarkModifiedTime: 0,
            wordCount: seed.totalWordCount.map(Int64.init),
            createdDate: now,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 1
        )
        try record.insert(db)
        return record.id ?? db.lastInsertedRowID
    }

    /// 确认目标书仍是可写的有效书架书，供分类与相关关系事务复用同一门闩。
    nonisolated func ensureWritableBook(_ db: Database, bookID: Int64) throws {
        // SQL 目的：确认书内相关分类的所属书仍为有效本地书。
        // 涉及表：book。
        // 关键过滤：按 id 精确命中，排除系统根、已删除与业务占位书。
        // 时间字段：不读取时间字段。
        // 返回字段用途：写事务存在性门闩。
        let sql = "SELECT id FROM book WHERE id = ? AND id != 0 AND is_deleted = 0 LIMIT 1"
        guard try Int64.fetchOne(db, sql: sql, arguments: [bookID]) != nil else {
            throw ContentRepositoryError.bookNotFound
        }
    }

    /// 返回当前书管理页可编辑的自定义分类 owner；六个默认种子及其他书私有分类均被保护。
    nonisolated func manageableCategoryOwner(
        _ db: Database,
        bookID: Int64,
        categoryID: Int64
    ) throws -> Int64 {
        // SQL 目的：确认待编辑分类是全局自定义分类或当前书籍私有分类。
        // 涉及表：category。
        // 关键过滤：id 精确命中、记录有效、owner 为全局或当前书，且排除固定主键 1...6。
        // 时间字段：不读取时间字段。
        // 返回字段用途：重命名/删除条件与标题判重范围。
        let sql = """
            SELECT book_id FROM category
            WHERE id = ?
              AND (book_id = 0 OR book_id = ?)
              AND id > ?
              AND is_deleted = 0
            LIMIT 1
            """
        guard let ownerBookID = try Int64.fetchOne(
            db,
            sql: sql,
            arguments: [categoryID, bookID, Self.defaultCategoryUpperBound]
        ) else {
            throw ContentRepositoryError.categoryNotFound
        }
        return ownerBookID
    }

    /// 按 Android 规则在目标 owner 可见范围内做标题判重；私有分类同时避让全局分类名。
    nonisolated func ensureUniqueCategoryTitle(
        _ db: Database,
        ownerBookID: Int64,
        title: String,
        excludingID: Int64?
    ) throws {
        // SQL 目的：判断新建或重命名标题是否与当前书可见分类重名。
        // 涉及表：category。
        // 关键过滤：book_id=0 或当前书籍、记录有效、标题精确匹配；重命名时排除自身主键。
        // 时间字段：不读取时间字段。
        // 返回字段用途：业务唯一性门闩。
        let sql: String
        let arguments: StatementArguments
        if let excludingID {
            sql = """
                SELECT id FROM category
                WHERE (book_id = 0 OR book_id = ?)
                  AND title = ? AND is_deleted = 0 AND id != ?
                LIMIT 1
                """
            arguments = [ownerBookID, title, excludingID]
        } else {
            sql = """
                SELECT id FROM category
                WHERE (book_id = 0 OR book_id = ?)
                  AND title = ? AND is_deleted = 0
                LIMIT 1
                """
            arguments = [ownerBookID, title]
        }
        guard try Int64.fetchOne(db, sql: sql, arguments: arguments) == nil else {
            throw ContentRepositoryError.categoryAlreadyExists
        }
    }

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

    nonisolated static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// 使用稳定 ID 与 seed 对 Viewer 项排序，相同来源上下文可跨观察刷新保持随机顺序。
    nonisolated static func stablyShuffleViewerItems(
        _ items: [ContentViewerListItem],
        seed: Int64
    ) -> [ContentViewerListItem] {
        items.sorted { lhs, rhs in
            let lhsID = numericID(lhs.id)
            let rhsID = numericID(rhs.id)
            let lhsScore = stableRandomScore(id: lhsID, seed: seed)
            let rhsScore = stableRandomScore(id: rhsID, seed: seed)
            return lhsScore == rhsScore ? lhsID < rhsID : lhsScore < rhsScore
        }
    }

    nonisolated static func stableRandomScore(id: Int64, seed: Int64) -> UInt64 {
        var value = UInt64(bitPattern: id) ^ UInt64(bitPattern: seed) &+ 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    nonisolated static func numericID(_ id: ContentViewerItemID) -> Int64 {
        switch id {
        case .note(let value), .review(let value), .relevant(let value): value
        }
    }
}
