/**
 * [INPUT]: 依赖 Foundation、NoteImportModels 与 NoteImportTextSupport，接收 Kindle My Clippings 文本
 * [OUTPUT]: 对外提供 KindleClippingsNoteImportParser，输出标注、笔记与最新书签合并后的统一 Draft
 * [POS]: Data/Import/Parsers 的 Kindle 文件实现，逐记录隔离失败并保持 Android 源顺序与绑定语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct KindleClippingsNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .kindle

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let records = KindleClippingRecordParser.parse(content)
        let recordsByIndex = Dictionary(uniqueKeysWithValues: records.map { ($0.sourceIndex, $0) })
        var identities: [KindleBookIdentity] = []
        var recordsByIdentity: [KindleBookIdentity: [KindleClippingRecord]] = [:]

        for record in records {
            if recordsByIdentity[record.identity] == nil {
                identities.append(record.identity)
            }
            recordsByIdentity[record.identity, default: []].append(record)
        }

        let positionedBooks = identities.enumerated().compactMap { order, identity -> (Int, NoteImportDraftBook)? in
            guard let bookRecords = recordsByIdentity[identity],
                  let book = buildBook(identity: identity, records: bookRecords, recordsByIndex: recordsByIndex)
            else { return nil }
            return (order, book)
        }
        guard !positionedBooks.isEmpty else { throw NoteImportParserError.noteNotFound }
        return positionedBooks.sorted { lhs, rhs in
            let lhsTime = lhs.1.notes.last?.createdTime ?? 0
            let rhsTime = rhs.1.notes.last?.createdTime ?? 0
            return lhsTime == rhsTime ? lhs.0 < rhs.0 : lhsTime > rhsTime
        }.map(\.1)
    }

    private func buildBook(
        identity: KindleBookIdentity,
        records: [KindleClippingRecord],
        recordsByIndex: [Int: KindleClippingRecord]
    ) -> NoteImportDraftBook? {
        let annotations = records.filter { $0.type != .bookmark }
        let positionUnit: Int64 = annotations.contains { $0.position.location != nil } ? 1 : 2
        let highlights = records.filter { $0.type == .highlight }
        let noteRecords = records.filter { $0.type == .note }
        var notesByHighlightIndex: [Int: [KindleClippingRecord]] = [:]
        var standaloneNotes: [KindleClippingRecord] = []

        for noteRecord in noteRecords {
            if let highlight = relatedHighlight(
                for: noteRecord,
                highlights: highlights,
                recordsByIndex: recordsByIndex
            ) {
                notesByHighlightIndex[highlight.sourceIndex, default: []].append(noteRecord)
            } else {
                standaloneNotes.append(noteRecord)
            }
        }

        var positionedNotes: [(Int, NoteImportDraftNote)] = []
        for highlight in highlights {
            let relatedNotes = notesByHighlightIndex[highlight.sourceIndex, default: []]
                .sorted { $0.sourceIndex < $1.sourceIndex }
            let idea = relatedNotes.map(\.content)
                .filter { !NoteImportTextSupport.isBlank($0) }
                .joined(separator: "\n\n")
            guard !NoteImportTextSupport.isBlank(highlight.content) || !NoteImportTextSupport.isBlank(idea) else {
                continue
            }
            let relatedTime = relatedNotes.first(where: { $0.createdTime > 0 })?.createdTime ?? 0
            let createdTime = highlight.createdTime > 0 ? highlight.createdTime : relatedTime
            positionedNotes.append((highlight.sourceIndex, makeNote(
                content: highlight.content,
                idea: idea,
                position: highlight.position.primaryValue(for: positionUnit),
                positionUnit: positionUnit,
                createdTime: createdTime
            )))
        }

        for noteRecord in standaloneNotes where !NoteImportTextSupport.isBlank(noteRecord.content) {
            positionedNotes.append((noteRecord.sourceIndex, makeNote(
                content: "",
                idea: noteRecord.content,
                position: noteRecord.position.primaryValue(for: positionUnit),
                positionUnit: positionUnit,
                createdTime: noteRecord.createdTime
            )))
        }
        guard !positionedNotes.isEmpty else { return nil }

        var book = NoteImportDraftBook()
        book.name = identity.title
        book.rawName = identity.title
        book.author = identity.author
        book.type = 1
        book.source = 2
        book.positionUnit = positionUnit
        book.currentPositionUnit = positionUnit
        book.notes = positionedNotes.sorted { $0.0 < $1.0 }.map(\.1)
        applyLatestBookmark(to: &book, records: records, positionUnit: positionUnit)
        return book
    }

    private func relatedHighlight(
        for noteRecord: KindleClippingRecord,
        highlights: [KindleClippingRecord],
        recordsByIndex: [Int: KindleClippingRecord]
    ) -> KindleClippingRecord? {
        if let previous = recordsByIndex[noteRecord.sourceIndex - 1],
           previous.type == .highlight,
           previous.identity == noteRecord.identity,
           previous.position.page != nil,
           previous.position.page == noteRecord.position.page,
           previous.createdTime > 0,
           previous.createdTime == noteRecord.createdTime {
            return previous
        }

        let locationMatches = highlights.filter { $0.position.containsLocation(of: noteRecord.position) }
        return locationMatches.count == 1 ? locationMatches[0] : nil
    }

    private func makeNote(
        content: String,
        idea: String,
        position: String,
        positionUnit: Int64,
        createdTime: Int64
    ) -> NoteImportDraftNote {
        NoteImportDraftNote(
            content: content,
            idea: idea,
            position: position,
            positionUnit: positionUnit,
            createdTime: createdTime,
            isIncludeTime: createdTime > 0
        )
    }

    private func applyLatestBookmark(
        to book: inout NoteImportDraftBook,
        records: [KindleClippingRecord],
        positionUnit: Int64
    ) {
        guard let bookmark = records
            .filter({ $0.type == .bookmark && $0.createdTime > 0 })
            .max(by: { $0.createdTime < $1.createdTime })
        else { return }
        let position = bookmark.position.primaryValue(for: positionUnit)
            .components(separatedBy: "-").first ?? ""
        guard let readPosition = Double(position) else { return }
        book.readPosition = readPosition
        book.bookmarkModifiedTime = bookmark.createdTime
    }
}

private nonisolated enum KindleClippingType {
    case highlight
    case note
    case bookmark
}

private nonisolated struct KindleBookIdentity: Hashable {
    let title: String
    let author: String
}

private nonisolated struct KindleClippingPosition {
    let page: String?
    let location: String?

    func primaryValue(for positionUnit: Int64) -> String {
        if positionUnit == 1 {
            return location ?? page ?? ""
        }
        return page ?? location ?? ""
    }

    func containsLocation(of other: KindleClippingPosition) -> Bool {
        guard let otherStart = other.location?.components(separatedBy: "-").first.flatMap(Int64.init),
              let location,
              let start = location.components(separatedBy: "-").first.flatMap(Int64.init),
              let end = location.components(separatedBy: "-").last.flatMap(Int64.init)
        else { return false }
        return (start ... end).contains(otherStart)
    }
}

private nonisolated struct KindleClippingRecord {
    let identity: KindleBookIdentity
    let type: KindleClippingType
    let position: KindleClippingPosition
    let content: String
    let createdTime: Int64
    let sourceIndex: Int
}

private nonisolated enum KindleClippingRecordParser {
    private static let separator = "=========="
    private static let numericRange = "([0-9]+(?:\\s*[-–—]\\s*[0-9]+)?)"
    private static let locationPatterns = [
        "位置\\s*#?\\s*\(numericRange)",
        "(?i)\\blocation\\s*#?\\s*\(numericRange)",
        "(?i)\\bposici[oó]n\\s*#?\\s*\(numericRange)"
    ]
    private static let pagePatterns = [
        "第\\s*#?\\s*\(numericRange)\\s*页",
        "在\\s*#?\\s*\(numericRange)\\s*页上",
        "(?i)\\bpage\\s*#?\\s*\(numericRange)",
        "(?i)\\bp[aá]gina\\s*#?\\s*\(numericRange)"
    ]
    private static let spanishMonths = [
        "enero": 1, "febrero": 2, "marzo": 3, "abril": 4,
        "mayo": 5, "junio": 6, "julio": 7, "agosto": 8,
        "septiembre": 9, "setiembre": 9, "octubre": 10,
        "noviembre": 11, "diciembre": 12
    ]

    static func parse(_ content: String) -> [KindleClippingRecord] {
        guard !NoteImportTextSupport.isBlank(content) else { return [] }
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return splitRecords(normalized).enumerated().compactMap { index, block in
            parseRecord(block, sourceIndex: index)
        }
    }

    private static func splitRecords(_ content: String) -> [String] {
        var records: [String] = []
        var lines: [String] = []
        for line in content.components(separatedBy: "\n") {
            if NoteImportTextSupport.trimmed(line) == separator {
                if lines.contains(where: { !NoteImportTextSupport.isBlank($0) }) {
                    records.append(lines.joined(separator: "\n"))
                }
                lines.removeAll(keepingCapacity: true)
            } else {
                lines.append(line)
            }
        }
        if lines.contains(where: { !NoteImportTextSupport.isBlank($0) }) {
            records.append(lines.joined(separator: "\n"))
        }
        return records
    }

    private static func parseRecord(_ block: String, sourceIndex: Int) -> KindleClippingRecord? {
        let lines = block.components(separatedBy: "\n")
        guard let metadataIndex = lines.firstIndex(where: { parseType($0) != nil }), metadataIndex > 0 else {
            return nil
        }
        let metadata = NoteImportTextSupport.trimmed(lines[metadataIndex])
        guard let type = parseType(metadata) else { return nil }
        let titleLine = lines[..<metadataIndex]
            .map { NoteImportTextSupport.trimmed($0).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let identity = parseIdentity(titleLine) else { return nil }
        let content = lines.dropFirst(metadataIndex + 1).joined(separator: "\n")

        return KindleClippingRecord(
            identity: identity,
            type: type,
            position: KindleClippingPosition(
                page: findPosition(in: metadata, patterns: pagePatterns),
                location: findPosition(in: metadata, patterns: locationPatterns)
            ),
            content: NoteImportTextSupport.trimmed(content),
            createdTime: parseDate(metadata),
            sourceIndex: sourceIndex
        )
    }

    private static func parseIdentity(_ titleLine: String) -> KindleBookIdentity? {
        guard !NoteImportTextSupport.isBlank(titleLine) else { return nil }
        let parenthesizedMatch = captures(
            pattern: "^(.*)\\s*-?\\s*[（(]([^()（）]*)[）)]\\s*$",
            in: titleLine
        )
        if parenthesizedMatch.count > 2 {
            var title = parenthesizedMatch[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if title.last == "-" { title.removeLast() }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return KindleBookIdentity(
                title: title,
                author: NoteImportTextSupport.trimmed(parenthesizedMatch[2])
            )
        }
        let dashMatch = captures(pattern: "^(.+?)\\s+-\\s+(.+)$", in: titleLine)
        if dashMatch.count > 2 {
            let title = NoteImportTextSupport.trimmed(dashMatch[1])
            guard !title.isEmpty else { return nil }
            return KindleBookIdentity(title: title, author: NoteImportTextSupport.trimmed(dashMatch[2]))
        }
        return KindleBookIdentity(title: NoteImportTextSupport.trimmed(titleLine), author: "")
    }

    private static func parseType(_ metadata: String) -> KindleClippingType? {
        let trimmed = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("- ") else { return nil }
        let typePart = String(trimmed.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]).lowercased()
        if ["bookmark", "书签", "marcador"].contains(where: typePart.contains) { return .bookmark }
        if ["highlight", "标注", "subrayado"].contains(where: typePart.contains) { return .highlight }
        if ["note", "笔记", "备注", "nota"].contains(where: typePart.contains) { return .note }
        return nil
    }

    private static func findPosition(in metadata: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let value = captures(pattern: pattern, in: metadata).dropFirst().first else { continue }
            return value
                .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-")
        }
        return nil
    }

    private static func parseDate(_ metadata: String) -> Int64 {
        let chineseMatch = captures(
            pattern: "(\\d{4})年(\\d{1,2})月(\\d{1,2})日.*?(上午|下午)\\s*(\\d{1,2}):(\\d{1,2}):(\\d{1,2})",
            in: metadata
        )
        if chineseMatch.count > 7 {
            let hour12 = Int(chineseMatch[5]) ?? 0
            let hour: Int
            if chineseMatch[4] == "上午", hour12 == 12 {
                hour = 0
            } else if chineseMatch[4] == "下午", hour12 < 12 {
                hour = hour12 + 12
            } else {
                hour = hour12
            }
            return timestamp(
                year: Int(chineseMatch[1]) ?? 0,
                month: Int(chineseMatch[2]) ?? 0,
                day: Int(chineseMatch[3]) ?? 0,
                hour: hour,
                minute: Int(chineseMatch[6]) ?? 0,
                second: Int(chineseMatch[7]) ?? 0
            )
        }

        if let english = captures(
            pattern: "(?i)(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),\\s*.+$",
            in: metadata
        ).first {
            let normalized = english.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            for format in ["EEEE, MMMM d, yyyy h:mm:ss a", "EEEE, d MMMM yyyy HH:mm:ss"] {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .current
                formatter.dateFormat = format
                formatter.isLenient = false
                if let date = formatter.date(from: normalized) {
                    return Int64(date.timeIntervalSince1970 * 1_000)
                }
            }
        }

        let spanishMatch = captures(
            pattern: "(?i)Añadido el \\p{L}+,\\s*(\\d{1,2}) de (\\p{L}+) de (\\d{4}) (\\d{1,2}):(\\d{1,2}):(\\d{1,2})",
            in: metadata
        )
        if spanishMatch.count > 6, let month = spanishMonths[spanishMatch[2].lowercased()] {
            return timestamp(
                year: Int(spanishMatch[3]) ?? 0,
                month: month,
                day: Int(spanishMatch[1]) ?? 0,
                hour: Int(spanishMatch[4]) ?? 0,
                minute: Int(spanishMatch[5]) ?? 0,
                second: Int(spanishMatch[6]) ?? 0
            )
        }

        let isoMatch = captures(
            pattern: "(\\d{4})-(\\d{2})-(\\d{2})\\s+(\\d{1,2}):(\\d{2}):(\\d{2})",
            in: metadata
        )
        if isoMatch.count > 6 {
            return timestamp(
                year: Int(isoMatch[1]) ?? 0,
                month: Int(isoMatch[2]) ?? 0,
                day: Int(isoMatch[3]) ?? 0,
                hour: Int(isoMatch[4]) ?? 0,
                minute: Int(isoMatch[5]) ?? 0,
                second: Int(isoMatch[6]) ?? 0
            )
        }
        return 0
    }

    private static func timestamp(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let date = calendar.date(from: components) else { return 0 }
        let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day,
              resolved.hour == hour, resolved.minute == minute, resolved.second == second
        else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func captures(pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else { return [] }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}
