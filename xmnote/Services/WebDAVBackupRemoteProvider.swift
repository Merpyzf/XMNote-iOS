/**
 * [INPUT]: 依赖 WebDAVClient 与 BackupService.swift 中的通用备份模型
 * [OUTPUT]: 对外提供 WebDAVBackupRemoteProvider
 * [POS]: Services 模块的 WebDAV 云备份 provider，封装目录、上传、下载与删除操作
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// WebDAV 远端 provider，兼容当前 iOS 既有目录与传输行为。
struct WebDAVBackupRemoteProvider: CloudBackupRemoteProvider {
    let provider: CloudBackupProvider = .webdav

    private let client: WebDAVClient

    static let backupDirectoryName = "纸间书摘备份"

    init(client: WebDAVClient) {
        self.client = client
    }
}

extension WebDAVBackupRemoteProvider {

    func listBackups() async throws -> [BackupFileInfo] {
        let resources: [WebDAVResource]

        do {
            resources = try await client.listDirectory(Self.backupDirectoryName)
        } catch let error as NetworkError {
            if case .notFound = error {
                return []
            }
            throw BackupError.webdavError(error)
        } catch {
            throw BackupError.webdavError(error as? NetworkError ?? .unknown(underlying: error))
        }

        return resources
            .filter { !$0.isDirectory }
            .compactMap {
                BackupArchiveService.parseBackupFileInfo(
                    name: $0.displayName,
                    size: $0.contentLength,
                    lastModified: $0.lastModified,
                    provider: provider,
                    remoteIdentifier: "\(Self.backupDirectoryName)/\($0.displayName)"
                )
            }
            .sorted { ($0.backupDate ?? .distantPast) > ($1.backupDate ?? .distantPast) }
    }

    func uploadBackup(
        localFileURL: URL,
        fileName: String,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws {
        do {
            try await client.createDirectory(Self.backupDirectoryName)
            try await client.uploadFile(
                localURL: localFileURL,
                remotePath: "\(Self.backupDirectoryName)/\(fileName)"
            ) { fraction in
                progress?(fraction)
            }
        } catch {
            throw BackupError.webdavError(error as? NetworkError ?? .unknown(underlying: error))
        }
    }

    func downloadBackup(
        _ backup: BackupFileInfo,
        to localURL: URL,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws {
        do {
            try await client.downloadFile(remotePath: backup.remoteIdentifier, to: localURL) { fraction in
                progress?(fraction)
            }
        } catch {
            throw BackupError.webdavError(error as? NetworkError ?? .unknown(underlying: error))
        }
    }

    func deleteBackup(_ backup: BackupFileInfo) async throws {
        do {
            try await client.deleteResource(backup.remoteIdentifier)
        } catch {
            throw BackupError.webdavError(error as? NetworkError ?? .unknown(underlying: error))
        }
    }
}
