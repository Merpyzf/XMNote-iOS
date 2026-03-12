/**
 * [INPUT]: 依赖 SwiftUI/UIKit/CoreText 的文本样式与动态字号能力，接收业务侧约定的默认字号、字重、设计风格与语义文本样式
 * [OUTPUT]: 对外提供 SemanticTypography，统一把现有固定字号挂到系统 Dynamic Type 缩放曲线，同时保留默认态视觉大小
 * [POS]: Utilities 模块的语义排版桥接层，负责在不抬高默认视觉密度的前提下补齐语义缩放与最小可读字号约束
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreText
import SwiftUI
import UIKit

/// 系统语义排版桥接层：保留当前默认视觉密度，只补系统语义缩放和可读性下限。
enum SemanticTypography {
    static let minimumReadablePointSize: CGFloat = 11

    /// 返回保留 base size 的 SwiftUI 语义字体，默认态不抬高视觉层级。
    static func font(
        baseSize: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        minimumPointSize: CGFloat = minimumReadablePointSize,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> Font {
        let uiFont = uiFont(
            baseSize: baseSize,
            textStyle: textStyle.uiFontTextStyle,
            weight: weight?.uiFontWeight ?? .regular,
            design: design.uiFontSystemDesign,
            minimumPointSize: minimumPointSize,
            compatibleWith: traitCollection
        )
        return Font(uiFont as CTFont)
    }

    /// 返回保留 base size 的 UIKit 语义字体，供布局测量与 UIKit 桥接复用。
    static func uiFont(
        baseSize: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        design: UIFontDescriptor.SystemDesign = .default,
        minimumPointSize: CGFloat = minimumReadablePointSize,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        let clampedBaseSize = max(minimumPointSize, baseSize)
        var descriptor = UIFont.systemFont(ofSize: clampedBaseSize, weight: weight).fontDescriptor
        if design != .default, let designedDescriptor = descriptor.withDesign(design) {
            descriptor = designedDescriptor
        }
        let baseFont = UIFont(descriptor: descriptor, size: clampedBaseSize)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: baseFont,
            compatibleWith: traitCollection
        )
    }

    /// 返回缩放后的点数，供几何布局与自定义尺寸联动。
    static func scaledPointSize(
        baseSize: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        design: UIFontDescriptor.SystemDesign = .default,
        minimumPointSize: CGFloat = minimumReadablePointSize,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> CGFloat {
        uiFont(
            baseSize: baseSize,
            textStyle: textStyle,
            weight: weight,
            design: design,
            minimumPointSize: minimumPointSize,
            compatibleWith: traitCollection
        ).pointSize
    }

    /// 返回给定文本样式在默认 content size 下的系统点数，供“保当前视觉”迁移使用。
    static func defaultPointSize(for textStyle: UIFont.TextStyle) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        return UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: textStyle,
            compatibleWith: traits
        ).pointSize
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

private extension Font.Weight {
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .ultraLight:
            return .ultraLight
        case .thin:
            return .thin
        case .light:
            return .light
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        case .black:
            return .black
        default:
            return .regular
        }
    }
}

private extension Font.Design {
    var uiFontSystemDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .default:
            return .default
        case .rounded:
            return .rounded
        case .monospaced:
            return .monospaced
        case .serif:
            return .serif
        @unknown default:
            return .default
        }
    }
}
