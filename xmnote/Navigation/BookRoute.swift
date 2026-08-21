/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 BookRoute 与 BookDetailLaunchConfiguration，定义可返回、可恢复的书籍详情、指定章节目录、阅读数据、目录管理、章节书摘、书架二级列表与书单详情
 * [POS]: Navigation 模块的书籍路由，被 BookContainerView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书籍详情首帧参数；指定章节入口用值语义完整表达一次性定位和头部策略。
nonisolated struct BookDetailLaunchConfiguration: Hashable, Sendable {
    let bookID: Int64
    let initialSection: BookWorkspaceSection
    let targetChapterID: Int64?
    let initiallyCollapsesHeader: Bool
    let animatesInitialHeaderTransition: Bool
    let showsOneShotCoverTip: Bool

    /// 普通书籍入口保持既有书摘首屏与提示策略。
    static func standard(bookID: Int64) -> Self {
        Self(
            bookID: bookID,
            initialSection: .notes,
            targetChapterID: nil,
            initiallyCollapsesHeader: false,
            animatesInitialHeaderTransition: true,
            showsOneShotCoverTip: true
        )
    }

    /// 从真实 parent_id 链生成一次性定位方案；目标失效或出现循环时不产生错误滚动。
    func catalogFocusPlan(
        chapters: [BookDetailChapter]
    ) -> BookWorkspaceCatalogFocusPlan? {
        guard let targetChapterID else { return nil }
        let chaptersByID = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0) })
        guard var current = chaptersByID[targetChapterID] else { return nil }
        var ancestors: Set<Int64> = []
        var visited: Set<Int64> = [targetChapterID]
        while current.parentID != 0,
              visited.insert(current.parentID).inserted,
              let parent = chaptersByID[current.parentID] {
            ancestors.insert(parent.id)
            current = parent
        }
        return BookWorkspaceCatalogFocusPlan(
            targetChapterID: targetChapterID,
            expandedAncestorIDs: ancestors,
            initiallyCollapsesHeader: initiallyCollapsesHeader,
            animated: animatesInitialHeaderTransition
        )
    }
}

/// 指定章节目录入口的可测试一次性 UI 计划。
nonisolated struct BookWorkspaceCatalogFocusPlan: Hashable, Sendable {
    let targetChapterID: Int64
    let expandedAncestorIDs: Set<Int64>
    let initiallyCollapsesHeader: Bool
    let animated: Bool
}

/// BookRoute 定义主导航的导航目标与路由参数。
enum BookRoute: Hashable, Codable {
    case detail(bookId: Int64)
    case chapterCatalog(bookID: Int64, chapterID: Int64)
    case readingDetail(bookId: Int64)
    case chapterManager(bookID: Int64, bookName: String, doubanID: Int?, focusChapterID: Int64?)
    case chapterNotes(bookId: Int64, chapterId: Int64, title: String)
    case bookshelfList(BookshelfBookListRoute)
    case collectionDetail(collectionID: Int64)

    /// 将普通详情与指定章节目录路由收敛为详情页首帧配置；其他路由不属于书籍详情入口。
    var detailLaunchConfiguration: BookDetailLaunchConfiguration? {
        switch self {
        case .detail(let bookID):
            .standard(bookID: bookID)
        case .chapterCatalog(let bookID, let chapterID):
            BookDetailLaunchConfiguration(
                bookID: bookID,
                initialSection: .catalog,
                targetChapterID: chapterID,
                initiallyCollapsesHeader: true,
                animatesInitialHeaderTransition: false,
                showsOneShotCoverTip: false
            )
        case .readingDetail,
             .chapterManager,
             .chapterNotes,
             .bookshelfList,
             .collectionDetail:
            nil
        }
    }
}
