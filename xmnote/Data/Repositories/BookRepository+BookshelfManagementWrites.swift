import Foundation
import GRDB

/**
 * [INPUT]: 依赖 BookRepository 数据库连接、GRDB Database 与首页书籍管理相关 Record/Repository 模型
 * [OUTPUT]: 为 BookRepository 补充书架排序、置顶、批量编辑、移组、删除、重命名与上下文管理写入逻辑
 * [POS]: Data 层首页书架管理写入协作者，隔离 BookRepository 主文件中的复杂 SQL 写入与级联副作用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

extension BookRepository {
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

    /// 按 Android 聚合维度顺序写入对应 order 字段，不更新时间戳。
    /// - Throws: 任一 SQL 写入失败时抛出错误。
    nonisolated func updateBookshelfAggregateOrder(
        _ db: Database,
        context: BookshelfAggregateOrderContext,
        orderedIDs: [Int64]
    ) throws {
        for (index, id) in orderedIDs.enumerated() {
            switch context {
            case .readStatus:
                try updateReadStatusOrder(db, id: id, order: Int64(index))
            case .tag:
                try updateTagOrder(db, id: id, order: Int64(index))
            case .source:
                try updateSourceOrder(db, id: id, order: Int64(index))
            }
        }
    }

    /// 按 Android `updateBookListOrder` 语义写入默认分组二级列表的组内顺序。
    /// - Throws: 任一 SQL 写入失败时抛出错误。
    nonisolated func updateBooksInGroupOrder(
        _ db: Database,
        groupID: Int64,
        orderedBookIDs: [Int64]
    ) throws {
        let validIDs = try fetchOrderedBookIDs(inGroup: groupID, db: db)
        let validIDSet = Set(validIDs)
        let uniqueOrderedIDs = orderedBookIDs.reduce(into: [Int64]()) { result, id in
            guard validIDSet.contains(id), !result.contains(id) else { return }
            result.append(id)
        }
        let missingIDs = validIDs.filter { !uniqueOrderedIDs.contains($0) }
        for (index, id) in (uniqueOrderedIDs + missingIDs).enumerated() {
            try updateBookOrder(db, id: id, order: Int64(index))
        }
    }

    /// 按默认分组当前顺序计算移到最前/最后后的完整书籍顺序，置顶书籍保持前缀顺序。
    nonisolated func reorderedBookListItems(
        _ ids: [Int64],
        in currentItems: [BookshelfBookListOrderItem],
        placement: BookshelfMovePlacement
    ) -> [BookshelfBookListOrderItem] {
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

    /// 按 Android 组内置顶语义，使用当前分组内最大 pin_order 作为追加起点。
    /// - Throws: 任一 SQL 读取或写入失败时抛出错误。
    nonisolated func pinBooksInGroup(
        _ db: Database,
        groupID: Int64,
        bookIDs: [Int64]
    ) throws {
        let validIDs = try fetchOrderedBookIDs(inGroup: groupID, db: db)
        let validIDSet = Set(validIDs)
        var nextPinOrder = try maxBookPinOrder(inGroup: groupID, db: db)
        for bookID in bookIDs where validIDSet.contains(bookID) {
            guard try !isBookPinned(db, bookID: bookID) else { continue }
            nextPinOrder += 1
            try updateBookPin(db, bookID: bookID, pinned: true, pinOrder: nextPinOrder)
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

    /// 读取批量编辑候选项，单本选择时补齐该书当前值。
    /// - Throws: 任一 SQL 读取失败时抛出错误。
    nonisolated func fetchBookshelfBatchEditOptions(
        _ db: Database,
        bookIDs: [Int64]
    ) throws -> BookshelfBatchEditOptions {
        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        let initialValues = uniqueBookIDs.count == 1
            ? try fetchBatchEditInitialValues(db, bookID: uniqueBookIDs[0])
            : nil
        return BookshelfBatchEditOptions(
            tags: try fetchBatchBookTagOptions(db, ownerID: ownerID),
            sources: try fetchBatchSourceOptions(db),
            readStatuses: try fetchBatchReadStatusOptions(db),
            initialTagIDs: initialValues?.tagIDs ?? [],
            initialSourceID: initialValues?.sourceID,
            initialReadStatusID: initialValues?.readStatusID,
            initialReadStatusChangedAt: initialValues?.readStatusChangedAt,
            initialRatingScore: initialValues?.ratingScore
        )
    }

    /// 按 Android 批量标签语义写入：单本替换全部标签，多本只追加缺失标签。
    /// - Throws: 选择为空、标签无效或 SQL 写入失败时抛出错误。
    nonisolated func batchSetBooksTags(
        _ db: Database,
        bookIDs: [Int64],
        tagIDs: [Int64]
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }

        let uniqueTagIDs = normalizedPositiveIDs(tagIDs)
        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        let activeTagIDs = try fetchActiveBookTagIDs(db, ownerID: ownerID)
        guard Set(uniqueTagIDs).isSubset(of: activeTagIDs) else { throw BookshelfBatchWriteError.invalidTag }

        let now = timestampMillis()
        if uniqueBookIDs.count == 1, let bookID = uniqueBookIDs.first {
            try softDeleteTags(ofBook: bookID, updatedAt: now, db: db)
            for tagID in uniqueTagIDs {
                try insertTagBook(bookID: bookID, tagID: tagID, createdAt: now, db: db)
            }
            return
        }

        guard !uniqueTagIDs.isEmpty else { return }
        for bookID in uniqueBookIDs {
            let existingTagIDs = try fetchActiveTagIDs(ofBook: bookID, db: db)
            for tagID in uniqueTagIDs where !existingTagIDs.contains(tagID) {
                try insertTagBook(bookID: bookID, tagID: tagID, createdAt: now, db: db)
            }
        }
    }

    /// 按 Android `batchSetBooksSource` 语义批量更新书籍来源。
    /// - Throws: 选择为空、来源无效或 SQL 写入失败时抛出错误。
    nonisolated func batchSetBooksSource(
        _ db: Database,
        bookIDs: [Int64],
        sourceID: Int64
    ) throws {
        let uniqueBookIDs = normalizedNonNegativeIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try isActiveSource(db, sourceID: sourceID) else { throw BookshelfBatchWriteError.invalidSource }

        for bookID in uniqueBookIDs {
            try updateBookSource(db, bookID: bookID, sourceID: sourceID)
        }
    }

    /// 在批量移组面板中新增分组，默认放到默认书架头部位置，并返回可直接选中的目标分组选项。
    /// - Throws: 名称非法、名称重复或 SQL 写入失败时抛出错误。
    nonisolated func createGroup(
        _ db: Database,
        name: String
    ) throws -> BookEditorNamedOption {
        let normalized = try validatedManagementName(
            name,
            target: "分组",
            maxLength: BookshelfManagementLimits.groupNameMaxLength
        )
        guard try !isDuplicateGroupName(db, name: normalized, excludingGroupID: nil) else {
            throw BookshelfBatchWriteError.duplicateName("此分组名称已存在，请使用不同的名称")
        }

        let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
        var record = GroupRecord(
            id: nil,
            userId: ownerID,
            name: normalized,
            groupOrder: try minDefaultBookshelfOrder(db) - 1,
            pinned: 0,
            pinOrder: 0,
            createdDate: timestampMillis(),
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
        guard let groupID = record.id else { throw BookshelfBatchWriteError.invalidGroup }
        return BookEditorNamedOption(id: groupID, title: normalized)
    }

    /// 在批量标签面板中新增书籍标签，并返回可直接勾选的新选项。
    /// - Throws: 名称非法、名称重复或 SQL 写入失败时抛出错误。
    nonisolated func createTag(
        _ db: Database,
        name: String
    ) throws -> BookEditorNamedOption {
        let normalized = try validatedManagementName(
            name,
            target: "标签",
            maxLength: BookshelfManagementLimits.tagNameMaxLength
        )
        guard try !isDuplicateBookTagName(db, name: normalized, excludingTagID: 0) else {
            throw BookshelfBatchWriteError.duplicateName("此标签名称已存在，请使用不同的名称")
        }

        let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
        let nextOrder = (try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(tag_order), -1) + 1 FROM tag WHERE type = 2 AND user_id = ?",
            arguments: [ownerID]
        )) ?? 0
        var record = TagRecord(
            id: nil,
            userId: ownerID,
            name: normalized,
            color: 0,
            tagOrder: nextOrder,
            type: 2,
            createdDate: timestampMillis(),
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
        guard let tagID = record.id else { throw BookshelfBatchWriteError.invalidTag }
        return BookEditorNamedOption(id: tagID, title: normalized)
    }

    /// 在批量来源面板中新增书籍来源，并返回可直接选中的来源选项（默认归入“我的来源”分区）。
    /// - Throws: 名称非法、名称重复或 SQL 写入失败时抛出错误。
    nonisolated func createSource(
        _ db: Database,
        name: String
    ) throws -> BookshelfSourceOption {
        let normalized = try validatedManagementName(
            name,
            target: "来源",
            maxLength: BookshelfManagementLimits.sourceNameMaxLength
        )
        guard try !isDuplicateSourceName(db, name: normalized, excludingSourceID: 0) else {
            throw BookshelfBatchWriteError.duplicateName("此来源名称已存在，请使用不同的名称")
        }

        let nextOrder = (try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(source_order), -1) + 1 FROM source WHERE is_deleted = 0"
        )) ?? 0
        var record = SourceRecord(
            id: nil,
            name: normalized,
            sourceOrder: nextOrder,
            bookshelfOrder: -1,
            isHide: 0,
            createdDate: timestampMillis(),
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
        guard let sourceID = record.id else { throw BookshelfBatchWriteError.invalidSource }
        return BookshelfSourceOption(
            id: sourceID,
            title: normalized,
            category: sourceCategory(for: sourceID)
        )
    }

    /// 按 Android `updateBookReadStatus` 与 `rating` 语义批量更新阅读状态。
    /// - Throws: 选择为空、状态无效、读完未评分或 SQL 写入失败时抛出错误。
    nonisolated func batchSetBookReadStatus(
        _ db: Database,
        bookIDs: [Int64],
        input: BookshelfBatchReadStatusInput
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try isActiveReadStatus(db, statusID: input.statusID) else {
            throw BookshelfBatchWriteError.invalidReadStatus
        }

        let now = timestampMillis()
        let finishedStatusID = BookEntryReadingStatus.finished.rawValue
        let ratingScore = input.statusID == finishedStatusID ? max(0, min(input.ratingScore ?? 0, 50)) : nil
        for bookID in uniqueBookIDs {
            try BookReadStatusMutation.updateBookReadStatus(
                db,
                bookID: bookID,
                statusID: input.statusID,
                changedAt: input.changedAt,
                updatedAt: now,
                finishedRatingScore: ratingScore
            )
        }
    }

    /// 读取仍有效的分组候选项，供批量移入分组 Sheet 使用。
    /// - Throws: SQL 读取失败时抛出错误。
    nonisolated func fetchMoveTargetGroups(
        _ db: Database,
        excludingGroupID: Int64?
    ) throws -> [BookshelfMoveGroupOption] {
        let exclusionPredicate: String
        let arguments: StatementArguments
        if let excludingGroupID, excludingGroupID > 0 {
            exclusionPredicate = "AND g.id != ?"
            arguments = [excludingGroupID]
        } else {
            exclusionPredicate = ""
            arguments = []
        }

        // SQL 目的：读取可作为批量移入目标的有效分组，并补齐分组内有效书籍封面与排序元数据。
        // 涉及表：`group` g LEFT JOIN group_book gb LEFT JOIN book b，另通过 read_status/source/read_time_record/note 补齐现有分组预览排序所需字段。
        // 关键过滤：g.is_deleted = 0；gb/b 均过滤软删除；b.id != 0；默认分组二级页会额外排除当前 group id；组内书籍仅保留 Android 语义下最早有效分组关系。
        // 返回字段用途：group id/name 构造目标分组，book cover/count 构造移组 Sheet 的分组封面与数量；时间字段仅供现有预览排序逻辑使用，不参与写入。
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
            LEFT JOIN group_book gb
              ON gb.group_id = g.id
             AND gb.is_deleted = 0
            LEFT JOIN book b
              ON b.id = gb.book_id
             AND b.is_deleted = 0
             AND b.id != 0
             AND gb.id = (
                 SELECT gb2.id
                 FROM group_book gb2
                 WHERE gb2.book_id = b.id
                   AND gb2.is_deleted = 0
                 ORDER BY gb2.created_date ASC, gb2.id ASC
                 LIMIT 1
             )
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
              \(exclusionPredicate)
            ORDER BY g.group_order ASC, g.id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
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
            guard let bookID = row["book_id"] as Int64?,
                  var builder = builders[groupID] else {
                continue
            }
            builder.append(
                BookshelfGroupBookPreview(
                    id: bookID,
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
        return orderedGroupIDs.compactMap { groupID in
            guard let builder = builders[groupID] else { return nil }
            let sortedBooks = sortGroupPreviewBooks(builder.books, setting: groupBookListSetting)
            return BookshelfMoveGroupOption(
                id: builder.id,
                title: builder.name,
                bookCount: sortedBooks.count,
                representativeCovers: sortedBooks.prefix(4).map(\.cover)
            )
        }
    }

    /// 读取未删除的手动书单列表，供批量加入书单 Sheet 使用。
    /// - Throws: SQL 读取失败时抛出错误。
    nonisolated func fetchManualBookCollections(_ db: Database) throws -> [BookCollectionSummary] {
        // SQL 目的：读取可作为批量加入目标的手动书单，并统计每个书单下有效书籍关系数量。
        // 涉及表：collection c LEFT JOIN collection_book cb LEFT JOIN book b。
        // 关键过滤：c.is_deleted = 0、c.is_annual = 0；统计时仅计算 cb.is_deleted = 0 且 book 未软删除、非占位书的关系。
        // 时间字段：不参与排序和返回，保持 Android queryMineCollectionList 的 order 升序语义。
        // 返回字段用途：构建加入书单 Sheet 的标题、描述和书籍数量。
        let sql = """
            SELECT c.id,
                   COALESCE(c.title, '') AS title,
                   COALESCE(c.`desc`, '') AS description,
                   COUNT(b.id) AS book_count
            FROM collection c
            LEFT JOIN collection_book cb
              ON cb.collection_id = c.id
             AND cb.is_deleted = 0
            LEFT JOIN book b
              ON b.id = cb.book_id
             AND b.is_deleted = 0
             AND b.id != 0
            WHERE c.is_deleted = 0
              AND c.is_annual = 0
            GROUP BY c.id
            ORDER BY c.`order` ASC, c.id ASC
            """
        return try Row.fetchAll(db, sql: sql).compactMap { row in
            let title = (row["title"] as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return BookCollectionSummary(
                id: row["id"],
                title: title,
                description: row["description"] ?? "",
                bookCount: row["book_count"] ?? 0
            )
        }
    }

    /// 新建手动书单并返回可立即选中的摘要。
    /// - Throws: 名称为空、名称过长、重名或 SQL 写入失败时抛出错误。
    nonisolated func createBookCollection(_ db: Database, title: String) throws -> BookCollectionSummary {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw BookshelfBatchWriteError.invalidName("书单") }
        guard normalized.count <= BookshelfManagementLimits.collectionNameMaxLength else {
            throw BookshelfBatchWriteError.invalidNameLength(
                target: "书单",
                maxLength: BookshelfManagementLimits.collectionNameMaxLength
            )
        }

        // SQL 目的：按 Android CollectionDao.query(title, desc) 判定手动书单重名。
        // 涉及表：collection。
        // 关键过滤：title 与空 desc 精确匹配，且 is_deleted = 0；is_annual 不额外参与 Android 原始查重口径。
        // 时间字段：不读取时间字段。
        // 返回字段用途：存在任意同名空描述书单时阻止新增。
        let duplicateSQL = """
            SELECT id
            FROM collection
            WHERE title = ?
              AND `desc` = ''
              AND is_deleted = 0
            LIMIT 1
            """
        if try Int64.fetchOne(db, sql: duplicateSQL, arguments: [normalized]) != nil {
            throw BookshelfBatchWriteError.duplicateName("要创建的书单已经存在了")
        }

        // SQL 目的：读取当前有效书单最小 order，新书单按 Android 规则放在最前。
        // 涉及表：collection。
        // 关键过滤：只看 is_deleted = 0 的有效书单；Android queryMinCollectionOrder 不区分年度与手动书单。
        // 时间字段：不参与。
        // 返回字段用途：新建书单 order = min(order) - 1。
        let minOrder = try Int64.fetchOne(
            db,
            sql: "SELECT MIN(`order`) FROM collection WHERE is_deleted = 0"
        ) ?? 0
        let now = timestampMillis()
        var record = CollectionRecord(
            id: nil,
            title: normalized,
            desc: "",
            order: minOrder - 1,
            isAnnual: 0,
            year: 0,
            createdDate: now,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
        return BookCollectionSummary(
            id: record.id ?? 0,
            title: normalized,
            description: "",
            bookCount: 0
        )
    }

    /// 批量把书籍加入目标手动书单，仅为缺失的有效关系插入记录。
    /// - Throws: 选择为空、书单无效或 SQL 写入失败时抛出错误。
    nonisolated func addBooksToCollection(
        _ db: Database,
        bookIDs: [Int64],
        collectionID: Int64
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try isActiveManualCollection(db, collectionID: collectionID) else {
            throw BookshelfBatchWriteError.invalidCollection
        }

        let now = timestampMillis()
        for bookID in uniqueBookIDs {
            guard try isActiveBook(db, bookID: bookID) else { continue }
            guard try !hasActiveCollectionBookRelation(db, bookID: bookID, collectionID: collectionID) else {
                continue
            }
            var relation = CollectionBookRecord(
                id: nil,
                collectionId: collectionID,
                bookId: bookID,
                recommend: "",
                order: Int64(Int32.max),
                createdDate: now,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try relation.insert(db)
        }
    }

    /// 校验目标书单为未删除、非年度的手动书单。
    nonisolated func isActiveManualCollection(_ db: Database, collectionID: Int64) throws -> Bool {
        // SQL 目的：确认加入书单目标仍是可写手动书单。
        // 涉及表：collection。
        // 关键过滤：id 精确命中、is_deleted = 0、is_annual = 0。
        // 时间字段：不参与。
        // 返回字段用途：防止批量写入年度书单或已删除书单。
        let sql = """
            SELECT COUNT(*)
            FROM collection
            WHERE id = ?
              AND is_deleted = 0
              AND is_annual = 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [collectionID]) ?? 0) > 0
    }

    /// 查询有效书单关系是否已存在，避免重复插入。
    nonisolated func hasActiveCollectionBookRelation(
        _ db: Database,
        bookID: Int64,
        collectionID: Int64
    ) throws -> Bool {
        // SQL 目的：复刻 Android queryCollectionBookSuspend 的去重判断。
        // 涉及表：collection_book。
        // 关键过滤：book_id、collection_id 精确匹配且 is_deleted = 0。
        // 时间字段：不参与。
        // 返回字段用途：已有有效关系时跳过插入，保留原 recommend/order/created_date。
        let sql = """
            SELECT id
            FROM collection_book
            WHERE book_id = ?
              AND collection_id = ?
              AND is_deleted = 0
            LIMIT 1
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [bookID, collectionID]) != nil
    }

    /// 复刻 Android GroupRepository.moveBooksToGroup，把书籍移动到指定分组。
    /// - Throws: 选择为空、目标分组无效或 SQL 写入失败时抛出错误。
    nonisolated func moveBooksToGroup(
        _ db: Database,
        bookIDs: [Int64],
        targetGroupID: Int64
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        guard try isActiveGroup(db, groupID: targetGroupID) else { throw BookshelfBatchWriteError.invalidGroup }

        let now = timestampMillis()
        for bookID in uniqueBookIDs {
            guard try isActiveBook(db, bookID: bookID) else { continue }
            try updateBookPin(db, bookID: bookID, pinned: false, pinOrder: 0)
            let nextOrder = try maxBookOrder(inGroup: targetGroupID, db: db) + 1
            try softDeleteGroupRelations(ofBook: bookID, updatedAt: now, db: db)
            try insertGroupBook(groupID: targetGroupID, bookID: bookID, createdAt: now, db: db)
            try updateBookOrderWithTimestamp(db, id: bookID, order: nextOrder, updatedAt: now)
        }
    }

    /// 复刻 Android GroupRepository.moveOut，把书籍移回默认书架头部或尾部。
    /// - Throws: 选择为空或 SQL 写入失败时抛出错误。
    nonisolated func moveBooksOutOfGroup(
        _ db: Database,
        bookIDs: [Int64],
        placement: GroupBooksPlacement
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }

        let now = timestampMillis()
        for bookID in uniqueBookIDs {
            guard try isActiveBook(db, bookID: bookID) else { continue }
            try updateBookPin(db, bookID: bookID, pinned: false, pinOrder: 0)
            try softDeleteGroupRelations(ofBook: bookID, updatedAt: now, db: db)
            let order = switch placement {
            case .start:
                try minDefaultBookshelfOrder(db) - 1
            case .end:
                try maxDefaultBookshelfOrder(db) + 1
            }
            try updateBookOrderWithTimestamp(db, id: bookID, order: order, updatedAt: now)
        }
    }

    /// 复刻 Android BookRepository.deleteBooksAndGroups，先删除顶层书籍，再处理分组内书籍安置与分组删除。
    /// - Throws: 选择为空或任一 SQL 写入失败时抛出错误。
    nonisolated func deleteBookshelfItems(
        _ db: Database,
        ids: [BookshelfItemID],
        groupBooksPlacement: GroupBooksPlacement
    ) throws {
        guard !ids.isEmpty else { throw BookshelfBatchWriteError.emptySelection }

        let bookIDs = ids.compactMap { id -> Int64? in
            if case .book(let bookID) = id { return bookID }
            return nil
        }
        if !bookIDs.isEmpty {
            try deleteBooks(db, bookIDs: bookIDs)
        }

        let groupIDs = ids.compactMap { id -> Int64? in
            if case .group(let groupID) = id { return groupID }
            return nil
        }
        for groupID in normalizedPositiveIDs(groupIDs) {
            try deleteGroup(db, groupID: groupID, placement: groupBooksPlacement)
        }
    }

    /// 软删除一组书籍及其 Android 对齐关联数据。
    /// - Throws: 选择为空或任一 SQL 写入失败时抛出错误。
    nonisolated func deleteBooks(
        _ db: Database,
        bookIDs: [Int64]
    ) throws {
        let uniqueBookIDs = normalizedPositiveIDs(bookIDs)
        guard !uniqueBookIDs.isEmpty else { throw BookshelfBatchWriteError.emptySelection }
        for bookID in uniqueBookIDs {
            try deleteBook(db, bookID: bookID)
        }
    }

    /// 软删除单本书，并按 Android deleteBook 的 17 步顺序清理 book_id 关联表。
    /// - Throws: 任一 SQL 写入失败时抛出错误。
    nonisolated func deleteBook(
        _ db: Database,
        bookID: Int64
    ) throws {
        guard try isActiveBook(db, bookID: bookID) else { return }
        let now = timestampMillis()
        try softDeleteBook(db, bookID: bookID, updatedAt: now)
        try softDeleteTags(ofBook: bookID, updatedAt: now, db: db)
        try softDeleteTagNotesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteNotesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteAttachImagesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCategoriesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCategoryImagesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCategoryContentsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteReviewsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteReviewImagesOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteChaptersOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteGroupRelations(ofBook: bookID, updatedAt: now, db: db)
        try softDeleteReadStatusRecordsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteReadTimeRecordsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteSortRecordsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCheckInsOfBook(db, bookID: bookID, updatedAt: now)
        try softDeleteCollectionBooksOfBook(db, bookID: bookID)
        try softDeleteReadPlansOfBook(db, bookID: bookID)
    }

    /// 删除分组前先将组内书籍移回默认书架，再软删除分组本身。
    /// - Throws: 分组无效或 SQL 写入失败时抛出错误。
    nonisolated func deleteGroup(
        _ db: Database,
        groupID: Int64,
        placement: GroupBooksPlacement
    ) throws {
        guard try isActiveGroup(db, groupID: groupID) else { throw BookshelfBatchWriteError.invalidGroup }
        let bookIDs = try fetchOrderedBookIDs(inGroup: groupID, db: db)
        if !bookIDs.isEmpty {
            try moveBooksOutOfGroup(db, bookIDs: bookIDs, placement: placement)
        }
        try softDeleteGroup(db, groupID: groupID)
    }

    /// 重命名有效分组；iOS 在迁移面板中约束分组名唯一，重命名与新增都执行同一重名校验。
    /// - Throws: 名称非法、分组无效、名称重复或 SQL 写入失败时抛出错误。
    nonisolated func renameGroup(
        _ db: Database,
        groupID: Int64,
        newName: String
    ) throws {
        guard try isActiveGroup(db, groupID: groupID) else { throw BookshelfBatchWriteError.invalidGroup }
        let name = try validatedManagementName(
            newName,
            target: "分组",
            maxLength: BookshelfManagementLimits.groupNameMaxLength
        )
        guard try !isDuplicateGroupName(db, name: name, excludingGroupID: groupID) else {
            throw BookshelfBatchWriteError.duplicateName("此分组名称已存在，请使用不同的名称")
        }
        let now = timestampMillis()

        // SQL 目的：重命名有效书籍分组。
        // 涉及表：`group`。
        // 关键过滤：id = ? 且 is_deleted = 0，严格对齐 Android GroupDao.updateName。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新分组名称并触发书架观察流刷新。
        let sql = """
            UPDATE `group`
            SET updated_date = ?,
                name = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [now, name, groupID])
    }

    /// 重命名有效书籍标签，并执行 Android TagRepository.rename 的重名校验。
    /// - Throws: 名称为空、标签无效、名称重复或 SQL 写入失败时抛出错误。
    nonisolated func renameTag(
        _ db: Database,
        tagID: Int64,
        newName: String
    ) throws {
        guard try isActiveBookTag(db, tagID: tagID) else { throw BookshelfBatchWriteError.invalidTag }
        let name = try validatedManagementName(newName, target: "标签")
        guard try !isDuplicateBookTagName(db, name: name, excludingTagID: tagID) else {
            throw BookshelfBatchWriteError.duplicateName("此标签名称已存在，请使用不同的名称")
        }
        let now = timestampMillis()

        // SQL 目的：重命名有效书籍标签。
        // 涉及表：tag。
        // 关键过滤：id = ?、type = 2 且 is_deleted = 0，只影响书籍标签。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新标签名称并触发标签维度与二级列表刷新。
        let sql = """
            UPDATE tag
            SET updated_date = ?,
                name = ?
            WHERE id = ?
              AND type = 2
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [now, name, tagID])
    }

    /// 删除有效书籍标签，同时清理 tag_book 与 tag_note 关系。
    /// - Throws: 标签无效或 SQL 写入失败时抛出错误。
    nonisolated func deleteTag(
        _ db: Database,
        tagID: Int64
    ) throws {
        guard try isActiveBookTag(db, tagID: tagID) else { throw BookshelfBatchWriteError.invalidTag }
        let now = timestampMillis()
        try softDeleteTagBookRelations(db, tagID: tagID, updatedAt: now)
        try softDeleteTagNoteRelations(db, tagID: tagID, updatedAt: now)
        try softDeleteBookTag(db, tagID: tagID, updatedAt: now)
    }

    /// 重命名有效来源，并执行 Android SourceRepository.rename 的重名校验。
    /// - Throws: 名称为空、来源无效、名称重复或 SQL 写入失败时抛出错误。
    nonisolated func renameSource(
        _ db: Database,
        sourceID: Int64,
        newName: String
    ) throws {
        guard try isActiveSource(db, sourceID: sourceID) else { throw BookshelfBatchWriteError.invalidSource }
        let name = try validatedManagementName(newName, target: "来源")
        guard try !isDuplicateSourceName(db, name: name, excludingSourceID: sourceID) else {
            throw BookshelfBatchWriteError.duplicateName("此来源名称已存在，请使用不同的名称")
        }

        // SQL 目的：重命名有效书籍来源。
        // 涉及表：source。
        // 关键过滤：id = ? 且 is_deleted = 0，对齐 Android SourceDao.rename。
        // 时间字段：Android 来源重命名不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：更新来源名称并触发来源维度与二级列表刷新。
        let sql = """
            UPDATE source
            SET name = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [name, sourceID])
    }

    /// 删除有效来源前将书籍迁移到未知来源，再软删除来源本身。
    /// - Throws: 来源无效、尝试删除未知来源或 SQL 写入失败时抛出错误。
    nonisolated func deleteSource(
        _ db: Database,
        sourceID: Int64
    ) throws {
        guard try isActiveSource(db, sourceID: sourceID) else { throw BookshelfBatchWriteError.invalidSource }
        let fallbackSourceID = try unknownSourceID(db, deletingSourceID: sourceID)
        try migrateBooks(fromSourceID: sourceID, toSourceID: fallbackSourceID, db: db)
        try softDeleteSource(db, sourceID: sourceID)
    }

    /// 重命名作者资料，并按 Android `updateBooksAuthor` 同步所有同名书籍。
    /// - Throws: 名称为空或 SQL 写入失败时抛出错误。
    nonisolated func renameAuthor(
        _ db: Database,
        oldName: String,
        newName: String
    ) throws {
        let currentName = try validatedManagementName(oldName, target: "作者")
        let targetName = try validatedManagementName(newName, target: "作者")
        guard currentName != targetName else { return }
        let now = timestampMillis()

        if let authorID = try fetchAuthorID(db, name: currentName) {
            try updateAuthorName(db, authorID: authorID, name: targetName, updatedAt: now)
        } else {
            try insertAuthorName(db, name: targetName, now: now)
        }
        try updateBooksAuthor(db, oldName: currentName, newName: targetName)
    }

    /// 删除作者维度下的有效书籍，并按 Android `AuthorDao.deleteById` 硬删除作者资料。
    /// - Throws: 名称为空或 SQL 写入失败时抛出错误。
    nonisolated func deleteAuthor(
        _ db: Database,
        name: String
    ) throws {
        let authorName = try validatedManagementName(name, target: "作者")
        let bookIDs = try fetchBookIDsByAuthor(db, name: authorName)
        if !bookIDs.isEmpty {
            try deleteBooks(db, bookIDs: bookIDs)
        }
        if let authorID = try fetchAuthorID(db, name: authorName) {
            try hardDeleteAuthor(db, authorID: authorID)
        }
    }

    /// 重命名出版社资料，并按 Android `updateBooksPress` 同步所有同名书籍。
    /// - Throws: 名称为空或 SQL 写入失败时抛出错误。
    nonisolated func renamePress(
        _ db: Database,
        oldName: String,
        newName: String
    ) throws {
        let currentName = try validatedManagementName(oldName, target: "出版社")
        let targetName = try validatedManagementName(newName, target: "出版社")
        guard currentName != targetName else { return }
        let now = timestampMillis()

        if let pressID = try fetchPressID(db, name: currentName) {
            try updatePressName(db, pressID: pressID, name: targetName, updatedAt: now)
        } else {
            try insertPressName(db, name: targetName, now: now)
        }
        try updateBooksPress(db, oldName: currentName, newName: targetName)
    }

    /// 删除出版社维度下的有效书籍，并按 Android `PressDao.deleteById` 硬删除出版社资料。
    /// - Throws: 名称为空或 SQL 写入失败时抛出错误。
    nonisolated func deletePress(
        _ db: Database,
        name: String
    ) throws {
        let pressName = try validatedManagementName(name, target: "出版社")
        let bookIDs = try fetchBookIDsByPress(db, name: pressName)
        if !bookIDs.isEmpty {
            try deleteBooks(db, bookIDs: bookIDs)
        }
        if let pressID = try fetchPressID(db, name: pressName) {
            try hardDeletePress(db, pressID: pressID)
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

    /// 更新时间戳并写入单本书排序值；用于移入/移出分组这类 Android 会更新时间的路径。
    nonisolated func updateBookOrderWithTimestamp(
        _ db: Database,
        id: Int64,
        order: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：写入移入/移出分组后的 Book 排序值。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，严格对齐 Android BookDao.updateBookOrder。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：更新 book_order，让目标分组或默认书架排序立即刷新。
        let sql = """
            UPDATE book
            SET updated_date = ?,
                book_order = ?
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, order, id])
    }

    /// 校验分组是否仍有效。
    nonisolated func isActiveGroup(_ db: Database, groupID: Int64) throws -> Bool {
        // SQL 目的：校验批量移入目标分组是否仍有效。
        // 涉及表：`group`。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM `group`
            WHERE id = ?
              AND is_deleted = 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [groupID]) ?? 0) > 0
    }

    /// 校验书籍是否仍可被书架管理写入处理。
    nonisolated func isActiveBook(_ db: Database, bookID: Int64) throws -> Bool {
        // SQL 目的：校验被移组书籍是否仍有效。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM book
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [bookID]) ?? 0) > 0
    }

    /// 软删除单本书当前所有有效分组关系。
    nonisolated func softDeleteGroupRelations(
        ofBook bookID: Int64,
        updatedAt: Int64,
        db: Database
    ) throws {
        // SQL 目的：移入或移出分组时清除该书现有有效分组关系。
        // 涉及表：group_book。
        // 关键过滤：book_id = ? 且 is_deleted = 0；对齐 Android GroupBookDao.deleteByBookId。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：保证同一本书只保留一个有效分组归属，或回到默认书架顶层。
        let sql = """
            UPDATE group_book
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 插入目标分组与书籍关系。
    nonisolated func insertGroupBook(
        groupID: Int64,
        bookID: Int64,
        createdAt: Int64,
        db: Database
    ) throws {
        var relation = GroupBookRecord(
            id: nil,
            groupId: groupID,
            bookId: bookID,
            createdDate: createdAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try relation.insert(db)
    }

    /// 查询指定分组内有效书籍的最大排序值。
    nonisolated func maxBookOrder(inGroup groupID: Int64, db: Database) throws -> Int64 {
        // SQL 目的：读取目标分组内有效书籍最大 book_order，作为移入分组追加位置。
        // 涉及表：group_book JOIN book。
        // 关键过滤：group_id = ?、group_book/book 均未软删除、book.id != 0，并仅保留该书最早有效分组关系。
        // 返回字段用途：移入分组时写入 max + 1；空分组回退 0。
        let sql = """
            SELECT MAX(book.book_order)
            FROM group_book
            JOIN book ON group_book.book_id = book.id
            WHERE group_book.group_id = ?
              AND group_book.is_deleted = 0
              AND book.is_deleted = 0
              AND book.id != 0
              AND group_book.id = (
                  SELECT gb2.id
                  FROM group_book gb2
                  WHERE gb2.book_id = book.id
                    AND gb2.is_deleted = 0
                  ORDER BY gb2.created_date ASC, gb2.id ASC
                  LIMIT 1
              )
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [groupID]) ?? 0
    }

    /// 查询默认书架 Book/Group 混排最大排序值。
    nonisolated func maxDefaultBookshelfOrder(_ db: Database) throws -> Int64 {
        // SQL 目的：读取默认书架顶层有效书籍最大 book_order。
        // 涉及表：book；子查询使用 group_book 排除仍在任意有效分组中的书籍。
        // 关键过滤：book.is_deleted = 0、book.id != 0、group_book.is_deleted = 0。
        // 返回字段用途：与 group_order 最大值合并，移出分组到尾部时写入 max + 1。
        let bookSQL = """
            SELECT MAX(book_order)
            FROM book
            WHERE is_deleted = 0
              AND id != 0
              AND id NOT IN (
                  SELECT book_id
                  FROM group_book
                  WHERE is_deleted = 0
              )
            """
        // SQL 目的：读取默认书架有效分组最大 group_order。
        // 涉及表：`group`。
        // 关键过滤：is_deleted = 0。
        // 返回字段用途：与顶层书籍最大值合并，保持 Book/Group 共用手动排序空间。
        let groupSQL = """
            SELECT MAX(group_order)
            FROM `group`
            WHERE is_deleted = 0
            """
        let bookMax = try Int64.fetchOne(db, sql: bookSQL) ?? 0
        let groupMax = try Int64.fetchOne(db, sql: groupSQL) ?? 0
        return max(bookMax, groupMax)
    }

    /// 查询默认书架 Book/Group 混排最小排序值。
    nonisolated func minDefaultBookshelfOrder(_ db: Database) throws -> Int64 {
        // SQL 目的：读取默认书架顶层有效书籍最小 book_order。
        // 涉及表：book；子查询使用 group_book 排除仍在任意有效分组中的书籍。
        // 关键过滤：book.is_deleted = 0、book.id != 0、group_book.is_deleted = 0。
        // 返回字段用途：与 group_order 最小值合并，移出分组到头部时写入 min - 1。
        let bookSQL = """
            SELECT MIN(book_order)
            FROM book
            WHERE is_deleted = 0
              AND id != 0
              AND id NOT IN (
                  SELECT book_id
                  FROM group_book
                  WHERE is_deleted = 0
              )
            """
        // SQL 目的：读取默认书架有效分组最小 group_order。
        // 涉及表：`group`。
        // 关键过滤：is_deleted = 0。
        // 返回字段用途：与顶层书籍最小值合并，保持 Book/Group 共用手动排序空间。
        let groupSQL = """
            SELECT MIN(group_order)
            FROM `group`
            WHERE is_deleted = 0
            """
        let bookMin = try Int64.fetchOne(db, sql: bookSQL) ?? 0
        let groupMin = try Int64.fetchOne(db, sql: groupSQL) ?? 0
        return min(bookMin, groupMin)
    }

    /// 写入单本书置顶字段；用于默认分组组内置顶和取消置顶。
    nonisolated func updateBookPin(
        _ db: Database,
        bookID: Int64,
        pinned: Bool,
        pinOrder: Int64
    ) throws {
        let pinnedValue: Int64 = pinned ? 1 : 0
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

    /// 更新阅读状态排序值；对齐 Android updateBookReadStatusOrder。
    nonisolated func updateReadStatusOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入阅读状态在书架状态维度中的手动排序下标。
        // 涉及表：read_status。
        // 关键过滤：按 id 精确命中，且排除软删除状态。
        // 副作用用途：仅更新 read_status_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE read_status
            SET read_status_order = ?
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 更新标签排序值；对齐 Android tagRepo.updateOrder。
    nonisolated func updateTagOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入书籍标签在书架标签维度中的手动排序下标。
        // 涉及表：tag。
        // 关键过滤：按 id 精确命中，要求 type = 2 且 is_deleted = 0，避免影响书摘标签。
        // 副作用用途：仅更新 tag_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE tag
            SET tag_order = ?
            WHERE id = ?
              AND type = 2
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [order, id])
    }

    /// 更新来源排序值；对齐 Android updateBookSourceListOrder。
    nonisolated func updateSourceOrder(
        _ db: Database,
        id: Int64,
        order: Int64
    ) throws {
        // SQL 目的：写入书籍来源在书架来源维度中的手动排序下标。
        // 涉及表：source。
        // 关键过滤：按 id 精确命中，且排除软删除来源。
        // 副作用用途：仅更新 source_order，不更新 updated_date / last_sync_date。
        let sql = """
            UPDATE source
            SET source_order = ?
            WHERE id = ?
              AND is_deleted = 0
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

    /// 读取当前用户的书籍标签候选项。
    nonisolated func fetchBatchBookTagOptions(
        _ db: Database,
        ownerID: Int64
    ) throws -> [BookEditorNamedOption] {
        // SQL 目的：读取当前用户下可用于批量设置的书籍标签。
        // 涉及表：tag。
        // 关键过滤：user_id = ?、type = 2 仅书籍标签、is_deleted = 0 排除软删除。
        // 返回字段用途：id/name 直接构造批量标签 Sheet 选项；时间字段不参与本查询。
        let sql = """
            SELECT id, COALESCE(name, '') AS name
            FROM tag
            WHERE user_id = ?
              AND type = 2
              AND is_deleted = 0
            ORDER BY tag_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [ownerID]).map { row in
            let title: String = row["name"] ?? ""
            return BookEditorNamedOption(
                id: row["id"],
                title: title.isEmpty ? "未命名标签" : title
            )
        }
    }

    /// 读取批量来源候选项，并补齐“我的来源/默认来源”分区元数据。
    nonisolated func fetchBatchSourceOptions(_ db: Database) throws -> [BookshelfSourceOption] {
        // SQL 目的：读取可用于批量设置的有效书籍来源。
        // 涉及表：source。
        // 关键过滤：is_deleted = 0 排除软删除来源；隐藏来源仍允许作为存量书籍来源被重新选择。
        // 返回字段用途：id/name 直接构造批量来源 Sheet 选项；时间字段不参与本查询。
        let sql = """
            SELECT id, COALESCE(name, '') AS name
            FROM source
            WHERE is_deleted = 0
            ORDER BY source_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let sourceID: Int64 = row["id"] ?? 0
            let title: String = row["name"] ?? ""
            return BookshelfSourceOption(
                id: sourceID,
                title: title.isEmpty ? "未知来源" : title,
                category: sourceCategory(for: sourceID)
            )
        }
    }

    /// 按 Android 常量范围识别来源分区：1...27 为默认来源，其余归“我的来源”。
    nonisolated func sourceCategory(for sourceID: Int64) -> BookshelfSourceCategory {
        if BookshelfManagementLimits.defaultSourceIDRange.contains(sourceID) {
            return .appDefault
        }
        return .mine
    }

    /// 读取批量阅读状态候选项。
    nonisolated func fetchBatchReadStatusOptions(_ db: Database) throws -> [BookEditorNamedOption] {
        // SQL 目的：读取可用于批量设置的阅读状态字典。
        // 涉及表：read_status。
        // 关键过滤：is_deleted = 0 排除软删除状态。
        // 返回字段用途：id/name 直接构造批量阅读状态 Sheet 选项；时间字段不参与本查询。
        let sql = """
            SELECT id, COALESCE(name, '') AS name
            FROM read_status
            WHERE is_deleted = 0
            ORDER BY read_status_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            let title: String = row["name"] ?? ""
            return BookEditorNamedOption(
                id: row["id"],
                title: title.isEmpty ? "未命名状态" : title
            )
        }
    }

    /// 读取单本书当前批量编辑初始值。
    nonisolated func fetchBatchEditInitialValues(
        _ db: Database,
        bookID: Int64
    ) throws -> BookshelfBatchEditInitialValues? {
        // SQL 目的：读取单本书当前来源、阅读状态、状态时间与评分，作为批量编辑 Sheet 初始值。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，跳过已删除书籍和占位书籍。
        // 返回字段用途：source_id/read_status_id/read_status_changed_date/score 只用于 Sheet 默认选择，不产生写入副作用。
        let sql = """
            SELECT source_id, read_status_id, read_status_changed_date, score
            FROM book
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookID]) else { return nil }
        return BookshelfBatchEditInitialValues(
            tagIDs: try fetchBatchSelectedTagIDs(ofBook: bookID, db: db),
            sourceID: row["source_id"],
            readStatusID: row["read_status_id"],
            readStatusChangedAt: row["read_status_changed_date"],
            ratingScore: row["score"]
        )
    }

    /// 读取当前用户仍有效的书籍标签 ID 集合。
    nonisolated func fetchActiveBookTagIDs(_ db: Database, ownerID: Int64) throws -> Set<Int64> {
        // SQL 目的：读取当前用户下仍有效的书籍标签 ID，用于批量标签写入前校验。
        // 涉及表：tag。
        // 关键过滤：user_id = ?、type = 2、is_deleted = 0。
        // 返回字段用途：校验提交 tagIDs 全部来自有效书籍标签；时间字段不参与本查询。
        let sql = """
            SELECT id
            FROM tag
            WHERE user_id = ?
              AND type = 2
              AND is_deleted = 0
        """
        return Set(try Int64.fetchAll(db, sql: sql, arguments: [ownerID]))
    }

    /// 读取单本书当前有效书籍标签 ID，作为单本标签 Sheet 初始勾选项。
    nonisolated func fetchBatchSelectedTagIDs(ofBook bookID: Int64, db: Database) throws -> [Int64] {
        // SQL 目的：读取单本书当前有效书籍标签关系，作为标签 Sheet 初始选择。
        // 涉及表：tag_book tb JOIN tag t。
        // 关键过滤：tb.book_id = ?、tb.is_deleted = 0、t.is_deleted = 0、t.type = 2。
        // 返回字段用途：tag_id 按 tag_order/id 排序返回，用于单本标签替换前的默认勾选；时间字段不参与本查询。
        let sql = """
            SELECT t.id
            FROM tag_book tb
            JOIN tag t ON t.id = tb.tag_id
            WHERE tb.book_id = ?
              AND tb.is_deleted = 0
              AND t.is_deleted = 0
              AND t.type = 2
            ORDER BY t.tag_order ASC, t.id ASC
            """
        return try Int64.fetchAll(db, sql: sql, arguments: [bookID])
    }

    /// 软删除指定书籍当前有效标签关系。
    nonisolated func softDeleteTags(
        ofBook bookID: Int64,
        updatedAt: Int64,
        db: Database
    ) throws {
        // SQL 目的：软删除单本书现有标签关系，复刻 Android 单本批量设置标签的“先清空再插入”语义。
        // 涉及表：tag_book。
        // 关键过滤：book_id = ? 且 is_deleted = 0，仅处理当前有效关系。
        // 时间字段：updated_date 写入毫秒时间戳，last_sync_date 保持原值等待同步层处理。
        // 副作用用途：将旧关系标记为删除，为新标签集合插入干净关系。
        let sql = """
            UPDATE tag_book
            SET is_deleted = 1,
                updated_date = ?
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除单本书主记录。
    nonisolated func softDeleteBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除有效书籍主记录。
        // 涉及表：book。
        // 关键过滤：id = ?、is_deleted = 0、id != 0，对齐 Android BookDao.deleteBook。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：从所有书架观察流中移除该书，后续 helper 清理关联表。
        let sql = """
            UPDATE book
            SET updated_date = ?,
                is_deleted = 1
            WHERE id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍下书摘与标签的有效关系。
    nonisolated func softDeleteTagNotesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：删除指定书籍下全部书摘与标签关系。
        // 涉及表：tag_note；子查询读取 note。
        // 关键过滤：note.book_id = ? 且 tag_note.is_deleted = 0，覆盖该书所有书摘关系。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 3 步，避免书摘删除后残留 tag_note 关系。
        let sql = """
            UPDATE tag_note
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND note_id IN (
                  SELECT id
                  FROM note
                  WHERE book_id = ?
              )
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍下全部书摘。
    nonisolated func softDeleteNotesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部书摘。
        // 涉及表：note。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 4 步，使笔记列表观察流移除这些书摘。
        let sql = """
            UPDATE note
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍下书摘附图。
    nonisolated func softDeleteAttachImagesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部书摘附图。
        // 涉及表：attach_image；子查询读取 note。
        // 关键过滤：attach_image.note_id 属于该书 note，且 attach_image.is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 5 步，避免附图关系残留。
        let sql = """
            UPDATE attach_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND note_id IN (
                  SELECT id
                  FROM note
                  WHERE book_id = ?
              )
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍相关分类。
    nonisolated func softDeleteCategoriesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联分类。
        // 涉及表：category。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 6 步，清理相关内容分类入口。
        let sql = """
            UPDATE category
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍相关内容图片。
    nonisolated func softDeleteCategoryImagesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍相关内容的图片。
        // 涉及表：category_image；子查询读取 category_content。
        // 关键过滤：category_content.book_id = ? 且 category_image.is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 7 步，避免相关内容图片残留。
        let sql = """
            UPDATE category_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND category_content_id IN (
                  SELECT id
                  FROM category_content
                  WHERE book_id = ?
              )
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍相关内容。
    nonisolated func softDeleteCategoryContentsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部相关内容。
        // 涉及表：category_content。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 7.1 步。
        let sql = """
            UPDATE category_content
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍书评。
    nonisolated func softDeleteReviewsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部书评。
        // 涉及表：review。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 8 步。
        let sql = """
            UPDATE review
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍书评图片。
    nonisolated func softDeleteReviewImagesOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍书评关联图片。
        // 涉及表：review_image；子查询读取 review。
        // 关键过滤：review.book_id = ? 且 review_image.is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 9 步。
        let sql = """
            UPDATE review_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND review_id IN (
                  SELECT id
                  FROM review
                  WHERE book_id = ?
              )
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍章节。
    nonisolated func softDeleteChaptersOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍下全部章节。
        // 涉及表：chapter。
        // 关键过滤：book_id = ?、id != 0 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 10 步。
        let sql = """
            UPDATE chapter
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND id != 0
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍阅读状态历史。
    nonisolated func softDeleteReadStatusRecordsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍的阅读状态历史。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 12 步。
        let sql = """
            UPDATE book_read_status_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍阅读计时记录。
    nonisolated func softDeleteReadTimeRecordsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联的阅读计时记录。
        // 涉及表：read_time_record。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 13 步。
        let sql = """
            UPDATE read_time_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍排序设置。
    nonisolated func softDeleteSortRecordsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联排序设置。
        // 涉及表：sort。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 14 步。
        let sql = """
            UPDATE sort
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍打卡记录。
    nonisolated func softDeleteCheckInsOfBook(
        _ db: Database,
        bookID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联打卡记录。
        // 涉及表：check_in_record。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：复刻 Android 删除书籍第 15 步。
        let sql = """
            UPDATE check_in_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookID])
    }

    /// 软删除书籍与书单关系；这是删书级联清理，不是“加入书单”功能实现。
    nonisolated func softDeleteCollectionBooksOfBook(
        _ db: Database,
        bookID: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联的全部书单关系。
        // 涉及表：collection_book。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：Android CollectionBookDao.deleteByBookId 不更新时间戳，iOS 保持一致不改 updated_date。
        // 副作用用途：复刻 Android 删除书籍第 16 步，仅作为删除书籍级联清理。
        let sql = """
            UPDATE collection_book
            SET is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [bookID])
    }

    /// 软删除书籍阅读计划。
    nonisolated func softDeleteReadPlansOfBook(
        _ db: Database,
        bookID: Int64
    ) throws {
        // SQL 目的：软删除指定书籍关联阅读计划。
        // 涉及表：read_plan。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 时间字段：Android ReadPlanDao.deleteFromBook 不更新时间戳，iOS 保持一致不改 updated_date。
        // 副作用用途：复刻 Android 删除书籍第 17 步。
        let sql = """
            UPDATE read_plan
            SET is_deleted = 1
            WHERE book_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [bookID])
    }

    /// 读取指定书籍当前有效标签 ID 集合。
    nonisolated func fetchActiveTagIDs(ofBook bookID: Int64, db: Database) throws -> Set<Int64> {
        // SQL 目的：读取单本书现有有效标签关系，用于多本批量追加时避免重复插入。
        // 涉及表：tag_book。
        // 关键过滤：book_id = ? 且 is_deleted = 0。
        // 返回字段用途：仅返回 tag_id 集合；时间字段不参与本查询。
        let sql = """
            SELECT tag_id
            FROM tag_book
            WHERE book_id = ?
              AND is_deleted = 0
            """
        return Set(try Int64.fetchAll(db, sql: sql, arguments: [bookID]))
    }

    /// 插入一条有效的书籍标签关系。
    nonisolated func insertTagBook(
        bookID: Int64,
        tagID: Int64,
        createdAt: Int64,
        db: Database
    ) throws {
        var relation = TagBookRecord(
            id: nil,
            bookId: bookID,
            tagId: tagID,
            createdDate: createdAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try relation.insert(db)
    }

    /// 校验来源是否仍可用于书籍写入。
    nonisolated func isActiveSource(_ db: Database, sourceID: Int64) throws -> Bool {
        // SQL 目的：校验批量来源写入目标仍是有效来源。
        // 涉及表：source。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM source
            WHERE id = ?
              AND is_deleted = 0
        """
        return (try Int.fetchOne(db, sql: sql, arguments: [sourceID]) ?? 0) > 0
    }

    /// 校验书籍标签是否仍有效。
    nonisolated func isActiveBookTag(_ db: Database, tagID: Int64) throws -> Bool {
        // SQL 目的：校验待管理标签是否仍是有效书籍标签。
        // 涉及表：tag。
        // 关键过滤：id = ?、type = 2 且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM tag
            WHERE id = ?
              AND type = 2
              AND is_deleted = 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [tagID]) ?? 0) > 0
    }

    /// 校验分组名称是否重复。
    nonisolated func isDuplicateGroupName(
        _ db: Database,
        name: String,
        excludingGroupID: Int64?
    ) throws -> Bool {
        let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
        // SQL 目的：查询当前用户下是否存在同名有效分组。
        // 涉及表：`group`。
        // 关键过滤：user_id = ?、name = ?、is_deleted = 0；编辑场景额外排除当前 group id。
        // 返回字段用途：用于新增/重命名前置重名拦截；时间字段不参与本查询。
        let baseSQL = """
            SELECT COUNT(*)
            FROM `group`
            WHERE user_id = ?
              AND name = ?
              AND is_deleted = 0
            """
        let count: Int
        if let excludingGroupID {
            count = try Int.fetchOne(
                db,
                sql: baseSQL + "\n  AND id != ?",
                arguments: [ownerID, name, excludingGroupID]
            ) ?? 0
        } else {
            count = try Int.fetchOne(
                db,
                sql: baseSQL,
                arguments: [ownerID, name]
            ) ?? 0
        }
        return count > 0
    }

    /// 校验书籍标签名称是否重复。
    nonisolated func isDuplicateBookTagName(
        _ db: Database,
        name: String,
        excludingTagID: Int64
    ) throws -> Bool {
        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        // SQL 目的：查询同一用户下是否存在同名书籍标签。
        // 涉及表：tag。
        // 关键过滤：user_id = ?、name = ?、type = 2、is_deleted = 0，并排除当前 tag id。
        // 返回字段用途：用于重命名前置重名拦截；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM tag
            WHERE user_id = ?
              AND name = ?
              AND type = 2
              AND is_deleted = 0
              AND id != ?
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [ownerID, name, excludingTagID]) ?? 0) > 0
    }

    /// 校验来源名称是否重复。
    nonisolated func isDuplicateSourceName(
        _ db: Database,
        name: String,
        excludingSourceID: Int64
    ) throws -> Bool {
        // SQL 目的：查询是否存在同名有效来源。
        // 涉及表：source。
        // 关键过滤：name = ?、is_deleted = 0，并排除当前 source id。
        // 返回字段用途：用于来源重命名前置重名拦截；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM source
            WHERE name = ?
              AND is_deleted = 0
              AND id != ?
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [name, excludingSourceID]) ?? 0) > 0
    }

    /// 校验管理对象的新名称。
    nonisolated func validatedManagementName(
        _ name: String,
        target: String,
        maxLength: Int? = nil
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BookshelfBatchWriteError.invalidName(target) }
        if let maxLength, trimmed.count > maxLength {
            throw BookshelfBatchWriteError.invalidNameLength(target: target, maxLength: maxLength)
        }
        return trimmed
    }

    /// 软删除分组主记录。
    nonisolated func softDeleteGroup(
        _ db: Database,
        groupID: Int64
    ) throws {
        // SQL 目的：软删除有效分组主记录。
        // 涉及表：`group`。
        // 关键过滤：id = ? 且 is_deleted = 0，对齐 Android GroupDao.deleteGroup。
        // 时间字段：Android 删除分组不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：从默认书架分组入口移除该分组。
        let sql = """
            UPDATE `group`
            SET is_deleted = 1
            WHERE id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [groupID])
    }

    /// 软删除标签与书籍关系。
    nonisolated func softDeleteTagBookRelations(
        _ db: Database,
        tagID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定标签的全部书籍关系。
        // 涉及表：tag_book。
        // 关键过滤：tag_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：删除标签前清理书籍维度关系，避免孤立 tag_book。
        let sql = """
            UPDATE tag_book
            SET updated_date = ?,
                is_deleted = 1
            WHERE tag_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, tagID])
    }

    /// 软删除标签与书摘关系。
    nonisolated func softDeleteTagNoteRelations(
        _ db: Database,
        tagID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除指定标签的全部书摘关系。
        // 涉及表：tag_note。
        // 关键过滤：tag_id = ? 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：删除标签前清理书摘维度关系，避免孤立 tag_note。
        let sql = """
            UPDATE tag_note
            SET updated_date = ?,
                is_deleted = 1
            WHERE tag_id = ?
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, tagID])
    }

    /// 软删除书籍标签主记录。
    nonisolated func softDeleteBookTag(
        _ db: Database,
        tagID: Int64,
        updatedAt: Int64
    ) throws {
        // SQL 目的：软删除有效书籍标签主记录。
        // 涉及表：tag。
        // 关键过滤：id = ?、type = 2 且 is_deleted = 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值等待同步层处理。
        // 副作用用途：对齐 Android TagDao.deleteSync，使标签维度观察流移除该标签。
        let sql = """
            UPDATE tag
            SET updated_date = ?,
                is_deleted = 1
            WHERE id = ?
              AND type = 2
              AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, tagID])
    }

    /// 获取“未知来源”的有效 ID；若缺失且当前删除目标不是默认来源，则按 iOS seed 语义恢复默认来源。
    nonisolated func unknownSourceID(
        _ db: Database,
        deletingSourceID: Int64
    ) throws -> Int64 {
        if deletingSourceID == DatabaseOwnerResolver.defaultSourceID {
            throw BookshelfBatchWriteError.protectedDefaultSource
        }

        // SQL 目的：优先查找仍有效的“未知”来源，作为删除来源时的迁移目标。
        // 涉及表：source。
        // 关键过滤：name = '未知'、is_deleted = 0，并排除当前待删除 source id。
        // 返回字段用途：返回目标 source.id；时间字段不参与本查询。
        let lookupSQL = """
            SELECT id
            FROM source
            WHERE name = ?
              AND is_deleted = 0
              AND id != ?
            ORDER BY source_order ASC, id ASC
            LIMIT 1
            """
        if let sourceID = try Int64.fetchOne(
            db,
            sql: lookupSQL,
            arguments: [DatabaseOwnerResolver.defaultSourceName, deletingSourceID]
        ) {
            return sourceID
        }

        // SQL 目的：恢复 iOS 与 Android 对齐的默认未知来源种子。
        // 涉及表：source。
        // 关键过滤：使用固定 id = 1；INSERT OR IGNORE 避免已有记录时报错。
        // 时间字段：种子来源 created/updated/last_sync_date 均保持 0，与初始化种子一致。
        // 副作用用途：保证删除自定义来源时，总有可迁移的未知来源。
        let insertSQL = """
            INSERT OR IGNORE INTO source (id, name, source_order, bookshelf_order, is_hide, created_date, updated_date, last_sync_date, is_deleted)
            VALUES (?, ?, 0, -1, 0, 0, 0, 0, 0)
            """
        try db.execute(
            sql: insertSQL,
            arguments: [DatabaseOwnerResolver.defaultSourceID, DatabaseOwnerResolver.defaultSourceName]
        )

        // SQL 目的：确保默认未知来源处于有效状态并具备标准名称。
        // 涉及表：source。
        // 关键过滤：id = 1 且不是当前待删除来源。
        // 时间字段：保持 Android 删除来源迁移路径不更新时间戳的语义。
        // 副作用用途：恢复未知来源作为迁移目标。
        let restoreSQL = """
            UPDATE source
            SET name = ?,
                is_deleted = 0
            WHERE id = ?
              AND id != ?
            """
        try db.execute(
            sql: restoreSQL,
            arguments: [DatabaseOwnerResolver.defaultSourceName, DatabaseOwnerResolver.defaultSourceID, deletingSourceID]
        )

        guard try isActiveSource(db, sourceID: DatabaseOwnerResolver.defaultSourceID) else {
            throw BookshelfBatchWriteError.invalidSource
        }
        return DatabaseOwnerResolver.defaultSourceID
    }

    /// 将旧来源下的有效书籍迁移到新来源。
    nonisolated func migrateBooks(
        fromSourceID oldSourceID: Int64,
        toSourceID newSourceID: Int64,
        db: Database
    ) throws {
        // SQL 目的：删除来源前把有效书籍迁移到未知来源。
        // 涉及表：book。
        // 关键过滤：source_id = ?、is_deleted = 0、id != 0。
        // 时间字段：Android updateOldSourceToNew 不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：对齐 Android BookDao.updateOldSourceToNew，避免书籍引用已删除来源。
        let sql = """
            UPDATE book
            SET source_id = ?
            WHERE source_id = ?
              AND is_deleted = 0
              AND id != 0
            """
        try db.execute(sql: sql, arguments: [newSourceID, oldSourceID])
    }

    /// 软删除来源主记录。
    nonisolated func softDeleteSource(
        _ db: Database,
        sourceID: Int64
    ) throws {
        // SQL 目的：软删除有效来源主记录。
        // 涉及表：source。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 时间字段：Android SourceDao.delete 不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：删除来源维度入口；相关书籍已在前一步迁移到未知来源。
        let sql = """
            UPDATE source
            SET is_deleted = 1
            WHERE id = ?
              AND is_deleted = 0
        """
        try db.execute(sql: sql, arguments: [sourceID])
    }

    /// 读取指定作者名对应的首条作者资料 ID。
    nonisolated func fetchAuthorID(_ db: Database, name: String) throws -> Int64? {
        // SQL 目的：按作者名查找 Android 作者资料表中已编辑的作者记录。
        // 涉及表：author。
        // 关键过滤：name 精确匹配；Android AuthorDao.queryByName 不过滤 is_deleted，iOS 保持一致。
        // 返回字段用途：返回首条 author.id，供编辑或删除作者资料时定位主记录；时间字段不参与本查询。
        let sql = """
            SELECT id
            FROM author
            WHERE name = ?
            ORDER BY id ASC
            LIMIT 1
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [name])
    }

    /// 插入只有名称的作者资料，覆盖 Android 从未编辑作者进入编辑页后新增作者记录的场景。
    nonisolated func insertAuthorName(_ db: Database, name: String, now: Int64) throws {
        // SQL 目的：为原本只来自 book.author 字段的作者补建作者资料。
        // 涉及表：author。
        // 关键过滤：无过滤条件；Android AuthorDao.insertAuthor 使用 ABORT 策略但 author.name 无唯一约束。
        // 时间字段：created_date/updated_date 写入当前毫秒时间戳，last_sync_date 保持 0。
        // 副作用用途：让作者管理页后续可保存头像、简介等作者资料。
        let sql = """
            INSERT INTO author (
                douban_personage_id, photo_url, name, gender, birthdate, birthPlace, deathdate, bio,
                created_date, updated_date, last_sync_date, is_deleted
            )
            VALUES ('', '', ?, 0, '', '', '', '', ?, ?, 0, 0)
            """
        try db.execute(sql: sql, arguments: [name, now, now])
    }

    /// 更新作者资料名称。
    nonisolated func updateAuthorName(
        _ db: Database,
        authorID: Int64,
        name: String,
        updatedAt: Int64
    ) throws {
        // SQL 目的：保存作者编辑页中的作者名称修改。
        // 涉及表：author。
        // 关键过滤：id 精确匹配；Android AuthorDao.updateAuthor 不额外过滤 is_deleted，iOS 保持一致。
        // 时间字段：updated_date 写入当前毫秒时间戳；created_date/last_sync_date 保持原值。
        // 副作用用途：更新作者资料卡片标题，同时书籍 author 字段会在后续 SQL 中同步。
        let sql = """
            UPDATE author
            SET name = ?,
                updated_date = ?
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [name, updatedAt, authorID])
    }

    /// 硬删除作者资料主记录。
    nonisolated func hardDeleteAuthor(_ db: Database, authorID: Int64) throws {
        // SQL 目的：删除作者资料记录。
        // 涉及表：author。
        // 关键过滤：id 精确匹配；Android AuthorDao.deleteById 使用 DELETE FROM，不走软删除。
        // 副作用用途：删除作者维度下全部书籍后，移除对应作者资料。
        let sql = """
            DELETE FROM author
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [authorID])
    }

    /// 查询指定作者名下的有效书籍 ID。
    nonisolated func fetchBookIDsByAuthor(_ db: Database, name: String) throws -> [Int64] {
        // SQL 目的：删除作者时定位该作者下仍有效的书籍。
        // 涉及表：book。
        // 关键过滤：author 精确匹配、is_deleted = 0、id != 0，避免作者删除路径误处理占位书。
        // 返回字段用途：返回 book.id 交给 deleteBooks 做软删除级联；时间字段不参与本查询。
        let sql = """
            SELECT id
            FROM book
            WHERE author = ?
              AND is_deleted = 0
              AND id != 0
            """
        return try Int64.fetchAll(db, sql: sql, arguments: [name])
    }

    /// 批量更新书籍作者名。
    nonisolated func updateBooksAuthor(_ db: Database, oldName: String, newName: String) throws {
        // SQL 目的：作者重命名后同步更新存量书籍 author 字段。
        // 涉及表：book。
        // 关键过滤：author 精确匹配旧名称；Android BookDao.updateBooksAuthor 不过滤 is_deleted，iOS 保持一致。
        // 时间字段：Android 该写入不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：让作者聚合维度与二级列表立即归入新作者名。
        let sql = """
            UPDATE book
            SET author = ?
            WHERE author = ?
            """
        try db.execute(sql: sql, arguments: [newName, oldName])
    }

    /// 读取指定出版社名对应的首条出版社资料 ID。
    nonisolated func fetchPressID(_ db: Database, name: String) throws -> Int64? {
        // SQL 目的：按出版社名查找 Android 出版社资料表中已编辑的出版社记录。
        // 涉及表：press。
        // 关键过滤：name 精确匹配；Android PressDao.queryPressByName 不过滤 is_deleted，iOS 保持一致。
        // 返回字段用途：返回首条 press.id，供编辑或删除出版社资料时定位主记录；时间字段不参与本查询。
        let sql = """
            SELECT id
            FROM press
            WHERE name = ?
            ORDER BY id ASC
            LIMIT 1
            """
        return try Int64.fetchOne(db, sql: sql, arguments: [name])
    }

    /// 插入只有名称的出版社资料。
    nonisolated func insertPressName(_ db: Database, name: String, now: Int64) throws {
        // SQL 目的：为原本只来自 book.press 字段的出版社补建出版社资料。
        // 涉及表：press。
        // 关键过滤：无过滤条件；Android PressDao.insertPress 使用 ABORT 策略但 press.name 无唯一约束。
        // 时间字段：created_date/updated_date 写入当前毫秒时间戳，last_sync_date 保持 0。
        // 副作用用途：让出版社管理页后续可保存 logo、简介等资料。
        let sql = """
            INSERT INTO press (
                logo_url, name, introduction,
                created_date, updated_date, last_sync_date, is_deleted
            )
            VALUES ('', ?, '', ?, ?, 0, 0)
            """
        try db.execute(sql: sql, arguments: [name, now, now])
    }

    /// 更新出版社资料名称。
    nonisolated func updatePressName(
        _ db: Database,
        pressID: Int64,
        name: String,
        updatedAt: Int64
    ) throws {
        // SQL 目的：保存出版社编辑页中的出版社名称修改。
        // 涉及表：press。
        // 关键过滤：id 精确匹配；Android PressDao.updatePress 不额外过滤 is_deleted，iOS 保持一致。
        // 时间字段：updated_date 写入当前毫秒时间戳；created_date/last_sync_date 保持原值。
        // 副作用用途：更新出版社资料卡片标题，同时书籍 press 字段会在后续 SQL 中同步。
        let sql = """
            UPDATE press
            SET name = ?,
                updated_date = ?
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [name, updatedAt, pressID])
    }

    /// 硬删除出版社资料主记录。
    nonisolated func hardDeletePress(_ db: Database, pressID: Int64) throws {
        // SQL 目的：删除出版社资料记录。
        // 涉及表：press。
        // 关键过滤：id 精确匹配；Android PressDao.deleteById 使用 DELETE FROM，不走软删除。
        // 副作用用途：删除出版社维度下全部书籍后，移除对应出版社资料。
        let sql = """
            DELETE FROM press
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [pressID])
    }

    /// 查询指定出版社名下的有效书籍 ID。
    nonisolated func fetchBookIDsByPress(_ db: Database, name: String) throws -> [Int64] {
        // SQL 目的：删除出版社时定位该出版社下仍有效的书籍。
        // 涉及表：book。
        // 关键过滤：press 精确匹配、is_deleted = 0、id != 0，避免出版社删除路径误处理占位书。
        // 返回字段用途：返回 book.id 交给 deleteBooks 做软删除级联；时间字段不参与本查询。
        let sql = """
            SELECT id
            FROM book
            WHERE press = ?
              AND is_deleted = 0
              AND id != 0
            """
        return try Int64.fetchAll(db, sql: sql, arguments: [name])
    }

    /// 批量更新书籍出版社名。
    nonisolated func updateBooksPress(_ db: Database, oldName: String, newName: String) throws {
        // SQL 目的：出版社重命名后同步更新存量书籍 press 字段。
        // 涉及表：book。
        // 关键过滤：press 精确匹配旧名称；Android BookDao.updateBooksPress 不过滤 is_deleted，iOS 保持一致。
        // 时间字段：Android 该写入不更新 updated_date，iOS 保持一致不改时间字段。
        // 副作用用途：让出版社聚合维度与二级列表立即归入新出版社名。
        let sql = """
            UPDATE book
            SET press = ?
            WHERE press = ?
            """
        try db.execute(sql: sql, arguments: [newName, oldName])
    }

    /// 更新单本书籍的来源。
    nonisolated func updateBookSource(
        _ db: Database,
        bookID: Int64,
        sourceID: Int64
    ) throws {
        // SQL 目的：批量更新书籍来源，对齐 Android BookDao.updateBookSource 的窄写入语义。
        // 涉及表：book。
        // 关键过滤：仅 id = ?；不附加 is_deleted/id != 0 过滤，严格复刻 Android DAO。
        // 时间字段：不更新 updated_date / last_sync_date，避免制造 Android 当前不会产生的同步事件。
        // 副作用用途：更新 source_id，使来源维度观察流立即刷新。
        let sql = """
            UPDATE book
            SET source_id = ?
            WHERE id = ?
            """
        try db.execute(sql: sql, arguments: [sourceID, bookID])
    }

    /// 校验阅读状态是否仍可用于书籍写入。
    nonisolated func isActiveReadStatus(_ db: Database, statusID: Int64) throws -> Bool {
        // SQL 目的：校验批量阅读状态写入目标仍是有效阅读状态。
        // 涉及表：read_status。
        // 关键过滤：id = ? 且 is_deleted = 0。
        // 返回字段用途：返回计数是否大于 0；时间字段不参与本查询。
        let sql = """
            SELECT COUNT(*)
            FROM read_status
            WHERE id = ?
              AND is_deleted = 0
            """
        return (try Int.fetchOne(db, sql: sql, arguments: [statusID]) ?? 0) > 0
    }

    /// 过滤并保留正数 ID 的首次出现顺序。
    nonisolated func normalizedPositiveIDs(_ ids: [Int64]) -> [Int64] {
        ids.reduce(into: [Int64]()) { result, id in
            guard id > 0, !result.contains(id) else { return }
            result.append(id)
        }
    }

    /// 过滤并保留非负 ID 的首次出现顺序。
    nonisolated func normalizedNonNegativeIDs(_ ids: [Int64]) -> [Int64] {
        ids.reduce(into: [Int64]()) { result, id in
            guard id >= 0, !result.contains(id) else { return }
            result.append(id)
        }
    }

    /// 返回当前毫秒时间戳。
    nonisolated func timestampMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 查询首页书架所有浏览维度共用的只读快照。
    /// - Throws: 数据库查询失败时抛出错误。
}
