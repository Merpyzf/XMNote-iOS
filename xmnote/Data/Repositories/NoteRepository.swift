import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供本地数据库连接，依赖 ObservationStream 提供观察流桥接，依赖 UserDefaults/FileManager/S3UploadRepository 承接草稿、暂存图与上传事务
 * [OUTPUT]: 对外提供 NoteRepository（NoteRepositoryProtocol 的 GRDB 实现）
 * [POS]: Data 层笔记仓储实现，统一封装标签分组查询、书摘编辑 bootstrap、自动草稿与保存事务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 笔记仓储实现，负责标签分组订阅、书摘编辑页 bootstrap 与最终保存事务。
struct NoteRepository: NoteRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let userDefaults: UserDefaults
    private let s3UploadRepository: any S3UploadRepositoryProtocol
    private let fileManager: FileManager
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    /// 注入数据库、草稿存储与图片上传依赖，统一承接书摘编辑完整链路。
    init(
        databaseManager: DatabaseManager,
        userDefaults: UserDefaults = .standard,
        s3UploadRepository: any S3UploadRepositoryProtocol,
        fileManager: FileManager = .default
    ) {
        self.databaseManager = databaseManager
        self.userDefaults = userDefaults
        self.s3UploadRepository = s3UploadRepository
        self.fileManager = fileManager
    }

    /// 为笔记主页提供标签分组订阅流，标签或标签关联变更后自动刷新分组计数。
    func observeTagSections() -> AsyncThrowingStream<[TagSection], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchTagSections(db)
        }
    }

    /// 读取单条笔记详情，供详情页初始化富文本内容与位置信息。
    func fetchNoteDetail(noteId: Int64) async throws -> NoteDetailPayload? {
        try await databaseManager.database.dbPool.read { db in
            // SQL 目的：按 noteId 读取单条笔记详情（富文本内容 + 位置信息）。
            // 过滤条件：限定主键并排除软删除记录；LIMIT 1 保证只返回单条。
            // 返回字段：覆盖 NoteDetailPayload 的全部展示字段。
            let sql = """
                SELECT content, idea, position, position_unit, include_time, created_date
                FROM note
                WHERE id = ? AND is_deleted = 0
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [noteId]) else {
                return nil
            }
            return NoteDetailPayload(
                contentHTML: row["content"] ?? "",
                ideaHTML: row["idea"] ?? "",
                position: row["position"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                createdDate: row["created_date"] ?? 0
            )
        }
    }

    /// 保留旧详情页的轻量正文/想法保存入口，不负责书籍、标签或附图变更。
    func saveNoteDetail(noteId: Int64, contentHTML: String, ideaHTML: String) async throws {
        let now = Self.currentTimestampMillis
        try await databaseManager.database.dbPool.write { db in
            try db.execute(
                // SQL 目的：更新笔记内容与更新时间戳（毫秒）。
                // 过滤条件：按 id 精确更新，且仅对未删除记录生效。
                // 副作用：只修改 content/idea/updated_date 三列，不触碰其他业务字段。
                sql: """
                    UPDATE note
                    SET content = ?, idea = ?, updated_date = ?
                    WHERE id = ? AND is_deleted = 0
                """,
                arguments: [contentHTML, ideaHTML, now, noteId]
            )
        }
    }

    /// 拉取书摘编辑页首屏所需草稿、恢复草稿与书/章/标签选项。
    func fetchNoteEditorBootstrap(mode: NoteEditorMode, seed: NoteEditorSeed?) async throws -> NoteEditorBootstrap {
        let noteID = mode.noteID
        let payload = try await databaseManager.database.dbPool.read { db in
            let books = try fetchNoteEditorBooks(db)
            let tags = try fetchNoteEditorTags(db)
            let baseDraft = try buildBaseDraft(db, mode: mode, seed: seed, books: books)
            let chapters = baseDraft.bookId > 0 ? try fetchNoteEditorChapters(db, bookId: baseDraft.bookId) : []
            return (books, tags, baseDraft, chapters)
        }
        let recoveredDraft = fetchNoteEditorDraft(bookId: payload.2.bookId, noteId: noteID)
        return NoteEditorBootstrap(
            mode: mode,
            baseDraft: payload.2,
            recoveredDraft: recoveredDraft,
            books: payload.0,
            tags: payload.1,
            chapters: payload.3
        )
    }

    /// 当切换书籍时，重新拉取当前书籍下的章节选项。
    func fetchNoteEditorChapters(bookId: Int64) async throws -> [NoteEditorChapterOption] {
        guard bookId > 0 else { return [] }
        return try await databaseManager.database.dbPool.read { db in
            try fetchNoteEditorChapters(db, bookId: bookId)
        }
    }

    /// 新建书摘标签；需遵循 Android 的长度与重名校验。
    func createNoteTag(named name: String) async throws -> NoteEditorTagOption {
        let normalizedName = Self.normalizeTagName(name)
        guard !normalizedName.isEmpty, normalizedName.count <= 100 else {
            throw NoteEditorError.invalidTagName
        }

        return try await databaseManager.database.dbPool.write { db in
            let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)

            // SQL 目的：校验 note 标签是否已存在，避免新增同名标签。
            // 表关系：单表 tag 查询。
            // 过滤条件：限定 tag.type = 0、同 owner、未软删除，完全对齐 Android note tag 判重语义。
            let duplicateSQL = """
                SELECT id
                FROM tag
                WHERE name = ? AND type = 0 AND user_id = ? AND is_deleted = 0
                LIMIT 1
                """
            if try Int64.fetchOne(db, sql: duplicateSQL, arguments: [normalizedName, ownerID]) != nil {
                throw NoteEditorError.duplicateTagName
            }

            let nextOrder = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(tag_order), -1) + 1 FROM tag WHERE type = 0 AND user_id = ?",
                arguments: [ownerID]
            )) ?? 0

            var record = TagRecord(
                id: nil,
                userId: ownerID,
                name: normalizedName,
                color: 0,
                tagOrder: nextOrder,
                type: 0,
                createdDate: Self.currentTimestampMillis,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
            return NoteEditorTagOption(id: record.id ?? 0, title: normalizedName)
        }
    }

    /// 将选中的本地图片暂存到编辑目录，供自动保存与后续上传复用。
    func stageNoteEditorImage(data: Data, preferredFileExtension: String) async throws -> NoteEditorImageItem {
        guard !data.isEmpty else {
            throw NoteEditorError.invalidImageData
        }

        let directoryURL = try stagedImageDirectory()
        let sanitizedExtension = Self.sanitizedImageFileExtension(preferredFileExtension)
        let fileURL = directoryURL.appendingPathComponent("\(UUID().uuidString).\(sanitizedExtension)")
        try data.write(to: fileURL, options: .atomic)

        return NoteEditorImageItem(
            id: UUID().uuidString,
            remoteURL: nil,
            localFilePath: fileURL.path,
            createdDate: Self.currentTimestampMillis,
            uploadState: .uploading
        )
    }

    /// 上传单张暂存附图，返回携带远端 URL 的最新条目。
    func uploadStagedNoteEditorImage(_ item: NoteEditorImageItem) async throws -> NoteEditorImageItem {
        if let remoteURL = item.remoteURL, !remoteURL.isEmpty {
            return item.updatingUploadState(.success)
        }

        guard let localFilePath = item.localFilePath, !localFilePath.isEmpty else {
            throw NoteEditorError.invalidImageData
        }
        guard fileManager.fileExists(atPath: localFilePath) else {
            throw NoteEditorError.invalidImageData
        }

        let result = try await s3UploadRepository.uploadFile(
            localURL: URL(fileURLWithPath: localFilePath),
            prefix: "note_image",
            progress: nil
        )
        return item.withUploadedRemoteURL(result.remoteURL.absoluteString)
    }

    /// 删除单张暂存附图，避免残留无效缓存文件。
    func removeStagedNoteEditorImage(_ item: NoteEditorImageItem) async {
        guard let localFilePath = item.localFilePath, !localFilePath.isEmpty else { return }
        try? fileManager.removeItem(atPath: localFilePath)
    }

    /// 保存当前编辑草稿，用于自动恢复。
    func saveNoteEditorDraft(_ draft: NoteEditorDraft) {
        let key = Self.noteDraftStorageKey(bookId: draft.bookId, noteId: draft.noteId)
        let previousDraft = fetchNoteEditorDraft(bookId: draft.bookId, noteId: draft.noteId)

        guard let data = try? jsonEncoder.encode(draft) else { return }
        userDefaults.set(data, forKey: key)

        guard let previousDraft else { return }
        cleanupDetachedLocalImages(previous: previousDraft, current: draft)
    }

    /// 读取指定书籍与书摘组合下的自动保存草稿。
    func fetchNoteEditorDraft(bookId: Int64, noteId: Int64) -> NoteEditorDraft? {
        let key = Self.noteDraftStorageKey(bookId: bookId, noteId: noteId)
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? jsonDecoder.decode(NoteEditorDraft.self, from: data)
    }

    /// 删除指定书籍与书摘组合下的自动保存草稿，并清理本地暂存图。
    func deleteNoteEditorDraft(bookId: Int64, noteId: Int64) {
        let key = Self.noteDraftStorageKey(bookId: bookId, noteId: noteId)
        if let draft = fetchNoteEditorDraft(bookId: bookId, noteId: noteId) {
            cleanupLocalImages(in: draft.imageItems)
        }
        userDefaults.removeObject(forKey: key)
    }

    /// 按 Android 事务语义保存新建/编辑后的书摘。
    func saveNoteEditor(_ draft: NoteEditorDraft) async throws -> Int64 {
        let validatedDraft = try validateEditorDraft(draft)
        let uploadedImages = try ensureReadyUploadedImages(for: validatedDraft.imageItems)

        let noteID = try await databaseManager.database.dbPool.write { db in
            let now = Self.currentTimestampMillis
            let noteID: Int64

            guard var book = try BookRecord.fetchOne(db, key: validatedDraft.bookId),
                  book.isDeleted == 0 else {
                throw NoteEditorError.bookRequired
            }

            if validatedDraft.noteId > 0 {
                guard var existing = try NoteRecord.fetchOne(db, key: validatedDraft.noteId),
                      existing.isDeleted == 0 else {
                    throw NoteEditorError.noteNotFound
                }

                existing.bookId = validatedDraft.bookId
                existing.chapterId = validatedDraft.chapterId
                existing.content = validatedDraft.contentHTML
                existing.idea = validatedDraft.ideaHTML
                existing.position = validatedDraft.position
                existing.positionUnit = validatedDraft.positionUnit
                existing.includeTime = validatedDraft.includeTime ? 1 : 0
                existing.createdDate = validatedDraft.createdDate
                existing.updatedDate = now
                try existing.update(db)
                noteID = validatedDraft.noteId
            } else {
                var record = NoteRecord(
                    id: nil,
                    bookId: validatedDraft.bookId,
                    chapterId: validatedDraft.chapterId,
                    content: validatedDraft.contentHTML,
                    idea: validatedDraft.ideaHTML,
                    position: validatedDraft.position,
                    positionUnit: book.positionUnit,
                    wereadRange: "",
                    includeTime: validatedDraft.includeTime ? 1 : 0,
                    createdDate: validatedDraft.createdDate,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
                try record.insert(db)
                guard let insertedID = record.id else {
                    throw NoteEditorError.noteNotFound
                }
                noteID = insertedID
            }

            try updateBookReadPositionIfNeeded(
                db,
                book: &book,
                draft: validatedDraft,
                isEditing: validatedDraft.noteId > 0
            )
            try replaceNoteTagAssociations(
                db,
                noteId: noteID,
                tags: validatedDraft.selectedTags,
                timestamp: now
            )
            try replaceNoteImages(
                db,
                noteId: noteID,
                images: uploadedImages,
                timestamp: now
            )

            return noteID
        }

        deleteNoteEditorDraft(bookId: validatedDraft.bookId, noteId: validatedDraft.noteId)
        cleanupLocalImages(in: validatedDraft.imageItems)
        return noteID
    }
}

private extension NoteRepository {
    nonisolated static var currentTimestampMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    nonisolated static func noteDraftStorageKey(bookId: Int64, noteId: Int64) -> String {
        "note_draft_\(bookId)_\(noteId)"
    }

    nonisolated static func normalizeTagName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func sanitizedImageFileExtension(_ rawValue: String) -> String {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
        return normalized.isEmpty ? "jpg" : normalized
    }

    func stagedImageDirectory() throws -> URL {
        let cachesDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = cachesDirectory.appendingPathComponent("NoteEditorStaging", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    func cleanupDetachedLocalImages(previous: NoteEditorDraft, current: NoteEditorDraft) {
        let currentLocalPaths = Set(current.imageItems.compactMap(\.localFilePath))
        for image in previous.imageItems {
            guard let localFilePath = image.localFilePath else { continue }
            guard !currentLocalPaths.contains(localFilePath) else { continue }
            try? fileManager.removeItem(atPath: localFilePath)
        }
    }

    func cleanupLocalImages(in items: [NoteEditorImageItem]) {
        for item in items {
            guard let localFilePath = item.localFilePath else { continue }
            try? fileManager.removeItem(atPath: localFilePath)
        }
    }

    nonisolated func fetchTagSections(_ db: Database) throws -> [TagSection] {
        // SQL 目的：读取标签列表并统计每个标签关联的有效笔记数。
        // 表关系：tag t LEFT JOIN tag_note tn（仅 tn.is_deleted = 0）。
        // 分组与排序：按标签 id 聚合计数，再按 type/tag_order 输出用于分组展示。
        let sql = """
            SELECT t.id, t.name, t.type, t.tag_order,
                   COUNT(tn.id) AS note_count
            FROM tag t
            LEFT JOIN tag_note tn ON t.id = tn.tag_id AND tn.is_deleted = 0
            WHERE t.is_deleted = 0
            GROUP BY t.id
            ORDER BY t.type ASC, t.tag_order ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)

        var noteTagItems: [Tag] = []
        var bookTagItems: [Tag] = []

        for row in rows {
            let id: Int64 = row["id"]
            let name: String = row["name"] ?? ""
            let type: Int64 = row["type"]
            let noteCount: Int = row["note_count"]
            let tag = Tag(id: id, name: name, noteCount: noteCount)

            if type == 0 {
                noteTagItems.append(tag)
            } else {
                bookTagItems.append(tag)
            }
        }

        var sections: [TagSection] = []
        if !noteTagItems.isEmpty {
            sections.append(TagSection(id: 0, title: "笔记标签", tags: noteTagItems))
        }
        if !bookTagItems.isEmpty {
            sections.append(TagSection(id: 1, title: "书籍标签", tags: bookTagItems))
        }
        return sections
    }

    nonisolated func fetchNoteEditorBooks(_ db: Database) throws -> [BookPickerBook] {
        // SQL 目的：读取编辑页可选书籍列表，供书卡选择 sheet 展示。
        // 涉及表：book。
        // 关键过滤：仅保留未软删除书籍；按 updated_date DESC 对齐 Android “上次编辑书籍优先”。
        let sql = """
            SELECT id, name, author, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE is_deleted = 0
            ORDER BY updated_date DESC, id DESC
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            BookPickerBook(
                id: row["id"],
                title: row["name"] ?? "",
                author: row["author"] ?? "",
                coverURL: row["cover"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                totalPosition: row["total_position"] ?? 0,
                totalPagination: row["total_pagination"] ?? 0
            )
        }
    }

    nonisolated func fetchNoteEditorTags(_ db: Database) throws -> [NoteEditorTagOption] {
        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        // SQL 目的：读取 note 标签列表，供编辑页标签多选与新增后回填使用。
        // 涉及表：tag。
        // 关键过滤：type = 0、同 owner、未软删除；排序按 tag_order ASC。
        let sql = """
            SELECT id, name
            FROM tag
            WHERE type = 0 AND user_id = ? AND is_deleted = 0
            ORDER BY tag_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [ownerID]).compactMap { row in
            guard let title: String = row["name"], !title.isEmpty else { return nil }
            return NoteEditorTagOption(id: row["id"], title: title)
        }
    }

    nonisolated func fetchNoteEditorChapters(_ db: Database, bookId: Int64) throws -> [NoteEditorChapterOption] {
        // SQL 目的：读取指定书籍下的章节列表，供书摘编辑页章节选择与恢复使用。
        // 涉及表：chapter。
        // 关键过滤：限定 book_id 且排除软删除；排序按 chapter_order ASC，再按 id ASC。
        let sql = """
            SELECT id, title
            FROM chapter
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY chapter_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [bookId]).compactMap { row in
            guard let title: String = row["title"], !title.isEmpty else { return nil }
            return NoteEditorChapterOption(id: row["id"], title: title)
        }
    }

    nonisolated func buildBaseDraft(
        _ db: Database,
        mode: NoteEditorMode,
        seed: NoteEditorSeed?,
        books: [BookPickerBook]
    ) throws -> NoteEditorDraft {
        switch mode {
        case .edit(let noteId):
            return try buildEditingDraft(db, noteId: noteId)
        case .create:
            return try buildCreatingDraft(db, seed: seed, books: books)
        }
    }

    nonisolated func buildEditingDraft(_ db: Database, noteId: Int64) throws -> NoteEditorDraft {
        // SQL 目的：拉取编辑态书摘详情，并补齐书籍与章节信息。
        // 涉及表：note INNER JOIN book LEFT JOIN chapter。
        // 关键过滤：note/book/chapter 均排除软删除；chapter 可为空。
        let sql = """
            SELECT n.id, n.book_id, n.content, n.idea, n.position, n.position_unit, n.include_time, n.created_date,
                   b.name AS book_name, b.author AS book_author, b.cover AS book_cover,
                   b.position_unit AS book_position_unit, b.total_position, b.total_pagination,
                   COALESCE(c.id, 0) AS chapter_id, COALESCE(c.title, '') AS chapter_title
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            LEFT JOIN chapter c ON c.id = n.chapter_id AND c.is_deleted = 0
            WHERE n.id = ? AND n.is_deleted = 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [noteId]) else {
            throw NoteEditorError.noteNotFound
        }

        return NoteEditorDraft(
            noteId: row["id"],
            bookId: row["book_id"],
            bookTitle: row["book_name"] ?? "",
            bookAuthor: row["book_author"] ?? "",
            bookCoverURL: row["book_cover"] ?? "",
            bookPositionUnit: row["book_position_unit"] ?? 0,
            bookTotalPosition: row["total_position"] ?? 0,
            bookTotalPagination: row["total_pagination"] ?? 0,
            contentHTML: row["content"] ?? "",
            ideaHTML: row["idea"] ?? "",
            position: row["position"] ?? "",
            positionUnit: row["position_unit"] ?? 0,
            includeTime: (row["include_time"] as Int64? ?? 1) != 0,
            createdDate: row["created_date"] ?? Self.currentTimestampMillis,
            chapterId: row["chapter_id"] ?? 0,
            chapterTitle: row["chapter_title"] ?? "",
            selectedTags: try fetchSelectedTags(db, noteId: noteId),
            imageItems: try fetchEditorImages(db, noteId: noteId),
            lastAutoSaveTime: 0
        )
    }

    nonisolated func buildCreatingDraft(
        _ db: Database,
        seed: NoteEditorSeed?,
        books: [BookPickerBook]
    ) throws -> NoteEditorDraft {
        let selectedBook = resolveSeedBook(seed?.bookId, books: books)
        let chapterOption = try resolveSeedChapter(db, bookId: selectedBook?.id ?? 0, chapterId: seed?.chapterId)
        let timestamp = Self.currentTimestampMillis

        return NoteEditorDraft(
            noteId: 0,
            bookId: selectedBook?.id ?? 0,
            bookTitle: selectedBook?.title ?? "",
            bookAuthor: selectedBook?.author ?? "",
            bookCoverURL: selectedBook?.coverURL ?? "",
            bookPositionUnit: selectedBook?.positionUnit ?? 0,
            bookTotalPosition: selectedBook?.totalPosition ?? 0,
            bookTotalPagination: selectedBook?.totalPagination ?? 0,
            contentHTML: seed?.contentHTML ?? "",
            ideaHTML: seed?.ideaHTML ?? "",
            position: "",
            positionUnit: selectedBook?.positionUnit ?? 0,
            includeTime: true,
            createdDate: timestamp,
            chapterId: chapterOption?.id ?? 0,
            chapterTitle: chapterOption?.title ?? "",
            selectedTags: [],
            imageItems: [],
            lastAutoSaveTime: 0
        )
    }

    nonisolated func resolveSeedBook(_ bookId: Int64?, books: [BookPickerBook]) -> BookPickerBook? {
        if let bookId, bookId > 0 {
            return books.first(where: { $0.id == bookId })
        }
        return books.first
    }

    nonisolated func resolveSeedChapter(
        _ db: Database,
        bookId: Int64,
        chapterId: Int64?
    ) throws -> NoteEditorChapterOption? {
        guard bookId > 0, let chapterId, chapterId > 0 else { return nil }
        return try fetchNoteEditorChapters(db, bookId: bookId).first(where: { $0.id == chapterId })
    }

    nonisolated func fetchSelectedTags(_ db: Database, noteId: Int64) throws -> [NoteEditorTagOption] {
        // SQL 目的：读取指定书摘当前已选标签。
        // 表关系：tag_note INNER JOIN tag。
        // 关键过滤：tag_note/tag 均为未软删除记录，且 tag.type = 0。
        let sql = """
            SELECT t.id, t.name
            FROM tag_note tn
            JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0
            WHERE tn.note_id = ? AND tn.is_deleted = 0 AND t.type = 0
            ORDER BY t.tag_order ASC, tn.id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [noteId]).compactMap { row in
            guard let title: String = row["name"], !title.isEmpty else { return nil }
            return NoteEditorTagOption(id: row["id"], title: title)
        }
    }

    nonisolated func fetchEditorImages(_ db: Database, noteId: Int64) throws -> [NoteEditorImageItem] {
        // SQL 目的：读取指定书摘当前附图列表。
        // 表关系：attach_image。
        // 关键过滤：限定 note_id 且排除软删除；排序按 id ASC 对齐 Android 展示顺序。
        let sql = """
            SELECT id, image_url, created_date
            FROM attach_image
            WHERE note_id = ? AND is_deleted = 0
            ORDER BY id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [noteId]).map { row in
            NoteEditorImageItem(
                id: "remote-\(row["id"] as Int64? ?? 0)",
                remoteURL: row["image_url"] ?? "",
                localFilePath: nil,
                createdDate: row["created_date"] ?? 0
            )
        }
    }

    func validateEditorDraft(_ draft: NoteEditorDraft) throws -> NoteEditorDraft {
        var normalized = draft
        normalized.position = draft.position.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.chapterTitle = draft.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.selectedTags = draft.selectedTags.sorted { $0.title < $1.title }
        normalized.lastAutoSaveTime = 0

        let contentText = RichTextBridge.htmlToAttributed(normalized.contentHTML)
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ideaText = RichTextBridge.htmlToAttributed(normalized.ideaHTML)
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.bookId > 0 else {
            throw NoteEditorError.bookRequired
        }
        guard !contentText.isEmpty || !ideaText.isEmpty || !normalized.imageItems.isEmpty else {
            throw NoteEditorError.contentRequired
        }
        if !normalized.position.isEmpty, let readPosition = Double(normalized.position) {
            try validateReadPosition(
                readPosition,
                positionUnit: normalized.positionUnit,
                totalPosition: normalized.bookTotalPosition,
                totalPagination: normalized.bookTotalPagination
            )
        }
        return normalized
    }

    nonisolated func validateReadPosition(
        _ readPosition: Double,
        positionUnit: Int64,
        totalPosition: Int64,
        totalPagination: Int64
    ) throws {
        if positionUnit == 1 && totalPosition != 0 {
            if readPosition <= 0 {
                throw NoteEditorError.invalidReadPosition("页码应大于 0 页")
            }
            if readPosition > Double(totalPosition) {
                throw NoteEditorError.invalidReadPosition("页码应小于总页码（\(totalPosition) 页）")
            }
        }
        if positionUnit == 0 && totalPagination != 0 {
            if readPosition <= 0 {
                throw NoteEditorError.invalidReadPosition("页码应大于 0 页")
            }
            if readPosition > Double(totalPagination) {
                throw NoteEditorError.invalidReadPosition("页码应小于总页码（\(totalPagination) 页）")
            }
        }
        if positionUnit == 2, readPosition < 0 || readPosition > 100 {
            throw NoteEditorError.invalidReadPosition("进度值应在 [0,100] 区间内")
        }
    }

    func ensureReadyUploadedImages(for items: [NoteEditorImageItem]) throws -> [NoteEditorImageItem] {
        var readyImages: [NoteEditorImageItem] = []
        readyImages.reserveCapacity(items.count)

        for item in items {
            switch item.uploadState {
            case .uploading:
                throw NoteEditorError.imageUploadInProgress
            case .failed:
                throw NoteEditorError.imageUploadFailed
            case .success:
                guard let remoteURL = item.remoteURL, !remoteURL.isEmpty else {
                    throw NoteEditorError.invalidImageData
                }
                readyImages.append(
                    NoteEditorImageItem(
                        id: item.id,
                        remoteURL: remoteURL,
                        localFilePath: item.localFilePath,
                        createdDate: item.createdDate,
                        uploadState: .success
                    )
                )
            }
        }

        return readyImages
    }

    nonisolated func updateBookReadPositionIfNeeded(
        _ db: Database,
        book: inout BookRecord,
        draft: NoteEditorDraft,
        isEditing: Bool
    ) throws {
        guard !draft.position.isEmpty else { return }
        let readPosition = Double(draft.position) ?? 0

        if !isEditing {
            if book.currentPositionUnit == book.positionUnit {
                book.readPosition = max(book.readPosition, readPosition)
            } else {
                book.currentPositionUnit = book.positionUnit
                book.readPosition = readPosition
            }
            try book.update(db)
            return
        }

        if book.positionUnit == draft.positionUnit {
            book.currentPositionUnit = book.positionUnit
            book.readPosition = max(book.readPosition, readPosition)
            try book.update(db)
        }
    }

    nonisolated func replaceNoteTagAssociations(
        _ db: Database,
        noteId: Int64,
        tags: [NoteEditorTagOption],
        timestamp: Int64
    ) throws {
        try db.execute(
            // SQL 目的：软删除指定书摘的现有关联标签，随后按当前选择重建最新关系。
            // 表关系：tag_note。
            // 关键过滤：按 note_id 精确命中且仅更新当前有效记录。
            sql: """
                UPDATE tag_note
                SET is_deleted = 1, updated_date = ?
                WHERE note_id = ? AND is_deleted = 0
                """,
            arguments: [timestamp, noteId]
        )

        for tag in tags {
            var record = TagNoteRecord(
                id: nil,
                tagId: tag.id,
                noteId: noteId,
                createdDate: timestamp,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
        }
    }

    nonisolated func replaceNoteImages(
        _ db: Database,
        noteId: Int64,
        images: [NoteEditorImageItem],
        timestamp: Int64
    ) throws {
        try db.execute(
            // SQL 目的：软删除指定书摘的现有附图，随后按当前展示顺序重建附图记录。
            // 表关系：attach_image。
            // 关键过滤：按 note_id 精确命中且仅更新当前有效记录。
            sql: """
                UPDATE attach_image
                SET is_deleted = 1, updated_date = ?
                WHERE note_id = ? AND is_deleted = 0
                """,
            arguments: [timestamp, noteId]
        )

        for image in images {
            guard let remoteURL = image.remoteURL, !remoteURL.isEmpty else { continue }
            var record = AttachImageRecord(
                id: nil,
                noteId: noteId,
                imageUrl: remoteURL,
                createdDate: timestamp,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
        }
    }
}
