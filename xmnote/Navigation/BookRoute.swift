/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 BookRoute 枚举，定义书籍详情、阅读数据、目录管理、有效书/相关占位书录入、书架二级列表与书单详情目的地
 * [POS]: Navigation 模块的书籍路由，被 BookContainerView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// BookRoute 定义主导航的导航目标与路由参数。
enum BookRoute: Hashable, Codable {
    case detail(bookId: Int64)
    case readingDetail(bookId: Int64)
    case chapterManager(bookID: Int64, focusChapterID: Int64?)
    case edit(bookId: Int64)
    case editRelatedPlaceholder(bookId: Int64, sourceBookId: Int64)
    case add
    case create(seed: BookEditorSeed?)
    case bookshelfList(BookshelfBookListRoute)
    case collectionDetail(collectionID: Int64)
}
