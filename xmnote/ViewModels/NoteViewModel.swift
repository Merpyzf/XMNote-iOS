//
//  NoteViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import Foundation

@Observable
class NoteViewModel {
    var selectedCategory: NoteCategory = .excerpts
    var searchText: String = ""
    var tagSections: [TagSection] = []

    var filteredSections: [TagSection] {
        guard !searchText.isEmpty else { return tagSections }
        return tagSections.compactMap { section in
            let filtered = section.tags.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return TagSection(id: section.id, title: section.title, tags: filtered)
        }
    }

    init() {
        loadMockData()
    }

    private func loadMockData() {
        let myTags = TagSection(title: "我的标签", tags: [
            Tag(name: "人生感悟", noteCount: 12),
            Tag(name: "经典语录", noteCount: 8),
            Tag(name: "读书方法", noteCount: 5),
            Tag(name: "写作技巧", noteCount: 3),
            Tag(name: "历史故事", noteCount: 7),
            Tag(name: "哲学思考", noteCount: 4),
        ])

        let defaultTags = TagSection(title: "默认标签", tags: [
            Tag(name: "待整理", noteCount: 15),
            Tag(name: "重要", noteCount: 6),
            Tag(name: "收藏", noteCount: 9),
            Tag(name: "灵感", noteCount: 2),
        ])

        tagSections = [myTags, defaultTags]
    }
}
