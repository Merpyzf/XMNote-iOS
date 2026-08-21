/**
 * [INPUT]: 依赖 AppDatabase.empty、ContentRepository 与 Room v44 sort/book 表
 * [OUTPUT]: 验证 Chapter(type=1) 排序规则的持久化、类型隔离、合法值和失败回滚
 * [POS]: xmnoteTests 的目录分页排序 Repository TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterSortRepositoryTests {
    @Test
    func chapterPresentationUsesAndroidTreeOrderForBothCreatedRules() {
        let chapters = [
            makeChapter(id: 59_101, parentID: 0, order: 2),
            makeChapter(id: 59_102, parentID: 0, order: 1),
            makeChapter(id: 59_103, parentID: 59_102, order: 2),
            makeChapter(id: 59_104, parentID: 59_102, order: 1)
        ]

        #expect(
            BookWorkspaceChapterOrdering.preorder(
                chapters,
                rule: .createdDateAscending
            ).map(\.id) == [59_102, 59_104, 59_103, 59_101]
        )
        #expect(
            BookWorkspaceChapterOrdering.preorder(
                chapters,
                rule: .createdDateDescending
            ).map(\.id) == [59_101, 59_102, 59_103, 59_104]
        )
    }

    @Test
    func chapterSortWritesOnlyTypeOneAndKeepsEveryOtherContentRule() async throws {
        let database = try AppDatabase.empty()
        let repository = ContentRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_401 }
        )
        try await seedSortFixture(database)

        try await repository.updateBookContentSortRule(
            bookID: 59_001,
            type: .chapters,
            rule: .createdDateDescending
        )

        let rows = try await fetchSortRows(database)
        #expect(rows[1]?.order == 2)
        #expect(rows[1]?.created == 1_401)
        #expect(rows[1]?.updated == 1_401)
        #expect(rows[2]?.order == 4)
        #expect(rows[3]?.order == 2)
        #expect(rows[4]?.order == 1)
    }

    @Test
    func chapterSortRejectsNotePositionRulesWithoutChangingOldRule() async throws {
        let database = try AppDatabase.empty()
        let repository = ContentRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_402 }
        )
        try await seedSortFixture(database)

        await #expect(throws: ContentRepositoryError.invalidContentSortRule) {
            try await repository.updateBookContentSortRule(
                bookID: 59_001,
                type: .chapters,
                rule: .positionDescending
            )
        }

        let rows = try await fetchSortRows(database)
        #expect(rows[1] == nil)
        #expect(rows[2]?.order == 4)
        #expect(rows[3]?.order == 2)
        #expect(rows[4]?.order == 1)
    }

    @Test
    func chapterSortInsertFailureKeepsEveryPreviousContentRule() async throws {
        let database = try AppDatabase.empty()
        let repository = ContentRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_403 }
        )
        try await seedSortFixture(database)
        try await database.dbPool.write { db in
            // SQL 目的：在目录 sort(type=1) 插入时强制失败，验证其他类型和旧规则均不变。
            // 涉及表：sort；按 NEW.type 触发，不处理时间；副作用仅存在于隔离测试连接。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER fail_chapter_sort_insert
                    BEFORE INSERT ON sort
                    WHEN NEW.type = 1
                    BEGIN
                        SELECT RAISE(ABORT, 'forced sort failure');
                    END
                """
            )
        }

        await #expect(throws: (any Error).self) {
            try await repository.updateBookContentSortRule(
                bookID: 59_001,
                type: .chapters,
                rule: .createdDateDescending
            )
        }

        let rows = try await fetchSortRows(database)
        #expect(rows[1] == nil)
        #expect(rows[2]?.order == 4)
        #expect(rows[3]?.order == 2)
        #expect(rows[4]?.order == 1)
    }

    private func seedSortFixture(_ database: AppDatabase) async throws {
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: 59_001, name: "目录排序测试书")
            for (type, order) in [(2, 4), (3, 2), (4, 1)] {
                var record = SortRecord(
                    id: nil,
                    bookId: 59_001,
                    type: Int64(type),
                    order: Int64(order),
                    createdDate: 10,
                    updatedDate: 20,
                    lastSyncDate: 30,
                    isDeleted: 0
                )
                try record.insert(db)
            }
        }
    }

    private func makeChapter(id: Int64, parentID: Int64, order: Int64) -> BookDetailChapter {
        BookDetailChapter(
            id: id,
            parentID: parentID,
            title: "章节 \(id)",
            level: parentID == 0 ? 1 : 2,
            order: order,
            isStarred: false,
            noteCount: 0
        )
    }

    private struct StoredSort: Equatable {
        let order: Int64
        let created: Int64
        let updated: Int64
    }

    private func fetchSortRows(_ database: AppDatabase) async throws -> [Int64: StoredSort] {
        try await database.dbPool.read { db in
            // SQL 目的：读取目标书四个排序作用域的规则与更新时间；涉及 sort，按 book_id/is_deleted 过滤并按 id 稳定返回。
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT type, "order", created_date, updated_date
                    FROM sort WHERE book_id = 59001 AND is_deleted = 0
                """
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (
                    row["type"] as Int64,
                    StoredSort(
                        order: row["order"] as Int64,
                        created: row["created_date"] as Int64,
                        updated: row["updated_date"] as Int64
                    )
                )
            })
        }
    }
}
