/**
 * [INPUT]: 依赖 DesktopWebGroupRepository、BookRecord 与 V44 书籍关联/聚合表
 * [OUTPUT]: 提供 Android BookService 组内排序、分页和完整 WebBookDto 数据投影
 * [POS]: Data 层网页分组仓储的书籍投影扩展；后续 Book API 可复用相同聚合语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated extension DesktopWebGroupRepository {
    private struct NamedRelationDatabaseRow: Sendable {
        let bookID: Int64
        let id: Int64
        let name: String
    }

    private struct AggregateDatabaseRow: Sendable {
        let bookID: Int64
        let value: Int64
    }

    private struct SortContext: Sendable {
        let books: [BookRecord]
        let baseIndex: [Int64: Int]
        let lastModifiedTimes: [Int64: Int64]
        let readDoneTimes: [Int64: Int64]
        let noteCounts: [Int64: Int64]
        let totalReadingTimes: [Int64: Int64]
    }

    /// 构造组内完整书籍分页结果；查询分组是否存在不是 Android 合同的一部分。
    func pagedBooksInGroup(
        id: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPagedSnapshot<DesktopWebBookSnapshot> {
        let baseBooks = try await baseBooks(inGroup: id)
        let sorted = try await orderedBooksForGroup(
            baseBooks,
            sortBy: sortBy,
            sortOrder: sortOrder
        )
        let total = Int64(sorted.count)
        let offset = try groupBookOffset(page: page, pageSize: pageSize)
        let pageBooks = offset >= sorted.count
            ? []
            : Array(sorted[offset..<min(sorted.count, offset + min(pageSize, sorted.count - offset))])
        let lastModifiedTimes = sortBy == "modify_time"
            ? try await lastModifiedTimes(for: pageBooks)
            : [:]
        let items = try await projectBookSnapshots(
            pageBooks,
            lastModifiedTimes: lastModifiedTimes
        )
        return DesktopWebPagedSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: total,
            totalPages: Self.totalPages(total: total, pageSize: pageSize)
        )
    }

    /// 对任意已筛选书籍集执行 Android 组内排序，供书籍列表的 groupId 分支复用。
    func orderedBooksForGroup(
        _ rawBooks: [BookRecord],
        sortBy: String,
        sortOrder: String
    ) async throws -> [BookRecord] {
        let baseBooks = rawBooks.sorted {
            if $0.bookOrder != $1.bookOrder { return $0.bookOrder < $1.bookOrder }
            return ($0.id ?? 0) < ($1.id ?? 0)
        }
        let bookIDs = baseBooks.compactMap(\.id)
        let rawReadDoneTimes = sortBy == "read_done_time"
            ? try await aggregateMap(
                table: "book_read_status_record",
                value: "MAX(changed_date)",
                bookIDs: bookIDs,
                extraCondition: "AND read_status_id = 3"
            )
            : [:]
        let context = SortContext(
            books: baseBooks,
            baseIndex: Dictionary(uniqueKeysWithValues: bookIDs.enumerated().map { ($0.element, $0.offset) }),
            lastModifiedTimes: sortBy == "modify_time"
                ? try await lastModifiedTimes(for: baseBooks)
                : [:],
            readDoneTimes: Dictionary(uniqueKeysWithValues: baseBooks.compactMap { book in
                guard let id = book.id else { return nil }
                return (id, resolvedReadDoneTime(book: book, recordedTimes: rawReadDoneTimes))
            }),
            noteCounts: sortBy == "note_count"
                ? try await aggregateMap(table: "note", value: "COUNT(*)", bookIDs: bookIDs)
                : [:],
            totalReadingTimes: sortBy == "total_reading_time"
                ? try await aggregateMap(
                    table: "read_time_record",
                    value: "SUM(elapsed_seconds)",
                    bookIDs: bookIDs,
                    extraCondition: "AND status = 3"
                )
                : [:]
        )
        return sortedGroupBooks(context: context, sortBy: sortBy, sortOrder: sortOrder)
    }

    /// 对齐 Android 组内排序：置顶书始终在前，普通书按请求字段稳定排序。
    private func sortedGroupBooks(
        context: SortContext,
        sortBy: String,
        sortOrder: String
    ) -> [BookRecord] {
        let pinned = stableSort(
            context.books.filter { $0.pinned == 1 },
            baseIndex: context.baseIndex,
            primary: { Int64($0.pinOrder) },
            secondary: { _ in 0 },
            ascending: false
        )
        let regular = context.books.filter { $0.pinned != 1 }

        let sortedRegular: [BookRecord]
        switch sortBy {
        case "create_time":
            sortedRegular = stableSort(
                regular,
                baseIndex: context.baseIndex,
                primary: { $0.createdDate },
                secondary: { _ in 0 },
                ascending: sortOrder == "asc"
            )
        case "modify_time":
            sortedRegular = stableSort(
                regular,
                baseIndex: context.baseIndex,
                primary: { context.lastModifiedTimes[$0.id ?? 0] ?? 0 },
                secondary: { _ in 0 },
                ascending: sortOrder == "asc"
            )
        case "publish_date":
            let withDate = regular.filter { publishTimestamp($0.pubDate) != 0 }
            let withoutDate = regular.filter { publishTimestamp($0.pubDate) == 0 }
            sortedRegular = stableSort(
                withDate,
                baseIndex: context.baseIndex,
                primary: { publishTimestamp($0.pubDate) },
                secondary: { $0.createdDate },
                ascending: sortOrder == "asc"
            ) + stableSort(
                withoutDate,
                baseIndex: context.baseIndex,
                primary: { $0.createdDate },
                secondary: { _ in 0 },
                ascending: sortOrder == "asc"
            )
        case "name":
            sortedRegular = stableSortText(
                regular,
                baseIndex: context.baseIndex,
                primary: { sortableFirstLetter($0.name) },
                secondary: { $0.createdDate },
                ascending: sortOrder == "asc"
            )
        case "note_count":
            let withNotes = regular.filter { (context.noteCounts[$0.id ?? 0] ?? 0) > 0 }
            let withoutNotes = regular.filter { (context.noteCounts[$0.id ?? 0] ?? 0) <= 0 }
            if sortOrder == "asc" {
                sortedRegular = stableSort(
                    withNotes,
                    baseIndex: context.baseIndex,
                    primary: { context.noteCounts[$0.id ?? 0] ?? 0 },
                    secondary: { $0.createdDate },
                    ascending: true
                ) + stableSort(
                    withoutNotes,
                    baseIndex: context.baseIndex,
                    primary: { $0.createdDate },
                    secondary: { _ in 0 },
                    ascending: true
                )
            } else {
                sortedRegular = stableSort(
                    regular,
                    baseIndex: context.baseIndex,
                    primary: { context.noteCounts[$0.id ?? 0] ?? 0 },
                    secondary: { $0.createdDate },
                    ascending: false
                )
            }
        case "rating":
            let rated = regular.filter { $0.score > 0 }
            let unrated = regular.filter { $0.score <= 0 }
            sortedRegular = stableSort(
                rated,
                baseIndex: context.baseIndex,
                primary: { $0.score },
                secondary: { $0.createdDate },
                ascending: sortOrder == "asc"
            ) + stableSort(
                unrated,
                baseIndex: context.baseIndex,
                primary: { $0.createdDate },
                secondary: { _ in 0 },
                ascending: sortOrder == "asc"
            )
        case "read_done_time":
            let done = regular.filter { (context.readDoneTimes[$0.id ?? 0] ?? 0) > 0 }
            let unfinished = regular.filter { (context.readDoneTimes[$0.id ?? 0] ?? 0) <= 0 }
            sortedRegular = stableSort(
                done,
                baseIndex: context.baseIndex,
                primary: { context.readDoneTimes[$0.id ?? 0] ?? 0 },
                secondary: { $0.createdDate },
                ascending: sortOrder == "asc"
            ) + stableSort(
                unfinished,
                baseIndex: context.baseIndex,
                primary: { $0.createdDate },
                secondary: { _ in 0 },
                ascending: sortOrder == "asc"
            )
        case "total_reading_time":
            let withTime = regular.filter { (context.totalReadingTimes[$0.id ?? 0] ?? 0) > 0 }
            let withoutTime = regular.filter { (context.totalReadingTimes[$0.id ?? 0] ?? 0) <= 0 }
            sortedRegular = stableSort(
                withTime,
                baseIndex: context.baseIndex,
                primary: { context.totalReadingTimes[$0.id ?? 0] ?? 0 },
                secondary: { $0.createdDate },
                ascending: sortOrder == "asc"
            ) + stableSort(
                withoutTime,
                baseIndex: context.baseIndex,
                primary: { $0.createdDate },
                secondary: { _ in 0 },
                ascending: sortOrder == "asc"
            )
        case "reading_progress":
            let withProgress = regular.filter { readingProgress($0) > 0 }
            let withoutProgress = regular.filter { readingProgress($0) <= 0 }
            sortedRegular = stableSortDouble(
                withProgress,
                baseIndex: context.baseIndex,
                primary: { readingProgress($0) },
                secondary: { $0.createdDate },
                ascending: sortOrder == "asc"
            ) + stableSort(
                withoutProgress,
                baseIndex: context.baseIndex,
                primary: { $0.createdDate },
                secondary: { _ in 0 },
                ascending: sortOrder == "asc"
            )
        default:
            sortedRegular = regular.sorted {
                if $0.bookOrder != $1.bookOrder { return $0.bookOrder < $1.bookOrder }
                return ($0.id ?? 0) < ($1.id ?? 0)
            }
        }
        return pinned + sortedRegular
    }

    /// 批量读取 WebBookDto 的所有关联统计，并按当前页书籍原顺序生成快照。
    func projectBookSnapshots(
        _ books: [BookRecord],
        lastModifiedTimes: [Int64: Int64] = [:],
        recentReadTimes: [Int64: Int64] = [:]
    ) async throws -> [DesktopWebBookSnapshot] {
        let ids = books.compactMap(\.id)
        guard !ids.isEmpty else { return [] }
        async let tags = namedRelations(
            ids: ids,
            relationTable: "tag_book",
            targetTable: "tag",
            targetColumn: "tag_id"
        )
        async let groups = namedRelations(
            ids: ids,
            relationTable: "group_book",
            targetTable: "`group`",
            targetColumn: "group_id",
            orderBy: "ORDER BY relation.book_id, relation.created_date ASC, relation.id ASC"
        )
        async let noteCounts = aggregateMap(table: "note", value: "COUNT(*)", bookIDs: ids)
        async let reviewCounts = aggregateMap(table: "review", value: "COUNT(*)", bookIDs: ids)
        async let relevantCounts = aggregateMap(table: "category_content", value: "COUNT(*)", bookIDs: ids)
        async let readingTimes = aggregateMap(
            table: "read_time_record",
            value: "SUM(elapsed_seconds)",
            bookIDs: ids,
            extraCondition: "AND status = 3"
        )
        async let readDoneCounts = aggregateMap(
            table: "book_read_status_record",
            value: "COUNT(*)",
            bookIDs: ids,
            extraCondition: "AND read_status_id = 3"
        )
        async let readDoneTimes = aggregateMap(
            table: "book_read_status_record",
            value: "MAX(changed_date)",
            bookIDs: ids,
            extraCondition: "AND read_status_id = 3"
        )
        async let sourceNames = activeSourceNames()

        let (
            tagMap,
            groupMap,
            noteMap,
            reviewMap,
            relevantMap,
            readingMap,
            doneCountMap,
            doneTimeMap,
            sourceMap
        ) = try await (
            tags,
            groups,
            noteCounts,
            reviewCounts,
            relevantCounts,
            readingTimes,
            readDoneCounts,
            readDoneTimes,
            sourceNames
        )

        return books.compactMap { book in
            guard let id = book.id else { return nil }
            let doneTime = resolvedReadDoneTime(book: book, recordedTimes: doneTimeMap)
            return DesktopWebBookSnapshot(
                id: id,
                name: book.name.trimmingCharacters(in: .whitespacesAndNewlines),
                rawName: book.rawName,
                cover: book.cover.trimmingCharacters(in: .whitespacesAndNewlines),
                author: book.author.trimmingCharacters(in: .whitespacesAndNewlines),
                authorIntro: book.authorIntro,
                translator: book.translator,
                summary: book.summary,
                isbn: book.isbn,
                press: book.press,
                pubDate: book.pubDate,
                doubanId: book.doubanId == 0 ? nil : Int(book.doubanId),
                readStatus: Int(book.readStatusId),
                readStatusChangedTime: book.readStatusChangedDate,
                recentReadTime: (recentReadTimes[id] ?? 0) > 0 ? recentReadTimes[id] : nil,
                readDoneCount: Int(doneCountMap[id] ?? 0),
                score: Int(book.score),
                readPosition: book.readPosition,
                totalPosition: Int(book.totalPosition),
                totalPagination: Int(book.totalPagination),
                currentPositionUnit: Int(book.currentPositionUnit),
                positionUnit: Int(book.positionUnit),
                type: Int(book.type),
                sourceId: book.sourceId,
                sourceName: sourceMap[book.sourceId] ?? "未知",
                purchaseDate: book.purchaseDate == 0 ? nil : book.purchaseDate,
                price: book.price > 0 ? book.price : nil,
                isPinned: book.pinned == 1,
                pinOrder: Int(book.pinOrder),
                order: Int(book.bookOrder),
                wordCount: book.wordCount,
                totalReadingTime: readingMap[id] ?? 0,
                createdTime: book.createdDate,
                updatedTime: book.updatedDate,
                lastModifiedTime: (lastModifiedTimes[id] ?? 0) > 0 ? lastModifiedTimes[id] : nil,
                noteCount: Int(noteMap[id] ?? 0),
                reviewCount: Int(reviewMap[id] ?? 0),
                relevantCount: Int(relevantMap[id] ?? 0),
                readDoneTime: doneTime > 0 ? doneTime : nil,
                bookmarkModifiedTime: book.bookMarkModifiedTime > 0 ? book.bookMarkModifiedTime : nil,
                groups: Array((groupMap[id] ?? []).prefix(1)),
                tags: tagMap[id] ?? [],
                isDeleted: book.isDeleted == 1
            )
        }
    }

    /// 查询单张关联表中的有效名称引用；SQL 标识符只来自本文件固定调用点。
    private func namedRelations(
        ids: [Int64],
        relationTable: String,
        targetTable: String,
        targetColumn: String,
        orderBy: String = ""
    ) async throws -> [Int64: [DesktopWebNamedSnapshot]] {
        var result: [Int64: [DesktopWebNamedSnapshot]] = [:]
        for chunk in ids.chunked(maxCount: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try await database.dbPool.read { db in
                // SQL 目的：批量查询 WebBookDto 的有效标签或分组轻量引用。
                // 涉及表：调用点固定为 tag_book/tag 或 group_book/`group`。
                // 关键过滤：book_id 位于当前 500 项分块，关系与目标主记录均有效。
                // 时间字段：分组关系的 created_date 仅用于确定 Android groups.take(1) 的顺序。
                // 返回字段用途：按 book_id 组装 WebTagDto 或 WebGroupSimpleDto；不按 owner 过滤。
                let sql = """
                    SELECT relation.book_id, target.id, target.name
                    FROM \(relationTable) relation
                    INNER JOIN \(targetTable) target ON relation.\(targetColumn) = target.id
                    WHERE relation.book_id IN (\(placeholders))
                      AND relation.is_deleted = 0
                      AND target.is_deleted = 0
                    \(orderBy)
                    """
                return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk)).map { row in
                    NamedRelationDatabaseRow(
                        bookID: row["book_id"],
                        id: row["id"],
                        name: (row["name"] as String?) ?? ""
                    )
                }
            }
            for row in rows {
                result[row.bookID, default: []].append(
                    DesktopWebNamedSnapshot(
                        id: row.id,
                        name: row.name
                    )
                )
            }
        }
        return result
    }

    /// 批量统计指定表的数量、总和或最大时间；SQL 片段只来自本文件固定调用点。
    func aggregateMap(
        table: String,
        value: String,
        bookIDs: [Int64],
        extraCondition: String = ""
    ) async throws -> [Int64: Int64] {
        var result: [Int64: Int64] = [:]
        for chunk in bookIDs.chunked(maxCount: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try await database.dbPool.read { db in
                // SQL 目的：批量读取 WebBookDto 或排序上下文所需的数量、时长、最近完成时间。
                // 涉及表：固定调用点使用 note/review/category_content/read_time_record/book_read_status_record。
                // 关键过滤：book_id 位于当前分块、记录有效，并按调用点附加 status/read_status 条件。
                // 时间字段：MAX(changed_date) 原样返回毫秒；SUM(elapsed_seconds) 保持秒单位。
                // 返回字段用途：按 book_id 建立聚合映射，缺失项由服务层回退 0。
                let sql = """
                    SELECT book_id, \(value) AS aggregate_value
                    FROM \(table)
                    WHERE book_id IN (\(placeholders))
                      AND is_deleted = 0
                      \(extraCondition)
                    GROUP BY book_id
                    """
                return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk)).map { row in
                    AggregateDatabaseRow(
                        bookID: row["book_id"],
                        value: row["aggregate_value"]
                    )
                }
            }
            for row in rows {
                result[row.bookID] = row.value
            }
        }
        return result
    }

    /// 聚合 Android 定义的八类“最后修改时间”来源。
    func lastModifiedTimes(for books: [BookRecord]) async throws -> [Int64: Int64] {
        let ids = books.compactMap(\.id)
        var result: [Int64: Int64] = [:]
        let tableExpressions = [
            ("note", "MAX(CASE WHEN created_date > updated_date THEN created_date ELSE updated_date END)"),
            ("category_content", "MAX(CASE WHEN created_date > updated_date THEN created_date ELSE updated_date END)"),
            ("review", "MAX(CASE WHEN created_date > updated_date THEN created_date ELSE updated_date END)"),
            ("read_time_record", "MAX(created_date)"),
            ("check_in_record", "MAX(CASE WHEN created_date > updated_date THEN created_date ELSE updated_date END)")
        ]
        for (table, expression) in tableExpressions {
            for (id, value) in try await aggregateMap(table: table, value: expression, bookIDs: ids) {
                result[id] = max(result[id] ?? 0, value)
            }
        }
        for book in books {
            guard let id = book.id else { continue }
            result[id] = [
                result[id] ?? 0,
                book.bookMarkModifiedTime,
                book.createdDate,
                book.readStatusChangedDate,
                book.updatedDate
            ].max() ?? 0
        }
        return result
    }

    /// 读取全部有效来源名称；不存在或已删除来源由 DTO 回退“未知”。
    private func activeSourceNames() async throws -> [Int64: String] {
        try await database.dbPool.read { db in
            // SQL 目的：按 WebBookDao.queryAllSources 构造 WebBookDto.sourceName 映射。
            // 涉及表：source。
            // 关键过滤：is_deleted = 0；不排除隐藏来源，也不按 owner 过滤。
            // 返回字段用途：按 source_id 查名称，缺失时回退“未知”。
            let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM source WHERE is_deleted = 0")
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["id"] as Int64, (row["name"] as String?) ?? "")
            })
        }
    }

    func resolvedReadDoneTime(
        book: BookRecord,
        recordedTimes: [Int64: Int64]
    ) -> Int64 {
        let recorded = recordedTimes[book.id ?? 0] ?? 0
        if recorded > 0 { return recorded }
        return book.readStatusId == 3 && book.readStatusChangedDate > 0
            ? book.readStatusChangedDate
            : 0
    }

    private func groupBookOffset(page: Int, pageSize: Int) throws -> Int {
        let normalizedPage = max(page, 1)
        let normalizedPageSize = max(pageSize, 1)
        let value = (normalizedPage - 1).multipliedReportingOverflow(by: normalizedPageSize)
        return value.overflow ? Int.max : value.partialValue
    }

    func publishTimestamp(_ rawValue: String) -> Int64 {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(
            of: #"^(\d{4})-(\d{1,2})(?:-.+)?$"#,
            options: .regularExpression
        ) != nil else {
            return 0
        }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month) else {
            return 0
        }
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = Calendar.current.timeZone
        components.year = year
        components.month = month
        components.day = 1
        return components.date.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
    }

    func sortableFirstLetter(_ name: String) -> String {
        guard let first = name.first else { return "#" }
        let transformed = String(first)
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? String(first)
        return transformed.first.map { String($0).uppercased() } ?? "#"
    }

    func readingProgress(_ book: BookRecord) -> Double {
        switch book.currentPositionUnit {
        case 0:
            return book.readPosition > 0 ? min(max(book.readPosition / 100, 0), 1) : 0
        case 1:
            return book.totalPosition > 0 && book.readPosition > 0
                ? min(max(book.readPosition / Double(book.totalPosition), 0), 1)
                : 0
        default:
            return book.totalPagination > 0 && book.readPosition > 0
                ? min(max(book.readPosition / Double(book.totalPagination), 0), 1)
                : 0
        }
    }

    private func stableSort(
        _ books: [BookRecord],
        baseIndex: [Int64: Int],
        primary: (BookRecord) -> Int64,
        secondary: (BookRecord) -> Int64,
        ascending: Bool
    ) -> [BookRecord] {
        books.sorted { lhs, rhs in
            let lhsPrimary = primary(lhs)
            let rhsPrimary = primary(rhs)
            if lhsPrimary != rhsPrimary {
                return ascending ? lhsPrimary < rhsPrimary : lhsPrimary > rhsPrimary
            }
            let lhsSecondary = secondary(lhs)
            let rhsSecondary = secondary(rhs)
            if lhsSecondary != rhsSecondary {
                return ascending ? lhsSecondary < rhsSecondary : lhsSecondary > rhsSecondary
            }
            return (baseIndex[lhs.id ?? 0] ?? 0) < (baseIndex[rhs.id ?? 0] ?? 0)
        }
    }

    private func stableSortDouble(
        _ books: [BookRecord],
        baseIndex: [Int64: Int],
        primary: (BookRecord) -> Double,
        secondary: (BookRecord) -> Int64,
        ascending: Bool
    ) -> [BookRecord] {
        books.sorted { lhs, rhs in
            let lhsPrimary = primary(lhs)
            let rhsPrimary = primary(rhs)
            if lhsPrimary != rhsPrimary {
                return ascending ? lhsPrimary < rhsPrimary : lhsPrimary > rhsPrimary
            }
            let lhsSecondary = secondary(lhs)
            let rhsSecondary = secondary(rhs)
            if lhsSecondary != rhsSecondary {
                return ascending ? lhsSecondary < rhsSecondary : lhsSecondary > rhsSecondary
            }
            return (baseIndex[lhs.id ?? 0] ?? 0) < (baseIndex[rhs.id ?? 0] ?? 0)
        }
    }

    private func stableSortText(
        _ books: [BookRecord],
        baseIndex: [Int64: Int],
        primary: @escaping (BookRecord) -> String,
        secondary: @escaping (BookRecord) -> Int64,
        ascending: Bool
    ) -> [BookRecord] {
        let letters = books.filter { ("A"..."Z").contains(primary($0)) }
        let symbols = books.filter { !("A"..."Z").contains(primary($0)) }
        let sort: ([BookRecord]) -> [BookRecord] = { values in
            values.sorted { lhs, rhs in
                let lhsPrimary = primary(lhs)
                let rhsPrimary = primary(rhs)
                if lhsPrimary != rhsPrimary {
                    return ascending ? lhsPrimary < rhsPrimary : lhsPrimary > rhsPrimary
                }
                let lhsSecondary = secondary(lhs)
                let rhsSecondary = secondary(rhs)
                if lhsSecondary != rhsSecondary {
                    return ascending ? lhsSecondary < rhsSecondary : lhsSecondary > rhsSecondary
                }
                return (baseIndex[lhs.id ?? 0] ?? 0) < (baseIndex[rhs.id ?? 0] ?? 0)
            }
        }
        return sort(letters) + sort(symbols)
    }
}

nonisolated private extension Array {
    /// 按 Android Repository 的 SQLite IN 分块上限切分数组。
    func chunked(maxCount: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: maxCount).map { start in
            Array(self[start..<Swift.min(start + maxCount, count)])
        }
    }
}
