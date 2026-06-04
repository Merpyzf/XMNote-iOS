/**
 * [INPUT]: 依赖 SwiftUI App 生命周期、RepositoryContainer 与全局服务初始化流程
 * [OUTPUT]: 对外提供 xmnoteApp（应用入口）完成数据库/仓储/根视图启动，并在 DEBUG UI Test 下提供隔离书架二级列表 fixture
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
import GRDB

/// 应用入口，异步初始化数据库后注入环境并渲染主界面。
///
/// 数据库 I/O（DatabasePool 创建 + 迁移 + seed）通过 `Task.detached` 脱离主线程，
/// 消除首次启动 300-1200ms 的主线程阻塞。复用项目 Optional State + `.task` 延迟初始化模式。
@main
/// 应用入口，负责初始化全局依赖并挂载根界面。
struct xmnoteApp: App {
    @State private var appState = AppState()
    @State private var sceneStateStore = SceneStateStore()
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
                        .environment(sceneStateStore)
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
                        #if DEBUG
                        if let uiTestDatabase = try UITestLaunchConfiguration.makeDatabaseIfNeeded() {
                            return uiTestDatabase
                        }
                        #endif
                        return try AppDatabase()
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

#if DEBUG
/// UI Test 专用启动配置，使用隔离数据库构造二级书籍列表与可排序分组的稳定测试场景。
enum UITestLaunchConfiguration {
    nonisolated static let seedBookListArgument = "-XMNoteUITestSeedBookshelfBookList"
    nonisolated static let openWantReadListArgument = "-XMNoteUITestOpenWantReadList"
    nonisolated static let openReorderGroupListArgument = "-XMNoteUITestOpenReorderGroupList"
    nonisolated static let reorderGroupID: Int64 = 9_001

    /// 根据 UI Test 启动参数决定是否创建临时数据库；返回 nil 时保持生产数据库路径。
    nonisolated static func makeDatabaseIfNeeded() throws -> AppDatabase? {
        guard ProcessInfo.processInfo.arguments.contains(seedBookListArgument) else {
            return nil
        }
        let database = try AppDatabase.empty()
        try seedBookshelfBookListFixture(in: database)
        return database
    }

    /// UI Test 直达二级列表的路由，避免测试依赖首页聚合卡视觉排序。
    nonisolated static var requestedBookRoute: BookRoute? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(openWantReadListArgument) {
            return .bookshelfList(BookshelfBookListRoute(
                context: .readStatus(1),
                title: "想读",
                subtitleHint: "26本"
            ))
        }
        if arguments.contains(openReorderGroupListArgument) {
            return .bookshelfList(BookshelfBookListRoute(
                context: .defaultGroup(reorderGroupID),
                title: "UI测试排序分组",
                subtitleHint: "4本"
            ))
        }
        return nil
    }

    /// 在独立数据库内写入稳定书籍与分组数据；仅供 DEBUG UI Test 启动路径调用。
    nonisolated static func seedBookshelfBookListFixture(in database: AppDatabase) throws {
        try database.dbPool.write { db in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var group = GroupRecord()
            group.id = reorderGroupID
            group.userId = 1
            group.name = "UI测试排序分组"
            group.groupOrder = 1
            group.createdDate = now
            group.updatedDate = now
            try group.insert(db)

            for index in 1...26 {
                var book = makeFixtureBook(
                    id: Int64(1_000 + index),
                    title: String(format: "UI测试想读 %02d", index),
                    author: "测试作者",
                    order: Int64(index),
                    readStatusID: 1,
                    now: now
                )
                try book.insert(db)
            }

            for index in 1...4 {
                let bookID = Int64(2_000 + index)
                var book = makeFixtureBook(
                    id: bookID,
                    title: String(format: "UI测试排序 %02d", index),
                    author: "排序作者",
                    order: Int64(index),
                    readStatusID: 2,
                    now: now
                )
                try book.insert(db)

                var relation = GroupBookRecord()
                relation.id = Int64(3_000 + index)
                relation.groupId = reorderGroupID
                relation.bookId = bookID
                relation.createdDate = now
                relation.updatedDate = now
                try relation.insert(db)
            }
        }
    }

    /// 构造二级列表测试书籍，使用固定主键与排序值保证 UI Test 可重复。
    nonisolated static func makeFixtureBook(
        id: Int64,
        title: String,
        author: String,
        order: Int64,
        readStatusID: Int64,
        now: Int64
    ) -> BookRecord {
        var book = BookRecord()
        book.id = id
        book.userId = 1
        book.name = title
        book.rawName = title
        book.author = author
        book.sourceId = 1
        book.bookOrder = order
        book.readStatusId = readStatusID
        book.readStatusChangedDate = now
        book.createdDate = now
        book.updatedDate = now
        return book
    }
}
#endif
