/**
 * [INPUT]: 依赖汉王分享页首个 p 标签提取的文本与用户填写书名
 * [OUTPUT]: 对外提供 HanWangNoteImportParser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的汉王实现，对齐 Android HanWangParser
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct HanWangNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .hanwang
    let bookTitle: String

    init(bookTitle: String) { self.bookTitle = bookTitle }

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        var book = NoteImportDraftBook(); book.name = bookTitle; book.rawName = bookTitle; book.type = 1; book.positionUnit = 0; book.currentPositionUnit = 0
        for item in content.components(separatedBy: "\n\n") where !NoteImportTextSupport.isBlank(item) {
            let progress = NoteImportTextSupport.firstCapture(pattern: "\\((\\d+)%.*", in: item) ?? ""
            let hasIdea = item.contains("\n笔记：")
            let noteContent = NoteImportTextSupport.firstCapture(pattern: hasIdea ? "\\)((.|\\n)*?)笔记" : "\\)((.|\\n)*)", in: item) ?? ""
            let idea = hasIdea ? (NoteImportTextSupport.firstCapture(pattern: "笔记：((.|\\n)*)", in: item) ?? "") : ""
            if !NoteImportTextSupport.isBlank(noteContent) || !NoteImportTextSupport.isBlank(idea) {
                book.notes.append(NoteImportDraftNote(content: noteContent, idea: idea, position: progress, positionUnit: 0, isIncludeTime: false))
            }
        }
        guard !book.notes.isEmpty else { throw NoteImportParserError.noteNotFound }
        return [book]
    }
}
