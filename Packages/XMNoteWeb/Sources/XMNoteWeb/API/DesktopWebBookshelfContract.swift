/**
 * [INPUT]: 依赖共享 DesktopWebBook、DesktopWebBookshelfGroup 与分页 DTO
 * [OUTPUT]: 提供 BookshelfController 7 个 API 的混排模型、请求合同与 App 能力端口
 * [POS]: XMNoteWeb 书架公共边界；只表达 Android Web 合同，不依赖 App 数据库或 UI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android WebBookshelfItem 的混排响应；无关的 book/group 字段按 Gson 语义省略。
public struct DesktopWebBookshelfItem: Codable, Sendable, Equatable {
    public let type: String
    public let book: DesktopWebBook?
    public let group: DesktopWebBookshelfGroup?

    public init(
        type: String,
        book: DesktopWebBook? = nil,
        group: DesktopWebBookshelfGroup? = nil
    ) {
        self.type = type
        self.book = book
        self.group = group
    }
}

/// Android WebBookshelfManifestItem 的轻量混排顺序合同。
public struct DesktopWebBookshelfManifestItem: Codable, Sendable, Equatable {
    public let type: String
    public let id: Int64
    public let isPinned: Bool
    public let pinOrder: Int
    public let order: Int

    public init(type: String, id: Int64, isPinned: Bool, pinOrder: Int, order: Int) {
        self.type = type
        self.id = id
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.order = order
    }
}

/// Android BookshelfPinnedGroupsMetaDto，bookIds 按首次出现顺序去重。
public struct DesktopWebBookshelfPinnedGroupsMeta: Codable, Sendable, Equatable {
    public let groups: [DesktopWebBookshelfGroup]
    public let bookIds: [Int64]

    public init(groups: [DesktopWebBookshelfGroup], bookIds: [Int64]) {
        self.groups = groups
        self.bookIds = bookIds
    }
}

/// 书架混排项引用；type 保留原始大小写和未知值，由业务层按 Android 规则处理。
public struct DesktopWebBookshelfItemRef: Codable, Sendable, Equatable {
    public let type: String
    public let id: Int64

    public init(type: String, id: Int64) {
        self.type = type
        self.id = id
    }
}

/// POST items/query 请求；缺失的组内排序字段使用 Kotlin data class 默认值。
public struct DesktopWebBookshelfItemsQueryRequest: Codable, Sendable, Equatable {
    public let items: [DesktopWebBookshelfItemRef]
    public let groupSortBy: String
    public let groupSortOrder: String
    public let groupEnableSection: Bool

    public init(
        items: [DesktopWebBookshelfItemRef],
        groupSortBy: String = "custom",
        groupSortOrder: String = "desc",
        groupEnableSection: Bool = false
    ) {
        self.items = items
        self.groupSortBy = groupSortBy
        self.groupSortOrder = groupSortOrder
        self.groupEnableSection = groupEnableSection
    }

    private enum CodingKeys: String, CodingKey {
        case items, groupSortBy, groupSortOrder, groupEnableSection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([DesktopWebBookshelfItemRef].self, forKey: .items)
        groupSortBy = try container.decodeIfPresent(String.self, forKey: .groupSortBy) ?? "custom"
        groupSortOrder = try container.decodeIfPresent(String.self, forKey: .groupSortOrder) ?? "desc"
        groupEnableSection = try container.decodeIfPresent(Bool.self, forKey: .groupEnableSection) ?? false
    }
}

/// POST move 请求；placement 必填，空 movedItems 由服务层直接成功返回。
public struct DesktopWebBookshelfMoveRequest: Codable, Sendable, Equatable {
    public let movedItems: [DesktopWebBookshelfItemRef]
    public let anchorItem: DesktopWebBookshelfItemRef?
    public let placement: String

    public init(
        movedItems: [DesktopWebBookshelfItemRef],
        anchorItem: DesktopWebBookshelfItemRef? = nil,
        placement: String
    ) {
        self.movedItems = movedItems
        self.anchorItem = anchorItem
        self.placement = placement
    }
}

/// PUT order 请求；重复、未知类型与越界 ID 均不在 HTTP 层归一化。
public struct DesktopWebBookshelfReorderRequest: Codable, Sendable, Equatable {
    public let items: [DesktopWebBookshelfItemRef]

    public init(items: [DesktopWebBookshelfItemRef]) {
        self.items = items
    }
}

/// 隔离书架混排查询与排序写入；实现由 App Repository 提供，不向 Package 暴露数据库类型。
public protocol DesktopWebBookshelfPort: Sendable {
    func bookshelf(
        page: Int,
        pageSize: Int,
        keyword: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebPageResult<DesktopWebBookshelfItem>

    func sortedBookshelf(
        page: Int,
        pageSize: Int,
        keyword: String,
        sortBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebPageResult<DesktopWebBookshelfItem>

    func bookshelfManifest() async throws -> [DesktopWebBookshelfManifestItem]

    func bookshelfPinnedGroupsMeta(
        sortBy: String,
        sortOrder: String,
        enableSection: Bool,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool,
        layout: String
    ) async throws -> DesktopWebBookshelfPinnedGroupsMeta

    func queryBookshelfItems(
        _ request: DesktopWebBookshelfItemsQueryRequest
    ) async throws -> [DesktopWebBookshelfItem]

    func moveBookshelfItems(_ request: DesktopWebBookshelfMoveRequest) async throws

    func reorderBookshelf(_ request: DesktopWebBookshelfReorderRequest) async throws
}
