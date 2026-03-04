/**
 * [INPUT]: 依赖 SwiftUI App 生命周期、RepositoryContainer 与全局服务初始化流程
 * [OUTPUT]: 对外提供 xmnoteApp（应用入口）完成数据库/仓储/根视图启动
 * [POS]: 应用启动编排层，负责组装全局依赖并挂载 ContentView
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

//
//  xmnoteApp.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI
import Nuke

/// 应用入口，负责初始化图片管线、数据库与仓储容器并注入根视图环境。
@main
struct xmnoteApp: App {
    @State private var appState = AppState()
    @State private var databaseManager: DatabaseManager
    @State private var repositories: RepositoryContainer

    /// 启动时组装全局依赖；数据库初始化失败则直接终止应用启动。
    init() {
        do {
            ImagePipeline.shared = XMImagePipelineFactory.makeDefault()
            let manager = try DatabaseManager()
            _databaseManager = State(initialValue: manager)
            _repositories = State(initialValue: RepositoryContainer(databaseManager: manager))
        } catch {
            fatalError("数据库初始化失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(databaseManager)
                .environment(repositories)
        }
    }
}
