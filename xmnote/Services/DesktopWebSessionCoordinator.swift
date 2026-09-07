/**
 * [INPUT]: 依赖 XMNoteWeb.DesktopWebServer、Web API Adapter/设置仓储、MembershipRepository 实时会员权益、LocalNetworkEndpointProvider、固定域名 BonjourServicePublisher、UIKit 与 App scenePhase
 * [OUTPUT]: 对外提供当前会话/自动启动独立开关、六态会话状态、访问安全状态、实时会员裁决、可一次消费的原生高级版请求、固定局域网域名与有限后台收尾
 * [POS]: Services 的桌面网页会话唯一 owner，页面离开后仍由 App 根层持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation
import SwiftUI
import UIKit
import XMNoteWeb

/// 网页端当前可访问地址；固定域名不可用时保留 IP 端点与可解释的回退原因。
nonisolated struct DesktopWebAccessAddresses: Equatable, Sendable {
    let domainURL: URL?
    let ipEndpoints: [LocalNetworkEndpoint]
    let domainStatusMessage: String?

    nonisolated var isSimulatorOnly: Bool {
        !ipEndpoints.isEmpty
            && ipEndpoints.allSatisfy { $0.interfaceName == "simulator-loopback" }
    }

    /// 应用 DNS-SD 非权限事件；权限拒绝由会话 owner 转入失败态，不在地址值内吞掉。
    nonisolated func applying(
        _ event: BonjourServicePublisherEvent
    ) -> DesktopWebAccessAddresses {
        switch event {
        case .published(let url):
            return DesktopWebAccessAddresses(
                domainURL: url,
                ipEndpoints: ipEndpoints,
                domainStatusMessage: nil
            )
        case .unavailable(let message):
            return DesktopWebAccessAddresses(
                domainURL: nil,
                ipEndpoints: ipEndpoints,
                domainStatusMessage: message
            )
        case .policyDenied:
            return self
        }
    }
}

/// 网页服务失败的用户可见原因和下一步动作，避免页面根据展示文案猜测恢复方式。
nonisolated struct DesktopWebSessionFailure: Equatable, Sendable {
    /// 失败后的唯一主恢复动作；普通故障重试，权限故障引导系统设置。
    nonisolated enum Recovery: Equatable, Sendable {
        case retry
        case openSettings
    }

    let message: String
    let recovery: Recovery
}

/// 桌面网页会话的唯一可观察状态，避免 UI 把“启动任务已创建”误当成 socket 已监听。
nonisolated enum DesktopWebSessionState: Equatable, Sendable {
    case stopped
    case starting
    case waitingForLocalNetwork
    case running(addresses: DesktopWebAccessAddresses)
    case stopping
    case failed(DesktopWebSessionFailure)

    nonisolated var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    nonisolated var isTransitioning: Bool {
        self == .starting || self == .stopping
    }
}

/// 在 App 生命周期持有 HTTP、网络路径与 Bonjour，统一裁决用户开关和 scene 变化产生的竞态。
@MainActor
@Observable
final class DesktopWebSessionCoordinator {
    private static let autoStartDefaultsKey = "desktopWebSession.isEnabled"
    private static let port = 8090
    #if DEBUG
    private static let parityDatabasePathEnvironment = "XMNOTE_WEB_PARITY_DATABASE_PATH"
    private static let parityDefaultsSuiteEnvironment = "XMNOTE_WEB_PARITY_DEFAULTS_SUITE"
    private static let parityAccessAuthEnabledEnvironment =
        "XMNOTE_WEB_PARITY_ACCESS_AUTH_ENABLED"
    private static let parityAccessCodeEnvironment = "XMNOTE_WEB_PARITY_ACCESS_CODE"
    #endif

    private(set) var state: DesktopWebSessionState = .stopped
    private(set) var isEnabled: Bool
    private(set) var isAutoStartEnabled: Bool
    private(set) var isAccessAuthEnabled = true
    private(set) var accessAuthCode = ""
    private(set) var premiumUpgradeRequestID: UUID?

    private let server: DesktopWebServer
    private var endpointProvider: LocalNetworkEndpointProvider?
    private let bonjourPublisher = BonjourServicePublisher()
    private let defaults: UserDefaults
    private let settingsRepository: DesktopWebSettingsRepository
    private let nativeActionBridge: DesktopWebNativeActionBridge
    private let apiAdapter: DesktopWebAPIAdapter
    private let isPremiumProvider: @Sendable () async -> Bool
    private var isAppActive = false
    private var operationGeneration = 0
    private var latestEndpoints: [LocalNetworkEndpoint] = []

    init(defaults explicitDefaults: UserDefaults? = nil, membership: any MembershipRepositoryProtocol = MembershipRepository.shared) {
        let runtimeDefaults = Self.makeRuntimeDefaults(explicit: explicitDefaults)
        let defaults = runtimeDefaults.defaults
        let settingsRepository = DesktopWebSettingsRepository(defaults: defaults)
        let nativeActionBridge = DesktopWebNativeActionBridge()
        let isPremiumProvider: @Sendable () async -> Bool = {
            await membership.hasPremiumAccess()
        }
        let apiAdapter = DesktopWebAPIAdapter(
            repository: settingsRepository,
            nativeActionBridge: nativeActionBridge,
            defaults: defaults,
            isPremiumProvider: isPremiumProvider
        )
        self.defaults = defaults
        self.settingsRepository = settingsRepository
        self.nativeActionBridge = nativeActionBridge
        self.apiAdapter = apiAdapter
        self.isPremiumProvider = isPremiumProvider
        self.server = DesktopWebServer(
            apiDependencies: DesktopWebAPIDependencies(
                requestGate: apiAdapter,
                settings: apiAdapter,
                source: apiAdapter,
                tag: apiAdapter,
                group: apiAdapter,
                book: apiAdapter,
                bookshelf: apiAdapter,
                calendar: apiAdapter,
                chapter: apiAdapter,
                note: apiAdapter,
                related: apiAdapter,
                review: apiAdapter,
                readingRecord: apiAdapter,
                search: apiAdapter,
                statistics: apiAdapter,
                ai: apiAdapter,
                onlineBook: apiAdapter,
                bookCover: apiAdapter,
                export: apiAdapter,
                importTask: apiAdapter,
                upload: apiAdapter
            )
        )
        let isAutoStartEnabled =
            runtimeDefaults.isParityLaunch || defaults.bool(forKey: Self.autoStartDefaultsKey)
        self.isAutoStartEnabled = isAutoStartEnabled
        self.isEnabled = isAutoStartEnabled
        nativeActionBridge.onOpenPremiumUpgrade = { [weak self] in
            self?.premiumUpgradeRequestID = UUID()
        }
    }

    /// 为 DEBUG 双端一致性启动创建独立 UserDefaults suite，并预置可重复的授权边界；普通启动继续使用标准域。
    private static func makeRuntimeDefaults(
        explicit: UserDefaults?
    ) -> (defaults: UserDefaults, isParityLaunch: Bool) {
        if let explicit {
            return (explicit, false)
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let databasePath = environment[parityDatabasePathEnvironment]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !databasePath.isEmpty {
            let suiteName = environment[parityDefaultsSuiteEnvironment]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSuiteName = suiteName.flatMap { value in
                value.isEmpty ? nil : value
            } ?? "com.merpyzf.xmnote.web-api-parity"
            let parityDefaults = UserDefaults(suiteName: resolvedSuiteName) ?? .standard
            parityDefaults.set(
                environment[parityAccessAuthEnabledEnvironment] == "1",
                forKey: "desktopWeb.api.accessAuthEnabled"
            )
            if let accessCode = environment[parityAccessCodeEnvironment]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !accessCode.isEmpty {
                parityDefaults.set(accessCode, forKey: "desktopWeb.api.accessAuthCode")
            }
            return (parityDefaults, true)
        }
        #endif
        return (.standard, false)
    }

    /// 原子消费网页端高级版跳转请求，确保共享会话被多个 scene 观察时最多只有一个场景响应。
    func consumePremiumUpgradeRequest(_ requestID: UUID) -> Bool {
        guard premiumUpgradeRequestID == requestID else { return false }
        premiumUpgradeRequestID = nil
        return true
    }

    /// 在数据库与 App Repository 完成组装后安装全部 Web 能力，确保自动启动前路由已有真实数据源。
    func configure(database: AppDatabase, repositories: RepositoryContainer) {
        let uploadService = DesktopWebUploadService(
            configRepository: repositories.s3ConfigRepository,
            uploadRepository: repositories.s3UploadRepository,
            defaults: defaults,
            isPremiumProvider: isPremiumProvider
        )
        let importService = DesktopWebImportService(
            repository: repositories.noteImportRepository
        )
        let exportService = DesktopWebUnifiedExportAdapter(
            repository: repositories.exportRepository,
            isPremiumProvider: isPremiumProvider
        )
        apiAdapter.configureExternalServices(
            export: exportService,
            importTask: importService,
            upload: uploadService
        )
        apiAdapter.configure(database: database)
    }

    /// 从 Repository actor 刷新访问安全状态；页面任务取消只会放弃 UI 回写，不改变已保存配置。
    func refreshAccessAuthSettings() async {
        let snapshot = await settingsRepository.accessAuthSnapshot()
        guard !Task.isCancelled else { return }
        isAccessAuthEnabled = snapshot.isEnabled
        accessAuthCode = snapshot.accessCode
    }

    /// 保存访问授权开关并同步页面状态；关闭授权不会清除已生成的访问码。
    func setAccessAuthEnabled(_ enabled: Bool) async {
        await settingsRepository.setAccessAuthEnabled(enabled)
        guard !Task.isCancelled else { return }
        isAccessAuthEnabled = enabled
    }

    /// 校验并保存访问码；失败直接抛给页面使用 XMSystemAlert 展示。
    func setAccessAuthCode(_ code: String) async throws {
        try await settingsRepository.setAccessCode(code)
        guard !Task.isCancelled else { return }
        accessAuthCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 使用系统随机源重置访问码并回写页面；该变更会立即影响后续 API 请求。
    func resetAccessAuthCode() async {
        let code = await settingsRepository.resetAccessCode()
        guard !Task.isCancelled else { return }
        accessAuthCode = code
    }

    /// 更新当前 App 会话的运行意图并立即调和前台服务；不改写下次冷启动偏好。
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            if enabled, case .failed = state {
                retry()
            }
            return
        }
        isEnabled = enabled
        operationGeneration += 1
        let generation = operationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            if enabled, isAppActive {
                await start(generation: generation)
            } else if !enabled {
                await stop(generation: generation, forBackground: false)
            }
        }
    }

    /// 保存冷启动自动开启偏好；沿用历史开关键，避免升级后丢失老用户的自动恢复选择。
    func setAutoStartEnabled(_ enabled: Bool) {
        guard isAutoStartEnabled != enabled else { return }
        isAutoStartEnabled = enabled
        defaults.set(enabled, forKey: Self.autoStartDefaultsKey)
    }

    /// 从失败或等待态重新启动；取消语义由 generation 裁决，旧回调不能写回当前状态。
    func retry() {
        guard isAppActive, !state.isTransitioning else { return }
        isEnabled = true
        operationGeneration += 1
        let generation = operationGeneration
        Task { @MainActor [weak self] in
            await self?.stopInfrastructure(gracePeriod: .zero)
            guard let self, generation == self.operationGeneration else { return }
            await self.start(generation: generation)
        }
    }

    /// 处理 App scene 生命周期：inactive 保持不动，background 有限收尾，active 按当前会话意图恢复。
    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            isAppActive = true
            guard isEnabled, (state == .stopped || isFailed) else { return }
            operationGeneration += 1
            await start(generation: operationGeneration)
        case .background:
            isAppActive = false
            operationGeneration += 1
            await stop(generation: operationGeneration, forBackground: true)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// 启动静态站并等待真实监听成功，再启用地址监听、Bonjour 与防自动锁屏。
    private func start(generation: Int) async {
        guard generation == operationGeneration,
              isEnabled,
              isAppActive,
              state != .starting,
              !state.isRunning else {
            return
        }
        state = .starting
        latestEndpoints = []

        do {
            try await server.start(
                port: Self.port
            ) { [weak self] message in
                await self?.handleRuntimeFailure(message)
            }
        } catch {
            guard generation == operationGeneration else { return }
            isEnabled = false
            state = .failed(Self.failure(for: error.localizedDescription))
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        guard generation == operationGeneration, isEnabled, isAppActive else {
            await server.stop(gracePeriod: .zero)
            return
        }

        UIApplication.shared.isIdleTimerDisabled = true
        let provider = LocalNetworkEndpointProvider()
        endpointProvider = provider
        provider.start(port: Self.port) { [weak self] endpoints in
            self?.receiveEndpoints(endpoints, generation: generation)
        }
        state = .waitingForLocalNetwork
    }

    /// 根据最新路径切换地址并重建固定域名；先清除旧域名，避免网络切换期间展示过期解析。
    private func receiveEndpoints(_ endpoints: [LocalNetworkEndpoint], generation: Int) {
        guard generation == operationGeneration, isEnabled, isAppActive else { return }
        guard endpoints != latestEndpoints else { return }
        latestEndpoints = endpoints
        bonjourPublisher.stop()
        guard !endpoints.isEmpty else {
            state = .waitingForLocalNetwork
            return
        }

        let addresses = DesktopWebAccessAddresses(
            domainURL: nil,
            ipEndpoints: endpoints,
            domainStatusMessage: nil
        )
        state = .running(addresses: addresses)
        guard !addresses.isSimulatorOnly else { return }

        bonjourPublisher.start(
            port: Self.port,
            endpoints: endpoints
        ) { [weak self] event in
            self?.handleBonjourEvent(event, generation: generation)
        }
    }

    /// 普通域名错误只更新 IP 回退说明；系统拒绝本地网络权限时才停止整个网页会话。
    private func handleBonjourEvent(
        _ event: BonjourServicePublisherEvent,
        generation: Int
    ) {
        guard generation == operationGeneration,
              isEnabled,
              isAppActive,
              case .running(let addresses) = state else {
            return
        }
        switch event {
        case .published, .unavailable:
            state = .running(addresses: addresses.applying(event))
        case .policyDenied(let message):
            handleBonjourPolicyDenied(message, generation: generation)
        }
    }

    /// 本地网络权限拒绝会同时影响域名和电脑访问，按可恢复失败态关闭同一 generation 的基础设施。
    private func handleBonjourPolicyDenied(_ message: String, generation: Int) {
        guard generation == operationGeneration, isEnabled else { return }
        operationGeneration += 1
        let failureGeneration = operationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await stopInfrastructure(gracePeriod: .zero)
            guard failureGeneration == operationGeneration else { return }
            isEnabled = false
            state = .failed(
                DesktopWebSessionFailure(
                    message: message,
                    recovery: .openSettings
                )
            )
        }
    }

    /// 接收 listener 运行期故障，统一关闭伴随基础设施并回落当前会话开关。
    private func handleRuntimeFailure(_ message: String) async {
        operationGeneration += 1
        bonjourPublisher.stop()
        endpointProvider?.stop()
        endpointProvider = nil
        latestEndpoints = []
        UIApplication.shared.isIdleTimerDisabled = false
        isEnabled = false
        state = .failed(Self.failure(for: message))
    }

    /// 停止当前会话；后台时申请短暂执行时间，最多等待五秒后立即恢复自动锁屏。
    private func stop(generation: Int, forBackground: Bool) async {
        guard state != .stopped || endpointProvider != nil else {
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        state = .stopping
        UIApplication.shared.isIdleTimerDisabled = false
        let hasInFlightRequests: Bool
        if forBackground {
            hasInFlightRequests = await server.hasInFlightRequests()
        } else {
            hasInFlightRequests = false
        }
        let backgroundTaskID: UIBackgroundTaskIdentifier
        if hasInFlightRequests {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(
                withName: "Finish desktop web requests",
                expirationHandler: nil
            )
        } else {
            backgroundTaskID = .invalid
        }

        await stopInfrastructure(gracePeriod: hasInFlightRequests ? .seconds(5) : .zero)
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
        guard generation == operationGeneration else { return }
        state = .stopped
    }

    /// 按固定顺序停止发现、地址监听与 HTTP，防止 UI 在 socket 关闭后继续展示旧端点。
    private func stopInfrastructure(gracePeriod: Duration) async {
        bonjourPublisher.stop()
        endpointProvider?.stop()
        endpointProvider = nil
        latestEndpoints = []
        UIApplication.shared.isIdleTimerDisabled = false
        await server.stop(gracePeriod: gracePeriod)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// 将底层错误集中归类为重试或系统设置恢复，View 只消费稳定的交互语义。
    private nonisolated static func failure(for message: String) -> DesktopWebSessionFailure {
        let requiresSettings =
            message.contains("本地网络")
            || message.contains("权限")
            || message.contains("系统设置")
            || message.localizedCaseInsensitiveContains("permission")
            || message.localizedCaseInsensitiveContains("prohibited")
        return DesktopWebSessionFailure(
            message: message,
            recovery: requiresSettings ? .openSettings : .retry
        )
    }
}
