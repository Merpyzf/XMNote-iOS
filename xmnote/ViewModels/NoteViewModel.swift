//
//  NoteViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import Foundation
import GRDB

@Observable
class NoteViewModel {
    var selectedCategory: NoteCategory = .excerpts
    var searchText: String = ""
    var tagSections: [TagSection] = []

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    init(database: AppDatabase) {
        self.database = database
        startObservation()
    }

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

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Observation

    private func startObservation() {
        observationTask = Task {
            let observation = ValueObservation.tracking { db in
                try Self.fetchTagSections(db)
            }
            do {
                for try await sections in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.tagSections = sections }
                }
            } catch {
                // observation 被取消时静默处理
            }
        }
    }

    // MARK: - Query

    /// 查询标签并按 type 分组，每个标签附带关联笔记数
    private static func fetchTagSections(_ db: Database) throws -> [TagSection] {
        let sql = """
            SELECT t.id, t.name, t.type, t.tag_order,
                   COUNT(tn.id) AS note_count
            FROM tag t
            LEFT JOIN tag_note tn ON t.id = tn.tag_id AND tn.is_deleted = 0
            WHERE t.is_deleted = 0
            GROUP BY t.id
            ORDER BY t.type ASC, t.tag_order ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)

        var noteTagItems: [Tag] = []
        var bookTagItems: [Tag] = []

        for row in rows {
            let id: Int64 = row["id"]
            let name: String = row["name"] ?? ""
            let type: Int64 = row["type"]
            let noteCount: Int = row["note_count"]
            let tag = Tag(id: id, name: name, noteCount: noteCount)

            if type == 0 {
                noteTagItems.append(tag)
            } else {
                bookTagItems.append(tag)
            }
        }

        var sections: [TagSection] = []
        if !noteTagItems.isEmpty {
            sections.append(TagSection(id: 0, title: "笔记标签", tags: noteTagItems))
        }
        if !bookTagItems.isEmpty {
            sections.append(TagSection(id: 1, title: "书籍标签", tags: bookTagItems))
        }
        return sections
    }
}
