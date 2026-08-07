/**
 * [INPUT]: 依赖 ChapterNoteListContext 提供章节范围与首帧标题，依赖 NoteExcerptListView 共享查询、批量操作与统一 Viewer 跳转
 * [OUTPUT]: 对外提供 ChapterNotesView，按入口传入的真实章节名称承载指定章节及可选后代章节的书摘二级页面
 * [POS]: Note 模块章节书摘目的地，由 NoteRoute.chapterNotes 或 chapterNoteList 进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 章节书摘页；标题随入口上下文首帧确定，取消星标仅移除入口而不影响章节或书摘数据。
struct ChapterNotesView: View {
    @Environment(RepositoryContainer.self) private var repositories
    let context: ChapterNoteListContext
    let onOpenViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void

    var body: some View {
        NoteExcerptListView(
            origin: .chapter(
                bookID: context.bookID,
                chapterID: context.chapterID,
                includeDescendants: context.includeDescendants
            ),
            displayTitle: context.displayTitle,
            showsRemoveChapterStar: true,
            repository: repositories.noteRepository,
            externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
            onOpenViewer: onOpenViewer,
            onOpenNoteRoute: onOpenNoteRoute
        )
    }
}
