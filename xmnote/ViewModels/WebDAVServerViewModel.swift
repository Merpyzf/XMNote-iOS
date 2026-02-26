import Foundation
import GRDB

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

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }
}

// MARK: - Data Loading

extension WebDAVServerViewModel {

    func loadServers() async {
        do {
            servers = try await database.dbPool.read { db in
                try BackupServerRecord
                    .filter(Column("is_deleted") == 0)
                    .order(Column("is_using").desc)
                    .fetchAll(db)
            }
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
        isShowingForm = true
    }

    func beginEdit(_ server: BackupServerRecord) {
        editingServer = server
        formTitle = server.title
        formAddress = server.serverAddress
        formAccount = server.account
        formPassword = server.password
        testResultMessage = nil
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

        // 保存前先测试连接
        isTesting = true
        testResultMessage = nil
        let address = formAddress.trimmingCharacters(in: .whitespaces)
        let account = formAccount.trimmingCharacters(in: .whitespaces)
        let password = formPassword
        let title = formTitle.trimmingCharacters(in: .whitespaces)
        let editing = editingServer

        let client = WebDAVClient(baseURL: address, username: account, password: password)
        do {
            try await client.testConnection()
        } catch {
            isTesting = false
            testResultMessage = "连接失败: \(error.localizedDescription)"
            return false
        }
        isTesting = false

        do {
            try await database.dbPool.write { db in
                if var existing = editing {
                    existing.title = title
                    existing.serverAddress = address
                    existing.account = account
                    existing.password = password
                    existing.touchUpdatedDate()
                    try existing.update(db)
                } else {
                    var record = BackupServerRecord()
                    record.title = title
                    record.serverAddress = address
                    record.account = account
                    record.password = password
                    let count = try BackupServerRecord
                        .filter(Column("is_deleted") == 0)
                        .fetchCount(db)
                    record.isUsing = count == 0 ? 1 : 0
                    record.touchCreatedDate()
                    try record.insert(db)
                }
            }
            serverDidChange = true
            isShowingForm = false
            await loadServers()
            return true
        } catch {
            testResultMessage = "保存失败: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ server: BackupServerRecord) async {
        isProcessing = true
        defer { isProcessing = false }
        let serverCopy = server
        do {
            try await database.dbPool.write { db in
                var record = serverCopy
                record.markAsDeleted()
                try record.update(db)
            }
            serverDidChange = true
            await loadServers()
        } catch {
            // 静默失败
        }
    }

    func select(_ server: BackupServerRecord) async {
        isProcessing = true
        defer { isProcessing = false }
        let serverCopy = server
        do {
            try await database.dbPool.write { db in
                try db.execute(sql: "UPDATE backup_server SET is_using = 0")
                var record = serverCopy
                record.isUsing = 1
                record.touchUpdatedDate()
                try record.update(db)
            }
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
        isTesting = true
        testResultMessage = nil

        let client = WebDAVClient(
            baseURL: formAddress.trimmingCharacters(in: .whitespaces),
            username: formAccount.trimmingCharacters(in: .whitespaces),
            password: formPassword
        )
        do {
            try await client.testConnection()
            testResultMessage = "连接成功"
        } catch {
            testResultMessage = "连接失败: \(error.localizedDescription)"
        }
        isTesting = false
    }
}
