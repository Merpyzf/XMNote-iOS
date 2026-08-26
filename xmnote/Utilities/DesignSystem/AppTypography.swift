/**
 * [INPUT]: 依赖 SwiftUI、UIKit、SemanticTypography 与 BrandTypography
 * [OUTPUT]: 对外提供生产文本的 AppTypography 基础档位与 SettingsTypography 配置页语义组合
 * [POS]: Utilities/DesignSystem 的基础排版层，统一 SwiftUI 渲染、UIKit 测量与跨配置页稳定文本层级
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

// MARK: - App Typography

/// 全局文本语义入口，按信息层级统一生产路径字体出口，并保持系统 Dynamic Type 语义。
enum AppTypography {
    // 大标题层仅用于自定义焦点标题；系统导航标题继续交给 navigationTitle 管理。
    static let largeTitle: Font = .largeTitle
    static let title2: Font = .title2
    static let title3: Font = .title3
    static let title3Semibold: Font = .title3.weight(.semibold)

    // 主信息层用于卡片、列表与分区的首要标题；不替代长正文或辅助说明。
    static let headline: Font = .headline
    static let headlineSemibold: Font = .headline.weight(.semibold)

    // 次信息层用于列表副文本、字段值与紧凑说明；相邻档位不得仅凭局部观感混用。
    static let subheadline: Font = .subheadline
    static let subheadlineMedium: Font = .subheadline.weight(.medium)
    static let subheadlineSemibold: Font = .subheadline.weight(.semibold)

    // 正文层用于主要阅读文本与标准控件标签；callout 只承接更紧凑的说明正文。
    static let body: Font = .body
    static let bodyMedium: Font = .body.weight(.medium)
    static let callout: Font = .callout

    // 辅助层用于说明、状态与较弱操作，不用于承担页面主要任务。
    static let footnote: Font = .footnote
    static let monospacedFootnote: Font = .system(.footnote, design: .monospaced)
    static let footnoteMedium: Font = .footnote.weight(.medium)
    static let footnoteSemibold: Font = .footnote.weight(.semibold)

    // 元数据层用于时间、来源、标签与密集信息；caption2 不承载关键正文或主要操作。
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

/// 配置页稳定排版组合：主行 17pt 层、值 15pt 层、说明与分区标题 13pt 层。
/// 仅用于 Settings 页面语义，不替代书架、书摘或业务卡片已有的 feature token。
enum SettingsTypography {
    static let rowTitle: Font = AppTypography.bodyMedium
    static let rowValue: Font = AppTypography.subheadline
    static let rowDescription: Font = AppTypography.footnote
    static let sectionTitle: Font = AppTypography.footnoteSemibold
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
