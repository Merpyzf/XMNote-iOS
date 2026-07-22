import CryptoKit
import Foundation
import Testing
@testable import xmnote

struct ImportParserParityTests {
    @Test
    func mirroredFixtureAndGoldenHashesMatchFrozenManifest() throws {
        for testCase in try ImportParityFixture.cases() {
            #expect(try ImportParityFixture.sha256(testCase.inputURL) == testCase.inputSHA256)
            #expect(try ImportParityFixture.sha256(testCase.expectedURL) == testCase.expectedSHA256)
        }
    }

    @Test
    func productionParsersMatchAndroidGoldenByteForByte() async throws {
        try await ImportParityFixture.withFrozenEnvironment {
            let registry = NoteImportParserRegistry()
            for testCase in try ImportParityFixture.cases() {
                let importParser = try #require(makeParser(for: testCase.parserID, registry: registry))
                let data = try Data(contentsOf: testCase.inputURL)
                let actual = await ImportParserContractV1.execute(
                    parser: importParser,
                    data: data,
                    fileName: testCase.inputURL.lastPathComponent
                )
                let expected = try Data(contentsOf: testCase.expectedURL)
                #expect(
                    actual == expected,
                    Comment(rawValue: "\(testCase.id): \(JSONPointerDiff.first(expected: expected, actual: actual))")
                )
            }
        }
    }

    @Test
    func productionDetectionMatchesAndroidSelection() throws {
        for testCase in try ImportParityFixture.cases()
            where testCase.expectedStatus == "success" && testCase.selectionMode == "automatic"
        {
            let data = try Data(contentsOf: testCase.inputURL)
            #expect(NoteImportDetection.detect(data: data, fileExtension: testCase.inputURL.pathExtension) == testCase.parserID)
        }
    }

    @Test
    func wereadClipboardVersionDetectionMatchesAndroidSelection() throws {
        for testCase in try ImportParityFixture.cases()
            where testCase.expectedStatus == "success"
                && [.wereadOld, .wereadPre830, .weread830].contains(testCase.parserID)
        {
            let data = try Data(contentsOf: testCase.inputURL)
            #expect(NoteImportDetection.detectWereadClipboard(data: data) == testCase.parserID)
        }
    }

    @Test
    func rulesLedgerReferencesEveryCaseAndEveryParserHasSuccessAndFailureEvidence() throws {
        let cases = try ImportParityFixture.cases()
        for (parserID, parserCases) in Dictionary(grouping: cases, by: \.parserID) {
            #expect(parserCases.contains { $0.expectedStatus == "success" }, "\(parserID.rawValue) missing success evidence")
            #expect(parserCases.contains { $0.expectedStatus == "failure" }, "\(parserID.rawValue) missing failure evidence")
        }

        let data = try Data(contentsOf: ImportParityFixture.root.appending(path: "rules.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rules = try #require(object["rules"] as? [[String: Any]])
        let referencedCases = Set(rules.flatMap { $0["fixtureCases"] as? [String] ?? [] })
        #expect(referencedCases == Set(cases.map(\.id)))
    }

    @Test
    func deterministicMutationOutputsMatchAndroidOracle() async throws {
        try await ImportParityFixture.withFrozenEnvironment {
            let registry = NoteImportParserRegistry()
            for testCase in try ImportParityFixture.mutationCases() {
                #expect(try ImportParityFixture.sha256(testCase.inputURL) == testCase.inputSHA256)
                #expect(try ImportParityFixture.sha256(testCase.expectedURL) == testCase.expectedSHA256)
                let importParser = try #require(makeParser(for: testCase.parserID, registry: registry))
                let actual = await ImportParserContractV1.execute(
                    parser: importParser,
                    data: try Data(contentsOf: testCase.inputURL),
                    fileName: testCase.inputURL.lastPathComponent
                )
                let expected = try Data(contentsOf: testCase.expectedURL)
                #expect(
                    actual == expected,
                    Comment(rawValue: "\(testCase.id): \(JSONPointerDiff.first(expected: expected, actual: actual))")
                )
            }
        }
    }

    @Test
    func iOSParserOutputIsDeterministicAcrossTwentyExecutions() async throws {
        try await ImportParityFixture.withFrozenEnvironment {
            let registry = NoteImportParserRegistry()
            for testCase in try ImportParityFixture.cases() {
                let importParser = try #require(makeParser(for: testCase.parserID, registry: registry))
                let data = try Data(contentsOf: testCase.inputURL)
                let first = await ImportParserContractV1.execute(
                    parser: importParser,
                    data: data,
                    fileName: testCase.inputURL.lastPathComponent
                )
                for _ in 1 ..< 20 {
                    #expect(await ImportParserContractV1.execute(
                        parser: importParser,
                        data: data,
                        fileName: testCase.inputURL.lastPathComponent
                    ) == first)
                }
            }
        }
    }

    private func makeParser(
        for id: NoteImportParserID,
        registry: NoteImportParserRegistry
    ) -> (any NoteImportParser)? {
        if id == .dimo {
            return DimoNoteImportParser(attachmentImporter: FixtureAttachmentImporter())
        }
        if id == .hanwang {
            return HanWangNoteImportParser(bookTitle: "汉王测试书")
        }
        return registry.parser(for: id)
    }
}

private struct FixtureAttachmentImporter: NoteImportAttachmentImporter {
    func importAttachment(from _: URL) async throws -> URL? {
        nil
    }
}

private enum ImportParserContractV1 {
    static func execute(parser: any NoteImportParser, data: Data, fileName: String? = nil) async -> Data {
        let object: [String: Any]
        do {
            object = [
                "schemaVersion": 1,
                "status": "success",
                "books": try await parse(parser: parser, data: data, fileName: fileName).map(book)
            ]
        } catch let error as NoteImportParserError {
            object = failure(code: error.code, message: error.errorDescription ?? "未知解析错误")
        } catch {
            object = failure(code: "unexpected", message: error.localizedDescription)
        }
        var encoded = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        encoded.append(0x0A)
        return encoded
    }

    private static func parse(
        parser: any NoteImportParser,
        data: Data,
        fileName: String?
    ) async throws -> [NoteImportDraftBook] {
        if let fileName, let parser = parser as? any NoteImportFileNameAwareParser {
            return try await parser.parse(
                data: data,
                fileName: fileName,
                fileExtension: (fileName as NSString).pathExtension
            )
        }
        return try await parser.parse(data: data, fileExtension: fileName.map { ($0 as NSString).pathExtension })
    }

    private static func failure(code: String, message: String) -> [String: Any] {
        [
            "schemaVersion": 1,
            "status": "failure",
            "error": ["code": code, "message": message]
        ]
    }

    private static func book(_ book: NoteImportDraftBook) -> [String: Any] {
        [
            "name": book.name,
            "rawName": book.rawName,
            "author": book.author,
            "authorIntro": book.authorIntro,
            "translator": book.translator,
            "press": book.press,
            "isbn": book.isbn,
            "summary": book.summary,
            "pubDate": book.pubDate,
            "cover": book.cover,
            "type": book.type,
            "source": book.source,
            "sourceName": book.sourceName,
            "positionUnit": book.positionUnit,
            "currentPositionUnit": book.currentPositionUnit,
            "readPosition": decimal(book.readPosition),
            "totalPosition": book.totalPosition,
            "totalPagination": book.totalPagination,
            "wordCount": book.wordCount ?? NSNull(),
            "readStatusId": book.readStatusID,
            "readStatusChangedDate": book.readStatusChangedDate,
            "readDoneTime": book.readDoneTime,
            "wereadBookId": book.wereadBookID,
            "wereadUpdateTime": book.wereadUpdateTime,
            "group": book.group.map(group) ?? NSNull(),
            "groups": book.groups.map(group),
            "tags": book.tags.map(tag),
            "notes": book.notes.map(note),
            "chapters": book.chapters.map(chapter),
            "reviews": book.reviews.map(review),
            "preciseReadingDurations": book.preciseReadingDurations?.map(preciseDuration) ?? NSNull(),
            "fuzzyReadingDurations": book.fuzzyReadingDurations?.map(fuzzyDuration) ?? NSNull()
        ]
    }

    private static func note(_ note: NoteImportDraftNote) -> [String: Any] {
        [
            "content": note.content,
            "idea": note.idea,
            "position": note.position,
            "positionUnit": note.positionUnit,
            "createdTime": note.createdTime,
            "isIncludeTime": note.isIncludeTime,
            "wereadRange": note.wereadRange,
            "wereadChapterUid": note.wereadChapterUID,
            "chapter": note.chapter.map(chapter) ?? NSNull(),
            "tags": note.tags.map(tag),
            "attachments": note.attachments.map {
                ["imageUrl": $0.imageURL, "order": $0.order] as [String: Any]
            }
        ]
    }

    private static func chapter(_ chapter: NoteImportDraftChapter) -> [String: Any] {
        [
            "title": chapter.title,
            "remark": chapter.remark,
            "level": chapter.level,
            "order": chapter.order,
            "pathTitles": chapter.pathTitles,
            "sourceType": chapter.sourceType,
            "sourceUid": chapter.sourceUID,
            "sourceAnchor": chapter.sourceAnchor,
            "sourceOrder": chapter.sourceOrder,
            "sourcePath": chapter.sourcePath,
            "children": chapter.children.map(self.chapter)
        ]
    }

    private static func review(_ review: NoteImportDraftReview) -> [String: Any] {
        [
            "title": review.title,
            "content": review.content,
            "createdTime": review.createdTime,
            "images": review.images.map { ["image": $0.image, "order": $0.order] as [String: Any] }
        ]
    }

    private static func group(_ group: NoteImportDraftGroup) -> [String: Any] {
        ["name": group.name, "order": group.order]
    }

    private static func tag(_ tag: NoteImportDraftTag) -> [String: Any] {
        ["name": tag.name, "color": tag.color, "order": tag.order, "type": tag.type]
    }

    private static func preciseDuration(_ value: NoteImportPreciseReadingDuration) -> [String: Any] {
        [
            "startTime": value.startTime ?? NSNull(),
            "endTime": value.endTime ?? NSNull(),
            "position": value.position.map(decimal) ?? NSNull()
        ]
    }

    private static func fuzzyDuration(_ value: NoteImportFuzzyReadingDuration) -> [String: Any] {
        [
            "date": value.date ?? NSNull(),
            "durationSeconds": value.durationSeconds ?? NSNull(),
            "position": value.position.map(decimal) ?? NSNull()
        ]
    }

    private static func decimal(_ value: Double) -> String {
        guard let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else {
            return String(value)
        }
        var mutableDecimal = decimal
        return NSDecimalString(&mutableDecimal, Locale(identifier: "en_US_POSIX"))
    }
}

private struct ImportParityCase {
    let id: String
    let parserID: NoteImportParserID
    let inputURL: URL
    let inputSHA256: String
    let expectedURL: URL
    let expectedSHA256: String
    let expectedStatus: String
    let selectionMode: String
}

private struct ImportMutationCase {
    let id: String
    let parserID: NoteImportParserID
    let inputURL: URL
    let inputSHA256: String
    let expectedURL: URL
    let expectedSHA256: String
}

private enum ImportParityFixture {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/ImportParity/v1", directoryHint: .isDirectory)

    static func cases() throws -> [ImportParityCase] {
        let data = try Data(contentsOf: root.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.androidCommit == "6bb279fdf74aed287fc93a12c3f3aab6a8f7ee29")
        let selectedCases = ProcessInfo.processInfo.environment["IMPORT_PARITY_CASE"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        return try manifest.cases.filter { selectedCases == nil || selectedCases?.contains($0.id) == true }.map { item in
            ImportParityCase(
                id: item.id,
                parserID: try #require(NoteImportParserID(rawValue: item.parserId)),
                inputURL: root.appending(path: item.input),
                inputSHA256: item.inputSHA256,
                expectedURL: root.appending(path: item.expected),
                expectedSHA256: item.expectedSHA256,
                expectedStatus: item.expectedStatus,
                selectionMode: item.selectionMode ?? "automatic"
            )
        }
    }

    static func mutationCases() throws -> [ImportMutationCase] {
        let mutationRoot = root.appending(path: "mutations", directoryHint: .isDirectory)
        let data = try Data(contentsOf: mutationRoot.appending(path: "mutation-manifest.json"))
        let manifest = try JSONDecoder().decode(MutationManifest.self, from: data)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.androidCommit == "6bb279fdf74aed287fc93a12c3f3aab6a8f7ee29")
        return try manifest.cases.map { item in
            ImportMutationCase(
                id: item.id,
                parserID: try #require(NoteImportParserID(rawValue: item.parserId)),
                inputURL: mutationRoot.appending(path: item.input),
                inputSHA256: item.inputSHA256,
                expectedURL: mutationRoot.appending(path: item.expected),
                expectedSHA256: item.expectedSHA256
            )
        }
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func withFrozenEnvironment(_ operation: () async throws -> Void) async rethrows {
        let previousTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
        defer { NSTimeZone.default = previousTimeZone }
        try await operation()
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let androidCommit: String
        let cases: [Case]

        struct Case: Decodable {
            let id: String
            let parserId: String
            let input: String
            let inputSHA256: String
            let expected: String
            let expectedSHA256: String
            let expectedStatus: String
            let selectionMode: String?
        }
    }

    private struct MutationManifest: Decodable {
        let schemaVersion: Int
        let androidCommit: String
        let cases: [Case]

        struct Case: Decodable {
            let id: String
            let parserId: String
            let input: String
            let inputSHA256: String
            let expected: String
            let expectedSHA256: String
        }
    }
}

private enum JSONPointerDiff {
    static func first(expected: Data, actual: Data) -> String {
        guard let expectedObject = try? JSONSerialization.jsonObject(with: expected),
              let actualObject = try? JSONSerialization.jsonObject(with: actual)
        else { return "JSON 无法解码" }
        return compare(expectedObject, actualObject, path: "$") ?? "JSON 结构相等但字节不同"
    }

    private static func compare(_ expected: Any, _ actual: Any, path: String) -> String? {
        if let lhs = expected as? NSDictionary, let rhs = actual as? NSDictionary {
            let keys = Set(lhs.allKeys.compactMap { $0 as? String } + rhs.allKeys.compactMap { $0 as? String }).sorted()
            for key in keys {
                guard let expectedValue = lhs[key] else { return "\(path).\(key) 多余字段，iOS=\(String(describing: rhs[key]))" }
                guard let actualValue = rhs[key] else { return "\(path).\(key) 缺失字段，Android=\(expectedValue)" }
                if let difference = compare(expectedValue, actualValue, path: "\(path).\(key)") { return difference }
            }
            return nil
        }
        if let lhs = expected as? NSArray, let rhs = actual as? NSArray {
            for index in 0 ..< min(lhs.count, rhs.count) {
                if let difference = compare(lhs[index], rhs[index], path: "\(path)[\(index)]") { return difference }
            }
            return lhs.count == rhs.count ? nil : "\(path) 数组长度不同，Android=\(lhs.count)，iOS=\(rhs.count)"
        }
        return (expected as AnyObject).isEqual(actual) ? nil : "\(path) 值不同，Android=\(expected)，iOS=\(actual)"
    }
}
