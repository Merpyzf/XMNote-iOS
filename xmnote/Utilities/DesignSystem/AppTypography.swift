/**
 * [INPUT]: 依赖 SwiftUI、UIKit、SemanticTypography 与 BrandTypography
 * [OUTPUT]: 对外提供生产文本的 AppTypography 入口
 * [POS]: Utilities/DesignSystem 的基础排版层，统一 SwiftUI 渲染与 UIKit 测量字体来源
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

// MARK: - App Typography

/// 全局文本语义入口，统一生产路径字体出口，并尽量保持当前默认视觉基线不变。
enum AppTypography {
    static let largeTitle: Font = .largeTitle
    static let title2: Font = .title2
    static let title3: Font = .title3
    static let title3Semibold: Font = .title3.weight(.semibold)
    static let headline: Font = .headline
    static let headlineSemibold: Font = .headline.weight(.semibold)
    static let subheadline: Font = .subheadline
    static let subheadlineMedium: Font = .subheadline.weight(.medium)
    static let subheadlineSemibold: Font = .subheadline.weight(.semibold)
    static let body: Font = .body
    static let bodyMedium: Font = .body.weight(.medium)
    static let callout: Font = .callout
    static let footnote: Font = .footnote
    static let monospacedFootnote: Font = .system(.footnote, design: .monospaced)
    static let footnoteMedium: Font = .footnote.weight(.medium)
    static let footnoteSemibold: Font = .footnote.weight(.semibold)
    static let caption: Font = .caption
    static let captionMedium: Font = .caption.weight(.medium)
    static let captionSemibold: Font = .caption.weight(.semibold)
    static let caption2: Font = .caption2
    static let caption2Medium: Font = .caption2.weight(.medium)
    static let caption2Semibold: Font = .caption2.weight(.semibold)

    static func semantic(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        fixed(
            baseSize: SemanticTypography.defaultPointSize(for: style.uiFontTextStyle),
            relativeTo: style,
            weight: weight,
            design: design,
            minimumPointSize: SemanticTypography.defaultPointSize(for: style.uiFontTextStyle)
        )
    }

    static func fixed(
        baseSize: CGFloat,
        relativeTo style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        minimumPointSize: CGFloat? = nil
    ) -> Font {
        SemanticTypography.font(
            baseSize: baseSize,
            relativeTo: style,
            weight: weight,
            design: design,
            minimumPointSize: minimumPointSize ?? baseSize
        )
    }

    nonisolated static func uiSemantic(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        design: UIFontDescriptor.SystemDesign = .default
    ) -> UIFont {
        let baseSize = SemanticTypography.defaultPointSize(for: style)
        return SemanticTypography.uiFont(
            baseSize: baseSize,
            textStyle: style,
            weight: weight,
            design: design,
            minimumPointSize: baseSize
        )
    }

    nonisolated static func uiFixed(
        baseSize: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        design: UIFontDescriptor.SystemDesign = .default,
        minimumPointSize: CGFloat? = nil,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        SemanticTypography.uiFont(
            baseSize: baseSize,
            textStyle: textStyle,
            weight: weight,
            design: design,
            minimumPointSize: minimumPointSize ?? baseSize,
            compatibleWith: traitCollection
        )
    }

    static func brandDisplay(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle = .title2
    ) -> Font {
        Font.brandDisplay(size: size, relativeTo: textStyle)
    }

    static func brandTrim(
        size: CGFloat,
        textStyle: UIFont.TextStyle = .title2
    ) -> BrandTypography.VerticalTrim {
        BrandTypography.verticalTrim(size: size, textStyle: textStyle)
    }

}

private extension Font.TextStyle {
    var uiFontTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle:
            return .largeTitle
        case .title:
            return .title1
        case .title2:
            return .title2
        case .title3:
            return .title3
        case .headline:
            return .headline
        case .subheadline:
            return .subheadline
        case .body:
            return .body
        case .callout:
            return .callout
        case .footnote:
            return .footnote
        case .caption:
            return .caption1
        case .caption2:
            return .caption2
        @unknown default:
            return .body
        }
    }
}
