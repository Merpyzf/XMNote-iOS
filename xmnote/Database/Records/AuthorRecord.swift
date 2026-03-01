/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 AuthorRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 作者表，对应 Android AuthorEntity
nonisolated struct AuthorRecord: BaseRecord {
    static let databaseTableName = "author"

    var id: Int64?
    var doubanPersonageId: String = ""
    var photoUrl: String = ""
    var name: String = ""
    var gender: Int64 = 0
    var birthdate: String = ""
    var birthPlace: String = ""
    var deathdate: String = ""
    var bio: String = ""

    // MARK: - BaseRecord
    var createdDate: Int64 = 0
    var updatedDate: Int64 = 0
    var lastSyncDate: Int64 = 0
    var isDeleted: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name, gender, birthdate, deathdate, bio
        case doubanPersonageId = "douban_personage_id"
        case photoUrl = "photo_url"
        case birthPlace  // Android 列名就是 birthPlace（驼峰）
        case createdDate = "created_date"
        case updatedDate = "updated_date"
        case lastSyncDate = "last_sync_date"
        case isDeleted = "is_deleted"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
