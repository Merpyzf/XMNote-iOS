/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的 V44 review、review_image、book、sort 表，依赖 UserDefaults 草稿存储与可注入毫秒时钟
 * [OUTPUT]: 对外提供 Android ReviewService/ReviewDraftService 的列表、草稿、排序、详情与写入基础能力
 * [POS]: Data 层网页书评专用仓储；独立复刻 Android Web 路径，不让 XMNoteWeb 接触 GRDB 或 UserDefaults
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// WebAttachImageDto 的 Data 层书评图片投影。
nonisolated struct DesktopWebReviewImageSnapshot: Sendable, Equatable {
    let id: Int64
    let url: String
}

/// WebBookSimpleDto 的 Data 层书评关联书籍投影；封面代理留给 App Adapter。
nonisolated struct DesktopWebReviewBookSnapshot: Sendable, Equatable {
    let id: Int64
    let name: String
    let cover: String
    let author: String
    let press: String
}

/// WebGlobalReviewDto 的 Data 层投影。
nonisolated struct DesktopWebGlobalReviewSnapshot: Sendable, Equatable {
    let id: Int64
    let title: String
    let content: String
    let createdTime: Int64
    let updatedTime: Int64
    let images: [DesktopWebReviewImageSnapshot]
    let book: DesktopWebReviewBookSnapshot
}

/// WebBookReviewDto 的 Data 层投影。
nonisolated struct DesktopWebBookReviewSnapshot: Sendable, Equatable {
    let id: Int64
    let title: String
    let content: String
    let wordCount: Int
    let createdTime: Int64
    let updatedTime: Int64
    let images: [DesktopWebReviewImageSnapshot]
}

/// 书评分页投影。
nonisolated struct DesktopWebReviewPageSnapshot<Item: Sendable & Equatable>: Sendable, Equatable {
    let items: [Item]
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
}

/// WebReviewDraftDto 的 Data 层投影。
nonisolated struct DesktopWebReviewDraftSnapshot: Codable, Sendable, Equatable {
    let bookID: Int64
    let reviewID: Int64
    let title: String
    let content: String
    let imageURLs: [String]
    let createdTime: Int64?
    let savedTimeMillis: Int64
}

/// Package 全局筛选到 Data 层的无框架输入。
nonisolated struct DesktopWebGlobalReviewFilterInput: Sendable, Equatable {
    let keyword: String
    let bookID: Int64
    let sortBy: String
    let sortOrder: String
    let sortMode: String
    let excludeIDs: [Int64]
}

/// Package 草稿写入请求到 Data 层的无框架输入。
nonisolated struct DesktopWebReviewDraftInput: Sendable, Equatable {
    let bookID: Int64
    let reviewID: Int64
    let title: String?
    let content: String?
    let imageURLs: [String]?
    let uploadedTicketIDs: [String]?
    let createdTime: Int64?
    let savedTimeMillis: Int64?
}

/// Package 创建书评请求到 Data 层的无框架输入。
nonisolated struct DesktopWebReviewCreateInput: Sendable, Equatable {
    let bookID: Int64
    let title: String?
    let content: String?
    let imageURLs: [String]?
    let uploadedTicketIDs: [String]?
    let createdTime: Int64?
}

/// Package 更新书评请求到 Data 层的无框架输入。
nonisolated struct DesktopWebReviewUpdateInput: Sendable, Equatable {
    let title: String?
    let content: String?
    let imageURLs: [String]?
    let uploadedTicketIDs: [String]?
    let createdTime: Int64?
}

/// WebReviewSortRuleDto 的 Data 层投影。
nonisolated struct DesktopWebReviewSortRuleSnapshot: Sendable, Equatable {
    let sortBy: String
    let sortOrder: String
}

/// 串行保存 review_draft_{bookId}_{reviewId}，避免并发 Web 请求覆盖同一草稿。
actor DesktopWebReviewDraftStore {
    private let defaults: UserDefaults
    private let keyPrefix = "review_draft_"

    /// 注入 App 共享设置域；actor 串行化同键读写，任务取消后不会继续执行尚未开始的存储写入。
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 读取草稿；损坏 JSON 与 Android Gson 解析失败一样按不存在处理。
    func draft(bookID: Int64, reviewID: Int64) -> DesktopWebReviewDraftSnapshot? {
        guard let json = defaults.string(forKey: key(bookID: bookID, reviewID: reviewID)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DesktopWebReviewDraftSnapshot.self, from: data)
    }

    /// 同步写入完整草稿 JSON，保证返回成功前同进程后续读取可见。
    func save(_ draft: DesktopWebReviewDraftSnapshot) throws {
        let data = try JSONEncoder().encode(draft)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("保存书评草稿失败")
        }
        defaults.set(json, forKey: key(bookID: draft.bookID, reviewID: draft.reviewID))
    }

    /// 删除精确 book/review 组合，不扫描同书其他草稿。
    func delete(bookID: Int64, reviewID: Int64) {
        defaults.removeObject(forKey: key(bookID: bookID, reviewID: reviewID))
    }

    private func key(bookID: Int64, reviewID: Int64) -> String {
        "\(keyPrefix)\(bookID)_\(reviewID)"
    }
}

/// 使用独立 SQL 与草稿 actor 复刻 Android WebReviewRepository、ReviewService 和 ReviewDraftService。
nonisolated struct DesktopWebReviewRepository: Sendable {
    static let reviewContentType: Int64 = 4
    static let ascCreated: Int64 = 1
    static let descCreated: Int64 = 2

    let database: AppDatabase
    let draftStore: DesktopWebReviewDraftStore
    let currentTimeMillis: @Sendable () -> Int64
    let commitUploadedTickets: @Sendable ([String]?, [String]) throws -> Void

    /// 固定数据库、草稿设置域与毫秒时钟；数据库事务和草稿 actor 分别保护各自状态。
    init(
        database: AppDatabase,
        draftStore: DesktopWebReviewDraftStore,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        commitUploadedTickets: @escaping @Sendable ([String]?, [String]) throws -> Void = { _, _ in }
    ) {
        self.database = database
        self.draftStore = draftStore
        self.currentTimeMillis = currentTimeMillis
        self.commitUploadedTickets = commitUploadedTickets
    }

    /// 查询有效书籍范围内的全局书评，随机模式只对 items 应用排除 ID，total 保持未排除计数。
    func globalReviews(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalReviewFilterInput
    ) async throws -> DesktopWebReviewPageSnapshot<DesktopWebGlobalReviewSnapshot> {
        let keyword = Self.kotlinTrimmed(filter.keyword)
        let normalizedExcludeIDs = Self.distinct(filter.excludeIDs).filter { $0 > 0 }
        let result = try await database.dbPool.read { db -> ([ReviewRecord], Int) in
            var itemConditions = ["r.is_deleted = 0", "b.is_deleted = 0"]
            var itemArguments: [DatabaseValue] = []
            var countConditions = itemConditions
            var countArguments: [DatabaseValue] = []
            if !keyword.isEmpty {
                let condition = "(r.title LIKE '%' || ? || '%' OR r.content LIKE '%' || ? || '%')"
                itemConditions.append(condition)
                countConditions.append(condition)
                itemArguments.append(contentsOf: [keyword.databaseValue, keyword.databaseValue])
                countArguments.append(contentsOf: [keyword.databaseValue, keyword.databaseValue])
            }
            if filter.bookID != 0 {
                itemConditions.append("r.book_id = ?")
                countConditions.append("r.book_id = ?")
                itemArguments.append(filter.bookID.databaseValue)
                countArguments.append(filter.bookID.databaseValue)
            }
            if !normalizedExcludeIDs.isEmpty {
                itemConditions.append(
                    "r.id NOT IN (\(Array(repeating: "?", count: normalizedExcludeIDs.count).joined(separator: ",")))"
                )
                itemArguments.append(contentsOf: normalizedExcludeIDs.map(\.databaseValue))
            }
            let order = filter.sortOrder == "asc" ? "ASC" : "DESC"
            let offset = filter.sortMode == "random" ? 0 : Self.safeOffset(page: page, pageSize: pageSize)

            // SQL 目的：查询全局书评页，并仅返回有效书籍下的有效书评。
            // 涉及表：review INNER JOIN book。
            // 关键过滤：标题/正文 LIKE、可选 book_id、items 独有的正数去重 excludeIds。
            // 时间字段：按 created_date 排序；word_count 改由响应同源的可见文字算法在内存排序；随机模式使用 SQLite RANDOM()。
            // 返回字段用途：GET /api/v1/reviews 的 items。
            let records: [ReviewRecord]
            if filter.sortMode != "random", filter.sortBy == "word_count" {
                let all = try ReviewRecord.fetchAll(
                    db,
                    sql: """
                        SELECT r.* FROM review r
                        INNER JOIN book b ON r.book_id = b.id
                        WHERE \(itemConditions.joined(separator: " AND "))
                        """,
                    arguments: StatementArguments(itemArguments)
                )
                records = Self.pageReviews(
                    Self.sortByVisibleWordCount(all, sortOrder: filter.sortOrder),
                    page: page,
                    pageSize: pageSize
                )
            } else {
                let orderClause = filter.sortMode == "random"
                    ? "ORDER BY RANDOM()"
                    : "ORDER BY r.created_date \(order), r.id ASC"
                records = try ReviewRecord.fetchAll(
                    db,
                    sql: """
                        SELECT r.* FROM review r
                        INNER JOIN book b ON r.book_id = b.id
                        WHERE \(itemConditions.joined(separator: " AND "))
                        \(orderClause)
                        LIMIT \(pageSize) OFFSET \(offset)
                        """,
                    arguments: StatementArguments(itemArguments)
                )
            }

            // SQL 目的：统计同一全局书评筛选的总数。
            // 涉及表：review INNER JOIN book。
            // 关键过滤：与 items 相同但故意忽略 excludeIds，复刻 Android random 翻页合同。
            // 时间字段：无。
            // 返回字段用途：GET /api/v1/reviews 的 pagination.total。
            let countSQL = """
                SELECT COUNT(*) FROM review r
                INNER JOIN book b ON r.book_id = b.id
                WHERE \(countConditions.joined(separator: " AND "))
                """
            let total = try Int.fetchOne(
                db,
                sql: countSQL,
                arguments: StatementArguments(countArguments)
            ) ?? 0
            return (records, total)
        }
        let items = try await globalSnapshots(result.0)
        return DesktopWebReviewPageSnapshot(
            items: items,
            page: page,
            pageSize: pageSize,
            total: result.1,
            totalPages: Self.totalPages(total: result.1, pageSize: pageSize)
        )
    }

    /// 读取书内分页书评；返回字数按 Android HTML 可见文本口径计算。
    func bookReviews(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebReviewPageSnapshot<DesktopWebBookReviewSnapshot> {
        try await requireActiveBook(bookID, error: .notFound("书籍不存在: \(bookID)"))
        let order = sortOrder == "asc" ? "ASC" : "DESC"
        let offset = Self.safeOffset(page: page, pageSize: pageSize)
        let result = try await database.dbPool.read { db -> ([ReviewRecord], Int) in
            // SQL 目的：查询指定有效书籍的书评页。
            // 涉及表：review。
            // 关键过滤：book_id 精确匹配、is_deleted=0。
            // 时间字段：创建时间直接排序；字数按响应同源的可见文字算法排序，id ASC 打破平局。
            // 返回字段用途：GET /books/{bookId}/reviews 的 items。
            let records: [ReviewRecord]
            if sortBy == "word_count" {
                let all = try ReviewRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM review WHERE book_id = ? AND is_deleted = 0",
                    arguments: [bookID]
                )
                records = Self.pageReviews(
                    Self.sortByVisibleWordCount(all, sortOrder: sortOrder),
                    page: page,
                    pageSize: pageSize
                )
            } else {
                records = try ReviewRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM review
                        WHERE book_id = ? AND is_deleted = 0
                        ORDER BY created_date \(order), id ASC
                        LIMIT \(pageSize) OFFSET \(offset)
                        """,
                    arguments: [bookID]
                )
            }
            // SQL 目的：统计指定书籍的有效书评数。
            // 涉及表：review。
            // 关键过滤：book_id 精确匹配、is_deleted=0。
            // 时间字段：无。
            // 返回字段用途：书内书评分页 total。
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review WHERE book_id = ? AND is_deleted = 0",
                arguments: [bookID]
            ) ?? 0
            return (records, total)
        }
        return DesktopWebReviewPageSnapshot(
            items: try await bookReviewSnapshots(result.0),
            page: page,
            pageSize: pageSize,
            total: result.1,
            totalPages: Self.totalPages(total: result.1, pageSize: pageSize)
        )
    }

    /// 读取有效书籍下的精确书评详情。
    func review(id: Int64) async throws -> DesktopWebBookReviewSnapshot {
        let record = try await requireReviewFromActiveBook(id: id)
        guard
              let snapshot = try await bookReviewSnapshots([record]).first else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("书评不存在: \(id)")
        }
        return snapshot
    }

    /// 读取书评排序规则；缺失或未知规则默认创建时间升序。
    func bookReviewSortRule(bookID: Int64) async throws -> DesktopWebReviewSortRuleSnapshot {
        try await requireActiveBook(bookID, error: .notFound("书籍不存在: \(bookID)"))
        return Self.mapSortRule(try await sortRule(bookID: bookID))
    }

    /// 插入或更新 review 排序记录并回读最终值。
    func updateBookReviewSortRule(
        bookID: Int64,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebReviewSortRuleSnapshot {
        try await requireActiveBook(bookID, error: .notFound("书籍不存在: \(bookID)"))
        guard sortBy == "create_time" else {
            throw DesktopWebCatalogRepositoryError.invalidArgument(
                "不支持的书评排序规则: \(sortBy)_\(sortOrder)"
            )
        }
        let rule = sortBy == "create_time" && sortOrder == "desc" ? Self.descCreated : Self.ascCreated
        let now = currentTimeMillis()
        try await database.dbPool.write { db in
            // SQL 目的：复刻 SortRepository.updateSortRuleInternal 的存在性分支。
            // 涉及表：sort。
            // 关键过滤：book_id、type=REVIEW、is_deleted=0 决定插入或更新；更新故意不限制 is_deleted。
            // 时间字段：新行 created_date 复刻 SortModelMapper 写当前毫秒、updated_date 保持 0；更新时只写 updated_date。
            // 副作用用途：PUT /books/{bookId}/reviews/sort-rule。
            let activeCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sort WHERE book_id = ? AND type = ? AND is_deleted = 0",
                arguments: [bookID, Self.reviewContentType]
            ) ?? 0
            if activeCount == 0 {
                var record = SortRecord()
                record.bookId = bookID
                record.type = Self.reviewContentType
                record.order = rule
                record.createdDate = now
                try record.insert(db)
            } else {
                try db.execute(
                    sql: "UPDATE sort SET updated_date = ?, `order` = ? WHERE book_id = ? AND type = ?",
                    arguments: [now, rule, bookID, Self.reviewContentType]
                )
            }
        }
        return Self.mapSortRule(try await sortRule(bookID: bookID))
    }

    /// 读取指定有效书籍的草稿。
    func reviewDraft(bookID: Int64, reviewID: Int64) async throws -> DesktopWebReviewDraftSnapshot? {
        try Self.validateDraftIDs(bookID: bookID, reviewID: reviewID)
        try await requireActiveBook(bookID, error: .invalidArgument("书籍不存在: \(bookID)"))
        return await draftStore.draft(bookID: bookID, reviewID: reviewID)
    }

    /// 归一化并保存草稿；全空请求删除旧草稿并返回空 DTO。
    func upsertReviewDraft(_ input: DesktopWebReviewDraftInput) async throws -> DesktopWebReviewDraftSnapshot {
        try Self.validateDraftIDs(bookID: input.bookID, reviewID: input.reviewID)
        try await requireActiveBook(
            input.bookID,
            error: .invalidArgument("书籍不存在: \(input.bookID)")
        )
        let title = Self.kotlinTrimmed(input.title ?? "")
        let content = DesktopWebRichHTMLCanonicalizer.canonicalize(input.content ?? "")
        let imageURLs = (input.imageURLs ?? []).map(Self.kotlinTrimmed).filter { !$0.isEmpty }
        let createdTime = input.createdTime.flatMap { $0 > 0 ? $0 : nil }
        let savedTime = input.savedTimeMillis.flatMap { $0 > 0 ? $0 : nil } ?? currentTimeMillis()
        let snapshot = DesktopWebReviewDraftSnapshot(
            bookID: input.bookID,
            reviewID: input.reviewID,
            title: title,
            content: content,
            imageURLs: imageURLs,
            createdTime: createdTime,
            savedTimeMillis: savedTime
        )
        if Self.isKotlinBlank(title),
           Self.isKotlinBlank(content),
           imageURLs.isEmpty,
           createdTime == nil {
            await draftStore.delete(bookID: input.bookID, reviewID: input.reviewID)
            return snapshot
        }
        try await draftStore.save(snapshot)
        do {
            try commitUploadedTickets(input.uploadedTicketIDs, imageURLs)
        } catch {
            await draftStore.delete(bookID: input.bookID, reviewID: input.reviewID)
            throw error
        }
        return snapshot
    }

    /// 删除指定草稿；不存在时保持幂等成功。
    func deleteReviewDraft(bookID: Int64, reviewID: Int64) async throws {
        try Self.validateDraftIDs(bookID: bookID, reviewID: reviewID)
        try await requireActiveBook(bookID, error: .invalidArgument("书籍不存在: \(bookID)"))
        await draftStore.delete(bookID: bookID, reviewID: reviewID)
    }
}

nonisolated extension DesktopWebReviewRepository {
    func globalSnapshots(_ records: [ReviewRecord]) async throws -> [DesktopWebGlobalReviewSnapshot] {
        guard !records.isEmpty else { return [] }
        let reviewIDs = records.compactMap(\.id)
        let bookIDs = Self.distinct(records.map(\.bookId))
        let context = try await database.dbPool.read { db -> ([Int64: BookRecord], [Int64: [DesktopWebReviewImageSnapshot]]) in
            let books = try BookRecord
                .filter(bookIDs.contains(Column("id")) && Column("is_deleted") == 0)
                .fetchAll(db)
            return (
                Dictionary(uniqueKeysWithValues: books.compactMap { book in book.id.map { ($0, book) } }),
                try Self.imageSnapshots(db: db, reviewIDs: reviewIDs)
            )
        }
        return records.compactMap { review in
            guard let id = review.id, let book = context.0[review.bookId], let bookID = book.id else { return nil }
            return DesktopWebGlobalReviewSnapshot(
                id: id,
                title: review.title ?? "",
                content: review.content ?? "",
                createdTime: review.createdDate,
                updatedTime: review.updatedDate,
                images: context.1[id] ?? [],
                book: DesktopWebReviewBookSnapshot(
                    id: bookID,
                    name: book.name,
                    cover: book.cover,
                    author: book.author,
                    press: book.press
                )
            )
        }
    }

    func bookReviewSnapshots(_ records: [ReviewRecord]) async throws -> [DesktopWebBookReviewSnapshot] {
        guard !records.isEmpty else { return [] }
        let imageMap = try await database.dbPool.read { db in
            try Self.imageSnapshots(db: db, reviewIDs: records.compactMap(\.id))
        }
        return records.compactMap { review in
            guard let id = review.id else { return nil }
            let title = review.title ?? ""
            let content = review.content ?? ""
            return DesktopWebBookReviewSnapshot(
                id: id,
                title: title,
                content: content,
                wordCount: Self.androidWordCount(title + content),
                createdTime: review.createdDate,
                updatedTime: review.updatedDate,
                images: imageMap[id] ?? []
            )
        }
    }

    func reviewRecord(id: Int64) async throws -> ReviewRecord? {
        try await database.dbPool.read { db in
            // SQL 目的：按主键读取一条有效书评。
            // 涉及表：review。
            // 关键过滤：id 精确匹配且 is_deleted=0；故意不关联 book。
            // 时间字段：原样返回。
            // 返回字段用途：详情、更新与删除前校验。
            try ReviewRecord.fetchOne(
                db,
                sql: "SELECT * FROM review WHERE id = ? AND is_deleted = 0",
                arguments: [id]
            )
        }
    }

    /// 读取仍隶属于有效书籍的书评，避免直接 ID 路径修改隐藏记录。
    func requireReviewFromActiveBook(id: Int64) async throws -> ReviewRecord {
        guard let review = try await reviewRecord(id: id) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("书评不存在: \(id)")
        }
        try await requireActiveBook(
            review.bookId,
            error: .invalidArgument("书评不存在: \(id)")
        )
        return review
    }

    func requireActiveBook(
        _ bookID: Int64,
        error: DesktopWebCatalogRepositoryError
    ) async throws {
        let exists = try await database.dbPool.read { db in
            // SQL 目的：验证 Web 写入或书内读取的目标书籍仍有效且不是占位书。
            // 涉及表：book。
            // 关键过滤：id 精确匹配、id!=0、is_deleted=0。
            // 时间字段：无。
            // 返回字段用途：复刻 requireActiveBook/checkBookExists。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book WHERE id = ? AND is_deleted = 0 AND id != 0",
                arguments: [bookID]
            ) ?? 0
        }
        guard exists > 0 else { throw error }
    }

    func sortRule(bookID: Int64) async throws -> Int64 {
        try await database.dbPool.read { db in
            // SQL 目的：读取书籍有效 review 排序记录。
            // 涉及表：sort。
            // 关键过滤：book_id、type=4、is_deleted=0；多行时保留 Room 未指定顺序的首行语义。
            // 时间字段：无。
            // 返回字段用途：GET/PUT sort-rule 回读。
            try Int64.fetchOne(
                db,
                sql: "SELECT `order` FROM sort WHERE book_id = ? AND type = ? AND is_deleted = 0 LIMIT 1",
                arguments: [bookID, Self.reviewContentType]
            ) ?? Self.ascCreated
        }
    }

    static func imageSnapshots(
        db: Database,
        reviewIDs: [Int64]
    ) throws -> [Int64: [DesktopWebReviewImageSnapshot]] {
        guard !reviewIDs.isEmpty else { return [:] }
        let images = try ReviewImageRecord
            .filter(reviewIDs.contains(Column("review_id")) && Column("is_deleted") == 0)
            .order(Column("order").asc)
            .fetchAll(db)
        return Dictionary(grouping: images, by: \.reviewId).mapValues { records in
            records.map { DesktopWebReviewImageSnapshot(id: $0.id ?? 0, url: $0.image) }
        }
    }

    static func mapSortRule(_ rule: Int64) -> DesktopWebReviewSortRuleSnapshot {
        rule == descCreated
            ? DesktopWebReviewSortRuleSnapshot(sortBy: "create_time", sortOrder: "desc")
            : DesktopWebReviewSortRuleSnapshot(sortBy: "create_time", sortOrder: "asc")
    }

    static func validateDraftIDs(bookID: Int64, reviewID: Int64) throws {
        guard bookID > 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("bookId 必须大于 0")
        }
        guard reviewID >= 0 else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("reviewId 不能小于 0")
        }
    }

    static func androidWordCount(_ html: String) -> Int {
        let plain = RichTextPlainTextExtractor.plainText(from: html)
        let scalars = plain.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, scalars[start].value <= 0x20 || scalars[start].value == 0x200D {
            start = scalars.index(after: start)
        }
        while start < end {
            let previous = scalars.index(before: end)
            guard scalars[previous].value <= 0x20 || scalars[previous].value == 0x200D else { break }
            end = previous
        }
        return String(scalars[start..<end]).unicodeScalars
            .filter { $0.value != 0x200D }
            .map(String.init)
            .joined()
            .utf16.count
    }

    static func safeOffset(page: Int, pageSize: Int) -> Int {
        let result = (max(page, 1) - 1).multipliedReportingOverflow(by: max(pageSize, 1))
        return result.overflow ? Int.max : result.partialValue
    }

    static func sortByVisibleWordCount(
        _ reviews: [ReviewRecord],
        sortOrder: String
    ) -> [ReviewRecord] {
        reviews.sorted { left, right in
            let leftCount = androidWordCount((left.title ?? "") + (left.content ?? ""))
            let rightCount = androidWordCount((right.title ?? "") + (right.content ?? ""))
            if leftCount != rightCount {
                return sortOrder == "asc" ? leftCount < rightCount : leftCount > rightCount
            }
            return (left.id ?? 0) < (right.id ?? 0)
        }
    }

    static func pageReviews(_ reviews: [ReviewRecord], page: Int, pageSize: Int) -> [ReviewRecord] {
        let offset = safeOffset(page: max(page, 1), pageSize: max(pageSize, 1))
        guard offset < reviews.count else { return [] }
        return Array(reviews[offset..<min(reviews.count, offset + min(pageSize, reviews.count - offset))])
    }

    static func totalPages(total: Int, pageSize: Int) -> Int {
        guard total > 0 else { return 0 }
        return total / pageSize + (total % pageSize == 0 ? 0 : 1)
    }

    static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
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
