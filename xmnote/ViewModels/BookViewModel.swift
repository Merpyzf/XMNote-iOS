//
//  BookViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

import Foundation
import GRDB

// MARK: - BookItem

struct BookItem: Identifiable {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let readStatusId: Int64
    let noteCount: Int
    let pinned: Bool
}

// MARK: - ReadStatusFilter

enum ReadStatusFilter: CaseIterable, Identifiable {
    case all, unread, reading, finished, onHold

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .unread: "未读"
        case .reading: "在读"
        case .finished: "已读"
        case .onHold: "搁置"
        }
    }

    /// 对应 read_status 表的 id：1=未读 2=在读 3=已读 4=搁置
    var statusId: Int64? {
        switch self {
        case .all: nil
        case .unread: 1
        case .reading: 2
        case .finished: 3
        case .onHold: 4
        }
    }
}

// MARK: - BookViewModel

@Observable
class BookViewModel {
    var books: [BookItem] = []
    var selectedFilter: ReadStatusFilter = .all

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    init(database: AppDatabase) {
        self.database = database
        startObservation()
    }

    var filteredBooks: [BookItem] {
        guard let statusId = selectedFilter.statusId else { return books }
        return books.filter { $0.readStatusId == statusId }
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Observation

    private func startObservation() {
        observationTask = Task {
            let observation = ValueObservation.tracking { db in
                try Self.fetchBooks(db)
            }
            do {
                for try await items in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.books = items }
                }
            } catch {
                print("BookViewModel observation error: \(error)")
            }
        }
    }

    // MARK: - Query

    private static func fetchBooks(_ db: Database) throws -> [BookItem] {
        let sql = """
            SELECT b.id, b.name, b.author, b.cover,
                   b.read_status_id, b.pinned, b.pin_order, b.book_order,
                   COUNT(n.id) AS note_count
            FROM book b
            LEFT JOIN note n ON b.id = n.book_id AND n.is_deleted = 0
            WHERE b.is_deleted = 0
            GROUP BY b.id
            ORDER BY b.pinned DESC, b.pin_order ASC, b.book_order ASC
            """
        let rows = try Row.fetchAll(db, sql: sql)

        return rows.map { row in
            BookItem(
                id: row["id"],
                name: row["name"] ?? "",
                author: row["author"] ?? "",
                cover: row["cover"] ?? "",
                readStatusId: row["read_status_id"] ?? 0,
                noteCount: row["note_count"] ?? 0,
                pinned: (row["pinned"] as Int64? ?? 0) != 0
            )
        }
    }
}
