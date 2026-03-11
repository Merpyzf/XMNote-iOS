import Foundation

/**
 * [INPUT]: 依赖 BackupServerRepositoryProtocol 提供当前服务器，依赖 BackupService 执行备份与恢复
 * [OUTPUT]: 对外提供 BackupRepository（BackupRepositoryProtocol 的实现）
 * [POS]: Data 层备份仓储，统一封装本地数据库与 WebDAV 远端协同流程
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// BackupRepository 统一编排备份服务创建、备份历史读取和恢复流程。
struct BackupRepository: BackupRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let serverRepository: any BackupServerRepositoryProtocol

    /// 注入数据库与服务器仓储，组装备份仓储执行上下文。
    init(databaseManager: DatabaseManager, serverRepository: any BackupServerRepositoryProtocol) {
        self.databaseManager = databaseManager
        self.serverRepository = serverRepository
    }

    /// 触发一次完整备份流程，并通过 progress 回传阶段进度。
    func backup(progress: (@Sendable (BackupProgress) -> Void)?) async throws {
        let service = try await makeService()
        try await service.backup(progress: progress)
    }

    /// 拉取远端备份历史列表，供恢复入口展示。
    func fetchBackupHistory() async throws -> [BackupFileInfo] {
        let service = try await makeService()
        return try await service.fetchBackupList()
    }

    /// 使用指定备份执行恢复流程，并通过 progress 回传阶段进度。
    func restore(_ backup: BackupFileInfo, progress: (@Sendable (RestoreProgress) -> Void)?) async throws {
        let service = try await makeService()
        try await service.restore(backup, databaseManager: databaseManager, progress: progress)
    }
}

private extension BackupRepository {
    /// 根据当前选中服务器组装 BackupService；未配置服务器时抛出 noServerConfigured。
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
