import Foundation

/**
 * [INPUT]: 依赖 Swift Observation 与 Foundation 基础能力，供全局环境状态读写
 * [OUTPUT]: 对外提供 AppState/AppColorScheme 全局状态模型与会员限制测试开关，供根视图 environment 注入
 * [POS]: 应用级状态容器，位于 xmnote/AppState，统一承载界面主题、会员限制与能力开关
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 全局共享状态，通过 @Environment 注入到视图树。
@Observable
/// AppState 持有跨页面共享的主题、会员限制和能力开关，作为 SwiftUI 根环境状态源。
class AppState {
    var colorScheme: AppColorScheme = .system
    var isPremium: Bool = false
    // TODO: 上线前移除该测试开关，并让会员限制始终按真实会员状态生效。
    var isPremiumRestrictionEnabled: Bool = false
    var isAIEnabled: Bool = false
    var dataEpoch: Int = 0

    /// 仅在全局开关开启且当前不是会员时执行受限能力拦截。
    var shouldEnforcePremiumRestrictions: Bool {
        isPremiumRestrictionEnabled && !isPremium
    }
}

/// 应用主题偏好设置，决定界面跟随系统或强制浅色/深色。
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
