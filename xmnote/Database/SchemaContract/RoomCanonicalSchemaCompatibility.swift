/**
 * [INPUT]: 依赖 GRDB Database、RoomCanonicalSchemaV40...V45
 * [OUTPUT]: 对外提供 RoomCanonicalSchemaCompatibility，按备份库 user_version 分派 Room 物理 schema 与外键校验
 * [POS]: Database/SchemaContract 的跨端恢复兼容入口，被备份恢复闸门与 GRDB 迁移标记流程调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// Android Room 备份恢复兼容层，统一按 staging 库 `user_version` 分派到对应 Room schema 合同。
nonisolated enum RoomCanonicalSchemaCompatibility {
    nonisolated static let maximumRestorableDatabaseVersion = RoomCanonicalSchemaV45.databaseVersion

    /// 按数据库 `PRAGMA user_version` 校验 Room 物理结构；只读校验，不修复、不改业务表。
    nonisolated static func validatePhysicalSchema(_ db: Database) throws {
        let userVersion = try databaseVersion(db)
        guard userVersion <= maximumRestorableDatabaseVersion else {
            throw RoomCanonicalSchemaError.versionMismatch(userVersion)
        }

        if userVersion >= RoomCanonicalSchemaV45.databaseVersion {
            try RoomCanonicalSchemaV45.validatePhysicalSchema(db)
        } else if userVersion >= RoomCanonicalSchemaV44.databaseVersion {
            try RoomCanonicalSchemaV44.validatePhysicalSchema(db)
        } else if userVersion >= RoomCanonicalSchemaV43.databaseVersion {
            try RoomCanonicalSchemaV43.validatePhysicalSchema(db)
        } else if userVersion >= RoomCanonicalSchemaV42.databaseVersion {
            try RoomCanonicalSchemaV42.validatePhysicalSchema(db)
        } else if userVersion >= RoomCanonicalSchemaV41.databaseVersion {
            try RoomCanonicalSchemaV41.validatePhysicalSchema(db)
        } else {
            try RoomCanonicalSchemaV40.validatePhysicalSchema(db)
        }
    }

    /// 按数据库 `PRAGMA user_version` 校验外键闭包是否完整。
    nonisolated static func assertForeignKeyIntegrity(_ db: Database) throws {
        let userVersion = try databaseVersion(db)
        guard userVersion <= maximumRestorableDatabaseVersion else {
            throw RoomCanonicalSchemaError.versionMismatch(userVersion)
        }

        if userVersion >= RoomCanonicalSchemaV45.databaseVersion {
            try RoomCanonicalSchemaV45.assertForeignKeyIntegrity(db)
        } else if userVersion >= RoomCanonicalSchemaV44.databaseVersion {
            try RoomCanonicalSchemaV44.assertForeignKeyIntegrity(db)
        } else if userVersion >= RoomCanonicalSchemaV43.databaseVersion {
            try RoomCanonicalSchemaV43.assertForeignKeyIntegrity(db)
        } else if userVersion >= RoomCanonicalSchemaV42.databaseVersion {
            try RoomCanonicalSchemaV42.assertForeignKeyIntegrity(db)
        } else if userVersion >= RoomCanonicalSchemaV41.databaseVersion {
            try RoomCanonicalSchemaV41.assertForeignKeyIntegrity(db)
        } else {
            try RoomCanonicalSchemaV40.assertForeignKeyIntegrity(db)
        }
    }

    /// 读取 SQLite user_version，作为恢复闸门选择 schema 合同的事实源。
    nonisolated static func databaseVersion(_ db: Database) throws -> Int {
        // SQL 目的：读取 SQLite schema 版本号，判断 Android Room 备份库的物理合同版本。
        // 涉及表：无；返回字段：PRAGMA user_version 单值。
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }
}
