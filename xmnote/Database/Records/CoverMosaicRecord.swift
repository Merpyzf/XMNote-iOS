import Foundation
import GRDB

/// 书封拼贴作品表，对应 Android CoverMosaicEntity
nonisolated struct CoverMosaicRecord: BaseRecord {
    static let databaseTableName = "cover_mosaic"

    var id: Int64?
    var title: String = ""
    var coverUrl: String = ""
    /// 拼贴结构数据（JSON 字符串）
    var structDataJson: String = ""

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, title
        case coverUrl = "cover_url"
        case structDataJson = "struct_data_json"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
