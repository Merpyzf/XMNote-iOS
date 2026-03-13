import Foundation
import Testing
@testable import xmnote

@MainActor
struct S3LiveIntegrationTests {
    @Test
    func bundledDefaultConfigPassesLiveConnectionTest() async throws {
        let repository = try Self.makeUploadRepository()
        try await repository.testCurrentConfiguration()
    }

    @Test
    func uploadAndDeleteRoundTripAgainstLiveS3Endpoint() async throws {
        let repository = try Self.makeUploadRepository()
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("s3-live-\(UUID().uuidString).png")
        try Data("xmnote-live-test".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let result = try await repository.uploadFile(localURL: localURL, prefix: "ios_test", progress: nil)

        #expect(result.objectKey.hasPrefix("ios_test_"))
        #expect(result.remoteURL.absoluteString.contains(result.objectKey))

        try await repository.deleteObject(path: result.objectKey)
    }
}

private extension S3LiveIntegrationTests {
    static func makeUploadRepository() throws -> S3UploadRepository {
        let database = try AppDatabase.empty()
        let manager = DatabaseManager(database: database)
        let configRepository = S3ConfigRepository(databaseManager: manager)
        return S3UploadRepository(configRepository: configRepository)
    }
}
