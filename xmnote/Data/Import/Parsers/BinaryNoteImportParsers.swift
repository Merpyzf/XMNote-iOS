/**
 * [INPUT]: 依赖 Foundation、ZIPFoundation、SwiftSoup、GRDB 与统一导入模型，接收 iReader EPUB 和 Apple Books ZIP
 * [OUTPUT]: 对外提供 IReaderEBookNoteImportParser 与 AppleBooksNoteImportParser
 * [POS]: Data/Import/Parsers 的二进制文件实现，在临时目录解压并复刻 Android HTML/SQLite 解析规则
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import SwiftSoup
import ZIPFoundation

nonisolated struct IReaderEBookNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .ireaderEpub

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        try withExtractedArchive(data, extension: "epub") { root in
            let oebps = root.appendingPathComponent("OEBPS", isDirectory: true)
            let opf = oebps.appendingPathComponent("content.opf")
            let source = try String(contentsOf: opf, encoding: .utf8)
            guard let rawTitle = NoteImportTextSupport.firstCapture(
                pattern: "<dc:title[^>]*>(.*?)</dc:title>",
                in: source,
                options: [.caseInsensitive]
            ) else { throw NoteImportParserError.bookNotFound }
            let title = cleanIReaderTitle(rawTitle)
            guard !title.isEmpty else { throw NoteImportParserError.bookNotFound }
            var book = binaryEBook(name: title)
            let chapterURLs = try FileManager.default.contentsOfDirectory(
                at: oebps,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("chapter") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for chapterURL in chapterURLs {
                let document = try SwiftSoup.parse(String(contentsOf: chapterURL, encoding: .utf8))
                let chapterTitle = try document.getElementsByTag("h2").first()?.text() ?? ""
                for (index, element) in try document.getElementsByClass("zybooknote_summary").array().enumerated() {
                    let original = try element.text()
                    let idea = try element.getElementsByClass("zybooknote_remark").first()?.text() ?? ""
                    guard !NoteImportTextSupport.isBlank(original) || !NoteImportTextSupport.isBlank(idea) else { continue }
                    let href = try element.getElementsByTag("a").first()?.attr("href") ?? ""
                    book.notes.append(NoteImportDraftNote(
                        content: original,
                        idea: idea,
                        position: NoteImportTextSupport.firstCapture(pattern: "##([\\d-]+)##\\$", in: href) ?? "",
                        createdTime: 0,
                        isIncludeTime: false,
                        chapter: NoteImportDraftChapter(title: chapterTitle, order: Int64(index))
                    ))
                }
            }
            return [book]
        }
    }

    private func cleanIReaderTitle(_ value: String) -> String {
        var result = NoteImportTextSupport.trimmed(value)
        for pattern in ["\\[.*?]", "\\(.*?\\)", "（.*?）"] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        result = (try? NSRegularExpression(pattern: "\\s+").stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: " "
        )) ?? result
        return NoteImportTextSupport.trimmed(result)
    }
}

nonisolated struct AppleBooksNoteImportParser: NoteImportParser {
    let id: NoteImportParserID = .appleBooks

    func parse(data: Data, fileExtension _: String?) async throws -> [NoteImportDraftBook] {
        try withExtractedArchive(data, extension: "zip") { root in
            let children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            guard children.count == 1 else { throw NoteImportParserError.invalidDatabase }
            let export = children[0]
            let files = try FileManager.default.contentsOfDirectory(at: export, includingPropertiesForKeys: nil)
            guard let bookDB = files.first(where: { $0.lastPathComponent.hasPrefix("BKLibrary") && $0.pathExtension == "sqlite" }),
                  let noteDB = files.first(where: { $0.lastPathComponent.hasPrefix("AEAnnotation") && $0.pathExtension == "sqlite" })
            else { throw NoteImportParserError.invalidDatabase }
            let bookQueue = try DatabaseQueue(path: bookDB.path)
            let noteQueue = try DatabaseQueue(path: noteDB.path)
            let rows = try bookQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT ZSORTTITLE, ZSORTAUTHOR, ZASSETID FROM ZBKLIBRARYASSET")
            }
            var books: [NoteImportDraftBook] = []
            for row in rows {
                guard let rawTitle: String = row["ZSORTTITLE"] else { continue }
                let name = rawTitle.components(separatedBy: "（").first ?? rawTitle
                var book = binaryEBook(name: name, author: (row["ZSORTAUTHOR"] as String?) ?? "")
                let assetID: String = row["ZASSETID"]
                let noteRows = try noteQueue.read { db in
                    try Row.fetchAll(
                        db,
                        sql: """
                        SELECT ZANNOTATIONNOTE, ZANNOTATIONREPRESENTATIVETEXT,
                               ZANNOTATIONSELECTEDTEXT, ZANNOTATIONMODIFICATIONDATE
                        FROM ZAEANNOTATION
                        WHERE ZANNOTATIONASSETID = ? AND ZANNOTATIONDELETED = 0
                        """,
                        arguments: [assetID]
                    )
                }
                for noteRow in noteRows {
                    let selected: String? = noteRow["ZANNOTATIONSELECTEDTEXT"]
                    let representative: String? = noteRow["ZANNOTATIONREPRESENTATIVETEXT"]
                    let idea: String? = noteRow["ZANNOTATIONNOTE"]
                    let modification: Int64 = noteRow["ZANNOTATIONMODIFICATIONDATE"]
                    let original = selected ?? representative ?? ""
                    let noteIdea = idea ?? ""
                    guard !NoteImportTextSupport.isBlank(original) || !NoteImportTextSupport.isBlank(noteIdea) else { continue }
                    book.notes.append(NoteImportDraftNote(
                        content: original,
                        idea: noteIdea,
                        positionUnit: 1,
                        createdTime: (978_307_200 + modification) * 1_000
                    ))
                }
                if !book.notes.isEmpty { books.append(book) }
            }
            return books
        }
    }
}

private nonisolated func withExtractedArchive<T>(
    _ data: Data,
    extension fileExtension: String,
    operation: (URL) throws -> T
) throws -> T {
    let fileManager = FileManager.default
    let working = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let archive = working.appendingPathComponent("source.\(fileExtension)")
    let extracted = working.appendingPathComponent("extracted", isDirectory: true)
    defer { try? fileManager.removeItem(at: working) }
    do {
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try data.write(to: archive, options: .atomic)
        try fileManager.unzipItem(at: archive, to: extracted)
        return try operation(extracted)
    } catch let error as NoteImportParserError {
        throw error
    } catch {
        throw NoteImportParserError.noteFormat
    }
}

private nonisolated func binaryEBook(name: String, author: String = "") -> NoteImportDraftBook {
    var book = NoteImportDraftBook()
    book.name = name
    book.rawName = name
    book.author = author
    book.type = 1
    book.positionUnit = 1
    book.currentPositionUnit = 1
    return book
}
