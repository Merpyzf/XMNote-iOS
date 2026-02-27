/**
 * [INPUT]: 依赖 GRDB 的 DatabasePool/DatabaseMigrator 提供持久化能力
 * [OUTPUT]: 对外提供 AppDatabase 结构体，封装数据库连接池与迁移
 * [POS]: Database 模块入口，被 AppDatabaseKey 通过 Environment 注入全局
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - AppDatabase
// 数据库核心管理类，负责 DatabasePool 的初始化、迁移和生命周期管理
// 使用 WAL 模式，与 Android Room 的默认行为一致

struct AppDatabase {
    /// 数据库连接池（支持并发读取）
    /// 使用 private(set) 以支持热重载场景（备份恢复后重新打开数据库）
    private(set) var dbPool: DatabasePool

    /// 数据库文件名，与 Android 保持一致
    static let databaseName = "xm_note.db"

    /// 数据库版本号，与 Android DBConfig.DB_VERSION 同步
    static let databaseVersion = 38
}

// MARK: - 初始化

extension AppDatabase {

    /// 创建生产环境数据库（存储在 App 的 Application Support 目录）
    init() throws {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = appSupportURL.appendingPathComponent(Self.databaseName)
        dbPool = try Self.openDatabase(at: dbURL.path)
    }

    /// 创建指定路径的数据库（用于测试或备份恢复）
    init(path: String) throws {
        dbPool = try Self.openDatabase(at: path)
    }

    private static func openDatabase(at path: String) throws -> DatabasePool {
        var config = Configuration()
        // WAL 模式：与 Android Room 默认行为一致，支持并发读写
        // 备份时需要先 checkpoint 确保数据完整
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        let dbPool = try DatabasePool(path: path, configuration: config)

        // 兼容 Android Room：如果 user_version 已达标但缺少 grdb_migrations 表，
        // 手动标记迁移为已完成，避免对已有 schema 重复建表
        try dbPool.write { db in
            let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            let hasGRDBTable = try db.tableExists("grdb_migrations")

            if userVersion >= databaseVersion && !hasGRDBTable {
                try db.execute(sql: """
                    CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)
                """)
                try db.execute(sql: """
                    INSERT INTO grdb_migrations (identifier) VALUES ('v38-schema')
                """)
                try db.execute(sql: """
                    INSERT INTO grdb_migrations (identifier) VALUES ('v38-seed')
                """)
            }
        }

        // 执行迁移
        try migrator.migrate(dbPool)

        return dbPool
    }
}

// MARK: - 数据库路径

extension AppDatabase {

    /// 获取数据库文件路径
    var databasePath: String {
        dbPool.path
    }

    /// 获取数据库所在目录
    var databaseDirectory: String {
        (databasePath as NSString).deletingLastPathComponent
    }

    /// 获取所有数据库相关文件路径（主文件 + WAL + SHM）
    /// 备份时需要打包这三个文件
    var databaseFiles: [String] {
        let base = databasePath
        return [base, "\(base)-wal", "\(base)-shm"]
    }
}

// MARK: - Preview

extension AppDatabase {

    /// 内存数据库，仅用于 #Preview 和测试
    static func empty() throws -> AppDatabase {
        let tempDir = NSTemporaryDirectory()
        let path = (tempDir as NSString).appendingPathComponent("preview_\(UUID().uuidString).db")
        return try AppDatabase(path: path)
    }
}

// MARK: - Checkpoint

extension AppDatabase {

    /// 执行 WAL checkpoint，将 WAL 中的数据写入主数据库文件
    /// 备份前必须调用，确保主数据库文件包含所有最新数据
    func checkpoint() throws {
        try dbPool.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
