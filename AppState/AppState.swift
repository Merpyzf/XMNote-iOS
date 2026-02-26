//
//  AppState.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import Foundation

/// 全局共享状态，通过 @Environment 注入到视图树
@Observable
class AppState {
    var colorScheme: AppColorScheme = .system
    var isPremium: Bool = false
    var isAIEnabled: Bool = false
}

enum AppColorScheme: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}
