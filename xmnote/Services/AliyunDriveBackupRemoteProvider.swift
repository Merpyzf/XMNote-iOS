/**
 * [INPUT]: 依赖 AliyunpanSDK、BackupService.swift 中的通用备份模型
 * [OUTPUT]: 对外提供阿里云盘开放平台配置与 AliyunDriveBackupRemoteProvider
 * [POS]: Services 模块的阿里云盘云备份 provider，封装鉴权、账号信息与远端文件操作
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import AliyunpanSDK
import Foundation

/// 阿里云盘开放平台配置，默认复用 Android 端线上值，并允许通过 Info.plist 覆盖。
struct AliyunDriveOpenPlatformConfiguration {
    static let defaultAppId = "e2e4452a2d2144a1b45c4ae31e80af5c"
    static let defaultScope = "user:base,file:all:read,file:all:write"

    let appId: String
    let scope: String

    init(bundle: Bundle = .main) throws {
        let info = bundle.infoDictionary ?? [:]
        let appId = (info["AliyunpanAppID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = (info["AliyunpanScope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedAppId = appId?.isEmpty == false ? appId! : Self.defaultAppId
        let resolvedScope = scope?.isEmpty == false ? scope! : Self.defaultScope

        guard !resolvedAppId.isEmpty, !resolvedScope.isEmpty else {
            throw BackupError.invalidAliyunDriveConfiguration
        }

        self.appId = resolvedAppId
        self.scope = resolvedScope
    }
}

/// 阿里云盘远端 provider，同时负责登录态探测与账号信息读取。
final class AliyunDriveBackupRemoteProvider: CloudBackupRemoteProvider {
    let provider: CloudBackupProvider = .aliyunDrive

    private let configuration: AliyunDriveOpenPlatformConfiguration
    private let client: AliyunpanClient

    private static let appDirectoryName = "纸间书摘"

    init(configuration: AliyunDriveOpenPlatformConfiguration) {
        self.configuration = configuration
        self.client = AliyunpanClient(appId: configuration.appId, scope: configuration.scope)
    }
}

// MARK: - Authorization

extension AliyunDriveBackupRemoteProvider {

    /// 发起 PKCE 授权流程；若本地 token 未过期，SDK 会直接复用。
    func authorize() async throws {
        do {
            _ = try await client.authorize(credentials: .pkce)
        } catch {
            throw mapAliyunError(error)
        }
    }

    /// 清除 SDK 持久化 token，立即回到未授权状态。
    func revokeAuthorization() async {
        await MainActor.run {
            client.cleanToken()
        }
    }

    /// 返回当前是否存在可继续使用的本地授权信息。
    func hasAuthorizedSession() async -> Bool {
        await hasLocalToken()
    }

    /// 读取当前授权账号信息；token 无效时自动清除并返回 nil。
    func fetchAccountInfo() async throws -> CloudBackupAccountInfo? {
        guard await hasLocalToken() else { return nil }

        do {
            async let userInfoResponse = client.send(AliyunpanScope.User.GetUsersInfo())
            async let spaceInfoResponse = client.send(AliyunpanScope.User.GetSpaceInfo())

            let userInfo = try await userInfoResponse
            let spaceInfo = try await spaceInfoResponse

            return CloudBackupAccountInfo(
                userId: userInfo.id,
                nickName: userInfo.name,
                avatarURL: userInfo.avatar,
                usedSpace: spaceInfo.personal_space_info.used_size,
                totalSpace: spaceInfo.personal_space_info.total_size
            )
        } catch {
            if isAuthorizationFailure(error) {
                await revokeAuthorization()
                return nil
            }
            throw mapAliyunError(error)
        }
    }
}

// MARK: - Remote Operations

extension AliyunDriveBackupRemoteProvider {

    func listBackups() async throws -> [BackupFileInfo] {
        guard await hasLocalToken() else {
            throw BackupError.noAliyunDriveAuthorized
        }

        let driveId = try await fetchDefaultDriveId()
        guard let folderId = try await resolveAppDirectoryId(driveId: driveId, createIfMissing: false) else {
            return []
        }

        let files = try await fetchAllFiles(driveId: driveId, parentFileId: folderId)
        return files
            .filter { !$0.isFolder }
            .compactMap {
                BackupArchiveService.parseBackupFileInfo(
                    name: $0.name,
                    size: $0.size ?? 0,
                    lastModified: $0.updated_at ?? $0.created_at,
                    provider: provider,
                    remoteIdentifier: $0.file_id
                )
            }
            .sorted { ($0.backupDate ?? .distantPast) > ($1.backupDate ?? .distantPast) }
    }

    func uploadBackup(
        localFileURL: URL,
        fileName: String,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws {
        guard await hasLocalToken() else {
            throw BackupError.noAliyunDriveAuthorized
        }

        let driveId = try await fetchDefaultDriveId()
        let folderId = try await resolveAppDirectoryId(driveId: driveId, createIfMissing: true)
        progress?(nil)

        do {
            _ = try await client.uploader.upload(
                fileURL: localFileURL,
                fileName: fileName,
                driveId: driveId,
                folderId: folderId ?? "root",
                checkNameMode: .ignore,
                useProof: false
            )
            progress?(1)
        } catch {
            throw mapAliyunError(error)
        }
    }

    func downloadBackup(
        _ backup: BackupFileInfo,
        to localURL: URL,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws {
        guard await hasLocalToken() else {
            throw BackupError.noAliyunDriveAuthorized
        }

        let driveId = try await fetchDefaultDriveId()
        progress?(nil)

        do {
            let response = try await client.send(
                AliyunpanScope.File.GetFileDownloadUrl(
                    .init(drive_id: driveId, file_id: backup.remoteIdentifier)
                )
            )
            let (temporaryURL, _) = try await URLSession.shared.download(from: response.url)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.copyItem(at: temporaryURL, to: localURL)
            progress?(1)
        } catch {
            throw mapAliyunError(error)
        }
    }

    func deleteBackup(_ backup: BackupFileInfo) async throws {
        guard await hasLocalToken() else {
            throw BackupError.noAliyunDriveAuthorized
        }

        let driveId = try await fetchDefaultDriveId()
        do {
            _ = try await client.send(
                AliyunpanScope.File.DeleteFile(
                    .init(drive_id: driveId, file_id: backup.remoteIdentifier)
                )
            )
        } catch {
            throw mapAliyunError(error)
        }
    }
}

// MARK: - Internals

private extension AliyunDriveBackupRemoteProvider {

    func hasLocalToken() async -> Bool {
        await MainActor.run {
            guard let accessToken = client.accessToken else { return false }
            return accessToken.isEmpty == false
        }
    }

    func fetchDefaultDriveId() async throws -> String {
        do {
            let response = try await client.send(AliyunpanScope.User.GetDriveInfo())
            return response.default_drive_id
        } catch {
            throw mapAliyunError(error)
        }
    }

    func resolveAppDirectoryId(
        driveId: String,
        createIfMissing: Bool
    ) async throws -> String? {
        let rootFiles = try await fetchAllFiles(driveId: driveId, parentFileId: "root")
        if let existingFolder = rootFiles.first(where: { $0.isFolder && $0.name == Self.appDirectoryName }) {
            return existingFolder.file_id
        }

        guard createIfMissing else { return nil }

        do {
            let response = try await client.send(
                AliyunpanScope.File.CreateFile(
                    .init(
                        drive_id: driveId,
                        parent_file_id: "root",
                        name: Self.appDirectoryName,
                        type: .folder,
                        check_name_mode: .refuse
                    )
                )
            )
            return response.file_id
        } catch {
            throw mapAliyunError(error)
        }
    }

    func fetchAllFiles(
        driveId: String,
        parentFileId: String
    ) async throws -> [AliyunpanFile] {
        var allFiles: [AliyunpanFile] = []
        var marker: String?

        repeat {
            do {
                let response = try await client.send(
                    AliyunpanScope.File.GetFileList(
                        .init(
                            drive_id: driveId,
                            parent_file_id: parentFileId,
                            limit: 100,
                            marker: marker,
                            order_by: .updated_at,
                            order_direction: .desc
                        )
                    )
                )
                allFiles.append(contentsOf: response.items)
                marker = response.next_marker?.isEmpty == true ? nil : response.next_marker
            } catch {
                throw mapAliyunError(error)
            }
        } while marker != nil

        return allFiles
    }

    func isAuthorizationFailure(_ error: Error) -> Bool {
        if let error = error as? BackupError,
           case .noAliyunDriveAuthorized = error {
            return true
        }

        if let authorizeError = error as? AliyunpanError.AuthorizeError {
            switch authorizeError {
            case .accessTokenInvalid, .invalidCode, .authorizeFailed:
                return true
            default:
                return false
            }
        }

        if let serverError = error as? AliyunpanError.ServerError {
            return serverError.isAccessTokenInvalidOrExpired || serverError.code == .permissionDenied
        }

        return false
    }

    func mapAliyunError(_ error: Error) -> BackupError {
        if let backupError = error as? BackupError {
            return backupError
        }

        if let authorizeError = error as? AliyunpanError.AuthorizeError {
            switch authorizeError {
            case .accessTokenInvalid, .invalidCode:
                return .noAliyunDriveAuthorized
            case .authorizeFailed(let error, let errorMessage):
                let message = errorMessage ?? error ?? "阿里云盘授权失败"
                return .aliyunDriveError(message: message)
            case .notInstalledApp:
                return .aliyunDriveError(message: "未检测到阿里云盘客户端")
            case .invalidAuthorizeURL:
                return .aliyunDriveError(message: "阿里云盘授权链接无效")
            case .invalidPlatform:
                return .aliyunDriveError(message: "当前平台不支持阿里云盘授权")
            case .qrCodeAuthorizeTimeout:
                return .aliyunDriveError(message: "阿里云盘授权超时")
            }
        }

        if let serverError = error as? AliyunpanError.ServerError {
            if serverError.isAccessTokenInvalidOrExpired || serverError.code == .permissionDenied {
                return .noAliyunDriveAuthorized
            }
            return .aliyunDriveError(message: serverError.message ?? serverError.code.rawValue)
        }

        if let downloadError = error as? AliyunpanError.DownloadError {
            switch downloadError {
            case .downloadURLExpired:
                return .aliyunDriveError(message: "阿里云盘下载链接已过期")
            case .invalidDownloadURL:
                return .aliyunDriveError(message: "阿里云盘下载链接无效")
            case .userCancelled:
                return .aliyunDriveError(message: "下载已取消")
            case .invalidClient, .serverError, .unknownError:
                return .aliyunDriveError(message: "阿里云盘下载失败")
            }
        }

        if error is AliyunpanError.UploadError {
            return .aliyunDriveError(message: "阿里云盘上传失败")
        }

        if let networkError = error as? URLError {
            return .aliyunDriveError(message: networkError.localizedDescription)
        }

        return .aliyunDriveError(message: error.localizedDescription)
    }
}
