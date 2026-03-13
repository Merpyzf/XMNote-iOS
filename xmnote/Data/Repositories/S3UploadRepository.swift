import Foundation

/**
 * [INPUT]: 依赖 S3ConfigRepositoryProtocol 提供当前启用配置，依赖 S3ObjectStorageServicing 执行真实上传/删除动作
 * [OUTPUT]: 对外提供 S3UploadRepository（S3UploadRepositoryProtocol 的实现）
 * [POS]: Data 层 S3 上传仓储，统一封装对象键生成、当前客户端生命周期与路径删除能力
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// S3 上传仓储实现，负责在当前配置上下文中执行上传、校验、删除与取消。
final class S3UploadRepository: S3UploadRepositoryProtocol {
    typealias ClientFactory = (S3ResolvedConfiguration) -> any S3ObjectStorageServicing

    private let configRepository: any S3ConfigRepositoryProtocol
    private let clientFactory: ClientFactory
    private let clientLock = NSLock()
    private var activeClient: (any S3ObjectStorageServicing)?

    init(
        configRepository: any S3ConfigRepositoryProtocol,
        clientFactory: @escaping ClientFactory = { S3ObjectStorageService(configuration: $0) }
    ) {
        self.configRepository = configRepository
        self.clientFactory = clientFactory
    }

    /// 使用当前启用配置上传本地文件，并按 Android 规则生成对象键。
    func uploadFile(localURL: URL, prefix: String, progress: (@Sendable (Double) -> Void)?) async throws -> S3UploadResult {
        let config = try await requireCurrentConfig()
        let client = try makeClient(from: config)
        let objectKey = Self.makeObjectKey(prefix: prefix, localURL: localURL)
        setActiveClient(client)
        defer { clearActiveClient(client) }

        let remoteURL = try await client.uploadFile(localURL: localURL, objectKey: objectKey, progress: progress)
        return S3UploadResult(objectKey: objectKey, remoteURL: remoteURL)
    }

    /// 对当前启用配置执行联通性校验，用于真实功能测试与配置健康检查。
    func testCurrentConfiguration() async throws {
        let config = try await requireCurrentConfig()
        let client = try makeClient(from: config)
        try await client.testConnection()
    }

    /// 删除指定对象路径；传入完整 URL 时会自动解析成对象键。
    func deleteObject(path: String) async throws {
        let config = try await requireCurrentConfig()
        let client = try makeClient(from: config)
        let objectKey = Self.objectKey(from: path)
        try await client.deleteObject(objectKey: objectKey)
    }

    /// 转发取消信号到当前正在执行上传的 S3 客户端。
    func cancelCurrentUpload() {
        clientLock.lock()
        let client = activeClient
        clientLock.unlock()
        client?.cancelCurrentUpload()
    }
}

private extension S3UploadRepository {
    func requireCurrentConfig() async throws -> S3Config {
        guard let config = try await configRepository.fetchCurrentConfig() else {
            throw S3StorageError.noConfigConfigured
        }
        return config
    }

    func makeClient(from config: S3Config) throws -> any S3ObjectStorageServicing {
        let input = S3ConfigFormInput(
            bucket: config.bucket,
            secretId: config.secretId,
            secretKey: config.secretKey,
            region: config.region
        )
        return clientFactory(try S3ResolvedConfiguration(input: input))
    }

    func setActiveClient(_ client: any S3ObjectStorageServicing) {
        clientLock.lock()
        activeClient = client
        clientLock.unlock()
    }

    func clearActiveClient(_ client: any S3ObjectStorageServicing) {
        clientLock.lock()
        defer { clientLock.unlock() }
        if let activeClient,
           ObjectIdentifier(activeClient as AnyObject) == ObjectIdentifier(client as AnyObject) {
            self.activeClient = nil
        }
    }

    static func objectKey(from path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return trimmed
        }
        let objectKey = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return objectKey.removingPercentEncoding ?? objectKey
    }

    static func makeObjectKey(prefix: String, localURL: URL) -> String {
        let sanitizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExtension = localURL.pathExtension.isEmpty ? "png" : localURL.pathExtension.lowercased()
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if sanitizedPrefix.isEmpty {
            return "\(uuid).\(fileExtension)"
        }
        return "\(sanitizedPrefix)_\(uuid).\(fileExtension)"
    }
}

extension S3UploadRepository {
    nonisolated static func testingMakeObjectKey(prefix: String, localURL: URL) -> String {
        makeObjectKey(prefix: prefix, localURL: localURL)
    }

    nonisolated static func testingObjectKey(from path: String) -> String {
        objectKey(from: path)
    }
}
