import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供 backup_server 表读写，依赖 WebDAVClient 提供连接测试能力
 * [OUTPUT]: 对外提供 BackupServerRepository（BackupServerRepositoryProtocol 的实现）
 * [POS]: Data 层备份服务器仓储，统一封装服务器配置 CRUD（纯持久化）与连接测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct BackupServerRepository: BackupServerRepositoryProtocol {
    private let databaseManager: DatabaseManager

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func fetchServers() async throws -> [BackupServerRecord] {
        try await databaseManager.database.dbPool.read { db in
            try BackupServerRecord
                .filter(Column("is_deleted") == 0)
                .order(Column("is_using").desc)
                .fetchAll(db)
        }
    }

    func fetchCurrentServer() async throws -> BackupServerRecord? {
        try await databaseManager.database.dbPool.read { db in
            try BackupServerRecord
                .filter(Column("is_deleted") == 0)
                .filter(Column("is_using") == 1)
                .fetchOne(db)
        }
    }

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

    func delete(_ server: BackupServerRecord) async throws {
        try await databaseManager.database.dbPool.write { db in
            var record = server
            record.markAsDeleted()
            try record.update(db)
        }
    }

    func select(_ server: BackupServerRecord) async throws {
        try await databaseManager.database.dbPool.write { db in
            try db.execute(sql: "UPDATE backup_server SET is_using = 0")
            var record = server
            record.isUsing = 1
            record.touchUpdatedDate()
            try record.update(db)
        }
    }

    func testConnection(_ input: BackupServerFormInput) async throws {
        let client = WebDAVClient(
            baseURL: input.address,
            username: input.account,
            password: input.password
        )
        try await client.testConnection()
    }
}
