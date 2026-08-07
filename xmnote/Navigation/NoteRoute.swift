/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 NoteRoute 枚举，定义笔记模块导航目的地，并保留旧章节及相关管理路由的解码兼容
 * [POS]: Navigation 模块的笔记路由，被 NoteContainerView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// NoteRoute 定义主导航的导航目标与路由参数。
enum NoteRoute: Hashable, Codable {
    case detail(noteId: Int64)
    case edit(noteId: Int64)
    case create(seed: NoteEditorSeed)
    case noteExcerpts(scope: NoteExcerptScope)
    case noteExcerptList(context: NoteExcerptListContext)
    /// 保留既有编码形状，兼容历史 NavigationPath 与其他章节入口。
    case chapterNotes(bookID: Int64, chapterID: Int64, includeDescendants: Bool)
    /// 星标章节入口携带已展示名称，确保目的地首帧标题稳定。
    case chapterNoteList(context: ChapterNoteListContext)
    case mergeNotes(bookID: Int64, noteIDs: [Int64])
    case relatedCategory(scope: RelatedCategoryScope)
    /// 仅用于旧 Scene 快照解码；恢复后由导航层降级到“全部相关”，不再提供新入口。
    case relatedCategoryManagement
    case tagManagement
    case notesByTag(tagId: Int64)
}
