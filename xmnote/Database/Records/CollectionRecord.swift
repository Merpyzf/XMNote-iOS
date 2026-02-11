import Foundation
import GRDB

/// 书单表，对应 Android CollectionEntity
nonisolated struct CollectionRecord: BaseRecord {
    static let databaseTableName = "collection"

    var id: Int64?
    var title: String = ""
    var desc: String = ""
    var order: Int64 = 0
    /// 是否为年度书单: 0=否, 1=是
    var isAnnual: Int64 = 0
    var year: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, title, desc, order, year
        case isAnnual = "is_annual"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
