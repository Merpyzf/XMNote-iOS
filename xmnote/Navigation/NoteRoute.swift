/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 NoteRoute 枚举，只定义笔记模块可返回、可恢复的详情、列表、合并、相关分类与标签浏览目的地
 * [POS]: Navigation 模块的笔记路由，被 NoteContainerView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// NoteRoute 定义主导航的导航目标与路由参数。
enum NoteRoute: Hashable, Codable {
    case detail(noteId: Int64)
    case noteExcerpts(scope: NoteExcerptScope)
    case noteExcerptList(context: NoteExcerptListContext)
    /// 保留既有参数形状，兼容其他章节入口并支持 v3 类型安全快照。
    case chapterNotes(bookID: Int64, chapterID: Int64, includeDescendants: Bool)
    /// 星标章节入口携带已展示名称，确保目的地首帧标题稳定。
    case chapterNoteList(context: ChapterNoteListContext)
    case mergeNotes(bookID: Int64, noteIDs: [Int64])
    case relatedCategory(scope: RelatedCategoryScope)
    case tagManagement
    case notesByTag(tagId: Int64)
}
