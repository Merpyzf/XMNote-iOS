/**
 * [INPUT]: 依赖 GRDB DatabaseMigrator，依赖 DatabaseSchema+*.swift 各分片
 * [OUTPUT]: 对外提供 AppDatabase.migrator 静态属性，v38 全量迁移
 * [POS]: Database 模块的迁移入口，被 AppDatabase.init 调用执行 Schema 创建
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - v38 完整 Schema
// 精确复刻 Android Room 数据库的表结构（version 38）
// 建表顺序：先建无外键依赖的表，再建有外键依赖的表

extension AppDatabase {

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // iOS 从零开始，直接创建 v38 的完整 Schema
        migrator.registerMigration("v38-schema") { db in
            try createCoreTables(db)
            try createRelationTables(db)
            try createContentTables(db)
            try createReadingTables(db)
            try createConfigTables(db)

            // 同步 Android 的数据库版本号，备份恢复时通过此值校验兼容性
            try db.execute(sql: "PRAGMA user_version = 38")
        }

        // 初始数据填充（独立迁移，便于维护）
        migrator.registerMigration("v38-seed") { db in
            try seedInitialData(db)
        }

        return migrator
    }
}
