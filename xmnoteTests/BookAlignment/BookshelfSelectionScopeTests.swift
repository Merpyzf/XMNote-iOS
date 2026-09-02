/**
 * [INPUT]: 依赖 BookshelfSelectionScope 与书架 Book/Group 只读模型
 * [OUTPUT]: 验证 A-11 仅分组选择、混合重复选择与空分组的稳定书籍范围
 * [POS]: xmnoteTests/BookAlignment 选择范围合同测试，阻止书单和导出入口重新出现 direct-book gate
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Testing
@testable import xmnote

struct BookshelfSelectionScopeTests {
    @Test
    func groupOnlySelectionExpandsBooksInGroupOrder() {
        let group = Self.groupItem(id: 10, bookIDs: [101, 102])

        #expect(BookshelfSelectionScope.expandedBookIDs(
            selectedIDs: [.group(10)],
            items: [group]
        ) == [101, 102])
    }

    @Test
    func mixedSelectionKeepsFirstOccurrenceAndDropsInvalidIDs() {
        let group = Self.groupItem(id: 10, bookIDs: [101, 0, 102, 101])

        #expect(BookshelfSelectionScope.expandedBookIDs(
            selectedIDs: [.book(102), .group(10), .book(101), .book(-1)],
            items: [group]
        ) == [102, 101])
    }

    @Test
    func emptyGroupProducesNoDownstreamTargets() {
        let group = Self.groupItem(id: 10, bookIDs: [])

        #expect(BookshelfSelectionScope.expandedBookIDs(
            selectedIDs: [.group(10)],
            items: [group]
        ).isEmpty)
    }
}

private extension BookshelfSelectionScopeTests {
    static func groupItem(id: Int64, bookIDs: [Int64]) -> BookshelfItem {
        let books = bookIDs.map { bookID in
            BookshelfBookListItem(payload: BookshelfBookPayload(
                id: bookID,
                name: "book-\(bookID)",
                author: "",
                cover: "",
                readStatusId: 0,
                noteCount: 0
            ))
        }
        return BookshelfItem(
            id: .group(id),
            pinned: false,
            pinOrder: 0,
            sortOrder: 0,
            content: .group(BookshelfGroupPayload(
                id: id,
                name: "group-\(id)",
                bookCount: books.count,
                representativeCovers: [],
                books: books
            ))
        )
    }
}
