/**
 * [INPUT]: 依赖 Foundation 与 AWS Swift SDK（AWSS3/AWSSDKIdentity），承接 S3 解析配置并执行上传/删除/联通性校验
 * [OUTPUT]: 对外提供 S3ObjectStorageServicing 协议、S3ResolvedConfiguration 与 S3ObjectStorageService 实现
 * [POS]: Services 模块的 S3 客户端封装层，被 S3ConfigRepository 与 S3UploadRepository 作为唯一对象存储调用入口消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

#if canImport(AWSS3) && canImport(AWSSDKIdentity) && canImport(Smithy) && canImport(SmithyIdentity)
import AWSS3
import AWSSDKIdentity
import Smithy
import SmithyIdentity
#endif

/// S3 运行时客户端协议，隔离仓储层与底层 SDK 细节，便于测试替身注入。
protocol S3ObjectStorageServicing: AnyObject {
    func testConnection() async throws
    func uploadFile(localURL: URL, objectKey: String, progress: (@Sendable (Double) -> Void)?) async throws -> URL
    func deleteObject(objectKey: String) async throws
    func cancelCurrentUpload()
}

/// S3 运行时解析配置，统一校验输入并推导腾讯 COS 的 S3 兼容 endpoint。
struct S3ResolvedConfiguration: Equatable, Sendable {
    let bucket: String
    let secretId: String
    let secretKey: String
    let region: String
    let appID: String
    let endpoint: String
    let publicEndpoint: String
    let endpointURL: URL

    init(input: S3ConfigFormInput) throws {
        let normalized = input.normalized
        guard !normalized.bucket.isEmpty else {
            throw S3StorageError.invalidConfig(message: "存储桶名称不可以为空")
        }
        guard !normalized.secretId.isEmpty else {
            throw S3StorageError.invalidConfig(message: "SecretId 不可以为空")
        }
        guard !normalized.secretKey.isEmpty else {
            throw S3StorageError.invalidConfig(message: "SecretKey 不可以为空")
        }
        guard !normalized.region.isEmpty else {
            throw S3StorageError.invalidConfig(message: "地域不可以为空")
        }

        let bucketParts = normalized.bucket.split(separator: "-")
        guard let suffix = bucketParts.last, suffix.allSatisfy(\.isNumber) else {
            throw S3StorageError.invalidConfig(message: "存储桶名称格式错误，缺少 APPID 后缀")
        }

        let endpoint = "https://cos.\(normalized.region).myqcloud.com"
        guard let endpointURL = URL(string: endpoint) else {
            throw S3StorageError.invalidConfig(message: "S3 Endpoint 构造失败")
        }
        let publicEndpoint = "https://\(normalized.bucket).cos.\(normalized.region).myqcloud.com"

        bucket = normalized.bucket
        secretId = normalized.secretId
        secretKey = normalized.secretKey
        region = normalized.region
        appID = String(suffix)
        self.endpoint = endpoint
        self.publicEndpoint = publicEndpoint
        self.endpointURL = endpointURL
    }

    /// 根据对象键拼接远端访问 URL。
    func remoteURL(for objectKey: String) throws -> URL {
        let trimmedKey = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw S3StorageError.invalidConfig(message: "对象键不可以为空")
        }

        let encodedKey = trimmedKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedKey
        let base = publicEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let remoteURL = URL(string: "\(base)/\(encodedKey)") else {
            throw S3StorageError.invalidResponse
        }
        return remoteURL
    }
}

#if canImport(AWSS3) && canImport(AWSSDKIdentity) && canImport(Smithy) && canImport(SmithyIdentity)
/// 基于 AWS SDK for Swift 的 S3 兼容实现，目标后端为腾讯 COS S3 协议网关。
final class S3ObjectStorageService: S3ObjectStorageServicing {
    private final class UploadTaskBox {
        let task: Task<URL, Error>

        init(task: Task<URL, Error>) {
            self.task = task
        }
    }

    private let configuration: S3ResolvedConfiguration
    private let taskLock = NSLock()
    private var currentUploadTaskBox: UploadTaskBox?

    init(configuration: S3ResolvedConfiguration) {
        self.configuration = configuration
    }

    /// 通过上传并删除临时对象验证当前配置是否具备完整可用性。
    func testConnection() async throws {
        let testKey = "ios_test/healthcheck/\(UUID().uuidString).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("s3-health-\(UUID().uuidString).txt")
        try Data(" ".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await uploadFile(localURL: tempURL, objectKey: testKey, progress: nil)
        try await deleteObject(objectKey: testKey)
    }

    /// 上传本地文件到指定对象键。
    func uploadFile(localURL: URL, objectKey: String, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        progress?(0)

        let uploadTask = Task<URL, Error> { [configuration] in
            let client = try await Self.makeClient(configuration: configuration)
            let data = try Data(contentsOf: localURL)
            try Task.checkCancellation()

            let input = PutObjectInput(
                body: ByteStream.data(data),
                bucket: configuration.bucket,
                key: objectKey
            )
            _ = try await client.putObject(input: input)
            return try configuration.remoteURL(for: objectKey)
        }

        let taskBox = UploadTaskBox(task: uploadTask)
        storeCurrentUploadTask(taskBox)
        defer { clearCurrentUploadTask(taskBox) }

        do {
            let remoteURL = try await uploadTask.value
            progress?(1)
            return remoteURL
        } catch is CancellationError {
            throw S3StorageError.cancelled
        } catch {
            if Task.isCancelled {
                throw S3StorageError.cancelled
            }
            throw Self.mapError(error)
        }
    }

    /// 删除指定对象键，供联通性校验与功能测试回收测试文件。
    func deleteObject(objectKey: String) async throws {
        let client = try await Self.makeClient(configuration: configuration)
        let input = DeleteObjectInput(bucket: configuration.bucket, key: objectKey)

        do {
            _ = try await client.deleteObject(input: input)
        } catch is CancellationError {
            throw S3StorageError.cancelled
        } catch {
            throw Self.mapError(error)
        }
    }

    /// 取消当前正在执行的上传请求。
    func cancelCurrentUpload() {
        taskLock.lock()
        let task = currentUploadTaskBox?.task
        taskLock.unlock()
        task?.cancel()
    }
}

private extension S3ObjectStorageService {
    static func makeClient(configuration: S3ResolvedConfiguration) async throws -> S3Client {
        let credentials = AWSCredentialIdentity(
            accessKey: configuration.secretId,
            secret: configuration.secretKey
        )
        let identityResolver = StaticAWSCredentialIdentityResolver(credentials)

        var clientConfiguration = try await S3Client.S3ClientConfig(region: configuration.region)
        clientConfiguration.awsCredentialIdentityResolver = identityResolver
        clientConfiguration.endpoint = configuration.endpoint
        clientConfiguration.forcePathStyle = false
        return S3Client(config: clientConfiguration)
    }

    private func storeCurrentUploadTask(_ taskBox: UploadTaskBox) {
        taskLock.lock()
        currentUploadTaskBox = taskBox
        taskLock.unlock()
    }

    private func clearCurrentUploadTask(_ taskBox: UploadTaskBox) {
        taskLock.lock()
        defer { taskLock.unlock() }
        if let currentUploadTaskBox, currentUploadTaskBox === taskBox {
            self.currentUploadTaskBox = nil
        }
    }

    static func mapError(_ error: Error) -> Error {
        if error is S3StorageError {
            return error
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return S3StorageError.cancelled
        }
        return S3StorageError.serviceError(code: nsError.code, message: nsError.localizedDescription)
    }
}
#else
/// S3 依赖未链接时的兜底实现，避免在依赖未接入前出现静态符号缺失。
final class S3ObjectStorageService: S3ObjectStorageServicing {
    init(configuration: S3ResolvedConfiguration) {
        _ = configuration
    }

    func testConnection() async throws {
        throw S3StorageError.sdkUnavailable
    }

    func uploadFile(localURL: URL, objectKey: String, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        _ = (localURL, objectKey, progress)
        throw S3StorageError.sdkUnavailable
    }

    func deleteObject(objectKey: String) async throws {
        _ = objectKey
        throw S3StorageError.sdkUnavailable
    }

    func cancelCurrentUpload() {}
}
#endif
