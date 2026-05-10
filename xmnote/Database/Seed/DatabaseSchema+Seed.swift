/**
 * [INPUT]: 依赖 GRDB Database 与 Android Room v40 canonical 表结构
 * [OUTPUT]: 对外提供 Android 对齐的默认 seed 数据
 * [POS]: Database/Seed 初始化数据定义文件，被 Room canonical seed 迁移调用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - 初始数据填充
// 对应 Android NoteDatabase.initHolderData() 中的基础数据；当前产品未正式上线，只服务新库初始化。

extension AppDatabase {
    /// 在数据库首次创建时写入基础字典与占位数据，保证应用首启可直接运行核心流程。
    nonisolated static func seedInitialData(_ db: Database) throws {
        try seedDefaultUser(db)
        try seedReadStatus(db)
        try seedDefaultSourceZero(db)
        try seedSource(db)
        try seedDefaultBook(db)
        try seedDefaultChapter(db)
        try seedDefaultCategory(db)
        try seedCosConfig(db)
    }

    // MARK: - 默认用户（id=1）
    private nonisolated static func seedDefaultUser(_ db: Database) throws {
        // SQL 目的：写入 Android 默认临时用户 id=1，满足默认书和用户维度表的物理外键。
        // 涉及表：user；关键字段：user_id 与 id 均为 1。
        try db.execute(sql: """
            INSERT OR IGNORE INTO user (id, user_id, nickName, gender, phone, created_date, updated_date, last_sync_date, is_deleted)
            VALUES (1, 1, '临时用户', 1, '', 0, 0, 0, 0)
        """)
    }

    // MARK: - 阅读状态（5 种）
    // read_status 表为手动主键，ID 1=想读, 2=在读, 3=读完, 4=弃读, 5=搁置。
    private nonisolated static func seedReadStatus(_ db: Database) throws {
        let statuses = ["想读", "在读", "读完", "弃读", "搁置"]
        for (index, name) in statuses.enumerated() {
            let id = index + 1
            // SQL 目的：向 read_status 写入 Android 固定枚举值，供 book 与阅读状态历史记录引用。
            // 涉及表：read_status；关键字段：id/read_status_order 与 Android 固定映射一致。
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO read_status (id, name, read_status_order, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (?, ?, ?, 0, 0, 0, 0)
                    """,
                arguments: [id, name, id]
            )
        }
    }

    // MARK: - 默认来源父行（id=0）
    private nonisolated static func seedDefaultSourceZero(_ db: Database) throws {
        // SQL 目的：补齐 Android 默认书 book.source_id=0 的物理父行；该来源保持隐藏且软删除，不进入来源 UI。
        // 涉及表：source 与 book；关键字段：source.id=0 是跨端默认占位父行。
        try db.execute(sql: """
            INSERT OR IGNORE INTO source (id, name, source_order, bookshelf_order, is_hide, created_date, updated_date, last_sync_date, is_deleted)
            VALUES (0, '', -1, -1, 1, 0, 0, 0, 1)
        """)
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
            let id = index + 1
            // SQL 目的：初始化 Android 来源字典，source_order 与 Android 初始顺序一致。
            // 涉及表：source；时间字段：created_date 使用毫秒时间戳，其余同步字段为 0。
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO source (id, name, source_order, is_hide, bookshelf_order, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (?, ?, ?, 0, -1, ?, 0, 0, 0)
                    """,
                arguments: [id, name, index, now]
            )
        }
    }

    // MARK: - 默认书籍（占位记录，id=0）
    private nonisolated static func seedDefaultBook(_ db: Database) throws {
        // SQL 目的：写入 Android 默认占位书 id=0，承接未归属书摘和默认章节引用。
        // 涉及表：book、user、source、read_status；外键父行由本 seed 的前置步骤保证。
        try db.execute(sql: """
            INSERT OR IGNORE INTO book (
                id, user_id, douban_id, name, raw_name, cover, author, author_intro, translator,
                isbn, pub_date, press, summary, read_position, total_position, total_pagination,
                type, current_position_unit, position_unit, source_id, purchase_date, price,
                book_order, score, catalog, book_mark_modified_time, read_status_id,
                read_status_changed_date, pinned, pin_order, created_date, updated_date,
                last_sync_date, is_deleted
            )
            VALUES (
                0, 1, 0, '', '', '', '', '', '',
                '', '', '', '', 0, 0, 0,
                1, 1, 2, 0, 0, 0,
                0, 0, '', 0, 1,
                0, 0, 0, 0, 0,
                0, 0
            )
        """)
    }

    // MARK: - 默认章节（占位记录，id=0）
    private nonisolated static func seedDefaultChapter(_ db: Database) throws {
        // SQL 目的：写入 Android 默认占位章节 id=0，承接未归属章节的书摘引用。
        // 涉及表：chapter 与 book；关键字段：id/book_id/parent_id 均为 0。
        try db.execute(sql: """
            INSERT OR IGNORE INTO chapter (
                id, book_id, parent_id, title, remark, chapter_order, is_import,
                created_date, updated_date, last_sync_date, is_deleted
            )
            VALUES (0, 0, 0, '', '', 0, 0, 0, 0, 0, 0)
        """)
    }

    // MARK: - 默认笔记分类（6 种，绑定到 book_id=0 作为模板）
    private nonisolated static func seedDefaultCategory(_ db: Database) throws {
        let categories = ["书籍", "电影", "音乐", "地点", "人物", "事件"]
        for (index, title) in categories.enumerated() {
            // SQL 目的：插入默认分类模板，供新书快速继承分类结构。
            // 涉及表：category 与默认 book.id=0；排序字段 order 与数组下标一致。
            try db.execute(
                sql: """
                    INSERT INTO category (book_id, title, `order`, is_hide, created_date, updated_date, last_sync_date, is_deleted)
                    SELECT 0, ?, ?, 0, 0, 0, 0, 0
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM category
                        WHERE book_id = 0
                          AND title = ?
                    )
                    """,
                arguments: [title, index, title]
            )
        }
    }

    // MARK: - 默认 COS 配置
    private nonisolated static func seedCosConfig(_ db: Database) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // SQL 目的：初始化 cos_config 默认配置，确保首次进入备份能力时表中有可编辑记录。
        // 涉及表：cos_config；时间字段：created_date 使用毫秒时间戳。
        try db.execute(
            sql: """
                INSERT INTO cos_config (secret_id, secret_key, region, bucket, is_using, created_date, updated_date, last_sync_date, is_deleted)
                SELECT '', '', 'ap-shanghai', '纸间书摘', 1, ?, 0, 0, 0
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM cos_config
                )
            """,
            arguments: [now]
        )
    }
}
