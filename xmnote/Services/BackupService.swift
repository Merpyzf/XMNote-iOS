/**
 * [INPUT]: 依赖 Foundation、UIKit、SQLite3、ZIPFoundation 与 AppDatabase/DatabaseManager
 * [OUTPUT]: 对外提供云备份通用模型、BackupArchiveService 与 CloudBackupRemoteProvider 协议
 * [POS]: Services 模块的备份内核，负责本地备份包生成/恢复与跨 provider 的公共语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SQLite3
import UIKit
import ZIPFoundation

// MARK: - Cloud Backup Models

/// 当前支持的云备份提供方，rawValue 与 Android 常量保持一致。
enum CloudBackupProvider: Int, CaseIterable, Identifiable, Sendable {
    case aliyunDrive = 0
    case webdav = 1

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .aliyunDrive:
            "阿里云盘"
        case .webdav:
            "WebDAV"
        }
    }
}

/// 阿里云盘账号信息，供备份页展示昵称、头像与空间占用。
struct CloudBackupAccountInfo: Sendable {
    let userId: String
    let nickName: String
    let avatarURL: String
    let usedSpace: Int64?
    let totalSpace: Int64?

    var storageSummary: String? {
        guard let usedSpace, let totalSpace else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: usedSpace)) / \(formatter.string(fromByteCount: totalSpace))"
    }
}

/// 备份页面所需的 provider 级状态快照。
struct CloudBackupPageState: Sendable {
    let selectedProvider: CloudBackupProvider
    let webdavServer: BackupServerRecord?
    let isAliyunAuthorized: Bool
    let aliyunAccountInfo: CloudBackupAccountInfo?
    let aliyunAccountInfoErrorMessage: String?
    let lastBackupDate: Date?

    var isCurrentProviderAvailable: Bool {
        switch selectedProvider {
        case .aliyunDrive:
            isAliyunAuthorized
        case .webdav:
            webdavServer != nil
        }
    }
}

/// 备份历史列表项模型，provider-neutral，供界面展示与恢复路由使用。
struct BackupFileInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let remoteIdentifier: String
    let size: Int64
    let lastModified: Date?
    let deviceName: String
    let backupDate: Date?
    let provider: CloudBackupProvider
}

/// 手动备份流程阶段，用于驱动备份按钮文案与进度提示。
enum BackupProgress: Equatable, Sendable {
    case preparing
    case packaging
    case uploading(Double?)
    case finalizing
    case completed
}

/// 恢复流程阶段，用于驱动恢复进度条和阶段文案。
enum RestoreProgress: Equatable, Sendable {
    case downloading(Double?)
    case verifying
    case extracting
    case replacing
    case completed
}

/// 备份与恢复链路的业务错误类型，统一映射给 UI 层展示。
enum BackupError: LocalizedError {
    case noServerConfigured
    case noAliyunDriveAuthorized
    case invalidAliyunDriveConfiguration
    case zipFailed(underlying: Error)
    case unzipFailed(underlying: Error)
    case versionMismatch(backupVersion: Int, appVersion: Int)
    case backupFileCorrupted
    case webdavError(NetworkError)
    case aliyunDriveError(message: String)

    var errorDescription: String? {
        switch self {
        case .noServerConfigured:
            return "未配置 WebDAV 备份服务器"
        case .noAliyunDriveAuthorized:
            return "请先登录阿里云盘"
        case .invalidAliyunDriveConfiguration:
            return "阿里云盘开放平台配置无效"
        case .zipFailed:
            return "压缩备份文件失败"
        case .unzipFailed:
            return "解压备份文件失败"
        case .versionMismatch(let backup, let app):
            return "数据库版本不兼容（备份: v\(backup), 当前: v\(app)）"
        case .backupFileCorrupted:
            return "备份文件已损坏"
        case .webdavError(let error):
            return error.errorDescription
        case .aliyunDriveError(let message):
            return message
        }
    }
}

/// 统一的远端云备份 provider 能力。
protocol CloudBackupRemoteProvider {
    var provider: CloudBackupProvider { get }
    func listBackups() async throws -> [BackupFileInfo]
    func uploadBackup(
        localFileURL: URL,
        fileName: String,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws
    func downloadBackup(
        _ backup: BackupFileInfo,
        to localURL: URL,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws
    func deleteBackup(_ backup: BackupFileInfo) async throws
}

/// 本地备份包产物，提供归档文件路径与远端使用的逻辑文件名。
struct BackupArchiveArtifact: Sendable {
    let localFileURL: URL
    let fileName: String
}

/// 本地导出流程的临时票据，持有待交给系统文档选择器的归档文件。
struct LocalBackupExportTicket: Sendable {
    let workingDirectoryURL: URL
    let archiveFileURL: URL
    let suggestedFileName: String
}

/// 本地导入流程的临时票据，持有复制到沙盒后的备份文件和展示所需元信息。
struct LocalBackupImportTicket: Identifiable, Sendable {
    let workingDirectoryURL: URL
    let archiveFileURL: URL
    let fileName: String
    let backupDate: Date?
    let deviceName: String

    var id: String { archiveFileURL.path }
}

/// 备份包校验通过后的摘要信息，供导入前展示备份时间与设备来源。
struct BackupArchiveInspection: Sendable {
    let backupDate: Date?
    let deviceName: String
}

// MARK: - Backup Archive Service

/// 本地备份归档服务，负责数据库打包、解压、版本校验与恢复。
struct BackupArchiveService {
    let database: AppDatabase

    static let maxHistoryCount = 20

    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()
}

extension BackupArchiveService {
    /// 对备份包做非破坏性结构校验，确认主数据库存在且版本兼容。
    func validateBackupArchive(at archiveURL: URL) throws -> BackupArchiveInspection {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw BackupError.backupFileCorrupted
        }

        let workingDirectory = archiveURL
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        let extractDirectory = workingDirectory.appendingPathComponent("extracted")
        defer { try? fileManager.removeItem(at: workingDirectory) }

        do {
            try fileManager.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: archiveURL, to: extractDirectory)
        } catch {
            throw BackupError.unzipFailed(underlying: error)
        }

        let extractedDatabaseURL = extractDirectory.appendingPathComponent(AppDatabase.databaseName)
        guard fileManager.fileExists(atPath: extractedDatabaseURL.path) else {
            throw BackupError.backupFileCorrupted
        }

        try verifyDatabaseVersion(at: extractedDatabaseURL.path)
        try BackupSchemaValidator.prepareForRestore(at: extractedDatabaseURL.path)

        let resourceValues = try archiveURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let metadata = Self.parseLocalArchiveMetadata(
            fileName: archiveURL.lastPathComponent,
            lastModified: resourceValues.contentModificationDate,
            fileSize: Int64(resourceValues.fileSize ?? 0)
        )

        return BackupArchiveInspection(
            backupDate: metadata?.backupDate ?? resourceValues.contentModificationDate,
            deviceName: metadata?.deviceName ?? "未知设备"
        )
    }

    /// 创建统一 zip 备份包，内容仅包含数据库文件集（db/wal/shm）。
    func createBackupArchive(in directory: URL) throws -> BackupArchiveArtifact {
        let fileName = Self.makeBackupFileName()
        let archiveURL = directory.appendingPathComponent(fileName)
        let databaseURLs = existingDatabaseFileURLs()
        guard databaseURLs.contains(where: { $0.lastPathComponent == AppDatabase.databaseName }) else {
            throw BackupError.backupFileCorrupted
        }

        do {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            for databaseURL in databaseURLs {
                try archive.addEntry(
                    with: databaseURL.lastPathComponent,
                    fileURL: databaseURL
                )
            }
        } catch {
            throw BackupError.zipFailed(underlying: error)
        }

        return BackupArchiveArtifact(localFileURL: archiveURL, fileName: fileName)
    }

    /// 从统一 zip 备份包恢复数据库文件集，并基于 user_version 执行跨端版本校验。
    func restoreBackupArchive(
        from archiveURL: URL,
        databaseManager: DatabaseManager,
        progress: (@Sendable (RestoreProgress) -> Void)?
    ) throws {
        let fileManager = FileManager.default
        progress?(.verifying)

        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw BackupError.backupFileCorrupted
        }

        let workingDirectory = archiveURL
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        let extractDirectory = workingDirectory.appendingPathComponent("extracted")
        let rollbackDirectory = workingDirectory.appendingPathComponent("rollback")
        defer { try? fileManager.removeItem(at: workingDirectory) }

        progress?(.extracting)

        do {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: archiveURL, to: extractDirectory)
        } catch {
            throw BackupError.unzipFailed(underlying: error)
        }

        let extractedDatabaseURL = extractDirectory.appendingPathComponent(AppDatabase.databaseName)
        guard fileManager.fileExists(atPath: extractedDatabaseURL.path) else {
            throw BackupError.backupFileCorrupted
        }

        try verifyDatabaseVersion(at: extractedDatabaseURL.path)
        try BackupSchemaValidator.prepareForRestore(at: extractedDatabaseURL.path)

        progress?(.replacing)
        let databasePath = database.databasePath
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)

        do {
            try captureRollbackFiles(into: rollbackDirectory, databasePath: databasePath)
            try replaceDatabaseFiles(
                from: extractDirectory,
                databasePath: databasePath
            )
            try databaseManager.reopen()
            progress?(.completed)
        } catch {
            try? restoreRollbackFiles(
                from: rollbackDirectory,
                databasePath: databasePath
            )
            try? databaseManager.reopen()
            throw error
        }
    }
}

// MARK: - Helpers

extension BackupArchiveService {

    /// 统一生成云备份逻辑文件名，与 Android `StorageHelper.getCloudBackupFileName()` 对齐。
    static func makeBackupFileName(
        date: Date = Date(),
        deviceName: String = UIDevice.current.name
    ) -> String {
        let dateText = fileNameDateFormatter.string(from: date)
        let sanitizedDeviceName = deviceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "\(dateText)-\(sanitizedDeviceName)-v3"
    }

    /// 解析远端文件信息为统一 `BackupFileInfo`。
    static func parseBackupFileInfo(
        name: String,
        size: Int64,
        lastModified: Date?,
        provider: CloudBackupProvider,
        remoteIdentifier: String
    ) -> BackupFileInfo? {
        guard let stem = normalizedBackupStem(from: name) else { return nil }
        guard stem.count >= 19 else { return nil }

        let dateText = String(stem.prefix(19))
        let parsedDate = fileNameDateFormatter.date(from: dateText)
        let deviceName: String
        if stem.count > 20 {
            deviceName = String(stem.dropFirst(20))
        } else {
            deviceName = "未知设备"
        }

        return BackupFileInfo(
            id: "\(provider.rawValue)-\(remoteIdentifier)",
            name: name,
            remoteIdentifier: remoteIdentifier,
            size: size,
            lastModified: lastModified,
            deviceName: deviceName,
            backupDate: parsedDate ?? lastModified,
            provider: provider
        )
    }

    /// 兼容解析无扩展名与 `.zip` 本地导出文件名，统一提取 `-v3` 主干。
    static func normalizedBackupStem(from fileName: String) -> String? {
        let stem: String
        if fileName.lowercased().hasSuffix(".zip") {
            stem = String(fileName.dropLast(4))
        } else {
            stem = fileName
        }
        guard stem.hasSuffix("-v3") else { return nil }
        return String(stem.dropLast(3))
    }

    /// 解析本地导入文件名中的备份时间与设备信息；无法解析时返回 nil。
    static func parseLocalArchiveMetadata(
        fileName: String,
        lastModified: Date?,
        fileSize: Int64
    ) -> (backupDate: Date?, deviceName: String)? {
        guard let info = parseBackupFileInfo(
            name: fileName,
            size: fileSize,
            lastModified: lastModified,
            provider: .webdav,
            remoteIdentifier: fileName
        ) else {
            return nil
        }
        return (info.backupDate, info.deviceName)
    }
}

private extension BackupArchiveService {
    static let databaseFileSuffixes = ["", "-wal", "-shm"]

    /// 收集当前数据库目录中存在的 sqlite 文件集（db/wal/shm），用于与 Android 端对齐的备份归档。
    func existingDatabaseFileURLs() -> [URL] {
        database.databaseFiles
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 基于 SQLite `PRAGMA user_version` 校验跨端数据库版本兼容性。
    func verifyDatabaseVersion(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw BackupError.backupFileCorrupted
        }

        var databasePointer: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &databasePointer, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let databasePointer else {
            throw BackupError.backupFileCorrupted
        }
        defer { sqlite3_close(databasePointer) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(databasePointer, "PRAGMA user_version", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw BackupError.backupFileCorrupted
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BackupError.backupFileCorrupted
        }

        let backupVersion = Int(sqlite3_column_int(statement, 0))
        if backupVersion > AppDatabase.databaseVersion {
            throw BackupError.versionMismatch(
                backupVersion: backupVersion,
                appVersion: AppDatabase.databaseVersion
            )
        }
    }

    /// 在替换正式数据库前先复制一份当前 db/wal/shm，供恢复失败时回滚。
    func captureRollbackFiles(
        into directory: URL,
        databasePath: String
    ) throws {
        let fileManager = FileManager.default
        for suffix in Self.databaseFileSuffixes {
            let sourceURL = URL(fileURLWithPath: databasePath + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let destinationURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    /// 用 staging 中已校验通过的数据库文件集替换正式数据库文件。
    func replaceDatabaseFiles(
        from extractDirectory: URL,
        databasePath: String
    ) throws {
        let fileManager = FileManager.default
        try removeDatabaseFiles(at: databasePath)

        for suffix in Self.databaseFileSuffixes {
            let sourceURL = extractDirectory.appendingPathComponent(AppDatabase.databaseName + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let destinationURL = URL(fileURLWithPath: databasePath + suffix)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    /// 恢复失败时，用 rollback 目录下的文件集还原正式数据库。
    func restoreRollbackFiles(
        from rollbackDirectory: URL,
        databasePath: String
    ) throws {
        let fileManager = FileManager.default
        try removeDatabaseFiles(at: databasePath)

        for suffix in Self.databaseFileSuffixes {
            let rollbackURL = rollbackDirectory.appendingPathComponent(AppDatabase.databaseName + suffix)
            guard fileManager.fileExists(atPath: rollbackURL.path) else { continue }
            let destinationURL = URL(fileURLWithPath: databasePath + suffix)
            try fileManager.copyItem(at: rollbackURL, to: destinationURL)
        }
    }

    /// 删除正式数据库文件集，为替换或回滚准备干净目标路径。
    func removeDatabaseFiles(at databasePath: String) throws {
        let fileManager = FileManager.default
        for suffix in Self.databaseFileSuffixes {
            let fileURL = URL(fileURLWithPath: databasePath + suffix)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }
}
