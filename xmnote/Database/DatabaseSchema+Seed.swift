import Foundation
import GRDB

// MARK: - 初始数据填充
// 对应 Android NoteDatabase.initHolderData() 中的基础数据
// 这些数据在数据库首次创建时写入，与 Android 端保持一致

extension AppDatabase {

    static func seedInitialData(_ db: Database) throws {
        try seedReadStatus(db)
        try seedSource(db)
        try seedDefaultChapter(db)
        try seedDefaultCategory(db)
        try seedDefaultBook(db)
        try seedCosConfig(db)
    }

    // MARK: - 阅读状态（5 种）
    // read_status 表使用自增 ID，插入顺序决定 ID 值
    // ID 1=想读, 2=在读, 3=读完, 4=弃读, 5=搁置
    private static func seedReadStatus(_ db: Database) throws {
        let statuses = ["想读", "在读", "读完", "弃读", "搁置"]
        for (index, name) in statuses.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO read_status (name, read_status_order, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (?, ?, 0, 0, 0, 0)
                    """,
                arguments: [name, index + 1]
            )
        }
    }

    // MARK: - 书籍来源（27 种）
    private static func seedSource(_ db: Database) throws {
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
                sql: """
                    INSERT INTO source (name, source_order, is_hide, bookshelf_order, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (?, ?, 0, -1, ?, 0, 0, 0)
                    """,
                arguments: [name, index, now]
            )
        }
    }

    // MARK: - 默认章节（占位记录，id=1）
    private static func seedDefaultChapter(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO chapter (book_id, parent_id, title, remark, chapter_order, is_import, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (0, 0, '', '', 0, 0, 0, 0, 0, 0)
                """
        )
    }

    // MARK: - 默认笔记分类（6 种，绑定到 book_id=0 作为模板）
    private static func seedDefaultCategory(_ db: Database) throws {
        let categories = ["书籍", "电影", "音乐", "地点", "人物", "事件"]
        for (index, title) in categories.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO category (book_id, title, `order`, is_hide, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (0, ?, ?, 0, 0, 0, 0, 0)
                    """,
                arguments: [title, index]
            )
        }
    }

    // MARK: - 默认书籍（占位记录，id=1，用于未归属书籍的笔记）
    private static func seedDefaultBook(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO book (user_id, douban_id, name, raw_name, cover, author, author_intro, translator, isbn, pub_date, press, summary, read_position, total_position, total_pagination, type, current_position_unit, position_unit, source_id, purchase_date, price, book_order, score, catalog, book_mark_modified_time, read_status_id, read_status_changed_date, pinned, pin_order, created_date, updated_date, last_sync_date, is_deleted)
                VALUES (1, 0, '', '', '', '', '', '', '', '', '', '', 0, 0, 0, 1, 2, 2, 0, 0, 0, 0, 0, '', 0, 1, 0, 0, 0, 0, 0, 0, 0)
                """
        )
    }

    // MARK: - 默认 COS 配置
    private static func seedCosConfig(_ db: Database) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
                INSERT INTO cos_config (secret_id, secret_key, region, bucket, is_using, created_date, updated_date, last_sync_date, is_deleted)
                VALUES ('', '', 'ap-shanghai', '纸间书摘', 1, ?, 0, 0, 0)
                """,
            arguments: [now]
        )
    }
}
