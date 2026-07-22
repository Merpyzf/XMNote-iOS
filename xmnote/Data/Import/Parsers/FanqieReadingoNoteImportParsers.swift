/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收番茄小说和 Readingo 文本
 * [OUTPUT]: 对外提供 FanqieNoteImportParser 与 ReadingoNoteImportParser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的新式剪贴板状态机实现，逐项保留 Android 默认值与保存条件
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct FanqieNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .fanqie

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        guard let title = NoteImportTextSupport.firstCapture(pattern: "《(.+)》\\n(.+)\\n.+个笔记", in: content, group: 1),
              let author = NoteImportTextSupport.firstCapture(pattern: "《(.+)》\\n(.+)\\n.+个笔记", in: content, group: 2),
              !NoteImportTextSupport.isBlank(title)
        else { throw NoteImportParserError.bookNotFound }
        guard let marker = content.range(of: "个笔记") else { throw NoteImportParserError.noteNotFound }
        let body = NoteImportTextSupport.trimmed(String(content[marker.upperBound...]))
        guard !NoteImportTextSupport.isBlank(body) else { throw NoteImportParserError.noteNotFound }

        var chapters: [NoteImportDraftChapter] = []
        if let expression = try? NSRegularExpression(pattern: "\\*([^*]+)\\*") {
            for match in expression.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let range = Range(match.range(at: 1), in: body) {
                    chapters.append(NoteImportDraftChapter(title: String(body[range])))
                }
            }
        }
        var book = makeEBook(name: title, author: author)
        let chapterBodies = splitFanqieChapters(body).filter { !NoteImportTextSupport.isBlank($0) }
        for (index, chapterBody) in chapterBodies.enumerated() {
            for noteText in chapterBody.components(separatedBy: "\n\n") where !NoteImportTextSupport.isBlank(noteText) {
                guard var note = fanqieNote(noteText) else { continue }
                if chapters.indices.contains(index) { note.chapter = chapters[index] }
                book.notes.append(note)
            }
        }
        return [book]
    }

    private func fanqieNote(_ value: String) -> NoteImportDraftNote? {
        if value.contains("添加书签") { return nil }
        if let range = value.range(of: " 添加划线") {
            let original = NoteImportTextSupport.trimmed(String(value[range.upperBound...]))
            if !original.isEmpty {
                let date = NoteImportTextSupport.firstCapture(pattern: "(\\d{4}/\\d{2}/\\d{2}) 添加划线", in: value)
                    .map { NoteImportTextSupport.dateMilliseconds($0, format: "yyyy/MM/dd") } ?? 0
                return NoteImportDraftNote(content: original, createdTime: date)
            }
        }
        if let range = value.range(of: " 添加笔记") {
            let idea = NoteImportTextSupport.trimmed(String(value[range.upperBound...]))
            if !idea.isEmpty {
                let date = NoteImportTextSupport.firstCapture(pattern: "(\\d{4}/\\d{2}/\\d{2}) 添加笔记", in: value)
                    .map { NoteImportTextSupport.dateMilliseconds($0, format: "yyyy/MM/dd") } ?? 0
                return NoteImportDraftNote(idea: idea, createdTime: date)
            }
        }
        return nil
    }

    private func splitFanqieChapters(_ value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "\\* .+ \\*") else { return [value] }
        var result: [String] = []
        var cursor = value.startIndex
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(match.range, in: value) else { continue }
            result.append(String(value[cursor ..< range.lowerBound]))
            cursor = range.upperBound
        }
        result.append(String(value[cursor...]))
        return result
    }
}

nonisolated struct ReadingoNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .readingo

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let source = try NoteImportTextSupport.decodeUTF8(data)
            .replacingOccurrences(of: "-- 来自Readingo", with: "")
        let lines = source.components(separatedBy: "\n")
        var bookName = ""
        var currentChapter: NoteImportDraftChapter?
        var notes: [NoteImportDraftNote] = []
        var currentDate: Int64 = 0
        var original = ""
        var idea = ""
        var isParsingNote = false
        var isParsingIdea = false

        func savedNote() -> NoteImportDraftNote? {
            guard !NoteImportTextSupport.isBlank(original) else { return nil }
            return NoteImportDraftNote(
                content: original.trimmingCharacters(in: .newlines),
                idea: NoteImportTextSupport.isBlank(idea) ? "" : idea.trimmingCharacters(in: .newlines),
                createdTime: currentDate,
                chapter: currentChapter
            )
        }

        for line in lines {
            let trimmed = NoteImportTextSupport.trimmed(line)
            if trimmed.isEmpty {
                if isParsingNote, !original.isEmpty, !isParsingIdea { original += "\n" }
                if isParsingIdea, !idea.isEmpty { idea += "\n" }
                continue
            }
            if trimmed.hasPrefix("◆") {
                if isParsingNote, let note = savedNote() { notes.append(note) }
                original = ""
                idea = ""
                isParsingIdea = false
                isParsingNote = true
                currentDate = NoteImportTextSupport.dateMilliseconds(
                    NoteImportTextSupport.trimmed(String(trimmed.dropFirst())),
                    format: "yyyy-MM-dd HH:mm:ss"
                )
                continue
            }
            if trimmed.hasPrefix("# ") {
                if isParsingNote, let note = savedNote() { notes.append(note) }
                original = ""
                idea = ""
                isParsingIdea = false
                currentDate = 0
                isParsingNote = false
                currentChapter = NoteImportDraftChapter(title: NoteImportTextSupport.trimmed(String(trimmed.dropFirst(2))))
                continue
            }
            if isParsingNote {
                if trimmed.hasPrefix("原文:") {
                    isParsingIdea = false
                    original += line.range(of: "原文:").map { String(line[$0.upperBound...]) } ?? ""
                } else if trimmed.hasPrefix("想法:") {
                    isParsingIdea = true
                    idea += line.range(of: "想法:").map { String(line[$0.upperBound...]) } ?? ""
                } else if isParsingIdea {
                    if !idea.isEmpty { idea += "\n" }
                    idea += line
                } else {
                    if !original.isEmpty { original += "\n" }
                    original += line
                }
            } else if bookName.isEmpty {
                bookName = trimmed
            }
        }
        if isParsingNote, let note = savedNote() { notes.append(note) }
        guard !NoteImportTextSupport.isBlank(bookName) else { throw NoteImportParserError.bookNotFound }
        guard !notes.isEmpty else { throw NoteImportParserError.noteNotFound }
        var book = makeEBook(name: bookName)
        book.source = 27
        book.notes = notes
        return [book]
    }
}

private nonisolated func makeEBook(name: String, author: String = "") -> NoteImportDraftBook {
    var book = NoteImportDraftBook()
    book.name = name
    book.rawName = name
    book.author = author
    book.type = 1
    book.positionUnit = 1
    book.currentPositionUnit = 1
    return book
}
