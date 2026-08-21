/**
 * [INPUT]: 依赖统一导入 Hash、Kindle Parser、NoteImportRepository 与临时 Room v45 数据库
 * [OUTPUT]: 验证 Android v1/v2 Hash、Kindle 边界和两轮导入身份收敛
 * [POS]: xmnoteTests 的书摘导入核心一致性回归，覆盖解析结果之后的事务落库语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

struct NoteImportAlignmentTests {
    @Test
    func androidV1AndV2ContentHashesAreStable() {
        #expect(
            NoteImportContentHash.calculate(content: "书摘", idea: "想法")
                == "5d97458fd772660df8fadf375dcfcb2469ad662573537ab6b8b8610b227b6954"
        )
        #expect(
            NoteImportContentHash.calculate(content: "第一行\r\n第二行", idea: "")
                == NoteImportContentHash.calculate(content: "第一行\n第二行", idea: "")
        )
        #expect(NoteImportContentHash.calculate(content: "  ", idea: "\n") == nil)
        let ordered = NoteImportContentHash.calculate(
            content: "",
            idea: "",
            attachmentDigests: ["image-a", "image-b"]
        )
        #expect(ordered != nil)
        #expect(ordered != NoteImportContentHash.calculate(
            content: "",
            idea: "",
            attachmentDigests: ["image-b", "image-a"]
        ))
        #expect(
            NoteImportContentHash.calculate(
                content: "书摘",
                idea: "想法",
                attachmentDigests: ["ignored"]
            ) == NoteImportContentHash.calculate(content: "书摘", idea: "想法")
        )
    }

    @Test
    func kindleMixedLineEndingsMetadataNotesAndBookmarkMatchAndroid() async throws {
        let records = [
            kindleRecord(
                title: "\u{FEFF}Book With Spaces (Revised Edition) (Author Name)",
                metadata: "- Your Highlight on page 45 | location 100-200 | Added on Thursday, 1 February 2024 09:10:06",
                content: "First line\r\nSecond line"
            ),
            kindleRecord(
                title: "Book With Spaces (Revised Edition) (Author Name)",
                metadata: "- Your Note at location 110 | Added on Thursday, 1 February 2024 09:11:06",
                content: "First note",
                lineEnding: "\n"
            ),
            kindleRecord(
                title: "Book With Spaces (Revised Edition) (Author Name)",
                metadata: "- Your Note at location 120 | Added on Thursday, 1 February 2024 09:12:06",
                content: "Second note",
                lineEnding: "\r"
            ),
            "broken record without metadata",
            kindleRecord(
                title: "Book With Spaces (Revised Edition) (Author Name)",
                metadata: "- Your Bookmark at location 203 | Added on Monday, April 21, 2014 10:08:07 PM",
                content: ""
            )
        ]
        let data = Data(records.joined(separator: "\n==========\r\n").utf8)
        let book = try #require(
            try await KindleClippingsNoteImportParser().parse(data: data, fileExtension: "txt").first
        )
        let note = try #require(book.notes.first)

        #expect(book.name == "Book With Spaces (Revised Edition)")
        #expect(book.author == "Author Name")
        #expect(book.currentPositionUnit == 1)
        #expect(book.readPosition == 203)
        #expect(book.bookmarkModifiedTime > 0)
        #expect(book.notes.count == 1)
        #expect(note.content == "First line\nSecond line")
        #expect(note.idea == "First note\n\nSecond note")
        #expect(note.position == "100-200")
    }

    @Test
    func kindleKeepsAmbiguousAndStandaloneNotesInsteadOfMisbinding() async throws {
        let source = [
            kindleRecord(
                title: "示例书 (作者)",
                metadata: "- 您在位置 #100-200的标注 | 添加于 2026年4月2日星期四 下午12:19:38",
                content: "范围一"
            ),
            kindleRecord(
                title: "示例书 (作者)",
                metadata: "- 您在位置 #150-250的标注 | 添加于 2026年4月2日星期四 下午12:20:38",
                content: "范围二"
            ),
            kindleRecord(
                title: "示例书 (作者)",
                metadata: "- 您在位置 #175 的笔记 | 添加于 2026年4月2日星期四 下午12:21:38",
                content: "不可唯一绑定"
            ),
            kindleRecord(
                title: "示例书 (作者)",
                metadata: "- 您在位置 #999 的笔记 | 添加于 2026年4月2日星期四 上午12:19:38",
                content: "独立笔记"
            )
        ].joined(separator: "\n==========\n")
        let book = try #require(
            try await KindleClippingsNoteImportParser().parse(
                data: Data(source.utf8),
                fileExtension: "txt"
            ).first
        )

        #expect(book.notes.count == 4)
        #expect(book.notes.filter { $0.content.isEmpty }.map(\.idea) == ["不可唯一绑定", "独立笔记"])
    }

    @Test @MainActor
    func twoRoundImportKeepsHashChapterAndUserEditsConverged() async throws {
        let database = try AppDatabase.empty()
        let repository = NoteImportRepository(
            databaseManager: DatabaseManager(database: database),
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
        let chapter = NoteImportDraftChapter(
            title: "来源章节",
            level: 1,
            order: 7,
            pathTitles: ["来源章节"],
            sourceType: 1,
            sourceUID: "chapter-100",
            sourceOrder: 7,
            sourcePath: "来源章节"
        )
        var draft = NoteImportDraftBook()
        draft.name = "收敛测试书"
        draft.rawName = draft.name
        draft.type = 1
        draft.source = 4
        draft.positionUnit = 1
        draft.currentPositionUnit = 1
        draft.wereadBookID = "weread-100"
        draft.chapters = [chapter]
        draft.notes = [
            .init(
                content: "原始正文",
                idea: "原始想法",
                positionUnit: 1,
                createdTime: 1_710_000_000_000,
                wereadRange: "10-20",
                wereadChapterUID: 0,
                chapter: chapter
            ),
            .init(
                attachments: [
                    .init(imageURL: "https://example.com/a.png", digest: "digest-a", order: 1),
                    .init(imageURL: "https://example.com/b.png", digest: "digest-b", order: 2)
                ]
            )
        ]

        try await repository.commitImport(books: [.init(draft: draft)]) { _, _ in }
        let first = try await database.dbPool.read { db -> (Int64, Int64, Int64) in
            let bookID = try #require(BookRecord.filter(Column("weread_book_id") == "weread-100").fetchOne(db)?.id)
            let chapterID = try #require(ChapterRecord.filter(Column("book_id") == bookID).fetchOne(db)?.id)
            let noteID = try #require(NoteRecord.filter(Column("book_id") == bookID && Column("content") == "原始正文").fetchOne(db)?.id)
            return (bookID, chapterID, noteID)
        }
        try await database.dbPool.write { db in
            // SQL 目的：模拟用户编辑已导入书摘正文与想法，验证原始 Hash 能在二次导入时维持身份。
            // 涉及表：note；关键过滤：按首次导入 note.id 精确命中。
            // 时间字段：本测试只关注内容身份，不改动时间字段。
            // 副作用：后续重复导入不得覆盖用户编辑或新增重复书摘。
            try db.execute(
                sql: "UPDATE note SET content = ?, idea = ? WHERE id = ?",
                arguments: ["用户编辑正文", "用户编辑想法", first.2]
            )
            // SQL 目的：模拟用户重命名并排序已导入章节，验证来源身份与本地展示字段解耦。
            // 涉及表：chapter；关键过滤：按首次导入 chapter.id 精确命中。
            // 时间字段：本测试只关注本地编辑保持，不改动时间字段。
            // 副作用：后续重复导入必须复用原章节且保留标题与顺序。
            try db.execute(
                sql: "UPDATE chapter SET title = ?, chapter_order = ? WHERE id = ?",
                arguments: ["用户重命名章节", 99, first.1]
            )
        }

        try await repository.commitImport(
            books: [.init(draft: draft, targetBookID: first.0)]
        ) { _, _ in }

        let snapshot = try await database.dbPool.read { db in
            (
                try BookRecord.filter(Column("weread_book_id") == "weread-100").fetchCount(db),
                try NoteRecord.filter(Column("book_id") == first.0 && Column("is_deleted") == 0).fetchAll(db),
                try ChapterRecord.filter(Column("book_id") == first.0 && Column("is_deleted") == 0).fetchAll(db),
                try NoteImportHashRecord.filter(Column("book_id") == first.0).fetchAll(db)
            )
        }
        #expect(snapshot.0 == 1)
        #expect(snapshot.1.count == 2)
        #expect(snapshot.1.contains { $0.content == "用户编辑正文" && $0.idea == "用户编辑想法" })
        #expect(snapshot.2.count == 1)
        #expect(snapshot.2.first?.id == first.1)
        #expect(snapshot.2.first?.title == "用户重命名章节")
        #expect(snapshot.2.first?.chapterOrder == 99)
        #expect(snapshot.3.count == 2)
        #expect(Set(snapshot.3.map(\.noteId)) == Set(snapshot.1.compactMap(\.id)))
    }

    @Test @MainActor
    func hashIdentityMovesMergesAndDeletesInTheBusinessTransaction() async throws {
        let database = try AppDatabase.empty()
        let databaseManager = DatabaseManager(database: database)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let importRepository = NoteImportRepository(
            databaseManager: databaseManager,
            defaults: defaults
        )
        var draft = NoteImportDraftBook()
        draft.name = "Hash 生命周期源书"
        draft.rawName = draft.name
        draft.type = 1
        draft.source = 1
        draft.notes = [
            .init(content: "来源正文一", idea: "来源想法一"),
            .init(content: "来源正文二", idea: "来源想法二")
        ]
        try await importRepository.commitImport(books: [.init(draft: draft)]) { _, _ in }
        let sourceRawName = draft.rawName
        let source = try await database.dbPool.read { db -> (BookRecord, [NoteRecord]) in
            let fetchedBook = try BookRecord.filter(Column("raw_name") == sourceRawName).fetchOne(db)
            let book = try #require(fetchedBook)
            let notes = try NoteRecord
                .filter(Column("book_id") == book.id! && Column("is_deleted") == 0)
                .order(Column("id"))
                .fetchAll(db)
            return (book, notes)
        }
        let sourceIDs = try source.1.map { try #require($0.id) }
        let noteRepository = NoteRepository(
            databaseManager: databaseManager,
            userDefaults: defaults,
            s3UploadRepository: NoopS3UploadRepository()
        )
        let mergeDraft = try await noteRepository.fetchNoteMergeDraft(
            request: .init(sourceNoteIDs: sourceIDs)
        )
        let mergedID = try await noteRepository.mergeNotes(mergeDraft)

        let afterMerge = try await database.dbPool.read { db in
            (
                try NoteRecord.filter(sourceIDs.contains(Column("id"))).fetchCount(db),
                try NoteImportHashRecord.filter(Column("note_id") == mergedID).fetchAll(db)
            )
        }
        #expect(afterMerge.0 == 0)
        #expect(afterMerge.1.count == 2)

        let targetBookID = try await database.dbPool.write { db -> Int64 in
            var target = source.0
            target.id = nil
            target.name = "Hash 生命周期目标书"
            target.rawName = target.name
            target.wereadBookId = ""
            try target.insert(db)
            return try #require(target.id)
        }
        try await noteRepository.moveNotes(noteIDs: [mergedID], toBookID: targetBookID)
        let moved = try await database.dbPool.read { db in
            let fetchedNote = try NoteRecord.fetchOne(db, key: mergedID)
            return (
                try #require(fetchedNote),
                try NoteImportHashRecord.filter(Column("note_id") == mergedID).fetchAll(db)
            )
        }
        #expect(moved.0.bookId == targetBookID)
        #expect(moved.1.count == 2)
        #expect(moved.1.allSatisfy { $0.bookId == targetBookID })

        try await noteRepository.deleteNotes(noteIDs: [mergedID])
        let deleted = try await database.dbPool.read { db in
            (
                try NoteRecord.filter(Column("id") == mergedID).fetchCount(db),
                try NoteImportHashRecord.filter(Column("note_id") == mergedID).fetchCount(db)
            )
        }
        #expect(deleted.0 == 0)
        #expect(deleted.1 == 0)
    }

    @Test @MainActor
    func deletedSourceChapterIsSuppressedOnReimport() async throws {
        let database = try AppDatabase.empty()
        let repository = NoteImportRepository(
            databaseManager: DatabaseManager(database: database),
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
        let chapter = NoteImportDraftChapter(
            title: "不应复活",
            level: 1,
            pathTitles: ["不应复活"],
            sourceType: 1,
            sourceUID: "deleted-source-uid",
            sourceOrder: 1,
            sourcePath: "不应复活"
        )
        var draft = NoteImportDraftBook()
        draft.name = "删除章节抑制测试"
        draft.rawName = draft.name
        draft.type = 1
        draft.source = 4
        draft.wereadBookID = "deleted-source-book"
        draft.chapters = [chapter]
        draft.notes = [.init(
            content: "仍保留的书摘",
            idea: "",
            wereadRange: "10-20",
            chapter: chapter
        )]
        try await repository.commitImport(books: [.init(draft: draft)]) { _, _ in }
        let wereadBookID = draft.wereadBookID
        let IDs = try await database.dbPool.read { db -> (Int64, Int64) in
            let fetchedBook = try BookRecord.filter(Column("weread_book_id") == wereadBookID).fetchOne(db)
            let bookID = try #require(fetchedBook?.id)
            let fetchedChapter = try ChapterRecord.filter(Column("book_id") == bookID).fetchOne(db)
            let chapterID = try #require(fetchedChapter?.id)
            return (bookID, chapterID)
        }
        try await database.dbPool.write { db in
            // SQL 目的：构造 Android/旧备份章节 tombstone 前的书摘解绑状态，验证兼容读取不会复活来源章节。
            // 涉及表：note -> chapter；关键过滤：限定目标书与被删除章节。
            // 时间字段：兼容场景只模拟关系变化，不依赖时间字段。
            // 副作用：有效书摘保留并回到未分章节。
            try db.execute(
                sql: "UPDATE note SET chapter_id = 0 WHERE book_id = ? AND chapter_id = ?",
                arguments: [IDs.0, IDs.1]
            )
            // SQL 目的：构造 Android/旧备份遗留的来源章节 tombstone；生产新删除仍受 iOS 物理删除规则约束。
            // 涉及表：chapter；关键过滤：按被删除章节主键精确命中。
            // 时间字段：测试固定兼容状态，不依赖 updated_date。
            // 副作用：二次导入应识别其来源 UID 并抑制复活。
            try db.execute(
                sql: "UPDATE chapter SET is_deleted = 1 WHERE id = ?",
                arguments: [IDs.1]
            )
        }

        try await repository.commitImport(
            books: [.init(draft: draft, targetBookID: IDs.0)]
        ) { _, _ in }
        let snapshot = try await database.dbPool.read { db in
            (
                try ChapterRecord.filter(Column("book_id") == IDs.0 && Column("is_deleted") == 0).fetchCount(db),
                try ChapterRecord.filter(Column("book_id") == IDs.0).fetchCount(db),
                try NoteRecord.filter(Column("book_id") == IDs.0 && Column("is_deleted") == 0).fetchAll(db)
            )
        }
        #expect(snapshot.0 == 0)
        #expect(snapshot.1 == 1)
        #expect(snapshot.2.count == 1)
        #expect(snapshot.2.first?.chapterId == 0)
    }

    @Test @MainActor
    func kindleLegacyMatchingIsUniqueAndOnlyNewerBookmarkWins() async throws {
        let database = try AppDatabase.empty()
        let repository = NoteImportRepository(
            databaseManager: DatabaseManager(database: database),
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
        let seed = try await database.dbPool.write { db -> ([Int64], Int64) in
            let ownerID = try DatabaseOwnerResolver.resolveOwnerID(in: db)
            var result: [Int64] = []
            for author in ["作者甲", "作者乙"] {
                var record = BookRecord()
                record.userId = ownerID
                record.name = "旧 Kindle 书"
                record.rawName = "KindleLegacy"
                record.author = author
                record.sourceId = 2
                record.readStatusId = 1
                record.type = 1
                record.readPosition = author == "作者乙" ? 50 : 0
                record.bookMarkModifiedTime = author == "作者乙" ? 200 : 0
                try record.insert(db)
                result.append(try #require(record.id))
            }
            return (result, ownerID)
        }
        let candidateIDs = seed.0
        var draft = NoteImportDraftBook()
        draft.name = "Kindle Legacy"
        draft.rawName = draft.name
        draft.author = "作者乙"
        draft.type = 1
        draft.source = 2
        draft.positionUnit = 1
        draft.currentPositionUnit = 1

        let unique = try #require(try await repository.matchLocalBook(for: draft))
        #expect(unique.id == candidateIDs[1])

        try await database.dbPool.write { db in
            var duplicate = BookRecord()
            duplicate.userId = seed.1
            duplicate.name = "另一本旧 Kindle 书"
            duplicate.rawName = "\u{FEFF}KindleLegacy"
            duplicate.author = "作者乙"
            duplicate.sourceId = 2
            duplicate.readStatusId = 1
            duplicate.type = 1
            try duplicate.insert(db)
        }
        #expect(try await repository.matchLocalBook(for: draft) == nil)

        draft.readPosition = 80
        draft.bookmarkModifiedTime = 100
        try await repository.commitImport(
            books: [.init(draft: draft, targetBookID: candidateIDs[1])]
        ) { _, _ in }
        var bookmark = try await database.dbPool.read { db in
            let fetched = try BookRecord.fetchOne(db, key: candidateIDs[1])
            return try #require(fetched)
        }
        #expect(bookmark.readPosition == 50)
        #expect(bookmark.bookMarkModifiedTime == 200)

        draft.readPosition = 90
        draft.bookmarkModifiedTime = 300
        try await repository.commitImport(
            books: [.init(draft: draft, targetBookID: candidateIDs[1])]
        ) { _, _ in }
        bookmark = try await database.dbPool.read { db in
            let fetched = try BookRecord.fetchOne(db, key: candidateIDs[1])
            return try #require(fetched)
        }
        #expect(bookmark.readPosition == 90)
        #expect(bookmark.bookMarkModifiedTime == 300)
    }

    @Test @MainActor
    func manualReadingTimeBlocksTheEntireWereadDurationImport() async throws {
        let database = try AppDatabase.empty()
        let repository = NoteImportRepository(
            databaseManager: DatabaseManager(database: database),
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
        var draft = NoteImportDraftBook()
        draft.name = "手工阅读时长优先"
        draft.rawName = draft.name
        draft.type = 1
        draft.source = 4
        draft.wereadBookID = "manual-time-book"
        try await repository.commitImport(books: [.init(draft: draft)]) { _, _ in }
        let bookID = try await database.dbPool.read { db in
            let record = try BookRecord.filter(Column("weread_book_id") == "manual-time-book").fetchOne(db)
            return try #require(record?.id)
        }
        try await database.dbPool.write { db in
            var manual = ReadTimeRecordRecord()
            manual.bookId = bookID
            manual.startTime = 1_700_000_000_000
            manual.endTime = 1_700_000_600_000
            manual.elapsedSeconds = 600
            manual.status = 3
            manual.wereadReadDate = 0
            try manual.insert(db)
        }

        draft.wereadReadingDurations = [
            .init(date: 1_710_000_000_000, durationSeconds: 3_600)
        ]
        try await repository.commitImport(
            books: [.init(draft: draft, targetBookID: bookID)]
        ) { _, _ in }

        let durations = try await database.dbPool.read { db in
            try ReadTimeRecordRecord.filter(Column("book_id") == bookID && Column("is_deleted") == 0).fetchAll(db)
        }
        #expect(durations.count == 1)
        #expect(durations.first?.wereadReadDate == 0)
        #expect(durations.first?.elapsedSeconds == 600)
    }

    private func kindleRecord(
        title: String,
        metadata: String,
        content: String,
        lineEnding: String = "\r\n"
    ) -> String {
        [title, metadata, "", content].joined(separator: lineEnding)
    }
}

@MainActor
private final class NoopS3UploadRepository: S3UploadRepositoryProtocol {
    func stageImageData(_ data: Data, preferredFileExtension: String) async throws -> URL {
        throw S3StorageError.invalidImageData
    }
    func discardStagedFile(at localURL: URL) async {}
    func isStagedFileAvailable(at localURL: URL) async -> Bool { false }
    func uploadFile(
        localURL: URL,
        prefix: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> S3UploadResult {
        throw S3StorageError.invalidImageData
    }
    func testCurrentConfiguration() async throws {}
    func deleteObject(path: String) async throws {}
    func cancelCurrentUpload() {}
}
