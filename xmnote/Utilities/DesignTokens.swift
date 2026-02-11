//
//  DesignTokens.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import SwiftUI

// MARK: - Brand Colors

extension Color {
    /// 品牌主色 #2ECF77
    static let brand = Color(light: Color(hex: 0x2ECF77),
                             dark: Color(hex: 0x66B96A))

    /// 窗口背景色（浅灰蓝，对应 Android #F3F4F9）
    static let windowBackground = Color(light: Color(hex: 0xF3F4F9),
                                         dark: Color(hex: 0x0F0F0F))

    /// 内容卡片背景色
    static let contentBackground = Color(light: .white,
                                          dark: Color(hex: 0x1A1A1A))

    /// 标签背景色（浅绿，对应 Android #E8F0EC）
    static let tagBackground = Color(light: Color(hex: 0xE8F0EC),
                                      dark: Color(hex: 0x343536))

    /// 卡片边框色（对应 Android #7FE0E0E0）
    static let cardBorder = Color(light: Color(hex: 0xE0E0E0).opacity(0.5),
                                   dark: Color.white.opacity(0.1))
}

// MARK: - Reading Status Colors

extension Color {
    static let statusReading = Color(hex: 0x2196F3)
    static let statusDone = Color(hex: 0xFFB600)
    static let statusWish = Color(hex: 0xEF5350)
    static let statusOnHold = Color(hex: 0x9C27B0)
    static let statusAbandoned = Color(hex: 0x9E9E9E)
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
