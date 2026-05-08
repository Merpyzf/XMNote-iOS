//
//  DesignTokens.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//
//  [INPUT]: 无外部依赖，仅依赖 SwiftUI 框架
//  [OUTPUT]: Color 语义扩展（含阅读日历主题/事件条 pending 态/月总结图标渐变语义、Dialog 表层语义）、Spacing / CornerRadius / CardStyle 常量、Color(hex:) / Color(light:dark:) / Color(rgbaHex:) 构造器
//  [POS]: Utilities 模块的设计令牌中枢，全局 UI 一致性的单一真相源
//  [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

import SwiftUI
import UIKit

/// 阅读日历月总结图标的渐变角色枚举，不同角色对应不同色相方案。
enum ReadCalendarSummaryGradientRole {
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
    static let brand = Color(light: Color(hex: 0x2ECF77),
                             dark: Color(hex: 0x2ECF77))
    /// 品牌浅绿（进度条背景、热力图低级）
    static let brandLight = Color(hex: 0xACEEBB)
    /// 品牌深绿（热力图中级、强调）
    static let brandDeep = Color(hex: 0x2DA44F)
    /// 品牌最深绿（热力图高级）
    static let brandDarkest = Color(hex: 0x11632A)
    /// 热力图无活动底色
    static let heatmapNone = Color(light: Color(hex: 0xEFF0F4),
                                    dark: Color(hex: 0x2A2A2C))
}

// MARK: - Background

extension Color {
    /// 页面级 grouped 背景，承接 Tab 根页、分组列表与卡片流页面的底板层。
    static let surfacePage = Color(uiColor: .systemGroupedBackground)
    /// 默认内容卡片背景，承接页面底板上的主要内容容器。
    static let surfaceCard = Color(uiColor: .secondarySystemGroupedBackground)
    /// 嵌套在主卡片上的次级表层，承接 Sheet 内局部模块或多层卡片结构。
    static let surfaceNested = Color(uiColor: .tertiarySystemGroupedBackground)
    /// 标签背景色
    static let tagBackground = Color(light: Color(hex: 0xE8F0EC),
                                      dark: Color(hex: 0x343536))
    /// 书籍空封面背景色，统一承接无图与加载失败回退态。
    static let bookCoverPlaceholderBackground = Color(light: Color(hex: 0xEEEEEE),
                                                      dark: Color(hex: 0x333333))
    /// Sheet 根背景，和页面底板保持同一 grouped 语义。
    static let surfaceSheet = Color(uiColor: .systemGroupedBackground)
    /// 次级弱填充，承接圆形选项、轻量按钮与弱控件底。
    static let controlFillSecondary = Color(uiColor: .tertiarySystemFill)
}

// MARK: - Text

extension Color {
    /// 主要文本
    static let textPrimary = Color(light: Color(hex: 0x333333),
                                    dark: Color(hex: 0xC6C8CB))
    /// 次要文本
    static let textSecondary = Color(light: Color(hex: 0x666666),
                                      dark: Color(hex: 0x8C929B))
    /// 提示文本
    static let textHint = Color(light: Color(hex: 0x999999),
                                 dark: Color(hex: 0x999999))
    /// 搜索关键词命中色，对齐 Android 端 keywordHighlight 语义。
    static let keywordHighlight = Color(light: Color(hex: 0xEA4335),
                                        dark: Color(hex: 0xEA4335))
}

// MARK: - Icon

extension Color {
    /// 主要图标
    static let iconPrimary = Color(light: Color(hex: 0x000000),
                                    dark: Color(hex: 0xEEEEEE))
    /// 次要图标（= textSecondary）
    static let iconSecondary = Color(light: Color(hex: 0x666666),
                                      dark: Color(hex: 0x8C929B))
    /// 图标容器背景，承接未选中图标按钮与弱强调控件。
    static let iconBgShape = controlFillSecondary
}

// MARK: - Border & Divider

extension Color {
    /// 一级容器边框（页面主卡/分组壳层）
    static let surfaceBorderStrong = Color(uiColor: .opaqueSeparator)
    /// 二级内容边框（指标卡/列表卡）
    static let surfaceBorderDefault = Color(uiColor: .separator)
    /// 三级弱边框（弱化层级、避免与主信息竞争）
    static let surfaceBorderSubtle = Color(uiColor: .separator).opacity(0.72)
    /// 图表背景轨道色（柱图零值占位 / 背景 bar），避免与容器边框争抢视觉语义。
    static let chartBarTrack = Color(light: Color(hex: 0xC7CCD3).opacity(0.22),
                                     dark: Color.white.opacity(0.06))
    /// 书籍封面左侧厚度边的暗面，用于弱化但持续存在的体积感。
    static let bookCoverSpineDark = Color(
        light: Color.black.opacity(0.18),
        dark: Color.black.opacity(0.32)
    )
    /// 书籍封面左侧厚度边的亮面，用于让边缘不至于读成纯黑竖条。
    static let bookCoverSpineLight = Color(
        light: Color.white.opacity(0.22),
        dark: Color.white.opacity(0.10)
    )
    /// 书籍封面厚度边与正面的过渡阴影，用于形成短距离的边缘深度。
    static let bookCoverFoldShadow = Color(
        light: Color.black.opacity(0.10),
        dark: Color.black.opacity(0.18)
    )
    /// 书籍封面外部轻阴影，用于模拟 Apple Books 式的轻量陈列悬浮感。
    static let bookCoverDropShadow = Color(
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
    static let divider = Color(light: Color(hex: 0xEEEEEE),
                                dark: Color(hex: 0x333333))
}

// MARK: - Button & Overlay

extension Color {
    /// 主按钮禁用态
    static let buttonDisabled = Color(light: Color(hex: 0xA6D6B8),
                                       dark: Color(hex: 0x3A5C45))
    /// 遮罩层
    static let overlay = Color(light: Color.black.opacity(0.4),
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

// MARK: - Status

extension Color {
    static let statusReading = Color(hex: 0x42A5F5)
    static let statusDone = Color(hex: 0xFFB600)
    static let statusWish = Color(hex: 0xEF5350)
    static let statusOnHold = Color(hex: 0xAB47BC)
    static let statusAbandoned = Color(hex: 0x9E9E9E)
}

// MARK: - Feedback

extension Color {
    /// 错误/删除
    static let feedbackError = Color(hex: 0xEF5350)
    /// 警告
    static let feedbackWarning = Color(hex: 0xFF9800)
    /// 成功（复用品牌色）
    static let feedbackSuccess = brand
}

// MARK: - Reading Calendar Theme

extension Color {
    /// 阅读日历顶部动作图标（返回/设置/总结入口）
    static let readCalendarTopAction = Color(
        light: Color(hex: 0x111111),
        dark: Color(hex: 0xF2F2F7)
    )

    /// 阅读日历次级文本
    static let readCalendarSubtleText = Color(
        light: Color(hex: 0x647388),
        dark: Color(hex: 0xA6B3C2)
    )

    /// 阅读日历选中日背景
    static let readCalendarSelectionFill = Color(
        light: Color(hex: 0xE7EDF7),
        dark: Color(hex: 0x2B3645)
    )

    /// 阅读日历选中日描边
    static let readCalendarSelectionStroke = Color(
        light: Color(hex: 0xBCCBDF),
        dark: Color(hex: 0x4C617A)
    )

    /// 阅读日历“今天”标记色
    static let readCalendarTodayMark = Color(
        light: Color(hex: 0x4FAF82),
        dark: Color(hex: 0x77D6A9)
    )

    /// 阅读日历事件条文本色
    static let readCalendarEventText = Color(
        light: Color(hex: 0x2F3945),
        dark: Color(hex: 0xE6EDF7)
    )

    /// 阅读日历事件条取色中的骨架底色
    static let readCalendarEventPendingBase = Color(
        light: Color(hex: 0xD6DEE8),
        dark: Color(hex: 0x465566)
    )

    /// 阅读日历事件条取色中的骨架高光
    static let readCalendarEventPendingHighlight = Color(
        light: Color(hex: 0xF2F6FB),
        dark: Color(hex: 0x8CA0B7)
    )

    /// 阅读日历事件条取色中的文本色
    static let readCalendarEventPendingText = Color(
        light: Color(hex: 0x5A6778),
        dark: Color(hex: 0xD3DEEA)
    )

    /// 阅读日历低饱和事件色板
    static let readCalendarEventPalette: [Color] = [
        Color(light: Color(hex: 0xB4C6D8), dark: Color(hex: 0x5A7187)), // 雾蓝
        Color(light: Color(hex: 0xA9B8C9), dark: Color(hex: 0x53667B)), // 蓝灰
        Color(light: Color(hex: 0xAFC2B8), dark: Color(hex: 0x5B7268)), // 灰绿
        Color(light: Color(hex: 0xB8B2C8), dark: Color(hex: 0x665F7A)), // 灰紫
        Color(light: Color(hex: 0x9EB1C4), dark: Color(hex: 0x51667B)), // 岩青
        Color(light: Color(hex: 0xB2C0CF), dark: Color(hex: 0x5E7085)), // 青灰蓝
        Color(light: Color(hex: 0xA7B9B2), dark: Color(hex: 0x556B64)), // 鼠尾草灰
        Color(light: Color(hex: 0xAEB8C2), dark: Color(hex: 0x5C6774))  // 石墨蓝灰
    ]

    /// 阅读日历月总结图标渐变（统一亮度轨迹 + 按角色分色相）
    static func readCalendarSummaryGradientSpec(for role: ReadCalendarSummaryGradientRole) -> ReadCalendarSummaryGradientSpec {
        switch role {
        case .activity:
            return ReadCalendarSummaryGradientSpec(
                start: Color(light: Color(hex: 0x4CC9B0), dark: Color(hex: 0x6EDFC9)),
                mid: Color(light: Color(hex: 0x27B89B), dark: Color(hex: 0x48CDB1)),
                end: Color(light: Color(hex: 0x14907D), dark: Color(hex: 0x2EA792))
            )
        case .completion:
            return ReadCalendarSummaryGradientSpec(
                start: Color(light: Color(hex: 0xF5BE61), dark: Color(hex: 0xFFD28A)),
                mid: Color(light: Color(hex: 0xECA145), dark: Color(hex: 0xF1B960)),
                end: Color(light: Color(hex: 0xD98323), dark: Color(hex: 0xD6983E))
            )
        case .momentum:
            return ReadCalendarSummaryGradientSpec(
                start: Color(light: Color(hex: 0xF18A5C), dark: Color(hex: 0xFFAA80)),
                mid: Color(light: Color(hex: 0xE36E44), dark: Color(hex: 0xF28B63)),
                end: Color(light: Color(hex: 0xCB4F2F), dark: Color(hex: 0xD56B4A))
            )
        case .trend:
            return ReadCalendarSummaryGradientSpec(
                start: Color(light: Color(hex: 0x74A7FF), dark: Color(hex: 0x94BDFF)),
                mid: Color(light: Color(hex: 0x558CE8), dark: Color(hex: 0x76A5F4)),
                end: Color(light: Color(hex: 0x376DCC), dark: Color(hex: 0x5483DC))
            )
        }
    }
}

// MARK: - Spacing
//
// 选择指南（四步决策）：
//
// 第一步：先判断是不是“留白”问题
//   只有在表达元素之间的距离、容器与内容的边距、或视觉呼吸空间时，才使用 spacing token。
//   命中线宽、点击热区、组件尺寸约束时，不要把 spacing 当作通用尺寸常量。
//
// 第二步：判断层级
//   Inline    → 行内或紧密配对关系（图标与文字、主值与副标题、标签内边距）
//   Block     → 同级内容块之间的常规留白（按钮组、图表标题到图表、段落间距）
//   Container → 卡片或模块内部边距（内容到卡片边缘、局部分区）
//   Page      → 页面级边距与大分区留白
//
// 第三步：优先选择默认档
//   Inline    → half(6) / cozy(8)
//   Block     → cozy(8) / base(12)
//   Container → screenEdge(16) / contentEdge(18) / section(20)
//   Page      → screenEdge(16) / section(20) / double(24)
//
// 第四步：默认档不成立时，才使用补位档
//   微调档     → hairline(1) / tiny(2) / micro(3)，只用于视觉补偿、描边避让、极小留白
//   紧密补位档 → compact(4)，用于比 half 更紧的成组关系
//   中间补位档 → tight(10) / comfortable(14)，用于默认档之间的过渡密度
//   特殊约束   → actionReserved(44) 用于最小点击热区或操作预留，不属于常规 spacing
//
// 默认选择示例：
//   图标与短文本间距        → compact
//   主值与副标题            → half
//   图表标题到图表          → cozy
//   常规内容块间距          → base
//   页面横向安全边距        → screenEdge
//   普通卡片内容边距        → contentEdge
//   模块级强调分组          → section
//   大段留白/强分区         → double
//
// 反例：
//   不要用 actionReserved 表达普通 padding 或间距。
//   不要用 hairline / tiny / micro 充当卡片主边距。
//   不要默认从 tight / comfortable 开始试值，它们是补位档，不是首选档。

/// 全局间距设计令牌，统一页面留白层级、容器边距与紧密关系间距。
enum Spacing {
    static let none: CGFloat = 0
    static let hairline: CGFloat = 1
    static let tiny: CGFloat = 2
    static let micro: CGFloat = 3
    static let compact: CGFloat = 4
    static let half: CGFloat = 6
    static let cozy: CGFloat = 8
    static let tight: CGFloat = 10
    static let base: CGFloat = 12
    static let comfortable: CGFloat = 14
    static let section: CGFloat = 20
    static let double: CGFloat = 24
    static let actionReserved: CGFloat = 44
    static let screenEdge: CGFloat = 16
    static let contentEdge: CGFloat = 18
}

// MARK: - Corner Radius
//
// 选择指南（两步决策）：
//
// 第一步：判断元素角色
//   inlay     → 嵌在卡片/容器内的小型视觉零件（色块、封面、标签、徽章）
//   block     → 独立可识别的内容单元（事件条、列表项、标准卡片）
//   container → 承载内容块的外壳（面板、弹层、突出容器）
//
// 第二步：按视觉体量选尺寸
//   none(0) < hairline(2) < tiny(3) < small(4) < medium(6) < large(8~12) < xl(16) < xxl(18~22)
//
// 示例：
//   热力图方格 → 嵌在卡片里的小零件 → inlay → 最小的 → inlayTiny
//   书籍封面   → 嵌在网格里的小零件 → inlay → 稍大   → inlaySmall
//   事件条     → 独立内容单元       → block → 紧凑   → blockSmall
//   标准卡片   → 独立内容单元       → block → 标准   → blockLarge
//   日历面板   → 包裹内容的容器     → container → 标准 → containerMedium

/// 全局圆角设计令牌，按 inlay/block/container 三类角色复用。
enum CornerRadius {
    static let none: CGFloat = 0          // 关闭圆角（状态切换）

    // --- inlay: 嵌在卡片/容器内的小型视觉零件 ---
    static let inlayHairline: CGFloat = 2  // 装饰分隔条、极细引导条
    static let inlayTiny: CGFloat = 3      // 热力图方格、图例色块
    static let inlaySmall: CGFloat = 4     // 书籍封面缩略图
    static let inlayMedium: CGFloat = 6    // 标签、徽章

    // --- block: 独立可识别的内容单元 ---
    static let blockSmall: CGFloat = 8     // 事件条、紧凑卡片
    static let blockMedium: CGFloat = 10   // 列表项、输入框
    static let blockLarge: CGFloat = 12    // 标准卡片、内容区域

    // --- container: 承载内容块的外壳 ---
    static let containerMedium: CGFloat = 16  // 面板、弹层
    static let containerLarge: CGFloat = 18   // 突出容器（热力图 widget）
    static let containerXL: CGFloat = 22     // 闪屏图标容器、大型品牌展示
}

// MARK: - Card Style

/// 卡片样式基础常量，集中维护边框宽度等参数。
enum CardStyle {
    static let borderWidth: CGFloat = 0.5
}

// MARK: - Reading Calendar Typography

/// 全局文本语义入口，统一生产路径字体出口，并尽量保持当前默认视觉基线不变。
enum AppTypography {
    static let largeTitle: Font = .largeTitle
    static let title2: Font = .title2
    static let title3: Font = .title3
    static let title3Semibold: Font = .title3.weight(.semibold)
    static let headline: Font = .headline
    static let headlineSemibold: Font = .headline.weight(.semibold)
    static let subheadline: Font = .subheadline
    static let subheadlineMedium: Font = .subheadline.weight(.medium)
    static let subheadlineSemibold: Font = .subheadline.weight(.semibold)
    static let body: Font = .body
    static let bodyMedium: Font = .body.weight(.medium)
    static let callout: Font = .callout
    static let footnote: Font = .footnote
    static let footnoteSemibold: Font = .footnote.weight(.semibold)
    static let caption: Font = .caption
    static let captionMedium: Font = .caption.weight(.medium)
    static let captionSemibold: Font = .caption.weight(.semibold)
    static let caption2: Font = .caption2
    static let caption2Medium: Font = .caption2.weight(.medium)
    static let caption2Semibold: Font = .caption2.weight(.semibold)

    static func semantic(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        fixed(
            baseSize: SemanticTypography.defaultPointSize(for: style.uiFontTextStyle),
            relativeTo: style,
            weight: weight,
            design: design,
            minimumPointSize: SemanticTypography.defaultPointSize(for: style.uiFontTextStyle)
        )
    }

    static func semanticFont(
        _ style: UIFont.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        fixed(
            baseSize: SemanticTypography.defaultPointSize(for: style),
            relativeTo: style.fontTextStyle,
            weight: weight,
            design: design,
            minimumPointSize: SemanticTypography.defaultPointSize(for: style)
        )
    }

    static func fixed(
        baseSize: CGFloat,
        relativeTo style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        minimumPointSize: CGFloat? = nil
    ) -> Font {
        SemanticTypography.font(
            baseSize: baseSize,
            relativeTo: style,
            weight: weight,
            design: design,
            minimumPointSize: minimumPointSize ?? baseSize
        )
    }

    static func uiSemantic(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        design: UIFontDescriptor.SystemDesign = .default
    ) -> UIFont {
        let baseSize = SemanticTypography.defaultPointSize(for: style)
        return SemanticTypography.uiFont(
            baseSize: baseSize,
            textStyle: style,
            weight: weight,
            design: design,
            minimumPointSize: baseSize
        )
    }

    static func uiFixed(
        baseSize: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        design: UIFontDescriptor.SystemDesign = .default,
        minimumPointSize: CGFloat? = nil
    ) -> UIFont {
        SemanticTypography.uiFont(
            baseSize: baseSize,
            textStyle: textStyle,
            weight: weight,
            design: design,
            minimumPointSize: minimumPointSize ?? baseSize
        )
    }

    static func brandDisplay(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle = .title2
    ) -> Font {
        .brandDisplay(size: size, relativeTo: textStyle)
    }

    static func brandTrim(
        size: CGFloat,
        textStyle: UIFont.TextStyle = .title2
    ) -> BrandTypography.VerticalTrim {
        BrandTypography.verticalTrim(size: size, textStyle: textStyle)
    }

    static func topSwitcherTitleFont(
        for text: String,
        size: CGFloat
    ) -> Font {
        if text.xmContainsCJK {
            return fixed(
                baseSize: size,
                relativeTo: .headline,
                weight: .semibold,
                minimumPointSize: size
            )
        }
        return brandDisplay(size: size, relativeTo: .headline)
    }

    static func topSwitcherTitleTrim(
        for text: String,
        size: CGFloat
    ) -> BrandTypography.VerticalTrim {
        guard !text.xmContainsCJK else { return .zero }
        return brandTrim(size: size, textStyle: .headline)
    }
}

private extension Font.TextStyle {
    var uiFontTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle:
            return .largeTitle
        case .title:
            return .title1
        case .title2:
            return .title2
        case .title3:
            return .title3
        case .headline:
            return .headline
        case .subheadline:
            return .subheadline
        case .body:
            return .body
        case .callout:
            return .callout
        case .footnote:
            return .footnote
        case .caption:
            return .caption1
        case .caption2:
            return .caption2
        @unknown default:
            return .body
        }
    }
}

private extension UIFont.TextStyle {
    var fontTextStyle: Font.TextStyle {
        switch self {
        case .largeTitle:
            return .largeTitle
        case .title1:
            return .title
        case .title2:
            return .title2
        case .title3:
            return .title3
        case .headline:
            return .headline
        case .subheadline:
            return .subheadline
        case .body:
            return .body
        case .callout:
            return .callout
        case .footnote:
            return .footnote
        case .caption1:
            return .caption
        case .caption2:
            return .caption2
        default:
            return .body
        }
    }
}

private extension String {
    var xmContainsCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x3040...0x30FF,
                 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}

/// 阅读日历字体令牌，集中维护日期相关文本层级。
enum ReadCalendarTypography {
    static let topControlTitleFont: Font = AppTypography.fixed(baseSize: 18, relativeTo: .headline, weight: .semibold, design: .rounded)
    static let weekdayHeaderFont: Font = AppTypography.fixed(baseSize: 13, relativeTo: .caption, weight: .medium, design: .rounded)
    static let monthGridDayNumberFont: Font = AppTypography.fixed(baseSize: 13, relativeTo: .caption, weight: .medium, design: .rounded)
    static let monthGridDayNumberSelectedFont: Font = AppTypography.fixed(baseSize: 13, relativeTo: .caption, weight: .bold, design: .rounded)
    static let yearHeatmapMonthTitleFont: Font = AppTypography.semantic(.callout, weight: .semibold)
}

// MARK: - Timeline Calendar Style

/// 时间线日历样式令牌，集中维护字体、尺寸与颜色语义，避免页面内硬编码。
enum TimelineCalendarStyle {
    static let monthNumberFont: Font = AppTypography.brandDisplay(size: 20, relativeTo: .title3)
    static let monthNumberVerticalTrim = AppTypography.brandTrim(size: 20, textStyle: .title3)
    static let monthUnitFont: Font = AppTypography.fixed(baseSize: 10, relativeTo: .caption2, weight: .medium, design: .rounded)
    static let actionButtonFont: Font = AppTypography.fixed(baseSize: 13, relativeTo: .caption, weight: .semibold, design: .rounded)
    static let relativeNumberFont: Font = AppTypography.brandDisplay(size: 16, relativeTo: .body)
    static let relativeNumberVerticalTrim = AppTypography.brandTrim(size: 16, textStyle: .body)
    static let relativeUnitFont: Font = AppTypography.fixed(baseSize: 10, relativeTo: .caption2, design: .rounded)
    static let weekdayFont: Font = AppTypography.fixed(baseSize: 11, relativeTo: .caption2, weight: .medium, design: .rounded)
    static let categoryChipFont: Font = AppTypography.fixed(baseSize: 12, relativeTo: .caption, weight: .medium, design: .rounded)
    static let dayNumberFont: Font = AppTypography.brandDisplay(size: 13, relativeTo: .body)

    // 时间线圆角语义：顶部日历背景卡对齐热力图卡片，事件卡统一主内容卡角色。
    static let panelCornerRadius: CGFloat = CornerRadius.containerLarge
    static let eventCardCornerRadius: CGFloat = CornerRadius.blockLarge

    static let dayCellSize: CGFloat = 32
    static let selectedCircleSize: CGFloat = 30
    static let progressRingSize: CGFloat = 28
    static let progressRingLineWidth: CGFloat = 1.6
    static let markerDotSize: CGFloat = 4
    static let markerDotOffsetY: CGFloat = 12

    static let monthNumberColor: Color = .textPrimary
    static let monthUnitColor: Color = .textSecondary
    static let relativeNumberColor: Color = .textPrimary
    static let relativeUnitColor: Color = .textSecondary
    static let weekdayTextColor: Color = .textHint
    static let progressTrackColor: Color = Color.brand.opacity(0.18)

    // 粘性日期头部：品牌衬线体提升分组锚点辨识度，与顶部日历标题建立字体家族呼应
    static let sectionDateFont: Font = AppTypography.brandDisplay(size: 18, relativeTo: .subheadline)
    static let sectionYearFont: Font = AppTypography.brandDisplay(size: 18, relativeTo: .subheadline)
    static let sectionDateVerticalTrim = AppTypography.brandTrim(size: 18, textStyle: .subheadline)
    static let sectionFilterFont: Font = AppTypography.fixed(baseSize: 12, relativeTo: .caption, weight: .medium, design: .rounded)
}

// MARK: - Timeline Typography

/// 时间线卡片正文字体令牌，确保富文本密度在不同卡片中保持一致。
enum TimelineTypography {
    static let eventRichTextBaseFont: UIFont = AppTypography.uiSemantic(.callout)
    static let eventRichTextLineSpacing: CGFloat = 4
    static let eventFallbackTextFont: Font = AppTypography.callout
}

// MARK: - Color Helpers

extension Color {
    /// 通过十六进制 RGB 值构建颜色，便于与设计稿色值对齐。
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// 定义浅色/深色双主题颜色，运行时按系统外观自动切换。
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }

    /// 通过 RGBA 32 位整数构建颜色（高 8 位为红色，低 8 位为透明度）。
    init(rgbaHex: UInt32) {
        let red = Double((rgbaHex >> 24) & 0xFF) / 255.0
        let green = Double((rgbaHex >> 16) & 0xFF) / 255.0
        let blue = Double((rgbaHex >> 8) & 0xFF) / 255.0
        let alpha = Double(rgbaHex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
