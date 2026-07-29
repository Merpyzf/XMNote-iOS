/**
 * [INPUT]: 依赖 Foundation Codable/Sendable；数据与行为由 App 注入的 Group 能力端口提供
 * [OUTPUT]: 提供分组 8 个 Web API 使用的平台无关 DTO、请求、分页结果与能力端口
 * [POS]: XMNoteWeb 的分组公共边界；完整书籍 DTO 可被后续 Book 路由复用，但不依赖 App Record 或 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android PageResult 使用的分页元数据，total 保持 Long 对应的 Int64。
public struct DesktopWebPagination: Codable, Sendable, Equatable {
    public let page: Int
    public let pageSize: Int
    public let total: Int64
    public let totalPages: Int

    public init(page: Int, pageSize: Int, total: Int64, totalPages: Int) {
        self.page = page
        self.pageSize = pageSize
        self.total = total
        self.totalPages = totalPages
    }
}

/// Android PageResult 的通用响应外形，供列表接口共享。
public struct DesktopWebPageResult<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let pagination: DesktopWebPagination

    public init(items: [Item], pagination: DesktopWebPagination) {
        self.items = items
        self.pagination = pagination
    }
}

/// 书籍所处分组的轻量投影，字段与 WebGroupSimpleDto 一致。
public struct DesktopWebBookGroup: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// 书籍标签的轻量投影，字段与 WebTagDto 一致。
public struct DesktopWebBookTag: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// Android WebBookDto 的完整可观察响应合同。
public struct DesktopWebBook: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let rawName: String
    public let cover: String
    public let author: String
    public let authorIntro: String
    public let translator: String
    public let summary: String
    public let isbn: String
    public let press: String
    public let pubDate: String
    public let doubanId: Int?
    public let readStatus: Int
    public let readStatusChangedTime: Int64
    public let recentReadTime: Int64?
    public let readDoneCount: Int
    public let score: Int
    public let readPosition: Double
    public let totalPosition: Int
    public let totalPagination: Int
    public let currentPositionUnit: Int
    public let positionUnit: Int
    public let type: Int
    public let sourceId: Int64
    public let sourceName: String
    public let purchaseDate: Int64?
    public let price: Double?
    public let isPinned: Bool
    public let pinOrder: Int
    public let order: Int
    public let wordCount: Int64?
    public let totalReadingTime: Int64
    public let createdTime: Int64
    public let updatedTime: Int64
    public let lastModifiedTime: Int64?
    public let noteCount: Int
    public let reviewCount: Int
    public let relevantCount: Int
    public let readDoneTime: Int64?
    public let bookmarkModifiedTime: Int64?
    public let groups: [DesktopWebBookGroup]
    public let tags: [DesktopWebBookTag]
    public let isDeleted: Bool
    public let searchSource: String
    public let isInBookshelf: Bool
    public let fromRelatedContentBook: Bool

    public init(
        id: Int64,
        name: String,
        rawName: String,
        cover: String,
        author: String,
        authorIntro: String,
        translator: String,
        summary: String,
        isbn: String,
        press: String,
        pubDate: String,
        doubanId: Int?,
        readStatus: Int,
        readStatusChangedTime: Int64,
        recentReadTime: Int64? = nil,
        readDoneCount: Int,
        score: Int,
        readPosition: Double,
        totalPosition: Int,
        totalPagination: Int,
        currentPositionUnit: Int,
        positionUnit: Int,
        type: Int,
        sourceId: Int64,
        sourceName: String,
        purchaseDate: Int64?,
        price: Double?,
        isPinned: Bool,
        pinOrder: Int,
        order: Int,
        wordCount: Int64?,
        totalReadingTime: Int64,
        createdTime: Int64,
        updatedTime: Int64,
        lastModifiedTime: Int64?,
        noteCount: Int,
        reviewCount: Int,
        relevantCount: Int,
        readDoneTime: Int64?,
        bookmarkModifiedTime: Int64?,
        groups: [DesktopWebBookGroup],
        tags: [DesktopWebBookTag],
        isDeleted: Bool,
        searchSource: String = "bookshelf",
        isInBookshelf: Bool = true,
        fromRelatedContentBook: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rawName = rawName
        self.cover = cover
        self.author = author
        self.authorIntro = authorIntro
        self.translator = translator
        self.summary = summary
        self.isbn = isbn
        self.press = press
        self.pubDate = pubDate
        self.doubanId = doubanId
        self.readStatus = readStatus
        self.readStatusChangedTime = readStatusChangedTime
        self.recentReadTime = recentReadTime
        self.readDoneCount = readDoneCount
        self.score = score
        self.readPosition = readPosition
        self.totalPosition = totalPosition
        self.totalPagination = totalPagination
        self.currentPositionUnit = currentPositionUnit
        self.positionUnit = positionUnit
        self.type = type
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.purchaseDate = purchaseDate
        self.price = price
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.order = order
        self.wordCount = wordCount
        self.totalReadingTime = totalReadingTime
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.lastModifiedTime = lastModifiedTime
        self.noteCount = noteCount
        self.reviewCount = reviewCount
        self.relevantCount = relevantCount
        self.readDoneTime = readDoneTime
        self.bookmarkModifiedTime = bookmarkModifiedTime
        self.groups = groups
        self.tags = tags
        self.isDeleted = isDeleted
        self.searchSource = searchSource
        self.isInBookshelf = isInBookshelf
        self.fromRelatedContentBook = fromRelatedContentBook
    }
}

/// 分组列表及写操作返回模型，字段与 WebGroupListDto 一致。
public struct DesktopWebGroup: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let isPinned: Bool
    public let pinOrder: Int
    public let order: Int
    public let bookCount: Int
    public let createdTime: Int64

    public init(
        id: Int64,
        name: String,
        isPinned: Bool,
        pinOrder: Int,
        order: Int,
        bookCount: Int,
        createdTime: Int64
    ) {
        self.id = id
        self.name = name
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.order = order
        self.bookCount = bookCount
        self.createdTime = createdTime
    }
}

/// 创建分组请求；名称校验由 App 侧 Android 兼容仓储完成。
public struct DesktopWebGroupCreateRequest: Codable, Sendable, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// 更新分组请求；Android 合同要求 name 必填。
public struct DesktopWebGroupUpdateRequest: Codable, Sendable, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// 更新分组置顶状态请求。
public struct DesktopWebGroupPinRequest: Codable, Sendable, Equatable {
    public let pinned: Bool

    public init(pinned: Bool) {
        self.pinned = pinned
    }
}

/// 隔离分组查询与写入，保留 Android Web 独立于 App 分组管理的可观察语义。
public protocol DesktopWebGroupPort: Sendable {
    /// 分页读取全部有效分组及有效书籍计数。
    func groups(page: Int, pageSize: Int) async throws -> DesktopWebPageResult<DesktopWebGroup>

    /// 读取并按 Android 规则排序、分页、聚合指定分组的完整书籍 DTO。
    func booksInGroup(
        id: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook>

    /// 创建分组并返回未包含书籍详情的结果。
    func createGroup(_ request: DesktopWebGroupCreateRequest) async throws -> DesktopWebGroup

    /// 更新有效分组名称并返回当前统计结果。
    func updateGroup(id: Int64, request: DesktopWebGroupUpdateRequest) async throws -> DesktopWebGroup

    /// 将组内书籍逐本移回默认书架，再软删除关系与分组。
    func deleteGroup(id: Int64, placeAtEnd: Bool) async throws

    /// 更新分组置顶状态并返回持久化后的结果。
    func updateGroupPin(id: Int64, request: DesktopWebGroupPinRequest) async throws -> DesktopWebGroup

    /// 按原始输入顺序逐项更新分组排序。
    func reorderGroups(_ request: DesktopWebOrderRequest) async throws

    /// 规范化书籍 ID 后更新指定分组内书籍排序。
    func reorderGroupBooks(groupID: Int64, request: DesktopWebOrderRequest) async throws
}
