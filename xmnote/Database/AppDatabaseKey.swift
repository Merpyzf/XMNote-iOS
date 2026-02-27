/**
 * [INPUT]: 依赖 SwiftUI Environment 与 GRDB，依赖 AppDatabase
 * [OUTPUT]: 对外提供 DatabaseManager 可观察管理器与 SwiftUI Environment Key
 * [POS]: Database 模块的 SwiftUI 注入桥梁，被 xmnoteApp 初始化并注入全局
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import GRDB

// MARK: - DatabaseManager
// 可观察的数据库管理器，支持热重载（备份恢复后重新打开数据库）

@Observable
class DatabaseManager {
    private(set) var database: AppDatabase

    init() throws {
        database = try AppDatabase()
    }

    /// Preview/测试用初始化器
    init(database: AppDatabase) {
        self.database = database
    }

    /// 热重载数据库（备份恢复后调用）
    func reopen() throws {
        let path = database.databasePath
        database = try AppDatabase(path: path)
    }
}
