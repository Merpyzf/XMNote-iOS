/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收当当云阅读剪贴板文本
 * [OUTPUT]: 对外提供 DangdangNoteImportParser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的当当实现，保留 Android 行索引、空行与注释绑定语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct DangdangNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .dangdang

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data).replacingOccurrences(of: "\r\n", with: "\n")
        guard NoteImportTextSupport.contains(
            pattern: "\\n\\n(.|\\n)+?\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}",
            in: content
        ) else { throw NoteImportParserError.noteFormat }
        let sections = content.components(separatedBy: "\n\n")
            .filter { !NoteImportTextSupport.isBlank($0) }
        guard let info = sections.first else { throw NoteImportParserError.bookNotFound }
        let infoLines = info.components(separatedBy: "\n")
        guard let title = infoLines.first, !NoteImportTextSupport.isBlank(title) else {
            throw NoteImportParserError.bookNotFound
        }

        var book = NoteImportDraftBook()
        book.name = title
        book.rawName = title
        book.author = infoLines.indices.contains(1) ? infoLines[1] : ""
        book.type = 1
        book.positionUnit = 1
        book.currentPositionUnit = 1

        for section in sections.dropFirst() {
            let items = section.components(separatedBy: "\n")
            let chapterTitle = items.first ?? ""
            let lines = Array(items.dropFirst())
            let withoutDates = lines.filter { !isDate($0) }
            for index in withoutDates.indices where !withoutDates[index].hasPrefix("注:") {
                let noteContent = withoutDates[index]
                let idea = withoutDates.indices.contains(index + 1) && withoutDates[index + 1].hasPrefix("注:")
                    ? String(withoutDates[index + 1].dropFirst(2))
                    : ""
                let originalIndex = lines.firstIndex(of: noteContent) ?? 0
                let dateText = originalIndex > 0 ? lines[originalIndex - 1] : ""
                let createdTime = NoteImportTextSupport.androidDateMilliseconds(dateText)
                book.notes.append(NoteImportDraftNote(
                    content: noteContent,
                    idea: idea,
                    positionUnit: 1,
                    createdTime: createdTime,
                    isIncludeTime: createdTime != 0,
                    chapter: NoteImportDraftChapter(title: chapterTitle)
                ))
            }
        }
        return [book]
    }

    private func isDate(_ value: String) -> Bool {
        NoteImportTextSupport.contains(pattern: "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}", in: value)
    }
}
