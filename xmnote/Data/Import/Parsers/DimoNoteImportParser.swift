/**
 * [INPUT]: 依赖 Foundation、NoteImportModels、NoteImportTextSupport 与 NoteImportAttachmentImporter，接收滴墨 Markdown
 * [OUTPUT]: 对外提供 DimoNoteImportParser 的统一 Draft 结果
 * [POS]: Data/Import/Parsers 的滴墨实现，通过注入边界隔离附件下载上传与 Golden 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct DimoNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .dimo
    private let attachmentImporter: any NoteImportAttachmentImporter

    init(attachmentImporter: any NoteImportAttachmentImporter) {
        self.attachmentImporter = attachmentImporter
    }

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        let content = try NoteImportTextSupport.decodeUTF8(data)
        let sections = content.components(separatedBy: "- - - -")
        guard let info = sections.first,
              let rawName = NoteImportTextSupport.firstCapture(pattern: "# 《(.*?)》—— \\d+ 条滴墨书摘", in: info)
        else { throw NoteImportParserError.bookNotFound }
        let name = clearQuotationMarks(rawName)
        guard !NoteImportTextSupport.isBlank(name) else { throw NoteImportParserError.bookNotFound }
        guard sections.count > 1 else { throw NoteImportParserError.noteNotFound }

        var book = NoteImportDraftBook()
        book.name = name
        book.rawName = name
        book.author = captureLine("- 作者：(.*)", in: info)
        book.press = captureLine("- 出版：(.*)", in: info)
        let published = captureLine("- 出版时间：(.*)", in: info)
        book.pubDate = normalizedPublishDate(published)
        book.type = 0
        book.positionUnit = 2
        book.currentPositionUnit = 2
        if let coverSource = firstImageURL(in: info) {
            book.cover = try await importedURLString(coverSource) ?? ""
        }

        for section in sections.dropFirst() {
            let imageSources = allImageURLs(in: section)
            let noteContent = NoteImportTextSupport.firstCapture(
                pattern: "### ([\\s\\S]+?)(>|第(\\d+?)页|\\d{4}-\\d{2}-\\d{2})",
                in: section
            ).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let idea = NoteImportTextSupport.firstCapture(
                pattern: "> 心得：([\\s\\S]+?)(第(\\d+?)页|\\d{4}-\\d{2}-\\d{2})",
                in: section
            ).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard !imageSources.isEmpty || !NoteImportTextSupport.isBlank(noteContent) || !NoteImportTextSupport.isBlank(idea) else {
                continue
            }
            var attachments: [NoteImportDraftAttachment] = []
            for source in imageSources {
                if let imported = try await importedURLString(source) {
                    attachments.append(NoteImportDraftAttachment(imageURL: imported, order: Int64(attachments.count + 1)))
                }
            }
            let createdDate = NoteImportTextSupport.firstCapture(pattern: "(\\d{4}-\\d{2}-\\d{2})", in: section)
                .map(dayMilliseconds) ?? 0
            book.notes.append(NoteImportDraftNote(
                content: noteContent,
                idea: idea,
                position: NoteImportTextSupport.firstCapture(pattern: "第(\\d+?)页", in: section) ?? "",
                positionUnit: 2,
                createdTime: createdDate,
                isIncludeTime: createdDate != 0,
                attachments: attachments
            ))
        }
        return [book]
    }

    private func importedURLString(_ value: String) async throws -> String? {
        guard let url = URL(string: value) else { return nil }
        do {
            return try await attachmentImporter.importAttachment(from: url)?.absoluteString
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func captureLine(_ pattern: String, in value: String) -> String {
        NoteImportTextSupport.firstCapture(pattern: pattern, in: value) ?? ""
    }

    private func firstImageURL(in value: String) -> String? {
        NoteImportTextSupport.firstCapture(pattern: "!\\[]\\((.*?)\\)", in: value)
    }

    private func allImageURLs(in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "!\\[]\\((.*?)\\)") else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: value) else { return nil }
            let result = String(value[capture])
            return NoteImportTextSupport.isBlank(result) ? nil : result
        }
    }

    private func dayMilliseconds(_ value: String) -> Int64 {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = true
        return formatter.date(from: value).map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
    }

    private func normalizedPublishDate(_ value: String) -> String {
        NoteImportTextSupport.contains(pattern: "^\\d{4}-\\d{2}-\\d{2}$", in: value)
            ? String(value.prefix(7))
            : value
    }

    private func clearQuotationMarks(_ value: String) -> String {
        value.replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
            .replacingOccurrences(of: "<<", with: "")
            .replacingOccurrences(of: ">>", with: "")
    }
}
