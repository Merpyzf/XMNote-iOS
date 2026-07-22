/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收微信读书三代剪贴板文本
 * [OUTPUT]: 对外提供 7.1 前、8.3 前与 8.3 后三个 Parser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的微信剪贴板实现，与扫码授权 Adapter 分离并逐分支对齐 Android
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct WereadOldNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .wereadOld

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let lines = content.components(separatedBy: "\n")
        guard lines.count >= 2, !lines[0].isEmpty else { throw NoteImportParserError.bookNotFound }

        var book = wereadBook(name: lines[0], author: lines[1])
        let blocks = content.components(separatedBy: "\n\n")
        var currentChapter = ""
        var previousWasChapter = false
        var chapterCounts: [String: Int] = [:]
        for block in blocks.dropFirst() {
            let value = NoteImportTextSupport.trimmed(block)
            if value.hasPrefix("◆"), !value.hasPrefix("◆ 点评") {
                previousWasChapter = true
                currentChapter = duplicateChapter(
                    NoteImportTextSupport.trimmed(String(value.dropFirst())),
                    counts: &chapterCounts
                )
                continue
            }
            if value.contains(">") {
                if var note = parseOldNote(value, chapter: currentChapter) {
                    note.isIncludeTime = false
                    book.notes.append(note)
                }
            } else if previousWasChapter, !NoteImportTextSupport.isBlank(value) {
                book.notes.append(NoteImportDraftNote(
                    idea: value,
                    chapter: NoteImportDraftChapter(title: currentChapter)
                ))
            }
            previousWasChapter = false
        }
        return [book]
    }

    private func parseOldNote(_ value: String, chapter: String) -> NoteImportDraftNote? {
        var idea = ""
        let noteContent: String
        if value.hasPrefix(">>") {
            noteContent = String(value.dropFirst(2))
        } else if let separator = value.firstIndex(of: ">") {
            idea = String(value[..<separator])
            noteContent = String(value[value.index(after: separator)...])
        } else {
            noteContent = ""
        }
        guard !NoteImportTextSupport.isBlank(noteContent) else { return nil }
        return NoteImportDraftNote(
            content: noteContent,
            idea: idea,
            positionUnit: 1,
            chapter: NoteImportDraftChapter(title: chapter)
        )
    }
}

nonisolated struct WereadPre830NoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .wereadPre830

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let items = format(content)
        guard let first = items.first else { throw NoteImportParserError.bookNotFound }
        let info = first.components(separatedBy: "\n")
        guard info.count >= 2, !NoteImportTextSupport.isBlank(info[0]) else {
            throw NoteImportParserError.bookNotFound
        }

        var book = wereadBook(name: info[0], author: info[1])
        let dateMarker = try! NSRegularExpression(pattern: "^\\d{4}/\\d{1,2}/\\d{1,2}\\s+发表想法$")
        var currentChapter = ""
        var currentIsChapter = true
        var counts: [String: Int] = [:]
        var pendingIdea = ""
        var index = 1
        while index < items.count {
            let line = items[index]
            if line == ">>" {
                index += 1
                continue
            }
            if line.hasPrefix("◆") {
                let title = NoteImportTextSupport.trimmed(String(line.dropFirst()))
                if title == "点评" {
                    currentIsChapter = false
                } else {
                    currentIsChapter = true
                    currentChapter = duplicateChapter(title, counts: &counts)
                }
            } else if currentIsChapter {
                if line.hasPrefix(">>") {
                    var original = line.count >= 3 ? String(line.dropFirst(3)) : ""
                    while index + 1 < items.count {
                        let next = items[index + 1]
                        if next.hasPrefix(">>") || next.hasPrefix("◆") || matches(dateMarker, next) { break }
                        original += next + "\n"
                        index += 1
                    }
                    original = original.replacingOccurrences(of: "\u{FFFC}", with: "")
                        .trimmingCharacters(in: .newlines)
                    let idea = NoteImportTextSupport.trimmed(pendingIdea)
                    if !NoteImportTextSupport.isBlank(original) || !NoteImportTextSupport.isBlank(idea) {
                        book.notes.append(NoteImportDraftNote(
                            content: original,
                            idea: idea,
                            positionUnit: 1,
                            chapter: NoteImportDraftChapter(title: currentChapter)
                        ))
                    }
                    pendingIdea = ""
                } else if !matches(dateMarker, line) {
                    pendingIdea += line + "\n"
                }
            }
            index += 1
        }
        return [book]
    }

    private func format(_ content: String) -> [String] {
        var items: [String] = []
        for item in content.components(separatedBy: "\n\n") where !NoteImportTextSupport.isBlank(item) {
            let trimmed = NoteImportTextSupport.trimmed(item)
            if trimmed.contains("\n>>") {
                items.append(contentsOf: trimmed.components(separatedBy: "\n")
                    .filter { !NoteImportTextSupport.isBlank($0) }
                    .map(NoteImportTextSupport.trimmed))
            } else {
                items.append(trimmed)
            }
        }
        return items
    }

    private func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

nonisolated struct Weread830NoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .weread830

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let source = try NoteImportTextSupport.decodeUTF8(data)
        let content = source.replacingOccurrences(of: "-- 来自微信读书", with: "")
        let lines = content.components(separatedBy: "\n\n")
            .filter { !NoteImportTextSupport.isBlank($0) }
            .map { value in value.contains("◆") ? String(value.drop(while: { $0.isWhitespace })) : value }
        guard lines.count >= 2 else { throw NoteImportParserError.bookNotFound }
        let authorLines = lines[1].components(separatedBy: "\n")
        guard authorLines.count == 2 else { throw NoteImportParserError.bookNotFound }
        var book = wereadBook(name: lines[0], author: authorLines[0])

        let start = lines.contains(where: { $0.hasPrefix("点评") }) ? 4 : 2
        guard start <= lines.count else { return [book] }
        var contentLines = Array(lines.dropFirst(start))
        if !contentLines.isEmpty, !contentLines[0].hasPrefix("\n") {
            contentLines[0] = "\n" + contentLines[0]
        }
        var currentChapter = ""
        var counts: [String: Int] = [:]
        var isIdea = false
        var expectsOriginal = false
        var idea = ""
        var ideaOriginal = ""

        func makeIdeaNote() -> NoteImportDraftNote {
            NoteImportDraftNote(
                content: ideaOriginal,
                idea: idea,
                chapter: currentChapter.isEmpty ? nil : NoteImportDraftChapter(title: currentChapter)
            )
        }

        for index in contentLines.indices {
            let line = contentLines[index]
            if line.hasPrefix("◆ "), line.contains("发表想法") {
                if !NoteImportTextSupport.isBlank(idea) || !NoteImportTextSupport.isBlank(ideaOriginal) {
                    book.notes.append(makeIdeaNote())
                    idea = ""
                    ideaOriginal = ""
                }
                isIdea = true
                expectsOriginal = false
                continue
            }
            if isIdea {
                if !expectsOriginal {
                    idea = line
                    expectsOriginal = true
                } else {
                    if line.hasPrefix("原文：") {
                        ideaOriginal += String(line.dropFirst(3))
                        isIdea = false
                    }
                    if index == contentLines.index(before: contentLines.endIndex) {
                        book.notes.append(makeIdeaNote())
                    }
                }
                continue
            }

            if !line.hasPrefix("◆ "), currentChapter.isEmpty || isChapter(line, in: content) {
                if !NoteImportTextSupport.isBlank(idea) || !NoteImportTextSupport.isBlank(ideaOriginal) {
                    book.notes.append(makeIdeaNote())
                    idea = ""
                    ideaOriginal = ""
                }
                currentChapter = duplicateChapter(NoteImportTextSupport.trimmed(line), counts: &counts)
                isIdea = false
                expectsOriginal = false
            }
            if line.hasPrefix("◆ ") {
                if !NoteImportTextSupport.isBlank(idea) || !NoteImportTextSupport.isBlank(ideaOriginal) {
                    book.notes.append(makeIdeaNote())
                    idea = ""
                    ideaOriginal = ""
                }
                var original = ""
                for lookahead in index ..< contentLines.count {
                    let value = contentLines[lookahead]
                    original += value.hasPrefix("◆ ") ? String(value.dropFirst(2)) : "\n" + value
                    if lookahead + 1 < contentLines.count {
                        let next = contentLines[lookahead + 1]
                        if next.hasPrefix("◆ ") || isChapter(next, in: content) { break }
                    }
                }
                book.notes.append(NoteImportDraftNote(
                    content: original,
                    chapter: currentChapter.isEmpty ? nil : NoteImportDraftChapter(title: currentChapter)
                ))
                isIdea = false
                expectsOriginal = false
            }
        }
        return [book]
    }

    private func isChapter(_ line: String, in source: String) -> Bool {
        guard let range = source.range(of: line) else { return line.hasPrefix("\n\n\n") }
        var count = line.hasPrefix("\n") ? 1 : 0
        var cursor = range.lowerBound
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\n" else { break }
            count += 1
            cursor = previous
        }
        return count >= 3
    }
}

private nonisolated func wereadBook(name: String, author: String) -> NoteImportDraftBook {
    let cleanName = name.replacingOccurrences(of: "《", with: "")
        .replacingOccurrences(of: "》", with: "")
        .replacingOccurrences(of: "<<", with: "")
        .replacingOccurrences(of: ">>", with: "")
    var book = NoteImportDraftBook()
    book.name = cleanName
    book.rawName = cleanName
    book.author = author
    book.type = 1
    book.positionUnit = 1
    book.currentPositionUnit = 1
    return book
}

private nonisolated func duplicateChapter(_ title: String, counts: inout [String: Int]) -> String {
    let count = (counts[title] ?? 0) + 1
    counts[title] = count
    return count == 1 ? title : "\(title)（\(count - 1)）"
}
