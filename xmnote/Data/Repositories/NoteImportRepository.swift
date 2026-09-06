/**
 * [INPUT]: 依赖统一 NoteImport Draft、GRDB Record、DatabaseManager、可选会员写入门禁与三联凭证存储
 * [OUTPUT]: 对外提供 NoteImportRepository，完成全来源书摘的本地匹配和逐书增量落库
 * [POS]: Data/Repositories 的统一导入写边界；文件、剪贴板、API 与特殊入口共享此实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import SwiftSoup

@MainActor
final class NoteImportRepository: NoteImportRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let defaults: UserDefaults
    private let bookSearchRepository: any BookSearchRepositoryProtocol
    private let requiredMembership: (any MembershipRepositoryProtocol)?
    private let lifeWeekCredentialStore = LifeWeekCredentialStore()

    init(
        databaseManager: DatabaseManager,
        defaults: UserDefaults = .standard,
        bookSearchRepository: (any BookSearchRepositoryProtocol)? = nil,
        requiredMembership: (any MembershipRepositoryProtocol)? = nil
    ) {
        self.requiredMembership = requiredMembership
        self.databaseManager = databaseManager
        self.defaults = defaults
        self.bookSearchRepository = bookSearchRepository ?? BookSearchRepository()
    }

    /// 在 security scope 有效期内把外部 Kindle 文件复制到仓储拥有的临时票据；取消会停止复制，所有退出路径都会清理临时文件。
    func loadKindleClippingsFile(from url: URL) async throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard didAccess || url.isFileURL else { throw KindleImportFileError.accessDenied }

        let worker = Task.detached(priority: .userInitiated) {
            try Self.copyKindleFileToOwnedTemporaryData(from: url)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// 在 MainActor 上编排汉王分享页请求；URLSession 在挂起期间不阻塞主线程，父任务取消会取消请求。
    func fetchHanWangShareContent(from sharedURL: String) async throws -> String {
        let url = try Self.hanWangContentURL(from: sharedURL)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw NoteImportParserError.unexpected("未从二维码中找到书摘")
        }
        let document = try SwiftSoup.parse(html)
        guard let paragraph = try document.getElementsByTag("p").first() else {
            throw NoteImportParserError.unexpected("未从二维码中找到书摘")
        }
        let content = try paragraph.html().replacingOccurrences(of: "<br>", with: "\n")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteImportParserError.unexpected("未从二维码中找到书摘")
        }
        return content
    }

    /// 在 MainActor 编排恢复；实际凭证访问由独立 actor 串行执行，取消后由页面丢弃过期快照。
    func loadLifeWeekLoginState() async -> LifeWeekLoginState {
        await lifeWeekCredentialStore.load()
    }

    /// 在 MainActor 编排偏好写入；凭证 actor 原子完成删除及偏好提交，失败不伪报关闭成功。
    func setLifeWeekRemembersPassword(_ enabled: Bool) async throws {
        try await lifeWeekCredentialStore.setRemembersPassword(enabled)
    }

    /// MainActor 编排认证、凭证保存与抓取；认证失败不触碰存储，取消检查阻止旧任务推进，存储失败不阻断导入。
    func fetchLifeWeekBooks(
        phoneNumber: String,
        password: String,
        onAuthenticated: @MainActor @Sendable (String?) -> Void
    ) async throws -> [NoteImportDraftBook] {
        let service = LifeWeekImportService()
        let ticket = try await service.login(phoneNumber: phoneNumber, password: password)
        try Task.checkCancellation()
        let storageMessage = await lifeWeekCredentialStore.saveAuthenticated(phoneNumber: phoneNumber, password: password)
        try Task.checkCancellation()
        onAuthenticated(storageMessage)
        return try await service.fetchBooks(ticket: ticket)
    }

    func matchLocalBook(for draft: NoteImportDraftBook) async throws -> BookPickerBook? {
        try await databaseManager.database.dbPool.read { db in
            let exactRawName = draft.source == 2
                ? Self.kindleCanonicalRawName(draft)
                : draft.name
            var record = try BookRecord
                .filter(Column("raw_name") == exactRawName)
                .filter(Column("is_deleted") == 0 && Column("id") != 0)
                .order(Column("id"))
                .fetchOne(db)
            if record == nil, draft.source == 2 {
                let candidates = Self.kindleLegacyRawNameCandidates(draft)
                if !candidates.isEmpty {
                    let records = try BookRecord
                        .filter(candidates.contains(Column("raw_name")))
                        .filter(Column("source_id") == 2 && Column("is_deleted") == 0 && Column("id") != 0)
                        .order(Column("id"))
                        .fetchAll(db)
                    record = Self.uniqueKindleLegacyTarget(records, importedAuthor: draft.author)
                }
            }
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

    /// 显式目标校验只按主键判断存在性，刻意不排除软删除和占位书，以复刻 Android `queryByIdSuspend`。
    func hasImportTargetBook(id: Int64) async throws -> Bool {
        try await databaseManager.database.dbPool.read { db in
            // SQL 目的：确认 Web 导入请求显式指定的目标书主键存在。
            // 涉及表：book。
            // 关键过滤：只按 id 精确命中；Android queryByIdSuspend 不过滤 is_deleted 或 id = 0。
            // 时间字段：不涉及时间字段。
            // 返回字段用途：在开始写入前阻止不存在的 targetBookId 被误当成新书导入。
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book WHERE id = ?",
                arguments: [id]
            ) ?? 0) > 0
        }
    }

    /// 逐书容错执行文渠补全；调用运行在 MainActor，远端请求异步挂起，取消由上层提交任务继承。
    func enrichImportBookInfoIfNeeded(
        _ books: [NoteImportCommitBook]
    ) async -> [NoteImportCommitBook] {
        var enriched = books
        for index in enriched.indices {
            let item = enriched[index]
            guard item.targetBookID == nil, item.draft.source != 22 else { continue }
            do {
                let candidates = try await bookSearchRepository.search(
                    keyword: Self.cleanedBookName(item.draft.name),
                    source: .wenqu
                )
                guard let match = candidates.enumerated().max(by: { lhs, rhs in
                    Self.matchScore(lhs.element, draft: item.draft)
                        < Self.matchScore(rhs.element, draft: item.draft)
                })?.element else {
                    continue
                }
                enriched[index].draft = Self.merging(match, into: item.draft)
            } catch {
                // Android MatchBookInfoHelper 对单书网络或解析失败只记录日志并继续导入。
                continue
            }
        }
        return enriched
    }

    func commitImport(
        books: [NoteImportCommitBook],
        progress: @escaping (Int, Int) -> Void
    ) async throws {
        guard !books.isEmpty else { throw NoteImportParserError.noteNotFound }
        let placement = defaults.object(forKey: "newAddBookPosition") as? Int ?? 0
        for (index, item) in books.enumerated() {
            // 每本书的事务开始前重新校验，已提交的前序书不会因撤销而回滚。
            try await requiredMembership?.requirePremium()
            try Task.checkCancellation()
            try await databaseManager.database.dbPool.write { db in
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
                let bookID = try self.upsertBook(item, ownerID: ownerID, placement: placement, now: now, db: db)
                var chapterIndex = ChapterIndex()
                var chapterSession = try ChapterImportSession(bookID: bookID, db: db)
                try self.upsertChapters(
                    item.draft.chapters,
                    bookID: bookID,
                    parentID: 0,
                    parentPath: [],
                    now: now,
                    db: db,
                    session: &chapterSession,
                    index: &chapterIndex
                )
                try self.upsertFallbackNoteChapters(
                    item.draft.notes,
                    bookID: bookID,
                    now: now,
                    db: db,
                    session: &chapterSession,
                    index: &chapterIndex
                )
                try self.upsertNotes(
                    item.draft.notes,
                    bookID: bookID,
                    bookPositionUnit: item.draft.currentPositionUnit,
                    chapterIndex: chapterIndex,
                    ownerID: ownerID,
                    now: now,
                    db: db
                )
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
    nonisolated static let kindleMaximumFileSize: Int64 = 32 * 1_024 * 1_024
    nonisolated static let kindleStorageReserve: Int64 = 4 * 1_024 * 1_024
    nonisolated static let kindleCopyBufferSize = 64 * 1_024

    /// 从汉王二维码包装链接提取真实分享页 URL；兼容 fragment 与 query 两种 `path` 参数格式。
    nonisolated static func hanWangContentURL(from raw: String) throws -> URL {
        let candidate: String
        if let hash = raw.firstIndex(of: "#") {
            let fragment = raw[raw.index(after: hash)...]
            if let range = fragment.range(of: "path=") {
                let suffix = fragment[range.upperBound...]
                candidate = String(suffix.prefix { $0 != "&" })
            } else {
                candidate = raw
            }
        } else if let components = URLComponents(string: raw),
                  let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
                  !path.isEmpty {
            candidate = path
        } else {
            candidate = raw
        }
        guard let url = URL(string: candidate.removingPercentEncoding ?? candidate) else {
            throw NoteImportParserError.unexpected("二维码链接无效")
        }
        return url
    }

    /// 在非主 Actor 上流式复制外部文件并检查取消；临时文件名具备单次所有权，defer 只清理本次创建的精确路径。
    nonisolated static func copyKindleFileToOwnedTemporaryData(from sourceURL: URL) throws -> Data {
        try Task.checkCancellation()
        let knownSize = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let knownSize, Int64(knownSize) > kindleMaximumFileSize {
            throw KindleImportFileError.fileTooLarge
        }
        try ensureKindleTemporaryStorage(payloadBytes: Int64(knownSize ?? 1))

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmnote-kindle-import-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw KindleImportFileError.insufficientStorage
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let input = InputStream(url: sourceURL) else {
            throw KindleImportFileError.accessDenied
        }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            throw KindleImportFileError.insufficientStorage
        }
        input.open()
        defer {
            input.close()
            try? output.close()
        }

        var buffer = [UInt8](repeating: 0, count: kindleCopyBufferSize)
        var copiedBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let remaining = kindleMaximumFileSize - copiedBytes + 1
            let requested = min(buffer.count, Int(remaining))
            let readCount = input.read(&buffer, maxLength: requested)
            try Task.checkCancellation()
            if readCount < 0 { throw KindleImportFileError.readFailed }
            if readCount == 0 { break }
            if Int64(readCount) > remaining || copiedBytes + Int64(readCount) > kindleMaximumFileSize {
                throw KindleImportFileError.fileTooLarge
            }
            try ensureKindleTemporaryStorage(payloadBytes: Int64(readCount))
            do {
                try output.write(contentsOf: Data(buffer[0..<readCount]))
            } catch {
                throw KindleImportFileError.insufficientStorage
            }
            copiedBytes += Int64(readCount)
        }
        do {
            try output.synchronize()
            return try Data(contentsOf: temporaryURL)
        } catch let error as KindleImportFileError {
            throw error
        } catch {
            throw KindleImportFileError.readFailed
        }
    }

    nonisolated static func ensureKindleTemporaryStorage(payloadBytes: Int64) throws {
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: FileManager.default.temporaryDirectory.path
        )
        guard let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value else { return }
        if free - kindleStorageReserve < payloadBytes {
            throw KindleImportFileError.insufficientStorage
        }
    }

    nonisolated struct ChapterIndex: Sendable {
        var uid: [String: Int64] = [:]
        var anchor: [String: Int64] = [:]
        var path: [String: Int64] = [:]
        var title: [String: [Int64]] = [:]
        var suppressedUIDs: Set<String> = []
        var suppressedAnchors: Set<String> = []
        var suppressedPaths: Set<String> = []
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
            // Android `addBookForImport` 对显式目标只记录本次导入的原书名，不把导入元数据
            // 回填目标书，也不刷新 book.updated_date。
            record.rawName = draft.source == 2 ? Self.kindleCanonicalRawName(draft) : draft.name
            if let wordCount = draft.wordCount { record.wordCount = wordCount }
            if record.wereadBookId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !draft.wereadBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.wereadBookId = draft.wereadBookID
            }
            if draft.source == 2,
               draft.bookmarkModifiedTime > 0,
               draft.readPosition > 0,
               draft.bookmarkModifiedTime > record.bookMarkModifiedTime {
                record.readPosition = draft.readPosition
                record.currentPositionUnit = draft.currentPositionUnit
                record.positionUnit = draft.currentPositionUnit
                record.bookMarkModifiedTime = draft.bookmarkModifiedTime
                record.updatedDate = now
            }
            try record.update(db)
            return targetID
        }

        let edge: Int64 = placement == 1
            ? (try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(book_order), -1) FROM book WHERE user_id = ? AND is_deleted = 0", arguments: [ownerID]) ?? -1) + 1
            : (try Int64.fetchOne(db, sql: "SELECT COALESCE(MIN(book_order), 1) FROM book WHERE user_id = ? AND is_deleted = 0", arguments: [ownerID]) ?? 1) - 1
        let createdDate = derivedCreatedDate(draft, fallback: now)
        var record = BookRecord()
        record.userId = ownerID
        record.doubanId = draft.doubanID
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
        record.bookMarkModifiedTime = draft.bookmarkModifiedTime
        record.totalPosition = draft.totalPosition
        record.totalPagination = draft.totalPagination
        record.wordCount = draft.wordCount
        record.wereadBookId = draft.wereadBookID
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

    nonisolated static func kindleCanonicalRawName(_ draft: NoteImportDraftBook) -> String {
        (draft.rawName.isEmpty ? draft.name : draft.rawName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func kindleLegacyRawNameCandidates(_ draft: NoteImportDraftBook) -> [String] {
        guard draft.source == 2 else { return [] }
        let canonical = kindleCanonicalRawName(draft)
        guard !canonical.isEmpty else { return [] }
        let noSpace = canonical.replacingOccurrences(of: " ", with: "")
        let boundaries = [canonical.firstIndex(of: "("), canonical.firstIndex(of: "（")].compactMap { $0 }
        let truncated = boundaries.min().map {
            canonical[..<$0].replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        var values: [String] = []
        if noSpace != canonical { values.append(noSpace) }
        if !truncated.isEmpty, truncated != canonical { values.append(truncated) }
        values.append("\u{FEFF}\(noSpace)")
        if !truncated.isEmpty { values.append("\u{FEFF}\(truncated)") }
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated static func uniqueKindleLegacyTarget(
        _ candidates: [BookRecord],
        importedAuthor: String
    ) -> BookRecord? {
        var seen = Set<Int64>()
        let distinct = candidates.filter { record in
            guard let id = record.id else { return false }
            return seen.insert(id).inserted
        }
        if distinct.count == 1 { return distinct[0] }
        let author = normalizeKindleAuthor(importedAuthor)
        guard !author.isEmpty else { return nil }
        let matches = distinct.filter { normalizeKindleAuthor($0.author) == author }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated static func normalizeKindleAuthor(_ author: String) -> String {
        author.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    nonisolated static func cleanedBookName(_ name: String) -> String {
        let fullWidth = name.firstIndex(of: "（")
        let ascii = name.firstIndex(of: "(")
        let boundary = [fullWidth, ascii].compactMap { $0 }.min()
        return boundary.map { String(name[..<$0]) } ?? name
    }

    nonisolated static func matchScore(
        _ candidate: BookSearchResult,
        draft: NoteImportDraftBook
    ) -> Int {
        DesktopWebChapterOnlineRepository.ratio(draft.name, candidate.title)
            + DesktopWebChapterOnlineRepository.ratio(draft.author, candidate.author)
    }

    nonisolated static func merging(
        _ candidate: BookSearchResult,
        into draft: NoteImportDraftBook
    ) -> NoteImportDraftBook {
        var result = draft
        result.doubanID = Int64(candidate.doubanId ?? 0)
        if result.press.isEmpty {
            result.press = candidate.press.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.cover.isEmpty {
            result.cover = candidate.coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.author.isEmpty { result.author = candidate.author }
        if result.translator.isEmpty { result.translator = candidate.translator }
        if result.isbn.isEmpty {
            result.isbn = candidate.isbn.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.pubDate.isEmpty {
            result.pubDate = candidate.pubDate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.authorIntro.isEmpty {
            result.authorIntro = candidate.seed?.authorIntro
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if result.summary.isEmpty { result.summary = candidate.summary }
        return result
    }

    nonisolated struct ChapterSaveResult {
        let id: Int64
        let sourceType: Int64
        let sourceUID: String
        let sourceAnchor: String
    }

    nonisolated struct ChapterSourceKey: Hashable {
        let sourceType: Int64
        let value: String
    }

    nonisolated struct ChapterTitleKey: Hashable {
        let parentID: Int64
        let title: String
    }

    /// 单本书的一次章节导入会话；从含删除记录的完整快照匹配，确保重复导入不覆盖用户编辑或复活已删章节。
    nonisolated struct ChapterImportSession {
        private enum MatchKind {
            case sourceUID
            case sourceAnchor
            case legacyTitle
        }

        private struct Match {
            let id: Int64
            let kind: MatchKind
        }

        private let bookID: Int64
        private var recordsByID: [Int64: ChapterRecord]
        private var sourceUIDIndex: [ChapterSourceKey: [Int64]] = [:]
        private var sourceAnchorIndex: [ChapterSourceKey: [Int64]] = [:]
        private var titleIndex: [ChapterTitleKey: [Int64]] = [:]
        private var maximumOrderByParentID: [Int64: Int64] = [:]

        init(bookID: Int64, db: Database) throws {
            self.bookID = bookID
            let records = try ChapterRecord
                .filter(Column("book_id") == bookID)
                .fetchAll(db)
            recordsByID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
                record.id.map { ($0, record) }
            })
            rebuildIndexes()
        }

        /// 保存单个导入章节；匹配记录仅回填缺失身份，新记录才采用传入标题并计算本地顺序与层级。
        mutating func save(
            chapter: NoteImportDraftChapter,
            parentID: Int64,
            path: [String],
            now: Int64,
            db: Database
        ) throws -> ChapterSaveResult {
            let prepared = prepare(chapter: chapter, parentID: parentID, path: path)
            if let match = find(prepared), var existing = recordsByID[match.id] {
                guard existing.isDeleted == 0 else {
                    return ChapterSaveResult(
                        id: 0,
                        sourceType: prepared.sourceType,
                        sourceUID: prepared.sourceUid ?? "",
                        sourceAnchor: prepared.sourceAnchor ?? ""
                    )
                }
                let existingUID = existing.sourceUid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let incomingUID = prepared.sourceUid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let existingAnchor = existing.sourceAnchor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let incomingAnchor = prepared.sourceAnchor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let wasManual = existing.sourceType == 0
                let replacesLegacyIdentity = match.kind == .legacyTitle
                    && NoteImportRepository.isPathChapterUID(incomingUID)
                    && existing.sourceType == prepared.sourceType
                let upgradesPathIdentity = NoteImportRepository.isPathChapterUID(existingUID)
                    && !incomingUID.isEmpty
                    && !NoteImportRepository.isPathChapterUID(incomingUID)
                let needsUpdate = wasManual
                    || existingUID.isEmpty
                    || (existingAnchor.isEmpty && !incomingAnchor.isEmpty)
                    || replacesLegacyIdentity
                    || upgradesPathIdentity
                if needsUpdate {
                    if wasManual { existing.sourceType = prepared.sourceType }
                    if wasManual || existingUID.isEmpty || replacesLegacyIdentity || upgradesPathIdentity {
                        existing.sourceUid = incomingUID
                    }
                    if (wasManual || existingAnchor.isEmpty), !incomingAnchor.isEmpty {
                        existing.sourceAnchor = incomingAnchor
                    }
                    if existing.sourceOrder == 0, prepared.sourceOrder != 0 {
                        existing.sourceOrder = prepared.sourceOrder
                    }
                    if prepared.isImport == 1 { existing.isImport = 1 }
                    try existing.update(db)
                    recordsByID[match.id] = existing
                    rebuildIndexes()
                }
                return ChapterSaveResult(
                    id: match.id,
                    sourceType: prepared.sourceType,
                    sourceUID: incomingUID,
                    sourceAnchor: incomingAnchor
                )
            }

            var created = prepared
            created.chapterOrder = nextOrder(parentID: parentID)
            created.chapterLevel = Int64(activeDepth(parentID: parentID) + 1)
            created.createdDate = now
            created.updatedDate = 0
            try created.insert(db)
            guard let id = created.id else {
                throw NoteImportParserError.unexpected("创建章节失败")
            }
            recordsByID[id] = created
            rebuildIndexes()
            return ChapterSaveResult(
                id: id,
                sourceType: created.sourceType,
                sourceUID: created.sourceUid ?? "",
                sourceAnchor: created.sourceAnchor ?? ""
            )
        }

        private func prepare(
            chapter: NoteImportDraftChapter,
            parentID: Int64,
            path: [String]
        ) -> ChapterRecord {
            var sourceType = chapter.sourceType
            var sourceUID = chapter.sourceUID.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceAnchor = chapter.sourceAnchor.trimmingCharacters(in: .whitespacesAndNewlines)
            if sourceType == 0 { sourceType = 2 }
            if sourceUID.isEmpty, sourceAnchor.isEmpty {
                sourceUID = NoteImportRepository.pathChapterUID(sourceType: sourceType, path: path)
            }
            var record = ChapterRecord()
            record.bookId = bookID
            record.parentId = parentID
            record.title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            record.remark = chapter.remark
            record.isImport = 1
            record.sourceType = sourceType
            record.sourceUid = sourceUID
            record.sourceAnchor = sourceAnchor
            record.sourceOrder = chapter.sourceOrder
            record.sourcePath = path.joined(separator: " / ")
            return record
        }

        private func find(_ incoming: ChapterRecord) -> Match? {
            let sourceUID = incoming.sourceUid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sourceAnchor = incoming.sourceAnchor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if incoming.sourceType != 0, !sourceUID.isEmpty,
               let id = choose(sourceUIDIndex[ChapterSourceKey(sourceType: incoming.sourceType, value: sourceUID)]) {
                return Match(id: id, kind: .sourceUID)
            }
            if incoming.sourceType != 0, !sourceAnchor.isEmpty,
               let id = choose(sourceAnchorIndex[ChapterSourceKey(sourceType: incoming.sourceType, value: sourceAnchor)]) {
                return Match(id: id, kind: .sourceAnchor)
            }

            let incomingHasIdentity = incoming.sourceType != 0 && (!sourceUID.isEmpty || !sourceAnchor.isEmpty)
            let candidates = titleIndex[
                ChapterTitleKey(
                    parentID: incoming.parentId,
                    title: incoming.title.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            , default: []].filter { id in
                guard let existing = recordsByID[id] else { return false }
                return !hasIdentity(existing)
                    || !incomingHasIdentity
                    || NoteImportRepository.isPathChapterUID(sourceUID)
            }
            return choose(candidates).map { Match(id: $0, kind: .legacyTitle) }
        }

        private func choose(_ candidates: [Int64]?) -> Int64? {
            let values = candidates ?? []
            return values.filter { recordsByID[$0]?.isDeleted == 0 }.min() ?? values.min()
        }

        private func hasIdentity(_ record: ChapterRecord) -> Bool {
            record.sourceType != 0 && (
                !(record.sourceUid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !(record.sourceAnchor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            )
        }

        private mutating func nextOrder(parentID: Int64) -> Int64 {
            let value = (maximumOrderByParentID[parentID] ?? 0) + 1
            maximumOrderByParentID[parentID] = value
            return value
        }

        private func activeDepth(parentID: Int64) -> Int {
            var depth = 0
            var currentID = parentID
            var visited = Set<Int64>()
            while currentID != 0, visited.insert(currentID).inserted,
                  let record = recordsByID[currentID], record.isDeleted == 0 {
                depth += 1
                currentID = record.parentId
            }
            return depth
        }

        private mutating func rebuildIndexes() {
            sourceUIDIndex.removeAll(keepingCapacity: true)
            sourceAnchorIndex.removeAll(keepingCapacity: true)
            titleIndex.removeAll(keepingCapacity: true)
            maximumOrderByParentID.removeAll(keepingCapacity: true)
            for (id, record) in recordsByID {
                let sourceUID = record.sourceUid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let sourceAnchor = record.sourceAnchor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if record.sourceType != 0, !sourceUID.isEmpty {
                    sourceUIDIndex[
                        ChapterSourceKey(sourceType: record.sourceType, value: sourceUID),
                        default: []
                    ].append(id)
                }
                if record.sourceType != 0, !sourceAnchor.isEmpty {
                    sourceAnchorIndex[
                        ChapterSourceKey(sourceType: record.sourceType, value: sourceAnchor),
                        default: []
                    ].append(id)
                }
                titleIndex[
                    ChapterTitleKey(
                        parentID: record.parentId,
                        title: record.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    default: []
                ].append(id)
                if record.isDeleted == 0 {
                    maximumOrderByParentID[record.parentId] = max(
                        maximumOrderByParentID[record.parentId] ?? 0,
                        record.chapterOrder
                    )
                }
            }
        }
    }

    nonisolated func upsertChapters(
        _ chapters: [NoteImportDraftChapter],
        bookID: Int64,
        parentID: Int64,
        parentPath: [String],
        now: Int64,
        db: Database,
        session: inout ChapterImportSession,
        index: inout ChapterIndex
    ) throws {
        for chapter in chapters {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let path = (chapter.pathTitles.isEmpty ? parentPath + [title] : chapter.pathTitles)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let result = try session.save(
                chapter: chapter,
                parentID: parentID,
                path: path,
                now: now,
                db: db
            )
            let pathKey = Self.chapterPathKey(path)
            let anchorKey = Self.chapterAnchorKey(sourceType: result.sourceType, anchor: result.sourceAnchor)
            guard result.id != 0 else {
                if !result.sourceUID.isEmpty { index.suppressedUIDs.insert(result.sourceUID) }
                if !anchorKey.isEmpty { index.suppressedAnchors.insert(anchorKey) }
                if !pathKey.isEmpty { index.suppressedPaths.insert(pathKey) }
                continue
            }
            if !result.sourceUID.isEmpty { index.uid[result.sourceUID] = result.id }
            if !anchorKey.isEmpty { index.anchor[anchorKey] = result.id }
            if !pathKey.isEmpty { index.path[pathKey] = result.id }
            index.title[title, default: []].append(result.id)
            try upsertChapters(
                chapter.children,
                bookID: bookID,
                parentID: result.id,
                parentPath: path,
                now: now,
                db: db,
                session: &session,
                index: &index
            )
        }
    }

    nonisolated func upsertNotes(
        _ notes: [NoteImportDraftNote],
        bookID: Int64,
        bookPositionUnit: Int64,
        chapterIndex: ChapterIndex,
        ownerID: Int64,
        now: Int64,
        db: Database
    ) throws {
        try backfillImportHashes(bookID: bookID, db: db)
        var hashIndex = Dictionary(
            uniqueKeysWithValues: try NoteImportHashRecord
                .filter(Column("book_id") == bookID)
                .fetchAll(db)
                .map { ($0.contentHash, $0.noteId) }
        )

        for note in notes {
            let persistedContent = note.content.replacingOccurrences(of: "<", with: "&lt;")
            let persistedIdea = note.idea.replacingOccurrences(of: "<", with: "&lt;")
            guard let contentHash = NoteImportContentHash.calculate(
                content: persistedContent,
                idea: persistedIdea,
                attachmentDigests: note.attachments.map(\.digest)
            ) else { continue }
            if hashIndex[contentHash] != nil { continue }
            if let hashMatched = try NoteImportHashRecord
                .filter(Column("book_id") == bookID && Column("content_hash") == contentHash)
                .fetchOne(db) {
                hashIndex[contentHash] = hashMatched.noteId
                continue
            }

            let existing = (!NoteImportTextSupport.isBlank(persistedContent) || !NoteImportTextSupport.isBlank(persistedIdea))
                ? try NoteRecord
                    .filter(
                        Column("book_id") == bookID
                            && Column("content") == persistedContent
                            && Column("idea") == persistedIdea
                            && Column("is_deleted") == 0
                    )
                    .order(Column("id"))
                    .fetchOne(db)
                : nil
            if let existingID = existing?.id {
                try bindImportHash(bookID: bookID, contentHash: contentHash, noteID: existingID, db: db)
                hashIndex[contentHash] = existingID
                continue
            }

            let chapterID = resolveChapter(note.chapter, fallbackUID: note.wereadChapterUID, index: chapterIndex)
            var record = NoteRecord()
            record.bookId = bookID
            record.chapterId = chapterID
            record.content = persistedContent
            record.idea = persistedIdea
            record.position = note.position
            record.positionUnit = bookPositionUnit
            record.wereadRange = note.wereadRange
            record.includeTime = note.createdTime == 0 ? 0 : (note.isIncludeTime ? 1 : 0)
            record.createdDate = note.createdTime == 0 ? now : note.createdTime
            record.updatedDate = 0
            try record.insert(db)
            guard let noteID = record.id else { continue }
            try bindImportHash(bookID: bookID, contentHash: contentHash, noteID: noteID, db: db)
            hashIndex[contentHash] = noteID
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

    /// 为同一本书尚无身份的存量有效文本书摘按主键顺序懒回填 Hash；调用者位于逐书事务内，不产生并发观察窗口。
    nonisolated func backfillImportHashes(bookID: Int64, db: Database) throws {
        let hashedNoteIDs = Set(try NoteImportHashRecord
            .filter(Column("book_id") == bookID)
            .fetchAll(db)
            .map(\.noteId))
        let candidates = try NoteRecord
            .filter(Column("book_id") == bookID && Column("is_deleted") == 0)
            .order(Column("id"))
            .fetchAll(db)
        for note in candidates {
            guard let noteID = note.id,
                  !hashedNoteIDs.contains(noteID),
                  (!NoteImportTextSupport.isBlank(note.content) || !NoteImportTextSupport.isBlank(note.idea)),
                  let contentHash = NoteImportContentHash.calculate(content: note.content, idea: note.idea)
            else { continue }
            try NoteImportHashRecord(bookId: bookID, contentHash: contentHash, noteId: noteID).insert(db)
        }
    }

    /// 在当前逐书事务内绑定书摘与内容 Hash；复合主键冲突由 Record 的 IGNORE 策略保持首个身份。
    nonisolated func bindImportHash(
        bookID: Int64,
        contentHash: String,
        noteID: Int64,
        db: Database
    ) throws {
        try NoteImportHashRecord(bookId: bookID, contentHash: contentHash, noteId: noteID).insert(db)
        guard let bound = try NoteImportHashRecord
            .filter(Column("book_id") == bookID && Column("content_hash") == contentHash)
            .fetchOne(db), bound.noteId == noteID else {
            throw NoteImportParserError.unexpected("绑定书摘导入身份失败")
        }
    }

    nonisolated func upsertFallbackNoteChapters(
        _ notes: [NoteImportDraftNote],
        bookID: Int64,
        now: Int64,
        db: Database,
        session: inout ChapterImportSession,
        index: inout ChapterIndex
    ) throws {
        for note in notes {
            guard let chapter = note.chapter else { continue }
            let path = chapter.pathTitles.isEmpty ? [chapter.title] : chapter.pathTitles
            let titles = path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !titles.isEmpty, index.path[titles.joined(separator: "$")] == nil else { continue }
            var parentID: Int64 = 0
            var currentPath: [String] = []
            for title in titles {
                currentPath.append(title)
                let key = Self.chapterPathKey(currentPath)
                if index.suppressedPaths.contains(key) { break }
                if let existingID = index.path[key] { parentID = existingID; continue }
                let result = try session.save(
                    chapter: NoteImportDraftChapter(title: title),
                    parentID: parentID,
                    path: currentPath,
                    now: now,
                    db: db
                )
                guard result.id != 0 else {
                    index.suppressedPaths.insert(key)
                    if !result.sourceUID.isEmpty { index.suppressedUIDs.insert(result.sourceUID) }
                    break
                }
                index.path[key] = result.id
                if !result.sourceUID.isEmpty { index.uid[result.sourceUID] = result.id }
                index.title[title, default: []].append(result.id)
                parentID = result.id
            }
        }
    }

    nonisolated func resolveChapter(_ chapter: NoteImportDraftChapter?, fallbackUID: Int64, index: ChapterIndex) -> Int64 {
        if fallbackUID != 0 {
            let uid = String(fallbackUID)
            if index.suppressedUIDs.contains(uid) { return 0 }
            if let id = index.uid[uid] { return id }
        }
        guard let chapter else { return 0 }
        let sourceUID = chapter.sourceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceUID.isEmpty {
            if index.suppressedUIDs.contains(sourceUID) { return 0 }
            if let id = index.uid[sourceUID] { return id }
        }
        let anchorKey = Self.chapterAnchorKey(
            sourceType: chapter.sourceType == 0 ? 2 : chapter.sourceType,
            anchor: chapter.sourceAnchor
        )
        if !anchorKey.isEmpty {
            if index.suppressedAnchors.contains(anchorKey) { return 0 }
            if let id = index.anchor[anchorKey] { return id }
        }
        if !chapter.pathTitles.isEmpty {
            let pathKey = Self.chapterPathKey(chapter.pathTitles)
            if index.suppressedPaths.contains(pathKey) { return 0 }
            if let id = index.path[pathKey] { return id }
        }
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = Array(Set(index.title[title] ?? []))
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
        let wereadDurations = draft.wereadReadingDurations ?? []
        if !wereadDurations.isEmpty {
            // SQL 目的：判断当前书籍是否存在用户手工阅读时长；微信导入不得覆盖或混入手工计时。
            // 涉及表：read_time_record；weread_read_date = 0 表示非微信导入记录。
            // 关键过滤：仅统计当前书籍的有效记录。
            // 时间字段：weread_read_date 为毫秒时间戳，0 为来源标识而非日期。
            // 返回字段用途：存在任意手工记录时跳过整批微信阅读时长。
            let manualCount: Int = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM read_time_record WHERE book_id = ? AND is_deleted = 0 AND weread_read_date = 0",
                arguments: [bookID]
            ) ?? 0
            if manualCount == 0 {
                for duration in wereadDurations {
                    guard let date = duration.date,
                          let seconds = duration.durationSeconds,
                          date > 0,
                          seconds > 0 else { continue }
                    if let id: Int64 = try Int64.fetchOne(
                        db,
                        sql: "SELECT id FROM read_time_record WHERE book_id = ? AND weread_read_date = ? AND is_deleted = 0 ORDER BY id LIMIT 1",
                        arguments: [bookID, date]
                    ) {
                        try db.execute(
                            sql: "UPDATE read_time_record SET elapsed_seconds = ?, updated_date = ? WHERE id = ?",
                            arguments: [seconds, now, id]
                        )
                    } else {
                        var record = ReadTimeRecordRecord()
                        record.bookId = bookID
                        record.elapsedSeconds = seconds
                        record.status = 3
                        record.fuzzyReadDate = date
                        record.wereadReadDate = date
                        record.createdDate = now
                        record.updatedDate = now
                        try record.insert(db)
                    }
                }
            }
        }
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

    nonisolated static func chapterPathKey(_ path: [String]) -> String {
        path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "$")
    }

    nonisolated static func pathChapterUID(sourceType: Int64, path: [String]) -> String {
        let key = chapterPathKey(path)
        guard !key.isEmpty else { return "" }
        if sourceType == 1 { return "weread_path:\(key)" }
        if sourceType == 2 { return "api_import_catalog:\(key)" }
        return ""
    }

    nonisolated static func isPathChapterUID(_ sourceUID: String) -> Bool {
        sourceUID.hasPrefix("weread_path:") || sourceUID.hasPrefix("api_import_catalog:")
    }

    nonisolated static func chapterAnchorKey(sourceType: Int64, anchor: String) -> String {
        let normalized = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "" : "\(sourceType)\0\(normalized)"
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
