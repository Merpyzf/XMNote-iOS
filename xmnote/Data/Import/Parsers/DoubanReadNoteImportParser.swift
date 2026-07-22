/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收豆瓣阅读文本导出字节
 * [OUTPUT]: 对外提供 DoubanReadNoteImportParser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的豆瓣阅读实现，保持 Android 三换行分段与章节前缀规则
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct DoubanReadNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .doubanRead

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data).replacingOccurrences(of: "\r", with: "")
        let parts = content.components(separatedBy: "\n\n\n")
        guard let header = parts.first else { throw NoteImportParserError.noteFormat }
        let bookName = NoteImportTextSupport.firstCapture(pattern: "^#《(.+?)》", in: header) ?? ""
        guard !NoteImportTextSupport.isBlank(bookName) else { throw NoteImportParserError.bookNotFound }

        var book = NoteImportDraftBook()
        book.name = bookName
        book.rawName = bookName
        book.type = 1
        book.positionUnit = 1
        book.currentPositionUnit = 1

        var currentChapter = ""
        for item in parts.dropFirst() {
            if item.hasPrefix("##") {
                currentChapter = normalizeChapter(String(item.dropFirst(2)))
                continue
            }
            guard item.hasPrefix(">") else { continue }
            let noteParts = item.components(separatedBy: "\n\n")
            var note = NoteImportDraftNote()
            if noteParts.count == 2 {
                note.positionUnit = 1
                note.content = formattedContent(noteParts[0])
                note.idea = noteParts[1]
            } else {
                note.content = formattedContent(item)
            }
            note.isIncludeTime = false
            if !currentChapter.isEmpty {
                note.chapter = NoteImportDraftChapter(title: currentChapter)
            }
            book.notes.append(note)
        }
        return [book]
    }

    private func normalizeChapter(_ value: String) -> String {
        var result = NoteImportTextSupport.trimmed(value)
        if result.hasPrefix("章节：") {
            result.removeFirst("章节：".count)
        } else if result.hasPrefix("章节:") {
            result.removeFirst("章节:".count)
        }
        return NoteImportTextSupport.trimmed(result)
    }

    private func formattedContent(_ value: String) -> String {
        var result = ""
        for line in value.components(separatedBy: "\n") where line.hasPrefix(">") {
            result += String(line.dropFirst()) + "\n"
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
