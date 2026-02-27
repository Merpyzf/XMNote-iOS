/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 ReadingRoute 枚举，定义在读模块导航目的地
 * [POS]: Navigation 模块的在读路由，被 ReadingContainerView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

enum ReadingRoute: Hashable {
    case bookDetail(bookId: UUID)
    case readingSession(bookId: UUID)
}
