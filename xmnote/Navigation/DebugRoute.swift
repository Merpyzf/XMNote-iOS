/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 DebugRoute 枚举，定义调试页面导航目的地
 * [POS]: Navigation 模块的调试路由，被 MainTabView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// DebugRoute 定义仅用于开发构建的调试导航目标。
enum DebugRoute: Hashable, Codable {
    case debugCenter
}
