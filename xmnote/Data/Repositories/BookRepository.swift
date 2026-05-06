import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供本地数据库连接，依赖 ObservationStream 提供观察流桥接
 * [OUTPUT]: 对外提供 BookRepository（BookRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层书籍仓储实现，统一封装书架列表/详情/书摘数据读取与默认书架排序置顶写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍仓储实现，负责书架、详情与书摘订阅查询。
struct BookRepository: BookRepositoryProtocol {
    private let databaseManager: DatabaseManager

    /// 注入数据库管理器，供书架、详情和书摘查询复用同一数据源。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    /// 为书架页提供可持续订阅的数据流，任意书籍或笔记变更后会自动刷新列表。
    func observeBooks() -> AsyncThrowingStream<[BookItem], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBooks(db)
        }
    }

    /// 为首页书架提供书籍与分组混排订阅，本轮只读默认书架，不触发任何排序或置顶写入。
    func observeBookshelf(
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<[BookshelfItem], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookshelf(db, setting: setting, searchKeyword: searchKeyword)
        }
    }

    /// 为首页书架提供多维度只读快照，本轮仅聚合展示数据，不触发任何数据库写入。
    func observeBookshelfSnapshot(
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<BookshelfSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookshelfSnapshot(db, setting: setting, searchKeyword: searchKeyword)
        }
    }

    /// 按最终展示顺序提交书架排序，不更新时间戳，避免制造 Android 不会产生的同步事件。
    func updateBookshelfOrder(_ orderedItems: [BookshelfOrderItem]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try updateBookshelfOrder(db, orderedItems: orderedItems)
        }
    }

    /// 按选择顺序批量置顶 Book/Group，跳过 Android 同样会忽略的已置顶项。
    func pinBookshelfItems(_ ids: [BookshelfItemID]) async throws {
        try await databaseManager.database.dbPool.write { db in
            try pinBookshelfItems(db, ids: ids)
        }
    }

    /// 取消单个 Book/Group 置顶状态，不更新时间戳。
    func unpinBookshelfItem(_ id: BookshelfItemID) async throws {
        try await databaseManager.database.dbPool.write { db in
            try unpinBookshelfItem(db, id: id)
        }
    }

    /// 将选中普通项移动到普通区最前，置顶区不参与移动。
    func moveBookshelfItemsToStart(
        _ ids: [BookshelfItemID],
        in currentItems: [BookshelfOrderItem]
    ) async throws {
        let orderedItems = reorderedBookshelfItems(ids, in: currentItems, placement: .start)
        try await updateBookshelfOrder(orderedItems)
    }

    /// 将选中普通项移动到普通区最后，置顶区不参与移动。
    func moveBookshelfItemsToEnd(
        _ ids: [BookshelfItemID],
        in currentItems: [BookshelfOrderItem]
    ) async throws {
        let orderedItems = reorderedBookshelfItems(ids, in: currentItems, placement: .end)
        try await updateBookshelfOrder(orderedItems)
    }

    /// 为书籍详情页提供单书订阅流，用于展示基础信息、阅读状态和笔记统计。
    func observeBookDetail(bookId: Int64) -> AsyncThrowingStream<BookDetail?, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBook(db, bookId: bookId)
        }
    }

    /// 为书籍详情页提供书摘订阅流，保障新增/删除书摘后列表实时更新。
    func observeBookNotes(bookId: Int64) -> AsyncThrowingStream<[NoteExcerpt], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchNotes(db, bookId: bookId)
        }
    }

    /// 读取本地书籍选择结果，支持标题/作者/ISBN 关键字筛选。
    func fetchPickerBooks(matching query: String) async throws -> [BookPickerBook] {
        try await databaseManager.database.dbPool.read { db in
            try fetchPickerBooks(db, matching: query)
        }
    }

    /// 解析单本本地书籍，供创建成功后的选择流回填。
    func fetchPickerBook(bookId: Int64) async throws -> BookPickerBook? {
        try await databaseManager.database.dbPool.read { db in
            try fetchPickerBook(db, bookId: bookId)
        }
    }
}

nonisolated private struct IndexedBookshelfItem {
    let item: BookshelfItem
    let sourceIndex: Int
}

nonisolated private struct BookshelfGroupBookPreview {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
}

nonisolated private struct BookshelfGroupBuilder {
    let id: Int64
    let name: String
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
    private(set) var books: [BookshelfGroupBookPreview]

    mutating func append(_ book: BookshelfGroupBookPreview) {
        guard !books.contains(where: { $0.id == book.id }) else { return }
        books.append(book)
    }

    func makeItem(searchKeyword: String = "") -> BookshelfItem? {
        let sortedBooks = sortBooksByAndroidCustomOrder(books)
        let normalizedKeyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGroupMatched = normalizedKeyword.isEmpty || name.localizedCaseInsensitiveContains(normalizedKeyword)
        let visibleBooks = isGroupMatched ? sortedBooks : sortedBooks.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedKeyword)
                || $0.author.localizedCaseInsensitiveContains(normalizedKeyword)
        }
        guard !visibleBooks.isEmpty else { return nil }
        let payload = BookshelfGroupPayload(
            id: id,
            name: name,
            bookCount: visibleBooks.count,
            representativeCovers: visibleBooks.prefix(6).map(\.cover)
        )
        return BookshelfItem(
            id: .group(id),
            pinned: pinned,
            pinOrder: pinOrder,
            sortOrder: sortOrder,
            content: .group(payload)
        )
    }

    private func sortBooksByAndroidCustomOrder(_ books: [BookshelfGroupBookPreview]) -> [BookshelfGroupBookPreview] {
        let pinnedBooks = books.filter(\.pinned).sorted { lhs, rhs in
            if lhs.pinOrder != rhs.pinOrder {
                return lhs.pinOrder > rhs.pinOrder
            }
            return lhs.id < rhs.id
        }
        let notPinnedBooks = books.filter { !$0.pinned }.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.id < rhs.id
        }
        return pinnedBooks + notPinnedBooks
    }
}

nonisolated private struct BookshelfBookAggregateRow {
    let payload: BookshelfBookPayload
    let readStatusOrder: Int64
    let sourceOrder: Int64
    let sourceIsHidden: Bool
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
}

nonisolated private struct BookshelfTagInfo: Hashable {
    let id: Int64
    let name: String
    let order: Int64
}

nonisolated private struct BookshelfStatusKey: Hashable {
    let id: Int64
    let title: String
    let order: Int64
}

nonisolated private enum BookshelfMovePlacement {
    case start
    case end
}

private extension BookRepository {
    /// 按 Android `updateBookDataListOrder` 语义顺序更新 Book/Group order 字段。
    /// - Throws: 任一 SQL 写入失败时抛出错误。
    nonisolated func updateBookshelfOrder(
        _ db: Database,
        orderedItems: [BookshelfOrderItem]
    ) throws {
        for (index, item) in orderedItems.enumerated() {
            let order = Int64(index)
            switch item.id {
            case .book(let id):
                try updateBookOrder(db, id: id, order: order)
            case .group(let id):
                try updateGroupOrder(db, id: id, order: order)
            }
        }
    }

    /// 批量置顶 Book/Group，使用 Book 与 Group 的全局最大 pin_order 作为追加起点。
    /// - Throws: 任一 SQL 读取或写入失败时抛出错误。
    nonisolated func pinBookshelfItems(
        _ db: Database,
        ids: [BookshelfItemID]
    ) throws {
        var nextPinOrder = try maxBookshelfPinOrder(db)
        for id in ids {
            guard try !isBookshelfItemPinned(db, id: id) else { continue }
            nextPinOrder += 1
            try updateBookshelfPin(db, id: id, pinned: true, pinOrder: nextPinOrder)
        }
    }

    /// 取消单个 Book/Group 置顶状态，写入 pinned = 0 与 pin_order = 0。
    /// - Throws: SQL 写入失败时抛出错误。
    nonisolated func unpinBookshelfItem(
        _ db: Database,
        id: BookshelfItemID
    ) throws {
        try updateBookshelfPin(db, id: id, pinned: false, pinOrder: 0)
    }

    /// 计算移到最前/最后后的最终完整书架顺序，置顶项保持当前前缀顺序。
    nonisolated func reorderedBookshelfItems(
        _ ids: [BookshelfItemID],
        in currentItems: [BookshelfOrderItem],
        placement: BookshelfMovePlacement
    ) -> [BookshelfOrderItem] {
        let selectedIDSet = Set(ids)
        let pinnedItems = currentItems.filter(\.isPinned)
        let normalItems = currentItems.filter { !$0.isPinned }
        let normalByID = Dictionary(uniqueKeysWithValues: normalItems.map { ($0.id, $0) })
        let selectedItems = ids.compactMap { normalByID[$0] }
        let remainingItems = normalItems.filter { !selectedIDSet.contains($0.id) }

        switch placement {
        case .start:
            return pinnedItems + selectedItems + remainingItems
        case .end:
            return pinnedItems + remainingItems + selectedItems
        }
    }

    /// 更新单本书籍的手动排序值；对齐 Android BookDao.updateBookOrderSuspend。
    nonisolated func updateBookOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入 Book 默认书架手动排序下标。
        // 涉及表：book。
        // 关键过滤：严格对齐 Android，where id = ? and is_deleted = 0 and book.id != 0。
        // 副作用用途：仅更新 book_order，不更新 updated_date / last_sync_date，避免产生 Android 不会产生的同步事件。
        let sql = """
            UPDATE book
            SET book_order = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 更新单个分组的手动排序值；对齐 Android GroupDao.updateGroupOrderSuspend。
    nonisolated func updateGroupOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入 Group 默认书架手动排序下标。
        // 涉及表：`group`。
        // 关键过滤：严格对齐 Android，仅按 id 更新，不额外追加 is_deleted 条件。
        // 副作用用途：仅更新 group_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE `group`
            SET group_order = ?
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 查询 Book/Group 已置顶项的全局最大 pin_order。
    nonisolated func maxBookshelfPinOrder(_ db: Database) throws -> Int64 {
        // SQL 目的：读取 Book 已置顶项最大 pin_order。
        // 涉及表：book。
        // 关键过滤：对齐 Android queryMaxPinOrder，is_deleted = 0 且 pinned = 1。
        // 返回字段用途：与 Group 最大值合并，作为批量置顶追加起点。
        let bookSQL = """
            SELECT pin_order
            FROM book
            WHERE is_deleted = 0
              AND pinned = 1
            ORDER BY pin_order DESC
            LIMIT 1
            """
        // SQL 目的：读取 Group 已置顶项最大 pin_order。
        // 涉及表：`group`。
        // 关键过滤：对齐 Android queryMaxPinOrder，is_deleted = 0 且 pinned = 1。
        // 返回字段用途：与 Book 最大值合并，保证 Book/Group 共用 pin_order 序列。
        let groupSQL = """
            SELECT pin_order
            FROM `group`
            WHERE is_deleted = 0
              AND pinned = 1
            ORDER BY pin_order DESC
            LIMIT 1
            """
        let bookMax = try Int64.fetchOne(db, sql: bookSQL) ?? 0
        let groupMax = try Int64.fetchOne(db, sql: groupSQL) ?? 0
        return max(bookMax, groupMax)
    }

    /// 查询 Book/Group 是否已置顶，用于批量置顶跳过已有置顶项。
    nonisolated func isBookshelfItemPinned(
        _ db: Database,
        id: BookshelfItemID
    ) throws -> Bool {
        switch id {
        case .book(let bookID):
            // SQL 目的：查询指定 Book 是否已经置顶。
            // 涉及表：book。
            // 关键过滤：严格对齐 Android queryPinnedCount，仅过滤 pinned 与 id，不追加 is_deleted。
            // 返回字段用途：批量置顶时跳过已置顶 Book，保持 pin_order 追加序列。
            let sql = """
                SELECT COUNT(*)
                FROM book
                WHERE pinned = 1
                  AND id = ?
                """
            return try (Int.fetchOne(db, sql: sql, arguments: [bookID]) ?? 0) > 0
        case .group(let groupID):
            // SQL 目的：查询指定 Group 是否已经置顶。
            // 涉及表：`group`。
            // 关键过滤：严格对齐 Android queryPinnedCount，过滤 id、pinned 与 is_deleted = 0。
            // 返回字段用途：批量置顶时跳过已置顶 Group，保持 pin_order 追加序列。
            let sql = """
                SELECT COUNT(*)
                FROM `group`
                WHERE id = ?
                  AND pinned = 1
                  AND is_deleted = 0
                """
            return try (Int.fetchOne(db, sql: sql, arguments: [groupID]) ?? 0) > 0
        }
    }

    /// 写入 Book/Group 置顶字段；不更新时间戳。
    nonisolated func updateBookshelfPin(
        _ db: Database,
        id: BookshelfItemID,
        pinned: Bool,
        pinOrder: Int64
    ) throws {
        let pinnedValue: Int64 = pinned ? 1 : 0
        switch id {
        case .book(let bookID):
            // SQL 目的：更新 Book 置顶状态与 pin_order。
            // 涉及表：book。
            // 关键过滤：严格对齐 Android updatePinOrder，仅按 id 更新。
            // 副作用用途：写 pinned / pin_order，不更新 updated_date / last_sync_date。
            let sql = """
                UPDATE book
                SET pinned = ?,
                    pin_order = ?
                WHERE id = ?
                """
            try db.execute(sql: sql, arguments: [pinnedValue, pinOrder, bookID])
        case .group(let groupID):
            // SQL 目的：更新 Group 置顶状态与 pin_order。
            // 涉及表：`group`。
            // 关键过滤：严格对齐 Android updatePinOrder，仅按 id 更新。
            // 副作用用途：写 pinned / pin_order，不更新 updated_date / last_sync_date。
            let sql = """
                UPDATE `group`
                SET pinned = ?,
                    pin_order = ?
                WHERE id = ?
                """
            try db.execute(sql: sql, arguments: [pinnedValue, pinOrder, groupID])
        }
    }

    /// 查询首页书架所有浏览维度共用的只读快照。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfSnapshot(
        _ db: Database,
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) throws -> BookshelfSnapshot {
        let defaultItems = try fetchBookshelf(db, setting: setting, searchKeyword: searchKeyword)
        let allBooks = try fetchAllBookshelfBookRows(db)
        let keyword = normalizedSearchKeyword(searchKeyword)
        let filteredBooks = filterBooks(allBooks, keyword: keyword)
        let tagsByBook = try fetchBookshelfTagsByBook(db)

        return BookshelfSnapshot(
            defaultItems: defaultItems,
            statusSections: makeStatusSections(from: filteredBooks),
            tagGroups: makeTagGroups(from: filteredBooks, tagsByBook: tagsByBook),
            sourceGroups: makeSourceGroups(from: filteredBooks),
            ratingSections: makeRatingSections(from: filteredBooks),
            authorSections: makeAuthorSections(from: filteredBooks)
        )
    }

    /// 查询默认书架混排列表，对齐 Android `getDefaultBookList(CUSTOM)` 的只读展示语义。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelf(
        _ db: Database,
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        let topLevelBooks = try fetchTopLevelBookshelfBooks(db, searchKeyword: searchKeyword)
        let groups = try fetchBookshelfGroups(db, searchKeyword: searchKeyword)
        let indexedItems = (topLevelBooks + groups).enumerated().map { index, item in
            IndexedBookshelfItem(item: item, sourceIndex: index)
        }
        return sortByAndroidCustomOrder(indexedItems).map(\.item)
    }

    /// 查询不属于任何有效分组的书籍，作为默认书架顶层 Book 条目。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchTopLevelBookshelfBooks(
        _ db: Database,
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        // SQL 目的：读取默认书架中不属于有效分组的顶层书籍，并补齐有效书摘数量。
        // 涉及表：book b；LEFT JOIN note n 统计未删除书摘；LEFT JOIN read_status/source 补齐聚合展示字段；子查询使用 group_book gb JOIN `group` g 排除仍处于有效分组中的书籍。
        // 关键过滤：b.is_deleted = 0、b.id != 0；n.is_deleted = 0；gb.is_deleted = 0；g.is_deleted = 0；搜索过滤在 Swift 层按书名/作者执行。
        // 排序用途：返回 book_order / pinned / pin_order，最终在 Swift 层按 Android `formatByCustom` 统一混排。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.source_id, b.score,
                   b.read_status_id, COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(s.name, '') AS source_name,
                   b.pinned, b.pin_order, b.book_order,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON b.id = n.book_id AND n.is_deleted = 0
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            WHERE b.is_deleted = 0
              AND b.id != 0
              AND b.id NOT IN (
                  SELECT gb.book_id
                  FROM group_book gb
                  JOIN `group` g ON g.id = gb.group_id AND g.is_deleted = 0
                  WHERE gb.is_deleted = 0
            )
            GROUP BY b.id
            """
        let keyword = normalizedSearchKeyword(searchKeyword)
        return try Row.fetchAll(db, sql: sql).compactMap { row in
            let id: Int64 = row["id"]
            let name: String = row["name"] ?? ""
            let author: String = row["author"] ?? ""
            guard bookMatchesSearch(name: name, author: author, keyword: keyword) else { return nil }
            let payload = BookshelfBookPayload(
                id: id,
                name: name,
                author: author,
                cover: row["cover"] ?? "",
                readStatusId: row["read_status_id"] ?? 0,
                readStatusName: row["read_status_name"] ?? "",
                sourceId: row["source_id"] ?? 0,
                sourceName: row["source_name"] ?? "",
                score: row["score"] ?? 0,
                noteCount: row["note_count"] ?? 0
            )
            return BookshelfItem(
                id: .book(id),
                pinned: (row["pinned"] as Int64? ?? 0) != 0,
                pinOrder: row["pin_order"] ?? 0,
                sortOrder: row["book_order"] ?? 0,
                content: .book(payload)
            )
        }
    }

    /// 查询默认书架中的有效分组，过滤空分组并聚合代表封面。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfGroups(
        _ db: Database,
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        // SQL 目的：读取默认书架有效分组及其有效组内书籍，用于生成顶层 Group 条目和代表封面。
        // 涉及表：`group` g JOIN group_book gb JOIN book b。
        // 关键过滤：g.is_deleted = 0、gb.is_deleted = 0、b.is_deleted = 0、b.id != 0；无有效书籍的分组不会出现在 JOIN 结果中；搜索过滤在 Swift 层按组名/组内书名/作者执行。
        // 排序用途：返回 group_order / pinned / pin_order，以及组内 book_order / pinned / pin_order，Swift 层继续按 Android 自定义排序规则处理。
        let sql = """
            SELECT g.id AS group_id,
                   COALESCE(g.name, '') AS group_name,
                   g.group_order,
                   g.pinned AS group_pinned,
                   g.pin_order AS group_pin_order,
                   b.id AS book_id,
                   b.name AS book_name,
                   b.author AS book_author,
                   b.cover AS book_cover,
                   b.book_order AS book_order,
                   b.pinned AS book_pinned,
                   b.pin_order AS book_pin_order
            FROM `group` g
            JOIN group_book gb ON gb.group_id = g.id AND gb.is_deleted = 0
            JOIN book b ON b.id = gb.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE g.is_deleted = 0
            ORDER BY g.group_order ASC, g.id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)
        var orderedGroupIDs: [Int64] = []
        var builders: [Int64: BookshelfGroupBuilder] = [:]

        for row in rows {
            let groupID: Int64 = row["group_id"]
            if builders[groupID] == nil {
                let rawGroupName: String = row["group_name"] ?? ""
                orderedGroupIDs.append(groupID)
                builders[groupID] = BookshelfGroupBuilder(
                    id: groupID,
                    name: rawGroupName.isEmpty ? "未命名分组" : rawGroupName,
                    pinned: (row["group_pinned"] as Int64? ?? 0) != 0,
                    pinOrder: row["group_pin_order"] ?? 0,
                    sortOrder: row["group_order"] ?? 0,
                    books: []
                )
            }
            guard var builder = builders[groupID] else { continue }
            builder.append(
                BookshelfGroupBookPreview(
                    id: row["book_id"],
                    name: row["book_name"] ?? "",
                    author: row["book_author"] ?? "",
                    cover: row["book_cover"] ?? "",
                    pinned: (row["book_pinned"] as Int64? ?? 0) != 0,
                    pinOrder: row["book_pin_order"] ?? 0,
                    sortOrder: row["book_order"] ?? 0
                )
            )
            builders[groupID] = builder
        }

        return orderedGroupIDs.compactMap { groupID in
            builders[groupID]?.makeItem(searchKeyword: normalizedSearchKeyword(searchKeyword))
        }
    }

    /// 复刻 Android `BookListFormatHelper.formatByCustom` 的默认书架排序规则。
    nonisolated func sortByAndroidCustomOrder(_ items: [IndexedBookshelfItem]) -> [IndexedBookshelfItem] {
        let pinned = items
            .filter(\.item.pinned)
            .sorted { lhs, rhs in
                if lhs.item.pinOrder != rhs.item.pinOrder {
                    return lhs.item.pinOrder > rhs.item.pinOrder
                }
                return lhs.sourceIndex < rhs.sourceIndex
            }
        let notPinned = items
            .filter { !$0.item.pinned }
            .sorted { lhs, rhs in
                if lhs.item.sortOrder != rhs.item.sortOrder {
                    return lhs.item.sortOrder < rhs.item.sortOrder
                }
                return lhs.sourceIndex < rhs.sourceIndex
            }
        return pinned + notPinned
    }

    /// 查询所有有效书籍，作为非默认维度聚合的统一数据源。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchAllBookshelfBookRows(_ db: Database) throws -> [BookshelfBookAggregateRow] {
        // SQL 目的：读取所有有效书籍并补齐阅读状态、来源、评分、置顶排序和有效书摘数量，供只读维度聚合。
        // 涉及表：book b；LEFT JOIN note n 统计有效书摘；LEFT JOIN read_status rs/source s 读取维度标题与排序字段。
        // 关键过滤：b.is_deleted = 0、b.id != 0；n.is_deleted = 0；rs/s 仅连接未软删除记录。
        // 返回字段用途：Book payload 用于 UI 代表封面，order/pin/source/read_status 字段用于 Swift 层稳定聚合排序。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover,
                   b.read_status_id,
                   COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(rs.read_status_order, 999999) AS read_status_order,
                   b.source_id,
                   COALESCE(s.name, '') AS source_name,
                   COALESCE(s.source_order, 999999) AS source_order,
                   COALESCE(s.is_hide, 1) AS source_is_hide,
                   b.score, b.pinned, b.pin_order, b.book_order,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON n.book_id = b.id AND n.is_deleted = 0
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            WHERE b.is_deleted = 0
              AND b.id != 0
            GROUP BY b.id
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let payload = BookshelfBookPayload(
                id: row["id"],
                name: row["name"] ?? "",
                author: row["author"] ?? "",
                cover: row["cover"] ?? "",
                readStatusId: row["read_status_id"] ?? 0,
                readStatusName: row["read_status_name"] ?? "",
                sourceId: row["source_id"] ?? 0,
                sourceName: row["source_name"] ?? "",
                score: row["score"] ?? 0,
                noteCount: row["note_count"] ?? 0
            )
            return BookshelfBookAggregateRow(
                payload: payload,
                readStatusOrder: row["read_status_order"] ?? 999999,
                sourceOrder: row["source_order"] ?? 999999,
                sourceIsHidden: (row["source_is_hide"] as Int64? ?? 1) != 0,
                pinned: (row["pinned"] as Int64? ?? 0) != 0,
                pinOrder: row["pin_order"] ?? 0,
                sortOrder: row["book_order"] ?? 0
            )
        }
    }

    /// 查询有效书籍标签关系，供标签维度构建聚合卡。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfTagsByBook(_ db: Database) throws -> [Int64: [BookshelfTagInfo]] {
        // SQL 目的：读取书籍标签关系，供首页标签维度按书籍聚合。
        // 涉及表：tag_book tb JOIN tag t。
        // 关键过滤：tb.is_deleted = 0、t.is_deleted = 0、t.type = 1（书籍标签）。
        // 返回字段用途：book_id 用于归并，tag_order 用于标签卡排序。
        let sql = """
            SELECT tb.book_id, t.id AS tag_id, COALESCE(t.name, '') AS tag_name, t.tag_order
            FROM tag_book tb
            JOIN tag t ON t.id = tb.tag_id
            WHERE tb.is_deleted = 0
              AND t.is_deleted = 0
              AND t.type = 1
            ORDER BY t.tag_order ASC, t.id ASC
            """
        var result: [Int64: [BookshelfTagInfo]] = [:]
        for row in try Row.fetchAll(db, sql: sql) {
            let bookID: Int64 = row["book_id"]
            let tagName: String = row["tag_name"] ?? ""
            let info = BookshelfTagInfo(
                id: row["tag_id"],
                name: tagName.isEmpty ? "未命名标签" : tagName,
                order: row["tag_order"] ?? 0
            )
            result[bookID, default: []].append(info)
        }
        return result
    }

    nonisolated func filterBooks(
        _ books: [BookshelfBookAggregateRow],
        keyword: String
    ) -> [BookshelfBookAggregateRow] {
        guard !keyword.isEmpty else { return books }
        return books.filter {
            bookMatchesSearch(
                name: $0.payload.name,
                author: $0.payload.author,
                keyword: keyword
            )
        }
    }

    nonisolated func makeStatusSections(from books: [BookshelfBookAggregateRow]) -> [BookshelfSection] {
        let grouped = Dictionary(grouping: books) { row in
            statusKey(for: row)
        }
        return grouped.sorted { lhs, rhs in
            if lhs.key.order != rhs.key.order {
                return lhs.key.order < rhs.key.order
            }
            return lhs.key.id < rhs.key.id
        }.map { key, rows in
            let sortedRows = sortBooksByShelfOrder(rows)
            return BookshelfSection(
                id: "status-\(key.id)",
                title: key.title,
                subtitle: "\(sortedRows.count)本",
                books: sortedRows.map(\.payload)
            )
        }
    }

    nonisolated func makeTagGroups(
        from books: [BookshelfBookAggregateRow],
        tagsByBook: [Int64: [BookshelfTagInfo]]
    ) -> [BookshelfAggregateGroup] {
        var untaggedBooks: [BookshelfBookAggregateRow] = []
        var taggedBooks: [BookshelfTagInfo: [BookshelfBookAggregateRow]] = [:]
        for book in books {
            let tags = tagsByBook[book.payload.id] ?? []
            if tags.isEmpty {
                untaggedBooks.append(book)
            } else {
                for tag in tags {
                    taggedBooks[tag, default: []].append(book)
                }
            }
        }

        var groups: [BookshelfAggregateGroup] = []
        if !untaggedBooks.isEmpty {
            groups.append(makeAggregateGroup(
                id: "tag-untagged",
                title: "未设置标签",
                rows: untaggedBooks
            ))
        }

        groups.append(contentsOf: taggedBooks
            .sorted { lhs, rhs in
                if lhs.key.order != rhs.key.order {
                    return lhs.key.order < rhs.key.order
                }
                return lhs.key.name.localizedStandardCompare(rhs.key.name) == .orderedAscending
            }
            .map { tag, rows in
                makeAggregateGroup(id: "tag-\(tag.id)", title: tag.name, rows: rows)
            })
        return groups
    }

    nonisolated func makeSourceGroups(from books: [BookshelfBookAggregateRow]) -> [BookshelfAggregateGroup] {
        var unknownBooks: [BookshelfBookAggregateRow] = []
        var sourceBooks: [Int64: [BookshelfBookAggregateRow]] = [:]
        var sourceTitles: [Int64: String] = [:]
        var sourceOrders: [Int64: Int64] = [:]

        for book in books {
            let sourceName = book.payload.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if book.payload.sourceId == 0 || book.sourceIsHidden || sourceName.isEmpty {
                unknownBooks.append(book)
            } else {
                sourceBooks[book.payload.sourceId, default: []].append(book)
                sourceTitles[book.payload.sourceId] = sourceName
                sourceOrders[book.payload.sourceId] = book.sourceOrder
            }
        }

        var groups: [BookshelfAggregateGroup] = []
        if !unknownBooks.isEmpty {
            groups.append(makeAggregateGroup(id: "source-unknown", title: "未知来源", rows: unknownBooks))
        }
        groups.append(contentsOf: sourceBooks.keys.sorted { lhs, rhs in
            let lhsOrder = sourceOrders[lhs] ?? 999999
            let rhsOrder = sourceOrders[rhs] ?? 999999
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs < rhs
        }.map { sourceID in
            makeAggregateGroup(
                id: "source-\(sourceID)",
                title: sourceTitles[sourceID] ?? "未知来源",
                rows: sourceBooks[sourceID] ?? []
            )
        })
        return groups
    }

    nonisolated func makeRatingSections(from books: [BookshelfBookAggregateRow]) -> [BookshelfSection] {
        let grouped = Dictionary(grouping: books) { max(0, min($0.payload.score, 10)) }
        let orderedScores = grouped.keys.sorted { lhs, rhs in
            if lhs == 0 { return true }
            if rhs == 0 { return false }
            return lhs > rhs
        }
        return orderedScores.compactMap { score in
            guard let rows = grouped[score], !rows.isEmpty else { return nil }
            let sortedRows = score == 0 ? sortBooksByShelfOrder(rows) : rows.sorted {
                if $0.payload.score != $1.payload.score {
                    return $0.payload.score > $1.payload.score
                }
                return $0.payload.name.localizedStandardCompare($1.payload.name) == .orderedAscending
            }
            return BookshelfSection(
                id: "rating-\(score)",
                title: score == 0 ? "未评分" : ratingTitle(for: score),
                subtitle: "\(sortedRows.count)本",
                books: sortedRows.map(\.payload)
            )
        }
    }

    nonisolated func makeAuthorSections(from books: [BookshelfBookAggregateRow]) -> [BookshelfAuthorSection] {
        var authors: [String: [BookshelfBookAggregateRow]] = [:]
        for book in books {
            let name = normalizedAuthorName(book.payload.author)
            authors[name, default: []].append(book)
        }

        let authorGroups = authors.map { author, rows in
            makeAggregateGroup(
                id: "author-\(author)",
                title: author,
                rows: rows
            )
        }
        let grouped = Dictionary(grouping: authorGroups) { authorInitial($0.title) }
        return grouped.keys.sorted(by: authorSectionComparator).compactMap { key in
            guard let values = grouped[key] else { return nil }
            return BookshelfAuthorSection(
                id: key,
                title: key,
                authors: values.sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            )
        }
    }

    nonisolated func makeAggregateGroup(
        id: String,
        title: String,
        rows: [BookshelfBookAggregateRow]
    ) -> BookshelfAggregateGroup {
        let sortedRows = sortBooksByShelfOrder(rows)
        return BookshelfAggregateGroup(
            id: id,
            title: title,
            subtitle: "\(sortedRows.count)本",
            count: sortedRows.count,
            representativeCovers: sortedRows.prefix(6).map(\.payload.cover)
        )
    }

    nonisolated func sortBooksByShelfOrder(_ rows: [BookshelfBookAggregateRow]) -> [BookshelfBookAggregateRow] {
        rows.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            if lhs.pinned, lhs.pinOrder != rhs.pinOrder {
                return lhs.pinOrder > rhs.pinOrder
            }
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.payload.id < rhs.payload.id
        }
    }

    nonisolated func statusKey(for row: BookshelfBookAggregateRow) -> BookshelfStatusKey {
        let title = row.payload.readStatusName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row.payload.readStatusId != 0, !title.isEmpty else {
            return BookshelfStatusKey(id: 0, title: "未设置状态", order: -1)
        }
        return BookshelfStatusKey(id: row.payload.readStatusId, title: title, order: row.readStatusOrder)
    }

    nonisolated func ratingTitle(for score: Int64) -> String {
        String(format: "%.1f", Double(score) / 2.0)
    }

    nonisolated func normalizedSearchKeyword(_ searchKeyword: String?) -> String {
        searchKeyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated func bookMatchesSearch(name: String, author: String, keyword: String) -> Bool {
        guard !keyword.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(keyword)
            || author.localizedCaseInsensitiveContains(keyword)
    }

    nonisolated func normalizedAuthorName(_ author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知作者" : trimmed
    }

    nonisolated func authorInitial(_ author: String) -> String {
        guard author != "未知作者" else { return "#" }
        let transformed = author
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? author
        guard let first = transformed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "#"
        }
        let uppercased = String(first).uppercased()
        return ("A"..."Z").contains(uppercased) ? uppercased : "#"
    }

    nonisolated func authorSectionComparator(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return lhs < rhs
    }

    /// 查询书架页需要的书籍卡片数据，并补齐每本书的有效笔记数量。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBooks(_ db: Database) throws -> [BookItem] {
        // SQL 目的：读取书架列表并附带每本书的有效笔记数。
        // 表关系：book b LEFT JOIN note n（仅统计 n.is_deleted = 0）。
        // 过滤与排序：仅保留未删除书籍，按置顶状态与排序字段输出用于书架展示。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover,
                   b.read_status_id, b.pinned, b.pin_order, b.book_order,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON b.id = n.book_id AND n.is_deleted = 0
            WHERE b.is_deleted = 0
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
    nonisolated func fetchPickerBooks(_ db: Database, matching query: String) throws -> [BookPickerBook] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // SQL 目的：读取本地可选书籍列表，供通用书籍选择流本地搜索与回显。
        // 涉及表：book。
        // 关键过滤：仅保留未软删除书籍；若存在 query，则匹配 name/author/press/isbn；按 updated_date DESC 对齐 Android 最近编辑优先。
        let baseSQL = """
            SELECT id, name, author, press, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE is_deleted = 0
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
    nonisolated func fetchPickerBook(_ db: Database, bookId: Int64) throws -> BookPickerBook? {
        // SQL 目的：按主键读取单本本地书籍，供创建成功后回填到书籍选择流。
        // 涉及表：book。
        // 关键过滤：限定 id 精确命中，排除软删除书籍；返回 title/author/press/cover 与位置字段供选择行和回填使用。
        let sql = """
            SELECT id, name, author, press, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE id = ? AND is_deleted = 0
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookId]) else {
            return nil
        }
        return mapPickerBook(row)
    }

    /// 查询指定书籍详情数据，供详情页头部信息区与统计区渲染。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBook(_ db: Database, bookId: Int64) throws -> BookDetail? {
        // SQL 目的：读取单本书详情，并补充阅读状态名称与笔记总数。
        // 表关系：book b LEFT JOIN read_status rs；子查询统计 note 表有效记录。
        // 过滤条件：按 bookId 精确命中且排除软删除书籍。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.press,
                   COALESCE(rs.name, '') AS read_status_name,
                   (SELECT COUNT(*) FROM note n
                    WHERE n.book_id = b.id AND n.is_deleted = 0) AS note_count
            FROM book b
            LEFT JOIN read_status rs ON b.read_status_id = rs.id
            WHERE b.id = ? AND b.is_deleted = 0
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookId]) else {
            return nil
        }

        return BookDetail(
            id: row["id"],
            name: row["name"] ?? "",
            author: row["author"] ?? "",
            cover: row["cover"] ?? "",
            press: row["press"] ?? "",
            noteCount: row["note_count"] ?? 0,
            readStatusName: row["read_status_name"] ?? ""
        )
    }

    /// 查询书籍下的书摘列表，供详情页“书摘时间线”模块展示。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchNotes(_ db: Database, bookId: Int64) throws -> [NoteExcerpt] {
        // SQL 目的：拉取书籍下的书摘列表（详情页时间倒序）。
        // 过滤条件：限定 book_id 且排除软删除 note。
        // 返回字段：保留富文本内容、位置与 include_time，供详情页渲染。
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

    nonisolated func mapPickerBook(_ row: Row) -> BookPickerBook {
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
