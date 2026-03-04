import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供 backup_server 表读写，依赖 WebDAVClient 提供连接测试能力
 * [OUTPUT]: 对外提供 BackupServerRepository（BackupServerRepositoryProtocol 的实现）
 * [POS]: Data 层备份服务器仓储，统一封装服务器配置 CRUD（纯持久化）与连接测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

nonisolated struct BackupServerRepository: BackupServerRepositoryProtocol {
    private let databaseManager: DatabaseManager

    /// 注入数据库管理器，供备份服务器配置的持久化读写使用。
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    /// 读取服务器列表，供备份服务器管理页展示已配置地址并优先显示当前启用项。
    /// - Throws: 数据库查询失败时抛出错误。
    func fetchServers() async throws -> [BackupServerRecord] {
        try await databaseManager.database.dbPool.read { db in
            try BackupServerRecord
                .filter(Column("is_deleted") == 0)
                .order(Column("is_using").desc)
                .fetchAll(db)
        }
    }

    /// 读取当前启用的服务器配置，供备份执行流程作为默认目标地址。
    /// - Throws: 数据库查询失败时抛出错误。
    func fetchCurrentServer() async throws -> BackupServerRecord? {
        try await databaseManager.database.dbPool.read { db in
            try BackupServerRecord
                .filter(Column("is_deleted") == 0)
                .filter(Column("is_using") == 1)
                .fetchOne(db)
        }
    }

    /// 新增或编辑服务器配置；首条有效记录会被自动设为当前使用服务器。
    /// - Throws: 数据库写入失败时抛出错误。
    func saveServer(_ input: BackupServerFormInput, editingServer: BackupServerRecord?) async throws {
        try await databaseManager.database.dbPool.write { db in
            if var existing = editingServer {
                existing.title = input.title
                existing.serverAddress = input.address
                existing.account = input.account
                existing.password = input.password
                existing.touchUpdatedDate()
                try existing.update(db)
                return
            }

            var record = BackupServerRecord()
            record.title = input.title
            record.serverAddress = input.address
            record.account = input.account
            record.password = input.password
            let count = try BackupServerRecord
                .filter(Column("is_deleted") == 0)
                .fetchCount(db)
            record.isUsing = count == 0 ? 1 : 0
            record.touchCreatedDate()
            try record.insert(db)
        }
    }

    /// 软删除指定服务器配置，供服务器管理页执行“移除”操作。
    /// - Throws: 数据库写入失败时抛出错误。
    func delete(_ server: BackupServerRecord) async throws {
        try await databaseManager.database.dbPool.write { db in
            var record = server
            record.markAsDeleted()
            try record.update(db)
        }
    }

    /// 切换当前启用的服务器，保证全表始终只有一个 `is_using = 1` 的配置。
    /// - Throws: 数据库写入失败时抛出错误。
    func select(_ server: BackupServerRecord) async throws {
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：先清空 backup_server 的激活标记，确保“当前使用服务器”全表唯一。
            // 副作用：批量把 is_using 置 0，随后再把目标记录置 1（在同一写事务中完成）。
            try db.execute(sql: "UPDATE backup_server SET is_using = 0")
            var record = server
            record.isUsing = 1
            record.touchUpdatedDate()
            try record.update(db)
        }
    }

    /// 使用表单输入即时发起 WebDAV 连通性校验，供保存前验证凭据是否可用。
    /// - Throws: 网络错误、鉴权失败或服务端不可达时抛出错误。
    func testConnection(_ input: BackupServerFormInput) async throws {
        let client = WebDAVClient(
            baseURL: input.address,
            username: input.account,
            password: input.password
        )
        try await client.testConnection()
    }
}
