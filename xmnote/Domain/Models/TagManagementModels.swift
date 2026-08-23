/**
 * [INPUT]: 依赖 Foundation，承接 Android TagType 与标签管理页聚合数据
 * [OUTPUT]: 对外提供 TagManagementScope、TagCatalogMutation、TagManagementItem、TagManagementSnapshot 与标签管理错误模型
 * [POS]: Domain/Models 的标签管理领域模型，被 Repository、ViewModel、Personal 标签管理页与业务标签选择器共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 标签管理范围，对齐 Android AppConstant.TagType：1=书摘标签、2=书籍标签。
nonisolated enum TagManagementScope: Int64, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case note = 1
    case book = 2

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .note:
            return "书摘"
        case .book:
            return "书籍"
        }
    }

    var tagTitle: String {
        "\(title)标签"
    }

    var associatedItemTitle: String {
        switch self {
        case .note:
            return "书摘"
        case .book:
            return "书籍"
        }
    }

    var deleteMessage: String {
        switch self {
        case .note:
            return "删除标签将解除与书摘的关联，你确定要继续吗？"
        case .book:
            return "删除标签将解除与书籍的关联，你确定要继续吗？"
        }
    }
}

/// 标签目录完成一次全局写入后的领域事件，供复用标签选择器同步各页面现有内存快照。
nonisolated enum TagCatalogMutation: Hashable, Sendable {
    case renamed(scope: TagManagementScope, id: Int64, title: String)
    case deleted(scope: TagManagementScope, id: Int64)

    var scope: TagManagementScope {
        switch self {
        case .renamed(let scope, _, _), .deleted(let scope, _):
            return scope
        }
    }

    /// 将书摘标签目录变更投影到编辑器/回顾共用选项，保持未命中项的身份与原有顺序。
    func applying(to options: [NoteEditorTagOption]) -> [NoteEditorTagOption] {
        guard scope == .note else { return options }
        switch self {
        case .renamed(_, let id, let title):
            return options.map { option in
                guard option.id == id else { return option }
                return NoteEditorTagOption(id: id, title: title)
            }
        case .deleted(_, let id):
            return options.filter { $0.id != id }
        }
    }

    /// 将书摘标签目录变更投影到带关联数量的回顾筛选选项，名称变化不改写既有计数。
    func applying(to options: [NoteReviewTagOption]) -> [NoteReviewTagOption] {
        guard scope == .note else { return options }
        switch self {
        case .renamed(_, let id, let title):
            return options.map { option in
                guard option.id == id else { return option }
                return NoteReviewTagOption(id: id, title: title, noteCount: option.noteCount)
            }
        case .deleted(_, let id):
            return options.filter { $0.id != id }
        }
    }

    /// 将书摘标签目录变更投影到二级列表标签快照，保留排序字段供卡片展示稳定复用。
    func applying(to items: [NoteExcerptTagItem]) -> [NoteExcerptTagItem] {
        guard scope == .note else { return items }
        switch self {
        case .renamed(_, let id, let title):
            return items.map { item in
                guard item.id == id else { return item }
                return NoteExcerptTagItem(id: id, title: title, order: item.order)
            }
        case .deleted(_, let id):
            return items.filter { $0.id != id }
        }
    }
}

/// 标签管理列表项，包含 Android 标签实体字段和标签关联数量。
nonisolated struct TagManagementItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let color: Int64
    let order: Int64
    let associatedCount: Int

    /// 组装标签管理展示项，保留 color/order 供编辑全列更新与排序写回使用。
    init(id: Int64, name: String, color: Int64, order: Int64, associatedCount: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.order = order
        self.associatedCount = associatedCount
    }
}

/// 标签管理快照，同时承载书摘与书籍两类标签，保证分段数量和列表来自同一次数据库观察。
nonisolated struct TagManagementSnapshot: Hashable, Sendable {
    static let empty = TagManagementSnapshot(noteTags: [], bookTags: [])

    var noteTags: [TagManagementItem]
    var bookTags: [TagManagementItem]

    /// 按范围返回当前标签列表。
    func tags(for scope: TagManagementScope) -> [TagManagementItem] {
        switch scope {
        case .note:
            return noteTags
        case .book:
            return bookTags
        }
    }

    /// 返回替换指定范围后的新快照，用于拖拽排序后的本地乐观更新。
    func replacing(_ tags: [TagManagementItem], for scope: TagManagementScope) -> TagManagementSnapshot {
        switch scope {
        case .note:
            return TagManagementSnapshot(noteTags: tags, bookTags: bookTags)
        case .book:
            return TagManagementSnapshot(noteTags: noteTags, bookTags: tags)
        }
    }
}

/// 标签管理仓储错误，统一向 UI 暴露可读的业务失败原因。
nonisolated enum TagManagementRepositoryError: LocalizedError, Equatable {
    case invalidName
    case invalidNameLength(maxLength: Int)
    case duplicateName
    case invalidTag
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "标签名称不能为空"
        case .invalidNameLength(let maxLength):
            return "标签名称长度不能超过\(maxLength)个字符"
        case .duplicateName:
            return "要添加的标签已经存在了"
        case .invalidTag:
            return "标签已不存在，请刷新后重试"
        case .emptySelection:
            return "请选择要删除的标签"
        }
    }
}
