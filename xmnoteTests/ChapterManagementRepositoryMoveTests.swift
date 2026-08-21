/**
 * [INPUT]: 依赖 AppDatabase.empty、ChapterManagementRepository 与 Room v44 book/chapter 表
 * [OUTPUT]: 验证章节移动的父子关系、连续顺序、后代元数据、非法输入与事务回滚
 * [POS]: xmnoteTests 的目录管理 Repository 移动 TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementRepositoryMoveTests {
    @Test
    func moveRootUnderAnotherRootUpdatesEveryDescendantAndProtectsOldIdentity() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_001 }
        )
        try await seed(database: database, imported: true)

        _ = try await repository.moveChapters(
            bookID: 55_001,
            chapterIDs: [55_101],
            targetParentID: 55_102
        )

        let records = try await database.dbPool.read { db in
            try ChapterRecord
                .filter(Column("book_id") == 55_001)
                .order(Column("id"))
                .fetchAll(db)
        }
        let movedRoot = try #require(records.first { $0.id == 55_101 })
        let targetRoot = try #require(records.first { $0.id == 55_102 })
        let child = try #require(records.first { $0.id == 55_103 })

        #expect(targetRoot.parentId == 0)
        #expect(targetRoot.chapterOrder == 1)
        #expect(movedRoot.parentId == 55_102)
        #expect(movedRoot.chapterOrder == 1)
        #expect(movedRoot.chapterLevel == 2)
        #expect(movedRoot.sourcePath == "目标根 / 移动根")
        #expect(movedRoot.sourceType == 2)
        #expect(movedRoot.sourceUid == "api_import_catalog:移动根")
        #expect(child.parentId == 55_101)
        #expect(child.chapterLevel == 3)
        #expect(child.sourcePath == "目标根 / 移动根 / 子章节")
        #expect(child.sourceType == 2)
        #expect(child.sourceUid == "api_import_catalog:移动根$子章节")
        #expect(records.allSatisfy { $0.updatedDate == 1_001 })
    }

    @Test
    func moveRejectsSelfDescendantMissingAndDuplicateInputsWithoutWriting() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_002 }
        )
        try await seed(database: database, imported: false)

        await #expect(throws: ChapterManagementError.moveIntoOwnSubtree) {
            _ = try await repository.moveChapters(
                bookID: 55_001,
                chapterIDs: [55_101],
                targetParentID: 55_101
            )
        }
        await #expect(throws: ChapterManagementError.moveIntoOwnSubtree) {
            _ = try await repository.moveChapters(
                bookID: 55_001,
                chapterIDs: [55_101],
                targetParentID: 55_103
            )
        }
        await #expect(throws: ChapterManagementError.invalidSelection) {
            _ = try await repository.moveChapters(
                bookID: 55_001,
                chapterIDs: [55_101, 55_101],
                targetParentID: 55_102
            )
        }
        await #expect(throws: ChapterManagementError.invalidSelection) {
            _ = try await repository.moveChapters(
                bookID: 55_001,
                chapterIDs: [55_999],
                targetParentID: 55_102
            )
        }

        let positions = try await storedPositions(database)
        #expect(positions[55_101] == ChapterStructurePosition(chapterID: 55_101, parentID: 0, order: 4))
        #expect(positions[55_102] == ChapterStructurePosition(chapterID: 55_102, parentID: 0, order: 8))
        #expect(positions[55_103] == ChapterStructurePosition(chapterID: 55_103, parentID: 55_101, order: 3))
    }

    @Test
    func moveRollsBackParentOrdersAndMetadataWhenDescendantRefreshFails() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_003 }
        )
        try await seed(database: database, imported: false)
        try await database.dbPool.write { db in
            // SQL 目的：在后代 source_path 刷新时强制失败，验证父级、顺序与派生元数据同事务回滚。
            // 涉及表：chapter；按后代主键触发，不处理时间；副作用仅作用于隔离测试连接。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER fail_descendant_refresh
                    BEFORE UPDATE OF source_path ON chapter
                    WHEN NEW.id = 55103
                    BEGIN
                        SELECT RAISE(ABORT, 'forced metadata failure');
                    END
                """
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await repository.moveChapters(
                bookID: 55_001,
                chapterIDs: [55_101],
                targetParentID: 55_102
            )
        }

        let positions = try await storedPositions(database)
        #expect(positions[55_101]?.parentID == 0)
        #expect(positions[55_101]?.order == 4)
        #expect(positions[55_102]?.order == 8)
        #expect(positions[55_103]?.parentID == 55_101)
        let childPath = try await database.dbPool.read { db in
            // SQL 目的：确认回滚后后代来源路径保持原值；涉及 chapter，按主键过滤，不读时间，返回 source_path。
            try String.fetchOne(db, sql: "SELECT source_path FROM chapter WHERE id = 55103")
        }
        #expect(childPath == "移动根 / 子章节")
    }

    private func seed(database: AppDatabase, imported: Bool) async throws {
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: 55_001, name: "移动测试书")
            let inputs: [(Int64, Int64, String, Int64, Int64, String)] = [
                (55_101, 0, "移动根", 4, 1, "移动根"),
                (55_102, 0, "目标根", 8, 1, "目标根"),
                (55_103, 55_101, "子章节", 3, 2, "移动根 / 子章节")
            ]
            for input in inputs {
                var chapter = ChapterRecord(
                    id: input.0,
                    bookId: 55_001,
                    parentId: input.1,
                    title: input.2,
                    remark: "",
                    chapterOrder: input.3,
                    isImport: imported ? 1 : 0,
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
    }

    private func storedPositions(_ database: AppDatabase) async throws -> [Int64: ChapterStructurePosition] {
        try await database.dbPool.read { db in
            // SQL 目的：读取目标书全部章节结构位置；涉及 chapter，按 book_id 过滤，不读时间，返回 id/parent/order。
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, parent_id, chapter_order FROM chapter WHERE book_id = 55001"
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let id = row["id"] as Int64
                return (
                    id,
                    ChapterStructurePosition(
                        chapterID: id,
                        parentID: row["parent_id"] as Int64? ?? 0,
                        order: row["chapter_order"] as Int64? ?? 0
                    )
                )
            })
        }
    }
}
