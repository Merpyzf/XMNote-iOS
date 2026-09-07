/**
 * [INPUT]: 依赖 NoteReviewPalette / NoteReviewTextAlignment / NoteReviewFontSelection、SwiftUI/UIKit 颜色与内置思源宋体资源
 * [OUTPUT]: 对外提供书摘回顾卡片分级配色、中性画布外观、思源宋体解析、想法中性轻托底与文本对齐的 UI 映射
 * [POS]: Note 模块页面私有 UI 辅助，供回顾卡片和设置 Sheet 共享外观映射
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit
import os

/// 书摘桌面的页面私有表层语义；深色使用中性炭灰，普通装饰不染入品牌绿色。
enum NoteReviewCanvasAppearance {
    static let page = UIColor.xmResolved(Color.surfacePage)
    static let paper = UIColor.xmResolved(Color.surfaceCard)
    static let sheet = UIColor.xmResolved(Color.surfaceSheet)
    static let primary = UIColor.xmResolved(Color.textPrimary)
    static let secondary = UIColor.xmResolved(Color.textSecondary)
    static let hint = UIColor.xmResolved(Color.textHint)
    static let accent = UIColor.xmResolved(Color.selectionAccent)
    static let border = UIColor.xmResolved(Color.surfaceBorderDefault)
    static let subtleBorder = UIColor.xmResolved(Color.surfaceBorderSubtle)
    static let progressSurface = Color.xmResolved(UIColor.xmAdaptive(lightHex: 0x303030, darkHex: 0x303030))
    static let progressForeground = Color.xmResolved(UIColor.xmAdaptive(lightHex: 0xBBBBBB, darkHex: 0xBBBBBB,
        highContrastDarkHex: 0xF2F2F2))
    static let decoration = UIColor { traits in
        (traits.userInterfaceStyle == .dark ? UIColor.xmAdaptive(lightHex: 0x626262, darkHex: 0x626262) : UIColor.tertiaryLabel)
            .resolvedColor(with: traits)
    }
    static let canvasTint = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .clear : accent.resolvedColor(with: traits).withAlphaComponent(0.025)
    }
    static let actionForeground = Color.xmResolved(UIColor { traits in
        let color = traits.userInterfaceStyle == .dark
            ? UIColor.xmResolved(traits.accessibilityContrast == .high ? Color.iconPrimary : Color.iconSecondary)
            : UIColor.xmResolved(Color.textSecondary).withAlphaComponent(0.94)
        return color.resolvedColor(with: traits)
    })
    static let chromeForeground = UIColor { traits in
        (traits.userInterfaceStyle == .dark ? UIColor.xmResolved(Color.iconPrimary) : UIColor.label)
            .resolvedColor(with: traits)
    }

    /// 离屏纸面回到 UIKit 代理时沿用已解析颜色，不重新选择深浅主题。
    static func resolvedPaper(_ color: CGColor) -> UIColor { UIColor(cgColor: color) }

    /// 两种纸张材质在单一显示对象内连续混合，构色集中在既有页面外观 owner。
    static func interpolatePaper(from: CGColor, to: CGColor, progress: CGFloat) -> UIColor {
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        UIColor(cgColor: from).getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
        UIColor(cgColor: to).getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let p = min(1, max(0, progress))
        return UIColor.xmSRGB(red: sr + (tr - sr) * p, green: sg + (tg - sg) * p,
            blue: sb + (tb - sb) * p, alpha: sa + (ta - sa) * p)
    }

    static let backgroundColor = UIColor.xmAdaptive(
        lightHex: 0xF0F2F1,
        darkHex: 0x121212,
        highContrastLightHex: 0xE8ECEA,
        highContrastDarkHex: 0x111312
    )
}

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

/// 回顾卡片的单一外观描述，中性深色使用明确文字角色，其他主题保留 on-surface 派生层级。
struct NoteReviewCardAppearance {
    /// 用于颜色模式卡片与图片加载失败的纯色表面。
    let surface: Color
    /// 与 SwiftUI 纸面完全一致的动态 UIKit 表面色，供远景分块避免远近切换色差。
    let uiSurface: UIColor
    /// 用于图片模式加载成功时覆盖卡片的远程背景地址。
    let backgroundImageURL: String?
    /// 卡片的基础 on-surface 前景色；仅图片模式会应用已存储的自定义文字色。
    let onSurface: Color
    /// 想法区域使用的动态中性托底色，纯色模式建立克制明度差、图片模式增强文字方向的对比。
    let ideaBackgroundColor: Color
    /// UIKit 富文本所需的动态 on-surface 前景色。
    let uiOnSurface: UIColor

    let usesNeutralDarkAppearance: Bool

    /// 保留浅色及自定义主题的原有颜色；中性深色角色随高对比度动态解析。
    func neutralDarkColor(_ neutral: UIColor, fallback: UIColor) -> UIColor {
        let usesNeutral = usesNeutralDarkAppearance
        return UIColor { traits in
            (usesNeutral && traits.userInterfaceStyle == .dark ? neutral : fallback).resolvedColor(with: traits)
        }
    }

    /// 正文在中性深色中使用完整柔白，其他外观沿用原透明度。
    var bodyTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textPrimary), fallback: uiOnSurface.withOpacity(0.92))
    }

    /// 辅助富文本使用的 76% on-surface UIKit 颜色。
    var supplementTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textSecondary), fallback: uiOnSurface.withOpacity(0.76))
    }

    /// SwiftUI 辅助文字使用的 76% on-surface 颜色。
    var secondaryTextColor: Color {
        Color.xmResolved(metadataTextColor)
    }

    /// 页脚标题等主要 SwiftUI 文字使用的 92% on-surface 颜色。
    var bodyForegroundColor: Color {
        Color.xmResolved(bodyTextColor)
    }

    /// 出处低于正文；非中性外观保留已有页脚标题亮度。
    var sourceTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textSecondary), fallback: uiOnSurface.withOpacity(0.92))
    }

    /// 作者和章节属于较弱元数据，不能比出处更亮。
    var metadataTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textHint), fallback: uiOnSurface.withOpacity(0.76))
    }

    /// 总览原有完整 on-surface 前景仅在中性深色中归一到正文角色。
    var canvasBodyTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textPrimary), fallback: uiOnSurface)
    }

    /// 总览保留彩色主题原有辅助透明度。
    var canvasSecondaryTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textSecondary), fallback: uiOnSurface.withOpacity(0.72))
    }

    /// 总览书名在中性深色中使用出处色，其余主题保留原前景。
    var canvasSourceTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textSecondary), fallback: uiOnSurface)
    }

    /// 总览章节与作者使用元数据色，其他主题维持原辅助前景。
    var canvasMetadataTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textHint), fallback: uiOnSurface.withOpacity(0.72))
    }

    var sourceForegroundColor: Color { Color.xmResolved(sourceTextColor) }
    var immersiveBodyTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textPrimary), fallback: .label)
    }
    var immersiveSupplementTextColor: UIColor {
        neutralDarkColor(UIColor.xmResolved(Color.textSecondary), fallback: .secondaryLabel)
    }
    var immersiveSourceColor: Color {
        Color.xmResolved(neutralDarkColor(UIColor.xmResolved(Color.textSecondary), fallback: UIColor.xmResolved(Color.textPrimary)))
    }
    var immersiveChapterColor: Color {
        Color.xmResolved(neutralDarkColor(UIColor.xmResolved(Color.textHint), fallback: UIColor.xmResolved(Color.textSecondary)))
    }

    /// 卡片边框在中性深色中使用中性边界，其余主题沿用原派生色。
    var borderColor: Color {
        Color.xmResolved(neutralDarkColor(UIColor.xmResolved(Color.surfaceBorderDefault), fallback: uiOnSurface.withOpacity(0.16)))
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
        var darkSurfaceHex = UInt(cardSurfaceHex(isDarkAppearance: true))
        let lightTextHex = UInt(cardTextHex(isDarkAppearance: false))
        var darkTextHex = UInt(cardTextHex(isDarkAppearance: true))
        if !usesNeutralDarkAppearance {
            let legacySurface: UInt?
            let legacyText: UInt?
            switch palette.canonicalPalette {
            case .paper: legacySurface = 0x202723; legacyText = 0xE6ECE7
            case .dark: legacySurface = 0x1D2420; legacyText = 0xEAF0EB
            default: legacySurface = nil; legacyText = nil
            }
            if backgroundMode == .image, let legacySurface { darkSurfaceHex = legacySurface }
            if (backgroundMode == .color || customTextColorHex == nil), let legacyText { darkTextHex = legacyText }
        }
        let uiSurface = UIColor.xmAdaptive(lightHex: lightSurfaceHex, darkHex: darkSurfaceHex)
        let uiOnSurface = UIColor.xmAdaptive(lightHex: lightTextHex, darkHex: darkTextHex)
        let uiIdeaBackground = NoteReviewIdeaSurfaceStyle.backgroundColor(
            mode: backgroundMode,
            lightSurfaceHex: lightSurfaceHex,
            darkSurfaceHex: darkSurfaceHex,
            lightTextHex: lightTextHex,
            darkTextHex: darkTextHex
        )

        return NoteReviewCardAppearance(
            surface: Color.xmResolved(uiSurface),
            uiSurface: uiSurface,
            backgroundImageURL: imageURL,
            onSurface: Color.xmResolved(uiOnSurface),
            ideaBackgroundColor: Color.xmResolved(uiIdeaBackground),
            uiOnSurface: uiOnSurface,
            usesNeutralDarkAppearance: usesNeutralDarkAppearance
        )
    }

    /// 仅标准中性纯色主题参与角色统一，保留自定义背景和主动选择的彩色主题。
    var usesNeutralDarkAppearance: Bool {
        backgroundMode == .color
            && customBackgroundStartHex == nil && customBackgroundEndHex == nil
            && (palette.canonicalPalette == .paper || palette.canonicalPalette == .dark)
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

/// 回顾内置字体的资源身份与失败诊断 owner，避免把展示名称误当成 PostScript 注册名。
private enum NoteReviewBundledFont {
    static let sourceHanSerifPostScriptName = "SourceHanSerifSC-SemiBold"

    #if DEBUG
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "NoteReviewFont"
    )
    #endif

    /// 按基础字号解析已由 UIAppFonts 注册的思源宋体；资源异常时保持可读并在 Debug 日志中暴露失败。
    static func sourceHanSerif(base: UIFont) -> UIFont {
        guard let font = UIFont(name: sourceHanSerifPostScriptName, size: base.pointSize) else {
            #if DEBUG
            logger.error(
                "[note-review.font.resolve] status=missing postscript=\(sourceHanSerifPostScriptName, privacy: .public)"
            )
            #endif
            return base
        }
        return font
    }
}

/// 将领域字体选择转换为 RichText 所需的 UIKit 字体；字体资源不可用时安全回退到当前语义字体。
extension NoteReviewFontSelection {
    /// 按当前字体选择生成与基础字号一致的 UIKit 字体。
    func uiFont(base: UIFont) -> UIFont {
        switch self {
        case .system:
            return base
        case .sourceHanSerif:
            return NoteReviewBundledFont.sourceHanSerif(base: base)
        case .local(_, let displayName):
            return UIFont(name: displayName, size: base.pointSize)
                ?? NoteReviewBundledFont.sourceHanSerif(base: base)
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
