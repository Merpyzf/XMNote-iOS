/**
 * [INPUT]: 依赖 DesktopWebBookRepository、V44 书籍/分组/标签关系表与完整 WebBookDto 投影
 * [OUTPUT]: 提供 Android BookController 组合筛选列表、五类 section 及置顶分组卡语义
 * [POS]: Data 层网页书籍列表扩展；只暴露 App 快照，不让 XMNoteWeb 依赖 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android WebBookRepository.BookFilter 的 App 数据层快照。
nonisolated struct DesktopWebBookFilterSnapshot: Equatable, Sendable {
    let keyword: String
    let status: Int
    let groupID: Int64
    let tagIDs: [Int64]
    let tagMode: String
    let sourceIDs: [Int64]
}

/// 置顶分组卡中的预览书籍；封面仍为数据库原值。
nonisolated struct DesktopWebGroupPreviewBookSnapshot: Equatable, Sendable {
    let bookID: Int64
    let cover: String
}

/// Android WebBookshelfGroupDto 的 App 数据层快照。
nonisolated struct DesktopWebBookshelfGroupSnapshot: Equatable, Sendable {
    let id: Int64
    let name: String
    let isPinned: Bool
    let pinOrder: Int
    let order: Int
    let bookCount: Int
    let createdTime: Int64
    let previewBooks: [DesktopWebGroupPreviewBookSnapshot]
}

/// 单个 Android WebBookSectionDto 的 App 数据层快照。
nonisolated struct DesktopWebBookSectionSnapshot: Equatable, Sendable {
    let title: String
    let books: [DesktopWebBookSnapshot]
    let groups: [DesktopWebBookshelfGroupSnapshot]

    var count: Int { books.count + groups.count }
}

/// Android WebBookSectionResult 的 App 数据层快照。
nonisolated struct DesktopWebBookSectionResultSnapshot: Equatable, Sendable {
    let sections: [DesktopWebBookSectionSnapshot]
    let total: Int
}

nonisolated extension DesktopWebBookRepository {
    struct PinnedGroupMeta: Sendable {
        let groups: [DesktopWebBookshelfGroupSnapshot]
        let bookIDs: [Int64]
    }

    private struct SectionAggregateData: Sendable {
        let lastModifiedTimes: [Int64: Int64]
        let readDoneTimes: [Int64: Int64]
    }

    private struct GroupDatabaseRow: Sendable {
        let id: Int64
        let name: String
        let isPinned: Bool
        let pinOrder: Int
        let order: Int
        let bookCount: Int
        let createdTime: Int64
    }

    private struct CoverDatabaseRow: Sendable {
        let id: Int64
        let cover: String
    }

    /// 复制 Android 主书籍列表：组内分支使用组内排序，其余使用普通列表排序。
    func books(
        page: Int,
        pageSize: Int,
        filter: DesktopWebBookFilterSnapshot,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPagedSnapshot<DesktopWebBookSnapshot> {
        // NOTE(ANDROID-WEB-008): Android 主列表不按 user_id 隔离；基线阶段保留跨 owner 可见。
        let candidates = try await filteredBooks(
            filter: filter,
            trimsKeyword: false,
            usesGenericBaseOrder: filter.groupID <= 0
        )
        let sorted = if filter.groupID > 0 {
            try await projection.orderedBooksForGroup(
                candidates,
                sortBy: sortBy,
                sortOrder: sortOrder
            )
        } else {
            try await sortedBooks(candidates, sortBy: sortBy, sortOrder: sortOrder)
        }
        let offset = safeListOffset(page: page, pageSize: pageSize)
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
            totalPages: Self.listTotalPages(total: total, pageSize: pageSize)
        )
    }

    /// 复制 sectionBy 分支的全量响应，其中正数 groupID 不合并顶层置顶分组。
    func bookSections(
        filter: DesktopWebBookFilterSnapshot,
        sectionBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebBookSectionResultSnapshot {
        let normalizedFilter = DesktopWebBookFilterSnapshot(
            keyword: filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            status: filter.status,
            groupID: filter.groupID,
            tagIDs: filter.tagIDs,
            tagMode: filter.tagMode,
            sourceIDs: filter.sourceIDs
        )
        if filter.groupID > 0 {
            return try await groupedBookSections(
                filter: normalizedFilter,
                sectionBy: sectionBy,
                sortOrder: sortOrder
            )
        }
        return try await topLevelBookSections(
            filter: normalizedFilter,
            sectionBy: sectionBy,
            sortOrder: sortOrder,
            groupSortBy: groupSortBy,
            groupSortOrder: groupSortOrder,
            groupEnableSection: groupEnableSection
        )
    }

    /// 构建组合 WHERE 的全量候选；关键词空白判定与 Android isNotBlank 一致。
    func filteredBooks(
        filter: DesktopWebBookFilterSnapshot,
        trimsKeyword: Bool,
        usesGenericBaseOrder: Bool
    ) async throws -> [BookRecord] {
        let keyword = trimsKeyword
            ? filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            : filter.keyword
        var conditions = ["b.is_deleted = 0", "b.id != 0"]
        var values: [DatabaseValue] = []

        if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conditions.append(
                "(b.name LIKE '%' || ? || '%' OR b.author LIKE '%' || ? || '%' "
                    + "OR b.press LIKE '%' || ? || '%' OR b.isbn LIKE '%' || ? || '%')"
            )
            values.append(contentsOf: Array(repeating: keyword.databaseValue, count: 4))
        }
        if filter.status != 0 {
            conditions.append("b.read_status_id = ?")
            values.append(filter.status.databaseValue)
        }
        if !filter.sourceIDs.isEmpty {
            conditions.append(
                "b.source_id IN (\(Array(repeating: "?", count: filter.sourceIDs.count).joined(separator: ","))) "
                    + "AND EXISTS (SELECT 1 FROM source s WHERE s.id = b.source_id AND s.is_deleted = 0)"
            )
            values.append(contentsOf: filter.sourceIDs.map(\.databaseValue))
        }
        if filter.groupID != 0 {
            conditions.append(
                "EXISTS (SELECT 1 FROM group_book gb "
                    + "INNER JOIN `group` g ON g.id = gb.group_id "
                    + "WHERE gb.book_id = b.id AND gb.is_deleted = 0 "
                    + "AND g.is_deleted = 0 AND gb.group_id = ?)"
            )
            values.append(filter.groupID.databaseValue)
        }
        if !filter.tagIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.tagIDs.count).joined(separator: ",")
            if filter.tagMode == "and" {
                conditions.append(
                    "(SELECT COUNT(DISTINCT tb.tag_id) FROM tag_book tb "
                        + "INNER JOIN tag t ON t.id = tb.tag_id "
                        + "WHERE tb.book_id = b.id AND tb.is_deleted = 0 AND t.is_deleted = 0 "
                        + "AND tb.tag_id IN (\(placeholders))) = ?"
                )
                values.append(contentsOf: filter.tagIDs.map(\.databaseValue))
                values.append(filter.tagIDs.count.databaseValue)
            } else {
                conditions.append(
                    "EXISTS (SELECT 1 FROM tag_book tb "
                        + "INNER JOIN tag t ON t.id = tb.tag_id "
                        + "WHERE tb.book_id = b.id AND tb.is_deleted = 0 "
                        + "AND t.is_deleted = 0 AND tb.tag_id IN (\(placeholders)))"
                )
                values.append(contentsOf: filter.tagIDs.map(\.databaseValue))
            }
        }

        let whereClause = conditions.joined(separator: " AND ")
        let arguments = StatementArguments(values)
        return try await database.dbPool.read { db in
            // SQL 目的：复制 WebBookRepository.buildWhereClause/queryBooksForSection 的组合筛选。
            // 涉及表：book，并按请求使用 group_book/tag_book 子查询。
            // 关键过滤：书籍有效且非 0；来源、分组、标签主记录也必须有效；故意不校验 owner。
            // 时间字段：本查询不转换时间，后续内存排序直接使用毫秒值。
            // 返回字段用途：普通列表先按 pinned/pin_order 取稳定基序，section/组内分支保留无 ORDER BY 查询。
            let orderClause = usesGenericBaseOrder ? "ORDER BY b.pinned DESC, b.pin_order ASC" : ""
            let sql = """
                SELECT b.*
                FROM book b
                WHERE \(whereClause)
                \(orderClause)
                """
            return try BookRecord.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    private func groupedBookSections(
        filter: DesktopWebBookFilterSnapshot,
        sectionBy: String,
        sortOrder: String
    ) async throws -> DesktopWebBookSectionResultSnapshot {
        let candidates = try await filteredBooks(
            filter: filter,
            trimsKeyword: true,
            usesGenericBaseOrder: false
        )
        let rawOrdered = try await projection.orderedBooksForGroup(
            candidates,
            sortBy: sectionBy,
            sortOrder: sortOrder
        )
        // NOTE(ANDROID-WEB-012): Android 名称分区丢弃空书名，但响应 total 仍保留这些书籍。
        let ordered = sectionBy == "name"
            ? rawOrdered.filter {
                $0.pinned == 1
                    || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            : rawOrdered
        let aggregate = try await sectionAggregateData(for: candidates, sectionBy: sectionBy)
        let snapshots = try await projection.projectBookSnapshots(
            ordered,
            lastModifiedTimes: aggregate.lastModifiedTimes
        )
        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        let pinned = ordered.filter { $0.pinned == 1 }.compactMap { book in
            book.id.flatMap { snapshotByID[$0] }
        }
        var sections: [DesktopWebBookSectionSnapshot] = []
        if !pinned.isEmpty {
            sections.append(DesktopWebBookSectionSnapshot(title: "置顶", books: pinned, groups: []))
        }
        for book in ordered where book.pinned != 1 {
            let title = sectionKey(sectionBy: sectionBy, book: book, aggregate: aggregate)
            guard let id = book.id, let snapshot = snapshotByID[id] else { continue }
            append(snapshot, title: title, to: &sections)
        }
        return DesktopWebBookSectionResultSnapshot(sections: sections, total: candidates.count)
    }

    private func topLevelBookSections(
        filter: DesktopWebBookFilterSnapshot,
        sectionBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebBookSectionResultSnapshot {
        let includesPinnedGroups = filter.status == 0
            && filter.groupID == 0
            && filter.tagIDs.isEmpty
            && filter.sourceIDs.isEmpty
        let pinnedMeta = includesPinnedGroups
            ? try await pinnedGroupMeta(
                sortBy: groupSortBy,
                sortOrder: groupSortOrder,
                enableSection: groupEnableSection
            )
            : PinnedGroupMeta(groups: [], bookIDs: [])
        let matchedGroups = filter.keyword.isEmpty
            ? pinnedMeta.groups
            : pinnedMeta.groups.filter {
                $0.name.range(of: filter.keyword, options: .caseInsensitive) != nil
            }
        let excludedBookIDs = Set(pinnedMeta.bookIDs)
        let allCandidates = try await filteredBooks(
            filter: filter,
            trimsKeyword: true,
            usesGenericBaseOrder: false
        ).filter { book in
            guard let id = book.id else { return false }
            return !excludedBookIDs.contains(id)
        }
        guard !allCandidates.isEmpty else {
            let sections = matchedGroups.isEmpty
                ? []
                : [DesktopWebBookSectionSnapshot(title: "置顶", books: [], groups: matchedGroups)]
            return DesktopWebBookSectionResultSnapshot(sections: sections, total: matchedGroups.count)
        }

        let aggregate = try await sectionAggregateData(for: allCandidates, sectionBy: sectionBy)
        let allSnapshots = try await projection.projectBookSnapshots(
            allCandidates,
            lastModifiedTimes: aggregate.lastModifiedTimes
        )
        let snapshotByID = Dictionary(uniqueKeysWithValues: allSnapshots.map { ($0.id, $0) })
        let baseIndex = Dictionary(uniqueKeysWithValues: allCandidates.enumerated().compactMap { index, book in
            book.id.map { ($0, index) }
        })
        let pinnedBooks = allCandidates.filter { $0.pinned == 1 }.sorted { left, right in
            if left.pinOrder != right.pinOrder { return left.pinOrder > right.pinOrder }
            return (baseIndex[left.id ?? 0] ?? 0) < (baseIndex[right.id ?? 0] ?? 0)
        }
        let pinnedSnapshots = pinnedBooks.compactMap { book in
            book.id.flatMap { snapshotByID[$0] }
        }
        let regular = allCandidates.filter { $0.pinned != 1 }
        let keys = orderedSectionKeys(
            sectionBy: sectionBy,
            sortOrder: sortOrder,
            books: regular,
            aggregate: aggregate
        )
        var sections: [DesktopWebBookSectionSnapshot] = []
        if !pinnedSnapshots.isEmpty || !matchedGroups.isEmpty {
            sections.append(
                DesktopWebBookSectionSnapshot(
                    title: "置顶",
                    books: pinnedSnapshots,
                    groups: matchedGroups
                )
            )
        }
        for key in keys {
            let books = regular.filter { sectionKey(sectionBy: sectionBy, book: $0, aggregate: aggregate) == key }
            let sorted = sortBooksInTopLevelSection(
                books,
                sectionBy: sectionBy,
                sectionKey: key,
                sortOrder: sortOrder,
                aggregate: aggregate
            )
            let snapshots = sorted.compactMap { book in
                book.id.flatMap { snapshotByID[$0] }
            }
            if !snapshots.isEmpty {
                sections.append(DesktopWebBookSectionSnapshot(title: key, books: snapshots, groups: []))
            }
        }
        return DesktopWebBookSectionResultSnapshot(
            sections: sections,
            total: allCandidates.count + matchedGroups.count
        )
    }

    private func sectionAggregateData(
        for books: [BookRecord],
        sectionBy: String
    ) async throws -> SectionAggregateData {
        let ids = books.compactMap(\.id)
        let lastModified = sectionBy == "modify_time"
            ? try await projection.lastModifiedTimes(for: books)
            : [:]
        let rawReadDone = sectionBy == "read_done_time"
            ? try await projection.aggregateMap(
                table: "book_read_status_record",
                value: "MAX(changed_date)",
                bookIDs: ids,
                extraCondition: "AND read_status_id = 3"
            )
            : [:]
        let readDone = Dictionary(uniqueKeysWithValues: books.compactMap { book in
            book.id.map {
                ($0, projection.resolvedReadDoneTime(book: book, recordedTimes: rawReadDone))
            }
        })
        return SectionAggregateData(lastModifiedTimes: lastModified, readDoneTimes: readDone)
    }

    private func orderedSectionKeys(
        sectionBy: String,
        sortOrder: String,
        books: [BookRecord],
        aggregate: SectionAggregateData
    ) -> [String] {
        var seen: Set<String> = []
        let keys = books.compactMap { book -> String? in
            let key = sectionKey(sectionBy: sectionBy, book: book, aggregate: aggregate)
            return seen.insert(key).inserted ? key : nil
        }
        let special = Set(["无出版日期", "未读完", "#", "未知"])
        let normal = keys.filter { !special.contains($0) }.sorted { left, right in
            let comparison: ComparisonResult
            switch sectionBy {
            case "create_time", "modify_time", "read_done_time":
                comparison = compareOptionalInt(monthSectionValue(left), monthSectionValue(right), left, right)
            case "publish_date":
                comparison = compareOptionalInt(yearSectionValue(left), yearSectionValue(right), left, right)
            default:
                comparison = left.compare(right)
            }
            return sortOrder == "asc" ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return normal + keys.filter(special.contains)
    }

    private func sortBooksInTopLevelSection(
        _ books: [BookRecord],
        sectionBy: String,
        sectionKey: String,
        sortOrder: String,
        aggregate: SectionAggregateData
    ) -> [BookRecord] {
        switch sectionBy {
        case "create_time":
            return sectionLongSort(books, sortOrder: sortOrder) { $0.createdDate }
        case "modify_time":
            return sectionLongSort(books, sortOrder: sortOrder) {
                aggregate.lastModifiedTimes[$0.id ?? 0] ?? 0
            }
        case "publish_date":
            return sectionLongSort(books, sortOrder: sortOrder) {
                sectionKey == "无出版日期" ? $0.createdDate : projection.publishTimestamp($0.pubDate)
            }
        case "name":
            return sectionLongSort(books, sortOrder: sortOrder) { $0.createdDate }
        case "read_done_time":
            if sectionKey == "未读完" {
                return sectionLongSort(books, sortOrder: sortOrder) { $0.createdDate }
            }
            return sectionLongSort(books, sortOrder: sortOrder, usesCreateTie: true) {
                aggregate.readDoneTimes[$0.id ?? 0] ?? 0
            }
        default:
            return books
        }
    }

    private func sectionLongSort(
        _ books: [BookRecord],
        sortOrder: String,
        usesCreateTie: Bool = false,
        value: (BookRecord) -> Int64
    ) -> [BookRecord] {
        let ascending = sortOrder == "asc"
        return books.sorted { left, right in
            let leftValue = value(left)
            let rightValue = value(right)
            if leftValue != rightValue { return ascending ? leftValue < rightValue : leftValue > rightValue }
            if usesCreateTie && left.createdDate != right.createdDate {
                return ascending ? left.createdDate < right.createdDate : left.createdDate > right.createdDate
            }
            return ascending ? (left.id ?? 0) < (right.id ?? 0) : (left.id ?? 0) > (right.id ?? 0)
        }
    }

    private func sectionKey(
        sectionBy: String,
        book: BookRecord,
        aggregate: SectionAggregateData
    ) -> String {
        switch sectionBy {
        case "create_time":
            return monthKey(book.createdDate)
        case "modify_time":
            return monthKey(aggregate.lastModifiedTimes[book.id ?? 0] ?? 0)
        case "publish_date":
            let timestamp = projection.publishTimestamp(book.pubDate)
            return timestamp == 0 ? "无出版日期" : yearKey(timestamp)
        case "name":
            let first = projection.sortableFirstLetter(book.name)
            return ("A"..."Z").contains(first) ? first : "#"
        case "read_done_time":
            let time = aggregate.readDoneTimes[book.id ?? 0] ?? 0
            return time == 0 ? "未读完" : monthKey(time)
        default:
            return "未知"
        }
    }

    func pinnedGroupMeta(
        sortBy: String,
        sortOrder: String,
        enableSection: Bool
    ) async throws -> PinnedGroupMeta {
        let rows = try await pinnedGroupRows()
        guard !rows.isEmpty else { return PinnedGroupMeta(groups: [], bookIDs: []) }
        let groupIDs = rows.map(\.id)
        let orderedIDsByGroup: [Int64: [Int64]]
        if sortBy == "custom" && !enableSection {
            orderedIDsByGroup = try await defaultOrderedBookIDs(groupIDs: groupIDs)
        } else {
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
                let books = try await filteredBooks(
                    filter: filter,
                    trimsKeyword: false,
                    usesGenericBaseOrder: false
                )
                let rawOrdered = try await projection.orderedBooksForGroup(
                    books,
                    sortBy: sortBy,
                    sortOrder: sortOrder
                )
                let ordered = enableSection && sortBy == "name"
                    ? rawOrdered.filter {
                        $0.pinned == 1
                            || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    : rawOrdered
                result[groupID] = ordered.compactMap(\.id)
            }
            orderedIDsByGroup = result
        }

        var allIDs: [Int64] = []
        var seen: Set<Int64> = []
        for row in rows {
            for id in orderedIDsByGroup[row.id] ?? [] where seen.insert(id).inserted {
                allIDs.append(id)
            }
        }
        let coverMap = try await rawCoverMap(ids: allIDs)
        let groups = rows.map { row in
            let previews = (orderedIDsByGroup[row.id] ?? []).prefix(9).map { id in
                DesktopWebGroupPreviewBookSnapshot(bookID: id, cover: coverMap[id] ?? "")
            }
            return DesktopWebBookshelfGroupSnapshot(
                id: row.id,
                name: row.name,
                isPinned: row.isPinned,
                pinOrder: row.pinOrder,
                order: row.order,
                bookCount: row.bookCount,
                createdTime: row.createdTime,
                previewBooks: previews
            )
        }
        return PinnedGroupMeta(groups: groups, bookIDs: allIDs)
    }

    private func pinnedGroupRows() async throws -> [GroupDatabaseRow] {
        try await database.dbPool.read { db in
            // SQL 目的：复制 queryPinnedGroups 并补齐置顶分组卡计数。
            // 涉及表：`group`、group_book、book。
            // 关键过滤：分组有效且置顶；计数只接受每本书最早的有效关系；不按 owner 过滤。
            // 时间字段：created_date 作为分组卡 createdTime，不做时区转换。
            // 返回字段用途：Service 再按 pin_order DESC、id ASC 生成顶层置顶组顺序。
            let sql = """
                SELECT g.id, g.name, g.group_order, g.pinned, g.pin_order, g.created_date,
                       (SELECT COUNT(*)
                        FROM group_book gb
                        INNER JOIN book b ON gb.book_id = b.id
                        WHERE gb.group_id = g.id AND gb.is_deleted = 0 AND b.is_deleted = 0
                          AND gb.id = (
                              SELECT gb2.id
                              FROM group_book gb2
                              WHERE gb2.book_id = b.id AND gb2.is_deleted = 0
                              ORDER BY gb2.created_date ASC, gb2.id ASC
                              LIMIT 1
                          )) AS book_count
                FROM `group` g
                WHERE g.is_deleted = 0 AND g.pinned = 1
                ORDER BY g.pin_order ASC, g.group_order DESC
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                GroupDatabaseRow(
                    id: row["id"],
                    name: (row["name"] as String?) ?? "",
                    isPinned: (row["pinned"] as Int64) == 1,
                    pinOrder: Int(row["pin_order"] as Int64),
                    order: Int(row["group_order"] as Int64),
                    bookCount: Int(row["book_count"] as Int64),
                    createdTime: row["created_date"]
                )
            }.sorted {
                if $0.pinOrder != $1.pinOrder { return $0.pinOrder > $1.pinOrder }
                return $0.id < $1.id
            }
        }
    }

    private func defaultOrderedBookIDs(groupIDs: [Int64]) async throws -> [Int64: [Int64]] {
        guard !groupIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: groupIDs.count).joined(separator: ",")
        return try await database.dbPool.read { db in
            // SQL 目的：复制 batchQueryGroupBookRefs 的默认组内预览顺序。
            // 涉及表：group_book INNER JOIN book。
            // 关键过滤：关系/书籍有效，且只接受每本书最早的有效分组关系。
            // 时间字段：group_book.created_date 只用于判定最早关系。
            // 返回字段用途：每组按置顶、pin_order DESC、book_order ASC、id ASC 生成封面预览。
            let sql = """
                SELECT gb.group_id, b.id AS book_id
                FROM group_book gb
                INNER JOIN book b ON gb.book_id = b.id
                WHERE gb.group_id IN (\(placeholders))
                  AND gb.is_deleted = 0 AND b.is_deleted = 0
                  AND gb.id = (
                      SELECT gb2.id
                      FROM group_book gb2
                      WHERE gb2.book_id = b.id AND gb2.is_deleted = 0
                      ORDER BY gb2.created_date ASC, gb2.id ASC
                      LIMIT 1
                  )
                ORDER BY gb.group_id,
                         b.pinned DESC,
                         CASE WHEN b.pinned = 1 THEN b.pin_order ELSE 0 END DESC,
                         CASE WHEN b.pinned = 0 THEN b.book_order ELSE 0 END ASC,
                         b.id ASC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(groupIDs))
            var result: [Int64: [Int64]] = [:]
            for row in rows {
                result[row["group_id"] as Int64, default: []].append(row["book_id"] as Int64)
            }
            return result
        }
    }

    private func rawCoverMap(ids: [Int64]) async throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int64: String] = [:]
        for chunk in ids.chunkedForBookList(maxCount: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try await database.dbPool.read { db in
                // SQL 目的：批量回读置顶分组预览书籍的原始封面。
                // 涉及表：book。
                // 关键过滤：ID 位于当前分块且书籍有效；不按 owner 过滤。
                // 时间字段：无。
                // 返回字段用途：cover 在 Adapter 内再应用访问码代理签名。
                try Row.fetchAll(
                    db,
                    sql: "SELECT id, cover FROM book WHERE id IN (\(placeholders)) AND is_deleted = 0",
                    arguments: StatementArguments(chunk)
                ).map { row in
                    CoverDatabaseRow(
                        id: row["id"],
                        cover: (row["cover"] as String?) ?? ""
                    )
                }
            }
            for row in rows {
                result[row.id] = row.cover
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    private func append(
        _ snapshot: DesktopWebBookSnapshot,
        title: String,
        to sections: inout [DesktopWebBookSectionSnapshot]
    ) {
        if let index = sections.indices.last, sections[index].title == title {
            let current = sections[index]
            sections[index] = DesktopWebBookSectionSnapshot(
                title: title,
                books: current.books + [snapshot],
                groups: current.groups
            )
        } else {
            sections.append(DesktopWebBookSectionSnapshot(title: title, books: [snapshot], groups: []))
        }
    }

    private func monthKey(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d 年 %02d 月", components.year ?? 1970, components.month ?? 1)
    }

    private func yearKey(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
        return String(format: "%04d 年", Calendar.current.component(.year, from: date))
    }

    private func monthSectionValue(_ key: String) -> Int? {
        let numbers = key.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        guard numbers.count == 2, let year = Int(numbers[0]), let month = Int(numbers[1]), (1...12).contains(month) else {
            return nil
        }
        return year * 100 + month
    }

    private func yearSectionValue(_ key: String) -> Int? {
        let numbers = key.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        guard numbers.count == 1, numbers[0].count == 4 else { return nil }
        return Int(numbers[0])
    }

    private func compareOptionalInt(
        _ left: Int?,
        _ right: Int?,
        _ leftText: String,
        _ rightText: String
    ) -> ComparisonResult {
        guard let left, let right else { return leftText.compare(rightText) }
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    private func safeListOffset(page: Int, pageSize: Int) -> Int {
        let value = (max(1, page) - 1).multipliedReportingOverflow(by: max(1, pageSize))
        return value.overflow ? Int.max : value.partialValue
    }

    private static func listTotalPages(total: Int64, pageSize: Int) -> Int {
        guard total > 0 else { return 0 }
        let divisor = Int64(pageSize)
        return Int(total / divisor + (total % divisor == 0 ? 0 : 1))
    }
}

nonisolated private extension Array {
    /// 按 Android Repository 的 SQLite IN 上限分块。
    func chunkedForBookList(maxCount: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: maxCount).map { start in
            Array(self[start..<Swift.min(start + maxCount, count)])
        }
    }
}
