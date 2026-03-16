import Foundation
import GRDB

/**
 * [INPUT]: 依赖 DatabaseManager 提供本地数据库连接，依赖 BookRecord/ChapterRecord/GroupRecord/TagRecord/SourceRecord 等持久化实体
 * [OUTPUT]: 对外提供 BookEditorRepository（BookEditorRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层书籍录入仓储实现，统一封装录入选项、偏好和新增保存事务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍录入仓储实现，负责录入页加载、偏好持久化与保存新书事务。
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
}

private extension BookEditorRepository {
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
        // 过滤条件：仅保留 tag.type = 1 且 tag.is_deleted = 0，避免混入笔记标签。
        let sql = """
            SELECT id, name
            FROM tag
            WHERE type = 1 AND is_deleted = 0 AND user_id = ?
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

    nonisolated func isDuplicateBook(_ draft: BookEditorDraft, ownerId: Int64, db: Database) throws -> Bool {
        // SQL 目的：按 Android 规则判重，避免新增同一本书。
        // 过滤条件：精确匹配 name/author/translator/press/isbn/pub_date 六元组，且排除软删除记录。
        let sql = """
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
        let count = try Int.fetchOne(
            db,
            sql: sql,
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
                WHERE name = ? AND type = 1 AND is_deleted = 0 AND user_id = ?
                LIMIT 1
                """
            if let existing = try Int64.fetchOne(db, sql: querySQL, arguments: [tagName, ownerId]) {
                ids.append(existing)
                continue
            }

            let nextOrder = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(tag_order), -1) + 1 FROM tag WHERE type = 1 AND user_id = ?",
                arguments: [ownerId]
            )) ?? 0
            var record = TagRecord(
                id: nil,
                userId: ownerId,
                name: tagName,
                color: 0,
                tagOrder: nextOrder,
                type: 1,
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
