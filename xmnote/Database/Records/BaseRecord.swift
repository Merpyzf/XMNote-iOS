/**
 * [INPUT]: 依赖 GRDB Record/FetchableRecord/PersistableRecord 协议与对应数据表字段映射
 * [OUTPUT]: 对外提供 BaseRecord 字段合同与禁止软删除的编译期兼容哨兵
 * [POS]: Database/Records 层单表映射模型，负责字段编解码与硬删除治理边界收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - BaseRecord 协议
// 对应 Android BaseEntity，所有表共享的 4 个公共字段
// created_date / updated_date: 记录创建和修改时间戳（毫秒）
// last_sync_date: 最后同步时间戳
// is_deleted: Android Room v44 与旧备份兼容字段；生产 Repository 不得写入 1

/// 统一数据库基础字段合同；`isDeleted` 仅用于读取跨端历史数据和引用占位书状态。
nonisolated protocol BaseRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var createdDate: Int64 { get set }
    var updatedDate: Int64 { get set }
    var lastSyncDate: Int64 { get set }
    var isDeleted: Int64 { get set }
}

extension BaseRecord {
    /// 阻断旧 Repository 继续写 tombstone；删除应调用 GRDB `delete` 或精确 `DELETE`。
    @available(*, unavailable, message: "禁止软删除；请在事务内执行物理 DELETE")
    nonisolated mutating func markAsDeleted() {
        fatalError("禁止软删除；请在事务内执行物理 DELETE")
    }

    /// 更新修改时间戳
    nonisolated mutating func touchUpdatedDate() {
        updatedDate = Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 设置创建时间戳（仅在首次插入时调用）
    nonisolated mutating func touchCreatedDate() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        createdDate = now
        updatedDate = now
    }
}

extension KeyedDecodingContainer {
    /// Room 物理 schema 中部分文本列允许 NULL；Record 边界将其转为空字符串，避免污染业务层默认展示语义。
    nonisolated func decodeStringOrEmpty(forKey key: Key) throws -> String {
        try decodeIfPresent(String.self, forKey: key) ?? ""
    }
}
