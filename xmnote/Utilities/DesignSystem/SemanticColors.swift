/**
 * [INPUT]: 依赖 SwiftUI 与 UIKit 的系统动态颜色能力，以及集中式 Color 构造器
 * [OUTPUT]: 对外提供 XMNote 全局语义颜色与阅读日历颜色角色
 * [POS]: Utilities/DesignSystem 的颜色语义层，只表达用途，不承载页面布局
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 阅读日历月总结图标的渐变角色枚举，不同角色对应不同色相方案。
enum ReadCalendarSummaryGradientRole: Hashable {
    case activity
    case completion
    case momentum
    case trend
}

/// 三段式渐变配置，供月总结图标统一渲染。
struct ReadCalendarSummaryGradientSpec {
    let start: Color
    let mid: Color
    let end: Color
}

// MARK: - Brand

extension Color {
    /// 品牌主色 #2ECF77
    static let brand = Color.xmAdaptive(light: Color.xmHex(0x2ECF77),
                             dark: Color.xmHex(0x2ECF77))
    /// 品牌浅绿（进度条背景、热力图低级）
    static let brandLight = Color.xmHex(0xACEEBB)
    /// 品牌深绿（热力图中级、强调）
    static let brandDeep = Color.xmHex(0x2DA44F)
    /// 品牌最深绿（热力图高级）
    static let brandDarkest = Color.xmHex(0x11632A)
    /// 热力图无活动底色
    static let heatmapNone = Color.xmAdaptive(light: Color.xmHex(0xEFF0F4),
                                    dark: Color.xmHex(0x2A2A2C))
}

// MARK: - Background

extension Color {
    /// 页面级 grouped 背景，承接 Tab 根页、分组列表与卡片流页面的底板层。
    static let surfacePage = Color.xmResolved(.systemGroupedBackground)
    /// 默认内容卡片背景，承接页面底板上的主要内容容器。
    static let surfaceCard = Color.xmResolved(.secondarySystemGroupedBackground)
    /// 嵌套在主卡片上的次级表层，承接 Sheet 内局部模块或多层卡片结构。
    static let surfaceNested = Color.xmResolved(.tertiarySystemGroupedBackground)
    /// 标签背景色
    static let tagBackground = Color.xmAdaptive(light: Color.xmHex(0xE8F0EC),
                                      dark: Color.xmHex(0x343536))
    /// 书籍空封面背景色，统一承接无图与加载失败回退态。
    static let bookCoverPlaceholderBackground = Color.xmAdaptive(light: Color.xmHex(0xEEEEEE),
                                                      dark: Color.xmHex(0x333333))
    /// Sheet 根背景，和页面底板保持同一 grouped 语义。
    static let surfaceSheet = Color.xmResolved(.systemGroupedBackground)
    /// 次级弱填充，承接圆形选项、轻量按钮与弱控件底。
    static let controlFillSecondary = Color.xmResolved(.tertiarySystemFill)
    /// 批注与个人想法的弱中性表层，在内容卡片内建立分组但不抢占正文层级。
    static let surfaceAnnotation = controlFillSecondary.opacity(0.46)
}

// MARK: - Text

extension Color {
    /// 主要文本
    static let textPrimary = Color.xmAdaptive(light: Color.xmHex(0x333333),
                                    dark: Color.xmHex(0xC6C8CB))
    /// 次要文本
    static let textSecondary = Color.xmAdaptive(light: Color.xmHex(0x666666),
                                      dark: Color.xmHex(0x8C929B))
    /// 提示文本
    static let textHint = Color.xmAdaptive(light: Color.xmHex(0x999999),
                                 dark: Color.xmHex(0x999999))
    /// 搜索关键词命中色，沿用品牌绿的色相与饱和度，并按表面亮度保证正文级可读性。
    static let keywordHighlight = Color.xmAdaptive(light: Color.xmHex(0x1C7C47),
                                        dark: Color.xmHex(0x2ECF77))
}

// MARK: - Icon

extension Color {
    /// 主要图标
    static let iconPrimary = Color.xmAdaptive(light: Color.xmHex(0x000000),
                                    dark: Color.xmHex(0xEEEEEE))
    /// 次要图标（= textSecondary）
    static let iconSecondary = Color.xmAdaptive(light: Color.xmHex(0x666666),
                                      dark: Color.xmHex(0x8C929B))
    /// 图标容器背景，承接未选中图标按钮与弱强调控件。
    static let iconBgShape = controlFillSecondary
    /// 普通菜单项前景，隔离根级品牌 tint，承接非危险、非主操作菜单项。
    static let menuActionForeground = iconPrimary
    /// 选中菜单项前景：保留业务图标并在尾部 checkmark 标注状态，颜色保持中性避免抢占品牌主语义。
    static let menuSelectedForeground = iconPrimary
}

// MARK: - Border & Divider

extension Color {
    /// 一级容器边框（页面主卡/分组壳层）
    static let surfaceBorderStrong = Color.xmResolved(.opaqueSeparator)
    /// 二级内容边框（指标卡/列表卡）
    static let surfaceBorderDefault = Color.xmResolved(.separator)
    /// 三级弱边框（弱化层级、避免与主信息竞争）
    static let surfaceBorderSubtle = Color.xmResolved(.separator).opacity(0.72)
    /// 卡片内部弱分隔线，仅表达内容分组，不与卡片边框竞争。
    static let surfaceDividerSubtle = Color.xmResolved(.separator).opacity(0.28)
    /// 图表背景轨道色（柱图零值占位 / 背景 bar），避免与容器边框争抢视觉语义。
    static let chartBarTrack = Color.xmAdaptive(light: Color.xmHex(0xC7CCD3).opacity(0.22),
                                     dark: Color.white.opacity(0.06))
    /// 书籍封面左侧厚度边的暗面，用于弱化但持续存在的体积感。
    static let bookCoverSpineDark = Color.xmAdaptive(
        light: Color.black.opacity(0.18),
        dark: Color.black.opacity(0.32)
    )
    /// 书籍封面左侧厚度边的亮面，用于让边缘不至于读成纯黑竖条。
    static let bookCoverSpineLight = Color.xmAdaptive(
        light: Color.white.opacity(0.22),
        dark: Color.white.opacity(0.10)
    )
    /// 书籍封面厚度边与正面的过渡阴影，用于形成短距离的边缘深度。
    static let bookCoverFoldShadow = Color.xmAdaptive(
        light: Color.black.opacity(0.10),
        dark: Color.black.opacity(0.18)
    )
    /// 书籍封面外部轻阴影，用于模拟 Apple Books 式的轻量陈列悬浮感。
    static let bookCoverDropShadow = Color.xmAdaptive(
        light: Color.black.opacity(0.14),
        dark: Color.black.opacity(0.22)
    )
    /// 书籍封面进度条轨道色，维持玻璃底上的弱对比白轨道。
    static let bookCoverProgressTrack = Color.white.opacity(0.20)
    /// 书籍封面进度条完成段颜色，保证玻璃层上的完成态比轨道更清晰。
    static let bookCoverProgressFill = Color.white.opacity(0.84)
    /// 书籍封面进度条描边，轻微勾出悬浮边界，避免深色封面上融掉。
    static let bookCoverProgressStroke = Color.white.opacity(0.22)
    /// 分割线
    static let divider = Color.xmAdaptive(light: Color.xmHex(0xEEEEEE),
                                dark: Color.xmHex(0x333333))
}

// MARK: - Button & Overlay

extension Color {
    /// 承载白色文案的主提交表面；直接跟随品牌主题色，避免局部主操作出现独立色阶。
    static let primaryActionFill = Color.brand
    /// 主提交表面的内容色，与 primaryActionFill 成对使用。
    static let primaryActionForeground = Color.white
    /// 主按钮禁用态背景，复用系统中性弱填充，不混入品牌色或状态色。
    static let buttonDisabled = Color.controlFillSecondary
    /// 主按钮禁用态内容色，复用中性提示文字并保持弱于可用状态。
    static let buttonDisabledForeground = Color.textHint
    /// 遮罩层
    static let overlay = Color.xmAdaptive(light: Color.black.opacity(0.4),
                                dark: Color.black.opacity(0.5))
    /// 书籍封面毛玻璃角标的清洁白雾层，降低复杂封面采样带来的杂色。
    static let bookCoverBadgeBlurWash = Color.white.opacity(0.02)
    /// 书籍封面深色毛玻璃角标覆盖层，保证白字在浅色封面上不发虚。
    static let bookCoverBadgeDarkOverlay = Color.black.opacity(0.22)
    /// 书籍封面毛玻璃角标内侧轻边界，帮助浅色封面上识别角标边缘。
    static let bookCoverBadgeInnerStroke = Color.white.opacity(0.08)
    /// 书籍封面角标文字与图标阴影，低强度兜底白色内容可读性。
    static let bookCoverBadgeContentShadow = Color.black.opacity(0.26)
}

// MARK: - Selection

extension Color {
    /// 选择控件激活色；直接跟随品牌主题色，保持跨页面选择反馈一致。
    static let selectionAccent = Color.brand
    /// 选择控件未激活描边；独立于提示文本，在深色模式下降低重复圆环的视觉竞争。
    static let selectionInactive = Color.xmAdaptive(light: Color.xmHex(0xA1A5A3),
                                         dark: Color.xmHex(0x696D6B))
}

// MARK: - Status

extension Color {
    static let statusReading = Color.xmHex(0x42A5F5)
    static let statusDone = Color.xmHex(0xFFB600)
    static let statusWish = Color.xmHex(0xEF5350)
    static let statusOnHold = Color.xmHex(0xAB47BC)
    static let statusAbandoned = Color.xmHex(0x9E9E9E)
}

// MARK: - Rating

extension Color {
    /// 评分星级激活色，对齐 Android FluentRatingBar 的 activeColor。
    static let ratingActive = Color.xmHex(0xFFC500)
    /// 评分星级未激活色，浅色对齐 Android，深色降低亮度避免抢占内容层级。
    static let ratingInactive = Color.xmAdaptive(
        light: Color.xmHex(0xDFE8F1),
        dark: Color.xmHex(0xDFE8F1, alpha: 0.34)
    )
}

// MARK: - Feedback

extension Color {
    /// 错误/删除
    static let feedbackError = Color.xmHex(0xEF5350)
    /// 警告
    static let feedbackWarning = Color.xmHex(0xFF9800)
    /// 成功（复用品牌色）
    static let feedbackSuccess = brand
}

// MARK: - Reading Calendar Theme

extension Color {
    /// 阅读日历顶部动作图标（返回/设置/总结入口）
    static let readCalendarTopAction = Color.xmAdaptive(
        light: Color.xmHex(0x111111),
        dark: Color.xmHex(0xF2F2F7)
    )

    /// 阅读日历次级文本
    static let readCalendarSubtleText = Color.xmAdaptive(
        light: Color.xmHex(0x647388),
        dark: Color.xmHex(0xA6B3C2)
    )

    /// 阅读日历统计中的正向变化，只用于变化数字，不用于标签和单位。
    static let readCalendarSummaryDeltaUp = Color.xmHex(0x4CAF50, alpha: 0.86)

    /// 阅读日历统计中的负向变化，使用低刺激橙色避免和破坏性操作混淆。
    static let readCalendarSummaryDeltaDown = Color.xmAdaptive(
        light: Color.xmHex(0xD4821B, alpha: 0.92),
        dark: Color.xmHex(0xDE8E28, alpha: 0.92)
    )

    /// 阅读日历统计中的持平变化，维持次级信息层级。
    static let readCalendarSummaryDeltaFlat = Color.textSecondary.opacity(0.72)

    /// 阅读时长累计数字的强调色，区别于趋势和可交互品牌色。
    static let readCalendarSummaryDurationAccent = Color.xmAdaptive(
        light: Color.xmHex(0xB96040, alpha: 0.96),
        dark: Color.xmHex(0xE79A7C, alpha: 0.96)
    )

    /// 阅读日历选中日背景
    static let readCalendarSelectionFill = Color.xmAdaptive(
        light: Color.xmHex(0xE7EDF7),
        dark: Color.xmHex(0x2B3645)
    )

    /// 阅读日历选中日描边
    static let readCalendarSelectionStroke = Color.xmAdaptive(
        light: Color.xmHex(0xBCCBDF),
        dark: Color.xmHex(0x4C617A)
    )

    /// 阅读日历日期选中态背景，以品牌色透明状态层适配所在表面，避免预混灰绿产生脏色块。
    static let readCalendarSelectedDayFill = Color.xmAdaptive(
        light: Color.brand.opacity(0.18),
        dark: Color.brand.opacity(0.24)
    )

    /// 阅读日历日期选中态数字色，复用品牌深浅语义以避免纯黑并保证双主题对比度。
    static let readCalendarSelectedDayText = Color.xmAdaptive(
        light: Color.brandDarkest,
        dark: Color.brand
    )

    /// 阅读日历“今天”标记色
    static let readCalendarTodayMark = Color.xmAdaptive(
        light: Color.xmHex(0x4FAF82),
        dark: Color.xmHex(0x77D6A9)
    )

    /// 阅读日历年度热力图空白层级（与 Android 日历语义色一致）。
    static let readCalendarHeatmapNone = Color.xmAdaptive(
        light: Color.xmHex(0xEFF0F4),
        dark: Color.xmHex(0x1B1D1B)
    )

    /// 阅读日历年度热力图一级强度。
    static let readCalendarHeatmapVeryLess = Color.xmAdaptive(
        light: Color.xmHex(0x9BE9A8),
        dark: Color.xmHex(0x1F5E39)
    )

    /// 阅读日历年度热力图二级强度。
    static let readCalendarHeatmapLess = Color.xmAdaptive(
        light: Color.xmHex(0x41C462),
        dark: Color.xmHex(0x2D8A4E)
    )

    /// 阅读日历年度热力图三级强度。
    static let readCalendarHeatmapMore = Color.xmAdaptive(
        light: Color.xmHex(0x2FA04F),
        dark: Color.xmHex(0x3DBB68)
    )

    /// 阅读日历年度热力图四级强度。
    static let readCalendarHeatmapVeryMore = Color.xmAdaptive(
        light: Color.xmHex(0x226E39),
        dark: Color.xmHex(0x7AE08F)
    )

    /// 阅读日历事件条文本色
    static let readCalendarEventText = Color.xmAdaptive(
        light: Color.xmHex(0x2F3945),
        dark: Color.xmHex(0xE6EDF7)
    )

    /// 阅读日历事件条取色中的骨架底色
    static let readCalendarEventPendingBase = Color.xmAdaptive(
        light: Color.xmHex(0xD6DEE8),
        dark: Color.xmHex(0x465566)
    )

    /// 阅读日历事件条取色中的骨架高光
    static let readCalendarEventPendingHighlight = Color.xmAdaptive(
        light: Color.xmHex(0xF2F6FB),
        dark: Color.xmHex(0x8CA0B7)
    )

    /// 阅读日历事件条取色中的文本色
    static let readCalendarEventPendingText = Color.xmAdaptive(
        light: Color.xmHex(0x5A6778),
        dark: Color.xmHex(0xD3DEEA)
    )

    /// 阅读日历低饱和事件色板
    static let readCalendarEventPalette: [Color] = [
        Color.xmAdaptive(light: Color.xmHex(0xB4C6D8), dark: Color.xmHex(0x5A7187)), // 雾蓝
        Color.xmAdaptive(light: Color.xmHex(0xA9B8C9), dark: Color.xmHex(0x53667B)), // 蓝灰
        Color.xmAdaptive(light: Color.xmHex(0xAFC2B8), dark: Color.xmHex(0x5B7268)), // 灰绿
        Color.xmAdaptive(light: Color.xmHex(0xB8B2C8), dark: Color.xmHex(0x665F7A)), // 灰紫
        Color.xmAdaptive(light: Color.xmHex(0x9EB1C4), dark: Color.xmHex(0x51667B)), // 岩青
        Color.xmAdaptive(light: Color.xmHex(0xB2C0CF), dark: Color.xmHex(0x5E7085)), // 青灰蓝
        Color.xmAdaptive(light: Color.xmHex(0xA7B9B2), dark: Color.xmHex(0x556B64)), // 鼠尾草灰
        Color.xmAdaptive(light: Color.xmHex(0xAEB8C2), dark: Color.xmHex(0x5C6774))  // 石墨蓝灰
    ]

    /// 阅读日历月总结图标渐变（统一亮度轨迹 + 按角色分色相）
    static func readCalendarSummaryGradientSpec(for role: ReadCalendarSummaryGradientRole) -> ReadCalendarSummaryGradientSpec {
        switch role {
        case .activity:
            return ReadCalendarSummaryGradientSpec(
                start: Color.xmAdaptive(light: Color.xmHex(0x4CC9B0), dark: Color.xmHex(0x6EDFC9)),
                mid: Color.xmAdaptive(light: Color.xmHex(0x27B89B), dark: Color.xmHex(0x48CDB1)),
                end: Color.xmAdaptive(light: Color.xmHex(0x14907D), dark: Color.xmHex(0x2EA792))
            )
        case .completion:
            return ReadCalendarSummaryGradientSpec(
                start: Color.xmAdaptive(light: Color.xmHex(0xF5BE61), dark: Color.xmHex(0xFFD28A)),
                mid: Color.xmAdaptive(light: Color.xmHex(0xECA145), dark: Color.xmHex(0xF1B960)),
                end: Color.xmAdaptive(light: Color.xmHex(0xD98323), dark: Color.xmHex(0xD6983E))
            )
        case .momentum:
            return ReadCalendarSummaryGradientSpec(
                start: Color.xmAdaptive(light: Color.xmHex(0xF18A5C), dark: Color.xmHex(0xFFAA80)),
                mid: Color.xmAdaptive(light: Color.xmHex(0xE36E44), dark: Color.xmHex(0xF28B63)),
                end: Color.xmAdaptive(light: Color.xmHex(0xCB4F2F), dark: Color.xmHex(0xD56B4A))
            )
        case .trend:
            return ReadCalendarSummaryGradientSpec(
                start: Color.xmAdaptive(light: Color.xmHex(0x74A7FF), dark: Color.xmHex(0x94BDFF)),
                mid: Color.xmAdaptive(light: Color.xmHex(0x558CE8), dark: Color.xmHex(0x76A5F4)),
                end: Color.xmAdaptive(light: Color.xmHex(0x376DCC), dark: Color.xmHex(0x5483DC))
            )
        }
    }

    /// 年度阅读分布的月份颜色，与 Android 统计树图保持同一语义色板。
    static func readCalendarMonthContributionColor(for month: Int) -> Color {
        guard let colorValue = readCalendarMonthContributionColorValue(for: month) else {
            return .textSecondary
        }
        return Color.xmHex(colorValue)
    }

    /// 年度阅读分布的月份渐变，亮暗轨迹与 Android 树图保持一致。
    static func readCalendarMonthContributionGradientSpec(for month: Int) -> ReadCalendarSummaryGradientSpec {
        guard let colorValue = readCalendarMonthContributionColorValue(for: month) else {
            return ReadCalendarSummaryGradientSpec(
                start: .textSecondary,
                mid: .textSecondary,
                end: .textSecondary
            )
        }
        return ReadCalendarSummaryGradientSpec(
            start: readCalendarMonthContributionMixedColor(
                colorValue,
                targetComponent: 1,
                fraction: 0.18
            ),
            mid: Color.xmHex(colorValue),
            end: readCalendarMonthContributionMixedColor(
                colorValue,
                targetComponent: 0,
                fraction: 0.16
            )
        )
    }

    /// 返回 Android 月份色板中的 RGB 值，供纯色与渐变共享同一颜色来源。
    private static func readCalendarMonthContributionColorValue(for month: Int) -> UInt? {
        let palette: [UInt] = [
            0xA85662, 0x8C79B8, 0x5FAEBA, 0x9DB1BB,
            0x6EA77B, 0xD8A8B0, 0xC86872, 0x91AD69,
            0x5F82BE, 0xC47A99, 0xC39A52, 0x62A6A3
        ]
        guard (1...palette.count).contains(month) else { return nil }
        return palette[month - 1]
    }

    /// 按 sRGB 分量线性插值月份基础色，复现 Android `lerp` 的亮部与暗部色阶。
    private static func readCalendarMonthContributionMixedColor(
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
