import Foundation
import GRDB

/**
 * [INPUT]: 依赖 BookRepository 提供数据库读写 helper、BookshelfBookAggregateQuery 全量书籍聚合行与显示设置
 * [OUTPUT]: 为 BookRepository 补充首页书架快照、二级列表、默认分组读取、分区装配与排序比较逻辑
 * [POS]: Data 层首页书架快照装配协作者，隔离 BookRepository 主文件中的只读快照与排序策略
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

extension BookRepository {
    nonisolated func fetchBookshelfSnapshot(
        _ db: Database,
        settingsByDimension: [BookshelfDimension: BookshelfDisplaySetting],
        searchKeyword: String?
    ) throws -> BookshelfSnapshot {
        let defaultSetting = setting(for: .default, in: settingsByDimension)
        let allBooks = try BookshelfBookAggregateQuery.fetchAllRows(db)
        let defaultItems = try fetchBookshelf(
            db,
            rows: allBooks,
            setting: defaultSetting,
            searchKeyword: searchKeyword
        )
        let keyword = normalizedSearchKeyword(searchKeyword)
        let tagsByBook = try BookshelfBookAggregateQuery.fetchTagsByBook(db)

        let statusSections = makeStatusSections(
            from: allBooks,
            setting: setting(for: .status, in: settingsByDimension)
        )
        let tagGroups = makeTagGroups(
            from: allBooks,
            tagsByBook: tagsByBook,
            setting: setting(for: .tag, in: settingsByDimension)
        )
        let sourceGroups = makeSourceGroups(
            from: allBooks,
            setting: setting(for: .source, in: settingsByDimension)
        )
        let ratingSections = makeRatingSections(
            from: allBooks,
            setting: setting(for: .rating, in: settingsByDimension)
        )
        let authorSections = makeAuthorSections(
            from: allBooks,
            setting: setting(for: .author, in: settingsByDimension)
        )
        let pressGroups = makePressGroups(
            from: allBooks,
            setting: setting(for: .press, in: settingsByDimension)
        )

        return BookshelfSnapshot(
            defaultItems: defaultItems,
            defaultSections: makeDefaultSections(from: defaultItems, setting: defaultSetting),
            statusSections: filterSectionsByTitle(statusSections, keyword: keyword),
            tagGroups: filterAggregateGroupsByTitle(tagGroups, keyword: keyword),
            sourceGroups: filterAggregateGroupsByTitle(sourceGroups, keyword: keyword),
            ratingSections: filterSectionsByTitle(ratingSections, keyword: keyword),
            authorSections: filterAuthorSectionsByTitle(authorSections, keyword: keyword),
            pressGroups: filterAggregateGroupsByTitle(pressGroups, keyword: keyword)
        )
    }

    /// 查询二级书籍列表，按上下文实时读取，避免依赖导航时刻的静态数组。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfBookList(
        _ db: Database,
        context: BookshelfListContext,
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) throws -> BookshelfBookListSnapshot {
        let keyword = normalizedSearchKeyword(searchKeyword)
        let rows: [BookshelfBookAggregateRow]
        let title: String
        let allRows = try BookshelfBookAggregateQuery.fetchAllRows(db)

        switch context {
        case .defaultGroup(let groupID):
            let group = try fetchBookshelfGroupPayload(db, groupID: groupID, searchKeyword: "")
            let groupBookIDs = Set(try fetchOrderedBookIDs(inGroup: groupID, db: db))
            let filteredRows = filterBookListRows(
                allRows.filter { groupBookIDs.contains($0.payload.id) },
                keyword: keyword
            )
            let sortedRows = sortBookRows(filteredRows, setting: setting)
            title = group?.name ?? "分组"
            return BookshelfBookListSnapshot(
                title: title,
                subtitle: "\(sortedRows.count)本",
                sections: makeBookListSections(from: sortedRows, setting: setting)
            )
        case .readStatus(let statusID):
            let scopedRows = allRows.filter { row in
                if let statusID {
                    return row.payload.readStatusId == statusID
                }
                return row.payload.readStatusId == 0 || row.payload.readStatusName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            rows = filterBookListRows(scopedRows, keyword: keyword)
            title = nonEmptyString(scopedRows.first?.payload.readStatusName ?? "") ?? "未设置状态"
        case .tag(let tagID):
            let tagsByBook = try BookshelfBookAggregateQuery.fetchTagsByBook(db)
            let scopedRows: [BookshelfBookAggregateRow]
            if let tagID {
                scopedRows = allRows.filter { (tagsByBook[$0.payload.id] ?? []).contains { $0.id == tagID } }
                title = tagsByBook.values.flatMap { $0 }.first(where: { $0.id == tagID })?.name ?? "标签"
            } else {
                scopedRows = allRows.filter { (tagsByBook[$0.payload.id] ?? []).isEmpty }
                title = "未设置标签"
            }
            rows = filterBookListRows(scopedRows, keyword: keyword)
        case .source(let sourceID):
            let scopedRows: [BookshelfBookAggregateRow]
            if let sourceID {
                scopedRows = allRows.filter { $0.payload.sourceId == sourceID && !$0.sourceIsHidden }
                title = nonEmptyString(scopedRows.first?.payload.sourceName ?? "") ?? "来源"
            } else {
                scopedRows = allRows.filter {
                    $0.payload.sourceId == 0
                        || $0.sourceIsHidden
                        || $0.payload.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                title = "未知来源"
            }
            rows = filterBookListRows(scopedRows, keyword: keyword)
        case .rating(let score):
            let scopedRows = allRows.filter { ratingGroupScore(for: $0.payload.score) == score }
            rows = filterBookListRows(scopedRows, keyword: keyword)
            title = score == 0 ? "未评分" : ratingTitle(for: score)
        case .author(let author):
            let scopedRows = allRows.filter { normalizedAuthorName($0.payload.author) == author }
            rows = filterBookListRows(scopedRows, keyword: keyword)
            title = author
        case .press(let press):
            let scopedRows = allRows.filter { normalizedPressName($0.press) == press }
            rows = filterBookListRows(scopedRows, keyword: keyword)
            title = press
        }

        let sortedRows = sortBookRows(rows, setting: setting)
        return BookshelfBookListSnapshot(
            title: title,
            subtitle: "\(sortedRows.count)本",
            sections: makeBookListSections(from: sortedRows, setting: setting)
        )
    }

    /// 查询默认书架混排列表，对齐 Android `getDefaultBookList(CUSTOM)` 的只读展示语义。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelf(
        _ db: Database,
        rows: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        let topLevelBooks = try makeTopLevelBookshelfBookItems(
            db,
            rows: rows,
            searchKeyword: searchKeyword
        )
        let groups = try fetchBookshelfGroups(db, searchKeyword: searchKeyword)
        let indexedItems = (topLevelBooks + groups).enumerated().map { index, item in
            IndexedBookshelfItem(item: item, sourceIndex: index)
        }
        return sortBookshelfItems(indexedItems, setting: setting).map(\.item)
    }

    /// 从全量聚合行中过滤默认书架顶层书籍，保留 Android 同源列表展示模型。
    /// - Throws: 分组排除关系查询失败时抛出错误。
    nonisolated func makeTopLevelBookshelfBookItems(
        _ db: Database,
        rows: [BookshelfBookAggregateRow],
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        let groupedBookIDs = try fetchGroupedBookshelfBookIDs(db)
        let keyword = normalizedSearchKeyword(searchKeyword)
        return rows.compactMap { row in
            guard !groupedBookIDs.contains(row.payload.id),
                  bookListMatchesSearch(
                    name: row.payload.name,
                    author: row.payload.author,
                    keyword: keyword
                  ) else {
                return nil
            }
            return row.bookshelfItem
        }
    }

    /// 查询仍属于有效分组的书籍 ID，用于默认书架顶层列表排除组内书。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchGroupedBookshelfBookIDs(_ db: Database) throws -> Set<Int64> {
        // SQL 目的：查询所有仍属于有效分组的书籍 ID，供默认书架顶层列表排除组内书。
        // 涉及表：group_book gb 与 `group` g；通过 gb.group_id 关联分组表。
        // 关键过滤：gb.is_deleted = 0、g.is_deleted = 0、gb.book_id != 0；仅保留未删除分组中的未删除关联关系。
        // 返回字段用途：book_id 用于与 fetchAllBookshelfBookRows 返回的全量书籍聚合行做集合差集。
        let sql = """
            SELECT DISTINCT gb.book_id
            FROM group_book gb
            INNER JOIN `group` g ON g.id = gb.group_id AND g.is_deleted = 0
            WHERE gb.is_deleted = 0
              AND gb.book_id != 0
            """
        return Set(try Int64.fetchAll(db, sql: sql))
    }

    /// 查询不属于任何有效分组的书籍，作为默认书架顶层 Book 条目。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchTopLevelBookshelfBooks(
        _ db: Database,
        searchKeyword: String?
    ) throws -> [BookshelfItem] {
        // SQL 目的：读取默认书架中不属于有效分组的顶层书籍，并补齐有效书摘数量、阅读时长与条件排序字段。
        // 涉及表：book b；LEFT JOIN note n 统计未删除书摘；LEFT JOIN read_status/source 补齐聚合展示字段；LEFT JOIN read_time_record 聚合已完成阅读秒数；子查询使用 group_book gb JOIN `group` g 排除仍处于有效分组中的书籍。
        // 关键过滤：b.is_deleted = 0、b.id != 0；n.is_deleted = 0；read_time_record.status = 3；gb.is_deleted = 0；g.is_deleted = 0；搜索过滤在 Swift 层按书名/作者执行。
        // 排序用途：返回 book_order / pinned / pin_order、created_date / updated_date / pub_date / read_status_changed_date / read_position 等字段，最终在 Swift 层按 Android 显示设置统一混排。
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.pub_date, b.source_id, b.score,
                   b.read_status_id, COALESCE(rs.name, '') AS read_status_name,
                   COALESCE(s.name, '') AS source_name,
                   b.pinned, b.pin_order, b.book_order,
                   b.created_date, b.updated_date, b.read_status_changed_date,
                   b.read_position, b.total_position, b.total_pagination,
                   COALESCE(rt.total_reading_time, 0) AS total_reading_time,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON b.id = n.book_id AND n.is_deleted = 0
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            LEFT JOIN (
                SELECT book_id, SUM(elapsed_seconds) AS total_reading_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND status = 3
                  AND book_id != 0
                GROUP BY book_id
            ) rt ON rt.book_id = b.id
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
            let readStatusName: String = row["read_status_name"] ?? ""
            let sourceName: String = row["source_name"] ?? ""
            guard bookListMatchesSearch(
                name: name,
                author: author,
                keyword: keyword
            ) else {
                return nil
            }
            let payload = BookshelfBookPayload(
                id: id,
                name: name,
                author: author,
                cover: row["cover"] ?? "",
                readStatusId: row["read_status_id"] ?? 0,
                readStatusName: readStatusName,
                sourceId: row["source_id"] ?? 0,
                sourceName: sourceName,
                press: "",
                score: row["score"] ?? 0,
                noteCount: row["note_count"] ?? 0
            )
            return BookshelfItem(
                id: .book(id),
                pinned: (row["pinned"] as Int64? ?? 0) != 0,
                pinOrder: row["pin_order"] ?? 0,
                sortOrder: row["book_order"] ?? 0,
                sortMetadata: BookshelfItemSortMetadata(
                    createdDate: row["created_date"] ?? 0,
                    modifiedDate: row["updated_date"] ?? 0,
                    publishDate: BookshelfBookPresentationFormatter.publishTimestamp(from: row["pub_date"] ?? ""),
                    noteCount: row["note_count"] ?? 0,
                    rating: row["score"] ?? 0,
                    readDoneDate: row["read_status_changed_date"] ?? 0,
                    totalReadingTime: row["total_reading_time"] ?? 0,
                    readingProgress: BookshelfBookPresentationFormatter.readingProgress(
                        readPosition: row["read_position"] ?? 0.0,
                        totalPosition: row["total_position"] ?? 0,
                        totalPagination: row["total_pagination"] ?? 0
                    ),
                    bookCount: 1
                ),
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
        // SQL 目的：读取默认书架有效分组及其有效组内书籍，用于生成顶层 Group 条目、代表封面和条件排序元数据。
        // 涉及表：`group` g JOIN group_book gb JOIN book b；LEFT JOIN read_time_record 聚合组内书籍已完成阅读秒数。
        // 关键过滤：g.is_deleted = 0、gb.is_deleted = 0、b.is_deleted = 0、b.id != 0、read_time_record.status = 3；无有效书籍的分组不会出现在 JOIN 结果中；搜索过滤在 Swift 层只按组名执行。
        // 排序用途：返回 group_order / pinned / pin_order、group/book 创建修改时间、出版时间、评分、读完时间、阅读进度等字段，Swift 层继续按 Android 显示设置处理。
        let sql = """
            SELECT g.id AS group_id,
                   COALESCE(g.name, '') AS group_name,
                   g.group_order,
                   g.pinned AS group_pinned,
                   g.pin_order AS group_pin_order,
                   g.created_date AS group_created_date,
                   b.id AS book_id,
                   b.name AS book_name,
                   b.author AS book_author,
                   b.cover AS book_cover,
                   b.pub_date AS book_pub_date,
                   COALESCE(rs.name, '') AS book_read_status_name,
                   COALESCE(s.name, '') AS book_source_name,
                   (
                       SELECT COUNT(n.id)
                       FROM note n
                       WHERE n.book_id = b.id
                         AND n.is_deleted = 0
                   ) AS note_count,
                   b.created_date AS book_created_date,
                   b.updated_date AS book_updated_date,
                   b.score AS book_score,
                   b.read_status_changed_date AS book_read_status_changed_date,
                   b.read_position AS book_read_position,
                   b.total_position AS book_total_position,
                   b.total_pagination AS book_total_pagination,
                   COALESCE(rt.total_reading_time, 0) AS book_total_reading_time,
                   b.book_order AS book_order,
                   b.pinned AS book_pinned,
                   b.pin_order AS book_pin_order
            FROM `group` g
            JOIN group_book gb ON gb.group_id = g.id AND gb.is_deleted = 0
            JOIN book b ON b.id = gb.book_id AND b.is_deleted = 0 AND b.id != 0
            LEFT JOIN read_status rs ON rs.id = b.read_status_id AND rs.is_deleted = 0
            LEFT JOIN source s ON s.id = b.source_id AND s.is_deleted = 0
            LEFT JOIN (
                SELECT book_id, SUM(elapsed_seconds) AS total_reading_time
                FROM read_time_record
                WHERE is_deleted = 0
                  AND status = 3
                  AND book_id != 0
                GROUP BY book_id
            ) rt ON rt.book_id = b.id
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
                    createdDate: row["group_created_date"] ?? 0,
                    books: []
                )
            }
            guard var builder = builders[groupID] else { continue }
            builder.append(
                BookshelfGroupBookPreview(
                    id: row["book_id"],
                    name: row["book_name"] ?? "",
                    author: row["book_author"] ?? "",
                    readStatusName: row["book_read_status_name"] ?? "",
                    sourceName: row["book_source_name"] ?? "",
                    cover: row["book_cover"] ?? "",
                    noteCount: row["note_count"] ?? 0,
                    createdDate: row["book_created_date"] ?? 0,
                    modifiedDate: row["book_updated_date"] ?? 0,
                    publishDate: BookshelfBookPresentationFormatter.publishTimestamp(from: row["book_pub_date"] ?? ""),
                    score: row["book_score"] ?? 0,
                    readDoneDate: row["book_read_status_changed_date"] ?? 0,
                    totalReadingTime: row["book_total_reading_time"] ?? 0,
                    readingProgress: BookshelfBookPresentationFormatter.readingProgress(
                        readPosition: row["book_read_position"] ?? 0.0,
                        totalPosition: row["book_total_position"] ?? 0,
                        totalPagination: row["book_total_pagination"] ?? 0
                    ),
                    pinned: (row["book_pinned"] as Int64? ?? 0) != 0,
                    pinOrder: row["book_pin_order"] ?? 0,
                    sortOrder: row["book_order"] ?? 0
                )
            )
            builders[groupID] = builder
        }

        let groupBookListSetting = defaultGroupBookListSetting()
        let keyword = normalizedSearchKeyword(searchKeyword)
        return orderedGroupIDs.compactMap { groupID in
            guard let builder = builders[groupID] else { return nil }
            guard titleMatchesSearch(builder.name, keyword: keyword) else { return nil }
            return builder.makeItem(
                sortedBooks: sortGroupPreviewBooks(builder.books, setting: groupBookListSetting)
            )
        }
    }

    /// 查询单个默认分组的组内书籍，用于二级列表实时观察。
    /// - Throws: 数据库查询失败时抛出错误。
    nonisolated func fetchBookshelfGroupPayload(
        _ db: Database,
        groupID: Int64,
        searchKeyword: String
    ) throws -> BookshelfGroupPayload? {
        let items = try fetchBookshelfGroups(db, searchKeyword: searchKeyword)
        return items.compactMap { item -> BookshelfGroupPayload? in
            guard case .group(let payload) = item.content, payload.id == groupID else {
                return nil
            }
            return payload
        }.first
    }

    nonisolated func fetchBookIDs(inGroup groupID: Int64, db: Database) throws -> Set<Int64> {
        // SQL 目的：读取指定有效分组下仍有效的书籍 ID，供二级分组列表按当前显示设置重新排序。
        // 涉及表：group_book gb JOIN `group` g JOIN book b。
        // 关键过滤：gb.group_id = ?；gb/g/b 均要求 is_deleted = 0，b.id != 0。
        // 返回字段用途：仅用于在 Swift 层筛选 `fetchAllBookshelfBookRows` 已补齐的排序元数据，不产生写入副作用。
        let sql = """
            SELECT gb.book_id
            FROM group_book gb
            JOIN `group` g ON g.id = gb.group_id AND g.is_deleted = 0
            JOIN book b ON b.id = gb.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE gb.is_deleted = 0
              AND gb.group_id = ?
            """
        return Set(try Int64.fetchAll(db, sql: sql, arguments: [groupID]))
    }

    nonisolated func fetchOrderedBookIDs(inGroup groupID: Int64, db: Database) throws -> [Int64] {
        // SQL 目的：读取指定有效分组下仍有效书籍的当前 Android 自定义排序顺序。
        // 涉及表：group_book gb JOIN `group` g JOIN book b。
        // 关键过滤：gb.group_id = ?；gb/g/b 均要求 is_deleted = 0，b.id != 0；同一本书存在多个有效关系时仅保留最早关系。
        // 返回字段用途：组内拖拽排序写入前校验候选 ID，并为漏传书籍补齐稳定尾部顺序。
        let sql = """
            SELECT b.id
            FROM group_book gb
            JOIN `group` g ON g.id = gb.group_id AND g.is_deleted = 0
            JOIN book b ON b.id = gb.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE gb.is_deleted = 0
              AND gb.group_id = ?
              AND gb.id = (
                  SELECT gb2.id
                  FROM group_book gb2
                  WHERE gb2.book_id = b.id
                    AND gb2.is_deleted = 0
                  ORDER BY gb2.created_date ASC, gb2.id ASC
                  LIMIT 1
              )
            ORDER BY b.pinned DESC, b.pin_order DESC, b.book_order ASC, b.id ASC
            """
        return try Int64.fetchAll(db, sql: sql, arguments: [groupID])
    }

    nonisolated func maxBookPinOrder(inGroup groupID: Int64, db: Database) throws -> Int64 {
        // SQL 目的：读取指定分组内有效书籍的最大 pin_order。
        // 涉及表：group_book JOIN book。
        // 关键过滤：group_book.group_id = ?，book/group_book 均未软删除。
        // 返回字段用途：组内批量置顶时从最大 pin_order 之后连续追加。
        let sql = """
            SELECT MAX(book.pin_order)
            FROM group_book
            JOIN book ON group_book.book_id = book.id
            WHERE group_book.group_id = ?
              AND book.is_deleted = 0
              AND group_book.is_deleted = 0
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [groupID]) ?? 0
    }

    nonisolated func isBookPinned(_ db: Database, bookID: Int64) throws -> Bool {
        // SQL 目的：查询指定 Book 是否已经置顶。
        // 涉及表：book。
        // 关键过滤：严格对齐 Android queryPinnedCount，仅过滤 pinned 与 id，不追加 is_deleted。
        // 返回字段用途：组内批量置顶时跳过已置顶 Book。
        let sql = """
            SELECT COUNT(*)
            FROM book
            WHERE pinned = 1
              AND id = ?
            """
        return try (Int.fetchOne(db, sql: sql, arguments: [bookID]) ?? 0) > 0
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

    /// 按当前显示设置排序默认书架 Book/Group，条件排序时保留 Android 的可选置顶前置语义。
    nonisolated func sortBookshelfItems(
        _ items: [IndexedBookshelfItem],
        setting: BookshelfDisplaySetting
    ) -> [IndexedBookshelfItem] {
        guard setting.sortCriteria != .custom else {
            return sortByAndroidCustomOrder(items)
        }
        return sortedWithOptionalPinned(
            items,
            setting: setting,
            isPinned: { $0.item.pinned },
            pinOrder: { $0.item.pinOrder }
        ) { lhs, rhs in
            compareBookshelfItems(lhs, rhs, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    nonisolated func sortedWithOptionalPinned<T>(
        _ values: [T],
        setting: BookshelfDisplaySetting,
        isPinned: (T) -> Bool,
        pinOrder: (T) -> Int64,
        comparator: (T, T) -> Bool
    ) -> [T] {
        guard setting.pinnedInAllSorts else {
            return values.sorted(by: comparator)
        }
        let pinned = values.filter(isPinned).sorted {
            let lhsPinOrder = pinOrder($0)
            let rhsPinOrder = pinOrder($1)
            if lhsPinOrder != rhsPinOrder {
                return lhsPinOrder > rhsPinOrder
            }
            return comparator($0, $1)
        }
        let normal = values.filter { !isPinned($0) }.sorted(by: comparator)
        return pinned + normal
    }

    nonisolated func filterBookListRows(
        _ books: [BookshelfBookAggregateRow],
        keyword: String
    ) -> [BookshelfBookAggregateRow] {
        guard !keyword.isEmpty else { return books }
        return books.filter {
            bookListMatchesSearch(
                name: $0.payload.name,
                author: $0.payload.author,
                keyword: keyword
            )
        }
    }

    nonisolated func filterSectionsByTitle(
        _ sections: [BookshelfSection],
        keyword: String
    ) -> [BookshelfSection] {
        guard !keyword.isEmpty else { return sections }
        return sections.filter { titleMatchesSearch($0.title, keyword: keyword) }
    }

    nonisolated func filterAggregateGroupsByTitle(
        _ groups: [BookshelfAggregateGroup],
        keyword: String
    ) -> [BookshelfAggregateGroup] {
        guard !keyword.isEmpty else { return groups }
        return groups.filter { titleMatchesSearch($0.title, keyword: keyword) }
    }

    nonisolated func filterAuthorSectionsByTitle(
        _ sections: [BookshelfAuthorSection],
        keyword: String
    ) -> [BookshelfAuthorSection] {
        guard !keyword.isEmpty else { return sections }
        return sections.compactMap { section in
            let authors = section.authors.filter { titleMatchesSearch($0.title, keyword: keyword) }
            guard !authors.isEmpty else { return nil }
            return BookshelfAuthorSection(
                id: section.id,
                title: section.title,
                authors: authors
            )
        }
    }

    nonisolated func makeStatusSections(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfSection] {
        let grouped = Dictionary(grouping: books) { row in
            statusKey(for: row)
        }
        let sections = grouped.sorted { lhs, rhs in
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
                context: .readStatus(key.id == 0 ? nil : key.id),
                orderID: key.id == 0 ? nil : key.id,
                sortMetadata: sortMetadata(from: sortedRows),
                books: sortedRows.map(\.payload)
            )
        }
        return sortAggregateSections(sections, dimension: .status, setting: setting)
    }

    nonisolated func makeTagGroups(
        from books: [BookshelfBookAggregateRow],
        tagsByBook: [Int64: [BookshelfTagInfo]],
        setting: BookshelfDisplaySetting
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
                context: .tag(nil),
                orderID: nil,
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
                makeAggregateGroup(
                    id: "tag-\(tag.id)",
                    title: tag.name,
                    context: .tag(tag.id),
                    orderID: tag.id,
                    rows: rows
                )
            })
        return sortAggregateGroups(groups, dimension: .tag, setting: setting)
    }

    nonisolated func makeSourceGroups(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAggregateGroup] {
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
            groups.append(makeAggregateGroup(
                id: "source-unknown",
                title: "未知来源",
                context: .source(nil),
                orderID: nil,
                rows: unknownBooks
            ))
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
                context: .source(sourceID),
                orderID: sourceID,
                rows: sourceBooks[sourceID] ?? []
            )
        })
        return sortAggregateGroups(groups, dimension: .source, setting: setting)
    }

    nonisolated func makeRatingSections(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfSection] {
        let grouped: [Int64: [BookshelfBookAggregateRow]] = Dictionary(grouping: books) { row in
            ratingGroupScore(for: row.payload.score)
        }
        let orderedScores = grouped.keys.sorted { lhs, rhs in
            if lhs == 0 { return true }
            if rhs == 0 { return false }
            return lhs > rhs
        }
        let sections: [BookshelfSection] = orderedScores.compactMap { score in
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
                context: .rating(score),
                orderID: nil,
                sortMetadata: sortMetadata(from: sortedRows),
                books: sortedRows.map(\.payload)
            )
        }
        return sortAggregateSections(sections, dimension: .rating, setting: setting)
    }

    nonisolated func makeAuthorSections(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAuthorSection] {
        var authors: [String: [BookshelfBookAggregateRow]] = [:]
        for book in books {
            let name = normalizedAuthorName(book.payload.author)
            authors[name, default: []].append(book)
        }

        let authorGroups = authors.map { author, rows in
            makeAggregateGroup(
                id: "author-\(author)",
                title: author,
                context: .author(author),
                orderID: nil,
                rows: rows
            )
        }
        let sortedGroups = sortAggregateGroups(authorGroups, dimension: .author, setting: setting)
        guard setting.sortCriteria == .authorName else {
            return [
                BookshelfAuthorSection(
                    id: "author-all",
                    title: "",
                    authors: sortedGroups
                )
            ]
        }

        let grouped = Dictionary(grouping: sortedGroups) { authorInitial($0.title) }
        return grouped.keys.sorted { lhs, rhs in
            authorSectionComparator(lhs, rhs, order: setting.sortOrder)
        }.compactMap { key in
            guard let values = grouped[key] else { return nil }
            return BookshelfAuthorSection(
                id: key,
                title: key,
                authors: sortAggregateGroups(values, dimension: .author, setting: setting)
            )
        }
    }

    nonisolated func makePressGroups(
        from books: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAggregateGroup] {
        var presses: [String: [BookshelfBookAggregateRow]] = [:]
        for book in books {
            let press = normalizedPressName(book.press)
            presses[press, default: []].append(book)
        }

        let groups = presses.map { press, rows in
            makeAggregateGroup(
                id: "press-\(press)",
                title: press,
                context: .press(press),
                orderID: nil,
                rows: rows
            )
        }
        return sortAggregateGroups(groups, dimension: .press, setting: setting)
    }

    nonisolated func makeAggregateGroup(
        id: String,
        title: String,
        context: BookshelfListContext,
        orderID: Int64?,
        rows: [BookshelfBookAggregateRow]
    ) -> BookshelfAggregateGroup {
        let sortedRows = sortBooksByShelfOrder(rows)
        return BookshelfAggregateGroup(
            id: id,
            title: title,
            subtitle: "\(sortedRows.count)本",
            count: sortedRows.count,
            context: context,
            orderID: orderID,
            sortMetadata: sortMetadata(from: sortedRows),
            representativeCovers: sortedRows.prefix(6).map(\.payload.cover),
            books: sortedRows.map(\.listItem)
        )
    }

    /// 按当前显示设置生成默认书架分区；未启用分区时返回单个无标题 section。
    nonisolated func makeDefaultSections(
        from items: [BookshelfItem],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfDefaultSection] {
        guard !items.isEmpty else { return [] }
        guard setting.isSectionEnabled, setting.sortCriteria.supportsSection else {
            return [
                BookshelfDefaultSection(
                    id: "default",
                    title: nil,
                    items: items
                )
            ]
        }
        var orderedKeys: [BookshelfDisplaySectionKey] = []
        var groupedItems: [BookshelfDisplaySectionKey: [BookshelfItem]] = [:]
        for item in items {
            let key = sectionKey(for: item, criteria: setting.sortCriteria)
            if groupedItems[key] == nil {
                orderedKeys.append(key)
            }
            groupedItems[key, default: []].append(item)
        }
        return orderedKeys.map { key in
            BookshelfDefaultSection(
                id: key.id,
                title: key.title,
                items: groupedItems[key] ?? []
            )
        }
    }

    /// 按二级列表显示设置生成书籍分区；未启用分区时返回单个无标题 section。
    nonisolated func makeBookListSections(
        from rows: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfBookListSection] {
        guard !rows.isEmpty else { return [] }
        guard setting.isSectionEnabled, setting.sortCriteria.supportsSection else {
            return [
                BookshelfBookListSection(
                    id: "books",
                    title: nil,
                    books: rows.map(\.listItem)
                )
            ]
        }
        var orderedKeys: [BookshelfDisplaySectionKey] = []
        var groupedRows: [BookshelfDisplaySectionKey: [BookshelfBookAggregateRow]] = [:]
        for row in rows {
            let key = sectionKey(for: row, criteria: setting.sortCriteria)
            if groupedRows[key] == nil {
                orderedKeys.append(key)
            }
            groupedRows[key, default: []].append(row)
        }
        return orderedKeys.map { key in
            BookshelfBookListSection(
                id: key.id,
                title: key.title,
                books: (groupedRows[key] ?? []).map(\.listItem)
            )
        }
    }

    /// 对聚合卡执行 Repository 级排序，保留未设置标签/来源/状态/评分的 Android 前置语义。
    nonisolated func sortAggregateGroups(
        _ groups: [BookshelfAggregateGroup],
        dimension: BookshelfDimension,
        setting: BookshelfDisplaySetting
    ) -> [BookshelfAggregateGroup] {
        guard setting.sortCriteria != .custom else { return groups }
        let fixedGroups = groups.filter { isFixedLeadingAggregate($0, dimension: dimension) }
        let sortableGroups = groups.filter { !isFixedLeadingAggregate($0, dimension: dimension) }
        return fixedGroups + sortableGroups.sorted {
            compareAggregateGroups($0, $1, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    /// 对状态/评分这类 section 聚合执行 Repository 级排序。
    nonisolated func sortAggregateSections(
        _ sections: [BookshelfSection],
        dimension: BookshelfDimension,
        setting: BookshelfDisplaySetting
    ) -> [BookshelfSection] {
        guard setting.sortCriteria != .custom else { return sections }
        let fixedSections = sections.filter { isFixedLeadingSection($0, dimension: dimension) }
        let sortableSections = sections.filter { !isFixedLeadingSection($0, dimension: dimension) }
        return fixedSections + sortableSections.sorted {
            compareAggregateSections($0, $1, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    nonisolated func isFixedLeadingAggregate(_ group: BookshelfAggregateGroup, dimension: BookshelfDimension) -> Bool {
        switch dimension {
        case .status, .tag, .source:
            return group.orderID == nil
        case .rating:
            if case .rating(let score) = group.context {
                return score == 0
            }
            return false
        case .default, .author, .press:
            return false
        }
    }

    nonisolated func isFixedLeadingSection(_ section: BookshelfSection, dimension: BookshelfDimension) -> Bool {
        switch dimension {
        case .status:
            return section.orderID == nil
        case .rating:
            if case .rating(let score) = section.context {
                return score == 0
            }
            return false
        case .default, .tag, .source, .author, .press:
            return false
        }
    }

    nonisolated func compareAggregateGroups(
        _ lhs: BookshelfAggregateGroup,
        _ rhs: BookshelfAggregateGroup,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        let tieBreaker = lhs.id < rhs.id
        switch criteria {
        case .custom:
            return tieBreaker
        case .bookCount:
            return compareInt(Int64(lhs.count), Int64(rhs.count), order: order, missingLast: false, tie: tieBreaker)
        case .createdDate:
            return compareInt(lhs.sortMetadata.createdDate, rhs.sortMetadata.createdDate, order: order, missingLast: false, tie: tieBreaker)
        case .modifiedDate:
            return compareInt(lhs.sortMetadata.modifiedDate, rhs.sortMetadata.modifiedDate, order: order, missingLast: false, tie: tieBreaker)
        case .publishDate:
            return compareInt(lhs.sortMetadata.publishDate, rhs.sortMetadata.publishDate, order: order, missingLast: true, tie: tieBreaker)
        case .noteCount:
            return compareNoteCount(Int64(lhs.sortMetadata.noteCount), Int64(rhs.sortMetadata.noteCount), order: order, tie: tieBreaker)
        case .rating:
            return compareInt(lhs.sortMetadata.rating, rhs.sortMetadata.rating, order: order, missingLast: true, tie: tieBreaker)
        case .readDoneDate:
            return compareInt(lhs.sortMetadata.readDoneDate, rhs.sortMetadata.readDoneDate, order: order, missingLast: true, tie: tieBreaker)
        case .totalReadingTime:
            return compareInt(lhs.sortMetadata.totalReadingTime, rhs.sortMetadata.totalReadingTime, order: order, missingLast: true, tie: tieBreaker)
        case .readingProgress:
            return compareOptionalDouble(lhs.sortMetadata.readingProgress, rhs.sortMetadata.readingProgress, order: order, tie: tieBreaker)
        case .name, .readStatus, .tagName, .authorName, .pressName, .source:
            return compareText(lhs.title, rhs.title, order: order, tie: tieBreaker)
        }
    }

    nonisolated func compareAggregateSections(
        _ lhs: BookshelfSection,
        _ rhs: BookshelfSection,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        compareAggregateGroups(
            BookshelfAggregateGroup(
                id: lhs.id,
                title: lhs.title,
                subtitle: lhs.subtitle,
                count: lhs.count,
                context: lhs.context,
                orderID: lhs.orderID,
                sortMetadata: lhs.sortMetadata,
                representativeCovers: [],
                books: []
            ),
            BookshelfAggregateGroup(
                id: rhs.id,
                title: rhs.title,
                subtitle: rhs.subtitle,
                count: rhs.count,
                context: rhs.context,
                orderID: rhs.orderID,
                sortMetadata: rhs.sortMetadata,
                representativeCovers: [],
                books: []
            ),
            criteria: criteria,
            order: order
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

    nonisolated func sortBookRows(
        _ rows: [BookshelfBookAggregateRow],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfBookAggregateRow] {
        guard setting.sortCriteria != .custom else {
            return sortBooksByShelfOrder(rows)
        }
        return sortedWithOptionalPinned(
            rows,
            setting: setting,
            isPinned: { $0.pinned },
            pinOrder: { $0.pinOrder }
        ) { lhs, rhs in
            compareBookRows(lhs, rhs, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    /// 按默认分组二级列表设置排序分组预览书籍；这是只读展示排序，不回写 book_order 或 pin_order。
    nonisolated func sortGroupPreviewBooks(
        _ books: [BookshelfGroupBookPreview],
        setting: BookshelfDisplaySetting
    ) -> [BookshelfGroupBookPreview] {
        guard setting.sortCriteria != .custom else {
            return sortGroupPreviewBooksByShelfOrder(books)
        }
        return sortedWithOptionalPinned(
            books,
            setting: setting,
            isPinned: { $0.pinned },
            pinOrder: { $0.pinOrder }
        ) { lhs, rhs in
            compareGroupPreviewBooks(lhs, rhs, criteria: setting.sortCriteria, order: setting.sortOrder)
        }
    }

    /// 复刻 Android DEFAULT 分组手动排序：置顶书按 pin_order 倒序，普通书按 book_order 正序。
    nonisolated func sortGroupPreviewBooksByShelfOrder(
        _ books: [BookshelfGroupBookPreview]
    ) -> [BookshelfGroupBookPreview] {
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

    nonisolated func sortMetadata(from rows: [BookshelfBookAggregateRow]) -> BookshelfItemSortMetadata {
        BookshelfItemSortMetadata(
            createdDate: rows.map(\.createdDate).min() ?? 0,
            modifiedDate: rows.map(\.modifiedDate).max() ?? 0,
            publishDate: rows.map(\.publishDate).max() ?? 0,
            noteCount: rows.reduce(0) { $0 + $1.payload.noteCount },
            rating: rows.map(\.payload.score).max() ?? 0,
            readDoneDate: rows.map(\.readDoneDate).max() ?? 0,
            totalReadingTime: rows.reduce(0) { $0 + $1.totalReadingTime },
            readingProgress: nil,
            bookCount: rows.count
        )
    }

    nonisolated func compareBookshelfItems(
        _ lhs: IndexedBookshelfItem,
        _ rhs: IndexedBookshelfItem,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        let lhsItem = lhs.item
        let rhsItem = rhs.item
        let tieBreaker = lhs.sourceIndex < rhs.sourceIndex
        switch criteria {
        case .custom:
            return tieBreaker
        case .createdDate:
            return compareInt(lhsItem.sortMetadata.createdDate, rhsItem.sortMetadata.createdDate, order: order, missingLast: false, tie: tieBreaker)
        case .modifiedDate:
            return compareInt(lhsItem.sortMetadata.modifiedDate, rhsItem.sortMetadata.modifiedDate, order: order, missingLast: false, tie: tieBreaker)
        case .publishDate:
            return compareInt(lhsItem.sortMetadata.publishDate, rhsItem.sortMetadata.publishDate, order: order, missingLast: true, tie: tieBreaker)
        case .name, .readStatus, .tagName, .authorName, .pressName, .source:
            return compareText(lhsItem.title, rhsItem.title, order: order, tie: tieBreaker)
        case .noteCount:
            let lhsIsBook = isBookItem(lhsItem)
            let rhsIsBook = isBookItem(rhsItem)
            if lhsIsBook != rhsIsBook {
                return lhsIsBook
            }
            guard lhsIsBook else {
                return compareInt(lhsItem.sortMetadata.createdDate, rhsItem.sortMetadata.createdDate, order: order, missingLast: false, tie: tieBreaker)
            }
            return compareNoteCount(Int64(lhsItem.sortMetadata.noteCount), Int64(rhsItem.sortMetadata.noteCount), order: order, tie: tieBreaker)
        case .bookCount:
            return compareInt(Int64(lhsItem.sortMetadata.bookCount), Int64(rhsItem.sortMetadata.bookCount), order: order, missingLast: false, tie: tieBreaker)
        case .rating:
            return compareInt(lhsItem.sortMetadata.rating, rhsItem.sortMetadata.rating, order: order, missingLast: true, tie: tieBreaker)
        case .readDoneDate:
            return compareInt(lhsItem.sortMetadata.readDoneDate, rhsItem.sortMetadata.readDoneDate, order: order, missingLast: true, tie: tieBreaker)
        case .totalReadingTime:
            return compareInt(lhsItem.sortMetadata.totalReadingTime, rhsItem.sortMetadata.totalReadingTime, order: order, missingLast: true, tie: tieBreaker)
        case .readingProgress:
            return compareOptionalDouble(lhsItem.sortMetadata.readingProgress, rhsItem.sortMetadata.readingProgress, order: order, tie: tieBreaker)
        }
    }

    nonisolated func compareBookRows(
        _ lhs: BookshelfBookAggregateRow,
        _ rhs: BookshelfBookAggregateRow,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        let tieBreaker = lhs.payload.id < rhs.payload.id
        switch criteria {
        case .custom, .bookCount:
            return compareInt(lhs.sortOrder, rhs.sortOrder, order: .ascending, missingLast: false, tie: tieBreaker)
        case .createdDate:
            return compareInt(lhs.createdDate, rhs.createdDate, order: order, missingLast: false, tie: tieBreaker)
        case .modifiedDate:
            return compareInt(lhs.modifiedDate, rhs.modifiedDate, order: order, missingLast: false, tie: tieBreaker)
        case .publishDate:
            return compareInt(lhs.publishDate, rhs.publishDate, order: order, missingLast: true, tie: tieBreaker)
        case .name:
            return compareText(lhs.payload.name, rhs.payload.name, order: order, tie: tieBreaker)
        case .noteCount:
            return compareNoteCount(Int64(lhs.payload.noteCount), Int64(rhs.payload.noteCount), order: order, tie: tieBreaker)
        case .rating:
            return compareInt(lhs.payload.score, rhs.payload.score, order: order, missingLast: true, tie: tieBreaker)
        case .readDoneDate:
            return compareInt(lhs.readDoneDate, rhs.readDoneDate, order: order, missingLast: true, tie: tieBreaker)
        case .totalReadingTime:
            return compareInt(lhs.totalReadingTime, rhs.totalReadingTime, order: order, missingLast: true, tie: tieBreaker)
        case .readStatus:
            if lhs.readStatusOrder != rhs.readStatusOrder {
                return order == .ascending ? lhs.readStatusOrder < rhs.readStatusOrder : lhs.readStatusOrder > rhs.readStatusOrder
            }
            return compareText(lhs.payload.readStatusName, rhs.payload.readStatusName, order: order, tie: tieBreaker)
        case .tagName:
            return compareText(lhs.payload.name, rhs.payload.name, order: order, tie: tieBreaker)
        case .authorName:
            return compareText(lhs.payload.author, rhs.payload.author, order: order, tie: tieBreaker)
        case .pressName:
            return compareText(lhs.press, rhs.press, order: order, tie: tieBreaker)
        case .source:
            if lhs.sourceOrder != rhs.sourceOrder {
                return order == .ascending ? lhs.sourceOrder < rhs.sourceOrder : lhs.sourceOrder > rhs.sourceOrder
            }
            return compareText(lhs.payload.sourceName, rhs.payload.sourceName, order: order, tie: tieBreaker)
        case .readingProgress:
            return compareOptionalDouble(lhs.readingProgress, rhs.readingProgress, order: order, tie: tieBreaker)
        }
    }

    /// 比较两本分组预览书，保持与默认分组二级列表条件排序的字段语义一致。
    nonisolated func compareGroupPreviewBooks(
        _ lhs: BookshelfGroupBookPreview,
        _ rhs: BookshelfGroupBookPreview,
        criteria: BookshelfSortCriteria,
        order: BookshelfSortOrder
    ) -> Bool {
        let tieBreaker = lhs.id < rhs.id
        switch criteria {
        case .custom, .bookCount:
            return compareInt(lhs.sortOrder, rhs.sortOrder, order: .ascending, missingLast: false, tie: tieBreaker)
        case .createdDate:
            return compareInt(lhs.createdDate, rhs.createdDate, order: order, missingLast: false, tie: tieBreaker)
        case .modifiedDate:
            return compareInt(lhs.modifiedDate, rhs.modifiedDate, order: order, missingLast: false, tie: tieBreaker)
        case .publishDate:
            return compareInt(lhs.publishDate, rhs.publishDate, order: order, missingLast: true, tie: tieBreaker)
        case .name:
            return compareText(lhs.name, rhs.name, order: order, tie: tieBreaker)
        case .noteCount:
            return compareNoteCount(Int64(lhs.noteCount), Int64(rhs.noteCount), order: order, tie: tieBreaker)
        case .rating:
            return compareInt(lhs.score, rhs.score, order: order, missingLast: true, tie: tieBreaker)
        case .readDoneDate:
            return compareInt(lhs.readDoneDate, rhs.readDoneDate, order: order, missingLast: true, tie: tieBreaker)
        case .totalReadingTime:
            return compareInt(lhs.totalReadingTime, rhs.totalReadingTime, order: order, missingLast: true, tie: tieBreaker)
        case .readingProgress:
            return compareOptionalDouble(lhs.readingProgress, rhs.readingProgress, order: order, tie: tieBreaker)
        case .readStatus:
            return compareText(lhs.readStatusName, rhs.readStatusName, order: order, tie: tieBreaker)
        case .tagName:
            return compareText(lhs.name, rhs.name, order: order, tie: tieBreaker)
        case .authorName:
            return compareText(lhs.author, rhs.author, order: order, tie: tieBreaker)
        case .pressName:
            return compareText(lhs.name, rhs.name, order: order, tie: tieBreaker)
        case .source:
            return compareText(lhs.sourceName, rhs.sourceName, order: order, tie: tieBreaker)
        }
    }

    nonisolated func isBookItem(_ item: BookshelfItem) -> Bool {
        if case .book = item.content {
            return true
        }
        return false
    }

    nonisolated func compareNoteCount(
        _ lhs: Int64,
        _ rhs: Int64,
        order: BookshelfSortOrder,
        tie: Bool
    ) -> Bool {
        if order == .ascending {
            let lhsEmpty = lhs == 0
            let rhsEmpty = rhs == 0
            if lhsEmpty != rhsEmpty {
                return !lhsEmpty
            }
        }
        return compareInt(lhs, rhs, order: order, missingLast: false, tie: tie)
    }

    nonisolated func compareText(_ lhs: String, _ rhs: String, order: BookshelfSortOrder, tie: Bool) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        guard comparison != .orderedSame else { return tie }
        return order == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    nonisolated func compareInt(
        _ lhs: Int64,
        _ rhs: Int64,
        order: BookshelfSortOrder,
        missingLast: Bool,
        tie: Bool
    ) -> Bool {
        if missingLast {
            let lhsMissing = lhs == 0
            let rhsMissing = rhs == 0
            if lhsMissing != rhsMissing {
                return !lhsMissing
            }
        }
        guard lhs != rhs else { return tie }
        return order == .ascending ? lhs < rhs : lhs > rhs
    }

    nonisolated func compareOptionalDouble(
        _ lhs: Double?,
        _ rhs: Double?,
        order: BookshelfSortOrder,
        tie: Bool
    ) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return tie
        case (.none, .some):
            return false
        case (.some, .none):
            return true
        case (.some(let lhsValue), .some(let rhsValue)):
            guard lhsValue != rhsValue else { return tie }
            return order == .ascending ? lhsValue < rhsValue : lhsValue > rhsValue
        }
    }

    nonisolated func sectionKey(
        for item: BookshelfItem,
        criteria: BookshelfSortCriteria
    ) -> BookshelfDisplaySectionKey {
        switch criteria {
        case .createdDate:
            return monthSectionKey(timestamp: item.sortMetadata.createdDate, fallback: "未知创建时间", prefix: "created")
        case .modifiedDate:
            return monthSectionKey(timestamp: item.sortMetadata.modifiedDate, fallback: "未知修改时间", prefix: "modified")
        case .readDoneDate:
            return monthSectionKey(timestamp: item.sortMetadata.readDoneDate, fallback: "未读完", prefix: "read-done")
        case .publishDate:
            return yearSectionKey(timestamp: item.sortMetadata.publishDate, fallback: "未知出版年", prefix: "publish")
        case .name, .readStatus, .tagName, .authorName, .pressName, .source:
            return initialSectionKey(text: item.title, prefix: criteria.rawValue)
        case .custom, .noteCount, .bookCount, .rating, .totalReadingTime, .readingProgress:
            return BookshelfDisplaySectionKey(id: "all", title: "全部")
        }
    }

    nonisolated func sectionKey(
        for row: BookshelfBookAggregateRow,
        criteria: BookshelfSortCriteria
    ) -> BookshelfDisplaySectionKey {
        switch criteria {
        case .createdDate:
            return monthSectionKey(timestamp: row.createdDate, fallback: "未知创建时间", prefix: "created")
        case .modifiedDate:
            return monthSectionKey(timestamp: row.modifiedDate, fallback: "未知修改时间", prefix: "modified")
        case .readDoneDate:
            return monthSectionKey(timestamp: row.readDoneDate, fallback: "未读完", prefix: "read-done")
        case .publishDate:
            return yearSectionKey(timestamp: row.publishDate, fallback: "未知出版年", prefix: "publish")
        case .name:
            return initialSectionKey(text: row.payload.name, prefix: "name")
        case .readStatus:
            return initialSectionKey(text: row.payload.readStatusName, prefix: "read-status")
        case .tagName:
            return initialSectionKey(text: row.payload.name, prefix: "tag")
        case .authorName:
            return initialSectionKey(text: row.payload.author, prefix: "author")
        case .pressName:
            return initialSectionKey(text: row.press, prefix: "press")
        case .source:
            return initialSectionKey(text: row.payload.sourceName, prefix: "source")
        case .custom, .noteCount, .bookCount, .rating, .totalReadingTime, .readingProgress:
            return BookshelfDisplaySectionKey(id: "all", title: "全部")
        }
    }

    nonisolated func monthSectionKey(
        timestamp: Int64,
        fallback: String,
        prefix: String
    ) -> BookshelfDisplaySectionKey {
        guard timestamp > 0 else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: fallback)
        }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: fallback)
        }
        return BookshelfDisplaySectionKey(
            id: String(format: "%@-%04d-%02d", prefix, year, month),
            title: "\(year)年\(month)月"
        )
    }

    nonisolated func yearSectionKey(
        timestamp: Int64,
        fallback: String,
        prefix: String
    ) -> BookshelfDisplaySectionKey {
        guard timestamp > 0 else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: fallback)
        }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        guard let year = Calendar.current.dateComponents([.year], from: date).year else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: fallback)
        }
        return BookshelfDisplaySectionKey(id: "\(prefix)-\(year)", title: "\(year)年")
    }

    nonisolated func initialSectionKey(text: String, prefix: String) -> BookshelfDisplaySectionKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: "#")
        }
        let transformed = trimmed
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? trimmed
        guard let first = transformed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return BookshelfDisplaySectionKey(id: "\(prefix)-unknown", title: "#")
        }
        let uppercased = String(first).uppercased()
        let title = ("A"..."Z").contains(uppercased) ? uppercased : "#"
        return BookshelfDisplaySectionKey(id: "\(prefix)-\(title)", title: title)
    }

    nonisolated func statusKey(for row: BookshelfBookAggregateRow) -> BookshelfStatusKey {
        let title = row.payload.readStatusName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row.payload.readStatusId != 0, !title.isEmpty else {
            return BookshelfStatusKey(id: 0, title: "未设置状态", order: -1)
        }
        return BookshelfStatusKey(id: row.payload.readStatusId, title: title, order: row.readStatusOrder)
    }

    /// 将数据库原始评分约束到 Android 评分范围，供评分维度分组使用。
    nonisolated func ratingGroupScore(for score: Int64) -> Int64 {
        max(Int64(0), min(score, Int64(50)))
    }

    /// 将 Android 原始评分转换为用户可见星级标题，异常值只在展示层裁剪。
    nonisolated func ratingTitle(for score: Int64) -> String {
        String(format: "%.1f", Double(ratingGroupScore(for: score)) / 10.0)
    }

    nonisolated func normalizedSearchKeyword(_ searchKeyword: String?) -> String {
        searchKeyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated func setting(
        for dimension: BookshelfDimension,
        in settingsByDimension: [BookshelfDimension: BookshelfDisplaySetting]
    ) -> BookshelfDisplaySetting {
        settingsByDimension[dimension] ?? BookshelfDisplaySetting.defaultValue(for: dimension)
    }

    /// 读取默认分组二级列表设置，供顶层分组卡片代表封面复用 Android 组内排序语义。
    nonisolated func defaultGroupBookListSetting() -> BookshelfDisplaySetting {
        let settings = fetchBookshelfDisplaySettings(scope: .bookList)
        let fallback = BookshelfDisplaySetting.defaultBookListValue(for: .default)
        return sanitizedDefaultGroupBookListSetting(settings[.default] ?? fallback)
    }

    /// 净化默认分组二级列表设置，避免旧持久化值把不支持的维度排序带入分组预览。
    nonisolated func sanitizedDefaultGroupBookListSetting(
        _ setting: BookshelfDisplaySetting
    ) -> BookshelfDisplaySetting {
        var sanitized = setting
        let fallback = BookshelfDisplaySetting.defaultBookListValue(for: .default)
        let availableCriteria = BookshelfSortCriteria.availableForBookList(for: .default)
        if !availableCriteria.contains(sanitized.sortCriteria) {
            sanitized.sortCriteria = fallback.sortCriteria
        }
        if sanitized.sortCriteria == .custom {
            sanitized.sortOrder = .descending
            sanitized.isSectionEnabled = false
        } else if !sanitized.sortCriteria.supportsSection {
            sanitized.isSectionEnabled = false
        }
        sanitized.pinnedInAllSorts = true
        return sanitized
    }

    nonisolated func bookListMatchesSearch(
        name: String,
        author: String,
        keyword: String
    ) -> Bool {
        guard !keyword.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(keyword)
            || author.localizedCaseInsensitiveContains(keyword)
    }

    nonisolated func titleMatchesSearch(_ title: String, keyword: String) -> Bool {
        guard !keyword.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(keyword)
    }

    nonisolated func normalizedAuthorName(_ author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知作者" : trimmed
    }

    nonisolated func normalizedPressName(_ press: String) -> String {
        let trimmed = press.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知出版社" : trimmed
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

    nonisolated func authorSectionComparator(_ lhs: String, _ rhs: String, order: BookshelfSortOrder) -> Bool {
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return order == .ascending ? lhs < rhs : lhs > rhs
    }

}
