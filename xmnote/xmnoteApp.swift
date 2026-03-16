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
import AliyunpanSDK

/// 应用入口，异步初始化数据库后注入环境并渲染主界面。
///
/// 数据库 I/O（DatabasePool 创建 + 迁移 + seed）通过 `Task.detached` 脱离主线程，
/// 消除首次启动 300-1200ms 的主线程阻塞。复用项目 Optional State + `.task` 延迟初始化模式。
@main
/// 应用入口，负责初始化全局依赖并挂载根界面。
struct xmnoteApp: App {
    @State private var appState = AppState()
    @State private var databaseManager: DatabaseManager?
    @State private var repositories: RepositoryContainer?
    @State private var initError: Error?

    init() {
        #if DEBUG
        BrandTypography.debugLogAppInitRegistrationTriggered()
        #endif
        BrandTypography.registerBundledFontIfNeeded()
        ImagePipeline.shared = XMImagePipelineFactory.makeDefault()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let databaseManager, let repositories {
                    ContentView()
                        .id(appState.dataEpoch)
                        .environment(appState)
                        .environment(databaseManager)
                        .environment(repositories)
                        .transition(.opacity)
                } else if let initError {
                    databaseErrorView(initError)
                } else {
                    LaunchSplashView()
                }
            }
            .animation(.smooth(duration: 0.35), value: repositories != nil)
            .task {
                guard databaseManager == nil, initError == nil else { return }
                do {
                    let database = try await Task.detached(priority: .userInitiated) {
                        try AppDatabase()
                    }.value
                    let manager = DatabaseManager(database: database)
                    databaseManager = manager
                    repositories = RepositoryContainer(databaseManager: manager)
                } catch {
                    initError = error
                }
            }
            .onOpenURL { url in
                _ = Aliyunpan.handleOpenURL(url)
            }
        }
    }

    // MARK: - Error View

    private func databaseErrorView(_ error: Error) -> some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "exclamationmark.triangle")
                .font(AppTypography.largeTitle)
                .foregroundStyle(Color.feedbackError)
            Text("数据库初始化失败")
                .font(AppTypography.headline)
            Text(error.localizedDescription)
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.double)
        }
    }
}
