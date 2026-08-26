/**
 * [INPUT]: 依赖 SwiftUI 颜色、集中式构色能力与 HeatmapColorPalette 组件调色板
 * [OUTPUT]: 对外提供阅读日历专属颜色、热力色阶、总结渐变与月份贡献色映射
 * [POS]: Views/Reading/ReadCalendar 的 feature 展示 owner，阻止阅读日历主题泄漏到全局语义色层
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 集中持有阅读日历功能的主题角色，普通页面不应将这些颜色当作全局语义使用。
enum ReadCalendarTheme {
    /// 月总结图标渐变的业务角色。
    enum SummaryGradientRole: Hashable {
        case activity
        case completion
        case momentum
        case trend
    }

    /// 月总结图标与月份贡献图共享的三段式渐变配置。
    struct SummaryGradientSpec {
        let start: Color
        let mid: Color
        let end: Color
    }

    /// 顶部返回、设置与总结入口的图标色。
    static let topAction = Color.xmAdaptive(
        light: Color.xmHex(0x111111),
        dark: Color.xmHex(0xF2F2F7)
    )

    /// 星期、月份切换与顶部辅助信息的文字色。
    static let subtleText = Color.xmAdaptive(
        light: Color.xmHex(0x647388),
        dark: Color.xmHex(0xA6B3C2)
    )

    /// 统计中的正向变化色，仅用于变化数字。
    static let summaryDeltaUp = Color.xmHex(0x4CAF50, alpha: 0.86)

    /// 统计中的负向变化色，使用低刺激橙色与破坏性操作区分。
    static let summaryDeltaDown = Color.xmAdaptive(
        light: Color.xmHex(0xD4821B, alpha: 0.92),
        dark: Color.xmHex(0xDE8E28, alpha: 0.92)
    )

    /// 统计持平状态的次级文字色。
    static let summaryDeltaFlat = Color.textSecondary.opacity(0.72)

    /// 阅读时长累计数字的强调色。
    static let summaryDurationAccent = Color.xmAdaptive(
        light: Color.xmHex(0xB96040, alpha: 0.96),
        dark: Color.xmHex(0xE79A7C, alpha: 0.96)
    )

    /// 封面、错误提示与日历容器的选中背景。
    static let selectionFill = Color.xmAdaptive(
        light: Color.xmHex(0xE7EDF7),
        dark: Color.xmHex(0x2B3645)
    )

    /// 选中容器的配套描边。
    static let selectionStroke = Color.xmAdaptive(
        light: Color.xmHex(0xBCCBDF),
        dark: Color.xmHex(0x4C617A)
    )

    /// 月历日期选中态背景，保留原有双主题透明度。
    static let selectedDayFill = Color.xmAdaptive(
        light: Color.appTint.opacity(0.18),
        dark: Color.appTint.opacity(0.24)
    )

    /// 月历日期选中态数字色。
    static let selectedDayText = Color.xmAdaptive(
        light: Color.xmHex(0x11632A),
        dark: Color.appTint
    )

    /// 月历“今天”标记色。
    static let todayMark = Color.xmAdaptive(
        light: Color.xmHex(0x4FAF82),
        dark: Color.xmHex(0x77D6A9)
    )

    /// 阅读日历年度热力图的五级功能调色板。
    static let heatmapPalette = HeatmapColorPalette(
        none: Color.xmAdaptive(
            light: Color.xmHex(0xEFF0F4),
            dark: Color.xmHex(0x1B1D1B)
        ),
        veryLess: Color.xmAdaptive(
            light: Color.xmHex(0x9BE9A8),
            dark: Color.xmHex(0x1F5E39)
        ),
        less: Color.xmAdaptive(
            light: Color.xmHex(0x41C462),
            dark: Color.xmHex(0x2D8A4E)
        ),
        more: Color.xmAdaptive(
            light: Color.xmHex(0x2FA04F),
            dark: Color.xmHex(0x3DBB68)
        ),
        veryMore: Color.xmAdaptive(
            light: Color.xmHex(0x226E39),
            dark: Color.xmHex(0x7AE08F)
        )
    )

    /// 事件条颜色还在计算时的骨架底色。
    static let eventPendingBase = Color.xmAdaptive(
        light: Color.xmHex(0xD6DEE8),
        dark: Color.xmHex(0x465566)
    )

    /// 按月总结业务角色返回与旧版一致的三段式渐变。
    static func summaryGradientSpec(for role: SummaryGradientRole) -> SummaryGradientSpec {
        switch role {
        case .activity:
            return SummaryGradientSpec(
                start: Color.xmAdaptive(light: Color.xmHex(0x4CC9B0), dark: Color.xmHex(0x6EDFC9)),
                mid: Color.xmAdaptive(light: Color.xmHex(0x27B89B), dark: Color.xmHex(0x48CDB1)),
                end: Color.xmAdaptive(light: Color.xmHex(0x14907D), dark: Color.xmHex(0x2EA792))
            )
        case .completion:
            return SummaryGradientSpec(
                start: Color.xmAdaptive(light: Color.xmHex(0xF5BE61), dark: Color.xmHex(0xFFD28A)),
                mid: Color.xmAdaptive(light: Color.xmHex(0xECA145), dark: Color.xmHex(0xF1B960)),
                end: Color.xmAdaptive(light: Color.xmHex(0xD98323), dark: Color.xmHex(0xD6983E))
            )
        case .momentum:
            return SummaryGradientSpec(
                start: Color.xmAdaptive(light: Color.xmHex(0xF18A5C), dark: Color.xmHex(0xFFAA80)),
                mid: Color.xmAdaptive(light: Color.xmHex(0xE36E44), dark: Color.xmHex(0xF28B63)),
                end: Color.xmAdaptive(light: Color.xmHex(0xCB4F2F), dark: Color.xmHex(0xD56B4A))
            )
        case .trend:
            return SummaryGradientSpec(
                start: Color.xmAdaptive(light: Color.xmHex(0x74A7FF), dark: Color.xmHex(0x94BDFF)),
                mid: Color.xmAdaptive(light: Color.xmHex(0x558CE8), dark: Color.xmHex(0x76A5F4)),
                end: Color.xmAdaptive(light: Color.xmHex(0x376DCC), dark: Color.xmHex(0x5483DC))
            )
        }
    }

    /// 返回年度阅读分布中指定月份的三段式渐变。
    static func monthContributionGradientSpec(for month: Int) -> SummaryGradientSpec {
        guard let colorValue = monthContributionColorValue(for: month) else {
            return SummaryGradientSpec(
                start: .textSecondary,
                mid: .textSecondary,
                end: .textSecondary
            )
        }
        return SummaryGradientSpec(
            start: monthContributionMixedColor(
                colorValue,
                targetComponent: 1,
                fraction: 0.18
            ),
            mid: Color.xmHex(colorValue),
            end: monthContributionMixedColor(
                colorValue,
                targetComponent: 0,
                fraction: 0.16
            )
        )
    }

    /// 返回 Android 月份色板中的 RGB 值，供月份渐变共享同一颜色来源。
    private static func monthContributionColorValue(for month: Int) -> UInt? {
        let palette: [UInt] = [
            0xA85662, 0x8C79B8, 0x5FAEBA, 0x9DB1BB,
            0x6EA77B, 0xD8A8B0, 0xC86872, 0x91AD69,
            0x5F82BE, 0xC47A99, 0xC39A52, 0x62A6A3
        ]
        guard (1...palette.count).contains(month) else { return nil }
        return palette[month - 1]
    }

    /// 按 sRGB 分量线性插值月份基础色，复现 Android `lerp` 的亮部与暗部色阶。
    private static func monthContributionMixedColor(
        _ colorValue: UInt,
        targetComponent: Double,
        fraction: Double
    ) -> Color {
        let red = Double((colorValue >> 16) & 0xFF) / 255
        let green = Double((colorValue >> 8) & 0xFF) / 255
        let blue = Double(colorValue & 0xFF) / 255
        return Color.xmSRGB(
            red: red + (targetComponent - red) * fraction,
            green: green + (targetComponent - green) * fraction,
            blue: blue + (targetComponent - blue) * fraction,
            opacity: 1
        )
    }
}
