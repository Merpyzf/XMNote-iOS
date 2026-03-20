/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 NoteRoute 枚举，定义笔记模块导航目的地
 * [POS]: Navigation 模块的笔记路由，被 NoteContainerView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// NoteRoute 定义主导航的导航目标与路由参数。
enum NoteRoute: Hashable, Codable {
    case detail(noteId: Int64)
    case edit(noteId: Int64)
    case create(bookId: Int64?)
    case notesByTag(tagId: Int64)
}
