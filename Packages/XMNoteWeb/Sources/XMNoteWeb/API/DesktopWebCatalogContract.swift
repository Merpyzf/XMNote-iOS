/**
 * [INPUT]: 依赖 Foundation Codable/Sendable；数据与行为由 App 注入的 Source/Tag 能力端口提供
 * [OUTPUT]: 提供来源、标签 11 个 Web API 使用的平台无关 DTO、请求与能力端口
 * [POS]: XMNoteWeb 的目录数据公共边界；不依赖 App Record、Repository、GRDB 或 HTTP 框架类型
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 来源列表与详情的响应模型，字段和 Android WebSourceDto 保持一致。
public struct DesktopWebSource: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let order: Int
    public let isHidden: Bool
    public let isDefault: Bool
    public let bookCount: Int
    public let createdTime: Int64
    public let updatedTime: Int64

    public init(
        id: Int64,
        name: String,
        order: Int,
        isHidden: Bool,
        isDefault: Bool,
        bookCount: Int,
        createdTime: Int64,
        updatedTime: Int64
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.isHidden = isHidden
        self.isDefault = isDefault
        self.bookCount = bookCount
        self.createdTime = createdTime
        self.updatedTime = updatedTime
    }
}

/// 创建来源请求；名称的 trim、空值和重名规则由 App 侧业务实现裁决。
public struct DesktopWebSourceCreateRequest: Codable, Sendable, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// 局部更新来源请求；nil 字段保持原值，对齐 Android SourceUpdateRequest。
public struct DesktopWebSourceUpdateRequest: Codable, Sendable, Equatable {
    public let name: String?
    public let isHidden: Bool?

    public init(name: String? = nil, isHidden: Bool? = nil) {
        self.name = name
        self.isHidden = isHidden
    }
}

/// 来源与标签共用的排序请求；端口按输入顺序逐项处理，不在 Web 层去重。
public struct DesktopWebOrderRequest: Codable, Sendable, Equatable {
    public let ids: [Int64]

    public init(ids: [Int64]) {
        self.ids = ids
    }
}

/// 隔离来源查询与写入，路由仅负责 HTTP 参数解码和 Android 包络编码。
public protocol DesktopWebSourcePort: Sendable {
    /// 读取有效来源；showAll=false 时排除隐藏项，取消后不产生写入。
    func sources(showAll: Bool) async throws -> [DesktopWebSource]

    /// 按来源 ID 读取详情与有效书籍数量。
    func source(id: Int64) async throws -> DesktopWebSource

    /// 创建来源并返回保存后的完整快照。
    func createSource(_ request: DesktopWebSourceCreateRequest) async throws -> DesktopWebSource

    /// 局部更新来源名称或可见性，并返回更新后的完整快照。
    func updateSource(id: Int64, request: DesktopWebSourceUpdateRequest) async throws -> DesktopWebSource

    /// 删除自定义来源并把有效关联书籍迁回未知来源。
    func deleteSource(id: Int64) async throws

    /// 按输入数组下标逐项写入来源顺序，不对重复或不存在 ID 做预处理。
    func reorderSources(_ request: DesktopWebOrderRequest) async throws
}

/// 标签列表响应模型，保留两类关联数量和 Android 创建时间字段。
public struct DesktopWebTag: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let type: Int
    public let order: Int
    public let noteCount: Int
    public let bookCount: Int
    public let createdTime: Int64

    public init(
        id: Int64,
        name: String,
        type: Int,
        order: Int,
        noteCount: Int,
        bookCount: Int,
        createdTime: Int64
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.order = order
        self.noteCount = noteCount
        self.bookCount = bookCount
        self.createdTime = createdTime
    }
}

/// 标签新增与编辑的响应模型，字段和 Android WebTagResultDto 保持一致。
public struct DesktopWebTagResult: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let type: Int
    public let order: Int

    public init(id: Int64, name: String, type: Int, order: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.order = order
    }
}

/// 创建标签请求；type 仅允许 Android 合同中的 1 或 2。
public struct DesktopWebTagCreateRequest: Codable, Sendable, Equatable {
    public let name: String
    public let type: Int

    public init(name: String, type: Int) {
        self.name = name
        self.type = type
    }
}

/// 更新标签请求；Android 合同要求 name 必填。
public struct DesktopWebTagUpdateRequest: Codable, Sendable, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// 隔离标签查询与写入，保留 Android Web 独立于 App 标签管理页的既有语义。
public protocol DesktopWebTagPort: Sendable {
    /// 读取有效标签；type=0 返回全部类型，其他值按原值过滤。
    func tags(type: Int) async throws -> [DesktopWebTag]

    /// 创建标签并返回新增 ID、类型和排序值。
    func createTag(_ request: DesktopWebTagCreateRequest) async throws -> DesktopWebTagResult

    /// 更新标签名称并返回原类型与原排序值。
    func updateTag(id: Int64, request: DesktopWebTagUpdateRequest) async throws -> DesktopWebTagResult

    /// 软删除标签并按 Android Web 行为物理删除两类关联。
    func deleteTag(id: Int64) async throws

    /// 按输入数组下标逐项写入标签顺序，不限制标签类型或 owner。
    func reorderTags(_ request: DesktopWebOrderRequest) async throws
}
