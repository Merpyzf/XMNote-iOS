import Foundation
import GRDB

// MARK: - 阅读追踪表建表（6 张）
// read_time_record, read_target, book_read_status_record,
// read_plan, reminder_event, check_in_record

extension AppDatabase {

    static func createReadingTables(_ db: Database) throws {

        // ── read_time_record ──
        // 阅读时间记录（计时器产生的每次阅读会话）
        try db.create(table: "read_time_record") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("start_time", .integer).notNull().defaults(to: 0)
            t.column("end_time", .integer).notNull().defaults(to: 0)
            t.column("interrupt_time", .integer).notNull().defaults(to: 0)
            t.column("elapsed_seconds", .integer).notNull().defaults(to: 0)
            t.column("countdown_seconds", .integer).notNull().defaults(to: 0)
            t.column("paused_duration_millis", .integer).notNull().defaults(to: 0)
            t.column("paused", .integer).notNull().defaults(to: 0)
            t.column("position", .double).notNull().defaults(to: 0.0)
            t.column("status", .integer).notNull().defaults(to: 0)
            t.column("fuzzy_read_date", .integer).notNull().defaults(to: 0)
            t.column("weread_read_date", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── read_target ──
        // 阅读目标（每日时长 / 每年书籍数）
        try db.create(table: "read_target") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("time", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("target", .integer).notNull().defaults(to: 0)
            t.column("type", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── book_read_status_record ──
        // 书籍阅读状态变更历史
        try db.create(table: "book_read_status_record") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("read_status_id", .integer).notNull().defaults(to: 2)
                .indexed()
            t.column("changed_date", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── read_plan ──
        // 阅读计划
        try db.create(table: "read_plan") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("total_page_number", .integer).notNull().defaults(to: 0)
            t.column("read_page_number", .double).notNull().defaults(to: 0.0)
            t.column("position_type", .integer).notNull().defaults(to: 0)
            t.column("read_start_date", .integer).notNull().defaults(to: 0)
            t.column("day_read_number", .double).notNull().defaults(to: 0.0)
            t.column("read_interval", .integer).notNull().defaults(to: 1)
            t.column("reminder_time", .integer).notNull().defaults(to: 0)
            t.column("description", .text).notNull().defaults(to: "")
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── reminder_event ──
        // 阅读提醒事件
        try db.create(table: "reminder_event") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("event_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("read_plan_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("day_read_number", .double).notNull().defaults(to: 0.0)
            t.column("reminder_date_time", .integer).notNull().defaults(to: 0)
            t.column("is_done", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }

        // ── check_in_record ──
        // 打卡记录
        try db.create(table: "check_in_record") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("book_id", .integer).notNull().defaults(to: 0)
                .indexed()
            t.column("amount", .integer).notNull().defaults(to: 0)
            t.column("position", .text).notNull().defaults(to: "")
            t.column("position_unit", .integer).notNull().defaults(to: 0)
            t.column("remark", .text).notNull().defaults(to: "")
            t.column("checkin_date", .integer).notNull().defaults(to: 0)
            t.column("created_date", .integer).notNull().defaults(to: 0)
            t.column("updated_date", .integer).notNull().defaults(to: 0)
            t.column("last_sync_date", .integer).notNull().defaults(to: 0)
            t.column("is_deleted", .integer).notNull().defaults(to: 0)
        }
    }
}
