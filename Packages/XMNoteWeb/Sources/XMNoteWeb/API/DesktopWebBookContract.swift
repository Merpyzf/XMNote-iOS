/**
 * [INPUT]: 依赖 Foundation Codable/Sendable 与共享 DesktopWebBook/PageResult DTO
 * [OUTPUT]: 提供 19 个 Book API 的统计、筛选、分区、单书与批量写入模型和 App 能力端口
 * [POS]: XMNoteWeb 书籍公共边界；只表达 Android Web 合同，不依赖 App Record、Repository 或 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android WebBookStatsDto 的完整响应合同。
public struct DesktopWebBookStats: Codable, Sendable, Equatable {
    public let total: Int
    public let reading: Int
    public let want: Int
    public let read: Int
    public let dropped: Int
    public let hold: Int

    public init(
        total: Int,
        reading: Int,
        want: Int,
        read: Int,
        dropped: Int,
        hold: Int
    ) {
        self.total = total
        self.reading = reading
        self.want = want
        self.read = read
        self.dropped = dropped
        self.hold = hold
    }
}

/// Android BookFilter 的路由归一化结果，保留重复标签 ID 等可观察边界。
public struct DesktopWebBookFilter: Sendable, Equatable {
    public let keyword: String
    public let status: Int
    public let groupID: Int64
    public let tagIDs: [Int64]
    public let tagMode: String
    public let sourceIDs: [Int64]

    public init(
        keyword: String,
        status: Int,
        groupID: Int64,
        tagIDs: [Int64],
        tagMode: String,
        sourceIDs: [Int64]
    ) {
        self.keyword = keyword
        self.status = status
        self.groupID = groupID
        self.tagIDs = tagIDs
        self.tagMode = tagMode
        self.sourceIDs = sourceIDs
    }
}

/// 置顶分组卡的单本预览书籍。
public struct DesktopWebGroupPreviewBook: Codable, Sendable, Equatable {
    public let bookId: Int64
    public let cover: String

    public init(bookId: Int64, cover: String) {
        self.bookId = bookId
        self.cover = cover
    }
}

/// Android WebBookshelfGroupDto 的完整响应合同。
public struct DesktopWebBookshelfGroup: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let isPinned: Bool
    public let pinOrder: Int
    public let order: Int
    public let bookCount: Int
    public let createdTime: Int64
    public let covers: [String]
    public let previewBooks: [DesktopWebGroupPreviewBook]

    public init(
        id: Int64,
        name: String,
        isPinned: Bool,
        pinOrder: Int,
        order: Int,
        bookCount: Int,
        createdTime: Int64,
        covers: [String],
        previewBooks: [DesktopWebGroupPreviewBook]
    ) {
        self.id = id
        self.name = name
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.order = order
        self.bookCount = bookCount
        self.createdTime = createdTime
        self.covers = covers
        self.previewBooks = previewBooks
    }
}

/// Android WebBookSectionDto，置顶区可同时承载书籍和分组卡。
public struct DesktopWebBookSection: Codable, Sendable, Equatable {
    public let title: String
    public let count: Int
    public let books: [DesktopWebBook]
    public let groups: [DesktopWebBookshelfGroup]

    public init(
        title: String,
        count: Int,
        books: [DesktopWebBook],
        groups: [DesktopWebBookshelfGroup] = []
    ) {
        self.title = title
        self.count = count
        self.books = books
        self.groups = groups
    }
}

/// Android WebBookSectionResult 的全量分区响应。
public struct DesktopWebBookSectionResult: Codable, Sendable, Equatable {
    public let sections: [DesktopWebBookSection]
    public let total: Int

    public init(sections: [DesktopWebBookSection], total: Int) {
        self.sections = sections
        self.total = total
    }
}

/// Android BookPinRequest 的置顶请求合同。
public struct DesktopWebBookPinRequest: Codable, Sendable, Equatable {
    public let pinned: Bool
    public let groupId: Int64?

    public init(pinned: Bool, groupId: Int64? = nil) {
        self.pinned = pinned
        self.groupId = groupId
    }
}

/// Android WebBookPinResultDto 的置顶结果合同。
public struct DesktopWebBookPinResult: Codable, Sendable, Equatable {
    public let id: Int64
    public let isPinned: Bool
    public let pinOrder: Int

    public init(id: Int64, isPinned: Bool, pinOrder: Int) {
        self.id = id
        self.isPinned = isPinned
        self.pinOrder = pinOrder
    }
}

/// Android BookCreateRequest 的完整请求合同；缺省值由 Codable 按 Kotlin data class 语义补齐。
public struct DesktopWebBookCreateRequest: Codable, Sendable, Equatable {
    public let name: String
    public let rawName: String?
    public let author: String?
    public let cover: String?
    public let authorIntro: String?
    public let translator: String?
    public let summary: String?
    public let isbn: String?
    public let press: String?
    public let pubDate: String?
    public let doubanId: Int?
    public let readStatus: Int
    public let readStatusChangedTime: Int64?
    public let score: Int?
    public let type: Int?
    public let positionUnit: Int?
    public let readPosition: Double?
    public let totalPosition: Int?
    public let totalPagination: Int?
    public let sourceId: Int64?
    public let purchaseDate: Int64?
    public let price: Float?
    public let wordCount: Int64?
    public let catalog: String?
    public let tagIds: [Int64]?
    public let groupId: Int64?
    public let isDeleted: Bool?
    public let creationMode: String?

    public init(
        name: String,
        rawName: String? = nil,
        author: String? = nil,
        cover: String? = nil,
        authorIntro: String? = nil,
        translator: String? = nil,
        summary: String? = nil,
        isbn: String? = nil,
        press: String? = nil,
        pubDate: String? = nil,
        doubanId: Int? = nil,
        readStatus: Int = 1,
        readStatusChangedTime: Int64? = nil,
        score: Int? = nil,
        type: Int? = nil,
        positionUnit: Int? = nil,
        readPosition: Double? = nil,
        totalPosition: Int? = nil,
        totalPagination: Int? = nil,
        sourceId: Int64? = nil,
        purchaseDate: Int64? = nil,
        price: Float? = nil,
        wordCount: Int64? = nil,
        catalog: String? = nil,
        tagIds: [Int64]? = nil,
        groupId: Int64? = nil,
        isDeleted: Bool? = nil,
        creationMode: String? = nil
    ) {
        self.name = name
        self.rawName = rawName
        self.author = author
        self.cover = cover
        self.authorIntro = authorIntro
        self.translator = translator
        self.summary = summary
        self.isbn = isbn
        self.press = press
        self.pubDate = pubDate
        self.doubanId = doubanId
        self.readStatus = readStatus
        self.readStatusChangedTime = readStatusChangedTime
        self.score = score
        self.type = type
        self.positionUnit = positionUnit
        self.readPosition = readPosition
        self.totalPosition = totalPosition
        self.totalPagination = totalPagination
        self.sourceId = sourceId
        self.purchaseDate = purchaseDate
        self.price = price
        self.wordCount = wordCount
        self.catalog = catalog
        self.tagIds = tagIds
        self.groupId = groupId
        self.isDeleted = isDeleted
        self.creationMode = creationMode
    }

    private enum CodingKeys: String, CodingKey {
        case name, rawName, author, cover, authorIntro, translator, summary, isbn, press, pubDate
        case doubanId, readStatus, readStatusChangedTime, score, type, positionUnit, readPosition
        case totalPosition, totalPagination, sourceId, purchaseDate, price, wordCount, catalog
        case tagIds, groupId, isDeleted, creationMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        rawName = try container.decodeIfPresent(String.self, forKey: .rawName)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        authorIntro = try container.decodeIfPresent(String.self, forKey: .authorIntro)
        translator = try container.decodeIfPresent(String.self, forKey: .translator)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        isbn = try container.decodeIfPresent(String.self, forKey: .isbn)
        press = try container.decodeIfPresent(String.self, forKey: .press)
        pubDate = try container.decodeIfPresent(String.self, forKey: .pubDate)
        doubanId = try container.decodeIfPresent(Int.self, forKey: .doubanId)
        readStatus = try container.decodeIfPresent(Int.self, forKey: .readStatus) ?? 1
        readStatusChangedTime = try container.decodeIfPresent(Int64.self, forKey: .readStatusChangedTime)
        score = try container.decodeIfPresent(Int.self, forKey: .score)
        type = try container.decodeIfPresent(Int.self, forKey: .type)
        positionUnit = try container.decodeIfPresent(Int.self, forKey: .positionUnit)
        readPosition = try container.decodeIfPresent(Double.self, forKey: .readPosition)
        totalPosition = try container.decodeIfPresent(Int.self, forKey: .totalPosition)
        totalPagination = try container.decodeIfPresent(Int.self, forKey: .totalPagination)
        sourceId = try container.decodeIfPresent(Int64.self, forKey: .sourceId)
        purchaseDate = try container.decodeIfPresent(Int64.self, forKey: .purchaseDate)
        price = try container.decodeIfPresent(Float.self, forKey: .price)
        wordCount = try container.decodeIfPresent(Int64.self, forKey: .wordCount)
        catalog = try container.decodeIfPresent(String.self, forKey: .catalog)
        tagIds = try container.decodeIfPresent([Int64].self, forKey: .tagIds)
        groupId = try container.decodeIfPresent(Int64.self, forKey: .groupId)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted)
        creationMode = try container.decodeIfPresent(String.self, forKey: .creationMode)
    }
}

/// Android BookUpdateRequest 的局部更新合同；显式清空 wordCount 由 clearWordCount 单独表达。
public struct DesktopWebBookUpdateRequest: Codable, Sendable, Equatable {
    public let name: String?
    public let rawName: String?
    public let author: String?
    public let cover: String?
    public let authorIntro: String?
    public let translator: String?
    public let summary: String?
    public let isbn: String?
    public let press: String?
    public let pubDate: String?
    public let doubanId: Int?
    public let readStatus: Int?
    public let readStatusChangedTime: Int64?
    public let score: Int?
    public let type: Int?
    public let positionUnit: Int?
    public let readPosition: Double?
    public let totalPosition: Int?
    public let totalPagination: Int?
    public let sourceId: Int64?
    public let purchaseDate: Int64?
    public let price: Float?
    public let wordCount: Int64?
    public let clearWordCount: Bool?
    public let catalog: String?
    public let tagIds: [Int64]?
    public let groupId: Int64?

    public init(
        name: String? = nil,
        rawName: String? = nil,
        author: String? = nil,
        cover: String? = nil,
        authorIntro: String? = nil,
        translator: String? = nil,
        summary: String? = nil,
        isbn: String? = nil,
        press: String? = nil,
        pubDate: String? = nil,
        doubanId: Int? = nil,
        readStatus: Int? = nil,
        readStatusChangedTime: Int64? = nil,
        score: Int? = nil,
        type: Int? = nil,
        positionUnit: Int? = nil,
        readPosition: Double? = nil,
        totalPosition: Int? = nil,
        totalPagination: Int? = nil,
        sourceId: Int64? = nil,
        purchaseDate: Int64? = nil,
        price: Float? = nil,
        wordCount: Int64? = nil,
        clearWordCount: Bool? = nil,
        catalog: String? = nil,
        tagIds: [Int64]? = nil,
        groupId: Int64? = nil
    ) {
        self.name = name
        self.rawName = rawName
        self.author = author
        self.cover = cover
        self.authorIntro = authorIntro
        self.translator = translator
        self.summary = summary
        self.isbn = isbn
        self.press = press
        self.pubDate = pubDate
        self.doubanId = doubanId
        self.readStatus = readStatus
        self.readStatusChangedTime = readStatusChangedTime
        self.score = score
        self.type = type
        self.positionUnit = positionUnit
        self.readPosition = readPosition
        self.totalPosition = totalPosition
        self.totalPagination = totalPagination
        self.sourceId = sourceId
        self.purchaseDate = purchaseDate
        self.price = price
        self.wordCount = wordCount
        self.clearWordCount = clearWordCount
        self.catalog = catalog
        self.tagIds = tagIds
        self.groupId = groupId
    }
}

/// Android BookBatchDeleteRequest 的原始 ID 序列合同。
public struct DesktopWebBookBatchDeleteRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]

    public init(ids: [Int64]) {
        self.ids = ids
    }
}

/// Android BookBatchPinRequest，重复 ID 与可选分组作用域均原样保留。
public struct DesktopWebBookBatchPinRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let pinned: Bool
    public let groupId: Int64?

    public init(ids: [Int64], pinned: Bool, groupId: Int64? = nil) {
        self.ids = ids
        self.pinned = pinned
        self.groupId = groupId
    }
}

/// Android BookBatchUpdateRequest 的局部批量变更合同。
public struct DesktopWebBookBatchUpdateRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let readStatus: Int?
    public let readStatusChangedTime: Int64?
    public let sourceId: Int64?
    public let groupId: Int64?
    public let addTagIds: [Int64]?

    public init(
        ids: [Int64],
        readStatus: Int? = nil,
        readStatusChangedTime: Int64? = nil,
        sourceId: Int64? = nil,
        groupId: Int64? = nil,
        addTagIds: [Int64]? = nil
    ) {
        self.ids = ids
        self.readStatus = readStatus
        self.readStatusChangedTime = readStatusChangedTime
        self.sourceId = sourceId
        self.groupId = groupId
        self.addTagIds = addTagIds
    }
}

/// Android BookBatchSetTagsRequest；缺省 mode 必须按 Kotlin 默认值补为 append。
public struct DesktopWebBookBatchSetTagsRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let tagIds: [Int64]
    public let mode: String

    public init(ids: [Int64], tagIds: [Int64], mode: String = "append") {
        self.ids = ids
        self.tagIds = tagIds
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case ids, tagIds, mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ids = try container.decode([Int64].self, forKey: .ids)
        tagIds = try container.decode([Int64].self, forKey: .tagIds)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "append"
    }
}

/// 单本书的最终标签集合，批量替换会按最后一次同 ID 输入覆盖。
public struct DesktopWebBookBatchReplaceTagsItemRequest: Codable, Sendable, Equatable {
    public let id: Int64
    public let tagIds: [Int64]

    public init(id: Int64, tagIds: [Int64]) {
        self.id = id
        self.tagIds = tagIds
    }
}

/// Android BookBatchReplaceTagsRequest 的逐书精确替换合同。
public struct DesktopWebBookBatchReplaceTagsRequest: Codable, Sendable, Equatable {
    public let items: [DesktopWebBookBatchReplaceTagsItemRequest]

    public init(items: [DesktopWebBookBatchReplaceTagsItemRequest]) {
        self.items = items
    }
}

/// Android BookBatchMoveToGroupRequest，sourceGroupId 只参与同组短路判断。
public struct DesktopWebBookBatchMoveToGroupRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let targetGroupId: Int64
    public let sourceGroupId: Int64?

    public init(ids: [Int64], targetGroupId: Int64, sourceGroupId: Int64? = nil) {
        self.ids = ids
        self.targetGroupId = targetGroupId
        self.sourceGroupId = sourceGroupId
    }
}

/// Android BookBatchMoveOutRequest；缺省 placeAtEnd 必须按 Kotlin 默认值补为 true。
public struct DesktopWebBookBatchMoveOutRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]
    public let placeAtEnd: Bool

    public init(ids: [Int64], placeAtEnd: Bool = true) {
        self.ids = ids
        self.placeAtEnd = placeAtEnd
    }

    private enum CodingKeys: String, CodingKey {
        case ids, placeAtEnd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ids = try container.decode([Int64].self, forKey: .ids)
        placeAtEnd = try container.decodeIfPresent(Bool.self, forKey: .placeAtEnd) ?? true
    }
}

/// 隔离 Android Web 的只读书籍查询，使 Package 路由不接触 App 数据层。
public protocol DesktopWebBookPort: Sendable {
    /// 汇总全部有效且非占位书籍的阅读状态。
    func bookStats() async throws -> DesktopWebBookStats

    /// 读取单本有效书籍的完整 Web DTO。
    func book(id: Int64) async throws -> DesktopWebBook

    /// 按 Android 组合筛选与十类排序规则分页读取书籍。
    func books(
        page: Int,
        pageSize: Int,
        filter: DesktopWebBookFilter,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook>

    /// 按 Android 五类 section 规则返回全量书籍，并在默认书架口径合并置顶分组。
    func bookSections(
        filter: DesktopWebBookFilter,
        sectionBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebBookSectionResult

    /// 按最近阅读行为倒序分页读取在读书籍。
    func recentReadBooks(page: Int, pageSize: Int) async throws -> DesktopWebPageResult<DesktopWebBook>

    /// 读取最近创建书摘所属书籍；没有有效书摘时返回 nil。
    func lastNoteBook() async throws -> DesktopWebBook?

    /// 按 pinOrder 升序分页读取置顶书籍。
    func pinnedBooks(page: Int, pageSize: Int) async throws -> DesktopWebPageResult<DesktopWebBook>

    /// 按 Android 普通书籍排序规则分页读取未分组且非置顶书籍。
    func ungroupedBooks(
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook>

    /// 软删除书籍并执行 Android App Repository 的关联清理事务。
    func deleteBook(id: Int64) async throws

    /// 幂等更新全局置顶字段，groupId 仅决定新增 pinOrder 的计算作用域。
    func updateBookPin(
        id: Int64,
        request: DesktopWebBookPinRequest
    ) async throws -> DesktopWebBookPinResult

    /// 将软删除书籍恢复到默认书架，并追加在读状态记录。
    func addToBookshelf(id: Int64) async throws -> DesktopWebBook

    /// 按 Android Web 单事务创建书籍、章节、状态历史及关系。
    func createBook(_ request: DesktopWebBookCreateRequest) async throws -> DesktopWebBook

    /// 局部更新有效书籍，并按 Android 的非事务顺序同步状态、标签和主分组。
    func updateBook(
        id: Int64,
        request: DesktopWebBookUpdateRequest
    ) async throws -> DesktopWebBook

    /// 逐本执行 Android App 的 17 步删除事务，缺失或已删除 ID 静默跳过。
    func batchDeleteBooks(_ request: DesktopWebBookBatchDeleteRequest) async throws

    /// 按请求顺序批量切换置顶状态，重复或无效 ID 保留 Android 的幂等/跳过语义。
    func batchPinBooks(_ request: DesktopWebBookBatchPinRequest) async throws

    /// 批量修改阅读状态、来源、主分组并追加标签，保留跨书与跨步骤非事务行为。
    func batchUpdateBooks(_ request: DesktopWebBookBatchUpdateRequest) async throws

    /// 以 append 或 replace 模式原子更新多本书的标签集合。
    func batchSetBookTags(_ request: DesktopWebBookBatchSetTagsRequest) async throws

    /// 校验全部书籍和标签后，在单一事务中精确替换逐书标签集合。
    func batchReplaceBookTags(_ request: DesktopWebBookBatchReplaceTagsRequest) async throws

    /// 在单一事务中把有效书籍移至目标分组并取消置顶。
    func batchMoveToGroup(_ request: DesktopWebBookBatchMoveToGroupRequest) async throws

    /// 按头尾顺序逐本移出全部分组，保留每本四步非事务写入。
    func batchMoveOut(_ request: DesktopWebBookBatchMoveOutRequest) async throws
}
