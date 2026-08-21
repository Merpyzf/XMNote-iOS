/**
 * [INPUT]: 依赖 ChapterBatchImportParser、AppDatabase.empty 与 ChapterManagementRepository
 * [OUTPUT]: 验证手工批量目录录入的先序树、来源身份、连续顺序与统一时间
 * [POS]: xmnoteTests 的目录管理 Repository 批量录入 TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementRepositoryBatchImportTests {
    @Test
    func batchImportPersistsAndroidCatalogMetadataWithInjectedClock() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_301 }
        )
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: 58_001, name: "批量目录测试书")
        }
        let draft = try ChapterBatchImportParser.parse(
            "第一部\n\u{3000}\u{3000}第一章\n\u{3000}\u{3000}第二章"
        )

        let result = try await repository.importChapterBatch(bookID: 58_001, draft: draft)

        #expect(result.createdChapterCount == 3)
        #expect(result.reusedChapterCount == 0)
        let rows = try await database.dbPool.read { db in
            try ChapterRecord
                .filter(Column("book_id") == 58_001)
                .order(Column("id"))
                .fetchAll(db)
        }
        let root = try #require(rows.first { $0.title == "第一部" })
        let children = rows.filter { $0.parentId == root.id }.sorted { $0.chapterOrder < $1.chapterOrder }
        #expect(root.parentId == 0)
        #expect(root.chapterOrder == 1)
        #expect(root.chapterLevel == 1)
        #expect(root.isImport == 1)
        #expect(root.sourceType == 2)
        #expect(root.sourceUid == "")
        #expect(root.sourcePath == "第一部")
        #expect(root.createdDate == 1_301)
        #expect(children.map(\.title) == ["第一章", "第二章"])
        #expect(children.map(\.chapterOrder) == [1, 2])
        #expect(children.allSatisfy { $0.chapterLevel == 2 && $0.isImport == 1 && $0.sourceType == 2 })
        #expect(children.map(\.sourceUid) == ["", ""])
        #expect(children.map(\.sourcePath) == ["第一部 / 第一章", "第一部 / 第二章"])
        #expect(children.allSatisfy { $0.createdDate == 1_301 })
    }
}
