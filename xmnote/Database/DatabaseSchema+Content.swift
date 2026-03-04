/**
 * [INPUT]: 依赖 GRDB DatabaseMigrator 与 DatabaseSchema 命名空间，承接分段表结构/索引/种子迁移声明
 * [OUTPUT]: 对外提供 DatabaseSchema 扩展迁移步骤（DatabaseSchema+Content）供数据库初始化流程编排
 * [POS]: Database 层 Schema 分片定义文件，保证迁移职责可拆分且与仓储读写契约一致
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

// MARK: - 内容扩展表建表（7 张）
// review, review_image, category, category_content, category_image, attach_image, image

extension AppDatabase {

    /// 创建内容类数据表结构，失败时向上抛出错误。
    nonisolated static func createContentTables(_ db: Database) throws {

        // ── review ──
        // 书评
        try db.create(table: "review") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("title", .text)
            t.column("content", .text)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── review_image ──
        // 书评图片
        try db.create(table: "review_image") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("review_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("image", .text).notNull().defaults(to: "")
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── category ──
        // 相关分类
        try db.create(table: "category") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("title", .text)
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("is_hide", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── category_content ──
        // 分类内容
        try db.create(table: "category_content") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("category_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("title", .text)
            t.column("content", .text)
            t.column("content_book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("url", .text)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── category_image ──
        // 分类图片
        try db.create(table: "category_image") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("category_content_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("image", .text).notNull().defaults(to: "")
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── attach_image ──
        // 书摘附图
        try db.create(table: "attach_image") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("note_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("image_url", .text).notNull().defaults(to: "")
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── image ──
        // 通用图片资源
        try db.create(table: "image") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("url", .text).notNull().defaults(to: "")
            t.column("type", .integer).notNull().defaults(to: 0)
            t.column("pro", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }
    }
}
