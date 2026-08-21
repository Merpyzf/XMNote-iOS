/**
 * [INPUT]: 依赖 AppDatabase.empty、ChapterManagementRepository 与 Room v44 book/chapter 表
 * [OUTPUT]: 验证章节星标切换的精确字段、统一时间与失效书籍写入保护
 * [POS]: xmnoteTests 的目录管理 Repository 星标 TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementRepositoryStarTests {
    @Test
    func starAndUnstarOnlyChangeStarStateAndUpdatedDate() async throws {
        let database = try AppDatabase.empty()
        let starRepository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 701 }
        )
        let unstarRepository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 702 }
        )
        try await seedBookAndChapter(database: database, bookID: 53_001, chapterID: 53_101)

        try await starRepository.setChapterStarred(bookID: 53_001, chapterID: 53_101, isStarred: true)
        let starred = try #require(try await database.dbPool.read { db in
            try ChapterRecord.fetchOne(db, key: 53_101)
        })
        #expect(starred.isStarred == 1)
        #expect(starred.updatedDate == 701)
        #expect(starred.title == "原章节")
        #expect(starred.sourcePath == "原章节")

        try await unstarRepository.setChapterStarred(bookID: 53_001, chapterID: 53_101, isStarred: false)
        let unstarred = try #require(try await database.dbPool.read { db in
            try ChapterRecord.fetchOne(db, key: 53_101)
        })
        #expect(unstarred.isStarred == 0)
        #expect(unstarred.updatedDate == 702)
    }

    @Test
    func starRejectsChapterWhenOwningBookIsUnavailable() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 801 }
        )
        try await seedBookAndChapter(database: database, bookID: 53_002, chapterID: 53_102)
        try await database.dbPool.write { db in
            // SQL 目的：模拟其他页面使书籍不可访问，验证星标写入被事务前置校验阻止。
            // 涉及表：book；按书籍主键精确限定 fixture。
            // 时间字段：本测试不修改时间字段。
            // 副作用：仅改变测试书籍的兼容删除标记。
            try db.execute(sql: "UPDATE book SET is_deleted = 1 WHERE id = 53002")
        }

        await #expect(throws: ChapterManagementError.invalidBook) {
            try await repository.setChapterStarred(
                bookID: 53_002,
                chapterID: 53_102,
                isStarred: true
            )
        }

        let chapter = try #require(try await database.dbPool.read { db in
            try ChapterRecord.fetchOne(db, key: 53_102)
        })
        #expect(chapter.isStarred == 0)
        #expect(chapter.updatedDate == 2)
    }

    @Test
    func starRejectsMissingChapterWithoutChangingAnyExistingChapter() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 999 }
        )
        try await seedBookAndChapter(database: database, bookID: 53_003, chapterID: 53_103)

        await #expect(throws: ChapterManagementError.chapterNotFound) {
            try await repository.setChapterStarred(
                bookID: 53_003,
                chapterID: 53_999,
                isStarred: true
            )
        }

        let chapter = try #require(try await database.dbPool.read { db in
            try ChapterRecord.fetchOne(db, key: 53_103)
        })
        #expect(chapter.isStarred == 0)
        #expect(chapter.updatedDate == 2)
    }

    private func seedBookAndChapter(
        database: AppDatabase,
        bookID: Int64,
        chapterID: Int64
    ) async throws {
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: bookID, name: "星标测试书")
            var chapter = ChapterRecord(
                id: chapterID,
                bookId: bookID,
                parentId: 0,
                title: "原章节",
                remark: "",
                chapterOrder: 1,
                isImport: 0,
                chapterLevel: 1,
                sourceType: 0,
                sourceUid: nil,
                sourceAnchor: nil,
                sourceOrder: 0,
                sourcePath: "原章节",
                isStarred: 0,
                createdDate: 1,
                updatedDate: 2,
                lastSyncDate: 3,
                isDeleted: 0
            )
            try chapter.insert(db)
        }
    }
}
