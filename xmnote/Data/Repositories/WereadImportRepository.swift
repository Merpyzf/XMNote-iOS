/**
 * [INPUT]: 依赖 DatabaseManager、WereadImportAPIClient、WereadWebAuthorizationService、UserDefaults 与微信读书领域模型
 * [OUTPUT]: 对外提供 WereadImportRepository，完成授权恢复、远端抓取、本地匹配、历史回填与 GRDB 增量导入
 * [POS]: Data/Repositories 的微信读书扫码导入实现，是 ViewModel 唯一的数据与业务入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import GRDB

@MainActor
final class WereadImportRepository: WereadImportRepositoryProtocol {
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

    private let databaseManager: DatabaseManager
    private let defaults: UserDefaults
    private let api: WereadImportAPIClient
    private let webAuthorization: WereadWebAuthorizationService
    private let bookSearchRepository: any BookSearchRepositoryProtocol
    private let s3UploadRepository: (any S3UploadRepositoryProtocol)?

    init(
        databaseManager: DatabaseManager,
        defaults: UserDefaults = .standard,
        api: WereadImportAPIClient? = nil,
        webAuthorization: WereadWebAuthorizationService? = nil,
        bookSearchRepository: (any BookSearchRepositoryProtocol)? = nil,
        s3UploadRepository: (any S3UploadRepositoryProtocol)? = nil
    ) {
        self.databaseManager = databaseManager
        self.defaults = defaults
        self.api = api ?? WereadImportAPIClient()
        self.webAuthorization = webAuthorization ?? .shared
        self.bookSearchRepository = bookSearchRepository ?? BookSearchRepository()
        self.s3UploadRepository = s3UploadRepository
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
        } catch {
            await clearAuthorization()
            return nil
        }
    }

    func validateAuthorization(cookieHeader: String) async throws -> WereadAuthorization {
        guard let authorization = parseAuthorization(cookieHeader) else { throw WereadImportError.authorizationExpired }
        let renewed = try await renewedAuthorization(authorization, force: true)
        try await verify(renewed)
        persist(renewed)
        await webAuthorization.replaceCookies(with: renewed.cookieHeader)
        return renewed
    }

    func clearAuthorization() async {
        [Keys.cookie, Keys.userID, Keys.renewedAt].forEach(defaults.removeObject(forKey:))
        await webAuthorization.clearCookies()
    }

    func fetchImportBookIDs(authorization: WereadAuthorization, preferences: WereadImportPreferences) async throws -> [String] {
        let authorization = try await renewedAuthorization(authorization, force: true)
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
        guard !ids.isEmpty else { throw WereadImportError.emptyImport }
        let books = try await syncBooks(ids: ids, cookie: authorization.cookieHeader)
        let total = books.count
        var completed = Array<WereadImportBook?>(repeating: nil, count: total)
        var current = 0
        for chunkStart in stride(from: 0, to: total, by: 10) {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + 10, total)
            await withTaskGroup(of: (Int, WereadImportBook?).self) { group in
                for index in chunkStart..<chunkEnd {
                    let book = books[index]
                    group.addTask { [weak self] in
                        guard let self else { return (index, nil) }
                        do { return (index, try await self.fillDetails(book, cookie: authorization.cookieHeader, importsReadingTime: preferences.importsReadingTime)) }
                        catch { return (index, nil) }
                    }
                }
                for await (index, book) in group {
                    completed[index] = book
                    if book == nil { warning("《\(books[index].title)》加载失败，已跳过") }
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
        let books = try await syncBooks(ids: bookIDs, cookie: authorization.cookieHeader)
        var completed = Array<WereadImportBook?>(repeating: nil, count: books.count)
        var current = 0
        for chunkStart in stride(from: 0, to: books.count, by: 2) {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + 2, books.count)
            try await withThrowingTaskGroup(of: (Int, WereadImportBook).self) { group in
                for index in chunkStart..<chunkEnd {
                    let book = books[index]
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        return (index, try await self.fillDetails(book, cookie: authorization.cookieHeader, importsReadingTime: importsReadingTime))
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
        let selected = await enrichNewBooks(books.filter(\.isSelected))
        guard !selected.isEmpty else { throw WereadImportError.emptyImport }
        let newBookPlacement = defaults.object(forKey: Keys.newBookPosition) as? Int ?? 0
        for (index, source) in selected.enumerated() {
            try Task.checkCancellation()
            try await databaseManager.database.dbPool.write { db in
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
                let bookID = try self.upsertBook(source, ownerID: ownerID, placement: newBookPlacement, now: now, db: db)
                var chapterMap: [Int64: Int64] = [:]
                try self.upsertChapters(source.chapters, bookID: bookID, parentID: 0, now: now, db: db, map: &chapterMap)
                try self.upsertNotes(source.notes.filter(\.isSelected), bookID: bookID, chapters: chapterMap, now: now, db: db)
                try self.cleanupStaleChapters(bookID: bookID, preservedIDs: Set(chapterMap.values), now: now, db: db)
                try self.upsertReviews(source.reviews, bookID: bookID, now: now, db: db)
                try self.upsertReadingDays(source.readingDays, bookID: bookID, now: now, db: db)
                try self.mergeReadStatus(source, bookID: bookID, now: now, db: db)
            }
            progress(index + 1, selected.count)
        }
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
        let keys = Set(candidates.compactMap { book in book.id.map { candidateKey(id: $0, title: book.rawName, author: book.author) } }).subtracting(handled)
        return WereadBackfillPrompt(pendingCount: keys.count, candidateKeys: keys)
    }

    func performBackfill(
        authorization: WereadAuthorization,
        progress: @escaping (WereadBackfillProgress) -> Void
    ) async throws -> WereadBackfillResult {
        progress(.init(stage: .preparing, current: 0, total: 0, bookName: ""))
        let prompt = try await fetchBackfillPrompt()
        progress(.init(stage: .syncingRemoteBooks, current: 0, total: prompt.pendingCount, bookName: ""))
        let ids = try await shelfBookIDs(cookie: authorization.cookieHeader)
        let remote = try await syncBooks(ids: ids, cookie: authorization.cookieHeader)
        progress(.init(stage: .matchingBooks, current: 0, total: prompt.pendingCount, bookName: ""))
        let local = try await fetchBackfillBooks()
        var matched = 0, chapterUIDs = 0, skipped = 0, partialFailures = 0
        var handled = Set<String>()
        for (index, book) in local.enumerated() {
            try Task.checkCancellation()
            guard let bookID = book.id else { continue }
            let key = candidateKey(id: bookID, title: book.rawName, author: book.author)
            guard prompt.candidateKeys.contains(key) else { continue }
            progress(.init(stage: .processingBooks, current: index + 1, total: local.count, bookName: book.name))
            let matches = remote.filter { source in
                !book.wereadBookId.isEmpty
                    ? source.wereadBookID == book.wereadBookId
                    : normalized(source.rawTitle) == normalized(book.rawName) && normalized(source.author) == normalized(book.author)
            }
            guard matches.count == 1, let source = matches.first else { skipped += 1; handled.insert(key); continue }
            do {
                let chapterObject = try await api.post("/web/book/chapterInfos", cookie: authorization.cookieHeader, json: ["bookIds": [source.wereadBookID]]).object
                let remoteChapters = flattenChapters(buildChapters(from: chapterObject))
                let updated = try await databaseManager.database.dbPool.write { db -> Int in
                    if book.wereadBookId.isEmpty {
                        try db.execute(sql: "UPDATE book SET weread_book_id = ? WHERE id = ? AND weread_book_id = ''", arguments: [source.wereadBookID, bookID])
                    }
                    let localChapters = try ChapterRecord.filter(Column("book_id") == bookID && Column("is_deleted") == 0).fetchAll(db)
                    var count = 0
                    for chapter in localChapters where chapter.sourceUid?.isEmpty != false {
                        let candidates = remoteChapters.filter { self.normalized($0.title) == self.normalized(chapter.title) }
                        if candidates.count == 1, let target = candidates.first, let chapterID = chapter.id {
                            try db.execute(sql: "UPDATE chapter SET source_type = 1, source_uid = ?, source_order = ?, source_path = ? WHERE id = ?", arguments: [String(target.uid), target.order, target.sourcePath, chapterID])
                            count += 1
                        }
                    }
                    return count
                }
                if book.wereadBookId.isEmpty { matched += 1 }
                chapterUIDs += updated
                handled.insert(key)
            } catch is CancellationError { throw CancellationError() }
            catch { partialFailures += 1 }
        }
        let merged = Set(defaults.stringArray(forKey: Keys.handledBackfill) ?? []).union(handled)
        defaults.set(Array(merged), forKey: Keys.handledBackfill)
        return .init(bookIDMatchedCount: matched, chapterUIDUpdatedCount: chapterUIDs, skippedCount: skipped, partialFailureCount: partialFailures, handledCandidateKeys: handled)
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
        let response = try await api.post("/web/login/renewal", cookie: authorization.cookieHeader, json: ["rq": "%2Fweb%2Fbook%2Fread", "ql": false])
        var values = cookieDictionary(authorization.cookieHeader)
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: response.httpResponse.allHeaderFields.reduce(into: [:]) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }, for: URL(string: "https://weread.qq.com")!) { values[cookie.name] = cookie.value }
        let header = values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        guard let renewed = parseAuthorization(header) else { throw WereadImportError.authorizationExpired }
        persist(renewed)
        return renewed
    }

    func verify(_ authorization: WereadAuthorization) async throws {
        _ = try await api.post("/web/shelf/syncBook", cookie: authorization.cookieHeader, json: ["bookIds": ["39980421"], "count": 1, "isArchive": NSNull(), "currentArchiveId": NSNull(), "loadMore": true])
    }

    func notebookBookIDs(cookie: String) async throws -> [String] {
        let object = try await api.get("/api/user/notebook", cookie: cookie).object
        return WereadImportAPIClient.array(object["books"]).compactMap { wrapper in
            let book = WereadImportAPIClient.dictionary(wrapper["book"])
            let type = WereadImportAPIClient.int(book?["type"]) ?? WereadImportAPIClient.int(wrapper["type"]) ?? 1
            return type == 1 ? WereadImportAPIClient.string(wrapper["bookId"] ?? book?["bookId"]) : nil
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
            (WereadImportAPIClient.int(item["type"]) == 1) ? WereadImportAPIClient.string(item["bookId"]) : nil
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
            .init(content: (WereadImportAPIClient.string($0["markText"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), range: WereadImportAPIClient.string($0["range"]) ?? "", chapterUID: WereadImportAPIClient.int64($0["chapterUid"]) ?? 0, createdAt: (WereadImportAPIClient.int64($0["createTime"]) ?? Int64(Date().timeIntervalSince1970)) * 1000)
        }
        let reviewObject = try await api.get("/web/review/list?bookId=\(source.wereadBookID)&listType=11&mine=1", cookie: cookie).object
        let wrappers = WereadImportAPIClient.array(reviewObject["reviews"])
        for wrapper in wrappers {
            let review = WereadImportAPIClient.dictionary(wrapper["review"]) ?? wrapper
            let type = WereadImportAPIClient.int(review["type"]) ?? 0
            if type == 1 {
                source.notes.append(.init(content: (WereadImportAPIClient.string(review["abstract"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), idea: (WereadImportAPIClient.string(review["content"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), range: WereadImportAPIClient.string(review["range"]) ?? "", chapterUID: WereadImportAPIClient.int64(review["chapterUid"]) ?? 0, createdAt: (WereadImportAPIClient.int64(review["createTime"]) ?? Int64(Date().timeIntervalSince1970)) * 1000))
            } else if type == 4, let content = WereadImportAPIClient.string(review["content"]), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                source.reviews.append(.init(title: WereadImportAPIClient.string(review["title"]) ?? "", content: content, createdAt: (WereadImportAPIClient.int64(review["createTime"]) ?? Int64(Date().timeIntervalSince1970)) * 1000))
            }
        }
        let chapterObject = try await api.post("/web/book/chapterInfos", cookie: cookie, json: ["bookIds": [source.wereadBookID]]).object
        source.chapters = buildChapters(from: chapterObject)
        let chapterOrder = chapterUIDOrder(source.chapters)
        source.notes.sort {
            let left = chapterOrder[$0.chapterUID] ?? Int.max
            let right = chapterOrder[$1.chapterUID] ?? Int.max
            return left == right ? rangeStart($0.range) < rangeStart($1.range) : left < right
        }
        if importsReadingTime || source.readStatusID == 3 {
            let info = try await api.get("/web/book/readinfo?bookId=\(source.wereadBookID)&readingDetail=1&readingBookIndex=1&finishedDate=1", cookie: cookie).object
            let readDetail = WereadImportAPIClient.dictionary(info["readDetail"])
            let finished = WereadImportAPIClient.int64(info["finishedDate"]) ?? 0
            let lastReading = WereadImportAPIClient.int64(readDetail?["lastReadingDate"]) ?? 0
            let resolved = finished > 0 ? finished * 1000 : (lastReading > 0 ? lastReading * 1000 : source.wereadUpdatedAt)
            if source.readStatusID == 3 { source.readStatusChangedAt = resolved }
            if importsReadingTime {
                source.readingDays = WereadImportAPIClient.array(readDetail?["data"]).compactMap { day in
                    guard let date = WereadImportAPIClient.int64(day["readDate"]), let seconds = WereadImportAPIClient.int64(day["readTime"]), seconds > 0 else { return nil }
                    return .init(date: date, seconds: seconds)
                }
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
            let level = requestedLevel > 1 && stack[requestedLevel - 1] == nil ? 1 : requestedLevel
            node.value.level = Int64(level)
            if level == 1 { roots.append(node) } else { stack[level - 1]?.children.append(node) }
            stack[level] = node
            stack.keys.filter { $0 > level }.forEach { stack.removeValue(forKey: $0) }
        }
        func hasFollowingChild(after index: Int, parentLevel: Int) -> Bool {
            for next in updated.dropFirst(index + 1) {
                let nextLevel = max(WereadImportAPIClient.int(next["level"]) ?? 1, 1)
                if nextLevel <= parentLevel { return false }
                if nextLevel == parentLevel + 1 { return true }
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
            let promoted = anchors.enumerated().first { _, anchor in
                let anchorTitle = (WereadImportAPIClient.string(anchor["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceAnchor = (WereadImportAPIClient.string(anchor["anchor"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !anchorTitle.isEmpty, !sourceAnchor.isEmpty, normalized(anchorTitle) != normalized(resolvedTitle), level < 5 else { return false }
                return hasFollowingChild(after: itemIndex, parentLevel: level)
            }
            let node = Node(.init(uid: promoted == nil ? uid : 0, title: resolvedTitle, order: order, level: Int64(level)))
            add(node, requestedLevel: level)
            if let (_, anchor) = promoted {
                let anchorTitle = (WereadImportAPIClient.string(anchor["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceAnchor = (WereadImportAPIClient.string(anchor["anchor"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                add(Node(.init(uid: uid, title: anchorTitle, order: order, level: Int64(level + 1), sourceAnchor: sourceAnchor)), requestedLevel: level + 1)
            }
        }
        func value(_ node: Node, path: [String]) -> WereadImportChapter {
            var item = node.value; let next = path + [item.title]; item.sourcePath = next.joined(separator: " / "); item.children = node.children.map { value($0, path: next) }; return item
        }
        return roots.map { value($0, path: []) }
    }

    func rangeStart(_ range: String) -> Int { Int(range.split(separator: "-").first ?? "0") ?? 0 }
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
    nonisolated func candidateKey(id: Int64, title: String, author: String) -> String {
        let input = "v2|\(id)|\(normalized(title))|\(normalized(author))"
        return Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func flattenChapters(_ chapters: [WereadImportChapter]) -> [WereadImportChapter] {
        chapters.flatMap { [$0] + flattenChapters($0.children) }
    }
    func fetchBackfillBooks() async throws -> [BookRecord] {
        try await databaseManager.database.dbPool.read { db in
            try BookRecord.fetchAll(db, sql: """
                SELECT b.* FROM book b
                WHERE b.source_id = 4 AND b.is_deleted = 0
                  AND (b.weread_book_id = '' OR EXISTS (
                      SELECT 1 FROM chapter c
                      WHERE c.book_id = b.id AND c.is_deleted = 0 AND c.source_type = 1
                        AND COALESCE(c.source_uid, '') = ''
                  ))
                """)
        }
    }
}

private extension WereadImportRepository {
    nonisolated func upsertBook(_ source: WereadImportBook, ownerID: Int64, placement: Int, now: Int64, db: Database) throws -> Int64 {
        if let target = source.targetBookID, var book = try BookRecord.fetchOne(db, key: target) {
            if book.wereadBookId.isEmpty { book.wereadBookId = source.wereadBookID }
            book.rawName = source.rawTitle; book.wordCount = source.wordCount; book.updatedDate = now; try book.update(db); return target
        }
        let edge = placement == 1
            ? (try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(book_order), -1) FROM book WHERE user_id = ? AND is_deleted = 0", arguments: [ownerID]) ?? -1) + 1
            : (try Int64.fetchOne(db, sql: "SELECT COALESCE(MIN(book_order), 1) FROM book WHERE user_id = ? AND is_deleted = 0", arguments: [ownerID]) ?? 1) - 1
        var book = BookRecord(); book.userId = ownerID; book.wereadBookId = source.wereadBookID; book.name = source.title; book.rawName = source.rawTitle; book.author = source.author; book.cover = source.coverURL; book.summary = source.summary; book.translator = source.translator; book.isbn = source.isbn; book.press = source.press; book.pubDate = source.publicationDate; book.wordCount = source.wordCount; book.type = 1; book.currentPositionUnit = 1; book.positionUnit = 1; book.sourceId = 4; book.bookOrder = edge; book.readStatusId = source.readStatusID; book.readStatusChangedDate = source.readStatusChangedAt; book.createdDate = now; book.updatedDate = now
        try book.insert(db); guard let id = book.id else { throw WereadImportError.message("创建书籍失败") }; return id
    }

    nonisolated func upsertChapters(_ chapters: [WereadImportChapter], bookID: Int64, parentID: Int64, now: Int64, db: Database, map: inout [Int64: Int64]) throws {
        for chapter in chapters {
            let sourceMatch = chapter.uid > 0
                ? try ChapterRecord.filter(Column("book_id") == bookID && Column("parent_id") == parentID && Column("source_type") == 1 && Column("source_uid") == String(chapter.uid) && Column("source_anchor") == chapter.sourceAnchor).fetchOne(db)
                : nil
            let titleMatch = try ChapterRecord.filter(Column("book_id") == bookID && Column("parent_id") == parentID && Column("title") == chapter.title && Column("is_deleted") == 0).fetchOne(db)
            var record = sourceMatch ?? titleMatch ?? ChapterRecord()
            let isNew = record.id == nil; record.bookId = bookID; record.parentId = parentID; record.title = chapter.title; record.chapterOrder = chapter.order; record.chapterLevel = chapter.level; record.isImport = 1; record.sourceType = 1; record.sourceUid = chapter.uid > 0 ? String(chapter.uid) : nil; record.sourceAnchor = chapter.sourceAnchor; record.sourceOrder = chapter.order; record.sourcePath = chapter.sourcePath; record.updatedDate = now; record.isDeleted = 0
            if isNew { record.createdDate = now; try record.insert(db) } else { try record.update(db) }
            if let id = record.id { if chapter.uid > 0 { map[chapter.uid] = id }; try upsertChapters(chapter.children, bookID: bookID, parentID: id, now: now, db: db, map: &map) }
        }
    }

    nonisolated func upsertNotes(_ notes: [WereadImportNote], bookID: Int64, chapters: [Int64: Int64], now: Int64, db: Database) throws {
        for note in notes where !note.content.isEmpty || !note.idea.isEmpty {
            let existing: Int64? = try Int64.fetchOne(db, sql: "SELECT id FROM note WHERE book_id = ? AND content = ? AND idea = ? LIMIT 1", arguments: [bookID, note.content, note.idea])
            let chapterID = chapters[note.chapterUID] ?? 0
            if let existing { if chapterID > 0 { try db.execute(sql: "UPDATE note SET chapter_id = ?, weread_range = ?, is_deleted = 0 WHERE id = ?", arguments: [chapterID, note.range, existing]) }; continue }
            var record = NoteRecord(); record.bookId = bookID; record.chapterId = chapterID; record.content = note.content; record.idea = note.idea; record.positionUnit = 1; record.wereadRange = note.range; record.createdDate = note.createdAt > 0 ? note.createdAt : now; record.updatedDate = now; try record.insert(db)
        }
    }

    nonisolated func upsertReviews(_ reviews: [WereadImportReview], bookID: Int64, now: Int64, db: Database) throws {
        var existing = try ReviewRecord.filter(Column("book_id") == bookID).fetchAll(db)
        for review in reviews {
            let title = review.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = normalizedReviewHTML(review.content)
            guard !existing.contains(where: { ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == title && normalizedReviewHTML($0.content ?? "") == plain }) else { continue }
            var record = ReviewRecord(); record.bookId = bookID; record.title = review.title; record.content = review.content; record.createdDate = review.createdAt > 0 ? review.createdAt : now; record.updatedDate = now; try record.insert(db)
            existing.append(record)
        }
    }

    nonisolated func normalizedReviewHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func cleanupStaleChapters(bookID: Int64, preservedIDs: Set<Int64>, now: Int64, db: Database) throws {
        let candidates = try ChapterRecord
            .filter(Column("book_id") == bookID && Column("source_type") == 1 && Column("is_deleted") == 0)
            .fetchAll(db)
            .compactMap(\.id)
            .filter { !preservedIDs.contains($0) }
        for candidate in candidates {
            let noteCount: Int = try Int.fetchOne(db, sql: """
                WITH RECURSIVE subtree(id) AS (
                    SELECT ?
                    UNION ALL
                    SELECT c.id FROM chapter c JOIN subtree s ON c.parent_id = s.id
                    WHERE c.book_id = ? AND c.is_deleted = 0
                )
                SELECT COUNT(*) FROM note WHERE chapter_id IN (SELECT id FROM subtree)
                """, arguments: [candidate, bookID]) ?? 0
            guard noteCount == 0 else { continue }
            try db.execute(sql: """
                WITH RECURSIVE subtree(id) AS (
                    SELECT ?
                    UNION ALL
                    SELECT c.id FROM chapter c JOIN subtree s ON c.parent_id = s.id
                    WHERE c.book_id = ? AND c.is_deleted = 0
                )
                UPDATE chapter SET is_deleted = 1, updated_date = ? WHERE id IN (SELECT id FROM subtree)
                """, arguments: [candidate, bookID, now])
        }
    }

    nonisolated func upsertReadingDays(_ days: [WereadImportReadingDay], bookID: Int64, now: Int64, db: Database) throws {
        let manual: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM read_time_record WHERE book_id = ? AND is_deleted = 0 AND weread_read_date = 0", arguments: [bookID]) ?? 0
        guard manual == 0 else { return }
        for day in days {
            let readDateMillis = day.date * 1000
            if let id: Int64 = try Int64.fetchOne(db, sql: "SELECT id FROM read_time_record WHERE book_id = ? AND weread_read_date = ? LIMIT 1", arguments: [bookID, readDateMillis]) {
                try db.execute(sql: "UPDATE read_time_record SET elapsed_seconds = ?, updated_date = ?, is_deleted = 0 WHERE id = ?", arguments: [day.seconds, now, id])
            } else {
                var record = ReadTimeRecordRecord(); record.bookId = bookID; record.elapsedSeconds = day.seconds; record.status = 3; record.fuzzyReadDate = readDateMillis; record.wereadReadDate = readDateMillis; record.createdDate = now; record.updatedDate = now; try record.insert(db)
            }
        }
    }

    nonisolated func mergeReadStatus(_ source: WereadImportBook, bookID: Int64, now: Int64, db: Database) throws {
        guard source.readStatusID == 3, source.readStatusChangedAt > 0 else { return }
        let latest: Int64 = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(changed_date), 0) FROM book_read_status_record WHERE book_id = ? AND is_deleted = 0", arguments: [bookID]) ?? 0
        guard source.readStatusChangedAt > latest else { return }
        var record = BookReadStatusRecordRecord(); record.bookId = bookID; record.readStatusId = 3; record.changedDate = source.readStatusChangedAt; record.createdDate = now; record.updatedDate = now; try record.insert(db)
        try db.execute(sql: "UPDATE book SET read_status_id = 3, read_status_changed_date = ?, updated_date = ? WHERE id = ?", arguments: [source.readStatusChangedAt, now, bookID])
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
