/**
 * [INPUT]: 依赖统一 NoteImportParserRegistry、NoteImportRepositoryProtocol 与 Android 导入任务 DTO
 * [OUTPUT]: 对外提供 30 分钟内存任务、异步解析、预览投影、幂等提交与任务删除
 * [POS]: Infra 层 Web 导入编排；Parser 和 Repository 仍是 App 业务 owner，Package 只持有能力端口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import XMNoteWeb
import ZIPFoundation

/// actor 串行保护任务状态；解析任务继承服务生命周期，提交通过 MainActor Repository 完成逐书事务。
actor DesktopWebImportService: DesktopWebImportPort {
    private struct ParsedBook: Sendable {
        var draft: NoteImportDraftBook
        let matchedBookID: Int64?
        let matchedBookName: String?
    }

    private struct Record: Sendable {
        let taskID: String
        var status: String
        let createdTime: Int64
        var updatedTime: Int64
        var sourceID: Int64?
        var sourceName: String?
        var books: [ParsedBook]
        var message: String?
        var importedBookCount: Int
        var importedNoteCount: Int
        var isCommitting: Bool
    }

    private let parserRegistry: NoteImportParserRegistry
    private let repository: any NoteImportRepositoryProtocol
    private let currentTimeMillis: @Sendable () -> Int64
    private var tasks: [String: Record] = [:]

    init(
        repository: any NoteImportRepositoryProtocol,
        parserRegistry: NoteImportParserRegistry = .init(),
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.repository = repository
        self.parserRegistry = parserRegistry
        self.currentTimeMillis = currentTimeMillis
    }

    /// 建立 processing 任务后立即返回，解析失败只写入任务详情，不让创建请求同步失败。
    func createImportTask(file: DesktopWebUploadedFile) async throws -> DesktopWebImportTaskCreateResponse {
        cleanupExpiredTasks()
        try Self.validateArchiveBeforeTaskCreation(file)
        let now = currentTimeMillis()
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        tasks[id] = Record(
            taskID: id,
            status: "pending",
            createdTime: now,
            updatedTime: now,
            sourceID: nil,
            sourceName: nil,
            books: [],
            message: nil,
            importedBookCount: 0,
            importedNoteCount: 0,
            isCommitting: false
        )
        Task { [weak self] in
            await self?.parseTask(id: id, file: file)
        }
        return .init(taskId: id, status: "processing")
    }

    /// 返回当前一致任务快照；不存在与过期任务使用 Android 的业务错误。
    func importTask(id: String) async throws -> DesktopWebJSONValue {
        cleanupExpiredTasks()
        guard let record = tasks[id] else {
            throw DesktopWebAPIError(code: 40001, message: "导入任务不存在或已过期")
        }
        return Self.detailJSON(record)
    }

    /// 合并同书多条选择、校验索引与目标冲突，并对 committed 任务返回原计数。
    func commitImportTask(
        id: String,
        request: DesktopWebImportTaskCommitRequest
    ) async throws -> DesktopWebImportTaskCommitResponse {
        cleanupExpiredTasks()
        guard var record = tasks[id] else {
            throw DesktopWebAPIError(code: 40001, message: "导入任务不存在或已过期")
        }
        if record.status == "committed" {
            return .init(importedBookCount: record.importedBookCount, importedNoteCount: record.importedNoteCount)
        }
        guard !record.isCommitting else {
            throw DesktopWebAPIError(code: 40001, message: "导入任务正在提交，请勿重复操作")
        }
        guard record.status == "succeeded" else {
            throw DesktopWebAPIError(code: 40001, message: "解析尚未完成，暂时无法导入")
        }
        record.isCommitting = true
        tasks[id] = record

        do {
            guard !request.books.isEmpty else {
                throw DesktopWebAPIError(code: 40001, message: "请至少选择一条书摘")
            }
            for targetBookID in Set(request.books.compactMap(\.targetBookId)) {
                guard try await repository.hasImportTargetBook(id: targetBookID) else {
                    throw DesktopWebAPIError(code: 40001, message: "目标书籍不存在: \(targetBookID)")
                }
            }

            var selections: [Int: (indexes: Set<Int>, target: Int64?, clear: Bool)] = [:]
            for selection in request.books {
                guard record.books.indices.contains(selection.index) else {
                    throw DesktopWebAPIError(code: 40001, message: "存在无效书籍索引: \(selection.index)")
                }
                var merged = selections[selection.index] ?? ([], nil, false)
                if selection.clearTargetBook { merged.clear = true }
                if let target = selection.targetBookId {
                    guard !merged.clear else {
                        throw DesktopWebAPIError(code: 40001, message: "同一本书不能同时清除和指定目标书籍")
                    }
                    if let existing = merged.target, existing != target {
                        throw DesktopWebAPIError(code: 40001, message: "同一本书存在冲突的目标书籍")
                    }
                    merged.target = target
                }
                for noteIndex in selection.noteIndexes {
                    guard record.books[selection.index].draft.notes.indices.contains(noteIndex) else {
                        throw DesktopWebAPIError(code: 40001, message: "存在无效书摘索引: \(noteIndex)")
                    }
                    merged.indexes.insert(noteIndex)
                }
                selections[selection.index] = merged
            }

            var commits: [NoteImportCommitBook] = []
            for bookIndex in selections.keys.sorted() {
                guard let selection = selections[bookIndex], !selection.indexes.isEmpty else { continue }
                let parsed = record.books[bookIndex]
                var draft = parsed.draft
                draft.notes = selection.indexes.sorted().map { draft.notes[$0] }
                let target = selection.clear ? nil : (selection.target ?? parsed.matchedBookID)
                commits.append(.init(draft: draft, targetBookID: target))
            }
            guard !commits.isEmpty else {
                throw DesktopWebAPIError(code: 40001, message: "请至少选择一条书摘")
            }
            commits = await repository.enrichImportBookInfoIfNeeded(commits)
            try await repository.commitImport(books: commits, progress: { _, _ in })
            record.status = "committed"
            record.isCommitting = false
            record.importedBookCount = commits.count
            record.importedNoteCount = commits.reduce(0) { $0 + $1.draft.notes.count }
            record.updatedTime = currentTimeMillis()
            if tasks[id] != nil {
                tasks[id] = record
            }
            return .init(
                importedBookCount: record.importedBookCount,
                importedNoteCount: record.importedNoteCount
            )
        } catch {
            if var current = tasks[id], current.status != "committed" {
                current.isCommitting = false
                tasks[id] = current
            }
            throw error
        }
    }

    /// 删除未知任务也返回成功；已经运行的解析任务在回写前检查记录仍存在。
    func deleteImportTask(id: String) async throws {
        cleanupExpiredTasks()
        tasks.removeValue(forKey: id)
    }

    private func parseTask(id: String, file: DesktopWebUploadedFile) async {
        guard var record = tasks[id] else { return }
        record.status = "processing"
        record.updatedTime = currentTimeMillis()
        tasks[id] = record
        do {
            let result = try await parse(file)
            let validBooks = result.books.compactMap { draft -> NoteImportDraftBook? in
                var draft = draft
                if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = draft.rawName }
                if draft.rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.rawName = draft.name }
                draft.notes = draft.notes.filter {
                    !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !$0.idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !draft.notes.isEmpty else { return nil }
                draft.source = result.sourceID
                draft.sourceName = Self.sourceName(result.sourceID) ?? ""
                return draft
            }
            guard !validBooks.isEmpty else {
                throw NoteImportParserError.unexpected("解析结果为空，请确认文件中包含有效书籍与书摘后重试")
            }
            var projected: [ParsedBook] = []
            for draft in validBooks {
                let match = try await repository.matchLocalBook(for: draft)
                projected.append(.init(
                    draft: draft,
                    matchedBookID: match?.id,
                    matchedBookName: match?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? match?.title : nil
                ))
            }
            guard var current = tasks[id] else { return }
            current.status = "succeeded"
            current.sourceID = result.sourceID
            current.sourceName = Self.sourceName(result.sourceID)
            current.books = projected
            current.message = nil
            current.updatedTime = currentTimeMillis()
            tasks[id] = current
        } catch {
            guard var current = tasks[id] else { return }
            current.status = "failed"
            current.message = error.localizedDescription.isEmpty ? "文件解析失败，请检查文件格式" : error.localizedDescription
            current.updatedTime = currentTimeMillis()
            tasks[id] = current
        }
    }

    private func parse(_ file: DesktopWebUploadedFile) async throws -> (books: [NoteImportDraftBook], sourceID: Int64) {
        let ext = URL(fileURLWithPath: file.fileName).pathExtension.lowercased()
        if ext == "json" {
            let parserID = try Self.detectWebJSONSource(file.data)
            guard let parser = parserRegistry.parser(for: parserID) else {
                throw NoteImportParserError.unexpected("暂不支持该 JSON 文件格式，请确认后重试")
            }
            return (try await parser.parse(data: file.data, fileExtension: ext), Self.sourceID(parserID))
        }
        if ext == "epub" {
            let parser = parserRegistry.parser(for: .ireaderEpub)!
            return (try await parser.parse(data: file.data, fileExtension: ext), 24)
        }
        if ext == "zip" {
            let archive = try Archive(data: file.data, accessMode: .read)
            let csvEntries = Self.flattenedCSVEntries(in: archive)
            if !csvEntries.isEmpty {
                guard let parser = parserRegistry.parser(for: .koodo) else {
                    throw NoteImportParserError.noteFormat
                }
                var batches: [[NoteImportDraftBook]] = []
                for entry in csvEntries {
                    var data = Data()
                    _ = try archive.extract(entry) { data.append($0) }
                    batches.append(try await parser.parse(data: data, fileExtension: "csv"))
                }
                return (Self.mergeKoodoBooks(batches), 23)
            }
            if Self.hasFlattenedOEBPS(in: archive) {
                let parser = parserRegistry.parser(for: .ireaderEpub)!
                return (try await parser.parse(data: file.data, fileExtension: "epub"), 24)
            }
            let parser = parserRegistry.parser(for: .appleBooks)!
            return (try await parser.parse(data: file.data, fileExtension: ext), 5)
        }
        guard ["txt", "html", "md", "csv"].contains(ext),
              let parserID = Self.detectWebTextSource(file.data, extension: ext),
              let parser = parserRegistry.parser(for: parserID) else {
            throw NoteImportParserError.unexpected("暂不支持该文件格式，请确认后重试")
        }
        let books: [NoteImportDraftBook]
        if let fileNameAware = parser as? any NoteImportFileNameAwareParser {
            books = try await fileNameAware.parse(
                data: file.data,
                fileName: file.fileName,
                fileExtension: ext
            )
        } else {
            books = try await parser.parse(data: file.data, fileExtension: ext)
        }
        return (books, Self.sourceID(parserID))
    }

    private func cleanupExpiredTasks() {
        // iOS 任务制品只存在于任务记录的内存 Data 中；登记前失败随调用栈释放，不存在本地遗漏目录。
        // 已登记任务仍与 Android 一样采用请求驱动 TTL 清理，不引入后台调度器。
        let now = currentTimeMillis()
        tasks = tasks.filter { now - $0.value.updatedTime <= 30 * 60 * 1_000 }
    }
}

private extension DesktopWebImportService {
    private static func detailJSON(_ record: Record) -> DesktopWebJSONValue {
        var object: [String: DesktopWebJSONValue] = [
            "taskId": .string(record.taskID),
            "status": .string(record.status),
            "totalBooks": .integer(Int64(record.books.count)),
            "totalNotes": .integer(Int64(record.books.reduce(0) { $0 + $1.draft.notes.count })),
            "books": .array(record.books.enumerated().map { bookIndex, book in
                var item: [String: DesktopWebJSONValue] = [
                    "index": .integer(Int64(bookIndex)),
                    "title": .string(book.draft.name),
                    "noteCount": .integer(Int64(book.draft.notes.count)),
                    "notes": .array(book.draft.notes.enumerated().map { noteIndex, note in
                        var noteObject: [String: DesktopWebJSONValue] = [
                            "index": .integer(Int64(noteIndex)),
                            "content": .string(note.content)
                        ]
                        if !note.idea.isEmpty { noteObject["idea"] = .string(note.idea) }
                        if let title = note.chapter?.title, !title.isEmpty { noteObject["chapterTitle"] = .string(title) }
                        if !note.position.isEmpty { noteObject["position"] = .string(note.position) }
                        if note.isIncludeTime, note.createdTime > 0 { noteObject["createdTime"] = .integer(note.createdTime) }
                        return .object(noteObject)
                    })
                ]
                if !book.draft.author.isEmpty { item["author"] = .string(book.draft.author) }
                if let id = book.matchedBookID { item["matchedBookId"] = .integer(id) }
                if let name = book.matchedBookName { item["matchedBookName"] = .string(name) }
                return .object(item)
            }),
            "importedBookCount": .integer(Int64(record.importedBookCount)),
            "importedNoteCount": .integer(Int64(record.importedNoteCount)),
            "createdTime": .integer(record.createdTime),
            "updatedTime": .integer(record.updatedTime)
        ]
        if let sourceID = record.sourceID { object["sourceId"] = .integer(sourceID) }
        if let sourceName = record.sourceName { object["sourceName"] = .string(sourceName) }
        if let message = record.message { object["message"] = .string(message) }
        return .object(object)
    }

    static func sourceID(_ parser: NoteImportParserID) -> Int64 {
        switch parser {
        case .kindle: 2
        case .kindleApp: 3
        case .wereadOld, .wereadPre830, .weread830: 4
        case .appleBooks: 5
        case .moonReader: 6
        case .duokan: 7
        case .ireaderSelected: 10
        case .doubanRead: 9
        case .jdReader: 11
        case .booxOld, .booxNew: 12
        case .dangdang: 13
        case .koreader: 14
        case .reader163: 15
        case .doubanApp: 16
        case .legado: 17
        case .neatReader: 18
        case .hanwang: 19
        case .fanqie: 20
        case .dimo: 21
        case .koodo: 23
        case .ireaderEpub: 24
        case .dedao: 25
        case .reeden: 26
        case .readingo: 27
        case .ireaderFile: 8
        }
    }

    static func sourceName(_ id: Int64) -> String? {
        let values = [
            "未知", "Kindle阅读器", "Kindle App", "微信读书", "Apple Books", "静读天下", "多看阅读",
            "掌阅", "豆瓣阅读", "掌阅精选", "京东读书", "文石阅读器", "当当云阅读", "KOReader",
            "网易蜗牛", "豆瓣阅读(App)", "阅读", "Neat Reader", "汉王阅读器", "番茄小说", "滴墨书摘",
            "三联生活周刊", "Koodo Reader", "iReader", "得到", "Reeden", "Readingo"
        ]
        guard id > 0, id <= Int64(values.count) else { return nil }
        return values[Int(id - 1)]
    }

    static func detectWebJSONSource(_ data: Data) throws -> NoteImportParserID {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw NoteImportParserError.unexpected("暂不支持该 JSON 文件格式，请确认后重试")
        }
        let objects: [[String: Any]]
        if let object = root as? [String: Any] { objects = [object] }
        else if let array = root as? [[String: Any]] { objects = array }
        else {
            throw NoteImportParserError.unexpected("暂不支持该 JSON 文件格式，请确认后重试")
        }

        let first = objects.first ?? [:]
        let reeden = !(first["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ((first["notes"] as? [[String: Any]])?.contains {
                !($0["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !($0["comment"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false)
        let neat = root is [String: Any]
            && !(first["bookName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ((first["noteList"] as? [[String: Any]])?.contains {
                !($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !($0["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false)
        let koreader = root is [String: Any] && isKOReaderJSON(first)
        let matches: [NoteImportParserID] = [
            reeden ? .reeden : nil,
            neat ? .neatReader : nil,
            koreader ? .koreader : nil
        ].compactMap { $0 }
        guard matches.count == 1 else {
            throw NoteImportParserError.unexpected(matches.isEmpty
                ? "暂不支持该 JSON 文件格式，请确认后重试"
                : "无法导入，文件里包含多种书摘格式。请按同一来源重新导出后重试")
        }
        return matches[0]
    }

    static func detectWebTextSource(_ data: Data, extension ext: String) -> NoteImportParserID? {
        if ext == "csv" { return .koodo }
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        if content.contains("此文档通过 [滴墨书摘APP](https://www.inkonote.com/share?platform=markdown) 导出")
            || content.contains("*此文档通过 滴墨书摘APP 导出") {
            return .dimo
        }
        if content.contains("==========") { return .kindle }
        if NoteImportDetection.isBoox(content) {
            return NoteImportDetection.isOldBoox(content) ? .booxOld : .booxNew
        }
        if NoteImportTextSupport.contains(pattern: "^#.*的批注与划线", in: content) {
            return .doubanRead
        }
        if content.contains("<div class=\"bookTitle\">") { return .kindleApp }
        return nil
    }

    static func isKOReaderJSON(_ object: [String: Any]) -> Bool {
        func hasNotes(_ value: Any?) -> Bool {
            (value as? [[String: Any]])?.contains {
                !($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !($0["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
        }
        if let documents = object["documents"] as? [[String: Any]], !documents.isEmpty {
            return documents.contains {
                (!(($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(($0["file"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    && hasNotes($0["entries"])
            }
        }
        return (!(object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(object["file"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && hasNotes(object["entries"])
    }

    static func validateArchiveBeforeTaskCreation(_ file: DesktopWebUploadedFile) throws {
        let ext = URL(fileURLWithPath: file.fileName).pathExtension.lowercased()
        guard ext == "zip" || ext == "epub" else { return }
        let archive = try Archive(data: file.data, accessMode: .read)
        var entryCount = 0
        var extractedBytes: UInt64 = 0
        for entry in archive {
            entryCount += 1
            guard entryCount <= 10_000 else {
                throw DesktopWebAPIError(code: 40001, message: "压缩包文件数量过多")
            }
            guard isSafeArchivePath(entry.path) else {
                throw DesktopWebAPIError(code: 40001, message: "压缩包包含非法文件路径")
            }
            let sum = extractedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !sum.overflow, sum.partialValue <= 512 * 1024 * 1024 else {
                throw DesktopWebAPIError(code: 40001, message: "压缩包解压后文件过大")
            }
            extractedBytes = sum.partialValue
        }
        guard archive.contains(where: { $0.type != .directory }) else {
            throw DesktopWebAPIError(
                code: 40001,
                message: ext == "zip"
                    ? "你上传的压缩包中没有文件"
                    : "未能从你上传的 Epub 文件中读取到任何内容"
            )
        }
    }

    static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              path.range(of: #"^[A-Za-z]:"# , options: .regularExpression) == nil else {
            return false
        }
        let components = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")
    }

    static func flattenedCSVEntries(in archive: Archive) -> [Entry] {
        archive.filter { entry in
            guard entry.type != .directory,
                  entry.path.lowercased().hasSuffix(".csv") else { return false }
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            return components.count == 1 || components.count == 2
        }
    }

    static func hasFlattenedOEBPS(in archive: Archive) -> Bool {
        archive.contains { entry in
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { return false }
            if components[0].localizedCaseInsensitiveContains("OEBPS") { return true }
            return components.count > 1 && components[1].localizedCaseInsensitiveContains("OEBPS")
        }
    }

    static func mergeKoodoBooks(_ batches: [[NoteImportDraftBook]]) -> [NoteImportDraftBook] {
        var books: [NoteImportDraftBook] = []
        for batch in batches {
            for incoming in batch {
                let identity = incoming.rawName.isEmpty ? incoming.name : incoming.rawName
                guard let index = books.firstIndex(where: {
                    ($0.rawName.isEmpty ? $0.name : $0.rawName) == identity
                }) else {
                    books.append(incoming)
                    continue
                }
                for note in incoming.notes {
                    if let noteIndex = books[index].notes.firstIndex(where: {
                        $0.createdTime == note.createdTime
                    }) {
                        if !note.idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            books[index].notes[noteIndex].idea = note.idea
                        }
                    } else {
                        books[index].notes.append(note)
                    }
                }
                books[index].notes.sort { $0.createdTime < $1.createdTime }
            }
        }
        return books.sorted {
            ($0.notes.last?.createdTime ?? 0) > ($1.notes.last?.createdTime ?? 0)
        }
    }
}
