/**
 * [INPUT]: 依赖 DesktopWebExportRepository、DesktopWebSettingsRepository、URLSession、UIKit PDF 与 ZIPFoundation
 * [OUTPUT]: 对外提供思源/Obsidian 枚举、本地 PDF/Markdown/Text 下载和四类远端导出
 * [POS]: Infra 层 Web 导出编排；数据库只读由 Repository 承担，Package 不接触文件与网络实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit
import XMNoteWeb
import ZIPFoundation

/// 导出没有共享可变任务；每次调用持有独立快照，取消会停止尚未开始的书籍或远端请求。
final class DesktopWebExportService: DesktopWebExportPort, @unchecked Sendable {
    private struct GeneratedFile {
        let name: String
        let data: Data
        let mediaType: String
    }

    private enum PreparedRemoteTarget {
        case yuQue(token: String, repositoryID: String)
        case notion(token: String, databaseID: String)
        case siYuan(baseURL: String, token: String, notebookID: String)
        case obsidian(baseURL: String, apiKey: String, directory: String)
    }

    private let repository: DesktopWebExportRepository
    private let settingsRepository: DesktopWebSettingsRepository
    private let session: URLSession
    private let currentTimeMillis: @Sendable () -> Int64

    init(
        repository: DesktopWebExportRepository,
        settingsRepository: DesktopWebSettingsRepository,
        session: URLSession = .shared,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.repository = repository
        self.settingsRepository = settingsRepository
        self.session = session
        self.currentTimeMillis = currentTimeMillis
    }

    /// 调用思源 lsNotebooks，并按 sort 升序映射空名称回退 ID。
    func siYuanNotebooks() async throws -> [DesktopWebExportPlatformOption] {
        let settings = try await exportSettings()
        let ip = settings.string("siyuanIp")
        let port = settings.string("siyuanPort")
        guard !ip.isEmpty else { throw DesktopWebAPIError(code: 400, message: "缺少思源 IP 地址，请先到设置中填写") }
        guard !port.isEmpty else { throw DesktopWebAPIError(code: 400, message: "缺少思源端口，请先到设置中填写") }
        let json = try await requestJSON(
            url: try requireURL("http://\(ip):\(port)/api/notebook/lsNotebooks"),
            method: "POST",
            headers: ["Authorization": "Token \(settings.string("siyuanToken"))"],
            body: Data("{}".utf8)
        )
        if let code = json["code"] as? Int, code != 0 {
            throw DesktopWebAPIError(code: 400, message: json["msg"] as? String ?? "思源请求失败")
        }
        let notebooks = ((json["data"] as? [String: Any])?["notebooks"] as? [[String: Any]]) ?? []
        return notebooks.sorted { Self.siYuanSort($0) < Self.siYuanSort($1) }.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(id: id, name: name.isEmpty ? id : name)
        }
    }

    /// 调用 Obsidian Local REST API vault 根目录，只返回去重后的一级目录名。
    func obsidianDirectories() async throws -> [DesktopWebExportPlatformOption] {
        let settings = try await exportSettings()
        let ip = settings.string("obsidianIp")
        let key = settings.string("obsidianApiKey")
        guard !ip.isEmpty else { throw DesktopWebAPIError(code: 400, message: "缺少 Obsidian IP 地址，请先到设置中填写") }
        guard !key.isEmpty else { throw DesktopWebAPIError(code: 400, message: "缺少 Obsidian API Key，请先到设置中填写") }
        let (data, response) = try await rawRequest(
            url: try requireURL("https://\(ip):27124/vault/"),
            method: "GET",
            headers: ["Authorization": "Bearer \(key)"],
            body: nil
        )
        if response.statusCode == 404 { return [] }
        guard (200...299).contains(response.statusCode) else { throw Self.httpError(data, response) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dirs = (object?["files"] as? [String] ?? [])
            .filter { $0.hasSuffix("/") }
            .map { $0.replacingOccurrences(of: "/", with: "") }
        return Array(Set(dirs.filter { !$0.isEmpty })).sorted { $0.lowercased() < $1.lowercased() }
            .map { .init(id: $0, name: $0) }
    }

    /// 生成单文件或 ZIP；文件名、选择规则和错误语义与 Android NoteExportWebService 对齐。
    func exportNotesLocally(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebExportFile {
        // iOS 以内存 Data 返回导出结果；ZIP 临时文件由 makeZIP 的 defer 在成功与失败路径统一清理。
        try ensureContentSelected(request.content)
        let target = request.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["pdf", "markdown", "text"].contains(target) else {
            throw DesktopWebAPIError(code: 40001, message: "不支持的导出格式：\(request.target)")
        }
        let ids = try await resolvedBookIDs(request.bookIds)
        guard !ids.isEmpty else { throw DesktopWebAPIError(code: 40001, message: "没有可导出的书籍") }
        var files: [GeneratedFile] = []
        let settings = try await exportSettings()
        for id in ids {
            try Task.checkCancellation()
            let bundle = try await repository.bundle(
                bookID: id,
                includeReview: request.content.review,
                includeRelated: request.content.relevant
            )
            files.append(contentsOf: generateFiles(
                bundle: bundle,
                target: target,
                selection: request.content,
                settings: settings
            ))
        }
        guard !files.isEmpty else {
            throw DesktopWebAPIError(code: 40001, message: "没有可导出的内容，请检查所选类别是否有数据")
        }
        let selectedCount = [request.content.note, request.content.relevant, request.content.review].filter { $0 }.count
        if ids.count == 1, selectedCount == 1, files.count == 1 {
            let file = files[0]
            return .init(fileName: file.name, mediaType: file.mediaType, data: file.data)
        }
        let name = ids.count == 1 ? await repository.safeBookName(ids[0]) : nil
        let zipName = "\(name.map { Self.sanitizeName($0) + "_" } ?? "")书摘导出_\(timestamp()).zip"
        return .init(fileName: zipName, mediaType: "application/zip", data: try Self.makeZIP(files))
    }

    /// 校验远端目标配置后逐书导出；单书失败进入 failedItems，目标级配置失败直接抛出。
    func exportNotesRemotely(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebRemoteExportResult {
        try ensureContentSelected(request.content)
        let target = request.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["yuque", "notion", "siyuan", "obsidian"].contains(target) else {
            throw DesktopWebAPIError(code: 40001, message: "不支持的远程导出目标：\(request.target)")
        }
        let ids = try await resolvedBookIDs(request.bookIds)
        guard !ids.isEmpty else { return .init(total: 0, successCount: 0, failCount: 0, failedItems: []) }
        let settings = try await exportSettings()
        try Self.validateRemoteSettings(target: target, settings: settings)
        let preparedTarget = try await prepareRemoteTarget(target, settings: settings)
        var failures: [DesktopWebRemoteExportFailedItem] = []
        var success = 0
        for id in ids {
            do {
                try Task.checkCancellation()
                let bundle = try await repository.bundle(
                    bookID: id,
                    includeReview: request.content.review,
                    includeRelated: request.content.relevant
                )
                try await uploadRemoteBook(
                    preparedTarget: preparedTarget,
                    bundle: bundle,
                    selection: request.content,
                    settings: settings
                )
                success += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(.init(
                    bookId: id,
                    bookName: await repository.safeBookName(id),
                    reason: error.localizedDescription.isEmpty ? "导出失败" : error.localizedDescription
                ))
            }
        }
        return .init(total: ids.count, successCount: success, failCount: failures.count, failedItems: failures)
    }
}

private extension DesktopWebExportService {
    func exportSettings() async throws -> [String: Any] {
        let data = try await settingsRepository.exportSettingsData()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopWebAPIError(code: 50001, message: "导出设置读取失败")
        }
        return object
    }

    func resolvedBookIDs(_ requested: [Int64]) async throws -> [Int64] {
        if requested.isEmpty { return try await repository.allBookIDs() }
        var seen = Set<Int64>()
        return requested.filter { $0 > 0 && seen.insert($0).inserted }
    }

    func ensureContentSelected(_ value: DesktopWebExportContentSelection) throws {
        guard value.note || value.relevant || value.review else {
            throw DesktopWebAPIError(code: 40001, message: "导出内容请至少选择一项")
        }
    }

    func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000))
    }

    func requestJSON(url: URL, method: String, headers: [String: String], body: Data?) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(url: url, method: method, headers: headers, body: body)
        guard (200...299).contains(response.statusCode) else { throw Self.httpError(data, response) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopWebAPIError(code: 400, message: "远端响应格式错误")
        }
        return json
    }

    func rawRequest(url: URL, method: String, headers: [String: String], body: Data?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if body != nil, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DesktopWebAPIError(code: 400, message: "远端响应无效")
        }
        return (data, http)
    }

    /// 在逐书循环前完成 Android 的目标级初始化，避免配置或仓库发现失败被误记为单书失败。
    private func prepareRemoteTarget(
        _ target: String,
        settings: [String: Any]
    ) async throws -> PreparedRemoteTarget {
        switch target {
        case "yuque":
            let token = settings.string("yuqueToken")
            return .yuQue(
                token: token,
                repositoryID: try await ensureYuQueRepositoryID(token: token)
            )
        case "notion":
            // TODO(DEFERRED-P0-NOTION): 当前仍使用旧 Integration Token/Page ID 与数据库导出流程；
            // OAuth 连接状态、workspace/data source 和同步式导出随 Notion 迁移单独实施。
            let token = settings.string("notionToken")
            return .notion(
                token: token,
                databaseID: try await ensureNotionDatabaseID(
                    token: token,
                    pageID: settings.string("notionPageId")
                )
            )
        case "siyuan":
            return .siYuan(
                baseURL: "http://\(settings.string("siyuanIp")):\(settings.string("siyuanPort"))",
                token: settings.string("siyuanToken"),
                notebookID: settings.string("siyuanNotebookId")
            )
        case "obsidian":
            return .obsidian(
                baseURL: "https://\(settings.string("obsidianIp")):27124",
                apiKey: settings.string("obsidianApiKey"),
                directory: settings.string("obsidianDirName")
            )
        default:
            throw DesktopWebAPIError(code: 40001, message: "不支持的远程导出目标：\(target)")
        }
    }

    /// 按目标专属生成器生成并上传一整本书；任一页面失败即把该书计入 failedItems。
    private func uploadRemoteBook(
        preparedTarget: PreparedRemoteTarget,
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any]
    ) async throws {
        let frozenTimestamp = timestamp()
        switch preparedTarget {
        case let .yuQue(token, repositoryID):
            let pages = DesktopWebRemoteExportGenerators.yuQuePages(
                bundle: bundle,
                selection: selection,
                settings: settings,
                timestamp: frozenTimestamp
            )
            try ensureRemotePages(pages, bookName: bundle.book.name)
            for (index, page) in pages.enumerated() {
                let body = Self.formBody([
                    "title": page.title,
                    "slug": Self.slug(page.title, timestamp: timestamp(), index: index),
                    "format": "markdown",
                    "body": page.body
                ])
                _ = try await requestJSON(
                    url: try requireURL("https://www.yuque.com/api/v2/repos/\(repositoryID)/docs"),
                    method: "POST",
                    headers: [
                        "X-Auth-Token": token,
                        "Content-Type": "application/x-www-form-urlencoded"
                    ],
                    body: body
                )
            }
        case let .notion(token, databaseID):
            let pages = DesktopWebNotionExportGenerator.pages(
                bundle: bundle,
                selection: selection,
                settings: settings,
                timestamp: frozenTimestamp
            )
            guard !pages.isEmpty else {
                throw DesktopWebAPIError(code: 40001, message: "《\(bundle.book.name)》暂无可导出的内容")
            }
            for page in pages {
                var body = page.body
                body["parent"] = ["database_id": databaseID]
                _ = try await requestJSON(
                    url: try requireURL("https://api.notion.com/v1/pages"),
                    method: "POST",
                    headers: Self.notionHeaders(token: token),
                    body: try JSONSerialization.data(withJSONObject: body)
                )
            }
        case let .siYuan(baseURL, token, notebookID):
            let pages = DesktopWebRemoteExportGenerators.siYuanPages(
                bundle: bundle,
                selection: selection,
                settings: settings,
                timestamp: frozenTimestamp
            )
            try ensureRemotePages(pages, bookName: bundle.book.name)
            for page in pages {
                let body = try JSONSerialization.data(withJSONObject: [
                    "notebook": notebookID,
                    "path": "/\(Self.sanitizeName(page.title))",
                    "markdown": page.body
                ])
                let json = try await requestJSON(
                    url: try requireURL("\(baseURL)/api/filetree/createDocWithMd"),
                    method: "POST",
                    headers: ["Authorization": "Token \(token)"],
                    body: body
                )
                if let code = json["code"] as? Int, code != 0 {
                    throw DesktopWebAPIError(
                        code: 400,
                        message: json["msg"] as? String ?? "思源导出失败"
                    )
                }
            }
        case let .obsidian(baseURL, apiKey, directory):
            let pages = DesktopWebRemoteExportGenerators.obsidianPages(
                bundle: bundle,
                selection: selection,
                settings: settings,
                timestamp: frozenTimestamp
            )
            try ensureRemotePages(pages, bookName: bundle.book.name)
            for page in pages {
                let path = [directory, "\(Self.sanitizeName(page.title)).md"]
                    .filter { !$0.isEmpty }
                    .joined(separator: "/")
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                let (data, response) = try await rawRequest(
                    url: try requireURL("\(baseURL)/vault/\(encoded)"),
                    method: "PUT",
                    headers: [
                        "Authorization": "Bearer \(apiKey)",
                        "Content-Type": "text/plain"
                    ],
                    body: Data(page.body.utf8)
                )
                guard (200...299).contains(response.statusCode) else {
                    throw Self.httpError(data, response)
                }
            }
        }
    }

    /// 保留 Android “选择了书摘即使为空也生成页面”的规则，只在页面列表确实为空时失败。
    func ensureRemotePages(
        _ pages: [DesktopWebRemoteExportPage],
        bookName: String
    ) throws {
        guard !pages.isEmpty else {
            throw DesktopWebAPIError(code: 40001, message: "《\(bookName)》暂无可导出的内容")
        }
    }

    /// 只执行一次语雀用户和知识库发现；缺少知识库时按 Android 表单参数创建。
    func ensureYuQueRepositoryID(token: String) async throws -> String {
        let user = try await requestJSON(
            url: try requireURL("https://www.yuque.com/api/v2/user"),
            method: "GET",
            headers: ["X-Auth-Token": token],
            body: nil
        )
        guard let rawUserID = (user["data"] as? [String: Any])?["id"] else {
            throw DesktopWebAPIError(code: 400, message: "语雀用户信息获取失败")
        }
        let userID = String(describing: rawUserID)
        let repos = try await requestJSON(
            url: try requireURL("https://www.yuque.com/api/v2/users/\(userID)/repos"),
            method: "GET",
            headers: ["X-Auth-Token": token],
            body: nil
        )
        let candidates = repos["data"] as? [[String: Any]] ?? []
        if let existing = candidates.first(where: { $0["name"] as? String == "纸间书摘" })?["id"] {
            return String(describing: existing)
        }
        let created = try await requestJSON(
            url: try requireURL("https://www.yuque.com/api/v2/users/\(userID)/repos"),
            method: "POST",
            headers: [
                "X-Auth-Token": token,
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            body: Self.formBody([
                "name": "纸间书摘",
                "slug": Self.slug("纸间书摘", timestamp: timestamp(), index: 0),
                "description": "从纸间书摘导出的读书笔记",
                "public": "0",
                "type": "Book"
            ])
        )
        guard let id = (created["data"] as? [String: Any])?["id"] else {
            throw DesktopWebAPIError(code: 400, message: "语雀知识库创建失败")
        }
        return String(describing: id)
    }

    /// 验证缓存的 Notion database 仍属于当前 page 且未归档，否则创建并保存“书摘导出”数据库。
    func ensureNotionDatabaseID(
        token: String,
        pageID: String
    ) async throws -> String {
        let cachedID = await settingsRepository.notionDatabaseID()
        let isValid: Bool
        do {
            let database = try await requestJSON(
                url: try requireURL("https://api.notion.com/v1/databases/\(cachedID)"),
                method: "GET",
                headers: Self.notionHeaders(token: token),
                body: nil
            )
            let parentID = (database["parent"] as? [String: Any])?["page_id"] as? String
            let isArchived = database["archived"] as? Bool ?? false
            isValid = parentID == pageID && !isArchived
        } catch {
            // Android databaseExists 会吞掉所有读取异常，然后转入创建数据库。
            isValid = false
        }
        if isValid {
            return cachedID
        }
        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": pageID],
            "cover": [
                "type": "external",
                "external": ["url": Self.notionCoverURLs.randomElement() ?? Self.notionCoverURLs[0]]
            ],
            "icon": ["type": "emoji", "emoji": "📔"],
            "title": [
                ["type": "text", "text": ["content": "书摘导出"]]
            ],
            "properties": ["Page": ["title": [String: Any]()] as [String: Any]]
        ]
        let created = try await requestJSON(
            url: try requireURL("https://api.notion.com/v1/databases"),
            method: "POST",
            headers: Self.notionHeaders(token: token),
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let id = created["id"] as? String, !id.isEmpty else {
            throw DesktopWebAPIError(code: 400, message: "Notion 数据库创建失败")
        }
        await settingsRepository.setNotionDatabaseID(id)
        return id
    }

    func requireURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw DesktopWebAPIError(code: 400, message: "远端地址无效") }
        return url
    }

    static func httpError(_ data: Data, _ response: HTTPURLResponse) -> DesktopWebAPIError {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DesktopWebAPIError(code: 400, message: text?.isEmpty == false ? text! : "HTTP \(response.statusCode)")
    }

    /// 返回 Android Notion Retrofit 客户端等价的鉴权与版本请求头。
    static func notionHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Notion-Version": "2022-06-28"
        ]
    }

    /// Android BaseDataRepository 用于创建 Notion 数据库的随机封面候选。
    static let notionCoverURLs = [
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_36.jpeg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_37.JPG",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_38.JPG",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_39.jpeg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_40.jpeg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_41.jpeg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_42.JPG",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_43.jpeg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_44.jpeg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_45.jpeg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notion_cover_46.jpeg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic1.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic10.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic11.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic12.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic14.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic15.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic17.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic18.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic19.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic2.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic20.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic21.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic4.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic5.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic6.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic7.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic8.jpg",
        "https://xmnote-1252413502.cos.ap-shanghai.myqcloud.com/notionPic9.jpg"
    ]

    static func validateRemoteSettings(target: String, settings: [String: Any]) throws {
        switch target {
        case "yuque":
            if settings.string("yuqueToken").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少语雀 Token，请先到设置中填写") }
        case "notion":
            if settings.string("notionToken").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少 Notion Integration Token，请先到设置中填写") }
            if settings.string("notionPageId").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少 Notion Page ID，请先到设置中填写") }
        case "siyuan":
            if settings.string("siyuanIp").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少思源 IP 地址，请先到设置中填写") }
            if settings.string("siyuanPort").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少思源端口，请先到设置中填写") }
            if settings.string("siyuanNotebookId").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少思源笔记本，请先在设置中填写 notebookId") }
        case "obsidian":
            if settings.string("obsidianIp").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少 Obsidian IP 地址，请先到设置中填写") }
            if settings.string("obsidianApiKey").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少 Obsidian API Key，请先到设置中填写") }
            if settings.string("obsidianDirName").isEmpty { throw DesktopWebAPIError(code: 40001, message: "缺少 Obsidian 目录，请先到设置中填写") }
        default: break
        }
    }

    private func generateFiles(
        bundle: DesktopWebExportBundle,
        target: String,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any]
    ) -> [GeneratedFile] {
        let sections = Self.contentSections(bundle: bundle, selection: selection, settings: settings)
        return sections.compactMap { title, markdown, text in
            switch target {
            case "markdown": return .init(name: "\(Self.safeFileName(title, timestamp: timestamp())).md", data: Data(markdown.utf8), mediaType: "text/markdown")
            case "text": return .init(name: "\(Self.safeFileName(title, timestamp: timestamp())).txt", data: Data(text.utf8), mediaType: "text/plain; charset=utf-8")
            case "pdf": return .init(name: "\(Self.safeFileName(title, timestamp: timestamp())).pdf", data: Self.makePDF(text), mediaType: "application/pdf")
            default: return nil
            }
        }
    }

    static func contentSections(
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any]
    ) -> [(String, String, String)] {
        var result: [(String, String, String)] = []
        if selection.note {
            result.append(("\(bundle.book.name)_书摘", markdownNotes(bundle, settings), textNotes(bundle, settings)))
        }
        if selection.review, !bundle.reviews.isEmpty {
            result.append(("\(bundle.book.name)_书评", markdownReviews(bundle, settings), textReviews(bundle, settings)))
        }
        if selection.relevant, !bundle.related.isEmpty {
            result.append(("\(bundle.book.name)_相关", markdownRelated(bundle, settings), textRelated(bundle, settings)))
        }
        return result
    }

    static func bookMarkdown(_ book: DesktopWebBookSnapshot) -> String {
        func optionalLine(_ value: String, prefix: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(prefix)\(value)"
        }
        let lines = [
            "<center><img src=\"\(book.cover)\" width=\"135px\" height=\"200px\"> </center>",
            "<center><font size=4>《\(book.name)》</font></center>",
            "<center><font color='#6e6e6e' size=2>\(optionalLine(book.author, prefix: "作者："))</font></center>",
            "<center><font color='#6e6e6e' size=2>\(optionalLine(book.translator, prefix: "译者："))</font></center>",
            "<center><font color='#6e6e6e' size=2>\(optionalLine(book.press, prefix: "出版社："))</font></center>",
            "<center><font color='#6e6e6e' size=2>\(optionalLine(book.pubDate, prefix: "出版年："))</font></center>",
            "<center><font color='#6e6e6e' size=2>\(optionalLine(book.isbn, prefix: "ISBN："))</font></center>"
        ]
        return lines.joined(separator: "\n")
    }

    static func summaryMarkdown(_ book: DesktopWebBookSnapshot, settings: [String: Any]) -> String {
        guard settings.bool("includeBookInfo", fallback: true) else { return "" }
        var result = ""
        if !book.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "### 书籍简介\n\n\(book.summary)"
        }
        // Android 当前实现以 author 是否为空决定是否输出作者简介标题，而不是检查 authorIntro。
        if !book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !book.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result += "\n" }
            result += "### 作者简介\n\n\(book.authorIntro)"
        }
        return result
    }

    static func markdownNotes(_ bundle: DesktopWebExportBundle, _ settings: [String: Any]) -> String {
        var page = bookMarkdown(bundle.book)
        page += "\n"
        if !bundle.notes.isEmpty {
            page += "<center><font color='#6e6e6e' size=2>\(bundle.notes.count) 条书摘</font></center>"
        }
        page += "\n\n"
        let summary = summaryMarkdown(bundle.book, settings: settings)
        if !summary.isEmpty {
            page += summary
            page += "\n\n"
        }
        page += "---\n\n"
        var lastPath: [String] = []
        for (index, note) in bundle.notes.enumerated() {
            if let chapter = note.chapter {
                let path = normalizedChapterPath(chapter)
                let prefix = commonPrefixLength(lastPath, path)
                if prefix < path.count {
                    let headings = path.dropFirst(prefix).enumerated().map { offset, title in
                        "\(String(repeating: "#", count: min(6, prefix + offset + 2))) \(title)"
                    }.joined(separator: "\n")
                    if !headings.isEmpty { page += headings + "\n\n" }
                }
                if !path.isEmpty { lastPath = path }
            }
            let content = clearHTML(note.content)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                page += content.replacingOccurrences(of: "\n", with: "<br>") + "\n\n"
            }
            if let idea = note.idea.map(clearHTML),
               !idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                page += "> \(idea.replacingOccurrences(of: "\n", with: "<br>"))\n\n"
            }
            if !note.images.isEmpty {
                page += note.images.map { "<img src=\"\($0.url)\" width=\"160\" style=\"margin:14px\">" }.joined()
                page += "\n\n"
            }
            if settings.bool("includeTag", fallback: true), !note.tags.isEmpty {
                page += note.tags.map { "#\($0.name.replacingOccurrences(of: " ", with: ""))" }
                    .joined(separator: "  ")
                page += "\n\n"
            }
            let info = noteInfo(note, settings: settings)
            if !info.isEmpty { page += "<font color='#6e6e6e' size=2> \(info) </font>\n\n" }
            if index != bundle.notes.count - 1 { page += "---\n\n" }
        }
        return page
    }

    static func markdownReviews(_ bundle: DesktopWebExportBundle, _ settings: [String: Any]) -> String {
        var page = bookMarkdown(bundle.book) + "\n\n"
        let summary = summaryMarkdown(bundle.book, settings: settings)
        if !summary.isEmpty { page += summary + "\n\n" }
        page += "---\n\n"
        for (index, review) in bundle.reviews.enumerated() {
            if !review.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                page += "### \(review.title)\n\n"
            }
            let content = clearHTML(review.content)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                page += content.replacingOccurrences(of: "\n", with: "<br>") + "\n\n"
            }
            if !review.images.isEmpty {
                page += review.images.map { "<img src=\"\($0.url)\" width=\"160\" style=\"margin:14px\">" }.joined()
                page += "\n\n"
            }
            page += "<font color='#6e6e6e' size=2>\(dateText(review.createdTime))</font>\n\n"
            if index != bundle.reviews.count - 1 { page += "---\n\n" }
        }
        return page
    }

    static func markdownRelated(_ bundle: DesktopWebExportBundle, _ settings: [String: Any]) -> String {
        var page = bookMarkdown(bundle.book) + "\n\n"
        let summary = summaryMarkdown(bundle.book, settings: settings)
        if !summary.isEmpty { page += summary + "\n\n" }
        page += "---\n\n"
        var lastCategory = ""
        for (index, value) in bundle.related.enumerated() {
            if value.categoryTitle != lastCategory {
                page += "### \(value.categoryTitle)\n\n\n"
                lastCategory = value.categoryTitle
            }
            if let book = value.contentBook {
                page += relatedBookMarkdown(book) + "\n\n"
                page += "<font color='#6e6e6e' size=2>\(dateText(value.createdTime))</font>\n\n"
            } else {
                if !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    page += "#### \(value.title)\n\n"
                }
                let content = clearHTML(value.content)
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    page += content.replacingOccurrences(of: "\n", with: "<br>") + "\n\n"
                }
                if !value.images.isEmpty {
                    page += value.images.map { "<img src=\"\($0.url)\" width=\"160\" style=\"margin:14px\">" }.joined()
                    page += "\n\n"
                }
                if settings.bool("includeDateTime", fallback: true) {
                    page += "<font color='#6e6e6e' size=2>\(dateText(value.createdTime))</font>\n\n"
                }
            }
            if index != bundle.related.count - 1 { page += "---\n\n" }
        }
        return page
    }

    static func textNotes(_ bundle: DesktopWebExportBundle, _ settings: [String: Any]) -> String {
        var page = bookText(bundle.book)
        if settings.bool("includeBookInfo", fallback: true) { page += summaryText(bundle.book) }
        else { page += "\n" }
        page += "\(bundle.notes.count) 条书摘\n"
        page += "-------------------\n"
        var lastChapterID: Int64?
        for (index, note) in bundle.notes.enumerated() {
            if let chapter = note.chapter, chapter.id != lastChapterID {
                page += "\n【\(chapter.title)】\n\n"
                lastChapterID = chapter.id
            }
            let content = clearHTML(note.content)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { page += content + "\n" }
            if let idea = note.idea.map(clearHTML),
               !idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                page += "【想法】\(idea)\n"
            }
            if !note.images.isEmpty {
                page += "【附图】" + note.images.map(\.url).joined(separator: "\n") + "\n"
            }
            if settings.bool("includeTag", fallback: true), !note.tags.isEmpty {
                page += note.tags.map { "#\($0.name.replacingOccurrences(of: " ", with: ""))" }
                    .joined(separator: "  ") + "\n"
            }
            var info: [String] = []
            if let chapter = note.chapter {
                let path = chapter.pathTitles.isEmpty ? [chapter.title] : chapter.pathTitles
                let display = path.joined(separator: " / ")
                if !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { info.append(display) }
            }
            if settings.bool("includePage", fallback: true), let position = note.position,
               !position.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let unit = switch note.positionUnit { case 1: "页码"; case 3: "进度"; default: "位置" }
                info.append("\(unit)：\(position)\(note.positionUnit == 3 ? "%" : "")")
            }
            if settings.bool("includeDateTime", fallback: true), note.createdTime != 0, note.isIncludeTime {
                info.append(dateText(note.createdTime))
            }
            if !info.isEmpty { page += info.joined(separator: " | ") + "\n" }
            if index != bundle.notes.count - 1 { page += "-------------------\n" }
        }
        return page
    }

    static func textReviews(_ bundle: DesktopWebExportBundle, _ settings: [String: Any]) -> String {
        var page = bookText(bundle.book)
        if settings.bool("includeBookInfo", fallback: true) { page += summaryText(bundle.book) }
        else { page += "\n" }
        page += "-------------------\n"
        for (index, review) in bundle.reviews.enumerated() {
            if !review.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                page += "【标题】\(review.title)\n"
            }
            let content = clearHTML(review.content)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                page += "【内容】\(content)\n"
            }
            if !review.images.isEmpty {
                page += "【附图】" + review.images.map(\.url).joined(separator: "\n") + "\n"
            }
            if settings.bool("includeDateTime", fallback: true) { page += dateText(review.createdTime) + "\n" }
            if index != bundle.reviews.count - 1 { page += "-------------------\n" }
        }
        return page
    }

    static func textRelated(_ bundle: DesktopWebExportBundle, _ settings: [String: Any]) -> String {
        var page = bookText(bundle.book)
        if settings.bool("includeBookInfo", fallback: true) { page += summaryText(bundle.book) }
        else { page += "\n" }
        page += "-------------------\n"
        for (index, value) in bundle.related.enumerated() {
            if let book = value.contentBook {
                page += relatedBookText(book) + "\n"
            } else {
                if !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    page += "【标题】\(value.title)\n"
                }
                let content = clearHTML(value.content)
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    page += "【内容】\(content)\n"
                }
                if !value.images.isEmpty {
                    page += "【附图】" + value.images.map(\.url).joined(separator: "\n") + "\n"
                }
            }
            var info = [value.categoryTitle]
            if settings.bool("includeDateTime", fallback: true) { info.append(dateText(value.createdTime)) }
            page += info.joined(separator: " | ") + "\n"
            if index != bundle.related.count - 1 { page += "-------------------\n" }
        }
        return page
    }

    static func normalizedChapterPath(_ chapter: DesktopWebChapterSnapshot) -> [String] {
        let source = chapter.pathTitles.isEmpty ? [chapter.title] : chapter.pathTitles
        return source.compactMap { value in
            let collapsed = value.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? nil : collapsed
        }.prefix(5).map { $0 }
    }

    static func commonPrefixLength(_ lhs: [String], _ rhs: [String]) -> Int {
        var index = 0
        while index < min(lhs.count, rhs.count), lhs[index] == rhs[index] { index += 1 }
        return index
    }

    static func relatedBookMarkdown(_ book: DesktopWebRelatedBookSnapshot) -> String {
        let snapshot = DesktopWebBookSnapshot(
            id: book.id,
            name: book.name,
            rawName: book.name,
            cover: book.cover,
            author: book.author,
            authorIntro: "",
            translator: book.translator ?? "",
            summary: "",
            isbn: "",
            press: book.press,
            pubDate: book.publicationDate ?? "",
            doubanId: nil,
            readStatus: 0,
            readStatusChangedTime: 0,
            recentReadTime: nil,
            readDoneCount: 0,
            score: 0,
            readPosition: 0,
            totalPosition: 0,
            totalPagination: 0,
            currentPositionUnit: 0,
            positionUnit: 0,
            type: 0,
            sourceId: 0,
            sourceName: "",
            purchaseDate: nil,
            price: nil,
            isPinned: false,
            pinOrder: 0,
            order: 0,
            wordCount: nil,
            totalReadingTime: 0,
            createdTime: 0,
            updatedTime: 0,
            lastModifiedTime: nil,
            noteCount: 0,
            reviewCount: 0,
            relevantCount: 0,
            readDoneTime: nil,
            bookmarkModifiedTime: nil,
            groups: [],
            tags: [],
            isDeleted: book.isDeleted ?? false
        )
        return bookMarkdown(snapshot)
    }

    static func bookText(_ book: DesktopWebBookSnapshot) -> String {
        var result = ""
        if !book.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "《\(book.name)》\n"
        }
        if !book.cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "封面：\(book.cover)\n"
        }
        if !book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "作者：\(book.author.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if !book.translator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "译者：\(book.translator.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if !book.press.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "出版社：\(book.press.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if !book.pubDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "出版年：\(book.pubDate.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if !book.isbn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "ISBN：\(book.isbn)"
        }
        return result
    }

    static func summaryText(_ book: DesktopWebBookSnapshot) -> String {
        var result = ""
        if !book.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "\n\n书籍简介\n\(book.summary)"
        }
        if !book.authorIntro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "\n\n作者简介\n\(book.authorIntro)"
        }
        if !book.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !book.authorIntro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "\n\n"
        }
        return result
    }

    static func relatedBookText(_ book: DesktopWebRelatedBookSnapshot) -> String {
        var result = ""
        if !book.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "《\(book.name)》\n"
        }
        if !book.cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "封面：\(book.cover)\n"
        }
        if !book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "作者：\(book.author.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if let translator = book.translator,
           !translator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "译者：\(translator.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if !book.press.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "出版社：\(book.press.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if let publicationDate = book.publicationDate,
           !publicationDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "出版年：\(publicationDate.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        return result
    }

    static func noteInfo(_ note: DesktopWebBookNoteSnapshot, settings: [String: Any]) -> String {
        var items: [String] = []
        if settings.bool("includePage", fallback: true), let position = note.position, !position.isEmpty {
            let unit = switch note.positionUnit { case 1: "页码"; case 3: "进度"; default: "位置" }
            items.append("\(unit)：\(position)\(note.positionUnit == 3 ? "%" : "")")
        }
        if settings.bool("includeDateTime", fallback: true), note.createdTime != 0 {
            items.append(dateText(note.createdTime))
        }
        return items.joined(separator: " | ")
    }

    static func clearHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dateText(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    static func safeFileName(_ value: String, timestamp: String) -> String {
        let illegal = try? NSRegularExpression(pattern: "[:\\\\/*\\\"?|<>'']")
        let range = NSRange(value.startIndex..., in: value)
        let escaped = illegal?.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "_"
        ) ?? value
        let units = Array(escaped.utf16.prefix(65))
        let result = String(decoding: units, as: UTF16.self)
            + "_\(timestamp)"
        return result.isEmpty ? "导出文件" : result
    }

    static func sanitizeName(_ value: String) -> String {
        let result = value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "*", with: "-")
            .replacingOccurrences(of: "?", with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "导出文档" : result
    }

    static func makePDF(_ text: String) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842), format: format)
        return renderer.pdfData { context in
            let font = UIFont.preferredFont(forTextStyle: .body)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let lines = text.components(separatedBy: "\n")
            var y: CGFloat = 36
            context.beginPage()
            for line in lines {
                if y > 806 { context.beginPage(); y = 36 }
                line.draw(in: CGRect(x: 36, y: y, width: 523, height: 18), withAttributes: attributes)
                y += 18
            }
        }
    }

    private static func makeZIP(_ files: [GeneratedFile]) throws -> Data {
        let root = FileManager.default.temporaryDirectory.appending(path: "web_export_\(UUID().uuidString)")
        let archiveURL = root.appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .create)
        } catch {
            throw DesktopWebAPIError(code: 50001, message: "导出压缩包创建失败")
        }
        var used: [String: Int] = [:]
        for file in files {
            let count = used[file.name, default: 0]
            used[file.name] = count + 1
            let name: String
            if count == 0 { name = file.name }
            else {
                let ext = URL(fileURLWithPath: file.name).pathExtension
                let base = URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent
                name = "\(base)_\(count).\(ext)"
            }
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(file.data.count), provider: { position, size in
                file.data.subdata(in: Int(position)..<Int(position) + size)
            })
        }
        return try Data(contentsOf: archiveURL)
    }

    static func slug(_ value: String, timestamp: String, index: Int) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(normalized.isEmpty ? "xmnote" : normalized)-\(timestamp)-\(index)"
    }

    static func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values.keys.sorted().map { key in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let value = values[key] ?? ""
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    static func siYuanSort(_ item: [String: Any]) -> Int64 {
        let sort = (item["sort"] as? NSNumber)?.int64Value ?? 0
        guard sort == 0,
              let id = item["id"] as? String,
              id.split(separator: "-").count == 2,
              let prefix = Int64(id.split(separator: "-")[0]) else {
            return sort
        }
        return prefix
    }
}

private extension Dictionary where Key == String, Value == Any {
    nonisolated func string(_ key: String) -> String {
        (self[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated func bool(_ key: String, fallback: Bool) -> Bool {
        self[key] as? Bool ?? fallback
    }
}
