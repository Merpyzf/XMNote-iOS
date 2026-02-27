//
//  DesignTokens.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//
//  [INPUT]: 无外部依赖，仅依赖 SwiftUI 框架
//  [OUTPUT]: Color 语义扩展（29 个）、Spacing / CornerRadius / CardStyle 常量、Color(hex:) / Color(light:dark:) 构造器
//  [POS]: Utilities 模块的设计令牌中枢，全局 UI 一致性的单一真相源
//  [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

import SwiftUI

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

// MARK: - Spacing

enum Spacing {
    static let half: CGFloat = 6
    static let base: CGFloat = 12
    static let double: CGFloat = 24
    static let screenEdge: CGFloat = 16
    static let contentEdge: CGFloat = 18
}

// MARK: - Corner Radius

enum CornerRadius {
    static let book: CGFloat = 4
    static let item: CGFloat = 10
    static let card: CGFloat = 12
    static let sheet: CGFloat = 16
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
}
