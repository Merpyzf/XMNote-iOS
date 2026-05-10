/**
 * [INPUT]: 依赖 GRDB、RoomCanonicalSchemaV40、StagingIntegrityCanonicalizer 与核心 Record，校验备份 staging 数据库
 * [OUTPUT]: 对外提供 BackupSchemaValidator，在正式替换前完成版本、schema、外键和解码校验
 * [POS]: Database/RestoreCompatibility 的恢复安全闸门，被 BackupArchiveService 调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 备份 staging 校验器，先确认物理 schema，再整理 Android 历史备份外键闭包，全部通过后才允许替换正式库。
nonisolated enum BackupSchemaValidator {
    /// 打开 staging 数据库并执行 Room schema、外键整理、关键 Record 解码校验，全部通过后才允许正式替换。
    nonisolated static func prepareForRestore(at databasePath: String) throws {
        let databasePool = try DatabasePool(path: databasePath)
        try databasePool.write { db in
            try RoomCanonicalSchemaV40.validatePhysicalSchema(db)
            try StagingIntegrityCanonicalizer.canonicalize(db)
            try RoomCanonicalSchemaV40.assertForeignKeyIntegrity(db)
            try AppDatabase.markRoomCanonicalMigrationsIfNeeded(db)
            try decodeCoreRecords(db)
        }
        try databasePool.writeWithoutTransaction { db in
            // SQL 目的：在 staging 数据库通过只读结构校验后截断 WAL，确保正式替换时数据库主文件自包含。
            // 涉及表：无；副作用：将 WAL 中已提交内容 checkpoint 到主库，并清空临时 WAL 文件。
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}

private extension BackupSchemaValidator {
    nonisolated static func decodeCoreRecords(_ db: Database) throws {
        // SQL 目的：读取一条 book 记录验证 Android nullable 文本字段可被 iOS BookRecord 解码。
        // 涉及表：book；返回字段：全列，用于覆盖恢复后编辑书籍、书架渲染等核心链路。
        _ = try BookRecord.fetchOne(db, sql: "SELECT * FROM book ORDER BY id ASC LIMIT 1")

        // SQL 目的：读取一条 chapter 记录验证章节标题字段可被 iOS ChapterRecord 解码。
        // 涉及表：chapter；返回字段：全列，用于覆盖书摘详情章节解析。
        _ = try ChapterRecord.fetchOne(db, sql: "SELECT * FROM chapter ORDER BY id ASC LIMIT 1")

        // SQL 目的：读取一条 note 记录验证 Android nullable 文本字段可被 iOS NoteRecord 解码。
        // 涉及表：note；返回字段：全列，用于覆盖书摘列表、详情、编辑入口。
        _ = try NoteRecord.fetchOne(db, sql: "SELECT * FROM note ORDER BY id ASC LIMIT 1")
    }
}
