/**
 * [INPUT]: 依赖 UserDefaults 持久化 Web 非敏感设置、ExportSettingsStore 与 Keychain 凭据，并复用书籍录入偏好键保持 App/Web 写入一致
 * [OUTPUT]: 对外提供设置快照、Android 局部 Patch 归一化、访问码校验、脱敏导出设置和仅供执行期使用的凭据快照
 * [POS]: Data 层网页设置仓储；不依赖 XMNoteWeb、HTTP、SwiftUI 或数据库类型
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 网页设置持久化失败；消息会由 Web Controller 按 Android 更新接口合同包装。
enum DesktopWebSettingsRepositoryError: LocalizedError {
    case invalidJSONObject
    case invalidAccessCode

    var errorDescription: String? {
        switch self {
        case .invalidJSONObject:
            return "设置内容格式错误"
        case .invalidAccessCode:
            return "访问授权码格式错误"
        }
    }
}

/// 用 actor 串行保护 UserDefaults 的复合读改写，避免并发 Web 请求互相覆盖局部 Patch。
actor DesktopWebSettingsRepository {
    struct AccessAuthSnapshot: Sendable, Equatable {
        let isEnabled: Bool
        let accessCode: String
    }

    private enum Keys {
        static let webSettings = "desktopWeb.api.webSettings"
        static let exportSettings = "desktopWeb.api.exportSettings"
        static let notionDatabaseID = "desktopWeb.api.notionDatabaseID"
        static let accessAuthEnabled = "desktopWeb.api.accessAuthEnabled"
        static let accessAuthCode = "desktopWeb.api.accessAuthCode"

        static let bookType = "book_entry_prefer_type"
        static let bookSourceID = "desktopWeb.bookEntry.sourceID"
        static let bookSourceName = "book_entry_prefer_source_name"
        static let bookPositionUnit = "book_entry_prefer_unit"
        static let bookReadStatus = "book_entry_prefer_status"
    }

    private static let accessCodeCharacters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    private static let validExportTargets: Set<String> = [
        "yuque", "notion", "onenote", "siyuan", "obsidian", "pdf", "markdown", "text"
    ]
    private static let defaultStatusKeys = [
        "wantRead", "startReading", "readDone", "abandon", "onHold"
    ]

    private let defaults: UserDefaults
    private let credentialStore: ExportCredentialStore
    private let exportSettingsStore: ExportSettingsStore

    init(
        defaults: UserDefaults = .standard,
        credentialStore: ExportCredentialStore = ExportCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        exportSettingsStore = ExportSettingsStore(defaults: defaults, credentialStore: credentialStore)
    }

    /// 返回完整 Web 设置 JSON；读取与书籍录入偏好快照在 actor 内串行完成。
    func webSettingsData() throws -> Data {
        try Self.encodeJSONObject(loadWebSettings())
    }

    /// 按 Android SpSettingHelper.updateWebSettings 的局部更新和归一化规则提交设置。
    func updateWebSettingsData(_ patchData: Data) throws {
        let patch = try Self.decodeObject(patchData)
        var current = loadWebSettings()

        if let display = patch["display"] as? [String: Any] {
            var target = Self.object(current["display"])
            Self.assignInt("noteMaxLines", from: display, to: &target)
            if let value = display["noteTextScale"] as? String {
                target["noteTextScale"] = Self.normalizedNoteTextScale(value)
            }
            Self.assignString("heatmapFilterType", from: display, to: &target)
            Self.assignString("chartConfig", from: display, to: &target)
            if let value = display["noteImageWallMode"] as? String {
                target["noteImageWallMode"] = value.lowercased() == "square" ? "square" : "ratio"
            }
            if let value = display["noteImageWallColumns"], !(value is NSNull) {
                target["noteImageWallColumns"] = Self.normalizedImageWallColumns(value)
            }
            if let value = display["noteImageWallMaxWidth"] as? String {
                target["noteImageWallMaxWidth"] =
                    value.lowercased() == "compact" ? "compact" : "comfortable"
            }
            current["display"] = target
        }

        if let appearance = patch["appearance"] as? [String: Any] {
            var target = Self.object(current["appearance"])
            Self.assignString("themeMode", from: appearance, to: &target)
            current["appearance"] = target
        }

        if let shell = patch["shell"] as? [String: Any] {
            var target = Self.object(current["shell"])
            Self.assignString("activeFilter", from: shell, to: &target)
            Self.assignBool("sidebarCollapsed", from: shell, to: &target)
            current["shell"] = target
        }

        if let book = patch["book"] as? [String: Any],
           let entry = book["entryPreference"] as? [String: Any] {
            updateBookEntryPreference(entry)
        }

        if let bookshelf = patch["bookshelf"] as? [String: Any] {
            var target = Self.object(current["bookshelf"])
            if let value = bookshelf["bookshelf"] as? [String: Any] {
                target["bookshelf"] = Self.normalizedBookshelfPreference(value)
            }
            if let value = bookshelf["groupOverlay"] as? [String: Any] {
                target["groupOverlay"] = Self.normalizedBookshelfPreference(value)
            }
            if let values = bookshelf["statusByKey"] as? [String: Any] {
                var statuses = Self.object(target["statusByKey"])
                for (key, value) in values {
                    guard let object = value as? [String: Any] else { continue }
                    statuses[key] = Self.normalizedBookshelfPreference(object)
                }
                target["statusByKey"] = Self.defaultStatusByKey().merging(statuses) { _, stored in stored }
            }
            current["bookshelf"] = target
        }

        if let notes = patch["notes"] as? [String: Any] {
            current["notes"] = Self.mergedNotes(
                current: Self.object(current["notes"]),
                patch: notes
            )
        }

        if let statistics = patch["statistics"] as? [String: Any] {
            var target = Self.object(current["statistics"])
            if let range = statistics["rangeState"] as? [String: Any] {
                var currentRange = Self.object(target["rangeState"])
                Self.assignString("dimension", from: range, to: &currentRange)
                Self.assignInt("year", from: range, to: &currentRange)
                Self.assignInt("month", from: range, to: &currentRange)
                Self.assignString("weekStart", from: range, to: &currentRange)
                target["rangeState"] = currentRange
            }
            Self.assignInt("allDimensionHeatmapYear", from: statistics, to: &target)
            Self.assignBool("readingDistributionIncludeFuzzy", from: statistics, to: &target)
            Self.assignString("calendarMode", from: statistics, to: &target)
            Self.assignInt("homeHeatmapYear", from: statistics, to: &target)
            Self.assignString("homeReadingRhythmMode", from: statistics, to: &target)
            Self.assignInt("homeYearlyBooksYear", from: statistics, to: &target)
            current["statistics"] = target
        }

        current["book"] = loadBookSettings()
        defaults.set(try Self.encodeJSONObject(current), forKey: Keys.webSettings)
    }

    /// 返回脱敏导出设置；只公开 hasCredential，旧凭据字段始终为空，避免 Web 响应泄露 Keychain 内容。
    func exportSettingsData() async throws -> Data {
        let settings = await exportSettingsStore.settings()
        var object = Self.exportSettingsObject(settings)
        object["yuqueHasCredential"] = await credentialStore.contains(.yuqueToken)
        object["notionConnected"] = await credentialStore.contains(.notionAccessToken)
        object["oneNoteConnected"] = await credentialStore.contains(.oneNoteAccount)
        object["siyuanHasCredential"] = await credentialStore.contains(.siYuanToken)
        object["obsidianHasCredential"] = await credentialStore.contains(.obsidianAPIKey)
        return try Self.encodeJSONObject(object)
    }

    /// 返回仅供导出执行期使用的设置字典；明文值不编码到 HTTP 响应、不写入 UserDefaults。
    func exportRuntimeSettingsData() async throws -> Data {
        let settings = await exportSettingsStore.settings()
        var object = Self.exportSettingsObject(settings)
        object["yuqueToken"] = try await credentialStore.value(for: .yuqueToken) ?? ""
        object["notionToken"] = try await credentialStore.value(for: .notionAccessToken) ?? ""
        object["siyuanToken"] = try await credentialStore.value(for: .siYuanToken) ?? ""
        object["obsidianApiKey"] = try await credentialStore.value(for: .obsidianAPIKey) ?? ""
        return try Self.encodeJSONObject(object)
    }

    /// 以单次 actor 事务应用 Web 局部 Patch；敏感字段进入 Keychain，旧 Notion token/page ID 明确忽略。
    func updateExportSettingsData(_ patchData: Data) async throws {
        let patch = try Self.decodeObject(patchData)
        var settings = await exportSettingsStore.settings()
        if let value = patch["exportNote"] as? Bool { settings.content.includesNotes = value }
        if let value = patch["exportRelevant"] as? Bool { settings.content.includesRelatedNotes = value }
        if let value = patch["exportReview"] as? Bool { settings.content.includesReviews = value }
        if let value = patch["includeDateTime"] as? Bool { settings.includesDateTime = value }
        if let value = patch["includePage"] as? Bool { settings.includesPage = value }
        if let value = patch["includeTag"] as? Bool { settings.includesTags = value }
        if let value = patch["includeBookInfo"] as? Bool { settings.includesBookInformation = value }
        if let value = patch["obsidianExportTags"] as? Bool { settings.obsidianExportsTags = value }
        if let value = patch["siyuanIp"] as? String { settings.siYuanHost = value.trimmed }
        if let value = patch["siyuanPort"] as? String, let port = Int(value.trimmed) { settings.siYuanPort = port }
        if let value = patch["siyuanNotebookId"] as? String { settings.siYuanNotebookID = value.trimmed }
        if let value = patch["obsidianIp"] as? String { settings.obsidianHost = value.trimmed }
        if let value = patch["obsidianDirName"] as? String { settings.obsidianDirectory = value.trimmed }
        if let value = patch["obsidianPinnedCertificateSHA256"] as? String {
            settings.obsidianPinnedCertificateSHA256 = value.trimmed
        }
        if let value = patch["notionDataSourceId"] as? String {
            settings.notionDataSourceID = value.trimmed
        }

        try await saveCredentialPatch(patch["yuqueToken"], credential: .yuqueToken)
        try await saveCredentialPatch(patch["siyuanToken"], credential: .siYuanToken)
        try await saveCredentialPatch(patch["obsidianApiKey"], credential: .obsidianAPIKey)
        // Notion 已切换 OAuth Broker；Integration token 与 page ID 永远不再接收或迁移。
        try? await credentialStore.remove(.notionAccessToken)
        defaults.removeObject(forKey: Keys.notionDatabaseID)
        if let value = patch["lastTarget"] as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if Self.validExportTargets.contains(normalized),
               let target = Self.exportTarget(normalized),
               target.supports(.noteExcerpt) {
                settings.lastNoteTarget = target
            }
        }
        try await exportSettingsStore.save(settings)
        defaults.set(try Self.encodeJSONObject(Self.exportSettingsObject(settings)), forKey: Keys.exportSettings)
    }

    /// 返回 Android `getNotionNoteDatabaseId` 对应的内部缓存；该值不属于 Web 导出设置响应。
    func notionDatabaseID() -> String {
        defaults.string(forKey: Keys.notionDatabaseID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 保存经 Notion 验证或创建后的数据库 ID，供下一次导出先行复用和重新校验。
    func setNotionDatabaseID(_ value: String) {
        defaults.set(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Keys.notionDatabaseID
        )
    }

    /// 校验请求访问码；关闭授权时直接放行，开启时按 Android 规则 trim 后精确比较。
    func isAccessAuthorized(_ submittedCode: String?) -> Bool {
        guard isAccessAuthEnabled() else { return true }
        guard let submittedCode else { return false }
        return submittedCode.trimmingCharacters(in: .whitespacesAndNewlines) == currentAccessCode()
    }

    /// 返回 App 页面所需的访问安全快照；首次读取会生成并持久化 8 位小写字母数字码。
    func accessAuthSnapshot() -> AccessAuthSnapshot {
        AccessAuthSnapshot(isEnabled: isAccessAuthEnabled(), accessCode: currentAccessCode())
    }

    /// 只返回访问授权开关，避免状态探测接口隐式生成或暴露访问码。
    func isAccessAuthEnabled() -> Bool {
        guard defaults.object(forKey: Keys.accessAuthEnabled) != nil else { return true }
        return defaults.bool(forKey: Keys.accessAuthEnabled)
    }

    /// 保存访问授权开关；关闭只改变校验行为，不清除原访问码。
    func setAccessAuthEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.accessAuthEnabled)
    }

    /// 保存用户输入的访问码，格式严格限制为 8 至 32 位小写字母或数字。
    func setAccessCode(_ code: String) throws {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidAccessCode(normalized) else {
            throw DesktopWebSettingsRepositoryError.invalidAccessCode
        }
        defaults.set(normalized, forKey: Keys.accessAuthCode)
    }

    /// 生成并持久化新的 8 位访问码；系统随机源由调用任务同步消费，不跨 actor 并发。
    func resetAccessCode() -> String {
        let code = Self.generateAccessCode()
        defaults.set(code, forKey: Keys.accessAuthCode)
        return code
    }

    private func currentAccessCode() -> String {
        let stored = defaults.string(forKey: Keys.accessAuthCode)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !Self.isValidAccessCode(stored) else { return stored }
        return resetAccessCode()
    }

    /// Web Patch 中省略字段表示保留；八个圆点是脱敏回显，也不得覆盖真实凭据。
    private func saveCredentialPatch(_ rawValue: Any?, credential: ExportCredential) async throws {
        guard let value = rawValue as? String else { return }
        let normalized = value.trimmed
        guard normalized != "••••••••" else { return }
        try await credentialStore.set(normalized, for: credential)
    }

    private func loadWebSettings() -> [String: Any] {
        var result = Self.defaultWebSettings()
        if let data = defaults.data(forKey: Keys.webSettings),
           let stored = try? Self.decodeObject(data) {
            result = Self.recursiveMerge(defaults: result, stored: stored)
        }
        var bookshelf = Self.object(result["bookshelf"])
        bookshelf["statusByKey"] = Self.defaultStatusByKey().merging(
            Self.object(bookshelf["statusByKey"])
        ) { _, stored in stored }
        result["bookshelf"] = bookshelf
        result["book"] = loadBookSettings()
        return result
    }

    private func loadBookSettings() -> [String: Any] {
        let keys = [
            Keys.bookType,
            Keys.bookSourceID,
            Keys.bookSourceName,
            Keys.bookPositionUnit,
            Keys.bookReadStatus
        ]
        guard keys.contains(where: { defaults.object(forKey: $0) != nil }) else {
            return ["entryPreference": ["sourceName": ""]]
        }
        return [
            "entryPreference": [
                "type": defaults.object(forKey: Keys.bookType) == nil
                    ? 0 : defaults.integer(forKey: Keys.bookType),
                "sourceId": defaults.object(forKey: Keys.bookSourceID) == nil
                    ? 1 : defaults.object(forKey: Keys.bookSourceID) as? Int64 ?? Int64(defaults.integer(forKey: Keys.bookSourceID)),
                "sourceName": defaults.string(forKey: Keys.bookSourceName) ?? "",
                "positionUnit": defaults.object(forKey: Keys.bookPositionUnit) == nil
                    ? 2 : defaults.integer(forKey: Keys.bookPositionUnit),
                "readStatus": defaults.object(forKey: Keys.bookReadStatus) == nil
                    ? 2 : defaults.integer(forKey: Keys.bookReadStatus)
            ]
        ]
    }

    private func updateBookEntryPreference(_ patch: [String: Any]) {
        let sourceName = patch["sourceName"] as? String
        let hasExplicitReset =
            Self.intValue(patch["type"]) == nil &&
            Self.int64Value(patch["sourceId"]) == nil &&
            Self.intValue(patch["positionUnit"]) == nil &&
            Self.intValue(patch["readStatus"]) == nil &&
            (sourceName == nil || sourceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)

        if hasExplicitReset {
            defaults.removeObject(forKey: Keys.bookType)
            defaults.removeObject(forKey: Keys.bookSourceID)
            defaults.removeObject(forKey: Keys.bookSourceName)
            defaults.removeObject(forKey: Keys.bookPositionUnit)
            defaults.removeObject(forKey: Keys.bookReadStatus)
            return
        }

        let current = Self.object(loadBookSettings()["entryPreference"])
        defaults.set(Self.intValue(patch["type"]) ?? Self.intValue(current["type"]) ?? 0, forKey: Keys.bookType)
        defaults.set(
            Self.int64Value(patch["sourceId"]) ?? Self.int64Value(current["sourceId"]) ?? 1,
            forKey: Keys.bookSourceID
        )
        defaults.set(sourceName ?? current["sourceName"] as? String ?? "", forKey: Keys.bookSourceName)
        defaults.set(
            Self.intValue(patch["positionUnit"]) ?? Self.intValue(current["positionUnit"]) ?? 2,
            forKey: Keys.bookPositionUnit
        )
        defaults.set(
            Self.intValue(patch["readStatus"]) ?? Self.intValue(current["readStatus"]) ?? 2,
            forKey: Keys.bookReadStatus
        )
    }

    private func loadExportSettings() -> [String: Any] {
        let fallback = Self.defaultExportSettings()
        guard let data = defaults.data(forKey: Keys.exportSettings),
              let stored = try? Self.decodeObject(data) else {
            return fallback
        }
        return Self.recursiveMerge(defaults: fallback, stored: stored)
    }

    private static func defaultWebSettings() -> [String: Any] {
        [
            "display": [
                "noteMaxLines": 6,
                "noteTextScale": "balanced",
                "heatmapFilterType": "all",
                "chartConfig": "",
                "noteImageWallMode": "ratio",
                "noteImageWallColumns": "auto",
                "noteImageWallMaxWidth": "comfortable"
            ],
            "appearance": ["themeMode": "system"],
            "shell": ["activeFilter": "home", "sidebarCollapsed": false],
            "book": ["entryPreference": ["sourceName": ""]],
            "bookshelf": [
                "bookshelf": defaultBookshelfPreference(),
                "groupOverlay": defaultBookshelfPreference(),
                "statusByKey": defaultStatusByKey()
            ],
            "notes": [
                "globalToolbar": [
                    "secondaryTab": "note",
                    "appliedNoteState": [
                        "viewMode": "list",
                        "sortOption": "create_time_desc",
                        "quickTagId": 0,
                        "selectedTagIds": [],
                        "tagMode": "or",
                        "selectedBooks": []
                    ],
                    "appliedRelatedState": [
                        "viewMode": "masonry",
                        "categoryId": 0,
                        "sortOption": "create_time_desc"
                    ],
                    "appliedReviewState": [
                        "viewMode": "list",
                        "sortOption": "create_time_desc"
                    ]
                ],
                "bookToolbarByBookId": [:],
                "reviewToolbarByBookId": [:],
                "noteContinuousEditingEnabled": false,
                "relatedContinuousEditingEnabled": false,
                "lastRelatedEditorCategoryId": 0
            ],
            "statistics": [
                "rangeState": [
                    "dimension": "all",
                    "year": 0,
                    "month": 0,
                    "weekStart": ""
                ],
                "allDimensionHeatmapYear": 0,
                "readingDistributionIncludeFuzzy": false,
                "calendarMode": "events",
                "homeHeatmapYear": 0,
                "homeReadingRhythmMode": "month",
                "homeYearlyBooksYear": 0
            ]
        ]
    }

    private static func defaultBookshelfPreference(sortBy: String = "custom") -> [String: Any] {
        [
            "sortBy": sortBy,
            "sortOrder": "desc",
            "enableSection": false,
            "gridColumns": 8,
            "filterTags": [],
            "tagMode": "or",
            "filterSources": [],
            "filterGroupOnly": false
        ]
    }

    private static func defaultStatusByKey() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: defaultStatusKeys.map { ($0, defaultBookshelfPreference(sortBy: "create_time")) })
    }

    private static func defaultExportSettings() -> [String: Any] {
        [
            "exportNote": true,
            "exportRelevant": true,
            "exportReview": true,
            "includeDateTime": true,
            "includePage": true,
            "includeTag": true,
            "includeBookInfo": true,
            "yuqueToken": "",
            "notionToken": "",
            "notionPageId": "",
            "notionDataSourceId": "",
            "siyuanIp": "",
            "siyuanPort": "6806",
            "siyuanToken": "",
            "siyuanNotebookId": "",
            "obsidianIp": "",
            "obsidianApiKey": "",
            "obsidianDirName": "",
            "obsidianExportTags": true,
            "lastTarget": "markdown"
        ]
    }

    /// 把统一领域设置映射为既有 Desktop Web 字段，并强制所有历史明文凭据字段为空。
    private static func exportSettingsObject(_ settings: ExportSettingsSnapshot) -> [String: Any] {
        [
            "exportNote": settings.content.includesNotes,
            "exportRelevant": settings.content.includesRelatedNotes,
            "exportReview": settings.content.includesReviews,
            "includeDateTime": settings.includesDateTime,
            "includePage": settings.includesPage,
            "includeTag": settings.includesTags,
            "includeBookInfo": settings.includesBookInformation,
            "yuqueToken": "",
            "notionToken": "",
            "notionPageId": "",
            "notionDataSourceId": settings.notionDataSourceID,
            "siyuanIp": settings.siYuanHost,
            "siyuanPort": String(settings.siYuanPort),
            "siyuanToken": "",
            "siyuanNotebookId": settings.siYuanNotebookID,
            "obsidianIp": settings.obsidianHost,
            "obsidianApiKey": "",
            "obsidianDirName": settings.obsidianDirectory,
            "obsidianExportTags": settings.obsidianExportsTags,
            "obsidianPinnedCertificateSHA256": settings.obsidianPinnedCertificateSHA256,
            "lastTarget": settings.lastNoteTarget.desktopWebIdentifier
        ]
    }

    /// 兼容旧 Web target 字符串并映射到稳定领域 case。
    private static func exportTarget(_ value: String) -> ExportTarget? {
        switch value {
        case "onenote": .oneNote
        case "siyuan": .siYuan
        default: ExportTarget(rawValue: value)
        }
    }

    private static func normalizedBookshelfPreference(_ patch: [String: Any]) -> [String: Any] {
        let sortBy = (patch["sortBy"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String: Any] = [
            "sortBy": sortBy?.isEmpty == false ? sortBy! : "custom",
            "sortOrder": patch["sortOrder"] as? String == "asc" ? "asc" : "desc",
            "enableSection": patch["enableSection"] as? Bool == true,
            "gridColumns": min(10, max(6, intValue(patch["gridColumns"]) ?? 8)),
            "filterTags": normalizedNamedItems(patch["filterTags"]),
            "tagMode": patch["tagMode"] as? String == "and" ? "and" : "or",
            "filterSources": normalizedNamedItems(patch["filterSources"]),
            "filterGroupOnly": patch["filterGroupOnly"] as? Bool == true
        ]
        if let filterStatus = intValue(patch["filterStatus"]), (1...5).contains(filterStatus) {
            result["filterStatus"] = filterStatus
        }
        return result
    }

    private static func normalizedNamedItems(_ value: Any?) -> [[String: Any]] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = intValue(item["id"]), id > 0 else { return nil }
            let name = (item["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            return ["id": id, "name": name]
        }
    }

    private static func mergedNotes(
        current: [String: Any],
        patch: [String: Any]
    ) -> [String: Any] {
        var target = current
        if let global = patch["globalToolbar"] as? [String: Any] {
            var currentGlobal = object(target["globalToolbar"])
            assignString("secondaryTab", from: global, to: &currentGlobal)
            if let note = global["appliedNoteState"] as? [String: Any] {
                var state = object(currentGlobal["appliedNoteState"])
                assignString("viewMode", from: note, to: &state)
                assignString("sortOption", from: note, to: &state)
                assignInt("quickTagId", from: note, to: &state)
                if let values = note["selectedTagIds"] as? [Any] {
                    state["selectedTagIds"] = values.compactMap(intValue)
                }
                assignString("tagMode", from: note, to: &state)
                if let books = note["selectedBooks"] as? [[String: Any]] {
                    state["selectedBooks"] = books.compactMap(normalizedSearchBook)
                }
                currentGlobal["appliedNoteState"] = state
            }
            if let related = global["appliedRelatedState"] as? [String: Any] {
                var state = object(currentGlobal["appliedRelatedState"])
                assignString("viewMode", from: related, to: &state)
                assignInt("categoryId", from: related, to: &state)
                assignString("sortOption", from: related, to: &state)
                currentGlobal["appliedRelatedState"] = state
            }
            if let review = global["appliedReviewState"] as? [String: Any] {
                var state = object(currentGlobal["appliedReviewState"])
                assignString("viewMode", from: review, to: &state)
                assignString("sortOption", from: review, to: &state)
                currentGlobal["appliedReviewState"] = state
            }
            target["globalToolbar"] = currentGlobal
        }

        if let values = patch["bookToolbarByBookId"] as? [String: Any] {
            var states = object(target["bookToolbarByBookId"])
            for (key, value) in values {
                guard let patchState = value as? [String: Any] else { continue }
                states[key] = mergedBookToolbar(
                    current: object(states[key]).isEmpty
                        ? ["sortOption": "create_time_desc", "tagFilter": 0, "selectedTagIds": [], "tagMode": "or"]
                        : object(states[key]),
                    patch: patchState
                )
            }
            target["bookToolbarByBookId"] = states
        }

        if let values = patch["reviewToolbarByBookId"] as? [String: Any] {
            var states = object(target["reviewToolbarByBookId"])
            for (key, value) in values {
                guard let patchState = value as? [String: Any] else { continue }
                var state = object(states[key])
                if state.isEmpty { state = ["sortOption": "create_time_asc"] }
                assignString("sortOption", from: patchState, to: &state)
                states[key] = state
            }
            target["reviewToolbarByBookId"] = states
        }

        assignBool("noteContinuousEditingEnabled", from: patch, to: &target)
        assignBool("relatedContinuousEditingEnabled", from: patch, to: &target)
        assignInt("lastRelatedEditorCategoryId", from: patch, to: &target)
        return target
    }

    private static func mergedBookToolbar(
        current: [String: Any],
        patch: [String: Any]
    ) -> [String: Any] {
        var target = current
        assignString("sortOption", from: patch, to: &target)
        assignInt("tagFilter", from: patch, to: &target)
        if let values = patch["selectedTagIds"] as? [Any] {
            var seen: Set<Int> = []
            target["selectedTagIds"] = values.compactMap(intValue).filter { $0 > 0 && seen.insert($0).inserted }
        }
        if let mode = patch["tagMode"] as? String {
            target["tagMode"] = mode == "and" ? "and" : "or"
        }
        if let value = patch["relatedSortOption"] as? String {
            if value == "create_time_asc" || value == "create_time_desc" {
                target["relatedSortOption"] = value
            } else {
                target.removeValue(forKey: "relatedSortOption")
            }
        }
        return target
    }

    private static func normalizedSearchBook(_ value: [String: Any]) -> [String: Any]? {
        guard let id = intValue(value["id"]), id > 0 else { return nil }
        return [
            "id": id,
            "name": (value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            "cover": value["cover"] as? String ?? "",
            "author": value["author"] as? String ?? "",
            "press": value["press"] as? String ?? ""
        ]
    }

    private static func normalizedNoteTextScale(_ value: String) -> String {
        let normalized = value.lowercased()
        return ["compact", "comfortable", "large"].contains(normalized) ? normalized : "balanced"
    }

    private static func normalizedImageWallColumns(_ value: Any) -> Any {
        if let number = intValue(value) {
            return min(8, max(2, number))
        }
        if let string = value as? String {
            if string.lowercased() == "auto" { return "auto" }
            if let number = Int(string) {
                return min(8, max(2, number))
            }
        }
        return "auto"
    }

    private static func recursiveMerge(
        defaults: [String: Any],
        stored: [String: Any]
    ) -> [String: Any] {
        var result = defaults
        for (key, value) in stored {
            if let defaultObject = defaults[key] as? [String: Any],
               let storedObject = value as? [String: Any] {
                result[key] = recursiveMerge(defaults: defaultObject, stored: storedObject)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func object(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func assignString(
        _ key: String,
        from source: [String: Any],
        to target: inout [String: Any]
    ) {
        if let value = source[key] as? String {
            target[key] = value
        }
    }

    private static func assignInt(
        _ key: String,
        from source: [String: Any],
        to target: inout [String: Any]
    ) {
        if let value = intValue(source[key]) {
            target[key] = value
        }
    }

    private static func assignBool(
        _ key: String,
        from source: [String: Any],
        to target: inout [String: Any]
    ) {
        if isBooleanValue(source[key]), let value = source[key] as? NSNumber {
            target[key] = value.boolValue
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard !isBooleanValue(value) else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(exactly: value) }
        if let value = value as? Double, value.rounded() == value {
            return Int(exactly: value)
        }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        guard !isBooleanValue(value) else { return nil }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double, value.rounded() == value {
            return Int64(exactly: value)
        }
        return nil
    }

    private static func isBooleanValue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func decodeObject(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw DesktopWebSettingsRepositoryError.invalidJSONObject
        }
        return object
    }

    private static func encodeJSONObject(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw DesktopWebSettingsRepositoryError.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func isValidAccessCode(_ code: String) -> Bool {
        guard (8...32).contains(code.count) else { return false }
        return code.unicodeScalars.allSatisfy { scalar in
            (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
        }
    }

    private static func generateAccessCode(length: Int = 8) -> String {
        var generator = SystemRandomNumberGenerator()
        return String(
            (0..<length).map { _ in
                accessCodeCharacters.randomElement(using: &generator)!
            }
        )
    }
}

private nonisolated extension String {
    /// 导出设置字段统一去除首尾空白，不改变中间内容。
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
