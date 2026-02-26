//
//  Tag.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

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
