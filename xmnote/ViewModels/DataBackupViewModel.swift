import Foundation
import GRDB

// MARK: - 操作状态

enum BackupOperationState: Equatable {
    case idle
    case backingUp(BackupProgress)
    case restoring(RestoreProgress)
}

// MARK: - DataBackupViewModel

@Observable
class DataBackupViewModel {
    var operationState: BackupOperationState = .idle
    var lastBackupDateText = ""
    var currentServer: BackupServerRecord?
    var backupList: [BackupFileInfo] = []
    var isShowingBackupHistory = false
    var selectedBackup: BackupFileInfo?
    var showRestoreConfirm = false
    var showRestoreSuccess = false
    var errorMessage: String?
    var showError = false

    private let databaseManager: DatabaseManager
    private let database: AppDatabase

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        self.database = databaseManager.database
    }
}

// MARK: - Data Loading

extension DataBackupViewModel {

    func loadPageData() async {
        await loadCurrentServer()
    }
}

// MARK: - 备份

extension DataBackupViewModel {

    func performBackup() async {
        guard let service = makeBackupService() else {
            showErrorMessage("未配置备份服务器")
            return
        }

        do {
            try await service.backup { progress in
                Task { @MainActor [weak self] in
                    self?.operationState = .backingUp(progress)
                }
            }
            operationState = .idle
        } catch {
            operationState = .idle
            showErrorMessage(error.localizedDescription)
        }
    }
}

// MARK: - 备份历史

extension DataBackupViewModel {

    func fetchBackupHistory() async {
        guard let service = makeBackupService() else {
            showErrorMessage("未配置备份服务器")
            return
        }

        do {
            backupList = try await service.fetchBackupList()
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }
}

// MARK: - 恢复

extension DataBackupViewModel {

    func performRestore(_ backup: BackupFileInfo) async {
        #if DEBUG
        print("[ViewModel] performRestore 开始: \(backup.name)")
        #endif
        guard let service = makeBackupService() else {
            showErrorMessage("未配置备份服务器")
            return
        }

        do {
            try await service.restore(backup, databaseManager: databaseManager) { progress in
                Task { @MainActor [weak self] in
                    self?.operationState = .restoring(progress)
                }
            }
            #if DEBUG
            print("[ViewModel] restore 成功，设置 idle")
            #endif
            operationState = .idle
            showRestoreSuccess = true
        } catch {
            #if DEBUG
            print("[ViewModel] restore 失败: \(error)")
            #endif
            operationState = .idle
            showErrorMessage(error.localizedDescription)
        }
    }
}

// MARK: - 辅助方法

private extension DataBackupViewModel {

    func loadCurrentServer() async {
        do {
            currentServer = try await database.dbPool.read { db in
                try BackupServerRecord
                    .filter(Column("is_deleted") == 0)
                    .filter(Column("is_using") == 1)
                    .fetchOne(db)
            }
        } catch {
            currentServer = nil
        }
    }

    func makeBackupService() -> BackupService? {
        guard let server = currentServer else { return nil }
        let client = WebDAVClient(
            baseURL: server.serverAddress,
            username: server.account,
            password: server.password
        )
        return BackupService(database: database, client: client)
    }

    func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}