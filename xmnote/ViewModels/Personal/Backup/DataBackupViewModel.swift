import Foundation

/**
 * [INPUT]: 依赖 BackupRepositoryProtocol 执行 provider 状态读取、授权、备份与恢复
 * [OUTPUT]: 对外提供 DataBackupViewModel 与 BackupOperationState，驱动备份页面状态
 * [POS]: Backup 模块数据备份状态编排器，被 DataBackupView/BackupHistorySheetView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - Operation State

/// BackupOperationState 表示备份页当前处于空闲、备份中还是恢复中，供页面统一映射按钮和进度态。
enum BackupOperationState: Equatable {
    case idle
    case backingUp(BackupProgress)
    case restoring(RestoreProgress)
}

enum CloudBackupLastSyncState: Equatable {
    case idle
    case loading
    case loaded(Date?)
    case failed
}

enum BackupBlockingAction: Equatable {
    case loadingPage
    case switchingProvider
    case authorizingAliyunDrive
    case revokingAliyunDrive
    case fetchingBackupHistory

    var loadingMessage: String {
        switch self {
        case .loadingPage:
            "加载中…"
        case .switchingProvider:
            "切换备份方式…"
        case .authorizingAliyunDrive:
            "登录阿里云盘…"
        case .revokingAliyunDrive:
            "退出阿里云盘…"
        case .fetchingBackupHistory:
            "读取备份历史…"
        }
    }
}

enum BackupInitialLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

struct BackupTaskPresentation: Equatable {
    let message: String
}

// MARK: - DataBackupViewModel

/// DataBackupViewModel 负责 provider 状态、授权动作和手动备份/恢复动作编排。
@MainActor
@Observable
final class DataBackupViewModel {
    var operationState: BackupOperationState = .idle
    var initialLoadState: BackupInitialLoadState = .idle
    var pageState = CloudBackupPageState(
        selectedProvider: .webdav,
        webdavServer: nil,
        isAliyunAuthorized: false,
        aliyunAccountInfo: nil,
        aliyunAccountInfoErrorMessage: nil,
        lastBackupDate: nil
    )
    var lastBackupState: CloudBackupLastSyncState = .idle
    var backupList: [BackupFileInfo] = []
    var isShowingBackupHistory = false
    var isShowingProviderPicker = false
    var selectedBackup: BackupFileInfo?
    var showRestoreConfirm = false
    var showRestoreSuccess = false
    var errorMessage: String?
    var showError = false
    var blockingAction: BackupBlockingAction?

    private let backupRepository: any BackupRepositoryProtocol
    private let onRestoreSucceeded: (@MainActor () -> Void)?
    private static let lastBackupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    /// 注入备份仓储，初始化备份页面状态。
    init(
        backupRepository: any BackupRepositoryProtocol,
        onRestoreSucceeded: (@MainActor () -> Void)? = nil
    ) {
        self.backupRepository = backupRepository
        self.onRestoreSucceeded = onRestoreSucceeded
    }
}

// MARK: - Derived State

extension DataBackupViewModel {

    var selectedProvider: CloudBackupProvider { pageState.selectedProvider }
    var currentServer: BackupServerRecord? { pageState.webdavServer }
    var aliyunAccountInfo: CloudBackupAccountInfo? { pageState.aliyunAccountInfo }
    var isAliyunAuthorized: Bool { pageState.isAliyunAuthorized }
    var aliyunAccountInfoErrorMessage: String? { pageState.aliyunAccountInfoErrorMessage }
    var isBusy: Bool { operationState != .idle || blockingAction != nil }
    var canPerformCloudOperation: Bool { pageState.isCurrentProviderAvailable && !isBusy }
    var isInitialLoading: Bool { initialLoadState == .loading }
    var isProviderSummaryLoading: Bool { blockingAction == .loadingPage }
    var isProviderDetailLoading: Bool { blockingAction == .loadingPage }
    var isLastBackupValueLoading: Bool { blockingAction == .loadingPage || lastBackupState == .loading }
    var isProviderSwitching: Bool { blockingAction == .switchingProvider }
    var isAliyunAuthorizing: Bool { blockingAction == .authorizingAliyunDrive }
    var isAliyunRevoking: Bool { blockingAction == .revokingAliyunDrive }
    var isBackupHistoryLoading: Bool { blockingAction == .fetchingBackupHistory }
    var taskPresentation: BackupTaskPresentation? {
        switch operationState {
        case .idle:
            return nil
        case .backingUp(let progress):
            return backupPresentation(for: progress)
        case .restoring(let progress):
            return restorePresentation(for: progress)
        }
    }

    var lastBackupDateText: String {
        switch lastBackupState {
        case .idle:
            return ""
        case .loading:
            return "读取中…"
        case .loaded(let date):
            guard let date else { return "未备份" }
            return Self.lastBackupDateFormatter.string(from: date)
        case .failed:
            return "获取失败"
        }
    }

    var selectedProviderSummary: String {
        switch selectedProvider {
        case .aliyunDrive:
            return isAliyunAuthorized ? "已登录" : "未登录"
        case .webdav:
            return currentServer?.title ?? "未配置"
        }
    }
}

// MARK: - Page Loading

extension DataBackupViewModel {

    /// 加载页面状态快照；页面首次进入与回到前台时均调用。
    func loadPageData() async {
        guard beginBlockingAction(.loadingPage) else { return }
        initialLoadState = .loading
        defer { endBlockingAction() }

        do {
            try await reloadPageState(showLatestBackupLoading: false)
            initialLoadState = .loaded
        } catch {
            initialLoadState = .failed
            showErrorMessage(error.localizedDescription)
        }
    }

    /// 仅在 App 回到前台时静默刷新授权状态与最近备份时间。
    func refreshOnBecomeActive() async {
        guard !isBusy else { return }

        do {
            try await reloadPageState(showLatestBackupLoading: false)
        } catch {
            // 回前台刷新不主动打断用户操作。
        }
    }
}

// MARK: - Provider Selection

extension DataBackupViewModel {

    /// 切换当前云备份方式并刷新页面状态。
    func selectProvider(_ provider: CloudBackupProvider) async {
        guard beginBlockingAction(.switchingProvider) else { return }
        defer { endBlockingAction() }

        do {
            clearTransientStateForProviderChange()
            try await backupRepository.selectCloudBackupProvider(provider)
            try await reloadPageState(showLatestBackupLoading: false)
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }

    /// 发起阿里云盘授权流程。
    func authorizeAliyunDrive() async {
        guard beginBlockingAction(.authorizingAliyunDrive) else { return }
        defer { endBlockingAction() }

        do {
            try await backupRepository.authorizeAliyunDrive()
            try await reloadPageState(showLatestBackupLoading: false)
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }

    /// 清除阿里云盘授权并刷新页面状态。
    func revokeAliyunDriveAuthorization() async {
        guard beginBlockingAction(.revokingAliyunDrive) else { return }
        defer { endBlockingAction() }

        await backupRepository.revokeAliyunDriveAuthorization()
        do {
            try await reloadPageState(showLatestBackupLoading: false)
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }
}

// MARK: - Backup

extension DataBackupViewModel {

    /// 触发手动备份流程并更新执行结果状态。
    func performBackup() async {
        guard pageState.isCurrentProviderAvailable else {
            showUnavailableProviderMessage()
            return
        }
        guard blockingAction == nil else { return }

        operationState = .backingUp(.preparing)

        do {
            try await backupRepository.backup { progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard case .backingUp = self.operationState else { return }
                    self.operationState = .backingUp(progress)
                }
            }
            operationState = .idle
            await refreshLatestBackupDate(showLoading: false)
        } catch {
            operationState = .idle
            showErrorMessage(error.localizedDescription)
        }
    }
}

// MARK: - Backup History

extension DataBackupViewModel {

    /// 拉取远端备份历史列表，供恢复弹层展示。
    func fetchBackupHistory() async -> Bool {
        guard pageState.isCurrentProviderAvailable else {
            showUnavailableProviderMessage()
            return false
        }
        guard beginBlockingAction(.fetchingBackupHistory) else { return false }
        defer { endBlockingAction() }

        backupList = []
        selectedBackup = nil
        showRestoreConfirm = false

        do {
            backupList = try await backupRepository.fetchBackupHistory()
            return true
        } catch {
            showErrorMessage(error.localizedDescription)
            return false
        }
    }
}

// MARK: - Restore

extension DataBackupViewModel {

    /// 触发手动恢复流程并更新执行结果状态。
    func performRestore(_ backup: BackupFileInfo) async {
        guard pageState.isCurrentProviderAvailable else {
            showUnavailableProviderMessage()
            return
        }
        guard blockingAction == nil else { return }

        operationState = .restoring(.downloading(nil))

        do {
            try await backupRepository.restore(backup) { progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard case .restoring = self.operationState else { return }
                    self.operationState = .restoring(progress)
                }
            }
            operationState = .idle
            showRestoreSuccess = true
            await refreshLatestBackupDate(showLoading: false)
        } catch {
            operationState = .idle
            showErrorMessage(error.localizedDescription)
        }
    }

    func acknowledgeRestoreSuccess() {
        onRestoreSucceeded?()
    }
}

// MARK: - Helpers

private extension DataBackupViewModel {

    func beginBlockingAction(_ action: BackupBlockingAction) -> Bool {
        guard blockingAction == nil, operationState == .idle else { return false }
        blockingAction = action
        return true
    }

    func endBlockingAction() {
        blockingAction = nil
    }

    func reloadPageState(showLatestBackupLoading: Bool) async throws {
        pageState = try await backupRepository.fetchCloudBackupPageState()
        lastBackupState = .loaded(pageState.lastBackupDate)
        await refreshLatestBackupDate(showLoading: showLatestBackupLoading && pageState.isCurrentProviderAvailable)
    }

    func refreshLatestBackupDate(showLoading: Bool) async {
        guard pageState.isCurrentProviderAvailable else {
            lastBackupState = .loaded(pageState.lastBackupDate)
            return
        }

        if showLoading {
            lastBackupState = .loading
        }

        do {
            let latestBackupDate = try await backupRepository.fetchLatestCloudBackupDate()
            pageState = updatedPageState(lastBackupDate: latestBackupDate)
            lastBackupState = .loaded(latestBackupDate)
        } catch {
            lastBackupState = .failed
        }
    }

    func updatedPageState(lastBackupDate: Date?) -> CloudBackupPageState {
        CloudBackupPageState(
            selectedProvider: pageState.selectedProvider,
            webdavServer: pageState.webdavServer,
            isAliyunAuthorized: pageState.isAliyunAuthorized,
            aliyunAccountInfo: pageState.aliyunAccountInfo,
            aliyunAccountInfoErrorMessage: pageState.aliyunAccountInfoErrorMessage,
            lastBackupDate: lastBackupDate
        )
    }

    func clearTransientStateForProviderChange() {
        backupList = []
        selectedBackup = nil
        showRestoreConfirm = false
        isShowingBackupHistory = false
        showRestoreSuccess = false
        errorMessage = nil
        showError = false
        lastBackupState = .idle
    }

    func showUnavailableProviderMessage() {
        switch selectedProvider {
        case .aliyunDrive:
            showErrorMessage("请先登录阿里云盘")
        case .webdav:
            showErrorMessage("请先配置 WebDAV 服务器")
        }
    }

    func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }

    func backupPresentation(for progress: BackupProgress) -> BackupTaskPresentation? {
        switch progress {
        case .preparing:
            return BackupTaskPresentation(
                message: "正在准备备份"
            )
        case .packaging:
            return BackupTaskPresentation(
                message: "正在整理你的数据"
            )
        case .uploading(let progressValue):
            return BackupTaskPresentation(
                message: progressValue.map { "正在上传备份 \(Int(($0 * 100).rounded()))%" } ?? "正在上传备份"
            )
        case .finalizing:
            return BackupTaskPresentation(
                message: "正在完成备份"
            )
        case .completed:
            return nil
        }
    }

    func restorePresentation(for progress: RestoreProgress) -> BackupTaskPresentation? {
        switch progress {
        case .downloading(let progressValue):
            return BackupTaskPresentation(
                message: progressValue.map { "正在下载备份 \(Int(($0 * 100).rounded()))%" } ?? "正在下载备份"
            )
        case .verifying:
            return BackupTaskPresentation(
                message: "正在检查备份"
            )
        case .extracting:
            return BackupTaskPresentation(
                message: "正在恢复数据"
            )
        case .replacing:
            return BackupTaskPresentation(
                message: "正在更新本地数据"
            )
        case .completed:
            return nil
        }
    }
}
