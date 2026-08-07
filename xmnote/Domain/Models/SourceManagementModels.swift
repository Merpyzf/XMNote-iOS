/**
 * [INPUT]: 依赖 Foundation，承接 Android SourceEntity 与书籍来源管理页聚合数据
 * [OUTPUT]: 对外提供 SourceManagementScope、SourceManagementItem、SourceManagementSnapshot 与来源管理错误模型
 * [POS]: Domain/Models 的书籍来源管理领域模型，被 Repository、ViewModel 与 Personal 书籍来源管理页共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 来源管理范围，按 Android 预设来源 ID 范围拆分“我的来源”和“默认来源”。
nonisolated enum SourceManagementScope: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case mine
    case appDefault

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mine:
            return "我的来源"
        case .appDefault:
            return "默认来源"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .mine:
            return "用户自定义来源"
        case .appDefault:
            return "应用默认来源"
        }
    }
}

/// 来源管理列表项，包含 Android 来源实体字段和关联书籍数量。
nonisolated struct SourceManagementItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let sourceOrder: Int64
    let bookshelfOrder: Int64
    let isHidden: Bool
    let isAppDefault: Bool
    let associatedBookCount: Int

    /// 组装来源管理展示项，保留排序和隐藏字段供编辑全列更新与排序写回使用。
    init(
        id: Int64,
        name: String,
        sourceOrder: Int64,
        bookshelfOrder: Int64,
        isHidden: Bool,
        isAppDefault: Bool,
        associatedBookCount: Int
    ) {
        self.id = id
        self.name = name
        self.sourceOrder = sourceOrder
        self.bookshelfOrder = bookshelfOrder
        self.isHidden = isHidden
        self.isAppDefault = isAppDefault
        self.associatedBookCount = associatedBookCount
    }
}

/// 来源管理快照，同时承载我的来源与默认来源，保证分段数量和列表来自同一次数据库观察。
nonisolated struct SourceManagementSnapshot: Hashable, Sendable {
    static let empty = SourceManagementSnapshot(mineSources: [], defaultSources: [])

    var mineSources: [SourceManagementItem]
    var defaultSources: [SourceManagementItem]

    /// 按范围返回当前来源列表。
    func sources(for scope: SourceManagementScope) -> [SourceManagementItem] {
        switch scope {
        case .mine:
            return mineSources
        case .appDefault:
            return defaultSources
        }
    }

    /// 返回替换指定范围后的新快照，用于拖拽排序后的本地乐观更新。
    func replacing(_ sources: [SourceManagementItem], for scope: SourceManagementScope) -> SourceManagementSnapshot {
        switch scope {
        case .mine:
            return SourceManagementSnapshot(mineSources: sources, defaultSources: defaultSources)
        case .appDefault:
            return SourceManagementSnapshot(mineSources: mineSources, defaultSources: sources)
        }
    }
}

/// 来源管理仓储错误，统一向 UI 暴露可读的业务失败原因。
nonisolated enum SourceManagementRepositoryError: LocalizedError, Equatable {
    case invalidName
    case invalidNameLength(maxLength: Int)
    case duplicateName
    case invalidSource
    case defaultSourceReadonly
    case emptySelection
    case invalidOrder

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "来源名称不能为空"
        case .invalidNameLength(let maxLength):
            return "来源名称长度不能超过\(maxLength)个字符"
        case .duplicateName:
            return "要添加的来源已经存在了，无法重复添加"
        case .invalidSource:
            return "来源已不存在，请刷新后重试"
        case .defaultSourceReadonly:
            return "默认来源由应用内置，不能在这里修改"
        case .emptySelection:
            return "请选择要删除的来源"
        case .invalidOrder:
            return "来源列表已更新，请重新调整顺序"
        }
    }
}
