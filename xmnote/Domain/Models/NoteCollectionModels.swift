/**
 * [INPUT]: 依赖 Foundation 基础类型，承接 Android 首页笔记四分类及二级列表的数据语义
 * [OUTPUT]: 对外提供书摘与章节二级页导航上下文、分页请求、星标章节、相关分类/内容、全量书评等领域模型
 * [POS]: Domain/Models 的笔记聚合模型，供 NoteRepository、ContentRepository、ViewModel 与类型安全路由共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 首页书摘入口范围；四个默认分组与用户标签共用同一查询语义。
nonisolated enum NoteExcerptScope: Hashable, Sendable, Codable {
    case all
    case untagged
    case withIdea
    case withImages
    case tag(id: Int64)
    case book(id: Int64)

    /// Android 历史路由使用的 tagId；非正数表示默认分组。
    var legacyTagID: Int64 {
        switch self {
        case .all: 0
        case .untagged: -1
        case .withIdea: -2
        case .withImages: -3
        case .tag(let id): id
        case .book: 0
        }
    }

    /// 将旧版 `notesByTag` 参数映射为显式范围，保持既有深链兼容。
    init(legacyTagID: Int64) {
        switch legacyTagID {
        case 0:
            self = .all
        case -1:
            self = .untagged
        case -2:
            self = .withIdea
        case -3:
            self = .withImages
        default:
            self = legacyTagID > 0 ? .tag(id: legacyTagID) : .all
        }
    }
}

/// 书摘二级页的稳定导航上下文；范围负责查询，标题负责首帧导航确认。
nonisolated struct NoteExcerptListContext: Hashable, Sendable, Codable {
    let scope: NoteExcerptScope
    let displayTitle: String

    /// 将入口已经展示的真实名称带入目的地，避免异步查询完成后再替换导航标题。
    init(scope: NoteExcerptScope, displayTitle: String) {
        self.scope = scope
        let normalizedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayTitle = normalizedTitle.isEmpty ? "书摘" : normalizedTitle
    }
}

/// 章节书摘二级页的稳定导航上下文；业务标识负责查询，入口标题负责首帧导航确认。
nonisolated struct ChapterNoteListContext: Hashable, Sendable, Codable {
    let bookID: Int64
    let chapterID: Int64
    let includeDescendants: Bool
    let displayTitle: String

    /// 将入口已经展示的章节名称带入目的地，异常空标题回退为明确的章节语义。
    init(
        bookID: Int64,
        chapterID: Int64,
        includeDescendants: Bool,
        displayTitle: String
    ) {
        self.bookID = bookID
        self.chapterID = chapterID
        self.includeDescendants = includeDescendants
        let normalizedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayTitle = normalizedTitle.isEmpty ? "章节" : normalizedTitle
    }
}

/// 书摘二级列表排序；随机模式通过请求 seed 保证一次浏览会话内顺序稳定。
nonisolated enum NoteExcerptSortRule: String, CaseIterable, Hashable, Sendable, Codable {
    case createdAscending
    case createdDescending
    case random
}

/// 首页默认分组或用户书摘标签的只读聚合项。
nonisolated struct NoteExcerptGroupItem: Identifiable, Hashable, Sendable {
    let scope: NoteExcerptScope
    let title: String
    let count: Int
    let order: Int64

    var id: NoteExcerptScope { scope }
}

/// 笔记首页书摘分组快照，明确隔离用户书摘标签与书籍标签。
nonisolated struct NoteHomeSnapshot: Hashable, Sendable {
    let defaultGroups: [NoteExcerptGroupItem]
    let userTags: [NoteExcerptGroupItem]
}

/// 书摘卡片关联标签的轻量快照。
nonisolated struct NoteExcerptTagItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let order: Int64
}

/// 书摘二级列表卡片需要的完整只读数据。
nonisolated struct NoteExcerptListItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let bookID: Int64
    let bookTitle: String
    let bookAuthor: String
    let bookCoverURL: String
    let chapterID: Int64
    let chapterTitle: String
    let contentHTML: String
    let ideaHTML: String
    let plainContent: String
    let plainIdea: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64
    let imageURLs: [String]
    let tags: [NoteExcerptTagItem]
}

/// 书摘分页读取请求；搜索条件始终与 scope 做 AND 组合。
nonisolated struct NoteExcerptPageRequest: Hashable, Sendable, Codable {
    let scope: NoteExcerptScope
    let query: String
    let sort: NoteExcerptSortRule
    let randomSeed: Int64
    let offset: Int
    let limit: Int

    /// 构建安全分页参数；负 offset 归零，limit 至少为 1。
    init(
        scope: NoteExcerptScope,
        query: String = "",
        sort: NoteExcerptSortRule = .createdDescending,
        randomSeed: Int64 = 0,
        offset: Int = 0,
        limit: Int = 30
    ) {
        self.scope = scope
        self.query = query
        self.sort = sort
        self.randomSeed = randomSeed
        self.offset = max(0, offset)
        self.limit = max(1, limit)
    }
}

/// 书摘二级列表一次观察结果，携带总数以支持稳定分页与空态判断。
nonisolated struct NoteExcerptListSnapshot: Hashable, Sendable {
    let items: [NoteExcerptListItem]
    let totalCount: Int
}

/// 章节书摘二级列表请求；搜索、排序与分页始终限制在当前章节或其后代范围。
nonisolated struct ChapterNotePageRequest: Hashable, Sendable, Codable {
    let bookID: Int64
    let chapterID: Int64
    let includesDescendants: Bool
    let query: String
    let sort: NoteExcerptSortRule
    let randomSeed: Int64
    let offset: Int
    let limit: Int

    /// 构建安全分页参数，根章节 0 表示指定书籍的全部书摘。
    init(
        bookID: Int64,
        chapterID: Int64,
        includesDescendants: Bool,
        query: String = "",
        sort: NoteExcerptSortRule = .createdDescending,
        randomSeed: Int64 = 0,
        offset: Int = 0,
        limit: Int = 30
    ) {
        self.bookID = bookID
        self.chapterID = chapterID
        self.includesDescendants = includesDescendants
        self.query = query
        self.sort = sort
        self.randomSeed = randomSeed
        self.offset = max(0, offset)
        self.limit = max(1, limit)
    }
}

/// 星标章节列表排序规则，对齐 Android 的最近变更和书摘数倒序。
nonisolated enum StarredChapterSort: String, CaseIterable, Hashable, Sendable, Codable {
    case recentlyChanged
    case noteCountDescending
}

/// 星标章节查询请求。
nonisolated struct StarredChapterRequest: Hashable, Sendable, Codable {
    let query: String
    let sort: StarredChapterSort

    init(query: String = "", sort: StarredChapterSort = .recentlyChanged) {
        self.query = query
        self.sort = sort
    }
}

/// 单个星标章节及其后代书摘计数。
nonisolated struct StarredChapterItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let bookID: Int64
    let parentID: Int64
    let title: String
    let pathTitles: [String]
    let directNoteCount: Int
    let descendantNoteCount: Int
    let updatedDate: Int64
}

/// 按书分组的星标章节快照。
nonisolated struct StarredChapterGroup: Identifiable, Hashable, Sendable {
    let id: Int64
    let bookTitle: String
    let bookAuthor: String
    let bookCoverURL: String
    let chapters: [StarredChapterItem]
    let chapterCount: Int
    let noteCount: Int
    let latestUpdatedDate: Int64
}

/// 相关二级列表作用域；自定义分类按精确标题跨书聚合。
nonisolated enum RelatedCategoryScope: Hashable, Sendable, Codable {
    case all
    case title(String)

    static let allTitle = "全部相关"

    var displayTitle: String {
        switch self {
        case .all: Self.allTitle
        case .title(let title): title
        }
    }
}

/// 相关分类入口排序。
nonisolated enum RelatedCategorySort: String, CaseIterable, Hashable, Sendable, Codable {
    case countAscending
    case countDescending
    case createdAscending
    case createdDescending
}

/// 相关分类入口查询请求。
nonisolated struct RelatedCategoryRequest: Hashable, Sendable, Codable {
    let query: String
    let sort: RelatedCategorySort

    init(query: String = "", sort: RelatedCategorySort = .countDescending) {
        self.query = query
        self.sort = sort
    }
}

/// 相关分类中出现的来源书籍摘要。
nonisolated struct RelatedCategoryBookItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let author: String
    let coverURL: String
}

/// 同名相关分类跨书聚合后的入口项。
nonisolated struct RelatedCategoryItem: Identifiable, Hashable, Sendable {
    let scope: RelatedCategoryScope
    let categoryIDs: [Int64]
    let title: String
    let books: [RelatedCategoryBookItem]
    let contentCount: Int
    let createdDate: Int64
    let updatedDate: Int64
    let isDefault: Bool

    var id: RelatedCategoryScope { scope }
}

/// 相关分类入口一次观察结果。
nonisolated struct RelatedCategorySnapshot: Hashable, Sendable {
    let items: [RelatedCategoryItem]
    let totalContentCount: Int
}

/// 相关内容二级列表排序；随机顺序由 request.randomSeed 固定。
nonisolated enum RelatedContentSortRule: String, CaseIterable, Hashable, Sendable, Codable {
    case createdAscending
    case createdDescending
    case random
}

/// 相关内容分页读取请求。
nonisolated struct RelatedContentPageRequest: Hashable, Sendable, Codable {
    let scope: RelatedCategoryScope
    let query: String
    let sort: RelatedContentSortRule
    let randomSeed: Int64
    let offset: Int
    let limit: Int

    /// 构建安全分页参数，搜索限定于当前相关分类作用域。
    init(
        scope: RelatedCategoryScope,
        query: String = "",
        sort: RelatedContentSortRule = .createdDescending,
        randomSeed: Int64 = 0,
        offset: Int = 0,
        limit: Int = 30
    ) {
        self.scope = scope
        self.query = query
        self.sort = sort
        self.randomSeed = randomSeed
        self.offset = max(0, offset)
        self.limit = max(1, limit)
    }
}

/// 相关列表稳定身份，区分普通内容与相关书籍。
nonisolated enum RelatedListItemID: Hashable, Sendable {
    case content(Int64)
    case bookRelation(Int64)
}

/// 普通相关内容卡片。
nonisolated struct RelatedContentListItem: Hashable, Sendable {
    let relationID: Int64
    let sourceBookID: Int64
    let sourceBookTitle: String
    let categoryID: Int64
    let categoryTitle: String
    let title: String
    let contentHTML: String
    let url: String
    let createdDate: Int64
    let imageURLs: [String]
}

/// 相关书籍卡片；relationID 是删除关联时的真实 owner。
nonisolated struct RelatedBookListItem: Hashable, Sendable {
    let relationID: Int64
    let sourceBookID: Int64
    let sourceBookTitle: String
    let categoryID: Int64
    let categoryTitle: String
    let relatedBookID: Int64
    let title: String
    let author: String
    let coverURL: String
    let createdDate: Int64
    let isPlaceholder: Bool
}

/// 相关列表混排项。
nonisolated enum RelatedListItem: Identifiable, Hashable, Sendable {
    case content(RelatedContentListItem)
    case book(RelatedBookListItem)

    var id: RelatedListItemID {
        switch self {
        case .content(let item): .content(item.relationID)
        case .book(let item): .bookRelation(item.relationID)
        }
    }

    var relationID: Int64 {
        switch self {
        case .content(let item): item.relationID
        case .book(let item): item.relationID
        }
    }

    var createdDate: Int64 {
        switch self {
        case .content(let item): item.createdDate
        case .book(let item): item.createdDate
        }
    }
}

/// 相关内容二级列表一次观察结果。
nonisolated struct RelatedContentListSnapshot: Hashable, Sendable {
    let items: [RelatedListItem]
    let totalCount: Int
}

/// 全量书评列表排序规则。
nonisolated enum BookReviewSortRule: String, CaseIterable, Hashable, Sendable, Codable {
    case wordCountAscending
    case wordCountDescending
    case createdAscending
    case createdDescending
}

/// 全量书评分页请求。
nonisolated struct BookReviewPageRequest: Hashable, Sendable, Codable {
    let query: String
    let sort: BookReviewSortRule
    let offset: Int
    let limit: Int

    init(
        query: String = "",
        sort: BookReviewSortRule = .createdDescending,
        offset: Int = 0,
        limit: Int = 30
    ) {
        self.query = query
        self.sort = sort
        self.offset = max(0, offset)
        self.limit = max(1, limit)
    }
}

/// 全量书评卡片数据；wordCount 使用去除富文本标记后的正文计算。
nonisolated struct BookReviewListItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let bookID: Int64
    let bookTitle: String
    let bookAuthor: String
    let bookCoverURL: String
    let bookScore: Int64
    let title: String
    let contentHTML: String
    let wordCount: Int
    let createdDate: Int64
    let imageURLs: [String]
}

/// 全量书评列表一次观察结果。
nonisolated struct BookReviewListSnapshot: Hashable, Sendable {
    let items: [BookReviewListItem]
    let totalCount: Int
}
