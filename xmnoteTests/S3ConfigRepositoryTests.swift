import Foundation
import Testing
@testable import xmnote

@MainActor
struct S3ConfigRepositoryTests {
    @Test
    func bundledDefaultConfigResolvesFromSeedRecord() async throws {
        let harness = try Self.makeHarness()

        let configs = try await harness.repository.fetchConfigs()
        #expect(configs.count == 1)

        let config = try #require(configs.first)
        #expect(config.id == 1)
        #expect(config.isBundledDefault == true)
        #expect(config.isUsing == true)
        #expect(config.bucket == "xmnote-1252413502")
        #expect(config.region == "ap-shanghai")
        #expect(!config.secretId.isEmpty)
        #expect(!config.secretKey.isEmpty)
    }

    @Test
    func saveSelectAndFetchCurrentCustomConfig() async throws {
        let harness = try Self.makeHarness()
        let created = try await harness.repository.saveConfig(
            S3ConfigFormInput(
                bucket: "demo-1234567890",
                secretId: "secret-id",
                secretKey: "secret-key",
                region: "ap-beijing"
            ),
            editingConfig: nil
        )

        #expect(created.isBundledDefault == false)
        #expect(created.isUsing == false)

        try await harness.repository.select(created)
        let current = try await harness.repository.fetchCurrentConfig()

        let selected = try #require(current)
        #expect(selected.id == created.id)
        #expect(selected.bucket == "demo-1234567890")
        #expect(selected.region == "ap-beijing")
        #expect(selected.isUsing == true)

        let configs = try await harness.repository.fetchConfigs()
        #expect(configs.count == 2)
        #expect(configs.first?.id == created.id)
        #expect(configs.first?.isUsing == true)
        #expect(configs.last?.id == 1)
        #expect(configs.last?.isUsing == false)
    }

    @Test
    func testConnectionUsesInjectedClientFactory() async throws {
        let recorder = ConnectionRecorder()
        let repository = try Self.makeHarness { configuration in
            recorder.record(configuration)
            return ConnectionTestClient()
        }.repository

        try await repository.testConnection(
            S3ConfigFormInput(
                bucket: "demo-1234567890",
                secretId: "sid",
                secretKey: "skey",
                region: "ap-guangzhou"
            )
        )

        let configuration = try #require(recorder.configurations.first)
        #expect(configuration.bucket == "demo-1234567890")
        #expect(configuration.appID == "1234567890")
        #expect(configuration.region == "ap-guangzhou")
    }
}

private extension S3ConfigRepositoryTests {
    struct Harness {
        let repository: S3ConfigRepository
    }

    static func makeHarness(
        clientFactory: @escaping S3ConfigRepository.ClientFactory = { _ in ConnectionTestClient() }
    ) throws -> Harness {
        let database = try AppDatabase.empty()
        let manager = DatabaseManager(database: database)
        return Harness(repository: S3ConfigRepository(databaseManager: manager, clientFactory: clientFactory))
    }

    final class ConnectionTestClient: S3ObjectStorageServicing {
        func testConnection() async throws {}
        func uploadFile(localURL: URL, objectKey: String, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
            _ = (localURL, objectKey, progress)
            return URL(string: "https://example.com/mock")!
        }
        func deleteObject(objectKey: String) async throws {
            _ = objectKey
        }
        func cancelCurrentUpload() {}
    }

    final class ConnectionRecorder {
        private(set) var configurations: [S3ResolvedConfiguration] = []

        func record(_ configuration: S3ResolvedConfiguration) {
            configurations.append(configuration)
        }
    }
}
