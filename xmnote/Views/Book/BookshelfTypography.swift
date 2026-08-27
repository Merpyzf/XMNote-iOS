/**
 * [INPUT]: 依赖 AppTypography、SwiftUI 与 UIKit
 * [OUTPUT]: 对 Book feature 提供书架顶部、搜索与网格内容的组合排版 token
 * [POS]: Views/Book 的页面级排版 owner，隔离书架业务排版与全局基础排版入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书架页面排版令牌，保持顶部、搜索与网格信息层级的既有视觉基线。
enum BookshelfTypography {
    static let topSelected: Font = AppTypography.fixed(
        baseSize: 20,
        relativeTo: .title3,
        weight: .semibold,
        minimumPointSize: 20
    )
    static let topUnselected: Font = AppTypography.fixed(
        baseSize: 18,
        relativeTo: .title3,
        weight: .medium,
        minimumPointSize: 18
    )
    static let searchField: Font = AppTypography.fixed(
        baseSize: 15,
        relativeTo: .body,
        minimumPointSize: 15
    )
    static let uiSearchField: UIFont = AppTypography.uiFixed(
        baseSize: 15,
        textStyle: .body,
        minimumPointSize: 15
    )
    static let gridTitle: Font = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption,
        weight: .medium,
        minimumPointSize: 12
    )
    static let gridSubtitle: Font = AppTypography.fixed(
        baseSize: 11,
        relativeTo: .caption2,
        minimumPointSize: 11
    )

    static let uiGridTitle: UIFont = AppTypography.uiFixed(
        baseSize: 12,
        textStyle: .caption1,
        weight: .medium,
        minimumPointSize: 12
    )
    static let uiGridSubtitle: UIFont = AppTypography.uiFixed(
        baseSize: 11,
        textStyle: .caption2,
        minimumPointSize: 11
    )

    /// 返回与 SwiftUI gridTitle 同源、按指定内容尺寸类别缩放的 UIKit 测量字体。
    nonisolated static func uiGridTitle(compatibleWith traits: UITraitCollection) -> UIFont {
        AppTypography.uiFixed(
            baseSize: 12,
            textStyle: .caption1,
            weight: .medium,
            minimumPointSize: 12,
            compatibleWith: traits
        )
    }

    /// 返回与 SwiftUI gridSubtitle 同源、按指定内容尺寸类别缩放的 UIKit 测量字体。
    nonisolated static func uiGridSubtitle(compatibleWith traits: UITraitCollection) -> UIFont {
        AppTypography.uiFixed(
            baseSize: 11,
            textStyle: .caption2,
            minimumPointSize: 11,
            compatibleWith: traits
        )
    }

    static let listTitle: Font = AppTypography.bodyMedium
    static let uiListTitle: UIFont = AppTypography.uiSemantic(.body, weight: .medium)
}
