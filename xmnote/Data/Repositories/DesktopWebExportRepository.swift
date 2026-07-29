/**
 * [INPUT]: 依赖 AppDatabase 与现有 Web Book/Note/Review/Related Repository 的 Android 对齐查询
 * [OUTPUT]: 对外提供导出书籍列表和单书完整只读快照
 * [POS]: Data 层 Web 导出数据边界；导出 Service 不直接访问 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated struct DesktopWebExportBundle: Sendable {
    let book: DesktopWebBookSnapshot
    let notes: [DesktopWebBookNoteSnapshot]
    let reviews: [DesktopWebBookReviewSnapshot]
    let related: [DesktopWebRelatedNoteSnapshot]
}

/// 组合已经逐接口对齐的 Web Repository，保证导出读取沿用同一软删除与排序语义。
nonisolated struct DesktopWebExportRepository: Sendable {
    private let database: AppDatabase
    private let bookRepository: DesktopWebBookRepository
    private let noteRepository: DesktopWebNoteRepository
    private let reviewRepository: DesktopWebReviewRepository
    private let relatedRepository: DesktopWebRelatedRepository

    init(database: AppDatabase, defaults: UserDefaults = .standard) {
        self.database = database
        bookRepository = DesktopWebBookRepository(database: database)
        noteRepository = DesktopWebNoteRepository(database: database)
        reviewRepository = DesktopWebReviewRepository(
            database: database,
            draftStore: DesktopWebReviewDraftStore(defaults: defaults)
        )
        relatedRepository = DesktopWebRelatedRepository(database: database)
    }

    /// 返回 Android BookRepository.queryAllBookIdsSuspend 的有效非占位书籍 ID 顺序。
    func allBookIDs() async throws -> [Int64] {
        try await database.dbPool.read { db in
            // SQL 目的：读取“未指定 bookIds”导出范围。
            // 涉及表：book。
            // 关键过滤：is_deleted=0 且排除 id=0 占位书籍；不按 owner 过滤以对齐 Android Web。
            // 时间字段：无。
            // 返回字段用途：本地/远端导出的单书迭代顺序。
            try Int64.fetchAll(db, sql: "SELECT id FROM book WHERE is_deleted = 0 AND id > 0 ORDER BY id ASC")
        }
    }

    /// 读取单书的书摘、书评和相关内容，分别沿用 Android 当前书内排序设置。
    func bundle(bookID: Int64, includeReview: Bool, includeRelated: Bool) async throws -> DesktopWebExportBundle {
        let book = try await bookRepository.book(id: bookID)
        let noteRule = try await noteRepository.bookNoteSortRule(bookID: bookID)
        let notes = try await noteRepository.bookNotes(
            bookID: bookID,
            page: 1,
            pageSize: 1_000_000,
            filter: .init(
                chapterID: 0,
                tagID: DesktopWebNoteRepository.noTagFilter,
                tagIDs: [],
                tagMode: "or",
                sortBy: noteRule.sortBy,
                sortOrder: noteRule.sortOrder
            )
        ).items
        let reviews: [DesktopWebBookReviewSnapshot]
        if includeReview {
            let rule = try await reviewRepository.bookReviewSortRule(bookID: bookID)
            reviews = try await reviewRepository.bookReviews(
                bookID: bookID,
                page: 1,
                pageSize: 1_000_000,
                sortBy: rule.sortBy,
                sortOrder: rule.sortOrder
            ).items
        } else {
            reviews = []
        }
        let related: [DesktopWebRelatedNoteSnapshot]
        if includeRelated {
            let rule = try await relatedRepository.sortRule(bookID: bookID)
            related = try await relatedRepository.allRelatedNotes(
                bookID: bookID,
                filter: .init(
                    categoryID: 0,
                    keyword: "",
                    sortBy: rule.sortBy,
                    sortOrder: rule.sortOrder
                )
            ).items
        } else {
            related = []
        }
        return .init(book: book, notes: notes, reviews: reviews, related: related)
    }

    /// 只读书名失败时按 Android safeBookName 回退到 ID 文案。
    func safeBookName(_ id: Int64) async -> String {
        (try? await bookRepository.book(id: id).name) ?? "ID:\(id)"
    }
}
