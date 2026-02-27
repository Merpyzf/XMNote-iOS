/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 BookRoute 枚举，定义书籍模块导航目的地
 * [POS]: Navigation 模块的书籍路由，被 BookContainerView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

enum BookRoute: Hashable {
    case detail(bookId: Int64)
    case edit(bookId: Int64)
    case add
}
