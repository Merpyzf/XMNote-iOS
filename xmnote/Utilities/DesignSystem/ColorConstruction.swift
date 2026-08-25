/**
 * [INPUT]: 依赖 SwiftUI 与 UIKit 的颜色构造能力
 * [OUTPUT]: 对外提供 Color/UIColor 的十六进制、浅深主题、sRGB 与框架桥接唯一入口
 * [POS]: Utilities/DesignSystem 的底层颜色构造层，供语义颜色和业务局部调色板受控构色
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

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

    /// 组合浅色与深色值，保持颜色在 UIKit trait 环境中动态解析。
    static func xmAdaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.xmResolved(dark)
                : UIColor.xmResolved(light)
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

    /// 从 32 位 RGBA 值构色（高 8 位为红色，低 8 位为透明度）。
    static func xmRGBAHex(_ rgbaHex: UInt32) -> Color {
        let red = Double((rgbaHex >> 24) & 0xFF) / 255.0
        let green = Double((rgbaHex >> 16) & 0xFF) / 255.0
        let blue = Double((rgbaHex >> 8) & 0xFF) / 255.0
        let alpha = Double(rgbaHex & 0xFF) / 255.0
        return xmSRGB(red: red, green: green, blue: blue, opacity: alpha)
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

    /// 组合浅色与深色十六进制值，按当前 trait 环境延迟解析。
    static func xmAdaptive(lightHex: UInt, darkHex: UInt) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.xmHex(darkHex)
                : UIColor.xmHex(lightHex)
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
