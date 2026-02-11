import Foundation
import GRDB

/// 出版社表，对应 Android PressEntity
nonisolated struct PressRecord: BaseRecord {
    static let databaseTableName = "press"

    var id: Int64?
    var logoUrl: String = ""
    var name: String = ""
    var introduction: String = ""

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name, introduction
        case logoUrl = "logo_url"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
