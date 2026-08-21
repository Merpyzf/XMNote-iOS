/**
 * [INPUT]: 依赖微信读书 Repository/ViewModel、可控 API 与仓储测试桩
 * [OUTPUT]: 验证批次边界、缓存重试、详情并发/进度、Cookie 续期和授权清理边界
 * [POS]: xmnoteTests 的微信读书授权导入一致性门禁
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct WereadImportAlignmentTests {
    @Test(arguments: [
        (0, []),
        (1, [1]),
        (99, [99]),
        (100, [100]),
        (101, [100, 1]),
        (201, [100, 100, 1])
    ])
    func batchBoundariesMatchAndroid(
        count: Int,
        expectedSizes: [Int]
    ) {
        let repository = WereadRepositoryStub()
        let route = WereadBatchRoute(
            authorization: .init(cookieHeader: "wr_vid=1; wr_skey=key", userID: "1"),
            bookIDs: (0..<count).map(String.init),
            importsReadingTime: false,
            repository: repository
        )
        let model = WereadBatchViewModel(route: route)

        #expect(model.batches.map { $0.bookIDs.count } == expectedSizes)
        #expect(model.batches.map(\.start) == expectedSizes.indices.map { $0 * 100 + 1 })
        #expect(model.batches.map(\.end) == expectedSizes.indices.map { index in
            index * 100 + expectedSizes[index]
        })
    }

    @Test
    func successfulBatchUsesCachedPreviewAndWeightedProgress() async throws {
        let repository = WereadRepositoryStub()
        let route = WereadBatchRoute(
            authorization: .init(cookieHeader: "wr_vid=1; wr_skey=key", userID: "1"),
            bookIDs: (0..<201).map(String.init),
            importsReadingTime: false,
            repository: repository
        )
        let model = WereadBatchViewModel(route: route)

        model.beginOpen(model.batches[0].id)
        try await waitUntil { model.batches[0].status == .success }
        #expect(repository.fetchCount == 1)
        #expect(model.completedPercent == 49)
        model.preview = nil
        model.beginOpen(model.batches[0].id)
        try await waitUntil { model.preview != nil }
        #expect(repository.fetchCount == 1)
    }

    @Test
    func failedBatchCanRetryAndOnlyOneBatchLoadsAtATime() async throws {
        let repository = WereadRepositoryStub()
        repository.failuresRemaining = 1
        repository.delay = .milliseconds(80)
        let route = WereadBatchRoute(
            authorization: .init(cookieHeader: "wr_vid=1; wr_skey=key", userID: "1"),
            bookIDs: (0..<101).map(String.init),
            importsReadingTime: false,
            repository: repository
        )
        let model = WereadBatchViewModel(route: route)

        model.beginOpen(model.batches[0].id)
        model.beginOpen(model.batches[1].id)
        try await waitUntil { model.batches[0].status == .failed }
        #expect(model.batches[1].status == .notStarted)
        model.beginOpen(model.batches[0].id)
        try await waitUntil { model.batches[0].status == .success }
        #expect(repository.fetchCount == 2)
    }

    @Test
    func cancelledOldBatchCannotWriteIntoTheNewState() async throws {
        let repository = WereadRepositoryStub()
        repository.ignoresCancellationForFirstBatch = true
        let route = WereadBatchRoute(
            authorization: .init(cookieHeader: "wr_vid=1; wr_skey=key", userID: "1"),
            bookIDs: (0..<101).map(String.init),
            importsReadingTime: false,
            repository: repository
        )
        let model = WereadBatchViewModel(route: route)

        model.beginOpen(model.batches[0].id)
        try await waitUntil { model.batches[0].status.isLoading }
        model.cancel()
        model.beginOpen(model.batches[1].id)
        try await waitUntil { model.batches[1].status == .success }
        try await Task.sleep(for: .milliseconds(220))

        #expect(model.batches[0].status == .notStarted)
        #expect(model.batches[0].books.isEmpty)
        #expect(model.batches[1].books.map(\.wereadBookID) == ["100"])
        #expect(model.preview?.books.map(\.wereadBookID) == ["100"])
    }

    @Test
    func batchDetailsUseTwoBookGroupsAndMonotonicProgress() async throws {
        let api = WereadAPIProbe()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("wr_vid=1; wr_skey=old", forKey: "wereadCookie")
        defaults.set("1", forKey: "wereadUserId")
        defaults.set(Date().timeIntervalSince1970, forKey: "wereadCookieRenewedAt")
        let database = try AppDatabase.empty()
        let repository = WereadImportRepository(
            databaseManager: DatabaseManager(database: database),
            defaults: defaults,
            api: api,
            nowMillis: { 1_710_000_000_000 }
        )
        var progress: [(Int, Int)] = []
        let authorization = WereadAuthorization(
            cookieHeader: "wr_vid=1; wr_skey=old",
            userID: "1"
        )

        let books = try await repository.fetchImportBooks(
            authorization: authorization,
            bookIDs: ["1", "2", "3", "4", "5"],
            importsReadingTime: false
        ) { current, total in
            progress.append((current, total))
        }

        #expect(books.count == 5)
        #expect(api.maximumConcurrentDetailLoads == 2)
        #expect(api.maximumSyncBookRequestCount == 5)
        #expect(progress.map(\.0) == [1, 2, 3, 4, 5])
        #expect(progress.allSatisfy { $0.1 == 5 })
    }

    @Test
    func ordinaryNetworkFailureDoesNotClearPersistedAuthorization() async throws {
        let api = WereadAPIProbe()
        api.renewalError = URLError(.notConnectedToInternet)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("wr_vid=1; wr_skey=old", forKey: "wereadCookie")
        defaults.set("1", forKey: "wereadUserId")
        defaults.set(0.0, forKey: "wereadCookieRenewedAt")
        let repository = WereadImportRepository(
            databaseManager: DatabaseManager(database: try AppDatabase.empty()),
            defaults: defaults,
            api: api
        )

        #expect(await repository.restoreAuthorization() == nil)
        #expect(defaults.string(forKey: "wereadCookie") == "wr_vid=1; wr_skey=old")
        #expect(defaults.string(forKey: "wereadUserId") == "1")
    }

    @Test
    func confirmedAuthorizationFailureClearsPersistedAuthorization() async throws {
        let api = WereadAPIProbe()
        api.renewalError = WereadImportError.authorizationExpired
        api.verifyError = WereadImportError.remote(code: -2013, message: "鉴权失败")
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("wr_vid=1; wr_skey=old", forKey: "wereadCookie")
        defaults.set("1", forKey: "wereadUserId")
        defaults.set(0.0, forKey: "wereadCookieRenewedAt")
        let repository = WereadImportRepository(
            databaseManager: DatabaseManager(database: try AppDatabase.empty()),
            defaults: defaults,
            api: api
        )

        #expect(await repository.restoreAuthorization() == nil)
        #expect(defaults.string(forKey: "wereadCookie") == nil)
        #expect(defaults.string(forKey: "wereadUserId") == nil)
    }

    @Test
    func bookmarkReviewChapterOrderingAndFinishedDateFallbackMatchAndroid() async throws {
        let api = WereadAPIProbe()
        api.usesSemanticFixture = true
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("wr_vid=1; wr_skey=old", forKey: "wereadCookie")
        defaults.set("1", forKey: "wereadUserId")
        defaults.set(Date().timeIntervalSince1970, forKey: "wereadCookieRenewedAt")
        let repository = WereadImportRepository(
            databaseManager: DatabaseManager(database: try AppDatabase.empty()),
            defaults: defaults,
            api: api,
            nowMillis: { 1_710_000_000_000 }
        )

        let book = try #require(try await repository.fetchImportBooks(
            authorization: .init(cookieHeader: "wr_vid=1; wr_skey=old", userID: "1"),
            bookIDs: ["semantic"],
            importsReadingTime: false
        ) { _, _ in }.first)

        #expect(book.notes.map(\.content) == ["早章节", "原文"])
        #expect(book.notes.map(\.idea) == ["", "想法"])
        #expect(book.notes.allSatisfy { $0.content != "书签" })
        #expect(book.reviews.map(\.content) == ["整书书评"])
        #expect(book.reviews.allSatisfy { $0.title.isEmpty })
        #expect(book.readStatusID == 3)
        #expect(book.readStatusChangedAt == 1_700_000_111_000)
        #expect(api.readInfoRequestCount == 1)
    }

    @Test
    func backfillUsesShelfAndNotebookUnionAndMarksSuccessfulCandidatesHandled() async throws {
        let api = WereadAPIProbe()
        api.shelfBackfillIDs = ["shelf-id"]
        api.notebookBackfillIDs = ["notebook-id"]
        api.backfillTitles = ["shelf-id": "书架历史书", "notebook-id": "笔记本历史书"]
        let defaults = try backfillDefaults()
        let database = try AppDatabase.empty()
        let shelfBookID = try await seedBackfillBook(database, title: "书架历史书")
        let notebookBookID = try await seedBackfillBook(database, title: "笔记本历史书")
        let repository = WereadImportRepository(
            databaseManager: DatabaseManager(database: database),
            defaults: defaults,
            api: api
        )

        #expect(try await repository.fetchBackfillPrompt().pendingCount == 2)
        let result = try await repository.performBackfill(
            authorization: .init(cookieHeader: "wr_vid=1; wr_skey=old", userID: "1")
        ) { _ in }
        let IDs = try await database.dbPool.read { db in
            (
                try BookRecord.fetchOne(db, key: shelfBookID)?.wereadBookId,
                try BookRecord.fetchOne(db, key: notebookBookID)?.wereadBookId
            )
        }

        #expect(result.bookIDMatchedCount == 2)
        #expect(result.partialFailureCount == 0)
        #expect(result.handledCandidateKeys.count == 2)
        #expect(IDs.0 == "shelf-id")
        #expect(IDs.1 == "notebook-id")
        #expect(api.syncedBackfillIDs == Set(["shelf-id", "notebook-id"]))
        #expect(try await repository.fetchBackfillPrompt().pendingCount == 0)
    }

    @Test
    func backfillPartialRemoteFailureKeepsOnlyUnresolvedCandidateForRetry() async throws {
        let api = WereadAPIProbe()
        api.shelfError = URLError(.timedOut)
        api.notebookBackfillIDs = ["resolved-id"]
        api.backfillTitles = ["resolved-id": "可回填历史书"]
        let defaults = try backfillDefaults()
        let database = try AppDatabase.empty()
        let resolvedBookID = try await seedBackfillBook(database, title: "可回填历史书")
        let retryBookID = try await seedBackfillBook(database, title: "远端暂缺历史书")
        let repository = WereadImportRepository(
            databaseManager: DatabaseManager(database: database),
            defaults: defaults,
            api: api
        )

        let result = try await repository.performBackfill(
            authorization: .init(cookieHeader: "wr_vid=1; wr_skey=old", userID: "1")
        ) { _ in }
        let IDs = try await database.dbPool.read { db in
            (
                try BookRecord.fetchOne(db, key: resolvedBookID)?.wereadBookId,
                try BookRecord.fetchOne(db, key: retryBookID)?.wereadBookId
            )
        }

        #expect(result.bookIDMatchedCount == 1)
        #expect(result.partialFailureCount == 1)
        #expect(result.handledCandidateKeys.count == 1)
        #expect(IDs.0 == "resolved-id")
        #expect(IDs.1 == "")
        #expect(try await repository.fetchBackfillPrompt().pendingCount == 1)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { throw WereadImportError.message("等待测试状态超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func backfillDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("wr_vid=1; wr_skey=old", forKey: "wereadCookie")
        defaults.set("1", forKey: "wereadUserId")
        defaults.set(Date().timeIntervalSince1970, forKey: "wereadCookieRenewedAt")
        return defaults
    }

    private func seedBackfillBook(_ database: AppDatabase, title: String) async throws -> Int64 {
        try await database.dbPool.write { db in
            var record = BookRecord()
            record.userId = try DatabaseOwnerResolver.resolveOwnerID(in: db)
            record.name = title
            record.rawName = title
            record.author = "历史作者"
            record.type = 1
            record.sourceId = 4
            record.readStatusId = 1
            try record.insert(db)
            return try #require(record.id)
        }
    }
}

private extension WereadImportBatchStatus {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

@MainActor
private final class WereadAPIProbe: WereadImportAPIClientProtocol {
    var renewalError: Error?
    var verifyError: Error?
    var usesSemanticFixture = false
    var shelfBackfillIDs: [String] = []
    var notebookBackfillIDs: [String] = []
    var backfillTitles: [String: String] = [:]
    var shelfError: Error?
    private(set) var maximumConcurrentDetailLoads = 0
    private(set) var maximumSyncBookRequestCount = 0
    private(set) var readInfoRequestCount = 0
    private(set) var syncedBackfillIDs = Set<String>()
    private var activeDetailLoads = 0

    func get(_ path: String, cookie _: String) async throws -> WereadImportAPIClient.Response {
        if path.contains("bookmarklist") {
            activeDetailLoads += 1
            maximumConcurrentDetailLoads = max(maximumConcurrentDetailLoads, activeDetailLoads)
            try await Task.sleep(for: .milliseconds(25))
            activeDetailLoads -= 1
            let id = path.components(separatedBy: "bookId=").last ?? "0"
            if usesSemanticFixture {
                return response(object: ["updated": [
                    ["type": 0, "markText": "书签", "range": "1-2", "chapterUid": 1, "createTime": 1_710_000_000],
                    ["type": 1, "markText": "早章节\n ", "range": "5-6", "chapterUid": 1, "createTime": 1_710_000_001]
                ]])
            }
            return response(object: ["updated": [[
                "type": 1,
                "markText": "note-\(id)",
                "range": "1-2",
                "chapterUid": 1,
                "createTime": 1_710_000_000
            ]]])
        }
        if path.contains("review/list") {
            guard usesSemanticFixture else { return response(object: ["reviews": []]) }
            return response(object: ["reviews": [
                ["review": ["type": 1, "abstract": "原文  ", "content": "想法\n", "range": "20-30", "chapterUid": 2, "createTime": 1_710_000_002]],
                ["review": ["type": 4, "content": "整书书评\n", "createTime": 1_710_000_003]],
                ["review": ["type": 4, "content": "  \n", "createTime": 1_710_000_004]]
            ]])
        }
        if path.contains("readinfo") {
            readInfoRequestCount += 1
            return usesSemanticFixture
                ? response(object: ["finishedDate": 0, "readDetail": ["lastReadingDate": 1_700_000_111]])
                : response(object: [:])
        }
        if path.contains("/api/user/notebook") {
            return response(object: [
                "books": notebookBackfillIDs.map { ["bookId": $0, "book": ["type": 1, "bookId": $0]] }
            ])
        }
        return response(object: [:])
    }

    func post(
        _ path: String,
        cookie _: String,
        json: [String: Any]
    ) async throws -> WereadImportAPIClient.Response {
        if path.contains("login/renewal") {
            if let renewalError { throw renewalError }
            return response(
                object: ["succ": 1],
                headers: ["Set-Cookie": "wr_skey=new; Max-Age=5400; Path=/; HttpOnly"]
            )
        }
        if path.contains("syncBook") {
            if let verifyError, (json["bookIds"] as? [String]) == ["39980421"] { throw verifyError }
            let ids = json["bookIds"] as? [String] ?? []
            maximumSyncBookRequestCount = max(maximumSyncBookRequestCount, ids.count)
            syncedBackfillIDs.formUnion(ids.filter { backfillTitles[$0] != nil })
            return response(object: [
                "books": ids.map { id in
                    [
                        "bookId": id,
                        "title": backfillTitles[id] ?? "book-\(id)",
                        "author": backfillTitles[id] == nil ? "author" : "历史作者",
                        "readUpdateTime": 1_710_000_000,
                        "finishReading": usesSemanticFixture ? 1 : 0,
                        "totalWords": 100
                    ] as [String: Any]
                }
            ])
        }
        if path.contains("chapterInfos") {
            if usesSemanticFixture {
                return response(object: ["data": [["updated": [
                    ["chapterUid": 2, "chapterIdx": 2, "level": 1, "title": "第二章", "anchors": []],
                    ["chapterUid": 1, "chapterIdx": 1, "level": 1, "title": "第一章", "anchors": []]
                ]]]])
            }
            return response(object: [
                "data": [[
                    "updated": [[
                        "chapterUid": 1,
                        "chapterIdx": 1,
                        "level": 1,
                        "title": "chapter",
                        "anchors": []
                    ]]
                ]]
            ])
        }
        return response(object: [:])
    }

    func shelfHTML(cookie _: String) async throws -> String {
        if let shelfError { throw shelfError }
        let state: [String: Any] = [
            "shelf": [
                "rawIndexes": shelfBackfillIDs.map { ["type": 1, "bookId": $0] }
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return "window.__INITIAL_STATE__=\(String(decoding: data, as: UTF8.self));(function()"
    }

    private func response(
        object: [String: Any],
        headers: [String: String] = [:]
    ) -> WereadImportAPIClient.Response {
        WereadImportAPIClient.Response(
            object: object,
            httpResponse: HTTPURLResponse(
                url: URL(string: "https://weread.qq.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }
}

@MainActor
private final class WereadRepositoryStub: WereadImportRepositoryProtocol {
    var failuresRemaining = 0
    var delay: Duration = .zero
    var ignoresCancellationForFirstBatch = false
    private(set) var fetchCount = 0

    func fetchPreferences() -> WereadImportPreferences { .default }
    func savePreferences(_: WereadImportPreferences) {}
    func restoreAuthorization() async -> WereadAuthorization? { nil }
    func validateAuthorization(cookieHeader: String) async throws -> WereadAuthorization {
        .init(cookieHeader: cookieHeader, userID: "1")
    }
    func clearAuthorization() async {}
    func fetchImportBookIDs(
        authorization _: WereadAuthorization,
        preferences _: WereadImportPreferences
    ) async throws -> [String] { [] }
    func fetchImportBooks(
        authorization _: WereadAuthorization,
        preferences _: WereadImportPreferences,
        progress _: @escaping (Int, Int) -> Void,
        warning _: @escaping (String) -> Void
    ) async throws -> [WereadImportBook] { [] }
    func fetchImportBooks(
        authorization _: WereadAuthorization,
        bookIDs: [String],
        importsReadingTime _: Bool,
        progress: @escaping (Int, Int) -> Void,
        warning _: @escaping (String) -> Void
    ) async throws -> [WereadImportBook] {
        try await fetch(bookIDs: bookIDs, progress: progress)
    }
    func fetchImportBooks(
        authorization _: WereadAuthorization,
        bookIDs: [String],
        importsReadingTime _: Bool,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [WereadImportBook] {
        try await fetch(bookIDs: bookIDs, progress: progress)
    }
    func matchLocalBooks(_ books: [WereadImportBook]) async throws -> [WereadImportBook] { books }
    func commitImport(books _: [WereadImportBook], progress _: @escaping (Int, Int) -> Void) async throws {}
    func fetchBackfillPrompt() async throws -> WereadBackfillPrompt { .init(pendingCount: 0, candidateKeys: []) }
    func performBackfill(
        authorization _: WereadAuthorization,
        progress _: @escaping (WereadBackfillProgress) -> Void
    ) async throws -> WereadBackfillResult {
        .init(
            bookIDMatchedCount: 0,
            chapterUIDUpdatedCount: 0,
            skippedCount: 0,
            partialFailureCount: 0,
            handledCandidateKeys: []
        )
    }

    private func fetch(
        bookIDs: [String],
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [WereadImportBook] {
        fetchCount += 1
        if ignoresCancellationForFirstBatch, bookIDs.first == "0" {
            do {
                try await Task.sleep(for: .milliseconds(160))
            } catch {
                // 模拟底层请求未响应结构化取消；ViewModel 的 generation 必须阻止旧结果回写。
            }
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw WereadImportError.message("fixture failure")
        }
        let books = bookIDs.enumerated().map { index, id in
            WereadImportBook(
                wereadBookID: id,
                title: "book-\(id)",
                rawTitle: "book-\(id)",
                author: "",
                coverURL: "",
                wereadUpdatedAt: Int64(index),
                readStatusID: 1
            )
        }
        for index in books.indices { progress(index + 1, books.count) }
        return books
    }
}
