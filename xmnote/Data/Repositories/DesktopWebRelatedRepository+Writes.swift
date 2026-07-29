/**
 * [INPUT]: 依赖 DesktopWebRelatedRepository 的数据库、时钟、上传票据回调与相关内容投影
 * [OUTPUT]: 对外提供 Android RelatedService 的类别、排序、相关内容 CRUD 与批量写入语义
 * [POS]: Data 层网页相关内容写扩展；按 Android 原始事务边界保留可观察副作用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated extension DesktopWebRelatedRepository {
    /// 创建全局或有效书籍内类别。
    func createCategory(
        bookID: Int64,
        input: DesktopWebRelatedCategoryCreateInput
    ) async throws -> DesktopWebRelatedCategorySnapshot {
        let title = Self.kotlinTrimmed(input.title)
        try Self.validateCategoryTitle(title)
        let targetBookID = try Self.resolveScopeBookID(
            scope: input.scope,
            fallbackBookID: bookID,
            currentBookID: bookID
        )
        if targetBookID > 0 {
            try await ensureActiveBookExists(id: targetBookID)
        }
        let order = try await database.dbPool.read { db -> Int64 in
            // SQL 目的：执行 Android 创建类别的全局+书内同名判重。
            // 涉及表：category。
            // 关键过滤：(book_id=目标 OR book_id=0)、title 精确相等、is_deleted=0。
            // 时间字段：不参与判重。
            // 返回字段：COUNT(*)。
            let duplicateCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM category
                    WHERE (book_id = ? OR book_id = 0)
                      AND title = ? AND is_deleted = 0
                    """,
                arguments: [targetBookID, title]
            ) ?? 0
            guard duplicateCount == 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("类别已存在")
            }
            if let requested = input.order {
                return max(requested, 0)
            }
            let whereClause = targetBookID == 0
                ? "is_deleted = 0"
                : "(book_id = 0 OR book_id = ?) AND is_deleted = 0"
            let arguments: StatementArguments = targetBookID == 0 ? [] : [targetBookID]
            // NOTE(ANDROID-WEB-047): 创建 global 类别时最大 order 也跨全部书籍计算。
            // SQL 目的：计算 Android 新类别默认 order。
            // 涉及表：category。
            // 关键过滤：global 目标只过滤删除态；书内目标包含全局与目标书籍类别。
            // 时间字段：不参与计算。
            // 返回字段：MAX(order)。
            let maximum = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(`order`) FROM category WHERE \(whereClause)",
                arguments: arguments
            )
            return max(maximum.map { $0 &+ 1 } ?? 0, 0)
        }
        let now = currentTimeMillis()
        let recordTemplate = CategoryRecord(
            bookId: targetBookID,
            title: title,
            order: order,
            isHide: 0,
            createdDate: now,
            updatedDate: now,
            lastSyncDate: 0,
            isDeleted: 0
        )
        let id = try await database.dbPool.write { db -> Int64 in
            var record = recordTemplate
            try record.insert(db)
            guard let id = record.id else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("类别创建失败")
            }
            return id
        }
        return try await category(id: id)
    }

    /// 局部更新类别；scope 变化只改 category.book_id，不迁移已有内容。
    func updateCategory(
        id: Int64,
        input: DesktopWebRelatedCategoryUpdateInput
    ) async throws -> DesktopWebRelatedCategorySnapshot {
        var record = try await activeCategory(id: id)
        let hasTitleChange = input.title != nil
        let hasOrderChange = input.order != nil
        let hasScopeChange = input.scope != nil
        guard hasTitleChange || hasOrderChange || hasScopeChange else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("缺少可更新字段")
        }
        let targetBookID = hasScopeChange
            ? try Self.resolveScopeBookID(
                scope: input.scope,
                fallbackBookID: record.bookId,
                currentBookID: input.bookID
            )
            : record.bookId
        let currentTitle = record.title ?? ""
        let targetTitle = input.title.map(Self.kotlinTrimmed) ?? currentTitle
        if targetBookID != record.bookId, Self.defaultCategoryTitles.contains(currentTitle) {
            throw DesktopWebCatalogRepositoryError.invalidArgument("系统默认类别不支持修改作用域")
        }
        if input.title != nil {
            try Self.validateCategoryTitle(targetTitle)
            if targetTitle != currentTitle, Self.defaultCategoryTitles.contains(currentTitle) {
                throw DesktopWebCatalogRepositoryError.invalidArgument("系统默认类别不支持重命名")
            }
        }
        if targetBookID > 0 {
            try await ensureActiveBookExists(id: targetBookID)
            if targetBookID != record.bookId {
                let outsideCount = try await database.dbPool.read { db in
                    try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM category_content
                            WHERE category_id = ? AND book_id != ? AND is_deleted = 0
                            """,
                        arguments: [id, targetBookID]
                    ) ?? 0
                }
                guard outsideCount == 0 else {
                    throw DesktopWebCatalogRepositoryError.invalidArgument(
                        "类别包含其他书籍的内容，不能切换到目标书籍"
                    )
                }
            }
        }
        record.title = targetTitle
        record.bookId = targetBookID
        if let order = input.order {
            record.order = max(order, 0)
        }
        record.updatedDate = currentTimeMillis()
        let updatedRecord = record
        try await database.dbPool.write { db in
            try updatedRecord.update(db)
        }
        return try await category(id: id)
    }

    /// 更新类别隐藏状态；默认类别也允许隐藏。
    func updateCategoryVisibility(id: Int64, isHidden: Bool) async throws -> DesktopWebRelatedCategorySnapshot {
        var record = try await activeCategory(id: id)
        record.isHide = isHidden ? 1 : 0
        record.updatedDate = currentTimeMillis()
        let updatedRecord = record
        try await database.dbPool.write { db in
            try updatedRecord.update(db)
        }
        return try await category(id: id)
    }

    /// 删除类别；系统默认类别只物理删除内容，自定义类别按同名跨作用域逐个物理删除。
    func deleteCategory(id: Int64) async throws {
        let category = try await activeCategory(id: id)
        let title = category.title ?? ""
        // NOTE(ANDROID-WEB-049): 删除按同名跨书籍扩散、物理删除且无共同事务，也不先清理 category_image。
        if Self.defaultCategoryTitles.contains(title) {
            try await physicallyDeleteCategoryContents(categoryID: id)
            return
        }
        let ids = try await database.dbPool.read { db in
            // SQL 目的：查找所有作用域中与目标同名的有效类别。
            // 涉及表：category。
            // 关键过滤：title 精确相等、is_deleted=0；不限制 book_id。
            // 时间字段：不参与查询。
            // 返回字段：类别主键。
            try Int64.fetchAll(
                db,
                sql: "SELECT id FROM category WHERE title = ? AND is_deleted = 0",
                arguments: [title]
            )
        }
        for categoryID in ids {
            try await physicallyDeleteCategoryContents(categoryID: categoryID)
            try await database.dbPool.write { db in
                // SQL 目的：物理删除单个同名类别。
                // 涉及表：category。
                // 关键过滤：主键精确命中；无软删除 tombstone。
                // 时间字段：无时间戳更新。
                // 副作用：每个类别独立提交，后续失败不会回滚先前类别。
                try db.execute(sql: "DELETE FROM category WHERE id = ?", arguments: [categoryID])
            }
        }
    }

    /// 使用单一时间戳和事务重排指定书籍可见的全部全局与书内类别。
    func reorderCategories(bookID: Int64, ids: [Int64]) async throws {
        let categories = try await database.dbPool.read { db in
            // SQL 目的：读取参与书内管理页重排的全局与书内类别。
            // 涉及表：category。
            // 关键过滤：(book_id=0 OR book_id=?)、is_deleted=0。
            // 时间字段：不参与读取。
            // 返回字段：category 完整记录，按旧 order 升序。
            try CategoryRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM category
                    WHERE (book_id = 0 OR book_id = ?) AND is_deleted = 0
                    ORDER BY `order` ASC
                    """,
                arguments: [bookID]
            )
        }
        guard !categories.isEmpty else { return }
        let normalizedIDs = Self.distinct(ids).filter { $0 > 0 }
        guard normalizedIDs.count == categories.count else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别排序参数不完整")
        }
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.compactMap { record in
            record.id.map { ($0, record) }
        })
        guard normalizedIDs.allSatisfy({ categoryMap[$0] != nil }) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别排序参数不合法")
        }
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            for (index, categoryID) in normalizedIDs.enumerated() {
                guard var record = categoryMap[categoryID] else { continue }
                record.order = Int64(index)
                record.updatedDate = now
                try record.update(db)
            }
        }
    }

    /// 更新相关内容排序；只接受 create_time 与 asc/desc。
    func updateSortRule(
        bookID: Int64,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebRelatedSortRuleSnapshot {
        let normalizedSortBy = sortBy.lowercased()
        let normalizedSortOrder = sortOrder.lowercased()
        guard normalizedSortBy == "create_time" else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("相关内容排序仅支持 create_time")
        }
        guard normalizedSortOrder == "asc" || normalizedSortOrder == "desc" else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("排序方向仅支持 asc 或 desc")
        }
        let order = normalizedSortOrder == "desc" ? Self.descCreated : Self.ascCreated
        try await database.dbPool.write { db in
            // SQL 目的：判断有效排序记录是否已经存在。
            // 涉及表：sort。
            // 关键过滤：book_id、type=3、is_deleted=0。
            // 时间字段：不参与计数。
            // 返回字段：COUNT(*)。
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sort WHERE book_id = ? AND type = ? AND is_deleted = 0",
                arguments: [bookID, Self.relatedContentType]
            ) ?? 0
            if count == 0 {
                var record = SortRecord(
                    bookId: bookID,
                    type: Self.relatedContentType,
                    order: order,
                    createdDate: currentTimeMillis(),
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try record.insert(db)
            } else {
                // SQL 目的：更新指定书籍全部同类型排序记录，包括意外重复行和 tombstone。
                // 涉及表：sort。
                // 关键过滤：book_id、type=3；故意不追加 is_deleted。
                // 时间字段：updated_date 使用请求处理时 Android 毫秒值。
                // 副作用：写入 order 与 updated_date。
                try db.execute(
                    sql: "UPDATE sort SET updated_date = ?, `order` = ? WHERE book_id = ? AND type = ?",
                    arguments: [currentTimeMillis(), order, bookID, Self.relatedContentType]
                )
            }
        }
        return DesktopWebRelatedSortRuleSnapshot(sortBy: "create_time", sortOrder: normalizedSortOrder)
    }

    /// 创建相关内容、图片并在同一数据库事务中提交上传票据。
    func createRelatedNote(input: DesktopWebRelatedNoteCreateInput) async throws -> DesktopWebRelatedNoteSnapshot {
        try await ensureActiveBookExists(id: input.bookID)
        let category = try await activeCategory(id: input.categoryID)
        guard category.bookId == 0 || category.bookId == input.bookID else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别不属于当前书籍")
        }
        let contentBookID = input.contentBookID ?? 0
        if contentBookID > 0 {
            try await ensureContentBookExists(id: contentBookID)
        }
        let title = Self.kotlinTrimmed(input.title ?? "")
        let content = DesktopWebRichHTMLCanonicalizer.canonicalize(Self.kotlinTrimmed(input.content ?? ""))
        let url = Self.kotlinTrimmed(input.url ?? "")
        let imageURLs = input.imageURLs ?? []
        try Self.validateRelatedNotePayload(
            title: title,
            content: content,
            url: url,
            imageURLs: imageURLs,
            contentBookID: contentBookID
        )
        let now = currentTimeMillis()
        let createdTime = input.createdTime.flatMap { $0 > 0 ? $0 : nil } ?? now
        let noteTemplate = CategoryContentRecord(
            categoryId: input.categoryID,
            bookId: input.bookID,
            title: title,
            content: content,
            contentBookId: contentBookID,
            url: url,
            createdDate: createdTime,
            updatedDate: now,
            lastSyncDate: 0,
            isDeleted: 0
        )
        let id = try await database.dbPool.write { db -> Int64 in
            var note = noteTemplate
            try note.insert(db)
            guard let id = note.id else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("笔记创建失败")
            }
            try replaceImages(db, noteID: id, imageURLs: imageURLs)
            try commitUploadedTickets(input.uploadedTicketIDs, imageURLs)
            return id
        }
        return try await relatedNote(id: id)
    }

    /// 局部更新相关内容；每次都重新验证当前类别存在与作用域。
    func updateRelatedNote(
        id: Int64,
        input: DesktopWebRelatedNoteUpdateInput
    ) async throws -> DesktopWebRelatedNoteSnapshot {
        var note = try await activeRelatedNote(id: id)
        let targetCategoryID = input.categoryID ?? note.categoryId
        let category = try await activeCategory(id: targetCategoryID)
        guard category.bookId == 0 || category.bookId == note.bookId else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别不属于当前书籍")
        }
        let targetContentBookID = input.contentBookID.map { max($0, 0) } ?? note.contentBookId
        if targetContentBookID > 0 {
            try await ensureContentBookExists(id: targetContentBookID)
        }
        let title = input.title.map(Self.kotlinTrimmed) ?? (note.title ?? "")
        let content = input.content.map { DesktopWebRichHTMLCanonicalizer.canonicalize(Self.kotlinTrimmed($0)) }
            ?? (note.content ?? "")
        let url = input.url.map(Self.kotlinTrimmed) ?? (note.url ?? "")
        let imageURLs = if let requested = input.imageURLs {
            requested
        } else {
            try await activeImageURLs(noteID: id)
        }
        try Self.validateRelatedNotePayload(
            title: title,
            content: content,
            url: url,
            imageURLs: imageURLs,
            contentBookID: targetContentBookID
        )
        note.categoryId = targetCategoryID
        note.title = title
        note.content = content
        note.url = url
        note.contentBookId = targetContentBookID
        if let createdTime = input.createdTime, createdTime > 0 {
            note.createdDate = createdTime
        }
        note.updatedDate = currentTimeMillis()
        let updatedNote = note
        try await database.dbPool.write { db in
            try updatedNote.update(db)
            if input.imageURLs != nil {
                try replaceImages(db, noteID: id, imageURLs: imageURLs)
            }
            try commitUploadedTickets(input.uploadedTicketIDs, imageURLs)
        }
        return try await relatedNote(id: id)
    }

    /// 在同一事务内软删除单条内容和全部有效图片。
    func deleteRelatedNote(id: Int64) async throws {
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：软删除单条有效相关内容。
            // 涉及表：category_content。
            // 关键过滤：id、is_deleted=0。
            // 时间字段：updated_date 使用本次调用毫秒值。
            // 副作用：is_deleted 置 1。
            try db.execute(
                sql: """
                    UPDATE category_content
                    SET updated_date = ?, is_deleted = 1
                    WHERE id = ? AND is_deleted = 0
                    """,
                arguments: [now, id]
            )
            guard db.changesCount > 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("笔记不存在: \(id)")
            }
            try db.execute(
                sql: """
                    UPDATE category_image
                    SET updated_date = ?, is_deleted = 1
                    WHERE category_content_id = ? AND is_deleted = 0
                    """,
                arguments: [now, id]
            )
        }
    }

    /// 在同一事务内批量软删除命中的有效内容及其有效图片。
    func batchDeleteRelatedNotes(ids: [Int64]) async throws {
        let normalizedIDs = Self.distinct(ids).filter { $0 > 0 }
        guard !normalizedIDs.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("缺少有效笔记编号")
        }
        let matchedIDs = try await activeRelatedNotes(ids: normalizedIDs).compactMap(\.id)
        guard !matchedIDs.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("未找到可删除笔记")
        }
        let placeholders = Array(repeating: "?", count: matchedIDs.count).joined(separator: ",")
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：批量软删除请求中仍有效的相关内容。
            // 涉及表：category_content。
            // 关键过滤：id IN、is_deleted=0。
            // 时间字段：所有命中行共用一次 updated_date。
            // 副作用：is_deleted 置 1。
            try db.execute(
                sql: """
                    UPDATE category_content
                    SET updated_date = ?, is_deleted = 1
                    WHERE id IN (\(placeholders)) AND is_deleted = 0
                    """,
                arguments: StatementArguments([now.databaseValue] + matchedIDs.map(\.databaseValue))
            )
            // SQL 目的：软删除全部请求 ID 对应图片。
            // 涉及表：category_image。
            // 关键过滤：category_content_id IN 命中内容且图片仍有效。
            // 时间字段：内容和图片共用同一毫秒值。
            // 副作用：is_deleted 置 1。
            try db.execute(
                sql: """
                    UPDATE category_image
                    SET updated_date = ?, is_deleted = 1
                    WHERE category_content_id IN (\(placeholders)) AND is_deleted = 0
                    """,
                arguments: StatementArguments([now.databaseValue] + matchedIDs.map(\.databaseValue))
            )
        }
    }

    /// 批量移动到类别；完整预检后使用单条 SQL 原子更新。
    func batchUpdateRelatedNotesCategory(ids: [Int64], categoryID: Int64) async throws {
        let normalizedIDs = Self.distinct(ids).filter { $0 > 0 }
        guard !normalizedIDs.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("缺少有效笔记编号")
        }
        guard categoryID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("目标类别无效")
        }
        let targetCategory = try await activeCategory(id: categoryID)
        let notes = try await activeRelatedNotes(ids: normalizedIDs)
        let noteMap = Dictionary(uniqueKeysWithValues: notes.compactMap { note in
            note.id.map { ($0, note) }
        })
        guard noteMap.count == normalizedIDs.count else {
            let missing = normalizedIDs.filter { noteMap[$0] == nil }
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "部分笔记不存在: \(missing.map(String.init).joined(separator: ","))"
            )
        }
        if targetCategory.bookId != 0, notes.contains(where: { $0.bookId != targetCategory.bookId }) {
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别不属于部分笔记所在书籍")
        }
        let placeholders = Array(repeating: "?", count: normalizedIDs.count).joined(separator: ",")
        let affected = try await database.dbPool.write { db -> Int in
            // SQL 目的：原子更新全部目标相关内容的类别。
            // 涉及表：category_content。
            // 关键过滤：id IN、is_deleted=0；前置已验证目标类别作用域。
            // 时间字段：所有命中行共用一次 updated_date。
            // 副作用：更新 category_id。
            try db.execute(
                sql: """
                    UPDATE category_content
                    SET category_id = ?, updated_date = ?
                    WHERE id IN (\(placeholders)) AND is_deleted = 0
                    """,
                arguments: StatementArguments(
                    [categoryID.databaseValue, currentTimeMillis().databaseValue]
                        + normalizedIDs.map(\.databaseValue)
                )
            )
            return db.changesCount
        }
        guard affected == normalizedIDs.count else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分笔记更新失败")
        }
    }
}

nonisolated extension DesktopWebRelatedRepository {
    func category(id: Int64) async throws -> DesktopWebRelatedCategorySnapshot {
        try await database.dbPool.read { db in
            // SQL 目的：读取写后有效类别并生成完整响应。
            // 涉及表：category，计数由 categorySnapshot 查询 category_content。
            // 关键过滤：id、is_deleted=0。
            // 时间字段：原样返回。
            // 返回字段：category 完整记录。
            guard let record = try CategoryRecord.fetchOne(
                db,
                sql: "SELECT * FROM category WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            ) else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("类别创建失败")
            }
            return try categorySnapshot(db, category: record)
        }
    }

    func physicallyDeleteCategoryContents(categoryID: Int64) async throws {
        try await database.dbPool.write { db in
            // SQL 目的：物理删除类别下全部内容，完全复刻 Android deleteNotesOfCategory。
            // 涉及表：category_content；category_image 外键可能使本步失败。
            // 关键过滤：category_id；不区分有效行和 tombstone。
            // 时间字段：不写删除时间。
            // 副作用：永久移除内容且不创建同步 tombstone。
            try db.execute(sql: "DELETE FROM category_content WHERE category_id = ?", arguments: [categoryID])
        }
    }

    func ensureContentBookExists(id: Int64) async throws {
        let exists = try await database.dbPool.read { db in
            // SQL 目的：校验关联书籍主键存在且有效。
            // 涉及表：book。
            // 关键过滤：id、id!=0、is_deleted=0。
            // 时间字段：不参与查询。
            // 返回字段：EXISTS 计数。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book WHERE id = ? AND id != 0 AND is_deleted = 0",
                arguments: [id]
            ) ?? 0
        } > 0
        guard exists else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("关联书籍不存在: \(id)")
        }
    }

    func activeImageURLs(noteID: Int64) async throws -> [String] {
        try await database.dbPool.read { db in
            // SQL 目的：更新请求省略 imageUrls 时读取当前有效图片 URL。
            // 涉及表：category_image。
            // 关键过滤：category_content_id、is_deleted=0。
            // 时间字段：不参与查询。
            // 返回字段：image，按 order 升序。
            try String.fetchAll(
                db,
                sql: """
                    SELECT image FROM category_image
                    WHERE is_deleted = 0 AND category_content_id = ?
                    ORDER BY `order` ASC
                    """,
                arguments: [noteID]
            )
        }
    }

    func activeRelatedNotes(ids: [Int64]) async throws -> [CategoryContentRecord] {
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try await database.dbPool.read { db in
            // SQL 目的：批量移动前读取全部有效目标内容。
            // 涉及表：category_content。
            // 关键过滤：id IN、is_deleted=0。
            // 时间字段：原样读取用于保留未改字段。
            // 返回字段：category_content 完整记录。
            try CategoryContentRecord.fetchAll(
                db,
                sql: "SELECT * FROM category_content WHERE id IN (\(placeholders)) AND is_deleted = 0",
                arguments: StatementArguments(ids)
            )
        }
    }

    func replaceImages(_ db: Database, noteID: Int64, imageURLs: [String]) throws {
        // SQL 目的：先软删除该内容全部有效图片。
        // 涉及表：category_image。
        // 关键过滤：category_content_id 且 is_deleted=0。
        // 时间字段：updated_date 使用独立时钟值。
        // 副作用：is_deleted 置 1。
        try db.execute(
            sql: """
                UPDATE category_image
                SET updated_date = ?, is_deleted = 1
                WHERE category_content_id = ? AND is_deleted = 0
                """,
            arguments: [currentTimeMillis(), noteID]
        )
        let now = currentTimeMillis()
        for (index, rawURL) in imageURLs.map(Self.kotlinTrimmed).filter({ !$0.isEmpty }).enumerated() {
            var image = CategoryImageRecord(
                categoryContentId: noteID,
                image: rawURL,
                order: Int64(index),
                createdDate: now,
                updatedDate: now,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try image.insert(db)
        }
    }

    static func validateCategoryTitle(_ title: String) throws {
        guard !isKotlinBlank(title) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别名称不能为空")
        }
        guard title.utf16.count <= 100 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别名称过长")
        }
    }

    static func validateRelatedNotePayload(
        title: String,
        content: String,
        url: String,
        imageURLs: [String],
        contentBookID: Int64
    ) throws {
        let hasPayload = !isKotlinBlank(title)
            || !isKotlinBlank(content)
            || !isKotlinBlank(url)
            || imageURLs.contains { !isKotlinBlank($0) }
            || contentBookID > 0
        guard hasPayload else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("笔记内容不能为空")
        }
    }

    static func resolveScopeBookID(
        scope: String?,
        fallbackBookID: Int64,
        currentBookID: Int64?
    ) throws -> Int64 {
        switch try normalizeScope(scope) {
        case "global":
            return 0
        case "book":
            if let currentBookID, currentBookID > 0 { return currentBookID }
            if fallbackBookID > 0 { return fallbackBookID }
            throw DesktopWebCatalogRepositoryError.invalidArgument("切换到当前书籍作用域时缺少 bookId")
        default:
            return fallbackBookID
        }
    }

    static func normalizeScope(_ scope: String?) throws -> String {
        switch scope.map(kotlinTrimmed)?.lowercased() {
        case "global":
            return "global"
        case "book", nil, "":
            return "book"
        default:
            throw DesktopWebCatalogRepositoryError.invalidArgument("类别作用域不合法")
        }
    }
}
