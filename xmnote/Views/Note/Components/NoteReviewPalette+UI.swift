/**
 * [INPUT]: 依赖 NoteReviewPalette / NoteReviewTextAlignment 与 SwiftUI/UIKit 颜色类型
 * [OUTPUT]: 对外提供书摘回顾卡片配色与文本对齐的 UI 映射
 * [POS]: Note 模块页面私有 UI 辅助，供回顾卡片和设置 Sheet 共享外观映射
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘回顾卡片配色的页面级 UI 映射。
extension NoteReviewPalette {
    var backgroundStyle: AnyShapeStyle {
        switch self {
        case .paper:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(light: Color(hex: 0xFEFFFE), dark: Color(hex: 0x242827)),
                        Color(light: Color(hex: 0xF9FCFA), dark: Color(hex: 0x222724)),
                        Color(light: Color(hex: 0xF4FAF6), dark: Color(hex: 0x202522))
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .dark:
            return AnyShapeStyle(Color(light: Color(hex: 0x282829), dark: Color(hex: 0x19191A)))
        case .lightGray:
            return AnyShapeStyle(Color(light: Color(hex: 0xF5F5F5), dark: Color(hex: 0x2A2A2C)))
        case .mistBlue:
            return AnyShapeStyle(Color(light: Color(hex: 0xE8EDF6), dark: Color(hex: 0x253044)))
        case .sageGreen:
            return AnyShapeStyle(Color(light: Color(hex: 0xE7F3E7), dark: Color(hex: 0x243529)))
        case .rose:
            return AnyShapeStyle(Color(light: Color(hex: 0xF5E9ED), dark: Color(hex: 0x3A2730)))
        }
    }

    var textColor: Color {
        switch self {
        case .paper:
            return Color(light: Color(hex: 0x3B4540), dark: Color(hex: 0xE4E8E5))
        case .dark:
            return Color(light: .white, dark: Color(hex: 0xF2F2F7))
        case .lightGray:
            return Color(light: Color(hex: 0x202124), dark: Color(hex: 0xE5E5EA))
        case .mistBlue:
            return Color(light: Color(hex: 0x254975), dark: Color(hex: 0xDCE8F8))
        case .sageGreen:
            return Color(light: Color(hex: 0x46554A), dark: Color(hex: 0xDCEADE))
        case .rose:
            return Color(light: Color(hex: 0x76393B), dark: Color(hex: 0xF2DDE4))
        }
    }

    var secondaryTextColor: Color {
        textColor.opacity(0.68)
    }

    var cardBorderColor: Color {
        switch self {
        case .paper:
            return Color(light: Color(hex: 0xDDE8E1).opacity(0.62), dark: Color.white.opacity(0.08))
        case .dark:
            return Color.white.opacity(0.09)
        case .lightGray:
            return textColor.opacity(0.10)
        case .mistBlue:
            return Color(light: Color(hex: 0xC9D5E5).opacity(0.56), dark: textColor.opacity(0.10))
        case .sageGreen:
            return Color(light: Color(hex: 0xC9DBC9).opacity(0.56), dark: textColor.opacity(0.10))
        case .rose:
            return Color(light: Color(hex: 0xE5CCD2).opacity(0.56), dark: textColor.opacity(0.10))
        }
    }

    var footerDividerColor: Color {
        switch self {
        case .dark:
            return Color.white.opacity(0.06)
        default:
            return textColor.opacity(0.045)
        }
    }

    var scrollEdgeWashSurfaceColor: Color {
        switch self {
        case .paper:
            return Color(light: Color(hex: 0xF8FCF9), dark: Color(hex: 0x222724))
        case .dark:
            return Color(light: Color(hex: 0x282829), dark: Color(hex: 0x19191A))
        case .lightGray:
            return Color(light: Color(hex: 0xF5F5F5), dark: Color(hex: 0x2A2A2C))
        case .mistBlue:
            return Color(light: Color(hex: 0xE8EDF6), dark: Color(hex: 0x253044))
        case .sageGreen:
            return Color(light: Color(hex: 0xE7F3E7), dark: Color(hex: 0x243529))
        case .rose:
            return Color(light: Color(hex: 0xF5E9ED), dark: Color(hex: 0x3A2730))
        }
    }

    var ideaBackgroundColor: Color {
        switch self {
        case .dark:
            return Color.white.opacity(0.08)
        default:
            return textColor.opacity(0.08)
        }
    }

    var swatchStyle: AnyShapeStyle {
        backgroundStyle
    }

    var uiTextColor: UIColor {
        switch self {
        case .paper:
            return UIColor(lightHex: 0x3B4540, darkHex: 0xE4E8E5)
        case .dark:
            return UIColor(lightHex: 0xFFFFFF, darkHex: 0xF2F2F7)
        case .lightGray:
            return UIColor(lightHex: 0x202124, darkHex: 0xE5E5EA)
        case .mistBlue:
            return UIColor(lightHex: 0x254975, darkHex: 0xDCE8F8)
        case .sageGreen:
            return UIColor(lightHex: 0x46554A, darkHex: 0xDCEADE)
        case .rose:
            return UIColor(lightHex: 0x76393B, darkHex: 0xF2DDE4)
        }
    }

    var uiBodyTextColor: UIColor {
        UIColor { traitCollection in
            uiTextColor.resolvedColor(with: traitCollection).withAlphaComponent(0.92)
        }
    }

    var uiSupplementTextColor: UIColor {
        UIColor { traitCollection in
            uiTextColor.resolvedColor(with: traitCollection).withAlphaComponent(0.88)
        }
    }
}

/// 书摘回顾文本对齐的 SwiftUI 映射。
extension NoteReviewTextAlignment {
    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading:
            return .natural
        case .center:
            return .center
        case .trailing:
            return .right
        }
    }
}

private extension UIColor {
    convenience init(lightHex: UInt, darkHex: UInt) {
        self.init { traitCollection in
            switch traitCollection.userInterfaceStyle {
            case .dark:
                return UIColor(hex: darkHex)
            default:
                return UIColor(hex: lightHex)
            }
        }
    }

    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
