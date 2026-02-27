/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 PersonalRoute 枚举，定义个人模块导航目的地
 * [POS]: Navigation 模块的个人路由，被 PersonalView 的 NavigationStack 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

enum PersonalRoute: Hashable {
    case settings
    case premium
    case readCalendar
    case readReminder
    case dataImport
    case dataBackup
    case webdavServers
    case batchExport
    case apiIntegration
    case aiConfiguration
    case tagManagement
    case groupManagement
    case bookSource
    case authorManagement
    case pressManagement
    case about
}
