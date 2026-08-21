/**
 * [INPUT]: 依赖 BookRoute、BookDetailLaunchConfiguration 与 BookWorkspaceSection
 * [OUTPUT]: 验证普通目录位置、指定章节首帧策略及目录管理显式参数可被 Codable 恢复
 * [POS]: xmnoteTests 的目录入口与导航参数 TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Testing
@testable import xmnote

@MainActor
struct ChapterCatalogRouteTests {
    @Test
    func catalogKeepsAndroidTabPositionZero() {
        #expect(BookWorkspaceSection.allCases.first == .catalog)
        #expect(BookWorkspaceSection.allCases.firstIndex(of: .catalog) == 0)
    }

    @Test
    func specifiedChapterRouteRestoresEveryOneShotLaunchBehavior() throws {
        let route = BookRoute.chapterCatalog(bookID: 71_001, chapterID: 71_099)
        let restored = try JSONDecoder().decode(
            BookRoute.self,
            from: JSONEncoder().encode(route)
        )

        #expect(restored == route)
        #expect(restored.detailLaunchConfiguration == BookDetailLaunchConfiguration(
            bookID: 71_001,
            initialSection: .catalog,
            targetChapterID: 71_099,
            initiallyCollapsesHeader: true,
            animatesInitialHeaderTransition: false,
            showsOneShotCoverTip: false
        ))
    }

    @Test
    func chapterManagerRouteCarriesBookIdentityWithoutGlobalTemporaryState() throws {
        let route = BookRoute.chapterManager(
            bookID: 72_001,
            bookName: "显式目录参数",
            doubanID: 72_777,
            focusChapterID: 72_099
        )
        let restored = try JSONDecoder().decode(
            BookRoute.self,
            from: JSONEncoder().encode(route)
        )

        #expect(restored == route)
        guard case let .chapterManager(bookID, bookName, doubanID, focusChapterID) = restored else {
            Issue.record("恢复后的路由类型错误")
            return
        }
        #expect(bookID == 72_001)
        #expect(bookName == "显式目录参数")
        #expect(doubanID == 72_777)
        #expect(focusChapterID == 72_099)
    }

    @Test
    func specifiedChapterFocusPlanExpandsOnlyAncestorsAndKeepsTargetHighlighted() {
        let configuration = BookDetailLaunchConfiguration(
            bookID: 73_001,
            initialSection: .catalog,
            targetChapterID: 73_103,
            initiallyCollapsesHeader: true,
            animatesInitialHeaderTransition: false,
            showsOneShotCoverTip: false
        )
        let chapters = [
            makeChapter(id: 73_101, parentID: 0),
            makeChapter(id: 73_102, parentID: 73_101),
            makeChapter(id: 73_103, parentID: 73_102),
            makeChapter(id: 73_104, parentID: 0)
        ]

        #expect(configuration.catalogFocusPlan(chapters: chapters) == BookWorkspaceCatalogFocusPlan(
            targetChapterID: 73_103,
            expandedAncestorIDs: [73_101, 73_102],
            initiallyCollapsesHeader: true,
            animated: false
        ))
    }

    @Test
    func deletingCurrentlyLocatedChapterRemovesTheFocusPlanWithoutFallbackHighlight() {
        let configuration = BookDetailLaunchConfiguration(
            bookID: 73_001,
            initialSection: .catalog,
            targetChapterID: 73_103,
            initiallyCollapsesHeader: true,
            animatesInitialHeaderTransition: false,
            showsOneShotCoverTip: false
        )
        let chapters = [
            makeChapter(id: 73_101, parentID: 0),
            makeChapter(id: 73_103, parentID: 73_101)
        ]

        #expect(configuration.catalogFocusPlan(chapters: chapters) != nil)
        #expect(configuration.catalogFocusPlan(chapters: chapters.filter { $0.id != 73_103 }) == nil)
    }

    private func makeChapter(id: Int64, parentID: Int64) -> BookDetailChapter {
        BookDetailChapter(
            id: id,
            parentID: parentID,
            title: "章节 \(id)",
            level: 1,
            order: id,
            isStarred: false,
            noteCount: 0
        )
    }
}
