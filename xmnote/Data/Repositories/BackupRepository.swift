import Foundation

/**
 * [INPUT]: 依赖 BackupServerRepositoryProtocol、BackupArchiveService、CloudBackupRemoteProvider 与 UserDefaults
 * [OUTPUT]: 对外提供 BackupRepository（BackupRepositoryProtocol 的实现）
 * [POS]: Data 层云备份仓储，统一编排 provider 选择、备份打包、历史读取、恢复与状态持久化
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// BackupRepository 统一编排云备份 provider 选择、打包上传、历史读取和恢复流程。
struct BackupRepository: BackupRepositoryProtocol {
    /// PreferenceKey 负责当前场景的enum定义，明确职责边界并组织相关能力。
    private enum PreferenceKey {
        // 对齐 Android SpSettingHelper#getCloudBackupService。
        static let selectedProvider = "currCloudBackupService"
        static let lastLocalBackupExportDate = "lastLocalBackupExportDate"
    }

    typealias RemoteProviderFactory = (
        _ provider: CloudBackupProvider,
        _ allowUnavailable: Bool
    ) async throws -> (any CloudBackupRemoteProvider)?

    private let databaseManager: DatabaseManager
    private let serverRepository: any BackupServerRepositoryProtocol
    private let aliyunDriveProvider: AliyunDriveBackupRemoteProvider?
    private let userDefaults: UserDefaults
    private let remoteProviderFactory: RemoteProviderFactory?

    /// 注入数据库、服务器仓储与阿里云 provider，组装备份仓储执行上下文。
    init(
        databaseManager: DatabaseManager,
        serverRepository: any BackupServerRepositoryProtocol,
        aliyunDriveProvider: AliyunDriveBackupRemoteProvider?,
        userDefaults: UserDefaults = .standard,
        remoteProviderFactory: RemoteProviderFactory? = nil
    ) {
        self.databaseManager = databaseManager
        self.serverRepository = serverRepository
        self.aliyunDriveProvider = aliyunDriveProvider
        self.userDefaults = userDefaults
        self.remoteProviderFactory = remoteProviderFactory
    }
}

// MARK: - Page State

extension BackupRepository {

    func fetchLastLocalBackupDate() async -> Date? {
        userDefaults.object(forKey: PreferenceKey.lastLocalBackupExportDate) as? Date
    }

    func fetchCloudBackupPageState() async throws -> CloudBackupPageState {
        let selectedProvider = try await fetchSelectedProvider()
        let webdavServer = try await serverRepository.fetchCurrentServer()
        let aliyunState = await fetchAliyunState()

        return CloudBackupPageState(
            selectedProvider: selectedProvider,
            webdavServer: webdavServer,
            isAliyunAuthorized: aliyunState.isAuthorized,
            aliyunAccountInfo: aliyunState.accountInfo,
            aliyunAccountInfoErrorMessage: aliyunState.errorMessage,
            lastBackupDate: nil
        )
    }

    func fetchLatestCloudBackupDate() async throws -> Date? {
        let provider = try await currentRemoteProvider()
        let backups = try await provider.listBackups()
        return backups.first?.backupDate
    }

    func selectCloudBackupProvider(_ provider: CloudBackupProvider) async throws {
        userDefaults.set(provider.rawValue, forKey: PreferenceKey.selectedProvider)
    }

    func authorizeAliyunDrive() async throws {
        guard let aliyunDriveProvider else {
            throw BackupError.invalidAliyunDriveConfiguration
        }
        try await aliyunDriveProvider.authorize()
    }

    func revokeAliyunDriveAuthorization() async {
        await aliyunDriveProvider?.revokeAuthorization()
    }
}

// MARK: - Backup Actions

extension BackupRepository {

    func prepareLocalExport() async throws -> LocalBackupExportTicket {
        let workingDirectory = try createTemporaryDirectory()
        do {
            let artifact = try await createArchiveArtifact(in: workingDirectory)
            let exportURL = workingDirectory.appendingPathComponent("\(artifact.fileName).zip")
            try FileManager.default.moveItem(at: artifact.localFileURL, to: exportURL)
            return LocalBackupExportTicket(
                workingDirectoryURL: workingDirectory,
                archiveFileURL: exportURL,
                suggestedFileName: exportURL.lastPathComponent
            )
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    func finalizeLocalExport(_ ticket: LocalBackupExportTicket, succeeded: Bool) async {
        if succeeded {
            userDefaults.set(Date(), forKey: PreferenceKey.lastLocalBackupExportDate)
        }
        try? FileManager.default.removeItem(at: ticket.workingDirectoryURL)
    }

    func prepareLocalImport(from url: URL) async throws -> LocalBackupImportTicket {
        let workingDirectory = try createTemporaryDirectory()
        do {
            let localFileURL = try await copyImportFileToTemporaryDirectory(
                from: url,
                workingDirectory: workingDirectory
            )
            let inspection = try await runBlockingWork {
                try archiveService().validateBackupArchive(at: localFileURL)
            }
            return LocalBackupImportTicket(
                workingDirectoryURL: workingDirectory,
                archiveFileURL: localFileURL,
                fileName: localFileURL.lastPathComponent,
                backupDate: inspection.backupDate,
                deviceName: inspection.deviceName
            )
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    func restoreLocalBackup(
        using ticket: LocalBackupImportTicket,
        progress: (@Sendable (RestoreProgress) -> Void)?
    ) async throws {
        defer { try? FileManager.default.removeItem(at: ticket.workingDirectoryURL) }
        try await runBlockingWork {
            try archiveService().restoreBackupArchive(
                from: ticket.archiveFileURL,
                databaseManager: databaseManager,
                progress: progress
            )
        }
    }

    func discardLocalImport(_ ticket: LocalBackupImportTicket) async {
        try? FileManager.default.removeItem(at: ticket.workingDirectoryURL)
    }

    func backup(progress: (@Sendable (BackupProgress) -> Void)?) async throws {
        let provider = try await currentRemoteProvider()
        let temporaryDirectory = try createTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        progress?(.preparing)
        progress?(.packaging)
        let artifact = try await createArchiveArtifact(in: temporaryDirectory)

        progress?(.uploading(nil))
        try await provider.uploadBackup(
            localFileURL: artifact.localFileURL,
            fileName: artifact.fileName
        ) { fraction in
            progress?(.uploading(fraction))
        }

        await cleanOldBackupsIfNeeded(using: provider, progress: progress)
        progress?(.completed)
    }

    func fetchBackupHistory() async throws -> [BackupFileInfo] {
        let provider = try await currentRemoteProvider()
        return try await provider.listBackups()
    }

    func restore(
        _ backup: BackupFileInfo,
        progress: (@Sendable (RestoreProgress) -> Void)?
    ) async throws {
        let provider = try await makeRequiredRemoteProvider(for: backup.provider)
        let temporaryDirectory = try createTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let localArchiveURL = temporaryDirectory.appendingPathComponent(backup.name)
        progress?(.downloading(nil))
        try await provider.downloadBackup(backup, to: localArchiveURL) { fraction in
            progress?(.downloading(fraction))
        }

        try await runBlockingWork {
            try archiveService().restoreBackupArchive(
                from: localArchiveURL,
                databaseManager: databaseManager,
                progress: progress
            )
        }
    }
}

// MARK: - Internals

private extension BackupRepository {

    func archiveService() -> BackupArchiveService {
        BackupArchiveService(database: databaseManager.database)
    }

    func createTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func createArchiveArtifact(in directory: URL) async throws -> BackupArchiveArtifact {
        try await runBlockingWork {
            try archiveService().createBackupArchive(in: directory)
        }
    }

    func copyImportFileToTemporaryDirectory(
        from sourceURL: URL,
        workingDirectory: URL
    ) async throws -> URL {
        try await runBlockingWork {
            let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let fileManager = FileManager.default
            let preferredName = sourceURL.lastPathComponent.isEmpty ? "\(UUID().uuidString).zip" : sourceURL.lastPathComponent
            let destinationURL = workingDirectory.appendingPathComponent(preferredName)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }
    }

    func runBlockingWork<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func currentRemoteProvider() async throws -> any CloudBackupRemoteProvider {
        let selectedProvider = try await fetchSelectedProvider()
        return try await makeRequiredRemoteProvider(for: selectedProvider)
    }

    func makeRequiredRemoteProvider(for provider: CloudBackupProvider) async throws -> any CloudBackupRemoteProvider {
        if let remoteProvider = try await makeRemoteProvider(for: provider, allowUnavailable: false) {
            return remoteProvider
        }

        switch provider {
        case .aliyunDrive:
            throw BackupError.noAliyunDriveAuthorized
        case .webdav:
            throw BackupError.noServerConfigured
        }
    }

    func makeRemoteProvider(
        for provider: CloudBackupProvider,
        allowUnavailable: Bool
    ) async throws -> (any CloudBackupRemoteProvider)? {
        if let remoteProviderFactory,
           let injectedProvider = try await remoteProviderFactory(provider, allowUnavailable) {
            return injectedProvider
        }

        switch provider {
        case .webdav:
            guard let server = try await serverRepository.fetchCurrentServer() else {
                return nil
            }
            let client = WebDAVClient(
                baseURL: server.serverAddress,
                username: server.account,
                password: server.password
            )
            return WebDAVBackupRemoteProvider(client: client)
        case .aliyunDrive:
            guard let aliyunDriveProvider else {
                if allowUnavailable {
                    return nil
                }
                throw BackupError.invalidAliyunDriveConfiguration
            }
            let isAuthorized = await aliyunDriveProvider.hasAuthorizedSession()
            if allowUnavailable || isAuthorized {
                return aliyunDriveProvider
            }
            return nil
        }
    }

    func cleanOldBackupsIfNeeded(
        using provider: any CloudBackupRemoteProvider,
        progress: (@Sendable (BackupProgress) -> Void)?
    ) async {
        do {
            let toDelete = try await backupsToDelete(using: provider)
            guard !toDelete.isEmpty else { return }

            progress?(.finalizing)
            for backup in toDelete {
                do {
                    try await provider.deleteBackup(backup)
                } catch {
                    print("[BackupRepository] 清理旧备份失败: \(error.localizedDescription)")
                }
            }
        } catch {
            print("[BackupRepository] 拉取旧备份列表失败，跳过清理: \(error.localizedDescription)")
        }
    }

    func backupsToDelete(
        using provider: any CloudBackupRemoteProvider
    ) async throws -> [BackupFileInfo] {
        let backups = try await provider.listBackups()
        guard backups.count > BackupArchiveService.maxHistoryCount else { return [] }
        return Array(backups.suffix(from: BackupArchiveService.maxHistoryCount))
    }

    func fetchSelectedProvider() async throws -> CloudBackupProvider {
        if let provider = storedProvider() {
            return provider
        }
        let defaultProvider: CloudBackupProvider = try await serverRepository.fetchCurrentServer() == nil ? .aliyunDrive : .webdav
        userDefaults.set(defaultProvider.rawValue, forKey: PreferenceKey.selectedProvider)
        return defaultProvider
    }

    func storedProvider() -> CloudBackupProvider? {
        guard let raw = userDefaults.object(forKey: PreferenceKey.selectedProvider) as? NSNumber else {
            return nil
        }
        return CloudBackupProvider(rawValue: raw.intValue)
    }
}

private extension BackupRepository {
    func fetchAliyunState() async -> (isAuthorized: Bool, accountInfo: CloudBackupAccountInfo?, errorMessage: String?) {
        guard let aliyunDriveProvider else {
            return (false, nil, nil)
        }

        var isAuthorized = await aliyunDriveProvider.hasAuthorizedSession()
        guard isAuthorized else {
            return (false, nil, nil)
        }

        do {
            if let accountInfo = try await aliyunDriveProvider.fetchAccountInfo() {
                return (true, accountInfo, nil)
            }
            isAuthorized = false
            return (false, nil, nil)
        } catch {
            let message = "用户信息获取失败：\(error.localizedDescription)"
            return (isAuthorized, nil, message)
        }
    }
}
