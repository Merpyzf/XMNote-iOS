/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 BookRoute 枚举，定义书籍模块可恢复的详情、书架二级列表与书单详情浏览目的地
 * [POS]: Navigation 模块的书籍路由，被 BookContainerView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// BookRoute 定义主导航的导航目标与路由参数。
enum BookRoute: Hashable, Codable {
    case detail(bookId: Int64)
    case bookshelfList(BookshelfBookListRoute)
    case collectionDetail(collectionID: Int64)
}
