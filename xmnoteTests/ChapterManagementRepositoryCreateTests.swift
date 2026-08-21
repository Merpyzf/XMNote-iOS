/**
 * [INPUT]: 依赖 AppDatabase.empty、ChapterManagementRepository 与 Room v44 book/chapter 表
 * [OUTPUT]: 验证新增章节的 Android 对齐字段、父子关系、顺序、来源元数据与可注入时间
 * [POS]: xmnoteTests 的目录管理 Repository TDD 测试，先于目录管理生产实现演进
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementRepositoryCreateTests {
    @Test
    func createChildChapterPersistsAndroidAlignedFieldsWithInjectedClock() async throws {
        let fixedNow: Int64 = 1_722_345_678_901
        let database = try AppDatabase.empty()
        let databaseManager = DatabaseManager(database: database)
        let repository = ChapterManagementRepository(
            databaseManager: databaseManager,
            now: { fixedNow }
        )
        let bookID: Int64 = 51_001
        let parentID: Int64 = 51_101

        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: bookID, name: "目录测试书")
            var parent = ChapterRecord(
                id: parentID,
                bookId: bookID,
                parentId: 0,
                title: "第一部分",
                remark: "",
                chapterOrder: 4,
                isImport: 0,
                chapterLevel: 1,
                sourceType: 0,
                sourceUid: nil,
                sourceAnchor: nil,
                sourceOrder: 0,
                sourcePath: "第一部分",
                isStarred: 0,
                createdDate: 11,
                updatedDate: 12,
                lastSyncDate: 13,
                isDeleted: 0
            )
            try parent.insert(db)
        }

        let chapterID = try await repository.createChapter(
            bookID: bookID,
            parentID: parentID,
            title: "  第一章  "
        )

        let chapter = try #require(try await database.dbPool.read { db in
            try ChapterRecord.fetchOne(db, key: chapterID)
        })
        #expect(chapter.bookId == bookID)
        #expect(chapter.parentId == parentID)
        #expect(chapter.title == "第一章")
        #expect(chapter.remark == "")
        #expect(chapter.chapterOrder == 1)
        #expect(chapter.chapterLevel == 2)
        #expect(chapter.isImport == 0)
        #expect(chapter.sourceType == 0)
        #expect(chapter.sourceUid == nil)
        #expect(chapter.sourceAnchor == nil)
        #expect(chapter.sourceOrder == 0)
        #expect(chapter.sourcePath == "第一部分 / 第一章")
        #expect(chapter.isStarred == 0)
        #expect(chapter.createdDate == fixedNow)
        #expect(chapter.updatedDate == 0)
        #expect(chapter.lastSyncDate == 0)
        #expect(chapter.isDeleted == 0)
    }

    @Test
    func createRejectsEmptyTitleMissingParentAndUnavailableBookWithoutWriting() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_722_345_678_902 }
        )
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: 51_002, name: "创建边界测试书")
        }

        await #expect(throws: ChapterManagementError.emptyTitle) {
            _ = try await repository.createChapter(bookID: 51_002, parentID: 0, title: " \n ")
        }
        await #expect(throws: ChapterManagementError.parentNotFound) {
            _ = try await repository.createChapter(bookID: 51_002, parentID: 99_999, title: "章节")
        }
        await #expect(throws: ChapterManagementError.invalidBook) {
            _ = try await repository.createChapter(bookID: 99_998, parentID: 0, title: "章节")
        }

        let count = try await database.dbPool.read { db in
            // SQL 目的：确认三次失败创建均未向目标书籍写入章节。
            // 涉及表：chapter；按 book_id 精确限定 fixture。
            // 时间字段：不读取时间字段。
            // 返回字段用途：断言失败路径没有部分写入。
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter WHERE book_id = 51002") ?? 0
        }
        #expect(count == 0)
    }
}
