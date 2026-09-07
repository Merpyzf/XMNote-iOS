/**
 * [INPUT]: 依赖 DesktopWebExportRepository、DesktopWebSettingsRepository、URLSession、UIKit PDF 与 ZIPFoundation
 * [OUTPUT]: 对外提供思源/Obsidian 枚举、本地 PDF/Markdown/Text 下载和四类远端导出
 * [POS]: Infra 层 Web 导出编排；数据库只读由 Repository 承担，Package 不接触文件与网络实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation
import UIKit
import XMNoteWeb
import ZIPFoundation

/// 生成器的内存文件中间态；统一 Repository 会先写入专属临时目录，Desktop Web 再按兼容合同返回单文件或 ZIP。
nonisolated struct ExportGeneratedFile: Sendable {
    let name: String
    let data: Data
    let mediaType: String
}

/// 冻结快照远端导出的逐书结构化结果。
nonisolated struct ExportRemoteSnapshotResult: Sendable {
    let successCount: Int
    let failures: [ExportFailure]
}

/// 单次数据源分页查询得到的最小 Notion 托管页事实，供同一批书并发只读复用。
nonisolated struct NotionLibraryPageIndexEntry: Sendable {
    let pageID: String
    let pageURL: String
    let syncID: String
    let metadataFingerprint: String
    let contentFingerprint: String
    let title: String
    let syncStatus: String
    let lastEditedTime: String
    let isInTrash: Bool
}

/// 按稳定同步 ID 分组的不可变索引；重复页必须由调用方显式报错，不能任取其一。
nonisolated struct NotionLibraryPageIndex: Sendable {
    let pagesBySyncID: [String: [NotionLibraryPageIndexEntry]]

    static let empty = NotionLibraryPageIndex(pagesBySyncID: [:])

    func pages(syncID: String) -> [NotionLibraryPageIndexEntry] {
        pagesBySyncID[syncID] ?? []
    }
}

/// 托管页已被移入回收站时必须把重建权交还用户，普通重试不得隐式创建重复页面。
nonisolated struct NotionManagedPageRequiresRebuildError: LocalizedError, Sendable {
    let pageID: String

    var errorDescription: String? {
        "Notion 中的持续同步页面已被删除，请确认后重建"
    }
}

/// 为同一 Service 的全部 Notion 请求预留全局启动时隙，并在 401 刷新后替换尚未发出的旧 Authorization。
private actor NotionRequestCoordinator {
    private var nextStartTime = Date.distantPast.timeIntervalSinceReferenceDate
    private var activeAccessToken: String?

    /// 先预留 350ms 时隙再等待；actor 重入期间后续调用会继续排在已预留时隙之后，不会同时启动。
    func prepare(headers: [String: String]) async throws -> [String: String] {
        let now = Date().timeIntervalSinceReferenceDate
        let reservedStart = max(now, nextStartTime)
        nextStartTime = reservedStart + 0.35
        if reservedStart > now {
            try await Task.sleep(for: .milliseconds(Int64(((reservedStart - now) * 1_000).rounded(.up))))
        }
        var result = headers
        if let activeAccessToken,
           let authorizationKey = result.keys.first(where: {
               $0.caseInsensitiveCompare("Authorization") == .orderedSame
           }) {
            result[authorizationKey] = "Bearer \(activeAccessToken)"
        }
        return result
    }

    /// 发布一次成功轮换后的 Token；只驻留内存，持久化仍由 ExportCredentialStore actor 独占。
    func use(accessToken: String) {
        activeAccessToken = accessToken
    }
}

/// 导出没有共享可变任务；每次调用持有独立快照，取消会停止尚未开始的书籍或远端请求。
final class DesktopWebExportService: DesktopWebExportPort, @unchecked Sendable {
    private enum PreparedRemoteTarget {
        case yuQue(token: String, repositoryID: String)
        case notion(token: String, databaseID: String)
        case oneNote(token: String, sectionID: String)
        case siYuan(baseURL: String, token: String, notebookID: String)
        case obsidian(baseURL: String, apiKey: String, directory: String, session: URLSession)
    }

    private let repository: DesktopWebExportRepository
    private let notionSyncRepository: NotionExportSyncRepository?
    private let settingsRepository: DesktopWebSettingsRepository
    private let session: URLSession
    private let oneNoteAuthentication: any OneNoteAccessTokenProviding
    private let notionRequestCoordinator = NotionRequestCoordinator()
    private let notionTokenRefresher: @Sendable (String) async throws -> String
    private let obsidianSessionFactory: @Sendable (String, String) -> URLSession
    private let currentTimeMillis: @Sendable () -> Int64

    init(
        repository: DesktopWebExportRepository,
        notionSyncRepository: NotionExportSyncRepository? = nil,
        settingsRepository: DesktopWebSettingsRepository,
        session: URLSession = .shared,
        oneNoteAuthentication: any OneNoteAccessTokenProviding = OneNoteAuthenticationService(),
        notionTokenRefresher: @escaping @Sendable (String) async throws -> String = { _ in
            throw DesktopWebAPIError(code: 401, message: "Notion 授权已失效，请重新连接")
        },
        obsidianSessionFactory: @escaping @Sendable (String, String) -> URLSession = {
            ObsidianSecureSessionFactory.make(host: $0, pinnedCertificateSHA256: $1)
        },
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.repository = repository
        self.notionSyncRepository = notionSyncRepository
        self.settingsRepository = settingsRepository
        self.session = session
        self.oneNoteAuthentication = oneNoteAuthentication
        self.notionTokenRefresher = notionTokenRefresher
        self.obsidianSessionFactory = obsidianSessionFactory
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
        let secureSession = obsidianSessionFactory(
            ip,
            settings.string("obsidianPinnedCertificateSHA256")
        )
        try await validateObsidianServer(baseURL: "https://\(ip):27124", session: secureSession)
        let (data, response) = try await rawRequest(
            url: try requireURL("https://\(ip):27124/vault/"),
            method: "GET",
            headers: ["Authorization": "Bearer \(key)"],
            body: nil,
            using: secureSession
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
        var files: [ExportGeneratedFile] = []
        var fileNameAllocator = ExportFileNameAllocator()
        let settings = try await exportSettings()
        for id in ids {
            try Task.checkCancellation()
            let bundle = try await repository.bundle(
                bookID: id,
                includeReview: request.content.review,
                includeRelated: request.content.relevant
            )
            files.append(contentsOf: try generateFiles(
                bundle: bundle,
                target: target,
                selection: request.content,
                settings: settings,
                fileNameAllocator: &fileNameAllocator
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

    /// 从 Repository 已冻结的完整快照生成本地文件；该入口不再访问数据库或可变设置。
    func generateLocalFiles(
        snapshot: ExportSnapshot,
        target: ExportTarget,
        settings: ExportSettingsSnapshot,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) throws -> [ExportGeneratedFile] {
        guard [.markdown, .text, .pdf].contains(target) else { return [] }
        let selection = DesktopWebExportContentSelection(
            note: settings.content.includesNotes,
            relevant: settings.content.includesRelatedNotes,
            review: settings.content.includesReviews
        )
        var rawSettings = Self.dictionary(
            from: settings,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
        rawSettings["_localeIdentifier"] = localeIdentifier
        rawSettings["_timeZoneIdentifier"] = timeZoneIdentifier
        var allocator = ExportFileNameAllocator()
        var files: [ExportGeneratedFile] = []
        for value in snapshot.books {
            try Task.checkCancellation()
            let bundle = DesktopWebExportBundle(
                book: value.book,
                notes: value.notes,
                reviews: value.reviews,
                related: value.relatedNotes
            )
            files.append(contentsOf: try generateFiles(
                bundle: bundle,
                target: target.desktopWebIdentifier,
                selection: selection,
                settings: rawSettings,
                fileNameAllocator: &allocator
            ))
        }
        return files
    }

    /// 使用 Repository 冻结的数据库、设置和凭据快照逐书写入远端，不在循环中回访数据库或 UserDefaults。
    func exportSnapshotRemotely(
        _ snapshot: ExportSnapshot,
        request: ExportRequest,
        credential: ExportCredentialSnapshot,
        progress: @escaping @Sendable (Int, Int, String) -> Void
    ) async throws -> ExportRemoteSnapshotResult {
        var rawSettings = Self.dictionary(
            from: request.settings,
            localeIdentifier: request.localeIdentifier,
            timeZoneIdentifier: request.timeZoneIdentifier
        )
        rawSettings["yuqueToken"] = credential.yuqueToken
        rawSettings["notionToken"] = credential.notionAccessToken
        rawSettings["notionDataSourceId"] = request.settings.notionDataSourceID
        rawSettings["siyuanIp"] = request.settings.siYuanHost
        rawSettings["siyuanPort"] = String(request.settings.siYuanPort)
        rawSettings["siyuanToken"] = credential.siYuanToken
        rawSettings["siyuanNotebookId"] = request.settings.siYuanNotebookID
        rawSettings["obsidianIp"] = request.settings.obsidianHost
        rawSettings["obsidianApiKey"] = credential.obsidianAPIKey
        rawSettings["obsidianDirName"] = request.settings.obsidianDirectory
        rawSettings["obsidianPinnedCertificateSHA256"] = request.settings.obsidianPinnedCertificateSHA256

        let preparedTarget: PreparedRemoteTarget
        var notionPageIndex = NotionLibraryPageIndex.empty
        switch request.target {
        case .yuque:
            guard !credential.yuqueToken.isEmpty else {
                throw DesktopWebAPIError(code: 40_001, message: "缺少语雀 Token，请先连接语雀")
            }
            preparedTarget = .yuQue(
                token: credential.yuqueToken,
                repositoryID: try await ensureYuQueRepositoryID(token: credential.yuqueToken)
            )
        case .notion:
            guard !credential.notionAccessToken.isEmpty else {
                throw DesktopWebAPIError(code: 40_001, message: "请先通过 OAuth 连接 Notion")
            }
            guard !request.settings.notionDataSourceID.isEmpty else {
                throw DesktopWebAPIError(code: 40_001, message: "请先选择 Notion 数据源")
            }
            preparedTarget = .notion(
                token: credential.notionAccessToken,
                databaseID: request.settings.notionDataSourceID
            )
            notionPageIndex = try await queryNotionLibraryPageIndex(
                token: credential.notionAccessToken,
                dataSourceID: request.settings.notionDataSourceID
            )
        case .oneNote:
            let token = try await oneNoteAuthentication.accessToken()
            let sectionID = try await ensureOneNoteSectionID(
                token: token,
                sectionName: request.settings.oneNoteSectionName
            )
            preparedTarget = .oneNote(token: token, sectionID: sectionID)
        case .siYuan:
            guard !request.settings.siYuanHost.isEmpty else {
                throw DesktopWebAPIError(code: 40_001, message: "缺少思源 IP 地址")
            }
            guard !request.settings.siYuanNotebookID.isEmpty else {
                throw DesktopWebAPIError(code: 40_001, message: "请先选择思源笔记本")
            }
            preparedTarget = .siYuan(
                baseURL: "http://\(request.settings.siYuanHost):\(request.settings.siYuanPort)",
                token: credential.siYuanToken,
                notebookID: request.settings.siYuanNotebookID
            )
        case .obsidian:
            guard !request.settings.obsidianHost.isEmpty, !credential.obsidianAPIKey.isEmpty else {
                throw DesktopWebAPIError(code: 40_001, message: "请先配置 Obsidian Local REST API")
            }
            let baseURL = "https://\(request.settings.obsidianHost):27124"
            let secureSession = obsidianSessionFactory(
                request.settings.obsidianHost,
                request.settings.obsidianPinnedCertificateSHA256
            )
            try await validateObsidianServer(baseURL: baseURL, session: secureSession)
            preparedTarget = .obsidian(
                baseURL: baseURL,
                apiKey: credential.obsidianAPIKey,
                directory: request.settings.obsidianDirectory,
                session: secureSession
            )
        case .pdf, .markdown, .text, .csv:
            throw DesktopWebAPIError(code: 40_001, message: "本地目标不能执行远端导出")
        }

        let selection = DesktopWebExportContentSelection(
            note: request.settings.content.includesNotes,
            relevant: request.settings.content.includesRelatedNotes,
            review: request.settings.content.includesReviews
        )
        if request.target == .notion {
            return try await exportNotionBooksConcurrently(
                snapshot.books,
                preparedTarget: preparedTarget,
                selection: selection,
                settings: rawSettings,
                request: request,
                credential: credential,
                pageIndex: notionPageIndex,
                progress: progress
            )
        }

        var failures: [ExportFailure] = []
        var successCount = 0
        for (index, value) in snapshot.books.enumerated() {
            if let failure = try await exportSnapshotBook(
                value,
                preparedTarget: preparedTarget,
                selection: selection,
                settings: rawSettings,
                request: request,
                credential: credential
            ) {
                failures.append(failure)
            } else {
                successCount += 1
            }
            progress(index + 1, snapshot.books.count, "已处理 \(index + 1)/\(snapshot.books.count) 本")
        }
        return ExportRemoteSnapshotResult(successCount: successCount, failures: failures)
    }

    /// Notion 最多并发三本，每本内部仍严格串行；父任务统一归并结果和进度，避免跨任务共享可变数组。
    private func exportNotionBooksConcurrently(
        _ books: [ExportBookSnapshot],
        preparedTarget: PreparedRemoteTarget,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any],
        request: ExportRequest,
        credential: ExportCredentialSnapshot,
        pageIndex: NotionLibraryPageIndex,
        progress: @escaping @Sendable (Int, Int, String) -> Void
    ) async throws -> ExportRemoteSnapshotResult {
        try await withThrowingTaskGroup(
            of: (Int, ExportFailure?).self,
            returning: ExportRemoteSnapshotResult.self
        ) { group in
            var nextIndex = 0
            let initialCount = min(3, books.count)
            for _ in 0..<initialCount {
                let index = nextIndex
                nextIndex += 1
                group.addTask { [self] in
                    (
                        index,
                        try await exportSnapshotBook(
                            books[index],
                            preparedTarget: preparedTarget,
                            selection: selection,
                            settings: settings,
                            request: request,
                            credential: credential,
                            pageIndex: pageIndex
                        )
                    )
                }
            }

            var completed = 0
            var successCount = 0
            var indexedFailures: [(Int, ExportFailure)] = []
            while let (index, failure) = try await group.next() {
                completed += 1
                if let failure {
                    indexedFailures.append((index, failure))
                } else {
                    successCount += 1
                }
                progress(completed, books.count, "已处理 \(completed)/\(books.count) 本")
                if nextIndex < books.count {
                    let scheduledIndex = nextIndex
                    nextIndex += 1
                    group.addTask { [self] in
                        (
                            scheduledIndex,
                            try await exportSnapshotBook(
                                books[scheduledIndex],
                                preparedTarget: preparedTarget,
                                selection: selection,
                                settings: settings,
                                request: request,
                                credential: credential,
                                pageIndex: pageIndex
                            )
                        )
                    }
                }
            }
            return ExportRemoteSnapshotResult(
                successCount: successCount,
                failures: indexedFailures.sorted { $0.0 < $1.0 }.map(\.1)
            )
        }
    }

    /// 执行单本远端写入并转换为结构化失败；取消继续向上冒泡，不被误记为普通单书失败。
    private func exportSnapshotBook(
        _ value: ExportBookSnapshot,
        preparedTarget: PreparedRemoteTarget,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any],
        request: ExportRequest,
        credential: ExportCredentialSnapshot,
        pageIndex: NotionLibraryPageIndex = .empty
    ) async throws -> ExportFailure? {
        do {
            try Task.checkCancellation()
            if request.kind == .bookInformation {
                try await uploadRemoteBookInformation(
                    preparedTarget: preparedTarget,
                    book: value.book,
                    request: request,
                    credential: credential,
                    pageIndex: pageIndex
                )
            } else if request.target == .notion {
                try await uploadManagedNotionBook(
                    preparedTarget: preparedTarget,
                    snapshot: value,
                    selection: selection,
                    settings: settings,
                    request: request,
                    credential: credential,
                    pageIndex: pageIndex
                )
            } else {
                try await uploadRemoteBook(
                    preparedTarget: preparedTarget,
                    bundle: DesktopWebExportBundle(
                        book: value.book,
                        notes: value.notes,
                        reviews: value.reviews,
                        related: value.relatedNotes
                    ),
                    selection: selection,
                    settings: settings
                )
            }
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let recoveryAction: ExportRecoveryAction? = error is NotionManagedPageRequiresRebuildError
                ? .confirmNotionPageRebuild
                : nil
            return ExportFailure(
                bookID: value.book.id,
                bookName: value.book.name,
                target: request.target,
                message: error.localizedDescription.isEmpty ? "导出失败" : error.localizedDescription,
                disposition: Self.failureDisposition(error, target: request.target),
                recoveryAction: recoveryAction
            )
        }
    }

    /// 将书籍信息写入已选 Notion data source；其他远端目标在领域预检阶段即被拒绝。
    private func uploadRemoteBookInformation(
        preparedTarget: PreparedRemoteTarget,
        book: DesktopWebBookSnapshot,
        request: ExportRequest,
        credential: ExportCredentialSnapshot,
        pageIndex: NotionLibraryPageIndex
    ) async throws {
        guard case let .notion(token, databaseID) = preparedTarget else {
            throw DesktopWebAPIError(code: 40_001, message: "书籍信息远端导出仅支持 Notion")
        }
        guard let notionSyncRepository,
              !credential.notionConnectionKey.isEmpty,
              !credential.notionDataInstanceID.isEmpty else {
            throw DesktopWebAPIError(code: 40_001, message: "Notion 连接信息不完整，请重新连接")
        }
        let syncID = "\(credential.notionDataInstanceID):\(book.id)"
        let baseBody = ExportNotionBookGenerator.pageBody(
            book: book,
            fields: request.settings.bookFields,
            localeIdentifier: request.localeIdentifier,
            timeZoneIdentifier: request.timeZoneIdentifier
        )
        let fingerprint = try Self.notionFingerprint(baseBody)
        var existing = try await notionSyncRepository.findPage(
            connectionKey: credential.notionConnectionKey,
            dataSourceID: databaseID,
            bookID: book.id
        )
        let indexedPages = pageIndex.pages(syncID: syncID)
        guard indexedPages.count <= 1 else {
            throw DesktopWebAPIError(
                code: 40_011,
                message: "Notion 中存在 \(indexedPages.count) 个相同同步页面，请保留一页后重试"
            )
        }
        var indexedPage = indexedPages.first
        var resolvedRemote: NotionLibraryPageIndexEntry?
        if let local = existing {
            if let indexedPage,
               Self.normalizedNotionID(indexedPage.pageID) == Self.normalizedNotionID(local.pageId) {
                resolvedRemote = indexedPage
            } else {
                resolvedRemote = try await retrieveNotionIndexEntry(
                    token: token,
                    pageID: local.pageId,
                    fallback: local
                )
            }
            if resolvedRemote?.isInTrash == true {
                guard request.confirmedNotionPageRebuildBookIDs.contains(book.id) else {
                    throw NotionManagedPageRequiresRebuildError(pageID: local.pageId)
                }
                if let localID = local.id { try await notionSyncRepository.deletePage(id: localID) }
                existing = nil
                indexedPage = nil
                resolvedRemote = nil
            }
        } else if let remote = indexedPage {
            if remote.isInTrash {
                guard request.confirmedNotionPageRebuildBookIDs.contains(book.id) else {
                    throw NotionManagedPageRequiresRebuildError(pageID: remote.pageID)
                }
                indexedPage = nil
            } else {
                var recovered = NotionPageSyncRecord(
                    id: nil,
                    connectionKey: credential.notionConnectionKey,
                    dataSourceId: databaseID,
                    bookId: book.id,
                    syncId: syncID,
                    pageId: remote.pageID,
                    pageUrl: remote.pageURL,
                    status: remote.syncStatus.isEmpty ? "已同步" : remote.syncStatus,
                    conflictCount: 0,
                    firstSyncDate: request.nowMilliseconds,
                    lastSyncDate: request.nowMilliseconds,
                    metadataFingerprint: remote.metadataFingerprint,
                    contentFingerprint: remote.contentFingerprint,
                    remoteLastEditedTime: remote.lastEditedTime,
                    lastExportedTitle: remote.title
                )
                recovered.id = try await notionSyncRepository.insertRecoveredPage(
                    recovered,
                    recoveredBlock: nil
                )
                existing = recovered
                resolvedRemote = remote
            }
        }
        let firstSync = existing?.firstSyncDate ?? request.nowMilliseconds
        var body = ExportNotionBookGenerator.applyingSyncState(
            to: baseBody,
            syncID: syncID,
            metadataFingerprint: fingerprint,
            contentFingerprint: resolvedRemote?.contentFingerprint.isEmpty == false
                ? resolvedRemote!.contentFingerprint
                : existing?.contentFingerprint ?? "",
            firstSyncMilliseconds: firstSync,
            lastSyncMilliseconds: request.nowMilliseconds,
            conflictCount: existing?.conflictCount ?? 0,
            localeIdentifier: request.localeIdentifier,
            timeZoneIdentifier: request.timeZoneIdentifier
        )

        let response: [String: Any]
        if let existing {
            let remoteMetadataFingerprint = resolvedRemote?.metadataFingerprint.isEmpty == false
                ? resolvedRemote!.metadataFingerprint
                : existing.metadataFingerprint
            if remoteMetadataFingerprint == fingerprint {
                var unchanged = existing
                unchanged.pageUrl = resolvedRemote?.pageURL.isEmpty == false
                    ? resolvedRemote!.pageURL
                    : existing.pageUrl
                unchanged.remoteLastEditedTime = resolvedRemote?.lastEditedTime.isEmpty == false
                    ? resolvedRemote!.lastEditedTime
                    : existing.remoteLastEditedTime
                unchanged.metadataFingerprint = fingerprint
                unchanged.contentFingerprint = resolvedRemote?.contentFingerprint.isEmpty == false
                    ? resolvedRemote!.contentFingerprint
                    : existing.contentFingerprint
                unchanged.status = "已同步"
                try await notionSyncRepository.updatePage(unchanged)
                return
            }
            response = try await requestJSON(
                url: try requireURL("https://api.notion.com/v1/pages/\(existing.pageId)"),
                method: "PATCH",
                headers: Self.notionHeaders(token: token),
                body: try JSONSerialization.data(withJSONObject: body)
            )
            try await notionSyncRepository.updatePage(
                NotionPageSyncRecord(
                    id: existing.id,
                    connectionKey: existing.connectionKey,
                    dataSourceId: existing.dataSourceId,
                    bookId: existing.bookId,
                    syncId: syncID,
                    pageId: existing.pageId,
                    pageUrl: response["url"] as? String ?? existing.pageUrl,
                    status: "已同步",
                    conflictCount: existing.conflictCount,
                    firstSyncDate: existing.firstSyncDate,
                    lastSyncDate: request.nowMilliseconds,
                    metadataFingerprint: fingerprint,
                    contentFingerprint: existing.contentFingerprint,
                    remoteLastEditedTime: response["last_edited_time"] as? String ?? existing.remoteLastEditedTime,
                    lastExportedTitle: book.name
                )
            )
        } else {
            body["parent"] = [
                "type": "data_source_id",
                "data_source_id": databaseID
            ]
            response = try await requestJSON(
                url: try requireURL("https://api.notion.com/v1/pages"),
                method: "POST",
                headers: Self.notionHeaders(token: token),
                body: try JSONSerialization.data(withJSONObject: body)
            )
            guard let pageID = response["id"] as? String, !pageID.isEmpty else {
                throw DesktopWebAPIError(code: 400, message: "Notion 页面创建成功状态无法确认")
            }
            _ = try await notionSyncRepository.insertPage(
                NotionPageSyncRecord(
                    id: nil,
                    connectionKey: credential.notionConnectionKey,
                    dataSourceId: databaseID,
                    bookId: book.id,
                    syncId: syncID,
                    pageId: pageID,
                    pageUrl: response["url"] as? String ?? "",
                    status: "已同步",
                    conflictCount: 0,
                    firstSyncDate: request.nowMilliseconds,
                    lastSyncDate: request.nowMilliseconds,
                    metadataFingerprint: fingerprint,
                    contentFingerprint: "",
                    remoteLastEditedTime: response["last_edited_time"] as? String ?? "",
                    lastExportedTitle: book.name
                )
            )
        }
    }

    /// 将一本书写入单个 Notion 托管页面；远端每批写入前先落恢复日志，成功后才切换正式 Block 映射。
    private func uploadManagedNotionBook(
        preparedTarget: PreparedRemoteTarget,
        snapshot: ExportBookSnapshot,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any],
        request: ExportRequest,
        credential: ExportCredentialSnapshot,
        pageIndex: NotionLibraryPageIndex
    ) async throws {
        guard case let .notion(token, dataSourceID) = preparedTarget,
              let notionSyncRepository,
              !credential.notionConnectionKey.isEmpty,
              !credential.notionDataInstanceID.isEmpty else {
            throw DesktopWebAPIError(code: 40_001, message: "Notion 连接信息不完整，请重新连接")
        }

        let syncID = "\(credential.notionDataInstanceID):\(snapshot.book.id)"
        let managedDraft = DesktopWebNotionExportGenerator.managedPageDraft(
            snapshot: snapshot,
            selection: selection,
            settings: settings
        )
        var generated = managedDraft.body
        generated.removeValue(forKey: "children")
        let children = managedDraft.children
        let contentFingerprint = try Self.notionFingerprint(["children": children])
        let metadataBase = ExportNotionBookGenerator.pageBody(
            book: snapshot.book,
            fields: request.settings.bookFields,
            localeIdentifier: request.localeIdentifier,
            timeZoneIdentifier: request.timeZoneIdentifier
        )
        let metadataFingerprint = try Self.notionFingerprint(metadataBase)
        var page = try await notionSyncRepository.findPage(
            connectionKey: credential.notionConnectionKey,
            dataSourceID: dataSourceID,
            bookID: snapshot.book.id
        )

        let indexedPages = pageIndex.pages(syncID: syncID)
        guard indexedPages.count <= 1 else {
            throw DesktopWebAPIError(
                code: 40_011,
                message: "Notion 中存在 \(indexedPages.count) 个相同同步页面，请保留一页后重试"
            )
        }
        let indexedPage = indexedPages.first
        var resolvedRemote: NotionLibraryPageIndexEntry?
        if var local = page {
            if let indexedPage,
               Self.normalizedNotionID(indexedPage.pageID) == Self.normalizedNotionID(local.pageId) {
                resolvedRemote = indexedPage
            } else {
                do {
                    resolvedRemote = try await retrieveNotionIndexEntry(
                        token: token,
                        pageID: local.pageId,
                        fallback: local
                    )
                } catch is NotionManagedPageRequiresRebuildError {
                    guard request.confirmedNotionPageRebuildBookIDs.contains(snapshot.book.id) else {
                        throw NotionManagedPageRequiresRebuildError(pageID: local.pageId)
                    }
                    if let localID = local.id { try await notionSyncRepository.deletePage(id: localID) }
                    page = nil
                }
            }
            if let remote = resolvedRemote, remote.isInTrash {
                guard request.confirmedNotionPageRebuildBookIDs.contains(snapshot.book.id) else {
                    throw NotionManagedPageRequiresRebuildError(pageID: local.pageId)
                }
                if let localID = local.id { try await notionSyncRepository.deletePage(id: localID) }
                page = nil
                resolvedRemote = nil
            } else if let remote = resolvedRemote, page != nil {
                local.pageUrl = remote.pageURL.isEmpty ? local.pageUrl : remote.pageURL
                local.status = remote.syncStatus.isEmpty ? local.status : remote.syncStatus
                page = local
                try await notionSyncRepository.updatePage(local)
            }
        } else if let remote = indexedPage {
            if remote.isInTrash {
                guard request.confirmedNotionPageRebuildBookIDs.contains(snapshot.book.id) else {
                    throw NotionManagedPageRequiresRebuildError(pageID: remote.pageID)
                }
            } else {
                guard remote.contentFingerprint == contentFingerprint else {
                    throw DesktopWebAPIError(
                        code: 40_010,
                        message: "已找到持续同步页面，但远端内容与本次快照不一致，本次未覆盖正文"
                    )
                }
                let blockIDs = try await notionTopLevelBlockIDs(token: token, pageID: remote.pageID)
                var recovered = NotionPageSyncRecord(
                    id: nil,
                    connectionKey: credential.notionConnectionKey,
                    dataSourceId: dataSourceID,
                    bookId: snapshot.book.id,
                    syncId: syncID,
                    pageId: remote.pageID,
                    pageUrl: remote.pageURL,
                    status: remote.syncStatus.isEmpty ? "已同步" : remote.syncStatus,
                    conflictCount: 0,
                    firstSyncDate: request.nowMilliseconds,
                    lastSyncDate: request.nowMilliseconds,
                    metadataFingerprint: remote.metadataFingerprint,
                    contentFingerprint: remote.contentFingerprint,
                    remoteLastEditedTime: remote.lastEditedTime,
                    lastExportedTitle: remote.title
                )
                let blocks = try Self.recoveredNotionUnitBlocks(
                    pageSyncID: 0,
                    units: managedDraft.units,
                    blockIDs: blockIDs,
                    nowMilliseconds: request.nowMilliseconds
                )
                recovered.id = try await notionSyncRepository.insertRecoveredPage(
                    recovered,
                    recoveredBlocks: blocks
                )
                page = recovered
                resolvedRemote = remote
            }
        }

        if var existing = page {
            if let pageSyncID = existing.id,
               try await notionSyncRepository.blocks(pageSyncID: pageSyncID).isEmpty,
               existing.contentFingerprint == contentFingerprint {
                let blockIDs = try await notionTopLevelBlockIDs(token: token, pageID: existing.pageId)
                let recoveredBlocks = try Self.recoveredNotionUnitBlocks(
                    pageSyncID: pageSyncID,
                    units: managedDraft.units,
                    blockIDs: blockIDs,
                    nowMilliseconds: request.nowMilliseconds
                )
                try await notionSyncRepository.replaceRecoveredBlockMappings(recoveredBlocks)
            }
            try await synchronizeManagedNotionUnits(
                draft: managedDraft,
                page: &existing,
                remote: resolvedRemote,
                token: token,
                repository: notionSyncRepository,
                metadataBase: metadataBase,
                metadataFingerprint: metadataFingerprint,
                contentFingerprint: contentFingerprint,
                generatedPageFields: generated,
                request: request
            )
            return
        }

        var metadata = ExportNotionBookGenerator.applyingSyncState(
            to: metadataBase,
            syncID: syncID,
            metadataFingerprint: metadataFingerprint,
            contentFingerprint: contentFingerprint,
            firstSyncMilliseconds: request.nowMilliseconds,
            lastSyncMilliseconds: request.nowMilliseconds,
            conflictCount: 0,
            localeIdentifier: request.localeIdentifier,
            timeZoneIdentifier: request.timeZoneIdentifier
        )
        metadata["parent"] = ["type": "data_source_id", "data_source_id": dataSourceID]
        metadata["icon"] = generated["icon"]
        metadata["cover"] = generated["cover"]
        let created = try await requestJSON(
            url: try requireURL("https://api.notion.com/v1/pages"),
            method: "POST",
            headers: Self.notionHeaders(token: token),
            body: try JSONSerialization.data(withJSONObject: metadata)
        )
        guard let pageID = created["id"] as? String, !pageID.isEmpty else {
            throw DesktopWebAPIError(code: 400, message: "Notion 页面创建结果不确定，请先检查远端")
        }
        var createdPage = NotionPageSyncRecord(
            id: nil,
            connectionKey: credential.notionConnectionKey,
            dataSourceId: dataSourceID,
            bookId: snapshot.book.id,
            syncId: syncID,
            pageId: pageID,
            pageUrl: created["url"] as? String ?? "",
            status: "有内容未同步",
            conflictCount: 0,
            firstSyncDate: request.nowMilliseconds,
            lastSyncDate: request.nowMilliseconds,
            metadataFingerprint: metadataFingerprint,
            contentFingerprint: "",
            remoteLastEditedTime: created["last_edited_time"] as? String ?? "",
            lastExportedTitle: snapshot.book.name
        )
        createdPage.id = try await notionSyncRepository.insertPage(createdPage)
        try await synchronizeManagedNotionUnits(
            draft: managedDraft,
            page: &createdPage,
            remote: nil,
            token: token,
            repository: notionSyncRepository,
            metadataBase: metadataBase,
            metadataFingerprint: metadataFingerprint,
            contentFingerprint: contentFingerprint,
            generatedPageFields: generated,
            request: request
        )
    }

    /// 对每个 Android v45 内容单元独立执行新增、替换、远端删除尊重与人工编辑冲突保留。
    private func synchronizeManagedNotionUnits(
        draft: DesktopWebNotionManagedPageDraft,
        page: inout NotionPageSyncRecord,
        remote: NotionLibraryPageIndexEntry?,
        token: String,
        repository: NotionExportSyncRepository,
        metadataBase: [String: Any],
        metadataFingerprint: String,
        contentFingerprint: String,
        generatedPageFields: [String: Any],
        request: ExportRequest
    ) async throws {
        guard let pageSyncID = page.id else {
            throw DesktopWebAPIError(code: 500, message: "Notion 页面本地映射缺少主键")
        }

        var mappings = Dictionary(
            uniqueKeysWithValues: try await repository.blocks(pageSyncID: pageSyncID).map { ($0.unitKey, $0) }
        )
        if let legacy = mappings["page_content"], page.contentFingerprint == contentFingerprint {
            let blockIDs = try Self.jsonStringArray(legacy.blockIdsJson)
            let recovered = try Self.recoveredNotionUnitBlocks(
                pageSyncID: pageSyncID,
                units: draft.units,
                blockIDs: blockIDs,
                nowMilliseconds: request.nowMilliseconds
            )
            try await repository.replaceRecoveredBlockMappings(recovered)
            mappings = Dictionary(uniqueKeysWithValues: recovered.map { ($0.unitKey, $0) })
        }

        let pending = try await repository.operations(pageSyncID: pageSyncID)
        for operation in pending where operation.operationType != "page_metadata_commit" {
            if operation.operationType == "preserve_deleted_record" {
                let markerIDs = try Self.jsonStringArray(operation.newBlockIdsJson)
                guard operation.state == "new_blocks_written",
                      markerIDs.count == Self.notionConflictMarkerCount,
                      let mapping = mappings[operation.unitKey],
                      let mappingID = mapping.id else {
                    throw DesktopWebAPIError(
                        code: 40_012,
                        message: "Notion 删除冲突写入结果不确定，请先检查远端后再继续"
                    )
                }
                try await repository.completePreservedDeletion(
                    operationID: operation.operationId,
                    pageSyncID: pageSyncID,
                    oldBlockID: mappingID
                )
                mappings.removeValue(forKey: operation.unitKey)
                page.conflictCount += 1
                continue
            }
            guard let unit = draft.units.first(where: { $0.key == operation.unitKey }) else {
                throw DesktopWebAPIError(
                    code: 40_010,
                    message: "Notion 存在无法关联当前快照的恢复操作，本次未继续写入"
                )
            }
            let oldMapping = mappings[unit.key]
            let resumed = try await continueNotionUnitOperation(
                operation,
                unit: unit,
                page: page,
                token: token,
                repository: repository,
                oldMapping: oldMapping,
                afterBlockID: nil,
                nowMilliseconds: request.nowMilliseconds
            )
            mappings[unit.key] = resumed
            if operation.operationType == "conflict_copy" { page.conflictCount += 1 }
        }

        let remoteChanged = remote.map {
            page.remoteLastEditedTime.isEmpty ||
                $0.lastEditedTime.isEmpty ||
                page.remoteLastEditedTime != $0.lastEditedTime
        } ?? false
        let remoteBlocks = remoteChanged
            ? try await notionTopLevelBlocks(token: token, pageID: page.pageId)
            : []
        let remoteBlocksByID = Dictionary(
            uniqueKeysWithValues: remoteBlocks.compactMap { block -> (String, [String: Any])? in
                guard let id = block["id"] as? String else { return nil }
                return (Self.normalizedNotionID(id), block)
            }
        )

        for (index, unit) in draft.units.enumerated() {
            try Task.checkCancellation()
            let sourceFingerprint = try Self.notionBlockFingerprint(
                unit.blocks,
                normalizingVolatileMediaURLs: true
            )
            guard var existing = mappings[unit.key] else {
                let inserted = try await performNotionUnitOperation(
                    type: "add",
                    unit: unit,
                    sourceFingerprint: sourceFingerprint,
                    page: page,
                    oldMapping: nil,
                    preservesOld: false,
                    afterBlockID: Self.previousManagedBlockID(
                        before: index,
                        units: draft.units,
                        mappings: mappings
                    ),
                    token: token,
                    repository: repository,
                    localeIdentifier: request.localeIdentifier,
                    timeZoneIdentifier: request.timeZoneIdentifier,
                    nowMilliseconds: request.nowMilliseconds
                )
                mappings[unit.key] = inserted
                continue
            }

            if !remoteChanged {
                if existing.state == "notion_deleted" {
                    existing.sourceFingerprint = sourceFingerprint
                    existing.sourceUpdatedDate = unit.sourceUpdatedAtMilliseconds
                    existing.lastSyncDate = request.nowMilliseconds
                    _ = try await repository.upsertBlock(existing)
                    mappings[unit.key] = existing
                } else if existing.sourceFingerprint != sourceFingerprint {
                    let replacement = try await performNotionUnitOperation(
                        type: "replace",
                        unit: unit,
                        sourceFingerprint: sourceFingerprint,
                        page: page,
                        oldMapping: existing,
                        preservesOld: false,
                        afterBlockID: try Self.jsonStringArray(existing.blockIdsJson).last,
                        token: token,
                        repository: repository,
                        localeIdentifier: request.localeIdentifier,
                        timeZoneIdentifier: request.timeZoneIdentifier,
                        nowMilliseconds: request.nowMilliseconds
                    )
                    mappings[unit.key] = replacement
                }
                continue
            }

            guard let mappedRemoteBlocks = try Self.remoteBlocks(
                for: existing,
                blocksByID: remoteBlocksByID
            ) else {
                existing.sourceFingerprint = sourceFingerprint
                existing.sourceUpdatedDate = unit.sourceUpdatedAtMilliseconds
                existing.state = "notion_deleted"
                existing.lastSyncDate = request.nowMilliseconds
                _ = try await repository.upsertBlock(existing)
                mappings[unit.key] = existing
                continue
            }
            let remoteFingerprint = try Self.notionBlockFingerprint(
                mappedRemoteBlocks,
                normalizingVolatileMediaURLs: false
            )
            if existing.sourceFingerprint == sourceFingerprint {
                if existing.state == "notion_deleted" {
                    existing.state = "managed"
                    existing.remoteFingerprint = remoteFingerprint
                    existing.lastSyncDate = request.nowMilliseconds
                    _ = try await repository.upsertBlock(existing)
                    mappings[unit.key] = existing
                }
                continue
            }

            let preservesOld = remoteFingerprint != existing.remoteFingerprint && unit.isUserRecord
            let replacement = try await performNotionUnitOperation(
                type: preservesOld ? "conflict_copy" : "replace",
                unit: unit,
                sourceFingerprint: sourceFingerprint,
                page: page,
                oldMapping: existing,
                preservesOld: preservesOld,
                afterBlockID: try Self.jsonStringArray(existing.blockIdsJson).last,
                token: token,
                repository: repository,
                localeIdentifier: request.localeIdentifier,
                timeZoneIdentifier: request.timeZoneIdentifier,
                nowMilliseconds: request.nowMilliseconds
            )
            mappings[unit.key] = replacement
            if preservesOld { page.conflictCount += 1 }
        }

        let currentKeys = Set(draft.units.map(\.key))
        for existing in mappings.values where
            existing.deletable &&
            !currentKeys.contains(existing.unitKey) &&
            draft.selectedContentTypes.contains(existing.contentType) {
            let mappedRemoteBlocks = remoteChanged
                ? try Self.remoteBlocks(for: existing, blocksByID: remoteBlocksByID)
                : []
            if mappedRemoteBlocks == nil {
                if let id = existing.id { try await repository.deleteBlock(id: id) }
                continue
            }
            let remoteFingerprint = try mappedRemoteBlocks.map {
                try Self.notionBlockFingerprint($0, normalizingVolatileMediaURLs: false)
            }
            let isGenerated = !Self.isUserRecordUnitKey(existing.unitKey)
            if !remoteChanged || remoteFingerprint == existing.remoteFingerprint || isGenerated {
                try await trashNotionBlocks(
                    try Self.jsonStringArray(existing.blockIdsJson),
                    token: token
                )
                if let id = existing.id { try await repository.deleteBlock(id: id) }
            } else {
                let operation = NotionSyncOperationRecord(
                    operationId: UUID().uuidString,
                    pageSyncId: pageSyncID,
                    unitKey: existing.unitKey,
                    operationType: "preserve_deleted_record",
                    state: "prepared",
                    oldBlockIdsJson: existing.blockIdsJson,
                    newBlockIdsJson: "[]",
                    blocksJson: try Self.jsonString(Self.notionDeletedRecordMarkers(
                        contentType: existing.contentType,
                        nowMilliseconds: request.nowMilliseconds,
                        localeIdentifier: request.localeIdentifier,
                        timeZoneIdentifier: request.timeZoneIdentifier
                    )),
                    sourceFingerprint: existing.sourceFingerprint,
                    sourceUpdatedDate: existing.sourceUpdatedDate,
                    createdDate: request.nowMilliseconds,
                    updatedDate: request.nowMilliseconds
                )
                try await repository.upsertOperation(operation)
                let markerIDs = try await appendNotionBlocks(
                    try Self.jsonObjectArray(operation.blocksJson),
                    pageID: page.pageId,
                    afterBlockID: try Self.jsonStringArray(existing.blockIdsJson).last,
                    token: token
                )
                var checkpoint = operation
                checkpoint.state = "new_blocks_written"
                checkpoint.blocksJson = "[]"
                checkpoint.newBlockIdsJson = try Self.jsonString(markerIDs)
                checkpoint.updatedDate = request.nowMilliseconds
                try await repository.upsertOperation(checkpoint)
                guard let id = existing.id else {
                    throw DesktopWebAPIError(code: 500, message: "Notion 删除冲突映射缺少主键")
                }
                try await repository.completePreservedDeletion(
                    operationID: operation.operationId,
                    pageSyncID: pageSyncID,
                    oldBlockID: id
                )
                page.conflictCount += 1
            }
        }

        let status = page.conflictCount > 0 ? "有冲突记录" : "已同步"
        var effectiveMetadataBase = metadataBase
        if let remote,
           !page.lastExportedTitle.isEmpty,
           remote.title != page.lastExportedTitle {
            var properties = effectiveMetadataBase["properties"] as? [String: Any] ?? [:]
            properties.removeValue(forKey: "书名")
            effectiveMetadataBase["properties"] = properties
        }
        var metadata = ExportNotionBookGenerator.applyingSyncState(
            to: effectiveMetadataBase,
            syncID: page.syncId,
            metadataFingerprint: metadataFingerprint,
            contentFingerprint: contentFingerprint,
            firstSyncMilliseconds: page.firstSyncDate,
            lastSyncMilliseconds: request.nowMilliseconds,
            conflictCount: page.conflictCount,
            localeIdentifier: request.localeIdentifier,
            timeZoneIdentifier: request.timeZoneIdentifier
        )
        var properties = metadata["properties"] as? [String: Any] ?? [:]
        properties["同步状态"] = ["select": ["name": status]]
        metadata["properties"] = properties
        metadata["icon"] = generatedPageFields["icon"]
        metadata["cover"] = generatedPageFields["cover"]
        let metadataOperation = NotionSyncOperationRecord(
            operationId: UUID().uuidString,
            pageSyncId: pageSyncID,
            unitKey: "page_metadata",
            operationType: "page_metadata_commit",
            state: "prepared",
            oldBlockIdsJson: "[]",
            newBlockIdsJson: "[]",
            blocksJson: "[]",
            sourceFingerprint: contentFingerprint,
            sourceUpdatedDate: request.nowMilliseconds,
            createdDate: request.nowMilliseconds,
            updatedDate: request.nowMilliseconds
        )
        try await repository.deleteOperations(
            pageSyncID: pageSyncID,
            operationType: "page_metadata_commit"
        )
        try await repository.upsertOperation(metadataOperation)
        let updated = try await requestJSON(
            url: try requireURL("https://api.notion.com/v1/pages/\(page.pageId)"),
            method: "PATCH",
            headers: Self.notionHeaders(token: token),
            body: try JSONSerialization.data(withJSONObject: metadata)
        )
        try await repository.deleteOperation(operationID: metadataOperation.operationId)
        page.pageUrl = updated["url"] as? String ?? page.pageUrl
        page.status = status
        page.metadataFingerprint = metadataFingerprint
        page.contentFingerprint = contentFingerprint
        page.lastSyncDate = request.nowMilliseconds
        page.remoteLastEditedTime = updated["last_edited_time"] as? String ?? page.remoteLastEditedTime
        if remote == nil || remote?.title == page.lastExportedTitle || page.lastExportedTitle.isEmpty {
            page.lastExportedTitle = Self.notionTitle(in: metadataBase) ?? page.lastExportedTitle
        }
        try await repository.updatePage(page)
    }

    /// 先保存可恢复操作，再分批追加新 Block，最后删除旧 Block 并原子切换正式映射。
    private func performNotionUnitOperation(
        type: String,
        unit: DesktopWebNotionContentUnit,
        sourceFingerprint: String,
        page: NotionPageSyncRecord,
        oldMapping: NotionBlockSyncRecord?,
        preservesOld: Bool,
        afterBlockID: String?,
        token: String,
        repository: NotionExportSyncRepository,
        localeIdentifier: String,
        timeZoneIdentifier: String,
        nowMilliseconds: Int64
    ) async throws -> NotionBlockSyncRecord {
        var blocks = unit.blocks
        if preservesOld {
            blocks.insert(contentsOf: Self.notionConflictMarkers(
                contentType: unit.contentType,
                nowMilliseconds: nowMilliseconds,
                localeIdentifier: localeIdentifier,
                timeZoneIdentifier: timeZoneIdentifier
            ), at: 0)
        }
        let operation = NotionSyncOperationRecord(
            operationId: UUID().uuidString,
            pageSyncId: page.id ?? 0,
            unitKey: unit.key,
            operationType: type,
            state: "prepared",
            oldBlockIdsJson: oldMapping?.blockIdsJson ?? "[]",
            newBlockIdsJson: "[]",
            blocksJson: try Self.jsonString(blocks),
            sourceFingerprint: sourceFingerprint,
            sourceUpdatedDate: unit.sourceUpdatedAtMilliseconds,
            createdDate: nowMilliseconds,
            updatedDate: nowMilliseconds
        )
        try await repository.upsertOperation(operation)
        return try await continueNotionUnitOperation(
            operation,
            unit: unit,
            page: page,
            token: token,
            repository: repository,
            oldMapping: oldMapping,
            afterBlockID: afterBlockID,
            nowMilliseconds: nowMilliseconds
        )
    }

    /// 恢复单元写入；每批成功后缩短 blocks_json 并保存已确认 ID，取消或进程中断后不会重写已确认批次。
    private func continueNotionUnitOperation(
        _ source: NotionSyncOperationRecord,
        unit: DesktopWebNotionContentUnit,
        page: NotionPageSyncRecord,
        token: String,
        repository: NotionExportSyncRepository,
        oldMapping: NotionBlockSyncRecord?,
        afterBlockID: String?,
        nowMilliseconds: Int64
    ) async throws -> NotionBlockSyncRecord {
        var operation = source
        var remaining = try Self.jsonObjectArray(operation.blocksJson)
        var newBlockIDs = try Self.jsonStringArray(operation.newBlockIdsJson)
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let count = min(100, remaining.count)
            let batch = Array(remaining.prefix(count))
            let appended = try await appendNotionBlocks(
                batch,
                pageID: page.pageId,
                afterBlockID: newBlockIDs.last ?? afterBlockID,
                token: token
            )
            remaining.removeFirst(count)
            newBlockIDs.append(contentsOf: appended)
            operation.blocksJson = try Self.jsonString(remaining)
            operation.newBlockIdsJson = try Self.jsonString(newBlockIDs)
            operation.state = remaining.isEmpty ? "new_blocks_written" : "prepared"
            operation.updatedDate = nowMilliseconds
            try await repository.upsertOperation(operation)
        }

        if operation.operationType == "replace" {
            try await trashNotionBlocks(
                try Self.jsonStringArray(operation.oldBlockIdsJson),
                token: token
            )
        }
        let managedIDs = operation.operationType == "conflict_copy"
            ? Array(newBlockIDs.dropFirst(Self.notionConflictMarkerCount))
            : newBlockIDs
        let mapping = try Self.notionUnitBlockRecord(
            pageSyncID: page.id ?? operation.pageSyncId,
            unit: unit,
            fingerprint: operation.sourceFingerprint,
            blockIDs: managedIDs,
            nowMilliseconds: nowMilliseconds
        )
        switch operation.operationType {
        case "add", "initialize_page":
            try await repository.completeInitialization(
                operationID: operation.operationId,
                newBlocks: [mapping]
            )
        case "conflict_copy":
            try await repository.completeConflictReplacement(
                operationID: operation.operationId,
                pageSyncID: page.id ?? operation.pageSyncId,
                oldBlockID: oldMapping?.id,
                newBlock: mapping
            )
        default:
            try await repository.completeReplacement(
                operationID: operation.operationId,
                oldBlockID: oldMapping?.id,
                newBlock: mapping
            )
        }
        return mapping
    }

    /// 严格验证每个 append 响应的 Block 数量；超时不盲目重发，保留操作日志供下次核对。
    private func appendNotionBlocks(
        _ blocks: [[String: Any]],
        pageID: String,
        afterBlockID: String?,
        token: String
    ) async throws -> [String] {
        var body: [String: Any] = ["children": blocks]
        if let afterBlockID, !afterBlockID.isEmpty { body["after"] = afterBlockID }
        let response = try await requestJSON(
            url: try requireURL("https://api.notion.com/v1/blocks/\(pageID)/children"),
            method: "PATCH",
            headers: Self.notionHeaders(token: token),
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let ids = (response["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        guard ids.count == blocks.count else {
            throw DesktopWebAPIError(code: 400, message: "Notion Block 写入结果不完整，请先检查远端")
        }
        return ids
    }

    /// 删除已由恢复日志覆盖的旧受管 Block；404 表示用户已先行删除，视为目标状态达成。
    private func trashNotionBlocks(_ blockIDs: [String], token: String) async throws {
        for blockID in blockIDs {
            let (data, response) = try await rawRequest(
                url: try requireURL("https://api.notion.com/v1/blocks/\(blockID)"),
                method: "DELETE",
                headers: Self.notionHeaders(token: token),
                body: nil
            )
            guard (200...299).contains(response.statusCode) || response.statusCode == 404 else {
                throw Self.httpError(data, response)
            }
        }
    }
}

private extension DesktopWebExportService {
    /// 把领域设置映射到已验证的 Android 文本生成键，避免生成器回读 UserDefaults。
    static func dictionary(
        from settings: ExportSettingsSnapshot,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> [String: Any] {
        [
            "exportNote": settings.content.includesNotes,
            "exportRelevant": settings.content.includesRelatedNotes,
            "exportReview": settings.content.includesReviews,
            "includeDateTime": settings.includesDateTime,
            "includePage": settings.includesPage,
            "includeTag": settings.includesTags,
            "includeBookInfo": settings.includesBookInformation,
            "obsidianExportTags": settings.obsidianExportsTags,
            "_localeIdentifier": localeIdentifier,
            "_timeZoneIdentifier": timeZoneIdentifier
        ]
    }

    func exportSettings() async throws -> [String: Any] {
        let data = try await settingsRepository.exportRuntimeSettingsData()
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

    /// 在逐书并发前分页读取一次数据源最小索引，避免每本书各自查询整个 Notion 数据源。
    func queryNotionLibraryPageIndex(
        token: String,
        dataSourceID: String
    ) async throws -> NotionLibraryPageIndex {
        var cursor: String?
        var entries: [NotionLibraryPageIndexEntry] = []
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let cursor, !cursor.isEmpty { body["start_cursor"] = cursor }
            let response = try await requestJSON(
                url: try requireURL("https://api.notion.com/v1/data_sources/\(dataSourceID)/query"),
                method: "POST",
                headers: Self.notionHeaders(token: token),
                body: try JSONSerialization.data(withJSONObject: body)
            )
            entries.append(contentsOf: (response["results"] as? [[String: Any]] ?? []).compactMap {
                Self.notionIndexEntry($0)
            })
            cursor = response["has_more"] as? Bool == true
                ? response["next_cursor"] as? String
                : nil
        } while cursor?.isEmpty == false
        return NotionLibraryPageIndex(pagesBySyncID: Dictionary(grouping: entries, by: \.syncID))
    }

    /// 回读本地映射指向但索引未返回的页面；404 与回收站统一进入显式重建流程。
    func retrieveNotionIndexEntry(
        token: String,
        pageID: String,
        fallback: NotionPageSyncRecord
    ) async throws -> NotionLibraryPageIndexEntry {
        let (data, response) = try await rawRequest(
            url: try requireURL("https://api.notion.com/v1/pages/\(pageID)"),
            method: "GET",
            headers: Self.notionHeaders(token: token),
            body: nil
        )
        if response.statusCode == 404 {
            throw NotionManagedPageRequiresRebuildError(pageID: pageID)
        }
        guard (200...299).contains(response.statusCode) else { throw Self.httpError(data, response) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopWebAPIError(code: 400, message: "Notion 页面响应格式错误")
        }
        let parsed = Self.notionIndexEntry(object)
        return NotionLibraryPageIndexEntry(
            pageID: parsed?.pageID ?? pageID,
            pageURL: parsed?.pageURL ?? fallback.pageUrl,
            syncID: parsed?.syncID.isEmpty == false ? parsed!.syncID : fallback.syncId,
            metadataFingerprint: parsed?.metadataFingerprint.isEmpty == false
                ? parsed!.metadataFingerprint
                : fallback.metadataFingerprint,
            contentFingerprint: parsed?.contentFingerprint.isEmpty == false
                ? parsed!.contentFingerprint
                : fallback.contentFingerprint,
            title: parsed?.title ?? fallback.lastExportedTitle,
            syncStatus: parsed?.syncStatus.isEmpty == false ? parsed!.syncStatus : fallback.status,
            lastEditedTime: parsed?.lastEditedTime ?? fallback.remoteLastEditedTime,
            isInTrash: parsed?.isInTrash
                ?? (object["in_trash"] as? Bool == true || object["archived"] as? Bool == true)
        )
    }

    /// 分页读取页面顶层 Block；同一份快照同时服务映射恢复、远端删除识别和人工编辑冲突判断。
    func notionTopLevelBlocks(token: String, pageID: String) async throws -> [[String: Any]] {
        var cursor: String?
        var result: [[String: Any]] = []
        repeat {
            var components = try requireURL(
                "https://api.notion.com/v1/blocks/\(pageID)/children"
            ).appending(queryItems: [URLQueryItem(name: "page_size", value: "100")])
            if let cursor, !cursor.isEmpty {
                components = components.appending(queryItems: [URLQueryItem(name: "start_cursor", value: cursor)])
            }
            let response = try await requestJSON(
                url: components,
                method: "GET",
                headers: Self.notionHeaders(token: token),
                body: nil
            )
            result.append(contentsOf: response["results"] as? [[String: Any]] ?? [])
            cursor = response["has_more"] as? Bool == true
                ? response["next_cursor"] as? String
                : nil
        } while cursor?.isEmpty == false
        return result
    }

    /// 仅返回顶层 Block ID，用于页面级指纹已验证后的映射恢复。
    func notionTopLevelBlockIDs(token: String, pageID: String) async throws -> [String] {
        try await notionTopLevelBlocks(token: token, pageID: pageID).compactMap { $0["id"] as? String }
    }

    func requestJSON(url: URL, method: String, headers: [String: String], body: Data?) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(url: url, method: method, headers: headers, body: body)
        guard (200...299).contains(response.statusCode) else { throw Self.httpError(data, response) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopWebAPIError(code: 400, message: "远端响应格式错误")
        }
        return json
    }

    func rawRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        using requestSession: URLSession? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard url.host?.lowercased() == "api.notion.com" else {
            return try await performRawRequest(
                url: url,
                method: method,
                headers: headers,
                body: body,
                using: requestSession
            )
        }

        var effectiveHeaders = headers
        var rateLimitRetryCount = 0
        var hasRefreshedAuthorization = false
        while true {
            try Task.checkCancellation()
            let startedHeaders = try await notionRequestCoordinator.prepare(headers: effectiveHeaders)
            let (data, response) = try await performRawRequest(
                url: url,
                method: method,
                headers: startedHeaders,
                body: body,
                using: requestSession
            )
            if response.statusCode == 401,
               !hasRefreshedAuthorization,
               let authorization = startedHeaders.first(where: {
                   $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
               })?.value,
               authorization.lowercased().hasPrefix("bearer ") {
                let rejectedToken = String(authorization.dropFirst("Bearer ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let refreshedToken = try await notionTokenRefresher(rejectedToken)
                await notionRequestCoordinator.use(accessToken: refreshedToken)
                effectiveHeaders["Authorization"] = "Bearer \(refreshedToken)"
                hasRefreshedAuthorization = true
                continue
            }
            if (response.statusCode == 429 || response.statusCode == 529),
               rateLimitRetryCount < 3 {
                let retryAfterSeconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "")
                let fallbackSeconds = Double(1 << rateLimitRetryCount)
                let delaySeconds = max(0, retryAfterSeconds ?? fallbackSeconds)
                try await Task.sleep(for: .milliseconds(Int64((delaySeconds * 1_000).rounded(.up))))
                rateLimitRetryCount += 1
                continue
            }
            return (data, response)
        }
    }

    /// 执行一次无策略网络请求；Notion 的启动间隔、刷新与限流重试全部由 rawRequest 外层统一编排。
    private func performRawRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        using requestSession: URLSession?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if body != nil, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await (requestSession ?? session).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DesktopWebAPIError(code: 400, message: "远端响应无效")
        }
        return (data, http)
    }

    /// 连接 Obsidian 前验证服务身份及已修复路径穿越问题的最低插件版本 4.1.3。
    func validateObsidianServer(baseURL: String, session: URLSession) async throws {
        let (data, response) = try await rawRequest(
            url: try requireURL("\(baseURL)/"),
            method: "GET",
            headers: [:],
            body: nil,
            using: session
        )
        guard (200...299).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["service"] as? String == "Obsidian Local REST API",
              let versions = object["versions"] as? [String: Any],
              let version = versions["self"] as? String,
              Self.isVersion(version, atLeast: "4.1.3") else {
            throw DesktopWebAPIError(
                code: 40_001,
                message: "Obsidian Local REST API 插件需要 4.1.3 或更高版本"
            )
        }
    }

    /// 比较仅含十进制数字的语义版本段；缺失段按零处理，预发布后缀不提升版本。
    static func isVersion(_ value: String, atLeast minimum: String) -> Bool {
        func components(_ text: String) -> [Int] {
            text.split(separator: ".").map { part in
                Int(part.prefix { $0.isNumber }) ?? 0
            }
        }
        let lhs = components(value)
        let rhs = components(minimum)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
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
            let token = settings.string("notionToken")
            let dataSourceID = settings.string("notionDataSourceId")
            guard !dataSourceID.isEmpty else {
                throw DesktopWebAPIError(code: 40_001, message: "请先通过 OAuth 选择 Notion 数据源")
            }
            return .notion(
                token: token,
                databaseID: dataSourceID
            )
        case "siyuan":
            return .siYuan(
                baseURL: "http://\(settings.string("siyuanIp")):\(settings.string("siyuanPort"))",
                token: settings.string("siyuanToken"),
                notebookID: settings.string("siyuanNotebookId")
            )
        case "obsidian":
            let host = settings.string("obsidianIp")
            let baseURL = "https://\(host):27124"
            let secureSession = obsidianSessionFactory(
                host,
                settings.string("obsidianPinnedCertificateSHA256")
            )
            try await validateObsidianServer(baseURL: baseURL, session: secureSession)
            return .obsidian(
                baseURL: baseURL,
                apiKey: settings.string("obsidianApiKey"),
                directory: settings.string("obsidianDirName"),
                session: secureSession
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
                body["parent"] = [
                    "type": "data_source_id",
                    "data_source_id": databaseID
                ]
                _ = try await requestJSON(
                    url: try requireURL("https://api.notion.com/v1/pages"),
                    method: "POST",
                    headers: Self.notionHeaders(token: token),
                    body: try JSONSerialization.data(withJSONObject: body)
                )
            }
        case let .oneNote(token, sectionID):
            let pages = DesktopWebRemoteExportGenerators.oneNotePages(
                bundle: bundle,
                selection: selection,
                settings: settings,
                timestamp: frozenTimestamp,
                createdDateTime: Self.dateText(
                    currentTimeMillis(),
                    localeIdentifier: settings.string("_localeIdentifier"),
                    timeZoneIdentifier: settings.string("_timeZoneIdentifier")
                )
            )
            try ensureRemotePages(pages, bookName: bundle.book.name)
            for page in pages {
                let (data, response) = try await rawRequest(
                    url: try requireURL("https://graph.microsoft.com/v1.0/me/onenote/sections/\(sectionID)/pages"),
                    method: "POST",
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "text/html"
                    ],
                    body: Data(page.body.utf8)
                )
                guard (200...299).contains(response.statusCode) else {
                    throw Self.httpError(data, response)
                }
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
        case let .obsidian(baseURL, apiKey, directory, secureSession):
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
                    body: Data(page.body.utf8),
                    using: secureSession
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

    /// 查找或创建“纸间书摘”笔记本与用户配置 section，整个导出任务只执行一次发现流程。
    func ensureOneNoteSectionID(token: String, sectionName rawSectionName: String) async throws -> String {
        let sectionName = rawSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "书摘导出"
            : rawSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebooks = try await graphCollection(
            url: try requireURL("https://graph.microsoft.com/v1.0/me/onenote/notebooks?$select=id,displayName"),
            token: token
        )
        let notebookID: String
        if let existing = notebooks.first(where: { $0["displayName"] as? String == "纸间书摘" })?["id"] as? String {
            notebookID = existing
        } else {
            let created = try await requestJSON(
                url: try requireURL("https://graph.microsoft.com/v1.0/me/onenote/notebooks"),
                method: "POST",
                headers: ["Authorization": "Bearer \(token)"],
                body: try JSONSerialization.data(withJSONObject: ["displayName": "纸间书摘"])
            )
            guard let id = created["id"] as? String, !id.isEmpty else {
                throw DesktopWebAPIError(code: 400, message: "OneNote 笔记本创建失败")
            }
            notebookID = id
        }

        let sections = try await graphCollection(
            url: try requireURL("https://graph.microsoft.com/v1.0/me/onenote/notebooks/\(notebookID)/sections?$select=id,displayName"),
            token: token
        )
        if let id = sections.first(where: { $0["displayName"] as? String == sectionName })?["id"] as? String {
            return id
        }
        let created = try await requestJSON(
            url: try requireURL("https://graph.microsoft.com/v1.0/me/onenote/notebooks/\(notebookID)/sections"),
            method: "POST",
            headers: ["Authorization": "Bearer \(token)"],
            body: try JSONSerialization.data(withJSONObject: ["displayName": sectionName])
        )
        guard let id = created["id"] as? String, !id.isEmpty else {
            throw DesktopWebAPIError(code: 400, message: "OneNote 分区创建失败")
        }
        return id
    }

    /// 跟随 Microsoft Graph `@odata.nextLink` 读取完整集合，避免笔记本或分区分页造成重复创建。
    func graphCollection(url: URL, token: String) async throws -> [[String: Any]] {
        var nextURL: URL? = url
        var result: [[String: Any]] = []
        while let url = nextURL {
            try Task.checkCancellation()
            let page = try await requestJSON(
                url: url,
                method: "GET",
                headers: ["Authorization": "Bearer \(token)"],
                body: nil
            )
            result.append(contentsOf: page["value"] as? [[String: Any]] ?? [])
            nextURL = (page["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return result
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
            "Notion-Version": "2026-03-11"
        ]
    }

    /// 对排序后的页面元数据 JSON 计算稳定 SHA-256，供 v45 页面同步基线跳过无变化写入。
    static func notionFingerprint(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 将恢复日志 JSON 规范化为排序键紧凑字符串，避免字典遍历顺序影响持久化比较。
    static func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw DesktopWebAPIError(code: 500, message: "Notion 恢复日志编码失败")
        }
        return text
    }

    /// Notion UUID 在带连字符和无连字符响应之间视为同一页面。
    static func normalizedNotionID(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 将已验证为同一内容指纹的远端顶层 Block 按草稿边界恢复为 v45 独立单元映射。
    static func recoveredNotionUnitBlocks(
        pageSyncID: Int64,
        units: [DesktopWebNotionContentUnit],
        blockIDs: [String],
        nowMilliseconds: Int64
    ) throws -> [NotionBlockSyncRecord] {
        guard blockIDs.count == units.reduce(0, { $0 + $1.blocks.count }) else {
            throw DesktopWebAPIError(
                code: 40_010,
                message: "已找到持续同步页面，但远端 Block 数量无法安全恢复，本次未覆盖正文"
            )
        }
        var offset = 0
        return try units.map { unit in
            let end = offset + unit.blocks.count
            defer { offset = end }
            let fingerprint = try notionBlockFingerprint(
                unit.blocks,
                normalizingVolatileMediaURLs: true
            )
            return try notionUnitBlockRecord(
                pageSyncID: pageSyncID,
                unit: unit,
                fingerprint: fingerprint,
                blockIDs: Array(blockIDs[offset..<end]),
                nowMilliseconds: nowMilliseconds
            )
        }
    }

    /// 将一个内容单元转换为 Android Room v45 notion_block_sync 记录。
    static func notionUnitBlockRecord(
        pageSyncID: Int64,
        unit: DesktopWebNotionContentUnit,
        fingerprint: String,
        blockIDs: [String],
        nowMilliseconds: Int64
    ) throws -> NotionBlockSyncRecord {
        NotionBlockSyncRecord(
            id: nil,
            pageSyncId: pageSyncID,
            unitKey: unit.key,
            contentType: unit.contentType,
            sourceId: unit.sourceID,
            sourceUpdatedDate: unit.sourceUpdatedAtMilliseconds,
            sourceFingerprint: fingerprint,
            remoteFingerprint: fingerprint,
            blockIdsJson: try jsonString(blockIDs),
            anchorKey: unit.anchorKey,
            deletable: unit.isDeletable,
            state: "managed",
            lastSyncDate: nowMilliseconds
        )
    }

    /// 返回当前单元之前最后一个仍受管的 Block，供 Notion `after` 保持 Android 单元顺序。
    static func previousManagedBlockID(
        before index: Int,
        units: [DesktopWebNotionContentUnit],
        mappings: [String: NotionBlockSyncRecord]
    ) -> String? {
        guard index > 0 else { return nil }
        for previous in units[..<index].reversed() {
            guard let mapping = mappings[previous.key], mapping.state == "managed" else { continue }
            if let value = try? jsonStringArray(mapping.blockIdsJson).last { return value }
        }
        return nil
    }

    /// 按映射 ID 顺序提取远端 Block；任一 Block 缺失即表示用户已在 Notion 删除该单元。
    static func remoteBlocks(
        for mapping: NotionBlockSyncRecord,
        blocksByID: [String: [String: Any]]
    ) throws -> [[String: Any]]? {
        let ids = try jsonStringArray(mapping.blockIdsJson)
        let blocks = ids.compactMap { blocksByID[normalizedNotionID($0)] }
        return blocks.count == ids.count ? blocks : nil
    }

    /// 对 Notion 请求与响应 Block 使用同一规范化口径；排除响应元数据但保留正文、样式、链接与图片。
    static func notionBlockFingerprint(
        _ blocks: [[String: Any]],
        normalizingVolatileMediaURLs: Bool
    ) throws -> String {
        let normalized = blocks.map {
            normalizeNotionBlock($0, normalizingVolatileMediaURLs: normalizingVolatileMediaURLs)
        }
        let data = try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeNotionBlock(
        _ block: [String: Any],
        normalizingVolatileMediaURLs: Bool
    ) -> [String: Any] {
        let type = block["type"] as? String ?? ""
        var result: [String: Any] = ["type": type]
        if let content = block[type] {
            result[type] = normalizeNotionValue(
                content,
                parentKey: type,
                normalizingVolatileMediaURLs: normalizingVolatileMediaURLs
            )
        }
        if let children = block["children"] {
            result["children"] = normalizeNotionValue(
                children,
                parentKey: "children",
                normalizingVolatileMediaURLs: normalizingVolatileMediaURLs
            )
        }
        return result
    }

    private static func normalizeNotionValue(
        _ value: Any,
        parentKey: String,
        normalizingVolatileMediaURLs: Bool
    ) -> Any {
        if let values = value as? [Any] {
            return values.map {
                normalizeNotionValue(
                    $0,
                    parentKey: parentKey,
                    normalizingVolatileMediaURLs: normalizingVolatileMediaURLs
                )
            }
        }
        guard let object = value as? [String: Any] else { return value }
        if parentKey == "rich_text" {
            return normalizeNotionRichText(
                object,
                normalizingVolatileMediaURLs: normalizingVolatileMediaURLs
            )
        }
        let responseOnly = Set([
            "object", "id", "parent", "created_time", "last_edited_time", "created_by",
            "last_edited_by", "has_children", "in_trash", "archived", "plain_text", "href", "request_id"
        ])
        var result: [String: Any] = [:]
        for key in object.keys.sorted() where !responseOnly.contains(key) {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            if key == "is_toggleable", raw as? Bool == false { continue }
            if let array = raw as? [Any], array.isEmpty { continue }
            if parentKey == "callout", key == "icon",
               let icon = raw as? [String: Any], icon["emoji"] as? String == "💡" {
                continue
            }
            if normalizingVolatileMediaURLs,
               key == "url",
               parentKey == "external" || parentKey == "file",
               let url = raw as? String {
                result[key] = url.components(separatedBy: "?").first?
                    .components(separatedBy: "#").first ?? url
            } else {
                result[key] = normalizeNotionValue(
                    raw,
                    parentKey: key,
                    normalizingVolatileMediaURLs: normalizingVolatileMediaURLs
                )
            }
        }
        return result
    }

    private static func normalizeNotionRichText(
        _ value: [String: Any],
        normalizingVolatileMediaURLs: Bool
    ) -> [String: Any] {
        let type = value["type"] as? String ?? "text"
        var result: [String: Any] = ["type": type]
        switch type {
        case "text":
            let text = value["text"] as? [String: Any] ?? [:]
            result["content"] = text["content"] as? String ?? ""
            result["link"] = (text["link"] as? [String: Any])?["url"] as? String ?? ""
        case "equation":
            result["expression"] = (value["equation"] as? [String: Any])?["expression"] as? String ?? ""
        case "mention":
            if let mention = value["mention"] {
                result["mention"] = normalizeNotionValue(
                    mention,
                    parentKey: "mention",
                    normalizingVolatileMediaURLs: normalizingVolatileMediaURLs
                )
            }
        default:
            break
        }
        let annotations = value["annotations"] as? [String: Any] ?? [:]
        result["bold"] = annotations["bold"] as? Bool ?? false
        result["italic"] = annotations["italic"] as? Bool ?? false
        result["strikethrough"] = annotations["strikethrough"] as? Bool ?? false
        result["underline"] = annotations["underline"] as? Bool ?? false
        result["code"] = annotations["code"] as? Bool ?? false
        result["color"] = annotations["color"] as? String ?? "default"
        return result
    }

    static let notionConflictMarkerCount = 2

    /// Android 冲突保留标记：上方保留 Notion 版本，下方追加本次冻结的纸间版本。
    static func notionConflictMarkers(
        contentType: String,
        nowMilliseconds: Int64,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> [[String: Any]] {
        let date = notionMarkerDate(
            nowMilliseconds,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
        return [
            notionMarkerBlock(type: "heading_3", text: "同步冲突 · \(notionContentTypeName(contentType))"),
            notionMarkerBlock(type: "paragraph", text: "上方是 Notion 版本，下方是纸间版本 · \(date)")
        ]
    }

    /// Android 删除冲突标记：来源记录已删除但 Notion 版本被用户编辑时保留远端内容。
    static func notionDeletedRecordMarkers(
        contentType: String,
        nowMilliseconds: Int64,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> [[String: Any]] {
        let date = notionMarkerDate(
            nowMilliseconds,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
        return [
            notionMarkerBlock(type: "heading_3", text: "同步冲突 · \(notionContentTypeName(contentType))"),
            notionMarkerBlock(type: "paragraph", text: "纸间已删除这条记录，已保留上方的 Notion 版本 · \(date)")
        ]
    }

    private static func notionMarkerBlock(type: String, text: String) -> [String: Any] {
        [
            "object": "block",
            "type": type,
            type: [
                "rich_text": [["type": "text", "text": ["content": text]]],
                "color": "gray"
            ]
        ]
    }

    private static func notionMarkerDate(
        _ milliseconds: Int64,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    private static func notionContentTypeName(_ value: String) -> String {
        switch value {
        case "NOTE": "书摘"
        case "REVIEW": "书评"
        case "RELEVANT": "关联笔记"
        case "BOOK_INFO": "书籍信息"
        default: "内容"
        }
    }

    static func isUserRecordUnitKey(_ value: String) -> Bool {
        value.hasPrefix("note:") || value.hasPrefix("review:") || value.hasPrefix("relevant:")
    }

    static func notionTitle(in body: [String: Any]) -> String? {
        let properties = body["properties"] as? [String: Any]
        let title = properties?["书名"] as? [String: Any]
        let items = title?["title"] as? [[String: Any]]
        let text = items?.first?["text"] as? [String: Any]
        return text?["content"] as? String
    }

    /// 解码恢复日志中的待写入 Block 数组。
    static func jsonObjectArray(_ value: String) throws -> [[String: Any]] {
        guard let data = value.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DesktopWebAPIError(code: 500, message: "Notion Block 恢复日志损坏")
        }
        return result
    }

    /// 解码恢复日志中的远端 Block ID 数组。
    static func jsonStringArray(_ value: String) throws -> [String] {
        guard let data = value.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw DesktopWebAPIError(code: 500, message: "Notion Block ID 恢复日志损坏")
        }
        return result
    }

    /// 使用请求冻结的区域与时区生成 OneNote meta created 时间。
    static func dateText(
        _ milliseconds: Int64,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier.isEmpty ? "zh_CN" : localeIdentifier)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier.isEmpty ? "Asia/Shanghai" : timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    /// 从 Notion Page 的公开属性形态提取最小索引条目；无同步 ID 的普通页面不属于纸间托管范围。
    static func notionIndexEntry(_ page: [String: Any]) -> NotionLibraryPageIndexEntry? {
        guard let pageID = page["id"] as? String, !pageID.isEmpty else { return nil }
        let properties = page["properties"] as? [String: Any] ?? [:]
        let syncID = notionPropertyText(properties["XMNote 同步 ID"], valueKey: "rich_text")
        guard !syncID.isEmpty else { return nil }
        return NotionLibraryPageIndexEntry(
            pageID: pageID,
            pageURL: page["url"] as? String ?? "",
            syncID: syncID,
            metadataFingerprint: notionPropertyText(
                properties["XMNote 元数据指纹"],
                valueKey: "rich_text"
            ),
            contentFingerprint: notionPropertyText(
                properties["XMNote 内容指纹"],
                valueKey: "rich_text"
            ),
            title: notionPropertyText(properties["书名"], valueKey: "title"),
            syncStatus: notionSelectName(properties["同步状态"]),
            lastEditedTime: page["last_edited_time"] as? String ?? "",
            isInTrash: page["in_trash"] as? Bool == true || page["archived"] as? Bool == true
        )
    }

    /// 兼容 plain_text 与 text.content 两种富文本响应，索引只需要拼接纯文本。
    static func notionPropertyText(_ rawProperty: Any?, valueKey: String) -> String {
        guard let property = rawProperty as? [String: Any],
              let values = property[valueKey] as? [[String: Any]] else { return "" }
        return values.map { value in
            if let plainText = value["plain_text"] as? String { return plainText }
            return ((value["text"] as? [String: Any])?["content"] as? String) ?? ""
        }.joined()
    }

    static func notionSelectName(_ rawProperty: Any?) -> String {
        guard let property = rawProperty as? [String: Any],
              let select = property["select"] as? [String: Any] else { return "" }
        return select["name"] as? String ?? ""
    }

    /// 远端超时可能已经产生写入，必须标记结果不确定并禁止盲目重试。
    static func failureDisposition(_ error: Error, target: ExportTarget) -> ExportFailureDisposition {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .resultUncertain
        }
        return target.isLocalFile ? .retryable : .nonRetryable
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
            if settings.string("notionToken").isEmpty { throw DesktopWebAPIError(code: 40001, message: "请先通过 OAuth 连接 Notion") }
            if settings.string("notionDataSourceId").isEmpty { throw DesktopWebAPIError(code: 40001, message: "请先选择 Notion 数据源") }
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
        settings: [String: Any],
        fileNameAllocator: inout ExportFileNameAllocator
    ) throws -> [ExportGeneratedFile] {
        let sections = Self.contentSections(bundle: bundle, selection: selection, settings: settings)
        var files: [ExportGeneratedFile] = []
        for (title, markdown, text) in sections {
            switch target {
            case "markdown":
                files.append(.init(
                    name: try fileNameAllocator.allocate(title: title, extension: "md"),
                    data: Data(markdown.utf8),
                    mediaType: "text/markdown"
                ))
            case "text":
                files.append(.init(
                    name: try fileNameAllocator.allocate(title: title, extension: "txt"),
                    data: Data(text.utf8),
                    mediaType: "text/plain; charset=utf-8"
                ))
            case "pdf":
                files.append(.init(
                    name: try fileNameAllocator.allocate(title: title, extension: "pdf"),
                    data: Self.makePDF(text),
                    mediaType: "application/pdf"
                ))
            default:
                break
            }
        }
        return files
    }

    static func contentSections(
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any]
    ) -> [(String, String, String)] {
        var result: [(String, String, String)] = []
        if selection.review, !bundle.reviews.isEmpty {
            result.append(("《\(bundle.book.name)》书评", markdownReviews(bundle, settings), textReviews(bundle, settings)))
        }
        if selection.relevant, !bundle.related.isEmpty {
            result.append(("《\(bundle.book.name)》相关", markdownRelated(bundle, settings), textRelated(bundle, settings)))
        }
        if selection.note {
            result.append(("《\(bundle.book.name)》", markdownNotes(bundle, settings), textNotes(bundle, settings)))
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
            page += "<font color='#6e6e6e' size=2>\(dateText(review.createdTime, settings: settings))</font>\n\n"
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
                page += "<font color='#6e6e6e' size=2>\(dateText(value.createdTime, settings: settings))</font>\n\n"
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
                    page += "<font color='#6e6e6e' size=2>\(dateText(value.createdTime, settings: settings))</font>\n\n"
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
                let unit = switch note.positionUnit { case 2: "页码"; case 0: "进度"; default: "位置" }
                info.append("\(unit)：\(position)\(note.positionUnit == 0 ? "%" : "")")
            }
            if settings.bool("includeDateTime", fallback: true), note.createdTime != 0, note.isIncludeTime {
                info.append(dateText(note.createdTime, settings: settings))
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
            if settings.bool("includeDateTime", fallback: true) { page += dateText(review.createdTime, settings: settings) + "\n" }
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
            if settings.bool("includeDateTime", fallback: true) { info.append(dateText(value.createdTime, settings: settings)) }
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
            let unit = switch note.positionUnit { case 2: "页码"; case 0: "进度"; default: "位置" }
            items.append("\(unit)：\(position)\(note.positionUnit == 0 ? "%" : "")")
        }
        if settings.bool("includeDateTime", fallback: true), note.createdTime != 0 {
            items.append(dateText(note.createdTime, settings: settings))
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

    static func dateText(_ milliseconds: Int64, settings: [String: Any]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.string("_localeIdentifier").isEmpty ? "zh_CN" : settings.string("_localeIdentifier"))
        formatter.timeZone = TimeZone(identifier: settings.string("_timeZoneIdentifier").isEmpty ? "Asia/Shanghai" : settings.string("_timeZoneIdentifier"))
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
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

    private static func makeZIP(_ files: [ExportGeneratedFile]) throws -> Data {
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

extension DesktopWebExportService {
    /// 暴露纯生成边界供 Android Oracle 验证；输入必须是已冻结快照与设置，不读取数据库或用户默认值。
    static func localContentSections(
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any]
    ) -> [(String, String, String)] {
        contentSections(bundle: bundle, selection: selection, settings: settings)
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
