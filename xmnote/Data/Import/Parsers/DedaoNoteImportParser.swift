/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收得到 App 剪贴板文本
 * [OUTPUT]: 对外提供 DedaoNoteImportParser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的得到实现，保留 Android 空白项和反序等现有特殊语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct DedaoNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .dedao

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let source = try NoteImportTextSupport.decodeUTF8(data).replacingOccurrences(of: " ", with: "")
        guard source.contains("——来自得到App") else { throw NoteImportParserError.noteFormat }
        let bookLines = source.components(separatedBy: "\n")
        guard let title = bookLines.first else { throw NoteImportParserError.bookNotFound }

        var book = NoteImportDraftBook()
        book.name = clearQuotationMarks(title)
        book.rawName = book.name
        book.author = bookLines.indices.contains(1) ? bookLines[1] : ""
        book.type = 1
        book.positionUnit = 1
        book.currentPositionUnit = 1

        let firstSection = source.components(separatedBy: "\n\n").first ?? ""
        let noteText = source
            .replacingOccurrences(of: firstSection, with: "")
            .replacingOccurrences(of: "——来自得到App", with: "")
        let chapterSections = noteText.components(separatedBy: "\n\n\n")
            .map(NoteImportTextSupport.trimmed)
            .filter { !NoteImportTextSupport.isBlank($0) }
        var notes: [NoteImportDraftNote] = []
        for chapterSection in chapterSections {
            guard let chapterTitle = chapterSection.components(separatedBy: "\n").first else { continue }
            let contentSection = chapterSection.replacingOccurrences(of: chapterTitle, with: "")
            for noteText in contentSection.components(separatedBy: "\n\n") {
                let pieces = noteText.components(separatedBy: "----------")
                guard !pieces.isEmpty else { continue }
                let content: String
                let idea: String
                if pieces.count == 1 {
                    content = NoteImportTextSupport.trimmed(pieces[0]).replacingOccurrences(of: "原文：", with: "")
                    idea = ""
                } else {
                    content = NoteImportTextSupport.trimmed(pieces[1]).replacingOccurrences(of: "原文：", with: "")
                    idea = NoteImportTextSupport.trimmed(pieces[0]).replacingOccurrences(of: "* ", with: "")
                }
                notes.append(NoteImportDraftNote(
                    content: content,
                    idea: idea,
                    positionUnit: 1,
                    createdTime: 0,
                    isIncludeTime: false,
                    chapter: NoteImportDraftChapter(title: chapterTitle)
                ))
            }
        }
        guard !notes.isEmpty else { throw NoteImportParserError.noteNotFound }
        book.notes = notes.reversed()
        return [book]
    }

    private func clearQuotationMarks(_ value: String) -> String {
        value.replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
            .replacingOccurrences(of: "<<", with: "")
            .replacingOccurrences(of: ">>", with: "")
    }
}
