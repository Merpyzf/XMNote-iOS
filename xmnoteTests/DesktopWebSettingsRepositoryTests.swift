import Foundation
import Testing
import XMNoteWeb
@testable import xmnote

@MainActor
struct DesktopWebSettingsRepositoryTests {
    @Test
    func defaultsMatchFrozenAndroidSettingsContract() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }

        let web = try await jsonObject(from: harness.repository.webSettingsData())
        let display = try object(web, "display")
        #expect(display["noteMaxLines"] as? Int == 6)
        #expect(display["noteTextScale"] as? String == "balanced")
        #expect(display["noteImageWallColumns"] as? String == "auto")

        let book = try object(web, "book")
        let entry = try object(book, "entryPreference")
        #expect(Set(entry.keys) == ["sourceName"])
        #expect(entry["sourceName"] as? String == "")

        let bookshelf = try object(web, "bookshelf")
        let statuses = try object(bookshelf, "statusByKey")
        #expect(Set(statuses.keys) == ["wantRead", "startReading", "readDone", "abandon", "onHold"])
        let wantRead = try object(statuses, "wantRead")
        #expect(wantRead["sortBy"] as? String == "create_time")

        let export = try await jsonObject(from: harness.repository.exportSettingsData())
        #expect(export["lastTarget"] as? String == "markdown")
        #expect(export["siyuanPort"] as? String == "6806")
        #expect(export["obsidianExportTags"] as? Bool == true)
    }

    @Test
    func webPatchUsesAndroidReplacementMergeAndNormalizationRules() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }

        try await harness.repository.updateWebSettingsData(
            jsonData(
                #"""
                {
                    "display": {
                        "noteMaxLines": 11,
                        "noteTextScale": "UNKNOWN",
                        "noteImageWallMode": "square",
                        "noteImageWallColumns": 99,
                        "noteImageWallMaxWidth": "wide"
                    },
                    "bookshelf": {
                        "bookshelf": {
                            "sortBy": "  ",
                            "sortOrder": "asc",
                            "enableSection": true,
                            "gridColumns": 2,
                            "filterStatus": 9,
                            "filterTags": [
                                {"id": 3, "name": "  技术  "},
                                {"id": 0, "name": "忽略"},
                                {"id": 4, "name": " "}
                            ],
                            "tagMode": "and",
                            "filterSources": [],
                            "filterGroupOnly": true
                        }
                    },
                    "notes": {
                        "globalToolbar": {
                            "appliedNoteState": {
                                "selectedTagIds": [3, -1, 3],
                                "selectedBooks": [
                                    {"id": 8, "name": "  Swift  ", "cover": "c"},
                                    {"id": 0, "name": "忽略"}
                                ]
                            }
                        },
                        "bookToolbarByBookId": {
                            "42": {
                                "selectedTagIds": [3, -1, 3, 4],
                                "tagMode": "unexpected",
                                "relatedSortOption": "unexpected"
                            }
                        }
                    }
                }
                """#
            )
        )

        let web = try await jsonObject(from: harness.repository.webSettingsData())
        let display = try object(web, "display")
        #expect(display["noteMaxLines"] as? Int == 11)
        #expect(display["noteTextScale"] as? String == "balanced")
        #expect(display["noteImageWallMode"] as? String == "square")
        #expect(display["noteImageWallColumns"] as? Int == 8)
        #expect(display["noteImageWallMaxWidth"] as? String == "comfortable")

        let bookshelf = try object(try object(web, "bookshelf"), "bookshelf")
        #expect(bookshelf["sortBy"] as? String == "custom")
        #expect(bookshelf["sortOrder"] as? String == "asc")
        #expect(bookshelf["enableSection"] as? Bool == true)
        #expect(bookshelf["gridColumns"] as? Int == 6)
        #expect(bookshelf["filterStatus"] == nil)
        #expect(bookshelf["tagMode"] as? String == "and")
        let filterTags = try #require(bookshelf["filterTags"] as? [[String: Any]])
        #expect(filterTags.count == 1)
        #expect(filterTags.first?["id"] as? Int == 3)
        #expect(filterTags.first?["name"] as? String == "技术")

        let notes = try object(web, "notes")
        let global = try object(try object(notes, "globalToolbar"), "appliedNoteState")
        #expect(global["selectedTagIds"] as? [Int] == [3, -1, 3])
        let selectedBooks = try #require(global["selectedBooks"] as? [[String: Any]])
        #expect(selectedBooks.count == 1)
        #expect(selectedBooks.first?["id"] as? Int == 8)
        #expect(selectedBooks.first?["name"] as? String == "Swift")

        let toolbar = try object(try object(notes, "bookToolbarByBookId"), "42")
        #expect(toolbar["selectedTagIds"] as? [Int] == [3, 4])
        #expect(toolbar["tagMode"] as? String == "or")
        #expect(toolbar["relatedSortOption"] == nil)
    }

    @Test
    func bookEntryPreferenceSharesAppKeysAndSupportsExplicitReset() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }

        try await harness.repository.updateWebSettingsData(
            jsonData(
                #"{"book":{"entryPreference":{"type":1,"sourceId":77,"sourceName":"微信读书","positionUnit":3,"readStatus":4}}}"#
            )
        )

        #expect(harness.defaults.integer(forKey: "book_entry_prefer_type") == 1)
        #expect(harness.defaults.string(forKey: "book_entry_prefer_source_name") == "微信读书")
        #expect(harness.defaults.integer(forKey: "book_entry_prefer_unit") == 3)
        #expect(harness.defaults.integer(forKey: "book_entry_prefer_status") == 4)

        var web = try await jsonObject(from: harness.repository.webSettingsData())
        var entry = try object(try object(web, "book"), "entryPreference")
        #expect(entry["sourceId"] as? Int == 77)

        try await harness.repository.updateWebSettingsData(
            jsonData(#"{"book":{"entryPreference":{"sourceName":"  "}}}"#)
        )

        web = try await jsonObject(from: harness.repository.webSettingsData())
        entry = try object(try object(web, "book"), "entryPreference")
        #expect(Set(entry.keys) == ["sourceName"])
        #expect(harness.defaults.object(forKey: "book_entry_prefer_type") == nil)
        #expect(harness.defaults.object(forKey: "book_entry_prefer_source_name") == nil)
    }

    @Test
    func exportPatchTrimsCredentialsAndIgnoresInvalidTarget() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }

        try await harness.repository.updateExportSettingsData(
            jsonData(#"{"yuqueToken":"  token  ","lastTarget":" PDF ","includePage":false}"#)
        )
        var export = try await jsonObject(from: harness.repository.exportSettingsData())
        #expect(export["yuqueToken"] as? String == "token")
        #expect(export["lastTarget"] as? String == "pdf")
        #expect(export["includePage"] as? Bool == false)

        try await harness.repository.updateExportSettingsData(
            jsonData(#"{"lastTarget":"unsupported","notionToken":" value "}"#)
        )
        export = try await jsonObject(from: harness.repository.exportSettingsData())
        #expect(export["lastTarget"] as? String == "pdf")
        #expect(export["notionToken"] as? String == "value")
    }

    @Test
    func accessCodeDefaultsValidationAuthorizationAndResetMatchAndroid() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }

        let first = await harness.repository.accessAuthSnapshot()
        #expect(first.isEnabled == true)
        #expect(first.accessCode.count == 8)
        #expect(isLowercaseAlphanumeric(first.accessCode))
        #expect(await harness.repository.isAccessAuthorized("  \(first.accessCode)  "))
        #expect(!(await harness.repository.isAccessAuthorized("wrong123")))

        await harness.repository.setAccessAuthEnabled(false)
        #expect(await harness.repository.isAccessAuthorized(nil))

        var rejectedInvalidCode = false
        do {
            try await harness.repository.setAccessCode("ABC-1234")
        } catch DesktopWebSettingsRepositoryError.invalidAccessCode {
            rejectedInvalidCode = true
        }
        #expect(rejectedInvalidCode)

        try await harness.repository.setAccessCode("  abc12345  ")
        let saved = await harness.repository.accessAuthSnapshot()
        #expect(saved.accessCode == "abc12345")
        let reset = await harness.repository.resetAccessCode()
        #expect(reset.count == 8)
        #expect(isLowercaseAlphanumeric(reset))
        #expect(reset != "abc12345")
    }

    private struct Harness {
        let suiteName: String
        let defaults: UserDefaults
        let repository: DesktopWebSettingsRepository
    }

    private func makeHarness() throws -> Harness {
        let suiteName = "DesktopWebSettingsRepositoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return Harness(
            suiteName: suiteName,
            defaults: defaults,
            repository: DesktopWebSettingsRepository(defaults: defaults)
        )
    }

    private func jsonData(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func object(_ parent: [String: Any], _ key: String) throws -> [String: Any] {
        try #require(parent[key] as? [String: Any])
    }

    private func isLowercaseAlphanumeric(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
        }
    }
}

@MainActor
struct DesktopWebAPIAdapterTests {
    @Test
    func productionProviderKeepsMembershipReadOnlyAndRoutesUpgrade() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        var didOpenPremium = false
        harness.bridge.onOpenPremiumUpgrade = {
            didOpenPremium = true
        }
        let adapter = DesktopWebAPIAdapter(
            repository: harness.repository,
            nativeActionBridge: harness.bridge
        )

        let capability = await adapter.membershipCapability()
        #expect(capability.isPremium == false)
        #expect(capability.desktopReadOnly == true)
        #expect(capability.canWriteCoreData == false)
        #expect(capability.upgradeActionAvailable == true)
        #expect(await adapter.isDesktopReadOnly())

        let result = await adapter.openPremiumUpgrade()
        #expect(result == DesktopWebNativeActionResult(accepted: true))
        #expect(didOpenPremium)
    }

    @Test
    func injectedPremiumCapabilityEnablesWritesAndRejectsDuplicateUpgrade() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        let adapter = DesktopWebAPIAdapter(
            repository: harness.repository,
            nativeActionBridge: harness.bridge,
            isPremiumProvider: { true }
        )

        let capability = await adapter.membershipCapability()
        #expect(capability.isPremium)
        #expect(!capability.desktopReadOnly)
        #expect(capability.canWriteCoreData)
        #expect(!(await adapter.isDesktopReadOnly()))

        let result = await adapter.openPremiumUpgrade()
        #expect(result.accepted == false)
        #expect(result.message == "当前已开通高级版")
    }

    @Test
    func adapterMapsAccessAuthorizationAndDynamicJSONWithoutHTTPLeakage() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        try await harness.repository.setAccessCode("abc12345")
        let adapter = DesktopWebAPIAdapter(
            repository: harness.repository,
            nativeActionBridge: harness.bridge,
            isPremiumProvider: { true }
        )

        #expect(await adapter.isAccessAuthorized(" abc12345 "))
        #expect(!(await adapter.isAccessAuthorized("wrong123")))

        try await adapter.updateWebSettings(
            .object(["appearance": .object(["themeMode": .string("dark")])])
        )
        let value = try await adapter.webSettings()
        let appearance = try #require(value.objectValue?["appearance"]?.objectValue)
        #expect(appearance["themeMode"] == .string("dark"))
    }

    @Test
    func catalogPortsFailDeterministicallyUntilDatabaseIsConfigured() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        let adapter = DesktopWebAPIAdapter(
            repository: harness.repository,
            nativeActionBridge: harness.bridge,
            isPremiumProvider: { true }
        )

        do {
            _ = try await adapter.source(id: 1)
            Issue.record("未配置数据库时不应返回来源")
        } catch let error as DesktopWebAPIError {
            #expect(error.code == 50001)
            #expect(error.message == "数据库尚未就绪")
        }
    }

    @Test
    func configuredCatalogMapsSnapshotsAndClassifiedErrors() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        let adapter = DesktopWebAPIAdapter(
            repository: harness.repository,
            nativeActionBridge: harness.bridge,
            isPremiumProvider: { true }
        )
        let database = try AppDatabase.empty()
        adapter.configure(database: database)

        let source = try await adapter.source(id: 1)
        #expect(source.id == 1)
        #expect(source.isDefault)

        do {
            _ = try await adapter.createSource(DesktopWebSourceCreateRequest(name: "未知"))
            Issue.record("Android 来源重名应映射为 40003")
        } catch let error as DesktopWebAPIError {
            #expect(error.code == 40003)
            #expect(error.message == "来源名称已存在: 未知")
        }
    }

    private struct Harness {
        let suiteName: String
        let defaults: UserDefaults
        let repository: DesktopWebSettingsRepository
        let bridge: DesktopWebNativeActionBridge
    }

    private func makeHarness() throws -> Harness {
        let suiteName = "DesktopWebAPIAdapterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return Harness(
            suiteName: suiteName,
            defaults: defaults,
            repository: DesktopWebSettingsRepository(defaults: defaults),
            bridge: DesktopWebNativeActionBridge()
        )
    }
}
