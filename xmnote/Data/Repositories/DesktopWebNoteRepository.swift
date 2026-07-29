/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 V44 note、book、chapter、tag、attach_image、sort 表与可注入毫秒时钟
 * [OUTPUT]: 对外提供 Android NoteService 书摘列表、筛选、排序设置、详情与写入基础能力
 * [POS]: Data 层网页书摘专用仓储；独立复刻 Android Web 路径，不让 XMNoteWeb 接触 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// WebTagDto 的 Data 层轻量投影。
nonisolated struct DesktopWebNoteTagSnapshot: Sendable, Equatable {
    let id: Int64
    let name: String
}

/// WebAttachImageDto 的 Data 层投影。
nonisolated struct DesktopWebNoteImageSnapshot: Sendable, Equatable {
    let id: Int64
    let url: String
}

/// WebBookSimpleDto 的 Data 层投影；封面代理留给 App Adapter。
nonisolated struct DesktopWebNoteBookSnapshot: Sendable, Equatable {
    let id: Int64
    let name: String
    let cover: String
    let author: String
    let press: String
}

/// WebBookNoteDto 共用的 Data 层投影。
nonisolated struct DesktopWebBookNoteSnapshot: Sendable, Equatable {
    let id: Int64
    let content: String
    let idea: String?
    let position: String?
    let positionUnit: Int
    let isIncludeTime: Bool
    let createdTime: Int64
    let updatedTime: Int64
    let chapter: DesktopWebChapterSnapshot?
    let tags: [DesktopWebNoteTagSnapshot]
    let images: [DesktopWebNoteImageSnapshot]
}

/// WebGlobalNoteDto 的 Data 层投影。
nonisolated struct DesktopWebGlobalNoteSnapshot: Sendable, Equatable {
    let note: DesktopWebBookNoteSnapshot
    let book: DesktopWebNoteBookSnapshot
}

/// 书内列表的章节计数。
nonisolated struct DesktopWebBookNoteChapterCountSnapshot: Sendable, Equatable {
    let chapterID: Int64
    let noteCount: Int
}

/// WebBookNotesPageDto 的 Data 层投影。
nonisolated struct DesktopWebBookNotesPageSnapshot: Sendable, Equatable {
    let items: [DesktopWebBookNoteSnapshot]
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
    let chapterNoteCounts: [DesktopWebBookNoteChapterCountSnapshot]
}

/// 全局书摘分页投影。
nonisolated struct DesktopWebGlobalNotesPageSnapshot: Sendable, Equatable {
    let items: [DesktopWebGlobalNoteSnapshot]
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
}

/// WebBookNoteTagFilterDto 的 Data 层投影。
nonisolated struct DesktopWebNoteTagFilterSnapshot: Sendable, Equatable {
    let id: Int64
    let name: String
    let noteCount: Int
    let section: String
}

/// WebBookNoteSortRuleDto 的 Data 层投影。
nonisolated struct DesktopWebNoteSortRuleSnapshot: Sendable, Equatable {
    let sortBy: String
    let sortOrder: String
}

/// Package 书内筛选到 Data 层的无框架输入。
nonisolated struct DesktopWebBookNoteFilterInput: Sendable, Equatable {
    let chapterID: Int64
    let tagID: Int64
    let tagIDs: [Int64]
    let tagMode: String
    let sortBy: String
    let sortOrder: String
}

/// Package 全局筛选到 Data 层的无框架输入。
nonisolated struct DesktopWebGlobalNoteFilterInput: Sendable, Equatable {
    let keyword: String
    let bookID: Int64
    let bookIDs: [Int64]
    let tagID: Int64
    let tagIDs: [Int64]
    let tagMode: String
    let sortBy: String
    let sortOrder: String
    let sortMode: String
    let excludeIDs: [Int64]
}

/// Package 创建书摘请求到 Data 层的无框架输入。
nonisolated struct DesktopWebNoteCreateInput: Sendable, Equatable {
    let bookID: Int64
    let chapterID: Int64?
    let content: String?
    let idea: String?
    let position: String?
    let tagIDs: [Int64]?
    let imageURLs: [String]?
    let uploadedTicketIDs: [String]?
    let createdTime: Int64?
}

/// Package 更新书摘请求到 Data 层的无框架输入。
nonisolated struct DesktopWebNoteUpdateInput: Sendable, Equatable {
    let bookID: Int64?
    let chapterID: Int64?
    let content: String?
    let idea: String?
    let position: String?
    let tagIDs: [Int64]?
    let imageURLs: [String]?
    let uploadedTicketIDs: [String]?
    let createdTime: Int64?
}

/// 合并草稿到 Data 层的无框架输入。
nonisolated struct DesktopWebNoteMergeDraftInput: Sendable, Equatable {
    let content: String?
    let idea: String?
    let position: String?
    let positionUnit: Int?
    let chapterID: Int64?
    let tagIDs: [Int64]?
    let imageURLs: [String]?
    let uploadedTicketIDs: [String]?
    let createdTime: Int64?
}

/// 合并请求到 Data 层的无框架输入。
nonisolated struct DesktopWebNoteMergeInput: Sendable, Equatable {
    let ids: [Int64]
    let contentOrderedIDs: [Int64]?
    let ideaOrderedIDs: [Int64]?
    let orderedIDs: [Int64]?
    let contentMergeRule: String?
    let ideaMergeRule: String?
    let merged: DesktopWebNoteMergeDraftInput?
}

/// WebNoteResultDto 的 Data 层写入结果。
nonisolated struct DesktopWebNoteResultSnapshot: Sendable, Equatable {
    let id: Int64
    let bookID: Int64
    let chapterID: Int64
    let content: String
    let idea: String?
    let position: String?
    let positionUnit: Int
    let createdTime: Int64
    let updatedTime: Int64
    let tags: [DesktopWebNoteTagSnapshot]
    let images: [DesktopWebNoteImageSnapshot]
}

/// 使用独立 SQL 与内存排序复刻 Android WebNoteRepository、NoteService 和 SortRepository。
nonisolated struct DesktopWebNoteRepository: Sendable {
    static let noTagFilter: Int64 = -1
    static let hasIdeaFilter: Int64 = -2
    static let hasImageFilter: Int64 = -3
    static let hasAnyTagFilter: Int64 = -4
    static let noteContentType: Int64 = 2
    static let ascCreated: Int64 = 1
    static let descCreated: Int64 = 2
    static let ascPosition: Int64 = 3
    static let descPosition: Int64 = 4

    let database: AppDatabase
    let chapterRepository: DesktopWebChapterRepository
    let currentTimeMillis: @Sendable () -> Int64
    let commitUploadedTickets: @Sendable ([String]?, [String]) throws -> Void

    /// 固定数据库与毫秒时钟；事务写入由 GRDB 原子提交，Android 非事务批量路径保持独立提交。
    init(
        database: AppDatabase,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        commitUploadedTickets: @escaping @Sendable ([String]?, [String]) throws -> Void = { _, _ in }
    ) {
        self.database = database
        self.currentTimeMillis = currentTimeMillis
        self.commitUploadedTickets = commitUploadedTickets
        chapterRepository = DesktopWebChapterRepository(
            database: database,
            currentTimeMillis: currentTimeMillis
        )
    }

    /// 读取有效书籍的筛选书摘，并复刻 App 章节分组及来源特化排序。
    func bookNotes(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        filter: DesktopWebBookNoteFilterInput
    ) async throws -> DesktopWebBookNotesPageSnapshot {
        try await requireActiveBook(bookID)
        let context = try await readContext(bookID: bookID)
        let filtered = filterBookNotes(context.notes, filter: filter, context: context)
        let sorted = sortBookNotes(filtered, filter: filter, context: context)
        let total = sorted.count
        let pageRecords = Self.page(sorted, page: page, pageSize: pageSize)
        let items = try await projectBookNotes(pageRecords, chapterRecords: context.chapters)
        let counts = Dictionary(grouping: filtered, by: \NoteRecord.chapterId)
            .map { DesktopWebBookNoteChapterCountSnapshot(chapterID: $0.key, noteCount: $0.value.count) }
            .sorted { $0.chapterID < $1.chapterID }
        return DesktopWebBookNotesPageSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: total,
            totalPages: Self.totalPages(total: total, pageSize: pageSize),
            chapterNoteCounts: counts
        )
    }

    /// 读取全局书摘；随机模式只从 items 排除 ID，total 故意统计未排除集合。
    func globalNotes(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalNoteFilterInput
    ) async throws -> DesktopWebGlobalNotesPageSnapshot {
        let base = try await activeGlobalNotes()
        let filteredForCount = try await filterGlobalNotes(base, filter: filter, includeExclusions: false)
        var filtered = try await filterGlobalNotes(base, filter: filter, includeExclusions: true)
        filtered = sortGlobalNotes(filtered, filter: filter)
        let pageRecords = Self.page(filtered, page: page, pageSize: pageSize)
        let items = try await projectGlobalNotes(pageRecords)
        return DesktopWebGlobalNotesPageSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: filteredForCount.count,
            totalPages: Self.totalPages(total: filteredForCount.count, pageSize: pageSize)
        )
    }

    /// 返回书内五个固定筛选项和实际使用的有效 note 标签。
    func bookNoteTagFilters(bookID: Int64) async throws -> [DesktopWebNoteTagFilterSnapshot] {
        try await requireActiveBook(bookID)
        return try await noteTagFilters(bookID: bookID)
    }

    /// 返回有效书籍范围内五个固定筛选项和实际使用的有效 note 标签。
    func globalNoteTagFilters() async throws -> [DesktopWebNoteTagFilterSnapshot] {
        try await noteTagFilters(bookID: nil)
    }

    /// 读取书籍的 note 排序规则；缺失时复刻微信读书范围字段驱动的默认值。
    func bookNoteSortRule(bookID: Int64) async throws -> DesktopWebNoteSortRuleSnapshot {
        try await requireActiveBook(bookID)
        let rule = try await sortRule(bookID: bookID)
        return Self.mapSortRule(rule)
    }

    /// 插入或更新 note 排序记录并回读；软删除旧行不会阻止插入新行。
    func updateBookNoteSortRule(
        bookID: Int64,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebNoteSortRuleSnapshot {
        try await requireActiveBook(bookID)
        let rule = Self.sortRule(sortBy: sortBy, sortOrder: sortOrder)
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：复刻 SortRepository.updateSortRuleInternal 的存在性分支。
            // 涉及表：sort。
            // 关键过滤：book_id、type=NOTE、is_deleted=0 决定插入或更新；更新语句故意不限制 is_deleted。
            // 时间字段：更新时写 updated_date 当前毫秒；新行 created_date 沿用 Android BaseEntity 构造时钟。
            // 副作用用途：PUT /books/{bookId}/notes/sort-rule。
            let activeCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sort WHERE book_id = ? AND type = ? AND is_deleted = 0",
                arguments: [bookID, Self.noteContentType]
            ) ?? 0
            if activeCount == 0 {
                var record = SortRecord()
                record.bookId = bookID
                record.type = Self.noteContentType
                record.order = rule
                record.createdDate = now
                try record.insert(db)
            } else {
                try db.execute(
                    sql: "UPDATE sort SET updated_date = ?, `order` = ? WHERE book_id = ? AND type = ?",
                    arguments: [now, rule, bookID, Self.noteContentType]
                )
            }
        }
        return Self.mapSortRule(try await sortRule(bookID: bookID))
    }

    /// 按 ID 返回有效书籍下的有效书摘。
    func note(id: Int64) async throws -> DesktopWebBookNoteSnapshot {
        let record = try await requireNoteFromActiveBook(id: id)
        let chapters = try await chapterRepository.allChapters(bookID: record.bookId)
        guard let snapshot = try await projectBookNotes([record], chapterRecords: chapters).first else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("笔记不存在: \(id)")
        }
        return snapshot
    }
}

nonisolated extension DesktopWebNoteRepository {
    struct ReadContext: Sendable {
        let notes: [NoteRecord]
        let chapters: [ChapterRecord]
        let relationTagIDs: [Int64: [Int64]]
        let displayTagIDs: [Int64: [Int64]]
        let imageCounts: [Int64: Int]
        let bookSource: Int64
        let includeTimeCount: Int
        let wereadRangeBlankCount: Int
    }

    /// 读取书内排序与筛选需要的稳定快照；查询不持有写事务。
    func readContext(bookID: Int64) async throws -> ReadContext {
        let notes = try await database.dbPool.read { db in
            // SQL 目的：读取单书全部有效书摘，作为 Android 内存筛选与 App 对齐排序输入。
            // 涉及表：note。
            // 关键过滤：book_id、is_deleted=0；按 id 升序稳定模拟 SQLite 无 ORDER 基础顺序。
            // 时间字段：created/updated 原样用于排序与响应。
            // 返回字段用途：GET /books/{bookId}/notes。
            try NoteRecord.fetchAll(
                db,
                sql: "SELECT * FROM note WHERE book_id = ? AND is_deleted = 0 ORDER BY id ASC",
                arguments: [bookID]
            )
        }
        let chapters = try await chapterRepository.allChapters(bookID: bookID)
        let relationTagIDs = try await activeTagRelationIDs(noteIDs: notes.compactMap(\.id))
        let displayTagIDs = try await displayTags(noteIDs: notes.compactMap(\.id)).mapValues { $0.map(\.id) }
        let imageCounts = try await activeImageCounts(noteIDs: notes.compactMap(\.id))
        let source = try await database.dbPool.read { db in
            // SQL 目的：读取书籍来源，驱动 Android NoteRepository 特化排序。
            // 涉及表：book。
            // 关键过滤：仅 book id；ActiveBookGuard 已在调用前校验。
            // 时间字段：无。
            // 返回字段用途：Kindle/微信读书/iReader 位置排序分支。
            try Int64.fetchOne(db, sql: "SELECT source_id FROM book WHERE id = ?", arguments: [bookID]) ?? 1
        }
        return ReadContext(
            notes: notes,
            chapters: chapters,
            relationTagIDs: relationTagIDs,
            displayTagIDs: displayTagIDs,
            imageCounts: imageCounts,
            bookSource: source,
            includeTimeCount: notes.filter { $0.includeTime == 1 }.count,
            wereadRangeBlankCount: notes.filter { Self.isKotlinBlank($0.wereadRange) }.count
        )
    }

    func filterBookNotes(
        _ notes: [NoteRecord],
        filter: DesktopWebBookNoteFilterInput,
        context: ReadContext
    ) -> [NoteRecord] {
        let chapterScope = filter.chapterID == 0
            ? nil
            : DesktopWebChapterRepository.collectDescendantIDs(
                records: context.chapters,
                rootIDs: [filter.chapterID]
            )
        let normalizedTagIDs = Self.distinctPositive(filter.tagIDs)
        return notes.filter { note in
            if let chapterScope, !chapterScope.contains(note.chapterId) { return false }
            let relationTagIDs = Set(context.relationTagIDs[note.id ?? 0] ?? [])
            let displayTagIDs = Set(context.displayTagIDs[note.id ?? 0] ?? [])
            switch filter.tagID {
            case Self.noTagFilter where !displayTagIDs.isEmpty: return false
            case Self.hasIdeaFilter where Self.isKotlinBlank(note.idea): return false
            case Self.hasImageFilter where (context.imageCounts[note.id ?? 0] ?? 0) == 0: return false
            case Self.hasAnyTagFilter where displayTagIDs.isEmpty: return false
            case let tagID where tagID > 0 && !relationTagIDs.contains(tagID): return false
            default: break
            }
            guard !normalizedTagIDs.isEmpty else { return true }
            let requested = Set(normalizedTagIDs)
            return filter.tagMode == "and"
                ? requested.isSubset(of: relationTagIDs)
                : !requested.isDisjoint(with: relationTagIDs)
        }
    }

    func sortBookNotes(
        _ notes: [NoteRecord],
        filter: DesktopWebBookNoteFilterInput,
        context: ReadContext
    ) -> [NoteRecord] {
        guard filter.sortBy != "modify_time" else {
            return Self.stableSorted(notes) {
                filter.sortOrder == "asc" ? $0.updatedDate < $1.updatedDate : $0.updatedDate > $1.updatedDate
            }
        }
        let rule = Self.sortRule(sortBy: filter.sortBy, sortOrder: filter.sortOrder)
        if filter.chapterID != 0 {
            return sortWithinChapter(notes, rule: rule, context: context)
        }
        let descending = rule != Self.ascCreated && rule != Self.ascPosition
        let chapterIDs = Self.flattenChapterIDs(context.chapters, descending: descending)
        let activeChapterIDs = Set(context.chapters.compactMap(\.id))
        var grouped = Dictionary(grouping: notes.filter { activeChapterIDs.contains($0.chapterId) }) {
            $0.chapterId
        }
        var result: [NoteRecord] = []
        for chapterID in chapterIDs {
            result.append(contentsOf: sortWithinChapter(grouped.removeValue(forKey: chapterID) ?? [], rule: rule, context: context))
        }
        let uncategorized = notes.filter { !activeChapterIDs.contains($0.chapterId) }
        result.append(contentsOf: sortWithinChapter(uncategorized, rule: rule, context: context))
        return result
    }

    func sortWithinChapter(_ notes: [NoteRecord], rule: Int64, context: ReadContext) -> [NoteRecord] {
        switch rule {
        case Self.ascCreated:
            if context.bookSource == 4 && context.includeTimeCount == 0 {
                return Self.stableSorted(notes) { ($0.id ?? 0) < ($1.id ?? 0) }
            }
            return Self.stableSorted(notes) { $0.createdDate < $1.createdDate }
        case Self.descCreated:
            if context.bookSource == 4 && context.includeTimeCount == 0 {
                return Self.stableSorted(notes) { ($0.id ?? 0) > ($1.id ?? 0) }
            }
            return Self.stableSorted(notes) { $0.createdDate > $1.createdDate }
        case Self.ascPosition:
            if context.bookSource == 24 {
                return Self.stableSorted(notes) { $0.position < $1.position }
            }
            if context.bookSource == 4 && context.wereadRangeBlankCount == 0 {
                return Self.stableSorted(notes) { Self.wereadRangeStart($0.wereadRange) < Self.wereadRangeStart($1.wereadRange) }
            }
            let usesPosition = notes.contains { Self.kotlinRound(Self.notePositionNumber($0.position)) != 0 }
            return usesPosition
                ? Self.stableSorted(notes) { Self.notePositionNumber($0.position) < Self.notePositionNumber($1.position) }
                : Self.stableSorted(notes) { ($0.id ?? 0) < ($1.id ?? 0) }
        default:
            if context.bookSource == 24 {
                // NOTE(Android App alignment): Android iReader 的“位置降序”仍按字符串升序，基线原样保留。
                return Self.stableSorted(notes) { $0.position < $1.position }
            }
            if context.bookSource == 4 && context.wereadRangeBlankCount == 0 {
                return Self.stableSorted(notes) { Self.wereadRangeStart($0.wereadRange) > Self.wereadRangeStart($1.wereadRange) }
            }
            let usesPosition = notes.contains { Self.kotlinRound(Self.notePositionNumber($0.position)) != 0 }
            return usesPosition
                ? Self.stableSorted(notes) { Self.notePositionNumber($0.position) > Self.notePositionNumber($1.position) }
                : Self.stableSorted(notes) { ($0.id ?? 0) > ($1.id ?? 0) }
        }
    }

    func activeGlobalNotes() async throws -> [NoteRecord] {
        try await database.dbPool.read { db in
            // SQL 目的：读取全局有效书籍中的有效书摘。
            // 涉及表：note INNER JOIN book。
            // 关键过滤：note/book is_deleted=0；不排除 book id 0，也不按 owner 过滤。
            // 时间字段：原样返回供动态排序。
            // 返回字段用途：GET /api/v1/notes 与全局筛选统计。
            try NoteRecord.fetchAll(
                db,
                sql: """
                    SELECT n.* FROM note n
                    INNER JOIN book b ON n.book_id = b.id
                    WHERE n.is_deleted = 0 AND b.is_deleted = 0
                    ORDER BY n.id ASC
                    """
            )
        }
    }

    func filterGlobalNotes(
        _ notes: [NoteRecord],
        filter: DesktopWebGlobalNoteFilterInput,
        includeExclusions: Bool
    ) async throws -> [NoteRecord] {
        let ids = notes.compactMap(\.id)
        let tagMap = try await activeTagRelationIDs(noteIDs: ids)
        let imageMap = try await activeImageCounts(noteIDs: ids)
        let normalizedBookIDs = !Self.distinctPositive(filter.bookIDs).isEmpty
            ? Self.distinctPositive(filter.bookIDs)
            : (filter.bookID > 0 ? [filter.bookID] : [])
        let bookSet = Set(normalizedBookIDs)
        let requestedTags = Set(Self.distinctPositive(filter.tagIDs))
        let exclusions = includeExclusions && filter.sortMode == "random"
            ? Set(Self.distinctPositive(filter.excludeIDs))
            : []
        let keyword = Self.kotlinTrimmed(filter.keyword)
        return notes.filter { note in
            let id = note.id ?? 0
            if !bookSet.isEmpty && !bookSet.contains(note.bookId) { return false }
            if !exclusions.isEmpty && exclusions.contains(id) { return false }
            if !keyword.isEmpty,
               !Self.sqliteLikeContains(note.content, keyword: keyword),
               !Self.sqliteLikeContains(note.idea, keyword: keyword) { return false }
            let noteTags = Set(tagMap[id] ?? [])
            switch filter.tagID {
            case Self.noTagFilter where !noteTags.isEmpty: return false
            case Self.hasIdeaFilter where Self.isKotlinBlank(note.idea): return false
            case Self.hasImageFilter where (imageMap[id] ?? 0) == 0: return false
            case Self.hasAnyTagFilter where noteTags.isEmpty: return false
            case let tagID where tagID > 0 && !noteTags.contains(tagID): return false
            default: break
            }
            guard !requestedTags.isEmpty else { return true }
            return filter.tagMode == "and"
                ? requestedTags.isSubset(of: noteTags)
                : !requestedTags.isDisjoint(with: noteTags)
        }
    }

    func sortGlobalNotes(
        _ notes: [NoteRecord],
        filter: DesktopWebGlobalNoteFilterInput
    ) -> [NoteRecord] {
        switch filter.sortMode {
        case "ordered":
            return Self.stableSorted(notes) {
                $0.bookId == $1.bookId ? ($0.id ?? 0) < ($1.id ?? 0) : $0.bookId > $1.bookId
            }
        case "random":
            return notes.shuffled()
        default:
            switch filter.sortBy {
            case "position":
                return Self.stableSorted(notes) {
                    filter.sortOrder == "asc" ? $0.position < $1.position : $0.position > $1.position
                }
            case "modify_time":
                return Self.stableSorted(notes) {
                    filter.sortOrder == "asc" ? $0.updatedDate < $1.updatedDate : $0.updatedDate > $1.updatedDate
                }
            default:
                return Self.stableSorted(notes) {
                    filter.sortOrder == "asc" ? $0.createdDate < $1.createdDate : $0.createdDate > $1.createdDate
                }
            }
        }
    }

    func projectBookNotes(
        _ notes: [NoteRecord],
        chapterRecords: [ChapterRecord],
        usesNullableParentTitle: Bool = false,
        parentTitleByID providedParentTitleByID: [Int64: String]? = nil
    ) async throws -> [DesktopWebBookNoteSnapshot] {
        guard !notes.isEmpty else { return [] }
        let noteIDs = notes.compactMap(\.id)
        let tags = try await displayTags(noteIDs: noteIDs)
        let images = try await displayImages(noteIDs: noteIDs)
        let chapterByID = Dictionary(uniqueKeysWithValues: chapterRecords.compactMap { record in
            record.id.map { ($0, record) }
        })
        let parentTitleByID: [Int64: String]
        if let providedParentTitleByID {
            parentTitleByID = providedParentTitleByID
        } else {
            parentTitleByID = try await activeParentTitles(for: chapterRecords)
        }
        return notes.map { note in
            let noteID = note.id ?? 0
            return DesktopWebBookNoteSnapshot(
                id: noteID,
                content: note.content,
                idea: Self.nonBlank(note.idea),
                position: Self.nonBlank(note.position),
                positionUnit: Int(note.positionUnit),
                isIncludeTime: note.includeTime == 1,
                createdTime: note.createdDate,
                updatedTime: note.updatedDate,
                chapter: chapterByID[note.chapterId].map { chapter in
                    let parentTitle = parentTitleByID[chapter.parentId]
                    return DesktopWebChapterSnapshot(
                        id: chapter.id ?? 0,
                        title: chapter.title,
                        parentTitle: Self.isKotlinBlank(parentTitle ?? "")
                            ? (usesNullableParentTitle ? nil : "")
                            : parentTitle,
                        parentID: chapter.parentId,
                        level: Int(chapter.chapterLevel),
                        pathTitles: DesktopWebChapterRepository.ancestorPath(
                            records: chapterRecords,
                            chapterID: chapter.id ?? 0
                        ).map(\.title),
                        isStarred: chapter.isStarred != 0
                    )
                },
                tags: tags[noteID] ?? [],
                images: images[noteID] ?? []
            )
        }
    }

    func projectGlobalNotes(_ notes: [NoteRecord]) async throws -> [DesktopWebGlobalNoteSnapshot] {
        guard !notes.isEmpty else { return [] }
        let bookIDs = Self.distinct(notes.map(\.bookId))
        let books = try await database.dbPool.read { db in
            try BookRecord.filter(bookIDs.contains(Column("id")) && Column("is_deleted") == 0).fetchAll(db)
        }
        let bookByID = Dictionary(uniqueKeysWithValues: books.compactMap { record in
            record.id.map { ($0, record) }
        })
        var chaptersByBook: [Int64: [ChapterRecord]] = [:]
        var parentTitlesByBook: [Int64: [Int64: String]] = [:]
        for bookID in bookIDs {
            let chapters = try await chapterRepository.allChapters(bookID: bookID)
            chaptersByBook[bookID] = chapters
            parentTitlesByBook[bookID] = try await activeParentTitles(for: chapters)
        }
        var result: [DesktopWebGlobalNoteSnapshot] = []
        for note in notes {
            guard let book = bookByID[note.bookId], let bookID = book.id else { continue }
            let projected = try await projectBookNotes(
                [note],
                chapterRecords: chaptersByBook[note.bookId] ?? [],
                usesNullableParentTitle: true,
                parentTitleByID: parentTitlesByBook[note.bookId] ?? [:]
            )[0]
            result.append(
                DesktopWebGlobalNoteSnapshot(
                    note: projected,
                    book: DesktopWebNoteBookSnapshot(
                        id: bookID,
                        name: book.name,
                        cover: book.cover,
                        author: book.author,
                        press: book.press
                    )
                )
            )
        }
        return result
    }

    /// 按 Android LEFT JOIN 读取有效父章节；包含 `id=0` 占位行，因此根章节会暴露其历史标题。
    private func activeParentTitles(
        for chapters: [ChapterRecord]
    ) async throws -> [Int64: String] {
        let parentIDs = Self.distinct(chapters.map(\.parentId))
        guard !parentIDs.isEmpty else { return [:] }
        let parents = try await database.dbPool.read { db in
            // SQL 目的：复刻 WebNoteDao.batchQueryChaptersWithParent 的父章节 LEFT JOIN。
            // 涉及表：chapter 自关联，按目标章节的 parent_id 读取有效父行。
            // 关键过滤：父章节 id 位于当前章节 parent_id 集合且 is_deleted=0；保留 id=0 占位行。
            // 时间字段：不涉及。
            // 返回字段用途：书内/全局书摘响应 chapter.parentTitle，包括 Android 历史占位标题。
            try ChapterRecord
                .filter(parentIDs.contains(Column("id")) && Column("is_deleted") == 0)
                .fetchAll(db)
        }
        // NOTE(ANDROID-WEB-086): Android 会把根章节的 id=0 占位标题 `empty empty` 暴露给 Web 客户端。
        return Dictionary(uniqueKeysWithValues: parents.compactMap { parent in
            parent.id.map { ($0, parent.title) }
        })
    }

    func noteTagFilters(bookID: Int64?) async throws -> [DesktopWebNoteTagFilterSnapshot] {
        let notes = bookID == nil
            ? try await activeGlobalNotes()
            : try await database.dbPool.read { db in
                // SQL 目的：读取单书有效书摘，作为书内标签筛选统计的全集。
                // 涉及表：note。
                // 关键过滤：book_id 精确匹配且 is_deleted=0；按 id 稳定返回。
                // 时间字段：不转换，记录仅用于内容、关系与图片计数。
                // 返回字段用途：GET /books/{bookId}/note-tags 的五个默认筛选项与自定义标签。
                try NoteRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM note WHERE book_id = ? AND is_deleted = 0 ORDER BY id ASC",
                    arguments: [bookID!]
                )
            }
        let ids = notes.compactMap(\.id)
        let relationTags = try await activeTagRelationIDs(noteIDs: ids)
        let imageCounts = try await activeImageCounts(noteIDs: ids)
        let defaults = [
            DesktopWebNoteTagFilterSnapshot(id: 0, name: "全部书摘", noteCount: notes.count, section: "default"),
            DesktopWebNoteTagFilterSnapshot(
                id: Self.noTagFilter,
                name: "无标签",
                noteCount: notes.filter { (relationTags[$0.id ?? 0] ?? []).isEmpty }.count,
                section: "default"
            ),
            DesktopWebNoteTagFilterSnapshot(
                id: Self.hasAnyTagFilter,
                name: "有标签",
                noteCount: notes.filter { !(relationTags[$0.id ?? 0] ?? []).isEmpty }.count,
                section: "default"
            ),
            DesktopWebNoteTagFilterSnapshot(
                id: Self.hasIdeaFilter,
                name: "有想法",
                noteCount: notes.filter { !Self.isSQLiteTrimBlank($0.idea) }.count,
                section: "default"
            ),
            DesktopWebNoteTagFilterSnapshot(
                id: Self.hasImageFilter,
                name: "有图片",
                noteCount: notes.filter { (imageCounts[$0.id ?? 0] ?? 0) > 0 }.count,
                section: "default"
            )
        ]
        let custom = try await customTagFilters(noteIDs: ids)
        return defaults + custom
    }

    func customTagFilters(noteIDs: [Int64]) async throws -> [DesktopWebNoteTagFilterSnapshot] {
        guard !noteIDs.isEmpty else { return [] }
        return try await database.dbPool.read { db in
            // SQL 目的：统计当前范围实际使用的有效 note 标签。
            // 涉及表：tag、tag_note、note。
            // 关键过滤：关系/标签/书摘有效、tag.type=1、note id 位于当前范围；不按 tag owner 过滤。
            // 时间字段：无；按 tag_order、tag.id 升序。
            // 返回字段用途：书内与全局标签筛选器 custom 区。
            let placeholders = Array(repeating: "?", count: noteIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id, t.name, COUNT(DISTINCT n.id) AS note_count
                    FROM tag t
                    INNER JOIN tag_note tn ON tn.tag_id = t.id AND tn.is_deleted = 0
                    INNER JOIN note n ON n.id = tn.note_id AND n.is_deleted = 0
                    WHERE n.id IN (\(placeholders)) AND t.is_deleted = 0 AND t.type = 1
                    GROUP BY t.id, t.name, t.tag_order
                    ORDER BY t.tag_order ASC, t.id ASC
                    """,
                arguments: StatementArguments(noteIDs)
            )
            return rows.map { row in
                DesktopWebNoteTagFilterSnapshot(
                    id: row["id"],
                    name: Self.kotlinTrimmed(row["name"] as String? ?? ""),
                    noteCount: row["note_count"],
                    section: "custom"
                )
            }
        }
    }

    func sortRule(bookID: Int64) async throws -> Int64 {
        if let saved = try await database.dbPool.read({ db in
            // SQL 目的：读取书籍有效 note 排序记录。
            // 涉及表：sort。
            // 关键过滤：book_id、type=2、is_deleted=0；Room 未规定多行次序。
            // 时间字段：无。
            // 返回字段用途：GET/PUT sort-rule 回读。
            try Int64.fetchOne(
                db,
                sql: "SELECT `order` FROM sort WHERE book_id = ? AND type = ? AND is_deleted = 0 LIMIT 1",
                arguments: [bookID, Self.noteContentType]
            )
        }) {
            return saved
        }
        let blankRangeCount = try await database.dbPool.read { db in
            // SQL 目的：复刻 SortRepository 缺省规则对微信读书 range 的判断。
            // 涉及表：note。
            // 关键过滤：book_id、is_deleted=0，统计 Kotlin isBlank 等价范围字段。
            // 时间字段：无。
            // 返回字段用途：零条空 range 时默认位置升序，否则创建时间升序。
            let notes = try NoteRecord.fetchAll(
                db,
                sql: "SELECT * FROM note WHERE book_id = ? AND is_deleted = 0",
                arguments: [bookID]
            )
            return notes.map(\.wereadRange).filter(Self.isKotlinBlank).count
        }
        return blankRangeCount == 0 ? Self.ascPosition : Self.ascCreated
    }

    func activeTagRelationIDs(noteIDs: [Int64]) async throws -> [Int64: [Int64]] {
        guard !noteIDs.isEmpty else { return [:] }
        return try await database.dbPool.read { db in
            // SQL 目的：读取书摘当前可见的有效标签关系，统一正 ID、特殊筛选和计数口径。
            // 涉及表：tag_note INNER JOIN tag。
            // 关键过滤：关系和标签主记录均有效，note_id 位于当前结果集；按关系主键稳定排序。
            // 时间字段：无。
            // 返回字段用途：书内/全局标签筛选及筛选项计数。
            let placeholders = Array(repeating: "?", count: noteIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT tn.note_id, tn.tag_id
                    FROM tag_note tn
                    INNER JOIN tag t ON t.id = tn.tag_id
                    WHERE tn.note_id IN (\(placeholders))
                      AND tn.is_deleted = 0
                      AND t.is_deleted = 0
                    ORDER BY tn.id ASC
                    """,
                arguments: StatementArguments(noteIDs)
            )
            return Dictionary(grouping: rows, by: { $0["note_id"] as Int64 }).mapValues { values in
                values.map { $0["tag_id"] as Int64 }
            }
        }
    }

    func activeImageCounts(noteIDs: [Int64]) async throws -> [Int64: Int] {
        guard !noteIDs.isEmpty else { return [:] }
        return try await database.dbPool.read { db in
            // SQL 目的：批量统计每条书摘仍有效的附图数量。
            // 涉及表：attach_image。
            // 关键过滤：note_id 在当前结果集且 is_deleted=0；按 note_id 分组。
            // 时间字段：无。
            // 返回字段用途：有图片筛选与筛选项计数。
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT note_id, COUNT(*) AS image_count FROM attach_image WHERE note_id IN (\(Array(repeating: "?", count: noteIDs.count).joined(separator: ","))) AND is_deleted = 0 GROUP BY note_id",
                arguments: StatementArguments(noteIDs)
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["note_id"] as Int64, $0["image_count"] as Int) })
        }
    }

    func displayTags(noteIDs: [Int64]) async throws -> [Int64: [DesktopWebNoteTagSnapshot]] {
        guard !noteIDs.isEmpty else { return [:] }
        return try await database.dbPool.read { db in
            // SQL 目的：读取响应展示用的有效书摘标签。
            // 涉及表：tag_note INNER JOIN tag。
            // 关键过滤：关系和 tag 有效、note id 位于结果集；不按 owner/type 过滤。
            // 时间字段：无；按关系 id 模拟 Room 表扫描顺序。
            // 返回字段用途：列表、详情和写响应 tags。
            let placeholders = Array(repeating: "?", count: noteIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT tn.note_id, t.id, t.name
                    FROM tag_note tn
                    INNER JOIN tag t ON tn.tag_id = t.id
                    WHERE tn.note_id IN (\(placeholders)) AND tn.is_deleted = 0 AND t.is_deleted = 0
                    ORDER BY tn.id ASC
                    """,
                arguments: StatementArguments(noteIDs)
            )
            return Dictionary(grouping: rows, by: { $0["note_id"] as Int64 }).mapValues { values in
                values.map { DesktopWebNoteTagSnapshot(id: $0["id"], name: $0["name"] as String? ?? "") }
            }
        }
    }

    func displayImages(noteIDs: [Int64]) async throws -> [Int64: [DesktopWebNoteImageSnapshot]] {
        guard !noteIDs.isEmpty else { return [:] }
        return try await database.dbPool.read { db in
            let records = try AttachImageRecord
                .filter(noteIDs.contains(Column("note_id")) && Column("is_deleted") == 0)
                .order(Column("id").asc)
                .fetchAll(db)
            return Dictionary(grouping: records, by: \.noteId).mapValues { records in
                records.map { DesktopWebNoteImageSnapshot(id: $0.id ?? 0, url: $0.imageUrl) }
            }
        }
    }

    func requireActiveBook(_ bookID: Int64) async throws {
        do {
            try await chapterRepository.requireActiveBook(bookID)
        } catch {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(bookID)")
        }
    }

    func noteRecord(id: Int64) async throws -> NoteRecord? {
        try await database.dbPool.read { db in
            // SQL 目的：按主键读取一条有效书摘。
            // 涉及表：note。
            // 关键过滤：id 精确匹配且 is_deleted=0；所属书籍有效性由调用方按业务入口校验。
            // 时间字段：原样返回。
            // 返回字段用途：详情、更新、删除与批量写前校验。
            try NoteRecord.fetchOne(
                db,
                sql: "SELECT * FROM note WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            )
        }
    }

    /// 读取有效书籍下的有效书摘；直接 ID 路径不得访问已删除书籍遗留内容。
    func requireNoteFromActiveBook(id: Int64) async throws -> NoteRecord {
        guard let record = try await noteRecord(id: id),
              (try? await activeBook(id: record.bookId, message: "笔记不存在: \(id)")) != nil else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("笔记不存在: \(id)")
        }
        return record
    }

    static func mapSortRule(_ rule: Int64) -> DesktopWebNoteSortRuleSnapshot {
        switch rule {
        case ascCreated: return DesktopWebNoteSortRuleSnapshot(sortBy: "create_time", sortOrder: "asc")
        case descCreated: return DesktopWebNoteSortRuleSnapshot(sortBy: "create_time", sortOrder: "desc")
        case ascPosition: return DesktopWebNoteSortRuleSnapshot(sortBy: "position", sortOrder: "asc")
        case descPosition: return DesktopWebNoteSortRuleSnapshot(sortBy: "position", sortOrder: "desc")
        default: return DesktopWebNoteSortRuleSnapshot(sortBy: "create_time", sortOrder: "asc")
        }
    }

    static func sortRule(sortBy: String, sortOrder: String) -> Int64 {
        sortBy == "position"
            ? (sortOrder == "asc" ? ascPosition : descPosition)
            : (sortOrder == "asc" ? ascCreated : descCreated)
    }

    static func flattenChapterIDs(_ records: [ChapterRecord], descending: Bool) -> [Int64] {
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.id.map { ($0, record) }
        })
        let children = Dictionary(grouping: records, by: \.parentId)
        let comparator: (ChapterRecord, ChapterRecord) -> Bool = { lhs, rhs in
            if lhs.chapterOrder != rhs.chapterOrder {
                return descending ? lhs.chapterOrder > rhs.chapterOrder : lhs.chapterOrder < rhs.chapterOrder
            }
            return descending ? (lhs.id ?? 0) > (rhs.id ?? 0) : (lhs.id ?? 0) < (rhs.id ?? 0)
        }
        let roots = records
            .filter { $0.parentId == 0 || byID[$0.parentId] == nil }
            .sorted(by: comparator)
        var result: [Int64] = []
        func visit(_ record: ChapterRecord, visited: Set<Int64>) {
            guard let id = record.id else { return }
            result.append(id)
            guard !visited.contains(id) else { return }
            for child in (children[id] ?? []).sorted(by: comparator) {
                visit(child, visited: visited.union([id]))
            }
        }
        roots.forEach { visit($0, visited: []) }
        return result
    }

    static func stableSorted<T>(_ values: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        values.enumerated().sorted { lhs, rhs in
            if areInIncreasingOrder(lhs.element, rhs.element) { return true }
            if areInIncreasingOrder(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func page<T>(_ values: [T], page: Int, pageSize: Int) -> [T] {
        let offset = (page - 1).multipliedReportingOverflow(by: pageSize)
        guard !offset.overflow, offset.partialValue < values.count else { return [] }
        let end = offset.partialValue.addingReportingOverflow(pageSize)
        let upperBound = end.overflow ? values.count : min(values.count, end.partialValue)
        return Array(values[offset.partialValue..<upperBound])
    }

    static func totalPages(total: Int, pageSize: Int) -> Int {
        guard total > 0 else { return 0 }
        return total / pageSize + (total % pageSize == 0 ? 0 : 1)
    }

    static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func distinctPositive(_ values: [Int64]) -> [Int64] {
        distinct(values).filter { $0 > 0 }
    }

    static func nonBlank(_ value: String) -> String? {
        isKotlinBlank(value) ? nil : value
    }

    static func notePositionNumber(_ value: String) -> Double {
        var token = value
        if value.contains("-") {
            token = value.hasPrefix("#") ? String(value.dropFirst()).split(separator: "-").first.map(String.init) ?? "" : value.split(separator: "-").first.map(String.init) ?? ""
        }
        return Double(token) ?? 0
    }

    static func wereadRangeStart(_ value: String) -> Int {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return 0 }
        return Int(parts[0]) ?? 0
    }

    static func kotlinRound(_ value: Double) -> Int {
        guard value.isFinite else { return value.sign == .minus ? Int.min : Int.max }
        return Int(floor(value + 0.5))
    }

    /// 复刻 SQLite LIKE 的 ASCII 不区分大小写与 `%`/`_` 通配语义，并以迭代状态机避免长书摘搜索递归溢出。
    static func sqliteLikeContains(_ value: String, keyword: String) -> Bool {
        let pattern = "%\(keyword)%"
        let valueScalars = value.unicodeScalars.map(asciiFold)
        let patternScalars = pattern.unicodeScalars.map(asciiFold)
        var previous = [Bool](repeating: false, count: valueScalars.count + 1)
        previous[0] = true

        for patternScalar in patternScalars {
            var current = [Bool](repeating: false, count: valueScalars.count + 1)
            if patternScalar.value == 0x25 {
                current[0] = previous[0]
                for valueIndex in valueScalars.indices {
                    current[valueIndex + 1] = previous[valueIndex + 1] || current[valueIndex]
                }
            } else {
                for valueIndex in valueScalars.indices {
                    current[valueIndex + 1] = previous[valueIndex]
                        && (patternScalar.value == 0x5F || patternScalar == valueScalars[valueIndex])
                }
            }
            previous = current
        }
        return previous[valueScalars.count]
    }

    static func asciiFold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard (0x41...0x5A).contains(scalar.value),
              let folded = Unicode.Scalar(scalar.value + 0x20) else { return scalar }
        return folded
    }

    static func isSQLiteTrimBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty
    }

    static func isKotlinBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy(isKotlinWhitespace)
    }

    static func kotlinTrimmed(_ value: String) -> String {
        let scalars = value.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isKotlinWhitespace(scalars[start]) { start = scalars.index(after: start) }
        while start < end {
            let previous = scalars.index(before: end)
            guard isKotlinWhitespace(scalars[previous]) else { break }
            end = previous
        }
        return String(scalars[start..<end])
    }

    static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }
}
