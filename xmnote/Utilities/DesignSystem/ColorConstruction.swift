/**
 * [INPUT]: 依赖 SwiftUI 与 UIKit 的颜色构造能力
 * [OUTPUT]: 对内提供受限 BaseColorPalette，对外提供 Color/UIColor 的集中构色与框架桥接入口
 * [POS]: Utilities/DesignSystem 的底层颜色构造层，供语义颜色和已批准局部调色板受控构色
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 仅承载被多个语义角色共享的原始品牌色阶，业务代码不得直接消费。
enum BaseColorPalette {
    static let brand200 = Color.xmHex(0xACEEBB)
    static let brand500 = Color.xmAdaptive(
        light: Color.xmHex(0x2ECF77),
        dark: Color.xmHex(0x2ECF77),
        highContrastLight: Color.xmHex(0x197A43),
        highContrastDark: Color.xmHex(0x5CDB90)
    )
    static let brand700 = Color.xmHex(0x2DA44F)
    static let brand900 = Color.xmHex(0x11632A)
}

// MARK: - Color Helpers

extension Color {
    /// 从设计值构建静态 RGB 色；调用方仍应优先选择已有语义色。
    static func xmHex(_ hex: UInt, alpha: Double = 1.0) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// 组合浅色、深色及可选高对比度值，保持颜色在 UIKit trait 环境中动态解析。
    static func xmAdaptive(
        light: Color,
        dark: Color,
        highContrastLight: Color? = nil,
        highContrastDark: Color? = nil
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHighContrast = traits.accessibilityContrast == .high

            if isHighContrast {
                return UIColor.xmResolved(
                    isDark ? highContrastDark ?? dark : highContrastLight ?? light
                )
            }
            return UIColor.xmResolved(isDark ? dark : light)
        })
    }

    /// 将 UIKit 动态色桥接为 SwiftUI Color，并保留系统 trait 解析能力。
    static func xmResolved(_ uiColor: UIColor) -> Color {
        Color(uiColor: uiColor)
    }

    /// 从归一化 sRGB 分量构色，集中承载算法产出的运行时颜色。
    static func xmSRGB<Component: BinaryFloatingPoint>(
        red: Component,
        green: Component,
        blue: Component,
        opacity: Component = 1.0
    ) -> Color {
        Color(
            .sRGB,
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            opacity: Double(opacity)
        )
    }

}

extension UIColor {
    /// 将 SwiftUI Color 桥接为 UIKit 动态色，供 UIKit 组件和离屏渲染复用。
    static func xmResolved(_ color: Color) -> UIColor {
        UIColor(color)
    }

    /// 从设计值构建静态 UIKit RGB 色；调用方仍应优先选择已有语义色。
    static func xmHex(_ hex: UInt, alpha: CGFloat = 1.0) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// 组合浅色、深色及可选高对比度十六进制值，按当前 trait 环境延迟解析。
    static func xmAdaptive(
        lightHex: UInt,
        darkHex: UInt,
        highContrastLightHex: UInt? = nil,
        highContrastDarkHex: UInt? = nil
    ) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHighContrast = traits.accessibilityContrast == .high

            if isHighContrast {
                return UIColor.xmHex(
                    isDark ? highContrastDarkHex ?? darkHex : highContrastLightHex ?? lightHex
                )
            }
            return UIColor.xmHex(isDark ? darkHex : lightHex)
        }
    }

    /// 从归一化 sRGB 分量构色，集中承载 UIKit 绘制与算法输出颜色。
    nonisolated static func xmSRGB(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat = 1.0
    ) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
