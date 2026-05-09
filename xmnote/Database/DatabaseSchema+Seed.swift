/**
 * [INPUT]: 依赖 GRDB DatabaseMigrator 与 DatabaseSchema 命名空间，承接分段表结构/索引/种子迁移声明
 * [OUTPUT]: 对外提供 DatabaseSchema 扩展迁移步骤（DatabaseSchema+Seed）供数据库初始化流程编排
 * [POS]: Database 层 Schema 分片定义文件，保证迁移职责可拆分且与仓储读写契约一致
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - 初始数据填充
// 对应 Android NoteDatabase.initHolderData() 中的基础数据
// 这些数据在数据库首次创建时写入，与 Android 端保持一致

extension AppDatabase {

    /// 在数据库首次创建时写入基础字典与占位数据，保证应用首启可直接运行核心流程。
    nonisolated static func seedInitialData(_ db: Database) throws {
        try seedReadStatus(db)
        try seedSource(db)
        try seedDefaultChapter(db)
        try seedDefaultCategory(db)
        try seedDefaultBook(db)
        try seedCosConfig(db)
    }

    // MARK: - 阅读状态（5 种）
    // read_status 表为手动主键，必须显式指定 id
    // ID 1=想读, 2=在读, 3=读完, 4=弃读, 5=搁置
    private nonisolated static func seedReadStatus(_ db: Database) throws {
        let statuses = ["想读", "在读", "读完", "弃读", "搁置"]
        for (index, name) in statuses.enumerated() {
            let id = index + 1
            try db.execute(
                // SQL 目的：向 read_status 写入固定枚举值（手动主键），供全局阅读状态引用。
                // 约束：id/read_status_order 与 Android 固定映射一致，避免跨端枚举错位。
                sql: """
                    INSERT INTO read_status (id, name, read_status_order, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (?, ?, ?, 0, 0, 0, 0)
                    """,
                arguments: [id, name, id]
            )
        }
    }

    // MARK: - 书籍来源（27 种）
    private nonisolated static func seedSource(_ db: Database) throws {
        let sources = [
            "未知", "Kindle阅读器", "Kindle App", "微信读书", "Apple Books",
            "静读天下", "多看阅读", "掌阅", "豆瓣阅读", "掌阅精选",
            "京东读书", "文石阅读器", "当当云阅读", "KOReader", "网易蜗牛",
            "豆瓣阅读(App)", "阅读", "Neat Reader", "汉王阅读器", "番茄小说",
            "滴墨书摘", "三联生活周刊", "Koodo Reader", "iReader", "得到",
            "Reeden", "Readingo"
        ]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, name) in sources.enumerated() {
            try db.execute(
                // SQL 目的：初始化 source 来源字典，source_order 与 Android 序号一致。
                // 时间字段：created_date 使用毫秒时间戳；其余同步字段保持 0（未同步态）。
                sql: """
                    INSERT INTO source (name, source_order, is_hide, bookshelf_order, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (?, ?, 0, -1, ?, 0, 0, 0)
                    """,
                arguments: [name, index, now]
            )
        }
    }

    // MARK: - 默认章节（占位记录，id=0）
    private nonisolated static func seedDefaultChapter(_ db: Database) throws {
        try db.execute(
            // SQL 目的：插入 chapter 占位记录（id=0, book_id=0），兼容默认章节引用。
            // 约束：id 与 Android 默认章节保持一致，避免跨端恢复后 chapter_id 指向不同占位行。
            sql: """
                INSERT INTO chapter (id, book_id, parent_id, title, remark, chapter_order, is_import, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (0, 0, 0, '', '', 0, 0, 0, 0, 0, 0)
                """
        )
    }

    // MARK: - 默认笔记分类（6 种，绑定到 book_id=0 作为模板）
    private nonisolated static func seedDefaultCategory(_ db: Database) throws {
        let categories = ["书籍", "电影", "音乐", "地点", "人物", "事件"]
        for (index, title) in categories.enumerated() {
            try db.execute(
                // SQL 目的：插入默认分类模板（book_id=0），供新书快速继承分类结构。
                // 排序规则：`order` 与数组下标一致，确保前后端展示顺序稳定。
                sql: """
                    INSERT INTO category (book_id, title, `order`, is_hide, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (0, ?, ?, 0, 0, 0, 0, 0)
                    """,
                arguments: [title, index]
            )
        }
    }

    // MARK: - 默认书籍（占位记录，id=0，用于未归属书籍的笔记）
    private nonisolated static func seedDefaultBook(_ db: Database) throws {
        try db.execute(
            // SQL 目的：写入 book 占位记录（逻辑默认书），承接未归属实体的外键引用。
            // 约束：read_status_id/source_id 等默认值需与 Android 初始库保持一致。
            sql: """
                INSERT INTO book (id, user_id, douban_id, name, raw_name, cover, author, author_intro, translator, isbn, pub_date, press, summary, read_position, total_position, total_pagination, type, current_position_unit, position_unit, source_id, purchase_date, price, book_order, score, catalog, book_mark_modified_time, read_status_id, read_status_changed_date, pinned, pin_order, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (0, 1, 0, '', '', '', '', '', '', '', '', '', '', 0, 0, 0, 1, 1, 2, 0, 0, 0, 0, 0, '', 0, 1, 0, 0, 0, 0, 0, 0, 0)
                """
        )
    }

    // MARK: - 默认 COS 配置
    private nonisolated static func seedCosConfig(_ db: Database) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.execute(
            // SQL 目的：初始化 cos_config 默认配置，确保首次进入备份能力时表中有可编辑记录。
            // 时间字段：created_date 使用毫秒时间戳，bucket/region 为默认值。
            sql: """
                INSERT INTO cos_config (secret_id, secret_key, region, bucket, is_using, created_date, updated_date, last_sync_date, is_deleted)
                VALUES ('', '', 'ap-shanghai', '纸间书摘', 1, ?, 0, 0, 0)
            """,
            arguments: [now]
        )
    }
}
