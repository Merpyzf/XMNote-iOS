/**
 * [INPUT]: 依赖 GRDB Database 执行 Android 恢复库与旧 iOS 本地库的软引用完整性修复
 * [OUTPUT]: 对外提供 DatabaseSoftReferenceRepair，供 v40 对齐迁移幂等软删除异常活跃关系
 * [POS]: Database 层迁移修复器，不引入物理外键，专门收敛跨端恢复后的孤儿数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 软引用完整性修复器，用于把 Android 级联语义下不应继续活跃的孤儿记录标记为软删除。
nonisolated enum DatabaseSoftReferenceRepair {
    /// 执行一次幂等软引用修复；调用方迁移事务保证所有 SQL 在同一事务内完成。
    nonisolated static func repair(_ db: Database, updatedAt: Int64 = currentTimestampMillis) throws {
        try repairBookScopedRows(db, updatedAt: updatedAt)
        try repairContentScopedRows(db, updatedAt: updatedAt)
        try repairRelationRows(db, updatedAt: updatedAt)
        try repairReminderRows(db, updatedAt: updatedAt)
    }
}

private extension DatabaseSoftReferenceRepair {
    nonisolated static var currentTimestampMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    nonisolated static func repairBookScopedRows(_ db: Database, updatedAt: Int64) throws {
        // SQL 目的：软删除引用缺失或已软删除书籍的书摘，避免 Android 恢复库中的孤儿 note 继续进入书摘、统计和日历 UI。
        // 涉及表：note LEFT SEMI book；关键过滤：note.is_deleted = 0，且 book.id = note.book_id 不存在或 book.is_deleted != 0。
        // 时间字段：updated_date 写入当前毫秒时间戳；created_date/last_sync_date 保持原值；副作用是只标记异常活跃行，不硬删 tombstone。
        try db.execute(sql: """
            UPDATE note
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM book b
                  WHERE b.id = note.book_id
                    AND b.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍的书评，避免孤儿 review 继续进入书评列表、时间线和阅读日历。
        // 涉及表：review 与 book；关键过滤：review.is_deleted = 0，且不存在有效 book 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；副作用是保留记录用于同步墓碑语义。
        try db.execute(sql: """
            UPDATE review
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM book b
                  WHERE b.id = review.book_id
                    AND b.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍的相关内容分类，避免孤儿 category 继续作为分类入口展示。
        // 涉及表：category 与 book；关键过滤：category.is_deleted = 0，且不存在有效 book 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；副作用是仅影响异常活跃分类。
        try db.execute(sql: """
            UPDATE category
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM book b
                  WHERE b.id = category.book_id
                    AND b.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍的章节，避免孤儿 chapter 被书摘详情误用。
        // 涉及表：chapter 与 book；关键过滤：chapter.is_deleted = 0，且不存在有效 book 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；默认 book_id=0 在默认书存在时会被保留。
        try db.execute(sql: """
            UPDATE chapter
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM book b
                  WHERE b.id = chapter.book_id
                    AND b.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍的阅读计时记录，避免孤儿时长进入统计、热力图、时间线和日历。
        // 涉及表：read_time_record 与 book；关键过滤：read_time_record.is_deleted = 0，且不存在有效 book 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；阅读时间字段 start_time/end_time/fuzzy_read_date 保持原值。
        try db.execute(sql: """
            UPDATE read_time_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM book b
                  WHERE b.id = read_time_record.book_id
                    AND b.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍、或引用无效阅读状态的阅读状态历史。
        // 涉及表：book_read_status_record、book、read_status；关键过滤：历史记录有效但父书籍或状态枚举无效。
        // 时间字段：updated_date 写入当前毫秒时间戳；changed_date 保持原值用于同步与排查。
        try db.execute(sql: """
            UPDATE book_read_status_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND (
                  NOT EXISTS (
                      SELECT 1
                      FROM book b
                      WHERE b.id = book_read_status_record.book_id
                        AND b.is_deleted = 0
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM read_status rs
                      WHERE rs.id = book_read_status_record.read_status_id
                        AND rs.is_deleted = 0
                  )
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍的打卡记录，避免孤儿 check_in_record 进入日历和时间线。
        // 涉及表：check_in_record 与 book；关键过滤：check_in_record.is_deleted = 0，且不存在有效 book 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；checkin_date 保持原值。
        try db.execute(sql: """
            UPDATE check_in_record
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM book b
                  WHERE b.id = check_in_record.book_id
                    AND b.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍的阅读计划，避免提醒与计划 UI 继续显示孤儿计划。
        // 涉及表：read_plan 与 book；关键过滤：read_plan.is_deleted = 0，且不存在有效 book 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；read_start_date/reminder_time 保持原值。
        try db.execute(sql: """
            UPDATE read_plan
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM book b
                  WHERE b.id = read_plan.book_id
                    AND b.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍的排序偏好，避免孤儿 sort 影响内容列表排序恢复。
        // 涉及表：sort 与 book；关键过滤：sort.is_deleted = 0，且不存在有效 book 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；排序字段 order/type 保持原值。
        try db.execute(sql: """
            UPDATE sort
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM book b
                  WHERE b.id = sort.book_id
                    AND b.is_deleted = 0
              )
        """, arguments: [updatedAt])
    }

    nonisolated static func repairContentScopedRows(_ db: Database, updatedAt: Int64) throws {
        // SQL 目的：软删除父书籍、父分类或相关书籍引用失效的相关内容记录，避免孤儿 category_content 进入阅读日历和时间线。
        // 涉及表：category_content、book、category；关键过滤：主记录有效但 book/category/content_book_id 任一必需父引用失效。
        // 时间字段：updated_date 写入当前毫秒时间戳；created_date/url/content 保持原值。
        try db.execute(sql: """
            UPDATE category_content
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND (
                  NOT EXISTS (
                      SELECT 1
                      FROM book b
                      WHERE b.id = category_content.book_id
                        AND b.is_deleted = 0
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM category c
                      WHERE c.id = category_content.category_id
                        AND c.is_deleted = 0
                  )
                  OR (
                      content_book_id != 0
                      AND NOT EXISTS (
                          SELECT 1
                          FROM book cb
                          WHERE cb.id = category_content.content_book_id
                            AND cb.is_deleted = 0
                      )
                  )
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书摘的附图，避免孤儿 attach_image 被详情页或时间线批量查询读出。
        // 涉及表：attach_image 与 note；关键过滤：attach_image.is_deleted = 0，且不存在有效 note 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；image_url 与创建时间保持原值。
        try db.execute(sql: """
            UPDATE attach_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM note n
                  WHERE n.id = attach_image.note_id
                    AND n.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书评的图片，避免孤儿 review_image 继续参与书评图片展示。
        // 涉及表：review_image 与 review；关键过滤：review_image.is_deleted = 0，且不存在有效 review 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；image/order 保持原值。
        try db.execute(sql: """
            UPDATE review_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM review r
                  WHERE r.id = review_image.review_id
                    AND r.is_deleted = 0
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除相关内容的图片，避免孤儿 category_image 继续参与相关内容图片展示。
        // 涉及表：category_image 与 category_content；关键过滤：category_image.is_deleted = 0，且不存在有效 category_content 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；image/order 保持原值。
        try db.execute(sql: """
            UPDATE category_image
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM category_content cc
                  WHERE cc.id = category_image.category_content_id
                    AND cc.is_deleted = 0
              )
        """, arguments: [updatedAt])
    }

    nonisolated static func repairRelationRows(_ db: Database, updatedAt: Int64) throws {
        // SQL 目的：软删除引用缺失或已软删除书籍/书籍标签的 tag_book 关系，避免书架标签维度出现孤儿书籍。
        // 涉及表：tag_book、book、tag；关键过滤：关系有效但 book 无效，或 tag 无效/非书籍标签 type=2。
        // 时间字段：updated_date 写入当前毫秒时间戳；created_date/last_sync_date 保持原值。
        try db.execute(sql: """
            UPDATE tag_book
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND (
                  NOT EXISTS (
                      SELECT 1
                      FROM book b
                      WHERE b.id = tag_book.book_id
                        AND b.is_deleted = 0
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM tag t
                      WHERE t.id = tag_book.tag_id
                        AND t.type = 2
                        AND t.is_deleted = 0
                  )
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书摘/书摘标签的 tag_note 关系，避免笔记标签列表显示孤儿关系。
        // 涉及表：tag_note、note、tag；关键过滤：关系有效但 note 无效，或 tag 无效/非书摘标签 type=1。
        // 时间字段：updated_date 写入当前毫秒时间戳；关系创建时间保持原值。
        try db.execute(sql: """
            UPDATE tag_note
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND (
                  NOT EXISTS (
                      SELECT 1
                      FROM note n
                      WHERE n.id = tag_note.note_id
                        AND n.is_deleted = 0
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM tag t
                      WHERE t.id = tag_note.tag_id
                        AND t.type = 1
                        AND t.is_deleted = 0
                  )
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍/分组的 group_book 关系，避免书架分组维度出现孤儿条目。
        // 涉及表：group_book、book、group；关键过滤：关系有效但 book 或 group 父记录无效。
        // 时间字段：updated_date 写入当前毫秒时间戳；last_sync_date 保持原值。
        try db.execute(sql: """
            UPDATE group_book
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND (
                  NOT EXISTS (
                      SELECT 1
                      FROM book b
                      WHERE b.id = group_book.book_id
                        AND b.is_deleted = 0
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM `group` g
                      WHERE g.id = group_book.group_id
                        AND g.is_deleted = 0
                  )
              )
        """, arguments: [updatedAt])

        // SQL 目的：软删除引用缺失或已软删除书籍/书单的 collection_book 关系，避免书单详情继续展示孤儿书籍。
        // 涉及表：collection_book、book、collection；关键过滤：关系有效但 book 或 collection 父记录无效。
        // 时间字段：updated_date 写入当前毫秒时间戳；recommend/order 保持原值。
        try db.execute(sql: """
            UPDATE collection_book
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND (
                  NOT EXISTS (
                      SELECT 1
                      FROM book b
                      WHERE b.id = collection_book.book_id
                        AND b.is_deleted = 0
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM collection c
                      WHERE c.id = collection_book.collection_id
                        AND c.is_deleted = 0
                  )
              )
        """, arguments: [updatedAt])
    }

    nonisolated static func repairReminderRows(_ db: Database, updatedAt: Int64) throws {
        // SQL 目的：软删除引用缺失或已软删除阅读计划的提醒事件，避免 read_plan 被修复后仍留下孤儿提醒。
        // 涉及表：reminder_event 与 read_plan；关键过滤：reminder_event.is_deleted = 0，且不存在有效 read_plan 父记录。
        // 时间字段：updated_date 写入当前毫秒时间戳；reminder_date_time 保持原值。
        try db.execute(sql: """
            UPDATE reminder_event
            SET updated_date = ?,
                is_deleted = 1
            WHERE is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM read_plan rp
                  WHERE rp.id = reminder_event.read_plan_id
                    AND rp.is_deleted = 0
              )
        """, arguments: [updatedAt])
    }
}
