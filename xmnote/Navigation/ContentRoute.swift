/**
 * [INPUT]: 依赖 Foundation 与 Domain/Models 中的通用内容查看模型
 * [OUTPUT]: 对外提供 ContentRoute 枚举，定义书摘/书评/相关查看与编辑的导航目的地
 * [POS]: Navigation 模块的跨内容路由，被 MainTabView 各 NavigationStack 统一消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// ContentRoute 定义三类内容查看页及其子编辑页的导航目标。
enum ContentRoute: Hashable, Codable {
    case contentViewer(
        source: ContentViewerSourceContext,
        initialItemID: ContentViewerItemID,
        keyword: String = ""
    )
    case reviewDetail(reviewId: Int64)
    case relevantDetail(contentId: Int64)
    /// 兼容既有编辑调用；等价于 `ReviewEditorMode.edit`。
    case reviewEditor(reviewId: Int64)
    /// 新建书评入口；与既有编辑 case 分离以保证历史 NavigationPath 可解码。
    case reviewEditorCreate(bookId: Int64)
    /// 兼容既有编辑调用；等价于 `RelevantEditorMode.edit`。
    case relevantEditor(contentId: Int64)
    /// 新建相关内容入口；与既有编辑 case 分离以保证历史 NavigationPath 可解码。
    case relevantEditorCreate(bookId: Int64, categoryId: Int64)

    /// 将新旧书评路由统一映射为编辑器模式。
    var reviewEditorMode: ReviewEditorMode? {
        switch self {
        case .reviewEditor(let reviewId): .edit(reviewID: reviewId)
        case .reviewEditorCreate(let bookId): .create(bookID: bookId)
        default: nil
        }
    }

    /// 将新旧相关内容路由统一映射为编辑器模式。
    var relevantEditorMode: RelevantEditorMode? {
        switch self {
        case .relevantEditor(let contentId): .edit(contentID: contentId)
        case .relevantEditorCreate(let bookId, let categoryId):
            .create(bookID: bookId, categoryID: categoryId)
        default: nil
        }
    }
}
