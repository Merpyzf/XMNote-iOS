/**
 * [INPUT]: 依赖 XMNoteWeb.DesktopWebServer、LocalNetworkEndpointProvider、BonjourServicePublisher、UIKit 与 App scenePhase
 * [OUTPUT]: 对外提供 App 级网页服务开关、六态会话状态、前后台恢复、局域网端点和有限后台收尾
 * [POS]: Services 的桌面网页会话唯一 owner，页面离开后仍由 App 根层持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation
import SwiftUI
import UIKit
import XMNoteWeb

/// 桌面网页会话的唯一可观察状态，避免 UI 把“启动任务已创建”误当成 socket 已监听。
nonisolated enum DesktopWebSessionState: Equatable, Sendable {
    case stopped
    case starting
    case waitingForLocalNetwork
    case running(endpoints: [LocalNetworkEndpoint])
    case stopping
    case failed(message: String)

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
    private static let enabledDefaultsKey = "desktopWebSession.isEnabled"
    private static let port = 8090

    private(set) var state: DesktopWebSessionState = .stopped
    private(set) var isEnabled: Bool
    private(set) var bonjourServiceName: String?

    private let server = DesktopWebServer()
    private var endpointProvider: LocalNetworkEndpointProvider?
    private let bonjourPublisher = BonjourServicePublisher()
    private let defaults: UserDefaults
    private var isAppActive = false
    private var operationGeneration = 0
    private var latestEndpoints: [LocalNetworkEndpoint] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    /// 保存用户偏好并立即调和前台会话；每次切换递增 generation，使旧异步启动结果无法覆盖新意图。
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            if enabled, case .failed = state {
                retry()
            }
            return
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
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

    /// 从失败或等待态重新启动；取消语义由 generation 裁决，旧回调不能写回当前状态。
    func retry() {
        guard isEnabled, isAppActive, !state.isTransitioning else { return }
        operationGeneration += 1
        let generation = operationGeneration
        Task { @MainActor [weak self] in
            await self?.stopInfrastructure(gracePeriod: .zero)
            guard let self, generation == self.operationGeneration else { return }
            await self.start(generation: generation)
        }
    }

    /// 处理 App scene 生命周期：inactive 保持不动，background 有限收尾，active 按保存开关自动恢复。
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
        bonjourServiceName = nil

        do {
            try await server.start(port: Self.port) { [weak self] message in
                await self?.handleRuntimeFailure(message)
            }
        } catch {
            guard generation == operationGeneration else { return }
            state = .failed(message: error.localizedDescription)
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
        bonjourPublisher.start(
            port: Self.port,
            onNameChange: { [weak self] name in
                self?.bonjourServiceName = name
            },
            onFailure: { [weak self] message in
                self?.handleBonjourFailure(message, generation: generation)
            }
        )
        state = .waitingForLocalNetwork
    }

    /// 根据最新路径切换 waiting/running；仅接受当前 generation 的回调，阻止 stop 后迟到写入。
    private func receiveEndpoints(_ endpoints: [LocalNetworkEndpoint], generation: Int) {
        guard generation == operationGeneration, isEnabled, isAppActive else { return }
        latestEndpoints = endpoints
        state = endpoints.isEmpty ? .waitingForLocalNetwork : .running(endpoints: endpoints)
    }

    /// DNS-SD 发布失败意味着系统发现能力不可用；停止同一会话并进入可重试失败态。
    private func handleBonjourFailure(_ message: String, generation: Int) {
        guard generation == operationGeneration, isEnabled else { return }
        operationGeneration += 1
        let failureGeneration = operationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await stopInfrastructure(gracePeriod: .zero)
            guard failureGeneration == operationGeneration else { return }
            state = .failed(message: message)
        }
    }

    /// 接收 listener 运行期故障，统一关闭伴随基础设施并保留用户开关供重新尝试。
    private func handleRuntimeFailure(_ message: String) async {
        operationGeneration += 1
        bonjourPublisher.stop()
        endpointProvider?.stop()
        endpointProvider = nil
        latestEndpoints = []
        bonjourServiceName = nil
        UIApplication.shared.isIdleTimerDisabled = false
        state = .failed(message: message)
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
        bonjourServiceName = nil
        UIApplication.shared.isIdleTimerDisabled = false
        await server.stop(gracePeriod: gracePeriod)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
