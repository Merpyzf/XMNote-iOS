/**
 * [INPUT]: 依赖 AppDatabase.empty、DesktopWebExportService、隔离设置和可控 URLProtocol
 * [OUTPUT]: 验证导出 API 的空范围、平台枚举、本地文件、Notion 单批索引/确认重建及不含印象笔记的远端目标合同
 * [POS]: iOS App Web 导出编排单元测试；锁定 Android NoteExportWebService 的关键可观察语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import GRDB
import Testing
import XMNoteWeb
@testable import xmnote

@MainActor
struct DesktopWebExportServiceTests {
    @Test
    func emptyRemoteScopeReturnsZeroBeforeCredentialValidation() async throws {
        let fixture = try makeExportFixture()
        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [],
            target: "yuque",
            content: .init(note: true, relevant: true, review: true)
        ))
        #expect(result == .init(total: 0, successCount: 0, failCount: 0, failedItems: []))
    }

    @Test
    func siYuanListUsesAndroidSortFallbackAndBlankNameFallback() async throws {
        let fixture = try makeExportFixture()
        try await updateExportSettings(fixture.settings, [
            "siyuanIp": "127.0.0.1",
            "siyuanPort": "6806",
            "siyuanToken": "token"
        ])
        ExportURLProtocolFixture.install(forHost: "127.0.0.1") { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:6806/api/notebook/lsNotebooks")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token token")
            return response(
                request,
                status: 200,
                json: """
                {
                  "code": 0,
                  "data": {
                    "notebooks": [
                      {"id":"2000-two","name":" B ","sort":0},
                      {"id":"1000-one","name":"   ","sort":0},
                      {"id":"fixed","name":"A","sort":5}
                    ]
                  }
                }
                """
            )
        }

        let values = try await fixture.service.siYuanNotebooks()
        #expect(values.map(\.id) == ["fixed", "1000-one", "2000-two"])
        #expect(values.map(\.name) == ["A", "1000-one", "B"])
    }

    @Test
    func localMarkdownUsesEscapedAndroidNameAndTextShape() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        let result = try await fixture.service.exportNotesLocally(.init(
            bookIds: [101],
            target: "markdown",
            content: .init(note: true, relevant: false, review: false)
        ))

        #expect(result.mediaType == "text/markdown")
        #expect(result.fileName == "《A_B》.md")
        let text = try #require(String(data: result.data, encoding: .utf8))
        #expect(text.contains("<center><font size=4>《A:B》</font></center>"))
        #expect(text.contains("<center><font color='#6e6e6e' size=2>1 条书摘</font></center>"))
        #expect(text.contains("原文<br>第二行"))
        #expect(text.contains("> 想法"))
        #expect(text.contains("<font color='#6e6e6e' size=2> 位置：12 | 2023-11-15 06:13:20 </font>"))
    }

    @Test
    func yuqueCreatesMissingRepoWithFormBodyThenUploadsDocument() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        try await updateExportSettings(fixture.settings, ["yuqueToken": "token"])
        let recorder = ExportRequestRecorder()
        ExportURLProtocolFixture.install(forHost: "www.yuque.com") { request in
            let index = recorder.append(request)
            switch index {
            case 0:
                return response(request, status: 200, json: #"{"data":{"id":42}}"#)
            case 1:
                return response(request, status: 200, json: #"{"data":[]}"#)
            case 2:
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
                let body = requestBodyData(request) ?? Data()
                let text = String(decoding: body, as: UTF8.self)
                #expect(text.contains("name=%E7%BA%B8%E9%97%B4%E4%B9%A6%E6%91%98"))
                #expect(text.contains("description=%E4%BB%8E%E7%BA%B8%E9%97%B4%E4%B9%A6%E6%91%98%E5%AF%BC%E5%87%BA%E7%9A%84%E8%AF%BB%E4%B9%A6%E7%AC%94%E8%AE%B0"))
                return response(request, status: 200, json: #"{"data":{"id":99}}"#)
            case 3:
                #expect(request.url?.path == "/api/v2/repos/99/docs")
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
                let text = String(decoding: requestBodyData(request) ?? Data(), as: UTF8.self)
                #expect(text.contains("format=markdown"))
                #expect(text.contains("title=A%3AB_%E4%B9%A6%E6%91%98_"))
                let decoded = text.removingPercentEncoding ?? text
                #expect(decoded.contains(#"<img src=""#))
                #expect(decoded.contains(#"<img>"#))
                #expect(decoded.contains("原文<br>第二行"))
                return response(request, status: 200, json: #"{"data":{"id":1}}"#)
            default:
                Issue.record("出现未预期的语雀请求: \(request.url?.absoluteString ?? "")")
                return response(request, status: 500, json: "{}")
            }
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "yuque",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.total == 1)
        #expect(result.successCount == 1)
        #expect(result.failCount == 0)
        #expect(recorder.count == 4)
    }

    @Test
    func notionUsesCurrentDataSourceAPIAndPlainQuoteWithoutLegacyDecoration() async throws {
        let fixture = try makeExportFixture(seedBook: true, noteCount: 60)
        try await updateExportSettings(fixture.settings, [
            "notionDataSourceId": "data-source-1"
        ])
        try await fixture.credentials.set("token", for: .notionAccessToken)
        let recorder = ExportRequestRecorder()
        ExportURLProtocolFixture.install(forHost: "api.notion.com") { request in
            _ = recorder.append(request)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/pages")
            let body = try #require(requestJSONObject(request))
            #expect((body["parent"] as? [String: Any])?["data_source_id"] as? String == "data-source-1")
            #expect((body["icon"] as? [String: Any])?["emoji"] as? String == "📖")
            let children = try #require(body["children"] as? [[String: Any]])
            #expect(children.count <= 100)
            let types = children.compactMap { $0["type"] as? String }
            #expect(types.contains("quote"))
            #expect(!types.contains("callout"))
            let encoded = String(decoding: requestBodyData(request) ?? Data(), as: UTF8.self)
            #expect(!encoded.contains("💡"))
            return response(request, status: 200, json: #"{"id":"page"}"#)
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "notion",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.successCount == 1)
        #expect(result.failCount == 0)
        #expect(recorder.count > 0)
    }

    @Test
    func notionRefreshesOnceAfterExplicitUnauthorizedResponse() async throws {
        let refreshRecorder = NotionRefreshRecorder()
        let fixture = try makeExportFixture(
            seedBook: true,
            notionTokenRefresher: { rejectedToken in
                #expect(rejectedToken == "expired-token")
                refreshRecorder.record()
                return "refreshed-token"
            }
        )
        try await updateExportSettings(fixture.settings, [
            "notionDataSourceId": "data-source-1"
        ])
        try await fixture.credentials.set("expired-token", for: .notionAccessToken)
        let recorder = ExportRequestRecorder()
        ExportURLProtocolFixture.install(forHost: "api.notion.com") { request in
            let index = recorder.append(request)
            if index == 0 {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-token")
                return response(request, status: 401, json: #"{"message":"unauthorized"}"#)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-token")
            return response(request, status: 200, json: #"{"id":"page"}"#)
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "notion",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.successCount == 1)
        #expect(recorder.count == 2)
        #expect(refreshRecorder.count == 1)
    }

    @Test
    func notionRetriesRateLimitResponseAndHonorsZeroRetryAfter() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        try await updateExportSettings(fixture.settings, [
            "notionDataSourceId": "data-source-1"
        ])
        try await fixture.credentials.set("token", for: .notionAccessToken)
        let recorder = ExportRequestRecorder()
        ExportURLProtocolFixture.install(forHost: "api.notion.com") { request in
            let index = recorder.append(request)
            if index == 0 {
                return response(
                    request,
                    status: 429,
                    json: #"{"message":"rate limited"}"#,
                    headers: ["Retry-After": "0"]
                )
            }
            return response(request, status: 200, json: #"{"id":"page"}"#)
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "notion",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.successCount == 1)
        #expect(recorder.count == 2)
    }

    @Test
    func unifiedNotionIndexesOnceAndOnlyRebuildsDeletedPageAfterConfirmation() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        let repository = ExportRepository(
            database: fixture.database,
            defaults: fixture.defaults,
            credentialStore: fixture.credentials,
            session: fixture.session
        )
        var settings = ExportSettingsSnapshot.androidDefault
        settings.notionDataSourceID = "data-source-1"
        try await repository.saveSettings(settings)
        try await repository.saveCredential("token", for: .notionAccessToken)
        fixture.defaults.set(
            "workspace:bot",
            forKey: NotionOAuthBrokerService.connectionKeyDefaultsKey
        )
        fixture.defaults.set(
            "instance",
            forKey: NotionOAuthBrokerService.dataInstanceIDDefaultsKey
        )

        let recorder = ExportRequestRecorder()
        ExportURLProtocolFixture.install(forHost: "api.notion.com") { request in
            let requestIndex = recorder.append(request)
            switch (request.url?.path, request.httpMethod) {
            case ("/v1/data_sources/data-source-1/query", "POST"):
                let body = try #require(requestJSONObject(request))
                #expect(body["page_size"] as? Int == 100)
                return response(request, status: 200, json: """
                    {
                      "results": [{
                        "id": "deleted-page",
                        "url": "https://notion.so/deleted-page",
                        "in_trash": true,
                        "last_edited_time": "2026-08-30T00:00:00.000Z",
                        "properties": {
                          "XMNote 同步 ID": {"rich_text": [{"plain_text": "instance:101"}]},
                          "XMNote 元数据指纹": {"rich_text": []},
                          "XMNote 内容指纹": {"rich_text": []},
                          "书名": {"title": [{"plain_text": "A:B"}]},
                          "同步状态": {"select": {"name": "已同步"}}
                        }
                      }],
                      "has_more": false,
                      "next_cursor": null
                    }
                    """)
            case ("/v1/pages", "POST"):
                return response(
                    request,
                    status: 200,
                    json: #"{"id":"rebuilt-page","url":"https://notion.so/rebuilt-page","last_edited_time":"2026-08-30T00:00:01.000Z"}"#
                )
            case ("/v1/blocks/rebuilt-page/children", "PATCH"):
                let body = try #require(requestJSONObject(request))
                let children = try #require(body["children"] as? [[String: Any]])
                let results = children.indices.map { ["id": "block-\(requestIndex)-\($0)"] }
                let data = try JSONSerialization.data(withJSONObject: ["results": results])
                return response(
                    request,
                    status: 200,
                    json: String(decoding: data, as: UTF8.self)
                )
            case ("/v1/pages/rebuilt-page", "PATCH"):
                return response(
                    request,
                    status: 200,
                    json: #"{"id":"rebuilt-page","url":"https://notion.so/rebuilt-page","last_edited_time":"2026-08-30T00:00:02.000Z"}"#
                )
            default:
                Issue.record("出现未预期的 Notion 请求: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return response(request, status: 500, json: "{}")
            }
        }

        let first = await repository.export(
            ExportRequest(
                kind: .noteExcerpt,
                scope: .bookIDs([101]),
                target: .notion,
                settings: settings,
                isPremium: true,
                nowMilliseconds: 1_700_000_000_000,
                localeIdentifier: "zh-CN",
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            progress: { _ in }
        )
        #expect(first.successCount == 0)
        #expect(first.notionPageRebuildBookIDs == [101])
        #expect(first.failures.first?.disposition == .nonRetryable)

        let rebuilt = await repository.export(
            ExportRequest(
                kind: .noteExcerpt,
                scope: .bookIDs([101]),
                target: .notion,
                settings: settings,
                isPremium: true,
                nowMilliseconds: 1_700_000_000_000,
                localeIdentifier: "zh-CN",
                timeZoneIdentifier: "Asia/Shanghai",
                confirmedNotionPageRebuildBookIDs: [101]
            ),
            progress: { _ in }
        )
        #expect(rebuilt.isCompleteSuccess)
        #expect(recorder.count == 8)
    }

    @Test
    func unifiedNotionRecoversMissingLocalPageAndBlockMappingWithoutCreatingDuplicate() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        let repository = ExportRepository(
            database: fixture.database,
            defaults: fixture.defaults,
            credentialStore: fixture.credentials,
            session: fixture.session
        )
        var settings = ExportSettingsSnapshot.androidDefault
        settings.notionDataSourceID = "data-source-1"
        try await repository.saveSettings(settings)
        try await repository.saveCredential("token", for: .notionAccessToken)
        fixture.defaults.set(
            "workspace:bot",
            forKey: NotionOAuthBrokerService.connectionKeyDefaultsKey
        )
        fixture.defaults.set(
            "instance",
            forKey: NotionOAuthBrokerService.dataInstanceIDDefaultsKey
        )

        let snapshot = try await DesktopWebExportRepository(
            database: fixture.database,
            defaults: fixture.defaults
        ).snapshot(scope: .bookIDs([101]), selection: .all)
        let book = try #require(snapshot.books.first)
        let draft = DesktopWebNotionExportGenerator.managedPageDraft(
            snapshot: book,
            selection: .init(note: true, relevant: true, review: true),
            settings: [:]
        )
        var generated = draft.body
        let children = generated.removeValue(forKey: "children") as? [[String: Any]] ?? []
        let fingerprintData = try JSONSerialization.data(
            withJSONObject: ["children": children],
            options: [.sortedKeys]
        )
        let fingerprint = SHA256.hash(data: fingerprintData)
            .map { String(format: "%02x", $0) }
            .joined()
        let recoveredBlockIDs = children.indices.map { "existing-block-\($0)" }
        let remoteBlocks = zip(children, recoveredBlockIDs).map { child, blockID in
            child.merging(["id": blockID]) { current, _ in current }
        }
        let remoteBlocksData = try JSONSerialization.data(withJSONObject: [
            "results": remoteBlocks,
            "has_more": false,
            "next_cursor": NSNull()
        ])
        let remoteBlocksJSON = try #require(String(data: remoteBlocksData, encoding: .utf8))

        let recorder = ExportRequestRecorder()
        ExportURLProtocolFixture.install(forHost: "api.notion.com") { request in
            _ = recorder.append(request)
            switch (request.url?.path, request.httpMethod) {
            case ("/v1/data_sources/data-source-1/query", "POST"):
                return response(request, status: 200, json: """
                    {
                      "results": [{
                        "id": "existing-page",
                        "url": "https://notion.so/existing-page",
                        "in_trash": false,
                        "last_edited_time": "2026-08-30T00:00:00.000Z",
                        "properties": {
                          "XMNote 同步 ID": {"rich_text": [{"plain_text": "instance:101"}]},
                          "XMNote 元数据指纹": {"rich_text": []},
                          "XMNote 内容指纹": {"rich_text": [{"plain_text": "\(fingerprint)"}]},
                          "书名": {"title": [{"plain_text": "A:B"}]},
                          "同步状态": {"select": {"name": "已同步"}}
                        }
                      }],
                      "has_more": false,
                      "next_cursor": null
                    }
                    """)
            case ("/v1/blocks/existing-page/children", "GET"):
                return response(
                    request,
                    status: 200,
                    json: remoteBlocksJSON
                )
            case ("/v1/pages/existing-page", "PATCH"):
                return response(
                    request,
                    status: 200,
                    json: #"{"id":"existing-page","url":"https://notion.so/existing-page","last_edited_time":"2026-08-30T00:00:01.000Z"}"#
                )
            default:
                Issue.record("出现未预期的 Notion 请求: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return response(request, status: 500, json: "{}")
            }
        }

        let result = await repository.export(
            ExportRequest(
                kind: .noteExcerpt,
                scope: .bookIDs([101]),
                target: .notion,
                settings: settings,
                isPremium: true,
                nowMilliseconds: 1_700_000_000_000,
                localeIdentifier: "zh-CN",
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            progress: { _ in }
        )
        #expect(result.isCompleteSuccess)
        #expect(recorder.count == 3)

        let syncRepository = NotionExportSyncRepository(database: fixture.database)
        let fetchedPage = try await syncRepository.findPage(
            connectionKey: "workspace:bot",
            dataSourceID: "data-source-1",
            bookID: 101
        )
        let recoveredPage = try #require(fetchedPage)
        #expect(recoveredPage.pageId == "existing-page")
        let pageSyncID = try #require(recoveredPage.id)
        let recoveredBlocks = try await syncRepository.blocks(pageSyncID: pageSyncID)
        #expect(recoveredBlocks.count == draft.units.count)
        #expect(Set(recoveredBlocks.map(\.unitKey)) == Set(draft.units.map(\.key)))
        let persistedBlockIDs = try recoveredBlocks.flatMap {
            try #require(
                JSONSerialization.jsonObject(with: Data($0.blockIdsJson.utf8)) as? [String]
            )
        }
        #expect(Set(persistedBlockIDs) == Set(recoveredBlockIDs))
    }

    @Test
    func unifiedNotionPreservesRemoteUserEditWhenSameNoteChangesLocally() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        let repository = ExportRepository(
            database: fixture.database,
            defaults: fixture.defaults,
            credentialStore: fixture.credentials,
            session: fixture.session
        )
        var settings = ExportSettingsSnapshot.androidDefault
        settings.notionDataSourceID = "data-source-1"
        try await repository.saveSettings(settings)
        try await repository.saveCredential("token", for: .notionAccessToken)
        fixture.defaults.set(
            "workspace:bot",
            forKey: NotionOAuthBrokerService.connectionKeyDefaultsKey
        )
        fixture.defaults.set(
            "instance",
            forKey: NotionOAuthBrokerService.dataInstanceIDDefaultsKey
        )

        let remote = ManagedNotionRemoteFixture()
        ExportURLProtocolFixture.install(forHost: "api.notion.com") { request in
            try remote.handle(request)
        }
        let originalRequest = ExportRequest(
            kind: .noteExcerpt,
            scope: .bookIDs([101]),
            target: .notion,
            settings: settings,
            isPremium: true,
            nowMilliseconds: 1_700_000_000_000,
            localeIdentifier: "zh-CN",
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let first = await repository.export(originalRequest, progress: { _ in })
        #expect(first.isCompleteSuccess)

        let syncRepository = NotionExportSyncRepository(database: fixture.database)
        let page = try #require(try await syncRepository.findPage(
            connectionKey: "workspace:bot",
            dataSourceID: "data-source-1",
            bookID: 101
        ))
        let pageSyncID = try #require(page.id)
        let originalNoteMapping = try #require(try await syncRepository.findBlock(
            pageSyncID: pageSyncID,
            unitKey: "note:201"
        ))
        let originalNoteBlockIDs = try #require(
            JSONSerialization.jsonObject(with: Data(originalNoteMapping.blockIdsJson.utf8)) as? [String]
        )
        let originalNoteBlockID = try #require(originalNoteBlockIDs.first)
        try remote.editBlock(id: originalNoteBlockID, text: "Notion 用户保留的版本")

        try await fixture.database.dbPool.write { db in
            guard var note = try NoteRecord.fetchOne(db, key: 201) else {
                throw DesktopWebAPIError(code: 500, message: "测试书摘不存在")
            }
            note.content = "纸间本地更新的版本"
            note.updatedDate += 60_000
            try note.update(db)
        }

        let second = await repository.export(
            ExportRequest(
                kind: originalRequest.kind,
                scope: originalRequest.scope,
                target: originalRequest.target,
                settings: originalRequest.settings,
                isPremium: originalRequest.isPremium,
                nowMilliseconds: originalRequest.nowMilliseconds + 60_000,
                localeIdentifier: originalRequest.localeIdentifier,
                timeZoneIdentifier: originalRequest.timeZoneIdentifier
            ),
            progress: { _ in }
        )
        #expect(second.isCompleteSuccess)
        #expect(!remote.deletedBlockIDs.contains(originalNoteBlockID))
        #expect(remote.containsBlock(id: originalNoteBlockID))
        #expect(remote.appendedPayloadContains("同步冲突 · 书摘"))
        #expect(remote.appendedPayloadContains("上方是 Notion 版本，下方是纸间版本"))
        #expect(!remote.appendedPayloadContains("💡"))

        let updatedPage = try #require(try await syncRepository.findPage(
            connectionKey: "workspace:bot",
            dataSourceID: "data-source-1",
            bookID: 101
        ))
        #expect(updatedPage.conflictCount == 1)
        #expect(updatedPage.status == "有冲突记录")
        let updatedMapping = try #require(try await syncRepository.findBlock(
            pageSyncID: pageSyncID,
            unitKey: "note:201"
        ))
        #expect(!updatedMapping.blockIdsJson.contains(originalNoteBlockID))
    }

    @Test
    func siYuanUsesDivBlocksAndRawLineBreaks() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        try await updateExportSettings(fixture.settings, [
            "siyuanIp": "127.0.0.3",
            "siyuanPort": "6806",
            "siyuanToken": "token",
            "siyuanNotebookId": "notebook"
        ])
        ExportURLProtocolFixture.install(forHost: "127.0.0.3") { request in
            #expect(request.url?.path == "/api/filetree/createDocWithMd")
            let body = try #require(requestJSONObject(request))
            #expect(body["notebook"] as? String == "notebook")
            let markdown = try #require(body["markdown"] as? String)
            #expect(markdown.contains("<div>\n<center><img"))
            #expect(markdown.contains("<div><center><font color='#6e6e6e' size=2>1 条书摘</font></center></div>"))
            #expect(markdown.contains("原文\n第二行"))
            #expect(!markdown.contains("原文<br>第二行"))
            return response(request, status: 200, json: #"{"code":0,"data":{"id":"doc"}}"#)
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "siyuan",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.successCount == 1)
        #expect(result.failCount == 0)
    }

    @Test
    func obsidianUsesRawMarkdownAndAppendsBookTags() async throws {
        let fixture = try makeExportFixture(seedBook: true)
        try await updateExportSettings(fixture.settings, [
            "obsidianIp": "127.0.0.4",
            "obsidianApiKey": "key",
            "obsidianDirName": "导出",
            "obsidianExportTags": true
        ])
        ExportURLProtocolFixture.install(forHost: "127.0.0.4") { request in
            if request.url?.path == "/" {
                return response(
                    request,
                    status: 200,
                    json: #"{"service":"Obsidian Local REST API","versions":{"self":"4.1.3"}}"#
                )
            }
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path.hasPrefix("/vault/") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
            let markdown = String(decoding: requestBodyData(request) ?? Data(), as: UTF8.self)
            #expect(markdown.contains("原文\n第二行"))
            #expect(!markdown.contains("原文<br>第二行"))
            #expect(markdown.hasSuffix("\n#Web 标签"))
            return response(request, status: 200, json: "{}")
        }

        let result = try await fixture.service.exportNotesRemotely(.init(
            bookIds: [101],
            target: "obsidian",
            content: .init(note: true, relevant: false, review: false)
        ))
        #expect(result.successCount == 1)
        #expect(result.failCount == 0)
    }
}

@MainActor
private struct ExportFixture {
    let service: DesktopWebExportService
    let settings: DesktopWebSettingsRepository
    let credentials: ExportCredentialStore
    let database: AppDatabase
    let defaults: UserDefaults
    let session: URLSession
}

@MainActor
private func makeExportFixture(
    seedBook: Bool = false,
    noteCount: Int = 1,
    notionTokenRefresher: @escaping @Sendable (String) async throws -> String = { _ in
        throw DesktopWebAPIError(code: 401, message: "refresh unavailable")
    }
) throws -> ExportFixture {
    let database = try AppDatabase.empty()
    if seedBook {
        try database.dbPool.write { db in
            var book = BookRecord()
            book.id = 101
            book.userId = 1
            book.name = "A:B"
            book.rawName = "A:B"
            book.author = "作者"
            book.sourceId = 1
            book.readStatusId = 1
            book.positionUnit = 1
            book.createdDate = 1_700_000_000_000
            book.updatedDate = 1_700_000_000_000
            try book.insert(db)

            for index in 0..<noteCount {
                var note = NoteRecord()
                note.id = Int64(201 + index)
                note.bookId = 101
                note.content = "原文<br>第二行"
                note.idea = "想法"
                note.position = "12"
                note.positionUnit = 1
                note.includeTime = 1
                note.createdDate = 1_700_000_000_000 + Int64(index)
                note.updatedDate = 1_700_000_000_000 + Int64(index)
                try note.insert(db)
            }

            var tag = TagRecord()
            tag.id = 301
            tag.userId = 1
            tag.name = "Web 标签"
            tag.type = 2
            tag.createdDate = 1_700_000_000_000
            tag.updatedDate = 1_700_000_000_000
            try tag.insert(db)

            var relation = TagBookRecord()
            relation.id = 401
            relation.bookId = 101
            relation.tagId = 301
            relation.createdDate = 1_700_000_000_000
            relation.updatedDate = 1_700_000_000_000
            try relation.insert(db)
        }
    }
    let defaults = UserDefaults(suiteName: "DesktopWebExportServiceTests.\(UUID().uuidString)")!
    let credentialStore = ExportCredentialStore(backend: .memory)
    let settings = DesktopWebSettingsRepository(
        defaults: defaults,
        credentialStore: credentialStore
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExportURLProtocolFixture.self]
    let session = URLSession(configuration: configuration)
    let service = DesktopWebExportService(
        repository: DesktopWebExportRepository(database: database, defaults: defaults),
        notionSyncRepository: NotionExportSyncRepository(database: database),
        settingsRepository: settings,
        session: session,
        notionTokenRefresher: notionTokenRefresher,
        obsidianSessionFactory: { _, _ in URLSession(configuration: configuration) },
        currentTimeMillis: { 1_700_000_000_000 }
    )
    return ExportFixture(
        service: service,
        settings: settings,
        credentials: credentialStore,
        database: database,
        defaults: defaults,
        session: session
    )
}

private func updateExportSettings(
    _ repository: DesktopWebSettingsRepository,
    _ object: [String: Any]
) async throws {
    try await repository.updateExportSettingsData(JSONSerialization.data(withJSONObject: object))
}

private final class ExportURLProtocolFixture: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func install(forHost host: String, _ value: @escaping Handler) {
        lock.withLock { handlers[host] = value }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try Self.lock.withLock {
                try #require(Self.handlers[request.url?.host ?? ""])
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ExportRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) -> Int {
        lock.withLock {
            requests.append(request)
            return requests.count - 1
        }
    }

    var count: Int { lock.withLock { requests.count } }
}

private final class NotionRefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.withLock { value += 1 }
    }

    var count: Int { lock.withLock { value } }
}

nonisolated private final class ManagedNotionRemoteFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var isCreated = false
    private var pageProperties: [String: Any] = [:]
    private var blocks: [[String: Any]] = []
    private var appendedPayloads: [[[String: Any]]] = []
    private var nextBlockIndex = 0
    private var lastEditedTime = "2026-08-30T00:00:00.000Z"
    private(set) var deletedBlockIDs: Set<String> = []

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        try lock.withLock {
            switch (request.url?.path, request.httpMethod) {
            case ("/v1/data_sources/data-source-1/query", "POST"):
                let results: [[String: Any]] = isCreated ? [[
                    "id": "managed-page",
                    "url": "https://notion.so/managed-page",
                    "in_trash": false,
                    "last_edited_time": lastEditedTime,
                    "properties": pageProperties
                ]] : []
                return try jsonResponse(request, object: [
                    "results": results,
                    "has_more": false,
                    "next_cursor": NSNull()
                ])
            case ("/v1/pages", "POST"):
                let body = try requireRequestObject(request)
                pageProperties = body["properties"] as? [String: Any] ?? [:]
                isCreated = true
                lastEditedTime = "2026-08-30T00:00:01.000Z"
                return try jsonResponse(request, object: pageResult())
            case ("/v1/blocks/managed-page/children", "GET"):
                return try jsonResponse(request, object: [
                    "results": blocks,
                    "has_more": false,
                    "next_cursor": NSNull()
                ])
            case ("/v1/blocks/managed-page/children", "PATCH"):
                let body = try requireRequestObject(request)
                let children = body["children"] as? [[String: Any]] ?? []
                appendedPayloads.append(children)
                let stored = children.map { child -> [String: Any] in
                    defer { nextBlockIndex += 1 }
                    return child.merging(["id": "managed-block-\(nextBlockIndex)"]) { current, _ in current }
                }
                blocks.append(contentsOf: stored)
                return try jsonResponse(request, object: ["results": stored.map { ["id": $0["id"]!] }])
            case ("/v1/pages/managed-page", "PATCH"):
                let body = try requireRequestObject(request)
                if let properties = body["properties"] as? [String: Any] {
                    pageProperties.merge(properties) { _, new in new }
                }
                lastEditedTime = "2026-08-30T00:00:03.000Z"
                return try jsonResponse(request, object: pageResult())
            default:
                if request.httpMethod == "PATCH",
                   let path = request.url?.path,
                   path.hasPrefix("/v1/blocks/"),
                   let body = requestJSONObject(request),
                   body["archived"] as? Bool == true {
                    let blockID = String(path.dropFirst("/v1/blocks/".count))
                    deletedBlockIDs.insert(blockID)
                    blocks.removeAll { ($0["id"] as? String) == blockID }
                    return try jsonResponse(request, object: ["id": blockID, "archived": true])
                }
                Issue.record("出现未预期的 Notion 请求: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return response(request, status: 500, json: "{}")
            }
        }
    }

    func editBlock(id: String, text: String) throws {
        try lock.withLock {
            guard let index = blocks.firstIndex(where: { ($0["id"] as? String) == id }) else {
                throw DesktopWebAPIError(code: 500, message: "测试远端 Block 不存在")
            }
            var block = blocks[index]
            let type = block["type"] as? String ?? "paragraph"
            var content = block[type] as? [String: Any] ?? [:]
            content["rich_text"] = [["type": "text", "text": ["content": text]]]
            block[type] = content
            blocks[index] = block
            lastEditedTime = "2026-08-30T00:00:02.000Z"
        }
    }

    func containsBlock(id: String) -> Bool {
        lock.withLock { blocks.contains { ($0["id"] as? String) == id } }
    }

    func appendedPayloadContains(_ text: String) -> Bool {
        lock.withLock {
            appendedPayloads.contains { payload in
                guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
                return String(decoding: data, as: UTF8.self).contains(text)
            }
        }
    }

    private func pageResult() -> [String: Any] {
        [
            "id": "managed-page",
            "url": "https://notion.so/managed-page",
            "last_edited_time": lastEditedTime,
            "properties": pageProperties
        ]
    }

    private func requireRequestObject(_ request: URLRequest) throws -> [String: Any] {
        guard let object = requestJSONObject(request) else {
            throw DesktopWebAPIError(code: 500, message: "测试请求缺少 JSON Body")
        }
        return object
    }

    private func jsonResponse(
        _ request: URLRequest,
        object: Any
    ) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: object)
        return response(request, status: 200, json: String(decoding: data, as: UTF8.self))
    }
}

private func response(
    _ request: URLRequest,
    status: Int,
    json: String,
    headers: [String: String] = [:]
) -> (HTTPURLResponse, Data) {
    var responseHeaders = ["Content-Type": "application/json"]
    responseHeaders.merge(headers) { _, supplied in supplied }
    return (
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://fixture.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: responseHeaders
        )!,
        Data(json.utf8)
    )
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 4_096)
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private func requestJSONObject(_ request: URLRequest) -> [String: Any]? {
    guard let data = requestBodyData(request) else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
