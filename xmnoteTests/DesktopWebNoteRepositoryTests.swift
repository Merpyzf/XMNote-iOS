/**
 * [INPUT]: 依赖 AppDatabase.empty、GRDB Record 与 DesktopWebNoteRepository
 * [OUTPUT]: 验证 15 条 Note API 的查询、筛选、排序、富文本、写事务、批量操作与 Android 缺陷兼容边界
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android Web 书摘域当前可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct DesktopWebNoteRepositoryTests {
    @Test
    func bookListUsesChapterTreeAndFiltersDeletedTagsConsistently() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database)
        try noteSeedBook(database, id: 11, name: "Book")
        try noteSeedChapter(database, id: 101, bookID: 11, title: "Root", order: 1)
        try noteSeedChapter(database, id: 102, bookID: 11, parentID: 101, title: "Child", order: 1)
        try noteSeedTag(database, id: 201, name: " Active ")
        try noteSeedTag(database, id: 202, name: "Deleted", isDeleted: 1)
        try noteSeedNote(database, id: 301, bookID: 11, chapterID: 101, content: "A", created: 10)
        try noteSeedNote(database, id: 302, bookID: 11, chapterID: 102, content: "B", idea: "Idea", created: 20)
        try noteSeedNote(database, id: 303, bookID: 11, content: "C", created: 30)
        try noteSeedTagRelation(database, id: 401, tagID: 201, noteID: 301)
        try noteSeedTagRelation(database, id: 402, tagID: 202, noteID: 302)
        try noteSeedImage(database, id: 501, noteID: 303, url: "image")

        let chapterPage = try await repository.bookNotes(
            bookID: 11,
            page: 1,
            pageSize: 20,
            filter: noteBookFilter(chapterID: 101, sortOrder: "asc")
        )
        #expect(chapterPage.items.map(\.id) == [301, 302])
        #expect(chapterPage.chapterNoteCounts == [
            DesktopWebBookNoteChapterCountSnapshot(chapterID: 101, noteCount: 1),
            DesktopWebBookNoteChapterCountSnapshot(chapterID: 102, noteCount: 1)
        ])
        #expect(chapterPage.items[1].chapter?.parentTitle == "Root")

        let noTagPage = try await repository.bookNotes(
            bookID: 11,
            page: 1,
            pageSize: 20,
            filter: noteBookFilter(tagID: -1, sortOrder: "asc")
        )
        #expect(noTagPage.items.map(\.id) == [302, 303])
        let deletedTagPage = try await repository.bookNotes(
            bookID: 11,
            page: 1,
            pageSize: 20,
            filter: noteBookFilter(tagID: 202, sortOrder: "asc")
        )
        #expect(deletedTagPage.items.isEmpty)

        let filters = try await repository.bookNoteTagFilters(bookID: 11)
        #expect(filters.map(\.id) == [0, -1, -4, -2, -3, 201])
        #expect(filters.first { $0.id == -1 }?.noteCount == 2)
        #expect(filters.first { $0.id == -4 }?.noteCount == 1)
        #expect(filters.first { $0.id == 201 }?.name == "Active")
    }

    @Test
    func globalListUsesSQLiteLikeAndRandomExclusionOnlyForItems() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database)
        try noteSeedBook(database, id: 21, name: "Active", cover: "cover")
        try noteSeedBook(database, id: 22, name: "Deleted", isDeleted: 1)
        try noteSeedTag(database, id: 211, name: "Deleted", isDeleted: 1)
        try await database.dbPool.write { db in
            // 测试目的：把 iOS 空库自带的 id=0 章节改成 Android V44 历史 schema 中的占位标题。
            // 涉及表：chapter；关键过滤：只更新内部占位行 id=0；时间字段：不涉及。
            // 副作用用途：验证 Android Web 会把该占位标题投影为根章节 parentTitle。
            try db.execute(
                sql: "UPDATE chapter SET title = ? WHERE id = 0",
                arguments: ["empty empty"]
            )
        }
        try noteSeedChapter(database, id: 212, bookID: 21, title: "Root", order: 1)
        try noteSeedNote(database, id: 221, bookID: 21, content: "Alpha", created: 10)
        try noteSeedNote(database, id: 222, bookID: 21, chapterID: 212, content: "beta", created: 20)
        try noteSeedNote(database, id: 223, bookID: 22, content: "Hidden", created: 30)
        try noteSeedTagRelation(database, id: 231, tagID: 211, noteID: 221)

        let percent = try await repository.globalNotes(
            page: 1,
            pageSize: 20,
            filter: noteGlobalFilter(keyword: "%", sortOrder: "asc")
        )
        #expect(percent.items.map { $0.note.id } == [221, 222])
        #expect(percent.items.first?.book.name == "Active")

        let caseInsensitive = try await repository.globalNotes(
            page: 1,
            pageSize: 20,
            filter: noteGlobalFilter(keyword: "ALPHA")
        )
        #expect(caseInsensitive.items.map { $0.note.id } == [221])

        let random = try await repository.globalNotes(
            page: 1,
            pageSize: 20,
            filter: noteGlobalFilter(sortMode: "random", excludeIDs: [221])
        )
        #expect(random.total == 2)
        #expect(random.items.map { $0.note.id } == [222])
        #expect(random.items.first?.note.chapter?.parentTitle == "empty empty")

        let hasTag = try await repository.globalNotes(
            page: 1,
            pageSize: 20,
            filter: noteGlobalFilter(tagID: -4)
        )
        #expect(hasTag.items.isEmpty)
    }

    @Test
    func globalListLongNonMatchingTextDoesNotOverflowTheSearchMatcher() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database)
        try noteSeedBook(database, id: 24, name: "Long")
        try noteSeedNote(
            database,
            id: 241,
            bookID: 24,
            content: String(repeating: "长文本", count: 10_000),
            created: 10
        )

        let result = try await repository.globalNotes(
            page: 1,
            pageSize: 20,
            filter: noteGlobalFilter(keyword: "XMNOTE-NO-MATCH-9D9A")
        )

        #expect(result.items.isEmpty)
        #expect(result.total == 0)
    }

    @Test
    func sortRuleDefaultsUpdateAndDetailRejectsDeletedBooks() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database, currentTimeMillis: { 9_000 })
        try noteSeedBook(database, id: 31, name: "Empty")
        try noteSeedBook(database, id: 32, name: "Deleted", isDeleted: 1)
        try noteSeedNote(database, id: 321, bookID: 32, content: "Still readable", created: 100)

        #expect(try await repository.bookNoteSortRule(bookID: 31) == .init(sortBy: "position", sortOrder: "asc"))
        #expect(
            try await repository.updateBookNoteSortRule(bookID: 31, sortBy: "create_time", sortOrder: "desc")
                == .init(sortBy: "create_time", sortOrder: "desc")
        )
        let storedSort = try await database.dbPool.read { db in try SortRecord.fetchOne(db) }
        #expect(storedSort?.bookId == 31)
        #expect(storedSort?.type == 2)
        #expect(storedSort?.order == 2)
        #expect(storedSort?.createdDate == 9_000)
        #expect(storedSort?.updatedDate == 0)

        await expectNoteError(.invalidArgument("笔记不存在: 321")) {
            _ = try await repository.note(id: 321)
        }
        await expectNoteError(.notFound("书籍不存在: 32")) {
            _ = try await repository.bookNotes(
                bookID: 32,
                page: 1,
                pageSize: 20,
                filter: noteBookFilter()
            )
        }
    }

    @Test
    func createCanonicalizesRichHTMLSyncsProgressAndReturnsStoredImageIDs() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database, currentTimeMillis: { 9_000 })
        try noteSeedBook(
            database,
            id: 41,
            name: "Book",
            readPosition: 10,
            totalPagination: 100,
            currentPositionUnit: 2,
            positionUnit: 2
        )
        try noteSeedTag(database, id: 411, name: "Tag")

        let result = try await repository.createNote(.init(
            bookID: 41,
            chapterID: nil,
            content: "<mark data-color=\"#FDFBCA\">text</mark><script>bad</script>",
            idea: nil,
            position: "20",
            tagIDs: [411],
            imageURLs: ["first", "second"],
            uploadedTicketIDs: nil,
            createdTime: 123
        ))
        #expect(result.content == "<mark style=\"background-color:-132150\">text</mark>&lt;script>bad&lt;/script>")
        #expect(result.createdTime == 123)
        #expect(result.images.map(\.id) == [1, 2])
        #expect(result.tags.map(\.id) == [411])
        let storedImages = try noteFetchImages(database, noteID: result.id)
        #expect(storedImages.map(\.imageUrl) == ["first", "second"])
        #expect(storedImages.compactMap(\.id) == result.images.map(\.id))
        let book = try noteFetchBook(database, id: 41)
        #expect(book?.readPosition == 20)
        #expect(book?.updatedDate == 9_000)

        await expectNoteError(.invalidArgument("书摘内容、想法、图片不能同时为空")) {
            _ = try await repository.createNote(.init(
                bookID: 41,
                chapterID: nil,
                content: nil,
                idea: nil,
                position: nil,
                tagIDs: nil,
                imageURLs: [""],
                uploadedTicketIDs: nil,
                createdTime: nil
            ))
        }

        let duplicateTags = try await repository.createNote(.init(
            bookID: 41,
            chapterID: nil,
            content: "duplicate tag",
            idea: nil,
            position: nil,
            tagIDs: [411, 411],
            imageURLs: nil,
            uploadedTicketIDs: nil,
            createdTime: nil
        ))
        #expect(duplicateTags.tags.map(\.id) == [411])
        await expectNoteError(.invalidArgument("书籍不存在: 999")) {
            _ = try await repository.createNote(.init(
                bookID: 999,
                chapterID: nil,
                content: "content",
                idea: nil,
                position: nil,
                tagIDs: nil,
                imageURLs: nil,
                uploadedTicketIDs: nil,
                createdTime: nil
            ))
        }
    }

    @Test
    func updatePreservesNilClearsExplicitArraysAndDeleteMutatesDeletedBookNotes() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database, currentTimeMillis: { 9_000 })
        try noteSeedBook(database, id: 51, name: "Source")
        try noteSeedBook(database, id: 52, name: "Target", positionUnit: 1)
        try noteSeedBook(database, id: 53, name: "Deleted", isDeleted: 1)
        try noteSeedTag(database, id: 511, name: "Tag")
        try noteSeedNote(database, id: 521, bookID: 51, content: "Old", idea: "Idea", created: 100)
        try noteSeedNote(database, id: 522, bookID: 53, content: "Hidden", created: 100)
        try noteSeedTagRelation(database, id: 531, tagID: 511, noteID: 521)
        try noteSeedImage(database, id: 541, noteID: 521, url: "old-image")
        try noteSeedTagRelation(database, id: 532, tagID: 511, noteID: 522)
        try noteSeedImage(database, id: 542, noteID: 522, url: "hidden-image")

        let moved = try await repository.updateNote(id: 521, input: .init(
            bookID: 52,
            chapterID: nil,
            content: "New",
            idea: nil,
            position: nil,
            tagIDs: nil,
            imageURLs: nil,
            uploadedTicketIDs: nil,
            createdTime: nil
        ))
        #expect(moved.bookID == 52)
        #expect(moved.positionUnit == 1)
        #expect(moved.idea == "Idea")
        #expect(moved.tags.map(\.id) == [511])
        #expect(moved.images.map(\.url) == ["old-image"])

        let cleared = try await repository.updateNote(id: 521, input: .init(
            bookID: nil,
            chapterID: nil,
            content: nil,
            idea: nil,
            position: nil,
            tagIDs: [],
            imageURLs: [],
            uploadedTicketIDs: nil,
            createdTime: nil
        ))
        #expect(cleared.tags.isEmpty)
        #expect(cleared.images.isEmpty)
        #expect(try noteFetchActiveTagRelations(database, noteID: 521).isEmpty)
        #expect(try noteFetchImages(database, noteID: 521).isEmpty)

        await expectNoteError(.invalidArgument("笔记不存在: 999")) {
            _ = try await repository.updateNote(id: 999, input: .init(
                bookID: nil,
                chapterID: nil,
                content: "x",
                idea: nil,
                position: nil,
                tagIDs: nil,
                imageURLs: nil,
                uploadedTicketIDs: nil,
                createdTime: nil
            ))
        }

        await expectNoteError(.invalidArgument("笔记不存在: 522")) {
            try await repository.deleteNote(id: 522)
        }
        #expect(try noteFetch(database, id: 522)?.isDeleted == 0)
        #expect(try noteFetchTagRelations(database, noteID: 522).allSatisfy { $0.isDeleted == 0 })
        #expect(try noteFetchAllImages(database, noteID: 522).allSatisfy { $0.isDeleted == 0 })
    }

    @Test
    func batchMoveChapterSetTagsAndDeleteRejectMissingIDsBeforeWrites() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database, currentTimeMillis: { 9_000 })
        try noteSeedBook(database, id: 61, name: "Book")
        try noteSeedChapter(database, id: 611, bookID: 61, title: "Chapter")
        try noteSeedTag(database, id: 621, name: "A")
        try noteSeedTag(database, id: 622, name: "B")
        try noteSeedNote(database, id: 631, bookID: 61, content: "One", created: 1)
        try noteSeedNote(database, id: 632, bookID: 61, content: "Two", created: 2)
        try noteSeedTagRelation(database, id: 641, tagID: 621, noteID: 631)

        try await repository.batchMoveNotesToChapter(ids: [631, 632], chapterID: 611)
        #expect(try noteFetch(database, id: 631)?.chapterId == 611)
        #expect(try noteFetch(database, id: 632)?.chapterId == 611)
        await expectNoteError(.invalidArgument("章节不存在: 999")) {
            try await repository.batchMoveNotesToChapter(ids: [631], chapterID: 999)
        }

        await expectNoteError(.invalidArgument("部分笔记不存在: 999")) {
            try await repository.batchSetNoteTags(ids: [631, 999], tagIDs: [622], mode: "append")
        }
        #expect(try noteFetchActiveTagRelations(database, noteID: 631).map(\.tagId) == [621])
        try await repository.batchSetNoteTags(ids: [631], tagIDs: [622], mode: "append")
        #expect(Set(try noteFetchActiveTagRelations(database, noteID: 631).map(\.tagId)) == [621, 622])
        try await repository.batchSetNoteTags(ids: [631], tagIDs: [], mode: "replace")
        #expect(try noteFetchActiveTagRelations(database, noteID: 631).isEmpty)

        await expectNoteError(.invalidArgument("部分笔记不存在: 999")) {
            try await repository.batchDeleteNotes(ids: [631, 999])
        }
        #expect(try noteFetch(database, id: 631)?.isDeleted == 0)
        try await repository.batchDeleteNotes(ids: [631])
        #expect(try noteFetch(database, id: 631)?.isDeleted == 1)
        #expect(try noteFetch(database, id: 632)?.isDeleted == 0)
    }

    @Test
    func moveBookCopiesAncestorPathAndRejectsMissingNotesBeforeWrites() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database, currentTimeMillis: { 9_000 })
        try noteSeedBook(database, id: 71, name: "Source")
        try noteSeedBook(database, id: 72, name: "Target")
        try noteSeedChapter(database, id: 711, bookID: 71, title: "Root", level: 1, sourcePath: "Root")
        try noteSeedChapter(
            database,
            id: 712,
            bookID: 71,
            parentID: 711,
            title: "Child",
            level: 2,
            sourcePath: "Root / Child"
        )
        try noteSeedChapter(database, id: 721, bookID: 72, title: "Root", level: 1, sourcePath: "Root")
        try noteSeedNote(database, id: 731, bookID: 71, chapterID: 712, content: "Move", created: 1)

        await expectNoteError(.invalidArgument("部分笔记不存在: 999")) {
            try await repository.batchMoveNotesToBook(ids: [731, 999], targetBookID: 72)
        }
        #expect(try noteFetch(database, id: 731)?.bookId == 71)
        try await repository.batchMoveNotesToBook(ids: [731], targetBookID: 72)
        let moved = try #require(try noteFetch(database, id: 731))
        #expect(moved.bookId == 72)
        let targetChapter = try #require(try noteFetchChapter(database, id: moved.chapterId))
        #expect(targetChapter.parentId == 721)
        #expect(targetChapter.title == "Child")
        #expect(targetChapter.sourcePath == "Root / Child")
        #expect(targetChapter.sourceUid == "")
        #expect(targetChapter.sourceAnchor == "")
        #expect(targetChapter.createdDate == 9_000)
    }

    @Test
    func mergeCanonicalizesDraftValidatesPositionAndDeduplicatesOrder() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebNoteRepository(database: database, currentTimeMillis: { 9_000 })
        try noteSeedBook(database, id: 81, name: "Book", totalPagination: 100, positionUnit: 2)
        try noteSeedTag(database, id: 811, name: "A")
        try noteSeedTag(database, id: 812, name: "B")
        try noteSeedNote(database, id: 821, bookID: 81, content: "One", idea: "I1", position: "10", created: 1)
        try noteSeedNote(database, id: 822, bookID: 81, content: "Two", idea: "I2", position: "10", created: 2)
        try noteSeedTagRelation(database, id: 831, tagID: 811, noteID: 821)
        try noteSeedTagRelation(database, id: 832, tagID: 812, noteID: 822)
        try noteSeedImage(database, id: 841, noteID: 821, url: "one")
        try noteSeedImage(database, id: 842, noteID: 822, url: "two")

        await expectNoteError(.invalidArgument("阅读位置单位无效")) {
            _ = try await repository.batchMergeNotes(.init(
                ids: [821, 822],
                contentOrderedIDs: [822, 821, 822],
                ideaOrderedIDs: [821, 822],
                orderedIDs: nil,
                contentMergeRule: "new_two_line",
                ideaMergeRule: "follow",
                merged: .init(
                    content: "invalid",
                    idea: nil,
                    position: "99",
                    positionUnit: 99,
                    chapterID: nil,
                    tagIDs: nil,
                    imageURLs: nil,
                    uploadedTicketIDs: nil,
                    createdTime: 123
                )
            ))
        }
        let merged = try await repository.batchMergeNotes(.init(
            ids: [821, 822],
            contentOrderedIDs: [822, 821, 822],
            ideaOrderedIDs: [821, 822],
            orderedIDs: nil,
            contentMergeRule: "new_two_line",
            ideaMergeRule: "follow",
            merged: .init(
                content: "<mark data-color=\"#FDFBCA\">raw</mark>",
                idea: nil,
                position: "99",
                positionUnit: 2,
                chapterID: nil,
                tagIDs: nil,
                imageURLs: nil,
                uploadedTicketIDs: nil,
                createdTime: 123
            )
        ))
        #expect(merged.content == "<mark style=\"background-color:-132150\">raw</mark>")
        #expect(merged.idea == "I1I2")
        #expect(merged.position == "99")
        #expect(merged.positionUnit == 2)
        #expect(merged.createdTime == 123)
        #expect(Set(merged.tags.map(\.id)) == [811, 812])
        #expect(merged.images.map(\.url) == ["two", "one"])
        #expect(try noteFetch(database, id: 821)?.isDeleted == 1)
        #expect(try noteFetch(database, id: 822)?.isDeleted == 1)
        #expect(try noteFetch(database, id: merged.id)?.isDeleted == 0)
    }
}

private func noteBookFilter(
    chapterID: Int64 = 0,
    tagID: Int64 = 0,
    tagIDs: [Int64] = [],
    tagMode: String = "or",
    sortBy: String = "create_time",
    sortOrder: String = "desc"
) -> DesktopWebBookNoteFilterInput {
    .init(
        chapterID: chapterID,
        tagID: tagID,
        tagIDs: tagIDs,
        tagMode: tagMode,
        sortBy: sortBy,
        sortOrder: sortOrder
    )
}

private func noteGlobalFilter(
    keyword: String = "",
    bookID: Int64 = 0,
    bookIDs: [Int64] = [],
    tagID: Int64 = 0,
    tagIDs: [Int64] = [],
    tagMode: String = "or",
    sortBy: String = "create_time",
    sortOrder: String = "desc",
    sortMode: String = "latest",
    excludeIDs: [Int64] = []
) -> DesktopWebGlobalNoteFilterInput {
    .init(
        keyword: keyword,
        bookID: bookID,
        bookIDs: bookIDs,
        tagID: tagID,
        tagIDs: tagIDs,
        tagMode: tagMode,
        sortBy: sortBy,
        sortOrder: sortOrder,
        sortMode: sortMode,
        excludeIDs: excludeIDs
    )
}

private func expectNoteError(
    _ expected: DesktopWebCatalogRepositoryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("预期抛出 \(expected)")
    } catch let error as DesktopWebCatalogRepositoryError {
        #expect(error == expected)
    } catch {
        Issue.record("收到非预期错误：\(error)")
    }
}

private func noteSeedBook(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    cover: String = "",
    readPosition: Double = 0,
    totalPosition: Int64 = 0,
    totalPagination: Int64 = 0,
    currentPositionUnit: Int64 = 2,
    positionUnit: Int64 = 2,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            name: name,
            cover: cover,
            readPosition: readPosition,
            totalPosition: totalPosition,
            totalPagination: totalPagination,
            currentPositionUnit: currentPositionUnit,
            positionUnit: positionUnit,
            sourceId: 1,
            readStatusId: 1,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func noteSeedChapter(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    parentID: Int64 = 0,
    title: String,
    order: Int64 = 0,
    level: Int64 = 1,
    sourcePath: String? = nil
) throws {
    try database.dbPool.write { db in
        var record = ChapterRecord(
            id: id,
            bookId: bookID,
            parentId: parentID,
            title: title,
            chapterOrder: order,
            chapterLevel: level,
            sourcePath: sourcePath ?? title,
            createdDate: 100
        )
        try record.insert(db)
    }
}

private func noteSeedNote(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    chapterID: Int64 = 0,
    content: String,
    idea: String = "",
    position: String = "",
    positionUnit: Int64 = 2,
    created: Int64,
    updated: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = NoteRecord(
            id: id,
            bookId: bookID,
            chapterId: chapterID,
            content: content,
            idea: idea,
            position: position,
            positionUnit: positionUnit,
            wereadRange: "",
            includeTime: 1,
            createdDate: created,
            updatedDate: updated,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func noteSeedTag(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = TagRecord(
            id: id,
            userId: 1,
            name: name,
            color: 0,
            tagOrder: 0,
            type: 1,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func noteSeedTagRelation(
    _ database: AppDatabase,
    id: Int64,
    tagID: Int64,
    noteID: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = TagNoteRecord(
            id: id,
            tagId: tagID,
            noteId: noteID,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func noteSeedImage(
    _ database: AppDatabase,
    id: Int64,
    noteID: Int64,
    url: String,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = AttachImageRecord(
            id: id,
            noteId: noteID,
            imageUrl: url,
            createdDate: 100,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func noteFetch(_ database: AppDatabase, id: Int64) throws -> NoteRecord? {
    try database.dbPool.read { db in try NoteRecord.fetchOne(db, key: id) }
}

private func noteFetchBook(_ database: AppDatabase, id: Int64) throws -> BookRecord? {
    try database.dbPool.read { db in try BookRecord.fetchOne(db, key: id) }
}

private func noteFetchChapter(_ database: AppDatabase, id: Int64) throws -> ChapterRecord? {
    try database.dbPool.read { db in try ChapterRecord.fetchOne(db, key: id) }
}

private func noteFetchTagRelations(_ database: AppDatabase, noteID: Int64) throws -> [TagNoteRecord] {
    try database.dbPool.read { db in
        try TagNoteRecord.filter(Column("note_id") == noteID).order(Column("id")).fetchAll(db)
    }
}

private func noteFetchActiveTagRelations(_ database: AppDatabase, noteID: Int64) throws -> [TagNoteRecord] {
    try database.dbPool.read { db in
        try TagNoteRecord
            .filter(Column("note_id") == noteID && Column("is_deleted") == 0)
            .order(Column("id"))
            .fetchAll(db)
    }
}

private func noteFetchAllImages(_ database: AppDatabase, noteID: Int64) throws -> [AttachImageRecord] {
    try database.dbPool.read { db in
        try AttachImageRecord.filter(Column("note_id") == noteID).order(Column("id")).fetchAll(db)
    }
}

private func noteFetchImages(_ database: AppDatabase, noteID: Int64) throws -> [AttachImageRecord] {
    try database.dbPool.read { db in
        try AttachImageRecord
            .filter(Column("note_id") == noteID && Column("is_deleted") == 0)
            .order(Column("id"))
            .fetchAll(db)
    }
}
