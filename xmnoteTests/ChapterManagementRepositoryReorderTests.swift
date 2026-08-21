/**
 * [INPUT]: 依赖 AppDatabase.empty、ChapterManagementRepository 与 Room v44 book/chapter 表
 * [OUTPUT]: 验证同级重排的连续序号、导入身份、输入完整性与事务回滚
 * [POS]: xmnoteTests 的目录管理 Repository 同级排序 TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementRepositoryReorderTests {
    @Test
    func reorderPersistsContinuousOneBasedOrderAndProtectsImportedIdentity() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 901 }
        )
        try await seed(database: database, imported: true)

        _ = try await repository.reorderSiblings(
            bookID: 54_001,
            parentID: 0,
            orderedChapterIDs: [54_102, 54_101]
        )

        let rows = try await database.dbPool.read { db in
            // SQL 目的：读取重排后的顺序、来源身份和更新时间；涉及 chapter，按 book_id 过滤，按 order 稳定返回。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, chapter_order, source_type, source_uid, updated_date
                    FROM chapter WHERE book_id = 54001 ORDER BY chapter_order
                """
            )
        }
        #expect(rows.map { $0["id"] as Int64 } == [54_102, 54_101])
        #expect(rows.map { $0["chapter_order"] as Int64 } == [1, 2])
        #expect(rows.allSatisfy { ($0["source_type"] as Int64) == 2 })
        #expect(rows.map { $0["source_uid"] as String } == [
            "api_import_catalog:第二章",
            "api_import_catalog:第一章"
        ])
        #expect(rows.allSatisfy { ($0["updated_date"] as Int64) == 901 })
    }

    @Test
    func reorderRejectsMissingOrDuplicateIDsWithoutWriting() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 902 }
        )
        try await seed(database: database, imported: false)

        await #expect(throws: ChapterManagementError.invalidSiblingOrder) {
            _ = try await repository.reorderSiblings(
                bookID: 54_001,
                parentID: 0,
                orderedChapterIDs: [54_101, 54_101]
            )
        }

        let orders = try await storedOrders(database)
        #expect(orders == [54_101: 5, 54_102: 9])
    }

    @Test
    func reorderRollsBackEverySiblingWhenMiddleUpdateFails() async throws {
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 903 }
        )
        try await seed(database: database, imported: false)
        try await database.dbPool.write { db in
            // SQL 目的：在第二条 chapter_order 更新时强制失败，验证完整同级列表事务回滚。
            // 涉及表：chapter；按章节主键触发，不处理时间；副作用仅存在于隔离测试连接。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER fail_second_reorder
                    BEFORE UPDATE OF chapter_order ON chapter
                    WHEN NEW.id = 54101
                    BEGIN
                        SELECT RAISE(ABORT, 'forced reorder failure');
                    END
                """
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await repository.reorderSiblings(
                bookID: 54_001,
                parentID: 0,
                orderedChapterIDs: [54_102, 54_101]
            )
        }

        let orders = try await storedOrders(database)
        #expect(orders == [54_101: 5, 54_102: 9])
    }

    private func seed(database: AppDatabase, imported: Bool) async throws {
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: 54_001, name: "排序测试书")
            for (id, title, order) in [(54_101, "第一章", 5), (54_102, "第二章", 9)] {
                var chapter = ChapterRecord(
                    id: Int64(id),
                    bookId: 54_001,
                    parentId: 0,
                    title: title,
                    remark: "",
                    chapterOrder: Int64(order),
                    isImport: imported ? 1 : 0,
                    chapterLevel: 1,
                    sourceType: 0,
                    sourceUid: nil,
                    sourceAnchor: nil,
                    sourceOrder: 0,
                    sourcePath: title,
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

    private func storedOrders(_ database: AppDatabase) async throws -> [Int64: Int64] {
        try await database.dbPool.read { db in
            // SQL 目的：读取目标书全部章节当前顺序；涉及 chapter，按 book_id 过滤，不读时间，返回 id/order 字典。
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, chapter_order FROM chapter WHERE book_id = 54001"
            )
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["id"] as Int64, $0["chapter_order"] as Int64)
            })
        }
    }
}
