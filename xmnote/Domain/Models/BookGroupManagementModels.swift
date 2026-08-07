/**
 * [INPUT]: 依赖 Foundation 与书架分组删除位置模型，承接 Android GroupManage 页的分组管理聚合数据
 * [OUTPUT]: 对外提供 BookGroupManagementItem、BookGroupManagementSnapshot 与分组管理错误模型
 * [POS]: Domain/Models 的书籍分组管理领域模型，被 Repository、ViewModel 与 Personal 分组管理页共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书籍分组管理列表项，保留分组展示、排序与删除确认所需的最小聚合信息。
nonisolated struct BookGroupManagementItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let bookCount: Int
    let representativeCovers: [String]

    /// 根据数据库聚合结果构建分组管理展示项。
    init(
        id: Int64,
        name: String,
        bookCount: Int,
        representativeCovers: [String]
    ) {
        self.id = id
        self.name = name
        self.bookCount = bookCount
        self.representativeCovers = representativeCovers
    }

    var subtitle: String {
        "\(bookCount) 本"
    }
}

/// 书籍分组管理快照，承载同一次数据库观察生成的全部有效分组。
nonisolated struct BookGroupManagementSnapshot: Hashable, Sendable {
    static let empty = BookGroupManagementSnapshot(groups: [])

    var groups: [BookGroupManagementItem]

    /// 返回替换列表后的快照，用于拖拽排序后的本地乐观更新。
    func replacing(_ groups: [BookGroupManagementItem]) -> BookGroupManagementSnapshot {
        BookGroupManagementSnapshot(groups: groups)
    }
}

/// 书籍分组管理仓储错误，统一向 UI 暴露可读的业务失败原因。
nonisolated enum BookGroupManagementRepositoryError: LocalizedError, Equatable {
    case invalidName
    case invalidNameLength(maxLength: Int)
    case invalidGroup
    case emptySelection
    case staleOrder

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "分组名称不能为空"
        case .invalidNameLength(let maxLength):
            return "分组名称长度不能超过\(maxLength)个字符"
        case .invalidGroup:
            return "分组已不存在，请刷新后重试"
        case .emptySelection:
            return "请选择要删除的分组"
        case .staleOrder:
            return "分组列表已更新，请重新调整顺序"
        }
    }
}
