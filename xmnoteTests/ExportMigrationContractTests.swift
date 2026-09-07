/**
 * [INPUT]: 依赖导出领域模型、Android Oracle 字节、PDFKit、Notion 生成器、内存凭据后端与隔离 UserDefaults
 * [OUTPUT]: 验证稳定目标、会员矩阵、Markdown/TXT/CSV 字节对齐、PDF 结构、新版 Quote 及凭据迁移合同
 * [POS]: iOS 统一导出迁移的固定输入验收测试，不访问真实网络、Keychain、数据库或用户设置
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import PDFKit
import Testing
import XMNoteWeb
@testable import xmnote

@Suite(.serialized)
struct ExportMigrationContractTests {
    @Test
    func androidOracleManifestPinsCommitSourcesAndFixtureBytes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ExportParity/v1", directoryHint: .isDirectory)
        let manifestData = try Data(contentsOf: root.appending(path: "export-oracle-manifest.json"))
        let manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        #expect(
            manifest["androidCommit"] as? String
                == "f916f93528610a79ed4528f9decd772af383f6b7"
        )
        #expect(manifest["locale"] as? String == "zh-CN")
        #expect(manifest["timeZone"] as? String == "Asia/Shanghai")
        let expectedHashes = try #require(manifest["fixtureSHA256"] as? [String: String])
        for (name, expected) in expectedHashes {
            let data = try Data(contentsOf: root.appending(path: name))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected)
        }
        let sources = try #require(manifest["androidSourceSHA256"] as? [String: String])
        #expect(sources.count == 7)
        #expect(sources.values.allSatisfy { $0.count == 64 })
    }

    @Test
    func targetListsUseStableStringsAndContainNoRemovedProvider() {
        #expect(ExportTarget.supportedTargets(for: .noteExcerpt).map(\.rawValue) == [
            "yuque",
            "notion",
            "one_note",
            "si_yuan",
            "obsidian",
            "pdf",
            "markdown",
            "text"
        ])
        #expect(ExportTarget.supportedTargets(for: .bookInformation).map(\.rawValue) == [
            "csv",
            "notion"
        ])
        let serializedTargets = ExportTarget.allCases.map(\.rawValue).joined(separator: "|").lowercased()
        #expect(!serializedTargets.contains("evernote"))
        #expect(!serializedTargets.contains("印象笔记"))
    }

    @Test
    func onlyMarkdownAndTextAreFree() {
        let freeTargets = ExportTarget.allCases.filter { !$0.requiresPremium }
        #expect(freeTargets == [.markdown, .text])
        #expect(ExportTarget.csv.requiresPremium)
        #expect(ExportTarget.notion.requiresPremium)
    }

    @Test
    func wholeRequestRetryRequiresEveryFailureToBeExplicitlyRetryable() {
        let retryableFailure = ExportFailure(
            bookID: 1,
            bookName: "测试书籍",
            target: .notion,
            message: "限流后仍未成功",
            disposition: .retryable
        )
        let retryableResult = ExportResult(
            requestedBookCount: 1,
            successCount: 0,
            failures: [retryableFailure],
            artifactTicket: nil
        )
        #expect(retryableResult.canSafelyRetry)
        #expect(!retryableResult.hasUncertainRemoteResult)

        let uncertainFailure = ExportFailure(
            bookID: 1,
            bookName: "测试书籍",
            target: .obsidian,
            message: "请求超时，远端结果未知",
            disposition: .resultUncertain
        )
        let uncertainResult = ExportResult(
            requestedBookCount: 1,
            successCount: 0,
            failures: [retryableFailure, uncertainFailure],
            artifactTicket: nil
        )
        #expect(!uncertainResult.canSafelyRetry)
        #expect(uncertainResult.hasUncertainRemoteResult)
    }

    @Test
    func filenameAllocatorMatchesAndroidUTF16AndCollisionRules() throws {
        #expect(ExportFileNameAllocator.sanitizedStem(":\\/*\"?|<>'") == "__________")
        #expect(ExportFileNameAllocator.sanitizedStem("   ") == "读书笔记")

        let source = String(repeating: "汉", count: 64) + "😀尾"
        let stem = ExportFileNameAllocator.sanitizedStem(source)
        #expect(stem.utf16.count <= 65)
        #expect(!stem.hasSuffix("尾"))

        var allocator = ExportFileNameAllocator()
        #expect(try allocator.allocate(title: "同名书籍", extension: "md") == "同名书籍.md")
        #expect(try allocator.allocate(title: "同名书籍", extension: ".md") == "同名书籍_1.md")
        #expect(try allocator.allocate(title: "同名书籍", extension: "md") == "同名书籍_2.md")
    }

    @Test
    func notionIdeaUsesPlainQuoteWithoutLegacyEmojiOrCallout() throws {
        let block = DesktopWebNotionExportGenerator.quote("普通想法")
        #expect(block["type"] as? String == "quote")
        #expect(block["callout"] == nil)
        let data = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("💡"))
        #expect(!text.contains("blue_background"))
    }

    @Test
    func memoryCredentialStoreTrimsVerifiesAndRemovesValues() async throws {
        let store = ExportCredentialStore(backend: .memory)
        try await store.set("  secret-value  ", for: .yuqueToken)
        #expect(try await store.value(for: .yuqueToken) == "secret-value")
        #expect(await store.contains(.yuqueToken))
        try await store.set("   ", for: .yuqueToken)
        #expect(try await store.value(for: .yuqueToken) == nil)
        #expect(await store.contains(.yuqueToken) == false)
    }

    @Test
    func legacyPlaintextMovesOnlySupportedCredentialsAfterVerifiedWrite() async throws {
        let suite = "ExportMigrationContractTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = [
            "yuqueToken": "yuque-secret",
            "siyuanToken": "siyuan-secret",
            "obsidianApiKey": "obsidian-secret",
            "notionToken": "legacy-notion-secret",
            "notionPageId": "legacy-page"
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: "desktopWeb.api.exportSettings"
        )
        defaults.set("legacy-database", forKey: "desktopWeb.api.notionDatabaseID")
        let credentials = ExportCredentialStore(backend: .memory)
        let store = ExportSettingsStore(defaults: defaults, credentialStore: credentials)

        _ = await store.settings()

        #expect(try await credentials.value(for: .yuqueToken) == "yuque-secret")
        #expect(try await credentials.value(for: .siYuanToken) == "siyuan-secret")
        #expect(try await credentials.value(for: .obsidianAPIKey) == "obsidian-secret")
        #expect(try await credentials.value(for: .notionAccessToken) == nil)
        let sanitizedData = try #require(defaults.data(forKey: "desktopWeb.api.exportSettings"))
        let sanitized = try #require(
            JSONSerialization.jsonObject(with: sanitizedData) as? [String: Any]
        )
        #expect(sanitized["yuqueToken"] as? String == "")
        #expect(sanitized["siyuanToken"] as? String == "")
        #expect(sanitized["obsidianApiKey"] as? String == "")
        #expect(sanitized["notionToken"] as? String == "")
        #expect(sanitized["notionPageId"] as? String == "")
        #expect(defaults.string(forKey: "desktopWeb.api.notionDatabaseID") == nil)
        #expect(defaults.bool(forKey: "export.credentials.migration.v2.completed"))
    }

    @Test
    func csvRegistryKeeps29SettingsButExcludesFiveDerivedOutputs() {
        #expect(ExportBookField.allCases.count == 29)
        let excluded = Set(ExportBookField.allCases.filter { !$0.isCSVOutputField })
        #expect(excluded == Set([
            .readScoreDisplay,
            .noteCount,
            .reviewCount,
            .relevantCount,
            .updatedDate
        ]))
        #expect(ExportBookField.allCases.filter(\.isCSVOutputField).count == 24)
    }

    @Test
    func markdownAndTextMatchPinnedAndroidOracleBytes() throws {
        let sections = DesktopWebExportService.localContentSections(
            bundle: Self.noteOracleBundle,
            selection: .init(note: true, relevant: false, review: false),
            settings: Self.noteOracleSettings
        )
        let section = try #require(sections.only)
        let markdownOracle = try Self.oracleData("expected-note.md")
        let textOracle = try Self.oracleData("expected-note.txt")
        #expect(section.0 == "《A:B》")
        #expect(Data(section.1.utf8) == markdownOracle)
        #expect(Data(section.2.utf8) == textOracle)
    }

    @Test
    func csvMatchesPinnedAndroidOracleBytesInAllEnabledFieldOrder() throws {
        let snapshot = ExportSnapshot(books: [
            ExportBookSnapshot(
                book: Self.csvOracleBook,
                chapters: [],
                notes: [],
                reviews: [],
                relatedNotes: []
            )
        ])
        let data = ExportCSVGenerator.generate(
            snapshot: snapshot,
            fields: ExportBookField.allCases.map {
                ExportBookFieldSelection(field: $0, isEnabled: true)
            },
            localeIdentifier: "zh-CN",
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let oracle = try Self.oracleData("expected-books.csv")
        #expect(data == oracle)
    }

    @Test
    func pdfUsesAndroidPageGeometryAndProvidesTOCOutlineAndInternalLink() async throws {
        let data = try await ExportPDFGenerator().generate(
            book: Self.pdfOracleBook,
            settings: .androidDefault,
            localeIdentifier: "zh-CN",
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount >= 3)
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let box = page.bounds(for: .mediaBox)
            #expect(abs(box.width - 595) < 0.01)
            #expect(abs(box.height - 842) < 0.01)
        }
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
            .precomposedStringWithCompatibilityMapping
        #expect(text.contains("A:B"))
        #expect(text.contains("目录"))
        #expect(text.contains("第一章"))
        #expect(text.contains("原文"))
        let outline = try #require(document.outlineRoot)
        #expect(outline.numberOfChildren > 0)
        let tocPage = try #require(document.page(at: 1))
        #expect(tocPage.annotations.contains { $0.action != nil })
    }
}

private extension ExportMigrationContractTests {
    static let oracleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/ExportParity/v1", directoryHint: .isDirectory)

    static func oracleData(_ name: String) throws -> Data {
        try Data(contentsOf: oracleRoot.appending(path: name))
    }

    static let noteOracleSettings: [String: Any] = [
        "includeBookInfo": true,
        "includeDateTime": true,
        "includePage": true,
        "includeTag": true,
        "_localeIdentifier": "zh-CN",
        "_timeZoneIdentifier": "Asia/Shanghai"
    ]

    static let noteOracleBundle = DesktopWebExportBundle(
        book: noteOracleBook,
        notes: [noteOracleNote],
        reviews: [],
        related: []
    )

    static let noteOracleBook = DesktopWebBookSnapshot(
        id: 101,
        name: "A:B",
        rawName: "A:B",
        cover: "",
        author: "作者",
        authorIntro: "",
        translator: "",
        summary: "",
        isbn: "",
        press: "",
        pubDate: "",
        doubanId: nil,
        readStatus: 1,
        readStatusChangedTime: 0,
        recentReadTime: nil,
        readDoneCount: 0,
        score: 0,
        readPosition: 0,
        totalPosition: 0,
        totalPagination: 0,
        currentPositionUnit: 0,
        positionUnit: 1,
        type: 0,
        sourceId: 1,
        sourceName: "豆瓣",
        purchaseDate: nil,
        price: nil,
        isPinned: false,
        pinOrder: 0,
        order: 0,
        wordCount: nil,
        totalReadingTime: 0,
        createdTime: 1_700_000_000_000,
        updatedTime: 1_700_000_000_000,
        lastModifiedTime: nil,
        noteCount: 1,
        reviewCount: 0,
        relevantCount: 0,
        readDoneTime: nil,
        bookmarkModifiedTime: nil,
        groups: [],
        tags: [.init(id: 301, name: "Web 标签")],
        isDeleted: false
    )

    static let noteOracleNote = DesktopWebBookNoteSnapshot(
        id: 201,
        content: "原文<br>第二行",
        idea: "想法",
        position: "12",
        positionUnit: 1,
        isIncludeTime: true,
        createdTime: 1_700_000_000_000,
        updatedTime: 1_700_000_000_000,
        chapter: nil,
        tags: [.init(id: 301, name: "Web 标签")],
        images: []
    )

    static let csvOracleBook = DesktopWebBookSnapshot(
        id: 102,
        name: "A:B, \"Oracle\"",
        rawName: "A:B, \"Oracle\"",
        cover: "https://example.com/cover.jpg",
        author: "作者",
        authorIntro: "",
        translator: "译者",
        summary: "",
        isbn: "ISBN,\"1\"",
        press: "出版社",
        pubDate: "2023-11",
        doubanId: 123,
        readStatus: 2,
        readStatusChangedTime: 1_700_000_000_000,
        recentReadTime: 1_700_000_001_000,
        readDoneCount: 2,
        score: 85,
        readPosition: 12.34,
        totalPosition: 1_000,
        totalPagination: 321,
        currentPositionUnit: 0,
        positionUnit: 0,
        type: 1,
        sourceId: 1,
        sourceName: "豆瓣",
        purchaseDate: 1_700_000_000_000,
        price: 12.345,
        isPinned: false,
        pinOrder: 0,
        order: 0,
        wordCount: 12_345,
        totalReadingTime: 150,
        createdTime: 1_700_000_000_000,
        updatedTime: 1_700_000_000_000,
        lastModifiedTime: nil,
        noteCount: 1,
        reviewCount: 0,
        relevantCount: 0,
        readDoneTime: nil,
        bookmarkModifiedTime: nil,
        groups: [.init(id: 1, name: "默认"), .init(id: 2, name: "收藏")],
        tags: [.init(id: 1, name: "标签 一"), .init(id: 2, name: "标签二")],
        isDeleted: false
    )

    static let pdfOracleBook: ExportBookSnapshot = {
        let chapter = DesktopWebChapterSnapshot(
            id: 501,
            title: "第一章",
            parentTitle: nil,
            parentID: 0,
            level: 0,
            pathTitles: ["第一章"],
            isStarred: false
        )
        let note = DesktopWebBookNoteSnapshot(
            id: 201,
            content: "原文<br>第二行",
            idea: "想法",
            position: "12",
            positionUnit: 1,
            isIncludeTime: true,
            createdTime: 1_700_000_000_000,
            updatedTime: 1_700_000_000_000,
            chapter: chapter,
            tags: [],
            images: []
        )
        return ExportBookSnapshot(
            book: noteOracleBook,
            chapters: [chapter],
            notes: [note],
            reviews: [],
            relatedNotes: []
        )
    }()
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
