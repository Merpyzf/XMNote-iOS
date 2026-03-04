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

/// DataBackupViewModel 负责备份模块的状态管理与业务动作编排，向界面提供可渲染数据。
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

    /// 注入备份与服务器仓储，初始化备份页面状态。
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

    /// 进入页面时加载当前选中的备份服务器信息。
    func loadPageData() async {
        await loadCurrentServer()
    }
}

// MARK: - 备份

extension DataBackupViewModel {

    /// 触发手动备份流程并更新执行结果状态。
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

    /// 拉取远端备份历史列表，供恢复弹层展示。
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

    /// 触发手动恢复流程并更新执行结果状态。
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

    /// 刷新当前选中的备份服务器状态。
    func loadCurrentServer() async {
        do {
            currentServer = try await serverRepository.fetchCurrentServer()
        } catch {
            currentServer = nil
        }
    }

    /// 根据当前状态决定备份模块界面应展示的内容分支。
    func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
