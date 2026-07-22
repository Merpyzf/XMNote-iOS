/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收多看、掌阅精选、静读天下、豆瓣 App 和网易蜗牛文本
 * [OUTPUT]: 对外提供五个剪贴板来源 Parser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的传统剪贴板实现，保留 Android 正则、顺序、日期与缺省字段语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct DuokanNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .duokan

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let trimmed = NoteImportTextSupport.trimmed(content)
        guard NoteImportTextSupport.contains(pattern: "\\n\\n.+\\n \\d{4}-\\d{2}-\\d{2}\\n", in: trimmed)
            || NoteImportTextSupport.contains(pattern: "^.+\\n\\n \\d{4}-\\d{2}-\\d{2}\\n", in: trimmed) else {
            throw NoteImportParserError.noteFormat
        }
        let lines = content.components(separatedBy: "\n")
        let noChapter = NoteImportTextSupport.contains(
            pattern: "^.+\\n\\n \\d{4}-\\d{2}-\\d{2}\\n",
            in: NoteImportTextSupport.trimmed(content)
        )
        let title = lines.first ?? ""
        let author = noChapter ? "" : (lines.indices.contains(2) ? lines[2] : "")
        guard !NoteImportTextSupport.isBlank(title) || !NoteImportTextSupport.isBlank(author) else {
            throw NoteImportParserError.bookNotFound
        }
        let bodyStart = noChapter ? 2 : 3
        let body = lines.count > bodyStart ? lines[bodyStart...].joined(separator: "\n") : ""
        let dates = allCaptures(pattern: " (\\d{4}-\\d{2}-\\d{2})", in: content)
            .map { NoteImportTextSupport.dateMilliseconds(NoteImportTextSupport.trimmed($0), format: "yyyy-MM-dd") }
        guard !dates.isEmpty, !NoteImportTextSupport.isBlank(body) else { throw NoteImportParserError.noteNotFound }

        var book = clipboardBook(name: title, author: author)
        var dateIndex = 0
        if noChapter {
            for value in regexSplit(pattern: " \\d{4}-\\d{2}-\\d{2}", value: body)
                .filter({ !NoteImportTextSupport.isBlank($0) })
                .map(NoteImportTextSupport.trimmed)
            {
                var note = duokanNote(value)
                note.positionUnit = 1
                note.createdTime = dates[dateIndex]
                dateIndex += 1
                book.notes.append(note)
            }
        } else {
            for section in chapterSections(body) {
                let sectionLines = section.components(separatedBy: "\n")
                let chapter = sectionLines.first ?? ""
                let sectionBody = sectionLines.dropFirst().joined(separator: "\n")
                for value in regexSplit(pattern: " \\d{4}-\\d{2}-\\d{2}", value: NoteImportTextSupport.trimmed(sectionBody))
                    .filter({ !NoteImportTextSupport.isBlank($0) })
                    .map(NoteImportTextSupport.trimmed)
                {
                    var note = duokanNote(value)
                    note.positionUnit = 1
                    note.createdTime = dates[dateIndex]
                    dateIndex += 1
                    note.chapter = NoteImportDraftChapter(title: NoteImportTextSupport.trimmed(chapter))
                    book.notes.append(note)
                }
            }
        }
        return [book]
    }

    private func chapterSections(_ content: String) -> [String] {
        var result: [String] = []
        for section in content.components(separatedBy: "\n\n").map(NoteImportTextSupport.trimmed) {
            if NoteImportTextSupport.contains(pattern: " \\d{4}-\\d{2}-\\d{2}", in: section) {
                result.append(section)
            } else if !result.isEmpty {
                result[result.count - 1] += "\n\n" + section
            }
        }
        return result
    }

    private func duokanNote(_ value: String) -> NoteImportDraftNote {
        guard let range = value.range(of: "注: ") else { return NoteImportDraftNote(content: NoteImportTextSupport.trimmed(value)) }
        return NoteImportDraftNote(
            content: NoteImportTextSupport.trimmed(String(value[..<range.lowerBound])),
            idea: NoteImportTextSupport.trimmed(String(value[value.index(range.lowerBound, offsetBy: 2)...]))
        )
    }
}

nonisolated struct IReaderSelectedNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .ireaderSelected

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        guard NoteImportTextSupport.contains(
            pattern: "条笔记(\\n\\n\\n§)|条笔记(\\n\\n\\n>>)",
            in: NoteImportTextSupport.trimmed(content)
        ) else { throw NoteImportParserError.noteFormat }
        let lines = content.components(separatedBy: "\n").filter { !NoteImportTextSupport.isBlank($0) }
        guard lines.count >= 2 else { throw NoteImportParserError.bookNotFound }
        let name = lines[0].split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !NoteImportTextSupport.isBlank(name) else { throw NoteImportParserError.bookNotFound }
        let hasAuthor = !lines[1].contains("条笔记")
        var book = clipboardBook(name: NoteImportTextSupport.trimmed(name), author: hasAuthor ? NoteImportTextSupport.trimmed(lines[1]) : "")
        var chapter = ""
        var pendingIdea = ""
        for line in lines.dropFirst(hasAuthor ? 3 : 2) {
            if line.hasPrefix("§") {
                chapter = NoteImportTextSupport.trimmed(String(line.dropFirst()))
            } else if line.hasPrefix(">>") {
                book.notes.append(NoteImportDraftNote(
                    content: String(line.dropFirst(2)),
                    idea: NoteImportTextSupport.isBlank(pendingIdea) ? "" : pendingIdea,
                    positionUnit: 1,
                    createdTime: 0,
                    isIncludeTime: false,
                    chapter: NoteImportDraftChapter(title: chapter)
                ))
                pendingIdea = ""
            } else {
                pendingIdea += "\n" + line
            }
        }
        return [book]
    }
}

nonisolated struct MoonReaderNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .moonReader

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let parts = content.components(separatedBy: "\n\n───────────────")
        guard parts.count == 2 else { throw NoteImportParserError.noteFormat }
        var book = moonBook(parts[0])
        let expression = try! NSRegularExpression(pattern: "\\n\\n([▪◆])\\s?([\\s\\S]*?)(?=\\n\\n[▪◆]|$)")
        let value = parts[1]
        var chapter = ""
        var grouped: [(String, [String])] = []
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let markerRange = Range(match.range(at: 1), in: value),
                  let bodyRange = Range(match.range(at: 2), in: value)
            else { continue }
            let marker = String(value[markerRange])
            let body = NoteImportTextSupport.trimmed(String(value[bodyRange]))
            if marker == "◆" {
                chapter = body
            } else {
                if let index = grouped.firstIndex(where: { $0.0 == chapter }) {
                    grouped[index].1.append(body)
                } else {
                    grouped.append((chapter, [body]))
                }
            }
        }
        for (chapterTitle, notes) in grouped {
            for value in notes {
                var original = value
                var idea = ""
                if let capture = NoteImportTextSupport.firstCapture(pattern: "(\\([\\s\\S]*?\\)+$)", in: value), capture.count >= 2 {
                    original = value.replacingOccurrences(of: capture, with: "")
                    idea = String(capture.dropFirst().dropLast())
                }
                book.notes.append(NoteImportDraftNote(
                    content: original,
                    idea: idea,
                    positionUnit: 1,
                    createdTime: 0,
                    isIncludeTime: false,
                    chapter: NoteImportDraftChapter(title: NoteImportTextSupport.trimmed(chapterTitle))
                ))
            }
        }
        return [book]
    }

    private func moonBook(_ value: String) -> NoteImportDraftBook {
        let prefix: String
        if let dot = value.firstIndex(of: ".") {
            prefix = String(value[..<dot])
        } else if let bracket = value.firstIndex(of: "(") {
            prefix = String(value[..<bracket])
        } else {
            prefix = value
        }
        let info = prefix.components(separatedBy: "-").map(NoteImportTextSupport.trimmed)
        return clipboardBook(name: info.first ?? "", author: info.count > 1 ? info[1] : "")
    }
}

nonisolated struct DoubanAppNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .doubanApp

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let blocks = content.components(separatedBy: "\n\n")
        guard let first = blocks.first else { throw NoteImportParserError.bookNotFound }
        let name = first.components(separatedBy: "-").first.map(NoteImportTextSupport.trimmed) ?? ""
        guard !NoteImportTextSupport.isBlank(name) else { throw NoteImportParserError.bookNotFound }
        guard blocks.count > 1 else { throw NoteImportParserError.noteNotFound }
        var book = clipboardBook(name: name)
        var chapter = ""
        for block in blocks.dropFirst() {
            if !block.hasPrefix("原文：") {
                chapter = NoteImportTextSupport.trimmed(block)
                continue
            }
            let hasIdea = block.contains("批注：")
            let originalPattern = hasIdea ? "原文：([\\w\\W]*)批注：" : "原文：([\\w\\W]*)(\\d{4}-\\d{2}-\\d{2})"
            let original = NoteImportTextSupport.firstCapture(pattern: originalPattern, in: block).map(NoteImportTextSupport.trimmed) ?? ""
            let idea = hasIdea
                ? NoteImportTextSupport.firstCapture(pattern: "批注：([\\w\\W]*)(\\d{4}-\\d{2}-\\d{2})", in: block).map(NoteImportTextSupport.trimmed) ?? ""
                : ""
            guard !NoteImportTextSupport.isBlank(original) || !NoteImportTextSupport.isBlank(idea) else { continue }
            let date = NoteImportTextSupport.firstCapture(pattern: "(\\d{4}-\\d{2}-\\d{2})", in: block)
                .map { NoteImportTextSupport.dateMilliseconds($0, format: "yyyy-MM-dd") } ?? 0
            book.notes.append(NoteImportDraftNote(
                content: original,
                idea: idea,
                positionUnit: 1,
                createdTime: date,
                chapter: NoteImportDraftChapter(title: chapter)
            ))
        }
        return [book]
    }
}

nonisolated struct Reader163NoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .reader163

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let lines = content.components(separatedBy: "\n")
        guard lines.count >= 2 else { throw NoteImportParserError.bookNotFound }
        let name = lines[0].replacingOccurrences(of: "《", with: "").replacingOccurrences(of: "》", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NoteImportParserError.bookNotFound }
        let blocks = content.components(separatedBy: "\n\n")
        guard blocks.count > 1 else { throw NoteImportParserError.noteNotFound }
        var book = clipboardBook(name: name, author: NoteImportTextSupport.trimmed(lines[1]))
        for block in blocks.dropFirst() {
            let chapter = NoteImportTextSupport.firstCapture(pattern: "◆ (.*)\\n", in: block).map(NoteImportTextSupport.trimmed) ?? ""
            let original = NoteImportTextSupport.firstCapture(pattern: ">> (.*)", in: block).map(NoteImportTextSupport.trimmed) ?? ""
            let idea = NoteImportTextSupport.firstCapture(pattern: "◆ [\\w\\W]*?\\n([\\w\\W]*)(?=>>)", in: block).map(NoteImportTextSupport.trimmed) ?? ""
            guard !NoteImportTextSupport.isBlank(original) || !NoteImportTextSupport.isBlank(idea) else { continue }
            book.notes.append(NoteImportDraftNote(
                content: original,
                idea: idea,
                positionUnit: 1,
                createdTime: 0,
                isIncludeTime: false,
                chapter: NoteImportDraftChapter(title: chapter)
            ))
        }
        return [book]
    }
}

private nonisolated func clipboardBook(name: String, author: String = "") -> NoteImportDraftBook {
    var book = NoteImportDraftBook()
    book.name = name
    book.rawName = name
    book.author = author
    book.type = 1
    book.positionUnit = 1
    book.currentPositionUnit = 1
    return book
}

private nonisolated func regexSplit(pattern: String, value: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [value] }
    var pieces: [String] = []
    var cursor = value.startIndex
    for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
        guard let range = Range(match.range, in: value) else { continue }
        pieces.append(String(value[cursor ..< range.lowerBound]))
        cursor = range.upperBound
    }
    pieces.append(String(value[cursor...]))
    return pieces
}

private nonisolated func allCaptures(pattern: String, in value: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
        guard let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}
