import Foundation
import GRDB

/// 白噪声表，对应 Android WhiteNoiseEntity
nonisolated struct WhiteNoiseRecord: BaseRecord {
    static let databaseTableName = "white_noise"

    var id: Int64?
    var name: String = ""
    var cover: String = ""
    var source: String = ""
    var size: Int64 = 0
    /// 是否为付费资源: 0=免费, 1=付费
    var pro: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name, cover, source, size, pro
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
