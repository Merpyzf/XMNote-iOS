import Foundation

/**
 * [INPUT]: 依赖 BackupServerRepositoryProtocol 提供服务器列表、CRUD 与连接测试
 * [OUTPUT]: 对外提供 WebDAVServerViewModel，驱动服务器管理页状态与表单行为
 * [POS]: Backup 模块服务器状态编排器，被 WebDAVServerListView/WebDAVServerFormView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@Observable
class WebDAVServerViewModel {
    var servers: [BackupServerRecord] = []
    var isShowingForm = false
    var editingServer: BackupServerRecord?

    // 表单字段
    var formTitle = "坚果云"
    var formAddress = "https://dav.jianguoyun.com/dav/"
    var formAccount = "1052060838@qq.com"
    var formPassword = "a8v5epxeu8ms7zmd"

    // 连接测试
    var isTesting = false
    var testResultMessage: String?

    // 列表操作加载态（select / delete）
    var isProcessing = false

    // 通知外部数据变更
    var serverDidChange = false

    private let repository: any BackupServerRepositoryProtocol
    private var lastValidatedInput: BackupServerFormInput?

    init(repository: any BackupServerRepositoryProtocol) {
        self.repository = repository
    }
}

// MARK: - Data Loading

extension WebDAVServerViewModel {

    func loadServers() async {
        do {
            servers = try await repository.fetchServers()
        } catch {
            servers = []
        }
    }
}

// MARK: - 表单操作

extension WebDAVServerViewModel {

    func beginAdd() {
        editingServer = nil
        testResultMessage = nil
        lastValidatedInput = nil
        isShowingForm = true
    }

    func beginEdit(_ server: BackupServerRecord) {
        editingServer = server
        formTitle = server.title
        formAddress = server.serverAddress
        formAccount = server.account
        formPassword = server.password
        testResultMessage = nil
        lastValidatedInput = nil
        isShowingForm = true
    }

    var isFormValid: Bool {
        !formTitle.trimmingCharacters(in: .whitespaces).isEmpty &&
        !formAddress.trimmingCharacters(in: .whitespaces).isEmpty &&
        !formAccount.trimmingCharacters(in: .whitespaces).isEmpty &&
        !formPassword.isEmpty
    }
}

// MARK: - CRUD

extension WebDAVServerViewModel {

    func save() async -> Bool {
        guard isFormValid else { return false }

        let input = formInput
        isTesting = true
        testResultMessage = nil

        do {
            if lastValidatedInput != input {
                try await repository.testConnection(input)
                lastValidatedInput = input
            }

            try await repository.saveServer(input, editingServer: editingServer)
            isTesting = false
            serverDidChange = true
            isShowingForm = false
            await loadServers()
            return true
        } catch {
            isTesting = false
            if error is NetworkError {
                testResultMessage = "连接失败: \(error.localizedDescription)"
            } else {
                testResultMessage = "保存失败: \(error.localizedDescription)"
            }
            return false
        }
    }

    func delete(_ server: BackupServerRecord) async {
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await repository.delete(server)
            serverDidChange = true
            await loadServers()
        } catch {
            // 静默失败
        }
    }

    func select(_ server: BackupServerRecord) async {
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await repository.select(server)
            serverDidChange = true
            await loadServers()
        } catch {
            // 静默失败
        }
    }
}

// MARK: - 测试连接

extension WebDAVServerViewModel {

    func testConnection() async {
        guard isFormValid else { return }
        let input = formInput
        isTesting = true
        testResultMessage = nil

        do {
            try await repository.testConnection(input)
            lastValidatedInput = input
            testResultMessage = "连接成功"
        } catch {
            lastValidatedInput = nil
            testResultMessage = "连接失败: \(error.localizedDescription)"
        }
        isTesting = false
    }
}

private extension WebDAVServerViewModel {
    var formInput: BackupServerFormInput {
        BackupServerFormInput(
            title: formTitle.trimmingCharacters(in: .whitespaces),
            address: formAddress.trimmingCharacters(in: .whitespaces),
            account: formAccount.trimmingCharacters(in: .whitespaces),
            password: formPassword
        )
    }
}
