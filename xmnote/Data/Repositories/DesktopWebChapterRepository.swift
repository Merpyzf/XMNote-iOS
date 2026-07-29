/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 V44 book、chapter、note 表与可注入毫秒时钟
 * [OUTPUT]: 对外提供 Android ChapterService 本地章节查询及写入基础语义
 * [POS]: Data 层网页章节专用仓储；独立复刻 Android Web 路径，不让 XMNoteWeb 接触 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// WebChapterFullDto 的 Data 层递归投影。
nonisolated struct DesktopWebChapterFullSnapshot: Sendable, Equatable {
    let id: Int64
    let title: String
    let order: Int
    let noteCount: Int
    let children: [DesktopWebChapterFullSnapshot]
    let parentID: Int64
    let level: Int
    let pathTitles: [String]
    let directNoteCount: Int
    let descendantNoteCount: Int
    let isStarred: Bool
}

/// WebChapterDto 的 Data 层轻量投影。
nonisolated struct DesktopWebChapterSnapshot: Sendable, Equatable {
    let id: Int64
    let title: String
    let parentTitle: String?
    let parentID: Int64
    let level: Int
    let pathTitles: [String]
    let isStarred: Bool
}

/// WebBookSimpleDto 的 Data 层章节分组书籍投影。
nonisolated struct DesktopWebChapterBookSnapshot: Sendable, Equatable {
    let id: Int64
    let name: String
    let cover: String
    let author: String
    let press: String
}

/// WebStarredChapterDto 的 Data 层投影。
nonisolated struct DesktopWebStarredChapterSnapshot: Sendable, Equatable {
    let id: Int64
    let title: String
    let parentTitle: String?
    let parentID: Int64
    let level: Int
    let pathTitles: [String]
    let order: Int
    let noteCount: Int
    let directNoteCount: Int
    let descendantNoteCount: Int
    let updatedTime: Int64
    let ancestorIDs: [Int64]
    let isStarred: Bool
}

/// WebStarredChapterGroupDto 的 Data 层投影。
nonisolated struct DesktopWebStarredChapterGroupSnapshot: Sendable, Equatable {
    let book: DesktopWebChapterBookSnapshot
    let chapters: [DesktopWebStarredChapterSnapshot]
    let chapterCount: Int
    let noteCount: Int
    let latestUpdatedTime: Int64
}

/// WebChapterResultDto 的 Data 层写入结果。
nonisolated struct DesktopWebChapterResultSnapshot: Sendable, Equatable {
    let id: Int64
    let title: String
    let parentID: Int64
    let order: Int
}

/// 使用独立 SQL 复刻 Android WebChapterRepository 与 ChapterTreeHelper。
nonisolated struct DesktopWebChapterRepository: Sendable {
    private struct LastUsedRow: Sendable {
        let record: ChapterRecord
        let parentTitle: String?
    }

    static let maxDepth = 5
    static let pathSeparator = " / "

    let database: AppDatabase
    let currentTimeMillis: @Sendable () -> Int64

    /// 固定数据库与毫秒时钟；单事务操作由 GRDB 原子提交，多阶段写入保留 Android 原有提交边界。
    init(
        database: AppDatabase,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.database = database
        self.currentTimeMillis = currentTimeMillis
    }

    /// 返回有效书籍的章节树；孤儿章节作为根，循环章节与 Android 一样不会出现在树中。
    func chapters(bookID: Int64) async throws -> [DesktopWebChapterFullSnapshot] {
        try await requireActiveBook(bookID)
        let records = try await allChapters(bookID: bookID)
        guard !records.isEmpty else { return [] }
        let noteCounts = try await directNoteCounts(ids: records.compactMap(\.id))
        return Self.fullTree(records: records, noteCounts: noteCounts)
    }

    /// 按最新书摘 created_date 返回最近使用章节，并从当前有效树重建标题路径。
    func lastUsedChapter(bookID: Int64) async throws -> DesktopWebChapterSnapshot? {
        try await requireActiveBook(bookID)
        let row = try await database.dbPool.read { db -> LastUsedRow? in
            // SQL 目的：复刻 WebChapterDao.queryLastUsedChapter，读取书籍最新有效书摘关联章节。
            // 涉及表：note INNER JOIN chapter，LEFT JOIN 父 chapter。
            // 关键过滤：章节与书摘有效、chapter.id/chapter_id 非 0、限定 book_id；父章节仅在有效时返回标题。
            // 时间字段：只按 note.created_date 毫秒值倒序，保持 Android 未增加并列次序的行为。
            // 返回字段用途：GET /api/v1/books/{bookId}/chapters/last-used。
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT c.*, p.title AS parent_title
                    FROM note n
                    INNER JOIN chapter c ON n.chapter_id = c.id
                    LEFT JOIN chapter p ON c.parent_id = p.id AND p.is_deleted = 0
                    WHERE c.id != 0
                      AND c.book_id = ?
                      AND c.is_deleted = 0
                      AND n.chapter_id != 0
                      AND n.is_deleted = 0
                    ORDER BY n.created_date DESC
                    LIMIT 1
                    """,
                arguments: [bookID]
            ) else { return nil }
            return try LastUsedRow(
                record: ChapterRecord(row: row),
                parentTitle: row["parent_title"]
            )
        }
        guard let row else { return nil }
        let record = row.record
        let records = try await allChapters(bookID: bookID)
        return DesktopWebChapterSnapshot(
            id: record.id ?? 0,
            title: record.title.trimmingCharacters(in: .whitespacesAndNewlines),
            parentTitle: Self.nonBlankTrimmed(row.parentTitle),
            parentID: record.parentId,
            level: Int(record.chapterLevel),
            pathTitles: Self.ancestorPath(records: records, chapterID: record.id ?? 0).map(\.title),
            isStarred: record.isStarred != 0
        )
    }

    /// 按有效书籍聚合所有星标章节及其子树书摘数量，再按最近更新时间倒序分组。
    func starredChapterGroups() async throws -> [DesktopWebStarredChapterGroupSnapshot] {
        let starred = try await database.dbPool.read { db in
            // SQL 目的：复刻 WebChapterDao.queryStarredChapters，发现存在星标的书籍。
            // 涉及表：chapter。
            // 关键过滤：id != 0、is_starred = 1、is_deleted = 0；不按 book 或 user owner 过滤。
            // 时间字段：updated_date 毫秒值倒序。
            // 返回字段用途：确定星标分组候选书籍。
            try ChapterRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM chapter
                    WHERE id != 0 AND is_starred = 1 AND is_deleted = 0
                    ORDER BY updated_date DESC
                    """
            )
        }
        guard !starred.isEmpty else { return [] }
        let bookIDs = Self.distinct(starred.map(\.bookId))
        let books = try await activeBooks(ids: bookIDs)
        guard !books.isEmpty else { return [] }

        var groups: [DesktopWebStarredChapterGroupSnapshot] = []
        for book in books {
            guard let bookID = book.id else { continue }
            let records = try await allChapters(bookID: bookID)
            let noteCounts = try await directNoteCounts(ids: records.compactMap(\.id))
            let fullRoots = Self.fullTree(records: records, noteCounts: noteCounts)
            let flat = Self.flatten(fullRoots)
            let starredChapters = flat.filter(\.isStarred)
            guard !starredChapters.isEmpty else { continue }
            let chapterByID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
                record.id.map { ($0, record) }
            })
            let starredScope = Self.collectDescendantIDs(
                records: records,
                rootIDs: starredChapters.map(\.id)
            )
            let items = starredChapters.map { chapter in
                let record = chapterByID[chapter.id]
                let ancestors = Self.ancestorPath(records: records, chapterID: chapter.id)
                return DesktopWebStarredChapterSnapshot(
                    id: chapter.id,
                    title: chapter.title,
                    parentTitle: chapter.pathTitles.dropLast().last,
                    parentID: chapter.parentID,
                    level: chapter.level,
                    pathTitles: chapter.pathTitles,
                    order: chapter.order,
                    noteCount: chapter.noteCount,
                    directNoteCount: chapter.directNoteCount,
                    descendantNoteCount: chapter.descendantNoteCount,
                    updatedTime: record?.updatedDate ?? 0,
                    ancestorIDs: ancestors.dropLast().compactMap(\.id),
                    isStarred: true
                )
            }
            groups.append(
                DesktopWebStarredChapterGroupSnapshot(
                    book: DesktopWebChapterBookSnapshot(
                        id: bookID,
                        name: book.name.trimmingCharacters(in: .whitespacesAndNewlines),
                        cover: book.cover,
                        author: book.author,
                        press: book.press
                    ),
                    chapters: items,
                    chapterCount: items.count,
                    noteCount: starredScope.reduce(0) { $0 + (noteCounts[$1] ?? 0) },
                    latestUpdatedTime: items.map(\.updatedTime).max() ?? 0
                )
            )
        }
        return groups.sorted { $0.latestUpdatedTime > $1.latestUpdatedTime }
    }
}

nonisolated extension DesktopWebChapterRepository {
    /// 查询单书全部有效非占位章节，排序与 Android WebChapterDao 一致。
    func allChapters(bookID: Int64) async throws -> [ChapterRecord] {
        try await database.dbPool.read { db in
            // SQL 目的：读取章节树的全部有效节点。
            // 涉及表：chapter。
            // 关键过滤：id != 0、book_id 精确匹配、is_deleted = 0；不按 user owner 过滤。
            // 时间字段：无；排序按 parent_id、chapter_order，保持 Room 查询顺序。
            // 返回字段用途：树构建、路径、层级、后代与写前校验。
            try ChapterRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM chapter
                    WHERE id != 0 AND book_id = ? AND is_deleted = 0
                    ORDER BY parent_id ASC, chapter_order ASC
                    """,
                arguments: [bookID]
            )
        }
    }

    /// 校验有效非占位书籍；创建、列表、最近章节和星标写入共用这一边界。
    func requireActiveBook(_ bookID: Int64) async throws {
        let exists = try await database.dbPool.read { db in
            // SQL 目的：复刻 ActiveBookGuard，确认书籍存在且未软删除。
            // 涉及表：book。
            // 关键过滤：id 精确匹配且 id != 0、is_deleted = 0；不按 user_id 过滤。
            // 时间字段：无。
            // 返回字段用途：章节 API 前置业务校验。
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM book WHERE id = ? AND id != 0 AND is_deleted = 0)",
                arguments: [bookID]
            ) ?? false
        }
        guard exists else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(bookID)")
        }
    }

    /// 按输入 ID 读取有效章节，结果随后由调用方恢复请求顺序。
    func chapters(ids: [Int64]) async throws -> [ChapterRecord] {
        guard !ids.isEmpty else { return [] }
        return try await database.dbPool.read { db in
            // SQL 目的：批量读取有效章节以校验排序与移动请求。
            // 涉及表：chapter。
            // 关键过滤：id 位于请求集合且 is_deleted = 0；Android 不排除 id 0，但调用方通常先要求正数。
            // 时间字段：无。
            // 返回字段用途：缺失、跨书籍和父子归属校验。
            try ChapterRecord
                .filter(ids.contains(Column("id")) && Column("is_deleted") == 0)
                .fetchAll(db)
        }
    }

    /// 按 ID 读取有效章节；故意不校验所属书籍是否仍有效。
    func chapter(id: Int64) async throws -> ChapterRecord? {
        try await database.dbPool.read { db in
            // SQL 目的：复刻 WebChapterDao.findById。
            // 涉及表：chapter。
            // 关键过滤：仅 id 与 is_deleted；故意不连接有效 book。
            // 时间字段：无。
            // 返回字段用途：章节更新、删除、排序父节点与移动。
            try ChapterRecord.fetchOne(
                db,
                sql: "SELECT * FROM chapter WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            )
        }
    }

    /// 按章节 ID 汇总有效书摘直接数量。
    func directNoteCounts(ids: [Int64]) async throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        return try await database.dbPool.read { db in
            // SQL 目的：复刻 WebChapterDao.batchQueryNoteCount。
            // 涉及表：note。
            // 关键过滤：chapter_id 位于有效章节集合且 note.is_deleted = 0；不校验书籍 owner。
            // 时间字段：无。
            // 返回字段用途：直接书摘数与递归后代汇总。
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT chapter_id, COUNT(*) AS note_count
                    FROM note
                    WHERE chapter_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                      AND is_deleted = 0
                    GROUP BY chapter_id
                    """,
                arguments: StatementArguments(ids)
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["chapter_id"] as Int64, Int(row["note_count"] as Int64))
            })
        }
    }

    /// 读取有效书籍；SQLite IN 的原始结果顺序用于复刻 Android 未显式排序的查询。
    func activeBooks(ids: [Int64]) async throws -> [BookRecord] {
        guard !ids.isEmpty else { return [] }
        return try await database.dbPool.read { db in
            // SQL 目的：复刻 WebBookDao.queryBooksByIds，为星标章节分组加载有效书籍。
            // 涉及表：book。
            // 关键过滤：id 位于星标章节书籍集合且 is_deleted = 0；故意不排除跨 owner 数据。
            // 时间字段：无；Android SQL 未声明排序，此处同样不增加 ORDER BY。
            // 返回字段用途：WebBookSimpleDto 分组头。
            try BookRecord
                .filter(ids.contains(Column("id")) && Column("is_deleted") == 0)
                .fetchAll(db)
        }
    }
}

nonisolated extension DesktopWebChapterRepository {
    static func fullTree(
        records: [ChapterRecord],
        noteCounts: [Int64: Int]
    ) -> [DesktopWebChapterFullSnapshot] {
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.id.map { ($0, record) }
        })
        let children = Dictionary(grouping: records, by: \.parentId)
        let roots = records.filter { record in
            record.parentId == 0 || byID[record.parentId] == nil
        }.sorted(by: chapterOrder)

        func build(
            _ record: ChapterRecord,
            level: Int,
            path: [String],
            visited: Set<Int64>
        ) -> DesktopWebChapterFullSnapshot {
            let id = record.id ?? 0
            let childRecords = visited.contains(id)
                ? []
                : (children[id] ?? []).sorted(by: chapterOrder)
            let childSnapshots = childRecords.map { child in
                build(
                    child,
                    level: level + 1,
                    path: path + [child.title],
                    visited: visited.union([id])
                )
            }
            let direct = noteCounts[id] ?? 0
            let descendant = direct + childSnapshots.reduce(0) { $0 + $1.descendantNoteCount }
            return DesktopWebChapterFullSnapshot(
                id: id,
                title: record.title.trimmingCharacters(in: .whitespacesAndNewlines),
                order: Int(Int32(truncatingIfNeeded: record.chapterOrder)),
                noteCount: direct,
                children: childSnapshots,
                parentID: record.parentId,
                level: level,
                pathTitles: path,
                directNoteCount: direct,
                descendantNoteCount: descendant,
                isStarred: record.isStarred != 0
            )
        }

        return roots.map { root in
            build(root, level: 1, path: [root.title], visited: [])
        }
    }

    static func chapterOrder(_ lhs: ChapterRecord, _ rhs: ChapterRecord) -> Bool {
        if lhs.chapterOrder != rhs.chapterOrder { return lhs.chapterOrder < rhs.chapterOrder }
        return (lhs.id ?? 0) < (rhs.id ?? 0)
    }

    static func ancestorPath(records: [ChapterRecord], chapterID: Int64) -> [ChapterRecord] {
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.id.map { ($0, record) }
        })
        var result: [ChapterRecord] = []
        var current = byID[chapterID]
        var visited: Set<Int64> = []
        while let chapter = current, let id = chapter.id, !visited.contains(id) {
            visited.insert(id)
            result.append(chapter)
            current = byID[chapter.parentId]
        }
        return result.reversed()
    }

    static func collectDescendantIDs(records: [ChapterRecord], rootIDs: [Int64]) -> Set<Int64> {
        let children = Dictionary(grouping: records, by: \.parentId)
        var result: Set<Int64> = []
        func visit(_ id: Int64) {
            guard result.insert(id).inserted else { return }
            for child in children[id] ?? [] {
                if let childID = child.id { visit(childID) }
            }
        }
        rootIDs.forEach(visit)
        return result
    }

    static func flatten(_ roots: [DesktopWebChapterFullSnapshot]) -> [DesktopWebChapterFullSnapshot] {
        var result: [DesktopWebChapterFullSnapshot] = []
        func visit(_ chapter: DesktopWebChapterFullSnapshot) {
            result.append(chapter)
            chapter.children.forEach(visit)
        }
        roots.forEach(visit)
        return result
    }

    static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    static func nonBlankTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
