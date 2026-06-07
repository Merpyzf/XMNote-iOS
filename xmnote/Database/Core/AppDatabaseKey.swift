/**
 * [INPUT]: 依赖 SwiftUI Environment 与 GRDB，依赖 AppDatabase
 * [OUTPUT]: 对外提供 DatabaseManager 可观察管理器、数据库热切换入口与 SwiftUI Environment Key
 * [POS]: Database/Core 的 SwiftUI 注入桥梁，被 xmnoteApp 初始化并注入全局
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import GRDB

// MARK: - DatabaseManager
// 可观察的数据库管理器，支持热重载（备份恢复后重新打开数据库）

/// 数据库管理器，负责持有 AppDatabase 并在恢复后重建连接。
@Observable
/// 全局数据库管理器，负责持有当前数据库实例并支持热重载。
class DatabaseManager {
    @ObservationIgnored
    private(set) var database: AppDatabase

    /// 创建数据库管理器并打开默认数据库文件。
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
        try reopen(at: path)
    }

    /// 关闭当前数据库连接并返回原数据库路径，供整库恢复在替换文件前释放旧连接。
    ///
    /// 调用价值：备份恢复需要在删除/复制 `db-wal-shm` 文件集前精确关闭 GRDB 连接池，避免旧连接继续读取被替换的 SQLite 文件。
    /// 失败语义：`close()` 失败时不会替换 `database`，调用方应停止文件替换并保留当前数据库。
    func closeCurrentDatabaseForReplacement() throws -> String {
        let path = database.databasePath
        database.interrupt()
        try database.close()
        return path
    }

    /// 按指定路径重新打开数据库，并把全局数据库实例切换到新连接池。
    ///
    /// 调用价值：整库恢复完成或回滚完成后，统一通过该入口重新建立 GRDB 连接池，保证后续 Repository 读取最新数据库文件。
    func reopen(at path: String) throws {
        database = try AppDatabase(path: path)
    }
}
