/**
 * [INPUT]: 依赖 SwiftUI、UIKit、SemanticTypography 与 BrandTypography
 * [OUTPUT]: 对外提供生产文本的 AppTypography 入口及共享图表/内联排版能力
 * [POS]: Utilities/DesignSystem 的基础排版层，统一 SwiftUI 渲染与 UIKit 测量字体来源
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

// MARK: - Reading Calendar Typography

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

    static func semanticFont(
        _ style: UIFont.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        fixed(
            baseSize: SemanticTypography.defaultPointSize(for: style),
            relativeTo: style.fontTextStyle,
            weight: weight,
            design: design,
            minimumPointSize: SemanticTypography.defaultPointSize(for: style)
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

    static func uiSemantic(
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

    static func uiFixed(
        baseSize: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        design: UIFontDescriptor.SystemDesign = .default,
        minimumPointSize: CGFloat? = nil
    ) -> UIFont {
        SemanticTypography.uiFont(
            baseSize: baseSize,
            textStyle: textStyle,
            weight: weight,
            design: design,
            minimumPointSize: minimumPointSize ?? baseSize
        )
    }

    /// 返回与 `captionMedium` 同源的 UIKit 字体，供基线测量与内联操作渲染复用。
    static func uiCaptionMedium(
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        SemanticTypography.uiFont(
            baseSize: SemanticTypography.defaultPointSize(for: .caption1),
            textStyle: .caption1,
            weight: .medium,
            minimumPointSize: SemanticTypography.defaultPointSize(for: .caption1),
            compatibleWith: traitCollection
        )
    }

    static func brandDisplay(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle = .title2
    ) -> Font {
        .brandDisplay(size: size, relativeTo: textStyle)
    }

    static func brandTrim(
        size: CGFloat,
        textStyle: UIFont.TextStyle = .title2
    ) -> BrandTypography.VerticalTrim {
        BrandTypography.verticalTrim(size: size, textStyle: textStyle)
    }

    static func topSwitcherTitleFont(
        for text: String,
        size: CGFloat
    ) -> Font {
        if text.xmContainsCJK {
            return fixed(
                baseSize: size,
                relativeTo: .headline,
                weight: .semibold,
                minimumPointSize: size
            )
        }
        return brandDisplay(size: size, relativeTo: .headline)
    }

    static func topSwitcherTitleTrim(
        for text: String,
        size: CGFloat
    ) -> BrandTypography.VerticalTrim {
        guard !text.xmContainsCJK else { return .zero }
        return brandTrim(size: size, textStyle: .headline)
    }
}

/// 月历热力图排版令牌，统一 Android 对齐字号与 SwiftUI/UIKit 测量字体来源。
enum CalendarHeatmapTypography {
    /// 返回月标题字体，使 SwiftUI 渲染跟随调用环境的 Dynamic Type。
    static func monthTitle(compatibleWith traitCollection: UITraitCollection? = nil) -> Font {
        SemanticTypography.font(
            baseSize: 12,
            relativeTo: .caption,
            weight: .bold,
            minimumPointSize: 12,
            compatibleWith: traitCollection
        )
    }

    /// 返回日期数字字体，与 uiDay 使用同一字号、语义曲线和辅助功能环境。
    static func day(compatibleWith traitCollection: UITraitCollection? = nil) -> Font {
        SemanticTypography.font(
            baseSize: 10,
            relativeTo: .caption2,
            minimumPointSize: 10,
            compatibleWith: traitCollection
        )
    }

    /// 返回图例文本字体，让不同使用场景保留各自视觉字号并共享语义缩放曲线。
    static func legend(baseSize: CGFloat) -> Font {
        AppTypography.fixed(
            baseSize: baseSize,
            relativeTo: .caption2,
            minimumPointSize: baseSize
        )
    }

    /// 返回日期数字的 UIKit 同源字体，供单元格尺寸测量使用。
    static func uiDay(compatibleWith traitCollection: UITraitCollection? = nil) -> UIFont {
        SemanticTypography.uiFont(
            baseSize: 10,
            textStyle: .caption2,
            minimumPointSize: 10,
            compatibleWith: traitCollection
        )
    }

    /// 返回月标题的 UIKit 同源字体，供横向滚动视口锁定最大月份高度。
    static func uiMonthTitle(compatibleWith traitCollection: UITraitCollection? = nil) -> UIFont {
        SemanticTypography.uiFont(
            baseSize: 12,
            textStyle: .caption1,
            weight: .bold,
            minimumPointSize: 12,
            compatibleWith: traitCollection
        )
    }
}

/// 月度阅读图表排版令牌，确保 SwiftUI 渲染字体与 UIKit 宽高测量使用同一来源。
enum MonthlyReadingChartTypography {
    static let collapsedSummary: Font = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption,
        minimumPointSize: 12
    )
    static let expandedSummary: Font = AppTypography.fixed(
        baseSize: 10.8,
        relativeTo: .caption2,
        minimumPointSize: 10.8
    )
    static let arrow: Font = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .caption,
        minimumPointSize: 14
    )
    static let dailyDate: Font = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption,
        minimumPointSize: 12
    )
    static let dailyDuration: Font = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption,
        weight: .medium,
        minimumPointSize: 12
    )

    static let uiCollapsedSummary: UIFont = AppTypography.uiFixed(
        baseSize: 12,
        textStyle: .caption1,
        minimumPointSize: 12
    )
    static let uiExpandedSummary: UIFont = AppTypography.uiFixed(
        baseSize: 10.8,
        textStyle: .caption2,
        minimumPointSize: 10.8
    )
    static let uiDailyDate: UIFont = AppTypography.uiFixed(
        baseSize: 12,
        textStyle: .caption1,
        minimumPointSize: 12
    )
    static let uiDailyDuration: UIFont = AppTypography.uiFixed(
        baseSize: 12,
        textStyle: .caption1,
        weight: .medium,
        minimumPointSize: 12
    )
}

/// 内容区 Inline Tab 的固定视觉层级，在辅助导航与正文之间保持 14pt 中间档。
enum XMInlineTabTypography {
    static let label: Font = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .footnote,
        minimumPointSize: 14
    )
    static let selectedLabel: Font = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .footnote,
        weight: .semibold,
        minimumPointSize: 14
    )
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

private extension UIFont.TextStyle {
    var fontTextStyle: Font.TextStyle {
        switch self {
        case .largeTitle:
            return .largeTitle
        case .title1:
            return .title
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
        case .caption1:
            return .caption
        case .caption2:
            return .caption2
        default:
            return .body
        }
    }
}

private extension String {
    var xmContainsCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x3040...0x30FF,
                 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}

/// 书架首页与书架列表的排版令牌，承接参考截图量取后的标题、搜索与网格文本层级。
