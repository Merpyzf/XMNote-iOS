/**
 * [INPUT]: 依赖 WebDAVServerViewModel 与可脚本化 BackupServerRepositoryProtocol 测试替身
 * [OUTPUT]: 验证首次失败、真实空数据与保留列表操作失败的状态语义
 * [POS]: xmnoteTests 的 WebDAV 设置状态回归测试，保护列表不被失败空态覆盖
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Testing
@testable import xmnote

@MainActor
struct WebDAVServerStateTests {
    @Test
    func initialFailureAndSuccessfulEmptyDataRemainDistinct() async {
        let repository = ScriptedBackupServerRepository(fetchSteps: [.failure, .success([])])
        let viewModel = WebDAVServerViewModel(repository: repository)

        await viewModel.loadServers()
        #expect(viewModel.loadPhase == .failure)
        #expect(viewModel.loadErrorMessage != nil)
        #expect(viewModel.servers.isEmpty)

        await viewModel.loadServers()
        #expect(viewModel.loadPhase == .content)
        #expect(viewModel.loadErrorMessage == nil)
        #expect(viewModel.servers.isEmpty)
    }

    @Test
    func deleteFailureKeepsTrustedServerList() async {
        let server = Self.server()
        let repository = ScriptedBackupServerRepository(
            fetchSteps: [.success([server])],
            shouldFailDelete: true
        )
        let viewModel = WebDAVServerViewModel(repository: repository)

        await viewModel.loadServers()
        await viewModel.delete(server)

        #expect(viewModel.loadPhase == .content)
        #expect(viewModel.servers.map(\.id) == [server.id])
        #expect(viewModel.operationErrorMessage == "删除失败，请重试")
    }

    private static func server() -> BackupServerRecord {
        var server = BackupServerRecord()
        server.id = 1
        server.title = "坚果云"
        server.serverAddress = "https://dav.example.com"
        server.account = "tester"
        server.password = "secret"
        server.isUsing = 1
        return server
    }
}

private final class ScriptedBackupServerRepository: BackupServerRepositoryProtocol, @unchecked Sendable {
    enum FetchStep {
        case success([BackupServerRecord])
        case failure
    }

    private var fetchSteps: [FetchStep]
    private let shouldFailDelete: Bool

    init(fetchSteps: [FetchStep], shouldFailDelete: Bool = false) {
        self.fetchSteps = fetchSteps
        self.shouldFailDelete = shouldFailDelete
    }

    func fetchServers() async throws -> [BackupServerRecord] {
        let step = fetchSteps.isEmpty ? .success([]) : fetchSteps.removeFirst()
        switch step {
        case .success(let servers):
            return servers
        case .failure:
            throw StubBackupServerError.failed
        }
    }

    func fetchCurrentServer() async throws -> BackupServerRecord? { nil }

    func saveServer(
        _ input: BackupServerFormInput,
        editingServer: BackupServerRecord?
    ) async throws {}

    func delete(_ server: BackupServerRecord) async throws {
        if shouldFailDelete {
            throw StubBackupServerError.failed
        }
    }

    func select(_ server: BackupServerRecord) async throws {}

    func testConnection(_ input: BackupServerFormInput) async throws {}
}

private enum StubBackupServerError: Error {
    case failed
}
