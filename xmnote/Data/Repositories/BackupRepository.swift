import Foundation

/**
 * [INPUT]: 依赖 BackupServerRepositoryProtocol 提供当前服务器，依赖 BackupService 执行备份与恢复
 * [OUTPUT]: 对外提供 BackupRepository（BackupRepositoryProtocol 的实现）
 * [POS]: Data 层备份仓储，统一封装本地数据库与 WebDAV 远端协同流程
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct BackupRepository: BackupRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let serverRepository: any BackupServerRepositoryProtocol

    init(databaseManager: DatabaseManager, serverRepository: any BackupServerRepositoryProtocol) {
        self.databaseManager = databaseManager
        self.serverRepository = serverRepository
    }

    func backup(progress: (@Sendable (BackupProgress) -> Void)?) async throws {
        let service = try await makeService()
        try await service.backup(progress: progress)
    }

    func fetchBackupHistory() async throws -> [BackupFileInfo] {
        let service = try await makeService()
        return try await service.fetchBackupList()
    }

    func restore(_ backup: BackupFileInfo, progress: (@Sendable (RestoreProgress) -> Void)?) async throws {
        let service = try await makeService()
        try await service.restore(backup, databaseManager: databaseManager, progress: progress)
    }
}

private extension BackupRepository {
    func makeService() async throws -> BackupService {
        guard let server = try await serverRepository.fetchCurrentServer() else {
            throw BackupError.noServerConfigured
        }

        let client = WebDAVClient(
            baseURL: server.serverAddress,
            username: server.account,
            password: server.password
        )
        return BackupService(database: databaseManager.database, client: client)
    }
}
