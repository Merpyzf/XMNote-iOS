import Foundation
import GRDB

/// 书评图片表，对应 Android ReviewImageEntity
/// 外键: review_id → review
nonisolated struct ReviewImageRecord: BaseRecord {
    static let databaseTableName = "review_image"

    var id: Int64?
    var reviewId: Int64 = 0
    var image: String = ""
    var order: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, image, order
        case reviewId = "review_id"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
