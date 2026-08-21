/**
 * [INPUT]: 依赖 AppDatabase.empty 已有用户/来源/阅读状态 seed、Room v44 book 外键与 GRDB Record
 * [OUTPUT]: 提供目录管理测试共享的最小合法书籍 fixture
 * [POS]: xmnoteTests 的目录管理数据库 fixture，保证测试初始状态满足真实 schema
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import GRDB
@testable import xmnote

/// 复用空数据库已有的系统用户写入测试书籍，避免绕过或重复 Room 外键记录。
func insertValidChapterTestBook(
    _ db: Database,
    id: Int64,
    name: String
) throws {
    var book = BookRecord(id: id, name: name)
    book.userId = 1
    book.readStatusId = 1
    try book.insert(db)
}
