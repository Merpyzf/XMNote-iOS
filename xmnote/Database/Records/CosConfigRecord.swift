import Foundation
import GRDB

/// 腾讯 COS 对象存储配置表，对应 Android CosConfigEntity
nonisolated struct CosConfigRecord: BaseRecord {
    static let databaseTableName = "cos_config"

    var id: Int64?
    var secretId: String = ""
    var secretKey: String = ""
    var region: String = ""
    var bucket: String = ""
    /// 是否正在使用: 0=否, 1=是
    var isUsing: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, region, bucket
        case secretId = "secret_id"
        case secretKey = "secret_key"
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
