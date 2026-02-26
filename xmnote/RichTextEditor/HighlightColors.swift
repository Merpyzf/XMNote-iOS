import UIKit

/// 13 组高亮色 light↔dark 映射，移植自 Android Constant.java
/// 使用 ARGB UInt32 作为字典 key，避免 UIColor 浮点精度问题
enum HighlightColors {

    // MARK: - 默认高亮色

    /// Android: Color.parseColor("#F9E79F") → 0xFFF9E79F
    static let defaultHighlightColor: UInt32 = 0xFFF9E79F

    // MARK: - Light → Dark 映射

    static let lightToDark: [UInt32: UInt32] = [
        0xFFFFE1F9: 0xFF665A64,
        0xFFFDFBCA: 0xFF8D8B42,
        0xFFC8F2EE: 0xFF7C9299,
        0xFFC8EDF8: 0xFF506062,
        0xFFB1C7E7: 0xFF323333,
        0xFFA6CED1: 0xFF6E8788,
        0xFFD4E8A4: 0xFF818F66,
        0xFFF0D472: 0xFFA89C00,
        0xFFF2A4B8: 0xFFAD7683,
        0xFFEB88E1: 0xFFC070B7,
        0xFFECD8FE: 0xFF83798D,
        0xFFDABDB9: 0xFFA9928F,
        0xFFDFDFDF: 0xFF626262,
    ]

    // MARK: - Dark → Light 映射

    static let darkToLight: [UInt32: UInt32] = {
        var map: [UInt32: UInt32] = [:]
        for (light, dark) in lightToDark {
            map[dark] = light
        }
        return map
    }()

    // MARK: - 转换工具

    /// ARGB UInt32 → UIColor
    static func color(from argb: UInt32) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    /// UIColor → ARGB UInt32（取 sRGB 分量）
    static func argb(from color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ai = UInt32(round(a * 255)) & 0xFF
        let ri = UInt32(round(r * 255)) & 0xFF
        let gi = UInt32(round(g * 255)) & 0xFF
        let bi = UInt32(round(b * 255)) & 0xFF
        return (ai << 24) | (ri << 16) | (gi << 8) | bi
    }

    /// 根据当前 trait 返回适配色
    /// - Parameter lightARGB: light mode 下的 ARGB 值
    /// - Parameter traitCollection: 当前 trait
    /// - Returns: 适配后的 UIColor
    static func adaptedColor(lightARGB: UInt32, for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark,
           let darkARGB = lightToDark[lightARGB] {
            return color(from: darkARGB)
        }
        return color(from: lightARGB)
    }

    /// Android 有符号 Int32 色值 → ARGB UInt32
    /// Android 存储格式：`background-color:-394337`（有符号 Int32）
    static func argbFromAndroidInt(_ value: Int32) -> UInt32 {
        return UInt32(bitPattern: value)
    }

    /// ARGB UInt32 → Android 有符号 Int32（序列化用）
    static func androidInt(from argb: UInt32) -> Int32 {
        return Int32(bitPattern: argb)
    }

    /// 将 dark mode 色值还原为 light mode 色值（序列化时使用）
    static func lightARGB(from displayARGB: UInt32) -> UInt32 {
        return darkToLight[displayARGB] ?? displayARGB
    }
}
