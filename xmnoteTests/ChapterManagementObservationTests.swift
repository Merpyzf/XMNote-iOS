/**
 * [INPUT]: 依赖 AppDatabase.empty、ChapterManagementRepository 的 GRDB observation 与目录写事务
 * [OUTPUT]: 验证新增、编辑、移动、重排、删除、星标、书摘计数及书籍失效都会刷新同一目录观察流
 * [POS]: xmnoteTests 的目录管理刷新闭环测试，证明页面无需额外事件总线即可获得数据库真相
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementObservationTests {
    @Test
    func observationRefreshesForEveryCatalogMutationAndFailsWhenBookBecomesUnavailable() async throws {
        let bookID: Int64 = 59_001
        let firstRootID: Int64 = 59_101
        let secondRootID: Int64 = 59_102
        let noteID: Int64 = 59_201
        let database = try AppDatabase.empty()
        let repository = ChapterManagementRepository(
            databaseManager: DatabaseManager(database: database),
            now: { 1_722_345_678_999 }
        )
        try await seed(
            database: database,
            bookID: bookID,
            firstRootID: firstRootID,
            secondRootID: secondRootID
        )

        var iterator = repository.observeSnapshot(bookID: bookID).makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.roots.map(\.id) == [firstRootID, secondRootID])

        let createdID = try await repository.createChapter(
            bookID: bookID,
            parentID: 0,
            title: "新增章节"
        )
        let afterCreate = try #require(try await iterator.next())
        #expect(afterCreate.node(id: createdID)?.item.title == "新增章节")

        try await repository.renameChapter(
            bookID: bookID,
            chapterID: createdID,
            title: "已编辑章节"
        )
        let afterRename = try #require(try await iterator.next())
        #expect(afterRename.node(id: createdID)?.item.title == "已编辑章节")

        try await repository.setChapterStarred(
            bookID: bookID,
            chapterID: createdID,
            isStarred: true
        )
        let afterStar = try #require(try await iterator.next())
        #expect(afterStar.node(id: createdID)?.item.isStarred == true)

        _ = try await repository.reorderSiblings(
            bookID: bookID,
            parentID: 0,
            orderedChapterIDs: [createdID, firstRootID, secondRootID]
        )
        let afterReorder = try #require(try await iterator.next())
        #expect(afterReorder.roots.map(\.id) == [createdID, firstRootID, secondRootID])
        #expect(afterReorder.roots.map(\.item.order) == [1, 2, 3])

        _ = try await repository.moveChapters(
            bookID: bookID,
            chapterIDs: [createdID],
            targetParentID: firstRootID
        )
        let afterMove = try #require(try await iterator.next())
        #expect(afterMove.node(id: createdID)?.item.parentID == firstRootID)
        #expect(afterMove.node(id: createdID)?.item.level == 2)
        #expect(afterMove.node(id: createdID)?.item.pathText == "第一章 / 已编辑章节")

        try await database.dbPool.write { db in
            var note = NoteRecord(
                id: noteID,
                bookId: bookID,
                chapterId: createdID,
                content: "目录观察书摘",
                idea: "",
                position: "",
                positionUnit: 0,
                wereadRange: "",
                includeTime: 1,
                createdDate: 1,
                updatedDate: 2,
                lastSyncDate: 3,
                isDeleted: 0
            )
            try note.insert(db)
        }
        let afterNoteInsert = try #require(try await iterator.next())
        #expect(afterNoteInsert.node(id: createdID)?.item.directNoteCount == 1)
        #expect(afterNoteInsert.node(id: firstRootID)?.item.descendantNoteCount == 1)

        let deletion = try await repository.deleteChapters(
            bookID: bookID,
            chapterIDs: [createdID],
            noteDisposition: .detach
        )
        let afterDelete = try #require(try await iterator.next())
        #expect(deletion.deletedChapterCount == 1)
        #expect(deletion.unassignedNoteCount == 1)
        #expect(afterDelete.node(id: createdID) == nil)
        #expect(afterDelete.unassignedNoteCount == 1)

        try await database.dbPool.write { db in
            // SQL 目的：模拟其他页面使当前书籍不可访问，验证目录观察流终止并向页面暴露错误。
            // 涉及表：book；通过主键限定当前测试书籍。
            // 时间字段：本测试只验证可访问状态，不修改时间字段。
            // 副作用：仅把兼容删除标记用于外部失效 fixture，不属于目录管理生产写入。
            try db.execute(
                sql: "UPDATE book SET is_deleted = 1 WHERE id = ?",
                arguments: [bookID]
            )
        }
        await #expect(throws: ChapterManagementError.invalidBook) {
            _ = try await iterator.next()
        }
    }

    private func seed(
        database: AppDatabase,
        bookID: Int64,
        firstRootID: Int64,
        secondRootID: Int64
    ) async throws {
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: bookID, name: "观察流测试书")
            for (id, title, order) in [
                (firstRootID, "第一章", Int64(4)),
                (secondRootID, "第二章", Int64(8))
            ] {
                var chapter = ChapterRecord(
                    id: id,
                    bookId: bookID,
                    parentId: 0,
                    title: title,
                    remark: "",
                    chapterOrder: order,
                    isImport: 0,
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
}
