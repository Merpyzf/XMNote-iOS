/**
 * [INPUT]: 依赖 Kindle 文件读取 Repository、统一网关、可控文件 Loader 与临时文件
 * [OUTPUT]: 验证两种入口复用、文件名/32 MiB 约束、取消与临时文件精确清理
 * [POS]: xmnoteTests 的 Kindle 数据线/系统文件入口门禁
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Testing
@testable import xmnote

@MainActor
struct KindleImportGatewayTests {
    @Test
    func connectedAndManualEntriesUseSameLoaderAndParser() async throws {
        let loader = KindleFileLoaderProbe(data: Data(validClippings.utf8))
        let gateway = DefaultKindleImportGateway(fileLoader: loader)
        let url = URL(fileURLWithPath: "/fixture/My Clippings.txt")

        let connected = try await gateway.parse(url: url, entryPoint: .connectedDevice)
        let manual = try await gateway.parse(url: url, entryPoint: .manualFile)

        #expect(loader.requestedURLs == [url, url])
        #expect(connected == manual)
        #expect(connected.singleOrNil?.source == 2)
        #expect(connected.singleOrNil?.notes.singleOrNil?.content == "正文")
    }

    @Test
    func gatewayRejectsAFileThatIsNotMyClippings() async throws {
        let loader = KindleFileLoaderProbe(data: Data(validClippings.utf8))
        let gateway = DefaultKindleImportGateway(fileLoader: loader)

        await #expect(throws: KindleImportFileError.invalidFileName) {
            try await gateway.parse(
                url: URL(fileURLWithPath: "/fixture/notes.txt"),
                entryPoint: .manualFile
            )
        }
        #expect(loader.requestedURLs.isEmpty)
    }

    @Test
    func repositoryRejectsFilesOver32MiBWithoutLeakingOwnedTemporaryFiles() async throws {
        let source = temporaryURL(named: "My Clippings.txt")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(32 * 1_024 * 1_024 + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: source) }
        let before = ownedTemporaryFiles()
        let repository = try makeRepository()

        await #expect(throws: KindleImportFileError.fileTooLarge) {
            _ = try await repository.loadKindleClippingsFile(from: source)
        }

        #expect(ownedTemporaryFiles() == before)
    }

    @Test
    func cancelledReadDoesNotLeaveAnOwnedTemporaryFile() async throws {
        let source = temporaryURL(named: "My Clippings.txt")
        let payload = Data(repeating: 0x41, count: 32 * 1_024 * 1_024)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let before = ownedTemporaryFiles()
        let repository = try makeRepository()

        let task = Task { try await repository.loadKindleClippingsFile(from: source) }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(ownedTemporaryFiles() == before)
    }

    private func makeRepository() throws -> NoteImportRepository {
        NoteImportRepository(
            databaseManager: DatabaseManager(database: try AppDatabase.empty()),
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func ownedTemporaryFiles() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(files.map(\.lastPathComponent).filter { $0.hasPrefix("xmnote-kindle-import-") })
    }

    private var validClippings: String {
        [
            "测试书 (作者)",
            "- Your Highlight on Location 1 | Added on Thursday, April 2, 2026 8:19:38 PM",
            "",
            "正文",
            "=========="
        ].joined(separator: "\n")
    }
}

@MainActor
private final class KindleFileLoaderProbe: KindleImportFileLoading {
    let data: Data
    private(set) var requestedURLs: [URL] = []

    init(data: Data) {
        self.data = data
    }

    func loadKindleClippingsFile(from url: URL) async throws -> Data {
        requestedURLs.append(url)
        return data
    }
}

private extension Array {
    var singleOrNil: Element? { count == 1 ? first : nil }
}
