/**
 * [INPUT]: 依赖 Foundation 提供值语义、错误描述与并发标记
 * [OUTPUT]: 对外提供章节管理快照、远端目录候选/导入结果、树节点、写入结果与业务错误模型
 * [POS]: Domain/Models 的书内目录管理领域模型，供 Repository、ViewModel 与 SwiftUI 页面共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 章节树支持的最大深度，与 Android AppConstant.MAX_CHAPTER_DEPTH 保持一致。
nonisolated enum ChapterManagementPolicy {
    static let maximumDepth = 5
    static let pathSeparator = " / "
}

/// 文曲动态配置的可用状态；该配置仅服务封面转存等扩展能力，不作为目录 API 的鉴权前提。
nonisolated enum ChapterRemoteConfigurationState: Hashable, Sendable {
    case available
    case unavailable
}

/// 远端目录发现方式；有豆瓣 ID 时精确匹配，没有时按 Android 流程以书名列出候选。
nonisolated enum ChapterRemoteCatalogMatchMode: Hashable, Sendable {
    case exactDoubanID
    case bookTitleCandidates
}

/// 文曲中的一本远端书籍及其目录预览；目录项保持服务端原始换行顺序。
nonisolated struct ChapterRemoteCatalogCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let remoteBookID: Int?
    let doubanID: Int?
    let title: String
    let author: String
    let press: String
    let catalogTitles: [String]

    var subtitle: String {
        [author, press]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 一次远端目录发现结果，携带 Android 实际采用的匹配模式。
nonisolated struct ChapterRemoteCatalogDiscovery: Hashable, Sendable {
    let bookTitle: String
    let matchMode: ChapterRemoteCatalogMatchMode
    let candidates: [ChapterRemoteCatalogCandidate]
}

/// 用户可选择的单条远端目录；稳定 ID 由候选与原始行号共同组成，重复标题仍可单独选择。
nonisolated struct ChapterRemoteCatalogItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let originalIndex: Int
}

/// 远端目录事务导入结果；复用数量用于明确冲突合并结果，成功不额外弹轻提示。
nonisolated struct ChapterRemoteImportResult: Hashable, Sendable {
    let importedChapterCount: Int
    let reusedChapterCount: Int
}

/// 单个章节的只读业务快照；层级、路径和后代书摘数均由 parent_id 树实时推导。
nonisolated struct ChapterManagementItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let bookID: Int64
    let parentID: Int64
    let title: String
    let remark: String
    let order: Int64
    let level: Int
    let pathTitles: [String]
    let directNoteCount: Int
    let descendantNoteCount: Int
    let childCount: Int
    let isStarred: Bool

    var displayTitle: String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "未命名章节" : normalized
    }

    var pathText: String {
        pathTitles
            .map { title in
                let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? "未命名章节" : normalized
            }
            .joined(separator: ChapterManagementPolicy.pathSeparator)
    }
}

/// 章节树节点，保留同级顺序并为页面展开、定位和范围操作提供稳定结构。
nonisolated struct ChapterManagementNode: Identifiable, Hashable, Sendable {
    let item: ChapterManagementItem
    let children: [ChapterManagementNode]

    var id: Int64 { item.id }

    /// 以先序顺序平铺当前子树，供管理页建立稳定列表身份。
    func flattened() -> [ChapterManagementNode] {
        [self] + children.flatMap { $0.flattened() }
    }

    /// 返回当前节点及全部后代 ID，供删除与移动目标过滤使用。
    func subtreeIDs() -> Set<Int64> {
        children.reduce(into: Set([id])) { result, child in
            result.formUnion(child.subtreeIDs())
        }
    }

    /// 返回当前子树高度；叶子高度为 1。
    func subtreeHeight() -> Int {
        1 + (children.map { $0.subtreeHeight() }.max() ?? 0)
    }
}

/// 单本书目录管理快照，集中提供树查询与多选归一化能力。
nonisolated struct ChapterManagementSnapshot: Hashable, Sendable {
    let bookID: Int64
    let roots: [ChapterManagementNode]
    let unassignedNoteCount: Int

    static func empty(bookID: Int64) -> Self {
        Self(bookID: bookID, roots: [], unassignedNoteCount: 0)
    }

    var flattened: [ChapterManagementNode] {
        roots.flatMap { $0.flattened() }
    }

    var chapterCount: Int { flattened.count }

    /// 按主键返回章节节点；不存在时返回 nil，调用方据此处理并发删除。
    func node(id: Int64) -> ChapterManagementNode? {
        flattened.first { $0.id == id }
    }

    /// 返回指定父级的直接子章节；parentID 为 0 时返回根章节。
    func directChildren(parentID: Int64) -> [ChapterManagementNode] {
        guard parentID != 0 else { return roots }
        return node(id: parentID)?.children ?? []
    }

    /// 返回章节的祖先 ID，顺序从根到直接父级。
    func ancestorIDs(of chapterID: Int64) -> [Int64] {
        let itemByID = Dictionary(uniqueKeysWithValues: flattened.map { ($0.id, $0.item) })
        var result: [Int64] = []
        var visited: Set<Int64> = []
        var currentParentID = itemByID[chapterID]?.parentID ?? 0
        while currentParentID != 0, visited.insert(currentParentID).inserted {
            result.append(currentParentID)
            currentParentID = itemByID[currentParentID]?.parentID ?? 0
        }
        return result.reversed()
    }

    /// 去掉已被选中祖先覆盖的章节，避免移动和删除同一子树两次。
    func topLevelSelection(from selectedIDs: Set<Int64>) -> [ChapterManagementNode] {
        let selected = selectedIDs.intersection(Set(flattened.map(\.id)))
        return flattened.filter { node in
            guard selected.contains(node.id) else { return false }
            return ancestorIDs(of: node.id).allSatisfy { !selected.contains($0) }
        }
    }
}

/// 管理页可见行，保留节点真实深度与当前展开状态。
nonisolated struct ChapterManagementVisibleItem: Identifiable, Hashable, Sendable {
    let node: ChapterManagementNode
    let isExpanded: Bool

    var id: Int64 { node.id }
    var item: ChapterManagementItem { node.item }
    var hasChildren: Bool { !node.children.isEmpty }
}

/// 移动目的地候选；禁用原因不为空时页面必须明确解释限制。
nonisolated struct ChapterMoveTarget: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let pathText: String
    let level: Int
    let disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }
    var isRoot: Bool { id == 0 }
}

/// 删除章节时对其有效书摘采取的处置方式，与 Android ChapterNoteDisposition 一致。
nonisolated enum ChapterNoteDisposition: Hashable, Sendable {
    case detach
    case delete
}

/// 章节删除结果，分别报告章节数、受影响书摘数、解绑数与物理删除数。
nonisolated struct ChapterDeletionResult: Hashable, Sendable {
    let deletedChapterCount: Int
    let affectedNoteCount: Int
    let unassignedNoteCount: Int
    let deletedNoteCount: Int
}

/// 目录管理数据损坏或写入冲突错误，向页面提供可行动的中文说明。
nonisolated enum ChapterManagementError: LocalizedError, Hashable, Sendable {
    case invalidBook
    case chapterNotFound
    case parentNotFound
    case emptyTitle
    case invalidSelection
    case invalidSiblingOrder
    case crossBookMove
    case moveIntoOwnSubtree
    case exceedsMaximumDepth
    case undoConflict
    case orphanedChapter(chapterID: Int64)
    case cyclicTree

    var errorDescription: String? {
        switch self {
        case .invalidBook:
            return "书籍不存在或已被删除，请返回后重新进入。"
        case .chapterNotFound:
            return "章节已不存在，目录已刷新。"
        case .parentNotFound:
            return "目标父章节已不存在，请重新选择位置。"
        case .emptyTitle:
            return "章节标题不能为空。"
        case .invalidSelection:
            return "所选章节已变化，请重新选择。"
        case .invalidSiblingOrder:
            return "同级目录已变化，请重新调整顺序。"
        case .crossBookMove:
            return "只能在同一本书内移动章节。"
        case .moveIntoOwnSubtree:
            return "不能移动到自身或自身的子章节中。"
        case .exceedsMaximumDepth:
            return "章节层级不能超过 \(ChapterManagementPolicy.maximumDepth) 层。"
        case .undoConflict:
            return "目录在操作后又发生了变化，无法安全撤销，请重新调整。"
        case .orphanedChapter:
            return "目录存在找不到父级的章节，请先恢复备份或在其他端修复。"
        case .cyclicTree:
            return "目录存在循环父子关系，请先恢复备份或在其他端修复。"
        }
    }
}
