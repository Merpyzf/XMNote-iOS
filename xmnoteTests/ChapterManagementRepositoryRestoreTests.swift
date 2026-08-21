/**
 * [INPUT]: 依赖 AppDatabase.empty、ChapterManagementRepository 与 ChapterStructureRestoreSnapshot
 * [OUTPUT]: 验证目录结构撤销的冲突令牌、导入身份保护与事务元数据恢复
 * [POS]: xmnoteTests 的目录管理 Repository 撤销 TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementRepositoryRestoreTests {
    @Test
    func restoreUsesExpectedCurrentStructureAndProtectsIdentityBeforeRestoring() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_101 }
        )
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: 56_001, name: "撤销测试书")
            let inputs: [(Int64, Int64, String, Int64, Int64, String)] = [
                (56_101, 56_102, "移动根", 1, 2, "目标根 / 移动根"),
                (56_102, 0, "目标根", 1, 1, "目标根"),
                (56_103, 56_101, "子章节", 1, 3, "目标根 / 移动根 / 子章节")
            ]
            for input in inputs {
                var chapter = ChapterRecord(
                    id: input.0,
                    bookId: 56_001,
                    parentId: input.1,
                    title: input.2,
                    remark: "",
                    chapterOrder: input.3,
                    isImport: 1,
                    chapterLevel: input.4,
                    sourceType: 0,
                    sourceUid: nil,
                    sourceAnchor: nil,
                    sourceOrder: 0,
                    sourcePath: input.5,
                    isStarred: 0,
                    createdDate: 1,
                    updatedDate: 2,
                    lastSyncDate: 3,
                    isDeleted: 0
                )
                try chapter.insert(db)
            }
        }
        let snapshot = ChapterStructureRestoreSnapshot(
            bookID: 56_001,
            restorePositions: [
                ChapterStructurePosition(chapterID: 56_101, parentID: 0, order: 1),
                ChapterStructurePosition(chapterID: 56_102, parentID: 0, order: 2),
                ChapterStructurePosition(chapterID: 56_103, parentID: 56_101, order: 1)
            ].sorted { $0.chapterID < $1.chapterID },
            expectedCurrentPositions: [
                ChapterStructurePosition(chapterID: 56_101, parentID: 56_102, order: 1),
                ChapterStructurePosition(chapterID: 56_102, parentID: 0, order: 1),
                ChapterStructurePosition(chapterID: 56_103, parentID: 56_101, order: 1)
            ].sorted { $0.chapterID < $1.chapterID }
        )

        try await repository.restoreChapterStructure(snapshot)

        let records = try await database.dbPool.read { db in
            try ChapterRecord.filter(Column("book_id") == 56_001).fetchAll(db)
        }
        let root = try #require(records.first { $0.id == 56_101 })
        let child = try #require(records.first { $0.id == 56_103 })
        #expect(root.parentId == 0)
        #expect(root.chapterOrder == 1)
        #expect(root.chapterLevel == 1)
        #expect(root.sourcePath == "移动根")
        #expect(root.sourceType == 2)
        #expect(root.sourceUid == "api_import_catalog:目标根$移动根")
        #expect(child.chapterLevel == 2)
        #expect(child.sourcePath == "移动根 / 子章节")
        #expect(child.sourceUid == "api_import_catalog:目标根$移动根$子章节")
        #expect(records.allSatisfy { $0.updatedDate == 1_101 })
    }
}
