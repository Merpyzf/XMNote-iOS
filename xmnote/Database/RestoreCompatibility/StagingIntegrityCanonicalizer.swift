/**
 * [INPUT]: 依赖 HardDeleteCanonicalizer，接收通过 Room 物理 schema 校验的备份 staging 数据库
 * [OUTPUT]: 对外提供 StagingIntegrityCanonicalizer，用于恢复前物理清理历史删除标记与外键孤儿
 * [POS]: Database/RestoreCompatibility 的 staging 整理入口，被 BackupSchemaValidator 调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB

/// 在备份 staging 库中复用正式库硬删除算法，确保导入前已经消除历史 tombstone 与外键孤儿。
nonisolated enum StagingIntegrityCanonicalizer {
    /// 整理只作用于解包后的 staging 副本；不修改原始备份包，也不创建用于掩盖断链的父记录。
    nonisolated static func canonicalize(_ db: Database) throws {
        try HardDeleteCanonicalizer.canonicalize(db)
    }
}
