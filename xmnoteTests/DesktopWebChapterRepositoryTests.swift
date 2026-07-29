/**
 * [INPUT]: 依赖 AppDatabase.empty、GRDB Record 与 DesktopWebChapterRepository
 * [OUTPUT]: 验证 17 条 Chapter API 的树聚合、星标、在线目录、导入、写入校验、软删除、排序、移动与异常边界
 * [POS]: iOS App 隔离数据库单元测试；锁定 Android Web 章节域当前可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
import Testing
@testable import xmnote

@MainActor
struct DesktopWebChapterRepositoryTests {
    @Test
    func readsBuildTreesLastUsedAndStarredGroupsWhileDroppingCyclesAndDeletedBooks() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebChapterRepository(database: database, currentTimeMillis: { 9_000 })
        try chapterSeedBook(database, id: 11, name: "  Active  ", cover: "/cover", author: "A", press: "P")
        try chapterSeedBook(database, id: 12, name: "Deleted", isDeleted: 1)
        try chapterSeed(database, id: 101, bookID: 11, title: "  Root  ", order: 2, isStarred: 1, updated: 100)
        try chapterSeed(database, id: 102, bookID: 11, parentID: 101, title: "Child", order: 1, isStarred: 1, updated: 200)
        try chapterSeed(database, id: 103, bookID: 11, parentID: 102, title: "Grandchild", order: 0)
        try chapterSeed(database, id: 104, bookID: 11, parentID: 999, title: "Orphan", order: 0)
        try chapterSeed(database, id: 105, bookID: 11, parentID: 106, title: "Cycle A")
        try chapterSeed(database, id: 106, bookID: 11, parentID: 105, title: "Cycle B")
        try chapterSeed(database, id: 201, bookID: 12, title: "Hidden", isStarred: 1, updated: 300)
        try chapterSeedNote(database, id: 1_001, bookID: 11, chapterID: 101, created: 10)
        try chapterSeedNote(database, id: 1_002, bookID: 11, chapterID: 102, created: 30)
        try chapterSeedNote(database, id: 1_003, bookID: 11, chapterID: 103, created: 20)
        try chapterSeedNote(database, id: 1_004, bookID: 11, chapterID: 103, created: 40, isDeleted: 1)

        let roots = try await repository.chapters(bookID: 11)
        #expect(roots.map(\.id) == [104, 101])
        let root = try #require(roots.first { $0.id == 101 })
        #expect(root.title == "Root")
        #expect(root.noteCount == 1)
        #expect(root.directNoteCount == 1)
        #expect(root.descendantNoteCount == 3)
        #expect(root.pathTitles == ["  Root  "])
        #expect(root.children.first?.level == 2)
        #expect(root.children.first?.children.first?.pathTitles == ["  Root  ", "Child", "Grandchild"])
        #expect(!roots.flatMap(collectChapterIDs).contains(105))

        let last = try #require(try await repository.lastUsedChapter(bookID: 11))
        #expect(last.id == 102)
        #expect(last.title == "Child")
        #expect(last.parentTitle == "Root")
        #expect(last.pathTitles == ["  Root  ", "Child"])

        let groups = try await repository.starredChapterGroups()
        #expect(groups.count == 1)
        #expect(groups.first?.book.id == 11)
        #expect(groups.first?.book.name == "Active")
        #expect(groups.first?.chapters.map(\.id) == [101, 102])
        #expect(groups.first?.chapters.last?.ancestorIDs == [101])
        #expect(groups.first?.chapterCount == 2)
        #expect(groups.first?.noteCount == 3)
        #expect(groups.first?.latestUpdatedTime == 200)
    }

    @Test
    func createUpdateStarAndBatchCreateRequireActiveBooks() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebChapterRepository(database: database, currentTimeMillis: { 9_000 })
        try chapterSeedBook(database, id: 21, name: "Active")
        try chapterSeedBook(database, id: 22, name: "Deleted", isDeleted: 1)
        try chapterSeed(database, id: 210, bookID: 21, title: "Parent", order: 4, level: 1, sourcePath: "Parent")
        try chapterSeed(database, id: 220, bookID: 22, title: "Hidden", order: 1, level: 1, sourcePath: "Hidden")

        let child = try await repository.createChapter(bookID: 21, title: "  Child  ", parentID: 210)
        #expect(child.title == "Child")
        #expect(child.parentID == 210)
        #expect(child.order == 1)
        let storedChild = try chapterFetch(database, id: child.id)
        #expect(storedChild?.chapterLevel == 2)
        #expect(storedChild?.sourcePath == "Parent / Child")
        #expect(storedChild?.sourceUid == "")
        #expect(storedChild?.sourceAnchor == "")
        #expect(storedChild?.createdDate == 9_000)
        #expect(storedChild?.updatedDate == 0)

        let updated = try await repository.updateChapter(id: 210, title: " Renamed ")
        #expect(updated.title == "Renamed")
        #expect(try chapterFetch(database, id: child.id)?.sourcePath == "Renamed / Child")
        #expect(try chapterFetch(database, id: child.id)?.updatedDate == 9_000)

        let starred = try await repository.updateChapterStarred(id: child.id, isStarred: true)
        #expect(starred.isStarred)
        #expect(starred.parentTitle == "Renamed")
        #expect(starred.pathTitles == ["Renamed", "Child"])

        do {
            _ = try await repository.updateChapter(id: 220, title: "Visible Mutation")
            Issue.record("删除书籍下的章节更新应被拒绝")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .notFound("书籍不存在: 22"))
        }
        do {
            _ = try await repository.updateChapterStarred(id: 220, isStarred: true)
            Issue.record("删除书籍下的章节星标应被 ActiveBookGuard 拒绝")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .notFound("书籍不存在: 22"))
        }

        let batch = try await repository.batchCreateChapters(
            bookID: 21,
            titles: [" A ", "   ", "B"],
            parentID: nil
        )
        #expect(batch.map(\.title) == ["A", "B"])
        #expect(batch.map(\.order) == [5, 6])
    }

    @Test
    func deleteAndBatchDeleteAreAtomicAndRejectUnknownIDs() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebChapterRepository(database: database, currentTimeMillis: { 9_000 })
        try chapterSeedBook(database, id: 31, name: "Book")
        try chapterSeed(database, id: 310, bookID: 31, title: "Root")
        try chapterSeed(database, id: 311, bookID: 31, parentID: 310, title: "Child")
        try chapterSeed(database, id: 312, bookID: 31, parentID: 311, title: "Grandchild")
        try chapterSeedNote(database, id: 3_101, bookID: 31, chapterID: 311, created: 1)
        try chapterSeedNote(database, id: 3_102, bookID: 31, chapterID: 312, created: 2, isDeleted: 1)

        try await repository.deleteChapter(id: 310)
        #expect(try chapterFetch(database, id: 310)?.isDeleted == 1)
        #expect(try chapterFetch(database, id: 311)?.isDeleted == 1)
        #expect(try chapterFetch(database, id: 312)?.isDeleted == 1)
        #expect(try chapterNoteState(database, id: 3_101) == ChapterNoteState(chapterID: 0, updated: 9_000))
        #expect(try chapterNoteState(database, id: 3_102) == ChapterNoteState(chapterID: 0, updated: 9_000))

        try chapterSeed(database, id: 999, bookID: 31, title: "Already Deleted", isDeleted: 1)
        try chapterSeedNote(database, id: 3_103, bookID: 31, chapterID: 999, created: 3)
        do {
            try await repository.batchDeleteChapters(ids: [999])
            Issue.record("已删除章节应被拒绝")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .notFound("部分章节不存在: 999"))
        }
        #expect(try chapterNoteState(database, id: 3_103) == ChapterNoteState(chapterID: 999, updated: 0))
    }

    @Test
    func reorderAndMoveValidateScopeThenAppendInRequestOrder() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebChapterRepository(database: database, currentTimeMillis: { 9_000 })
        try chapterSeedBook(database, id: 41, name: "Book")
        try chapterSeed(database, id: 410, bookID: 41, title: "Top A", order: 5)
        try chapterSeed(database, id: 411, bookID: 41, title: "Top B", order: 6)
        try chapterSeed(database, id: 412, bookID: 41, title: "Parent", order: 7)
        try chapterSeed(database, id: 413, bookID: 41, parentID: 412, title: "Child A", order: 2)
        try chapterSeed(database, id: 414, bookID: 41, parentID: 412, title: "Child B", order: 3)
        try chapterSeed(database, id: 415, bookID: 41, title: "Target", order: 8)

        try await repository.reorderParentChapters(bookID: 41, ids: [411, 410])
        #expect(try chapterFetch(database, id: 411)?.chapterOrder == 0)
        #expect(try chapterFetch(database, id: 410)?.chapterOrder == 1)
        #expect(try chapterFetch(database, id: 412)?.chapterOrder == 7)

        try await repository.reorderChildChapters(parentID: 412, ids: [414, 413])
        #expect(try chapterFetch(database, id: 414)?.chapterOrder == 0)
        #expect(try chapterFetch(database, id: 413)?.chapterOrder == 1)

        try await repository.moveToParent(chapterIDs: [413, 413, -1], parentID: 415)
        let moved = try #require(try chapterFetch(database, id: 413))
        #expect(moved.parentId == 415)
        #expect(moved.chapterOrder == 1)
        #expect(moved.chapterLevel == 2)
        #expect(moved.sourcePath == "Target / Child A")

        try await repository.moveOut(chapterIDs: [414])
        let movedOut = try #require(try chapterFetch(database, id: 414))
        #expect(movedOut.parentId == 0)
        #expect(movedOut.chapterOrder == 9)
        #expect(movedOut.chapterLevel == 1)
        #expect(movedOut.sourcePath == "Child B")

        do {
            try await repository.reorderChildChapters(parentID: 412, ids: [410])
            Issue.record("非直接子章节不应进入子章节排序")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .invalidArgument("章节不属于目标父章节: 410"))
        }
        do {
            try await repository.moveToParent(chapterIDs: [415], parentID: 413)
            Issue.record("父章节不应移动到自身后代下")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .invalidArgument("不能移动章节到自身子章节下"))
        }
    }

    @Test
    func onlineCandidatesUseExactFuzzywuzzyOrderAndCatalogNormalization() async throws {
        let database = try AppDatabase.empty()
        let chapters = DesktopWebChapterRepository(database: database)
        try chapterSeedBook(database, id: 51, name: "Book", doubanID: 321)
        let recorder = ChapterWenquQueryRecorder()
        let repository = DesktopWebChapterOnlineRepository(
            chapterRepository: chapters,
            fetchBooks: { query in
                await recorder.append(query)
                switch query {
                case .keyword:
                    return DesktopWebWenquResponse(
                        count: 4,
                        books: [
                            .init(
                                title: "axc",
                                author: "",
                                press: "P1",
                                pubdate: "2024-01",
                                image: "C1",
                                catalog: " \u{200B} ",
                                doubanId: 1
                            ),
                            .init(
                                title: "abc",
                                author: "",
                                press: "P2",
                                pubdate: "2024-02",
                                image: "C2",
                                catalog: nil,
                                doubanId: 2
                            ),
                            .init(
                                title: "abc",
                                author: "",
                                press: "P3",
                                pubdate: "2024-03",
                                image: "C3",
                                catalog: "Chapter",
                                doubanId: 3
                            ),
                            .init(
                                title: "ignored",
                                author: "",
                                press: nil,
                                pubdate: nil,
                                image: nil,
                                catalog: nil,
                                doubanId: 0
                            )
                        ]
                    )
                case .doubanID:
                    return DesktopWebWenquResponse(
                        count: 2,
                        books: [
                            .init(
                                title: "Wrong",
                                author: nil,
                                press: nil,
                                pubdate: nil,
                                image: nil,
                                catalog: "Wrong catalog",
                                doubanId: 999
                            ),
                            .init(
                                title: "Exact",
                                author: nil,
                                press: nil,
                                pubdate: nil,
                                image: nil,
                                catalog: " \u{00A0}第一章\u{200B} \n\n\u{200C}第二章\u{200D}\u{FEFF} ",
                                doubanId: 321
                            )
                        ]
                    )
                }
            }
        )

        #expect(DesktopWebChapterOnlineRepository.ratio("abc", "abc") == 100)
        #expect(DesktopWebChapterOnlineRepository.ratio("abc", "axc") == 67)
        #expect(DesktopWebChapterOnlineRepository.ratio("", "") == 0)
        let candidates = try await repository.searchCandidates(bookID: 51, keyword: "abc")
        #expect(candidates.map(\.doubanID) == [2, 3, 1])
        #expect(candidates.first?.publisher == "P2")
        #expect(candidates.last?.hasCatalog == true)

        let catalog = try await repository.onlineCatalog(bookID: 51, requestedDoubanID: nil)
        #expect(catalog.doubanID == 321)
        #expect(catalog.title == "Exact")
        #expect(catalog.catalog == "第一章\n第二章")
        #expect(await recorder.values == [.keyword("abc"), .doubanID(321)])

        do {
            _ = try await repository.searchCandidates(bookID: 51, keyword: " \n ")
            Issue.record("空白在线搜索词应被拒绝")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .invalidArgument("搜索关键词不能为空"))
        }
    }

    @Test
    func importPreviewMatchesAndroidKeysDuplicatePathsAndIndentValidation() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebChapterRepository(database: database)
        try chapterSeedBook(database, id: 61, name: "Book")
        try chapterSeed(database, id: 610, bookID: 61, title: "Root")

        let preview = try await repository.previewImport(
            bookID: 61,
            catalog: "Root\n  Child\n  Child\nOther"
        )
        #expect(preview.totalCount == 4)
        #expect(preview.duplicateCount == 2)
        #expect(preview.selectableCount == 2)
        #expect(preview.selectedCount == 2)
        #expect(preview.items.map(\.key) == ["p-0-0", "p-0-1"])
        #expect(preview.items.first?.duplicate == true)
        #expect(preview.items.first?.children.map(\.key) == ["p-0-0-1-0", "p-0-0-1-1"])
        #expect(preview.items.first?.children.map(\.duplicate) == [false, true])

        let empty = try await repository.previewImport(bookID: 61, catalog: " \n\u{00A0}\n")
        #expect(empty.totalCount == 0)
        do {
            _ = try await repository.previewImport(bookID: 61, catalog: "  Missing parent")
            Issue.record("首行二级章节应被拒绝")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .invalidArgument("第 2 层章节缺少父章节：Missing parent"))
        }
        do {
            _ = try await repository.previewImport(
                bookID: 61,
                catalog: "Root\n  L2\n    L3\n      L4\n        L5\n          L6"
            )
            Issue.record("六级章节应被拒绝")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .invalidArgument("章节层级不能超过 5 层"))
        }
    }

    @Test
    func importCommitCreatesAncestorsCountsDuplicatesAndIncludesDeepSelections() async throws {
        let database = try AppDatabase.empty()
        let repository = DesktopWebChapterRepository(database: database, currentTimeMillis: { 9_000 })
        try chapterSeedBook(database, id: 71, name: "Book")
        try chapterSeed(database, id: 710, bookID: 71, title: "Root", sourcePath: "Root")
        let catalog = "Root\n  Child\n  Child\nOther"
        let result = try await repository.commitImport(
            bookID: 71,
            catalog: catalog,
            selectedKeys: ["p-0-0-1-0", "p-0-1"]
        )
        #expect(result == DesktopWebChapterImportCommitResultSnapshot(created: 2, skipped: 1, duplicated: 0))
        let stored = try chapterAll(database, bookID: 71)
        #expect(stored.map(\.title).sorted() == ["Child", "Other", "Root"])
        #expect(stored.first { $0.title == "Child" }?.parentId == 710)
        #expect(stored.first { $0.title == "Child" }?.sourcePath == "Root / Child")
        #expect(stored.first { $0.title == "Child" }?.sourceUid == "")
        #expect(stored.first { $0.title == "Child" }?.sourceAnchor == "")
        #expect(stored.first { $0.title == "Child" }?.createdDate == 9_000)

        let duplicate = try await repository.commitImport(
            bookID: 71,
            catalog: "Root",
            selectedKeys: ["p-0-0"]
        )
        #expect(duplicate == DesktopWebChapterImportCommitResultSnapshot(created: 0, skipped: 0, duplicated: 1))

        let grandchildOnly = try await repository.commitImport(
            bookID: 71,
            catalog: "New Root\n  New Child\n    New Grandchild",
            selectedKeys: ["p-0-0-1-0-2-0"]
        )
        #expect(
            grandchildOnly
                == DesktopWebChapterImportCommitResultSnapshot(created: 3, skipped: 0, duplicated: 0)
        )
        #expect(try chapterAll(database, bookID: 71).contains { $0.title == "New Root" })

        do {
            _ = try await repository.commitImport(bookID: 71, catalog: "Root", selectedKeys: [])
            Issue.record("空选择列表应被拒绝")
        } catch let error as DesktopWebCatalogRepositoryError {
            #expect(error == .invalidArgument("请至少选择一个章节"))
        }
    }
}

private actor ChapterWenquQueryRecorder {
    private(set) var values: [DesktopWebWenquQuery] = []

    func append(_ value: DesktopWebWenquQuery) {
        values.append(value)
    }
}

private struct ChapterNoteState: Equatable {
    let chapterID: Int64
    let updated: Int64
}

private func collectChapterIDs(_ chapter: DesktopWebChapterFullSnapshot) -> [Int64] {
    [chapter.id] + chapter.children.flatMap(collectChapterIDs)
}

private func chapterSeedBook(
    _ database: AppDatabase,
    id: Int64,
    name: String,
    cover: String = "",
    author: String = "",
    press: String = "",
    doubanID: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = BookRecord(
            id: id,
            userId: 1,
            doubanId: doubanID,
            name: name,
            cover: cover,
            author: author,
            press: press,
            sourceId: 1,
            readStatusId: 1,
            createdDate: 1,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func chapterAll(_ database: AppDatabase, bookID: Int64) throws -> [ChapterRecord] {
    try database.dbPool.read { db in
        // SQL 目的：测试读取单书全部章节的持久化状态。
        // 涉及表：chapter；关键过滤：book_id 精确匹配；时间字段：原样读取。
        // 返回字段用途：核对目录导入的父子、路径、时间和未创建节点。
        try ChapterRecord.fetchAll(
            db,
            sql: "SELECT * FROM chapter WHERE book_id = ? ORDER BY id",
            arguments: [bookID]
        )
    }
}

private func chapterSeed(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    parentID: Int64 = 0,
    title: String,
    order: Int64 = 0,
    level: Int64 = 0,
    sourcePath: String? = nil,
    isStarred: Int64 = 0,
    updated: Int64 = 0,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = ChapterRecord(
            id: id,
            bookId: bookID,
            parentId: parentID,
            title: title,
            chapterOrder: order,
            chapterLevel: level,
            sourcePath: sourcePath,
            isStarred: isStarred,
            createdDate: 1,
            updatedDate: updated,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func chapterSeedNote(
    _ database: AppDatabase,
    id: Int64,
    bookID: Int64,
    chapterID: Int64,
    created: Int64,
    isDeleted: Int64 = 0
) throws {
    try database.dbPool.write { db in
        var record = NoteRecord(
            id: id,
            bookId: bookID,
            chapterId: chapterID,
            content: "fixture",
            createdDate: created,
            isDeleted: isDeleted
        )
        try record.insert(db)
    }
}

private func chapterFetch(_ database: AppDatabase, id: Int64) throws -> ChapterRecord? {
    try database.dbPool.read { db in
        // SQL 目的：测试读取指定章节的完整持久化状态。
        // 涉及表：chapter；关键过滤：id 精确匹配；时间字段：原样读取。
        // 返回字段用途：核对层级、路径、顺序、软删除与时间副作用。
        try ChapterRecord.fetchOne(db, sql: "SELECT * FROM chapter WHERE id = ?", arguments: [id])
    }
}

private func chapterNoteState(_ database: AppDatabase, id: Int64) throws -> ChapterNoteState? {
    try database.dbPool.read { db in
        // SQL 目的：测试读取书摘解除章节关联后的字段状态。
        // 涉及表：note；关键过滤：id 精确匹配；时间字段：updated_date 原样读取毫秒值。
        // 返回字段用途：核对删除事务同时更新有效和已软删除书摘。
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT chapter_id, updated_date FROM note WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        return ChapterNoteState(chapterID: row["chapter_id"], updated: row["updated_date"])
    }
}
