import Foundation
import GRDB

/// 分类图片表，对应 Android CategoryImageEntity
/// 外键: category_content_id → category_content
nonisolated struct CategoryImageRecord: BaseRecord {
    static let databaseTableName = "category_image"

    var id: Int64?
    var categoryContentId: Int64 = 0
    var image: String = ""
    var order: Int64 = 0

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, image, order
        case categoryContentId = "category_content_id"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
