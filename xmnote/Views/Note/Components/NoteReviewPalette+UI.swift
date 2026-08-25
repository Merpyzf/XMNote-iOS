/**
 * [INPUT]: 依赖 NoteReviewPalette / NoteReviewTextAlignment 与 SwiftUI/UIKit 颜色类型
 * [OUTPUT]: 对外提供书摘回顾卡片配色与文本对齐的 UI 映射
 * [POS]: Note 模块页面私有 UI 辅助，供回顾卡片和设置 Sheet 共享外观映射
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘回顾配色的页面级 UI 映射，始终从领域层的亮暗纯色集合构造动态颜色。
extension NoteReviewPalette {
    /// 当前规范化配色的自适应不透明卡片表面。
    var cardSurfaceColor: Color {
        Color.xmResolved(uiCardSurfaceColor)
    }

    /// 当前规范化配色的自适应卡片前景色。
    var cardOnSurfaceColor: Color {
        Color.xmResolved(uiCardOnSurfaceColor)
    }

    /// 当前规范化配色的 UIKit 表面色，供 RichText 等 UIKit 路径按系统主题解析。
    var uiCardSurfaceColor: UIColor {
        let colorSet = canonicalPalette.cardColorSet
        return UIColor.xmAdaptive(lightHex: UInt(colorSet.lightSurfaceHex), darkHex: UInt(colorSet.darkSurfaceHex))
    }

    /// 当前规范化配色的 UIKit 前景色，供 RichText 等 UIKit 路径按系统主题解析。
    var uiCardOnSurfaceColor: UIColor {
        let colorSet = canonicalPalette.cardColorSet
        return UIColor.xmAdaptive(lightHex: UInt(colorSet.lightTextHex), darkHex: UInt(colorSet.darkTextHex))
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

    /// 想法引导线使用的 on-surface 派生颜色。
    var ideaRuleColor: Color {
        onSurface.opacity(0.18)
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
        let surface = Color.xmResolved(UIColor.xmAdaptive(
            lightHex: UInt(cardSurfaceHex(isDarkAppearance: false)),
            darkHex: UInt(cardSurfaceHex(isDarkAppearance: true))
        ))
        let uiOnSurface = UIColor.xmAdaptive(
            lightHex: UInt(cardTextHex(isDarkAppearance: false)),
            darkHex: UInt(cardTextHex(isDarkAppearance: true))
        )

        return NoteReviewCardAppearance(
            surface: surface,
            backgroundImageURL: imageURL,
            onSurface: Color.xmResolved(uiOnSurface),
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
    /// 创建保留亮暗模式解析能力的指定不透明度颜色。
    func withOpacity(_ opacity: CGFloat) -> UIColor {
        UIColor { traitCollection in
            self.resolvedColor(with: traitCollection).withAlphaComponent(opacity)
        }
    }

}

extension Color {
    /// 将当前 ColorPicker 选择转换为持久化使用的 RGB 十六进制值。
    var rgbHex: UInt32 {
        let resolved = UIColor.xmResolved(self)
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
