/**
 * [INPUT]: 依赖 Foundation、UIKit、ZIPFoundation，依赖 AppDatabase 进行数据库操作
 * [OUTPUT]: 对外提供 BackupService 与 BackupFileInfo，封装备份打包与恢复逻辑
 * [POS]: Services 模块的备份业务服务，被 BackupRepository 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit
import ZIPFoundation

// MARK: - Data Models

struct BackupFileInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let remotePath: String
    let size: Int64
    let lastModified: Date?
    let deviceName: String
    let backupDate: Date?
}

enum BackupProgress: Equatable, Sendable {
    case preparing, packaging, uploading(Double), cleaning, completed
}

enum RestoreProgress: Equatable, Sendable {
    case downloading(Double), verifying, extracting, replacing, completed
}

enum BackupError: LocalizedError {
    case noServerConfigured
    case databaseCheckpointFailed
    case zipFailed(underlying: Error)
    case unzipFailed(underlying: Error)
    case versionMismatch(backupVersion: Int, appVersion: Int)
    case backupFileCorrupted
    case webdavError(NetworkError)

    var errorDescription: String? {
        switch self {
        case .noServerConfigured:
            return "未配置备份服务器"
        case .databaseCheckpointFailed:
            return "数据库 checkpoint 失败"
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
        }
    }
}

// MARK: - BackupService

struct BackupService: Sendable {
    let database: AppDatabase
    let client: WebDAVClient

    static let backupDirName = "纸间书摘备份"
    static let maxHistoryCount = 20

    private static let fileNameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return f
    }()
}

// MARK: - 备份

extension BackupService {

    func backup(progress: (@Sendable (BackupProgress) -> Void)?) async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // 1. Checkpoint
        progress?(.preparing)
        do {
            try database.checkpoint()
        } catch {
            throw BackupError.databaseCheckpointFailed
        }

        // 2. 打包 ZIP
        progress?(.packaging)
        let deviceName = await UIDevice.current.name
            .replacingOccurrences(of: " ", with: "_")
        let dateStr = Self.fileNameDateFormatter.string(from: Date())
        let backupName = "\(dateStr)-\(deviceName)-v3"
        let zipURL = tmpDir.appendingPathComponent("\(backupName).zip")

        do {
            let archive = try Archive(url: zipURL, accessMode: .create)
            let dbPath = database.databasePath
            try archive.addEntry(with: AppDatabase.databaseName,
                                 fileURL: URL(fileURLWithPath: dbPath))
        } catch {
            throw BackupError.zipFailed(underlying: error)
        }

        // 3. 确保远程目录存在
        progress?(.uploading(0))
        do {
            try await client.createDirectory(Self.backupDirName)
        } catch {
            throw BackupError.webdavError(error as? NetworkError ?? .unknown(underlying: error))
        }

        // 4. 上传
        let remotePath = "\(Self.backupDirName)/\(backupName)"
        do {
            try await client.uploadFile(localURL: zipURL, remotePath: remotePath) { fraction in
                progress?(.uploading(fraction))
            }
        } catch {
            throw BackupError.webdavError(error as? NetworkError ?? .unknown(underlying: error))
        }

        // 5. 清理旧备份
        progress?(.cleaning)
        await cleanOldBackups()

        progress?(.completed)
    }
}

// MARK: - 备份列表

extension BackupService {

    func fetchBackupList() async throws -> [BackupFileInfo] {
        let resources: [WebDAVResource]
        do {
            resources = try await client.listDirectory(Self.backupDirName)
        } catch {
            throw BackupError.webdavError(error as? NetworkError ?? .unknown(underlying: error))
        }

        #if DEBUG
        print("[Backup] Resources count: \(resources.count)")
        for r in resources {
            print("[Backup]   href=\(r.href) name=\(r.displayName) isDir=\(r.isDirectory) size=\(r.contentLength)")
        }
        #endif

        let result = resources
            .filter { !$0.isDirectory && $0.displayName.hasSuffix("-v3") }
            .compactMap { Self.parseBackupFileInfo(from: $0) }
            .sorted { ($0.backupDate ?? .distantPast) > ($1.backupDate ?? .distantPast) }

        #if DEBUG
        print("[Backup] After filter: \(result.count) items")
        #endif

        return result
    }
}

// MARK: - 恢复

extension BackupService {

    func restore(_ backup: BackupFileInfo,
                 databaseManager: DatabaseManager,
                 progress: (@Sendable (RestoreProgress) -> Void)?) async throws {
        #if DEBUG
        print("[Restore] 开始恢复: \(backup.name)")
        #endif

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // 1. 下载
        #if DEBUG
        print("[Restore] Step 1: 开始下载")
        #endif
        let zipURL = tmpDir.appendingPathComponent(backup.name)
        do {
            try await client.downloadFile(remotePath: backup.remotePath, to: zipURL) { fraction in
                progress?(.downloading(fraction))
            }
        } catch {
            #if DEBUG
            print("[Restore] Step 1 失败: \(error)")
            #endif
            throw BackupError.webdavError(error as? NetworkError ?? .unknown(underlying: error))
        }
        #if DEBUG
        print("[Restore] Step 1 完成: 文件大小 \(try? fm.attributesOfItem(atPath: zipURL.path)[.size] ?? 0)")
        #endif

        // 2. 校验 ZIP
        #if DEBUG
        print("[Restore] Step 2: 校验 ZIP")
        #endif
        progress?(.verifying)
        guard fm.fileExists(atPath: zipURL.path) else {
            #if DEBUG
            print("[Restore] Step 2 失败: ZIP 文件不存在")
            #endif
            throw BackupError.backupFileCorrupted
        }

        // 3. 解压
        #if DEBUG
        print("[Restore] Step 3: 开始解压")
        #endif
        progress?(.extracting)
        let extractDir = tmpDir.appendingPathComponent("extracted")
        do {
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try fm.unzipItem(at: zipURL, to: extractDir)
        } catch {
            #if DEBUG
            print("[Restore] Step 3 失败: \(error)")
            #endif
            throw BackupError.unzipFailed(underlying: error)
        }
        #if DEBUG
        print("[Restore] Step 3 完成")
        #endif

        // 4. 校验数据库版本
        #if DEBUG
        print("[Restore] Step 4: 校验数据库版本")
        #endif
        let extractedDB = extractDir.appendingPathComponent(AppDatabase.databaseName)
        guard fm.fileExists(atPath: extractedDB.path) else {
            #if DEBUG
            print("[Restore] Step 4 失败: 数据库文件不存在")
            #endif
            throw BackupError.backupFileCorrupted
        }
        try verifyDatabaseVersion(at: extractedDB.path)
        #if DEBUG
        print("[Restore] Step 4 完成")
        #endif

        // 5. 替换数据库文件
        #if DEBUG
        print("[Restore] Step 5: 替换数据库文件")
        #endif
        progress?(.replacing)

        let dbPath = database.databasePath
        let dbURL = URL(fileURLWithPath: dbPath)

        // 移除现有数据库文件（主文件 + WAL + SHM）
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: dbPath + suffix)
            try? fm.removeItem(at: fileURL)
        }

        // 复制恢复的数据库
        try fm.copyItem(at: extractedDB, to: dbURL)
        #if DEBUG
        print("[Restore] Step 5 完成: \(dbPath)")
        #endif

        // 6. 热重载
        #if DEBUG
        print("[Restore] Step 6: 热重载数据库")
        #endif
        try databaseManager.reopen()
        #if DEBUG
        print("[Restore] Step 6 完成")
        #endif

        progress?(.completed)
        #if DEBUG
        print("[Restore] 恢复流程全部完成")
        #endif
    }
}

// MARK: - 辅助方法

private extension BackupService {

    /// 清理超出上限的旧备份
    func cleanOldBackups() async {
        guard let list = try? await fetchBackupList(),
              list.count > Self.maxHistoryCount else { return }

        let toDelete = list.suffix(from: Self.maxHistoryCount)
        for file in toDelete {
            try? await client.deleteResource(file.remotePath)
        }
    }

    /// 校验备份数据库版本（通过 SQLite PRAGMA）
    func verifyDatabaseVersion(at path: String) throws {
        guard let data = FileManager.default.contents(atPath: path),
              data.count > 100 else {
            throw BackupError.backupFileCorrupted
        }
        // 简单校验：SQLite 文件头 "SQLite format 3\000"
        let header = String(data: data.prefix(16), encoding: .utf8) ?? ""
        guard header.hasPrefix("SQLite format 3") else {
            throw BackupError.backupFileCorrupted
        }
    }

    /// 从 WebDAVResource 解析 BackupFileInfo
    ///
    /// 文件名格式：{yyyy-MM-dd-HH-mm-ss}-{device}-v3
    /// 示例：2025-12-22-03-51-50-lynx-v3
    static func parseBackupFileInfo(from resource: WebDAVResource) -> BackupFileInfo? {
        let name = resource.displayName
        guard name.hasSuffix("-v3") else { return nil }

        // 去掉 "-v3" 后缀
        let stem = String(name.dropLast(3))
        // 日期部分固定 19 字符：yyyy-MM-dd-HH-mm-ss
        guard stem.count >= 19 else { return nil }

        let dateStr = String(stem.prefix(19))
        let backupDate = fileNameDateFormatter.date(from: dateStr)

        var deviceName = "未知设备"
        // 日期后如果还有 "-xxx" 就是设备名
        if stem.count > 20 {
            deviceName = String(stem.dropFirst(20))
        }

        return BackupFileInfo(
            id: resource.href,
            name: name,
            remotePath: "\(backupDirName)/\(name)",
            size: resource.contentLength,
            lastModified: resource.lastModified,
            deviceName: deviceName,
            backupDate: backupDate ?? resource.lastModified
        )
    }
}
