import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供本地数据库连接，依赖 BookRecord/ChapterRecord/GroupRecord/TagRecord/SourceRecord 等持久化实体
 * [OUTPUT]: 对外提供 BookEditorRepository（BookEditorRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层书籍录入仓储实现，统一封装录入选项、偏好、新增保存与既有书籍编辑事务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍录入仓储实现，负责录入页加载、偏好持久化与书籍新增/编辑事务。
struct BookEditorRepository: BookEditorRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let userDefaults: UserDefaults

    private enum Keys {
        static let preferBookType = "book_entry_prefer_type"
        static let preferSourceName = "book_entry_prefer_source_name"
        static let preferProgressUnit = "book_entry_prefer_unit"
        static let preferReadingStatus = "book_entry_prefer_status"
    }

    init(
        databaseManager: DatabaseManager,
        userDefaults: UserDefaults = .standard
    ) {
        self.databaseManager = databaseManager
        self.userDefaults = userDefaults
    }

    /// 读取录入页选项集合，覆盖来源、分组、标签与录入偏好。
    func fetchOptions() async throws -> BookEditorOptions {
        let preference = loadPreference()
        return try await databaseManager.database.dbPool.read { db in
            let ownerId = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
            return BookEditorOptions(
                sources: try fetchSources(db),
                groups: try fetchGroups(db, ownerId: ownerId),
                tags: try fetchTags(db, ownerId: ownerId),
                preference: preference
            )
        }
    }

    /// 根据搜索结果与当前偏好构建录入页首屏草稿。
    func makeDraft(from seed: BookEditorSeed?) -> BookEditorDraft {
        let preference = loadPreference()
        let seed = seed ?? .manual
        let bookType = seed.preferredBookType ?? preference.bookType
        let progressUnit = seed.preferredProgressUnit ?? preference.progressUnit
        let sourceName = resolvedSourceName(seed: seed, preference: preference)

        return BookEditorDraft(
            title: seed.title,
            rawTitle: seed.rawTitle,
            author: seed.author,
            authorIntro: seed.authorIntro,
            translator: seed.translator,
            press: seed.press,
            isbn: seed.isbn,
            pubDate: seed.pubDate,
            summary: seed.summary,
            catalog: seed.catalog,
            coverURL: seed.coverURL,
            doubanId: seed.doubanId,
            totalPagesText: seed.totalPages.map(String.init) ?? "",
            totalPositionText: "",
            currentProgressText: "",
            wordCount: seed.totalWordCount,
            sourceName: sourceName,
            groupName: "",
            tagNames: [],
            purchaseDate: nil,
            priceText: "",
            readStatusChangedDate: .now,
            bookType: bookType,
            progressUnit: progressUnit,
            readingStatus: preference.readingStatus,
            searchSource: seed.searchSource
        )
    }

    /// 保存录入偏好，为后续手动创建和搜索结果补空提供默认值。
    func savePreference(_ preference: BookEntryPreference) {
        userDefaults.set(preference.bookType.rawValue, forKey: Keys.preferBookType)
        userDefaults.set(preference.sourceName, forKey: Keys.preferSourceName)
        userDefaults.set(preference.progressUnit.rawValue, forKey: Keys.preferProgressUnit)
        userDefaults.set(preference.readingStatus.rawValue, forKey: Keys.preferReadingStatus)
    }

    /// 读取既有书籍并转换为录入页可编辑草稿。
    func fetchEditableBook(bookId: Int64) async throws -> BookEditorDraft {
        try await databaseManager.database.dbPool.read { db in
            guard let book = try BookRecord.fetchOne(db, key: bookId), book.isDeleted == 0 else {
                throw BookEditorError.bookNotFound
            }

            let sourceName = try fetchSourceName(sourceId: book.sourceId, db: db)
            let groupName = try fetchPrimaryGroupName(bookId: bookId, db: db)
            let tagNames = try fetchBookTagNames(bookId: bookId, db: db)

            return BookEditorDraft(
                title: book.name,
                rawTitle: book.rawName,
                author: book.author,
                authorIntro: book.authorIntro,
                translator: book.translator,
                press: book.press,
                isbn: book.isbn,
                pubDate: book.pubDate,
                summary: book.summary,
                catalog: book.catalog,
                coverURL: book.cover,
                doubanId: book.doubanId > 0 ? Int(book.doubanId) : nil,
                totalPagesText: formatPositiveInteger(book.totalPagination),
                totalPositionText: formatPositiveInteger(book.totalPosition),
                currentProgressText: formatProgress(book.readPosition, unit: book.positionUnit),
                wordCount: book.wordCount.map(Int.init),
                sourceName: sourceName,
                groupName: groupName,
                tagNames: tagNames,
                purchaseDate: dateFromMillis(book.purchaseDate),
                priceText: formatPositiveDecimal(book.price),
                readStatusChangedDate: dateFromMillis(book.readStatusChangedDate) ?? .now,
                bookType: BookEntryBookType(rawValue: book.type) ?? .paper,
                progressUnit: BookEntryProgressUnit(rawValue: book.positionUnit) ?? .pagination,
                readingStatus: BookEntryReadingStatus(rawValue: book.readStatusId) ?? .reading,
                searchSource: nil
            )
        }
    }

    /// 按 Android 判重规则和事务顺序保存新书。
    func saveBook(_ draft: BookEditorDraft) async throws -> Int64 {
        let normalizedTitle = draft.trimmedTitle
        guard !normalizedTitle.isEmpty else {
            throw BookEditorError.emptyTitle
        }

        let result = try await databaseManager.database.dbPool.write { db in
            let ownerId = try DatabaseOwnerResolver.resolveOwnerID(in: db)
            let normalizedDraft = normalizeDraft(draft)
            let normalizedTagNames = normalizeTagNames(normalizedDraft.tagNames)
            guard try !isDuplicateBook(normalizedDraft, ownerId: ownerId, db: db) else {
                throw BookEditorError.duplicateBook
            }

            let sourceId = try resolveSourceId(for: normalizedDraft.sourceName, in: db)
            let groupId = try resolveGroupId(for: normalizedDraft.groupName, ownerId: ownerId, in: db)
            let tagIds = try resolveTagIds(for: normalizedTagNames, ownerId: ownerId, in: db)
            let now = Int64(Date().timeIntervalSince1970 * 1000)

            var book = try buildBookRecord(
                from: normalizedDraft,
                ownerId: ownerId,
                sourceId: sourceId,
                createdAt: now,
                db: db
            )
            try book.insert(db)
            guard let bookId = book.id else {
                throw BookSearchError.remoteService(message: "新书保存后未生成主键")
            }

            try insertChapters(from: normalizedDraft.catalog, for: bookId, createdAt: now, db: db)
            try insertReadStatusRecord(
                bookId: bookId,
                status: normalizedDraft.readingStatus,
                changedAt: Int64(normalizedDraft.readStatusChangedDate.timeIntervalSince1970 * 1000),
                createdAt: now,
                db: db
            )

            if let groupId {
                var groupBook = GroupBookRecord(
                    id: nil,
                    groupId: groupId,
                    bookId: bookId,
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try groupBook.insert(db)
            }

            for tagId in tagIds {
                var tagBook = TagBookRecord(
                    id: nil,
                    bookId: bookId,
                    tagId: tagId,
                    createdDate: now,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try tagBook.insert(db)
            }

            return (
                bookId,
                BookEntryPreference(
                    bookType: normalizedDraft.bookType,
                    sourceName: normalizedDraft.sourceName.isEmpty ? "未知" : normalizedDraft.sourceName,
                    progressUnit: normalizedDraft.progressUnit,
                    readingStatus: normalizedDraft.readingStatus
                )
            )
        }

        savePreference(result.1)
        return result.0
    }

    /// 按当前模式保存书籍草稿；新增沿用原事务，编辑更新主表并重建可编辑关系。
    func saveBookDraft(_ draft: BookEditorDraft, mode: BookEditorMode) async throws -> Int64 {
        switch mode {
        case .create:
            return try await saveBook(draft)
        case .edit(let bookId):
            return try await updateBook(draft, bookId: bookId)
        }
    }
}

private extension BookEditorRepository {
    nonisolated static var currentTimestampMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func loadPreference() -> BookEntryPreference {
        let bookType = BookEntryBookType(rawValue: Int64(userDefaults.integer(forKey: Keys.preferBookType)))
            ?? BookEntryPreference.default.bookType
        let progressUnit = BookEntryProgressUnit(rawValue: Int64(userDefaults.integer(forKey: Keys.preferProgressUnit)))
            ?? BookEntryPreference.default.progressUnit
        let readingStatus = BookEntryReadingStatus(rawValue: Int64(userDefaults.integer(forKey: Keys.preferReadingStatus)))
            ?? BookEntryPreference.default.readingStatus
        let sourceName = userDefaults.string(forKey: Keys.preferSourceName) ?? BookEntryPreference.default.sourceName

        return BookEntryPreference(
            bookType: bookType,
            sourceName: sourceName.isEmpty ? BookEntryPreference.default.sourceName : sourceName,
            progressUnit: progressUnit,
            readingStatus: readingStatus
        )
    }

    func resolvedSourceName(seed: BookEditorSeed, preference: BookEntryPreference) -> String {
        if let preferredSourceName = seed.preferredSourceName, !preferredSourceName.isEmpty {
            return preferredSourceName
        }
        if !preference.sourceName.isEmpty {
            return preference.sourceName
        }
        return "未知"
    }

    nonisolated func fetchSources(_ db: Database) throws -> [BookEditorNamedOption] {
        // SQL 目的：读取未删除来源列表，供录入页“来源”建议芯片展示。
        // 过滤条件：仅保留 source.is_deleted = 0，按 source_order 升序保持 Android 字典顺序。
        let sql = """
            SELECT id, name
            FROM source
            WHERE is_deleted = 0
            ORDER BY source_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql).compactMap { row in
            guard let name: String = row["name"], !name.isEmpty else { return nil }
            return BookEditorNamedOption(id: row["id"], title: name)
        }
    }

    nonisolated func fetchGroups(_ db: Database, ownerId: Int64) throws -> [BookEditorNamedOption] {
        // SQL 目的：读取未删除分组列表，供录入页单选分组建议使用。
        // 过滤条件：仅保留 group.is_deleted = 0，排序规则与 Android 分组列表一致。
        let sql = """
            SELECT id, name
            FROM `group`
            WHERE is_deleted = 0 AND user_id = ?
            ORDER BY pinned DESC, pin_order ASC, group_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [ownerId]).compactMap { row in
            guard let name: String = row["name"], !name.isEmpty else { return nil }
            return BookEditorNamedOption(id: row["id"], title: name)
        }
    }

    nonisolated func fetchTags(_ db: Database, ownerId: Int64) throws -> [BookEditorNamedOption] {
        // SQL 目的：读取书籍标签列表，供录入页多选建议和新标签补全使用。
        // 过滤条件：仅保留 tag.type = 2 且 tag.is_deleted = 0，避免混入笔记标签。
        let sql = """
            SELECT id, name
            FROM tag
            WHERE type = 2 AND is_deleted = 0 AND user_id = ?
            ORDER BY tag_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [ownerId]).compactMap { row in
            guard let name: String = row["name"], !name.isEmpty else { return nil }
            return BookEditorNamedOption(id: row["id"], title: name)
        }
    }

    nonisolated func normalizeDraft(_ draft: BookEditorDraft) -> BookEditorDraft {
        var copy = draft
        copy.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.rawTitle = draft.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.author = draft.author.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.authorIntro = draft.authorIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.translator = draft.translator.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.press = draft.press.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.isbn = draft.isbn.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pubDate = draft.pubDate.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.catalog = draft.catalog.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.coverURL = draft.coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sourceName = draft.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.groupName = draft.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.priceText = draft.priceText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.totalPagesText = draft.totalPagesText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.totalPositionText = draft.totalPositionText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.currentProgressText = draft.currentProgressText.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    nonisolated func normalizeTagNames(_ tagNames: [String]) -> [String] {
        Array(
            Set(
                tagNames
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }

    nonisolated func isDuplicateBook(
        _ draft: BookEditorDraft,
        ownerId: Int64,
        db: Database,
        excludingBookId: Int64? = nil
    ) throws -> Bool {
        // SQL 目的：按 Android 规则判重，避免新增同一本书。
        // 过滤条件：精确匹配 name/author/translator/press/isbn/pub_date 六元组，且排除软删除记录；编辑模式额外排除当前书籍 ID。
        let baseSQL = """
            SELECT COUNT(*)
            FROM book
            WHERE is_deleted = 0
              AND user_id = ?
              AND name = ?
              AND author = ?
              AND translator = ?
              AND press = ?
              AND isbn = ?
              AND pub_date = ?
            """
        let count: Int
        if let excludingBookId {
            count = try Int.fetchOne(
                db,
                sql: baseSQL + "\n  AND id != ?",
                arguments: [
                    ownerId,
                    draft.title,
                    draft.author,
                    draft.translator,
                    draft.press,
                    draft.isbn,
                    draft.pubDate,
                    excludingBookId
                ]
            ) ?? 0
        } else {
            count = try Int.fetchOne(
                db,
                sql: baseSQL,
                arguments: [
                    ownerId,
                    draft.title,
                    draft.author,
                    draft.translator,
                    draft.press,
                    draft.isbn,
                    draft.pubDate
                ]
            ) ?? 0
        }
        return count > 0
    }

    nonisolated func resolveSourceId(for sourceName: String, in db: Database) throws -> Int64 {
        let normalized = sourceName.isEmpty ? "未知" : sourceName
        // SQL 目的：按来源名称查重或创建来源记录，保证在线小说平台也能落到 source 表。
        // 过滤条件：同名且未删除的 source 视为可复用来源。
        let querySQL = """
            SELECT id
            FROM source
            WHERE name = ? AND is_deleted = 0
            LIMIT 1
            """
        if let id = try Int64.fetchOne(db, sql: querySQL, arguments: [normalized]) {
            return id
        }

        let nextOrder = (try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(source_order), -1) + 1 FROM source")) ?? 0
        var record = SourceRecord(
            id: nil,
            name: normalized,
            sourceOrder: nextOrder,
            bookshelfOrder: -1,
            isHide: 0,
            createdDate: Int64(Date().timeIntervalSince1970 * 1000),
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
        return record.id ?? 1
    }

    nonisolated func resolveGroupId(for groupName: String, ownerId: Int64, in db: Database) throws -> Int64? {
        guard !groupName.isEmpty else { return nil }
        let querySQL = """
            SELECT id
            FROM `group`
            WHERE name = ? AND is_deleted = 0 AND user_id = ?
            LIMIT 1
            """
        if let id = try Int64.fetchOne(db, sql: querySQL, arguments: [groupName, ownerId]) {
            return id
        }

        let nextOrder = (try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(group_order), -1) + 1 FROM `group` WHERE user_id = ?",
            arguments: [ownerId]
        )) ?? 0
        var record = GroupRecord(
            id: nil,
            userId: ownerId,
            name: groupName,
            groupOrder: nextOrder,
            pinned: 0,
            pinOrder: 0,
            createdDate: Int64(Date().timeIntervalSince1970 * 1000),
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
        return record.id
    }

    nonisolated func resolveTagIds(for tagNames: [String], ownerId: Int64, in db: Database) throws -> [Int64] {
        var ids: [Int64] = []
        for tagName in tagNames {
            let querySQL = """
                SELECT id
                FROM tag
                WHERE name = ? AND type = 2 AND is_deleted = 0 AND user_id = ?
                LIMIT 1
                """
            if let existing = try Int64.fetchOne(db, sql: querySQL, arguments: [tagName, ownerId]) {
                ids.append(existing)
                continue
            }

            let nextOrder = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(tag_order), -1) + 1 FROM tag WHERE type = 2 AND user_id = ?",
                arguments: [ownerId]
            )) ?? 0
            var record = TagRecord(
                id: nil,
                userId: ownerId,
                name: tagName,
                color: 0,
                tagOrder: nextOrder,
                type: 2,
                createdDate: Int64(Date().timeIntervalSince1970 * 1000),
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
            if let id = record.id {
                ids.append(id)
            }
        }
        return ids
    }

    nonisolated func buildBookRecord(
        from draft: BookEditorDraft,
        ownerId: Int64,
        sourceId: Int64,
        createdAt: Int64,
        db: Database
    ) throws -> BookRecord {
        let readStatusChangedDate = Int64(draft.readStatusChangedDate.timeIntervalSince1970 * 1000)
        let nextOrder = (try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(book_order), -1) + 1 FROM book WHERE is_deleted = 0 AND user_id = ?",
            arguments: [ownerId]
        )) ?? 0
        let currentProgress = Double(draft.currentProgressText) ?? 0
        let totalPages = Int64(draft.totalPagesText.digitsOnly) ?? 0
        let totalPosition = Int64(draft.totalPositionText.digitsOnly) ?? 0
        let price = Double(draft.priceText) ?? 0

        var readPosition = currentProgress
        var resolvedTotalPages = totalPages
        var resolvedTotalPosition = totalPosition

        switch draft.progressUnit {
        case .progress:
            readPosition = min(max(currentProgress, 0), 100)
        case .position:
            readPosition = Double(Int64(draft.currentProgressText.digitsOnly) ?? 0)
            resolvedTotalPages = 0
        case .pagination:
            readPosition = Double(Int64(draft.currentProgressText.digitsOnly) ?? 0)
            resolvedTotalPosition = 0
        }

        return BookRecord(
            id: nil,
            userId: ownerId,
            doubanId: Int64(draft.doubanId ?? 0),
            name: draft.title,
            rawName: draft.rawTitle.isEmpty ? draft.title : draft.rawTitle,
            cover: draft.coverURL,
            author: draft.author,
            authorIntro: draft.authorIntro,
            translator: draft.translator,
            isbn: draft.isbn,
            pubDate: draft.pubDate,
            press: draft.press,
            summary: draft.summary,
            readPosition: readPosition,
            totalPosition: resolvedTotalPosition,
            totalPagination: resolvedTotalPages,
            type: draft.bookType.rawValue,
            currentPositionUnit: draft.progressUnit.rawValue,
            positionUnit: draft.progressUnit.rawValue,
            sourceId: sourceId,
            purchaseDate: draft.purchaseDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0,
            price: price,
            bookOrder: nextOrder,
            pinned: 0,
            pinOrder: 0,
            readStatusId: draft.readingStatus.rawValue,
            readStatusChangedDate: readStatusChangedDate,
            score: 0,
            catalog: draft.catalog,
            bookMarkModifiedTime: 0,
            wordCount: draft.wordCount.map(Int64.init),
            createdDate: createdAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
    }

    func updateBook(_ draft: BookEditorDraft, bookId: Int64) async throws -> Int64 {
        let normalizedTitle = draft.trimmedTitle
        guard !normalizedTitle.isEmpty else {
            throw BookEditorError.emptyTitle
        }

        let preference = try await databaseManager.database.dbPool.write { db in
            guard var book = try BookRecord.fetchOne(db, key: bookId), book.isDeleted == 0 else {
                throw BookEditorError.bookNotFound
            }

            let ownerId = book.userId
            let normalizedDraft = normalizeDraft(draft)
            let normalizedTagNames = normalizeTagNames(normalizedDraft.tagNames)
            guard try !isDuplicateBook(
                normalizedDraft,
                ownerId: ownerId,
                db: db,
                excludingBookId: bookId
            ) else {
                throw BookEditorError.duplicateBook
            }

            let sourceId = try resolveSourceId(for: normalizedDraft.sourceName, in: db)
            let groupId = try resolveGroupId(for: normalizedDraft.groupName, ownerId: ownerId, in: db)
            let tagIds = try resolveTagIds(for: normalizedTagNames, ownerId: ownerId, in: db)
            let now = Self.currentTimestampMillis
            let changedAt = Int64(normalizedDraft.readStatusChangedDate.timeIntervalSince1970 * 1000)
            let shouldInsertReadStatus = book.readStatusId != normalizedDraft.readingStatus.rawValue
                || book.readStatusChangedDate != changedAt

            applyDraft(normalizedDraft, to: &book, sourceId: sourceId, updatedAt: now)
            try book.update(db)

            try replaceGroupRelation(groupId: groupId, for: bookId, updatedAt: now, db: db)
            try replaceTagRelations(tagIds: tagIds, for: bookId, updatedAt: now, db: db)
            if shouldInsertReadStatus {
                try insertReadStatusRecord(
                    bookId: bookId,
                    status: normalizedDraft.readingStatus,
                    changedAt: changedAt,
                    createdAt: now,
                    db: db
                )
            }

            return BookEntryPreference(
                bookType: normalizedDraft.bookType,
                sourceName: normalizedDraft.sourceName.isEmpty ? "未知" : normalizedDraft.sourceName,
                progressUnit: normalizedDraft.progressUnit,
                readingStatus: normalizedDraft.readingStatus
            )
        }

        savePreference(preference)
        return bookId
    }

    nonisolated func applyDraft(
        _ draft: BookEditorDraft,
        to book: inout BookRecord,
        sourceId: Int64,
        updatedAt: Int64
    ) {
        let readStatusChangedDate = Int64(draft.readStatusChangedDate.timeIntervalSince1970 * 1000)
        let currentProgress = Double(draft.currentProgressText) ?? 0
        let totalPages = Int64(draft.totalPagesText.digitsOnly) ?? 0
        let totalPosition = Int64(draft.totalPositionText.digitsOnly) ?? 0
        let price = Double(draft.priceText) ?? 0

        var readPosition = currentProgress
        var resolvedTotalPages = totalPages
        var resolvedTotalPosition = totalPosition

        switch draft.progressUnit {
        case .progress:
            readPosition = min(max(currentProgress, 0), 100)
        case .position:
            readPosition = Double(Int64(draft.currentProgressText.digitsOnly) ?? 0)
            resolvedTotalPages = 0
        case .pagination:
            readPosition = Double(Int64(draft.currentProgressText.digitsOnly) ?? 0)
            resolvedTotalPosition = 0
        }

        book.doubanId = Int64(draft.doubanId ?? 0)
        book.name = draft.title
        book.rawName = draft.rawTitle.isEmpty ? draft.title : draft.rawTitle
        book.cover = draft.coverURL
        book.author = draft.author
        book.authorIntro = draft.authorIntro
        book.translator = draft.translator
        book.isbn = draft.isbn
        book.pubDate = draft.pubDate
        book.press = draft.press
        book.summary = draft.summary
        book.readPosition = readPosition
        book.totalPosition = resolvedTotalPosition
        book.totalPagination = resolvedTotalPages
        book.type = draft.bookType.rawValue
        book.currentPositionUnit = draft.progressUnit.rawValue
        book.positionUnit = draft.progressUnit.rawValue
        book.sourceId = sourceId
        book.purchaseDate = draft.purchaseDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        book.price = price
        book.readStatusId = draft.readingStatus.rawValue
        book.readStatusChangedDate = readStatusChangedDate
        book.catalog = draft.catalog
        book.wordCount = draft.wordCount.map(Int64.init)
        book.updatedDate = updatedAt
    }

    nonisolated func fetchSourceName(sourceId: Int64, db: Database) throws -> String {
        // SQL 目的：按书籍 source_id 读取当前来源名称，用于编辑页回填来源文本。
        // 过滤条件：仅使用未删除 source；若来源缺失则回退 Android 默认“未知”。
        let sql = """
            SELECT name
            FROM source
            WHERE id = ? AND is_deleted = 0
            LIMIT 1
            """
        return try String.fetchOne(db, sql: sql, arguments: [sourceId]) ?? "未知"
    }

    nonisolated func fetchPrimaryGroupName(bookId: Int64, db: Database) throws -> String {
        // SQL 目的：读取书籍当前有效分组名称，供编辑页单分组字段回填。
        // 关联关系：group_book.group_id -> group.id；仅保留两表未删除记录，按关系创建顺序选择首个有效分组。
        let sql = """
            SELECT g.name
            FROM group_book gb
            JOIN `group` g ON g.id = gb.group_id
            WHERE gb.book_id = ?
              AND gb.is_deleted = 0
              AND g.is_deleted = 0
            ORDER BY gb.id ASC
            LIMIT 1
            """
        return try String.fetchOne(db, sql: sql, arguments: [bookId]) ?? ""
    }

    nonisolated func fetchBookTagNames(bookId: Int64, db: Database) throws -> [String] {
        // SQL 目的：读取书籍当前有效标签，供编辑页多选标签回填。
        // 关联关系：tag_book.tag_id -> tag.id；仅保留书籍标签 type = 2 与两表未删除关系，按标签排序稳定展示。
        let sql = """
            SELECT t.name
            FROM tag_book tb
            JOIN tag t ON t.id = tb.tag_id
            WHERE tb.book_id = ?
              AND tb.is_deleted = 0
              AND t.type = 2
              AND t.is_deleted = 0
            ORDER BY t.tag_order ASC, t.id ASC
            """
        return try String.fetchAll(db, sql: sql, arguments: [bookId])
    }

    nonisolated func replaceGroupRelation(groupId: Int64?, for bookId: Int64, updatedAt: Int64, db: Database) throws {
        // SQL 目的：编辑分组时替换书籍有效分组关系，保持单书唯一有效分组语义。
        // 副作用：先软删除 group_book 中当前书籍的有效关系，再按草稿分组插入新关系。
        let sql = """
            UPDATE group_book
            SET updated_date = ?, is_deleted = 1
            WHERE book_id = ? AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookId])

        guard let groupId else { return }
        var relation = GroupBookRecord(
            id: nil,
            groupId: groupId,
            bookId: bookId,
            createdDate: updatedAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try relation.insert(db)
    }

    nonisolated func replaceTagRelations(tagIds: [Int64], for bookId: Int64, updatedAt: Int64, db: Database) throws {
        // SQL 目的：编辑标签时替换书籍有效标签关系，和 Android 单书编辑保存的全量覆盖意图一致。
        // 副作用：先软删除 tag_book 中当前书籍的有效关系，再插入当前草稿标签集合。
        let sql = """
            UPDATE tag_book
            SET updated_date = ?, is_deleted = 1
            WHERE book_id = ? AND is_deleted = 0
            """
        try db.execute(sql: sql, arguments: [updatedAt, bookId])

        for tagId in tagIds {
            var relation = TagBookRecord(
                id: nil,
                bookId: bookId,
                tagId: tagId,
                createdDate: updatedAt,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try relation.insert(db)
        }
    }

    nonisolated func dateFromMillis(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }

    nonisolated func formatPositiveInteger(_ value: Int64) -> String {
        value > 0 ? String(value) : ""
    }

    nonisolated func formatPositiveDecimal(_ value: Double) -> String {
        guard value > 0 else { return "" }
        if value.rounded() == value {
            return String(Int64(value))
        }
        return String(value)
    }

    nonisolated func formatProgress(_ value: Double, unit: Int64) -> String {
        guard value > 0 else { return "" }
        if unit == BookEntryProgressUnit.progress.rawValue {
            return formatPositiveDecimal(value)
        }
        return String(Int64(value))
    }

    nonisolated func insertChapters(from catalog: String, for bookId: Int64, createdAt: Int64, db: Database) throws {
        let titles = catalog
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for (index, title) in titles.enumerated() {
            var chapter = ChapterRecord(
                id: nil,
                bookId: bookId,
                parentId: 0,
                title: title,
                remark: "",
                chapterOrder: Int64(index + 1),
                isImport: 0,
                createdDate: createdAt,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try chapter.insert(db)
        }
    }

    nonisolated func insertReadStatusRecord(
        bookId: Int64,
        status: BookEntryReadingStatus,
        changedAt: Int64,
        createdAt: Int64,
        db: Database
    ) throws {
        var record = BookReadStatusRecordRecord(
            id: nil,
            bookId: bookId,
            readStatusId: status.rawValue,
            changedDate: changedAt,
            createdDate: createdAt,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try record.insert(db)
    }
}

private extension String {
    nonisolated var digitsOnly: String {
        filter(\.isNumber)
    }
}
