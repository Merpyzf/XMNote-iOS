/**
 * [INPUT]: 依赖 SwiftUI Color 与 DesignSystem 的跨外观颜色构造能力
 * [OUTPUT]: 对外提供 XMBookCover 组件家族的占位、厚度边、阴影、进度与角标外观
 * [POS]: UIComponents/Foundation 的书籍封面组件级 Appearance，避免封面细节泄漏为全局颜色语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 集中维护书籍封面组件家族的视觉细节；页面只在组合封面相关效果时读取对应角色。
enum XMBookCoverAppearance {
    /// 无图与加载失败时的封面底色。
    static let placeholderBackground = Color.xmAdaptive(
        light: Color.xmHex(0xEEEEEE),
        dark: Color.xmHex(0x333333)
    )

    /// 封面左侧厚度边的暗面。
    static let spineDark = Color.xmAdaptive(
        light: Color.black.opacity(0.18),
        dark: Color.black.opacity(0.32)
    )

    /// 封面左侧厚度边的亮面。
    static let spineLight = Color.xmAdaptive(
        light: Color.white.opacity(0.22),
        dark: Color.white.opacity(0.10)
    )

    /// 厚度边与封面正面之间的短距离过渡阴影。
    static let foldShadow = Color.xmAdaptive(
        light: Color.black.opacity(0.10),
        dark: Color.black.opacity(0.18)
    )

    /// 封面陈列与堆叠场景共用的外部轻阴影基色。
    static let dropShadow = Color.xmAdaptive(
        light: Color.black.opacity(0.14),
        dark: Color.black.opacity(0.22)
    )

    /// 封面底部进度条的内部外观。
    enum Progress {
        static let track = Color.white.opacity(0.20)
        static let fill = Color.white.opacity(0.84)
        static let stroke = Color.white.opacity(0.22)
    }

    /// 书架封面角标的玻璃覆盖与内容阴影。
    enum Badge {
        static let blurWash = Color.white.opacity(0.02)
        static let darkOverlay = Color.black.opacity(0.22)
        static let innerStroke = Color.white.opacity(0.08)
        static let contentShadow = Color.black.opacity(0.26)
    }
}
