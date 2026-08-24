/**
 * [INPUT]: 依赖 SwiftUI App/WindowGroup 生命周期、GRDB Database、RepositoryContainer、ReadingTimerCoordinator、AppState、桌面网页会话、AliyunpanSDK 与 scene 级外部路由
 * [OUTPUT]: 对外提供 xmnoteApp 与 AppSceneRoot，原子发布应用运行时，为每个 window 隔离 SceneStateStore、书单导入和阅读计时深链，并统一应用滚动回弹策略
 * [POS]: 应用启动与多 scene 编排层；应用服务保持全局，导航恢复及外部页面请求下沉到各自场景
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

//
//  xmnoteApp.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI
import GRDB
import Nuke
import AliyunpanSDK

/// 启动期一次性发布的运行时依赖，避免数据库、仓储与计时器分步写入产生不可用中间态。
struct AppRuntimeContext {
    let databaseManager: DatabaseManager
    let repositories: RepositoryContainer
    let readingTimerCoordinator: ReadingTimerCoordinator
}

@main
/// 应用入口，常驻挂载根界面并在后台完成数据库、仓储与阅读计时依赖组装。
struct xmnoteApp: App {
    @UIApplicationDelegateAdaptor(ReadingTimerNotificationDelegate.self) private var notificationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()
    @State private var toastCenter = XMToastCenter()
    @State private var runtime: AppRuntimeContext?
    @State private var readingTimerSettingsStore = ReadingTimerSettingsStore()
    @State private var desktopWebSessionCoordinator = DesktopWebSessionCoordinator()
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
            AppSceneRoot(runtime: runtime, initializationError: initError)
                .environment(appState)
                .environment(readingTimerSettingsStore)
                .environment(desktopWebSessionCoordinator)
                .environment(toastCenter)
                .xmToastHost(center: toastCenter)
                .scrollBounceBehavior(.always, axes: [.vertical, .horizontal])
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["XMNOTE_WEB_PARITY_PREMIUM"] == "1" {
                        appState.isPremium = true
                    }
                    #endif
                    await desktopWebSessionCoordinator.updatePremiumStatus(appState.isPremium)
                    if runtime != nil {
                        await desktopWebSessionCoordinator.handleScenePhase(scenePhase)
                        return
                    }
                    guard runtime == nil, initError == nil else { return }
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
                        let repositoryContainer = RepositoryContainer(databaseManager: manager)
                        let timerCoordinator = ReadingTimerCoordinator(
                            repository: repositoryContainer.readingTimerRepository
                        )
                        desktopWebSessionCoordinator.configure(
                            database: database,
                            repositories: repositoryContainer
                        )
                        runtime = AppRuntimeContext(
                            databaseManager: manager,
                            repositories: repositoryContainer,
                            readingTimerCoordinator: timerCoordinator
                        )
                        await timerCoordinator.refresh(reason: .appLaunch)
                        await desktopWebSessionCoordinator.handleScenePhase(scenePhase)
                    } catch {
                        initError = error
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        await desktopWebSessionCoordinator.handleScenePhase(phase)
                        guard let readingTimerCoordinator = runtime?.readingTimerCoordinator else { return }
                        switch phase {
                        case .active:
                            await readingTimerCoordinator.refresh(reason: .foreground)
                        case .inactive, .background:
                            await readingTimerCoordinator.persistBeforeSuspension()
                        @unknown default:
                            break
                        }
                    }
                }
                .onChange(of: appState.dataEpoch) { _, _ in
                    Task {
                        await runtime?.readingTimerCoordinator.refresh(reason: .dataSourceChanged)
                    }
                }
                .onChange(of: appState.isPremium) { _, isPremium in
                    Task {
                        await desktopWebSessionCoordinator.updatePremiumStatus(isPremium)
                    }
                }
        }
    }

}

/// 每个 WindowGroup 场景独立持有恢复状态与外部路由，避免多窗口共享返回栈或重复消费页面请求。
private struct AppSceneRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneStateStore = SceneStateStore()
    @State private var bookCollectionImportRouter = BookCollectionImportRouter()
    @State private var readingTimerDeepLinkRouter = ReadingTimerDeepLinkRouter()

    let runtime: AppRuntimeContext?
    let initializationError: Error?

    var body: some View {
        ContentView(runtime: runtime, initializationError: initializationError)
            .environment(sceneStateStore)
            .environment(bookCollectionImportRouter)
            .environment(readingTimerDeepLinkRouter)
            .task {
                bookCollectionImportRouter.consumePendingShareImport()
                consumeReadingTimerSystemHandoffIfNeeded()
            }
            .onOpenURL { url in
                if Aliyunpan.handleOpenURL(url) {
                    return
                }
                if readingTimerDeepLinkRouter.handle(url) {
                    return
                }
                bookCollectionImportRouter.handle(url)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .readingTimerSystemHandoffDidChange)
            ) { _ in
                consumeReadingTimerSystemHandoffIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                bookCollectionImportRouter.consumePendingShareImport()
                consumeReadingTimerSystemHandoffIfNeeded()
            }
    }

    /// 读取通知或 Live Activity 的进程级一次性交接，并只写入成功消费它的场景路由器。
    private func consumeReadingTimerSystemHandoffIfNeeded() {
        guard let url = ReadingTimerSystemHandoff.consumeURL() else { return }
        _ = readingTimerDeepLinkRouter.handle(url)
    }
}

/// 书单导入请求，区分手动深链预览与系统分享自动导入两条消费路径。
nonisolated struct BookCollectionImportRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let link: String
    let source: Source

    enum Source: Equatable, Sendable {
        case deepLink
        case systemShare
    }

    init(link: String, source: Source) {
        self.id = UUID()
        self.link = link
        self.source = source
    }
}

/// 书单导入深链分发器，把系统 URL 与 Share Extension handoff 转成书单页可消费的导入请求。
@Observable
final class BookCollectionImportRouter {
    var pendingImport: BookCollectionImportRequest?

    private let handoffStore = BookCollectionShareImportHandoffStore()

    /// 处理 App 级打开 URL 事件；直接 weread 链接或带 `url` 参数的深链进入预览，Share Extension 深链消费 App Group handoff。
    func handle(_ url: URL) {
        if Self.isShareExtensionImportURL(url) {
            consumePendingShareImport()
            return
        }
        guard let link = Self.wereadLink(from: url) else { return }
        pendingImport = BookCollectionImportRequest(link: link, source: .deepLink)
    }

    /// 消费 Share Extension 写入的待导入链接；失败时静默忽略，让用户仍可使用书单页粘贴导入兜底。
    func consumePendingShareImport() {
        do {
            guard let payload = try handoffStore.consumePendingPayload() else { return }
            guard let link = WereadCollectionLinkExtractor.extractLink(from: payload.link) else { return }
            pendingImport = BookCollectionImportRequest(link: link, source: .systemShare)
        } catch {
            #if DEBUG
            print("BookCollectionImportRouter handoff consume failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// 消费当前待导入请求，避免页面恢复后重复解析或重复落库。
    func consumePendingImport(_ request: BookCollectionImportRequest) {
        guard pendingImport?.id == request.id else { return }
        pendingImport = nil
    }

    private static func wereadLink(from url: URL) -> String? {
        if let link = WereadCollectionLinkExtractor.extractLink(from: url) {
            return link
        }
        guard url.scheme == "xmnote" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host == "import-weread" || url.path.contains("import-weread") {
            return components?.queryItems?
                .first(where: { $0.name == "url" })?
                .value
                .flatMap(WereadCollectionLinkExtractor.extractLink(from:))
        }
        return nil
    }

    private static func isShareExtensionImportURL(_ url: URL) -> Bool {
        guard url.scheme == "xmnote",
              url.host == "import-weread" || url.path.contains("import-weread") else {
            return false
        }
        let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "source" })?
            .value
        return source == "share-extension"
    }
}

#if DEBUG
/// DEBUG 测试启动配置，使用指定 V44 快照或内存夹具隔离 Web API 一致性验证与 UI Test。
enum UITestLaunchConfiguration {
    nonisolated static let webAPIParityDatabasePathEnvironment = "XMNOTE_WEB_PARITY_DATABASE_PATH"
    nonisolated static let seedBookListArgument = "-XMNoteUITestSeedBookshelfBookList"
    nonisolated static let openDefaultBookshelfArgument = "-XMNoteUITestOpenDefaultBookshelf"
    nonisolated static let openWantReadListArgument = "-XMNoteUITestOpenWantReadList"
    nonisolated static let openReorderGroupListArgument = "-XMNoteUITestOpenReorderGroupList"
    nonisolated static let resetSceneStateArgument = "-XMNoteUITestResetSceneState"
    nonisolated static let exerciseTimerDeepLinkConflictArgument =
        "-XMNoteUITestExerciseTimerDeepLinkConflict"
    nonisolated static let reorderGroupID: Int64 = 9_001
    nonisolated static let manualCollectionID: Int64 = 9_101
    nonisolated static let annualCollectionID: Int64 = 9_102
    nonisolated static let annualFinishedBookID: Int64 = 4_001

    /// 优先打开调用方提供的隔离 V44 快照，否则按 UI Test 参数创建夹具；返回 nil 时保持生产数据库路径。
    nonisolated static func makeDatabaseIfNeeded() throws -> AppDatabase? {
        if let databasePath = ProcessInfo.processInfo.environment[webAPIParityDatabasePathEnvironment]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !databasePath.isEmpty {
            return try AppDatabase(path: databasePath)
        }
        guard shouldSeedBookshelfFixture else {
            return nil
        }
        let database = try AppDatabase.empty()
        try seedBookshelfBookListFixture(in: database)
        return database
    }

    /// 一级书架 UI Test 直达书籍首页，不依赖用户真实 Tab 恢复状态。
    nonisolated static var shouldOpenDefaultBookshelf: Bool {
        ProcessInfo.processInfo.arguments.contains(openDefaultBookshelfArgument)
    }

    /// 导航 UI Test 首次启动时忽略旧 SceneStorage，随后仍允许同一测试重启并验证新快照恢复。
    nonisolated static var shouldResetSceneState: Bool {
        ProcessInfo.processInfo.arguments.contains(resetSceneStateArgument)
    }

    /// 导航 UI Test 是否注入“已有全屏任务 + 连续计时深链”的 newest-wins 场景。
    nonisolated static var shouldExerciseTimerDeepLinkConflict: Bool {
        ProcessInfo.processInfo.arguments.contains(exerciseTimerDeepLinkConflictArgument)
    }

    /// 需要隔离书架数据的 UI Test 启动参数集合。
    nonisolated static var shouldSeedBookshelfFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(seedBookListArgument)
            || arguments.contains(openDefaultBookshelfArgument)
            || arguments.contains(openWantReadListArgument)
            || arguments.contains(openReorderGroupListArgument)
            || arguments.contains(exerciseTimerDeepLinkConflictArgument)
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

            var note = NoteRecord()
            note.id = 5_001
            note.bookId = 1_001
            note.content = "UI 测试书摘"
            note.idea = "用于验证从笔记进入书籍后的沉浸导航"
            note.positionUnit = 1
            note.createdDate = now
            note.updatedDate = now
            try note.insert(db)

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

            try seedBookCollectionFixture(now: now, db: db)
        }
    }

    /// 写入书单 UI Test 数据，覆盖手动书单、年度书单、推荐语与详情展示路径。
    nonisolated static func seedBookCollectionFixture(now: Int64, db: Database) throws {
        let annualReadDate: Int64 = 1_767_225_600_000
        var annualFinishedBook = makeFixtureBook(
            id: annualFinishedBookID,
            title: "UI测试读完年度书",
            author: "年度作者",
            order: 1,
            readStatusID: 3,
            now: annualReadDate
        )
        try annualFinishedBook.insert(db)

        var readStatusRecord = BookReadStatusRecordRecord()
        readStatusRecord.id = 9_301
        readStatusRecord.bookId = annualFinishedBookID
        readStatusRecord.readStatusId = 3
        readStatusRecord.changedDate = annualReadDate
        readStatusRecord.createdDate = annualReadDate
        readStatusRecord.updatedDate = annualReadDate
        try readStatusRecord.insert(db)

        var manual = CollectionRecord()
        manual.id = manualCollectionID
        manual.title = "UI测试手动书单"
        manual.desc = "用于验证 iOS 书单列表与详情"
        manual.order = 1
        manual.isAnnual = 0
        manual.year = 0
        manual.createdDate = now
        manual.updatedDate = now
        try manual.insert(db)

        var annual = CollectionRecord()
        annual.id = annualCollectionID
        annual.title = "2026 年阅读书单"
        annual.desc = "年度只读验证"
        annual.order = 2026
        annual.isAnnual = 1
        annual.year = 2026
        annual.createdDate = now
        annual.updatedDate = now
        try annual.insert(db)

        let relations: [(Int64, Int64, Int64, String, Int64)] = [
            (9_201, manualCollectionID, 1_001, "适合验证书单详情的推荐语", 0),
            (9_202, manualCollectionID, 1_002, "", 1),
            (9_203, annualCollectionID, annualFinishedBookID, "年度书单只读推荐语", 0)
        ]
        for relationData in relations {
            var relation = CollectionBookRecord()
            relation.id = relationData.0
            relation.collectionId = relationData.1
            relation.bookId = relationData.2
            relation.recommend = relationData.3
            relation.order = relationData.4
            relation.createdDate = now
            relation.updatedDate = now
            try relation.insert(db)
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
