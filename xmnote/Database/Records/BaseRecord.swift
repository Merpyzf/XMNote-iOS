import Foundation
import GRDB

// MARK: - BaseRecord 协议
// 对应 Android BaseEntity，所有表共享的 4 个公共字段
// created_date / updated_date: 记录创建和修改时间戳（毫秒）
// last_sync_date: 最后同步时间戳
// is_deleted: 软删除标记（0=正常, 1=已删除）

nonisolated protocol BaseRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var createdDate: Int64 { get set }
    var updatedDate: Int64 { get set }
    var lastSyncDate: Int64 { get set }
    var isDeleted: Int64 { get set }
}

extension BaseRecord {
    /// 标记为已删除（软删除）
    mutating func markAsDeleted() {
        isDeleted = 1
        updatedDate = Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 更新修改时间戳
    mutating func touchUpdatedDate() {
        updatedDate = Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 设置创建时间戳（仅在首次插入时调用）
    mutating func touchCreatedDate() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        createdDate = now
        updatedDate = now
    }
}
