/**
 * [INPUT]: 依赖 BookRepository、Room v47 合成数据库与书籍/分组/标签/书单/同步关系 Record
 * [OUTPUT]: 锁定新库/旧库书籍完整数据图硬删除、分组/标签批量事务回滚、关系替换、排序、Android 当前标签语义与引用占位书清理合同
 * [POS]: xmnoteTests/BookAlignment 高风险 Repository 最终状态测试，不依赖私有 B0 或 UI 控件结构
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct BookAlignmentRepositoryContractTests {
    @Test
    func deletingBookFromFreshDatabaseWithoutLegacyReadRecordStillSucceeds() async throws {
        let database = try AppDatabase.empty()
        let repository = BookRepository(databaseManager: DatabaseManager(database: database))
        let bookID: Int64 = 80_001

        let hasLegacyReadRecord = try await database.dbPool.read { db in
            try db.tableExists("read_record")
        }
        #expect(!hasLegacyReadRecord)

        try await database.dbPool.write { db in
            try Self.insertBook(db, id: bookID, name: "新库删书合同", order: 1)
        }

        try await repository.deleteBooks([bookID])

        let bookCount = try await database.dbPool.read { db in
            // SQL 目的：确认不含 legacy read_record 的新建库仍能完成普通书物理删除。
            // 涉及表：book；关键过滤：合成 book id，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：覆盖 hardDeleteBookGraph 的缺表兼容分支。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book WHERE id = ?",
                arguments: [bookID]
            ) ?? 0
        }
        #expect(bookCount == 0)
    }

    @Test
    func deletingNormalBookPhysicallyRemovesMainRowAndBusinessRelations() async throws {
        let harness = try BookAlignmentRepositoryHarness.make()
        defer { harness.cleanup() }
        let targetBookID: Int64 = 81_001
        let untouchedBookID: Int64 = 81_002
        let groupID: Int64 = 81_101
        let tagID: Int64 = 81_201
        let targetMetadataID: Int64 = 81_501
        let untouchedMetadataID: Int64 = 81_502

        try await harness.write { db in
            try Self.insertBook(db, id: targetBookID, name: "待删除书", order: 10)
            try Self.insertBook(db, id: untouchedBookID, name: "不相关书", order: 20)
            try Self.insertGroup(db, id: groupID, name: "删除合同分组", order: 1)
            try Self.insertGroupBook(db, id: 81_301, groupID: groupID, bookID: targetBookID)
            try Self.insertTag(db, id: tagID, name: "删除合同标签", order: 1)
            try Self.insertTagBook(db, id: 81_401, tagID: tagID, bookID: targetBookID)
            try Self.insertDeletionMetadataGraph(
                db,
                bookID: targetBookID,
                rowID: targetMetadataID
            )
            try Self.insertDeletionMetadataGraph(
                db,
                bookID: untouchedBookID,
                rowID: untouchedMetadataID
            )
        }

        try await harness.repository.deleteBooks([targetBookID, targetBookID])

        let state = try await harness.read { db in
            // SQL 目的：读取目标书、对照书及目标书的分组/标签关系总行数，区分物理删除与墓碑。
            // 涉及表：book、group_book、tag_book；关键过滤：固定 book id，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：锁定正常书及业务 relation 不留任何行。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM book WHERE id = ?) AS target_book_count,
                        (SELECT COUNT(*) FROM book WHERE id = ?) AS untouched_book_count,
                        (SELECT COUNT(*) FROM group_book WHERE book_id = ?) AS group_relation_count,
                        (SELECT COUNT(*) FROM tag_book WHERE book_id = ?) AS tag_relation_count
                    """,
                arguments: [targetBookID, untouchedBookID, targetBookID, targetBookID]
            )
        }
        let row = try #require(state)
        #expect((row["target_book_count"] as Int?) == 0)
        #expect((row["untouched_book_count"] as Int?) == 1)
        #expect((row["group_relation_count"] as Int?) == 0)
        #expect((row["tag_relation_count"] as Int?) == 0)

        let metadataState = try await harness.read { db in
            // SQL 目的：核对删书后 Room v47 历史阅读、计划、导入去重与 Notion 同步数据图的物理状态。
            // 涉及表：read_record、read_plan、reminder_event、note_import_hash、notion_page_sync、notion_block_sync、notion_sync_operation。
            // 关键过滤：分别按目标与对照合成主键精确命中，不过滤 is_deleted；时间字段不参与。
            // 返回用途：目标图必须归零，对照图必须逐表保留，防止无条件或过宽 DELETE。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM read_record WHERE id = ?) AS target_read_record_count,
                        (SELECT COUNT(*) FROM read_plan WHERE id = ?) AS target_read_plan_count,
                        (SELECT COUNT(*) FROM reminder_event WHERE id = ?) AS target_reminder_count,
                        (SELECT COUNT(*) FROM note_import_hash WHERE book_id = ?) AS target_import_hash_count,
                        (SELECT COUNT(*) FROM notion_page_sync WHERE id = ?) AS target_notion_page_count,
                        (SELECT COUNT(*) FROM notion_block_sync WHERE id = ?) AS target_notion_block_count,
                        (SELECT COUNT(*) FROM notion_sync_operation WHERE operation_id = ?) AS target_notion_operation_count,
                        (SELECT COUNT(*) FROM read_record WHERE id = ?) AS untouched_read_record_count,
                        (SELECT COUNT(*) FROM read_plan WHERE id = ?) AS untouched_read_plan_count,
                        (SELECT COUNT(*) FROM reminder_event WHERE id = ?) AS untouched_reminder_count,
                        (SELECT COUNT(*) FROM note_import_hash WHERE book_id = ?) AS untouched_import_hash_count,
                        (SELECT COUNT(*) FROM notion_page_sync WHERE id = ?) AS untouched_notion_page_count,
                        (SELECT COUNT(*) FROM notion_block_sync WHERE id = ?) AS untouched_notion_block_count,
                        (SELECT COUNT(*) FROM notion_sync_operation WHERE operation_id = ?) AS untouched_notion_operation_count
                    """,
                arguments: [
                    targetMetadataID,
                    targetMetadataID,
                    targetMetadataID,
                    targetBookID,
                    targetMetadataID,
                    targetMetadataID,
                    Self.notionOperationID(targetMetadataID),
                    untouchedMetadataID,
                    untouchedMetadataID,
                    untouchedMetadataID,
                    untouchedBookID,
                    untouchedMetadataID,
                    untouchedMetadataID,
                    Self.notionOperationID(untouchedMetadataID)
                ]
            )
        }
        let metadataRow = try #require(metadataState)
        #expect((metadataRow["target_read_record_count"] as Int?) == 0)
        #expect((metadataRow["target_read_plan_count"] as Int?) == 0)
        #expect((metadataRow["target_reminder_count"] as Int?) == 0)
        #expect((metadataRow["target_import_hash_count"] as Int?) == 0)
        #expect((metadataRow["target_notion_page_count"] as Int?) == 0)
        #expect((metadataRow["target_notion_block_count"] as Int?) == 0)
        #expect((metadataRow["target_notion_operation_count"] as Int?) == 0)
        #expect((metadataRow["untouched_read_record_count"] as Int?) == 1)
        #expect((metadataRow["untouched_read_plan_count"] as Int?) == 1)
        #expect((metadataRow["untouched_reminder_count"] as Int?) == 1)
        #expect((metadataRow["untouched_import_hash_count"] as Int?) == 1)
        #expect((metadataRow["untouched_notion_page_count"] as Int?) == 1)
        #expect((metadataRow["untouched_notion_block_count"] as Int?) == 1)
        #expect((metadataRow["untouched_notion_operation_count"] as Int?) == 1)

        let observedIDs = try await harness.firstObservedBookIDs()
        #expect(!observedIDs.contains(targetBookID))
        #expect(observedIDs.contains(untouchedBookID))
    }

    @Test
    func movingBookPhysicallyReplacesOldGroupRelationAndRemainsDuplicateFreeOnRetry() async throws {
        let harness = try BookAlignmentRepositoryHarness.make()
        defer { harness.cleanup() }
        let bookID: Int64 = 82_001
        let sourceGroupID: Int64 = 82_101
        let targetGroupID: Int64 = 82_102

        try await harness.write { db in
            try Self.insertBook(db, id: bookID, name: "移组合同书", order: 7, pinned: 1, pinOrder: 9)
            try Self.insertGroup(db, id: sourceGroupID, name: "原分组", order: 1)
            try Self.insertGroup(db, id: targetGroupID, name: "目标分组", order: 2)
            try Self.insertGroupBook(db, id: 82_201, groupID: sourceGroupID, bookID: bookID)
        }

        try await harness.repository.moveBooks(
            [bookID, bookID],
            fromGroup: sourceGroupID,
            toGroup: targetGroupID
        )
        await #expect(throws: (any Error).self) {
            try await harness.repository.moveBooks(
                [bookID],
                fromGroup: sourceGroupID,
                toGroup: targetGroupID
            )
        }

        let relationState = try await harness.read { db in
            // SQL 目的：检查重试移组后的全部 group_book 行与书籍置顶状态。
            // 涉及表：group_book、book；关键过滤：book_id 精确匹配，不过滤 relation.is_deleted。
            // 时间字段：返回 updated_date 验证纯关系与排序移动不改写书籍内容时间。
            // 返回用途：证明旧 relation 物理删除、目标 relation 唯一且取消置顶。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM group_book WHERE book_id = ?) AS all_relation_count,
                        (SELECT COUNT(*) FROM group_book WHERE book_id = ? AND group_id = ?) AS source_count,
                        (SELECT COUNT(*) FROM group_book WHERE book_id = ? AND group_id = ?) AS target_count,
                        pinned,
                        pin_order,
                        updated_date
                    FROM book
                    WHERE id = ?
                    """,
                arguments: [bookID, bookID, sourceGroupID, bookID, targetGroupID, bookID]
            )
        }
        let row = try #require(relationState)
        #expect((row["all_relation_count"] as Int?) == 1)
        #expect((row["source_count"] as Int?) == 0)
        #expect((row["target_count"] as Int?) == 1)
        #expect((row["pinned"] as Int64?) == 0)
        #expect((row["pin_order"] as Int64?) == 0)
        #expect((row["updated_date"] as Int64?) == 0)

        #expect(try await harness.firstGroupBookIDs(groupID: sourceGroupID).isEmpty)
        #expect(try await harness.firstGroupBookIDs(groupID: targetGroupID) == [bookID])
    }

    @Test
    func movingTwoBooksRollsBackFirstBookWhenSecondTargetRelationInsertFails() async throws {
        let harness = try BookAlignmentRepositoryHarness.make()
        defer { harness.cleanup() }
        let firstBookID: Int64 = 86_001
        let secondBookID: Int64 = 86_002
        let sourceGroupID: Int64 = 86_101
        let targetGroupID: Int64 = 86_102

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: firstBookID,
                name: "晚失败第一本",
                order: 11,
                pinned: 1,
                pinOrder: 101,
                updatedDate: 1_001
            )
            try Self.insertBook(
                db,
                id: secondBookID,
                name: "晚失败第二本",
                order: 22,
                pinned: 1,
                pinOrder: 102,
                updatedDate: 1_002
            )
            try Self.insertGroup(db, id: sourceGroupID, name: "晚失败原分组", order: 1)
            try Self.insertGroup(db, id: targetGroupID, name: "晚失败目标分组", order: 2)
            try Self.insertGroupBook(db, id: 86_201, groupID: sourceGroupID, bookID: firstBookID)
            try Self.insertGroupBook(db, id: 86_202, groupID: sourceGroupID, bookID: secondBookID)

            // SQL 目的：只在批量移组处理第二本书的目标 relation INSERT 时强制 ABORT，制造可重复的晚失败。
            // 涉及表：group_book；关键过滤：NEW.group_id/NEW.book_id 精确命中合成测试 ID。
            // 时间字段：不参与；副作用仅存在于本用例临时连接，用于验证外层 Repository 事务回滚。
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER book_alignment_fail_second_group_insert
                    BEFORE INSERT ON group_book
                    WHEN NEW.group_id = \(targetGroupID)
                     AND NEW.book_id = \(secondBookID)
                    BEGIN
                        SELECT RAISE(ABORT, 'forced second relation failure');
                    END
                    """
            )
        }
        let sourceIDsBeforeMove = try await harness.firstGroupBookIDs(groupID: sourceGroupID)

        await #expect(throws: (any Error).self) {
            try await harness.repository.moveBooks(
                [firstBookID, secondBookID],
                fromGroup: sourceGroupID,
                toGroup: targetGroupID
            )
        }

        let books = try await harness.read { db in
            // SQL 目的：读取晚失败后两本书的排序、置顶和更新时间，验证第一本已执行的写入也被回滚。
            // 涉及表：book；关键过滤：id 限定为本用例两本书；时间字段：读取 updated_date 原值。
            // 返回用途：两本书均须恢复操作前全部字段，而非只回滚触发失败的第二本。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, book_order, pinned, pin_order, updated_date
                    FROM book
                    WHERE id IN (?, ?)
                    ORDER BY id ASC
                    """,
                arguments: [firstBookID, secondBookID]
            )
        }
        #expect(books.map { $0["book_order"] as Int64 } == [11, 22])
        #expect(books.map { $0["pinned"] as Int64 } == [1, 1])
        #expect(books.map { $0["pin_order"] as Int64 } == [101, 102])
        #expect(books.map { $0["updated_date"] as Int64 } == [1_001, 1_002])

        let relations = try await harness.read { db in
            // SQL 目的：读取晚失败后两本书的全部现存分组关系，验证旧关系恢复且目标组零新增。
            // 涉及表：group_book；关键过滤：book_id 限定为两本书，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：同时锁定原 relation 主键，避免以新行伪装回滚。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, group_id, book_id
                    FROM group_book
                    WHERE book_id IN (?, ?)
                    ORDER BY book_id ASC, id ASC
                    """,
                arguments: [firstBookID, secondBookID]
            )
        }
        #expect(relations.map { $0["id"] as Int64 } == [86_201, 86_202])
        #expect(relations.map { $0["group_id"] as Int64 } == [sourceGroupID, sourceGroupID])
        #expect(relations.map { $0["book_id"] as Int64 } == [firstBookID, secondBookID])
        let targetRelationCount = try await harness.read { db in
            // SQL 目的：确认晚失败事务没有在目标组留下任一本书的中间 relation。
            // 涉及表：group_book；关键过滤：目标 group_id 与两本测试 book_id，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：目标组新增必须严格为零。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM group_book WHERE group_id = ? AND book_id IN (?, ?)",
                arguments: [targetGroupID, firstBookID, secondBookID]
            ) ?? 0
        }
        #expect(targetRelationCount == 0)
        #expect(try await harness.firstGroupBookIDs(groupID: sourceGroupID) == sourceIDsBeforeMove)
    }

    @Test
    func deletingGroupsRollsBackFirstNonEmptyGroupWhenSecondIDIsInvalid() async throws {
        let harness = try BookAlignmentRepositoryHarness.make()
        defer { harness.cleanup() }
        let bookID: Int64 = 87_001
        let validGroupID: Int64 = 87_101
        let invalidGroupID: Int64 = 87_999
        let relationID: Int64 = 87_201

        try await harness.write { db in
            try Self.insertBook(
                db,
                id: bookID,
                name: "批量删组回滚书",
                order: 37,
                pinned: 1,
                pinOrder: 701,
                updatedDate: 1_701
            )
            try Self.insertGroup(db, id: validGroupID, name: "批量删组回滚组", order: 19)
            try Self.insertGroupBook(
                db,
                id: relationID,
                groupID: validGroupID,
                bookID: bookID
            )
        }

        let repository = BookGroupManagementRepository(
            databaseManager: DatabaseManager(database: harness.database)
        )
        await #expect(throws: BookGroupManagementRepositoryError.invalidGroup) {
            try await repository.deleteGroups(
                groupIDs: [validGroupID, invalidGroupID],
                placement: .start
            )
        }

        let state = try await harness.read { db in
            // SQL 目的：读取批量删组晚失败后的首组、旧 relation 与书籍排序/置顶字段。
            // 涉及表：group、group_book、book；关键过滤：全部使用本用例合成主键，不过滤 is_deleted。
            // 时间字段：读取 group/book.updated_date 原值；返回用途：证明第一组的完整删除链路已整体回滚。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        g.name AS group_name,
                        g.group_order,
                        g.pinned AS group_pinned,
                        g.pin_order AS group_pin_order,
                        g.updated_date AS group_updated_date,
                        g.is_deleted AS group_is_deleted,
                        (SELECT id FROM group_book WHERE id = ?) AS relation_id,
                        (SELECT group_id FROM group_book WHERE id = ?) AS relation_group_id,
                        (SELECT book_id FROM group_book WHERE id = ?) AS relation_book_id,
                        (SELECT is_deleted FROM group_book WHERE id = ?) AS relation_is_deleted,
                        b.book_order,
                        b.pinned AS book_pinned,
                        b.pin_order AS book_pin_order,
                        b.updated_date AS book_updated_date
                    FROM `group` g
                    JOIN book b ON b.id = ?
                    WHERE g.id = ?
                    """,
                arguments: [
                    relationID,
                    relationID,
                    relationID,
                    relationID,
                    bookID,
                    validGroupID
                ]
            )
        }
        let row = try #require(state)
        #expect((row["group_name"] as String?) == "批量删组回滚组")
        #expect((row["group_order"] as Int64?) == 19)
        #expect((row["group_pinned"] as Int64?) == 0)
        #expect((row["group_pin_order"] as Int64?) == 0)
        #expect((row["group_updated_date"] as Int64?) == 0)
        #expect((row["group_is_deleted"] as Int64?) == 0)
        #expect((row["relation_id"] as Int64?) == relationID)
        #expect((row["relation_group_id"] as Int64?) == validGroupID)
        #expect((row["relation_book_id"] as Int64?) == bookID)
        #expect((row["relation_is_deleted"] as Int64?) == 0)
        #expect((row["book_order"] as Int64?) == 37)
        #expect((row["book_pinned"] as Int64?) == 1)
        #expect((row["book_pin_order"] as Int64?) == 701)
        #expect((row["book_updated_date"] as Int64?) == 1_701)
    }

    @Test
    func deletingTagsRollsBackFirstTagAndRelationsWhenSecondIDIsInvalid() async throws {
        let harness = try BookAlignmentRepositoryHarness.make()
        defer { harness.cleanup() }
        let bookID: Int64 = 88_001
        let tagID: Int64 = 88_101
        let invalidTagID: Int64 = 88_999
        let noteID: Int64 = 88_201
        let tagBookID: Int64 = 88_301
        let tagNoteID: Int64 = 88_302

        try await harness.write { db in
            try Self.insertBook(db, id: bookID, name: "批量删标签回滚书", order: 1)
            try Self.insertTag(db, id: tagID, name: "批量删标签回滚标签", order: 23)
            try Self.insertNote(db, id: noteID, bookID: bookID)
            try Self.insertTagBook(db, id: tagBookID, tagID: tagID, bookID: bookID)
            try Self.insertTagNote(db, id: tagNoteID, tagID: tagID, noteID: noteID)
        }

        let repository = TagManagementRepository(
            databaseManager: DatabaseManager(database: harness.database)
        )
        await #expect(throws: TagManagementRepositoryError.invalidTag) {
            try await repository.deleteTags(
                tagIDs: [tagID, invalidTagID],
                scope: .book
            )
        }

        let state = try await harness.read { db in
            // SQL 目的：读取批量删标签晚失败后的首标签及其书籍/书摘关系原始行。
            // 涉及表：tag、tag_book、tag_note；关键过滤：全部使用合成主键，不过滤 is_deleted。
            // 时间字段：读取 tag.updated_date 原值；返回用途：证明物理删除与排序归一化均未部分提交。
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        t.name,
                        t.tag_order,
                        t.updated_date,
                        t.is_deleted,
                        (SELECT id FROM tag_book WHERE id = ?) AS tag_book_id,
                        (SELECT tag_id FROM tag_book WHERE id = ?) AS tag_book_tag_id,
                        (SELECT book_id FROM tag_book WHERE id = ?) AS tag_book_book_id,
                        (SELECT is_deleted FROM tag_book WHERE id = ?) AS tag_book_is_deleted,
                        (SELECT id FROM tag_note WHERE id = ?) AS tag_note_id,
                        (SELECT tag_id FROM tag_note WHERE id = ?) AS tag_note_tag_id,
                        (SELECT note_id FROM tag_note WHERE id = ?) AS tag_note_note_id,
                        (SELECT is_deleted FROM tag_note WHERE id = ?) AS tag_note_is_deleted
                    FROM tag t
                    WHERE t.id = ?
                    """,
                arguments: [
                    tagBookID,
                    tagBookID,
                    tagBookID,
                    tagBookID,
                    tagNoteID,
                    tagNoteID,
                    tagNoteID,
                    tagNoteID,
                    tagID
                ]
            )
        }
        let row = try #require(state)
        #expect((row["name"] as String?) == "批量删标签回滚标签")
        #expect((row["tag_order"] as Int64?) == 23)
        #expect((row["updated_date"] as Int64?) == 0)
        #expect((row["is_deleted"] as Int64?) == 0)
        #expect((row["tag_book_id"] as Int64?) == tagBookID)
        #expect((row["tag_book_tag_id"] as Int64?) == tagID)
        #expect((row["tag_book_book_id"] as Int64?) == bookID)
        #expect((row["tag_book_is_deleted"] as Int64?) == 0)
        #expect((row["tag_note_id"] as Int64?) == tagNoteID)
        #expect((row["tag_note_tag_id"] as Int64?) == tagID)
        #expect((row["tag_note_note_id"] as Int64?) == noteID)
        #expect((row["tag_note_is_deleted"] as Int64?) == 0)
    }

    @Test
    func groupSortingRejectsIncompleteOrDuplicateInputThenWritesExactFinalOrder() async throws {
        let harness = try BookAlignmentRepositoryHarness.make()
        defer { harness.cleanup() }
        let groupID: Int64 = 83_101
        let bookA: Int64 = 83_001
        let bookB: Int64 = 83_002
        let bookC: Int64 = 83_003

        try await harness.write { db in
            try Self.insertGroup(db, id: groupID, name: "排序合同分组", order: 1)
            for (index, bookID) in [bookA, bookB, bookC].enumerated() {
                try Self.insertBook(
                    db,
                    id: bookID,
                    name: "排序书 \(index)",
                    order: Int64((index + 1) * 10),
                    updatedDate: Int64(1_000 + index)
                )
                try Self.insertGroupBook(
                    db,
                    id: Int64(83_201 + index),
                    groupID: groupID,
                    bookID: bookID
                )
            }
        }

        await #expect(throws: (any Error).self) {
            try await harness.repository.updateBooksInGroupOrder(
                groupID: groupID,
                orderedBookIDs: [bookC, bookA, bookC, 999_999]
            )
        }
        #expect(try await harness.firstGroupBookIDs(groupID: groupID) == [bookA, bookB, bookC])

        try await harness.repository.updateBooksInGroupOrder(
            groupID: groupID,
            orderedBookIDs: [bookC, bookA, bookB]
        )

        let rows = try await harness.read { db in
            // SQL 目的：读取分组内三本书的最终 book_order 与时间字段。
            // 涉及表：book、group_book；关键过滤：指定 group_id 且 relation 有效。
            // 时间字段：读取 updated_date，锁定当前 Android 排序不刷新书籍修改时间的结果。
            // 返回用途：按 book_order/id 排序后与 Repository 读取顺序交叉验证。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT b.id, b.book_order, b.updated_date
                    FROM book b
                    JOIN group_book gb ON gb.book_id = b.id
                    WHERE gb.group_id = ?
                      AND gb.is_deleted = 0
                    ORDER BY b.book_order ASC, b.id ASC
                    """,
                arguments: [groupID]
            )
        }
        #expect(rows.map { $0["id"] as Int64 } == [bookC, bookA, bookB])
        #expect(rows.map { $0["book_order"] as Int64 } == [0, 1, 2])
        let timestamps = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["id"] as Int64, row["updated_date"] as Int64)
        })
        #expect(timestamps[bookA] == 1_000)
        #expect(timestamps[bookB] == 1_001)
        #expect(timestamps[bookC] == 1_002)
        #expect(try await harness.firstGroupBookIDs(groupID: groupID) == [bookC, bookA, bookB])
    }

    @Test
    func tagsUseExplicitReplaceAddAndRemoveWhileRemovedRelationsStayPhysical() async throws {
        let harness = try BookAlignmentRepositoryHarness.make()
        defer { harness.cleanup() }
        let bookA: Int64 = 84_001
        let bookB: Int64 = 84_002
        let tagA: Int64 = 84_101
        let tagB: Int64 = 84_102
        let tagC: Int64 = 84_103

        try await harness.write { db in
            try Self.insertBook(db, id: bookA, name: "单本替换", order: 1)
            try Self.insertBook(db, id: bookB, name: "多本追加", order: 2)
            try Self.insertTag(db, id: tagA, name: "标签 A", order: 1)
            try Self.insertTag(db, id: tagB, name: "标签 B", order: 2)
            try Self.insertTag(db, id: tagC, name: "标签 C", order: 3)
            try Self.insertTagBook(db, id: 84_201, tagID: tagA, bookID: bookA)
            try Self.insertTagBook(db, id: 84_202, tagID: tagB, bookID: bookB)
        }

        try await harness.repository.mutateBooksTags(bookIDs: [bookA], tagIDs: [tagC], mode: .replace)
        #expect(try await harness.tagIDs(bookID: bookA) == [tagC])
        #expect(try await harness.repository.fetchBookshelfBatchEditOptions(bookIDs: [bookA]).initialTagIDs == [tagC])

        try await harness.repository.mutateBooksTags(
            bookIDs: [bookA, bookB, bookA],
            tagIDs: [tagA, tagC, tagA],
            mode: .add
        )

        #expect(try await harness.tagIDs(bookID: bookA) == [tagA, tagC])
        #expect(try await harness.tagIDs(bookID: bookB) == [tagA, tagB, tagC])
        try await harness.repository.mutateBooksTags(
            bookIDs: [bookA, bookB],
            tagIDs: [tagC],
            mode: .remove
        )
        #expect(try await harness.tagIDs(bookID: bookA) == [tagA])
        #expect(try await harness.tagIDs(bookID: bookB) == [tagA, tagB])
        let staleRelationCount = try await harness.read { db in
            // SQL 目的：统计两本书标签写入后留下的墓碑 relation。
            // 涉及表：tag_book；关键过滤：book_id 在本用例集合内且 is_deleted != 0。
            // 时间字段：不参与；返回用途：强制单本替换被移除的 relation 物理 DELETE。
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM tag_book WHERE book_id IN (?, ?) AND is_deleted != 0",
                arguments: [bookA, bookB]
            ) ?? 0
        }
        #expect(staleRelationCount == 0)
    }

    @Test
    func removingCollectionRelationsRetainsReferencedPlaceholderAndDeletesItAfterLastReference() async throws {
        let harness = try BookAlignmentRepositoryHarness.make()
        defer { harness.cleanup() }
        let placeholderBookID: Int64 = 85_001
        let categoryReferencedPlaceholderID: Int64 = 85_002
        let ownerBookID: Int64 = 85_003
        let collectionA: Int64 = 85_101
        let collectionB: Int64 = 85_102
        let relationA: Int64 = 85_201
        let relationB: Int64 = 85_202
        let categoryRelation: Int64 = 85_203

        try await harness.write { db in
            try Self.insertBook(db, id: placeholderBookID, name: "双书单引用占位书", order: 0, isDeleted: 1)
            try Self.insertBook(db, id: categoryReferencedPlaceholderID, name: "相关内容引用占位书", order: 0, isDeleted: 1)
            try Self.insertBook(db, id: ownerBookID, name: "相关内容宿主书", order: 1)
            try Self.insertCollection(db, id: collectionA, title: "书单 A")
            try Self.insertCollection(db, id: collectionB, title: "书单 B")
            try Self.insertCollectionBook(db, id: relationA, collectionID: collectionA, bookID: placeholderBookID)
            try Self.insertCollectionBook(db, id: relationB, collectionID: collectionB, bookID: placeholderBookID)
            try Self.insertCollectionBook(db, id: categoryRelation, collectionID: collectionA, bookID: categoryReferencedPlaceholderID)
            try Self.insertCategoryContentReference(
                db,
                ownerBookID: ownerBookID,
                contentBookID: categoryReferencedPlaceholderID
            )
        }

        try await harness.repository.removeBooksFromCollection(collectionBookIDs: [relationA])
        #expect(try await harness.rowCount(table: "collection_book", id: relationA) == 0)
        #expect(try await harness.rowCount(table: "book", id: placeholderBookID) == 1)

        try await harness.repository.removeBooksFromCollection(collectionBookIDs: [relationB])
        #expect(try await harness.rowCount(table: "collection_book", id: relationB) == 0)
        #expect(try await harness.rowCount(table: "book", id: placeholderBookID) == 0)

        try await harness.repository.removeBooksFromCollection(collectionBookIDs: [categoryRelation])
        #expect(try await harness.rowCount(table: "collection_book", id: categoryRelation) == 0)
        #expect(try await harness.rowCount(table: "book", id: categoryReferencedPlaceholderID) == 1)
    }
}

private extension BookAlignmentRepositoryContractTests {
    nonisolated static func insertBook(
        _ db: Database,
        id: Int64,
        name: String,
        order: Int64,
        pinned: Int64 = 0,
        pinOrder: Int64 = 0,
        updatedDate: Int64 = 0,
        isDeleted: Int64 = 0
    ) throws {
        var record = BookRecord()
        record.id = id
        record.userId = 1
        record.name = name
        record.rawName = name
        record.sourceId = 0
        record.readStatusId = 1
        record.totalPosition = 100
        record.totalPagination = 100
        record.bookOrder = order
        record.pinned = pinned
        record.pinOrder = pinOrder
        record.createdDate = 100
        record.updatedDate = updatedDate
        record.isDeleted = isDeleted
        try record.insert(db)
    }

    static func insertGroup(_ db: Database, id: Int64, name: String, order: Int64) throws {
        var record = GroupRecord()
        record.id = id
        record.userId = 1
        record.name = name
        record.groupOrder = order
        record.createdDate = 100
        try record.insert(db)
    }

    static func insertGroupBook(_ db: Database, id: Int64, groupID: Int64, bookID: Int64) throws {
        var record = GroupBookRecord()
        record.id = id
        record.groupId = groupID
        record.bookId = bookID
        record.createdDate = id
        try record.insert(db)
    }

    static func insertTag(_ db: Database, id: Int64, name: String, order: Int64) throws {
        var record = TagRecord()
        record.id = id
        record.userId = 1
        record.name = name
        record.tagOrder = order
        record.type = 2
        record.createdDate = 100
        try record.insert(db)
    }

    static func insertTagBook(_ db: Database, id: Int64, tagID: Int64, bookID: Int64) throws {
        var record = TagBookRecord()
        record.id = id
        record.tagId = tagID
        record.bookId = bookID
        record.createdDate = id
        try record.insert(db)
    }

    static func insertNote(_ db: Database, id: Int64, bookID: Int64) throws {
        var record = NoteRecord(
            id: id,
            bookId: bookID,
            chapterId: 0,
            content: "批量删标签回滚书摘",
            createdDate: 100,
            updatedDate: 200
        )
        try record.insert(db)
    }

    static func insertTagNote(_ db: Database, id: Int64, tagID: Int64, noteID: Int64) throws {
        var record = TagNoteRecord(
            id: id,
            tagId: tagID,
            noteId: noteID,
            createdDate: 100
        )
        try record.insert(db)
    }

    static func insertDeletionMetadataGraph(
        _ db: Database,
        bookID: Int64,
        rowID: Int64
    ) throws {
        // SQL 目的：插入 Room 历史 read_record，覆盖当前 Record 层未建模但物理库仍保留的直接 book 外键。
        // 涉及表：read_record；关键字段：id/book_id 使用合成测试 ID。
        // 时间字段：固定为合成毫秒值；副作用仅构造删书合同数据图。
        try db.execute(
            sql: """
                INSERT INTO read_record (
                    id, book_id, start_time, end_time,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, 100, 200, 100, 200, 0, 0)
                """,
            arguments: [rowID, bookID]
        )

        var readPlan = ReadPlanRecord()
        readPlan.id = rowID
        readPlan.bookId = bookID
        readPlan.totalPageNumber = 300
        readPlan.readPageNumber = 30
        readPlan.positionType = 1
        readPlan.readStartDate = 100
        readPlan.dayReadNumber = 10
        readPlan.readInterval = 1
        readPlan.reminderTime = 200
        readPlan.description = "合成阅读计划 \(rowID)"
        readPlan.createdDate = 100
        readPlan.updatedDate = 200
        try readPlan.insert(db)

        var reminder = ReminderEventRecord()
        reminder.id = rowID
        reminder.eventId = rowID
        reminder.readPlanId = rowID
        reminder.dayReadNumber = 10
        reminder.reminderDateTime = 300
        reminder.createdDate = 100
        reminder.updatedDate = 200
        try reminder.insert(db)

        let importHash = NoteImportHashRecord(
            bookId: bookID,
            contentHash: "book-alignment-content-\(rowID)",
            noteId: rowID
        )
        try importHash.insert(db)

        var pageSync = NotionPageSyncRecord(
            id: rowID,
            connectionKey: "book-alignment-connection-\(rowID)",
            dataSourceId: "book-alignment-source-\(rowID)",
            bookId: bookID,
            syncId: "book-alignment-sync-\(rowID)",
            pageId: "book-alignment-page-\(rowID)",
            pageUrl: "https://example.invalid/book-alignment/\(rowID)",
            status: "synced",
            conflictCount: 0,
            firstSyncDate: 100,
            lastSyncDate: 200
        )
        try pageSync.insert(db)

        var blockSync = NotionBlockSyncRecord(
            id: rowID,
            pageSyncId: rowID,
            unitKey: "book-alignment-unit-\(rowID)",
            contentType: "note",
            sourceId: rowID,
            sourceUpdatedDate: 100,
            sourceFingerprint: "source-fingerprint-\(rowID)",
            remoteFingerprint: "remote-fingerprint-\(rowID)",
            blockIdsJson: "[]",
            anchorKey: "anchor-\(rowID)",
            deletable: true,
            state: "synced",
            lastSyncDate: 200
        )
        try blockSync.insert(db)

        let operation = NotionSyncOperationRecord(
            operationId: notionOperationID(rowID),
            pageSyncId: rowID,
            unitKey: "book-alignment-unit-\(rowID)",
            operationType: "replace",
            state: "pending",
            oldBlockIdsJson: "[]",
            newBlockIdsJson: "[]",
            blocksJson: "[]",
            sourceFingerprint: "source-fingerprint-\(rowID)",
            sourceUpdatedDate: 100,
            createdDate: 100,
            updatedDate: 200
        )
        try operation.insert(db)
    }

    static func notionOperationID(_ rowID: Int64) -> String {
        "book-alignment-operation-\(rowID)"
    }

    static func insertCollection(_ db: Database, id: Int64, title: String) throws {
        var record = CollectionRecord()
        record.id = id
        record.title = title
        record.createdDate = 100
        try record.insert(db)
    }

    static func insertCollectionBook(
        _ db: Database,
        id: Int64,
        collectionID: Int64,
        bookID: Int64
    ) throws {
        var record = CollectionBookRecord()
        record.id = id
        record.collectionId = collectionID
        record.bookId = bookID
        record.createdDate = 100
        try record.insert(db)
    }

    static func insertCategoryContentReference(
        _ db: Database,
        ownerBookID: Int64,
        contentBookID: Int64
    ) throws {
        var category = CategoryRecord()
        category.id = 85_301
        category.bookId = ownerBookID
        category.title = "占位书引用分类"
        category.createdDate = 100
        try category.insert(db)

        var content = CategoryContentRecord()
        content.id = 85_401
        content.categoryId = 85_301
        content.bookId = ownerBookID
        content.contentBookId = contentBookID
        content.title = "引用占位书"
        content.createdDate = 100
        try content.insert(db)
    }
}

@MainActor
private final class BookAlignmentRepositoryHarness {
    let workingDirectoryURL: URL
    let database: AppDatabase
    let repository: BookRepository

    private init(workingDirectoryURL: URL, database: AppDatabase) {
        self.workingDirectoryURL = workingDirectoryURL
        self.database = database
        repository = BookRepository(databaseManager: DatabaseManager(database: database))
    }

    static func make() throws -> BookAlignmentRepositoryHarness {
        let workingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmnote-book-contract-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workingDirectoryURL,
                withIntermediateDirectories: true
            )
            let databaseURL = workingDirectoryURL.appendingPathComponent("contract.db")
            let database = try AppDatabase(path: databaseURL.path)
            try database.dbPool.write { db in
                try installLegacyReadRecordSchema(db)
            }
            return BookAlignmentRepositoryHarness(
                workingDirectoryURL: workingDirectoryURL,
                database: database
            )
        } catch {
            try? FileManager.default.removeItem(at: workingDirectoryURL)
            throw error
        }
    }

    /// 为合成合同库补入 Pixel B0 仍保留、但新建 Room v47 库不创建的旧版阅读记录表。
    private static func installLegacyReadRecordSchema(_ db: Database) throws {
        // SQL 目的：复刻 Pixel 真实恢复库中的 legacy read_record 物理表，覆盖删书兼容清理。
        // 涉及表：read_record、book；关键约束：book_id NO ACTION 外键与 B0 一致。
        // 时间字段：仅声明表结构所需列，不写运行时值；副作用仅限临时合同库。
        try db.execute(
            sql: """
                CREATE TABLE IF NOT EXISTS read_record (
                    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                    book_id INTEGER NOT NULL,
                    start_time INTEGER NOT NULL DEFAULT 0,
                    end_time INTEGER NOT NULL DEFAULT 0,
                    created_date INTEGER NOT NULL,
                    updated_date INTEGER NOT NULL,
                    last_sync_date INTEGER NOT NULL,
                    is_deleted INTEGER NOT NULL,
                    FOREIGN KEY (book_id) REFERENCES book (id)
                        ON DELETE NO ACTION ON UPDATE NO ACTION
                )
                """
        )

        // SQL 目的：复刻 B0 对 legacy read_record.book_id 的查询索引。
        // 涉及表：read_record；关键字段：book_id；时间字段：不参与。
        // 副作用用途：保持旧库清理场景的物理结构与真实基准一致。
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS index_read_record_book_id ON read_record(book_id)"
        )
    }

    func write(_ updates: (Database) throws -> Void) async throws {
        try await database.dbPool.write { db in
            try updates(db)
        }
    }

    func read<Value>(_ value: (Database) throws -> Value) async throws -> Value {
        try await database.dbPool.read { db in
            try value(db)
        }
    }

    func firstObservedBookIDs() async throws -> [Int64] {
        var iterator = repository.observeBooks().makeAsyncIterator()
        return try await iterator.next()?.map(\.id) ?? []
    }

    func firstGroupBookIDs(groupID: Int64) async throws -> [Int64] {
        var iterator = repository.observeBookshelfBookList(
            context: .defaultGroup(groupID),
            setting: .defaultBookListValue(for: .default),
            searchKeyword: nil
        ).makeAsyncIterator()
        return try await iterator.next()?.books.map(\.id) ?? []
    }

    func tagIDs(bookID: Int64) async throws -> [Int64] {
        try await read { db in
            // SQL 目的：读取单本书全部现存 tag_book 行的 tag_id，同时暴露不应存在的墓碑。
            // 涉及表：tag_book；关键过滤：book_id 精确匹配，不过滤 is_deleted。
            // 时间字段：不参与；返回字段：tag_id 按主键顺序供集合断言。
            try Int64.fetchAll(
                db,
                sql: "SELECT tag_id FROM tag_book WHERE book_id = ? ORDER BY tag_id ASC, id ASC",
                arguments: [bookID]
            )
        }
    }

    func rowCount(table: String, id: Int64) async throws -> Int {
        try await read { db in
            let allowedTables = ["book", "collection_book"]
            guard allowedTables.contains(table) else { return -1 }
            // SQL 目的：按主键统计书或书单关系的物理行，区分 DELETE 与 is_deleted 墓碑。
            // 涉及表：只允许 book/collection_book 白名单；关键过滤：id 精确匹配，不过滤 is_deleted。
            // 时间字段：不参与；返回用途：验证占位书引用计数收敛后的物理清理。
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE id = ?",
                arguments: [id]
            ) ?? 0
        }
    }

    func cleanup() {
        database.interrupt()
        try? database.close()
        try? FileManager.default.removeItem(at: workingDirectoryURL)
    }
}
