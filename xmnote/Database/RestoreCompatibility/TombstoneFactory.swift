/**
 * [INPUT]: 保留历史类型名与 GRDB Database 参数，仅用于阻断旧调用重新引入 tombstone
 * [OUTPUT]: 对外提供编译期不可用的 TombstoneFactory 兼容哨兵
 * [POS]: Database/RestoreCompatibility 的历史兼容边界；生产恢复链路不得调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 保留旧类型名以让误用在编译期失败；外键断链现在必须物理删除子记录。
nonisolated enum TombstoneFactory {
    /// 禁止为缺失父记录补 tombstone；调用方应改用 `HardDeleteCanonicalizer`。
    @available(*, unavailable, message: "禁止创建 tombstone；请物理删除失去父级的子记录")
    nonisolated static func ensureParent(table: String, id: Int64, db: Database) throws {
        throw TombstoneFactoryError.disabled
    }
}

nonisolated enum TombstoneFactoryError: LocalizedError {
    case disabled

    var errorDescription: String? {
        "Tombstone 创建已停用；请物理删除失去父级的子记录"
    }
}
