/**
 * [INPUT]: 依赖 Foundation Codable/Sendable 与共享分页模型
 * [OUTPUT]: 提供 RelatedController 18 个 API 的类别、相关内容、排序、CRUD 与批量能力端口
 * [POS]: XMNoteWeb 相关内容公共边界；只表达 Android Web 合同，不依赖 App 数据库、Repository 或 UI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android WebRelatedCategoryDto；scope 仅取 book/global。
public struct DesktopWebRelatedCategory: Codable, Sendable, Equatable {
    public let id: Int64
    public let bookId: Int64
    public let scope: String
    public let title: String
    public let order: Int64
    public let isHide: Bool
    public let contentCount: Int
    public let isSystemDefault: Bool
    public let createdTime: Int64
    public let updatedTime: Int64

    public init(
        id: Int64,
        bookId: Int64,
        scope: String,
        title: String,
        order: Int64,
        isHide: Bool,
        contentCount: Int,
        isSystemDefault: Bool,
        createdTime: Int64,
        updatedTime: Int64
    ) {
        self.id = id
        self.bookId = bookId
        self.scope = scope
        self.title = title
        self.order = order
        self.isHide = isHide
        self.contentCount = contentCount
        self.isSystemDefault = isSystemDefault
        self.createdTime = createdTime
        self.updatedTime = updatedTime
    }
}

/// Android WebBookSimpleDto 的相关内容投影；可选字段为空时按 Gson 语义省略。
public struct DesktopWebRelatedBook: Codable, Sendable, Equatable {
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

/// Android WebRelatedImageDto。
public struct DesktopWebRelatedImage: Codable, Sendable, Equatable {
    public let id: Int64
    public let url: String
    public let order: Int

    public init(id: Int64, url: String, order: Int) {
        self.id = id
        self.url = url
        self.order = order
    }
}

/// Android WebRelatedNoteDto，用于书内列表、详情和写入响应。
public struct DesktopWebRelatedNote: Codable, Sendable, Equatable {
    public let id: Int64
    public let bookId: Int64
    public let categoryId: Int64
    public let categoryTitle: String
    public let title: String
    public let content: String
    public let url: String
    public let contentBookId: Int64
    public let contentBook: DesktopWebRelatedBook?
    public let images: [DesktopWebRelatedImage]
    public let createdTime: Int64
    public let updatedTime: Int64

    public init(
        id: Int64,
        bookId: Int64,
        categoryId: Int64,
        categoryTitle: String,
        title: String,
        content: String,
        url: String,
        contentBookId: Int64,
        contentBook: DesktopWebRelatedBook?,
        images: [DesktopWebRelatedImage],
        createdTime: Int64,
        updatedTime: Int64
    ) {
        self.id = id
        self.bookId = bookId
        self.categoryId = categoryId
        self.categoryTitle = categoryTitle
        self.title = title
        self.content = content
        self.url = url
        self.contentBookId = contentBookId
        self.contentBook = contentBook
        self.images = images
        self.createdTime = createdTime
        self.updatedTime = updatedTime
    }
}

/// Android WebGlobalRelevantDto；全局列表额外携带来源书籍。
public struct DesktopWebGlobalRelatedNote: Codable, Sendable, Equatable {
    public let id: Int64
    public let bookId: Int64
    public let categoryId: Int64
    public let categoryTitle: String
    public let title: String
    public let content: String
    public let url: String
    public let contentBookId: Int64
    public let contentBook: DesktopWebRelatedBook?
    public let images: [DesktopWebRelatedImage]
    public let createdTime: Int64
    public let updatedTime: Int64
    public let book: DesktopWebRelatedBook

    public init(
        id: Int64,
        bookId: Int64,
        categoryId: Int64,
        categoryTitle: String,
        title: String,
        content: String,
        url: String,
        contentBookId: Int64,
        contentBook: DesktopWebRelatedBook?,
        images: [DesktopWebRelatedImage],
        createdTime: Int64,
        updatedTime: Int64,
        book: DesktopWebRelatedBook
    ) {
        self.id = id
        self.bookId = bookId
        self.categoryId = categoryId
        self.categoryTitle = categoryTitle
        self.title = title
        self.content = content
        self.url = url
        self.contentBookId = contentBookId
        self.contentBook = contentBook
        self.images = images
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.book = book
    }
}

/// Android RelatedCategoryCreateRequest。
public struct DesktopWebRelatedCategoryCreateRequest: Codable, Sendable, Equatable {
    public let title: String
    public let order: Int64?
    public let scope: String?

    public init(title: String, order: Int64? = nil, scope: String? = nil) {
        self.title = title
        self.order = order
        self.scope = scope
    }
}

/// Android RelatedCategoryUpdateRequest；nil 表示保留原值。
public struct DesktopWebRelatedCategoryUpdateRequest: Codable, Sendable, Equatable {
    public let title: String?
    public let order: Int64?
    public let scope: String?
    public let bookId: Int64?

    public init(
        title: String? = nil,
        order: Int64? = nil,
        scope: String? = nil,
        bookId: Int64? = nil
    ) {
        self.title = title
        self.order = order
        self.scope = scope
        self.bookId = bookId
    }
}

/// Android RelatedCategoryVisibilityRequest。
public struct DesktopWebRelatedCategoryVisibilityRequest: Codable, Sendable, Equatable {
    public let isHide: Bool

    public init(isHide: Bool) {
        self.isHide = isHide
    }
}

/// Android RelatedCategoryReorderRequest；服务层再执行正数去重。
public struct DesktopWebRelatedCategoryReorderRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]

    public init(ids: [Int64]) {
        self.ids = ids
    }
}

/// Android WebRelatedSortRuleDto。
public struct DesktopWebRelatedSortRule: Codable, Sendable, Equatable {
    public let sortBy: String
    public let sortOrder: String

    public init(sortBy: String, sortOrder: String) {
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

/// Android RelatedSortRuleUpdateRequest，字段缺失时使用 Kotlin 默认值。
public struct DesktopWebRelatedSortRuleUpdateRequest: Codable, Sendable, Equatable {
    public let sortBy: String
    public let sortOrder: String

    public init(sortBy: String = "create_time", sortOrder: String = "asc") {
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case sortBy, sortOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sortBy = try container.decodeIfPresent(String.self, forKey: .sortBy) ?? "create_time"
        sortOrder = try container.decodeIfPresent(String.self, forKey: .sortOrder) ?? "asc"
    }
}

/// Android RelatedNoteCreateRequest。
public struct DesktopWebRelatedNoteCreateRequest: Codable, Sendable, Equatable {
    public let bookId: Int64
    public let categoryId: Int64
    public let title: String?
    public let content: String?
    public let url: String?
    public let imageUrls: [String]?
    public let uploadedTicketIds: [String]?
    public let contentBookId: Int64?
    public let createdTime: Int64?

    public init(
        bookId: Int64,
        categoryId: Int64,
        title: String? = nil,
        content: String? = nil,
        url: String? = nil,
        imageUrls: [String]? = nil,
        uploadedTicketIds: [String]? = nil,
        contentBookId: Int64? = nil,
        createdTime: Int64? = nil
    ) {
        self.bookId = bookId
        self.categoryId = categoryId
        self.title = title
        self.content = content
        self.url = url
        self.imageUrls = imageUrls
        self.uploadedTicketIds = uploadedTicketIds
        self.contentBookId = contentBookId
        self.createdTime = createdTime
    }
}

/// Android RelatedNoteUpdateRequest；字段缺失表示保留，显式空图片数组表示清空。
public struct DesktopWebRelatedNoteUpdateRequest: Codable, Sendable, Equatable {
    public let categoryId: Int64?
    public let title: String?
    public let content: String?
    public let url: String?
    public let imageUrls: [String]?
    public let uploadedTicketIds: [String]?
    public let contentBookId: Int64?
    public let createdTime: Int64?

    public init(
        categoryId: Int64? = nil,
        title: String? = nil,
        content: String? = nil,
        url: String? = nil,
        imageUrls: [String]? = nil,
        uploadedTicketIds: [String]? = nil,
        contentBookId: Int64? = nil,
        createdTime: Int64? = nil
    ) {
        self.categoryId = categoryId
        self.title = title
        self.content = content
        self.url = url
        self.imageUrls = imageUrls
        self.uploadedTicketIds = uploadedTicketIds
        self.contentBookId = contentBookId
        self.createdTime = createdTime
    }
}

/// Android RelatedNoteBatchDeleteRequest。
public struct DesktopWebRelatedNoteBatchDeleteRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]

    public init(ids: [Int64]) {
        self.ids = ids
    }
}

/// Android RelatedNoteBatchUpdateCategoryRequest。
public struct DesktopWebRelatedNoteBatchUpdateCategoryRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let categoryId: Int64

    public init(ids: [Int64], categoryId: Int64) {
        self.ids = ids
        self.categoryId = categoryId
    }
}

/// 书内相关内容筛选；路由已经应用 Android 参数默认值与排序回退。
public struct DesktopWebRelatedNoteFilter: Sendable, Equatable {
    public let categoryID: Int64
    public let keyword: String
    public let sortBy: String
    public let sortOrder: String

    public init(categoryID: Int64, keyword: String, sortBy: String, sortOrder: String) {
        self.categoryID = categoryID
        self.keyword = keyword
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

/// 全局相关内容筛选；excludeIDs 保留路由解析顺序，Repository 再去重正数。
public struct DesktopWebGlobalRelatedNoteFilter: Sendable, Equatable {
    public let bookID: Int64
    public let categoryID: Int64
    public let keyword: String
    public let sortBy: String
    public let sortOrder: String
    public let sortMode: String
    public let excludeIDs: [Int64]

    public init(
        bookID: Int64,
        categoryID: Int64,
        keyword: String,
        sortBy: String,
        sortOrder: String,
        sortMode: String,
        excludeIDs: [Int64]
    ) {
        self.bookID = bookID
        self.categoryID = categoryID
        self.keyword = keyword
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.sortMode = sortMode
        self.excludeIDs = excludeIDs
    }
}

/// 隔离 RelatedController 的业务能力；实现由 App Adapter 经专用 Repository 提供。
public protocol DesktopWebRelatedPort: Sendable {
    /// 读取 Android 所谓“全局”类别集合，并按 includeHidden 决定是否保留隐藏项。
    func globalRelatedCategories(includeHidden: Bool) async throws -> [DesktopWebRelatedCategory]

    /// 读取指定书籍可用的全局与书内类别。
    func relatedCategories(bookID: Int64, includeHidden: Bool) async throws -> [DesktopWebRelatedCategory]

    /// 创建书内或全局类别。
    func createRelatedCategory(
        bookID: Int64,
        request: DesktopWebRelatedCategoryCreateRequest
    ) async throws -> DesktopWebRelatedCategory

    /// 局部更新类别名称、顺序或作用域。
    func updateRelatedCategory(
        id: Int64,
        request: DesktopWebRelatedCategoryUpdateRequest
    ) async throws -> DesktopWebRelatedCategory

    /// 更新类别可见性并返回完整快照。
    func updateRelatedCategoryVisibility(
        id: Int64,
        request: DesktopWebRelatedCategoryVisibilityRequest
    ) async throws -> DesktopWebRelatedCategory

    /// 删除类别及 Android 路径定义的关联内容。
    func deleteRelatedCategory(id: Int64) async throws

    /// 按请求顺序重排指定书籍可见的全部类别。
    func reorderRelatedCategories(
        bookID: Int64,
        request: DesktopWebRelatedCategoryReorderRequest
    ) async throws

    /// 读取指定书籍的相关内容排序设置。
    func relatedNoteSortRule(bookID: Int64) async throws -> DesktopWebRelatedSortRule

    /// 更新指定书籍的相关内容排序设置。
    func updateRelatedNoteSortRule(
        bookID: Int64,
        request: DesktopWebRelatedSortRuleUpdateRequest
    ) async throws -> DesktopWebRelatedSortRule

    /// 分页读取指定书籍的相关内容。
    func relatedNotes(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        filter: DesktopWebRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebRelatedNote>

    /// 不分页读取指定书籍的相关内容，保留 Android 空列表 pageSize=0 合同。
    func allRelatedNotes(
        bookID: Int64,
        filter: DesktopWebRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebRelatedNote>

    /// 分页读取有效来源书籍下的全局相关内容。
    func globalRelatedNotes(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalRelatedNote>

    /// 按内容 ID 读取详情。
    func relatedNote(id: Int64) async throws -> DesktopWebRelatedNote

    /// 创建相关内容及其图片。
    func createRelatedNote(
        _ request: DesktopWebRelatedNoteCreateRequest
    ) async throws -> DesktopWebRelatedNote

    /// 局部更新相关内容及其图片。
    func updateRelatedNote(
        id: Int64,
        request: DesktopWebRelatedNoteUpdateRequest
    ) async throws -> DesktopWebRelatedNote

    /// 软删除单条相关内容并清理图片。
    func deleteRelatedNote(id: Int64) async throws

    /// 批量软删除有效相关内容并清理请求 ID 对应图片。
    func batchDeleteRelatedNotes(_ request: DesktopWebRelatedNoteBatchDeleteRequest) async throws

    /// 批量把相关内容移动到同一有效类别。
    func batchUpdateRelatedNotesCategory(
        _ request: DesktopWebRelatedNoteBatchUpdateCategoryRequest
    ) async throws
}
