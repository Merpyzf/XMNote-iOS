/**
 * [INPUT]: 依赖 MainTabView、AppState 数据版本与 SceneStateStore 新会话启动能力，承接应用首屏容器装配
 * [OUTPUT]: 对外提供 ContentView（应用根视图壳层）供 App 入口加载，默认从在读根页启动且不执行 scene 自动恢复
 * [POS]: Views 顶层页面容器，负责把导航主骨架挂接到应用生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

//
//  ContentView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

/// 应用根视图，挂载主 Tab 导航骨架并统一品牌色 tint。
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(SceneStateStore.self) private var sceneStateStore

    var body: some View {
        MainTabView()
            .tint(Color.brand)
            .task(id: appState.dataEpoch) {
                sceneStateStore.startFreshSession(dataEpoch: appState.dataEpoch)
            }
    }
}

#Preview {
    ContentView()
}
