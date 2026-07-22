/**
 * [INPUT]: 依赖统一 NoteImport Draft、GRDB Record 与 DatabaseManager
 * [OUTPUT]: 对外提供 NoteImportRepository，完成全来源书摘的本地匹配和逐书增量落库
 * [POS]: Data/Repositories 的统一导入写边界；文件、剪贴板、API 与特殊入口共享此实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

@MainActor
final class NoteImportRepository: NoteImportRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let defaults: UserDefaults

    init(databaseManager: DatabaseManager, defaults: UserDefaults = .standard) {
        self.databaseManager = databaseManager
        self.defaults = defaults
    }

    func matchLocalBook(for draft: NoteImportDraftBook) async throws -> BookPickerBook? {
        try await databaseManager.database.dbPool.read { db in
            let normalizedRawName = draft.rawName.isEmpty ? draft.name : draft.rawName
            let record = try BookRecord.fetchOne(db, sql: """
                SELECT * FROM book
                WHERE is_deleted = 0 AND (
                    raw_name = ? OR
                    (name = ? AND (? = '' OR author = ?))
                )
                ORDER BY CASE WHEN raw_name = ? THEN 0 ELSE 1 END, id
                LIMIT 1
                """, arguments: [normalizedRawName, draft.name, draft.author, draft.author, normalizedRawName])
            guard let record, let id = record.id else { return nil }
            return BookPickerBook(
                id: id,
                title: record.name,
                author: record.author,
                press: record.press,
                coverURL: record.cover,
                positionUnit: record.positionUnit,
                totalPosition: record.totalPosition,
                totalPagination: record.totalPagination
            )
        }
    }

    func commitImport(
        books: [NoteImportCommitBook],
        progress: @escaping (Int, Int) -> Void
    ) async throws {
        guard !books.isEmpty else { throw NoteImportParserError.noteNotFound }
        let placement = defaults.object(forKey: "newAddBookPosition") as? Int ?? 0
        for (index, item) in books.enumerated() {
            try Task.checkCancellation()
            try await databaseManager.database.dbPool.write { db in
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
                let bookID = try self.upsertBook(item, ownerID: ownerID, placement: placement, now: now, db: db)
                var chapterIndex = ChapterIndex()
                try self.upsertChapters(item.draft.chapters, bookID: bookID, parentID: 0, parentPath: [], now: now, db: db, index: &chapterIndex)
                try self.upsertFallbackNoteChapters(item.draft.notes, bookID: bookID, now: now, db: db, index: &chapterIndex)
                try self.upsertNotes(item.draft.notes, bookID: bookID, chapterIndex: chapterIndex, ownerID: ownerID, now: now, db: db)
                try self.upsertReviews(item.draft.reviews, bookID: bookID, now: now, db: db)
                try self.upsertBookMetadata(item.draft, bookID: bookID, ownerID: ownerID, now: now, db: db)
                try self.upsertReadingTime(item.draft, bookID: bookID, now: now, db: db)
                try self.mergeReadStatus(item.draft, bookID: bookID, now: now, db: db)
            }
            progress(index + 1, books.count)
        }
    }
}

private extension NoteImportRepository {
    nonisolated struct ChapterIndex: Sendable {
        var uid: [String: Int64] = [:]
        var path: [String: Int64] = [:]
        var title: [String: [Int64]] = [:]
    }

    nonisolated func upsertBook(
        _ item: NoteImportCommitBook,
        ownerID: Int64,
        placement: Int,
        now: Int64,
        db: Database
    ) throws -> Int64 {
        let draft = item.draft
        if let targetID = item.targetBookID, var record = try BookRecord.fetchOne(db, key: targetID) {
            if record.rawName.isEmpty { record.rawName = draft.rawName.isEmpty ? draft.name : draft.rawName }
            if record.author.isEmpty { record.author = draft.author }
            if record.authorIntro.isEmpty { record.authorIntro = draft.authorIntro }
            if record.translator.isEmpty { record.translator = draft.translator }
            if record.press.isEmpty { record.press = draft.press }
            if record.isbn.isEmpty { record.isbn = draft.isbn }
            if record.summary.isEmpty { record.summary = draft.summary }
            if record.pubDate.isEmpty { record.pubDate = draft.pubDate }
            if record.cover.isEmpty { record.cover = draft.cover }
            if record.wordCount == nil { record.wordCount = draft.wordCount }
            record.updatedDate = now
            try record.update(db)
            return targetID
        }

        let edge: Int64 = placement == 1
            ? (try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(book_order), -1) FROM book WHERE user_id = ? AND is_deleted = 0", arguments: [ownerID]) ?? -1) + 1
            : (try Int64.fetchOne(db, sql: "SELECT COALESCE(MIN(book_order), 1) FROM book WHERE user_id = ? AND is_deleted = 0", arguments: [ownerID]) ?? 1) - 1
        let createdDate = derivedCreatedDate(draft, fallback: now)
        var record = BookRecord()
        record.userId = ownerID
        record.name = draft.name
        record.rawName = draft.rawName.isEmpty ? draft.name : draft.rawName
        record.author = draft.author
        record.authorIntro = draft.authorIntro
        record.translator = draft.translator
        record.press = draft.press
        record.isbn = draft.isbn
        record.summary = draft.summary
        record.pubDate = draft.pubDate
        record.cover = draft.cover
        record.type = draft.type
        record.sourceId = draft.source
        record.positionUnit = draft.positionUnit
        record.currentPositionUnit = draft.currentPositionUnit
        record.readPosition = draft.readPosition
        record.totalPosition = draft.totalPosition
        record.totalPagination = draft.totalPagination
        record.wordCount = draft.wordCount
        record.score = draft.score
        record.purchaseDate = draft.purchaseDate
        record.price = draft.price
        record.readStatusId = draft.readStatusID
        record.readStatusChangedDate = draft.readStatusChangedDate == 0 ? createdDate : draft.readStatusChangedDate
        record.bookOrder = edge
        record.createdDate = createdDate
        record.updatedDate = now
        try record.insert(db)
        guard let id = record.id else { throw NoteImportParserError.unexpected("创建书籍失败") }
        return id
    }

    nonisolated func upsertChapters(
        _ chapters: [NoteImportDraftChapter],
        bookID: Int64,
        parentID: Int64,
        parentPath: [String],
        now: Int64,
        db: Database,
        index: inout ChapterIndex
    ) throws {
        for (offset, chapter) in chapters.enumerated() {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let path = chapter.pathTitles.isEmpty ? parentPath + [title] : chapter.pathTitles
            let sourceUID = chapter.sourceUID.isEmpty ? nil : chapter.sourceUID
            var record: ChapterRecord?
            if let sourceUID {
                record = try ChapterRecord.fetchOne(db, sql: "SELECT * FROM chapter WHERE book_id = ? AND source_type = ? AND source_uid = ? LIMIT 1", arguments: [bookID, chapter.sourceType, sourceUID])
            }
            if record == nil {
                record = try ChapterRecord.fetchOne(db, sql: "SELECT * FROM chapter WHERE book_id = ? AND parent_id = ? AND title = ? AND is_deleted = 0 LIMIT 1", arguments: [bookID, parentID, title])
            }
            var value = record ?? ChapterRecord()
            let isNew = value.id == nil
            value.bookId = bookID
            value.parentId = parentID
            value.title = title
            value.remark = chapter.remark
            value.chapterOrder = chapter.order == 0 ? Int64(offset + 1) : chapter.order
            value.chapterLevel = chapter.level == 0 ? Int64(path.count) : chapter.level
            value.isImport = 1
            value.sourceType = chapter.sourceType == 0 ? 2 : chapter.sourceType
            value.sourceUid = sourceUID ?? Self.catalogUID(path)
            value.sourceAnchor = chapter.sourceAnchor.isEmpty ? nil : chapter.sourceAnchor
            value.sourceOrder = chapter.sourceOrder
            value.sourcePath = chapter.sourcePath.isEmpty ? path.joined(separator: "$") : chapter.sourcePath
            value.updatedDate = now
            value.isDeleted = 0
            if isNew { value.createdDate = now; try value.insert(db) } else { try value.update(db) }
            guard let chapterID = value.id else { continue }
            if let sourceUID { index.uid[sourceUID] = chapterID }
            index.uid[value.sourceUid ?? ""] = chapterID
            index.path[path.joined(separator: "$")] = chapterID
            index.title[title, default: []].append(chapterID)
            try upsertChapters(chapter.children, bookID: bookID, parentID: chapterID, parentPath: path, now: now, db: db, index: &index)
        }
    }

    nonisolated func upsertNotes(
        _ notes: [NoteImportDraftNote],
        bookID: Int64,
        chapterIndex: ChapterIndex,
        ownerID: Int64,
        now: Int64,
        db: Database
    ) throws {
        for note in notes where !note.content.isEmpty || !note.idea.isEmpty {
            let existingID: Int64? = try Int64.fetchOne(db, sql: "SELECT id FROM note WHERE book_id = ? AND content = ? AND idea = ? AND is_deleted = 0 LIMIT 1", arguments: [bookID, note.content, note.idea])
            let chapterID = resolveChapter(note.chapter, fallbackUID: note.wereadChapterUID, index: chapterIndex)
            if let existingID {
                if chapterID > 0 { try db.execute(sql: "UPDATE note SET chapter_id = ?, updated_date = ? WHERE id = ?", arguments: [chapterID, now, existingID]) }
                continue
            }
            var record = NoteRecord()
            record.bookId = bookID
            record.chapterId = chapterID
            record.content = note.content.replacingOccurrences(of: "<", with: "&lt;")
            record.idea = note.idea.replacingOccurrences(of: "<", with: "&lt;")
            record.position = note.position
            record.positionUnit = note.positionUnit
            record.wereadRange = note.wereadRange
            record.includeTime = note.isIncludeTime ? 1 : 0
            record.createdDate = note.createdTime == 0 ? now : note.createdTime
            record.updatedDate = now
            try record.insert(db)
            guard let noteID = record.id else { continue }
            for attachment in note.attachments where !attachment.imageURL.isEmpty {
                var image = AttachImageRecord()
                image.noteId = noteID
                image.imageUrl = attachment.imageURL
                image.createdDate = now
                image.updatedDate = now
                try image.insert(db)
            }
            for tag in note.tags { try linkTag(tag, ownerID: ownerID, bookID: nil, noteID: noteID, now: now, db: db) }
        }
    }

    nonisolated func upsertFallbackNoteChapters(
        _ notes: [NoteImportDraftNote],
        bookID: Int64,
        now: Int64,
        db: Database,
        index: inout ChapterIndex
    ) throws {
        for note in notes {
            guard let chapter = note.chapter else { continue }
            let path = chapter.pathTitles.isEmpty ? [chapter.title] : chapter.pathTitles
            let titles = path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !titles.isEmpty, index.path[titles.joined(separator: "$")] == nil else { continue }
            var parentID: Int64 = 0
            var currentPath: [String] = []
            for (offset, title) in titles.enumerated() {
                currentPath.append(title)
                let key = currentPath.joined(separator: "$")
                if let existingID = index.path[key] { parentID = existingID; continue }
                var record = try ChapterRecord.fetchOne(db, sql: "SELECT * FROM chapter WHERE book_id = ? AND parent_id = ? AND title = ? AND is_deleted = 0 LIMIT 1", arguments: [bookID, parentID, title]) ?? ChapterRecord()
                let isNew = record.id == nil
                record.bookId = bookID; record.parentId = parentID; record.title = title; record.chapterOrder = Int64(offset + 1); record.chapterLevel = Int64(currentPath.count); record.isImport = 1; record.sourceType = 0; record.sourcePath = key; record.updatedDate = now; record.isDeleted = 0
                if isNew { record.createdDate = now; try record.insert(db) } else { try record.update(db) }
                guard let chapterID = record.id else { continue }
                index.path[key] = chapterID; index.title[title, default: []].append(chapterID); parentID = chapterID
            }
        }
    }

    nonisolated func resolveChapter(_ chapter: NoteImportDraftChapter?, fallbackUID: Int64, index: ChapterIndex) -> Int64 {
        if fallbackUID != 0, let id = index.uid[String(fallbackUID)] { return id }
        guard let chapter else { return 0 }
        if !chapter.sourceUID.isEmpty, let id = index.uid[chapter.sourceUID] { return id }
        if !chapter.pathTitles.isEmpty, let id = index.path[chapter.pathTitles.joined(separator: "$")] { return id }
        let matches = index.title[chapter.title] ?? []
        return matches.count == 1 ? matches[0] : 0
    }

    nonisolated func upsertReviews(_ reviews: [NoteImportDraftReview], bookID: Int64, now: Int64, db: Database) throws {
        var keys = Set(try ReviewRecord.filter(Column("book_id") == bookID && Column("is_deleted") == 0).fetchAll(db).map { reviewKey($0.title ?? "", $0.content ?? "") })
        for review in reviews {
            let title = review.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = review.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = reviewKey(title, content)
            guard key != "\0", !keys.contains(key) else { continue }
            var record = ReviewRecord()
            record.bookId = bookID
            record.title = title
            record.content = content
            record.createdDate = review.createdTime == 0 ? now : review.createdTime
            record.updatedDate = record.createdDate
            try record.insert(db)
            if let reviewID = record.id {
                for (offset, source) in review.images.enumerated() {
                    var image = ReviewImageRecord()
                    image.reviewId = reviewID
                    image.image = source.image
                    image.order = source.order == 0 ? Int64(offset + 1) : source.order
                    image.createdDate = now
                    image.updatedDate = now
                    try image.insert(db)
                }
            }
            keys.insert(key)
        }
    }

    nonisolated func upsertBookMetadata(_ draft: NoteImportDraftBook, bookID: Int64, ownerID: Int64, now: Int64, db: Database) throws {
        for group in ([draft.group].compactMap { $0 } + draft.groups) where !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var record = try GroupRecord.fetchOne(db, sql: "SELECT * FROM \"group\" WHERE user_id = ? AND name = ? AND is_deleted = 0 LIMIT 1", arguments: [ownerID, name])
            if record == nil {
                var created = GroupRecord(); created.userId = ownerID; created.name = name; created.groupOrder = group.order; created.createdDate = now; created.updatedDate = now; try created.insert(db); record = created
            }
            if let groupID = record?.id { try insertRelationIfMissing(table: "group_book", left: ("group_id", groupID), right: ("book_id", bookID), now: now, db: db) }
        }
        for tag in draft.tags { try linkTag(tag, ownerID: ownerID, bookID: bookID, noteID: nil, now: now, db: db) }
    }

    nonisolated func linkTag(_ draft: NoteImportDraftTag, ownerID: Int64, bookID: Int64?, noteID: Int64?, now: Int64, db: Database) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var record = try TagRecord.fetchOne(db, sql: "SELECT * FROM tag WHERE user_id = ? AND name = ? AND is_deleted = 0 LIMIT 1", arguments: [ownerID, name])
        if record == nil {
            var created = TagRecord(); created.userId = ownerID; created.name = name; created.color = draft.color; created.tagOrder = draft.order; created.type = draft.type == 0 ? (bookID == nil ? 1 : 2) : draft.type; created.createdDate = now; created.updatedDate = now; try created.insert(db); record = created
        }
        guard let tagID = record?.id else { return }
        if let bookID { try insertRelationIfMissing(table: "tag_book", left: ("tag_id", tagID), right: ("book_id", bookID), now: now, db: db) }
        if let noteID { try insertRelationIfMissing(table: "tag_note", left: ("tag_id", tagID), right: ("note_id", noteID), now: now, db: db) }
    }

    nonisolated func insertRelationIfMissing(table: String, left: (String, Int64), right: (String, Int64), now: Int64, db: Database) throws {
        let count: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(left.0) = ? AND \(right.0) = ? AND is_deleted = 0", arguments: [left.1, right.1]) ?? 0
        guard count == 0 else { return }
        try db.execute(sql: "INSERT INTO \(table) (\(left.0), \(right.0), created_date, updated_date, last_sync_date, is_deleted) VALUES (?, ?, ?, ?, 0, 0)", arguments: [left.1, right.1, now, now])
    }

    nonisolated func upsertReadingTime(_ draft: NoteImportDraftBook, bookID: Int64, now: Int64, db: Database) throws {
        for duration in draft.preciseReadingDurations ?? [] {
            guard let start = duration.startTime, let end = duration.endTime, end > start else { continue }
            let exists: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM read_time_record WHERE book_id = ? AND start_time = ? AND end_time = ? AND is_deleted = 0", arguments: [bookID, start, end]) ?? 0
            guard exists == 0 else { continue }
            var record = ReadTimeRecordRecord(); record.bookId = bookID; record.startTime = start; record.endTime = end; record.elapsedSeconds = Int64((Double(end - start) / 1_000).rounded()); record.position = duration.position ?? 0; record.status = 3; record.createdDate = now; record.updatedDate = now; try record.insert(db)
        }
        for duration in draft.fuzzyReadingDurations ?? [] {
            guard let date = duration.date, let imported = duration.durationSeconds, imported > 0 else { continue }
            let calendar = Calendar(identifier: .gregorian)
            let startDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(date) / 1_000))
            let start = Int64(startDate.timeIntervalSince1970 * 1_000)
            let end = Int64((calendar.date(byAdding: .day, value: 1, to: startDate)?.timeIntervalSince1970 ?? startDate.timeIntervalSince1970) * 1_000) - 1
            let local: Int64 = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(elapsed_seconds), 0) FROM read_time_record WHERE book_id = ? AND is_deleted = 0 AND ((start_time BETWEEN ? AND ?) OR (fuzzy_read_date BETWEEN ? AND ?))", arguments: [bookID, start, end, start, end]) ?? 0
            guard imported > local else { continue }
            let delta = imported - local
            if let id: Int64 = try Int64.fetchOne(db, sql: "SELECT id FROM read_time_record WHERE book_id = ? AND fuzzy_read_date BETWEEN ? AND ? AND is_deleted = 0 ORDER BY id DESC LIMIT 1", arguments: [bookID, start, end]) {
                try db.execute(sql: "UPDATE read_time_record SET elapsed_seconds = elapsed_seconds + ?, position = ?, updated_date = ? WHERE id = ?", arguments: [delta, duration.position ?? 0, now, id])
            } else {
                var record = ReadTimeRecordRecord(); record.bookId = bookID; record.fuzzyReadDate = date; record.elapsedSeconds = delta; record.position = duration.position ?? 0; record.status = 3; record.createdDate = now; record.updatedDate = now; try record.insert(db)
            }
        }
    }

    nonisolated func mergeReadStatus(_ draft: NoteImportDraftBook, bookID: Int64, now: Int64, db: Database) throws {
        let changed = draft.readStatusChangedDate == 0 ? draft.readDoneTime : draft.readStatusChangedDate
        guard changed > 0 else { return }
        let latest: Int64 = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(changed_date), 0) FROM book_read_status_record WHERE book_id = ? AND is_deleted = 0", arguments: [bookID]) ?? 0
        guard changed > latest else { return }
        var record = BookReadStatusRecordRecord(); record.bookId = bookID; record.readStatusId = draft.readStatusID; record.changedDate = changed; record.createdDate = now; record.updatedDate = now; try record.insert(db)
        try db.execute(sql: "UPDATE book SET read_status_id = ?, read_status_changed_date = ?, updated_date = ? WHERE id = ?", arguments: [draft.readStatusID, changed, now, bookID])
    }

    nonisolated static func catalogUID(_ path: [String]) -> String {
        "catalog:" + path.joined(separator: "\0")
    }

    nonisolated func derivedCreatedDate(_ draft: NoteImportDraftBook, fallback: Int64) -> Int64 {
        let values = [
            draft.preciseReadingDurations?.compactMap(\.startTime).min() ?? 0,
            draft.fuzzyReadingDurations?.compactMap(\.date).min() ?? 0,
            draft.notes.map(\.createdTime).min() ?? 0,
            draft.reviews.map(\.createdTime).min() ?? 0,
            draft.wereadUpdateTime
        ].filter { $0 != 0 }
        return values.min() ?? fallback
    }

    nonisolated func reviewKey(_ title: String, _ html: String) -> String {
        let plain = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let normalizedContent = plain.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalizedTitle + "\0" + normalizedContent
    }
}
