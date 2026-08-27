/**
 * [INPUT]: 依赖 BookshelfGridLayoutPolicy、BookshelfTitleDisplayMode、BookshelfSortCriteria 与 DynamicTypeSize
 * [OUTPUT]: 验证双书架共用策略的列数上限、标题模式和排序辅助行高度
 * [POS]: xmnoteTests 的书架功能布局回归测试，保护辅助功能字号下的密度与内容完整性
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import Testing
@testable import xmnote

@MainActor
struct BookshelfGridLayoutPolicyTests {
    @Test
    func accessibilitySizesLimitGridToTwoColumns() {
        #expect(
            BookshelfGridLayoutPolicy.effectiveColumnCount(
                requested: 4,
                dynamicTypeSize: .large
            ) == 4
        )
        #expect(
            BookshelfGridLayoutPolicy.effectiveColumnCount(
                requested: 4,
                dynamicTypeSize: .accessibility5
            ) == 2
        )
    }

    @Test
    func heightAccountsForFullTitlesAndSortAuxiliaryText() {
        let standard = BookshelfGridLayoutPolicy.itemHeight(
            containerWidth: 393,
            requestedColumnCount: 3,
            dynamicTypeSize: .large,
            titleDisplayMode: .standard,
            sortCriteria: .name
        )
        let fullTitle = BookshelfGridLayoutPolicy.itemHeight(
            containerWidth: 393,
            requestedColumnCount: 3,
            dynamicTypeSize: .large,
            titleDisplayMode: .full,
            sortCriteria: .name
        )
        let auxiliary = BookshelfGridLayoutPolicy.itemHeight(
            containerWidth: 393,
            requestedColumnCount: 3,
            dynamicTypeSize: .large,
            titleDisplayMode: .standard,
            sortCriteria: .createdDate
        )

        #expect(fullTitle > standard)
        #expect(auxiliary > standard)
    }

    @Test
    func accessibilityHeightUsesTheSameDynamicTypographyOwner() {
        let regular = BookshelfGridLayoutPolicy.itemHeight(
            containerWidth: 393,
            requestedColumnCount: 4,
            dynamicTypeSize: .large,
            titleDisplayMode: .full,
            sortCriteria: .readingProgress
        )
        let accessibility = BookshelfGridLayoutPolicy.itemHeight(
            containerWidth: 393,
            requestedColumnCount: 4,
            dynamicTypeSize: .accessibility5,
            titleDisplayMode: .full,
            sortCriteria: .readingProgress
        )

        #expect(accessibility > regular)
    }
}
