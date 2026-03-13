import Foundation
import Testing
@testable import xmnote

@MainActor
struct S3UploadRepositoryTests {
    @Test
    func uploadUsesPrefixAndLocalFileExtension() async throws {
        let client = RecordingS3Client()
        let repository = S3UploadRepository(
            configRepository: CurrentConfigRepository(),
            clientFactory: { _ in client }
        )
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("cover.jpeg")
        try Data("hello".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let result = try await repository.uploadFile(localURL: localURL, prefix: "book_cover", progress: nil)

        #expect(result.objectKey.hasPrefix("book_cover_"))
        #expect(result.objectKey.hasSuffix(".jpeg"))
        #expect(client.uploadedObjectKeys == [result.objectKey])
        #expect(result.remoteURL.absoluteString == "https://example.com/\(result.objectKey)")
    }

    @Test
    func deleteParsesFullURLToObjectKey() async throws {
        let client = RecordingS3Client()
        let repository = S3UploadRepository(
            configRepository: CurrentConfigRepository(),
            clientFactory: { _ in client }
        )

        try await repository.deleteObject(path: "https://example.com/ios_test/folder/test%20file.png")

        #expect(client.deletedObjectKeys == ["ios_test/folder/test file.png"])
    }

    @Test
    func cancelForwardsToActiveClient() async throws {
        let client = HangingS3Client()
        let repository = S3UploadRepository(
            configRepository: CurrentConfigRepository(),
            clientFactory: { _ in client }
        )
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("cover.png")
        try Data("hello".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let task = Task {
            try await repository.uploadFile(localURL: localURL, prefix: "cancel", progress: nil)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        repository.cancelCurrentUpload()

        let result = await task.result
        #expect(client.cancelCalled == true)
        if case .failure(let error) = result {
            #expect((error as? S3StorageError) == .cancelled)
        } else {
            Issue.record("取消上传后应返回 cancelled 错误")
        }
    }
}

private extension S3UploadRepositoryTests {
    final class CurrentConfigRepository: S3ConfigRepositoryProtocol {
        private let current = S3Config(
            id: 1,
            bucket: "xmnote-1252413502",
            secretId: "sid",
            secretKey: "skey",
            region: "ap-shanghai",
            isUsing: true,
            isBundledDefault: true
        )

        func fetchConfigs() async throws -> [S3Config] { [current] }
        func fetchCurrentConfig() async throws -> S3Config? { current }
        func saveConfig(_ input: S3ConfigFormInput, editingConfig: S3Config?) async throws -> S3Config {
            _ = (input, editingConfig)
            return current
        }
        func delete(_ config: S3Config) async throws { _ = config }
        func select(_ config: S3Config) async throws { _ = config }
        func testConnection(_ input: S3ConfigFormInput) async throws { _ = input }
    }

    final class RecordingS3Client: S3ObjectStorageServicing {
        private(set) var uploadedObjectKeys: [String] = []
        private(set) var deletedObjectKeys: [String] = []

        func testConnection() async throws {}

        func uploadFile(localURL: URL, objectKey: String, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
            _ = localURL
            progress?(1)
            uploadedObjectKeys.append(objectKey)
            return URL(string: "https://example.com/\(objectKey)")!
        }

        func deleteObject(objectKey: String) async throws {
            deletedObjectKeys.append(objectKey)
        }

        func cancelCurrentUpload() {}
    }

    final class HangingS3Client: S3ObjectStorageServicing {
        private(set) var cancelCalled = false

        func testConnection() async throws {}

        func uploadFile(localURL: URL, objectKey: String, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
            _ = (localURL, objectKey, progress)
            try await Task.sleep(nanoseconds: 300_000_000)
            if cancelCalled {
                throw S3StorageError.cancelled
            }
            return URL(string: "https://example.com/success")!
        }

        func deleteObject(objectKey: String) async throws {
            _ = objectKey
        }

        func cancelCurrentUpload() {
            cancelCalled = true
        }
    }
}
