/**
 * [INPUT]: 依赖 ExportRepositoryProtocol、ExportRoute 与会员快照，接收页面配置、执行和交付动作
 * [OUTPUT]: 对外提供 ExportViewModel，统一管理选择、配置、预检、执行、结果与 ArtifactTicket 生命周期
 * [POS]: ViewModels/Export 的页面状态 owner；不直接访问数据库、网络、Keychain 或文件生成器
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 导出页面阶段把配置流程与不可恢复的执行现场分离。
nonisolated enum ExportPagePhase: Equatable, Sendable {
    case loading
    case configuring
    case running
    case result
}

/// 统一导出页面状态 owner；所有异步结果回到 MainActor，取消只终止当前任务且不会复用半成品文件。
@MainActor @Observable
final class ExportViewModel {
    var kind: ExportKind
    var scope: ExportScope
    var target: ExportTarget
    var settings = ExportSettingsSnapshot.androidDefault
    var step: ExportConfigurationStep
    var phase: ExportPagePhase = .loading
    var progress = ExportProgress(
        phase: .preflighting,
        completedUnits: 0,
        totalUnits: 1,
        message: "正在准备导出"
    )
    var result: ExportResult?
    var errorMessage: String?
    var showsShareSheet = false
    var showsDocumentPicker = false
    var showsNotionPageRebuildConfirmation = false
    var pendingCredential = ""
    var isCredentialConfigured = false

    private let repository: any ExportRepositoryProtocol
    private let isPremium: Bool
    @ObservationIgnored
    nonisolated(unsafe) private var exportTask: Task<Void, Never>?

    init(
        route: ExportRoute,
        repository: any ExportRepositoryProtocol,
        isPremium: Bool
    ) {
        kind = route.initialKind
        scope = route.scope
        step = route.initialStep
        self.repository = repository
        self.isPremium = isPremium
        let candidates = ExportTarget.supportedTargets(for: route.initialKind)
        target = route.initialTarget.flatMap { candidates.contains($0) ? $0 : nil }
            ?? candidates.first
            ?? .markdown
    }

    deinit {
        exportTask?.cancel()
    }

    /// 读取 Repository 中经过明文迁移和归一化的设置；任务取消时不覆盖当前页面草稿。
    func load() async {
        do {
            let loaded = try await repository.settings()
            guard !Task.isCancelled else { return }
            settings = loaded
            target = preferredTarget(from: loaded)
            await refreshCredentialStatus()
            phase = .configuring
        } catch {
            errorMessage = error.localizedDescription
            phase = .configuring
        }
    }

    /// 切换导出类型时选用该类型上次的稳定目标，若设置已失效则回退首个支持目标。
    func selectKind(_ value: ExportKind) {
        kind = value
        target = preferredTarget(from: settings)
        pendingCredential = ""
        Task { await refreshCredentialStatus() }
    }

    /// 切换目标并刷新脱敏连接状态；不会从 Keychain读取凭据明文。
    func selectTarget(_ value: ExportTarget) {
        guard value.supports(kind) else { return }
        target = value
        pendingCredential = ""
        Task { await refreshCredentialStatus() }
    }

    /// 保存远端目标的凭据草稿；Notion 与 OneNote 必须走授权流程，不接受手填令牌。
    func savePendingCredential() async {
        guard let credential = editableCredential else { return }
        do {
            try await repository.saveCredential(pendingCredential, for: credential)
            pendingCredential = ""
            await refreshCredentialStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 远端账户连接由 Repository 隐藏 token 与认证 SDK；页面只刷新脱敏连接状态。
    func connectCurrentAccount() async {
        do {
            switch target {
            case .notion:
                try await repository.connectNotion()
            case .oneNote:
                try await repository.connectOneNote()
            case .yuque, .siYuan, .obsidian, .pdf, .markdown, .text, .csv:
                return
            }
            await refreshCredentialStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 进入下一配置步骤；设置会在离开配置页时保存，但运行任务只使用点击执行时的快照。
    func advance() async {
        if let next = ExportConfigurationStep(rawValue: step.rawValue + 1) {
            step = next
            return
        }
        await startExport()
    }

    func goBack() {
        guard let previous = ExportConfigurationStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// 保存设置并启动一次冻结请求；进度闭包跨 actor 时只把 Sendable 值投递回 MainActor。
    func startExport(
        scopeOverride: ExportScope? = nil,
        confirmedNotionPageRebuildBookIDs: Set<Int64> = []
    ) async {
        guard phase != .running else { return }
        if target.requiresPremium, !isPremium {
            errorMessage = "\(target.title) 导出需要高级版"
            return
        }
        do {
            updateLastTarget()
            try await repository.saveSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        result?.artifactTicket?.cleanup()
        result = nil
        phase = .running
        let request = ExportRequest(
            kind: kind,
            scope: scopeOverride ?? scope,
            target: target,
            settings: settings,
            isPremium: isPremium,
            confirmedNotionPageRebuildBookIDs: confirmedNotionPageRebuildBookIDs
        )
        exportTask = Task { [weak self, repository] in
            let value = await repository.export(request) { progress in
                Task { @MainActor [weak self] in
                    self?.progress = progress
                }
            }
            guard !Task.isCancelled else { return }
            self?.result = value
            self?.phase = .result
            self?.exportTask = nil
        }
    }

    /// 取消只作用于当前运行任务；Repository 会清理尚未交付的任务目录。
    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        result = nil
        phase = .configuring
        step = .preflight
    }

    /// 分享或保存回调结束后统一清理票据，保证系统控制器使用文件期间文件仍然存在。
    func finishArtifactDelivery() {
        showsShareSheet = false
        showsDocumentPicker = false
        result?.artifactTicket?.cleanup()
        result = nil
        phase = .configuring
        step = .preflight
    }

    func retry() async {
        await startExport()
    }

    /// 用户明确确认后只重新处理被 Notion 删除的托管页，不重复导出整批中的成功书籍。
    func rebuildDeletedNotionPages() async {
        let bookIDs = result?.notionPageRebuildBookIDs ?? []
        guard !bookIDs.isEmpty else { return }
        showsNotionPageRebuildConfirmation = false
        await startExport(
            scopeOverride: .bookIDs(Array(bookIDs).sorted()),
            confirmedNotionPageRebuildBookIDs: bookIDs
        )
    }

    var canAdvance: Bool {
        switch step {
        case .scope:
            true
        case .target:
            !target.requiresPremium || isPremium
        case .configuration:
            kind != .noteExcerpt || settings.content.hasSelection
        case .preflight:
            true
        }
    }

    var isPremiumAccessAvailable: Bool {
        isPremium
    }

    var editableCredential: ExportCredential? {
        switch target {
        case .yuque: .yuqueToken
        case .siYuan: .siYuanToken
        case .obsidian: .obsidianAPIKey
        case .notion, .oneNote, .pdf, .markdown, .text, .csv: nil
        }
    }

    var localArtifactURLs: [URL] {
        result?.artifactTicket?.artifacts.map(\.fileURL) ?? []
    }

    private func preferredTarget(from value: ExportSettingsSnapshot) -> ExportTarget {
        let preferred = kind == .noteExcerpt ? value.lastNoteTarget : value.lastBookTarget
        return preferred.supports(kind)
            ? preferred
            : ExportTarget.supportedTargets(for: kind).first ?? .markdown
    }

    private func updateLastTarget() {
        if kind == .noteExcerpt {
            settings.lastNoteTarget = target
        } else {
            settings.lastBookTarget = target
        }
    }

    /// 只查询 Keychain 是否存在当前凭据；actor 调用不阻塞主线程且不返回秘密内容。
    private func refreshCredentialStatus() async {
        guard let editableCredential else {
            switch target {
            case .notion:
                isCredentialConfigured = await repository.hasCredential(.notionAccessToken)
            case .oneNote:
                isCredentialConfigured = await repository.hasCredential(.oneNoteAccount)
            case .yuque, .siYuan, .obsidian, .pdf, .markdown, .text, .csv:
                isCredentialConfigured = true
            }
            return
        }
        isCredentialConfigured = await repository.hasCredential(editableCredential)
    }
}
