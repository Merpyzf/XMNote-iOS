/**
 * [INPUT]: 依赖 Foundation Encodable/Sendable 与现有完整书籍 DTO；数据由 App 注入的 Search 能力端口提供
 * [OUTPUT]: 提供 SearchController 两条 Web API 的异构分页、聚合错误与能力端口
 * [POS]: XMNoteWeb 搜索公共边界；不依赖 App Record、GRDB 或 Hummingbird 类型
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android SearchType 的四个稳定查询域。
public enum DesktopWebSearchType: String, Sendable, CaseIterable {
    case book
    case note
    case review
    case relevant
}

/// 搜索预览中的书籍轻量投影；可选元数据为 nil 时编码会省略对应键。
public struct DesktopWebSearchSimpleBook: Encodable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let cover: String
    public let author: String
    public let press: String
    public let translator: String?
    public let pubDate: String?
    public let isDeleted: Bool?

    public init(
        id: Int64,
        name: String,
        cover: String,
        author: String,
        press: String,
        translator: String? = nil,
        pubDate: String? = nil,
        isDeleted: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.cover = cover
        self.author = author
        self.press = press
        self.translator = translator
        self.pubDate = pubDate
        self.isDeleted = isDeleted
    }
}

/// 搜索结果中展示的标签轻量投影。
public struct DesktopWebSearchTag: Encodable, Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// 搜索结果中的图片预览，只暴露 URL。
public struct DesktopWebSearchPreviewImage: Encodable, Sendable, Equatable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

/// Android WebNoteDto 的搜索专用响应合同。
public struct DesktopWebSearchNote: Encodable, Sendable, Equatable {
    public let id: Int64
    public let content: String
    public let idea: String?
    public let createdTime: Int64
    public let isIncludeTime: Bool
    public let book: DesktopWebSearchSimpleBook
    public let chapter: String?
    public let tags: [DesktopWebSearchTag]
    public let previewImages: [DesktopWebSearchPreviewImage]

    public init(
        id: Int64,
        content: String,
        idea: String?,
        createdTime: Int64,
        isIncludeTime: Bool,
        book: DesktopWebSearchSimpleBook,
        chapter: String?,
        tags: [DesktopWebSearchTag],
        previewImages: [DesktopWebSearchPreviewImage]
    ) {
        self.id = id
        self.content = content
        self.idea = idea
        self.createdTime = createdTime
        self.isIncludeTime = isIncludeTime
        self.book = book
        self.chapter = chapter
        self.tags = tags
        self.previewImages = previewImages
    }
}

/// Android WebReviewDto 的搜索专用响应合同。
public struct DesktopWebSearchReview: Encodable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let content: String
    public let createdTime: Int64
    public let book: DesktopWebSearchSimpleBook
    public let previewImages: [DesktopWebSearchPreviewImage]

    public init(
        id: Int64,
        title: String,
        content: String,
        createdTime: Int64,
        book: DesktopWebSearchSimpleBook,
        previewImages: [DesktopWebSearchPreviewImage]
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdTime = createdTime
        self.book = book
        self.previewImages = previewImages
    }
}

/// Android WebRelevantDto 的搜索专用响应合同。
public struct DesktopWebSearchRelevant: Encodable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let content: String
    public let url: String?
    public let createdTime: Int64
    public let book: DesktopWebSearchSimpleBook
    public let categoryTitle: String?
    public let displayKind: String?
    public let previewImages: [DesktopWebSearchPreviewImage]
    public let contentBook: DesktopWebSearchSimpleBook?

    public init(
        id: Int64,
        title: String,
        content: String,
        url: String?,
        createdTime: Int64,
        book: DesktopWebSearchSimpleBook,
        categoryTitle: String?,
        displayKind: String?,
        previewImages: [DesktopWebSearchPreviewImage],
        contentBook: DesktopWebSearchSimpleBook?
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.url = url
        self.createdTime = createdTime
        self.book = book
        self.categoryTitle = categoryTitle
        self.displayKind = displayKind
        self.previewImages = previewImages
        self.contentBook = contentBook
    }
}

/// 在不增加类型包装键的前提下编码四类异构搜索项。
public enum DesktopWebSearchItem: Encodable, Sendable, Equatable {
    case book(DesktopWebBook)
    case note(DesktopWebSearchNote)
    case review(DesktopWebSearchReview)
    case relevant(DesktopWebSearchRelevant)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .book(let value):
            try value.encode(to: encoder)
        case .note(let value):
            try value.encode(to: encoder)
        case .review(let value):
            try value.encode(to: encoder)
        case .relevant(let value):
            try value.encode(to: encoder)
        }
    }
}

/// Android PageResult<Any> 的异构搜索分页外形。
public struct DesktopWebSearchPage: Encodable, Sendable, Equatable {
    public let items: [DesktopWebSearchItem]
    public let pagination: DesktopWebPagination

    public init(items: [DesktopWebSearchItem], pagination: DesktopWebPagination) {
        self.items = items
        self.pagination = pagination
    }

    /// 构造聚合搜索某一域失败时的空页，同时保留请求分页元数据。
    public static func empty(page: Int, pageSize: Int) -> Self {
        Self(
            items: [],
            pagination: DesktopWebPagination(page: page, pageSize: pageSize, total: 0, totalPages: 0)
        )
    }
}

/// 聚合搜索逐域失败消息；成功域为 nil 并按 Gson 默认行为省略字段。
public struct DesktopWebSearchAggregateErrors: Encodable, Sendable, Equatable {
    public let book: String?
    public let note: String?
    public let relevant: String?
    public let review: String?

    public init(
        book: String? = nil,
        note: String? = nil,
        relevant: String? = nil,
        review: String? = nil
    ) {
        self.book = book
        self.note = note
        self.relevant = relevant
        self.review = review
    }
}

/// Android WebSearchAggregateResultDto 的四域聚合响应。
public struct DesktopWebSearchAggregateResult: Encodable, Sendable, Equatable {
    public let book: DesktopWebSearchPage
    public let note: DesktopWebSearchPage
    public let relevant: DesktopWebSearchPage
    public let review: DesktopWebSearchPage
    public let errors: DesktopWebSearchAggregateErrors

    public init(
        book: DesktopWebSearchPage,
        note: DesktopWebSearchPage,
        relevant: DesktopWebSearchPage,
        review: DesktopWebSearchPage,
        errors: DesktopWebSearchAggregateErrors = .init()
    ) {
        self.book = book
        self.note = note
        self.relevant = relevant
        self.review = review
        self.errors = errors
    }
}

/// 隔离 SearchController 与 App 数据库实现，聚合失败降级由 Adapter 按域执行。
public protocol DesktopWebSearchPort: Sendable {
    /// 查询单一域；实现应保持 Android 的分页、来源合并和投影规则，取消时不得产生写副作用。
    func search(
        type: DesktopWebSearchType,
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async throws -> DesktopWebSearchPage

    /// 顺序查询四个域并把每域异常降级为空页；该读取操作不产生数据库写入。
    func searchAggregate(
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async -> DesktopWebSearchAggregateResult
}
