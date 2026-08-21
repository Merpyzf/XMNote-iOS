/**
 * [INPUT]: 依赖 DesktopWebImportService、ZIPFoundation 与可控 NoteImportRepositoryProtocol Stub
 * [OUTPUT]: 验证 Android Web 导入来源识别、ZIP 一层扁平化、任务状态和显式目标校验
 * [POS]: iOS App Web 导入编排单元测试；锁定 4 条 Import API 的关键边界语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Testing
import XMNoteWeb
import ZIPFoundation
@testable import xmnote

@MainActor
struct DesktopWebImportServiceTests {
    @Test
    func zipUsesFlattenedCSVPriorityAndMergesSameBookAcrossFiles() async throws {
        let repository = ImportRepositoryStub()
        let service = DesktopWebImportService(repository: repository)
        let first = Data("""
        key,chapter,text,notes,bookName,bookAuthor
        100,第一章,原文一,,同一本书,作者
        """.utf8)
        let second = Data("""
        key,chapter,text,notes,bookName,bookAuthor
        100,第一章,原文一,补充想法,同一本书,作者
        200,第二章,原文二,,同一本书,作者
        """.utf8)
        let archive = try makeZIP([
            "Koodo/first.csv": first,
            "second.csv": second,
            "Koodo/OEBPS/content.opf": Data("<package/>".utf8)
        ])

        let created = try await service.createImportTask(file: .init(
            fileName: "notes.zip",
            contentType: "application/zip",
            data: archive
        ))
        #expect(created.status == "processing")

        let detail = try await waitForImportTask(service, id: created.taskId, status: "succeeded")
        #expect(detail["sourceId"]?.integerValue == 23)
        #expect(detail["totalBooks"]?.integerValue == 1)
        #expect(detail["totalNotes"]?.integerValue == 2)
        let books = try #require(detail["books"]?.arrayValue)
        let book = try #require(books.first?.objectValue)
        let notes = try #require(book["notes"]?.arrayValue)
        #expect(notes.first?.objectValue?["idea"]?.stringValue == "补充想法")
    }

    @Test
    func textDetectionRejectsSourcesNotExposedByAndroidWebImport() async throws {
        let service = DesktopWebImportService(repository: ImportRepositoryStub())
        let created = try await service.createImportTask(file: .init(
            fileName: "dedao.txt",
            contentType: "text/plain",
            data: Data("一条笔记\n——来自得到App".utf8)
        ))

        let detail = try await waitForImportTask(service, id: created.taskId, status: "failed")
        #expect(detail["message"]?.stringValue == "暂不支持该文件格式，请确认后重试")
    }

    @Test
    func invalidExplicitTargetFailsBeforeRepositoryCommit() async throws {
        let repository = ImportRepositoryStub(existingTargetIDs: [])
        let service = DesktopWebImportService(repository: repository)
        let csv = Data("""
        key,chapter,text,notes,bookName,bookAuthor
        100,第一章,原文,,测试书,作者
        """.utf8)
        let created = try await service.createImportTask(file: .init(
            fileName: "notes.csv",
            contentType: "text/csv",
            data: csv
        ))
        _ = try await waitForImportTask(service, id: created.taskId, status: "succeeded")

        do {
            _ = try await service.commitImportTask(
                id: created.taskId,
                request: .init(books: [
                    .init(index: 0, noteIndexes: [0], targetBookId: 9_999, clearTargetBook: false)
                ])
            )
            Issue.record("不存在的显式目标书应被拒绝")
        } catch let error as DesktopWebAPIError {
            #expect(error.code == 40_001)
            #expect(error.message == "目标书籍不存在: 9999")
        }
        #expect(repository.committedBooks.isEmpty)
    }

    @Test
    func emptyArchiveFailsSynchronouslyBeforeCreatingTask() async throws {
        let service = DesktopWebImportService(repository: ImportRepositoryStub())
        let archive = try Archive(data: Data(), accessMode: .create)
        let data = try #require(archive.data)

        do {
            _ = try await service.createImportTask(file: .init(
                fileName: "empty.zip",
                contentType: "application/zip",
                data: data
            ))
            Issue.record("空 ZIP 应在创建任务前失败")
        } catch let error as DesktopWebAPIError {
            #expect(error.code == 40_001)
            #expect(error.message == "你上传的压缩包中没有文件")
        }
    }
}

@MainActor
private final class ImportRepositoryStub: NoteImportRepositoryProtocol {
    let existingTargetIDs: Set<Int64>
    private(set) var committedBooks: [NoteImportCommitBook] = []

    init(existingTargetIDs: Set<Int64> = []) {
        self.existingTargetIDs = existingTargetIDs
    }

    func loadKindleClippingsFile(from url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    func fetchHanWangShareContent(from _: String) async throws -> String {
        ""
    }

    func fetchLifeWeekBooks(
        phoneNumber _: String,
        password _: String
    ) async throws -> [NoteImportDraftBook] {
        []
    }

    func matchLocalBook(for _: NoteImportDraftBook) async throws -> BookPickerBook? {
        nil
    }

    func hasImportTargetBook(id: Int64) async throws -> Bool {
        existingTargetIDs.contains(id)
    }

    func enrichImportBookInfoIfNeeded(
        _ books: [NoteImportCommitBook]
    ) async -> [NoteImportCommitBook] {
        books
    }

    func commitImport(
        books: [NoteImportCommitBook],
        progress: @escaping (Int, Int) -> Void
    ) async throws {
        committedBooks = books
        progress(books.count, books.count)
    }
}

private extension DesktopWebJSONValue {
    var arrayValue: [DesktopWebJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

private func waitForImportTask(
    _ service: DesktopWebImportService,
    id: String,
    status: String
) async throws -> [String: DesktopWebJSONValue] {
    for _ in 0 ..< 200 {
        let detail = try await service.importTask(id: id)
        let object = try #require(detail.objectValue)
        if object["status"]?.stringValue == status { return object }
        await Task.yield()
    }
    Issue.record("导入任务未进入 \(status)")
    return [:]
}

private func makeZIP(_ files: [String: Data]) throws -> Data {
    let archive = try Archive(data: Data(), accessMode: .create)
    for path in files.keys.sorted() {
        let data = files[path] ?? Data()
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count)
        ) { position, size in
            let start = Int(position)
            guard start < data.count else { return Data() }
            return data.subdata(in: start ..< min(start + size, data.count))
        }
    }
    return try #require(archive.data)
}
