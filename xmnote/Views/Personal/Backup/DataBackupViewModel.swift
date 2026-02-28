import Foundation

/**
 * [INPUT]: 依赖 BackupRepositoryProtocol 执行备份/恢复，依赖 BackupServerRepositoryProtocol 读取当前服务器
 * [OUTPUT]: 对外提供 DataBackupViewModel 与 BackupOperationState，驱动备份页面状态
 * [POS]: Backup 模块数据备份状态编排器，被 DataBackupView/BackupHistorySheetView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

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

    private let backupRepository: any BackupRepositoryProtocol
    private let serverRepository: any BackupServerRepositoryProtocol

    init(
        backupRepository: any BackupRepositoryProtocol,
        serverRepository: any BackupServerRepositoryProtocol
    ) {
        self.backupRepository = backupRepository
        self.serverRepository = serverRepository
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
        guard currentServer != nil else {
            showErrorMessage("未配置备份服务器")
            return
        }

        do {
            try await backupRepository.backup { progress in
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
        guard currentServer != nil else {
            showErrorMessage("未配置备份服务器")
            return
        }

        do {
            backupList = try await backupRepository.fetchBackupHistory()
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

        guard currentServer != nil else {
            showErrorMessage("未配置备份服务器")
            return
        }

        do {
            try await backupRepository.restore(backup) { progress in
                Task { @MainActor [weak self] in
                    self?.operationState = .restoring(progress)
                }
            }
            #if DEBUG
            print("[ViewModel] restore 成功，设置 idle")
            #endif
            operationState = .idle
            showRestoreSuccess = true
            await loadCurrentServer()
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
            currentServer = try await serverRepository.fetchCurrentServer()
        } catch {
            currentServer = nil
        }
    }

    func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
