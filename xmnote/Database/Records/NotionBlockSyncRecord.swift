/**
 * [INPUT]: 依赖 GRDB Record 协议与 Android Room v45 notion_block_sync 表结构
 * [OUTPUT]: 对外提供 NotionBlockSyncRecord，完整映射可独立冲突判断的 Notion 内容单元
 * [POS]: Database/Records 层单表映射模型；当前只服务 schema/恢复兼容，不开放 Notion 业务入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 一个可独立进行冲突判断的 Notion 内容单元映射。
nonisolated struct NotionBlockSyncRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notion_block_sync"

    var id: Int64?
    var pageSyncId: Int64
    var unitKey: String
    var contentType: String
    var sourceId: Int64
    var sourceUpdatedDate: Int64
    var sourceFingerprint: String
    var remoteFingerprint: String
    var blockIdsJson: String
    var anchorKey: String
    var deletable: Bool
    var state: String
    var lastSyncDate: Int64

    /// 映射 Swift 属性名与 Android Room snake_case 字段名。
    enum CodingKeys: String, CodingKey {
        case id, deletable, state
        case pageSyncId = "page_sync_id"
        case unitKey = "unit_key"
        case contentType = "content_type"
        case sourceId = "source_id"
        case sourceUpdatedDate = "source_updated_date"
        case sourceFingerprint = "source_fingerprint"
        case remoteFingerprint = "remote_fingerprint"
        case blockIdsJson = "block_ids_json"
        case anchorKey = "anchor_key"
        case lastSyncDate = "last_sync_date"
    }

    /// 在数据库插入后回填自增主键。
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
