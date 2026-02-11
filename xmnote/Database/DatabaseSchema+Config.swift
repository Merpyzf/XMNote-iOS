import Foundation
import GRDB

// MARK: - 配置与辅助表建表（10 张）
// setting, collection, collection_book, backup_server, cos_config,
// white_noise, widget_config, author, press, cover_mosaic

extension AppDatabase {

    static func createConfigTables(_ db: Database) throws {

        // ── setting ──
        // 键值对设置
        try db.create(table: "setting") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("key", .text)
            t.column("value", .text)
            t.column("user_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── collection ──
        // 书单
        try db.create(table: "collection") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull().defaults(to: "")
            t.column("desc", .text).notNull().defaults(to: "")
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("is_annual", .integer).notNull().defaults(to: 0)
            t.column("year", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── collection_book ──
        // 书单↔书籍关系
        try db.create(table: "collection_book") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("collection_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("recommend", .text).notNull().defaults(to: "")
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── backup_server ──
        // 备份服务器配置
        try db.create(table: "backup_server") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull().defaults(to: "")
            t.column("server_address", .text).notNull().defaults(to: "")
            t.column("account", .text).notNull().defaults(to: "")
            t.column("password", .text).notNull().defaults(to: "")
            t.column("is_using", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── cos_config ──
        // 腾讯 COS 对象存储配置
        try db.create(table: "cos_config") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("secret_id", .text).notNull().defaults(to: "")
            t.column("secret_key", .text).notNull().defaults(to: "")
            t.column("region", .text).notNull().defaults(to: "")
            t.column("bucket", .text).notNull().defaults(to: "")
            t.column("is_using", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── white_noise ──
        try db.create(table: "white_noise") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().defaults(to: "")
            t.column("cover", .text).notNull().defaults(to: "")
            t.column("source", .text).notNull().defaults(to: "")
            t.column("size", .integer).notNull().defaults(to: 0)
            t.column("pro", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── widget_config ──
        try db.create(table: "widget_config") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("widget_id", .integer).notNull().defaults(to: 0)
            t.column("type", .integer).notNull().defaults(to: 0)
            t.column("theme_id", .integer).notNull().defaults(to: 0)
            t.column("pattern_id", .integer).notNull().defaults(to: -1)
            t.column("book_ids", .text).notNull().defaults(to: "")
            t.column("tag_ids", .text).notNull().defaults(to: "")
            t.column("refresh_interval", .integer).notNull().defaults(to: 0)
            t.column("font_size", .integer).notNull().defaults(to: 2)
            t.column("sort_type", .integer).notNull().defaults(to: 0)
            t.column("is_protected", .integer).notNull().defaults(to: 0)
            t.column("statistics_data_type", .integer).notNull().defaults(to: 0)
            t.column("display_elements", .integer).notNull().defaults(to: 0)
            t.column("transparent", .integer).notNull().defaults(to: 100)
            t.column("filter_rule_is_or", .integer).notNull().defaults(to: 1)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── author ──
        try db.create(table: "author") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("douban_personage_id", .text).notNull().defaults(to: "")
            t.column("photo_url", .text).notNull().defaults(to: "")
            t.column("name", .text).notNull().defaults(to: "")
            t.column("gender", .integer).notNull().defaults(to: 0)
            t.column("birthdate", .text).notNull().defaults(to: "")
            t.column("birthPlace", .text).notNull().defaults(to: "")
            t.column("deathdate", .text).notNull().defaults(to: "")
            t.column("bio", .text).notNull().defaults(to: "")
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── press ──
        // 出版社
        try db.create(table: "press") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("logo_url", .text).notNull().defaults(to: "")
            t.column("name", .text).notNull().defaults(to: "")
            t.column("introduction", .text).notNull().defaults(to: "")
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── cover_mosaic ──
        // 书封拼贴作品
        try db.create(table: "cover_mosaic") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull().defaults(to: "")
            t.column("cover_url", .text).notNull().defaults(to: "")
            t.column("struct_data_json", .text).notNull().defaults(to: "")
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }
    }
}
