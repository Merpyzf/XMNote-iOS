import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供本地数据库连接，依赖 ObservationStream 提供观察流桥接，依赖 UserDefaults/FileManager/S3UploadRepository 承接草稿、暂存图与上传事务
 * [OUTPUT]: 对外提供 NoteRepository（NoteRepositoryProtocol 的 GRDB 实现）、有效章节语义的回顾卡片、纸流轻量布局源及跳过首个观察基线的变化信号，覆盖聚合列表、章节范围、批量写入、合并、编辑草稿与保存事务
 * [POS]: Data 层笔记仓储实现，统一收口书摘读取、iOS 已批准硬删除、关系替换、跨书章节迁移与合并原子事务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 笔记仓储实现，负责聚合订阅、批量操作、合并与书摘编辑完整数据链路。
struct NoteRepository: NoteRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let userDefaults: UserDefaults
    private let s3UploadRepository: any S3UploadRepositoryProtocol
    private let fileManager: FileManager
    private let noteReviewSettingStore: NoteReviewSettingStore
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    /// 注入数据库、草稿存储与图片上传依赖，统一承接书摘编辑完整链路。
    init(
        databaseManager: DatabaseManager,
        userDefaults: UserDefaults = .standard,
        s3UploadRepository: any S3UploadRepositoryProtocol,
        fileManager: FileManager = .default,
        noteReviewSettingStore: NoteReviewSettingStore = .shared
    ) {
        self.databaseManager = databaseManager
        self.userDefaults = userDefaults
        self.s3UploadRepository = s3UploadRepository
        self.fileManager = fileManager
        self.noteReviewSettingStore = noteReviewSettingStore
    }

    /// 为笔记主页提供标签分组订阅流，标签或标签关联变更后自动刷新分组计数。
    func observeTagSections() -> AsyncThrowingStream<[TagSection], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchTagSections(db)
        }
    }

    /// 观察首页默认分组与用户书摘标签；底层表变化后重新计算真实计数。
    func observeNoteHomeSnapshot() -> AsyncThrowingStream<NoteHomeSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchNoteHomeSnapshot(db)
        }
    }

    /// 观察当前 scope 下的一页书摘；搜索条件在 Repository 内与 scope 合并，避免越界成全局搜索。
    func observeNoteExcerptList(request: NoteExcerptPageRequest) -> AsyncThrowingStream<NoteExcerptListSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchNoteExcerptList(db, request: request)
        }
    }

    /// 观察指定章节范围的一页书摘；观察任务由调用方取消，Repository 每次都在同一数据库快照内重算后代范围与分页。
    func observeChapterNoteList(request: ChapterNotePageRequest) -> AsyncThrowingStream<NoteExcerptListSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchChapterNoteList(db, request: request)
        }
    }

    /// 观察星标章节分组；章节树、后代范围与书摘数均在同一数据库快照内计算。
    func observeStarredChapterGroups(request: StarredChapterRequest) -> AsyncThrowingStream<[StarredChapterGroup], Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchStarredChapterGroups(db, request: request)
        }
    }

    /// 更新章节星标状态；只允许修改有效的非根章节。
    func setChapterStarred(chapterID: Int64, isStarred: Bool) async throws {
        guard chapterID > 0 else { throw NoteCollectionRepositoryError.invalidChapter }
        let now = Self.currentTimestampMillis
        try await databaseManager.database.dbPool.write { db in
            try db.execute(
                // SQL 目的：设置单个有效章节的星标状态，并写入变更时间供“最近变更”排序。
                // 涉及表：chapter。
                // 关键过滤：按 chapter.id 精确命中，排除系统根章节与已删除章节。
                // 时间字段：updated_date 使用本地当前毫秒时间戳，不做时区换算。
                // 副作用：只更新 is_starred/updated_date；书摘和章节树结构不变。
                sql: """
                    UPDATE chapter
                    SET is_starred = ?, updated_date = ?
                    WHERE id = ? AND id != 0 AND is_deleted = 0
                """,
                arguments: [isStarred ? 1 : 0, now, chapterID]
            )
            guard db.changesCount > 0 else { throw NoteCollectionRepositoryError.chapterNotFound }
        }
    }

    /// 观察相关分类入口，按精确标题跨书聚合并固定“全部相关”为第一项。
    func observeRelatedCategories(request: RelatedCategoryRequest) -> AsyncThrowingStream<RelatedCategorySnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchRelatedCategorySnapshot(db, request: request)
        }
    }

    /// 观察当前相关分类作用域内的一页普通内容与相关书籍混排项。
    func observeRelatedContentList(request: RelatedContentPageRequest) -> AsyncThrowingStream<RelatedContentListSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchRelatedContentList(db, request: request)
        }
    }

    /// 删除首页相关聚合项；系统默认分类只清空同名聚合内容，自定义分类连同跨书同名定义一起软删除。
    func deleteRelatedCategory(scope: RelatedCategoryScope) async throws {
        guard case .title(let rawTitle) = scope else {
            throw NoteCollectionRepositoryError.cannotDeleteAllRelated
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NoteCollectionRepositoryError.relatedCategoryNotFound }

        try await databaseManager.database.dbPool.write { db in
            try softDeleteRelatedCategoryAggregation(db, title: title)
        }
    }

    /// 观察全量书评页，字数排序使用去除富文本后的可见正文长度。
    func observeBookReviewList(request: BookReviewPageRequest) -> AsyncThrowingStream<BookReviewListSnapshot, Error> {
        ObservationStream.make(in: databaseManager.database.dbPool) { db in
            try fetchBookReviewList(db, request: request)
        }
    }

    /// 读取书摘回顾设置，供回顾页恢复筛选范围与外观偏好。
    func fetchNoteReviewSettings() -> NoteReviewSettings {
        noteReviewSettingStore.fetchSettings()
    }

    /// 保存书摘回顾设置，并通过设置存储广播变更事件。
    func saveNoteReviewSettings(_ settings: NoteReviewSettings) {
        noteReviewSettingStore.save(settings)
    }

    /// 观察书摘回顾设置变更，供页面在外部设置入口写入后同步刷新。
    func observeNoteReviewSettingChanges() -> AsyncStream<Void> {
        noteReviewSettingStore.observeChanges()
    }

    /// 将回顾依赖的数据库表变化桥接为无载荷事件；观察任务由调用方取消，避免保活页面释放后继续占用数据库观察资源。
    func observeNoteReviewDataChanges() -> AsyncThrowingStream<Void, Error> {
        ObservationStream.makeChangeSignal(in: databaseManager.database.dbPool) { db in
            try noteReviewDataFingerprint(db)
        }
    }

    /// 使用当前 S3 配置上传回顾背景图；对象键由统一上传仓储生成，避免 ViewModel 直接依赖网络客户端。
    func uploadNoteReviewBackground(localURL: URL) async throws -> S3UploadResult {
        try await s3UploadRepository.uploadFile(localURL: localURL, prefix: "note_review_background", progress: nil)
    }

    /// 下载回顾背景图；网络响应必须是成功状态，避免把错误页面当作图片交给分享渲染器。
    func fetchNoteReviewBackgroundData(remoteURL: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// 按当前筛选与排序读取一页书摘回顾卡片。
    func fetchNoteReviewPage(request: NoteReviewPageRequest) async throws -> [NoteReviewCardItem] {
        try await databaseManager.database.dbPool.read { db in
            try fetchNoteReviewPage(db, request: request)
        }
    }

    /// 使用卡堆相同的数据范围读取完整轻量身份序列；随机会话在主键序列之上自行洗牌。
    func fetchNoteReviewIDs(settings: NoteReviewSettings) async throws -> [Int64] {
        try await databaseManager.database.dbPool.read { db in
            try fetchNoteReviewIDs(db, settings: settings)
        }
    }

    /// 异步按输入顺序读取纸流测高字段；数据库等待不占用主线程，读取事务内的每条 SQL 最多绑定 128 个书摘 ID。
    func fetchNoteReviewOverviewLayoutSources(
        noteIDs: [Int64]
    ) async throws -> [NoteReviewOverviewLayoutSource] {
        try await databaseManager.database.dbPool.read { db in
            try fetchNoteReviewOverviewLayoutSources(db, noteIDs: noteIDs)
        }
    }

    /// 按主键读取单个书摘操作上下文，避免当日记录页为定位一条书摘加载整页回顾数据。
    func fetchNoteReviewItem(noteID: Int64) async throws -> NoteReviewCardItem? {
        try await databaseManager.database.dbPool.read { db in
            try fetchNoteReviewItem(db, noteID: noteID)
        }
    }

    /// 批量读取书摘操作上下文，在一个读事务内补齐标签、图片与微信读书跳转信息。
    func fetchNoteReviewItems(noteIDs: [Int64]) async throws -> [NoteReviewCardItem] {
        try await databaseManager.database.dbPool.read { db in
            try fetchNoteReviewItems(db, noteIDs: noteIDs)
        }
    }

    /// 读取书摘标签筛选选项，附带有效书摘数量。
    func fetchNoteReviewTagOptions() async throws -> [NoteReviewTagOption] {
        try await databaseManager.database.dbPool.read { db in
            try fetchNoteReviewTagOptions(db)
        }
    }

    /// 读取当前回顾卡片标签编辑所需的全部标签与已选标签。
    func fetchNoteReviewTagEditSnapshot(noteID: Int64) async throws -> NoteReviewTagEditSnapshot {
        try await databaseManager.database.dbPool.read { db in
            NoteReviewTagEditSnapshot(
                availableTags: try fetchNoteEditorTags(db),
                selectedTags: try fetchSelectedTags(db, noteId: noteID)
            )
        }
    }

    /// 替换当前回顾卡片的书摘标签，并返回数据库确认后的最新选中标签。
    func replaceNoteReviewTags(noteID: Int64, tags: [NoteEditorTagOption]) async throws -> [NoteEditorTagOption] {
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：确认目标书摘仍存在且未被软删除，避免给已删除书摘写入标签关系。
            // 涉及表：note。
            // 关键过滤：按 note.id 精确命中，并排除 note.is_deleted=1 的记录。
            // 时间字段：不读取时间字段；后续 tag_note 写入使用当前本地毫秒时间戳。
            // 返回字段用途：仅作为写入前存在性门闩，不参与 UI 展示。
            let existsSQL = """
                SELECT id
                FROM note
                WHERE id = ? AND is_deleted = 0
                LIMIT 1
                """
            guard try Int64.fetchOne(db, sql: existsSQL, arguments: [noteID]) != nil else {
                throw NoteEditorError.noteNotFound
            }

            let availableByID = Dictionary(
                uniqueKeysWithValues: try fetchNoteEditorTags(db).map { ($0.id, $0) }
            )
            var seen = Set<Int64>()
            let validTags = tags.compactMap { tag -> NoteEditorTagOption? in
                guard tag.id > 0, !seen.contains(tag.id), let available = availableByID[tag.id] else {
                    return nil
                }
                seen.insert(tag.id)
                return available
            }
            try replaceNoteTagAssociations(
                db,
                noteId: noteID,
                tags: validTags,
                timestamp: Self.currentTimestampMillis
            )
            return try fetchSelectedTags(db, noteId: noteID)
        }
    }

    /// 在单一事务中物理增删爱心所绑定的标签关系，不创建独立收藏数据。
    func setNoteTagMembership(noteID: Int64, tagID: Int64, isPresent: Bool) async throws {
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：确认收藏目标仍是有效书摘，阻止给已删除记录追加标签关系。
            // 涉及表：note。
            // 关键过滤：按主键精确命中且 is_deleted = 0。
            // 时间字段：不读取时间；新增关系使用下方当前 Unix 毫秒时间戳。
            // 返回字段用途：仅作为事务写入前的存在性门闩。
            let noteExistsSQL = """
                SELECT id
                FROM note
                WHERE id = ? AND is_deleted = 0
                LIMIT 1
                """
            guard try Int64.fetchOne(db, sql: noteExistsSQL, arguments: [noteID]) != nil else {
                throw NoteEditorError.noteNotFound
            }

            // SQL 目的：确认绑定目标为仍有效的自定义书摘标签。
            // 涉及表：tag。
            // 关键过滤：按主键精确命中、type = 1 且 is_deleted = 0。
            // 时间字段：不读取时间字段。
            // 返回字段用途：仅作为关系写入的外键与业务类型校验。
            let tagExistsSQL = """
                SELECT id
                FROM tag
                WHERE id = ? AND type = 1 AND is_deleted = 0
                LIMIT 1
                """
            guard try Int64.fetchOne(db, sql: tagExistsSQL, arguments: [tagID]) != nil else {
                throw NoteEditorError.invalidTagName
            }

            // SQL 目的：物理移除目标书摘与标签的所有历史关系，既用于取消收藏，也用于新增前清理旧 tombstone。
            // 涉及表：tag_note。
            // 关键过滤：同时按 note_id 与 tag_id 精确命中，不区分 is_deleted，确保关系唯一。
            // 时间字段：不读取或写入时间字段。
            // 副作用：遵循项目批准的全局硬删除规则；不会影响书摘上的其他标签关系。
            let deleteMembershipSQL = """
                DELETE FROM tag_note
                WHERE note_id = ? AND tag_id = ?
                """
            try db.execute(sql: deleteMembershipSQL, arguments: [noteID, tagID])

            guard isPresent else { return }
            let timestamp = Self.currentTimestampMillis
            var record = TagNoteRecord(
                id: nil,
                tagId: tagID,
                noteId: noteID,
                createdDate: timestamp,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try record.insert(db)
        }
    }

    /// 按设置中保存的书籍 ID 读取回显书籍，输出顺序跟随设置保存顺序。
    func fetchNoteReviewSelectedBooks(bookIDs: [Int64]) async throws -> [BookPickerBook] {
        try await databaseManager.database.dbPool.read { db in
            try fetchNoteReviewSelectedBooks(db, bookIDs: bookIDs)
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
            if let existing = try NoteRecord.fetchOne(db, key: noteId), existing.isDeleted == 0 {
                _ = try ensureImportHashes(db, note: existing)
            }
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
            // 过滤条件：限定 tag.type = 1、同 owner、未软删除，完全对齐 Android note tag 判重语义。
            let duplicateSQL = """
                SELECT id
                FROM tag
                WHERE name = ? AND type = 1 AND user_id = ? AND is_deleted = 0
                LIMIT 1
                """
            if try Int64.fetchOne(db, sql: duplicateSQL, arguments: [normalizedName, ownerID]) != nil {
                throw NoteEditorError.duplicateTagName
            }

            let nextOrder = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(tag_order), -1) + 1 FROM tag WHERE type = 1 AND user_id = ?",
                arguments: [ownerID]
            )) ?? 0

            var record = TagRecord(
                id: nil,
                userId: ownerID,
                name: normalizedName,
                color: 0,
                tagOrder: nextOrder,
                type: 1,
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
            uploadState: .uploading,
            origin: .newInDraft
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

                if existing.bookId == validatedDraft.bookId {
                    _ = try ensureImportHashes(db, note: existing)
                } else {
                    try moveImportHashes(db, note: existing, targetBookID: validatedDraft.bookId)
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

/// 笔记聚合查询的业务错误。
nonisolated enum NoteCollectionRepositoryError: LocalizedError {
    case invalidChapter
    case chapterNotFound
    case cannotDeleteAllRelated
    case relatedCategoryNotFound

    var errorDescription: String? {
        switch self {
        case .invalidChapter: "未指定章节不可星标"
        case .chapterNotFound: "章节不存在"
        case .cannotDeleteAllRelated: "“全部相关”不能删除"
        case .relatedCategoryNotFound: "相关分类不存在"
        }
    }
}

private nonisolated struct NoteCollectionSQLFilter {
    var predicates: [String]
    var arguments: [(any DatabaseValueConvertible)?]
}

private struct StarredChapterDatabaseItem {
    let id: Int64
    let bookID: Int64
    let parentID: Int64
    let title: String
    let updatedDate: Int64
    let isStarred: Bool
}

private extension NoteRepository {
    /// 读取首页默认分组与用户书摘标签，所有计数仅包含有效书籍下的有效书摘。
    nonisolated func fetchNoteHomeSnapshot(_ db: Database) throws -> NoteHomeSnapshot {
        // SQL 目的：一次聚合首页四个默认书摘分组的真实数量。
        // 涉及表：note INNER JOIN book；tag_note/tag/attach_image 通过 EXISTS 子查询判定分组归属。
        // 关键过滤：排除已删除书摘与书籍；“无标签”只把有效书摘标签关系计为标签；图片分组只认有效附图。
        // 时间字段：不读取时间字段。
        // 返回字段用途：构建固定顺序的默认分组计数。
        let defaultCountSQL = """
            SELECT
                COUNT(*) AS all_count,
                SUM(CASE WHEN NOT EXISTS (
                    SELECT 1
                    FROM tag_note tn
                    JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
                    WHERE tn.note_id = n.id AND tn.is_deleted = 0
                ) THEN 1 ELSE 0 END) AS untagged_count,
                SUM(CASE WHEN trim(COALESCE(n.idea, '')) != '' THEN 1 ELSE 0 END) AS idea_count,
                SUM(CASE WHEN EXISTS (
                    SELECT 1 FROM attach_image ai
                    WHERE ai.note_id = n.id AND ai.is_deleted = 0
                ) THEN 1 ELSE 0 END) AS image_count
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE n.is_deleted = 0
            """
        let countRow = try Row.fetchOne(db, sql: defaultCountSQL)
        let defaultGroups = [
            NoteExcerptGroupItem(scope: .all, title: "所有书摘", count: countRow?["all_count"] ?? 0, order: 0),
            NoteExcerptGroupItem(scope: .untagged, title: "不含标签", count: countRow?["untagged_count"] ?? 0, order: 1),
            NoteExcerptGroupItem(scope: .withIdea, title: "包含想法", count: countRow?["idea_count"] ?? 0, order: 2),
            NoteExcerptGroupItem(scope: .withImages, title: "包含图片", count: countRow?["image_count"] ?? 0, order: 3)
        ]

        let ownerID = try DatabaseOwnerResolver.fetchExistingOwnerID(in: db) ?? 0
        // SQL 目的：读取当前用户的书摘标签及有效书摘计数，禁止把 type=2 的书籍标签混入笔记首页。
        // 涉及表：tag LEFT JOIN tag_note LEFT JOIN note LEFT JOIN book。
        // 关键过滤：tag.type=1、同 owner 且 tag 有效；COUNT 只统计关系、书摘、书籍均有效的记录。
        // 排序：按 Android tag_order ASC，再按 id 稳定兜底。
        // 时间字段：不读取时间字段。
        // 返回字段用途：构建“我的标签”入口与计数。
        let userTagSQL = """
            SELECT t.id, COALESCE(t.name, '') AS name, t.tag_order,
                   COUNT(DISTINCT CASE WHEN tn.is_deleted = 0
                                            AND n.is_deleted = 0
                                            AND b.is_deleted = 0
                                            AND b.id != 0
                                       THEN n.id END) AS note_count
            FROM tag t
            LEFT JOIN tag_note tn ON tn.tag_id = t.id
            LEFT JOIN note n ON n.id = tn.note_id
            LEFT JOIN book b ON b.id = n.book_id
            WHERE t.type = 1 AND t.user_id = ? AND t.is_deleted = 0
            GROUP BY t.id
            ORDER BY t.tag_order ASC, t.id ASC
            """
        let userTags = try Row.fetchAll(db, sql: userTagSQL, arguments: [ownerID]).map { row in
            NoteExcerptGroupItem(
                scope: .tag(id: row["id"]),
                title: row["name"] ?? "",
                count: row["note_count"] ?? 0,
                order: row["tag_order"] ?? 0
            )
        }
        return NoteHomeSnapshot(defaultGroups: defaultGroups, userTags: userTags)
    }

    /// 读取当前 scope 的书摘页；时间排序走 SQL 分页，随机排序先稳定打散 ID 再回表读取当前页。
    nonisolated func fetchNoteExcerptList(
        _ db: Database,
        request: NoteExcerptPageRequest
    ) throws -> NoteExcerptListSnapshot {
        let filter = noteExcerptFilter(
            scope: request.scope,
            query: request.query,
            searchScope: request.searchScope
        )
        let whereClause = filter.predicates.joined(separator: "\n              AND ")

        // SQL 目的：统计当前 scope 与搜索条件共同命中的书摘总数。
        // 涉及表：note INNER JOIN book；scope 通过 tag_note/tag/attach_image 子查询表达。
        // 关键过滤：搜索与 scope 使用 AND，排除无效书摘和书籍。
        // 时间字段：不读取时间字段。
        // 返回字段用途：分页 hasMore 与空态判断。
        let countSQL = """
            SELECT COUNT(*)
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE \(whereClause)
            """
        let arguments = StatementArguments(filter.arguments)
        let totalCount = try Int.fetchOne(db, sql: countSQL, arguments: arguments) ?? 0

        let rows: [Row]
        switch request.sort {
        case .createdAscending, .createdDescending:
            let direction = request.sort == .createdAscending ? "ASC" : "DESC"
            var pageArguments = filter.arguments
            pageArguments.append(Int64(request.limit))
            pageArguments.append(Int64(request.offset))
            rows = try Row.fetchAll(
                db,
                sql: noteExcerptSelectSQL(
                    whereClause: whereClause,
                    suffix: "ORDER BY n.created_date \(direction), n.id \(direction) LIMIT ? OFFSET ?"
                ),
                arguments: StatementArguments(pageArguments)
            )
        case .random:
            // SQL 目的：读取当前筛选范围的完整稳定 ID 集合；随机分值在内存侧由 request.randomSeed 确定。
            // 涉及表：note INNER JOIN book，并复用与计数完全相同的 scope/search 条件。
            // 关键过滤：排除已删除书摘和书籍。
            // 排序：数据库先按 id 输出，最终由稳定哈希重排。
            // 时间字段：不读取时间字段。
            // 返回字段用途：确保分页和 Viewer 在同一 seed 下得到相同顺序。
            let idSQL = """
                SELECT n.id
                FROM note n
                JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
                WHERE \(whereClause)
                ORDER BY n.id ASC
                """
            let allIDs = try Int64.fetchAll(db, sql: idSQL, arguments: arguments)
            let orderedIDs = Self.stablyShuffledIDs(allIDs, seed: request.randomSeed)
            let pageIDs = Array(orderedIDs.dropFirst(request.offset).prefix(request.limit))
            rows = try fetchNoteExcerptRows(db, filter: filter, orderedIDs: pageIDs)
        }

        return try buildNoteExcerptSnapshot(db, rows: rows, totalCount: totalCount)
    }

    /// 读取指定章节范围的一页书摘，后代章节集合与结果行在同一数据库读取快照中完成。
    nonisolated func fetchChapterNoteList(
        _ db: Database,
        request: ChapterNotePageRequest
    ) throws -> NoteExcerptListSnapshot {
        guard request.bookID > 0 else { throw NoteBatchMutationError.bookNotFound }
        var filter = NoteCollectionSQLFilter(
            predicates: ["n.is_deleted = 0", "n.book_id = ?"],
            arguments: [request.bookID]
        )

        if request.chapterID > 0 {
            let chapterIDs = try fetchChapterScopeIDs(
                db,
                bookID: request.bookID,
                chapterID: request.chapterID,
                includesDescendants: request.includesDescendants
            )
            filter.predicates.append("n.chapter_id IN (\(Self.placeholders(count: chapterIDs.count)))")
            for chapterID in chapterIDs {
                filter.arguments.append(chapterID)
            }
        }

        let keyword = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            let pattern = "%\(Self.escapeLikePattern(keyword))%"
            filter.predicates.append("""
                (COALESCE(n.content, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(n.idea, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
                """)
            filter.arguments.append(pattern)
            filter.arguments.append(pattern)
        }

        let whereClause = filter.predicates.joined(separator: "\n              AND ")
        // SQL 目的：统计指定书籍章节范围与局部搜索共同命中的有效书摘数量。
        // 涉及表：note INNER JOIN book；章节范围已在同一读取快照中解析为明确 ID 集合。
        // 关键过滤：限定 book_id、可选 chapter_id 集、note/book 有效状态与正文/想法搜索词。
        // 时间字段：不读取时间字段。
        // 返回字段用途：驱动分页 hasMore 与局部空态。
        let countSQL = """
            SELECT COUNT(*)
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE \(whereClause)
            """
        let arguments = StatementArguments(filter.arguments)
        let totalCount = try Int.fetchOne(db, sql: countSQL, arguments: arguments) ?? 0

        let rows: [Row]
        switch request.sort {
        case .createdAscending, .createdDescending:
            let direction = request.sort == .createdAscending ? "ASC" : "DESC"
            var pageArguments = filter.arguments
            pageArguments.append(Int64(request.limit))
            pageArguments.append(Int64(request.offset))
            rows = try Row.fetchAll(
                db,
                sql: noteExcerptSelectSQL(
                    whereClause: whereClause,
                    suffix: "ORDER BY n.created_date \(direction), n.id \(direction) LIMIT ? OFFSET ?"
                ),
                arguments: StatementArguments(pageArguments)
            )
        case .random:
            // SQL 目的：读取当前章节与搜索范围内的完整有效书摘 ID，供稳定随机分页使用。
            // 涉及表：note INNER JOIN book。
            // 关键过滤：完全复用计数查询的书籍、章节与搜索条件。
            // 排序：先按主键稳定输出，再由 randomSeed 的稳定哈希排序。
            // 时间字段：不读取时间字段。
            // 返回字段用途：从稳定顺序截取当前页后回表补齐卡片字段。
            let idSQL = """
                SELECT n.id
                FROM note n
                JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
                WHERE \(whereClause)
                ORDER BY n.id ASC
                """
            let allIDs = try Int64.fetchAll(db, sql: idSQL, arguments: arguments)
            let orderedIDs = Self.stablyShuffledIDs(allIDs, seed: request.randomSeed)
            let pageIDs = Array(orderedIDs.dropFirst(request.offset).prefix(request.limit))
            rows = try fetchNoteExcerptRows(db, filter: filter, orderedIDs: pageIDs)
        }

        return try buildNoteExcerptSnapshot(
            db,
            rows: rows,
            totalCount: totalCount
        )
    }

    /// 将同源 SQL 行批量补齐标签和附图，避免章节列表与默认分组列表产生映射分叉。
    nonisolated func buildNoteExcerptSnapshot(
        _ db: Database,
        rows: [Row],
        totalCount: Int
    ) throws -> NoteExcerptListSnapshot {
        let noteIDs: [Int64] = rows.map { $0["id"] }
        let tagsByNoteID = try batchFetchNoteExcerptTags(db, noteIDs: noteIDs)
        let imageURLsByNoteID = try batchFetchNoteReviewImages(db, noteIDs: noteIDs)
        let items = rows.map { row -> NoteExcerptListItem in
            let noteID: Int64 = row["id"]
            let contentHTML = Self.trimTrailingWhitespaceAndNewlines(row["content"] ?? "")
            let ideaHTML = Self.trimTrailingWhitespaceAndNewlines(row["idea"] ?? "")
            return NoteExcerptListItem(
                id: noteID,
                bookID: row["book_id"],
                bookTitle: row["book_title"] ?? "",
                bookAuthor: row["book_author"] ?? "",
                bookCoverURL: row["book_cover"] ?? "",
                chapterID: row["chapter_id"] ?? 0,
                chapterTitle: row["chapter_title"] ?? "",
                contentHTML: contentHTML,
                ideaHTML: ideaHTML,
                plainContent: RichTextPlainTextExtractor.plainText(from: contentHTML)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                plainIdea: RichTextPlainTextExtractor.plainText(from: ideaHTML)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                position: row["position"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                createdDate: row["created_date"] ?? 0,
                imageURLs: imageURLsByNoteID[noteID] ?? [],
                tags: tagsByNoteID[noteID] ?? []
            )
        }
        return NoteExcerptListSnapshot(items: items, totalCount: totalCount)
    }

    /// 解析章节本身及可选后代 ID；父子关系只认 parent_id，chapter_level/source_path 不作为结构真相源。
    nonisolated func fetchChapterScopeIDs(
        _ db: Database,
        bookID: Int64,
        chapterID: Int64,
        includesDescendants: Bool
    ) throws -> [Int64] {
        // SQL 目的：读取目标书籍的完整有效章节父子关系，在内存中安全解析后代范围。
        // 涉及表：chapter。
        // 关键过滤：限定 book_id、排除根章节和删除记录；目标章节也必须在结果中存在。
        // 时间字段：不读取时间字段。
        // 返回字段用途：parent_id 是结构真相源，id 用于构造书摘范围过滤。
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, parent_id
                FROM chapter
                WHERE book_id = ? AND id != 0 AND is_deleted = 0
                ORDER BY id ASC
                """,
            arguments: [bookID]
        )
        let allIDs = Set(rows.map { $0["id"] as Int64 })
        guard allIDs.contains(chapterID) else { throw NoteBatchMutationError.chapterNotFound }
        guard includesDescendants else { return [chapterID] }

        let childrenByParent = Dictionary(grouping: rows, by: { $0["parent_id"] as Int64 })
        var result: [Int64] = []
        var visited = Set<Int64>()
        var queue = [chapterID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current).inserted else { continue }
            result.append(current)
            queue.append(contentsOf: childrenByParent[current, default: []].map { $0["id"] as Int64 })
        }
        return result
    }

    /// 生成书摘 scope/search SQL 条件，确保列表、计数与随机 ID 查询共用同一事实来源。
    nonisolated func noteExcerptFilter(
        scope: NoteExcerptScope,
        query: String,
        searchScope: NoteExcerptSearchScope
    ) -> NoteCollectionSQLFilter {
        var filter = NoteCollectionSQLFilter(
            predicates: ["n.is_deleted = 0"],
            arguments: []
        )
        switch scope {
        case .all:
            break
        case .untagged:
            filter.predicates.append("""
                NOT EXISTS (
                    SELECT 1
                    FROM tag_note tn
                    JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
                    WHERE tn.note_id = n.id AND tn.is_deleted = 0
                )
                """)
        case .withIdea:
            filter.predicates.append("trim(COALESCE(n.idea, '')) != ''")
        case .withImages:
            filter.predicates.append("EXISTS (SELECT 1 FROM attach_image ai WHERE ai.note_id = n.id AND ai.is_deleted = 0)")
        case .tag(let id):
            filter.predicates.append("""
                EXISTS (
                    SELECT 1
                    FROM tag_note tn
                    JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
                    WHERE tn.note_id = n.id AND tn.tag_id = ? AND tn.is_deleted = 0
                )
                """)
            filter.arguments.append(id)
        case .book(let id):
            filter.predicates.append("n.book_id = ?")
            filter.arguments.append(id)
        }

        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            let pattern = "%\(Self.escapeLikePattern(keyword))%"
            switch searchScope {
            case .contentAndIdea:
                filter.predicates.append("""
                    (COALESCE(n.content, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                     OR COALESCE(n.idea, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
                    """)
                filter.arguments.append(pattern)
                filter.arguments.append(pattern)
            case .contentIdeaAndBookMetadata:
                filter.predicates.append("""
                    (COALESCE(n.content, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                     OR COALESCE(n.idea, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                     OR COALESCE(b.name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                     OR COALESCE(b.author, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
                    """)
                filter.arguments.append(pattern)
                filter.arguments.append(pattern)
                filter.arguments.append(pattern)
                filter.arguments.append(pattern)
            }
        }
        return filter
    }

    /// 统一书摘列表基础字段 SQL，调用方只注入已受控的 WHERE 与排序/分页片段。
    nonisolated func noteExcerptSelectSQL(whereClause: String, suffix: String) -> String {
        // SQL 目的：读取二级书摘卡片的基础字段，标签和图片由后续批量查询补齐。
        // 涉及表：note INNER JOIN book LEFT JOIN chapter。
        // 关键过滤：由调用方传入同一 scope/search whereClause；章节允许缺失或被删除。
        // 时间字段：created_date 为 Android 毫秒时间戳，读取阶段不转换。
        // 返回字段用途：构建 NoteExcerptListItem 与 Viewer 同源列表。
        """
            SELECT n.id, n.book_id, n.chapter_id, n.content, n.idea, n.position,
                   n.position_unit, n.include_time, n.created_date,
                   COALESCE(b.name, '') AS book_title,
                   COALESCE(b.author, '') AS book_author,
                   COALESCE(b.cover, '') AS book_cover,
                   COALESCE(c.title, '') AS chapter_title
            FROM note n
            JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
            LEFT JOIN chapter c ON c.id = n.chapter_id AND c.is_deleted = 0
            WHERE \(whereClause)
            \(suffix)
            """
    }

    /// 按稳定随机 ID 页回表读取书摘，并恢复传入顺序。
    nonisolated func fetchNoteExcerptRows(
        _ db: Database,
        filter: NoteCollectionSQLFilter,
        orderedIDs: [Int64]
    ) throws -> [Row] {
        guard !orderedIDs.isEmpty else { return [] }
        var scopedFilter = filter
        scopedFilter.predicates.append("n.id IN (\(Self.placeholders(count: orderedIDs.count)))")
        scopedFilter.arguments.append(contentsOf: orderedIDs)
        let rows = try Row.fetchAll(
            db,
            sql: noteExcerptSelectSQL(
                whereClause: scopedFilter.predicates.joined(separator: "\n              AND "),
                suffix: ""
            ),
            arguments: StatementArguments(scopedFilter.arguments)
        )
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["id"] as Int64, row)
        })
        return orderedIDs.compactMap { rowsByID[$0] }
    }

    /// 批量读取书摘标签，保留 Android tag_order 排序与真实标签 ID。
    nonisolated func batchFetchNoteExcerptTags(
        _ db: Database,
        noteIDs: [Int64]
    ) throws -> [Int64: [NoteExcerptTagItem]] {
        guard !noteIDs.isEmpty else { return [:] }
        // SQL 目的：批量读取当前书摘页的有效书摘标签。
        // 涉及表：tag_note INNER JOIN tag。
        // 关键过滤：限定 note_id 集合，关系与标签均有效，且 tag.type=1。
        // 排序：tag_order ASC、关系 id ASC。
        // 时间字段：不读取时间字段。
        // 返回字段用途：按 note_id 分组构建卡片标签。
        let sql = """
            SELECT tn.note_id, t.id, COALESCE(t.name, '') AS name, t.tag_order
            FROM tag_note tn
            JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
            WHERE tn.is_deleted = 0
              AND tn.note_id IN (\(Self.placeholders(count: noteIDs.count)))
            ORDER BY t.tag_order ASC, tn.id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(noteIDs))
        var result: [Int64: [NoteExcerptTagItem]] = [:]
        for row in rows {
            let noteID: Int64 = row["note_id"]
            result[noteID, default: []].append(
                NoteExcerptTagItem(
                    id: row["id"],
                    title: row["name"] ?? "",
                    order: row["tag_order"] ?? 0
                )
            )
        }
        return result
    }

    nonisolated static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// 使用 SplitMix64 为稳定 ID 生成确定性随机分值，相同 seed 下分页与 Viewer 顺序一致。
    nonisolated static func stablyShuffledIDs(_ ids: [Int64], seed: Int64) -> [Int64] {
        ids.sorted { lhs, rhs in
            let lhsScore = stableRandomScore(id: lhs, seed: seed)
            let rhsScore = stableRandomScore(id: rhs, seed: seed)
            return lhsScore == rhsScore ? lhs < rhs : lhsScore < rhsScore
        }
    }

    nonisolated static func stableRandomScore(id: Int64, seed: Int64) -> UInt64 {
        var value = UInt64(bitPattern: id) ^ UInt64(bitPattern: seed) &+ 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

private extension NoteRepository {
    /// 读取相关分类并按精确标题聚合；隐藏分类不进入自定义分类入口。
    nonisolated func fetchRelatedCategorySnapshot(
        _ db: Database,
        request: RelatedCategoryRequest
    ) throws -> RelatedCategorySnapshot {
        // SQL 目的：读取全部有效且未隐藏的相关分类定义，供同名分类跨书聚合。
        // 涉及表：category。
        // 关键过滤：category.is_deleted=0、is_hide=0；全局分类 book_id=0 保留。
        // 排序：order ASC、id ASC 提供稳定聚合顺序。
        // 时间字段：created_date/updated_date 为 Android 毫秒时间戳。
        // 返回字段用途：确定分类 ID 集合、默认分类属性及排序时间。
        let categorySQL = """
            SELECT id, book_id, COALESCE(title, '') AS title, "order", created_date, updated_date
            FROM category
            WHERE is_deleted = 0 AND is_hide = 0
            ORDER BY "order" ASC, id ASC
            """
        let categoryRows = try Row.fetchAll(db, sql: categorySQL)

        // SQL 目的：读取全部有效相关关系及其来源书籍，供“全部相关”与自定义标题聚合计数/书籍。
        // 涉及表：category_content INNER JOIN book；category 只用于后续按可见 ID 归并。
        // 关键过滤：关系与来源书籍有效，来源书籍不能是系统根；related book 可为 is_deleted=1 占位书，不影响来源书有效性。
        // 排序：category_id、created_date、id。
        // 时间字段：created_date/updated_date 原样保留毫秒值。
        // 返回字段用途：聚合数量、最早创建时间、最近更新时间与来源书籍摘要。
        let contentSQL = """
            SELECT cc.id, cc.category_id, cc.created_date, cc.updated_date,
                   b.id AS source_book_id,
                   COALESCE(b.name, '') AS source_book_title,
                   COALESCE(b.author, '') AS source_book_author,
                   COALESCE(b.cover, '') AS source_book_cover
            FROM category_content cc
            JOIN book b ON b.id = cc.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE cc.is_deleted = 0
            ORDER BY cc.category_id ASC, cc.created_date ASC, cc.id ASC
            """
        let contentRows = try Row.fetchAll(db, sql: contentSQL)
        let rowsByCategoryID = Dictionary(grouping: contentRows, by: { $0["category_id"] as Int64 })

        func uniqueBooks(from rows: [Row]) -> [RelatedCategoryBookItem] {
            var seen = Set<Int64>()
            return rows.compactMap { row in
                let bookID: Int64 = row["source_book_id"]
                guard seen.insert(bookID).inserted else { return nil }
                return RelatedCategoryBookItem(
                    id: bookID,
                    title: row["source_book_title"] ?? "",
                    author: row["source_book_author"] ?? "",
                    coverURL: row["source_book_cover"] ?? ""
                )
            }
        }

        let keyword = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allItem = RelatedCategoryItem(
            scope: .all,
            categoryIDs: categoryRows.map { $0["id"] as Int64 },
            title: RelatedCategoryScope.allTitle,
            books: uniqueBooks(from: contentRows),
            contentCount: contentRows.count,
            createdDate: 0,
            updatedDate: 0,
            isDefault: true
        )

        var customItems: [RelatedCategoryItem] = []
        for (title, sameTitleRows) in Dictionary(grouping: categoryRows, by: { $0["title"] as String? ?? "" }) {
            guard !title.isEmpty else { continue }
            if !keyword.isEmpty, !title.localizedCaseInsensitiveContains(keyword) { continue }
            let categoryIDs = sameTitleRows.map { $0["id"] as Int64 }
            let relatedRows = categoryIDs.flatMap { rowsByCategoryID[$0] ?? [] }
            customItems.append(
                RelatedCategoryItem(
                    scope: .title(title),
                    categoryIDs: categoryIDs.sorted(),
                    title: title,
                    books: uniqueBooks(from: relatedRows),
                    contentCount: relatedRows.count,
                    createdDate: relatedRows.compactMap { $0["created_date"] as Int64? }.min() ?? 0,
                    updatedDate: relatedRows.compactMap { $0["updated_date"] as Int64? }.max() ?? 0,
                    isDefault: sameTitleRows.contains(where: Self.isProtectedDefaultRelatedCategory)
                )
            )
        }

        switch request.sort {
        case .countAscending:
            customItems.sort { $0.contentCount == $1.contentCount ? $0.title < $1.title : $0.contentCount < $1.contentCount }
        case .countDescending:
            customItems.sort { $0.contentCount == $1.contentCount ? $0.title < $1.title : $0.contentCount > $1.contentCount }
        case .createdAscending:
            customItems.sort { $0.createdDate == $1.createdDate ? $0.title < $1.title : $0.createdDate < $1.createdDate }
        case .createdDescending:
            customItems.sort { $0.createdDate == $1.createdDate ? $0.title < $1.title : $0.createdDate > $1.createdDate }
        }

        let includesAll = keyword.isEmpty || RelatedCategoryScope.allTitle.localizedCaseInsensitiveContains(keyword)
        return RelatedCategorySnapshot(
            items: (includesAll ? [allItem] : []) + customItems,
            totalContentCount: contentRows.count
        )
    }

    /// 读取当前相关分类的一页混排项；普通排序走 SQL，随机排序使用稳定 seed。
    nonisolated func fetchRelatedContentList(
        _ db: Database,
        request: RelatedContentPageRequest
    ) throws -> RelatedContentListSnapshot {
        let filter = relatedContentFilter(scope: request.scope, query: request.query)
        let whereClause = filter.predicates.joined(separator: "\n              AND ")
        // SQL 目的：统计当前相关分类与局部搜索共同命中的关系总数。
        // 涉及表：category_content INNER JOIN category/source book，LEFT JOIN related book。
        // 关键过滤：由 filter 固定 scope 与搜索 AND 语义；来源书必须有效，相关书允许为业务占位书。
        // 时间字段：不读取时间字段。
        // 返回字段用途：分页 hasMore 与空态判断。
        let countSQL = relatedContentBaseSQL(
            selection: "COUNT(*)",
            whereClause: whereClause,
            suffix: ""
        )
        let arguments = StatementArguments(filter.arguments)
        let totalCount = try Int.fetchOne(db, sql: countSQL, arguments: arguments) ?? 0

        let rows: [Row]
        switch request.sort {
        case .createdAscending, .createdDescending:
            let direction = request.sort == .createdAscending ? "ASC" : "DESC"
            var pageArguments = filter.arguments
            pageArguments.append(Int64(request.limit))
            pageArguments.append(Int64(request.offset))
            rows = try Row.fetchAll(
                db,
                sql: relatedContentBaseSQL(
                    selection: relatedContentSelection,
                    whereClause: whereClause,
                    suffix: "ORDER BY cc.created_date \(direction), cc.id \(direction) LIMIT ? OFFSET ?"
                ),
                arguments: StatementArguments(pageArguments)
            )
        case .random:
            let idSQL = relatedContentBaseSQL(
                selection: "cc.id",
                whereClause: whereClause,
                suffix: "ORDER BY cc.id ASC"
            )
            let allIDs = try Int64.fetchAll(db, sql: idSQL, arguments: arguments)
            let orderedIDs = Self.stablyShuffledIDs(allIDs, seed: request.randomSeed)
            let pageIDs = Array(orderedIDs.dropFirst(request.offset).prefix(request.limit))
            rows = try fetchRelatedContentRows(db, filter: filter, orderedIDs: pageIDs)
        }

        let contentIDs = rows.compactMap { row -> Int64? in
            let contentBookID: Int64 = row["content_book_id"] ?? 0
            return contentBookID == 0 ? row["id"] : nil
        }
        let imagesByContentID = try batchFetchRelatedImages(db, contentIDs: contentIDs)
        let items = rows.map { row -> RelatedListItem in
            let relationID: Int64 = row["id"]
            let contentBookID: Int64 = row["content_book_id"] ?? 0
            if contentBookID > 0 {
                return .book(
                    RelatedBookListItem(
                        relationID: relationID,
                        sourceBookID: row["source_book_id"],
                        sourceBookTitle: row["source_book_title"] ?? "",
                        categoryID: row["category_id"],
                        categoryTitle: row["category_title"] ?? "",
                        relatedBookID: contentBookID,
                        title: row["related_book_title"] ?? "",
                        author: row["related_book_author"] ?? "",
                        coverURL: row["related_book_cover"] ?? "",
                        createdDate: row["created_date"] ?? 0,
                        isPlaceholder: (row["related_book_is_deleted"] as Int64? ?? 0) != 0
                    )
                )
            }
            return .content(
                RelatedContentListItem(
                    relationID: relationID,
                    sourceBookID: row["source_book_id"],
                    sourceBookTitle: row["source_book_title"] ?? "",
                    categoryID: row["category_id"],
                    categoryTitle: row["category_title"] ?? "",
                    title: row["content_title"] ?? "",
                    contentHTML: Self.trimTrailingWhitespaceAndNewlines(row["content_html"] ?? ""),
                    url: row["url"] ?? "",
                    createdDate: row["created_date"] ?? 0,
                    imageURLs: imagesByContentID[relationID] ?? []
                )
            )
        }
        return RelatedContentListSnapshot(items: items, totalCount: totalCount)
    }

    nonisolated var relatedContentSelection: String {
        """
            cc.id, cc.category_id, cc.content_book_id, cc.created_date,
            COALESCE(cc.title, '') AS content_title,
            COALESCE(cc.content, '') AS content_html,
            COALESCE(cc.url, '') AS url,
            COALESCE(cat.title, '') AS category_title,
            source_book.id AS source_book_id,
            COALESCE(source_book.name, '') AS source_book_title,
            COALESCE(related_book.name, '') AS related_book_title,
            COALESCE(related_book.author, '') AS related_book_author,
            COALESCE(related_book.cover, '') AS related_book_cover,
            COALESCE(related_book.is_deleted, 0) AS related_book_is_deleted
            """
    }

    /// 生成相关混排查询公共骨架，所有插值均来自本文件受控 SQL 片段。
    nonisolated func relatedContentBaseSQL(selection: String, whereClause: String, suffix: String) -> String {
        // SQL 目的：查询相关内容与相关书籍混排的公共数据集。
        // 涉及表：category_content INNER JOIN category/source book，LEFT JOIN related book。
        // 关键过滤：来源书必须有效；related book 不过滤 is_deleted，以保留仍被有效关系引用的业务占位书。
        // 时间字段：created_date 为 Android 毫秒时间戳。
        // 返回字段用途：由 selection 决定计数、ID 或完整卡片读取。
        """
            SELECT \(selection)
            FROM category_content cc
            JOIN category cat ON cat.id = cc.category_id AND cat.is_deleted = 0
            JOIN book source_book ON source_book.id = cc.book_id
                                  AND source_book.is_deleted = 0
                                  AND source_book.id != 0
            LEFT JOIN book related_book ON related_book.id = cc.content_book_id
            WHERE \(whereClause)
            \(suffix)
            """
    }

    nonisolated func relatedContentFilter(
        scope: RelatedCategoryScope,
        query: String
    ) -> NoteCollectionSQLFilter {
        var filter = NoteCollectionSQLFilter(
            predicates: ["cc.is_deleted = 0"],
            arguments: []
        )
        switch scope {
        case .all:
            break
        case .title(let title):
            filter.predicates.append("cat.title = ? AND cat.is_hide = 0")
            filter.arguments.append(title)
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            let pattern = "%\(Self.escapeLikePattern(keyword))%"
            filter.predicates.append("""
                (COALESCE(cc.title, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(cc.content, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(cc.url, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(related_book.name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(related_book.author, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
                """)
            for _ in 0..<5 { filter.arguments.append(pattern) }
        }
        return filter
    }

    nonisolated func fetchRelatedContentRows(
        _ db: Database,
        filter: NoteCollectionSQLFilter,
        orderedIDs: [Int64]
    ) throws -> [Row] {
        guard !orderedIDs.isEmpty else { return [] }
        var scopedFilter = filter
        scopedFilter.predicates.append("cc.id IN (\(Self.placeholders(count: orderedIDs.count)))")
        scopedFilter.arguments.append(contentsOf: orderedIDs)
        let rows = try Row.fetchAll(
            db,
            sql: relatedContentBaseSQL(
                selection: relatedContentSelection,
                whereClause: scopedFilter.predicates.joined(separator: "\n              AND "),
                suffix: ""
            ),
            arguments: StatementArguments(scopedFilter.arguments)
        )
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0) })
        return orderedIDs.compactMap { rowsByID[$0] }
    }

    /// 批量读取普通相关内容附图；相关书籍不拥有 category_image。
    nonisolated func batchFetchRelatedImages(
        _ db: Database,
        contentIDs: [Int64]
    ) throws -> [Int64: [String]] {
        guard !contentIDs.isEmpty else { return [:] }
        // SQL 目的：批量读取相关内容页当前普通内容项的有效附图。
        // 涉及表：category_image。
        // 关键过滤：限定 category_content_id 集合且图片有效。
        // 排序：order ASC、id ASC 对齐 Android 图片墙顺序。
        // 时间字段：不读取时间字段。
        // 返回字段用途：按内容 ID 构建图片 URL 数组。
        let sql = """
            SELECT category_content_id, image
            FROM category_image
            WHERE is_deleted = 0
              AND category_content_id IN (\(Self.placeholders(count: contentIDs.count)))
            ORDER BY "order" ASC, id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(contentIDs))
        var result: [Int64: [String]] = [:]
        for row in rows {
            let contentID: Int64 = row["category_content_id"]
            guard let image: String = row["image"], !image.isEmpty else { continue }
            result[contentID, default: []].append(image)
        }
        return result
    }

    /// 按首页标题聚合语义删除相关分类；系统默认分类只清空内容，自定义分类继续删除定义。
    nonisolated func softDeleteRelatedCategoryAggregation(_ db: Database, title: String) throws {
        // SQL 目的：定位精确同名的有效分类，决定首页聚合删除应保留系统分类根还是删除自定义分类定义。
        // 涉及表：category。
        // 关键过滤：title 精确匹配且分类有效。
        // 时间字段：created_date 是 Android Unix 毫秒时间戳，仅参与兼容库系统根识别，不做时区换算。
        // 返回字段用途：id/book_id/title/created_date 共同判断真实系统默认身份，并取得同名跨书业务范围。
        let categoryRows = try Row.fetchAll(
            db,
            sql: "SELECT id, book_id, title, created_date FROM category WHERE title = ? AND is_deleted = 0 ORDER BY id ASC",
            arguments: [title]
        )
        guard !categoryRows.isEmpty else { throw NoteCollectionRepositoryError.relatedCategoryNotFound }
        let categoryIDs = categoryRows.map { $0["id"] as Int64 }
        let now = Self.currentTimestampMillis
        if categoryRows.contains(where: Self.isProtectedDefaultRelatedCategory) {
            try softDeleteRelatedCategoryContents(db, categoryIDs: categoryIDs, timestamp: now)
        } else {
            try softDeleteRelatedCategories(db, categoryIDs: categoryIDs, timestamp: now)
        }
    }

    /// 按已完成保护校验的分类主键软删除内容与分类定义。
    nonisolated func softDeleteRelatedCategories(
        _ db: Database,
        categoryIDs: [Int64],
        timestamp: Int64
    ) throws {
        guard !categoryIDs.isEmpty else { throw NoteCollectionRepositoryError.relatedCategoryNotFound }
        let placeholders = Self.placeholders(count: categoryIDs.count)

        try softDeleteRelatedCategoryContents(db, categoryIDs: categoryIDs, timestamp: timestamp)
        try db.execute(
            // SQL 目的：软删除同名自建分类定义，保留跨端可同步的 tombstone。
            // 涉及表：category。
            // 关键过滤：限定已确认不含六个系统种子分类的 ID，且只处理有效记录。
            // 时间字段：updated_date 写本次事务的 Unix 毫秒时间戳。
            // 副作用：跨书同名自定义分类不再出现在有效查询中。
            sql: "UPDATE category SET updated_date = ?, is_deleted = 1 WHERE id IN (\(placeholders)) AND is_deleted = 0",
            arguments: StatementArguments([timestamp] + categoryIDs)
        )
    }

    /// 软删除分类范围内的内容、附图与相关书籍关系，对齐 Android is_deleted 语义。
    nonisolated func softDeleteRelatedCategoryContents(
        _ db: Database,
        categoryIDs: [Int64],
        timestamp: Int64
    ) throws {
        guard !categoryIDs.isEmpty else { throw NoteCollectionRepositoryError.relatedCategoryNotFound }
        let placeholders = Self.placeholders(count: categoryIDs.count)
        // SQL 目的：锁定待删除分类下的有效内容主键，供附图同步软删除。
        // 涉及表：category_content。
        // 关键过滤：限定待删除分类 ID 集合且 is_deleted = 0。
        // 时间字段：不读取时间字段。
        // 返回字段用途：构建附图子表的批量更新范围。
        let contentIDs = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM category_content WHERE category_id IN (\(placeholders)) AND is_deleted = 0",
            arguments: StatementArguments(categoryIDs)
        )
        if !contentIDs.isEmpty {
            try db.execute(
                // SQL 目的：软删除分类内容的有效附图，对齐 Android CategoryImageDao.deleteFromContent。
                // 涉及表：category_image。
                // 关键过滤：限定有效内容主键集合且只处理有效附图。
                // 时间字段：updated_date 写本次事务的 Unix 毫秒时间戳。
                // 副作用：附图不再出现于有效查询，同时保留同步墓碑。
                sql: "UPDATE category_image SET updated_date = ?, is_deleted = 1 WHERE category_content_id IN (\(Self.placeholders(count: contentIDs.count))) AND is_deleted = 0",
                arguments: StatementArguments([timestamp] + contentIDs)
            )
        }
        try db.execute(
            // SQL 目的：软删除分类范围内的相关内容与相关书籍关系。
            // 涉及表：category_content。
            // 关键过滤：限定精确标题解析出的分类 ID 集合且 is_deleted = 0。
            // 时间字段：updated_date 写本次事务的 Unix 毫秒时间戳。
            // 副作用：保留 Android 可同步的关系 tombstone。
            sql: "UPDATE category_content SET updated_date = ?, is_deleted = 1 WHERE category_id IN (\(placeholders)) AND is_deleted = 0",
            arguments: StatementArguments([timestamp] + categoryIDs)
        )
    }
}

private extension NoteRepository {
    /// 读取、过滤和排序全量书评；字数使用富文本可见标题与正文计算，避免 HTML 标签污染排序。
    nonisolated func fetchBookReviewList(
        _ db: Database,
        request: BookReviewPageRequest
    ) throws -> BookReviewListSnapshot {
        // SQL 目的：读取全部有效书评及所属书籍基础字段，附图稍后按当前页批量补齐。
        // 涉及表：review INNER JOIN book。
        // 关键过滤：书评与书籍有效，排除系统根书籍。
        // 排序：先按 id 稳定输出，最终搜索/字数/时间排序在内存侧统一完成。
        // 时间字段：created_date 为 Android 毫秒时间戳。
        // 返回字段用途：构建 BookReviewListItem 并计算标题与正文的去 HTML 总字数。
        let sql = """
            SELECT rv.id, rv.book_id, COALESCE(rv.title, '') AS title,
                   COALESCE(rv.content, '') AS content, rv.created_date,
                   COALESCE(b.name, '') AS book_title,
                   COALESCE(b.author, '') AS book_author,
                   COALESCE(b.cover, '') AS book_cover,
                   b.score AS book_score
            FROM review rv
            JOIN book b ON b.id = rv.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE rv.is_deleted = 0
            ORDER BY rv.id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)
        let keyword = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var intermediate = rows.compactMap { row -> (Row, String, String, Int)? in
            let title = RichTextPlainTextExtractor.plainText(from: row["title"] ?? "")
            let content = RichTextPlainTextExtractor.plainText(from: row["content"] ?? "")
            if !keyword.isEmpty,
               !title.localizedCaseInsensitiveContains(keyword),
               !content.localizedCaseInsensitiveContains(keyword) {
                return nil
            }
            return (row, title, content, title.count + content.count)
        }
        switch request.sort {
        case .wordCountAscending:
            intermediate.sort { $0.3 == $1.3 ? ($0.0["id"] as Int64) < ($1.0["id"] as Int64) : $0.3 < $1.3 }
        case .wordCountDescending:
            intermediate.sort { $0.3 == $1.3 ? ($0.0["id"] as Int64) > ($1.0["id"] as Int64) : $0.3 > $1.3 }
        case .createdAscending:
            intermediate.sort {
                let lhsDate: Int64 = $0.0["created_date"] ?? 0
                let rhsDate: Int64 = $1.0["created_date"] ?? 0
                return lhsDate == rhsDate ? ($0.0["id"] as Int64) < ($1.0["id"] as Int64) : lhsDate < rhsDate
            }
        case .createdDescending:
            intermediate.sort {
                let lhsDate: Int64 = $0.0["created_date"] ?? 0
                let rhsDate: Int64 = $1.0["created_date"] ?? 0
                return lhsDate == rhsDate ? ($0.0["id"] as Int64) > ($1.0["id"] as Int64) : lhsDate > rhsDate
            }
        }
        let totalCount = intermediate.count
        let page = Array(intermediate.dropFirst(request.offset).prefix(request.limit))
        let reviewIDs = page.map { $0.0["id"] as Int64 }
        let imagesByReviewID = try batchFetchReviewImages(db, reviewIDs: reviewIDs)
        let items = page.map { entry -> BookReviewListItem in
            let row = entry.0
            let reviewID: Int64 = row["id"]
            return BookReviewListItem(
                id: reviewID,
                bookID: row["book_id"],
                bookTitle: row["book_title"] ?? "",
                bookAuthor: row["book_author"] ?? "",
                bookCoverURL: row["book_cover"] ?? "",
                bookScore: row["book_score"] ?? 0,
                title: row["title"] ?? "",
                contentHTML: Self.trimTrailingWhitespaceAndNewlines(row["content"] ?? ""),
                wordCount: entry.3,
                createdDate: row["created_date"] ?? 0,
                imageURLs: imagesByReviewID[reviewID] ?? []
            )
        }
        return BookReviewListSnapshot(items: items, totalCount: totalCount)
    }

    /// 批量读取当前书评页附图。
    nonisolated func batchFetchReviewImages(
        _ db: Database,
        reviewIDs: [Int64]
    ) throws -> [Int64: [String]] {
        guard !reviewIDs.isEmpty else { return [:] }
        // SQL 目的：批量读取当前书评页的有效附图。
        // 涉及表：review_image。
        // 关键过滤：限定 review_id 集合且图片有效。
        // 排序：order ASC、id ASC 对齐 Android。
        // 时间字段：不读取时间字段。
        // 返回字段用途：按书评 ID 构建图片 URL 数组。
        let sql = """
            SELECT review_id, image
            FROM review_image
            WHERE is_deleted = 0
              AND review_id IN (\(Self.placeholders(count: reviewIDs.count)))
            ORDER BY "order" ASC, id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(reviewIDs))
        var result: [Int64: [String]] = [:]
        for row in rows {
            let reviewID: Int64 = row["review_id"]
            guard let image: String = row["image"], !image.isEmpty else { continue }
            result[reviewID, default: []].append(image)
        }
        return result
    }
}

private extension NoteRepository {
    /// 读取星标章节、完整同书章节树与直接书摘数，并按 Android 规则计算可见分组。
    nonisolated func fetchStarredChapterGroups(
        _ db: Database,
        request: StarredChapterRequest
    ) throws -> [StarredChapterGroup] {
        // SQL 目的：读取包含星标章节的有效书籍下全部章节，为路径和后代书摘数建立完整章节树。
        // 涉及表：chapter INNER JOIN book；EXISTS 子查询定位至少含一个星标章节的书籍。
        // 关键过滤：章节/书籍均有效，排除系统根章节；星标仅决定书籍范围，非星标章节仍用于树计算。
        // 排序：book_id、parent_id、chapter_order、id，提供稳定树输入。
        // 时间字段：updated_date 为 Android 毫秒时间戳，用于最近变更排序。
        // 返回字段用途：构建 StarredChapterGroup 与每个星标章节的路径/后代计数。
        let chapterSQL = """
            SELECT c.id, c.book_id, c.parent_id, COALESCE(c.title, '') AS title,
                   c.updated_date, c.is_starred,
                   COALESCE(b.name, '') AS book_title,
                   COALESCE(b.author, '') AS book_author,
                   COALESCE(b.cover, '') AS book_cover
            FROM chapter c
            JOIN book b ON b.id = c.book_id AND b.is_deleted = 0 AND b.id != 0
            WHERE c.id != 0 AND c.is_deleted = 0
              AND EXISTS (
                  SELECT 1
                  FROM chapter starred
                  WHERE starred.book_id = c.book_id
                    AND starred.id != 0
                    AND starred.is_starred = 1
                    AND starred.is_deleted = 0
              )
            ORDER BY c.book_id ASC, c.parent_id ASC, c.chapter_order ASC, c.id ASC
            """
        let rows = try Row.fetchAll(db, sql: chapterSQL)
        guard !rows.isEmpty else { return [] }

        let chapterIDs: [Int64] = rows.map { $0["id"] }
        // SQL 目的：批量统计章节直接包含的有效书摘数，后代聚合在内存章节树完成。
        // 涉及表：note。
        // 关键过滤：限定当前章节集合且 note.is_deleted=0。
        // 时间字段：不读取时间字段。
        // 返回字段用途：构建 directNoteCount，并进一步计算 descendantNoteCount。
        let countSQL = """
            SELECT chapter_id, COUNT(*) AS note_count
            FROM note
            WHERE is_deleted = 0
              AND chapter_id IN (\(Self.placeholders(count: chapterIDs.count)))
            GROUP BY chapter_id
            """
        let countRows = try Row.fetchAll(db, sql: countSQL, arguments: StatementArguments(chapterIDs))
        let directCounts = Dictionary(uniqueKeysWithValues: countRows.map { row in
            (row["chapter_id"] as Int64, row["note_count"] as Int)
        })

        var groups: [StarredChapterGroup] = []
        for bookRows in Dictionary(grouping: rows, by: { $0["book_id"] as Int64 }).values {
            guard let first = bookRows.first else { continue }
            let bookID: Int64 = first["book_id"]
            let chapters = bookRows.map { row in
                StarredChapterDatabaseItem(
                    id: row["id"],
                    bookID: row["book_id"],
                    parentID: row["parent_id"],
                    title: row["title"] ?? "",
                    updatedDate: row["updated_date"] ?? 0,
                    isStarred: (row["is_starred"] as Int64? ?? 0) != 0
                )
            }
            let chapterByID = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0) })
            let childrenByParent = Dictionary(grouping: chapters, by: \.parentID)

            func catalogPreorder() -> [StarredChapterDatabaseItem] {
                var result: [StarredChapterDatabaseItem] = []
                var visited = Set<Int64>()

                func visit(_ chapter: StarredChapterDatabaseItem) {
                    guard visited.insert(chapter.id).inserted else { return }
                    result.append(chapter)
                    for child in childrenByParent[chapter.id] ?? [] {
                        visit(child)
                    }
                }

                let roots = chapters.filter { chapter in
                    chapter.parentID == 0 || chapterByID[chapter.parentID] == nil
                }
                roots.forEach(visit)
                chapters.forEach(visit)
                return result
            }

            func descendantIDs(of rootID: Int64) -> Set<Int64> {
                var result = Set<Int64>()
                var pending = [rootID]
                while let current = pending.popLast() {
                    guard result.insert(current).inserted else { continue }
                    pending.append(contentsOf: (childrenByParent[current] ?? []).map(\.id))
                }
                return result
            }

            func pathTitles(for chapter: StarredChapterDatabaseItem) -> [String] {
                var result: [String] = []
                var current: StarredChapterDatabaseItem? = chapter
                var visited = Set<Int64>()
                while let item = current, visited.insert(item.id).inserted {
                    if !item.title.isEmpty { result.append(item.title) }
                    current = chapterByID[item.parentID]
                }
                return result.reversed()
            }

            var starredItems = catalogPreorder().filter(\.isStarred).map { chapter in
                let scopeIDs = descendantIDs(of: chapter.id)
                return StarredChapterItem(
                    id: chapter.id,
                    bookID: chapter.bookID,
                    parentID: chapter.parentID,
                    title: chapter.title,
                    pathTitles: pathTitles(for: chapter),
                    directNoteCount: directCounts[chapter.id] ?? 0,
                    descendantNoteCount: scopeIDs.reduce(0) { $0 + (directCounts[$1] ?? 0) },
                    updatedDate: chapter.updatedDate
                )
            }

            let keyword = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyword.isEmpty {
                let bookMatched = (first["book_title"] as String? ?? "").localizedCaseInsensitiveContains(keyword)
                    || (first["book_author"] as String? ?? "").localizedCaseInsensitiveContains(keyword)
                if !bookMatched {
                    starredItems = starredItems.filter { item in
                        item.title.localizedCaseInsensitiveContains(keyword)
                            || item.pathTitles.contains { $0.localizedCaseInsensitiveContains(keyword) }
                    }
                }
            }
            guard !starredItems.isEmpty else { continue }

            switch request.sort {
            case .recentlyChanged:
                break
            case .noteCountDescending:
                starredItems = starredItems.enumerated()
                    .sorted { lhs, rhs in
                        guard lhs.element.descendantNoteCount == rhs.element.descendantNoteCount else {
                            return lhs.element.descendantNoteCount > rhs.element.descendantNoteCount
                        }
                        return lhs.offset < rhs.offset
                    }
                    .map(\.element)
            }
            let visibleScopeIDs = starredItems.reduce(into: Set<Int64>()) { result, item in
                result.formUnion(descendantIDs(of: item.id))
            }
            groups.append(
                StarredChapterGroup(
                    id: bookID,
                    bookTitle: first["book_title"] ?? "",
                    bookAuthor: first["book_author"] ?? "",
                    bookCoverURL: first["book_cover"] ?? "",
                    chapters: starredItems,
                    chapterCount: starredItems.count,
                    noteCount: visibleScopeIDs.reduce(0) { $0 + (directCounts[$1] ?? 0) },
                    latestUpdatedDate: starredItems.map(\.updatedDate).max() ?? 0
                )
            )
        }

        switch request.sort {
        case .recentlyChanged:
            groups.sort {
                $0.latestUpdatedDate == $1.latestUpdatedDate
                    ? $0.id < $1.id
                    : $0.latestUpdatedDate > $1.latestUpdatedDate
            }
        case .noteCountDescending:
            groups.sort {
                $0.noteCount == $1.noteCount
                    ? $0.latestUpdatedDate > $1.latestUpdatedDate
                    : $0.noteCount > $1.noteCount
            }
        }
        return groups
    }
}

private extension NoteRepository {
    /// SQL 目的：追踪会影响书摘回顾卡片内容、书籍来源、标签与附图的全部本地表变更。
    /// 涉及表：note、book、chapter、tag_note、tag、attach_image；通过各表记录数、更新时间与文本长度聚合形成观察指纹。
    /// 关键过滤：仅用于变化检测，不改变回顾查询的 is_deleted 语义；所有软删除和有效记录变化都必须触发刷新。
    /// 时间字段：updated_date 沿用 Android 毫秒时间戳，仅参与变化比较，不做时区转换。
    /// 返回字段用途：ValueObservation 仅在指纹变化时向 ViewModel 发出外部数据变更事件。
    nonisolated func noteReviewDataFingerprint(_ db: Database) throws -> String {
        let sql = """
            SELECT
                (SELECT COUNT(*) || ':' || COALESCE(MAX(updated_date), 0) || ':' || COALESCE(SUM(LENGTH(content) + LENGTH(idea)), 0) FROM note)
                || '|' ||
                (SELECT COUNT(*) || ':' || COALESCE(MAX(updated_date), 0) || ':' || COALESCE(SUM(LENGTH(name) + LENGTH(author) + LENGTH(cover)), 0) FROM book)
                || '|' ||
                (SELECT COUNT(*) || ':' || COALESCE(MAX(updated_date), 0) || ':' || COALESCE(SUM(LENGTH(title) + LENGTH(source_uid)), 0) FROM chapter)
                || '|' ||
                (SELECT COUNT(*) || ':' || COALESCE(MAX(updated_date), 0) || ':' || COALESCE(SUM(note_id + tag_id), 0) FROM tag_note)
                || '|' ||
                (SELECT COUNT(*) || ':' || COALESCE(MAX(updated_date), 0) || ':' || COALESCE(SUM(LENGTH(name)), 0) FROM tag)
                || '|' ||
                (SELECT COUNT(*) || ':' || COALESCE(MAX(updated_date), 0) || ':' || COALESCE(SUM(LENGTH(image_url)), 0) FROM attach_image)
                AS fingerprint
            """
        return try String.fetchOne(db, sql: sql) ?? ""
    }

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

    /// 以卡堆完全相同的书籍与标签条件读取轻量身份序列，避免全屏回顾随数据量持有完整模型。
    nonisolated func fetchNoteReviewIDs(
        _ db: Database,
        settings: NoteReviewSettings
    ) throws -> [Int64] {
        var predicates = ["n.is_deleted = 0"]
        var arguments: [Int64] = []

        if !settings.selectedBookIDs.isEmpty {
            predicates.append("n.book_id IN (\(Self.placeholders(count: settings.selectedBookIDs.count)))")
            arguments.append(contentsOf: settings.selectedBookIDs)
        }
        if !settings.selectedTagIDs.isEmpty {
            predicates.append(noteReviewTagPredicate(settings: settings))
            arguments.append(contentsOf: settings.selectedTagIDs)
            if settings.tagMatchRule == .all {
                arguments.append(Int64(settings.selectedTagIDs.count))
            }
        }

        // SQL 目的：按现有卡堆筛选范围读取全屏会话所需的轻量书摘身份集合。
        // 涉及表：note 为主表；标签条件通过 noteReviewTagPredicate 关联 tag_note 与 tag。
        // 关键过滤：排除 note.is_deleted = 1，并复用书籍 IN 与标签任一/全部匹配语义。
        // 排序：固定按 book_id DESC、note.id ASC 输出；顺序回顾直接使用，随机回顾在后台按会话种子洗牌。
        // 时间字段：不读取时间字段，也不做时区转换。
        // 返回字段用途：只长期保存 Int64 身份，完整正文、富文本、图片与布局均按可见区域加载。
        let sql = """
            SELECT n.id
            FROM note n
            WHERE \(predicates.joined(separator: "\n              AND "))
            ORDER BY n.book_id DESC, n.id ASC
            """
        return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    nonisolated func fetchNoteReviewPage(_ db: Database, request: NoteReviewPageRequest) throws -> [NoteReviewCardItem] {
        let limit = max(1, request.limit)
        let settings = request.settings
        var predicates = ["n.is_deleted = 0"]
        var arguments: [Int64] = []

        if !settings.selectedBookIDs.isEmpty {
            predicates.append("n.book_id IN (\(Self.placeholders(count: settings.selectedBookIDs.count)))")
            arguments.append(contentsOf: settings.selectedBookIDs)
        }

        if !settings.selectedTagIDs.isEmpty {
            predicates.append(noteReviewTagPredicate(settings: settings))
            arguments.append(contentsOf: settings.selectedTagIDs)
            if settings.tagMatchRule == .all {
                arguments.append(Int64(settings.selectedTagIDs.count))
            }
        }

        if settings.sortRule == .random, !request.excludedNoteIDs.isEmpty {
            predicates.append("n.id NOT IN (\(Self.placeholders(count: request.excludedNoteIDs.count)))")
            arguments.append(contentsOf: request.excludedNoteIDs)
        }

        let orderClause: String
        switch settings.sortRule {
        case .random:
            orderClause = "ORDER BY RANDOM()"
        case .ordered:
            orderClause = "ORDER BY n.book_id DESC, n.id ASC"
        }

        let pagingClause: String
        switch settings.sortRule {
        case .random:
            pagingClause = "LIMIT ?"
            arguments.append(Int64(limit))
        case .ordered:
            pagingClause = "LIMIT ? OFFSET ?"
            arguments.append(Int64(limit))
            arguments.append(Int64(max(0, request.offset)))
        }

        // SQL 目的：按书摘回顾设置读取一页书摘卡片基础字段，并携带微信读书原文跳转参数。
        // 涉及表：note 为主表，book/chapter 补充展示信息与 weread_book_id、source_type、source_uid；标签/图片由后续批量查询补齐。
        // 关键过滤：始终排除 note.is_deleted=1；章节连接排除 id=0 的 Android 根占位记录；书籍范围使用 note.book_id IN；标签范围通过 tag_note 子查询支持任一/全部标签；
        //          随机模式额外排除已加载 note.id，避免同一轮卡堆重复出现。
        // 排序：随机模式使用 SQLite RANDOM()；顺序模式按 Android NoteReview DAO 的 book_id DESC、note.id ASC。
        // 分页：顺序模式使用 LIMIT/OFFSET；随机模式仅 LIMIT。
        // 时间字段：created_date 为 Android 毫秒时间戳，读取阶段不做时区转换；weread_range 为 Android 原始 start-end 字符串。
        // 返回字段用途：构建 NoteReviewCardItem 的正文、书籍/章节、位置、创建时间与 weReadOriginalURL 数据能力。
        let sql = """
            SELECT n.id, n.book_id, n.content, n.idea, n.position, n.position_unit, n.include_time, n.created_date,
                   COALESCE(n.weread_range, '') AS weread_range,
                   COALESCE(b.name, '') AS book_name,
                   COALESCE(b.author, '') AS book_author,
                   COALESCE(b.cover, '') AS book_cover,
                   COALESCE(b.weread_book_id, '') AS weread_book_id,
                   COALESCE(c.title, '') AS chapter_title,
                   COALESCE(c.source_type, 0) AS chapter_source_type,
                   COALESCE(c.source_uid, '') AS chapter_source_uid
            FROM note n
            LEFT JOIN book b ON b.id = n.book_id
            LEFT JOIN chapter c ON c.id = n.chapter_id AND c.id != 0 AND c.is_deleted = 0
            WHERE \(predicates.joined(separator: "\n              AND "))
            \(orderClause)
            \(pagingClause)
            """

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        let noteIDs: [Int64] = rows.map { $0["id"] }
        let tagsByNoteID = try batchFetchNoteReviewTags(db, noteIDs: noteIDs)
        let imageURLsByNoteID = try batchFetchNoteReviewImages(db, noteIDs: noteIDs)

        return rows.map { row in
            let noteID: Int64 = row["id"]
            return NoteReviewCardItem(
                id: noteID,
                bookID: row["book_id"],
                bookTitle: row["book_name"] ?? "",
                bookAuthor: row["book_author"] ?? "",
                bookCoverURL: row["book_cover"] ?? "",
                chapterTitle: row["chapter_title"] ?? "",
                contentHTML: Self.trimTrailingWhitespaceAndNewlines(row["content"] ?? ""),
                ideaHTML: Self.trimTrailingWhitespaceAndNewlines(row["idea"] ?? ""),
                position: row["position"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                createdDate: row["created_date"] ?? 0,
                imageURLs: imageURLsByNoteID[noteID] ?? [],
                tags: tagsByNoteID[noteID] ?? [],
                weReadOriginalURL: WeReadOriginalURLBuilder.build(
                    bookID: row["weread_book_id"] ?? "",
                    chapterSourceType: row["chapter_source_type"] ?? 0,
                    chapterUID: row["chapter_source_uid"] ?? "",
                    range: row["weread_range"] ?? ""
                )
            )
        }
    }

    /// 读取单个有效书摘及其标签、图片与微信读书原文地址，字段口径与批量读取完全一致。
    nonisolated func fetchNoteReviewItem(_ db: Database, noteID: Int64) throws -> NoteReviewCardItem? {
        try fetchNoteReviewItems(db, noteIDs: [noteID]).first
    }

    /// 分批读取纸流全量测高所需字段；每条 SQL 最多绑定 128 个身份，并在内存中恢复输入顺序。
    nonisolated func fetchNoteReviewOverviewLayoutSources(
        _ db: Database,
        noteIDs: [Int64]
    ) throws -> [NoteReviewOverviewLayoutSource] {
        let orderedIDs = Self.uniquePositiveIDs(noteIDs)
        guard !orderedIDs.isEmpty else { return [] }

        let maximumBatchSize = 128
        var sourcesByID: [Int64: NoteReviewOverviewLayoutSource] = [:]
        sourcesByID.reserveCapacity(orderedIDs.count)

        for startIndex in stride(from: 0, to: orderedIDs.count, by: maximumBatchSize) {
            let endIndex = min(startIndex + maximumBatchSize, orderedIDs.count)
            let batchIDs = Array(orderedIDs[startIndex..<endIndex])

            // SQL 目的：读取纸流全量布局测高所需的最小正文、标题和版本字段，不构建完整操作卡片。
            // 涉及表：note 为主表；book/chapter 仅补充纸面标题及各自 updated_date。
            // 关键过滤：note.id 位于当前最多 128 个输入主键且 note.is_deleted=0；chapter 排除 Android 根占位与已删除记录。
            // 排序：IN 查询不依赖 SQLite 返回顺序；读取后按调用方输入 ID 顺序恢复，重复及非正 ID 已稳定去除。
            // 时间字段：三个 updated_date 均保持 Android Unix 毫秒原值，不做时区换算；缺失连接回填 0。
            // 返回字段用途：只供纸流预览内容测高与高度缓存失效判断，不读取标签、图片、封面、位置或原文跳转字段。
            let sql = """
                SELECT n.id AS note_id,
                       COALESCE(n.content, '') AS content_html,
                       COALESCE(n.idea, '') AS idea_html,
                       COALESCE(b.name, '') AS book_title,
                       COALESCE(c.title, '') AS chapter_title,
                       COALESCE(n.updated_date, 0) AS note_updated_date,
                       COALESCE(b.updated_date, 0) AS book_updated_date,
                       COALESCE(c.updated_date, 0) AS chapter_updated_date
                FROM note n
                LEFT JOIN book b ON b.id = n.book_id
                LEFT JOIN chapter c ON c.id = n.chapter_id AND c.id != 0 AND c.is_deleted = 0
                WHERE n.id IN (\(Self.placeholders(count: batchIDs.count)))
                  AND n.is_deleted = 0
                """
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(batchIDs)
            )
            for row in rows {
                let noteID: Int64 = row["note_id"]
                sourcesByID[noteID] = NoteReviewOverviewLayoutSource(
                    noteID: noteID,
                    contentHTML: Self.trimTrailingWhitespaceAndNewlines(row["content_html"] ?? ""),
                    ideaHTML: Self.trimTrailingWhitespaceAndNewlines(row["idea_html"] ?? ""),
                    bookTitle: row["book_title"] ?? "",
                    chapterTitle: row["chapter_title"] ?? "",
                    noteUpdatedDate: row["note_updated_date"] ?? 0,
                    bookUpdatedDate: row["book_updated_date"] ?? 0,
                    chapterUpdatedDate: row["chapter_updated_date"] ?? 0
                )
            }
        }

        return orderedIDs.compactMap { sourcesByID[$0] }
    }

    /// 批量读取有效书摘及操作上下文，保持输入主键顺序并去除重复项。
    nonisolated func fetchNoteReviewItems(
        _ db: Database,
        noteIDs: [Int64]
    ) throws -> [NoteReviewCardItem] {
        let orderedIDs = noteIDs.reduce(into: [Int64]()) { result, noteID in
            guard noteID > 0, !result.contains(noteID) else { return }
            result.append(noteID)
        }
        guard !orderedIDs.isEmpty else { return [] }

        // SQL 目的：批量读取指定书摘的回顾卡片基础字段，并携带微信读书原文跳转参数。
        // 涉及表：note 为主表，book/chapter 补充书籍展示与微信读书来源字段；标签/图片由后续批量查询补齐。
        // 关键过滤：note.id 位于输入主键集合且 note.is_deleted=0；chapter 仅连接非根占位的有效记录。
        // 时间字段：created_date 保持 Android 毫秒时间戳；weread_range 保留原始 start-end 字符串。
        // 返回字段用途：一次构建重度日期全部书摘的标签、复制、原文、分享卡片和外部发送上下文。
        let sql = """
            SELECT n.id, n.book_id, n.content, n.idea, n.position, n.position_unit, n.include_time, n.created_date,
                   COALESCE(n.weread_range, '') AS weread_range,
                   COALESCE(b.name, '') AS book_name,
                   COALESCE(b.author, '') AS book_author,
                   COALESCE(b.cover, '') AS book_cover,
                   COALESCE(b.weread_book_id, '') AS weread_book_id,
                   COALESCE(c.title, '') AS chapter_title,
                   COALESCE(c.source_type, 0) AS chapter_source_type,
                   COALESCE(c.source_uid, '') AS chapter_source_uid
            FROM note n
            LEFT JOIN book b ON b.id = n.book_id
            LEFT JOIN chapter c ON c.id = n.chapter_id AND c.id != 0 AND c.is_deleted = 0
            WHERE n.id IN (\(Self.placeholders(count: orderedIDs.count)))
              AND n.is_deleted = 0
            """
        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments(orderedIDs)
        )
        let tagsByNoteID = try batchFetchNoteReviewTags(db, noteIDs: orderedIDs)
        let imageURLsByNoteID = try batchFetchNoteReviewImages(db, noteIDs: orderedIDs)
        let itemsByID = rows.reduce(into: [Int64: NoteReviewCardItem]()) { result, row in
            let noteID: Int64 = row["id"]
            let bookID: Int64 = row["book_id"]
            let bookTitle: String = row["book_name"] ?? ""
            let bookAuthor: String = row["book_author"] ?? ""
            let bookCoverURL: String = row["book_cover"] ?? ""
            let chapterTitle: String = row["chapter_title"] ?? ""
            let contentHTML: String = Self.trimTrailingWhitespaceAndNewlines(row["content"] ?? "")
            let ideaHTML: String = Self.trimTrailingWhitespaceAndNewlines(row["idea"] ?? "")
            let position: String = row["position"] ?? ""
            let positionUnit: Int64 = row["position_unit"] ?? 0
            let includeTime = (row["include_time"] as Int64? ?? 1) != 0
            let createdDate: Int64 = row["created_date"] ?? 0
            let wereadBookID: String = row["weread_book_id"] ?? ""
            let chapterSourceType: Int64 = row["chapter_source_type"] ?? 0
            let chapterSourceUID: String = row["chapter_source_uid"] ?? ""
            let wereadRange: String = row["weread_range"] ?? ""
            let weReadOriginalURL = WeReadOriginalURLBuilder.build(
                bookID: wereadBookID,
                chapterSourceType: chapterSourceType,
                chapterUID: chapterSourceUID,
                range: wereadRange
            )
            result[noteID] = NoteReviewCardItem(
                id: noteID,
                bookID: bookID,
                bookTitle: bookTitle,
                bookAuthor: bookAuthor,
                bookCoverURL: bookCoverURL,
                chapterTitle: chapterTitle,
                contentHTML: contentHTML,
                ideaHTML: ideaHTML,
                position: position,
                positionUnit: positionUnit,
                includeTime: includeTime,
                createdDate: createdDate,
                imageURLs: imageURLsByNoteID[noteID] ?? [],
                tags: tagsByNoteID[noteID] ?? [],
                weReadOriginalURL: weReadOriginalURL
            )
        }
        return orderedIDs.compactMap { itemsByID[$0] }
    }

    nonisolated func fetchNoteReviewTagOptions(_ db: Database) throws -> [NoteReviewTagOption] {
        // SQL 目的：读取书摘回顾可选标签，并统计每个标签关联的有效书摘数量。
        // 涉及表：tag LEFT JOIN tag_note LEFT JOIN note。
        // 关键过滤：仅保留 tag.type=1 的书摘标签，排除 tag/tag_note/note 软删除记录。
        // 排序：按 tag_order ASC、tag.id ASC，和书摘编辑页标签顺序保持一致。
        // 返回字段用途：构建设置 Sheet 的标签多选项与右侧数量辅助信息。
        let sql = """
            SELECT t.id, t.name, COUNT(DISTINCT n.id) AS note_count
            FROM tag t
            LEFT JOIN tag_note tn ON tn.tag_id = t.id AND tn.is_deleted = 0
            LEFT JOIN note n ON n.id = tn.note_id AND n.is_deleted = 0
            WHERE t.type = 1 AND t.is_deleted = 0
            GROUP BY t.id
            ORDER BY t.tag_order ASC, t.id ASC
            """
        return try Row.fetchAll(db, sql: sql).compactMap { row in
            guard let title: String = row["name"], !title.isEmpty else { return nil }
            return NoteReviewTagOption(
                id: row["id"],
                title: title,
                noteCount: row["note_count"] ?? 0
            )
        }
    }

    nonisolated func fetchNoteReviewSelectedBooks(_ db: Database, bookIDs: [Int64]) throws -> [BookPickerBook] {
        let ids = Self.uniquePositiveIDs(bookIDs)
        guard !ids.isEmpty else { return [] }

        // SQL 目的：按回顾设置保存的 book_id 列表读取书籍回显数据。
        // 涉及表：book。
        // 关键过滤：限定 id IN 已选书籍，排除软删除书籍与默认占位书 id=0。
        // 时间字段：不读取时间字段；输出顺序在内存侧恢复为用户保存的选择顺序。
        // 返回字段用途：构建 BookPicker 预选项与设置行摘要。
        let sql = """
            SELECT id, name, author, press, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE id IN (\(Self.placeholders(count: ids.count)))
              AND is_deleted = 0
              AND id != 0
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(ids))
        let booksByID: [Int64: BookPickerBook] = Dictionary(
            uniqueKeysWithValues: rows.map { row in
                let book = BookPickerBook(
                    id: row["id"],
                    title: row["name"] ?? "",
                    author: row["author"] ?? "",
                    press: row["press"] ?? "",
                    coverURL: row["cover"] ?? "",
                    positionUnit: row["position_unit"] ?? 0,
                    totalPosition: row["total_position"] ?? 0,
                    totalPagination: row["total_pagination"] ?? 0
                )
                return (book.id, book)
            }
        )
        return ids.compactMap { booksByID[$0] }
    }

    nonisolated func noteReviewTagPredicate(settings: NoteReviewSettings) -> String {
        let placeholders = Self.placeholders(count: settings.selectedTagIDs.count)
        switch settings.tagMatchRule {
        case .any:
            return """
                n.id IN (
                    SELECT tn.note_id
                    FROM tag_note tn
                    JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
                    WHERE tn.is_deleted = 0 AND tn.tag_id IN (\(placeholders))
                )
                """
        case .all:
            return """
                n.id IN (
                    SELECT tn.note_id
                    FROM tag_note tn
                    JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
                    WHERE tn.is_deleted = 0 AND tn.tag_id IN (\(placeholders))
                    GROUP BY tn.note_id
                    HAVING COUNT(DISTINCT tn.tag_id) = ?
                )
                """
        }
    }

    nonisolated func batchFetchNoteReviewTags(
        _ db: Database,
        noteIDs: [Int64]
    ) throws -> [Int64: [NoteEditorTagOption]] {
        guard !noteIDs.isEmpty else { return [:] }
        // SQL 目的：批量读取回顾卡片关联的书摘标签对象。
        // 涉及表：tag_note INNER JOIN tag。
        // 关键过滤：限定当前页 note_id 集合，排除 tag_note/tag 软删除记录，并限制 tag.type=1。
        // 排序：按 tag_order ASC、tag_note.id ASC 对齐 Android 标签展示顺序。
        // 返回字段用途：按 note_id 分组后渲染当前卡标签 rail，并为回顾卡片标签编辑提供本地回写模型。
        let sql = """
            SELECT tn.note_id, t.id, t.name
            FROM tag_note tn
            JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
            WHERE tn.is_deleted = 0 AND tn.note_id IN (\(Self.placeholders(count: noteIDs.count)))
            ORDER BY t.tag_order ASC, tn.id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(noteIDs))
        var result: [Int64: [NoteEditorTagOption]] = [:]
        for row in rows {
            let noteID: Int64 = row["note_id"]
            guard let name: String = row["name"], !name.isEmpty else { continue }
            result[noteID, default: []].append(NoteEditorTagOption(id: row["id"], title: name))
        }
        return result
    }

    nonisolated func batchFetchNoteReviewImages(
        _ db: Database,
        noteIDs: [Int64]
    ) throws -> [Int64: [String]] {
        guard !noteIDs.isEmpty else { return [:] }
        // SQL 目的：批量读取回顾卡片关联的书摘附图 URL。
        // 涉及表：attach_image。
        // 关键过滤：限定当前页 note_id 集合，排除已软删除图片。
        // 排序：按 id ASC 保持 Android 附图展示顺序。
        // 返回字段用途：按 note_id 分组后渲染卡片图片墙。
        let sql = """
            SELECT note_id, image_url
            FROM attach_image
            WHERE is_deleted = 0 AND note_id IN (\(Self.placeholders(count: noteIDs.count)))
            ORDER BY id ASC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(noteIDs))
        var result: [Int64: [String]] = [:]
        for row in rows {
            let noteID: Int64 = row["note_id"]
            guard let url: String = row["image_url"], !url.isEmpty else { continue }
            result[noteID, default: []].append(url)
        }
        return result
    }

    nonisolated static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    nonisolated static func uniquePositiveIDs(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        var result: [Int64] = []
        result.reserveCapacity(ids.count)
        for id in ids where id > 0 && !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    /// 读取阶段统一清理尾部空白与换行，避免卡片底部出现额外空段。
    nonisolated static func trimTrailingWhitespaceAndNewlines(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var endIndex = text.endIndex
        while endIndex > text.startIndex {
            let previousIndex = text.index(before: endIndex)
            let scalar = text[previousIndex]
            guard scalar.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                break
            }
            endIndex = previousIndex
        }
        return String(text[..<endIndex])
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

            if type == 1 {
                noteTagItems.append(tag)
            } else if type == 2 {
                bookTagItems.append(tag)
            }
        }

        var sections: [TagSection] = []
        if !noteTagItems.isEmpty {
            sections.append(TagSection(id: 1, title: "笔记标签", tags: noteTagItems))
        }
        if !bookTagItems.isEmpty {
            sections.append(TagSection(id: 2, title: "书籍标签", tags: bookTagItems))
        }
        return sections
    }

    nonisolated func fetchNoteEditorBooks(_ db: Database) throws -> [BookPickerBook] {
        // SQL 目的：读取编辑页可选书籍列表，供书卡选择 sheet 展示。
        // 涉及表：book。
        // 关键过滤：仅保留未软删除且非占位书籍；返回 title/author/press/cover 与位置字段；按 updated_date DESC 对齐 Android “上次编辑书籍优先”。
        let sql = """
            SELECT id, name, author, press, cover, position_unit, total_position, total_pagination
            FROM book
            WHERE is_deleted = 0
              AND id != 0
            ORDER BY updated_date DESC, id DESC
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            BookPickerBook(
                id: row["id"],
                title: row["name"] ?? "",
                author: row["author"] ?? "",
                press: row["press"] ?? "",
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
        // 关键过滤：type = 1、同 owner、未软删除；排序按 tag_order ASC。
        let sql = """
            SELECT id, name
            FROM tag
            WHERE type = 1 AND user_id = ? AND is_deleted = 0
            ORDER BY tag_order ASC, id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [ownerID]).compactMap { row in
            guard let title: String = row["name"], !title.isEmpty else { return nil }
            return NoteEditorTagOption(id: row["id"], title: title)
        }
    }

    nonisolated func fetchNoteEditorChapters(_ db: Database, bookId: Int64) throws -> [NoteEditorChapterOption] {
        // SQL 目的：一次读取指定书籍的全部有效章节，在内存中按 parent_id 构建 Android 选择器同款的先序平铺结果。
        // 涉及表：chapter。
        // 关键过滤：限定 book_id，排除系统根与兼容删除行；同父级按 chapter_order/id 稳定排序。
        // 时间字段：不读取或转换时间字段。
        // 返回字段用途：id/parent_id 构树，title/order 展示与排序，is_starred 保留与 Android 一致的选择语义。
        let sql = """
            SELECT id, book_id, parent_id, title, remark, chapter_order,
                   is_import, chapter_level, source_type, source_uid,
                   source_anchor, source_order, source_path, is_starred,
                   created_date, updated_date, last_sync_date, is_deleted
            FROM chapter
            WHERE book_id = ? AND id != 0 AND is_deleted = 0
            ORDER BY parent_id ASC, chapter_order ASC, id ASC
            """
        let chapters = try ChapterRecord.fetchAll(db, sql: sql, arguments: [bookId])
            .filter { $0.id != nil }
        let childrenByParentID = Dictionary(grouping: chapters, by: \.parentId)
            .mapValues { children in
                children.sorted { lhs, rhs in
                    if lhs.chapterOrder != rhs.chapterOrder {
                        return lhs.chapterOrder < rhs.chapterOrder
                    }
                    return (lhs.id ?? 0) < (rhs.id ?? 0)
                }
            }
        var result: [NoteEditorChapterOption] = []
        var visitedIDs: Set<Int64> = []

        /// 选择列表需要一次性物化为稳定先序；visited 防止旧备份中的循环关系卡住编辑页。
        func appendSubtree(_ chapter: ChapterRecord, level: Int, parentPath: [String]) {
            guard let chapterID = chapter.id, visitedIDs.insert(chapterID).inserted else { return }
            let normalizedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = normalizedTitle.isEmpty ? "未命名章节" : normalizedTitle
            let displayLevel = min(ChapterManagementPolicy.maximumDepth, max(1, level))
            let path = parentPath + [displayTitle]
            result.append(
                NoteEditorChapterOption(
                    id: chapterID,
                    title: displayTitle,
                    parentID: chapter.parentId,
                    level: displayLevel,
                    pathText: path.joined(separator: ChapterManagementPolicy.pathSeparator),
                    isStarred: chapter.isStarred != 0
                )
            )
            for child in childrenByParentID[chapterID] ?? [] {
                appendSubtree(child, level: displayLevel + 1, parentPath: path)
            }
        }

        for root in childrenByParentID[0] ?? [] {
            appendSubtree(root, level: 1, parentPath: [])
        }

        // 旧备份若存在孤儿/循环章节，仍以存储层级作为独立分支显示；不隐藏数据，也不让异常结构阻塞整个书摘编辑页。
        for chapter in chapters {
            guard let chapterID = chapter.id, !visitedIDs.contains(chapterID) else { continue }
            let fallbackLevel = chapter.chapterLevel > 0 ? Int(chapter.chapterLevel) : 1
            let storedPath = (chapter.sourcePath ?? "")
                .components(separatedBy: ChapterManagementPolicy.pathSeparator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            appendSubtree(
                chapter,
                level: fallbackLevel,
                parentPath: storedPath.count > 1 ? Array(storedPath.dropLast()) : []
            )
        }
        return result
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
        // 关键过滤：tag_note/tag 均为未软删除记录，且 tag.type = 1。
        let sql = """
            SELECT t.id, t.name
            FROM tag_note tn
            JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0
            WHERE tn.note_id = ? AND tn.is_deleted = 0 AND t.type = 1
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
        if positionUnit == 0, readPosition < 0 || readPosition > 100 {
            throw NoteEditorError.invalidReadPosition("进度值应在 [0,100] 区间内")
        }
        if positionUnit == 1 && totalPosition != 0 {
            if readPosition <= 0 {
                throw NoteEditorError.invalidReadPosition("位置应大于 0")
            }
            if readPosition > Double(totalPosition) {
                throw NoteEditorError.invalidReadPosition("位置应小于总位置（\(totalPosition)）")
            }
        }
        if positionUnit == 2 && totalPagination != 0 {
            if readPosition <= 0 {
                throw NoteEditorError.invalidReadPosition("页码应大于 0 页")
            }
            if readPosition > Double(totalPagination) {
                throw NoteEditorError.invalidReadPosition("页码应小于总页码（\(totalPagination) 页）")
            }
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
                        uploadState: .success,
                        origin: item.origin
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
            // SQL 目的：软删除指定书摘的现有标签关系，随后按当前选择重建唯一有效关系。
            // 表关系：tag_note。
            // 关键过滤：按 note_id 精确命中且只处理 is_deleted = 0 的关系。
            // 时间字段：updated_date 与新关系 created_date 均使用调用方传入的 Unix 毫秒时间戳。
            // 副作用：保留可同步的旧关系 tombstone，仍处于外层书摘保存事务中。
            sql: "UPDATE tag_note SET updated_date = ?, is_deleted = 1 WHERE note_id = ? AND is_deleted = 0",
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
            // 关键过滤：按 note_id 精确命中且只处理 is_deleted = 0 的附图。
            // 时间字段：updated_date 与新附图 created_date 均使用调用方传入的 Unix 毫秒时间戳。
            // 副作用：保留可同步的旧附图 tombstone，仍处于外层书摘保存事务中。
            sql: "UPDATE attach_image SET updated_date = ?, is_deleted = 1 WHERE note_id = ? AND is_deleted = 0",
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

extension NoteRepository {
    /// 读取批量编辑首屏；进入数据库读取前响应任务取消，读取完成后不会保活调用方。
    func fetchNoteBatchEditBootstrap(noteIDs: [Int64]) async throws -> NoteBatchEditBootstrap {
        try Task.checkCancellation()
        let requestedIDs = Self.normalizedPositiveIDs(noteIDs)
        guard !requestedIDs.isEmpty else { throw NoteBatchMutationError.emptySelection }

        return try await databaseManager.database.dbPool.read { db in
            let notes = try fetchBatchNoteItems(db, noteIDs: requestedIDs)
            let availableIDs = Set(notes.map(\.id))
            return NoteBatchEditBootstrap(
                requestedNoteIDs: requestedIDs,
                notes: notes,
                unavailableNoteIDs: requestedIDs.filter { !availableIDs.contains($0) },
                books: try fetchNoteEditorBooks(db),
                tags: try fetchNoteEditorTags(db)
            )
        }
    }

    /// 物理删除批量书摘及关联数据；调用任务在事务开始前可取消，事务开始后原子完成。
    func deleteNotes(noteIDs: [Int64]) async throws {
        try Task.checkCancellation()
        let ids = Self.normalizedPositiveIDs(noteIDs)
        guard !ids.isEmpty else { throw NoteBatchMutationError.emptySelection }

        try await databaseManager.database.dbPool.write { db in
            _ = try requireActiveNoteRecords(db, noteIDs: ids)
            try hardDeleteNotes(db, noteIDs: ids)
        }
    }

    /// 跨书移动原书摘；调用任务在事务开始前可取消，章节路径创建和书摘更新在同一事务内原子完成。
    func moveNotes(noteIDs: [Int64], toBookID bookID: Int64) async throws {
        try Task.checkCancellation()
        let ids = Self.normalizedPositiveIDs(noteIDs)
        guard !ids.isEmpty else { throw NoteBatchMutationError.emptySelection }
        guard bookID > 0 else { throw NoteBatchMutationError.bookNotFound }

        try await databaseManager.database.dbPool.write { db in
            guard let isTargetBookDeleted = try BookRecord.fetchOne(db, key: bookID)?.isDeleted,
                  isTargetBookDeleted == 0 else {
                throw NoteBatchMutationError.bookNotFound
            }
            var records = try requireActiveNoteRecords(db, noteIDs: ids)
            let now = Self.currentTimestampMillis

            for index in records.indices {
                let pathTitles = try fetchChapterPathTitles(db, chapterID: records[index].chapterId)
                let targetChapterID = try ensureChapterPath(
                    db,
                    bookID: bookID,
                    pathTitles: pathTitles,
                    timestamp: now
                )
                try moveImportHashes(db, note: records[index], targetBookID: bookID)
                records[index].bookId = bookID
                records[index].chapterId = targetChapterID
                records[index].updatedDate = now
                try records[index].update(db)
            }
        }
    }

    /// 在书内移动原书摘到章节；调用任务在事务开始前可取消，所有书摘要么一起更新、要么一起回滚。
    func moveNotes(noteIDs: [Int64], toChapterID chapterID: Int64) async throws {
        try Task.checkCancellation()
        let ids = Self.normalizedPositiveIDs(noteIDs)
        guard !ids.isEmpty else { throw NoteBatchMutationError.emptySelection }
        guard chapterID > 0 else { throw NoteBatchMutationError.chapterNotFound }

        try await databaseManager.database.dbPool.write { db in
            guard let chapter = try ChapterRecord.fetchOne(db, key: chapterID),
                  chapter.id != 0,
                  chapter.isDeleted == 0 else {
                throw NoteBatchMutationError.chapterNotFound
            }
            var records = try requireActiveNoteRecords(db, noteIDs: ids)
            guard records.allSatisfy({ $0.bookId == chapter.bookId }) else {
                throw NoteBatchMutationError.chapterBookMismatch
            }
            let now = Self.currentTimestampMillis
            for index in records.indices {
                records[index].chapterId = chapterID
                records[index].updatedDate = now
                try records[index].update(db)
            }
        }
    }

    /// 在选择章节现场创建手动章节；调用任务在事务开始前可取消，父级校验、排序计算与插入原子完成。
    func createChapter(bookID: Int64, parentID: Int64, title: String) async throws -> NoteEditorChapterOption {
        try Task.checkCancellation()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bookID > 0 else { throw NoteBatchMutationError.bookNotFound }
        guard !normalizedTitle.isEmpty, normalizedTitle.count <= 100 else {
            throw NoteBatchMutationError.invalidChapterTitle
        }

        return try await databaseManager.database.dbPool.write { db in
            guard let isBookDeleted = try BookRecord.fetchOne(db, key: bookID)?.isDeleted,
                  isBookDeleted == 0 else {
                throw NoteBatchMutationError.bookNotFound
            }
            let parentPath: [String]
            if parentID > 0 {
                guard let parent = try ChapterRecord.fetchOne(db, key: parentID), parent.isDeleted == 0 else {
                    throw NoteBatchMutationError.chapterNotFound
                }
                guard parent.bookId == bookID else { throw NoteBatchMutationError.chapterBookMismatch }
                parentPath = try fetchChapterPathTitles(db, chapterID: parentID)
                guard parentPath.count < 5 else { throw NoteBatchMutationError.invalidChapterDepth }
            } else {
                parentPath = []
            }

            // SQL 目的：计算现场新增章节在当前父级下的尾部排序序号。
            // 涉及表：chapter。
            // 关键过滤：限定同书、同 parent_id 与有效记录；parentID=0 表示根章节。
            // 时间字段：不读取时间字段。
            // 返回字段用途：MAX + 1 对齐 Android ChapterRepository.addChapterSync。
            let nextOrder = (try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(MAX(chapter_order), 0) + 1
                    FROM chapter
                    WHERE book_id = ? AND parent_id = ? AND is_deleted = 0
                    """,
                arguments: [bookID, max(0, parentID)]
            )) ?? 1
            let now = Self.currentTimestampMillis
            var chapter = ChapterRecord(
                id: nil,
                bookId: bookID,
                parentId: max(0, parentID),
                title: normalizedTitle,
                remark: "",
                chapterOrder: nextOrder,
                isImport: 0,
                chapterLevel: Int64(parentPath.count + 1),
                sourceType: 0,
                sourceUid: nil,
                sourceAnchor: nil,
                sourceOrder: 0,
                sourcePath: (parentPath + [normalizedTitle]).joined(separator: " / "),
                isStarred: 0,
                createdDate: now,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try chapter.insert(db)
            guard let chapterID = chapter.id else { throw NoteBatchMutationError.chapterNotFound }
            return NoteEditorChapterOption(
                id: chapterID,
                title: normalizedTitle,
                parentID: max(0, parentID),
                level: parentPath.count + 1,
                pathText: (parentPath + [normalizedTitle]).joined(separator: ChapterManagementPolicy.pathSeparator),
                isStarred: false
            )
        }
    }

    /// 全量替换多条书摘的标签；调用任务在事务开始前可取消，旧关系软删除后重建有效集合。
    func replaceTagsForNotes(noteIDs: [Int64], tagIDs: [Int64]) async throws {
        try Task.checkCancellation()
        let ids = Self.normalizedPositiveIDs(noteIDs)
        let normalizedTagIDs = Self.normalizedPositiveIDs(tagIDs)
        guard !ids.isEmpty else { throw NoteBatchMutationError.emptySelection }

        try await databaseManager.database.dbPool.write { db in
            _ = try requireActiveNoteRecords(db, noteIDs: ids)
            let tags = try requireActiveNoteTags(db, tagIDs: normalizedTagIDs)
            let now = Self.currentTimestampMillis
            for noteID in ids {
                try replaceNoteTagAssociations(db, noteId: noteID, tags: tags, timestamp: now)
            }
        }
    }

    /// 生成合并预览；调用任务在读取前响应取消，正文、想法、标签与附图均来自同一数据库快照。
    func fetchNoteMergeDraft(request: NoteMergePreviewRequest) async throws -> NoteMergeDraft {
        try Task.checkCancellation()
        let sourceIDs = Self.normalizedPositiveIDs(request.sourceNoteIDs)
        guard sourceIDs.count >= 2 else { throw NoteBatchMutationError.emptySelection }

        return try await databaseManager.database.dbPool.read { db in
            let sourceNotes = try requireActiveNoteItems(db, noteIDs: sourceIDs)
            let bookIDs = Set(sourceNotes.map(\.bookID))
            guard bookIDs.count == 1, let bookID = bookIDs.first else {
                throw NoteBatchMutationError.notesFromDifferentBooks
            }
            guard let book = try fetchNoteEditorBooks(db).first(where: { $0.id == bookID }) else {
                throw NoteBatchMutationError.bookNotFound
            }

            let rawTexts = try fetchRawNoteTexts(db, noteIDs: sourceIDs)
            let expectedContentIDs = sourceIDs.filter { rawTexts[$0]?.content.isBlank == false }
            let expectedIdeaIDs = sourceIDs.filter { rawTexts[$0]?.idea.isBlank == false }
            let contentIDs = try validatedMergeOrder(
                request.contentNoteIDs,
                expectedIDs: expectedContentIDs,
                sourceIDs: sourceIDs
            )
            let ideaIDs = try validatedMergeOrder(
                request.ideaNoteIDs,
                expectedIDs: expectedIdeaIDs,
                sourceIDs: sourceIDs
            )
            let contentHTML = contentIDs.compactMap { rawTexts[$0]?.content }.joined(separator: request.contentRule.separator)
            let ideaHTML = ideaIDs.compactMap { rawTexts[$0]?.idea }.joined(separator: request.ideaRule.separator)

            let sharedPosition = sourceNotes.first.map { first in
                sourceNotes.allSatisfy { !$0.position.isBlank && $0.position == first.position }
                    ? first.position
                    : ""
            } ?? ""
            let sharedChapterID = sourceNotes.first.map { first in
                sourceNotes.allSatisfy { $0.chapterID > 0 && $0.chapterID == first.chapterID }
                    ? first.chapterID
                    : 0
            } ?? 0
            let sharedChapterTitle = sourceNotes.first(where: { $0.chapterID == sharedChapterID })?.chapterTitle ?? ""

            var seenTagIDs = Set<Int64>()
            let mergedTags = sourceNotes.flatMap(\.tags).compactMap { tag -> NoteEditorTagOption? in
                guard seenTagIDs.insert(tag.id).inserted else { return nil }
                return NoteEditorTagOption(id: tag.id, title: tag.title)
            }

            return NoteMergeDraft(
                sourceNoteIDs: sourceIDs,
                sourceNotes: sourceNotes,
                book: book,
                contentNoteIDs: contentIDs,
                ideaNoteIDs: ideaIDs,
                contentRule: request.contentRule,
                ideaRule: request.ideaRule,
                contentHTML: contentHTML,
                ideaHTML: ideaHTML,
                position: sharedPosition,
                positionUnit: book.positionUnit,
                includeTime: true,
                createdDate: Self.currentTimestampMillis,
                chapterID: sharedChapterID,
                chapterTitle: sharedChapterTitle,
                selectedTags: mergedTags,
                imageItems: try fetchMergeImages(db, noteIDs: sourceIDs)
            )
        }
    }

    /// 提交合并草稿；调用任务在事务开始前可取消，来源删除与合并结果插入作为不可分割事务完成。
    func mergeNotes(_ draft: NoteMergeDraft) async throws -> Int64 {
        try Task.checkCancellation()
        let sourceIDs = Self.normalizedPositiveIDs(draft.sourceNoteIDs)
        guard sourceIDs.count >= 2,
              draft.sourceNotes.count == sourceIDs.count,
              Set(draft.sourceNotes.map(\.id)) == Set(sourceIDs),
              !draft.contentHTML.isBlank || !draft.ideaHTML.isBlank || !draft.imageItems.isEmpty else {
            throw NoteBatchMutationError.invalidMergeDraft
        }
        let uploadedImages = try ensureReadyUploadedImages(for: draft.imageItems)
        let selectedTagIDs = Self.normalizedPositiveIDs(draft.selectedTags.map(\.id))

        return try await databaseManager.database.dbPool.write { db in
            guard var book = try BookRecord.fetchOne(db, key: draft.book.id), book.isDeleted == 0 else {
                throw NoteBatchMutationError.bookNotFound
            }
            let sourceRecords = try requireActiveNoteRecords(db, noteIDs: sourceIDs)
            guard sourceRecords.allSatisfy({ $0.bookId == draft.book.id }) else {
                throw NoteBatchMutationError.notesFromDifferentBooks
            }

            if draft.chapterID > 0 {
                guard let chapter = try ChapterRecord.fetchOne(db, key: draft.chapterID),
                      chapter.isDeleted == 0 else {
                    throw NoteBatchMutationError.chapterNotFound
                }
                guard chapter.bookId == draft.book.id else {
                    throw NoteBatchMutationError.chapterBookMismatch
                }
            }
            let selectedTags = try requireActiveNoteTags(db, tagIDs: selectedTagIDs)
            let now = Self.currentTimestampMillis
            let position = draft.position.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numericPosition = Double(position), !position.isEmpty {
                try validateReadPosition(
                    numericPosition,
                    positionUnit: book.positionUnit,
                    totalPosition: book.totalPosition,
                    totalPagination: book.totalPagination
                )
            }

            let sourceImportHashes = try sourceRecords.reduce(into: Set<String>()) { result, note in
                result.formUnion(try ensureImportHashes(db, note: note))
            }
            try hardDeleteNotes(db, noteIDs: sourceIDs)

            var mergedRecord = NoteRecord(
                id: nil,
                bookId: draft.book.id,
                chapterId: draft.chapterID,
                content: draft.contentHTML,
                idea: draft.ideaHTML,
                position: position,
                positionUnit: book.positionUnit,
                wereadRange: "",
                includeTime: draft.includeTime ? 1 : 0,
                createdDate: draft.createdDate > 0 ? draft.createdDate : now,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try mergedRecord.insert(db)
            guard let mergedNoteID = mergedRecord.id else {
                throw NoteBatchMutationError.invalidMergeDraft
            }
            for contentHash in sourceImportHashes {
                try NoteImportHashRecord(
                    bookId: draft.book.id,
                    contentHash: contentHash,
                    noteId: mergedNoteID
                ).insert(db)
            }

            if let numericPosition = Double(position), !position.isEmpty {
                if book.currentPositionUnit == book.positionUnit {
                    book.readPosition = max(book.readPosition, numericPosition)
                } else {
                    book.currentPositionUnit = book.positionUnit
                    book.readPosition = numericPosition
                }
                try book.update(db)
            }
            try replaceNoteTagAssociations(db, noteId: mergedNoteID, tags: selectedTags, timestamp: now)
            try replaceNoteImages(db, noteId: mergedNoteID, images: uploadedImages, timestamp: now)
            return mergedNoteID
        }
    }
}

private extension NoteRepository {
    /// 在任何正文/想法/归属变更前固化导入身份；无存量 Hash 时按 Android v1 文本规则补建。
    nonisolated func ensureImportHashes(
        _ db: Database,
        note: NoteRecord
    ) throws -> Set<String> {
        guard let noteID = note.id else { return [] }
        let existing = Set(try NoteImportHashRecord
            .filter(Column("note_id") == noteID)
            .fetchAll(db)
            .map(\.contentHash))
        if !existing.isEmpty { return existing }
        guard let contentHash = NoteImportContentHash.calculate(
            content: note.content,
            idea: note.idea
        ) else { return [] }
        try NoteImportHashRecord(
            bookId: note.bookId,
            contentHash: contentHash,
            noteId: noteID
        ).insert(db)
        return [contentHash]
    }

    /// 跨书移动时在同一事务内迁移 Hash 复合主键，避免原书残留身份或目标书重复导入。
    nonisolated func moveImportHashes(
        _ db: Database,
        note: NoteRecord,
        targetBookID: Int64
    ) throws {
        guard let noteID = note.id, note.bookId != targetBookID else {
            _ = try ensureImportHashes(db, note: note)
            return
        }
        let hashes = try ensureImportHashes(db, note: note)
        try db.execute(
            // SQL 目的：移除书摘原书归属下的全部导入身份，随后以目标书复合主键重建。
            // 涉及表：note_import_hash -> note。
            // 关键过滤：按 note_id 精确命中。
            // 时间字段：派生身份表无时间字段。
            // 副作用：调用者仍处于跨书移动事务，失败会与 note 更新共同回滚。
            sql: "DELETE FROM note_import_hash WHERE note_id = ?",
            arguments: [noteID]
        )
        for contentHash in hashes {
            try NoteImportHashRecord(
                bookId: targetBookID,
                contentHash: contentHash,
                noteId: noteID
            ).insert(db)
        }
    }

    nonisolated static let protectedDefaultRelatedCategoryIDs: ClosedRange<Int64> = 1...6
    nonisolated static let protectedDefaultRelatedCategoryTitles: Set<String> = [
        "书籍", "电影", "音乐", "地点", "人物", "事件"
    ]

    /// 识别 Android 固定六个种子分类；book_id=0 仅代表全局作用域，不能单独作为保护条件。
    nonisolated static func isProtectedDefaultRelatedCategory(_ row: Row) -> Bool {
        let id: Int64 = row["id"]
        let bookID: Int64 = row["book_id"] ?? 0
        guard bookID == 0 else { return false }
        if protectedDefaultRelatedCategoryIDs.contains(id) {
            return true
        }
        let title: String = row["title"] ?? ""
        let createdDate: Int64 = row["created_date"] ?? -1
        return createdDate == 0 && protectedDefaultRelatedCategoryTitles.contains(title)
    }

    nonisolated struct RawNoteText {
        let content: String
        let idea: String
    }

    /// 去重并保留调用方顺序，防止同一书摘被重复更新或重复合并。
    nonisolated static func normalizedPositiveIDs(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { $0 > 0 && seen.insert($0).inserted }
    }

    /// 读取批量操作卡片并恢复调用方 ID 顺序，确保选择状态与数据库返回顺序解耦。
    nonisolated func fetchBatchNoteItems(_ db: Database, noteIDs: [Int64]) throws -> [NoteExcerptListItem] {
        guard !noteIDs.isEmpty else { return [] }
        // SQL 目的：批量读取选中书摘及其书籍、章节基础字段，标签与附图随后按 ID 集合批量补齐。
        // 涉及表：note INNER JOIN book LEFT JOIN chapter。
        // 关键过滤：限定 note.id 集合，排除已删除书摘/书籍；失效章节以空标题降级。
        // 时间字段：created_date 为 Android 毫秒时间戳，不做时区转换。
        // 返回字段用途：构建批量编辑 bootstrap 与合并来源预览。
        let rows = try Row.fetchAll(
            db,
            sql: noteExcerptSelectSQL(
                whereClause: "n.is_deleted = 0 AND n.id IN (\(Self.placeholders(count: noteIDs.count)))",
                suffix: ""
            ),
            arguments: StatementArguments(noteIDs)
        )
        let snapshot = try buildNoteExcerptSnapshot(db, rows: rows, totalCount: rows.count)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        return noteIDs.compactMap { byID[$0] }
    }

    /// 要求全部来源书摘仍有效，任何失效选择都中止写入，避免批量操作静默只改一部分。
    nonisolated func requireActiveNoteItems(_ db: Database, noteIDs: [Int64]) throws -> [NoteExcerptListItem] {
        let items = try fetchBatchNoteItems(db, noteIDs: noteIDs)
        guard items.count == noteIDs.count else { throw NoteBatchMutationError.noteNotFound }
        return items
    }

    /// 读取全部有效书摘 Record；写事务只接收完整选择集，避免并发删除后部分提交。
    nonisolated func requireActiveNoteRecords(_ db: Database, noteIDs: [Int64]) throws -> [NoteRecord] {
        guard !noteIDs.isEmpty else { throw NoteBatchMutationError.emptySelection }
        // SQL 目的：读取批量写入的全部有效书摘 Record。
        // 涉及表：note INNER JOIN book，避免对已删除书籍中的旧兼容记录继续写入。
        // 关键过滤：限定主键集合，note/book 均有效且书籍不是系统根。
        // 时间字段：完整返回 created_date/updated_date，移动时仅覆盖 updated_date。
        // 返回字段用途：作为移动、删除和合并事务的真实写入 owner。
        let records = try NoteRecord.fetchAll(
            db,
            sql: """
                SELECT n.*
                FROM note n
                JOIN book b ON b.id = n.book_id AND b.is_deleted = 0 AND b.id != 0
                WHERE n.is_deleted = 0
                  AND n.id IN (\(Self.placeholders(count: noteIDs.count)))
                """,
            arguments: StatementArguments(noteIDs)
        )
        guard records.count == noteIDs.count else { throw NoteBatchMutationError.noteNotFound }
        let order = Dictionary(uniqueKeysWithValues: noteIDs.enumerated().map { ($0.element, $0.offset) })
        return records.sorted { order[$0.id ?? 0, default: .max] < order[$1.id ?? 0, default: .max] }
    }

    /// 校验全部标签仍为当前用户的有效书摘标签，并按调用顺序返回写入模型。
    nonisolated func requireActiveNoteTags(
        _ db: Database,
        tagIDs: [Int64]
    ) throws -> [NoteEditorTagOption] {
        guard !tagIDs.isEmpty else { return [] }
        let availableByID = Dictionary(uniqueKeysWithValues: try fetchNoteEditorTags(db).map { ($0.id, $0) })
        let tags = tagIDs.compactMap { availableByID[$0] }
        guard tags.count == tagIDs.count else { throw NoteBatchMutationError.tagNotFound }
        return tags
    }

    /// 按外键依赖顺序物理删除书摘、附图、标签和导入 Hash，全部副作用与业务写入共享事务。
    nonisolated func hardDeleteNotes(_ db: Database, noteIDs: [Int64]) throws {
        guard !noteIDs.isEmpty else { return }
        let placeholders = Self.placeholders(count: noteIDs.count)
        try db.execute(
            // SQL 目的：物理删除选中书摘的全部附图，先解除 attach_image -> note 外键引用。
            // 涉及表：attach_image -> note。
            // 关键过滤：按 note_id 集合精确命中，兼容清理历史 tombstone。
            // 时间字段：物理删除不写时间字段。
            // 副作用：解除主记录硬删除前的外键约束。
            sql: "DELETE FROM attach_image WHERE note_id IN (\(placeholders))",
            arguments: StatementArguments(noteIDs)
        )
        try db.execute(
            // SQL 目的：物理删除选中书摘的全部标签关系，先解除 tag_note -> note 外键引用。
            // 涉及表：tag_note -> note/tag。
            // 关键过滤：按 note_id 集合精确命中，兼容清理历史 tombstone。
            // 时间字段：物理删除不写时间字段。
            // 副作用：解除主记录硬删除前的外键约束。
            sql: "DELETE FROM tag_note WHERE note_id IN (\(placeholders))",
            arguments: StatementArguments(noteIDs)
        )
        try db.execute(
            // SQL 目的：物理清理选中书摘的导入去重 Hash，这是 Android v45 删除管理器的特例。
            // 涉及表：note_import_hash -> note。
            // 关键过滤：按 note_id 集合精确命中。
            // 时间字段：该派生表无 is_deleted/updated_date 语义。
            // 副作用：后续重新导入不会被旧 Hash 阻断。
            sql: "DELETE FROM note_import_hash WHERE note_id IN (\(placeholders))",
            arguments: StatementArguments(noteIDs)
        )
        try db.execute(
            // SQL 目的：在所有依赖关系清理后物理删除选中书摘主记录。
            // 涉及表：note。
            // 关键过滤：按 id 集合精确命中，兼容清理历史 tombstone。
            // 时间字段：物理删除不写时间字段。
            // 副作用：观察流在事务提交时刷新；失败与关联关系、Hash 清理共同回滚。
            sql: "DELETE FROM note WHERE id IN (\(placeholders))",
            arguments: StatementArguments(noteIDs)
        )
    }

    /// 从真实 parent_id 链读取祖先标题路径；缺失章节降级到根章节，循环或超深结构显式失败。
    nonisolated func fetchChapterPathTitles(_ db: Database, chapterID: Int64) throws -> [String] {
        guard chapterID > 0 else { return [] }
        var currentID = chapterID
        var visited = Set<Int64>()
        var reversedTitles: [String] = []

        while currentID > 0 {
            guard visited.insert(currentID).inserted else { throw NoteBatchMutationError.invalidChapterDepth }
            guard let chapter = try ChapterRecord.fetchOne(db, key: currentID), chapter.isDeleted == 0 else {
                return []
            }
            reversedTitles.append(chapter.title)
            guard reversedTitles.count <= 5 else { throw NoteBatchMutationError.invalidChapterDepth }
            currentID = chapter.parentId
        }
        return Array(reversedTitles.reversed())
    }

    /// 在目标书中按“同书 + 同父级 + 精确标题”复用章节，缺失节点按 Android 目录导入来源逐级创建。
    nonisolated func ensureChapterPath(
        _ db: Database,
        bookID: Int64,
        pathTitles: [String],
        timestamp: Int64
    ) throws -> Int64 {
        guard pathTitles.count <= 5 else { throw NoteBatchMutationError.invalidChapterDepth }
        guard !pathTitles.isEmpty else { return 0 }
        var parentID: Int64 = 0
        var resolvedPath: [String] = []

        for (index, title) in pathTitles.enumerated() {
            resolvedPath.append(title)
            // SQL 目的：按 Android querySubChapterTitle 语义复用目标书同父级下的精确同名章节。
            // 涉及表：chapter。
            // 关键过滤：非根、有效、同 book_id/parent_id/title；同名重复时按最小 id 稳定选择。
            // 时间字段：不读取时间字段。
            // 返回字段用途：复用现有章节主键，避免跨书移动制造重复目录。
            if let existingID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM chapter
                    WHERE id != 0 AND is_deleted = 0
                      AND book_id = ? AND parent_id = ? AND title = ?
                    ORDER BY id ASC
                    LIMIT 1
                    """,
                arguments: [bookID, parentID, title]
            ) {
                parentID = existingID
                continue
            }

            // SQL 目的：计算新章节在目标父级下的尾部排序序号。
            // 涉及表：chapter。
            // 关键过滤：同 book_id、parent_id 且有效；根与子章节共用同一安全条件。
            // 时间字段：不读取时间字段。
            // 返回字段用途：MAX + 1 对齐 Android ChapterRepository.addChapterSync 的追加规则。
            let nextOrder = (try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(MAX(chapter_order), 0) + 1
                    FROM chapter
                    WHERE book_id = ? AND parent_id = ? AND is_deleted = 0
                    """,
                arguments: [bookID, parentID]
            )) ?? 1
            var chapter = ChapterRecord(
                id: nil,
                bookId: bookID,
                parentId: parentID,
                title: title,
                remark: "",
                chapterOrder: nextOrder,
                isImport: 1,
                chapterLevel: Int64(index + 1),
                sourceType: 2,
                sourceUid: nil,
                sourceAnchor: nil,
                sourceOrder: 0,
                sourcePath: resolvedPath.joined(separator: " / "),
                isStarred: 0,
                createdDate: timestamp,
                updatedDate: 0,
                lastSyncDate: 0,
                isDeleted: 0
            )
            try chapter.insert(db)
            guard let insertedID = chapter.id else { throw NoteBatchMutationError.chapterNotFound }
            parentID = insertedID
        }
        return parentID
    }

    /// 读取合并拼接所需原始 HTML，禁止复用列表尾部清理逻辑改变用户正文。
    nonisolated func fetchRawNoteTexts(_ db: Database, noteIDs: [Int64]) throws -> [Int64: RawNoteText] {
        guard !noteIDs.isEmpty else { return [:] }
        // SQL 目的：读取合并来源书摘的原始正文和想法 HTML。
        // 涉及表：note。
        // 关键过滤：限定有效来源 ID；有效性完整校验已由 requireActiveNoteItems 承担。
        // 时间字段：不读取时间字段。
        // 返回字段用途：按正文/想法独立顺序拼接，保留原始尾部字符。
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, content, idea
                FROM note
                WHERE is_deleted = 0
                  AND id IN (\(Self.placeholders(count: noteIDs.count)))
                """,
            arguments: StatementArguments(noteIDs)
        )
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let id: Int64 = row["id"]
            return (id, RawNoteText(content: row["content"] ?? "", idea: row["idea"] ?? ""))
        })
    }

    /// 校验合并排序仍完整覆盖对应非空字段来源，拒绝重复、越界或遗漏 ID。
    nonisolated func validatedMergeOrder(
        _ requestedIDs: [Int64],
        expectedIDs: [Int64],
        sourceIDs: [Int64]
    ) throws -> [Int64] {
        let normalized = Self.normalizedPositiveIDs(requestedIDs)
        guard normalized.count == requestedIDs.filter({ $0 > 0 }).count,
              Set(normalized).isSubset(of: Set(sourceIDs)) else {
            throw NoteBatchMutationError.invalidMergeDraft
        }
        let expectedSet = Set(expectedIDs)
        let orderedRelevantIDs = normalized.filter { expectedSet.contains($0) }
        guard Set(orderedRelevantIDs) == expectedSet,
              orderedRelevantIDs.count == expectedIDs.count else {
            throw NoteBatchMutationError.invalidMergeDraft
        }
        return orderedRelevantIDs
    }

    /// 按来源书摘顺序和每条附图主键顺序汇总合并附图，重复 URL 仍保留为独立图片。
    nonisolated func fetchMergeImages(_ db: Database, noteIDs: [Int64]) throws -> [NoteEditorImageItem] {
        guard !noteIDs.isEmpty else { return [] }
        // SQL 目的：读取全部合并来源书摘的有效附图及真实主键。
        // 涉及表：attach_image。
        // 关键过滤：限定 note_id 集合且排除旧 tombstone。
        // 排序：SQL 先按 note_id/id，最终再按调用方 noteIDs 顺序恢复 Android 合并顺序。
        // 时间字段：created_date 为毫秒时间戳，直接保留。
        // 返回字段用途：构建可由合并页继续增删的 NoteEditorImageItem。
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, note_id, image_url, created_date
                FROM attach_image
                WHERE is_deleted = 0
                  AND note_id IN (\(Self.placeholders(count: noteIDs.count)))
                ORDER BY note_id ASC, id ASC
                """,
            arguments: StatementArguments(noteIDs)
        )
        let byNoteID = Dictionary(grouping: rows, by: { $0["note_id"] as Int64 })
        return noteIDs.flatMap { noteID in
            byNoteID[noteID, default: []].map { row in
                let imageID: Int64 = row["id"]
                return NoteEditorImageItem(
                    id: "merge-\(noteID)-\(imageID)",
                    remoteURL: row["image_url"] ?? "",
                    localFilePath: nil,
                    createdDate: row["created_date"] ?? 0,
                    uploadState: .success
                )
            }
        }
    }
}

private extension String {
    /// 合并判空只忽略空白字符，不转换或清理富文本 HTML。
    nonisolated var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
