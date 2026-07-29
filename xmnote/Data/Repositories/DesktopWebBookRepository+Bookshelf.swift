/**
 * [INPUT]: 依赖 DesktopWebBookRepository、V44 书籍/分组/关系表与完整 WebBookDto 投影
 * [OUTPUT]: 提供 Android BookshelfService 7 条混排查询、manifest、移动及重排语义
 * [POS]: Data 层网页书架扩展；保留 Android 的排序、事务和越界写入边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// App 数据层的书架轻量 manifest 条目。
nonisolated struct DesktopWebBookshelfManifestSnapshot: Equatable, Sendable {
    let type: String
    let id: Int64
    let isPinned: Bool
    let pinOrder: Int
    let order: Int
}

/// App 数据层的混排项；仅 type 对应的一侧快照有值。
nonisolated struct DesktopWebBookshelfItemSnapshot: Equatable, Sendable {
    let type: String
    let book: DesktopWebBookSnapshot?
    let group: DesktopWebBookshelfGroupSnapshot?
}

/// Package item ref 到 Data 层的无框架输入。
nonisolated struct DesktopWebBookshelfItemRefInput: Equatable, Sendable {
    let type: String
    let id: Int64
}

/// 置顶分组元数据的 App 数据层快照。
nonisolated struct DesktopWebBookshelfPinnedGroupsMetaSnapshot: Equatable, Sendable {
    let groups: [DesktopWebBookshelfGroupSnapshot]
    let bookIDs: [Int64]
}

nonisolated extension DesktopWebBookRepository {
    private struct BookshelfGroupRow: Sendable {
        let id: Int64
        let name: String
        let isPinned: Bool
        let pinOrder: Int
        let order: Int
        let bookCount: Int
        let createdTime: Int64
    }

    /// 按手动混排 manifest 分页，并按请求设置生成分组封面预览。
    func bookshelf(
        page: Int,
        pageSize: Int,
        keyword: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebPagedSnapshot<DesktopWebBookshelfItemSnapshot> {
        // NOTE(ANDROID-WEB-006/008): Android 书架混排同时跨 group 与 book owner 读取。
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let allManifest = try await bookshelfManifest()
        let manifest: [DesktopWebBookshelfManifestSnapshot]
        if normalizedKeyword.isEmpty {
            manifest = allManifest
        } else {
            let bookIDs = try await matchedTopLevelBookIDs(keyword: normalizedKeyword)
            let groupIDs = Set(
                try await bookshelfGroupRows(ids: nil, pinnedOnly: false)
                    .filter { $0.name.range(of: normalizedKeyword, options: .caseInsensitive) != nil }
                    .map(\.id)
            )
            manifest = allManifest.filter { item in
                switch item.type {
                case "book": bookIDs.contains(item.id)
                case "group": groupIDs.contains(item.id)
                default: false
                }
            }
        }

        let offset = bookshelfOffset(page: page, pageSize: pageSize)
        let pageRefs = offset >= manifest.count
            ? []
            : Array(manifest[offset..<min(manifest.count, offset + min(pageSize, manifest.count - offset))])
                .map { DesktopWebBookshelfItemRefInput(type: $0.type, id: $0.id) }
        let items = try await buildBookshelfItems(
            itemRefs: pageRefs,
            groupSortBy: groupSortBy,
            groupSortOrder: groupSortOrder,
            groupEnableSection: groupEnableSection
        )
        let total = Int64(manifest.count)
        return DesktopWebPagedSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: total,
            totalPages: bookshelfTotalPages(total: total, pageSize: pageSize)
        )
    }

    /// 按普通书籍排序展开未置顶分组，仅保留置顶分组卡并排除其内部书籍。
    func sortedBookshelf(
        page: Int,
        pageSize: Int,
        keyword: String,
        sortBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebPagedSnapshot<DesktopWebBookshelfItemSnapshot> {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedMeta = try await bookshelfPinnedGroupsMeta(
            sortBy: sortBy,
            sortOrder: sortOrder,
            enableSection: false,
            groupSortBy: groupSortBy,
            groupSortOrder: groupSortOrder,
            groupEnableSection: groupEnableSection,
            layout: "grid"
        )
        let excludedBookIDs = Set(pinnedMeta.bookIDs)
        let filter = DesktopWebBookFilterSnapshot(
            keyword: normalizedKeyword,
            status: 0,
            groupID: 0,
            tagIDs: [],
            tagMode: "or",
            sourceIDs: []
        )
        let candidates = try await filteredBooks(
            filter: filter,
            trimsKeyword: false,
            usesGenericBaseOrder: true
        )
        let ordered = try await sortedBooks(candidates, sortBy: sortBy, sortOrder: sortOrder)
            .filter { !excludedBookIDs.contains($0.id ?? 0) }
        let modifiedTimes = sortBy == "modify_time"
            ? try await projection.lastModifiedTimes(for: ordered)
            : [:]
        let books = try await projection.projectBookSnapshots(
            ordered,
            lastModifiedTimes: modifiedTimes
        )
        let visibleGroups = normalizedKeyword.isEmpty
            ? pinnedMeta.groups
            : pinnedMeta.groups.filter {
                $0.name.range(of: normalizedKeyword, options: .caseInsensitive) != nil
            }
        let pinnedBookItems = books.filter(\.isPinned).map {
            DesktopWebBookshelfItemSnapshot(type: "book", book: $0, group: nil)
        }
        let regularBookItems = books.filter { !$0.isPinned }.map {
            DesktopWebBookshelfItemSnapshot(type: "book", book: $0, group: nil)
        }
        let pinnedGroupItems = visibleGroups.map {
            DesktopWebBookshelfItemSnapshot(type: "group", book: nil, group: $0)
        }
        let allItems = sortPinnedBookshelfItems(pinnedGroupItems + pinnedBookItems)
            + regularBookItems
        let offset = bookshelfOffset(page: page, pageSize: pageSize)
        let paged = offset >= allItems.count
            ? []
            : Array(allItems[offset..<min(allItems.count, offset + min(pageSize, allItems.count - offset))])
        let total = Int64(allItems.count)
        return DesktopWebPagedSnapshot(
            items: paged,
            page: page,
            pageSize: pageSize,
            total: total,
            totalPages: bookshelfTotalPages(total: total, pageSize: pageSize)
        )
    }

    /// 返回顶层有效未分组书籍和全部有效分组的统一手动排序清单。
    func bookshelfManifest() async throws -> [DesktopWebBookshelfManifestSnapshot] {
        try await database.dbPool.read { db in
            try fetchBookshelfManifest(db)
        }
    }

    /// 生成置顶分组卡与其按首次出现去重的书籍 ID；前三个顶层排序参数按 Android 保持无作用。
    func bookshelfPinnedGroupsMeta(
        sortBy: String,
        sortOrder: String,
        enableSection: Bool,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool,
        layout: String
    ) async throws -> DesktopWebBookshelfPinnedGroupsMetaSnapshot {
        _ = sortBy
        _ = sortOrder
        _ = enableSection
        let meta = try await pinnedGroupMeta(
            sortBy: groupSortBy,
            sortOrder: groupSortOrder,
            enableSection: groupEnableSection && layout == "grid"
        )
        return DesktopWebBookshelfPinnedGroupsMetaSnapshot(
            groups: meta.groups,
            bookIDs: meta.bookIDs
        )
    }

    /// 按原始引用顺序批量展开完整书籍与分组卡，未知或缺失引用静默丢弃。
    func queryBookshelfItems(
        itemRefs: [DesktopWebBookshelfItemRefInput],
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> [DesktopWebBookshelfItemSnapshot] {
        try await validateBookshelfManifestRefs(itemRefs, requireCompleteManifest: false)
        return try await buildBookshelfItems(
            itemRefs: itemRefs,
            groupSortBy: groupSortBy,
            groupSortOrder: groupSortOrder,
            groupEnableSection: groupEnableSection
        )
    }

    /// 在单一事务中按当前 manifest 移动非置顶项，并重新编号全部保留条目。
    func moveBookshelfItems(
        movedItems: [DesktopWebBookshelfItemRefInput],
        anchorItem: DesktopWebBookshelfItemRefInput?,
        placement: String
    ) async throws {
        guard !movedItems.isEmpty else { return }
        try await database.dbPool.write { db in
            let currentItems = try fetchBookshelfManifest(db)
            let movedKeys = Set(movedItems.map(bookshelfItemKey))
            let movableItems = currentItems.filter {
                !$0.isPinned && movedKeys.contains(bookshelfItemKey($0))
            }
            guard !movableItems.isEmpty else { return }
            let remainingItems = currentItems.filter {
                !movedKeys.contains(bookshelfItemKey($0))
            }
            let nextItems = try applyBookshelfMove(
                remainingItems: remainingItems,
                movedItems: movableItems,
                anchorItem: anchorItem,
                placement: placement
            )
            let now = currentTimeMillis()
            for (index, item) in nextItems.enumerated() {
                try updateBookshelfOrder(db, item: item, order: index, now: now)
            }
        }
    }

    /// 校验请求为当前完整 manifest 后，在一个事务中按请求顺序写入共享排序空间。
    func reorderBookshelf(_ items: [DesktopWebBookshelfItemRefInput]) async throws {
        try await validateBookshelfManifestRefs(items, requireCompleteManifest: true)
        try await database.dbPool.write { db in
            let now = currentTimeMillis()
            for (index, item) in items.enumerated() {
                let manifestItem = DesktopWebBookshelfManifestSnapshot(
                    type: item.type,
                    id: item.id,
                    isPinned: false,
                    pinOrder: 0,
                    order: index
                )
                try updateBookshelfOrder(db, item: manifestItem, order: index, now: now)
            }
        }
    }
}

private nonisolated extension DesktopWebBookRepository {
    func validateBookshelfManifestRefs(
        _ itemRefs: [DesktopWebBookshelfItemRefInput],
        requireCompleteManifest: Bool
    ) async throws {
        let manifest = try await bookshelfManifest()
        let manifestKeys = Set(manifest.map(bookshelfItemKey))
        let requestedKeys = itemRefs.map(bookshelfItemKey)
        let hasInvalidType = itemRefs.contains { $0.type != "book" && $0.type != "group" }
        let hasDuplicates = requestedKeys.count != Set(requestedKeys).count
        let hasUnknownItem = requestedKeys.contains { !manifestKeys.contains($0) }
        let missesManifestItem = requireCompleteManifest && Set(requestedKeys) != manifestKeys
        guard !hasInvalidType, !hasDuplicates, !hasUnknownItem, !missesManifestItem else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("书架项目与当前清单不一致")
        }
    }

    func fetchBookshelfManifest(_ db: Database) throws -> [DesktopWebBookshelfManifestSnapshot] {
        // SQL 目的：读取书架顶层未分组书籍的手动排序与置顶字段。
        // 涉及表：book，并以 group_book NOT EXISTS 判断顶层归属。
        // 关键过滤：书籍有效且非占位，不存在任意有效分组关系；不限制 owner。
        // 返回字段：与有效分组共同构建 WebBookshelfManifestItem。
        let books = try Row.fetchAll(
            db,
            sql: """
                SELECT b.id, b.book_order AS item_order, b.pinned, b.pin_order
                FROM book b
                WHERE b.is_deleted = 0 AND b.id != 0
                  AND NOT EXISTS (
                      SELECT 1 FROM group_book gb
                      INNER JOIN `group` g ON g.id = gb.group_id
                      WHERE gb.book_id = b.id
                        AND gb.is_deleted = 0
                        AND g.is_deleted = 0
                  )
                """
        ).map { row in
            DesktopWebBookshelfManifestSnapshot(
                type: "book",
                id: row["id"],
                isPinned: (row["pinned"] as Int64) == 1,
                pinOrder: Int(row["pin_order"] as Int64),
                order: Int(row["item_order"] as Int64)
            )
        }
        // SQL 目的：读取全部有效分组的手动排序与置顶字段。
        // 涉及表：group；不连接关系表。
        // 关键过滤：仅 is_deleted = 0，故意不限制 owner。
        // 返回字段：与顶层书籍共同构建 WebBookshelfManifestItem。
        let groups = try Row.fetchAll(
            db,
            sql: """
                SELECT id, group_order AS item_order, pinned, pin_order
                FROM `group`
                WHERE is_deleted = 0
                """
        ).map { row in
            DesktopWebBookshelfManifestSnapshot(
                type: "group",
                id: row["id"],
                isPinned: (row["pinned"] as Int64) == 1,
                pinOrder: Int(row["pin_order"] as Int64),
                order: Int(row["item_order"] as Int64)
            )
        }
        return (books + groups).sorted { left, right in
            if left.isPinned != right.isPinned { return left.isPinned && !right.isPinned }
            if left.isPinned, left.pinOrder != right.pinOrder { return left.pinOrder > right.pinOrder }
            if !left.isPinned, left.order != right.order { return left.order < right.order }
            if left.type != right.type { return left.type < right.type }
            return left.id < right.id
        }
    }

    func buildBookshelfItems(
        itemRefs: [DesktopWebBookshelfItemRefInput],
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> [DesktopWebBookshelfItemSnapshot] {
        guard !itemRefs.isEmpty else { return [] }
        let bookIDs = distinctBookshelfIDs(itemRefs.filter { $0.type == "book" }.map(\.id))
        let groupIDs = distinctBookshelfIDs(itemRefs.filter { $0.type == "group" }.map(\.id))
        let bookRecords = try await activeBooks(ids: bookIDs)
        let bookSnapshots = try await projection.projectBookSnapshots(bookRecords)
        let bookMap: [Int64: DesktopWebBookSnapshot] = Dictionary(
            uniqueKeysWithValues: bookSnapshots.map { ($0.id, $0) }
        )

        let groupRows = try await bookshelfGroupRows(ids: groupIDs, pinnedOnly: false)
        let orderedIDsByGroup = try await orderedBookshelfGroupBookIDs(
            groupIDs: groupIDs,
            sortBy: groupSortBy,
            sortOrder: groupSortOrder,
            enableSection: groupEnableSection
        )
        let previewIDs = distinctBookshelfIDs(orderedIDsByGroup.values.flatMap { $0 })
        let coverMap: [Int64: String] = Dictionary(
            uniqueKeysWithValues: try await activeBooks(ids: previewIDs).compactMap {
                guard let id = $0.id else { return nil }
                return (id, $0.cover)
            }
        )
        let groupMap: [Int64: DesktopWebBookshelfGroupSnapshot] = Dictionary(
            uniqueKeysWithValues: groupRows.map { row in
            let previews = (orderedIDsByGroup[row.id] ?? []).prefix(9).map { id in
                DesktopWebGroupPreviewBookSnapshot(bookID: id, cover: coverMap[id] ?? "")
            }
            return (
                row.id,
                DesktopWebBookshelfGroupSnapshot(
                    id: row.id,
                    name: row.name,
                    isPinned: row.isPinned,
                    pinOrder: row.pinOrder,
                    order: row.order,
                    bookCount: row.bookCount,
                    createdTime: row.createdTime,
                    previewBooks: previews
                )
            )
            }
        )

        return itemRefs.compactMap { item in
            switch item.type {
            case "book":
                return bookMap[item.id].map {
                    DesktopWebBookshelfItemSnapshot(type: "book", book: $0, group: nil)
                }
            case "group":
                return groupMap[item.id].map {
                    DesktopWebBookshelfItemSnapshot(type: "group", book: nil, group: $0)
                }
            default:
                return nil
            }
        }
    }

    func orderedBookshelfGroupBookIDs(
        groupIDs: [Int64],
        sortBy: String,
        sortOrder: String,
        enableSection: Bool
    ) async throws -> [Int64: [Int64]] {
        guard !groupIDs.isEmpty else { return [:] }
        if sortBy == "custom" && !enableSection {
            return try await defaultBookshelfGroupBookIDs(groupIDs: groupIDs)
        }
        var result: [Int64: [Int64]] = [:]
        for groupID in groupIDs {
            let filter = DesktopWebBookFilterSnapshot(
                keyword: "",
                status: 0,
                groupID: groupID,
                tagIDs: [],
                tagMode: "or",
                sourceIDs: []
            )
            let candidates = try await filteredBooks(
                filter: filter,
                trimsKeyword: false,
                usesGenericBaseOrder: false
            )
            let ordered = try await projection.orderedBooksForGroup(
                candidates,
                sortBy: sortBy,
                sortOrder: sortOrder
            )
            let visible = enableSection && sortBy == "name"
                ? ordered.filter {
                    $0.pinned == 1
                        || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                : ordered
            result[groupID] = visible.compactMap(\.id)
        }
        return result
    }

    func defaultBookshelfGroupBookIDs(groupIDs: [Int64]) async throws -> [Int64: [Int64]] {
        var result: [Int64: [Int64]] = [:]
        for chunk in groupIDs.chunkedForBookshelf(maxCount: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows: [(groupID: Int64, bookID: Int64)] = try await database.dbPool.read { db in
                // SQL 目的：读取各分组首关系书籍的默认预览顺序。
                // 涉及表：group_book INNER JOIN book。
                // 关键过滤：关系和书籍有效，只接受每本书最早的有效分组关系。
                // 返回字段：按组、置顶、pin_order DESC、book_order ASC、id ASC 排列的书籍 ID。
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT gb.group_id, b.id AS book_id
                        FROM group_book gb
                        INNER JOIN book b ON gb.book_id = b.id
                        WHERE gb.group_id IN (\(placeholders))
                          AND gb.is_deleted = 0 AND b.is_deleted = 0
                          AND gb.id = (
                              SELECT gb2.id FROM group_book gb2
                              WHERE gb2.book_id = b.id AND gb2.is_deleted = 0
                              ORDER BY gb2.created_date ASC, gb2.id ASC
                              LIMIT 1
                          )
                        ORDER BY gb.group_id,
                                 b.pinned DESC,
                                 CASE WHEN b.pinned = 1 THEN b.pin_order ELSE 0 END DESC,
                                 CASE WHEN b.pinned = 0 THEN b.book_order ELSE 0 END ASC,
                                 b.id ASC
                        """,
                    arguments: StatementArguments(chunk)
                ).map { row in
                    (groupID: row["group_id"], bookID: row["book_id"])
                }
            }
            for row in rows {
                result[row.groupID, default: []].append(row.bookID)
            }
        }
        return result
    }

    private func bookshelfGroupRows(
        ids: [Int64]?,
        pinnedOnly: Bool
    ) async throws -> [BookshelfGroupRow] {
        guard let ids else {
            return try await fetchBookshelfGroupRows(ids: nil, pinnedOnly: pinnedOnly)
        }
        guard !ids.isEmpty else { return [] }
        var rowsByID: [Int64: BookshelfGroupRow] = [:]
        for chunk in ids.chunkedForBookshelf(maxCount: 500) {
            for row in try await fetchBookshelfGroupRows(ids: chunk, pinnedOnly: pinnedOnly) {
                rowsByID[row.id] = row
            }
        }
        return ids.compactMap { rowsByID[$0] }
    }

    private func fetchBookshelfGroupRows(
        ids: [Int64]?,
        pinnedOnly: Bool
    ) async throws -> [BookshelfGroupRow] {
        var conditions = ["g.is_deleted = 0"]
        var arguments: StatementArguments = []
        if pinnedOnly { conditions.append("g.pinned = 1") }
        if let ids {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            conditions.append("g.id IN (\(placeholders))")
            arguments = StatementArguments(ids)
        }
        let whereClause = conditions.joined(separator: " AND ")
        let queryArguments = arguments
        return try await database.dbPool.read { db in
            // SQL 目的：读取有效分组卡及其首关系有效书籍数量。
            // 涉及表：group，并以 group_book INNER JOIN book 相关子查询计数。
            // 关键过滤：分组有效，可选置顶/ID；关系和书籍有效且只接受最早有效关系；不限制 owner。
            // 时间字段：created_date 原样作为 createdTime。
            // 返回字段：WebBookshelfGroupDto 所需元数据，调用方恢复请求顺序。
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT g.id, g.name, g.group_order, g.pinned, g.pin_order, g.created_date,
                           (SELECT COUNT(*)
                            FROM group_book gb
                            INNER JOIN book b ON gb.book_id = b.id
                            WHERE gb.group_id = g.id AND gb.is_deleted = 0 AND b.is_deleted = 0
                              AND gb.id = (
                                  SELECT gb2.id FROM group_book gb2
                                  WHERE gb2.book_id = b.id AND gb2.is_deleted = 0
                                  ORDER BY gb2.created_date ASC, gb2.id ASC
                                  LIMIT 1
                              )) AS book_count
                    FROM `group` g
                    WHERE \(whereClause)
                    """,
                arguments: queryArguments
            )
            return rows.map { row in
                BookshelfGroupRow(
                    id: row["id"],
                    name: (row["name"] as String?) ?? "",
                    isPinned: (row["pinned"] as Int64) == 1,
                    pinOrder: Int(row["pin_order"] as Int64),
                    order: Int(row["group_order"] as Int64),
                    bookCount: Int(row["book_count"] as Int64),
                    createdTime: row["created_date"]
                )
            }
        }
    }

    func matchedTopLevelBookIDs(keyword: String) async throws -> Set<Int64> {
        try await database.dbPool.read { db in
            // SQL 目的：复制 bookshelf 关键词搜索中的顶层书籍匹配。
            // 涉及表：book，并以 group_book NOT EXISTS 排除任意有效分组关系。
            // 关键过滤：有效非占位书籍，name/author/press/isbn 任一 LIKE；不限制 owner。
            // 返回字段：用于过滤已排序 manifest 的书籍 ID 集合。
            Set(
                try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT b.id
                        FROM book b
                        WHERE b.is_deleted = 0 AND b.id != 0
                          AND NOT EXISTS (
                              SELECT 1 FROM group_book gb
                              INNER JOIN `group` g ON g.id = gb.group_id
                              WHERE gb.book_id = b.id
                                AND gb.is_deleted = 0
                                AND g.is_deleted = 0
                          )
                          AND (b.name LIKE '%' || ? || '%'
                               OR b.author LIKE '%' || ? || '%'
                               OR b.press LIKE '%' || ? || '%'
                               OR b.isbn LIKE '%' || ? || '%')
                        """,
                    arguments: [keyword, keyword, keyword, keyword]
                )
            )
        }
    }

    func applyBookshelfMove(
        remainingItems: [DesktopWebBookshelfManifestSnapshot],
        movedItems: [DesktopWebBookshelfManifestSnapshot],
        anchorItem: DesktopWebBookshelfItemRefInput?,
        placement: String
    ) throws -> [DesktopWebBookshelfManifestSnapshot] {
        let insertionIndex: Int
        switch placement {
        case "start":
            insertionIndex = remainingItems.firstIndex { !$0.isPinned } ?? remainingItems.count
        case "end":
            insertionIndex = remainingItems.count
        case "before", "after":
            let anchorKey = anchorItem.map(bookshelfItemKey)
            guard let anchorKey,
                  let anchorIndex = remainingItems.firstIndex(where: {
                      bookshelfItemKey($0) == anchorKey
                  }) else {
                insertionIndex = remainingItems.count
                break
            }
            insertionIndex = placement == "before" ? anchorIndex : anchorIndex + 1
        default:
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "Unsupported bookshelf move placement: \(placement)"
            )
        }
        return Array(remainingItems.prefix(insertionIndex))
            + movedItems
            + Array(remainingItems.dropFirst(insertionIndex))
    }

    func updateBookshelfOrder(
        _ db: Database,
        item: DesktopWebBookshelfManifestSnapshot,
        order: Int,
        now: Int64
    ) throws {
        switch item.type {
        case "book":
            // SQL 目的：按 WebBookDao.updateBookOrder 写入请求指定书籍序号。
            // 涉及表：book；只按 id 更新，不校验有效状态、顶层归属或 owner。
            // 时间字段：同一请求使用共享 now 毫秒值。
            // 副作用用途：move 重编当前 manifest，reorder 则保留任意外部 ID 行为。
            try db.execute(
                sql: "UPDATE book SET book_order = ?, updated_date = ? WHERE id = ?",
                arguments: [order, now, item.id]
            )
        case "group":
            // SQL 目的：按 WebBookDao.updateGroupOrder 写入请求指定分组序号。
            // 涉及表：group；只按 id 更新，不校验有效状态或 owner。
            // 时间字段：同一请求使用共享 now 毫秒值。
            // 副作用用途：move 重编当前 manifest，reorder 则保留任意外部 ID 行为。
            try db.execute(
                sql: "UPDATE `group` SET group_order = ?, updated_date = ? WHERE id = ?",
                arguments: [order, now, item.id]
            )
        default:
            break
        }
    }

    func sortPinnedBookshelfItems(
        _ items: [DesktopWebBookshelfItemSnapshot]
    ) -> [DesktopWebBookshelfItemSnapshot] {
        items.sorted { left, right in
            let leftPin = left.type == "group" ? left.group?.pinOrder ?? 0 : left.book?.pinOrder ?? 0
            let rightPin = right.type == "group" ? right.group?.pinOrder ?? 0 : right.book?.pinOrder ?? 0
            if leftPin != rightPin { return leftPin > rightPin }
            if left.type != right.type { return left.type == "group" }
            let leftID = left.type == "group" ? left.group?.id ?? .max : left.book?.id ?? .max
            let rightID = right.type == "group" ? right.group?.id ?? .max : right.book?.id ?? .max
            return leftID < rightID
        }
    }

    func bookshelfItemKey(_ item: DesktopWebBookshelfManifestSnapshot) -> String {
        "\(item.type)-\(item.id)"
    }

    func bookshelfItemKey(_ item: DesktopWebBookshelfItemRefInput) -> String {
        "\(item.type)-\(item.id)"
    }

    func distinctBookshelfIDs(_ ids: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        return ids.filter { seen.insert($0).inserted }
    }

    func bookshelfOffset(page: Int, pageSize: Int) -> Int {
        let result = (max(1, page) - 1).multipliedReportingOverflow(by: max(1, pageSize))
        return result.overflow ? Int.max : result.partialValue
    }

    func bookshelfTotalPages(total: Int64, pageSize: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int(ceil(Double(total) / Double(pageSize)))
    }
}

private nonisolated extension Array {
    /// 按 Android WebBookRepository 的 500 项 SQLite IN 分块。
    func chunkedForBookshelf(maxCount: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: maxCount).map { start in
            Array(self[start..<Swift.min(start + maxCount, count)])
        }
    }
}
