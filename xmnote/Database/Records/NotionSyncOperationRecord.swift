/**
 * [INPUT]: 依赖 GRDB Record 协议与 Android Room v45 notion_sync_operation 表结构
 * [OUTPUT]: 对外提供 NotionSyncOperationRecord，映射远端非事务写入的本地恢复记录
 * [POS]: Database/Records 层单表映射模型；当前只服务 schema/恢复兼容，不开放 Notion 业务入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Notion 非事务远端写入的本地恢复记录。
nonisolated struct NotionSyncOperationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notion_sync_operation"

    var operationId: String
    var pageSyncId: Int64
    var unitKey: String
    var operationType: String
    var state: String
    var oldBlockIdsJson: String
    var newBlockIdsJson: String
    var blocksJson: String
    var sourceFingerprint: String
    var sourceUpdatedDate: Int64
    var createdDate: Int64
    var updatedDate: Int64

    /// 映射 Swift 属性名与 Android Room snake_case 字段名。
    enum CodingKeys: String, CodingKey {
        case state
        case operationId = "operation_id"
        case pageSyncId = "page_sync_id"
        case unitKey = "unit_key"
        case operationType = "operation_type"
        case oldBlockIdsJson = "old_block_ids_json"
        case newBlockIdsJson = "new_block_ids_json"
        case blocksJson = "blocks_json"
        case sourceFingerprint = "source_fingerprint"
        case sourceUpdatedDate = "source_updated_date"
        case createdDate = "created_date"
        case updatedDate = "updated_date"
    }
}
