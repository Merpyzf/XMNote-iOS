/**
 * [INPUT]: 依赖 AppDatabase.empty、ChapterManagementRepository 与 Room v44 book/chapter 表
 * [OUTPUT]: 验证章节重命名的标题规则、导入身份保护、后代路径刷新与统一事务时间
 * [POS]: xmnoteTests 的目录管理 Repository 重命名 TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementRepositoryRenameTests {
    @Test
    func renameImportedParentProtectsOriginalIdentityAndRefreshesDescendantPaths() async throws {
        let fixedNow: Int64 = 1_722_345_679_002
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { fixedNow }
        )
        let bookID: Int64 = 52_001
        let parentID: Int64 = 52_101
        let childID: Int64 = 52_102

        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: bookID, name: "目录测试书")
            var parent = importedChapter(
                id: parentID,
                bookID: bookID,
                parentID: 0,
                title: "旧父级",
                order: 1,
                level: 1,
                path: "旧父级"
            )
            try parent.insert(db)
            var child = importedChapter(
                id: childID,
                bookID: bookID,
                parentID: parentID,
                title: "旧子级",
                order: 1,
                level: 2,
                path: "旧父级 / 旧子级"
            )
            try child.insert(db)
        }

        try await repository.renameChapter(
            bookID: bookID,
            chapterID: parentID,
            title: "  新父级  "
        )

        let records = try await database.dbPool.read { db in
            try ChapterRecord
                .filter([parentID, childID].contains(Column("id")))
                .order(Column("id"))
                .fetchAll(db)
        }
        let parent = try #require(records.first { $0.id == parentID })
        let child = try #require(records.first { $0.id == childID })

        #expect(parent.title == "新父级")
        #expect(parent.sourceType == 2)
        #expect(parent.sourceUid == "api_import_catalog:旧父级")
        #expect(parent.sourcePath == "新父级")
        #expect(parent.updatedDate == fixedNow)

        #expect(child.title == "旧子级")
        #expect(child.sourceType == 2)
        #expect(child.sourceUid == "api_import_catalog:旧父级$旧子级")
        #expect(child.sourcePath == "新父级 / 旧子级")
        #expect(child.chapterLevel == 2)
        #expect(child.updatedDate == fixedNow)
    }

    @Test
    func renameAcceptsLongNonblankTitleBecauseAndroidHasNoLengthCap() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 100 }
        )
        let title = String(repeating: "章", count: 300)

        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: 52_011, name: "长标题")
            var chapter = importedChapter(
                id: 52_111,
                bookID: 52_011,
                parentID: 0,
                title: "旧标题",
                order: 1,
                level: 1,
                path: "旧标题",
                isImported: false
            )
            try chapter.insert(db)
        }

        try await repository.renameChapter(bookID: 52_011, chapterID: 52_111, title: title)

        let storedTitle = try await database.dbPool.read { db in
            // SQL 目的：读取重命名后的完整标题，证明 Android 没有额外长度上限。
            // 涉及表：chapter；按章节主键精确读取。
            // 时间字段：不读取时间字段。
            // 返回字段用途：与 300 字符输入逐字比较。
            try String.fetchOne(db, sql: "SELECT title FROM chapter WHERE id = 52111")
        }
        #expect(storedTitle == title)
    }

    @Test
    func renameRejectsEmptyMissingAndUnavailableTargetsWithoutWriting() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 4_444 }
        )
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: 52_021, name: "重命名边界测试书")
            var chapter = importedChapter(
                id: 52_121,
                bookID: 52_021,
                parentID: 0,
                title: "原标题",
                order: 1,
                level: 1,
                path: "原标题",
                isImported: false
            )
            try chapter.insert(db)
        }

        await #expect(throws: ChapterManagementError.emptyTitle) {
            try await repository.renameChapter(bookID: 52_021, chapterID: 52_121, title: "   ")
        }
        await #expect(throws: ChapterManagementError.chapterNotFound) {
            try await repository.renameChapter(bookID: 52_021, chapterID: 52_999, title: "新标题")
        }
        try await database.dbPool.write { db in
            // SQL 目的：模拟其他页面使书籍不可访问，验证重命名事务不会写章节。
            // 涉及表：book；按书籍主键精确限定 fixture。
            // 时间字段：本测试不修改时间字段。
            // 副作用：仅改变测试书籍的兼容删除标记。
            try db.execute(sql: "UPDATE book SET is_deleted = 1 WHERE id = 52021")
        }
        await #expect(throws: ChapterManagementError.invalidBook) {
            try await repository.renameChapter(bookID: 52_021, chapterID: 52_121, title: "新标题")
        }

        let chapter = try #require(try await database.dbPool.read { db in
            try ChapterRecord.fetchOne(db, key: 52_121)
        })
        #expect(chapter.title == "原标题")
        #expect(chapter.updatedDate == 2)
    }

    nonisolated private func importedChapter(
        id: Int64,
        bookID: Int64,
        parentID: Int64,
        title: String,
        order: Int64,
        level: Int64,
        path: String,
        isImported: Bool = true
    ) -> ChapterRecord {
        ChapterRecord(
            id: id,
            bookId: bookID,
            parentId: parentID,
            title: title,
            remark: "",
            chapterOrder: order,
            isImport: isImported ? 1 : 0,
            chapterLevel: level,
            sourceType: 0,
            sourceUid: nil,
            sourceAnchor: nil,
            sourceOrder: 0,
            sourcePath: path,
            isStarred: 0,
            createdDate: 1,
            updatedDate: 2,
            lastSyncDate: 3,
            isDeleted: 0
        )
    }
}
