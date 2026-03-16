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

// MARK: - Backup Archive Service

/// 本地备份归档服务，负责数据库打包、解压、版本校验与恢复。
struct BackupArchiveService {
    let database: AppDatabase

    static let maxHistoryCount = 20
    static let androidPreferencesFileName = "com.merpyzf.xmnote_preferences.xml"

    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()
}

extension BackupArchiveService {

    /// 创建统一 zip 备份包，内容为数据库文件集（db/wal/shm）与 Android 兼容占位偏好文件。
    func createBackupArchive(in directory: URL) throws -> BackupArchiveArtifact {
        let fileName = Self.makeBackupFileName()
        let archiveURL = directory.appendingPathComponent(fileName)
        let preferencesURL = directory.appendingPathComponent(Self.androidPreferencesFileName)
        let databaseURLs = existingDatabaseFileURLs()
        guard databaseURLs.contains(where: { $0.lastPathComponent == AppDatabase.databaseName }) else {
            throw BackupError.backupFileCorrupted
        }

        do {
            try createAndroidPreferencesPlaceholder(at: preferencesURL)
            let archive = try Archive(url: archiveURL, accessMode: .create)
            for databaseURL in databaseURLs {
                try archive.addEntry(
                    with: databaseURL.lastPathComponent,
                    fileURL: databaseURL
                )
            }
            try archive.addEntry(
                with: Self.androidPreferencesFileName,
                fileURL: preferencesURL
            )
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

        progress?(.extracting)
        let extractDirectory = archiveURL.deletingLastPathComponent().appendingPathComponent("extracted")

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

        progress?(.replacing)
        let databasePath = database.databasePath
        let databaseURL = URL(fileURLWithPath: databasePath)
        let extractedWalURL = extractDirectory.appendingPathComponent("\(AppDatabase.databaseName)-wal")
        let extractedShmURL = extractDirectory.appendingPathComponent("\(AppDatabase.databaseName)-shm")

        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: databasePath + suffix)
            try? fileManager.removeItem(at: fileURL)
        }

        try fileManager.copyItem(at: extractedDatabaseURL, to: databaseURL)
        if fileManager.fileExists(atPath: extractedWalURL.path) {
            try fileManager.copyItem(at: extractedWalURL, to: URL(fileURLWithPath: "\(databasePath)-wal"))
        }
        if fileManager.fileExists(atPath: extractedShmURL.path) {
            try fileManager.copyItem(at: extractedShmURL, to: URL(fileURLWithPath: "\(databasePath)-shm"))
        }
        try databaseManager.reopen()
        progress?(.completed)
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
        guard name.hasSuffix("-v3") else { return nil }
        let stem = String(name.dropLast(3))
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
}

private extension BackupArchiveService {

    /// 收集当前数据库目录中存在的 sqlite 文件集（db/wal/shm），用于与 Android 端对齐的备份归档。
    func existingDatabaseFileURLs() -> [URL] {
        database.databaseFiles
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 写入 Android 兼容占位偏好文件，保证 Android 恢复流程不因缺少 SP 文件失败。
    func createAndroidPreferencesPlaceholder(at url: URL) throws {
        let content = """
        <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
        <map />
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
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
}
