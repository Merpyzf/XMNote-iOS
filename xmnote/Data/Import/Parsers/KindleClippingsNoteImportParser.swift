/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收 Kindle My Clippings 文本
 * [OUTPUT]: 对外提供 KindleClippingsNoteImportParser，输出按位置绑定想法后的统一 Draft
 * [POS]: Data/Import/Parsers 的 Kindle 文件实现，保留 Android 两阶段解析和位置范围匹配语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct KindleClippingsNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .kindle

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let blocks = content.components(separatedBy: "==========")
        var containers: [KindleBookContainer] = []

        for raw in blocks {
            let block = NoteImportTextSupport.trimmed(raw)
            guard !block.isEmpty,
                  block.contains("的标注 | ") || block.contains("Your Highlight") || block.contains("La subrayado en"),
                  let name = bookName(block),
                  let original = noteContent(block),
                  let position = position(block)
            else { continue }
            var note = NoteImportDraftNote(
                content: original,
                position: position,
                positionUnit: 1,
                createdTime: noteDate(block)
            )
            note.positionUnit = 1
            if let index = containers.firstIndex(where: { $0.book.name == name }) {
                containers[index].notes.append(note)
            } else {
                var book = NoteImportDraftBook()
                book.name = name
                book.rawName = name
                book.author = bookAuthor(block)
                book.type = 1
                book.positionUnit = 1
                book.currentPositionUnit = 1
                containers.append(KindleBookContainer(book: book, notes: [note]))
            }
        }

        for raw in blocks {
            let block = NoteImportTextSupport.trimmed(raw)
            guard !block.isEmpty,
                  block.contains("的笔记 | ") || block.contains("Your Note") || block.contains("La nota en"),
                  let name = bookName(block)
            else { continue }
            let idea = noteContent(block) ?? ""
            guard !NoteImportTextSupport.isBlank(idea), let position = position(block) else { continue }
            let value = KindleIdea(content: idea, position: position, createdTime: noteDate(block))
            if let index = containers.firstIndex(where: { $0.book.name == name }) {
                containers[index].ideas.append(value)
            } else {
                var book = NoteImportDraftBook()
                book.name = name
                containers.append(KindleBookContainer(book: book, ideas: [value]))
            }
        }

        var books: [NoteImportDraftBook] = []
        for container in containers {
            var book = container.book
            for note in container.notes {
                var matches = 0
                for idea in container.ideas {
                    guard let range = positionRange(note.position),
                          let ideaPosition = positionStart(idea.position),
                          range.contains(ideaPosition)
                    else { continue }
                    book.notes.append(NoteImportDraftNote(
                        content: note.content,
                        idea: idea.content,
                        position: note.position,
                        createdTime: note.createdTime
                    ))
                    matches += 1
                }
                if matches == 0 { book.notes.append(note) }
            }
            books.append(book)
        }
        guard !books.isEmpty else { throw NoteImportParserError.noteNotFound }
        return books.sorted { ($0.notes.last?.createdTime ?? 0) > ($1.notes.last?.createdTime ?? 0) }
    }

    private func bookName(_ block: String) -> String? {
        guard let first = block.components(separatedBy: "\r\n").first else { return nil }
        if let bracket = first.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            let name = String(first[..<bracket]).replacingOccurrences(of: " ", with: "")
            return name.isEmpty ? nil : name
        }
        let name = first.replacingOccurrences(of: " ", with: "")
        return name.isEmpty ? nil : name
    }

    private func bookAuthor(_ block: String) -> String {
        guard let first = block.components(separatedBy: "\r\n").first,
              let start = first.lastIndex(of: "(")
        else { return "" }
        return String(first[first.index(after: start) ..< first.index(before: first.endIndex)])
    }

    private func noteContent(_ block: String) -> String? {
        guard let range = block.range(of: "\r\n\r\n") else { return nil }
        let value = NoteImportTextSupport.trimmed(String(block[range.upperBound...]))
        return value.isEmpty ? nil : value
    }

    private func position(_ block: String) -> String? {
        let patterns = [
            "位置 (#.*?)[）的]",
            "[lL]ocation (.*?)\\|",
            "[pP]osición (.*?)\\|",
            "- 您在第 (.*?) 页",
            "page (.*?)\\|",
            "página (.*?)\\|"
        ]
        for pattern in patterns {
            if let value = NoteImportTextSupport.firstCapture(pattern: pattern, in: block) {
                return NoteImportTextSupport.trimmed(value)
            }
        }
        return nil
    }

    private func noteDate(_ block: String) -> Int64 {
        if let value = NoteImportTextSupport.firstCapture(pattern: "\\| Added on (.*)", in: block) {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "EEEE d MMMM yyyy HH:mm:ss"
            return formatter.date(from: value.replacingOccurrences(of: ",", with: ""))
                .map { Int64($0.timeIntervalSince1970) * 1_000 } ?? 0
        }
        if let year = NoteImportTextSupport.firstCapture(pattern: "添加于 (\\d+)年(\\d+)月(\\d+)日.* (..)(\\d+):(\\d+):(\\d+)", in: block, group: 1),
           let month = NoteImportTextSupport.firstCapture(pattern: "添加于 (\\d+)年(\\d+)月(\\d+)日.* (..)(\\d+):(\\d+):(\\d+)", in: block, group: 2),
           let day = NoteImportTextSupport.firstCapture(pattern: "添加于 (\\d+)年(\\d+)月(\\d+)日.* (..)(\\d+):(\\d+):(\\d+)", in: block, group: 3),
           let marker = NoteImportTextSupport.firstCapture(pattern: "添加于 (\\d+)年(\\d+)月(\\d+)日.* (..)(\\d+):(\\d+):(\\d+)", in: block, group: 4),
           let hour = NoteImportTextSupport.firstCapture(pattern: "添加于 (\\d+)年(\\d+)月(\\d+)日.* (..)(\\d+):(\\d+):(\\d+)", in: block, group: 5),
           let minute = NoteImportTextSupport.firstCapture(pattern: "添加于 (\\d+)年(\\d+)月(\\d+)日.* (..)(\\d+):(\\d+):(\\d+)", in: block, group: 6),
           let second = NoteImportTextSupport.firstCapture(pattern: "添加于 (\\d+)年(\\d+)月(\\d+)日.* (..)(\\d+):(\\d+):(\\d+)", in: block, group: 7)
        {
            let adjustedHour = (Int(hour) ?? 0) + (marker == "下午" ? 12 : 0)
            return NoteImportTextSupport.dateMilliseconds(
                "\(year)-\(month)-\(day) \(adjustedHour):\(minute):\(second)",
                format: "yyyy-M-d H:mm:ss"
            )
        }
        return 0
    }

    private func positionRange(_ value: String) -> ClosedRange<Int>? {
        let pieces = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .components(separatedBy: "-")
        guard pieces.count == 2, let start = Int(pieces[0]), let end = Int(pieces[1]) else { return nil }
        return start ... end
    }

    private func positionStart(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).components(separatedBy: "-").first ?? "")
    }
}

private nonisolated struct KindleBookContainer {
    var book: NoteImportDraftBook
    var notes: [NoteImportDraftNote] = []
    var ideas: [KindleIdea] = []
}

private nonisolated struct KindleIdea {
    var content: String
    var position: String
    var createdTime: Int64
}
