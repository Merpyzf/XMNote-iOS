/**
 * [INPUT]: 依赖同一 GRDB 只读快照与回顾筛选条件
 * [OUTPUT]: 提供最多 1024 个身份/版本的主键游标批次及实际查询计划
 * [POS]: Data 回顾目录的业务库只读适配，不修改业务索引、schema 或原有筛选语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 元数据扫描使用主键游标，展示顺序在派生索引中产生，避免每一批在业务表重做随机排序。
nonisolated struct NoteReviewDirectorySourceQuery: Sendable {
    let request: NoteReviewDirectoryRequest

    /// 调用者在同一 DatabaseSnapshot 队列执行；单次返回固定尺寸记录，完全不读取正文、图片和标签展示模型。
    func read(_ db: Database, after noteID: Int64?, limit: Int) throws -> [NoteReviewDirectoryRecord] {
        let query = sql(after: noteID, limit: limit)
        return try Row.fetchAll(db, sql: query.text, arguments: query.arguments).map { row in
            .init(noteID: row["note_id"], bookID: row["book_id"], chapterID: row["chapter_id"],
                  noteRevision: row["note_revision"], bookRevision: row["book_revision"], chapterRevision: row["chapter_revision"])
        }
    }

    /// 验证真实 WHERE 条件下的游标访问计划；不能以使用 LIMIT 就推断没有全表扫描。
    func queryPlan(_ db: Database, after noteID: Int64?) throws -> [String] {
        let query = sql(after: noteID, limit: 1_024)
        // SQL：EXPLAIN 不执行读取，只返回下面元数据查询的实际索引/排序选择。
        return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + query.text, arguments: query.arguments).map { $0["detail"] }
    }

    /// 书籍、标签任一/全部规则与现有回顾保持一致；游标仅影响批次，不改变最终成员集合。
    private func sql(after noteID: Int64?, limit: Int) -> (text: String, arguments: StatementArguments) {
        var predicates = ["n.is_deleted = 0", "n.id > ?"]
        var values: [Int64] = [noteID ?? 0]
        if !request.bookIDs.isEmpty {
            predicates.append("n.book_id IN (\(placeholders(request.bookIDs.count)))")
            values += request.bookIDs
        }
        if !request.tagIDs.isEmpty {
            let selection = request.tagMatchRule == .all ? "COUNT(DISTINCT tn.tag_id)" : "1"
            var tagQuery = """
                (SELECT \(selection) FROM tag_note tn INDEXED BY index_tag_note_note_id
                JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
                WHERE tn.note_id = n.id AND tn.is_deleted = 0 AND tn.tag_id IN (\(placeholders(request.tagIDs.count)))
                """
            values += request.tagIDs
            if request.tagMatchRule == .all {
                tagQuery += ") = ?"
                values.append(Int64(request.tagIDs.count))
            } else {
                tagQuery = "EXISTS " + tagQuery + ")"
            }
            predicates.append(tagQuery)
        }
        values.append(Int64(max(1, min(1_024, limit))))
        // SQL 目的：按主键 seek 分批读取可回顾成员元数据，供独立目录排序和版本校验。
        // 表关系：note 主表，book/chapter 左连接补充关联版本；有效非根章节规则与原回顾一致。
        // 条件：有效 note、同一书籍范围、相同 tag_note/tag 任一或全部匹配，排除无效和非书摘标签。
        // 标签按本条 note_id 相关查询，避免每一页先物化整份标签成员；any 使用 EXISTS，all 仅对本条关系计 DISTINCT。
        // 显式使用 Room 已有 note_id 索引；实际计划曾反向选中 tag_id 索引，导致每条 note 重扫标签的全部关系。
        // 时间：三个 updated_date 保留 Android Unix 毫秒值，不做时区换算；NULL/无关联回填 0。
        // 返回：只有身份、关联身份、revision；不读取 content/idea/name/title/封面/图片或操作上下文。
        // 展示顺序：本扫描顺序不是回顾顺序；后者由派生 records_order 索引按原 book_id DESC/id ASC 或固定 seed 决定。
        // 多书籍 IN 禁止选择 book_id 索引后逐页全局排序；NOT INDEXED 仍允许 note 的 rowid 主键 seek，单书保留复合 book_id/rowid 范围。
        let text = """
            SELECT n.id AS note_id, n.book_id, n.chapter_id,
                   COALESCE(n.updated_date, 0) AS note_revision,
                   COALESCE(b.updated_date, 0) AS book_revision,
                   COALESCE(c.updated_date, 0) AS chapter_revision
            FROM note n \(request.bookIDs.count > 1 ? "NOT INDEXED" : "")
            LEFT JOIN book b ON b.id = n.book_id
            LEFT JOIN chapter c ON c.id = n.chapter_id AND c.id != 0 AND c.is_deleted = 0
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY n.id ASC LIMIT ?
            """
        return (text, StatementArguments(values))
    }

    /// 仅插入占位符，所有用户筛选值仍经绑定传入 SQL。
    private func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }
}

/// 只在元数据扫描期间持有业务读取快照；EOF 后释放，避免排序/栅格准备继续阻止业务 WAL 回收。
actor NoteReviewDirectorySourceReader {
    private let pool: DatabasePool
    private let query: NoteReviewDirectorySourceQuery
    private var snapshot: DatabaseSnapshot?

    /// 注入仓储连接池但不立即打开；首次异步读取在此 actor 的执行器上创建一致性快照。
    init(pool: DatabasePool, request: NoteReviewDirectoryRequest) {
        self.pool = pool
        query = NoteReviewDirectorySourceQuery(request: request)
    }

    /// 逐批读取允许任务取消；结束即释放源快照，旧检查点失效后的新扫描从 cursor=nil 重新建立快照。
    func read(after cursor: Int64?, limit: Int) async throws -> [NoteReviewDirectoryRecord] {
        try Task.checkCancellation()
        if snapshot == nil {
            guard cursor == nil else { throw NoteReviewDirectoryError.closed }
            snapshot = try pool.makeSnapshot()
        }
        guard let source = snapshot else { throw NoteReviewDirectoryError.closed }
        let query = query
        do {
            let result = try await source.read { try query.read($0, after: cursor, limit: limit) }
            try Task.checkCancellation()
            if result.isEmpty { snapshot = nil }
            return result
        } catch {
            snapshot = nil
            throw error
        }
    }
}
