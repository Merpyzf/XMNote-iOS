/**
 * [INPUT]: 依赖 SwiftUI 与 UIKit 的系统动态颜色能力，以及集中式 Color 构造器
 * [OUTPUT]: 对外提供 XMNote 跨模块稳定语义颜色，包含与 Android 对齐的搜索关键字命中语义
 * [POS]: Utilities/DesignSystem 的颜色语义层，只表达用途，不承载页面布局
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

// MARK: - App Accent

extension Color {
    /// App 根级交互 tint，为按钮、系统控件与导航交互提供统一品牌入口。
    static let appTint = BaseColorPalette.brand500
}

// MARK: - Background

extension Color {
    /// 页面级 grouped 背景，承接 Tab 根页、分组列表与卡片流页面的底板层。
    static let surfacePage = Color.xmResolved(.systemGroupedBackground)
    /// 默认内容卡片背景，承接页面底板上的主要内容容器。
    static let surfaceCard = Color.xmResolved(.secondarySystemGroupedBackground)
    /// 嵌套在主卡片上的次级表层，承接 Sheet 内局部模块或多层卡片结构。
    static let surfaceNested = Color.xmResolved(.tertiarySystemGroupedBackground)
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
    static let textPrimary = Color.xmAdaptive(
        light: Color.xmHex(0x333333),
        dark: Color.xmHex(0xC6C8CB),
        highContrastLight: Color.xmHex(0x111111),
        highContrastDark: Color.xmHex(0xF2F2F2)
    )
    /// 次要文本
    static let textSecondary = Color.xmAdaptive(
        light: Color.xmHex(0x666666),
        dark: Color.xmHex(0x8C929B),
        highContrastLight: Color.xmHex(0x4A4A4A),
        highContrastDark: Color.xmHex(0xBFC3C8)
    )
    /// 提示文本
    static let textHint = Color.xmAdaptive(
        light: Color.xmHex(0x999999),
        dark: Color.xmHex(0x999999),
        highContrastLight: Color.xmHex(0x6D6D72),
        highContrastDark: Color.xmHex(0xB0B0B5)
    )
    /// 搜索关键词命中色：标准模式对齐 Android，高对比度模式保留红色语义并增强可读性。
    static let keywordHighlight = Color.xmAdaptive(
        light: Color.xmHex(0xEA4335),
        dark: Color.xmHex(0xEA4335),
        highContrastLight: Color.xmHex(0xA01C11),
        highContrastDark: Color.xmHex(0xF5A39C)
    )
    /// 正文与 Markdown 中可跳转链接的前景色，不承担选中、成功或装饰语义。
    static let linkForeground = Color.xmAdaptive(
        light: BaseColorPalette.brand700,
        dark: BaseColorPalette.brand700,
        highContrastLight: Color.xmHex(0x1B6F37),
        highContrastDark: Color.xmHex(0x65D98D)
    )
}

// MARK: - Icon

extension Color {
    /// 主要图标
    static let iconPrimary = Color.xmAdaptive(
        light: Color.xmHex(0x000000),
        dark: Color.xmHex(0xEEEEEE),
        highContrastLight: Color.xmHex(0x000000),
        highContrastDark: Color.xmHex(0xFFFFFF)
    )
    /// 次要图标（= textSecondary）
    static let iconSecondary = textSecondary
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
    /// 标准内容分隔线，保留既有浅深色对比并供跨模块列表与正文分节复用。
    static let surfaceDividerDefault = Color.xmAdaptive(
        light: Color.xmHex(0xEEEEEE),
        dark: Color.xmHex(0x333333),
        highContrastLight: Color.xmHex(0x8A8A8F),
        highContrastDark: Color.xmHex(0x707074)
    )
    /// 卡片内部弱分隔线，仅表达内容分组，不与卡片边框竞争。
    static let surfaceDividerSubtle = Color.xmResolved(.separator).opacity(0.28)
}

// MARK: - Button & Overlay

extension Color {
    /// 承载白色文案的主提交表面；直接跟随品牌主题色，避免局部主操作出现独立色阶。
    static let primaryActionFill = Color.appTint
    /// 主提交表面的内容色，与 primaryActionFill 成对使用。
    static let primaryActionForeground = Color.xmAdaptive(
        light: Color.white,
        dark: Color.white,
        highContrastLight: Color.white,
        highContrastDark: Color.black
    )
    /// 主按钮禁用态背景，复用系统中性弱填充，不混入品牌色或状态色。
    static let buttonDisabled = Color.controlFillSecondary
    /// 主按钮禁用态内容色，复用中性提示文字并保持弱于可用状态。
    static let buttonDisabledForeground = Color.textHint
    /// 编辑类 swipe 动作填充色，保持既有 SwiftUI 标准蓝色，避免继承 App 品牌 tint。
    static let editActionFill = Color.blue
    /// 遮罩层
    static let overlay = Color.xmAdaptive(light: Color.black.opacity(0.4),
                                dark: Color.black.opacity(0.5))
}

// MARK: - Selection

extension Color {
    /// 选择控件激活色；直接跟随品牌主题色，保持跨页面选择反馈一致。
    static let selectionAccent = Color.appTint
    /// 选中项的高对比前景色，用于浅色表面上的选中文案与图标，不承担链接语义。
    static let selectionForeground = Color.xmAdaptive(
        light: BaseColorPalette.brand700,
        dark: BaseColorPalette.brand700,
        highContrastLight: Color.xmHex(0x1B6F37),
        highContrastDark: Color.xmHex(0x65D98D)
    )
    /// 选择控件未激活描边；独立于提示文本，在深色模式下降低重复圆环的视觉竞争。
    static let selectionInactive = Color.xmAdaptive(
        light: Color.xmHex(0xA1A5A3),
        dark: Color.xmHex(0x696D6B),
        highContrastLight: Color.xmHex(0x707472),
        highContrastDark: Color.xmHex(0xAEB2B0)
    )
}

// MARK: - Feedback

extension Color {
    /// 错误/删除
    static let feedbackError = Color.xmAdaptive(
        light: Color.xmHex(0xEF5350),
        dark: Color.xmHex(0xEF5350),
        highContrastLight: Color.xmHex(0xC62828),
        highContrastDark: Color.xmHex(0xFF6961)
    )
    /// 警告
    static let feedbackWarning = Color.xmAdaptive(
        light: Color.xmHex(0xFF9800),
        dark: Color.xmHex(0xFF9800),
        highContrastLight: Color.xmHex(0xA35E00),
        highContrastDark: Color.xmHex(0xFFB340)
    )
    /// 成功（复用品牌色）
    static let feedbackSuccess = appTint
}
