/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 CosConfigRecord（数据库 Record 实体）供 Repository 层完成持久化读写
 * [POS]: Database/Records 层单表映射模型，负责 camelCase 与 snake_case 编解码契约收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

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
