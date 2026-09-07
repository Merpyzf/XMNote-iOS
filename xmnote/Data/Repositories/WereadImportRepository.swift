/**
 * [INPUT]: 依赖 DatabaseManager、WereadImportAPIClient、WereadWebAuthorizationService、UserDefaults 与微信读书领域模型
 * [OUTPUT]: 对外提供 WereadImportRepository，按微信读书普通书籍类型筛选候选，完成授权恢复、远端抓取、本地匹配、历史回填并把写入统一交给 NoteImportRepository
 * [POS]: Data/Repositories 的微信读书扫码导入实现，是 ViewModel 唯一的数据与业务入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import GRDB

@MainActor
final class WereadImportRepository: WereadImportRepositoryProtocol {
    /// 微信读书书架与笔记本的书籍类型；与划线、评论及本地书籍类型分别解释。
    private enum RemoteBookType: Int {
        case book = 0
        case publicAccount = 3
    }

    private enum DetailLoadResult: Sendable {
        case success(Int, WereadImportBook)
        case failure(Int)
    }

    fileprivate struct BackfillLocalBook {
        let record: BookRecord
        let chapterSourceUIDs: Set<String>
        let hasMissingChapterSourceUID: Bool
    }

    fileprivate struct BackfillRemoteBook {
        var book: WereadImportBook
        var chapterUIDs: Set<String> = []
    }

    fileprivate struct BackfillRemoteLoadResult {
        let books: [BackfillRemoteBook]
        let failedTitleKeys: Set<String>
        let partialFailureCount: Int
    }

    fileprivate struct BackfillLocalNote {
        let id: Int64
        let chapterID: Int64
        let range: String
        let content: String
        let idea: String
    }

    fileprivate struct BackfillChapterUpdate {
        let chapterID: Int64
        let sourceUID: String
        let sourceOrder: Int64
    }

    fileprivate struct BackfillNoteKey: Hashable {
        let rangeStart: Int64
        let rangeEnd: Int64
        let content: String
        let idea: String
    }

    fileprivate struct BackfillChapterStats {
        var updatedCount = 0
        var skippedCount = 0
        var partialFailureCount = 0
        var shouldRetry = false
    }

    private enum Keys {
        static let cookie = "wereadCookie"
        static let userID = "wereadUserId"
        static let renewedAt = "wereadCookieRenewedAt"
        static let recentCount = "wereadImportRecentCount"
        static let readingTime = "wereadImportReadingTime"
        static let onlyNotes = "wereadImportOnlyNotes"
        static let usageTips = "wereadImportUsageTips"
        static let handledBackfill = "wereadImportHandledBackfillV2"
        static let newBookPosition = "newAddBookPosition"
    }

    private let membership: any MembershipRepositoryProtocol
    private let databaseManager: DatabaseManager
    private let defaults: UserDefaults
    private let api: any WereadImportAPIClientProtocol
    private let webAuthorization: WereadWebAuthorizationService
    private let bookSearchRepository: any BookSearchRepositoryProtocol
    private let s3UploadRepository: (any S3UploadRepositoryProtocol)?
    private let noteImportRepository: any NoteImportRepositoryProtocol
    private let nowMillis: @Sendable () -> Int64

    init(
        databaseManager: DatabaseManager,
        defaults: UserDefaults = .standard,
        api: (any WereadImportAPIClientProtocol)? = nil,
        webAuthorization: WereadWebAuthorizationService? = nil,
        bookSearchRepository: (any BookSearchRepositoryProtocol)? = nil,
        s3UploadRepository: (any S3UploadRepositoryProtocol)? = nil,
        noteImportRepository: (any NoteImportRepositoryProtocol)? = nil,
        membership: any MembershipRepositoryProtocol = MembershipRepository.shared,
        nowMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        let resolvedBookSearchRepository = bookSearchRepository ?? BookSearchRepository()
        self.membership = membership
        self.databaseManager = databaseManager
        self.defaults = defaults
        self.api = api ?? WereadImportAPIClient()
        self.webAuthorization = webAuthorization ?? .shared
        self.bookSearchRepository = resolvedBookSearchRepository
        self.s3UploadRepository = s3UploadRepository
        self.noteImportRepository = noteImportRepository ?? NoteImportRepository(
            databaseManager: databaseManager,
            defaults: defaults,
            bookSearchRepository: resolvedBookSearchRepository,
            requiredMembership: membership
        )
        self.nowMillis = nowMillis
    }

    func fetchPreferences() -> WereadImportPreferences {
        WereadImportPreferences(
            recentBookCount: defaults.object(forKey: Keys.recentCount) as? Int ?? -1,
            importsReadingTime: defaults.bool(forKey: Keys.readingTime),
            onlyBooksWithNotes: defaults.bool(forKey: Keys.onlyNotes),
            showsUsageTips: defaults.object(forKey: Keys.usageTips) as? Bool ?? true
        )
    }

    func savePreferences(_ preferences: WereadImportPreferences) {
        defaults.set(preferences.recentBookCount, forKey: Keys.recentCount)
        defaults.set(preferences.importsReadingTime, forKey: Keys.readingTime)
        defaults.set(preferences.onlyBooksWithNotes, forKey: Keys.onlyNotes)
        defaults.set(preferences.showsUsageTips, forKey: Keys.usageTips)
    }

    func restoreAuthorization() async -> WereadAuthorization? {
        guard let cookie = defaults.string(forKey: Keys.cookie), let authorization = parseAuthorization(cookie) else { return nil }
        do {
            let renewed = try await renewedAuthorization(authorization, force: false)
            try await verify(renewed)
            await webAuthorization.replaceCookies(with: renewed.cookieHeader)
            return renewed
        } catch WereadImportError.authorizationExpired {
            await clearAuthorization(ifMatches: authorization.cookieHeader)
            return nil
        } catch {
            return nil
        }
    }

    func validateAuthorization(cookieHeader: String) async throws -> WereadAuthorization {
        guard let authorization = parseAuthorization(cookieHeader) else { throw WereadImportError.authorizationExpired }
        let renewed = try await renewedAuthorization(authorization, force: true)
        do {
            try await verify(renewed)
        } catch WereadImportError.authorizationExpired {
            await clearAuthorization(ifMatches: renewed.cookieHeader)
            throw WereadImportError.authorizationExpired
        }
        persist(renewed)
        await webAuthorization.replaceCookies(with: renewed.cookieHeader)
        return renewed
    }

    func clearAuthorization() async {
        [Keys.cookie, Keys.userID, Keys.renewedAt].forEach(defaults.removeObject(forKey:))
        await webAuthorization.clearCookies()
    }

    func fetchImportBookIDs(authorization: WereadAuthorization, preferences: WereadImportPreferences) async throws -> [String] {
        try await membership.requirePremium()
        let authorization = try await currentAuthorization(fallback: authorization, force: true)
        let ids = preferences.onlyBooksWithNotes
            ? try await notebookBookIDs(cookie: authorization.cookieHeader)
            : try await shelfBookIDs(cookie: authorization.cookieHeader)
        if preferences.recentBookCount > 0 { return Array(ids.prefix(preferences.recentBookCount)) }
        return ids
    }

    func fetchImportBooks(
        authorization: WereadAuthorization,
        preferences: WereadImportPreferences,
        progress: @escaping (Int, Int) -> Void,
        warning: @escaping (String) -> Void
    ) async throws -> [WereadImportBook] {
        let ids = try await fetchImportBookIDs(authorization: authorization, preferences: preferences)
        return try await fetchImportBooks(
            authorization: authorization,
            bookIDs: ids,
            importsReadingTime: preferences.importsReadingTime,
            progress: progress,
            warning: warning
        )
    }

    func fetchImportBooks(
        authorization: WereadAuthorization,
        bookIDs: [String],
        importsReadingTime: Bool,
        progress: @escaping (Int, Int) -> Void,
        warning: @escaping (String) -> Void
    ) async throws -> [WereadImportBook] {
        try await membership.requirePremium()
        let ids = bookIDs
        guard !ids.isEmpty else { throw WereadImportError.emptyImport }
        var effectiveAuthorization = try await currentAuthorization(fallback: authorization, force: false)
        let books = try await syncBooks(ids: ids, cookie: effectiveAuthorization.cookieHeader)
        let total = books.count
        var completed = Array<WereadImportBook?>(repeating: nil, count: total)
        var current = 0
        for chunkStart in stride(from: 0, to: total, by: 10) {
            try await membership.requirePremium()
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + 10, total)
            effectiveAuthorization = try await currentAuthorization(fallback: effectiveAuthorization, force: false)
            let groupCookie = effectiveAuthorization.cookieHeader
            try await withThrowingTaskGroup(of: DetailLoadResult.self) { group in
                for index in chunkStart..<chunkEnd {
                    let book = books[index]
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        do {
                            return .success(
                                index,
                                try await self.fillDetails(
                                    book,
                                    cookie: groupCookie,
                                    importsReadingTime: importsReadingTime
                                )
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return .failure(index)
                        }
                    }
                }
                for try await result in group {
                    let index: Int
                    switch result {
                    case .success(let valueIndex, let book):
                        index = valueIndex
                        completed[index] = book
                    case .failure(let valueIndex):
                        index = valueIndex
                        warning("《\(books[index].title)》加载失败，已跳过")
                    }
                    current += 1
                    progress(current, total)
                }
            }
        }
        try Task.checkCancellation()
        let result = completed.compactMap { $0 }
        guard !result.isEmpty else { throw WereadImportError.emptyImport }
        return result
    }

    func fetchImportBooks(
        authorization: WereadAuthorization,
        bookIDs: [String],
        importsReadingTime: Bool,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [WereadImportBook] {
        try await membership.requirePremium()
        guard !bookIDs.isEmpty else { return [] }
        var effectiveAuthorization = try await currentAuthorization(fallback: authorization, force: false)
        let books = try await syncBooks(ids: bookIDs, cookie: effectiveAuthorization.cookieHeader)
        var completed = Array<WereadImportBook?>(repeating: nil, count: books.count)
        var current = 0
        for chunkStart in stride(from: 0, to: books.count, by: 2) {
            try await membership.requirePremium()
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + 2, books.count)
            effectiveAuthorization = try await currentAuthorization(fallback: effectiveAuthorization, force: false)
            let groupCookie = effectiveAuthorization.cookieHeader
            try await withThrowingTaskGroup(of: (Int, WereadImportBook).self) { group in
                for index in chunkStart..<chunkEnd {
                    let book = books[index]
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        return (index, try await self.fillDetails(book, cookie: groupCookie, importsReadingTime: importsReadingTime))
                    }
                }
                for try await (index, book) in group {
                    completed[index] = book
                    current += 1
                    progress(current, books.count)
                }
            }
        }
        return completed.compactMap { $0 }
    }

    func matchLocalBooks(_ books: [WereadImportBook]) async throws -> [WereadImportBook] {
        let rows = try await databaseManager.database.dbPool.read { db in
            try BookRecord.filter(Column("is_deleted") == 0).fetchAll(db)
        }
        var claimed = Set<Int64>()
        return books.map { source in
            var source = source
            let byID = rows.first { !$0.wereadBookId.isEmpty && $0.wereadBookId == source.wereadBookID }
            let byName = rows.first { row in
                row.wereadBookId.isEmpty && row.rawName == source.rawTitle && row.id.map { !claimed.contains($0) } == true
            }
            if let target = byID ?? byName, let id = target.id {
                source.targetBookID = id
                source.targetBookTitle = target.name
                claimed.insert(id)
            }
            return source
        }
    }

    func commitImport(books: [WereadImportBook], progress: @escaping (Int, Int) -> Void) async throws {
        try await membership.requirePremium()
        let selected = await enrichNewBooks(books.filter(\.isSelected))
        guard !selected.isEmpty else { throw WereadImportError.emptyImport }
        let commits = selected.map { source in
            NoteImportCommitBook(
                draft: noteImportDraft(from: source),
                targetBookID: source.targetBookID
            )
        }
        try await noteImportRepository.commitImport(books: commits, progress: progress)
    }

    /// 预览使用生产提交转换器生成完整快照，包含未勾选书摘，保留专用时长与章节身份。
    func makePreviewDrafts(_ books: [WereadImportBook]) -> [NoteImportDraftBook] {
        books.map { book in
            var source = book
            for index in source.notes.indices { source.notes[index].isSelected = true }
            var draft = noteImportDraft(from: source)
            draft.sourceReadingStatus = source.readStatusID == 3 ? .finished : .unfinished
            draft.usesCompletionReadingStatus = true
            return draft
        }
    }

    /// MainActor 编排会员验证与逐书写入；父任务取消沿仓储传播，显式资料补丁在补全后生效。
    func commitPreviewImport(books: [NoteImportCommitBook], progress: @escaping (Int, Int) -> Void) async throws {
        let enriched = try await enrichPreviewPayloads(books)
        try await noteImportRepository.commitImport(books: enriched, progress: progress)
    }

    /// MainActor 完成微信资料补全后提交整个目标；取消沿仓储传播，不拆散同目标事务。
    func commitPreviewGroup(_ group: NoteImportCommitGroup) async throws -> NoteImportCommitGroupResult {
        var value = group
        value.books = try await enrichPreviewPayloads(group.books)
        try Task.checkCancellation()
        return try await noteImportRepository.commitImportGroup(value)
    }

    /// 网络补全仅处理新书；不重新转换冻结的来源内容，显式资料补丁由最终事务应用。
    private func enrichPreviewPayloads(_ books: [NoteImportCommitBook]) async throws -> [NoteImportCommitBook] {
        try await membership.requirePremium()
        var enriched = books
        for index in enriched.indices {
            try Task.checkCancellation()
            guard enriched[index].targetBookID == nil else { continue }
            let draft = enriched[index].draft
            let source = WereadImportBook(
                wereadBookID: draft.wereadBookID, title: draft.name, rawTitle: draft.rawName,
                author: draft.author, coverURL: draft.cover, summary: draft.summary,
                translator: draft.translator, isbn: draft.isbn, press: draft.press,
                publicationDate: draft.pubDate, wordCount: draft.wordCount,
                wereadUpdatedAt: draft.wereadUpdateTime, readStatusID: draft.readStatusID
            )
            let value = await enrichNewBook(source)
            // 沿用微信读书的资料补全与封面转存，只回填资料；已冻结的章节、位置和时长不再次转换。
            enriched[index].draft.cover = value.coverURL
            enriched[index].draft.summary = value.summary
            enriched[index].draft.translator = value.translator
            enriched[index].draft.isbn = value.isbn
            enriched[index].draft.press = value.press
            enriched[index].draft.pubDate = value.publicationDate
            enriched[index].draft.wordCount = value.wordCount
        }
        try Task.checkCancellation()
        return enriched
    }

    func enrichNewBooks(_ books: [WereadImportBook]) async -> [WereadImportBook] {
        var result = books
        for chunkStart in stride(from: 0, to: result.count, by: 5) {
            if Task.isCancelled { break }
            let chunkEnd = min(chunkStart + 5, result.count)
            await withTaskGroup(of: (Int, WereadImportBook).self) { group in
                for index in chunkStart..<chunkEnd {
                    let book = result[index]
                    group.addTask { [weak self] in
                        guard let self else { return (index, book) }
                        return (index, await self.enrichNewBook(book))
                    }
                }
                for await (index, book) in group { result[index] = book }
            }
        }
        return result
    }

    func enrichNewBook(_ source: WereadImportBook) async -> WereadImportBook {
        var source = source
        guard source.targetBookID == nil else { return source }
        if source.summary.isEmpty || source.isbn.isEmpty || source.press.isEmpty,
           let candidates = try? await bookSearchRepository.search(keyword: source.title, source: .wenqu),
           let candidate = candidates.first(where: { normalized($0.title) == normalized(source.title) }) ?? candidates.first {
            let seed = (try? await bookSearchRepository.prepareSeed(for: candidate)) ?? candidate.seed
            if source.coverURL.isEmpty { source.coverURL = seed?.coverURL ?? candidate.coverURL }
            if source.summary.isEmpty { source.summary = seed?.summary ?? candidate.summary }
            if source.translator.isEmpty { source.translator = seed?.translator ?? candidate.translator }
            if source.isbn.isEmpty { source.isbn = seed?.isbn ?? candidate.isbn }
            if source.press.isEmpty { source.press = seed?.press ?? candidate.press }
            if source.publicationDate.isEmpty { source.publicationDate = seed?.pubDate ?? candidate.pubDate }
            if source.wordCount == nil, let count = seed?.totalWordCount ?? candidate.totalWordCount, count > 0 { source.wordCount = Int64(count) }
        }
        source.coverURL = await transferCoverIfPossible(source.coverURL)
        return source
    }

    func transferCoverIfPossible(_ value: String) async -> String {
        guard let s3UploadRepository, let url = URL(string: value), url.scheme?.hasPrefix("http") == true,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return value }
        let fileExtension = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let temporaryURL = FileManager.default.temporaryDirectory.appending(path: "weread_\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let result = try await s3UploadRepository.uploadFile(localURL: temporaryURL, prefix: "book_cover", progress: nil)
            return result.remoteURL.absoluteString
        } catch { return value }
    }

    func fetchBackfillPrompt() async throws -> WereadBackfillPrompt {
        let candidates = try await fetchBackfillBooks()
        let handled = Set(defaults.stringArray(forKey: Keys.handledBackfill) ?? [])
        let keys = Set(candidates.map(candidateKey)).subtracting(handled)
        return WereadBackfillPrompt(pendingCount: keys.count, candidateKeys: keys)
    }

    func performBackfill(
        authorization: WereadAuthorization,
        progress: @escaping (WereadBackfillProgress) -> Void
    ) async throws -> WereadBackfillResult {
        progress(.init(stage: .preparing, current: 0, total: 0, bookName: ""))
        let prompt = try await fetchBackfillPrompt()
        guard prompt.pendingCount > 0 else {
            return .init(
                bookIDMatchedCount: 0,
                chapterUIDUpdatedCount: 0,
                skippedCount: 0,
                partialFailureCount: 0,
                handledCandidateKeys: []
            )
        }
        let authorization = try await currentAuthorization(fallback: authorization, force: true)
        progress(.init(stage: .syncingRemoteBooks, current: 0, total: prompt.pendingCount, bookName: ""))
        let remoteLoad = try await loadBackfillRemoteBooks(cookie: authorization.cookieHeader)
        progress(.init(stage: .matchingBooks, current: 0, total: prompt.pendingCount, bookName: ""))
        let local = try await fetchBackfillBooks().filter { prompt.candidateKeys.contains(candidateKey($0)) }
        let matches = matchBackfillBooks(local: local, remote: remoteLoad.books)
        var matched = 0
        var chapterUIDs = 0
        var skipped = 0
        var partialFailures = remoteLoad.partialFailureCount
        var retryCandidateKeys = Set<String>()
        var handledCandidateKeys = Set<String>()

        for localBook in local where localBook.record.wereadBookId.isEmpty {
            let key = candidateKey(localBook)
            guard matches[localBook.record.id ?? 0] == nil else { continue }
            let titleKeys = normalizedBackfillTitleKeys(localBook)
            if remoteLoad.partialFailureCount > 0 || !titleKeys.isDisjoint(with: remoteLoad.failedTitleKeys) {
                retryCandidateKeys.insert(key)
            }
        }

        let resolved = local.compactMap { localBook -> (BackfillLocalBook, String, String)? in
            guard let localID = localBook.record.id else { return nil }
            let key = candidateKey(localBook)
            let matchedID = matches[localID] ?? ""
            let remoteID = localBook.record.wereadBookId.isEmpty ? matchedID : localBook.record.wereadBookId
            if localBook.record.wereadBookId.isEmpty && matchedID.isEmpty { skipped += 1 }
            return remoteID.isEmpty ? nil : (localBook, remoteID, key)
        }

        for (index, item) in resolved.enumerated() {
            try Task.checkCancellation()
            let (localBook, remoteID, key) = item
            guard let bookID = localBook.record.id else { continue }
            progress(.init(
                stage: .processingBooks,
                current: index + 1,
                total: resolved.count,
                bookName: localBook.record.name
            ))
            do {
                if localBook.record.wereadBookId.isEmpty {
                    let changed = try await databaseManager.database.dbPool.write { db in
                        try db.execute(
                            // SQL 目的：只为尚未建立微信关联的历史书籍回填远端 ID。
                            // 涉及表：book。
                            // 关键过滤：按主键命中且 weread_book_id 去空白后仍为空，避免覆盖并发写入。
                            // 时间字段：关联修复不改变业务更新时间。
                            // 副作用：返回实际更新行数，用于区分已被其他任务抢先处理的情况。
                            sql: "UPDATE book SET weread_book_id = ? WHERE id = ? AND TRIM(COALESCE(weread_book_id, '')) = ''",
                            arguments: [remoteID, bookID]
                        )
                        return db.changesCount
                    }
                    if changed > 0 { matched += 1 }
                }

                if localBook.hasMissingChapterSourceUID {
                    let stats = try await backfillChapterSourceUIDs(
                        localBook: localBook,
                        remoteBookID: remoteID,
                        cookie: authorization.cookieHeader
                    )
                    chapterUIDs += stats.updatedCount
                    partialFailures += stats.partialFailureCount
                    if stats.shouldRetry { retryCandidateKeys.insert(key) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isAuthorizationFailure(error) { throw WereadImportError.authorizationExpired }
                partialFailures += 1
                retryCandidateKeys.insert(key)
            }
        }

        handledCandidateKeys = Set(local.map(candidateKey)).subtracting(retryCandidateKeys)
        let merged = Set(defaults.stringArray(forKey: Keys.handledBackfill) ?? []).union(handledCandidateKeys)
        defaults.set(Array(merged), forKey: Keys.handledBackfill)
        return .init(
            bookIDMatchedCount: matched,
            chapterUIDUpdatedCount: chapterUIDs,
            skippedCount: skipped,
            partialFailureCount: partialFailures,
            handledCandidateKeys: handledCandidateKeys
        )
    }
}

private extension WereadImportRepository {
    func parseAuthorization(_ header: String) -> WereadAuthorization? {
        let values = cookieDictionary(header)
        guard let userID = values["wr_vid"], Int64(userID) != nil,
              let key = values["wr_skey"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return WereadAuthorization(cookieHeader: header, userID: userID)
    }

    func cookieDictionary(_ header: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: header.split(separator: ";").compactMap { item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            return (pair[0].trimmingCharacters(in: .whitespaces), pair[1].trimmingCharacters(in: .whitespaces))
        })
    }

    func persist(_ authorization: WereadAuthorization) {
        defaults.set(authorization.cookieHeader, forKey: Keys.cookie)
        defaults.set(authorization.userID, forKey: Keys.userID)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.renewedAt)
    }

    func renewedAuthorization(_ authorization: WereadAuthorization, force: Bool) async throws -> WereadAuthorization {
        let last = defaults.double(forKey: Keys.renewedAt)
        guard force || Date().timeIntervalSince1970 - last >= 3600 else { return authorization }
        let response: WereadImportAPIClient.Response
        do {
            response = try await api.post(
                "/web/login/renewal",
                cookie: authorization.cookieHeader,
                json: ["rq": "%2Fweb%2Fbook%2Fread", "ql": false]
            )
        } catch {
            if isAuthorizationFailure(error), await confirmsAuthorizationExpired(authorization) {
                await clearAuthorization(ifMatches: authorization.cookieHeader)
                throw WereadImportError.authorizationExpired
            }
            throw error
        }
        let success = WereadImportAPIClient.int(response.object["succ"]) == 1
        guard success else {
            let code = WereadImportAPIClient.int(response.object["errCode"])
                ?? WereadImportAPIClient.int(response.object["errcode"])
                ?? 0
            let message = WereadImportAPIClient.string(response.object["errMsg"])
                ?? WereadImportAPIClient.string(response.object["errmsg"])
                ?? ""
            let error = WereadImportError.remote(code: code, message: message)
            if isAuthorizationFailure(error), await confirmsAuthorizationExpired(authorization) {
                await clearAuthorization(ifMatches: authorization.cookieHeader)
                throw WereadImportError.authorizationExpired
            }
            throw error
        }
        var values = cookieDictionary(authorization.cookieHeader)
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: response.httpResponse.allHeaderFields.reduce(into: [:]) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }, for: URL(string: "https://weread.qq.com/web/login/renewal")!)
            .filter { !$0.value.isEmpty && ($0.expiresDate == nil || $0.expiresDate! > Date()) }
        guard responseCookies.contains(where: { $0.name == "wr_skey" && !$0.value.isEmpty }) else {
            throw WereadImportError.invalidResponse
        }
        for cookie in responseCookies { values[cookie.name] = cookie.value }
        let header = values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        guard let renewed = parseAuthorization(header) else { throw WereadImportError.authorizationExpired }
        persist(renewed)
        return renewed
    }

    func verify(_ authorization: WereadAuthorization) async throws {
        do {
            _ = try await api.post("/web/shelf/syncBook", cookie: authorization.cookieHeader, json: ["bookIds": ["39980421"], "count": 1, "isArchive": NSNull(), "currentArchiveId": NSNull(), "loadMore": true])
        } catch {
            if isAuthorizationFailure(error) { throw WereadImportError.authorizationExpired }
            throw error
        }
    }

    func currentAuthorization(
        fallback: WereadAuthorization,
        force: Bool
    ) async throws -> WereadAuthorization {
        let stored = defaults.string(forKey: Keys.cookie)
            .flatMap { parseAuthorization($0) }
        let candidate = stored.flatMap { value in
            value.userID == fallback.userID ? value : nil
        } ?? fallback
        return try await renewedAuthorization(candidate, force: force)
    }

    func confirmsAuthorizationExpired(_ authorization: WereadAuthorization) async -> Bool {
        do {
            try await verify(authorization)
            return false
        } catch WereadImportError.authorizationExpired {
            return true
        } catch {
            return false
        }
    }

    func isAuthorizationFailure(_ error: Error) -> Bool {
        if case WereadImportError.authorizationExpired = error { return true }
        if case WereadImportError.remote(let code, _) = error {
            return code == 401 || code == 403 || code == -2012 || code == -2013
        }
        return false
    }

    func clearAuthorization(ifMatches checkedCookie: String) async {
        guard defaults.string(forKey: Keys.cookie) == nil
                || defaults.string(forKey: Keys.cookie) == checkedCookie else { return }
        await clearAuthorization()
    }

    func notebookBookIDs(cookie: String) async throws -> [String] {
        let object = try await api.get("/api/user/notebook", cookie: cookie).object
        return WereadImportAPIClient.array(object["books"]).compactMap { wrapper in
            let book = WereadImportAPIClient.dictionary(wrapper["book"])
            let type = WereadImportAPIClient.int(book?["type"])
            return type == RemoteBookType.book.rawValue
                ? WereadImportAPIClient.string(wrapper["bookId"] ?? book?["bookId"]) : nil
        }
    }

    func shelfBookIDs(cookie: String) async throws -> [String] {
        let html = try await api.shelfHTML(cookie: cookie)
        guard let start = html.range(of: "window.__INITIAL_STATE__=")?.upperBound else { return [] }
        let tail = html[start...]
        let jsonText = tail.components(separatedBy: ";(function()").first ?? String(tail)
        guard let data = jsonText.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shelf = root["shelf"] as? [String: Any] else { return [] }
        return WereadImportAPIClient.array(shelf["rawIndexes"]).compactMap { item in
            (WereadImportAPIClient.int(item["type"]) == RemoteBookType.book.rawValue)
                ? WereadImportAPIClient.string(item["bookId"]) : nil
        }
    }

    func syncBooks(ids: [String], cookie: String) async throws -> [WereadImportBook] {
        var result: [WereadImportBook] = []
        for chunk in ids.chunked(into: 100) {
            let object = try await api.post("/web/shelf/syncBook", cookie: cookie, json: ["bookIds": chunk, "count": chunk.count, "isArchive": NSNull(), "currentArchiveId": NSNull(), "loadMore": true]).object
            for book in WereadImportAPIClient.array(object["books"]) {
                let title = (WereadImportAPIClient.string(book["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(.init(
                    wereadBookID: WereadImportAPIClient.string(book["bookId"]) ?? "",
                    title: title, rawTitle: title,
                    author: WereadImportAPIClient.string(book["author"]) ?? "",
                    coverURL: (WereadImportAPIClient.string(book["cover"]) ?? "").replacingOccurrences(of: "s_", with: "t9_"),
                    wordCount: WereadImportAPIClient.int64(book["totalWords"]),
                    wereadUpdatedAt: (WereadImportAPIClient.int64(book["readUpdateTime"]) ?? 0) * 1000,
                    readStatusID: WereadImportAPIClient.int(book["finishReading"]) == 1 ? 3 : 1
                ))
            }
        }
        return result.sorted { $0.wereadUpdatedAt > $1.wereadUpdatedAt }
    }

    func fillDetails(_ source: WereadImportBook, cookie: String, importsReadingTime: Bool) async throws -> WereadImportBook {
        var source = source
        let marks = try await api.get("/web/book/bookmarklist?bookId=\(source.wereadBookID)", cookie: cookie).object
        source.notes = WereadImportAPIClient.array(marks["updated"]).filter { WereadImportAPIClient.int($0["type"]) == 1 }.map {
            .init(
                content: trimEnd(WereadImportAPIClient.string($0["markText"]) ?? ""),
                range: WereadImportAPIClient.string($0["range"]) ?? "",
                chapterUID: WereadImportAPIClient.int64($0["chapterUid"]) ?? 0,
                createdAt: WereadImportAPIClient.int64($0["createTime"]).map { $0 * 1_000 } ?? nowMillis()
            )
        }
        let reviewObject = try await api.get("/web/review/list?bookId=\(source.wereadBookID)&listType=11&mine=1", cookie: cookie).object
        let wrappers = WereadImportAPIClient.array(reviewObject["reviews"])
        for wrapper in wrappers {
            let review = WereadImportAPIClient.dictionary(wrapper["review"]) ?? wrapper
            let type = WereadImportAPIClient.int(review["type"]) ?? 0
            if type == 1 {
                source.notes.append(.init(
                    content: trimEnd(WereadImportAPIClient.string(review["abstract"]) ?? ""),
                    idea: trimEnd(WereadImportAPIClient.string(review["content"]) ?? ""),
                    range: WereadImportAPIClient.string(review["range"]) ?? "",
                    chapterUID: WereadImportAPIClient.int64(review["chapterUid"]) ?? 0,
                    createdAt: WereadImportAPIClient.int64(review["createTime"]).map { $0 * 1_000 } ?? nowMillis()
                ))
            } else if type == 4 {
                let content = trimEnd(WereadImportAPIClient.string(review["content"]) ?? "")
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                source.reviews.append(.init(
                    content: content,
                    createdAt: WereadImportAPIClient.int64(review["createTime"]).map { $0 * 1_000 } ?? nowMillis()
                ))
            }
        }
        do {
            let chapterObject = try await api.post("/web/book/chapterInfos", cookie: cookie, json: ["bookIds": [source.wereadBookID]]).object
            source.chapters = buildChapters(from: chapterObject)
        } catch is CancellationError {
            throw CancellationError()
        } catch WereadImportError.authorizationExpired {
            throw WereadImportError.authorizationExpired
        } catch WereadImportError.remote(let code, let message) where [401, 403, -2012, -2013].contains(code) {
            throw WereadImportError.remote(code: code, message: message)
        } catch {
            source.chapters = []
        }
        let chapterOrder = chapterUIDOrder(source.chapters)
        source.notes = source.notes.filter { chapterOrder[$0.chapterUID] != nil }.sorted {
            let left = chapterOrder[$0.chapterUID] ?? Int.max
            let right = chapterOrder[$1.chapterUID] ?? Int.max
            return left == right ? rangeStart($0.range) < rangeStart($1.range) : left < right
        }
        if importsReadingTime || source.readStatusID == 3 {
            do {
                let info = try await api.get("/web/book/readinfo?bookId=\(source.wereadBookID)&readingDetail=1&readingBookIndex=1&finishedDate=1", cookie: cookie).object
                let readDetail = WereadImportAPIClient.dictionary(info["readDetail"])
                let finished = WereadImportAPIClient.int64(info["finishedDate"]) ?? 0
                let lastReading = WereadImportAPIClient.int64(readDetail?["lastReadingDate"]) ?? 0
                let resolved = finished > 0 ? finished * 1_000 : (lastReading > 0 ? lastReading * 1_000 : source.wereadUpdatedAt)
                if source.readStatusID == 3 { source.readStatusChangedAt = resolved }
                if importsReadingTime {
                    source.summary = WereadImportAPIClient.string(
                        WereadImportAPIClient.dictionary(info["bookInfo"])?["intro"]
                    ) ?? ""
                    source.readingDays = WereadImportAPIClient.array(readDetail?["data"]).compactMap { day in
                        guard let date = WereadImportAPIClient.int64(day["readDate"]),
                              let seconds = WereadImportAPIClient.int64(day["readTime"]),
                              seconds > 0 else { return nil }
                        return .init(date: date, seconds: seconds)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if importsReadingTime { throw error }
                if source.readStatusID == 3 { source.readStatusChangedAt = source.wereadUpdatedAt }
            }
        }
        return source
    }

    func buildChapters(from root: [String: Any]) -> [WereadImportChapter] {
        let data = WereadImportAPIClient.array(root["data"])
        let updated = data.flatMap { WereadImportAPIClient.array($0["updated"]) }.sorted { (WereadImportAPIClient.int($0["chapterIdx"]) ?? 0) < (WereadImportAPIClient.int($1["chapterIdx"]) ?? 0) }
        final class Node { var value: WereadImportChapter; var children: [Node] = []; init(_ value: WereadImportChapter) { self.value = value } }
        var roots: [Node] = []; var stack: [Int: Node] = [:]
        func add(_ node: Node, requestedLevel: Int) {
            var actualLevel = requestedLevel
            if actualLevel == 1 {
                roots.append(node)
            } else if let parent = stack[actualLevel - 1] {
                parent.children.append(node)
            } else {
                actualLevel = 1
                roots.append(node)
            }
            node.value.level = Int64(actualLevel)
            stack[actualLevel] = node
            stack.keys.filter { $0 > actualLevel }.forEach { stack.removeValue(forKey: $0) }
        }
        func anchorLevel(_ anchor: [String: Any], chapterLevel: Int) -> Int {
            var level = WereadImportAPIClient.int(anchor["level"]).flatMap { $0 > 0 ? $0 : nil }
                ?? chapterLevel + 1
            if level <= chapterLevel || stack[level - 1] == nil { level = chapterLevel + 1 }
            return level
        }
        func hasFollowingChild(after index: Int, parentLevel: Int, childLevel: Int) -> Bool {
            for next in updated.dropFirst(index + 1) {
                let nextLevel = max(WereadImportAPIClient.int(next["level"]) ?? 1, 1)
                if nextLevel <= parentLevel { return false }
                if nextLevel == childLevel { return true }
            }
            return false
        }
        for (itemIndex, item) in updated.enumerated() {
            let level = max(WereadImportAPIClient.int(item["level"]) ?? 1, 1)
            guard level <= 5 else { continue }
            let uid = WereadImportAPIClient.int64(item["chapterUid"]) ?? 0
            let title = (WereadImportAPIClient.string(item["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.isEmpty ? "第\(uid)章" : title
            let order = WereadImportAPIClient.int64(item["chapterIdx"]) ?? 0
            let anchors = WereadImportAPIClient.array(item["anchors"])
            let firstValidAnchor = anchors.enumerated().first { _, anchor in
                let anchorTitle = (WereadImportAPIClient.string(anchor["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceAnchor = (WereadImportAPIClient.string(anchor["anchor"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return !anchorTitle.isEmpty
                    && !sourceAnchor.isEmpty
                    && normalized(anchorTitle) != normalized(resolvedTitle)
            }
            let promoted = firstValidAnchor.flatMap { index, anchor -> (Int, [String: Any])? in
                let resolvedLevel = anchorLevel(anchor, chapterLevel: level)
                guard resolvedLevel <= 5,
                      resolvedLevel == level + 1,
                      hasFollowingChild(after: itemIndex, parentLevel: level, childLevel: resolvedLevel) else {
                    return nil
                }
                return (index, anchor)
            }
            let node = Node(.init(
                uid: promoted == nil ? uid : 0,
                title: resolvedTitle,
                order: order,
                level: Int64(level)
            ))
            add(node, requestedLevel: level)
            for (index, anchor) in anchors.enumerated() {
                let anchorTitle = (WereadImportAPIClient.string(anchor["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceAnchor = (WereadImportAPIClient.string(anchor["anchor"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !anchorTitle.isEmpty,
                      !sourceAnchor.isEmpty,
                      normalized(anchorTitle) != normalized(resolvedTitle) else { continue }
                let resolvedLevel = anchorLevel(anchor, chapterLevel: level)
                guard resolvedLevel <= 5, index == promoted?.0 else { continue }
                add(
                    Node(.init(
                        uid: uid,
                        title: anchorTitle,
                        order: order,
                        level: Int64(resolvedLevel),
                        sourceAnchor: sourceAnchor
                    )),
                    requestedLevel: resolvedLevel
                )
            }
        }
        func value(_ node: Node, path: [String]) -> WereadImportChapter {
            var item = node.value; let next = path + [item.title]; item.sourcePath = next.joined(separator: " / "); item.children = node.children.map { value($0, path: next) }; return item
        }
        return roots.map { value($0, path: []) }
    }

    func rangeStart(_ range: String) -> Int {
        let parts = range.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 ? (Int(parts[0]) ?? 0) : 0
    }
    func trimEnd(_ value: String) -> String {
        var result = value
        while let last = result.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            result.removeLast()
        }
        return result
    }
    func chapterUIDOrder(_ chapters: [WereadImportChapter]) -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        var index = 0
        func visit(_ items: [WereadImportChapter]) {
            for item in items { if item.uid > 0, result[item.uid] == nil { result[item.uid] = index }; index += 1; visit(item.children) }
        }
        visit(chapters)
        return result
    }
    nonisolated func normalized(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
    func candidateKey(_ localBook: BackfillLocalBook) -> String {
        let record = localBook.record
        let sourceUIDs = localBook.chapterSourceUIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
        let input = [
            "v2",
            String(record.id ?? 0),
            record.wereadBookId.trimmingCharacters(in: .whitespacesAndNewlines),
            record.name.trimmingCharacters(in: .whitespacesAndNewlines),
            record.rawName.trimmingCharacters(in: .whitespacesAndNewlines),
            record.author.trimmingCharacters(in: .whitespacesAndNewlines),
            record.wordCount.map(String.init) ?? "",
            sourceUIDs,
            localBook.hasMissingChapterSourceUID ? "true" : "false"
        ].joined(separator: "\u{001F}")
        return Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func flattenChapters(_ chapters: [WereadImportChapter]) -> [WereadImportChapter] {
        chapters.flatMap { [$0] + flattenChapters($0.children) }
    }

    func fetchBackfillBooks() async throws -> [BackfillLocalBook] {
        try await databaseManager.database.dbPool.read { db in
            // SQL 目的：筛出尚未建立微信书籍身份，或虽有书籍身份但章节 UID 仍缺失的历史候选书。
            // 涉及表：book 为候选主体；chapter 判断微信来源章节；note 与 chapter 联查确认存在可用范围身份的书摘。
            // 关键过滤：排除根记录和删除记录；缺书籍 ID 时只接受微信来源书/章节，缺章节 UID 时要求有效书摘包含 `start-end` 范围。
            // 时间字段：本查询不读取或换算时间字段。
            // 返回用途：按本地书籍主键倒序生成回填快照，后续候选键和远端唯一匹配都基于这份快照。
            let books = try BookRecord.fetchAll(db, sql: """
                SELECT b.* FROM book b
                WHERE b.id != 0
                  AND b.is_deleted = 0
                  AND (
                      (
                          TRIM(COALESCE(b.weread_book_id, '')) = ''
                          AND (
                              b.source_id = 4
                              OR b.id IN (
                                  SELECT DISTINCT c.book_id
                                  FROM chapter c
                                  WHERE c.id != 0 AND c.is_deleted = 0 AND c.source_type = 1
                              )
                          )
                      )
                      OR (
                          TRIM(COALESCE(b.weread_book_id, '')) != ''
                          AND EXISTS (
                              SELECT 1
                              FROM note n
                              INNER JOIN chapter c ON n.chapter_id = c.id
                              WHERE n.book_id = b.id
                                AND n.is_deleted = 0
                                AND c.id != 0
                                AND c.is_deleted = 0
                                AND c.source_type IN (0, 1)
                                AND TRIM(COALESCE(c.source_uid, '')) = ''
                                AND INSTR(TRIM(COALESCE(n.weread_range, '')), '-') > 0
                          )
                      )
                  )
                ORDER BY b.id DESC
                """)
            return try books.map { book in
                let bookID = book.id ?? 0
                // SQL 目的：收集候选书当前已绑定的全部微信章节 UID，作为远端书籍匹配的最高优先级证据。
                // 涉及表：chapter。
                // 关键过滤：限定当前书籍、有效微信来源章节，并排除空白 UID；DISTINCT 消除历史重复值。
                // 时间字段：本查询不读取或换算时间字段。
                // 返回用途：结果参与候选键计算，并用于远端章节集合的唯一交集匹配。
                let sourceUIDs = try String.fetchAll(db, sql: """
                    SELECT DISTINCT TRIM(COALESCE(source_uid, ''))
                    FROM chapter
                    WHERE book_id = ? AND is_deleted = 0 AND source_type = 1
                      AND TRIM(COALESCE(source_uid, '')) != ''
                    """, arguments: [bookID])
                // SQL 目的：判断候选书是否仍有能够通过书摘范围反查、但缺少微信 UID 的章节。
                // 涉及表：note 通过 chapter_id 内连接 chapter。
                // 关键过滤：书摘和章节均有效、排除根记录、章节来源仅限手工/微信、UID 为空且 weread_range 含合法分隔符。
                // 时间字段：本查询不读取或换算时间字段。
                // 返回用途：布尔结果进入 v2 候选键，确保章节回填完成后提示身份随状态变化。
                let hasMissing = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM note n
                        INNER JOIN chapter c ON n.chapter_id = c.id
                        WHERE n.book_id = ?
                          AND n.is_deleted = 0
                          AND n.chapter_id != 0
                          AND c.id != 0
                          AND c.is_deleted = 0
                          AND c.source_type IN (0, 1)
                          AND TRIM(COALESCE(c.source_uid, '')) = ''
                          AND INSTR(TRIM(COALESCE(n.weread_range, '')), '-') > 0
                    )
                    """, arguments: [bookID]) ?? false
                return BackfillLocalBook(
                    record: book,
                    chapterSourceUIDs: Set(sourceUIDs),
                    hasMissingChapterSourceUID: hasMissing
                )
            }
        }
    }

    func loadBackfillRemoteBooks(cookie: String) async throws -> BackfillRemoteLoadResult {
        var IDs: [String] = []
        var seen = Set<String>()
        var failures: [Error] = []
        for loader in [shelfBookIDs, notebookBookIDs] {
            do {
                for ID in try await loader(cookie) {
                    let value = ID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, seen.insert(value).inserted { IDs.append(value) }
                }
            } catch {
                if isAuthorizationFailure(error) { throw WereadImportError.authorizationExpired }
                failures.append(error)
            }
        }
        if IDs.isEmpty, let failure = failures.first { throw failure }

        var remote = try await syncBooks(ids: IDs, cookie: cookie).map {
            BackfillRemoteBook(book: $0)
        }
        let local = try await fetchBackfillBooks()
        let titlesNeedingChapterEvidence = Set(local
            .filter { !$0.chapterSourceUIDs.isEmpty }
            .flatMap { [$0.record.rawName, $0.record.name] }
            .map(normalizedBackfillTitle)
            .filter { !$0.isEmpty })
        var failedTitleKeys = Set<String>()
        for index in remote.indices {
            let titleKey = normalizedBackfillTitle(remote[index].book.title)
            guard titlesNeedingChapterEvidence.contains(titleKey) else { continue }
            do {
                let object = try await api.post(
                    "/web/book/chapterInfos",
                    cookie: cookie,
                    json: ["bookIds": [remote[index].book.wereadBookID]]
                ).object
                remote[index].chapterUIDs = Set(flattenChapters(buildChapters(from: object))
                    .map(\.uid)
                    .filter { $0 > 0 }
                    .map(String.init))
            } catch {
                if isAuthorizationFailure(error) { throw WereadImportError.authorizationExpired }
                failedTitleKeys.insert(titleKey)
            }
        }
        return BackfillRemoteLoadResult(
            books: remote,
            failedTitleKeys: failedTitleKeys,
            partialFailureCount: failures.count + failedTitleKeys.count
        )
    }

    func matchBackfillBooks(
        local: [BackfillLocalBook],
        remote: [BackfillRemoteBook]
    ) -> [Int64: String] {
        let grouped = Dictionary(grouping: remote.filter {
            !$0.book.wereadBookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) { normalizedBackfillTitle($0.book.title) }
        var usedRemoteIDs = Set<String>()
        var result: [Int64: String] = [:]
        for localBook in local {
            guard let localID = localBook.record.id else { continue }
            let titleKeys = normalizedBackfillTitleKeys(localBook)
            let candidates = titleKeys
                .flatMap { grouped[$0] ?? [] }
                .reduce(into: [BackfillRemoteBook]()) { values, item in
                    guard !usedRemoteIDs.contains(item.book.wereadBookID),
                          !values.contains(where: { $0.book.wereadBookID == item.book.wereadBookID }) else { return }
                    values.append(item)
                }
            guard let matched = matchBackfillBook(localBook, candidates: candidates) else { continue }
            let remoteID = matched.book.wereadBookID.trimmingCharacters(in: .whitespacesAndNewlines)
            usedRemoteIDs.insert(remoteID)
            result[localID] = remoteID
        }
        return result
    }

    func matchBackfillBook(
        _ localBook: BackfillLocalBook,
        candidates: [BackfillRemoteBook]
    ) -> BackfillRemoteBook? {
        guard !candidates.isEmpty else { return nil }
        if !localBook.chapterSourceUIDs.isEmpty {
            let chapterMatches = candidates.filter {
                !$0.chapterUIDs.isEmpty && !$0.chapterUIDs.isDisjoint(with: localBook.chapterSourceUIDs)
            }
            if chapterMatches.count == 1 { return chapterMatches[0] }
        }

        let rawNameKey = normalizedBackfillTitle(localBook.record.rawName)
        if !rawNameKey.isEmpty,
           let matched = uniqueBackfillCandidate(
               candidates.filter { normalizedBackfillTitle($0.book.title) == rawNameKey },
               localAuthor: localBook.record.author
           ) {
            return matched
        }

        let titleKeys = normalizedBackfillTitleKeys(localBook)
        let authorKey = normalizedBackfillText(localBook.record.author)
        if !authorKey.isEmpty {
            let authorMatches = candidates.filter {
                titleKeys.contains(normalizedBackfillTitle($0.book.title))
                    && normalizedBackfillText($0.book.author) == authorKey
            }
            if authorMatches.count == 1 { return authorMatches[0] }
        }

        if let localWordCount = localBook.record.wordCount, localWordCount > 0 {
            let wordMatches = candidates.filter { remoteBook in
                guard let remoteWordCount = remoteBook.book.wordCount, remoteWordCount > 0 else { return false }
                let tolerance = max(1_000, Int64(Double(remoteWordCount) * 0.03))
                return abs(localWordCount - remoteWordCount) <= tolerance
            }
            if wordMatches.count == 1 { return wordMatches[0] }
        }
        return nil
    }

    func uniqueBackfillCandidate(
        _ candidates: [BackfillRemoteBook],
        localAuthor: String
    ) -> BackfillRemoteBook? {
        if candidates.count == 1 { return candidates[0] }
        let authorKey = normalizedBackfillText(localAuthor)
        guard !authorKey.isEmpty else { return nil }
        let matches = candidates.filter { normalizedBackfillText($0.book.author) == authorKey }
        return matches.count == 1 ? matches[0] : nil
    }

    func normalizedBackfillTitleKeys(_ localBook: BackfillLocalBook) -> Set<String> {
        Set([localBook.record.rawName, localBook.record.name]
            .map(normalizedBackfillTitle)
            .filter { !$0.isEmpty })
    }

    func normalizedBackfillTitle(_ value: String) -> String {
        var result = normalizedBackfillText(value)
        if result.hasPrefix("《") { result.removeFirst() }
        if result.hasSuffix("》") { result.removeLast() }
        return result
    }

    func normalizedBackfillText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    func backfillChapterSourceUIDs(
        localBook: BackfillLocalBook,
        remoteBookID: String,
        cookie: String
    ) async throws -> BackfillChapterStats {
        guard let bookID = localBook.record.id else { return .init() }
        let localState = try await databaseManager.database.dbPool.read { db -> ([ChapterRecord], [BackfillLocalNote]) in
            // SQL 目的：读取候选书的完整有效章节集合，供路径、标题和来源身份联合匹配。
            // 涉及表：chapter。
            // 关键过滤：限定当前书籍并排除删除记录；保留根章节以便恢复完整父子路径语义。
            // 时间字段：章节时间字段按数据库原值解码，本查询不做时区或单位转换。
            // 返回用途：与远端章节树扁平结果比对，只生成唯一可证明的 UID 更新。
            let chapters = try ChapterRecord.fetchAll(db, sql: """
                SELECT * FROM chapter
                WHERE book_id = ? AND is_deleted = 0
                """, arguments: [bookID])
            // SQL 目的：读取缺少章节 UID 的微信历史书摘身份，作为章节级精确回填证据。
            // 涉及表：note 通过 chapter_id 内连接 chapter。
            // 关键过滤：书摘/章节均有效、排除根记录、章节来源仅限手工/微信、UID 为空且 weread_range 含 `start-end`。
            // 时间字段：本查询不读取或换算时间字段。
            // 返回用途：返回书摘 ID、章节 ID、范围、正文和想法，用远端范围与内容组合反证章节唯一性。
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.id AS note_id,
                       n.chapter_id AS chapter_id,
                       COALESCE(n.weread_range, '') AS weread_range,
                       COALESCE(n.content, '') AS content,
                       COALESCE(n.idea, '') AS idea
                FROM note n
                INNER JOIN chapter c ON n.chapter_id = c.id
                WHERE n.book_id = ?
                  AND n.is_deleted = 0
                  AND n.chapter_id != 0
                  AND c.id != 0
                  AND c.is_deleted = 0
                  AND c.source_type IN (0, 1)
                  AND TRIM(COALESCE(c.source_uid, '')) = ''
                  AND INSTR(TRIM(COALESCE(n.weread_range, '')), '-') > 0
                ORDER BY n.id ASC
                """, arguments: [bookID])
            let notes = rows.map { row in
                BackfillLocalNote(
                    id: row["note_id"],
                    chapterID: row["chapter_id"],
                    range: row["weread_range"],
                    content: row["content"],
                    idea: row["idea"]
                )
            }
            return (chapters, notes)
        }
        guard !localState.1.isEmpty else { return .init() }

        let remoteDetails: (chapters: [WereadImportChapter], notes: [WereadImportNote])
        do {
            remoteDetails = try await loadBackfillRemoteDetails(bookID: remoteBookID, cookie: cookie)
        } catch {
            if isAuthorizationFailure(error) { throw WereadImportError.authorizationExpired }
            return .init(
                skippedCount: Set(localState.1.map(\.chapterID)).count,
                partialFailureCount: 1,
                shouldRetry: true
            )
        }

        let remoteChapters = flattenChapters(remoteDetails.chapters)
        let updates = matchBackfillChapters(
            localChapters: localState.0,
            localNotes: localState.1,
            remoteChapters: remoteChapters,
            remoteNotes: remoteDetails.notes
        )
        let candidateChapterCount = Set(localState.1.map(\.chapterID)).count
        let updated = try await databaseManager.database.dbPool.write { db in
            var count = 0
            for update in updates {
                try db.execute(
                    // SQL 目的：用书摘原始身份唯一匹配后，为历史章节补齐微信 UID 与远端顺序。
                    // 涉及表：chapter。
                    // 关键过滤：章节有效、来源为手工/微信且 source_uid 仍为空，防止覆盖用户或并发任务已写身份。
                    // 时间字段：身份修复不改变业务更新时间。
                    // 副作用：source_type 统一为微信；所有更新在同一事务中提交。
                    sql: """
                        UPDATE chapter
                        SET source_type = 1, source_uid = ?, source_order = ?
                        WHERE id = ? AND is_deleted = 0 AND source_type IN (0, 1)
                          AND TRIM(COALESCE(source_uid, '')) = ''
                        """,
                    arguments: [update.sourceUID, update.sourceOrder, update.chapterID]
                )
                count += db.changesCount
            }
            return count
        }
        return .init(
            updatedCount: updated,
            skippedCount: max(candidateChapterCount - updated, 0)
        )
    }

    func loadBackfillRemoteDetails(
        bookID: String,
        cookie: String
    ) async throws -> (chapters: [WereadImportChapter], notes: [WereadImportNote]) {
        let marks = try await api.get("/web/book/bookmarklist?bookId=\(bookID)", cookie: cookie).object
        var notes = WereadImportAPIClient.array(marks["updated"])
            .filter { WereadImportAPIClient.int($0["type"]) == 1 }
            .map {
                WereadImportNote(
                    content: trimEnd(WereadImportAPIClient.string($0["markText"]) ?? ""),
                    range: WereadImportAPIClient.string($0["range"]) ?? "",
                    chapterUID: WereadImportAPIClient.int64($0["chapterUid"]) ?? 0,
                    createdAt: 0
                )
            }
        let reviews = try await api.get(
            "/web/review/list?bookId=\(bookID)&listType=11&mine=1",
            cookie: cookie
        ).object
        for wrapper in WereadImportAPIClient.array(reviews["reviews"]) {
            let review = WereadImportAPIClient.dictionary(wrapper["review"]) ?? wrapper
            guard WereadImportAPIClient.int(review["type"]) == 1 else { continue }
            notes.append(.init(
                content: trimEnd(WereadImportAPIClient.string(review["abstract"]) ?? ""),
                idea: trimEnd(WereadImportAPIClient.string(review["content"]) ?? ""),
                range: WereadImportAPIClient.string(review["range"]) ?? "",
                chapterUID: WereadImportAPIClient.int64(review["chapterUid"]) ?? 0,
                createdAt: 0
            ))
        }
        let chapterObject = try await api.post(
            "/web/book/chapterInfos",
            cookie: cookie,
            json: ["bookIds": [bookID]]
        ).object
        return (buildChapters(from: chapterObject), notes)
    }

    func matchBackfillChapters(
        localChapters: [ChapterRecord],
        localNotes: [BackfillLocalNote],
        remoteChapters: [WereadImportChapter],
        remoteNotes: [WereadImportNote]
    ) -> [BackfillChapterUpdate] {
        let updateable: [Int64: ChapterRecord] = Dictionary(uniqueKeysWithValues: localChapters.compactMap { chapter in
            guard let ID = chapter.id,
                  (chapter.sourceUid ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  chapter.sourceType == 0 || chapter.sourceType == 1 else { return nil }
            return (ID, chapter)
        })
        guard !updateable.isEmpty else { return [] }
        let remoteByUID: [String: WereadImportChapter] = Dictionary(uniqueKeysWithValues: remoteChapters.compactMap { chapter in
            guard chapter.uid > 0 else { return nil }
            return (String(chapter.uid), chapter)
        })
        var remoteNotesByKey: [BackfillNoteKey: [String]] = [:]
        for note in remoteNotes {
            guard note.chapterUID > 0, let key = backfillNoteKey(
                range: note.range,
                content: note.content,
                idea: note.idea
            ) else { continue }
            remoteNotesByKey[key, default: []].append(String(note.chapterUID))
        }
        let localTitleCounts = Dictionary(grouping: updateable.values.map { normalizedBackfillText($0.title) }) { $0 }
            .mapValues(\.count)
        let remoteTitleCounts = Dictionary(grouping: remoteChapters.map { normalizedBackfillText($0.title) }) { $0 }
            .mapValues(\.count)
        var matchedUIDs: [Int64: Set<String>] = [:]
        for note in localNotes where updateable[note.chapterID] != nil {
            guard let key = backfillNoteKey(range: note.range, content: note.content, idea: note.idea) else { continue }
            let UIDs = Set(remoteNotesByKey[key] ?? [])
            guard UIDs.count == 1, let UID = UIDs.first, remoteByUID[UID] != nil else { continue }
            matchedUIDs[note.chapterID, default: []].insert(UID)
        }
        return Set(localNotes.map(\.chapterID)).compactMap { chapterID in
            guard let localChapter = updateable[chapterID],
                  let UIDs = matchedUIDs[chapterID], UIDs.count == 1,
                  let UID = UIDs.first,
                  let remoteChapter = remoteByUID[UID],
                  backfillChapterMatches(
                      local: localChapter,
                      remote: remoteChapter,
                      localTitleCounts: localTitleCounts,
                      remoteTitleCounts: remoteTitleCounts
                  ) else { return nil }
            return BackfillChapterUpdate(
                chapterID: chapterID,
                sourceUID: UID,
                sourceOrder: remoteChapter.order
            )
        }
    }

    func backfillNoteKey(range: String, content: String, idea: String) -> BackfillNoteKey? {
        let parts = range.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int64(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              start >= 0, end > start else { return nil }
        return .init(
            rangeStart: start,
            rangeEnd: end,
            content: trimEnd(content),
            idea: trimEnd(idea)
        )
    }

    func backfillChapterMatches(
        local: ChapterRecord,
        remote: WereadImportChapter,
        localTitleCounts: [String: Int],
        remoteTitleCounts: [String: Int]
    ) -> Bool {
        let localPath = normalizedBackfillPath(local.sourcePath ?? "")
        let remotePath = normalizedBackfillPath(remote.sourcePath)
        if !localPath.isEmpty, !remotePath.isEmpty { return localPath == remotePath }
        let localTitle = normalizedBackfillText(local.title)
        let remoteTitle = normalizedBackfillText(remote.title)
        return !localTitle.isEmpty
            && localTitle == remoteTitle
            && localTitleCounts[localTitle] == 1
            && remoteTitleCounts[remoteTitle] == 1
    }

    func normalizedBackfillPath(_ value: String) -> String {
        value.components(separatedBy: " / ")
            .map(normalizedBackfillText)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    func noteImportDraft(from source: WereadImportBook) -> NoteImportDraftBook {
        var draft = NoteImportDraftBook()
        draft.name = source.title
        draft.rawName = source.rawTitle
        draft.author = source.author
        draft.translator = source.translator
        draft.press = source.press
        draft.isbn = source.isbn
        draft.summary = source.summary
        draft.pubDate = source.publicationDate
        draft.cover = source.coverURL
        draft.type = 1
        draft.source = 4
        draft.sourceName = "微信读书"
        draft.positionUnit = 1
        draft.currentPositionUnit = 1
        draft.wordCount = source.wordCount
        draft.readStatusID = source.readStatusID
        draft.readStatusChangedDate = source.readStatusChangedAt
        draft.wereadBookID = source.wereadBookID
        draft.wereadUpdateTime = source.wereadUpdatedAt
        draft.chapters = source.chapters.map(noteImportChapter)
        draft.notes = source.notes.filter(\.isSelected).map { note in
            NoteImportDraftNote(
                content: note.content,
                idea: note.idea,
                positionUnit: 1,
                createdTime: note.createdAt,
                wereadRange: note.range,
                wereadChapterUID: note.chapterUID
            )
        }
        draft.reviews = source.reviews.map { review in
            NoteImportDraftReview(
                title: review.title,
                content: review.content,
                createdTime: review.createdAt
            )
        }
        draft.wereadReadingDurations = source.readingDays.map { day in
            NoteImportFuzzyReadingDuration(
                date: day.date * 1_000,
                durationSeconds: day.seconds
            )
        }
        return draft
    }

    func noteImportChapter(_ source: WereadImportChapter) -> NoteImportDraftChapter {
        NoteImportDraftChapter(
            title: source.title,
            level: source.level,
            order: source.order,
            pathTitles: source.sourcePath.components(separatedBy: " / ").filter { !$0.isEmpty },
            sourceType: 1,
            sourceUID: source.uid > 0 ? String(source.uid) : "",
            sourceAnchor: source.sourceAnchor,
            sourceOrder: source.order,
            sourcePath: source.sourcePath,
            children: source.children.map(noteImportChapter)
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
