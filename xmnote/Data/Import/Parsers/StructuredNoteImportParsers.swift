/**
 * [INPUT]: 依赖 Foundation、SwiftSoup、NoteImportModels 与 NoteImportTextSupport，接收 HTML、JSON 和 CSV 导入字节
 * [OUTPUT]: 对外提供 Kindle App、KOReader、阅读、Neat Reader、Koodo 与 Reeden Parser
 * [POS]: Data/Import/Parsers 的结构化格式实现，输出统一 Draft 并接受 Android Golden 字节级验证
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftSoup

nonisolated struct KindleAppNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .kindleApp

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let html = try NoteImportTextSupport.decodeUTF8(data)
        let document = try SwiftSoup.parse(html, "utf-8")
        let title = try document.getElementsByClass("bookTitle").text()
        guard !title.isEmpty else { throw NoteImportParserError.bookNotFound }
        var book = structuredEBook(name: title, author: try document.getElementsByClass("authors").text())
        var items: [String] = []
        for element in try document.getElementsByTag("div").array() {
            if element.hasClass("sectionHeading") {
                items.append("$" + (try element.text()))
            } else if element.hasClass("noteHeading") || element.hasClass("noteText") {
                items.append(try element.text())
            }
        }
        var parentChapter = ""
        var index = 0
        while index < items.count {
            if items[index].hasPrefix("$") {
                parentChapter = String(items[index].dropFirst())
                index += 1
            }
            guard index < items.count else { break }
            let heading = items[index]
            if heading.hasPrefix("标注") || heading.hasPrefix("Highlight") || heading.hasPrefix("標註") {
                var note = NoteImportDraftNote()
                note.positionUnit = 1
                note.isIncludeTime = false
                note.position = NoteImportTextSupport.firstCapture(pattern: "\\b(\\d+)\\b", in: heading) ?? ""
                if let arrow = heading.firstIndex(of: ">"), let dash = heading.firstIndex(of: "-") {
                    note.chapter = NoteImportDraftChapter(
                        title: NoteImportTextSupport.trimmed(parentChapter) + "$"
                            + NoteImportTextSupport.trimmed(String(heading[heading.index(after: dash) ..< arrow]))
                    )
                } else {
                    note.chapter = NoteImportDraftChapter(title: parentChapter)
                }
                index += 1
                if index < items.count {
                    note.content = items[index]
                    index += 1
                    if index < items.count {
                        let possibleNote = items[index]
                        if possibleNote.hasPrefix("笔记") || possibleNote.hasPrefix("Note") || possibleNote.hasPrefix("備註") {
                            index += 1
                            if index < items.count { note.idea = items[index] }
                        } else {
                            index -= 1
                        }
                    }
                }
                book.notes.append(note)
            }
            index += 1
        }
        return [book]
    }
}

nonisolated struct KOReaderNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .koreader

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else { throw NoteImportParserError.noteFormat }
            if let documents = root["documents"] as? [[String: Any]] {
                return documents.map(parseNewDocument)
            }
            return try parseOldObjects(data)
        } catch let error as NoteImportParserError {
            throw error
        } catch {
            throw NoteImportParserError.noteFormat
        }
    }

    private func parseNewDocument(_ value: [String: Any]) -> NoteImportDraftBook {
        var book = structuredEBook(name: value.string("title"), author: value.string("author"))
        book.source = 14
        book.totalPosition = value.int64("number_of_pages")
        let entries = value["entries"] as? [[String: Any]] ?? []
        book.readPosition = entries.compactMap { ($0["page"] as? NSNumber)?.doubleValue }.max() ?? 0
        book.notes = entries.map { entry in
            var note = NoteImportDraftNote(
                content: entry.string("text"),
                idea: entry.string("note"),
                chapter: NoteImportDraftChapter(title: entry.string("chapter"))
            )
            if let time = entry["time"] as? NSNumber {
                note.createdTime = time.int64Value * 1_000
            } else {
                note.isIncludeTime = false
            }
            if let page = entry["page"] as? String {
                note.positionUnit = 1
                note.position = page
            } else if let page = entry["page"] as? NSNumber {
                note.positionUnit = 1
                note.position = String(page.intValue)
            }
            return note
        }
        return book
    }

    private func parseOldObjects(_ data: Data) throws -> [NoteImportDraftBook] {
        let source = try NoteImportTextSupport.decodeUTF8(data)
        let blocks = source.components(separatedBy: "}\n{")
        var books: [NoteImportDraftBook] = []
        for (index, raw) in blocks.enumerated() where !NoteImportTextSupport.isBlank(raw) {
            var block = raw
            if blocks.count > 1 {
                if index == 0 { block += "}" }
                else if index == blocks.count - 1 { block = "{" + block }
                else { block = "{" + block + "}" }
            }
            guard let data = block.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["entries"] is [Any]
            else { continue }
            let title = value.string("title")
            guard !NoteImportTextSupport.isBlank(title) else { throw NoteImportParserError.noteFormat }
            if books.contains(where: { $0.name == title }) { continue }
            var book = structuredEBook(name: title, author: value.string("author"))
            book.source = 14
            for entry in value["entries"] as? [[String: Any]] ?? [] {
                let original = entry.string("text")
                let idea = entry.string("note")
                if NoteImportTextSupport.isBlank(original), NoteImportTextSupport.isBlank(idea) { continue }
                let page = entry.int64("page")
                let time = entry.int64("time")
                book.notes.append(NoteImportDraftNote(
                    content: original,
                    idea: idea,
                    position: page == 0 ? "" : String(page),
                    positionUnit: 1,
                    createdTime: time == 0 ? 0 : time * 1_000,
                    isIncludeTime: true,
                    chapter: NoteImportTextSupport.isBlank(entry.string("chapter"))
                        ? nil : NoteImportDraftChapter(title: entry.string("chapter"))
                ))
            }
            books.append(book)
        }
        return books.sorted { $0.name < $1.name }
    }
}

nonisolated struct LegadoNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .legado

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !items.isEmpty else {
            throw NoteImportParserError.noteFormat
        }
        var books: [NoteImportDraftBook] = []
        for item in items {
            let name = item.string("bookName")
            let index = books.firstIndex(where: { $0.name == name })
            if index == nil { books.append(structuredEBook(name: name, author: item.string("bookAuthor"))) }
            let target = index ?? books.index(before: books.endIndex)
            books[target].notes.append(NoteImportDraftNote(
                content: item.string("bookText"),
                idea: item.string("content"),
                position: String(item.int64("chapterPos")),
                positionUnit: 1,
                createdTime: item.int64("time"),
                chapter: NoteImportDraftChapter(
                    title: item.string("chapterName"),
                    order: item.int64("chapterIndex")
                )
            ))
        }
        return books.sorted {
            ($0.notes.map(\.createdTime).max() ?? 0) > ($1.notes.map(\.createdTime).max() ?? 0)
        }
    }
}

nonisolated struct NeatReaderNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .neatReader

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notes = object["noteList"] as? [[String: Any]]
        else { throw NoteImportParserError.noteFormat }
        var book = structuredEBook(name: object.string("bookName"))
        book.notes = notes.map {
            NoteImportDraftNote(
                content: $0.string("text"),
                idea: $0.string("note"),
                positionUnit: 1,
                createdTime: $0.int64("updateTime")
            )
        }
        return [book]
    }
}

nonisolated struct KoodoNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .koodo

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let source = try NoteImportTextSupport.decodeUTF8(data)
        let rows = parseCSV(source)
        guard let headers = rows.first else { throw NoteImportParserError.bookNotFound }
        let normalized = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func index(_ key: String) -> Int? { normalized.firstIndex(where: { $0.contains(key) }) }
        var books: [NoteImportDraftBook] = []
        for row in rows.dropFirst() {
            func field(_ key: String) -> String {
                guard let position = index(key), row.indices.contains(position) else { return "" }
                return row[position]
            }
            let name = field("bookName")
            if NoteImportTextSupport.isBlank(name) { continue }
            let bookIndex: Int
            if let existing = books.firstIndex(where: { $0.rawName == name }) {
                bookIndex = existing
            } else {
                var book = NoteImportDraftBook()
                book.name = name
                book.rawName = name
                book.author = field("bookAuthor")
                book.type = 1
                book.positionUnit = 1
                books.append(book)
                bookIndex = books.index(before: books.endIndex)
            }
            guard let created = Int64(field("key")) else { throw NoteImportParserError.noteFormat }
            let original = field("text")
            let idea = field("notes")
            if NoteImportTextSupport.isBlank(original), NoteImportTextSupport.isBlank(idea) { continue }
            if let noteIndex = books[bookIndex].notes.firstIndex(where: { $0.createdTime == created }) {
                if !NoteImportTextSupport.isBlank(idea) { books[bookIndex].notes[noteIndex].idea = idea }
            } else {
                books[bookIndex].notes.append(NoteImportDraftNote(
                    content: original,
                    idea: idea,
                    createdTime: created,
                    isIncludeTime: created != 0,
                    chapter: NoteImportDraftChapter(title: field("chapter"))
                ))
                books[bookIndex].notes.sort { $0.createdTime < $1.createdTime }
            }
        }
        guard !books.isEmpty else { throw NoteImportParserError.bookNotFound }
        return books.sorted { ($0.notes.last?.createdTime ?? 0) > ($1.notes.last?.createdTime ?? 0) }
    }
}

nonisolated struct ReedenNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .reeden

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let values: [[String: Any]]
            if let array = object as? [[String: Any]] { values = array }
            else if let item = object as? [String: Any] { values = [item] }
            else { throw NoteImportParserError.noteFormat }
            return values.map { value in
                var book = structuredEBook(
                    name: NoteImportTextSupport.trimmed(value.string("title")),
                    author: NoteImportTextSupport.trimmed(value.string("author"))
                )
                let description = value.string("description")
                book.summary = description == "UnKnown" ? "" : NoteImportTextSupport.trimmed(description)
                book.source = 26
                if let statistics = value["readingStatistics"] as? [String: Any],
                   let records = statistics["readingRecords"] as? [[String: Any]]
                {
                    let durations = records.compactMap { record -> NoteImportFuzzyReadingDuration? in
                        let seconds = record.int64("readSeconds")
                        guard seconds > 0 else { return nil }
                        let date = NoteImportTextSupport.dateMilliseconds(record.string("date"), format: "yyyy-MM-dd")
                        guard date != 0 else { return nil }
                        return NoteImportFuzzyReadingDuration(date: date, durationSeconds: seconds)
                    }
                    book.fuzzyReadingDurations = durations.isEmpty ? nil : durations
                }
                for note in value["notes"] as? [[String: Any]] ?? [] {
                    let timestamp = note.string("timestamp")
                    let created: Int64
                    if let raw = Int64(NoteImportTextSupport.trimmed(timestamp)) {
                        created = (1 ... 9_999_999_999).contains(raw) ? raw * 1_000 : raw
                    } else {
                        created = NoteImportTextSupport.dateMilliseconds(
                            NoteImportTextSupport.trimmed(note.string("createTime")),
                            format: "yyyy年M月d日 HH:mm"
                        )
                    }
                    book.notes.append(NoteImportDraftNote(
                        content: trimEndWhitespace(note.string("content")),
                        idea: trimEndWhitespace(note.string("comment")),
                        createdTime: created,
                        chapter: NoteImportDraftChapter(
                            title: NoteImportTextSupport.trimmed(note.string("sectionName")),
                            order: note.int64("sectionIndex")
                        )
                    ))
                }
                return book
            }
        } catch let error as NoteImportParserError {
            throw error
        } catch {
            throw NoteImportParserError.noteFormat
        }
    }
}

private nonisolated func structuredEBook(name: String, author: String = "") -> NoteImportDraftBook {
    var book = NoteImportDraftBook()
    book.name = name
    book.rawName = name
    book.author = author
    book.type = 1
    book.positionUnit = 1
    book.currentPositionUnit = 1
    return book
}

private nonisolated func parseCSV(_ source: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var index = source.startIndex
    while index < source.endIndex {
        let character = source[index]
        if character == "\"" {
            let next = source.index(after: index)
            if quoted, next < source.endIndex, source[next] == "\"" {
                field.append("\"")
                index = next
            } else {
                quoted.toggle()
            }
        } else if character == ",", !quoted {
            row.append(field)
            field = ""
        } else if character == "\n", !quoted {
            row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            rows.append(row)
            row = []
            field = ""
        } else {
            field.append(character)
        }
        index = source.index(after: index)
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }
    return rows
}

private nonisolated func trimEndWhitespace(_ value: String) -> String {
    var result = value
    while result.last?.isWhitespace == true { result.removeLast() }
    return result
}

private extension Dictionary where Key == String, Value == Any {
    nonisolated func string(_ key: String) -> String { self[key] as? String ?? "" }
    nonisolated func int64(_ key: String) -> Int64 {
        (self[key] as? NSNumber)?.int64Value ?? Int64(self[key] as? String ?? "") ?? 0
    }
}
