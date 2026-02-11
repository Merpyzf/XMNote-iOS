import Foundation
import GRDB

/// 备份服务器信息表，对应 Android BackupServerEntity
nonisolated struct BackupServerRecord: BaseRecord {
    static let databaseTableName = "backup_server"

    var id: Int64?
    var title: String = ""
    var serverAddress: String = ""
    var account: String = ""
    var password: String = ""
    /// 是否正在使用: 0=否, 1=是
    var isUsing: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, title, account, password
        case serverAddress = "server_address"
        case isUsing = "is_using"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
