/**
 * [INPUT]: 依赖 Foundation 与 Domain/Models 中的通用内容查看模型
 * [OUTPUT]: 对外提供 ContentRoute 枚举，定义书摘/书评/相关查看与编辑的导航目的地
 * [POS]: Navigation 模块的跨内容路由，被 MainTabView 各 NavigationStack 统一消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// ContentRoute 定义三类内容查看页及其子编辑页的导航目标。
enum ContentRoute: Hashable {
    case noteViewer(source: ContentViewerSourceContext, noteId: Int64)
    case reviewDetail(reviewId: Int64)
    case relevantDetail(contentId: Int64)
    case reviewEditor(reviewId: Int64)
    case relevantEditor(contentId: Int64)
}
