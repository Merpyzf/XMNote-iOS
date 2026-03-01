//
//  DesignTokens.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//
//  [INPUT]: 无外部依赖，仅依赖 SwiftUI 框架
//  [OUTPUT]: Color 语义扩展（含阅读日历主题/事件条 pending 态/月总结图标渐变语义）、Spacing / CornerRadius / CardStyle 常量、Color(hex:) / Color(light:dark:) / Color(rgbaHex:) 构造器
//  [POS]: Utilities 模块的设计令牌中枢，全局 UI 一致性的单一真相源
//  [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

import SwiftUI

enum ReadCalendarSummaryGradientRole {
    case activity
    case completion
    case momentum
    case trend
}

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
    /// 窗口背景色
    static let windowBackground = Color(light: Color(hex: 0xF2F2F6),
                                         dark: Color(hex: 0x000000))
    /// 内容卡片背景色
    static let contentBackground = Color(light: .white,
                                          dark: Color(hex: 0x1C1C1C))
    /// 标签背景色
    static let tagBackground = Color(light: Color(hex: 0xE8F0EC),
                                      dark: Color(hex: 0x343536))
    /// Sheet 背景
    static let bgSheet = Color(light: Color(hex: 0xF2F2F6),
                                dark: Color(hex: 0x1C1C1C))
    /// 次级背景（搜索栏、次级按钮等）
    static let bgSecondary = Color(light: Color(hex: 0xF2F2F2),
                                    dark: Color(hex: 0x262626))
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
}

// MARK: - Icon

extension Color {
    /// 主要图标
    static let iconPrimary = Color(light: Color(hex: 0x000000),
                                    dark: Color(hex: 0xEEEEEE))
    /// 次要图标（= textSecondary）
    static let iconSecondary = Color(light: Color(hex: 0x666666),
                                      dark: Color(hex: 0x8C929B))
    /// 图标容器背景（= bgSecondary）
    static let iconBgShape = Color(light: Color(hex: 0xF2F2F2),
                                    dark: Color(hex: 0x262626))
}

// MARK: - Border & Divider

extension Color {
    /// 卡片边框色
    static let cardBorder = Color(light: Color(hex: 0xCCCCCC).opacity(0.5),
                                   dark: Color.white.opacity(0.1))
    /// 分割线
    static let divider = Color(light: Color(hex: 0xEEEEEE),
                                dark: Color(hex: 0x333333))
    /// 内容边框
    static let contentBorder = Color(light: Color(hex: 0xCCCCCC),
                                      dark: Color(hex: 0x666666))
}

// MARK: - Button & Overlay

extension Color {
    /// 主按钮禁用态
    static let buttonDisabled = Color(light: Color(hex: 0xA6D6B8),
                                       dark: Color(hex: 0x3A5C45))
    /// 遮罩层
    static let overlay = Color(light: Color.black.opacity(0.4),
                                dark: Color.black.opacity(0.5))
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
// 选择指南（两步决策）：
//
// 第一步：判断间距场景
//   内部间距 → 元素内部的紧凑留白（图标与文字、标签内 padding）
//   元素间距 → 同级元素之间的呼吸空间（按钮组、控件行间、列表项间）
//   容器间距 → 容器与内容的边距（卡片 padding、屏幕边距）
//
// 第二步：按密度选 token
//   compact(4) < half(6) < cozy(8) < base(12) < screenEdge(16) < contentEdge(18) < double(24)
//
// 示例：
//   HStack 图标与文字间距   → 内部间距 → 最紧凑 → compact
//   月份选择器内 padding    → 内部间距 → 稍松   → half
//   工具栏按钮组 spacing    → 元素间距 → 舒适   → cozy
//   VStack 段落间距         → 元素间距 → 标准   → base
//   卡片内容到边缘          → 容器间距 → 屏幕级 → screenEdge
//   面板内容边距            → 容器间距 → 宽松   → contentEdge
//   区块之间大留白          → 容器间距 → 最大   → double

enum Spacing {
    static let compact: CGFloat = 4
    static let half: CGFloat = 6
    static let cozy: CGFloat = 8
    static let base: CGFloat = 12
    static let double: CGFloat = 24
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
//   tiny(2.5) < small(4) < medium(6~8) < large(10~12) < xl(16) < xxl(18)
//
// 示例：
//   热力图方格 → 嵌在卡片里的小零件 → inlay → 最小的 → inlayTiny
//   书籍封面   → 嵌在网格里的小零件 → inlay → 稍大   → inlaySmall
//   事件条     → 独立内容单元       → block → 紧凑   → blockSmall
//   标准卡片   → 独立内容单元       → block → 标准   → blockLarge
//   日历面板   → 包裹内容的容器     → container → 标准 → containerMedium

enum CornerRadius {
    // --- inlay: 嵌在卡片/容器内的小型视觉零件 ---
    static let inlayTiny: CGFloat = 2.5    // 热力图方格、图例色块
    static let inlaySmall: CGFloat = 4     // 书籍封面缩略图
    static let inlayMedium: CGFloat = 6    // 标签、徽章

    // --- block: 独立可识别的内容单元 ---
    static let blockSmall: CGFloat = 8     // 事件条、紧凑卡片
    static let blockMedium: CGFloat = 10   // 列表项、输入框
    static let blockLarge: CGFloat = 12    // 标准卡片、内容区域

    // --- container: 承载内容块的外壳 ---
    static let containerMedium: CGFloat = 16  // 面板、弹层
    static let containerLarge: CGFloat = 18   // 突出容器（热力图 widget）
}

// MARK: - Card Style

enum CardStyle {
    static let borderWidth: CGFloat = 0.5
}

// MARK: - Color Helpers

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }

    init(rgbaHex: UInt32) {
        let red = Double((rgbaHex >> 24) & 0xFF) / 255.0
        let green = Double((rgbaHex >> 16) & 0xFF) / 255.0
        let blue = Double((rgbaHex >> 8) & 0xFF) / 255.0
        let alpha = Double(rgbaHex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
