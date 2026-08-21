/**
 * [INPUT]: 依赖 BookshelfTitleDisplayMode、DesignTokens 字体与 XMKeywordHighlighting
 * [OUTPUT]: 对外提供 BookshelfTitleText，统一书架卡片与列表中的书名单行/两行尾部省略及搜索关键字高亮语义
 * [POS]: Book 模块页面私有标题组件，被默认书架与二级书籍列表复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书架书名文本；默认与遗留滚动值均单行省略，两行模式保持最多两行省略。
struct BookshelfTitleText: View {
    let text: String
    let mode: BookshelfTitleDisplayMode
    var style: BookshelfTitleTextStyle = .captionMedium
    var color: Color = .textPrimary
    var highlightKeyword: String = ""

    var body: some View {
        switch mode {
        case .standard, .compact:
            titleLabel
                .lineLimit(1)
                .truncationMode(.tail)
        case .full:
            titleLabel
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private var titleLabel: some View {
        XMKeywordHighlighting.text(
            text,
            keyword: highlightKeyword,
            baseFont: style.font,
            highlightFont: style.font,
            baseColor: color
        )
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 书架标题字号语义，保证 SwiftUI 渲染字体与 UIKit 布局行高来自同一设计令牌。
enum BookshelfTitleTextStyle {
    case captionMedium
    case bodyMedium

    var font: Font {
        switch self {
        case .captionMedium:
            return BookshelfTypography.gridTitle
        case .bodyMedium:
            return AppTypography.bodyMedium
        }
    }

    var uiFont: UIFont {
        switch self {
        case .captionMedium:
            return BookshelfTypography.uiGridTitle
        case .bodyMedium:
            return AppTypography.uiSemantic(.body, weight: .medium)
        }
    }

    var lineHeight: CGFloat {
        ceil(uiFont.lineHeight + 2)
    }
}
