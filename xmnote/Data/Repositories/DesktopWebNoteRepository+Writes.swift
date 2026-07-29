/**
 * [INPUT]: 依赖 DesktopWebNoteRepository、GRDB V44 note/book/chapter/tag 关系表与 Android 富文本兼容器
 * [OUTPUT]: 对外提供 NoteController 创建、更新、删除、批量移动/打标与合并写入语义
 * [POS]: Data 层网页书摘写入扩展；按 Android 事务边界落库，不让 XMNoteWeb 直接访问 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated extension DesktopWebNoteRepository {
    /// 创建书摘并在同一数据库事务内更新书籍进度、标签和图片；上传凭证提交失败会回滚数据库事务。
    func createNote(_ input: DesktopWebNoteCreateInput) async throws -> DesktopWebNoteResultSnapshot {
        let imageURLs = Self.normalizedImageURLs(input.imageURLs) ?? []
        try Self.validateContent(content: input.content, idea: input.idea, imageURLs: imageURLs)
        let targetBook = try await activeBook(id: input.bookID, message: "书籍不存在: \(input.bookID)")
        let chapterID = input.chapterID ?? 0
        if chapterID != 0, !(try await chapterBelongsToBook(chapterID, bookID: input.bookID)) {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节不属于该书籍")
        }
        let tagIDs = Self.distinct(input.tagIDs ?? [])
        guard tagIDs.allSatisfy({ $0 > 0 }), try await activeTagsExist(tagIDs) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分标签不存在")
        }
        try Self.validatePosition(input.position, book: targetBook)

        let now = currentTimeMillis()
        let preparedRecord = NoteRecord(
            id: nil,
            bookId: input.bookID,
            chapterId: chapterID,
            content: DesktopWebRichHTMLCanonicalizer.canonicalize(input.content ?? ""),
            idea: DesktopWebRichHTMLCanonicalizer.canonicalize(input.idea ?? ""),
            position: input.position ?? "",
            positionUnit: targetBook.positionUnit,
            wereadRange: "",
            includeTime: 1,
            createdDate: input.createdTime.flatMap { $0 > 0 ? $0 : nil } ?? now,
            updatedDate: 0,
            lastSyncDate: 0,
            isDeleted: 0
        )

        let record = try await database.dbPool.write { db -> NoteRecord in
            var record = preparedRecord
            try record.insert(db)
            guard let noteID = record.id else {
                throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("创建书摘失败")
            }
            try Self.syncBookReadPosition(db: db, book: targetBook, note: record, now: now)
            if !tagIDs.isEmpty {
                try Self.replaceTags(db: db, noteID: noteID, tagIDs: tagIDs, now: now)
            }
            if !imageURLs.isEmpty {
                try Self.replaceImages(db: db, noteID: noteID, imageURLs: imageURLs, now: now)
            }
            try commitUploadedTickets(input.uploadedTicketIDs, imageURLs)
            return record
        }
        return try await writeResult(record: record, tagIDs: tagIDs, imageURLs: imageURLs)
    }

    /// 局部更新书摘；nil 保留旧值，显式空数组清空关系，整个主写路径保持 Android 单事务语义。
    func updateNote(id: Int64, input: DesktopWebNoteUpdateInput) async throws -> DesktopWebNoteResultSnapshot {
        var record = try await requireNoteFromActiveBook(id: id)
        if let bookID = input.bookID, bookID <= 0 {
            throw DesktopWebCatalogRepositoryError.invalidArgument("目标书籍不存在")
        }
        let targetBookID = input.bookID ?? record.bookId
        let targetBook = try await activeBook(id: targetBookID, message: "目标书籍不存在")
        let targetPositionUnit = targetBookID == record.bookId ? record.positionUnit : targetBook.positionUnit
        let chapterID = input.chapterID ?? record.chapterId
        if chapterID != 0, !(try await chapterBelongsToBook(chapterID, bookID: targetBookID)) {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节不属于该书籍")
        }
        let normalizedRequestTagIDs = input.tagIDs.map(Self.distinct)
        if let tagIDs = normalizedRequestTagIDs {
            guard tagIDs.allSatisfy({ $0 > 0 }), try await activeTagsExist(tagIDs) else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("部分标签不存在")
            }
        }

        let existingTagIDs = input.tagIDs == nil
            ? try await displayTags(noteIDs: [id])[id, default: []].map(\.id)
            : []
        let existingImageURLs = input.imageURLs == nil
            ? try await displayImages(noteIDs: [id])[id, default: []].map(\.url)
            : []
        let finalContent = input.content.map(DesktopWebRichHTMLCanonicalizer.canonicalize) ?? record.content
        let finalIdea = input.idea.map(DesktopWebRichHTMLCanonicalizer.canonicalize) ?? record.idea
        let finalPosition = input.position ?? record.position
        let finalTagIDs = normalizedRequestTagIDs ?? existingTagIDs
        let finalImageURLs = Self.normalizedImageURLs(input.imageURLs) ?? existingImageURLs
        try Self.validateContent(content: finalContent, idea: finalIdea, imageURLs: finalImageURLs)
        try Self.validatePosition(finalPosition, book: targetBook, positionUnit: targetPositionUnit)

        let now = currentTimeMillis()
        record.bookId = targetBookID
        record.chapterId = chapterID
        record.content = finalContent
        record.idea = finalIdea
        record.position = finalPosition
        record.positionUnit = targetPositionUnit
        if let createdTime = input.createdTime, createdTime > 0 { record.createdDate = createdTime }
        record.updatedDate = now

        let updatedRecord = record
        try await database.dbPool.write { db in
            try updatedRecord.update(db)
            try Self.syncBookReadPosition(db: db, book: targetBook, note: updatedRecord, now: now)
            if input.tagIDs != nil {
                try Self.replaceTags(db: db, noteID: id, tagIDs: finalTagIDs, now: now)
            }
            if input.imageURLs != nil {
                try Self.replaceImages(db: db, noteID: id, imageURLs: finalImageURLs, now: now)
                try commitUploadedTickets(input.uploadedTicketIDs, finalImageURLs)
            }
        }
        return try await writeResult(record: updatedRecord, tagIDs: finalTagIDs, imageURLs: finalImageURLs)
    }

    /// 软删除有效书籍下的书摘及其标签、图片关系。
    func deleteNote(id: Int64) async throws {
        _ = try await requireNoteFromActiveBook(id: id)
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            guard try Self.softDeleteGraph(db: db, noteID: id, now: now) else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("笔记不存在: \(id)")
            }
        }
    }

    /// 预校验全部书摘及其书籍后，在单事务内软删除完整图谱。
    func batchDeleteNotes(ids rawIDs: [Int64]) async throws {
        let ids = try Self.normalizeIDs(rawIDs)
        _ = try await requiredActiveNotes(ids: ids)
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            for id in ids {
                _ = try Self.softDeleteGraph(db: db, noteID: id, now: now)
            }
        }
    }

    /// 预校验全部资源后，在单事务内批量移动书摘章节。
    func batchMoveNotesToChapter(ids rawIDs: [Int64], chapterID: Int64) async throws {
        let ids = try Self.normalizeIDs(rawIDs)
        let notes = try await requiredActiveNotes(ids: ids)
        let notesByID = Dictionary(uniqueKeysWithValues: notes.compactMap { note in
            note.id.map { ($0, note) }
        })
        let targetChapter = chapterID == 0 ? nil : try await activeChapter(id: chapterID)
        if chapterID != 0, targetChapter == nil {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节不存在: \(chapterID)")
        }
        if let targetChapter {
            let invalidIDs = notes.filter { $0.bookId != targetChapter.bookId }.compactMap(\.id)
            guard invalidIDs.isEmpty else {
                throw DesktopWebCatalogRepositoryError.invalidArgument(
                    "章节不属于笔记所属书籍，noteId=\(invalidIDs.map(String.init).joined(separator: ","))"
                )
            }
        }

        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            for id in ids {
                guard var note = notesByID[id], note.chapterId != chapterID else { continue }
                note.chapterId = chapterID
                note.updatedDate = now
                try note.update(db)
            }
        }
    }

    /// 预校验全部资源后，在单事务内批量替换标签并统一更新时间。
    func batchSetNoteTags(ids rawIDs: [Int64], tagIDs rawTagIDs: [Int64], mode rawMode: String) async throws {
        let ids = try Self.normalizeIDs(rawIDs)
        let lowercasedMode = rawMode.lowercased()
        let mode = Self.isKotlinBlank(lowercasedMode) ? "append" : lowercasedMode
        guard mode == "append" || mode == "replace" else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("mode 仅支持 append 或 replace")
        }
        let tagIDs = Self.distinct(rawTagIDs)
        guard tagIDs.allSatisfy({ $0 > 0 }), try await activeTagsExist(tagIDs) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分标签不存在")
        }
        if mode == "append", tagIDs.isEmpty { return }
        let notes = try await requiredActiveNotes(ids: ids)
        let notesByID = Dictionary(uniqueKeysWithValues: notes.compactMap { note in
            note.id.map { ($0, note) }
        })
        let existing = mode == "append" ? try await displayTags(noteIDs: ids) : [:]
        let now = currentTimeMillis()

        try await database.dbPool.write { db in
            for id in ids {
                guard var note = notesByID[id] else { continue }
                let finalTagIDs = mode == "append"
                    ? Self.distinct(existing[id, default: []].map(\.id) + tagIDs)
                    : tagIDs
                try Self.replaceTags(db: db, noteID: id, tagIDs: finalTagIDs, now: now)
                note.updatedDate = now
                try note.update(db)
            }
        }
    }

    /// 在单事务内把书摘移动到目标书，并按源章节祖先路径复用或创建目标章节。
    func batchMoveNotesToBook(ids rawIDs: [Int64], targetBookID: Int64) async throws {
        let ids = try Self.normalizeIDs(rawIDs)
        guard targetBookID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("targetBookId 不能为空")
        }
        _ = try await activeBook(id: targetBookID, message: "目标书籍不存在")
        let notes = try await requiredActiveNotes(ids: ids)
        let notesByID = Dictionary(uniqueKeysWithValues: notes.compactMap { note in
            note.id.map { ($0, note) }
        })
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            var targetChapters = try ChapterRecord.fetchAll(
                db,
                sql: "SELECT * FROM chapter WHERE book_id = ? AND is_deleted = 0",
                arguments: [targetBookID]
            )
            var sourceCache: [Int64: ChapterRecord?] = [:]
            for id in ids {
                guard var note = notesByID[id] else { continue }
                let mappedChapterID = try Self.resolveTargetChapterID(
                    db: db,
                    sourceChapterID: note.chapterId,
                    targetBookID: targetBookID,
                    now: now,
                    targetChapters: &targetChapters,
                    sourceCache: &sourceCache
                )
                if note.bookId != targetBookID || note.chapterId != mappedChapterID {
                    note.bookId = targetBookID
                    note.chapterId = mappedChapterID
                    note.updatedDate = now
                    try note.update(db)
                }
            }
        }
    }

    /// 合并同书书摘并软删除原图谱；上传凭证按 Android 设计在数据库事务提交后再确认。
    func batchMergeNotes(_ input: DesktopWebNoteMergeInput) async throws -> DesktopWebNoteResultSnapshot {
        let ids = try Self.normalizeIDs(input.ids)
        guard ids.count >= 2 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("至少选择两条书摘")
        }
        let records = try await requiredActiveNotes(ids: ids)
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { note in note.id.map { ($0, note) } })
        let missingIDs = ids.filter { byID[$0] == nil }
        guard missingIDs.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "部分书摘不存在: \(missingIDs.map(String.init).joined(separator: ","))"
            )
        }
        let selected = ids.compactMap { byID[$0] }
        let bookID = selected[0].bookId
        guard selected.allSatisfy({ $0.bookId == bookID }) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("仅支持合并同一本书中的书摘")
        }
        let sourceBook = try await activeBook(id: bookID, message: "部分笔记不存在")

        let contentOrdered = Self.notesForMerge(
            selected,
            orderedIDs: input.contentOrderedIDs ?? input.orderedIDs ?? []
        )
        let ideaOrdered = Self.notesForMerge(
            selected,
            orderedIDs: input.ideaOrderedIDs ?? input.orderedIDs ?? []
        )
        let contentRule = Self.normalizedMergeRule(input.contentMergeRule)
        let ideaRule = Self.normalizedMergeRule(input.ideaMergeRule)
        let defaultContent = Self.mergeText(
            contentOrdered.map(\.content).filter { !Self.isKotlinBlank($0) },
            rule: contentRule
        )
        let defaultIdea = Self.mergeText(
            ideaOrdered.map(\.idea).filter { !Self.isKotlinBlank($0) },
            rule: ideaRule
        )
        let tagMap = try await displayTags(noteIDs: ids)
        let defaultTagIDs = Self.distinct(ids.flatMap { tagMap[$0, default: []].map(\.id) })
        let imageMap = try await displayImages(noteIDs: ids)
        let defaultImageURLs = contentOrdered.flatMap { note in
            imageMap[note.id ?? 0, default: []].sorted { $0.id < $1.id }.map(\.url)
        }
        let defaultPosition = contentOrdered.allSatisfy({ !Self.isKotlinBlank($0.position) })
            && Set(contentOrdered.map(\.position)).count == 1
            ? contentOrdered[0].position
            : ""
        let chapterIDs = contentOrdered.map(\.chapterId)
        let defaultChapterID = chapterIDs.allSatisfy { $0 != 0 } && Set(chapterIDs).count == 1
            ? chapterIDs[0]
            : 0

        let draft = input.merged
        let mergedContent = DesktopWebRichHTMLCanonicalizer.canonicalize(draft?.content ?? defaultContent)
        let mergedIdea = DesktopWebRichHTMLCanonicalizer.canonicalize(draft?.idea ?? defaultIdea)
        let mergedPosition = draft?.position ?? defaultPosition
        let mergedPositionUnit = Int64(draft?.positionUnit ?? Int(selected[0].positionUnit))
        let mergedChapterID = draft?.chapterID ?? defaultChapterID
        let mergedTagIDs = draft?.tagIDs.map(Self.distinctPositive) ?? defaultTagIDs
        let mergedImageURLs = Self.normalizedImageURLs(draft?.imageURLs) ?? defaultImageURLs
        let mergedTicketIDs = draft?.uploadedTicketIDs?.map(Self.kotlinTrimmed).filter { !$0.isEmpty } ?? []
        let mergedCreatedTime = draft?.createdTime.flatMap { $0 > 0 ? $0 : nil } ?? currentTimeMillis()

        if mergedChapterID != 0, !(try await chapterBelongsToBook(mergedChapterID, bookID: bookID)) {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节不属于当前书籍")
        }
        guard try await activeTagsExist(mergedTagIDs) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("部分标签不存在")
        }
        try Self.validateContent(content: mergedContent, idea: mergedIdea, imageURLs: mergedImageURLs)
        try Self.validatePosition(mergedPosition, book: sourceBook, positionUnit: mergedPositionUnit)
        let now = currentTimeMillis()
        let preparedMerged = NoteRecord(
            id: nil,
            bookId: bookID,
            chapterId: mergedChapterID,
            content: mergedContent,
            idea: mergedIdea,
            position: mergedPosition,
            positionUnit: mergedPositionUnit,
            wereadRange: "",
            includeTime: 1,
            createdDate: mergedCreatedTime,
            updatedDate: now,
            lastSyncDate: 0,
            isDeleted: 0
        )
        let merged = try await database.dbPool.write { db -> NoteRecord in
            var merged = preparedMerged
            for id in ids { _ = try Self.softDeleteGraph(db: db, noteID: id, now: now) }
            try merged.insert(db)
            guard let mergedID = merged.id else {
                throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("合并失败，请重试")
            }
            if !mergedTagIDs.isEmpty {
                try Self.replaceTags(db: db, noteID: mergedID, tagIDs: mergedTagIDs, now: now)
            }
            if !mergedImageURLs.isEmpty {
                try Self.replaceImages(db: db, noteID: mergedID, imageURLs: mergedImageURLs, now: now)
            }
            return merged
        }
        try commitUploadedTickets(mergedTicketIDs, mergedImageURLs)
        guard merged.id != nil else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("合并失败，请重试")
        }
        return try await writeResult(record: merged, tagIDs: mergedTagIDs, imageURLs: mergedImageURLs)
    }
}

nonisolated extension DesktopWebNoteRepository {
    func activeBook(id: Int64, message: String) async throws -> BookRecord {
        guard let book = try await database.dbPool.read({ db in
            // SQL 目的：读取 Web 书摘写入目标的有效书籍及位置配置。
            // 涉及表：book。
            // 关键过滤：id 精确匹配、id!=0 且 is_deleted=0。
            // 时间字段：updated_date 仅在进度同步时覆盖，其余原样保留。
            // 返回字段用途：创建、更新、跨书移动的存在性和位置校验。
            try BookRecord.fetchOne(
                db,
                sql: "SELECT * FROM book WHERE id = ? AND id != 0 AND is_deleted = 0",
                arguments: [id]
            )
        }) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(message)
        }
        return book
    }

    func chapterBelongsToBook(_ chapterID: Int64, bookID: Int64) async throws -> Bool {
        try await database.dbPool.read { db in
            // SQL 目的：验证章节是否是目标书籍的有效章节。
            // 涉及表：chapter。
            // 关键过滤：chapter id、book_id 与 is_deleted=0 同时匹配。
            // 时间字段：无。
            // 返回字段用途：创建、更新、合并书摘的章节约束。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chapter WHERE id = ? AND book_id = ? AND is_deleted = 0",
                arguments: [chapterID, bookID]
            ) ?? 0
        } > 0
    }

    func activeTagsExist(_ tagIDs: [Int64]) async throws -> Bool {
        guard !tagIDs.isEmpty else { return true }
        return try await database.dbPool.read { db in
            // SQL 目的：按 Android countExistingTags 校验规范化后的标签均为有效记录。
            // 涉及表：tag。
            // 关键过滤：id IN 去重请求数组且 is_deleted=0。
            // 时间字段：无。
            // 返回字段用途：与去重后的请求长度比较，重复 ID 不影响合法性。
            let placeholders = Array(repeating: "?", count: tagIDs.count).joined(separator: ",")
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM tag WHERE id IN (\(placeholders)) AND is_deleted = 0",
                arguments: StatementArguments(tagIDs)
            ) ?? 0
            return count == tagIDs.count
        }
    }

    func activeNotes(ids: [Int64]) async throws -> [NoteRecord] {
        guard !ids.isEmpty else { return [] }
        return try await database.dbPool.read { db in
            // SQL 目的：批量读取仍有效的书摘，供批量移动和合并前校验。
            // 涉及表：note。
            // 关键过滤：id 位于规范化 ID 集合且 is_deleted=0；不关联 book。
            // 时间字段：原样返回，写入路径按操作决定是否覆盖 updated_date。
            // 返回字段用途：缺失 ID 检测、同书校验与批量更新。
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return try NoteRecord.fetchAll(
                db,
                sql: "SELECT * FROM note WHERE id IN (\(placeholders)) AND is_deleted = 0",
                arguments: StatementArguments(ids)
            )
        }
    }

    /// 批量读取并验证所有书摘存在且其来源书籍仍有效。
    func requiredActiveNotes(ids: [Int64]) async throws -> [NoteRecord] {
        let notes = try await activeNotes(ids: ids)
        let byID = Dictionary(uniqueKeysWithValues: notes.compactMap { note in note.id.map { ($0, note) } })
        let missingIDs = ids.filter { byID[$0] == nil }
        guard missingIDs.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "部分笔记不存在: \(missingIDs.map(String.init).joined(separator: ","))"
            )
        }
        for bookID in Set(notes.map(\.bookId)) {
            _ = try await activeBook(id: bookID, message: "部分笔记不存在")
        }
        return ids.compactMap { byID[$0] }
    }

    func activeChapter(id: Int64) async throws -> ChapterRecord? {
        try await database.dbPool.read { db in
            // SQL 目的：按主键读取一个有效章节，供批量移动目标校验。
            // 涉及表：chapter。
            // 关键过滤：id 精确匹配且 is_deleted=0。
            // 时间字段：无。
            // 返回字段用途：确认章节存在并取得所属 book_id。
            try ChapterRecord.fetchOne(
                db,
                sql: "SELECT * FROM chapter WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            )
        }
    }

    func writeResult(
        record: NoteRecord,
        tagIDs: [Int64],
        imageURLs: [String]
    ) async throws -> DesktopWebNoteResultSnapshot {
        let id = record.id ?? 0
        let tags = tagIDs.isEmpty ? [] : try await displayTags(noteIDs: [id])[id, default: []]
        let images = try await displayImages(noteIDs: [id])[id, default: []]
        return DesktopWebNoteResultSnapshot(
            id: id,
            bookID: record.bookId,
            chapterID: record.chapterId,
            content: record.content,
            idea: Self.nonBlank(record.idea),
            position: Self.nonBlank(record.position),
            positionUnit: Int(record.positionUnit),
            createdTime: record.createdDate,
            updatedTime: record.updatedDate,
            tags: tags,
            images: images
        )
    }
}

private nonisolated extension DesktopWebNoteRepository {
    static func validateContent(content: String?, idea: String?, imageURLs: [String]?) throws {
        let hasContent = !(content.map(isKotlinBlank) ?? true)
        let hasIdea = !(idea.map(isKotlinBlank) ?? true)
        let hasImages = !(imageURLs?.isEmpty ?? true)
        guard hasContent || hasIdea || hasImages else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("书摘内容、想法、图片不能同时为空")
        }
    }

    static func normalizedImageURLs(_ values: [String]?) -> [String]? {
        values?.map(kotlinTrimmed).filter { !$0.isEmpty }
    }

    static func validatePosition(
        _ position: String?,
        book: BookRecord,
        positionUnit: Int64? = nil
    ) throws {
        let effectiveUnit = positionUnit ?? book.positionUnit
        guard (0...2).contains(effectiveUnit) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("阅读位置单位无效")
        }
        guard let position,
              let numeric = Double(kotlinTrimmed(position)),
              !kotlinTrimmed(position).isEmpty else { return }
        switch effectiveUnit {
        case 1 where book.totalPosition != 0:
            if numeric <= 0 {
                throw DesktopWebCatalogRepositoryError.invalidArgument("位置应大于0")
            }
            if numeric > Double(book.totalPosition) {
                throw DesktopWebCatalogRepositoryError.invalidArgument("位置应小于总位置(\(book.totalPosition))")
            }
        case 2 where book.totalPagination != 0:
            if numeric <= 0 {
                throw DesktopWebCatalogRepositoryError.invalidArgument("页码应大于0页")
            }
            if numeric > Double(book.totalPagination) {
                throw DesktopWebCatalogRepositoryError.invalidArgument("页码应小于总页码(\(book.totalPagination)页)")
            }
        case 0:
            if numeric < 0 || numeric > 100 {
                throw DesktopWebCatalogRepositoryError.invalidArgument("进度值应在[0,100]区间内")
            }
        default:
            break
        }
    }

    static func normalizeIDs(_ values: [Int64]) throws -> [Int64] {
        let normalized = distinctPositive(values)
        guard !normalized.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("ids 不能为空")
        }
        return normalized
    }

    static func replaceTags(db: Database, noteID: Int64, tagIDs: [Int64], now: Int64) throws {
        // SQL 目的：软删除书摘当前全部有效标签关系，再插入请求关系。
        // 涉及表：tag_note。
        // 关键过滤：note_id 精确匹配且仅更新 is_deleted=0 的关系。
        // 时间字段：删除关系 updated_date 与新关系 created_date 使用当前操作毫秒值。
        // 副作用用途：创建、更新、合并书摘的全量标签替换。
        try db.execute(
            sql: "UPDATE tag_note SET is_deleted = 1, updated_date = ? WHERE note_id = ? AND is_deleted = 0",
            arguments: [now, noteID]
        )
        for tagID in tagIDs {
            var relation = TagNoteRecord(
                id: nil,
                tagId: tagID,
                noteId: noteID,
                createdDate: now,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try relation.insert(db)
        }
    }

    static func replaceImages(db: Database, noteID: Int64, imageURLs: [String], now: Int64) throws {
        // SQL 目的：软删除书摘当前全部有效附图，再按请求顺序插入新图片。
        // 涉及表：attach_image。
        // 关键过滤：note_id 精确匹配且仅更新 is_deleted=0 的图片；空 URL 也按 Android 原样插入。
        // 时间字段：删除图片 updated_date 与新图片 created_date 使用当前操作毫秒值。
        // 副作用用途：创建、更新、合并书摘的全量图片替换。
        try db.execute(
            sql: "UPDATE attach_image SET is_deleted = 1, updated_date = ? WHERE note_id = ? AND is_deleted = 0",
            arguments: [now, noteID]
        )
        for url in imageURLs {
            var image = AttachImageRecord(
                id: nil,
                noteId: noteID,
                imageUrl: url,
                createdDate: now,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try image.insert(db)
        }
    }

    static func syncBookReadPosition(db: Database, book: BookRecord, note: NoteRecord, now: Int64) throws {
        let trimmed = kotlinTrimmed(note.position)
        guard !trimmed.isEmpty,
              let numeric = Double(trimmed),
              book.positionUnit == note.positionUnit else { return }
        let next = book.currentPositionUnit == book.positionUnit
            ? (numeric.isNaN ? numeric : max(numeric, book.readPosition))
            : numeric
        guard book.currentPositionUnit != book.positionUnit || next != book.readPosition else { return }
        // SQL 目的：书摘保存后同步书籍当前阅读单位与最大阅读位置。
        // 涉及表：book。
        // 关键过滤：按目标书籍主键更新；调用前已校验有效书籍和 position_unit 一致。
        // 时间字段：updated_date 写书摘操作当前毫秒值。
        // 副作用用途：复刻 NoteService.syncBookReadPositionFromNote。
        try db.execute(
            sql: "UPDATE book SET current_position_unit = ?, read_position = ?, updated_date = ? WHERE id = ?",
            arguments: [book.positionUnit, next, now, book.id ?? 0]
        )
    }

    static func softDeleteGraph(db: Database, noteID: Int64, now: Int64) throws -> Bool {
        // SQL 目的：软删除一条仍有效书摘，并在命中时继续软删除标签与图片关系。
        // 涉及表：note、tag_note、attach_image。
        // 关键过滤：三表均按 note id；主表和关系只更新 is_deleted=0 的记录。
        // 时间字段：所有命中记录 updated_date 使用同一操作毫秒值。
        // 副作用用途：单删、批删与合并原书摘清理，保证图谱状态一致。
        try db.execute(
            sql: "UPDATE note SET is_deleted = 1, updated_date = ? WHERE id = ? AND is_deleted = 0",
            arguments: [now, noteID]
        )
        guard db.changesCount > 0 else { return false }
        try db.execute(
            sql: "UPDATE tag_note SET is_deleted = 1, updated_date = ? WHERE note_id = ? AND is_deleted = 0",
            arguments: [now, noteID]
        )
        try db.execute(
            sql: "UPDATE attach_image SET is_deleted = 1, updated_date = ? WHERE note_id = ? AND is_deleted = 0",
            arguments: [now, noteID]
        )
        return true
    }

    static func resolveTargetChapterID(
        db: Database,
        sourceChapterID: Int64,
        targetBookID: Int64,
        now: Int64,
        targetChapters: inout [ChapterRecord],
        sourceCache: inout [Int64: ChapterRecord?]
    ) throws -> Int64 {
        guard sourceChapterID != 0 else { return 0 }
        func source(_ id: Int64) throws -> ChapterRecord? {
            if let cached = sourceCache[id] { return cached }
            // SQL 目的：读取源书摘章节及其有效祖先，供跨书路径映射。
            // 涉及表：chapter。
            // 关键过滤：id 精确匹配且 is_deleted=0；不限制所属书籍。
            // 时间字段：无。
            // 返回字段用途：构造从根到叶的标题路径；缺失节点回退未分类。
            let record = try ChapterRecord.fetchOne(
                db,
                sql: "SELECT * FROM chapter WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            )
            sourceCache[id] = record
            return record
        }
        guard let first = try source(sourceChapterID) else { return 0 }
        var path: [ChapterRecord] = []
        var current: ChapterRecord? = first
        var visited: Set<Int64> = []
        while let chapter = current, let id = chapter.id, visited.insert(id).inserted {
            path.append(chapter)
            current = chapter.parentId == 0 ? nil : try source(chapter.parentId)
        }
        var parentID: Int64 = 0
        for chapter in path.reversed() {
            parentID = try ensureTargetChapter(
                db: db,
                targetBookID: targetBookID,
                parentID: parentID,
                title: chapter.title,
                now: now,
                targetChapters: &targetChapters
            )
        }
        return parentID
    }

    static func ensureTargetChapter(
        db: Database,
        targetBookID: Int64,
        parentID: Int64,
        title: String,
        now: Int64,
        targetChapters: inout [ChapterRecord]
    ) throws -> Int64 {
        let normalizedTitle = kotlinTrimmed(title)
        if let existing = targetChapters.first(where: {
            $0.parentId == parentID && kotlinTrimmed($0.title) == normalizedTitle
        }), let id = existing.id {
            return id
        }
        let parentPath = targetChapterPath(targetChapters, chapterID: parentID)
        let level = parentPath.count + 1
        guard level <= 5 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("章节层级不能超过 5 层")
        }
        let nextOrder = (targetChapters.filter { $0.parentId == parentID }.map(\.chapterOrder).max() ?? 0) + 1
        var chapter = ChapterRecord(
            id: nil,
            bookId: targetBookID,
            parentId: parentID,
            title: normalizedTitle,
            remark: "",
            chapterOrder: nextOrder,
            isImport: 0,
            chapterLevel: Int64(level),
            sourceType: 0,
            sourceUid: "",
            sourceAnchor: "",
            sourceOrder: 0,
            sourcePath: (parentPath + [normalizedTitle]).joined(separator: " / "),
            isStarred: 0,
            createdDate: now,
            updatedDate: now,
            lastSyncDate: 0,
            isDeleted: 0
        )
        try chapter.insert(db)
        guard let id = chapter.id else {
            throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("创建章节失败")
        }
        targetChapters.append(chapter)
        return id
    }

    static func targetChapterPath(_ chapters: [ChapterRecord], chapterID: Int64) -> [String] {
        guard chapterID != 0 else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: chapters.compactMap { chapter in
            chapter.id.map { ($0, chapter) }
        })
        var result: [String] = []
        var current = byID[chapterID]
        var visited: Set<Int64> = []
        while let chapter = current, let id = chapter.id, visited.insert(id).inserted {
            result.append(kotlinTrimmed(chapter.title))
            current = byID[chapter.parentId]
        }
        return result.reversed()
    }

    static func notesForMerge(_ notes: [NoteRecord], orderedIDs: [Int64]) -> [NoteRecord] {
        guard !orderedIDs.isEmpty else { return notes }
        let byID = Dictionary(uniqueKeysWithValues: notes.compactMap { note in note.id.map { ($0, note) } })
        var used: Set<Int64> = []
        let ordered = distinct(orderedIDs).compactMap { id -> NoteRecord? in
            guard let note = byID[id] else { return nil }
            used.insert(id)
            return note
        }
        return ordered + notes.filter { !used.contains($0.id ?? 0) }
    }

    static func normalizedMergeRule(_ value: String?) -> String {
        let normalized = kotlinTrimmed(value ?? "").lowercased()
        return ["follow", "new_one_line", "new_two_line"].contains(normalized)
            ? normalized
            : "new_one_line"
    }

    static func mergeText(_ values: [String], rule: String) -> String {
        let separator = rule == "follow" ? "" : (rule == "new_two_line" ? "<br><br>" : "<br>")
        return values.joined(separator: separator)
    }
}
