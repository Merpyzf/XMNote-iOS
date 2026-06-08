/**
 * [INPUT]: 依赖 Foundation 基础类型，承接 Android 全局搜索四类本地结果的统一领域表达
 * [OUTPUT]: 对外提供 GlobalSearchCategory、GlobalSearchScope、GlobalSearchFieldScope、GlobalSearchTarget、GlobalSearchResult、GlobalSearchSnapshot
 * [POS]: Domain/Models 的全局搜索领域模型，供 Repository、ViewModel 与 Search 页面共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 全局搜索结果分类，对齐 Android SearchItem 的四类业务范围。
nonisolated enum GlobalSearchCategory: String, CaseIterable, Identifiable, Sendable {
    case book
    case note
    case relevant
    case review

    var id: Self { self }

    var title: String {
        switch self {
        case .book:
            return String(localized: "书籍")
        case .note:
            return String(localized: "书摘")
        case .relevant:
            return String(localized: "相关")
        case .review:
            return String(localized: "书评")
        }
    }

    var iconSystemName: String {
        switch self {
        case .book:
            return "book.closed"
        case .note:
            return "quote.opening"
        case .relevant:
            return "link"
        case .review:
            return "text.bubble"
        }
    }
}

/// 分类内字段范围，用于在结果较多时帮助用户缩小到书名、正文、想法、标签等具体业务字段。
nonisolated enum GlobalSearchFieldScope: Hashable, Identifiable, Sendable {
    case bookTitle
    case bookAuthor
    case bookPress
    case bookTag
    case bookISBN
    case noteContent
    case noteIdea
    case noteBookTitle
    case noteTag
    case relevantTitle
    case relevantContent
    case relevantBookTitle
    case relevantCategory
    case reviewTitle
    case reviewContent
    case reviewBookTitle

    var id: Self { self }

    var category: GlobalSearchCategory {
        switch self {
        case .bookTitle, .bookAuthor, .bookPress, .bookTag, .bookISBN:
            return .book
        case .noteContent, .noteIdea, .noteBookTitle, .noteTag:
            return .note
        case .relevantTitle, .relevantContent, .relevantBookTitle, .relevantCategory:
            return .relevant
        case .reviewTitle, .reviewContent, .reviewBookTitle:
            return .review
        }
    }

    var title: String {
        switch self {
        case .bookTitle, .noteBookTitle, .relevantBookTitle, .reviewBookTitle:
            return String(localized: "书名")
        case .bookAuthor:
            return String(localized: "作者")
        case .bookPress:
            return String(localized: "出版社")
        case .bookTag, .noteTag:
            return String(localized: "标签")
        case .bookISBN:
            return String(localized: "ISBN")
        case .noteContent:
            return String(localized: "正文")
        case .noteIdea:
            return String(localized: "想法")
        case .relevantTitle, .reviewTitle:
            return String(localized: "标题")
        case .relevantContent:
            return String(localized: "内容")
        case .relevantCategory:
            return String(localized: "分类")
        case .reviewContent:
            return String(localized: "正文")
        }
    }

    var matchedFieldNames: Set<String> {
        switch self {
        case .bookTitle:
            return ["书名"]
        case .bookAuthor:
            return ["作者", "译者"]
        case .bookPress:
            return ["出版社"]
        case .bookTag:
            return ["标签"]
        case .bookISBN:
            return ["ISBN"]
        case .noteContent:
            return ["正文"]
        case .noteIdea:
            return ["想法"]
        case .noteBookTitle:
            return ["书名"]
        case .noteTag:
            return ["标签"]
        case .relevantTitle:
            return ["标题"]
        case .relevantContent:
            return ["内容"]
        case .relevantBookTitle:
            return ["书名"]
        case .relevantCategory:
            return ["分类"]
        case .reviewTitle:
            return ["标题"]
        case .reviewContent:
            return ["正文"]
        case .reviewBookTitle:
            return ["书名"]
        }
    }
}

extension GlobalSearchCategory {
    var fieldScopes: [GlobalSearchFieldScope] {
        switch self {
        case .book:
            return [.bookTitle, .bookAuthor, .bookPress, .bookTag, .bookISBN]
        case .note:
            return [.noteContent, .noteIdea, .noteBookTitle, .noteTag]
        case .relevant:
            return [.relevantTitle, .relevantContent, .relevantBookTitle, .relevantCategory]
        case .review:
            return [.reviewTitle, .reviewContent, .reviewBookTitle]
        }
    }
}

/// 搜索结果筛选范围；`.all` 表示聚合展示当前关键词下的全部非空结果。
nonisolated enum GlobalSearchScope: Hashable, Identifiable, Sendable {
    case all
    case book
    case note
    case relevant
    case review

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            return String(localized: "全部")
        case .book:
            return GlobalSearchCategory.book.title
        case .note:
            return GlobalSearchCategory.note.title
        case .relevant:
            return GlobalSearchCategory.relevant.title
        case .review:
            return GlobalSearchCategory.review.title
        }
    }

    var category: GlobalSearchCategory? {
        switch self {
        case .all:
            return nil
        case .book:
            return .book
        case .note:
            return .note
        case .relevant:
            return .relevant
        case .review:
            return .review
        }
    }

    init(category: GlobalSearchCategory) {
        switch category {
        case .book:
            self = .book
        case .note:
            self = .note
        case .relevant:
            self = .relevant
        case .review:
            self = .review
        }
    }
}

/// 搜索结果点击后的业务目标，不让 Domain 反向依赖 Navigation 路由类型。
nonisolated enum GlobalSearchTarget: Hashable, Sendable {
    case bookDetail(bookId: Int64)
    case noteViewer(noteId: Int64, bookId: Int64)
    case relevantDetail(contentId: Int64)
    case relevantBook(contentId: Int64, bookId: Int64)
    case reviewDetail(reviewId: Int64)
}

/// 书籍类搜索结果的展示字段，对齐 Android 本地书籍搜索卡片。
nonisolated struct GlobalSearchBookDisplay: Hashable, Sendable {
    let title: String
    let coverURL: String?
    let author: String
    let translator: String
    let press: String
    let isbn: String
    let dateText: String
    let readStatusName: String
    let sourceName: String
    let progressText: String
    let recentReadText: String
    let tagNames: [String]

    init(
        title: String,
        coverURL: String?,
        author: String,
        translator: String,
        press: String,
        isbn: String,
        dateText: String,
        readStatusName: String = "",
        sourceName: String = "",
        progressText: String = "",
        recentReadText: String = "",
        tagNames: [String] = []
    ) {
        self.title = title
        self.coverURL = coverURL
        self.author = author
        self.translator = translator
        self.press = press
        self.isbn = isbn
        self.dateText = dateText
        self.readStatusName = readStatusName
        self.sourceName = sourceName
        self.progressText = progressText
        self.recentReadText = recentReadText
        self.tagNames = tagNames
    }
}

/// 书摘类搜索结果的展示字段，对齐 Android 书摘搜索卡片的正文、想法、图片、标签与页脚。
nonisolated struct GlobalSearchNoteDisplay: Hashable, Sendable {
    let content: String
    let idea: String
    let imageURLs: [String]
    let tagNames: [String]
    let bookTitle: String
    let dateText: String
}

/// 普通相关内容搜索结果的展示字段，对齐 Android 相关内容卡片。
nonisolated struct GlobalSearchRelevantContentDisplay: Hashable, Sendable {
    let title: String
    let content: String
    let imageURLs: [String]
    let categoryTitle: String
    let bookTitle: String
    let dateText: String
}

/// 相关书籍搜索结果的展示字段，对齐 Android 相关书籍卡片。
nonisolated struct GlobalSearchRelevantBookDisplay: Hashable, Sendable {
    let book: GlobalSearchBookDisplay
    let sourceBookTitle: String
}

/// 书评搜索结果的展示字段，对齐 Android 书评搜索卡片。
nonisolated struct GlobalSearchReviewDisplay: Hashable, Sendable {
    let title: String
    let content: String
    let imageURLs: [String]
    let bookTitle: String
    let dateText: String
}

/// 搜索结果的类型化展示载荷，避免 UI 用拼接字符串还原业务字段。
nonisolated enum GlobalSearchResultDisplay: Hashable, Sendable {
    case book(GlobalSearchBookDisplay)
    case note(GlobalSearchNoteDisplay)
    case relevantContent(GlobalSearchRelevantContentDisplay)
    case relevantBook(GlobalSearchRelevantBookDisplay)
    case review(GlobalSearchReviewDisplay)
}

/// 单条全局搜索结果，统一承载四类业务结果的列表展示与导航所需字段。
nonisolated struct GlobalSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let category: GlobalSearchCategory
    let target: GlobalSearchTarget
    let display: GlobalSearchResultDisplay
    let title: String
    let subtitle: String
    let snippet: String
    let coverURL: String?
    let timestamp: Int64
    let matchedFields: [String]

    init(
        id: String,
        category: GlobalSearchCategory,
        target: GlobalSearchTarget,
        display: GlobalSearchResultDisplay,
        title: String,
        subtitle: String = "",
        snippet: String = "",
        coverURL: String? = nil,
        timestamp: Int64 = 0,
        matchedFields: [String] = []
    ) {
        self.id = id
        self.category = category
        self.target = target
        self.display = display
        self.title = title
        self.subtitle = subtitle
        self.snippet = snippet
        self.coverURL = coverURL
        self.timestamp = timestamp
        self.matchedFields = matchedFields
    }
}

/// 一次全局搜索的完整快照，保留分组结果与聚合计数。
nonisolated struct GlobalSearchSnapshot: Equatable, Sendable {
    let keyword: String
    let books: [GlobalSearchResult]
    let notes: [GlobalSearchResult]
    let relevants: [GlobalSearchResult]
    let reviews: [GlobalSearchResult]

    static let empty = GlobalSearchSnapshot(
        keyword: "",
        books: [],
        notes: [],
        relevants: [],
        reviews: []
    )

    var totalCount: Int {
        books.count + notes.count + relevants.count + reviews.count
    }

    var isEmpty: Bool {
        totalCount == 0
    }

    var nonEmptyCategories: [GlobalSearchCategory] {
        GlobalSearchCategory.allCases.filter { count(for: $0) > 0 }
    }

    /// 读取指定筛选范围下的结果；`.all` 聚合四类非空结果，用于多分类搜索首屏。
    func results(for scope: GlobalSearchScope) -> [GlobalSearchResult] {
        switch scope {
        case .all:
            return books + notes + relevants + reviews
        case .book:
            return books
        case .note:
            return notes
        case .relevant:
            return relevants
        case .review:
            return reviews
        }
    }

    /// 读取指定分类数量，用于顶部范围筛选与分区标题。
    func count(for category: GlobalSearchCategory) -> Int {
        switch category {
        case .book:
            return books.count
        case .note:
            return notes.count
        case .relevant:
            return relevants.count
        case .review:
            return reviews.count
        }
    }
}
