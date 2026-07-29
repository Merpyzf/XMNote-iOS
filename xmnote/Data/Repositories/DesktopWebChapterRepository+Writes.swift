/**
 * [INPUT]: 依赖 DesktopWebChapterRepository 的章节树查询、AppDatabase/GRDB 写连接与 Android 分类错误
 * [OUTPUT]: 对外提供 ChapterController 10 条本地章节写接口的数据副作用
 * [POS]: Data 层网页章节写入扩展；保留 Android 事务边界、软删除、层级与路径刷新语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated extension DesktopWebChapterRepository {
    /// 创建单个章节；书籍和父章节校验后按同父最大顺序追加。
    func createChapter(
        bookID: Int64,
        title rawTitle: String,
        parentID rawParentID: Int64?
    ) async throws -> DesktopWebChapterResultSnapshot {
        try await requireActiveBook(bookID)
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节标题不能为空")
        }
        let parentID = rawParentID ?? 0
        let records = try await validateCreateParent(bookID: bookID, parentID: parentID)
        let level = Self.ancestorPath(records: records, chapterID: parentID).count + 1
        try Self.requireDepth(level)
        let path = Self.ancestorPath(records: records, chapterID: parentID).map(\.title) + [title]
        let now = currentTimeMillis()
        let order = try await nextOrder(bookID: bookID, parentID: parentID)
        let id = try await insertChapter(
            bookID: bookID,
            parentID: parentID,
            title: title,
            order: order,
            level: level,
            pathTitles: path,
            createdTime: now
        )
        return DesktopWebChapterResultSnapshot(
            id: id,
            title: title,
            parentID: parentID,
            order: Int(order)
        )
    }

    /// 校验所属书籍有效后，在一个事务中更新标题并刷新全树冗余层级与路径。
    func updateChapter(id: Int64, title rawTitle: String) async throws -> DesktopWebChapterResultSnapshot {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节标题不能为空")
        }
        guard let record = try await chapter(id: id) else {
            throw DesktopWebCatalogRepositoryError.notFound("章节不存在: \(id)")
        }
        try await requireActiveBook(record.bookId)
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：更新有效章节标题；Android DAO SQL 本身不检查 is_deleted 或所属书籍状态。
            // 涉及表：chapter。
            // 关键过滤：仅 id；调用前 findById 已确认章节当前有效。
            // 时间字段：updated_date 写入请求开始时的毫秒值。
            // 副作用用途：章节标题更新的第一阶段提交。
            try db.execute(
                sql: "UPDATE chapter SET title = ?, updated_date = ? WHERE id = ?",
                arguments: [title, now, id]
            )
            try refreshMetadata(db, bookID: record.bookId, now: now)
        }
        return DesktopWebChapterResultSnapshot(
            id: id,
            title: title,
            parentID: record.parentId,
            order: Int(Int32(truncatingIfNeeded: record.chapterOrder))
        )
    }

    /// 更新星标并返回当前树路径；该接口是少数会再次校验有效书籍的章节写路径。
    func updateChapterStarred(id: Int64, isStarred: Bool) async throws -> DesktopWebChapterSnapshot {
        guard id > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节编号必须为正数")
        }
        guard let record = try await chapter(id: id) else {
            throw DesktopWebCatalogRepositoryError.notFound("章节不存在: \(id)")
        }
        try await requireActiveBook(record.bookId)
        try await requireActiveBook(record.bookId)
        let now = currentTimeMillis()
        let changed = try await database.dbPool.write { db in
            // SQL 目的：复刻 WebChapterDao.updateStarred。
            // 涉及表：chapter。
            // 关键过滤：id 精确匹配、id != 0、is_deleted = 0。
            // 时间字段：updated_date 写入当前毫秒值。
            // 副作用用途：星标状态与分组最近更新时间。
            try db.execute(
                sql: """
                    UPDATE chapter
                    SET is_starred = ?, updated_date = ?
                    WHERE id = ? AND id != 0 AND is_deleted = 0
                    """,
                arguments: [isStarred ? 1 : 0, now, id]
            )
            return db.changesCount
        }
        guard changed > 0 else {
            throw DesktopWebCatalogRepositoryError.notFound("章节不存在: \(id)")
        }
        let records = try await allChapters(bookID: record.bookId)
        guard let updated = records.first(where: { $0.id == id }) else {
            throw DesktopWebCatalogRepositoryError.notFound("章节不存在: \(id)")
        }
        let parentTitle = records.first(where: { $0.id == updated.parentId })?.title
        return DesktopWebChapterSnapshot(
            id: id,
            title: updated.title.trimmingCharacters(in: .whitespacesAndNewlines),
            parentTitle: Self.nonBlankTrimmed(parentTitle),
            parentID: updated.parentId,
            level: Self.ancestorPath(records: records, chapterID: id).count,
            pathTitles: Self.ancestorPath(records: records, chapterID: id).map(\.title),
            isStarred: updated.isStarred != 0
        )
    }

    /// 事务内解除全部后代的书摘关联并软删除整棵子树。
    func deleteChapter(id: Int64) async throws {
        guard let record = try await chapter(id: id) else {
            throw DesktopWebCatalogRepositoryError.notFound("章节不存在: \(id)")
        }
        let records = try await allChapters(bookID: record.bookId)
        let ids = Self.collectDescendantIDs(records: records, rootIDs: [id])
        try await deleteChapterIDs(ids, now: currentTimeMillis())
    }

    /// 批量校验章节及所属书籍后，原子解除书摘关系并软删除全部子树。
    func batchDeleteChapters(ids: [Int64]) async throws {
        let normalized = try normalizeChapterIDs(ids, emptyMessage: "删除列表不能为空")
        let existing = try await requiredChapters(ids: normalized)
        let bookIDs = Self.distinct(existing.map(\.bookId))
        for bookID in bookIDs {
            try await requireActiveBook(bookID)
        }
        var allRecords: [ChapterRecord] = []
        for bookID in bookIDs {
            allRecords.append(contentsOf: try await allChapters(bookID: bookID))
        }
        let deleteIDs = Self.collectDescendantIDs(records: allRecords, rootIDs: normalized)
        try await deleteChapterIDs(deleteIDs, now: currentTimeMillis())
    }

    /// 逐项重排书籍顶层章节；不要求请求覆盖全部同级章节。
    func reorderParentChapters(bookID: Int64, ids: [Int64]) async throws {
        try await requireActiveBook(bookID)
        let normalized = try normalizeChapterIDs(ids, emptyMessage: "排序列表不能为空")
        let records = try await requiredChapters(ids: normalized)
        let crossBook = records.filter { $0.bookId != bookID }.compactMap(\.id)
        guard crossBook.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "章节不属于当前书籍: \(Self.join(crossBook))"
            )
        }
        let children = records.filter { $0.parentId != 0 }.compactMap(\.id)
        guard children.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "只能排序顶级章节: \(Self.join(children))"
            )
        }
        try await updateOrders(ids: normalized, now: currentTimeMillis())
    }

    /// 校验父章节所属书籍有效后，原子重排指定父章节的直接子章节。
    func reorderChildChapters(parentID: Int64, ids: [Int64]) async throws {
        guard parentID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("父章节编号必须为正数")
        }
        guard let parent = try await chapter(id: parentID) else {
            throw DesktopWebCatalogRepositoryError.notFound("父章节不存在: \(parentID)")
        }
        try await requireActiveBook(parent.bookId)
        let normalized = try normalizeChapterIDs(ids, emptyMessage: "排序列表不能为空")
        let records = try await requiredChapters(ids: normalized)
        let crossBook = records.filter { $0.bookId != parent.bookId }.compactMap(\.id)
        guard crossBook.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "章节不属于目标父章节所在书籍: \(Self.join(crossBook))"
            )
        }
        let notChildren = records.filter { $0.parentId != parentID }.compactMap(\.id)
        guard notChildren.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "章节不属于目标父章节: \(Self.join(notChildren))"
            )
        }
        try await updateOrders(ids: normalized, now: currentTimeMillis())
    }

    /// 按请求首次出现顺序把章节追加到父节点末尾，并刷新目标书籍整棵树的冗余字段。
    func moveToParent(chapterIDs rawIDs: [Int64], parentID: Int64) async throws {
        let ids = Self.distinct(rawIDs).filter { $0 > 0 }
        guard !ids.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节列表不能为空")
        }
        guard let parent = try await chapter(id: parentID) else {
            throw DesktopWebCatalogRepositoryError.notFound("父章节不存在: \(parentID)")
        }
        try await requireActiveBook(parent.bookId)
        guard !ids.contains(parentID) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("不能移动章节到自身")
        }
        let moving = try await requiredChapters(ids: ids)
        let crossBook = moving.filter { $0.bookId != parent.bookId }.compactMap(\.id)
        guard crossBook.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "章节不属于目标父章节所在书籍: \(Self.join(crossBook))"
            )
        }
        let descendants = try await collectGlobalDescendantIDs(parentIDs: ids)
        guard !descendants.contains(parentID) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("不能移动章节到自身子章节下")
        }
        let allRecords = try await allChapters(bookID: parent.bookId)
        let parentDepth = Self.ancestorPath(records: allRecords, chapterID: parentID).count
        let height = Self.subtreeHeight(records: allRecords, rootIDs: ids)
        guard parentDepth + height <= Self.maxDepth else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "章节层级不能超过 \(Self.maxDepth) 层"
            )
        }
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            var order = try maxOrder(db, bookID: parent.bookId, parentID: parentID)
            for id in ids {
                order &+= 1
                try updateParentAndOrder(db, id: id, parentID: parentID, order: order, now: now)
            }
            try refreshMetadata(db, bookID: parent.bookId, now: now)
        }
    }

    /// 把同书子章节按请求顺序追加到顶层；不校验该书籍当前是否有效。
    func moveOut(chapterIDs: [Int64]) async throws {
        let ids = try normalizeChapterIDs(chapterIDs, emptyMessage: "章节列表不能为空")
        let moving = try await requiredChapters(ids: ids)
        let bookIDs = Self.distinct(moving.map(\.bookId))
        guard bookIDs.count == 1, let bookID = bookIDs.first else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节不属于同一本书")
        }
        try await requireActiveBook(bookID)
        let topLevel = moving.filter { $0.parentId == 0 }.compactMap(\.id)
        guard topLevel.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "只能移出子章节: \(Self.join(topLevel))"
            )
        }
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            var order = try maxOrder(db, bookID: bookID, parentID: 0)
            for id in ids {
                order &+= 1
                try updateParentAndOrder(db, id: id, parentID: 0, order: order, now: now)
            }
            try refreshMetadata(db, bookID: bookID, now: now)
        }
    }

    /// 在一个事务中创建同级章节，跳过 trim 后为空的标题。
    func batchCreateChapters(
        bookID: Int64,
        titles: [String],
        parentID rawParentID: Int64?
    ) async throws -> [DesktopWebChapterResultSnapshot] {
        try await requireActiveBook(bookID)
        guard !titles.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("标题列表不能为空")
        }
        let parentID = rawParentID ?? 0
        let records = try await validateCreateParent(bookID: bookID, parentID: parentID)
        let level = Self.ancestorPath(records: records, chapterID: parentID).count + 1
        try Self.requireDepth(level)
        let parentPath = Self.ancestorPath(records: records, chapterID: parentID).map(\.title)
        let now = currentTimeMillis()
        return try await database.dbPool.write { db in
            var order = try maxOrder(db, bookID: bookID, parentID: parentID)
            var created: [DesktopWebChapterResultSnapshot] = []
            for rawTitle in titles {
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                order &+= 1
                let id = try insertChapter(
                    db,
                    bookID: bookID,
                    parentID: parentID,
                    title: title,
                    order: order,
                    level: level,
                    pathTitles: parentPath + [title],
                    createdTime: now
                )
                created.append(
                    DesktopWebChapterResultSnapshot(
                        id: id,
                        title: title,
                        parentID: parentID,
                        order: Int(order)
                    )
                )
            }
            return created
        }
    }
}

private nonisolated extension DesktopWebChapterRepository {
    func validateCreateParent(bookID: Int64, parentID: Int64) async throws -> [ChapterRecord] {
        if parentID == 0 { return try await allChapters(bookID: bookID) }
        guard parentID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("父章节编号必须为正数")
        }
        guard let parent = try await chapter(id: parentID) else {
            throw DesktopWebCatalogRepositoryError.notFound("父章节不存在: \(parentID)")
        }
        guard parent.bookId == bookID else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("父章节不属于当前书籍")
        }
        let records = try await allChapters(bookID: bookID)
        guard Self.ancestorPath(records: records, chapterID: parentID).count < Self.maxDepth else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "章节层级不能超过 \(Self.maxDepth) 层"
            )
        }
        return records
    }

    func requiredChapters(ids: [Int64]) async throws -> [ChapterRecord] {
        let records = try await chapters(ids: ids)
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.id.map { ($0, record) }
        })
        let missing = ids.filter { byID[$0] == nil }
        guard missing.isEmpty else {
            throw DesktopWebCatalogRepositoryError.notFound(
                "部分章节不存在: \(Self.join(missing))"
            )
        }
        return ids.compactMap { byID[$0] }
    }

    func normalizeChapterIDs(_ ids: [Int64], emptyMessage: String) throws -> [Int64] {
        guard !ids.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(emptyMessage)
        }
        guard ids.allSatisfy({ $0 > 0 }) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节编号必须为正数")
        }
        guard Set(ids).count == ids.count else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节列表不能包含重复项")
        }
        return ids
    }

    func nextOrder(bookID: Int64, parentID: Int64) async throws -> Int32 {
        var order = try await maxOrder(bookID: bookID, parentID: parentID)
        order &+= 1
        return order
    }

    func maxOrder(bookID: Int64, parentID: Int64) async throws -> Int32 {
        try await database.dbPool.read { db in
            try maxOrder(db, bookID: bookID, parentID: parentID)
        }
    }

    func maxOrder(_ db: Database, bookID: Int64, parentID: Int64) throws -> Int32 {
        // SQL 目的：读取同书同父有效章节的最大 chapter_order。
        // 涉及表：chapter；关键过滤：book_id、parent_id、is_deleted=0。
        // 返回字段用途：新增或移动章节的尾部顺序；按 Android Int 截断。
        let value = try Int64.fetchOne(
            db,
            sql: """
                SELECT IFNULL(MAX(chapter_order), 0)
                FROM chapter
                WHERE book_id = ? AND parent_id = ? AND is_deleted = 0
                """,
            arguments: [bookID, parentID]
        ) ?? 0
        return Int32(truncatingIfNeeded: value)
    }

    func insertChapter(
        bookID: Int64,
        parentID: Int64,
        title: String,
        order: Int32,
        level: Int,
        pathTitles: [String],
        createdTime: Int64
    ) async throws -> Int64 {
        try await database.dbPool.write { db in
            try insertChapter(
                db,
                bookID: bookID,
                parentID: parentID,
                title: title,
                order: order,
                level: level,
                pathTitles: pathTitles,
                createdTime: createdTime
            )
        }
    }

    func insertChapter(
        _ db: Database,
        bookID: Int64,
        parentID: Int64,
        title: String,
        order: Int32,
        level: Int,
        pathTitles: [String],
        createdTime: Int64
    ) throws -> Int64 {
        var record = ChapterRecord(
            bookId: bookID,
            parentId: parentID,
            title: title,
            chapterOrder: Int64(order),
            chapterLevel: Int64(level),
            sourceUid: "",
            sourceAnchor: "",
            sourcePath: pathTitles.joined(separator: Self.pathSeparator),
            createdDate: createdTime
        )
        try record.insert(db)
        return record.id ?? db.lastInsertedRowID
    }

    func deleteChapterIDs(_ ids: Set<Int64>, now: Int64) async throws {
        guard !ids.isEmpty else { return }
        let values = Array(ids)
        try await database.dbPool.write { db in
            let placeholders = values.map { _ in "?" }.joined(separator: ",")
            // SQL 目的：事务内把待删章节关联的所有书摘改为未分配章节。
            // 涉及表：note。
            // 关键过滤：chapter_id 位于根章节及其全部有效后代；不区分 note 是否软删除。
            // 时间字段：updated_date 写入同一请求毫秒值。
            // 副作用用途：避免书摘继续指向已删除章节。
            try db.execute(
                sql: "UPDATE note SET updated_date = ?, chapter_id = 0 WHERE chapter_id IN (\(placeholders))",
                arguments: StatementArguments([now] + values)
            )
            // SQL 目的：事务内软删除请求章节及其有效后代。
            // 涉及表：chapter。
            // 关键过滤：id 位于删除集合；Android 不追加 is_deleted 过滤。
            // 时间字段：updated_date 与书摘解除关联使用同一毫秒值。
            // 副作用用途：保留备份兼容的软删除语义。
            try db.execute(
                sql: "UPDATE chapter SET is_deleted = 1, updated_date = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([now] + values)
            )
        }
    }

    func updateOrders(ids: [Int64], now: Int64) async throws {
        try await database.dbPool.write { db in
            for (index, id) in ids.enumerated() {
                // SQL 目的：按请求数组下标重写单个章节顺序。
                // 涉及表：chapter。
                // 关键过滤：仅 id；前置校验已确认章节有效和父级归属。
                // 时间字段：updated_date 使用同一请求毫秒值。
                // 副作用用途：顶层或直接子章节局部重排。
                try db.execute(
                    sql: "UPDATE chapter SET chapter_order = ?, updated_date = ? WHERE id = ?",
                    arguments: [index, now, id]
                )
            }
        }
    }

    func updateParentAndOrder(
        id: Int64,
        parentID: Int64,
        order: Int32,
        now: Int64
    ) async throws {
        try await database.dbPool.write { db in
            try updateParentAndOrder(db, id: id, parentID: parentID, order: order, now: now)
        }
    }

    func updateParentAndOrder(
        _ db: Database,
        id: Int64,
        parentID: Int64,
        order: Int32,
        now: Int64
    ) throws {
        // SQL 目的：移动单个章节并写入目标同级尾部顺序。
        // 涉及表：chapter；关键过滤：仅 id，前置校验已确认有效章节。
        // 时间字段：updated_date 使用移动请求毫秒值；副作用由调用方事务统一提交。
        try db.execute(
            sql: """
                UPDATE chapter
                SET parent_id = ?, chapter_order = ?, updated_date = ?
                WHERE id = ?
                """,
            arguments: [parentID, Int64(order), now, id]
        )
    }

    func refreshMetadata(bookID: Int64, now: Int64) async throws {
        try await database.dbPool.write { db in
            try refreshMetadata(db, bookID: bookID, now: now)
        }
    }

    func refreshMetadata(_ db: Database, bookID: Int64, now: Int64) throws {
        // SQL 目的：在当前事务快照中读取书籍全部有效章节以重建层级和路径。
        // 涉及表：chapter；关键过滤：id!=0、book_id、is_deleted=0。
        let records = try ChapterRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM chapter
                WHERE id != 0 AND book_id = ? AND is_deleted = 0
                ORDER BY parent_id ASC, chapter_order ASC
                """,
            arguments: [bookID]
        )
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.id.map { ($0, record) }
        })
        let children = Dictionary(grouping: records, by: \.parentId)
        let roots = records.filter { $0.parentId == 0 || byID[$0.parentId] == nil }
            .sorted(by: Self.chapterOrder)
        var metadata: [(id: Int64, level: Int, path: String)] = []
        func visit(_ record: ChapterRecord, level: Int, titles: [String], visited: Set<Int64>) {
            guard let id = record.id else { return }
            metadata.append((id, level, titles.joined(separator: Self.pathSeparator)))
            guard !visited.contains(id) else { return }
            for child in (children[id] ?? []).sorted(by: Self.chapterOrder) {
                visit(
                    child,
                    level: level + 1,
                    titles: titles + [child.title],
                    visited: visited.union([id])
                )
            }
        }
        roots.forEach { visit($0, level: 1, titles: [$0.title], visited: []) }
        for item in metadata {
            // SQL 目的：刷新章节树的冗余层级与标题路径。
            // 涉及表：chapter；关键过滤：当前树遍历可达节点 id。
            // 时间字段：updated_date 使用原始写请求毫秒值；循环节点保持 Android 的不可达行为。
            try db.execute(
                sql: """
                    UPDATE chapter
                    SET chapter_level = ?, source_path = ?, updated_date = ?
                    WHERE id = ?
                    """,
                arguments: [item.level, item.path, now, item.id]
            )
        }
    }

    func collectGlobalDescendantIDs(parentIDs: [Int64]) async throws -> Set<Int64> {
        var result: Set<Int64> = []
        var current = Self.distinct(parentIDs)
        while !current.isEmpty {
            let currentParentIDs = current
            let next = try await database.dbPool.read { db in
                // SQL 目的：按父 ID 批量发现有效直接子章节，递归检测移动目标是否位于自身子树。
                // 涉及表：chapter。
                // 关键过滤：parent_id 位于当前层且 is_deleted = 0；故意不按 book_id 过滤。
                // 时间字段：无。
                // 返回字段用途：move-to-parent 循环关系防护。
                try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM chapter
                        WHERE parent_id IN (\(currentParentIDs.map { _ in "?" }.joined(separator: ",")))
                          AND is_deleted = 0
                        """,
                    arguments: StatementArguments(currentParentIDs)
                )
            }
            current = next.filter { result.insert($0).inserted }
        }
        return result
    }

    static func subtreeHeight(records: [ChapterRecord], rootIDs: [Int64]) -> Int {
        let children = Dictionary(grouping: records, by: \.parentId)
        func height(_ id: Int64, visited: Set<Int64>) -> Int {
            guard !visited.contains(id) else { return 0 }
            let items = children[id] ?? []
            guard !items.isEmpty else { return 1 }
            return 1 + (items.compactMap(\.id).map { height($0, visited: visited.union([id])) }.max() ?? 0)
        }
        return rootIDs.map { height($0, visited: []) }.max() ?? 0
    }

    static func requireDepth(_ depth: Int) throws {
        guard (1...maxDepth).contains(depth) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "章节层级不能超过 \(maxDepth) 层"
            )
        }
    }

    static func join(_ ids: [Int64]) -> String {
        ids.map(String.init).joined(separator: ",")
    }
}
