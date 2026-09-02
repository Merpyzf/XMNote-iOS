import Foundation

/**
 * [INPUT]: 依赖 BookRepository 首页书架快照、Android v46 内置来源边界与管理写入扩展的中间数据需求
 * [OUTPUT]: 为 BookRepository 补充首页书架内部支撑类型、管理写入限制与局部字符串规范化 helper
 * [POS]: Data 层首页书架仓储内部支撑模型，避免 helper 类型散落在 BookRepository 主入口或全局命名空间
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

extension BookRepository {
    struct IndexedBookshelfItem {
        let item: BookshelfItem
        let sourceIndex: Int
    }

    struct BookshelfGroupBookPreview {
        let id: Int64
        let name: String
        let author: String
        let readStatusName: String
        let sourceName: String
        let cover: String
        let noteCount: Int
        let createdDate: Int64
        let modifiedDate: Int64
        let publishDate: Int64
        let score: Int64
        let readDoneDate: Int64
        let totalReadingTime: Int64
        let readingProgress: Double?
        let pinned: Bool
        let pinOrder: Int64
        let sortOrder: Int64

        var listItem: BookshelfBookListItem {
            BookshelfBookListItem(
                id: id,
                title: name,
                author: author,
                cover: cover,
                noteCount: noteCount,
                pinned: pinned
            )
        }
    }

    struct BookshelfGroupBuilder {
        let id: Int64
        let name: String
        let pinned: Bool
        let pinOrder: Int64
        let sortOrder: Int64
        let createdDate: Int64
        private(set) var books: [BookshelfGroupBookPreview]

        mutating func append(_ book: BookshelfGroupBookPreview) {
            guard !books.contains(where: { $0.id == book.id }) else { return }
            books.append(book)
        }

        /// 用已按二级列表设置排好的组内书构建顶层分组卡片载荷。
        func makeItem(sortedBooks: [BookshelfGroupBookPreview]) -> BookshelfItem? {
            guard !sortedBooks.isEmpty else { return nil }
            let payload = BookshelfGroupPayload(
                id: id,
                name: name,
                bookCount: sortedBooks.count,
                representativeCovers: sortedBooks.prefix(6).map(\.cover),
                books: sortedBooks.map { $0.listItem }
            )
            return BookshelfItem(
                id: .group(id),
                pinned: pinned,
                pinOrder: pinOrder,
                sortOrder: sortOrder,
                sortMetadata: BookshelfItemSortMetadata(
                    createdDate: createdDate,
                    modifiedDate: books.map(\.modifiedDate).max() ?? createdDate,
                    publishDate: 0,
                    noteCount: sortedBooks.reduce(0) { $0 + $1.noteCount },
                    rating: sortedBooks.map(\.score).max() ?? 0,
                    readDoneDate: sortedBooks.map(\.readDoneDate).max() ?? 0,
                    totalReadingTime: sortedBooks.reduce(0) { $0 + $1.totalReadingTime },
                    readingProgress: nil,
                    bookCount: sortedBooks.count
                ),
                content: .group(payload)
            )
        }
    }

    enum BookshelfBatchWriteError: LocalizedError {
        case emptySelection
        case invalidGroup
        case invalidTag
        case invalidSource
        case invalidReadStatus
        case invalidCollection
        case invalidBook
        case invalidOrder
        case ratingRequired
        case invalidName(String)
        case invalidNameLength(target: String, maxLength: Int)
        case duplicateName(String)
        case protectedDefaultSource

        var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "请先选择书籍"
            case .invalidGroup:
                return "分组已不存在，请刷新后重试"
            case .invalidTag:
                return "标签已不存在，请刷新后重试"
            case .invalidSource:
                return "来源已不存在，请刷新后重试"
            case .invalidReadStatus:
                return "阅读状态已不存在，请刷新后重试"
            case .invalidCollection:
                return "书单已不存在，请刷新后重试"
            case .invalidBook:
                return "书籍状态已变化，请刷新后重试"
            case .invalidOrder:
                return "排序内容已变化，请刷新后重试"
            case .ratingRequired:
                return "标记读完时需要选择评分"
            case .invalidName(let target):
                return "\(target)名称不能为空"
            case .invalidNameLength(let target, let maxLength):
                return "\(target)名称长度不能超过\(maxLength)个字符"
            case .duplicateName(let message):
                return message
            case .protectedDefaultSource:
                return "未知来源不能删除"
            }
        }
    }

    nonisolated enum BookshelfManagementLimits {
        static let groupNameMaxLength = 100
        static let tagNameMaxLength = 100
        static let sourceNameMaxLength = 100
        static let collectionNameMaxLength = 100
        static let defaultSourceIDRange: ClosedRange<Int64> = 1...28
    }

    struct BookshelfStatusKey: Hashable {
        let id: Int64
        let title: String
        let order: Int64
    }

    struct BookshelfDisplaySectionKey: Hashable {
        let id: String
        let title: String
    }

    struct BookshelfBatchEditInitialValues: Hashable {
        let tagIDs: [Int64]
        let sourceID: Int64?
        let readStatusID: Int64?
        let readStatusChangedAt: Int64?
        let ratingScore: Int64?
    }

    enum BookshelfMovePlacement {
        case start
        case end
    }

    func nonEmptyString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
