import Foundation
import GRDB

// MARK: - AppDatabase
// 数据库核心管理类，负责 DatabasePool 的初始化、迁移和生命周期管理
// 使用 WAL 模式，与 Android Room 的默认行为一致

struct AppDatabase {
    /// 数据库连接池（支持并发读取）
    let dbPool: DatabasePool

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
