/**
 * [INPUT]: 依赖可选 AppRuntimeContext、数据库初始化错误、AppState、UISceneSession 标识、SceneStateStore、SceneStorage 与耐久快照
 * [OUTPUT]: 对外提供 ContentView，在原子恢复完成前挂载中性不可交互壳层，并把每次编码结果同步提交到双层 scene 存储
 * [POS]: Views 顶层恢复门控，以系统 scene 身份隔离正常恢复与异常终止恢复，阻止空栈首帧和晚恢复覆盖
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

//
//  ContentView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import Foundation
import OSLog
import SwiftUI
import UIKit

/// 应用根视图，挂载主 Tab 导航骨架并统一品牌色 tint。
struct ContentView: View {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "XMNote",
        category: "SceneState"
    )

    @Environment(AppState.self) private var appState
    @Environment(SceneStateStore.self) private var sceneStateStore
    @SceneStorage("xmnote.scene.snapshot") private var persistedSceneData: Data?
    @State private var sceneSessionIdentifier: String?
    private let sceneSnapshotArchive = SceneSnapshotArchive()
    let runtime: AppRuntimeContext?
    let initializationError: Error?

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            if let initializationError {
                DatabaseInitializationFailureView(error: initializationError)
            } else if sceneStateStore.isRestored,
                      sceneStateStore.snapshot.dataEpoch == appState.dataEpoch {
                MainTabView(
                    runtime: runtime,
                    initialSceneSnapshot: sceneStateStore.snapshot
                )
                .id(appState.dataEpoch)
                .tint(Color.brand)
            } else {
                SceneRestorationBootstrapView()
            }
        }
        .background {
            SceneSessionIdentityReader { identifier in
                guard sceneSessionIdentifier == nil else { return }
                sceneSessionIdentifier = identifier
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .task(id: restorationTaskID) {
            guard let sceneSessionIdentifier else { return }
            connectScenePersistence(for: sceneSessionIdentifier)
            restoreSceneIfNeeded(sessionIdentifier: sceneSessionIdentifier)
        }
        .onDisappear {
            sceneStateStore.disconnectPersistenceSink()
        }
    }

    /// 将 store 的每次成功编码直接写入当前 scene，避免通过 onChange 间接桥接时遗漏快速路径变更。
    private func connectScenePersistence(for sessionIdentifier: String) {
        sceneStateStore.connectPersistenceSink { data in
            do {
                try sceneSnapshotArchive.save(data, for: sessionIdentifier)
            } catch {
                Self.logger.error(
                    "Durable scene snapshot write failed reason=\(error.localizedDescription, privacy: .public)"
                )
            }
            guard persistedSceneData != data else { return }
            persistedSceneData = data
        }
    }

    /// 首次装载读取当前 scene 快照；数据库世界切换时只失效旧路径，不重复覆盖同一会话的运行态。
    private func restoreSceneIfNeeded(sessionIdentifier: String) {
        if !sceneStateStore.isRestored {
            sceneStateStore.restore(
                from: sceneDataForInitialRestoration(sessionIdentifier: sessionIdentifier),
                currentDataEpoch: appState.dataEpoch
            )
        } else if sceneStateStore.snapshot.dataEpoch != appState.dataEpoch {
            sceneStateStore.resetForDataEpoch(appState.dataEpoch)
        }

        if persistedSceneData != sceneStateStore.persistedData {
            persistedSceneData = sceneStateStore.persistedData
        }
    }

    /// DEBUG UI Test 可在首轮启动清空旧现场；生产构建始终读取系统提供的当前 scene 数据。
    private func sceneDataForInitialRestoration(sessionIdentifier: String) -> Data? {
#if DEBUG
        if UITestLaunchConfiguration.shouldResetSceneState {
            return nil
        }
#endif
        do {
            if let archived = try sceneSnapshotArchive.load(for: sessionIdentifier) {
                return archived
            }
        } catch {
            Self.logger.error(
                "Durable scene snapshot read failed; falling back to SceneStorage reason=\(error.localizedDescription, privacy: .public)"
            )
        }
        return persistedSceneData
    }

    private var restorationTaskID: SceneRestorationTaskID {
        SceneRestorationTaskID(
            dataEpoch: appState.dataEpoch,
            sessionIdentifier: sceneSessionIdentifier
        )
    }
}

/// Scene 身份和快照尚未共同就绪时只呈现中性表面，避免把首页骨架误认为已恢复的真实根页。
private struct SceneRestorationBootstrapView: View {
    var body: some View {
        Color.surfacePage
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 恢复任务身份同时包含数据世界与系统 scene；任一变化都重新建立对应存储连接。
private struct SceneRestorationTaskID: Hashable {
    let dataEpoch: Int
    let sessionIdentifier: String?
}

/// 通过零尺寸 UIKit 探针读取当前窗口的 UISceneSession 持久标识，供多窗口快照隔离使用。
private struct SceneSessionIdentityReader: UIViewRepresentable {
    let onResolve: @MainActor (String) -> Void

    /// 创建只负责读取所属 UIWindowScene 的透明探针，不参与页面布局或交互。
    func makeUIView(context: Context) -> SceneSessionIdentityProbeView {
        SceneSessionIdentityProbeView(onResolve: onResolve)
    }

    /// SwiftUI 重算不会改变探针职责，回调只更新为当前 scene 根视图持有的闭包。
    func updateUIView(_ uiView: SceneSessionIdentityProbeView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfPossible()
    }
}

/// 在进入真实 UIWindow 后发布会话标识；同一实例只发布一次，防止布局刷新重复触发恢复。
private final class SceneSessionIdentityProbeView: UIView {
    var onResolve: @MainActor (String) -> Void
    private var resolvedIdentifier: String?

    init(onResolve: @escaping @MainActor (String) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 窗口归属建立后立即读取 UISceneSession；UIKit 在主线程调用，异步发布避开当前视图更新事务。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveIfPossible()
    }

    /// 仅在窗口已有 scene 且标识尚未发布时提交一次，避免同一恢复任务被重复启动。
    func resolveIfPossible() {
        guard let identifier = window?.windowScene?.session.persistentIdentifier,
              resolvedIdentifier != identifier else { return }
        resolvedIdentifier = identifier
        DispatchQueue.main.async { [weak self] in
            self?.onResolve(identifier)
        }
    }
}

/// 数据库初始化失败页保留现有错误语义，在导航启动壳层无法继续替换时明确告知失败原因。
private struct DatabaseInitializationFailureView: View {
    let error: Error

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "exclamationmark.triangle")
                .font(AppTypography.largeTitle)
                .foregroundStyle(Color.feedbackError)
            Text("数据库初始化失败")
                .font(AppTypography.headline)
            Text(error.localizedDescription)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.double)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView(runtime: nil, initializationError: nil)
        .environment(AppState())
        .environment(SceneStateStore())
        .environment(BookCollectionImportRouter())
        .environment(ReadingTimerDeepLinkRouter())
        .environment(DesktopWebSessionCoordinator())
        .environment(ReadingTimerSettingsStore())
        .environment(XMToastCenter())
}
