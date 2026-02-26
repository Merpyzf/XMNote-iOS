//
//  BookDetailViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

import Foundation
import GRDB

// MARK: - BookDetail

struct BookDetail: Identifiable {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let press: String
    let noteCount: Int
    let readStatusName: String
}

// MARK: - NoteExcerpt

struct NoteExcerpt: Identifiable {
    let id: Int64
    let content: String
    let idea: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64

    /// 格式化底部信息：位置 | 时间
    var footerText: String {
        var parts: [String] = []
        if !position.isEmpty {
            let unit = switch positionUnit {
            case 1: "位置"
            case 2: "%"
            default: "页"
            }
            parts.append(positionUnit == 2 ? "\(position)\(unit)" : "第\(position)\(unit)")
        }
        if includeTime, createdDate > 0 {
            parts.append(Self.formatDate(createdDate))
        }
        return parts.joined(separator: " | ")
    }

    private static func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

// MARK: - BookDetailViewModel

@Observable
class BookDetailViewModel {
    var book: BookDetail?
    var notes: [NoteExcerpt] = []

    private let bookId: Int64
    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?

    init(bookId: Int64, database: AppDatabase) {
        self.bookId = bookId
        self.database = database
    }

    var hasNotes: Bool { !notes.isEmpty }

    func startObservation() {
        observationTask = Task {
            let observation = ValueObservation.tracking { [bookId] db in
                try Self.fetchData(db, bookId: bookId)
            }
            do {
                for try await (book, notes) in observation.values(in: database.dbPool) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.book = book
                        self.notes = notes
                    }
                }
            } catch {
                print("BookDetailViewModel observation error: \(error)")
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Query

    private static func fetchData(
        _ db: Database, bookId: Int64
    ) throws -> (BookDetail?, [NoteExcerpt]) {
        let book = try fetchBook(db, bookId: bookId)
        let notes = try fetchNotes(db, bookId: bookId)
        return (book, notes)
    }

    private static func fetchBook(_ db: Database, bookId: Int64) throws -> BookDetail? {
        let sql = """
            SELECT b.id, b.name, b.author, b.cover, b.press,
                   COALESCE(rs.name, '') AS read_status_name,
                   (SELECT COUNT(*) FROM note n
                    WHERE n.book_id = b.id AND n.is_deleted = 0) AS note_count
            FROM book b
            LEFT JOIN read_status rs ON b.read_status_id = rs.id
            WHERE b.id = ? AND b.is_deleted = 0
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [bookId]) else {
            return nil
        }
        return BookDetail(
            id: row["id"],
            name: row["name"] ?? "",
            author: row["author"] ?? "",
            cover: row["cover"] ?? "",
            press: row["press"] ?? "",
            noteCount: row["note_count"] ?? 0,
            readStatusName: row["read_status_name"] ?? ""
        )
    }

    private static func fetchNotes(_ db: Database, bookId: Int64) throws -> [NoteExcerpt] {
        let sql = """
            SELECT id, content, idea, position, position_unit,
                   include_time, created_date
            FROM note
            WHERE book_id = ? AND is_deleted = 0
            ORDER BY created_date DESC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [bookId])
        return rows.map { row in
            NoteExcerpt(
                id: row["id"],
                content: row["content"] ?? "",
                idea: row["idea"] ?? "",
                position: row["position"] ?? "",
                positionUnit: row["position_unit"] ?? 0,
                includeTime: (row["include_time"] as Int64? ?? 1) != 0,
                createdDate: row["created_date"] ?? 0
            )
        }
    }
}
