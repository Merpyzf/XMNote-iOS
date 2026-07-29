/**
 * [INPUT]: 依赖 GRDB Database 与 Android Room v40 canonical 表结构
 * [OUTPUT]: 对外提供 Android 对齐的根记录、字典、白噪音与背景图 seed 数据
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
        try seedWhiteNoise(db)
        try seedBackgroundImages(db)
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

    // MARK: - 白噪音（5 种）
    /// 写入 Android 新库内置的白噪音资源，稳定 ID、顺序和付费标记供跨端恢复后继续识别。
    private nonisolated static func seedWhiteNoise(_ db: Database) throws {
        let resources: [(name: String, size: Int64, isPro: Bool, cover: String, source: String)] = [
            (
                "雨天",
                60_624_912,
                false,
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/rain.jpg",
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/rainbest.mp3"
            ),
            (
                "森林",
                17_666_725,
                true,
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/forest.jpg",
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/birds.mp3"
            ),
            (
                "冬天",
                14_453_352,
                true,
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/snow.jpg",
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/snow.mp3"
            ),
            (
                "雷雨天",
                8_095_536,
                true,
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/thunder.jpg",
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/thunder.mp3"
            ),
            (
                "咖啡馆",
                16_573_824,
                true,
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/cafe-bar.jpg",
                "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/cafe-brazil-walla.mp3"
            )
        ]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, resource) in resources.enumerated() {
            // SQL 目的：按 Android BaseDataRepository 顺序写入内置白噪音，显式 ID 避免跨端资源标识漂移。
            // 涉及表：white_noise；时间字段：created_date 使用 Unix 毫秒，其余同步字段为 0。
            // 冲突策略：相同 ID 已存在时保持原记录，避免 seed 重放覆盖用户侧状态。
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO white_noise (
                        id, name, cover, source, size, pro,
                        created_date, updated_date, last_sync_date, is_deleted
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0)
                    """,
                arguments: [
                    index + 1,
                    resource.name,
                    resource.cover,
                    resource.source,
                    resource.size,
                    resource.isPro ? 1 : 0,
                    now
                ]
            )
        }
    }

    // MARK: - 阅读计时背景图（31 张）
    /// 写入 Android 新库内置的阅读计时背景图，保持稳定 ID、原始顺序和付费分组。
    private nonisolated static func seedBackgroundImages(_ db: Database) throws {
        let resources: [(url: String, isPro: Bool)] = [
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/marcel-strauss-lRIMRLE9SOk-unsplash.jpg", false),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/aswin-raj-thekkoot-H90LxRG9n2g-unsplash.jpg", false),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/nasa-Yj1M5riCKk4-unsplash.jpeg", false),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/patrick-hodskins-mU4Y8dX-iJE-unsplash-2.jpg", false),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/eberhard-grossgasteiger-XAxEp-NKBiQ-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/mona-eendra-vC8wj_Kphak-unsplash-2.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/szabo-viktor-28ZbKOWiZfs-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/wolfgang-hasselmann-jfk5YgXAPRM-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/eberhard-grossgasteiger-tXdiTsGf2z0-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/greg-kantra-23w5guoXxMM-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/charles-etoroma-QMUfC72oEWk-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/patrick-langwallner-3pR7d-tIRx8-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/caseen-kyle-registos-iHtwBlSOXjc-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/sen-KQ3GGLRnUtE-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/peter-burdon-oDv2Lft6610-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/aliaksei-zc-yuEJWyg8-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/livia-fressy-toaa6L4C3bk-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/zoltan-tasi-gN-r3UPfajY-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/masako-ishida-2bDOv9lhZJU-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/matei-pruteanu-qmqI6cWVMeI-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/paolo-celentano-7Kti8iT3bjg-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/amirhossein-khedri-1nhIdeKrVdY-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/kristaps-ungurs-_xfxnGGa088-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/zoe-V8dteQ3sdx0-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/colin-lloyd-5lyqDE0VpQI-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/milin-john-2Z-uXuaGADg-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/tanya-pro-LFJi3Deh_Gk-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/tito-la-star-xSRmNcisgDk-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/luke-peterson-y5_N-lH93U0-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/anil-xavier-GqEykCDt_e8-unsplash.jpeg", true),
            ("https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/jasper-garratt-iZai8e-Ymy0-unsplash.jpeg", true)
        ]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, resource) in resources.enumerated() {
            // SQL 目的：按 Android BaseDataRepository 顺序写入阅读计时背景图，显式 ID 保证资源标识稳定。
            // 涉及表：image；关键字段：type=1 对齐 Android BackgroundImageType.TIMING。
            // 时间字段：created_date 使用 Unix 毫秒，其余同步字段为 0；相同 ID 冲突时保留原记录。
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO image (
                        id, url, type, pro,
                        created_date, updated_date, last_sync_date, is_deleted
                    )
                    VALUES (?, ?, 1, ?, ?, 0, 0, 0)
                    """,
                arguments: [
                    index + 1,
                    resource.url,
                    resource.isPro ? 1 : 0,
                    now
                ]
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
