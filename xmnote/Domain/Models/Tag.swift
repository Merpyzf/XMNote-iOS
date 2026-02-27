/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 Tag、TagSection 两个标签域展示模型
 * [POS]: Domain/Models 的标签聚合模型定义，被 NoteViewModel 与标签视图消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 标签视图模型，从 TagRecord + tag_note COUNT 聚合而来
struct Tag: Identifiable {
    let id: Int64
    let name: String
    let noteCount: Int

    init(id: Int64, name: String, noteCount: Int) {
        self.id = id
        self.name = name
        self.noteCount = noteCount
    }
}

/// 标签分组，按 type 区分（笔记标签 / 书籍标签）
struct TagSection: Identifiable {
    let id: Int64
    let title: String
    let tags: [Tag]

    init(id: Int64, title: String, tags: [Tag]) {
        self.id = id
        self.title = title
        self.tags = tags
    }
}
