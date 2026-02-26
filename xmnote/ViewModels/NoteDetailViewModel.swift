import Foundation
import GRDB
import UIKit

@MainActor
@Observable
class NoteDetailViewModel {
    struct Metadata {
        let position: String
        let positionUnit: Int64
        let includeTime: Bool
        let createdDate: Int64

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

    let noteId: Int64

    var contentText = NSAttributedString()
    var ideaText = NSAttributedString()
    var contentFormats = Set<RichTextFormat>()
    var ideaFormats = Set<RichTextFormat>()
    var selectedHighlightARGB: UInt32 = HighlightColors.defaultHighlightColor

    var metadata: Metadata?
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    private let database: AppDatabase

    init(noteId: Int64, database: AppDatabase) {
        self.noteId = noteId
        self.database = database
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let payload = try await database.dbPool.read { db in
                try Self.fetchNotePayload(db: db, noteId: noteId)
            }
            guard let payload else {
                errorMessage = "笔记不存在或已删除"
                return
            }

            contentText = RichTextBridge.htmlToAttributed(payload.contentHTML)
            ideaText = RichTextBridge.htmlToAttributed(payload.ideaHTML)
            metadata = Metadata(
                position: payload.position,
                positionUnit: payload.positionUnit,
                includeTime: payload.includeTime,
                createdDate: payload.createdDate
            )
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    func save() async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let contentHTML = RichTextBridge.attributedToHtml(contentText)
        let ideaHTML = RichTextBridge.attributedToHtml(ideaText)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        do {
            try await database.dbPool.write { db in
                try db.execute(
                    sql: """
                        UPDATE note
                        SET content = ?, idea = ?, updated_date = ?
                        WHERE id = ? AND is_deleted = 0
                    """,
                    arguments: [contentHTML, ideaHTML, now, noteId]
                )
            }
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}

private extension NoteDetailViewModel {
    struct Payload {
        let contentHTML: String
        let ideaHTML: String
        let position: String
        let positionUnit: Int64
        let includeTime: Bool
        let createdDate: Int64
    }

    nonisolated static func fetchNotePayload(db: Database, noteId: Int64) throws -> Payload? {
        let sql = """
            SELECT content, idea, position, position_unit, include_time, created_date
            FROM note
            WHERE id = ? AND is_deleted = 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [noteId]) else {
            return nil
        }

        return Payload(
            contentHTML: row["content"] ?? "",
            ideaHTML: row["idea"] ?? "",
            position: row["position"] ?? "",
            positionUnit: row["position_unit"] ?? 0,
            includeTime: (row["include_time"] as Int64? ?? 1) != 0,
            createdDate: row["created_date"] ?? 0
        )
    }
}
