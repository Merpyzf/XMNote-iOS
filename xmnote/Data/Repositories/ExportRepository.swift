/**
 * [INPUT]: 依赖 DesktopWebExportRepository 的冻结快照、ExportSettingsStore/Keychain、统一本地与远端生成 Service 和临时文件系统
 * [OUTPUT]: 对外提供 ExportRepositoryProtocol 实现、平台选项查询与原生/Desktop Web 共用的单一导出编排入口
 * [POS]: Data 层导出业务 owner；ViewModel、HTTP Adapter 与生成器均不得绕过该 Repository 访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import XMNoteWeb

/// 导出 Repository 只持有 Sendable 值与内部线程安全依赖；每次任务的快照、文件目录和进度节流器彼此隔离。
final class ExportRepository: ExportRepositoryProtocol, @unchecked Sendable {
    private let snapshotRepository: DesktopWebExportRepository
    private let settingsStore: ExportSettingsStore
    private let credentialStore: ExportCredentialStore
    private let oneNoteAuthentication: any OneNoteAccessTokenProviding
    private let exportService: DesktopWebExportService
    private let fileManager: FileManager
    private let defaults: UserDefaults

    init(
        database: AppDatabase,
        defaults: UserDefaults = .standard,
        credentialStore: ExportCredentialStore = ExportCredentialStore(),
        oneNoteAuthentication: any OneNoteAccessTokenProviding = OneNoteAuthenticationService(),
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        let snapshotRepository = DesktopWebExportRepository(database: database, defaults: defaults)
        self.snapshotRepository = snapshotRepository
        self.credentialStore = credentialStore
        self.oneNoteAuthentication = oneNoteAuthentication
        self.defaults = defaults
        let notionTokenRefresher = NotionOAuthTokenRefresher(
            session: session,
            credentialStore: credentialStore
        )
        settingsStore = ExportSettingsStore(defaults: defaults, credentialStore: credentialStore)
        exportService = DesktopWebExportService(
            repository: snapshotRepository,
            notionSyncRepository: NotionExportSyncRepository(database: database),
            settingsRepository: DesktopWebSettingsRepository(
                defaults: defaults,
                credentialStore: credentialStore
            ),
            session: session,
            oneNoteAuthentication: oneNoteAuthentication,
            notionTokenRefresher: { rejectedToken in
                try await notionTokenRefresher.refreshAccessToken(
                    rejectedAccessToken: rejectedToken
                )
            }
        )
        self.fileManager = fileManager
    }

    /// 读取经过迁移和归一化的非敏感设置。
    func settings() async throws -> ExportSettingsSnapshot {
        await settingsStore.settings()
    }

    /// 保存非敏感设置快照，凭据必须调用 saveCredential 单独进入 Keychain。
    func saveSettings(_ settings: ExportSettingsSnapshot) async throws {
        try await settingsStore.save(settings)
    }

    /// 将凭据保存到 WhenUnlockedThisDeviceOnly Keychain 项。
    func saveCredential(_ value: String, for credential: ExportCredential) async throws {
        try await settingsStore.saveCredential(value, for: credential)
    }

    /// 返回脱敏连接状态，不向界面暴露已保存的凭据值。
    func hasCredential(_ credential: ExportCredential) async -> Bool {
        await settingsStore.hasCredential(credential)
    }

    /// 通过默认空配置的 OAuth Broker 连接 Notion，token 仅由 Broker Service 写入 Keychain。
    func connectNotion() async throws {
        let service = await MainActor.run {
            NotionOAuthBrokerService(credentialStore: credentialStore, defaults: defaults)
        }
        try await service.connect()
    }

    /// 触发 MSAL public-client 登录；仅保存账户缓存存在标记，不把 Graph access token 持久化到应用设置。
    func connectOneNote() async throws {
        let token = try await oneNoteAuthentication.accessToken()
        guard !token.isEmpty else { throw OneNoteAuthenticationError.emptyToken }
        try await credentialStore.set("msal_cache", for: .oneNoteAccount)
    }

    /// 查询思源笔记本；网络和凭据读取仍由同一个导出 Service 负责。
    func siYuanNotebooks() async throws -> [DesktopWebExportPlatformOption] {
        try await exportService.siYuanNotebooks()
    }

    /// 查询 Obsidian Vault 一级目录；连接安全策略由统一导出 Service 校验。
    func obsidianDirectories() async throws -> [DesktopWebExportPlatformOption] {
        try await exportService.obsidianDirectories()
    }

    /// 执行统一导出：先做目标与会员双重预检，再冻结完整数据库快照，最后生成文件或按目标写入远端。
    func export(
        _ request: ExportRequest,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async -> ExportResult {
        let reporter = ExportProgressReporter(handler: progress)
        do {
            try validate(request)
            await reporter.publish(.init(
                phase: .preflighting,
                completedUnits: 0,
                totalUnits: 1,
                message: "正在检查导出设置"
            ), force: true)
            let snapshot = try await snapshotRepository.snapshot(
                scope: request.scope,
                selection: request.settings.content
            )
            guard !snapshot.books.isEmpty else {
                throw ExportRepositoryError.noBooks
            }
            try Task.checkCancellation()
            await reporter.publish(.init(
                phase: .readingSnapshot,
                completedUnits: snapshot.books.count,
                totalUnits: snapshot.books.count,
                message: "已冻结 \(snapshot.books.count) 本书的数据"
            ), force: true)

            if request.target.isLocalFile {
                let ticket = try await makeLocalArtifacts(
                    request: request,
                    snapshot: snapshot,
                    reporter: reporter
                )
                await reporter.publish(.init(
                    phase: .finishing,
                    completedUnits: snapshot.books.count,
                    totalUnits: snapshot.books.count,
                    message: "导出完成"
                ), force: true)
                return ExportResult(
                    requestedBookCount: snapshot.books.count,
                    successCount: snapshot.books.count,
                    failures: [],
                    artifactTicket: ticket
                )
            }

            let remote = try await exportRemote(
                request: request,
                snapshot: snapshot,
                reporter: reporter
            )
            await reporter.publish(.init(
                phase: .finishing,
                completedUnits: remote.successCount + remote.failures.count,
                totalUnits: snapshot.books.count,
                message: remote.failures.isEmpty ? "导出完成" : "导出已完成，部分书籍失败"
            ), force: true)
            return remote
        } catch is CancellationError {
            return ExportResult(
                requestedBookCount: 0,
                successCount: 0,
                failures: [ExportFailure(
                    bookID: nil,
                    bookName: nil,
                    target: request.target,
                    message: "导出已取消",
                    disposition: .nonRetryable
                )],
                artifactTicket: nil
            )
        } catch {
            return ExportResult(
                requestedBookCount: 0,
                successCount: 0,
                failures: [failure(from: error, target: request.target)],
                artifactTicket: nil
            )
        }
    }

    /// 本地文件只写入任务专属临时目录，全部写入成功后才创建票据交给分享/保存界面。
    private func makeLocalArtifacts(
        request: ExportRequest,
        snapshot: ExportSnapshot,
        reporter: ExportProgressReporter
    ) async throws -> ArtifactTicket {
        await reporter.publish(.init(
            phase: .generating,
            completedUnits: 0,
            totalUnits: snapshot.books.count,
            message: "正在生成 \(request.target.title)"
        ), force: true)
        let files: [ExportGeneratedFile]
        if request.target == .csv {
            var allocator = ExportFileNameAllocator()
            let title: String
            if case let .collectionID(id) = request.scope {
                title = try await snapshotRepository.collectionName(id)
            } else {
                title = "全部书籍"
            }
            files = [.init(
                name: try allocator.allocate(title: title, extension: "csv"),
                data: ExportCSVGenerator.generate(
                    snapshot: snapshot,
                    fields: request.settings.bookFields,
                    localeIdentifier: request.localeIdentifier,
                    timeZoneIdentifier: request.timeZoneIdentifier
                ),
                mediaType: "text/csv; charset=utf-8"
            )]
        } else if request.target == .pdf {
            var allocator = ExportFileNameAllocator()
            let generator = ExportPDFGenerator()
            var generated: [ExportGeneratedFile] = []
            for (index, book) in snapshot.books.enumerated() {
                try Task.checkCancellation()
                let data = try await generator.generate(
                    book: book,
                    settings: request.settings,
                    localeIdentifier: request.localeIdentifier,
                    timeZoneIdentifier: request.timeZoneIdentifier
                )
                generated.append(.init(
                    name: try allocator.allocate(title: book.book.name, extension: "pdf"),
                    data: data,
                    mediaType: "application/pdf"
                ))
                await reporter.publish(.init(
                    phase: .generating,
                    completedUnits: index + 1,
                    totalUnits: snapshot.books.count,
                    message: "已生成 \(index + 1)/\(snapshot.books.count) 本 PDF"
                ))
            }
            files = generated
        } else {
            files = try exportService.generateLocalFiles(
                snapshot: snapshot,
                target: request.target,
                settings: request.settings,
                localeIdentifier: request.localeIdentifier,
                timeZoneIdentifier: request.timeZoneIdentifier
            )
        }
        guard !files.isEmpty else { throw ExportRepositoryError.noContent }

        let rootURL = fileManager.temporaryDirectory
            .appending(path: "xmnote_export_\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            var artifacts: [ExportArtifact] = []
            artifacts.reserveCapacity(files.count)
            for file in files {
                try Task.checkCancellation()
                let url = rootURL.appending(path: file.name, directoryHint: .notDirectory)
                try file.data.write(to: url, options: .atomic)
                artifacts.append(ExportArtifact(
                    fileName: file.name,
                    mediaType: file.mediaType,
                    fileURL: url
                ))
            }
            return ArtifactTicket(rootURL: rootURL, artifacts: artifacts)
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    /// 远端调用先冻结凭据，再由 Service 逐书串行处理；Notion 自身在 Service 内按最多三本并发规则调度。
    private func exportRemote(
        request: ExportRequest,
        snapshot: ExportSnapshot,
        reporter: ExportProgressReporter
    ) async throws -> ExportResult {
        await reporter.publish(.init(
            phase: .uploading,
            completedUnits: 0,
            totalUnits: snapshot.books.count,
            message: "正在导出到 \(request.target.title)"
        ), force: true)
        let result = try await exportService.exportSnapshotRemotely(
            snapshot,
            request: request,
            credential: try await credentialSnapshot()
        ) { completed, total, message in
            Task {
                await reporter.publish(.init(
                    phase: .uploading,
                    completedUnits: completed,
                    totalUnits: total,
                    message: message
                ))
            }
        }
        return ExportResult(
            requestedBookCount: snapshot.books.count,
            successCount: result.successCount,
            failures: result.failures,
            artifactTicket: nil
        )
    }

    /// 冻结本次任务真正需要的 Keychain 值；该结构不持久化、不编码也不返回给界面。
    private func credentialSnapshot() async throws -> ExportCredentialSnapshot {
        try await ExportCredentialSnapshot(
            yuqueToken: credentialStore.value(for: .yuqueToken) ?? "",
            notionAccessToken: credentialStore.value(for: .notionAccessToken) ?? "",
            notionRefreshToken: credentialStore.value(for: .notionRefreshToken) ?? "",
            notionConnectionKey: defaults.string(
                forKey: NotionOAuthBrokerService.connectionKeyDefaultsKey
            ) ?? "",
            notionDataInstanceID: defaults.string(
                forKey: NotionOAuthBrokerService.dataInstanceIDDefaultsKey
            ) ?? "",
            siYuanToken: credentialStore.value(for: .siYuanToken) ?? "",
            obsidianAPIKey: credentialStore.value(for: .obsidianAPIKey) ?? ""
        )
    }

    /// Repository 层重复执行界面门禁，阻止原生、Web 或未来调用方绕过会员与目标组合限制。
    private func validate(_ request: ExportRequest) throws {
        guard request.target.supports(request.kind) else {
            throw ExportRepositoryError.unsupportedTarget
        }
        guard !request.target.requiresPremium || request.isPremium else {
            throw ExportRepositoryError.premiumRequired
        }
        if request.kind == .noteExcerpt, !request.settings.content.hasSelection {
            throw ExportRepositoryError.noContentSelection
        }
    }

    /// 将底层错误转换为不泄露配置值的结构化失败，并区分超时后的结果不确定状态。
    private func failure(from error: Error, target: ExportTarget) -> ExportFailure {
        let disposition: ExportFailureDisposition
        if let urlError = error as? URLError, urlError.code == .timedOut, !target.isLocalFile {
            disposition = .resultUncertain
        } else if error is CancellationError || error is ExportRepositoryError {
            disposition = .nonRetryable
        } else {
            disposition = .retryable
        }
        return ExportFailure(
            bookID: nil,
            bookName: nil,
            target: target,
            message: error.localizedDescription.isEmpty ? "导出失败" : error.localizedDescription,
            disposition: disposition
        )
    }
}

/// 执行期凭据快照只在内存中跨 Service 边界传递。
nonisolated struct ExportCredentialSnapshot: Sendable {
    let yuqueToken: String
    let notionAccessToken: String
    let notionRefreshToken: String
    let notionConnectionKey: String
    let notionDataInstanceID: String
    let siYuanToken: String
    let obsidianAPIKey: String
}

/// 统一导出前置错误，均可在用户修改范围、会员或设置后重新发起新任务。
enum ExportRepositoryError: LocalizedError {
    case unsupportedTarget
    case premiumRequired
    case noContentSelection
    case noBooks
    case noContent

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget: "导出类型与目标不匹配"
        case .premiumRequired: "该导出目标需要高级版"
        case .noContentSelection: "导出内容请至少选择一项"
        case .noBooks: "没有可导出的书籍"
        case .noContent: "没有可导出的内容，请检查所选类别是否有数据"
        }
    }
}

/// 进度发布 actor 以单调时间间隔限制到最高 10Hz；强制阶段边界不受节流影响。
private actor ExportProgressReporter {
    private let handler: @Sendable (ExportProgress) -> Void
    private var lastPublishedAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init(handler: @escaping @Sendable (ExportProgress) -> Void) {
        self.handler = handler
    }

    /// actor 串行保证相邻进度至少间隔 100ms；阶段边界会等待下一个时隙而不是突破 10Hz 上限。
    func publish(_ value: ExportProgress, force: Bool = false) async {
        var now = clock.now
        if let lastPublishedAt {
            let elapsed = lastPublishedAt.duration(to: now)
            if elapsed < .milliseconds(100) {
                guard force else { return }
                try? await Task.sleep(for: .milliseconds(100) - elapsed)
                now = clock.now
            }
        }
        lastPublishedAt = now
        handler(value)
    }
}
