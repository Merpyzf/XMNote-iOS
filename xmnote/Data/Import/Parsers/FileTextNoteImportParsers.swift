/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收京东读书和掌阅文件文本
 * [OUTPUT]: 对外提供 JDReaderNoteImportParser 与 IReaderFileNoteImportParser
 * [POS]: Data/Import/Parsers 的文件名相关文本实现，保留 Android DocumentFile 文件名与行范围语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct JDReaderNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .jdReader

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        guard content.contains("来自京东读书 for Android") || content.contains("来自京东读书专业版 for Android") else {
            throw NoteImportParserError.noteFormat
        }
        let lines = content.components(separatedBy: "\n").filter { !NoteImportTextSupport.isBlank($0) }
        guard lines.count >= 2,
              let name = NoteImportTextSupport.firstCapture(pattern: "《(.*)》", in: lines[0]).map(NoteImportTextSupport.trimmed),
              !name.isEmpty
        else { throw NoteImportParserError.bookNotFound }
        let author = NoteImportTextSupport.firstCapture(pattern: "作者:(.*)", in: lines[1]).map(NoteImportTextSupport.trimmed) ?? ""
        var book = fileTextBook(name: name, author: author)
        var lastIndex: Int?
        if lines.count > 4 {
            for index in 2 ..< lines.count - 2 {
                let line = lines[index]
                if line.hasPrefix("想法:") {
                    if let lastIndex, line.count > 3 {
                        book.notes[lastIndex].idea = String(line.dropFirst(3))
                    }
                } else if !NoteImportTextSupport.isBlank(line) {
                    book.notes.append(NoteImportDraftNote(
                        content: line,
                        positionUnit: 1,
                        createdTime: 0,
                        isIncludeTime: false
                    ))
                    lastIndex = book.notes.index(before: book.notes.endIndex)
                }
            }
        }
        return [book]
    }
}

nonisolated struct IReaderFileNoteImportParser: NoteImportFileNameAwareParser {
    let id: NoteImportParserID = .ireaderFile

    func parse(data _: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        throw NoteImportParserError.noteFormat
    }

    func parse(data: Data, fileName: String, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data).replacingOccurrences(of: "\r", with: "")
        let name = bookName(fileName)
        guard !name.isEmpty else { throw NoteImportParserError.noteFormat }
        var book = fileTextBook(name: name)
        for item in content.components(separatedBy: "\n\n") where !NoteImportTextSupport.isBlank(item) {
            let lines = item.components(separatedBy: "\n").filter { !NoteImportTextSupport.isBlank($0) }
            guard lines.count >= 3,
                  let originalRange = item.range(of: "原文："),
                  let ideaRange = item.range(of: "想法：")
            else { continue }
            let original = NoteImportTextSupport.trimmed(String(item[originalRange.upperBound ..< ideaRange.lowerBound]))
            let idea = NoteImportTextSupport.trimmed(String(item[ideaRange.upperBound...]))
            book.notes.append(NoteImportDraftNote(
                content: original,
                idea: idea,
                positionUnit: 1,
                createdTime: NoteImportTextSupport.dateMilliseconds(lines[0], format: "yyyy-MM-dd")
            ))
        }
        return [book]
    }

    private func bookName(_ fileName: String) -> String {
        let withoutExtension = (fileName as NSString).deletingPathExtension
        if let start = withoutExtension.firstIndex(of: "《"), let end = withoutExtension.firstIndex(of: "》"), start < end {
            return NoteImportTextSupport.trimmed(String(withoutExtension[withoutExtension.index(after: start) ..< end]))
        }
        if let marker = withoutExtension.range(of: "笔记") {
            return NoteImportTextSupport.trimmed(String(withoutExtension[..<marker.lowerBound]))
        }
        return NoteImportTextSupport.trimmed(withoutExtension)
    }
}

private nonisolated func fileTextBook(name: String, author: String = "") -> NoteImportDraftBook {
    var book = NoteImportDraftBook()
    book.name = name
    book.rawName = name
    book.author = author
    book.type = 1
    book.positionUnit = 1
    book.currentPositionUnit = 1
    return book
}
