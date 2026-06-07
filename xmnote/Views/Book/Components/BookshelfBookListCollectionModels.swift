/**
 * [INPUT]: 依赖 BookshelfBookListSnapshot、BookshelfBookListItem 与书架展示设置构建 collection 配置和 item 状态
 * [OUTPUT]: 对外提供二级书籍列表 collection 的配置、item、空态、结果切换状态与布局 metrics
 * [POS]: Book 模块二级书籍列表页面私有模型组件，隔离 UIKit host 输入与 section 状态定义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// UIKit 集合区输入配置。
struct BookshelfBookListCollectionConfiguration {
    let snapshot: BookshelfBookListSnapshot
    let subtitle: String
    let contentState: BookshelfContentState
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let showsNoteCount: Bool
    let sortCriteria: BookshelfSortCriteria
    let titleDisplayMode: BookshelfTitleDisplayMode
    let isEditing: Bool
    let hasSearchKeyword: Bool
    let searchDrawerHeight: CGFloat
    let searchPresentation: BookshelfSearchDrawerPresentation
    let isBrowseSearchFocused: Bool
    let browseSearchText: String
    let browseSearchKeyword: String
    let browseSearchPlaceholder: String
    let browseSearchFocusTrigger: Int
    let selectedBookIDs: Set<Int64>
    let canReorder: Bool
    let movableBookIDs: Set<Int64>
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let bottomContentInset: CGFloat
    let onActivateBrowseSearch: () -> Void
    let onRequestBrowseSearchFocus: () -> Void
    let onBrowseSearchKeywordChange: (String) -> Void
    let onSubmitBrowseSearch: (String) -> Void
    let onBrowseSearchFocusChange: (Bool) -> Void
    let onClearBrowseSearch: () -> Void
    let onCollapseBrowseSearch: () -> Void
    let onToggleSelection: (Int64) -> Void
    let onSelectBook: (Int64) -> Void
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void
    let onCommitOrder: ([Int64]) -> Void

    static let empty = BookshelfBookListCollectionConfiguration(
        snapshot: .empty,
        subtitle: "",
        contentState: .loading,
        layoutMode: .list,
        columnCount: 3,
        showsNoteCount: true,
        sortCriteria: .custom,
        titleDisplayMode: .standard,
        isEditing: false,
        hasSearchKeyword: false,
        searchDrawerHeight: 0,
        searchPresentation: .hidden,
        isBrowseSearchFocused: false,
        browseSearchText: "",
        browseSearchKeyword: "",
        browseSearchPlaceholder: "",
        browseSearchFocusTrigger: 0,
        selectedBookIDs: [],
        canReorder: false,
        movableBookIDs: [],
        supportsContextPin: false,
        activeWriteAction: nil,
        bottomContentInset: 0,
        onActivateBrowseSearch: {},
        onRequestBrowseSearchFocus: {},
        onBrowseSearchKeywordChange: { _ in },
        onSubmitBrowseSearch: { _ in },
        onBrowseSearchFocusChange: { _ in },
        onClearBrowseSearch: {},
        onCollapseBrowseSearch: {},
        onToggleSelection: { _ in },
        onSelectBook: { _ in },
        onContextAction: { _, _ in },
        onCommitOrder: { _ in }
    )

    var showsSearchDrawerInCollection: Bool {
        searchDrawerHeight > 0
    }

    var hasBrowseSearchKeyword: Bool {
        !browseSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasBrowseSearchText: Bool {
        !browseSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isBrowseSearchPinned: Bool {
        searchPresentation.isPinned
    }

    var showsExpandedSearchSurface: Bool {
        searchPresentation.isPinned || hasBrowseSearchText || hasBrowseSearchKeyword || isBrowseSearchFocused
    }
}

/// 二级书籍列表 item 类型，把 subtitle、empty 与书籍行统一交给 collection view 管理。
enum BookshelfBookListEmptyState: Hashable {
    case contentEmpty
    case searchEmpty(selectedCount: Int)
    case error(String)

    var icon: String {
        switch self {
        case .contentEmpty:
            return "books.vertical"
        case .searchEmpty:
            return "books.vertical"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .contentEmpty:
            return "暂无书籍"
        case .searchEmpty:
            return "没有匹配的书籍"
        case .error:
            return "书籍加载失败"
        }
    }

    var message: String? {
        switch self {
        case .contentEmpty:
            return nil
        case .searchEmpty(let selectedCount):
            return selectedCount > 0 ? "已选书籍仍保留，清除搜索可继续整理" : "清除搜索后查看全部书籍"
        case .error(let message):
            return message.isEmpty ? "请稍后重试" : message
        }
    }

    var iconColor: Color {
        switch self {
        case .contentEmpty:
            return Color.brand.opacity(0.32)
        case .searchEmpty:
            return Color.brand.opacity(0.40)
        case .error:
            return Color.feedbackWarning.opacity(0.42)
        }
    }
}

enum BookshelfBookListCollectionItem: Hashable {
    case searchDrawer
    case loading
    case empty(BookshelfBookListEmptyState)
    case book(BookshelfBookListItem)
}

/// 搜索结果区的粗粒度状态，用于决定结构动效是内容补位还是空态稳定刷新。
enum BookshelfBookListResultState: Equatable {
    case content
    case empty
    case loading
    case error
    case other
}

/// 二级列表搜索结果切换类型，避免空态重复查询误触发布局位移动画。
enum BookshelfBookListResultTransition: Equatable {
    case contentToEmpty
    case emptyToContent
    case contentToContent
    case emptyToEmpty
    case other
}

/// 空态 SwiftUI 容器的呈现模式；重复无结果更新必须保持位置稳定。
enum BookshelfBookListEmptyPresentationMode: Hashable {
    case enteringFromContent
    case steadyEmptyUpdate
}

/// 二级列表网格布局的确定性尺寸，保证 UICollectionView 切换整理态时不依赖 self-sizing 猜测。
enum BookshelfBookListGridMetrics {
    static func itemHeight(
        containerWidth: CGFloat,
        columnCount: Int,
        titleDisplayMode: BookshelfTitleDisplayMode
    ) -> CGFloat {
        let clampedColumnCount = max(2, min(columnCount, 4))
        let sectionInset = max(0, Spacing.screenEdge / 2)
        let itemHorizontalInset = Spacing.screenEdge / 2
        let availableWidth = max(1, containerWidth - sectionInset * 2)
        let itemWidth = availableWidth / CGFloat(clampedColumnCount)
        let contentWidth = max(1, itemWidth - itemHorizontalInset * 2)
        let coverHeight = XMBookCover.height(forWidth: contentWidth)
        let titleLineCount: CGFloat = titleDisplayMode == .full ? 2 : 1
        let titleHeight = BookshelfTitleTextStyle.captionMedium.lineHeight * titleLineCount
        let authorFont = AppTypography.uiFixed(
            baseSize: 11,
            textStyle: .caption2,
            minimumPointSize: 11
        )
        let authorHeight = ceil(authorFont.lineHeight + 1)
        return ceil(coverHeight + Spacing.half + titleHeight + Spacing.tiny + authorHeight)
    }
}

/// 二级书籍列表非网格内容的基础尺寸，书籍行以估算高度承接完整元信息。
enum BookshelfBookListLayoutMetrics {
    static let listRowHeight: CGFloat = 128
    static let loadingHeight: CGFloat = 520
    static let emptyHeight: CGFloat = 320
    static let sectionHeaderHeight: CGFloat = 34
}

/// 二级书籍列表 collection 内部 section。
struct BookshelfBookListCollectionSectionState: Hashable {
    let id: String
    let title: String?
    let items: [BookshelfBookListCollectionItem]
}
