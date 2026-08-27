/**
 * [INPUT]: 依赖 BookshelfTypography、书架展示设置、DynamicTypeSize 与 XMBookCover 比例
 * [OUTPUT]: 对 Book feature 提供默认书架与二级书单共用的动态列数和同源排版高度策略
 * [POS]: Book 模块页面私有布局策略；不属于全局设计令牌或跨模块 UIComponents
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 两个生产书架网格共用的布局策略，确保 Dynamic Type、列数与 UIKit 测量保持同一身份。
enum BookshelfGridLayoutPolicy {
    /// 辅助功能字号降低网格密度，但不改写用户持久化的列数偏好。
    static func effectiveColumnCount(
        requested: Int,
        dynamicTypeSize: DynamicTypeSize
    ) -> Int {
        let clamped = max(2, min(requested, 4))
        return dynamicTypeSize.isAccessibilitySize ? min(clamped, 2) : clamped
    }

    /// 使用真实排版 owner 与条件辅助行计算网格项的确定高度。
    static func itemHeight(
        containerWidth: CGFloat,
        requestedColumnCount: Int,
        dynamicTypeSize: DynamicTypeSize,
        titleDisplayMode: BookshelfTitleDisplayMode,
        sortCriteria: BookshelfSortCriteria
    ) -> CGFloat {
        let columnCount = effectiveColumnCount(
            requested: requestedColumnCount,
            dynamicTypeSize: dynamicTypeSize
        )
        let sectionInset = max(0, Spacing.screenEdge / 2)
        let itemHorizontalInset = Spacing.screenEdge / 2
        let availableWidth = max(1, containerWidth - sectionInset * 2)
        let itemWidth = availableWidth / CGFloat(columnCount)
        let contentWidth = max(1, itemWidth - itemHorizontalInset * 2)
        let coverHeight = XMBookCover.height(forWidth: contentWidth)
        let traits = UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory
        )
        let titleFont = BookshelfTypography.uiGridTitle(compatibleWith: traits)
        let subtitleFont = BookshelfTypography.uiGridSubtitle(compatibleWith: traits)
        let titleLineCount: CGFloat = titleDisplayMode == .full ? 2 : 1
        let titleHeight = ceil(titleFont.lineHeight + 2) * titleLineCount
        let subtitleHeight = ceil(subtitleFont.lineHeight + 1)
        let auxiliaryHeight = sortCriteria.canDisplayBookAuxiliaryText
            ? Spacing.tiny + subtitleHeight
            : 0

        return ceil(
            coverHeight
                + Spacing.half
                + titleHeight
                + Spacing.tiny
                + subtitleHeight
                + auxiliaryHeight
        )
    }
}

private extension BookshelfSortCriteria {
    var canDisplayBookAuxiliaryText: Bool {
        switch self {
        case .createdDate, .modifiedDate, .publishDate, .rating, .readDoneDate,
             .totalReadingTime, .readingProgress:
            true
        case .custom, .name, .noteCount, .bookCount, .readStatus, .tagName,
             .authorName, .pressName, .source:
            false
        }
    }
}

private extension DynamicTypeSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
