/**
 * [INPUT]: 依赖 NoteReviewPalette / NoteReviewTextAlignment 与 SwiftUI/UIKit 颜色类型
 * [OUTPUT]: 对外提供书摘回顾卡片配色、想法中性轻托底与文本对齐的 UI 映射
 * [POS]: Note 模块页面私有 UI 辅助，供回顾卡片和设置 Sheet 共享外观映射
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘回顾配色的页面级 UI 映射，始终从领域层的亮暗纯色集合构造动态颜色。
extension NoteReviewPalette {
    /// 当前规范化配色的自适应不透明卡片表面。
    var cardSurfaceColor: Color {
        Color(uiColor: uiCardSurfaceColor)
    }

    /// 当前规范化配色的自适应卡片前景色。
    var cardOnSurfaceColor: Color {
        Color(uiColor: uiCardOnSurfaceColor)
    }

    /// 当前规范化配色的 UIKit 表面色，供 RichText 等 UIKit 路径按系统主题解析。
    var uiCardSurfaceColor: UIColor {
        let colorSet = canonicalPalette.cardColorSet
        return UIColor(lightHex: UInt(colorSet.lightSurfaceHex), darkHex: UInt(colorSet.darkSurfaceHex))
    }

    /// 当前规范化配色的 UIKit 前景色，供 RichText 等 UIKit 路径按系统主题解析。
    var uiCardOnSurfaceColor: UIColor {
        let colorSet = canonicalPalette.cardColorSet
        return UIColor(lightHex: UInt(colorSet.lightTextHex), darkHex: UInt(colorSet.darkTextHex))
    }
}

/// 回顾卡片的单一外观描述，确保所有前景层级均由同一 on-surface 颜色派生。
struct NoteReviewCardAppearance {
    /// 用于颜色模式卡片与图片加载失败的纯色表面。
    let surface: Color
    /// 用于图片模式加载成功时覆盖卡片的远程背景地址。
    let backgroundImageURL: String?
    /// 卡片的基础 on-surface 前景色；仅图片模式会应用已存储的自定义文字色。
    let onSurface: Color
    /// 想法区域使用的动态中性托底色，纯色模式建立克制明度差、图片模式增强文字方向的对比。
    let ideaBackgroundColor: Color
    /// UIKit 富文本所需的动态 on-surface 前景色。
    let uiOnSurface: UIColor

    /// 正文使用的 92% on-surface UIKit 颜色。
    var bodyTextColor: UIColor {
        uiOnSurface.withOpacity(0.92)
    }

    /// 辅助富文本使用的 76% on-surface UIKit 颜色。
    var supplementTextColor: UIColor {
        uiOnSurface.withOpacity(0.76)
    }

    /// SwiftUI 辅助文字使用的 76% on-surface 颜色。
    var secondaryTextColor: Color {
        onSurface.opacity(0.76)
    }

    /// 页脚标题等主要 SwiftUI 文字使用的 92% on-surface 颜色。
    var bodyForegroundColor: Color {
        onSurface.opacity(0.92)
    }

    /// 卡片边框使用的 on-surface 派生颜色。
    var borderColor: Color {
        onSurface.opacity(0.16)
    }

    /// 页脚分隔线使用的 on-surface 派生颜色。
    var footerDividerColor: Color {
        onSurface.opacity(0.045)
    }

    /// 标签文字使用的 on-surface 派生颜色。
    var tagForegroundColor: Color {
        secondaryTextColor
    }

    /// 标签胶囊底色使用的 on-surface 派生颜色。
    var tagBackgroundColor: Color {
        onSurface.opacity(0.06)
    }

    /// 图片未加载时的占位表面使用的 on-surface 派生颜色。
    var imagePlaceholderColor: Color {
        onSurface.opacity(0.08)
    }

    /// 图片边框使用的 on-surface 派生颜色。
    var imageBorderColor: Color {
        onSurface.opacity(0.11)
    }

    /// 书籍封面边框使用的 on-surface 派生颜色。
    var coverBorderColor: Color {
        onSurface.opacity(0.12)
    }
}

/// 将回顾设置映射为卡片的唯一 UI 外观入口，并保留旧版自定义背景数据的纯色兼容回退。
extension NoteReviewSettings {
    /// 当前设置对应的卡片外观；颜色模式不生成渐变，图片不可用时回退到规范化 palette 表面。
    var cardAppearance: NoteReviewCardAppearance {
        let imageURL = normalizedBackgroundImageURL
        let lightSurfaceHex = UInt(cardSurfaceHex(isDarkAppearance: false))
        let darkSurfaceHex = UInt(cardSurfaceHex(isDarkAppearance: true))
        let lightTextHex = UInt(cardTextHex(isDarkAppearance: false))
        let darkTextHex = UInt(cardTextHex(isDarkAppearance: true))
        let uiSurface = UIColor(lightHex: lightSurfaceHex, darkHex: darkSurfaceHex)
        let uiOnSurface = UIColor(lightHex: lightTextHex, darkHex: darkTextHex)
        let uiIdeaBackground = NoteReviewIdeaSurfaceStyle.backgroundColor(
            mode: backgroundMode,
            lightSurfaceHex: lightSurfaceHex,
            darkSurfaceHex: darkSurfaceHex,
            lightTextHex: lightTextHex,
            darkTextHex: darkTextHex
        )

        return NoteReviewCardAppearance(
            surface: Color(uiColor: uiSurface),
            backgroundImageURL: imageURL,
            onSurface: Color(uiColor: uiOnSurface),
            ideaBackgroundColor: Color(uiColor: uiIdeaBackground),
            uiOnSurface: uiOnSurface
        )
    }

    /// 规范化图片地址，避免空白字符串触发无效的远程图片请求。
    private var normalizedBackgroundImageURL: String? {
        guard backgroundMode == .image else { return nil }
        guard let backgroundImageURL else { return nil }
        let trimmedURL = backgroundImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedURL.isEmpty ? nil : trimmedURL
    }
}

/// 想法区域的页面私有表面策略，以中性明度差替代 on-surface 染色。
private enum NoteReviewIdeaSurfaceStyle {
    static let lightSurfaceLuminanceThreshold: CGFloat = 0.20
    static let lightSurfaceDarkeningOpacity: CGFloat = 0.02
    static let darkSurfaceOverlayOpacity: CGFloat = 0.06
    static let imageOverlayOpacity: CGFloat = 0.12
    static let contrastBackdropPivotLuminance: CGFloat = 0.179

    /// 根据卡片背景模式与当前亮暗外观生成透明托底色，保留底层纯色或图片纹理。
    static func backgroundColor(
        mode: NoteReviewBackgroundMode,
        lightSurfaceHex: UInt,
        darkSurfaceHex: UInt,
        lightTextHex: UInt,
        darkTextHex: UInt
    ) -> UIColor {
        UIColor { traitCollection in
            let isDarkAppearance = traitCollection.userInterfaceStyle == .dark
            let surfaceHex = isDarkAppearance ? darkSurfaceHex : lightSurfaceHex
            let textHex = isDarkAppearance ? darkTextHex : lightTextHex

            switch mode {
            case .color:
                if relativeLuminance(of: surfaceHex) >= lightSurfaceLuminanceThreshold {
                    return UIColor.black.withAlphaComponent(lightSurfaceDarkeningOpacity)
                }
                return UIColor.white.withAlphaComponent(darkSurfaceOverlayOpacity)
            case .image:
                let overlayColor: UIColor = relativeLuminance(of: textHex) > contrastBackdropPivotLuminance
                    ? .black
                    : .white
                return overlayColor.withAlphaComponent(imageOverlayOpacity)
            }
        }
    }

    /// 按 WCAG 的 sRGB 线性化规则计算十六进制颜色的相对亮度。
    private static func relativeLuminance(of hex: UInt) -> CGFloat {
        let red = linearizedComponent(CGFloat((hex >> 16) & 0xFF) / 255.0)
        let green = linearizedComponent(CGFloat((hex >> 8) & 0xFF) / 255.0)
        let blue = linearizedComponent(CGFloat(hex & 0xFF) / 255.0)
        return red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    /// 将单个 sRGB 分量转换到线性光空间，供相对亮度判断使用。
    private static func linearizedComponent(_ component: CGFloat) -> CGFloat {
        guard component > 0.04045 else {
            return component / 12.92
        }
        return CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
    }
}

/// 将领域字体选择转换为 RichText 所需的 UIKit 字体；本地字体未注册时安全回退到系统字体。
extension NoteReviewFontSelection {
    /// 按当前字体选择生成与基础字号一致的 UIKit 字体。
    func uiFont(base: UIFont) -> UIFont {
        switch self {
        case .system:
            return base
        case .sourceHanSerif:
            return UIFont(name: "Songti SC", size: base.pointSize) ?? base
        case .local(_, let displayName):
            return UIFont(name: displayName, size: base.pointSize) ?? base
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
        case .justified:
            return .leading
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
        case .justified:
            return .leading
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
        case .justified:
            return .justified
        }
    }

    /// 短标题与元信息不参与两端拉伸；其他模式继续服从用户选择。
    var auxiliaryNSTextAlignment: NSTextAlignment {
        switch self {
        case .justified:
            return .natural
        case .leading, .center, .trailing:
            return nsTextAlignment
        }
    }
}

private extension UIColor {
    /// 创建保留亮暗模式解析能力的指定不透明度颜色。
    func withOpacity(_ opacity: CGFloat) -> UIColor {
        UIColor { traitCollection in
            self.resolvedColor(with: traitCollection).withAlphaComponent(opacity)
        }
    }

    /// 根据系统亮暗模式解析两组 RGB 十六进制颜色。
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

    /// 根据 RGB 十六进制值创建不透明 UIKit 颜色。
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

extension Color {
    /// 将当前 ColorPicker 选择转换为持久化使用的 RGB 十六进制值。
    var rgbHex: UInt32 {
        let resolved = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            return 0
        }
        return UInt32(red * 255.0) << 16
            | UInt32(green * 255.0) << 8
            | UInt32(blue * 255.0)
    }
}
