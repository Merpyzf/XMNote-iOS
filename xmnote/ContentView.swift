/**
 * [INPUT]: 依赖可选 AppRuntimeContext、MainTabView、AppState 数据版本、SceneStateStore 与 SwiftUI SceneStorage
 * [OUTPUT]: 对外提供 ContentView（常驻应用根壳层），首帧恢复 scene、展示导航启动壳层，并在依赖就绪后原位接入生产页面
 * [POS]: Views 顶层页面容器，负责在数据库初始化前后保持同一导航生命周期并桥接系统 scene 存储
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

//
//  ContentView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import Foundation
import SwiftUI

/// 应用根视图，挂载主 Tab 导航骨架并统一品牌色 tint。
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(SceneStateStore.self) private var sceneStateStore
    @SceneStorage("xmnote.scene.snapshot") private var persistedSceneData: Data?
    let runtime: AppRuntimeContext?
    let initializationError: Error?

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            if let initializationError {
                DatabaseInitializationFailureView(error: initializationError)
            } else {
                MainTabView(
                    runtime: runtime,
                    initialSceneSnapshot: launchSceneSnapshot
                )
                .id(appState.dataEpoch)
                .tint(Color.brand)
            }
        }
        .task(id: appState.dataEpoch) {
            restoreSceneIfNeeded()
        }
        .onChange(of: sceneStateStore.persistedData) { _, newValue in
            guard persistedSceneData != newValue else { return }
            persistedSceneData = newValue
        }
    }

    /// 在 SwiftUI 首次执行 body 时直接从 SceneStorage 推导导航初值，避免先出现默认 Tab 再恢复历史现场。
    private var launchSceneSnapshot: AppSceneSnapshot {
        if sceneStateStore.isRestored {
            return sceneStateStore.snapshot
        }
        guard let persistedSceneData,
              let snapshot = try? JSONDecoder().decode(AppSceneSnapshot.self, from: persistedSceneData),
              snapshot.dataEpoch == appState.dataEpoch else {
            return AppSceneSnapshot.empty(dataEpoch: appState.dataEpoch)
        }
        return snapshot
    }

    /// 首次装载读取当前 scene 快照；数据库世界切换时只失效旧路径，不重复覆盖同一会话的运行态。
    private func restoreSceneIfNeeded() {
        if !sceneStateStore.isRestored {
            sceneStateStore.restore(
                from: persistedSceneData,
                currentDataEpoch: appState.dataEpoch
            )
        } else if sceneStateStore.snapshot.dataEpoch != appState.dataEpoch {
            sceneStateStore.resetForDataEpoch(appState.dataEpoch)
        }

        if persistedSceneData != sceneStateStore.persistedData {
            persistedSceneData = sceneStateStore.persistedData
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
}
