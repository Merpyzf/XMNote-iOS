/**
 * [INPUT]: 依赖 Foundation 与 Domain/Models 中的通用内容查看模型
 * [OUTPUT]: 对外提供 ContentRoute 枚举，定义书评与相关内容的可恢复详情浏览目的地
 * [POS]: Navigation 模块的跨内容路由，被 MainTabView 各 NavigationStack 统一消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// ContentRoute 定义书评与相关内容的普通详情浏览目标。
enum ContentRoute: Hashable, Codable {
    case reviewDetail(reviewId: Int64)
    case relevantDetail(contentId: Int64)
}
