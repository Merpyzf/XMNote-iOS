//
//  Tag.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import Foundation

struct Tag: Identifiable {
    let id: UUID
    let name: String
    let noteCount: Int

    init(id: UUID = UUID(), name: String, noteCount: Int) {
        self.id = id
        self.name = name
        self.noteCount = noteCount
    }
}

struct TagSection: Identifiable {
    let id: UUID
    let title: String
    let tags: [Tag]

    init(id: UUID = UUID(), title: String, tags: [Tag]) {
        self.id = id
        self.title = title
        self.tags = tags
    }
}
