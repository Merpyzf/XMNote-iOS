/**
 * [INPUT]: 依赖首页书籍二级列表编辑动作、批量编辑 Sheet 与确认弹窗业务状态
 * [OUTPUT]: 对外提供语义化 BookshelfBookListEditAction、BookshelfBatchEditSheet 与二级列表编辑确认输入模型
 * [POS]: Book 模块二级书籍列表 ViewModel 状态模型，隔离 BookshelfBookListViewModel 的状态类型定义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 二级书籍列表编辑动作，已核对动作走真实写入，未核对 destructive 动作继续保护提示。
enum BookshelfBookListEditAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pin
    case unpin
    case reorder
    case moveToStart
    case moveToEnd
    case moveToGroup
    case addToBookList
    case moveOut
    case setTag
    case setSource
    case setReadStatus
    case exportNote
    case exportBook
    case renameGroup
    case deleteGroup
    case renameTag
    case deleteTag
    case renameSource
    case deleteSource
    case deleteBooks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pin:
            return "置顶"
        case .unpin:
            return "取消置顶"
        case .reorder:
            return "排序"
        case .moveToStart:
            return "最前"
        case .moveToEnd:
            return "最后"
        case .moveToGroup:
            return "移组"
        case .addToBookList:
            return "书单"
        case .moveOut:
            return "移出"
        case .setTag:
            return "标签"
        case .setSource:
            return "来源"
        case .setReadStatus:
            return "状态"
        case .exportNote:
            return "导出笔记"
        case .exportBook:
            return "导出书籍"
        case .renameGroup, .renameTag, .renameSource:
            return "重命名"
        case .deleteGroup:
            return "删分组"
        case .deleteTag:
            return "删标签"
        case .deleteSource:
            return "删来源"
        case .deleteBooks:
            return "删除"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteGroup, .deleteTag, .deleteSource, .deleteBooks:
            return true
        case .pin, .unpin, .reorder, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook, .renameGroup, .renameTag, .renameSource:
            return false
        }
    }

    var requiresSelection: Bool {
        switch self {
        case .pin, .unpin, .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .moveOut, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook, .deleteBooks:
            return true
        case .reorder, .renameGroup, .deleteGroup, .renameTag, .deleteTag, .renameSource, .deleteSource:
            return false
        }
    }
}

/// 二级书籍列表批量编辑 Sheet 类型，承载打开 Sheet 时刻的可选项快照与局部读取状态。
enum BookshelfBatchEditSheet: Identifiable, Hashable, Sendable {
    case tags(
        mode: BookTagMutationMode,
        bookIDs: [Int64],
        options: [BookEditorNamedOption],
        initialSelectedIDs: [Int64],
        allowsEmptySelection: Bool,
        isLoading: Bool,
        errorMessage: String?
    )
    case source(options: [BookshelfSourceOption], initialSelectedID: Int64?)
    case readStatus(options: [BookEditorNamedOption], initialStatusID: Int64?, initialChangedAt: Date?, initialRatingScore: Int64?)
    case moveGroup(options: [BookshelfMoveGroupOption], isLoading: Bool, errorMessage: String?)
    case bookCollection(options: [BookCollectionSummary], isLoading: Bool, errorMessage: String?)

    var id: String {
        switch self {
        case .tags(let mode, _, _, _, _, _, _):
            return "tags-\(mode.rawValue)"
        case .source:
            return "source"
        case .readStatus:
            return "readStatus"
        case .moveGroup:
            return "moveGroup"
        case .bookCollection:
            return "bookCollection"
        }
    }
}

/// 多本书标签命令选择状态，冻结打开确认弹窗时的书籍范围。
struct BookshelfBatchTagModeConfirmation: Identifiable, Hashable, Sendable {
    let bookIDs: [Int64]

    var id: String { bookIDs.map(String.init).joined(separator: "-") }
}

/// 默认分组移出确认状态，承载打开弹窗时的选择数量。
struct BookshelfMoveOutPlacementConfirmation: Identifiable, Hashable, Sendable {
    let selectedCount: Int

    var id: Int { selectedCount }
}

/// 二级列表删除确认状态，覆盖批量删书与上下文分组/标签/来源删除。
struct BookshelfBookListDeleteConfirmation: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case books(bookIDs: [Int64])
        case group(title: String)
        case tag(title: String)
        case source(title: String)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .books(let bookIDs):
            return "books-\(bookIDs.map(String.init).joined(separator: "-"))"
        case .group(let title):
            return "group-\(title)"
        case .tag(let title):
            return "tag-\(title)"
        case .source(let title):
            return "source-\(title)"
        }
    }
}

/// 二级列表重命名输入状态，承载当前上下文对象与初始名称。
struct BookshelfBookListNameEdit: Identifiable, Hashable, Sendable {
    let action: BookshelfBookListEditAction
    let currentName: String

    var id: String { "\(action.rawValue)-\(currentName)" }
}

/// 二级列表编辑动作策略，集中定义不同聚合上下文可出现的工具栏动作。
enum BookshelfBookListActionPolicy {
    /// 根据二级列表上下文返回可用编辑动作，避免 ViewModel 混入静态菜单配置。
    static func editActions(for context: BookshelfListContext) -> [BookshelfBookListEditAction] {
        switch context {
        case .defaultGroup:
            return [
                .pin,
                .unpin,
                .moveToStart,
                .moveToEnd,
                .moveToGroup,
                .addToBookList,
                .moveOut,
                .setTag,
                .setSource,
                .setReadStatus,
                .deleteBooks,
                .renameGroup,
                .deleteGroup
            ]
        case .tag(let tagID):
            var actions = sharedBookActions()
            if tagID != nil {
                actions.append(contentsOf: [.renameTag, .deleteTag])
            }
            return actions
        case .source(let sourceID):
            var actions = sharedBookActions()
            if sourceID != nil {
                actions.append(contentsOf: [.renameSource, .deleteSource])
            }
            return actions
        case .readStatus, .rating, .author, .press:
            return sharedBookActions()
        }
    }

    /// 判断当前路由上下文是否具备对应管理对象。
    static func canManageCurrentContext(
        _ action: BookshelfBookListEditAction,
        in context: BookshelfListContext
    ) -> Bool {
        switch (context, action) {
        case (.defaultGroup, .renameGroup), (.defaultGroup, .deleteGroup):
            return true
        case (.tag(let tagID), .renameTag), (.tag(let tagID), .deleteTag):
            return tagID != nil
        case (.source(let sourceID), .renameSource), (.source(let sourceID), .deleteSource):
            return sourceID != nil
        default:
            return false
        }
    }

    /// 多数聚合二级列表共享的书籍批量操作动作。
    private static func sharedBookActions() -> [BookshelfBookListEditAction] {
        [.moveToGroup, .addToBookList, .setTag, .setSource, .setReadStatus, .deleteBooks]
    }
}

/// 二级书籍列表状态编排器，让 pushed destination 通过 Repository 实时观察数据，而不是消费静态路由数组；所有 UI 状态均在主线程更新。
