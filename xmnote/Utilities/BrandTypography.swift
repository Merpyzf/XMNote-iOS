/**
 * [INPUT]: 依赖 SwiftUI/UIKit 字体系统与项目内注册字体资源（RozhaOne-Regular.ttf）
 * [OUTPUT]: 对外提供 BrandTypography 与 Font/UIFont 品牌字体扩展，统一品牌字体调用入口
 * [POS]: Utilities 模块的品牌字体门面，负责品牌展示字体的注册名与回退策略
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit
import CoreText
import os

/// 品牌字体入口，集中维护字体注册名与回退策略。
enum BrandTypography {
    /// 品牌字体 PostScript 名称，对应 RozhaOne-Regular.ttf。
    static let rozhaPostScriptName = "RozhaOne-Regular"
    private static let fontFileName = "RozhaOne-Regular"
    private static let fontFileExtension = "ttf"
    private static var didAttemptRuntimeRegistration = false
    #if DEBUG
    private static var didLogAvailability = false
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "BrandFont"
    )
    #endif

    /// 判断品牌字体是否已在运行时注册成功。
    static func isBrandFontAvailable() -> Bool {
        if UIFont(name: rozhaPostScriptName, size: 12) != nil {
            debugLogAvailabilityIfNeeded(available: true, source: "precheck")
            return true
        }
        registerBundledFontIfNeeded()
        let available = UIFont(name: rozhaPostScriptName, size: 12) != nil
        debugLogAvailabilityIfNeeded(available: available, source: "post-register")
        return available
    }

    /// 运行时注册 Bundle 内字体，兜底生成式 Info.plist 未注入 UIAppFonts 的场景。
    static func registerBundledFontIfNeeded() {
        guard !didAttemptRuntimeRegistration else { return }
        didAttemptRuntimeRegistration = true
        guard let fontURL = Bundle.main.url(forResource: fontFileName, withExtension: fontFileExtension) else {
            #if DEBUG
            logger.error("[brand.font.register] status=missing-file file=\(fontFileName).\(fontFileExtension)")
            #endif
            return
        }
        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
        #if DEBUG
        if success {
            logger.notice("[brand.font.register] status=success file=\(fontURL.lastPathComponent)")
        } else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            logger.error("[brand.font.register] status=failed file=\(fontURL.lastPathComponent) error=\(message)")
        }
        #endif
    }

    #if DEBUG
    /// 记录 App 启动阶段是否触发品牌字体注册。
    static func debugLogAppInitRegistrationTriggered() {
        logger.notice("[brand.font.app.init] registerBundledFontIfNeeded invoked")
    }

    /// 打印 TopSwitcher 标题位品牌字体解析信息，辅助定位“未生效”问题。
    static func debugLogTopSwitcherTitle(_ text: String, size: CGFloat) {
        let available = isBrandFontAvailable()
        let containsCJK = text.containsCJK
        let resolvedFontName = UIFont(name: rozhaPostScriptName, size: size)?.fontName ?? "nil"
        logger.notice(
            "[brand.font.topSwitcher] text=\(text) size=\(Int(size)) available=\(available) containsCJK=\(containsCJK) resolvedFont=\(resolvedFontName)"
        )
        if containsCJK {
            logger.notice("[brand.font.topSwitcher] note=CJK text may fallback per glyph even when brand font is available")
        }
    }

    /// 标记 TopSwitcher 当前使用的模式，确保 tabs/title 路径都可观测。
    static func debugLogTopSwitcherMode(_ mode: String, tabsCount: Int, title: String?) {
        let safeTitle = title ?? "-"
        logger.notice("[top.switcher.mode] mode=\(mode) tabsCount=\(tabsCount) title=\(safeTitle)")
    }

    /// 标记 tabs 模式下引号装饰策略，避免误判为字体回退问题。
    static func debugLogTopSwitcherTabsUsesQuoteIcon(_ tabsCount: Int) {
        logger.notice("[top.switcher.tabs] tabsCount=\(tabsCount) quoteDecoration=icon asset=TopSwitcherQuote")
    }

    private static func debugLogAvailabilityIfNeeded(available: Bool, source: String) {
        guard !didLogAvailability else { return }
        didLogAvailability = true
        let resolved = UIFont(name: rozhaPostScriptName, size: 12)?.fontName ?? "nil"
        logger.notice("[brand.font.availability] available=\(available) source=\(source) postscript=\(rozhaPostScriptName) resolved=\(resolved)")
    }
    #endif
}

private extension String {
    /// 判断字符串是否包含中日韩字符，用于提示字体可能发生按字形回退。
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,   // CJK Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0x3040...0x30FF,   // Hiragana + Katakana
                 0xAC00...0xD7AF:   // Hangul Syllables
                return true
            default:
                return false
            }
        }
    }
}

extension Font {
    /// 返回品牌展示字体，缺失时回退到系统半粗体并保持 Dynamic Type 缩放。
    static func brandDisplay(size: CGFloat, relativeTo textStyle: Font.TextStyle = .title2) -> Font {
        if BrandTypography.isBrandFontAvailable() {
            return .custom(BrandTypography.rozhaPostScriptName, size: size, relativeTo: textStyle)
        }
        return .system(textStyle, design: .default, weight: .semibold)
    }
}

extension UIFont {
    /// 返回 UIKit 品牌展示字体，默认按 textStyle 做指标缩放。
    static func brandDisplay(size: CGFloat, textStyle: UIFont.TextStyle = .title2) -> UIFont {
        let fallback = UIFont.systemFont(ofSize: size, weight: .semibold)
        let base = UIFont(name: BrandTypography.rozhaPostScriptName, size: size) ?? fallback
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }
}
