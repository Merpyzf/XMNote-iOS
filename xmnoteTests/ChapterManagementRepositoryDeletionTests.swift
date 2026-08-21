/**
 * [INPUT]: 依赖 AppDatabase.empty、ChapterManagementRepository 与 Room v45 chapter/note/关系表
 * [OUTPUT]: 验证目录删除闭包、两种书摘处置、物理删除、剩余顺序与跨表事务回滚
 * [POS]: xmnoteTests 的目录管理 Repository 删除 TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct ChapterManagementRepositoryDeletionTests {
    @Test
    func deleteLeafWithoutNotesPhysicallyRemovesOnlyThatChapter() async throws {
        let fixture = try await makeFixture()

        let result = try await fixture.repository.deleteChapters(
            bookID: fixture.bookID,
            chapterIDs: [fixture.siblingID],
            noteDisposition: .detach
        )

        #expect(result.deletedChapterCount == 1)
        #expect(result.affectedNoteCount == 0)
        let siblingExists = try await fixture.database.dbPool.read { db in
            // SQL 目的：确认无书摘叶子章节已被物理删除；涉及 chapter，按主键过滤，不读时间，返回存在性断言。
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chapter WHERE id = ?)", arguments: [fixture.siblingID])
        }
        #expect(siblingExists == false)
    }

    @Test
    func deleteSubtreeDetachesNotesAndKeepsUnrelatedSiblingOrder() async throws {
        let fixture = try await makeFixture()

        let result = try await fixture.repository.deleteChapters(
            bookID: fixture.bookID,
            chapterIDs: [fixture.rootID],
            noteDisposition: .detach
        )

        #expect(result.deletedChapterCount == 2)
        #expect(result.affectedNoteCount == 2)
        #expect(result.unassignedNoteCount == 2)
        #expect(result.deletedNoteCount == 0)
        let state = try await fixture.database.dbPool.read { db in
            // SQL 目的：联合核对章节物理删除、书摘解绑/统一更新时间与剩余同级顺序不收敛。
            // 涉及表：chapter、note；均按 fixture 主键过滤，updated_date 为注入的 Unix 毫秒值。
            // 返回字段用途：逐表证明 detach 复合事务的最终状态。
            (
                chapters: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter WHERE id IN (?, ?)", arguments: [fixture.rootID, fixture.childID]),
                noteChapters: try Int64.fetchAll(db, sql: "SELECT chapter_id FROM note WHERE id IN (?, ?) ORDER BY id", arguments: [fixture.rootNoteID, fixture.childNoteID]),
                noteDates: try Int64.fetchAll(db, sql: "SELECT updated_date FROM note WHERE id IN (?, ?) ORDER BY id", arguments: [fixture.rootNoteID, fixture.childNoteID]),
                siblingOrder: try Int64.fetchOne(db, sql: "SELECT chapter_order FROM chapter WHERE id = ?", arguments: [fixture.siblingID])
            )
        }
        #expect(state.chapters == 0)
        #expect(state.noteChapters == [0, 0])
        #expect(state.noteDates == [1_201, 1_201])
        #expect(state.siblingOrder == 9)
    }

    @Test
    func deleteSubtreeWithNotesPhysicallyDeletesEveryNoteDependency() async throws {
        let fixture = try await makeFixture()

        let result = try await fixture.repository.deleteChapters(
            bookID: fixture.bookID,
            chapterIDs: [fixture.rootID],
            noteDisposition: .delete
        )

        #expect(result.deletedChapterCount == 2)
        #expect(result.affectedNoteCount == 2)
        #expect(result.unassignedNoteCount == 0)
        #expect(result.deletedNoteCount == 2)
        let counts = try await fixture.database.dbPool.read { db in
            // SQL 目的：确认 delete 处置物理清理书摘及全部依赖；涉及 note/tag_note/attach_image/note_import_hash。
            // 关键过滤：按两个受影响书摘主键；物理删除不读取时间字段；返回各表残留计数。
            (
                note: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE id IN (?, ?)", arguments: [fixture.rootNoteID, fixture.childNoteID]),
                tagNote: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_note WHERE note_id IN (?, ?)", arguments: [fixture.rootNoteID, fixture.childNoteID]),
                image: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attach_image WHERE note_id IN (?, ?)", arguments: [fixture.rootNoteID, fixture.childNoteID]),
                hash: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_import_hash WHERE note_id IN (?, ?)", arguments: [fixture.rootNoteID, fixture.childNoteID])
            )
        }
        #expect(counts.note == 0)
        #expect(counts.tagNote == 0)
        #expect(counts.image == 0)
        #expect(counts.hash == 0)
    }

    @Test
    func deleteNotesAlsoPhysicallyCleansHistoricalDeletedNotesWithoutCountingThem() async throws {
        let fixture = try await makeFixture()
        let historicalDeletedNoteID: Int64 = 57_203
        try await fixture.database.dbPool.write { db in
            var note = NoteRecord(
                id: historicalDeletedNoteID,
                bookId: fixture.bookID,
                chapterId: fixture.childID,
                content: "历史删除书摘",
                idea: "",
                position: "",
                positionUnit: 0,
                wereadRange: "",
                includeTime: 1,
                createdDate: 1,
                updatedDate: 2,
                lastSyncDate: 3,
                isDeleted: 1
            )
            try note.insert(db)
        }

        let result = try await fixture.repository.deleteChapters(
            bookID: fixture.bookID,
            chapterIDs: [fixture.rootID],
            noteDisposition: .delete
        )

        #expect(result.affectedNoteCount == 2)
        #expect(result.deletedNoteCount == 2)
        let historicalNoteExists = try await fixture.database.dbPool.read { db in
            // SQL 目的：确认物理删除章节前也清理不可见的历史删除书摘，避免 Room 外键残留。
            // 涉及表：note；按历史书摘主键精确读取。
            // 时间字段：不读取时间字段。
            // 返回字段用途：历史行不计入 Android 有效书摘结果，但必须随章节物理清理。
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM note WHERE id = ?)",
                arguments: [historicalDeletedNoteID]
            )
        }
        #expect(historicalNoteExists == false)
    }

    @Test
    func deleteDescendantsKeepsParentAndItsDirectNote() async throws {
        let fixture = try await makeFixture()

        let result = try await fixture.repository.deleteDescendants(
            bookID: fixture.bookID,
            parentID: fixture.rootID,
            noteDisposition: .detach
        )

        #expect(result.deletedChapterCount == 1)
        #expect(result.affectedNoteCount == 1)
        let relationships = try await fixture.database.dbPool.read { db in
            // SQL 目的：证明仅删后代、保留父章节直连书摘并解绑子章节书摘。
            // 涉及表：chapter、note；按 fixture 主键过滤，不读时间；返回存在性与 chapter_id。
            (
                rootExists: try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chapter WHERE id = ?)", arguments: [fixture.rootID]),
                childExists: try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chapter WHERE id = ?)", arguments: [fixture.childID]),
                rootNoteChapter: try Int64.fetchOne(db, sql: "SELECT chapter_id FROM note WHERE id = ?", arguments: [fixture.rootNoteID]),
                childNoteChapter: try Int64.fetchOne(db, sql: "SELECT chapter_id FROM note WHERE id = ?", arguments: [fixture.childNoteID])
            )
        }
        #expect(relationships.rootExists == true)
        #expect(relationships.childExists == false)
        #expect(relationships.rootNoteChapter == fixture.rootID)
        #expect(relationships.childNoteChapter == 0)
    }

    @Test
    func deleteMissingChapterFailsWithoutWriting() async throws {
        let fixture = try await makeFixture()

        await #expect(throws: ChapterManagementError.invalidSelection) {
            _ = try await fixture.repository.deleteChapters(
                bookID: fixture.bookID,
                chapterIDs: [999_999],
                noteDisposition: .detach
            )
        }

        let chapterCount = try await fixture.database.dbPool.read { db in
            // SQL 目的：确认不存在章节删除失败后整本书目录未变化；涉及 chapter，按 book_id 过滤，不读时间，返回计数。
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter WHERE book_id = ?", arguments: [fixture.bookID])
        }
        #expect(chapterCount == 3)
    }

    @Test
    func deleteRollsBackNotesDependenciesAndChaptersWhenFinalChapterDeleteFails() async throws {
        let fixture = try await makeFixture()
        try await fixture.database.dbPool.write { db in
            // SQL 目的：建立临时触发器，在最终章节 DELETE 中途强制失败以验证跨表事务回滚。
            // 涉及表：chapter；按 childID 触发，不处理时间；副作用仅存在于隔离测试连接。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER fail_chapter_physical_delete
                    BEFORE DELETE ON chapter
                    WHEN OLD.id = 57102
                    BEGIN
                        SELECT RAISE(ABORT, 'forced chapter delete failure');
                    END
                """
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await fixture.repository.deleteChapters(
                bookID: fixture.bookID,
                chapterIDs: [fixture.rootID],
                noteDisposition: .delete
            )
        }

        let counts = try await fixture.database.dbPool.read { db in
            // SQL 目的：失败后核对章节、书摘和三张依赖表全部恢复。
            // 涉及 chapter/note/tag_note/attach_image/note_import_hash；按 fixture 主键过滤，不读时间，返回残留计数。
            (
                chapter: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chapter WHERE id IN (?, ?)", arguments: [fixture.rootID, fixture.childID]),
                note: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE id IN (?, ?)", arguments: [fixture.rootNoteID, fixture.childNoteID]),
                tagNote: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_note WHERE note_id IN (?, ?)", arguments: [fixture.rootNoteID, fixture.childNoteID]),
                image: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attach_image WHERE note_id IN (?, ?)", arguments: [fixture.rootNoteID, fixture.childNoteID]),
                hash: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_import_hash WHERE note_id IN (?, ?)", arguments: [fixture.rootNoteID, fixture.childNoteID])
            )
        }
        #expect(counts.chapter == 2)
        #expect(counts.note == 2)
        #expect(counts.tagNote == 2)
        #expect(counts.image == 2)
        #expect(counts.hash == 2)
    }

    private struct Fixture {
        let database: AppDatabase
        let repository: ChapterManagementRepository
        let bookID: Int64 = 57_001
        let rootID: Int64 = 57_101
        let childID: Int64 = 57_102
        let siblingID: Int64 = 57_103
        let rootNoteID: Int64 = 57_201
        let childNoteID: Int64 = 57_202
    }

    private func makeFixture() async throws -> Fixture {
        let database = try AppDatabase.empty()
        let fixture = Fixture(
            database: database,
            repository: ChapterManagementRepository(
                databaseManager: DatabaseManager(database: database),
                now: { 1_201 }
            )
        )
        try await database.dbPool.write { db in
            try insertValidChapterTestBook(db, id: fixture.bookID, name: "删除测试书")
            let tagID: Int64 = 57_301
            var tag = TagRecord(
                id: tagID,
                userId: 1,
                name: "删除事务标签",
                color: 0,
                tagOrder: 1,
                type: 1,
                createdDate: 1,
                updatedDate: 2,
                lastSyncDate: 3,
                isDeleted: 0
            )
            try tag.insert(db)
            let chapterInputs: [(Int64, Int64, String, Int64, Int64, String)] = [
                (fixture.rootID, 0, "父章节", 4, 1, "父章节"),
                (fixture.childID, fixture.rootID, "子章节", 2, 2, "父章节 / 子章节"),
                (fixture.siblingID, 0, "保留章节", 9, 1, "保留章节")
            ]
            for input in chapterInputs {
                var chapter = ChapterRecord(
                    id: input.0,
                    bookId: fixture.bookID,
                    parentId: input.1,
                    title: input.2,
                    remark: "",
                    chapterOrder: input.3,
                    isImport: 0,
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
            for (noteID, chapterID) in [
                (fixture.rootNoteID, fixture.rootID),
                (fixture.childNoteID, fixture.childID)
            ] {
                var note = NoteRecord(
                    id: noteID,
                    bookId: fixture.bookID,
                    chapterId: chapterID,
                    content: "书摘 \(noteID)",
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
                var tagNote = TagNoteRecord(
                    id: noteID + 100,
                    tagId: tagID,
                    noteId: noteID,
                    createdDate: 1,
                    updatedDate: 2,
                    lastSyncDate: 3,
                    isDeleted: 0
                )
                try tagNote.insert(db)
                var image = AttachImageRecord(
                    id: noteID + 200,
                    noteId: noteID,
                    imageUrl: "image-\(noteID)",
                    createdDate: 1,
                    updatedDate: 2,
                    lastSyncDate: 3,
                    isDeleted: 0
                )
                try image.insert(db)
                try NoteImportHashRecord(
                    bookId: fixture.bookID,
                    contentHash: "hash-\(noteID)",
                    noteId: noteID
                ).insert(db)
            }
        }
        return fixture
    }
}
