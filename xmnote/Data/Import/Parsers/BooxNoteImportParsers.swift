/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收 BOOX 文本导出字节
 * [OUTPUT]: 对外提供 BooxOldNoteImportParser 与 BooxNewNoteImportParser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的 BOOX 新旧版本实现，逐分支复刻 Android 生产 Parser
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct BooxOldNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .booxOld

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        // Kotlin `String.lines()` 会移除 CRLF 的 `\r`；Swift 按 `\n` 切分前需显式复刻。
        let content = try NoteImportTextSupport.decodeUTF8(data)
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard NoteImportDetection.isBoox(content) else { throw NoteImportParserError.noteFormat }
        let lines = content.components(separatedBy: "\n")
        guard let firstLine = lines.first,
              let bookInfo = BooxBookInfo.parse(firstLine)
        else { throw NoteImportParserError.bookNotFound }

        var book = NoteImportDraftBook()
        book.name = bookInfo.title
        book.author = bookInfo.author.isEmpty && shouldUseSecondLineAsAuthor(lines)
            ? NoteImportTextSupport.trimmed(lines[1])
            : bookInfo.author
        book.type = 1
        book.positionUnit = 1
        book.currentPositionUnit = 1

        let startIndex: Int
        if lines.count <= 1 {
            startIndex = lines.count
        } else if !bookInfo.author.isEmpty {
            startIndex = 1
        } else {
            startIndex = shouldUseSecondLineAsAuthor(lines) ? 2 : 1
        }
        let notePart = lines.dropFirst(startIndex).map { "\($0)\n" }.joined()
        let noteItems = notePart.components(separatedBy: "-------------------\n")
            .filter { !NoteImportTextSupport.isBlank($0) }
        book.notes = noteItems.compactMap(parseNote)
        return [book]
    }

    private func parseNote(_ item: String) -> NoteImportDraftNote? {
        let content = NoteImportTextSupport.firstCapture(
            pattern: "【原文】([\\s\\S]*?)(?:【批注】|【註解】)",
            in: item
        ).map(NoteImportTextSupport.trimmed) ?? ""
        let idea = NoteImportTextSupport.firstCapture(
            pattern: "(?:【批注】|【註解】)([\\s\\S]*?)(?:【页码】|【頁碼】)",
            in: item
        ).map(NoteImportTextSupport.trimmed) ?? ""
        guard !NoteImportTextSupport.isBlank(content) || !NoteImportTextSupport.isBlank(idea) else { return nil }

        var note = NoteImportDraftNote()
        note.content = content
        note.idea = idea
        note.positionUnit = 1
        note.position = NoteImportTextSupport.firstCapture(
            pattern: "(?:【页码】|【頁碼】)(\\d*)?\\n",
            in: item
        ).flatMap { Int($0) }.map(String.init) ?? ""
        if let date = NoteImportTextSupport.firstCapture(
            pattern: "(?:时间|時間)：(.*)\\n【原文】",
            in: item
        ) {
            note.createdTime = NoteImportTextSupport.androidDateMilliseconds(date)
        }
        if note.createdTime == 0 {
            note.isIncludeTime = false
        }
        if let chapter = NoteImportTextSupport.firstCapture(
            pattern: "(.*)\\n(?:时间|時間)：\\d\\d\\d\\d-\\d\\d-\\d\\d \\d\\d:\\d\\d\\n【原文】",
            in: item
        ).map(NoteImportTextSupport.trimmed), !chapter.isEmpty, chapter != "null" {
            note.chapter = NoteImportDraftChapter(title: chapter)
        }
        return note
    }

    private func shouldUseSecondLineAsAuthor(_ lines: [String]) -> Bool {
        guard lines.indices.contains(1) else { return false }
        let line = NoteImportTextSupport.trimmed(lines[1])
        guard !line.isEmpty else { return false }
        return !isNotAuthorLine(line)
    }

    private func isNotAuthorLine(_ line: String) -> Bool {
        if line == "null" || line == "-------------------" { return true }
        if line.hasPrefix("时间：") || line.hasPrefix("時間：") { return true }
        if line.hasPrefix("【原文】") || BooxLabels.isIdeaLine(line) || BooxLabels.isPageLine(line) { return true }
        return NoteImportTextSupport.contains(pattern: "^第.{1,12}[章节卷回篇部集幕].*", in: line)
            || NoteImportTextSupport.contains(pattern: "^Chapter\\s+\\d+.*", in: line)
    }
}

nonisolated struct BooxNewNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .booxNew

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        guard NoteImportDetection.isBoox(content) else { throw NoteImportParserError.noteFormat }
        let lines = content.components(separatedBy: "\n")
        guard let firstLine = lines.first,
              let bookInfo = BooxBookInfo.parse(firstLine)
        else { throw NoteImportParserError.bookNotFound }

        var book = NoteImportDraftBook()
        book.name = bookInfo.title
        book.author = bookInfo.author
        book.type = 1
        book.positionUnit = 1
        book.currentPositionUnit = 1

        let body = NoteImportTextSupport.trimmed(lines.dropFirst().joined(separator: "\n"))
        let items = body.components(separatedBy: "-------------------")
            .filter { !NoteImportTextSupport.isBlank($0) }
            .map(NoteImportTextSupport.trimmed)
        var currentChapter = ""
        var currentChapterIsNull = false
        for item in items {
            let itemLines = item.components(separatedBy: "\n")
            guard let first = itemLines.first else { continue }
            var contentStartIndex = 1
            if !NoteImportTextSupport.contains(pattern: "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}", in: first) {
                contentStartIndex = 2
                if first == "null" {
                    currentChapterIsNull = true
                } else {
                    currentChapter = first
                }
            }

            let noteContent = parseContent(lines: itemLines, startIndex: contentStartIndex)
            let idea = parseIdea(lines: itemLines, startIndex: contentStartIndex)
            guard !NoteImportTextSupport.isBlank(noteContent) || !NoteImportTextSupport.isBlank(idea) else { continue }
            var note = NoteImportDraftNote()
            note.content = noteContent
            note.idea = idea
            note.positionUnit = 1
            note.createdTime = NoteImportTextSupport.firstCapture(
                pattern: "(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2})",
                in: item
            ).map(NoteImportTextSupport.androidDateMilliseconds) ?? 0
            note.position = NoteImportTextSupport.firstCapture(
                pattern: "(?:页码|頁碼)：(\\d+)",
                in: item
            ) ?? ""
            if !currentChapter.isEmpty && !currentChapterIsNull {
                note.chapter = NoteImportDraftChapter(title: currentChapter)
            }
            currentChapterIsNull = false
            book.notes.append(note)
        }
        return [book]
    }

    private func parseContent(lines: [String], startIndex: Int) -> String {
        guard startIndex < lines.count else { return "" }
        var result: [String] = []
        for line in lines[startIndex...] {
            if BooxLabels.isIdeaLine(line) { break }
            result.append(line)
        }
        return NoteImportTextSupport.trimmed(result.joined(separator: "\n") + (result.isEmpty ? "" : "\n"))
    }

    private func parseIdea(lines: [String], startIndex: Int) -> String {
        guard startIndex < lines.count else { return "" }
        var result: [String] = []
        var found = false
        for line in lines[startIndex...] {
            if BooxLabels.isIdeaLine(line) {
                found = true
                result.append(BooxLabels.removingIdeaLabel(line))
            } else if found {
                result.append(line)
            }
        }
        return NoteImportTextSupport.trimmed(result.joined(separator: "\n") + (result.isEmpty ? "" : "\n"))
    }
}

private nonisolated enum BooxBookInfo {
    static func parse(_ line: String) -> (title: String, author: String)? {
        guard let title = NoteImportTextSupport.firstCapture(pattern: "<<(.+?)>>(.*)$", in: line, group: 1),
              let author = NoteImportTextSupport.firstCapture(pattern: "<<(.+?)>>(.*)$", in: line, group: 2)
        else { return nil }
        let trimmedTitle = NoteImportTextSupport.trimmed(title)
        guard !trimmedTitle.isEmpty else { return nil }
        return (trimmedTitle, NoteImportTextSupport.trimmed(author))
    }
}

private nonisolated enum BooxLabels {
    static func isIdeaLine(_ line: String) -> Bool {
        line.hasPrefix("【批注】") || line.hasPrefix("【註解】")
    }

    static func removingIdeaLabel(_ line: String) -> String {
        if line.hasPrefix("【批注】") { return String(line.dropFirst("【批注】".count)) }
        if line.hasPrefix("【註解】") { return String(line.dropFirst("【註解】".count)) }
        return line
    }

    static func isPageLine(_ line: String) -> Bool {
        line.hasPrefix("【页码】") || line.hasPrefix("【頁碼】")
    }
}
