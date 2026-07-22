import Foundation
import GRDB
import Testing
@testable import xmnote

struct ApiNoteImportTests {
    @Test
    func hummingbirdSendRouteAcceptsAndroidDTO() async throws {
        let port = Int.random(in: 18_000...19_000)
        let probe = ApiServerProbe()
        let server = ApiNoteImportServer()
        await server.start(port: port, accessCode: "123456", isPremium: true) { payload in
            await probe.receive(payload)
        } onState: { state in
            await probe.receive(state)
        }
        defer { Task { await server.stop() } }
        for _ in 0..<100 {
            if await probe.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await probe.isRunning)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/send")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("123456", forHTTPHeaderField: "X-XMNote-Access-Code")
        request.httpBody = Data("{\"title\":\"服务测试\",\"type\":1,\"locationUnit\":0}".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("\"code\":200") == true)
        #expect(await probe.bookName == "服务测试")
        request.setValue("wrong", forHTTPHeaderField: "X-XMNote-Access-Code")
        let (rejectedData, rejectedResponse) = try await URLSession.shared.data(for: request)
        #expect((rejectedResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: rejectedData, encoding: .utf8)?.contains("\"code\":500") == true)
        #expect(String(data: rejectedData, encoding: .utf8)?.contains("访问码不正确") == true)
        await server.stop()
    }

    @Test
    func androidDTOValidationAndConversion() throws {
        let json = """
        {
          "title":"API 测试书","author":"作者","type":1,"locationUnit":1,
          "totalPageCount":500,"currentPage":42,"rating":4.5,"source":"Kindle App",
          "entries":[{"page":42,"text":"原文","note":"想法","chapter":"第一章","time":1710000000}],
          "reviews":[{"title":"短评","content":"<p>正文</p>","time":1710000000}],
          "chapters":[{"title":"第一章","children":[{"title":"第一节"}]}],
          "preciseReadingDurations":[{"startTime":1710000000,"endTime":1710000060,"position":42}],
          "fuzzyReadingDurations":[{"date":1710028800,"durationSeconds":600,"position":42}]
        }
        """
        let dto = try JSONDecoder().decode(ApiNoteImportDTO.self, from: Data(json.utf8))
        let payload = try dto.validatedPayload(now: 2_000_000_000_000)
        #expect(payload.source == 3)
        #expect(payload.noteList.first?.createdDateTime == 1_710_000_000_000)
        #expect(payload.preciseReadingDurations?.first?.endTime == 1_710_000_060_000)
        #expect(payload.apiImportChapterList.first?.children.first?.pathTitles == ["第一章", "第一节"])
    }

    @Test
    func androidDTOValidationMessageIsStable() throws {
        let dto = try JSONDecoder().decode(ApiNoteImportDTO.self, from: Data("{\"type\":1,\"locationUnit\":1}".utf8))
        do { _ = try dto.validatedPayload(); Issue.record("应当校验失败") }
        catch { #expect(error.localizedDescription == "书籍名称（title）是必填项，不能为空。") }
    }

    @Test @MainActor
    func unifiedDraftWritesEveryRepresentativeTable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("note_import_snapshot_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent(AppDatabase.databaseName).path)
        let repository = NoteImportRepository(databaseManager: DatabaseManager(database: database), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let tables = ["book", "chapter", "note", "review", "review_image", "attach_image", "group_book", "tag_book", "tag_note", "read_time_record", "book_read_status_record"]
        let baseline = try await database.dbPool.read { db in try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE is_deleted = 0") ?? 0 } }

        let child = NoteImportDraftChapter(title: "第一节", level: 2, order: 1, pathTitles: ["第一章", "第一节"], sourceType: 2, sourcePath: "第一章$第一节")
        let root = NoteImportDraftChapter(title: "第一章", level: 1, order: 1, pathTitles: ["第一章"], sourceType: 2, sourcePath: "第一章", children: [child])
        var draft = NoteImportDraftBook()
        draft.name = "快照书"; draft.rawName = "快照书"; draft.author = "作者"; draft.type = 1; draft.source = 3; draft.positionUnit = 1; draft.currentPositionUnit = 1
        draft.group = NoteImportDraftGroup(name: "导入分组")
        draft.tags = [NoteImportDraftTag(name: "书籍标签", type: 2)]
        draft.chapters = [root]
        draft.notes = [NoteImportDraftNote(content: "原文", idea: "想法", position: "12", positionUnit: 1, createdTime: 1_710_000_000_000, chapter: child, tags: [NoteImportDraftTag(name: "笔记标签", type: 1)], attachments: [NoteImportDraftAttachment(imageURL: "https://example.com/a.jpg")])]
        draft.reviews = [NoteImportDraftReview(title: "短评", content: "<p>正文</p>", createdTime: 1_710_000_000_000, images: [NoteImportDraftReviewImage(image: "https://example.com/r.jpg", order: 1)])]
        draft.preciseReadingDurations = [NoteImportPreciseReadingDuration(startTime: 1_710_000_000_000, endTime: 1_710_000_060_000, position: 12)]
        draft.fuzzyReadingDurations = [NoteImportFuzzyReadingDuration(date: 1_710_028_800_000, durationSeconds: 600, position: 12)]
        draft.readStatusID = 3; draft.readStatusChangedDate = 1_710_000_000_000

        try await repository.commitImport(books: [NoteImportCommitBook(draft: draft)]) { _, _ in }
        let counts = try await database.dbPool.read { db in
            try tables.map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE is_deleted = 0") ?? 0
            }
        }
        #expect(zip(counts, baseline).map { $0.0 - $0.1 } == [1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1])
    }
}

private actor ApiServerProbe {
    var state: ApiNoteImportServer.State = .stopped
    var bookName: String?
    var isRunning: Bool { state == .running }
    func receive(_ value: ApiNoteImportServer.State) { state = value }
    func receive(_ payload: ApiImportBookPayload) { bookName = payload.name }
}
