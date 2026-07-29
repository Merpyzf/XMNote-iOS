/**
 * [INPUT]: 依赖 DesktopWebBookRepository、V44 书籍/章节/状态/年度书单及关系表和可注入毫秒时钟
 * [OUTPUT]: 提供 Android BookService 单书创建、局部更新及其状态/目录/关系副作用
 * [POS]: Data 层网页书籍录入扩展；Package 只经能力端口传递无数据库输入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated extension DesktopWebBookRepository {
    /// 按 Android Web 的预校验与单一 Room 事务创建书籍；取消不会中断已进入的同步 GRDB 事务。
    func createBook(_ input: DesktopWebBookCreateInput) async throws -> DesktopWebBookSnapshot {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("书名不能为空")
        }
        let author = input.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let translator = input.translator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let press = input.press?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isbn = input.isbn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pubDate = input.pubDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await requireUniqueBook(
            excluding: nil,
            name: name,
            author: author,
            translator: translator,
            press: press,
            isbn: isbn,
            pubDate: pubDate
        )
        try await validateOptionalBookGroup(input.groupID)
        let sourceID = input.sourceID ?? 1
        try await requireActiveBookSource(sourceID)
        let normalizedTagIDs = try await normalizeActiveBookTagIDs(input.tagIDs) ?? []

        let now = currentTimeMillis()
        let changedTime = input.readStatusChangedTime.flatMap { $0 > 0 ? $0 : nil } ?? now
        let shouldCreateDeletedBook = input.isDeleted == true
        if shouldCreateDeletedBook && input.creationMode != "related_hidden" {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "仅 creationMode=related_hidden 时允许 isDeleted=true"
            )
        }
        let groupID = input.groupID ?? 0
        let newOrder = try await newBookOrder(groupID: groupID)
        let type = Int64(input.type ?? Int(BookEntryBookType.paper.rawValue))
        let positionUnit = try resolvePositionUnit(bookType: type, requested: input.positionUnit)
        let trimmedRawName = input.rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = trimmedRawName?.isEmpty == false ? trimmedRawName! : name

        let prototype = BookRecord(
            id: nil,
            userId: 1,
            doubanId: Int64(input.doubanID ?? 0),
            name: name,
            rawName: rawName,
            cover: input.cover ?? "",
            author: author,
            authorIntro: input.authorIntro ?? "",
            translator: translator,
            isbn: isbn,
            pubDate: pubDate,
            press: press,
            summary: input.summary ?? "",
            readPosition: input.readPosition ?? 0,
            totalPosition: Int64(max(0, input.totalPosition ?? 0)),
            totalPagination: Int64(max(0, input.totalPagination ?? 0)),
            type: type,
            currentPositionUnit: positionUnit,
            positionUnit: positionUnit,
            sourceId: sourceID,
            purchaseDate: input.purchaseDate ?? 0,
            price: Double(input.price ?? 0),
            bookOrder: newOrder,
            pinned: 0,
            pinOrder: 0,
            readStatusId: Int64(input.readStatus),
            readStatusChangedDate: changedTime,
            score: Int64(input.score ?? 0),
            catalog: input.catalog ?? "",
            bookMarkModifiedTime: input.readPosition == nil ? 0 : now,
            wordCount: input.wordCount,
            createdDate: now,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: shouldCreateDeletedBook ? 1 : 0
        )

        let stored = try await database.dbPool.write { db -> BookRecord in
            var book = prototype
            try book.insert(db)
            guard let bookID = book.id else {
                throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("新书保存后未生成主键")
            }

            if let catalog = input.catalog, !catalog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try insertCatalogChapters(db, bookID: bookID, catalog: catalog)
                // SQL 目的：创建时目录已经解析为 chapter，随后清空 book.catalog。
                // 涉及表：book。
                // 关键过滤：新生成 book id；不改变 updated_date。
                // 副作用用途：对齐 App addBook 与 Web createBook 的目录迁移语义。
                try db.execute(sql: "UPDATE book SET catalog = '' WHERE id = ?", arguments: [bookID])
                book.catalog = ""
            }

            if !shouldCreateDeletedBook {
                try syncReadStatusSideEffectsInTransaction(
                    db,
                    book: &book,
                    changedTime: changedTime
                )
            }

            for tagID in normalizedTagIDs {
                var relation = TagBookRecord(
                    id: nil,
                    bookId: bookID,
                    tagId: tagID,
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try relation.insert(db)
            }
            if groupID > 0 {
                var relation = GroupBookRecord(
                    id: nil,
                    groupId: groupID,
                    bookId: bookID,
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try relation.insert(db)
            }
            return book
        }
        guard let snapshot = try await projection.projectBookSnapshots([stored]).first else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(stored.id ?? 0)")
        }
        return snapshot
    }

    /// 按 Android Web 非事务步骤局部更新书籍；任何后续失败都保留此前已提交副作用。
    func updateBook(
        id: Int64,
        input: DesktopWebBookUpdateInput
    ) async throws -> DesktopWebBookSnapshot {
        var book = try await activeBookForMutation(id: id)
        try await validateOptionalBookGroup(input.groupID)
        if let sourceID = input.sourceID {
            try await requireActiveBookSource(sourceID)
        }
        let normalizedTagIDs = try await normalizeActiveBookTagIDs(input.tagIDs)
        let nextName = input.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? book.name
        let nextAuthor = input.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? book.author
        let nextTranslator = input.translator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? book.translator
        let nextPress = input.press?.trimmingCharacters(in: .whitespacesAndNewlines) ?? book.press
        let nextISBN = input.isbn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? book.isbn
        let nextPubDate = input.pubDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? book.pubDate
        try await requireUniqueBook(
            excluding: id,
            name: nextName,
            author: nextAuthor,
            translator: nextTranslator,
            press: nextPress,
            isbn: nextISBN,
            pubDate: nextPubDate
        )

        let now = currentTimeMillis()
        let oldReadStatus = book.readStatusId
        let oldReadStatusChangedDate = book.readStatusChangedDate
        if input.name != nil { book.name = nextName }
        if let rawName = input.rawName { book.rawName = rawName.trimmingCharacters(in: .whitespacesAndNewlines) }
        if input.author != nil { book.author = nextAuthor }
        if let cover = input.cover { book.cover = cover }
        if let authorIntro = input.authorIntro { book.authorIntro = authorIntro }
        if input.translator != nil { book.translator = nextTranslator }
        if let summary = input.summary { book.summary = summary }
        if input.isbn != nil { book.isbn = nextISBN }
        if input.press != nil { book.press = nextPress }
        if input.pubDate != nil { book.pubDate = nextPubDate }
        if let doubanID = input.doubanID { book.doubanId = Int64(doubanID) }
        if let readStatus = input.readStatus { book.readStatusId = Int64(readStatus) }
        if let score = input.score { book.score = Int64(score) }

        let targetType = Int64(input.type ?? Int(book.type))
        let shouldResolvePositionUnit = input.positionUnit != nil || input.type != nil
        let resolvedPositionUnit = shouldResolvePositionUnit
            ? try resolvePositionUnit(bookType: targetType, requested: input.positionUnit)
            : nil
        if let type = input.type { book.type = Int64(type) }
        if let sourceID = input.sourceID { book.sourceId = sourceID }
        if let purchaseDate = input.purchaseDate { book.purchaseDate = purchaseDate }
        if let price = input.price { book.price = Double(price) }
        if input.clearWordCount == true {
            book.wordCount = nil
        } else if let wordCount = input.wordCount {
            book.wordCount = wordCount
        }
        if let catalog = input.catalog { book.catalog = catalog }
        if let resolvedPositionUnit {
            book.positionUnit = resolvedPositionUnit
            book.currentPositionUnit = resolvedPositionUnit
        }
        if let totalPagination = input.totalPagination {
            book.totalPagination = Int64(max(0, totalPagination))
        }
        if let totalPosition = input.totalPosition {
            book.totalPosition = Int64(max(0, totalPosition))
        }
        if let readPosition = input.readPosition {
            let effectiveUnit = resolvedPositionUnit ?? book.positionUnit
            book.positionUnit = effectiveUnit
            book.currentPositionUnit = effectiveUnit
            book.readPosition = readPosition
            book.bookMarkModifiedTime = now
        }
        if let changedTime = input.readStatusChangedTime {
            book.readStatusChangedDate = changedTime
        }
        if let readStatus = input.readStatus, Int64(readStatus) != oldReadStatus {
            book.readStatusChangedDate = input.readStatusChangedTime ?? now
        }

        book.updatedDate = now
        let statusChanged = book.readStatusId != oldReadStatus
            || book.readStatusChangedDate != oldReadStatusChangedDate
        let preparedBook = book
        book = try await database.dbPool.write { db in
            var transactionBook = preparedBook
            try updateWebBook(db, book: transactionBook)
            if statusChanged {
                try syncReadStatusSideEffectsInTransaction(
                    db,
                    book: &transactionBook,
                    changedTime: transactionBook.readStatusChangedDate
                )
            }
            if let normalizedTagIDs {
                try replaceBookTags(
                    db,
                    bookID: id,
                    tagIDs: normalizedTagIDs,
                    createdAt: now
                )
            }
            try normalizeBookGroupRelations(
                db,
                bookID: id,
                requestedGroupID: input.groupID,
                now: now
            )
            return transactionBook
        }

        let updated = try await bookIncludingDeleted(id: id)
        guard let snapshot = try await projection.projectBookSnapshots([updated]).first else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(id)")
        }
        return snapshot
    }
}

nonisolated extension DesktopWebBookRepository {
    /// 查询同名有效候选并按六字段精确判重；不隔离 owner。
    func requireUniqueBook(
        excluding id: Int64?,
        name: String,
        author: String,
        translator: String,
        press: String,
        isbn: String,
        pubDate: String
    ) async throws {
        let count = try await database.dbPool.read { db in
            // SQL 目的：复制 ensureBookNotDuplicated 的六字段精确判重。
            // 涉及表：book。
            // 关键过滤：有效、非占位、排除当前 id，并精确比较 name/author/translator/press/isbn/pub_date。
            // 时间字段：无；不按 owner 过滤。
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM book
                    WHERE is_deleted = 0
                      AND id != 0
                      AND id != ?
                      AND name = ?
                      AND author = ?
                      AND translator = ?
                      AND press = ?
                      AND isbn = ?
                      AND pub_date = ?
                    """,
                arguments: [id ?? 0, name, author, translator, press, isbn, pubDate]
            ) ?? 0
        }
        guard count == 0 else {
            throw DesktopWebCatalogRepositoryError.duplicate("书籍已存在")
        }
    }

    /// 校验可选分组参数；0 表示默认书架，负数、缺失或已删除分组均拒绝。
    func validateOptionalBookGroup(_ groupID: Int64?) async throws {
        guard let groupID, groupID != 0 else { return }
        guard groupID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("分组不存在")
        }
        let exists = try await database.dbPool.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM `group` WHERE id = ? AND is_deleted = 0",
                arguments: [groupID]
            ) ?? 0) > 0
        }
        guard exists else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("分组不存在")
        }
    }

    /// 校验来源主记录有效；书籍创建的默认来源 1 也经过同一约束。
    func requireActiveBookSource(_ sourceID: Int64) async throws {
        guard sourceID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("来源不存在")
        }
        let exists = try await database.dbPool.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM source WHERE id = ? AND is_deleted = 0",
                arguments: [sourceID]
            ) ?? 0) > 0
        }
        guard exists else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("来源不存在")
        }
    }

    /// 保序去重并校验请求中的全部标签主记录有效。
    func normalizeActiveBookTagIDs(_ tagIDs: [Int64]?) async throws -> [Int64]? {
        guard let tagIDs else { return nil }
        var seen: Set<Int64> = []
        let normalized = tagIDs.filter { seen.insert($0).inserted }
        guard !normalized.contains(where: { $0 <= 0 }),
              try await activeTagsExist(normalized) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分标签不存在")
        }
        return normalized
    }

    /// 校验书籍类型与进度单位组合，并补齐 Android 默认单位。
    func resolvePositionUnit(bookType: Int64, requested: Int?) throws -> Int64 {
        let unit = Int64(requested ?? (bookType == 1 ? 1 : 2))
        let isValid = switch bookType {
        case 0: unit == 2
        case 1: unit == 0 || unit == 1
        default: false
        }
        guard isValid else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("当前书籍类型不支持所选进度类型")
        }
        return unit
    }

    /// 按新增位置偏好读取顶层或目标分组边界，并使用 Kotlin Int 溢出规则扩展一位。
    func newBookOrder(groupID: Int64) async throws -> Int64 {
        let placeAtEnd = shouldPlaceNewBookAtEnd()
        if groupID == 0 {
            let boundary = try await database.dbPool.read { db -> Int64 in
                let aggregate = placeAtEnd ? "MAX" : "MIN"
                // SQL 目的：读取未分组有效书籍和有效分组共享的顶层排序边界。
                // 涉及表：book、group_book、group。
                // 关键过滤：book 有效非占位且无有效关系；group 有效；不按 owner 过滤。
                // 返回字段用途：按设置向尾部 +1 或头部 -1。
                let book = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT \(aggregate)(book_order)
                        FROM book
                        WHERE is_deleted = 0 AND id != 0
                          AND id NOT IN (
                              SELECT gb.book_id
                              FROM group_book gb
                              INNER JOIN `group` g ON g.id = gb.group_id
                              WHERE gb.is_deleted = 0 AND g.is_deleted = 0
                          )
                        """
                ) ?? 0
                let group = try Int64.fetchOne(
                    db,
                    sql: "SELECT \(aggregate)(group_order) FROM `group` WHERE is_deleted = 0"
                ) ?? 0
                return placeAtEnd ? max(book, group) : min(book, group)
            }
            let delta: Int32 = placeAtEnd ? 1 : -1
            return Int64(Int32(truncatingIfNeeded: boundary) &+ delta)
        }
        let boundary = try await database.dbPool.read { db in
            // SQL 目的：读取指定 groupId 下、以首个有效关系归属该组的有效书籍排序边界。
            // 涉及表：group_book JOIN book；不连接 group 主表。
            // 关键过滤：关系和书籍有效、书籍非占位、关系为该书最早有效关系。
            // 返回字段用途：按新增位置偏好 +1/-1；空组回退 0。
            let aggregate = placeAtEnd ? "MAX" : "MIN"
            return try Int64.fetchOne(
                db,
                sql: """
                    SELECT \(aggregate)(book.book_order)
                    FROM group_book
                    JOIN book ON group_book.book_id = book.id
                    WHERE group_book.group_id = ?
                      AND group_book.is_deleted = 0
                      AND book.is_deleted = 0
                      AND book.id != 0
                      AND group_book.id = (
                          SELECT gb2.id FROM group_book gb2
                          WHERE gb2.book_id = book.id AND gb2.is_deleted = 0
                          ORDER BY gb2.created_date ASC, gb2.id ASC
                          LIMIT 1
                      )
                    """,
                arguments: [groupID]
            ) ?? 0
        }
        let delta: Int32 = placeAtEnd ? 1 : -1
        return Int64(Int32(truncatingIfNeeded: boundary) &+ delta)
    }

    /// 在创建事务中解析最多五级目录并插入 chapter；任何格式或写入失败回滚整本书。
    func insertCatalogChapters(_ db: Database, bookID: Int64, catalog: String) throws {
        let lines = try catalogChapterLines(catalog)
        var parentIDs: [Int: Int64] = [:]
        var paths: [Int: [String]] = [:]
        for line in lines {
            let parentID: Int64
            let parentPath: [String]
            if line.depth == 0 {
                parentID = 0
                parentPath = []
            } else {
                guard let resolvedParent = parentIDs[line.depth - 1],
                      let resolvedPath = paths[line.depth - 1] else {
                    throw DesktopWebCatalogRepositoryError.invalidArgument(
                        "目录层级缺少上级章节：\(line.title)"
                    )
                }
                parentID = resolvedParent
                parentPath = resolvedPath
            }
            let path = parentPath + [line.title]
            // SQL 目的：按书籍、父章节和标题复用同一有效章节。
            // 涉及表：chapter。
            // 关键过滤：book_id、parent_id、title 精确匹配且 is_deleted = 0；无确定排序。
            // 返回字段用途：复用 id 或决定插入新章节。
            let existingID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM chapter
                    WHERE book_id = ? AND parent_id = ? AND title = ? AND is_deleted = 0
                    LIMIT 1
                    """,
                arguments: [bookID, parentID, line.title]
            )
            let chapterID: Int64
            if let existingID {
                chapterID = existingID
            } else {
                // SQL 目的：读取同父章节当前最大 chapter_order。
                // 涉及表：chapter。
                // 关键过滤：book_id、parent_id 精确匹配且有效。
                // 返回字段用途：以 Kotlin Int max + 1 生成兄弟排序值。
                let maximum = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT MAX(chapter_order) FROM chapter
                        WHERE book_id = ? AND parent_id = ? AND is_deleted = 0
                        """,
                    arguments: [bookID, parentID]
                ) ?? 0
                let chapterNow = currentTimeMillis()
                var chapter = ChapterRecord(
                    id: nil,
                    bookId: bookID,
                    parentId: parentID,
                    title: line.title,
                    chapterOrder: Int64(Int32(truncatingIfNeeded: maximum) &+ 1),
                    chapterLevel: Int64(line.depth + 1),
                    sourcePath: path.joined(separator: " / "),
                    createdDate: chapterNow,
                    updatedDate: chapterNow,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try chapter.insert(db)
                chapterID = chapter.id ?? db.lastInsertedRowID
            }
            parentIDs[line.depth] = chapterID
            paths[line.depth] = path
            parentIDs = parentIDs.filter { $0.key <= line.depth }
            paths = paths.filter { $0.key <= line.depth }
        }
    }

    /// 将目录文本转换为 Android 的缩进深度和标题序列。
    func catalogChapterLines(_ catalog: String) throws -> [(title: String, depth: Int)] {
        var result: [(String, Int)] = []
        var existingDepths: Set<Int> = []
        for rawLine in catalog.components(separatedBy: "\n") {
            let normalized = trimCatalogLine(rawLine)
            if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let depth = catalogDepth(normalized)
            guard depth < 5 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("章节层级不能超过 5 层")
            }
            let title = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { continue }
            if depth > 0 && !existingDepths.contains(depth - 1) {
                throw DesktopWebCatalogRepositoryError.invalidArgument("目录层级缺少上级章节：\(title)")
            }
            result.append((title, depth))
            existingDepths.insert(depth)
            existingDepths = existingDepths.filter { $0 <= depth }
        }
        return result
    }

    /// 复制 Kotlin normalizeCatalogLine：替换 NBSP、移除 ZWJ，并只裁掉尾部空白。
    func trimCatalogLine(_ line: String) -> String {
        var characters = Array(line.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200D}", with: ""))
        while characters.last?.isWhitespace == true {
            characters.removeLast()
        }
        return String(characters)
    }

    /// 按 tab、两个半角空格或两个全角空格累计目录深度，遇到其他字符立即停止。
    func catalogDepth(_ line: String) -> Int {
        let characters = Array(line)
        var index = 0
        var depth = 0
        while index < characters.count {
            if characters[index] == "\t" {
                depth += 1
                index += 1
            } else if index + 1 < characters.count,
                      characters[index] == " ", characters[index + 1] == " " {
                depth += 1
                index += 2
            } else if index + 1 < characters.count,
                      characters[index] == "　", characters[index + 1] == "　" {
                depth += 1
                index += 2
            } else {
                break
            }
        }
        return depth
    }

    /// 创建事务内同步状态历史、读完进度和年度书单，沿用同一连接保证整体回滚。
    func syncReadStatusSideEffectsInTransaction(
        _ db: Database,
        book: inout BookRecord,
        changedTime: Int64
    ) throws {
        let effectiveChangedTime = changedTime > 0 ? changedTime : currentTimeMillis()
        let now = currentTimeMillis()
        try upsertReadStatus(db, book: book, changedTime: effectiveChangedTime, now: now)
        var needsUpdate = false
        if book.readStatusChangedDate != effectiveChangedTime {
            book.readStatusChangedDate = effectiveChangedTime
            needsUpdate = true
        }
        if book.readStatusId == 3 {
            needsUpdate = markWebBookFinished(&book) || needsUpdate
        }
        if needsUpdate {
            book.updatedDate = now
            try updateWebBook(db, book: book)
        }
        try syncAnnualCollections(db, book: book)
    }

    /// 更新或插入最新阅读状态记录，保持同状态只改时间的 Android 规则。
    func upsertReadStatus(
        _ db: Database,
        book: BookRecord,
        changedTime: Int64,
        now: Int64
    ) throws {
        // SQL 目的：读取最新有效阅读状态，决定更新还是插入。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id 匹配且有效；按 id DESC、changed_date DESC。
        // 时间字段：changed_date 为毫秒。
        let newest = try Row.fetchOne(
            db,
            sql: """
                SELECT id, read_status_id FROM book_read_status_record
                WHERE book_id = ? AND is_deleted = 0
                ORDER BY id DESC, changed_date DESC LIMIT 1
                """,
            arguments: [book.id]
        )
        if let newest, (newest["read_status_id"] as Int64) == book.readStatusId {
            // SQL 目的：同状态时只更新最新一条历史的业务时间。
            // 涉及表：book_read_status_record。
            // 关键过滤：最新同状态记录 id；时间均为毫秒。
            // 副作用用途：避免连续相同状态产生重复历史。
            try db.execute(
                sql: "UPDATE book_read_status_record SET updated_date = ?, changed_date = ? WHERE id = ?",
                arguments: [now, changedTime, newest["id"] as Int64]
            )
        } else {
            var status = BookReadStatusRecordRecord(
                id: nil,
                bookId: book.id ?? 0,
                readStatusId: book.readStatusId,
                changedDate: changedTime,
                createdDate: now,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try status.insert(db)
        }
    }

    /// 读完状态按当前单位推进到终点；无有效总量时保持原位置。
    func markWebBookFinished(_ book: inout BookRecord) -> Bool {
        let nextPosition: Double?
        switch book.positionUnit {
        case 1 where book.totalPosition > 0: nextPosition = Double(book.totalPosition)
        case 2 where book.totalPagination > 0: nextPosition = Double(book.totalPagination)
        case 0: nextPosition = 100
        default: nextPosition = nil
        }
        guard let nextPosition, book.readPosition != nextPosition else { return false }
        book.readPosition = nextPosition
        return true
    }

    /// 使用当前 WebBookDao.updateBook 的精确列集合更新主表。
    func updateWebBook(_ db: Database, book: BookRecord) throws {
        // SQL 目的：复制 WebBookDao.updateBook 的全字段覆盖集合。
        // 涉及表：book。
        // 关键过滤：仅按 id；服务层已做有效书校验，但 DAO 不复查删除状态或 owner。
        // 时间字段：updated_date 与 book_mark_modified_time 均来自调用流程。
        // 副作用用途：单书更新与阅读状态副作用共用该 DAO 合同。
        try db.execute(
            sql: """
                UPDATE book SET
                    name = ?, raw_name = ?, author = ?, author_intro = ?, translator = ?,
                    summary = ?, isbn = ?, press = ?, pub_date = ?, douban_id = ?, cover = ?,
                    read_status_id = ?, read_status_changed_date = ?, score = ?, type = ?,
                    position_unit = ?, current_position_unit = ?, read_position = ?,
                    total_position = ?, total_pagination = ?, source_id = ?, purchase_date = ?,
                    price = ?, word_count = ?, catalog = ?,
                    book_mark_modified_time = ?, updated_date = ?
                WHERE id = ?
                """,
            arguments: [
                book.name, book.rawName, book.author, book.authorIntro, book.translator,
                book.summary, book.isbn, book.press, book.pubDate, book.doubanId, book.cover,
                book.readStatusId, book.readStatusChangedDate, book.score, book.type,
                book.positionUnit, book.currentPositionUnit, book.readPosition,
                book.totalPosition, book.totalPagination, book.sourceId, book.purchaseDate,
                book.price, book.wordCount, book.catalog,
                book.bookMarkModifiedTime, book.updatedDate, book.id
            ]
        )
    }

    /// 在既有连接内同步 Web 年度书单；标题与更新时间规则不同于 App 公共 helper。
    func syncAnnualCollections(_ db: Database, book: BookRecord) throws {
        let years = try webReadDoneYears(db, book: book)
        // SQL 目的：读取书籍当前有效年度书单关系。
        // 涉及表：collection_book JOIN collection。
        // 关键过滤：关系与书单有效、is_annual = 1；按 collection.id 分组。
        // 返回字段用途：移除不再命中的年份并补齐缺失年份。
        let linked = try Row.fetchAll(
            db,
            sql: """
                SELECT collection.id, collection.year FROM collection_book
                INNER JOIN collection ON collection_book.collection_id = collection.id
                WHERE collection_book.book_id = ?
                  AND collection_book.is_deleted = 0
                  AND collection.is_deleted = 0
                  AND collection.is_annual = 1
                GROUP BY collection.id
                """,
            arguments: [book.id]
        ).map { (id: $0["id"] as Int64, year: Int($0["year"] as Int64)) }
        for item in linked where !years.contains(item.year) {
            // SQL 目的：移除不再属于读完年份的年度书单关系。
            // 涉及表：collection_book。
            // 关键过滤：book_id、collection_id 且有效；updated_date 使用独立当前毫秒。
            // 副作用用途：对齐 WebBookDao.softDeleteCollectionBook。
            try db.execute(
                sql: """
                    UPDATE collection_book SET is_deleted = 1, updated_date = ?
                    WHERE book_id = ? AND collection_id = ? AND is_deleted = 0
                    """,
                arguments: [currentTimeMillis(), book.id, item.id]
            )
        }
        let linkedYears = Set(linked.map(\.year))
        for year in years.sorted() where !linkedYears.contains(year) {
            try ensureWebAnnualCollection(db, bookID: book.id ?? 0, year: year)
        }
    }

    /// 汇总有效读完历史与当前书籍快照的自然年集合。
    func webReadDoneYears(_ db: Database, book: BookRecord) throws -> Set<Int> {
        // SQL 目的：读取全部有效且非零的读完历史时间。
        // 涉及表：book_read_status_record。
        // 关键过滤：book_id、read_status_id = 3、有效、changed_date != 0。
        // 时间字段：按设备 Calendar.current 转换自然年。
        var times = try Int64.fetchAll(
            db,
            sql: """
                SELECT changed_date FROM book_read_status_record
                WHERE book_id = ? AND read_status_id = 3
                  AND is_deleted = 0 AND changed_date != 0
                ORDER BY id ASC, changed_date ASC
                """,
            arguments: [book.id]
        )
        if book.readStatusId == 3, book.readStatusChangedDate > 0 {
            times.append(book.readStatusChangedDate)
        }
        return Set(times.compactMap { timestamp in
            Calendar.current.dateComponents(
                [.year],
                from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
            ).year
        })
    }

    /// 查询或创建 Web 风格年度书单，并在缺少有效关系时追加关联。
    func ensureWebAnnualCollection(_ db: Database, bookID: Int64, year: Int) throws {
        // SQL 目的：查询指定年份的有效年度书单。
        // 涉及表：collection。
        // 关键过滤：is_annual = 1、year 匹配且有效。
        // 返回字段用途：复用或创建 collection id。
        var collectionID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM collection WHERE is_annual = 1 AND year = ? AND is_deleted = 0",
            arguments: [year]
        )
        if collectionID == nil {
            let now = currentTimeMillis()
            var collection = CollectionRecord(
                id: nil,
                title: "\(year)年阅读书单",
                desc: "",
                order: Int64(year),
                isAnnual: 1,
                year: Int64(year),
                createdDate: now,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try collection.insert(db)
            collectionID = collection.id ?? db.lastInsertedRowID
        }
        guard let collectionID else { return }
        // SQL 目的：判断当前年度书单有效关系是否已存在。
        // 涉及表：collection_book。
        // 关键过滤：book_id、collection_id 且有效。
        // 返回字段用途：避免重复插入。
        let exists = (try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM collection_book
                WHERE book_id = ? AND collection_id = ? AND is_deleted = 0
                """,
            arguments: [bookID, collectionID]
        ) ?? 0) > 0
        if !exists {
            var relation = CollectionBookRecord(
                id: nil,
                collectionId: collectionID,
                bookId: bookID,
                createdDate: currentTimeMillis(),
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try relation.insert(db)
        }
    }

    /// 把 WebBookDao.updateBook 包装为一次独立提交。
    func persistWebBookUpdate(_ book: BookRecord) async throws {
        try await database.dbPool.write { db in
            try updateWebBook(db, book: book)
        }
    }

    /// 非事务同步状态历史、主表读完进度与年度书单；每个 DAO 级写入独立提交。
    func syncReadStatusSideEffectsNontransactional(
        book: inout BookRecord,
        changedTime: Int64
    ) async throws {
        let effectiveChangedTime = changedTime > 0 ? changedTime : currentTimeMillis()
        let now = currentTimeMillis()
        let bookID = book.id ?? 0
        let readStatusID = book.readStatusId
        let newest = try await database.dbPool.read { db -> (Int64, Int64)? in
            // SQL 目的：读取最新有效阅读状态记录。
            // 涉及表：book_read_status_record。
            // 关键过滤：book_id 且有效；按 id/changed_date 倒序。
            // 返回字段用途：决定独立更新或插入。
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, read_status_id FROM book_read_status_record
                    WHERE book_id = ? AND is_deleted = 0
                    ORDER BY id DESC, changed_date DESC LIMIT 1
                    """,
                arguments: [bookID]
            ) else { return nil }
            return (row["id"], row["read_status_id"])
        }
        if let newest, newest.1 == book.readStatusId {
            try await database.dbPool.write { db in
                // SQL 目的：更新最新同状态历史的业务时间。
                // 涉及表：book_read_status_record。
                // 关键过滤：记录 id；时间均为毫秒。
                // 副作用用途：这是独立提交，后续失败不回滚。
                try db.execute(
                    sql: "UPDATE book_read_status_record SET updated_date = ?, changed_date = ? WHERE id = ?",
                    arguments: [now, effectiveChangedTime, newest.0]
                )
            }
        } else {
            try await database.dbPool.write { db in
                var status = BookReadStatusRecordRecord(
                    id: nil,
                    bookId: bookID,
                    readStatusId: readStatusID,
                    changedDate: effectiveChangedTime,
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try status.insert(db)
            }
        }
        var needsUpdate = false
        if book.readStatusChangedDate != effectiveChangedTime {
            book.readStatusChangedDate = effectiveChangedTime
            needsUpdate = true
        }
        if book.readStatusId == 3 {
            needsUpdate = markWebBookFinished(&book) || needsUpdate
        }
        if needsUpdate {
            book.updatedDate = now
            try await persistWebBookUpdate(book)
        }
        try await syncAnnualCollectionsNontransactional(book: book)
    }

    /// 按 Android 多 DAO 顺序非事务同步年度书单关系。
    func syncAnnualCollectionsNontransactional(book: BookRecord) async throws {
        let years = try await database.dbPool.read { db in try webReadDoneYears(db, book: book) }
        let linked = try await database.dbPool.read { db -> [(Int64, Int)] in
            // SQL 目的：读取当前有效年度书单关系。
            // 涉及表：collection_book JOIN collection。
            // 关键过滤：关系与书单有效、is_annual = 1。
            // 返回字段用途：逐项独立删除或补齐。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT collection.id, collection.year FROM collection_book
                    INNER JOIN collection ON collection_book.collection_id = collection.id
                    WHERE collection_book.book_id = ?
                      AND collection_book.is_deleted = 0
                      AND collection.is_deleted = 0
                      AND collection.is_annual = 1
                    GROUP BY collection.id
                    """,
                arguments: [book.id]
            ).map { ($0["id"], Int($0["year"] as Int64)) }
        }
        for item in linked where !years.contains(item.1) {
            let updatedAt = currentTimeMillis()
            try await database.dbPool.write { db in
                // SQL 目的：独立软删除不再匹配的年度书单关系。
                // 涉及表：collection_book。
                // 关键过滤：book_id、collection_id 且有效；updated_date 为独立毫秒。
                // 副作用用途：后续年度创建失败不会回滚本删除。
                try db.execute(
                    sql: """
                        UPDATE collection_book SET is_deleted = 1, updated_date = ?
                        WHERE book_id = ? AND collection_id = ? AND is_deleted = 0
                        """,
                    arguments: [updatedAt, book.id, item.0]
                )
            }
        }
        let linkedYears = Set(linked.map(\.1))
        for year in years.sorted() where !linkedYears.contains(year) {
            try await ensureWebAnnualCollectionNontransactional(bookID: book.id ?? 0, year: year)
        }
    }

    /// 非事务查询/创建年度书单后再独立查询/插入关系。
    func ensureWebAnnualCollectionNontransactional(bookID: Int64, year: Int) async throws {
        var collectionID = try await database.dbPool.read { db in
            // SQL 目的：查询目标年份有效年度书单。
            // 涉及表：collection。
            // 关键过滤：is_annual = 1、year 匹配且有效。
            // 返回字段用途：决定是否独立创建。
            try Int64.fetchOne(
                db,
                sql: "SELECT id FROM collection WHERE is_annual = 1 AND year = ? AND is_deleted = 0",
                arguments: [year]
            )
        }
        if collectionID == nil {
            let now = currentTimeMillis()
            collectionID = try await database.dbPool.write { db in
                var collection = CollectionRecord(
                    id: nil,
                    title: "\(year)年阅读书单",
                    desc: "",
                    order: Int64(year),
                    isAnnual: 1,
                    year: Int64(year),
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try collection.insert(db)
                return collection.id ?? db.lastInsertedRowID
            }
        }
        guard let collectionID else { return }
        let exists = try await database.dbPool.read { db in
            // SQL 目的：查询目标书单关系是否已有效存在。
            // 涉及表：collection_book。
            // 关键过滤：book_id、collection_id 且有效。
            // 返回字段用途：决定是否独立插入。
            (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM collection_book
                    WHERE book_id = ? AND collection_id = ? AND is_deleted = 0
                    """,
                arguments: [bookID, collectionID]
            ) ?? 0) > 0
        }
        if !exists {
            let now = currentTimeMillis()
            try await database.dbPool.write { db in
                var relation = CollectionBookRecord(
                    id: nil,
                    collectionId: collectionID,
                    bookId: bookID,
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try relation.insert(db)
            }
        }
    }

    /// 在调用方事务内精确替换书籍标签关系。
    func replaceBookTags(
        _ db: Database,
        bookID: Int64,
        tagIDs: [Int64],
        createdAt: Int64
    ) throws {
        // SQL 目的：清空书籍当前全部有效标签关系，为同事务内的最终集合重建腾出空间。
        // 涉及表：tag_book；关键过滤：book_id 与 is_deleted=0。
        // 时间字段：updated_date 使用本次书籍更新的统一毫秒值。
        // 副作用用途：任一关系插入失败时由外层事务整体回滚。
        try db.execute(
            sql: """
                UPDATE tag_book SET is_deleted = 1, updated_date = ?
                WHERE book_id = ? AND is_deleted = 0
                """,
            arguments: [createdAt, bookID]
        )
        for tagID in tagIDs {
            var relation = TagBookRecord(
                id: nil,
                bookId: bookID,
                tagId: tagID,
                createdDate: createdAt,
                updatedDate: createdAt,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try relation.insert(db)
        }
    }

    /// 在调用方事务内把书籍关系规范化为请求分组或现有首个有效分组。
    func normalizeBookGroupRelations(
        _ db: Database,
        bookID: Int64,
        requestedGroupID: Int64?,
        now: Int64
    ) throws {
        // SQL 目的：读取书籍全部有效分组关系以选择保留关系。
        // 涉及表：group_book；关键过滤：book_id、is_deleted=0；按创建时间和主键稳定排序。
        // 返回字段用途：省略 groupId 时保留首关系，显式 groupId 时保留对应关系。
        let relations = try GroupBookRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM group_book
                WHERE book_id = ? AND is_deleted = 0
                ORDER BY created_date ASC, id ASC
                """,
            arguments: [bookID]
        )
        let keep: GroupBookRecord? = if requestedGroupID == nil {
            relations.first
        } else if requestedGroupID! <= 0 {
            nil
        } else {
            relations.first { $0.groupId == requestedGroupID }
        }
        if let keepID = keep?.id {
            // SQL 目的：仅保留选中的有效主关系。
            // 涉及表：group_book；关键过滤：同书、排除 keepID、仅有效关系。
            // 时间字段：updated_date 使用书籍更新时刻；副作用与主表写入同事务。
            try db.execute(
                sql: """
                    UPDATE group_book SET is_deleted = 1, updated_date = ?
                    WHERE book_id = ? AND id != ? AND is_deleted = 0
                    """,
                arguments: [now, bookID, keepID]
            )
        } else {
            // SQL 目的：移除书籍全部现有有效分组关系。
            // 涉及表：group_book；关键过滤：book_id、is_deleted=0。
            // 时间字段：updated_date 使用书籍更新时刻。
            try db.execute(
                sql: """
                    UPDATE group_book SET is_deleted = 1, updated_date = ?
                    WHERE book_id = ? AND is_deleted = 0
                    """,
                arguments: [now, bookID]
            )
            if let requestedGroupID, requestedGroupID > 0 {
                var relation = GroupBookRecord(
                    id: nil,
                    groupId: requestedGroupID,
                    bookId: bookID,
                    createdDate: now,
                    updatedDate: now,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try relation.insert(db)
            }
        }
    }

    /// 先独立软删除全部有效标签关系，再按请求原序逐条独立插入。
    func replaceBookTagsNontransactional(
        bookID: Int64,
        tagIDs: [Int64],
        createdAt: Int64
    ) async throws {
        let deletedAt = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：按 WebBookDao.softDeleteTagBooksByBookId 清空当前有效标签关系。
            // 涉及表：tag_book。
            // 关键过滤：book_id 且 is_deleted = 0；更新时间独立于主表 now。
            // 副作用用途：每个后续插入都不与本删除共享事务。
            try db.execute(
                sql: """
                    UPDATE tag_book SET is_deleted = 1, updated_date = ?
                    WHERE book_id = ? AND is_deleted = 0
                    """,
                arguments: [deletedAt, bookID]
            )
        }
        for tagID in tagIDs {
            try await database.dbPool.write { db in
                var relation = TagBookRecord(
                    id: nil,
                    bookId: bookID,
                    tagId: tagID,
                    createdDate: createdAt,
                    updatedDate: createdAt,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try relation.insert(db)
            }
        }
    }

    /// 规范化为首个有效主分组；删除与新关系插入按 Android Web 分别提交。
    func normalizeBookGroupRelationsNontransactional(
        bookID: Int64,
        requestedGroupID: Int64?,
        now: Int64
    ) async throws {
        let relations = try await database.dbPool.read { db in
            // SQL 目的：读取书籍全部有效分组关系并确定首关系。
            // 涉及表：group_book。
            // 关键过滤：book_id 且有效；按 created_date、id 升序。
            // 返回字段用途：保留请求分组现有关系或首关系。
            try GroupBookRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM group_book
                    WHERE book_id = ? AND is_deleted = 0
                    ORDER BY created_date ASC, id ASC
                    """,
                arguments: [bookID]
            )
        }
        let keep: GroupBookRecord? = if requestedGroupID == nil {
            relations.first
        } else if requestedGroupID! <= 0 {
            nil
        } else {
            relations.first { $0.groupId == requestedGroupID }
        }
        if let keep, let keepID = keep.id {
            try await database.dbPool.write { db in
                // SQL 目的：保留主关系并软删除该书其余有效分组关系。
                // 涉及表：group_book。
                // 关键过滤：book_id、id != keep 且有效；使用主流程 now。
                // 副作用用途：省略 groupId 时也会把多关系归一化为首关系。
                try db.execute(
                    sql: """
                        UPDATE group_book SET is_deleted = 1, updated_date = ?
                        WHERE book_id = ? AND id != ? AND is_deleted = 0
                        """,
                    arguments: [now, bookID, keepID]
                )
            }
        } else if let requestedGroupID, requestedGroupID > 0 {
            try await softDeleteAllGroupRelations(bookID: bookID, now: now)
            try await database.dbPool.write { db in
                var relation = GroupBookRecord(
                    id: nil,
                    groupId: requestedGroupID,
                    bookId: bookID,
                    createdDate: now,
                    updatedDate: now,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try relation.insert(db)
            }
        } else {
            try await softDeleteAllGroupRelations(bookID: bookID, now: now)
        }
    }

    /// 以独立提交软删除书籍全部有效分组关系。
    func softDeleteAllGroupRelations(bookID: Int64, now: Int64) async throws {
        try await database.dbPool.write { db in
            // SQL 目的：软删除书籍全部有效分组关系。
            // 涉及表：group_book。
            // 关键过滤：book_id 且 is_deleted = 0；时间复用主流程 now。
            // 副作用用途：新分组插入失败时该删除不会回滚。
            try db.execute(
                sql: """
                    UPDATE group_book SET is_deleted = 1, updated_date = ?
                    WHERE book_id = ? AND is_deleted = 0
                    """,
                arguments: [now, bookID]
            )
        }
    }
}
