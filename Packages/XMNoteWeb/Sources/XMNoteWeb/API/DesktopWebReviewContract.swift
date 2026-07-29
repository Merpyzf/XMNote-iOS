/**
 * [INPUT]: 依赖 Foundation Codable/Sendable 与共享分页模型
 * [OUTPUT]: 提供 ReviewController 11 个 API 的列表、草稿、排序、CRUD DTO 与能力端口
 * [POS]: XMNoteWeb 书评公共边界；只表达 Android Web 合同，不依赖 App 数据库、Repository 或 UI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android WebAttachImageDto 的书评投影；写响应中的 ID 可能是临时数组下标。
public struct DesktopWebReviewImage: Codable, Sendable, Equatable {
    public let id: Int64
    public let url: String

    public init(id: Int64, url: String) {
        self.id = id
        self.url = url
    }
}

/// Android WebBookSimpleDto 的书评关联书籍投影。
public struct DesktopWebReviewBook: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let cover: String
    public let author: String
    public let press: String

    public init(id: Int64, name: String, cover: String, author: String, press: String) {
        self.id = id
        self.name = name
        self.cover = cover
        self.author = author
        self.press = press
    }
}

/// Android WebGlobalReviewDto。
public struct DesktopWebGlobalReview: Codable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let content: String
    public let createdTime: Int64
    public let updatedTime: Int64
    public let images: [DesktopWebReviewImage]
    public let book: DesktopWebReviewBook

    public init(
        id: Int64,
        title: String,
        content: String,
        createdTime: Int64,
        updatedTime: Int64,
        images: [DesktopWebReviewImage],
        book: DesktopWebReviewBook
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.images = images
        self.book = book
    }
}

/// Android WebBookReviewDto，用于书内列表、详情和写入结果。
public struct DesktopWebBookReview: Codable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let content: String
    public let wordCount: Int
    public let createdTime: Int64
    public let updatedTime: Int64
    public let images: [DesktopWebReviewImage]

    public init(
        id: Int64,
        title: String,
        content: String,
        wordCount: Int,
        createdTime: Int64,
        updatedTime: Int64,
        images: [DesktopWebReviewImage]
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.wordCount = wordCount
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.images = images
    }
}

/// Android WebReviewDraftDto。
public struct DesktopWebReviewDraft: Codable, Sendable, Equatable {
    public let bookId: Int64
    public let reviewId: Int64
    public let title: String
    public let content: String
    public let imageUrls: [String]
    public let createdTime: Int64?
    public let savedTimeMillis: Int64

    public init(
        bookId: Int64,
        reviewId: Int64,
        title: String,
        content: String,
        imageUrls: [String],
        createdTime: Int64?,
        savedTimeMillis: Int64
    ) {
        self.bookId = bookId
        self.reviewId = reviewId
        self.title = title
        self.content = content
        self.imageUrls = imageUrls
        self.createdTime = createdTime
        self.savedTimeMillis = savedTimeMillis
    }
}

/// Android ReviewDraftUpsertRequest；nil 与空数组语义由 App Adapter 原样保留。
public struct DesktopWebReviewDraftUpsertRequest: Codable, Sendable, Equatable {
    public let bookId: Int64
    public let reviewId: Int64
    public let title: String?
    public let content: String?
    public let imageUrls: [String]?
    public let uploadedTicketIds: [String]?
    public let createdTime: Int64?
    public let savedTimeMillis: Int64?

    public init(
        bookId: Int64,
        reviewId: Int64 = 0,
        title: String? = nil,
        content: String? = nil,
        imageUrls: [String]? = nil,
        uploadedTicketIds: [String]? = nil,
        createdTime: Int64? = nil,
        savedTimeMillis: Int64? = nil
    ) {
        self.bookId = bookId
        self.reviewId = reviewId
        self.title = title
        self.content = content
        self.imageUrls = imageUrls
        self.uploadedTicketIds = uploadedTicketIds
        self.createdTime = createdTime
        self.savedTimeMillis = savedTimeMillis
    }

    private enum CodingKeys: String, CodingKey {
        case bookId, reviewId, title, content, imageUrls, uploadedTicketIds, createdTime, savedTimeMillis
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try container.decode(Int64.self, forKey: .bookId)
        reviewId = try container.decodeIfPresent(Int64.self, forKey: .reviewId) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        imageUrls = try container.decodeIfPresent([String].self, forKey: .imageUrls)
        uploadedTicketIds = try container.decodeIfPresent([String].self, forKey: .uploadedTicketIds)
        createdTime = try container.decodeIfPresent(Int64.self, forKey: .createdTime)
        savedTimeMillis = try container.decodeIfPresent(Int64.self, forKey: .savedTimeMillis)
    }
}

/// Android ReviewCreateRequest。
public struct DesktopWebReviewCreateRequest: Codable, Sendable, Equatable {
    public let bookId: Int64
    public let title: String?
    public let content: String?
    public let imageUrls: [String]?
    public let uploadedTicketIds: [String]?
    public let createdTime: Int64?

    public init(
        bookId: Int64,
        title: String? = nil,
        content: String? = nil,
        imageUrls: [String]? = nil,
        uploadedTicketIds: [String]? = nil,
        createdTime: Int64? = nil
    ) {
        self.bookId = bookId
        self.title = title
        self.content = content
        self.imageUrls = imageUrls
        self.uploadedTicketIds = uploadedTicketIds
        self.createdTime = createdTime
    }
}

/// Android ReviewUpdateRequest；字段缺失表示保留原值，显式空数组表示清空图片。
public struct DesktopWebReviewUpdateRequest: Codable, Sendable, Equatable {
    public let title: String?
    public let content: String?
    public let imageUrls: [String]?
    public let uploadedTicketIds: [String]?
    public let createdTime: Int64?

    public init(
        title: String? = nil,
        content: String? = nil,
        imageUrls: [String]? = nil,
        uploadedTicketIds: [String]? = nil,
        createdTime: Int64? = nil
    ) {
        self.title = title
        self.content = content
        self.imageUrls = imageUrls
        self.uploadedTicketIds = uploadedTicketIds
        self.createdTime = createdTime
    }
}

/// 书评排序设置。
public struct DesktopWebReviewSortRule: Codable, Sendable, Equatable {
    public let sortBy: String
    public let sortOrder: String

    public init(sortBy: String, sortOrder: String) {
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

/// Android ReviewSortRuleUpdateRequest。
public struct DesktopWebReviewSortRuleUpdateRequest: Codable, Sendable, Equatable {
    public let sortBy: String
    public let sortOrder: String

    public init(sortBy: String = "create_time", sortOrder: String = "asc") {
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey { case sortBy, sortOrder }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sortBy = try container.decodeIfPresent(String.self, forKey: .sortBy) ?? "create_time"
        sortOrder = try container.decodeIfPresent(String.self, forKey: .sortOrder) ?? "asc"
    }
}

/// 全局书评查询参数，已由路由应用 Android 默认值和枚举回退。
public struct DesktopWebGlobalReviewFilter: Sendable, Equatable {
    public let keyword: String
    public let bookID: Int64
    public let sortBy: String
    public let sortOrder: String
    public let sortMode: String
    public let excludeIDs: [Int64]

    public init(
        keyword: String,
        bookID: Int64,
        sortBy: String,
        sortOrder: String,
        sortMode: String,
        excludeIDs: [Int64]
    ) {
        self.keyword = keyword
        self.bookID = bookID
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.sortMode = sortMode
        self.excludeIDs = excludeIDs
    }
}

/// 隔离 ReviewController 路由与 App 数据库、草稿设置及业务副作用。
public protocol DesktopWebReviewPort: Sendable {
    func globalReviews(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalReviewFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalReview>
    func reviewDraft(bookID: Int64, reviewID: Int64) async throws -> DesktopWebReviewDraft?
    func upsertReviewDraft(_ request: DesktopWebReviewDraftUpsertRequest) async throws -> DesktopWebReviewDraft
    func deleteReviewDraft(bookID: Int64, reviewID: Int64) async throws
    func bookReviews(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBookReview>
    func bookReviewSortRule(bookID: Int64) async throws -> DesktopWebReviewSortRule
    func updateBookReviewSortRule(
        bookID: Int64,
        request: DesktopWebReviewSortRuleUpdateRequest
    ) async throws -> DesktopWebReviewSortRule
    func review(id: Int64) async throws -> DesktopWebBookReview
    func createReview(_ request: DesktopWebReviewCreateRequest) async throws -> DesktopWebBookReview
    func updateReview(id: Int64, request: DesktopWebReviewUpdateRequest) async throws -> DesktopWebBookReview
    func deleteReview(id: Int64) async throws
}
