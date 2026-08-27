/**
 * [INPUT]: 依赖 BookshelfBookListCollectionConfiguration、BookshelfBookListCollectionSectionState 与 UIKit compositional layout
 * [OUTPUT]: 对外提供二级书籍列表 collection 的 section 状态构建与布局 section 工厂
 * [POS]: Book 模块二级书籍列表页面私有布局协作者，隔离 UIKit host 中的纯布局和结果状态映射逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 构建二级书籍列表的 collection section 快照，避免 HostView 同时承担数据映射职责。
enum BookshelfBookListCollectionSectionBuilder {
    /// 从 SwiftUI 输入配置生成 UIKit collection 可消费的 section 状态。
    static func makeSections(
        from configuration: BookshelfBookListCollectionConfiguration
    ) -> [BookshelfBookListCollectionSectionState] {
        var nextSections: [BookshelfBookListCollectionSectionState] = []
        if configuration.showsSearchDrawerInCollection {
            nextSections.append(BookshelfBookListCollectionSectionState(
                id: "search-drawer",
                title: nil,
                items: [.searchDrawer]
            ))
        }
        switch configuration.contentState {
        case .loading:
            nextSections.append(BookshelfBookListCollectionSectionState(id: "loading", title: nil, items: [.loading]))
        case .empty:
            let emptyState: BookshelfBookListEmptyState = configuration.hasSearchKeyword
                ? .searchEmpty(selectedCount: configuration.selectedBookIDs.count)
                : .contentEmpty
            nextSections.append(BookshelfBookListCollectionSectionState(id: "empty", title: nil, items: [.empty(emptyState)]))
        case .error(let message):
            nextSections.append(BookshelfBookListCollectionSectionState(
                id: "error",
                title: nil,
                items: [.empty(.error(message))]
            ))
        case .content:
            nextSections.append(contentsOf: configuration.snapshot.sections.map { section in
                BookshelfBookListCollectionSectionState(
                    id: section.id,
                    title: section.title,
                    items: section.books.map(BookshelfBookListCollectionItem.book)
                )
            })
        }
        return nextSections
    }

    /// 从 section 快照识别结果区状态，忽略搜索抽屉这类 chrome section。
    static func resultState(in sections: [BookshelfBookListCollectionSectionState]) -> BookshelfBookListResultState {
        let resultSections = sections.filter { $0.id != "search-drawer" }
        guard !resultSections.isEmpty else { return .other }
        if resultSections.contains(where: { $0.id == "loading" }) {
            return .loading
        }
        if resultSections.contains(where: { $0.id == "error" }) {
            return .error
        }
        if resultSections.contains(where: { $0.id == "empty" }) {
            return .empty
        }
        if resultSections.contains(where: { section in
            section.items.contains {
                if case .book = $0 { return true }
                return false
            }
        }) {
            return .content
        }
        return .other
    }

    /// 将前后结果状态转换为动效意图，避免把重复无结果输入误当作结构变化。
    static func resultTransition(
        from previousSections: [BookshelfBookListCollectionSectionState],
        to nextSections: [BookshelfBookListCollectionSectionState]
    ) -> BookshelfBookListResultTransition {
        switch (resultState(in: previousSections), resultState(in: nextSections)) {
        case (.content, .empty):
            return .contentToEmpty
        case (.empty, .content):
            return .emptyToContent
        case (.content, .content):
            return .contentToContent
        case (.empty, .empty):
            return .emptyToEmpty
        default:
            return .other
        }
    }

    /// 只有内容首次筛成空态时允许空态上浮进入，重复空态更新必须保持稳定。
    static func emptyPresentationMode(
        for transition: BookshelfBookListResultTransition
    ) -> BookshelfBookListEmptyPresentationMode {
        transition == .contentToEmpty ? .enteringFromContent : .steadyEmptyUpdate
    }
}

/// 构建二级书籍列表的 compositional layout section，避免 HostView 混入静态布局公式。
enum BookshelfBookListCollectionLayoutFactory {
    /// 二级列表 grid 模式只让真实书籍多列排列，并用绝对高度避免编辑态切换时自适应高度重算错位。
    static func makeGridSection(
        columnCount: Int,
        containerWidth: CGFloat,
        dynamicTypeSize: DynamicTypeSize,
        titleDisplayMode: BookshelfTitleDisplayMode,
        sortCriteria: BookshelfSortCriteria
    ) -> NSCollectionLayoutSection {
        let clampedColumnCount = BookshelfGridLayoutPolicy.effectiveColumnCount(
            requested: columnCount,
            dynamicTypeSize: dynamicTypeSize
        )
        let itemHeight = BookshelfBookListGridMetrics.itemHeight(
            containerWidth: containerWidth,
            columnCount: clampedColumnCount,
            dynamicTypeSize: dynamicTypeSize,
            titleDisplayMode: titleDisplayMode,
            sortCriteria: sortCriteria
        )
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(clampedColumnCount)),
            heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: Spacing.screenEdge / 2,
            bottom: 0,
            trailing: Spacing.screenEdge / 2
        )

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(itemHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            repeatingSubitem: item,
            count: clampedColumnCount
        )

        let horizontalInset = max(0, Spacing.screenEdge / 2)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Spacing.section
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.base,
            leading: horizontalInset,
            bottom: Spacing.base,
            trailing: horizontalInset
        )
        return section
    }

    /// 搜索抽屉使用精确高度，作为 collection 内容的一部分由原生滚动露出。
    static func makeSearchDrawerSection(height: CGFloat) -> NSCollectionLayoutSection {
        let resolvedHeight = max(0, height)
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(resolvedHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(resolvedHeight)
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .zero
        section.interGroupSpacing = 0
        return section
    }

    /// 二级列表 list 模式使用单列全宽布局；书籍行估算高度，加载与空态保持确定高度。
    static func makeListSection(
        itemHeight: CGFloat,
        usesEstimatedHeight: Bool
    ) -> NSCollectionLayoutSection {
        let resolvedHeight = max(1, itemHeight)
        let heightDimension: NSCollectionLayoutDimension = usesEstimatedHeight
            ? .estimated(resolvedHeight)
            : .absolute(resolvedHeight)
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: heightDimension
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: heightDimension
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Spacing.base
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.base,
            leading: Spacing.screenEdge,
            bottom: Spacing.base,
            trailing: Spacing.screenEdge
        )
        return section
    }

    /// 构建固定高度 section header，供有标题的结果分区复用。
    static func makeSectionHeader() -> NSCollectionLayoutBoundarySupplementaryItem {
        let headerSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(BookshelfBookListLayoutMetrics.sectionHeaderHeight)
        )
        return NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: headerSize,
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
    }
}
