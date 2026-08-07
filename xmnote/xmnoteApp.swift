/**
 * [INPUT]: 依赖 SwiftUI App 生命周期、GRDB Database、RepositoryContainer、XMToastCenter、App Group 书单分享导入 handoff、全局滚动回弹规范与服务初始化流程
 * [OUTPUT]: 对外提供 xmnoteApp（应用入口）常驻挂载 ContentView、全轴短内容回弹环境、原子发布数据库运行时依赖、全局 Toast 与书单分享导入，并在 DEBUG UI Test 下提供隔离书架 fixture
 * [POS]: 应用启动编排层，负责建立全局交互环境并异步组装运行时依赖，不阻塞首页导航壳层建立
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
import GRDB

/// 启动期一次性发布的运行时依赖，避免数据库管理器和仓储容器分步写入产生不可用中间态。
struct AppRuntimeContext {
    let databaseManager: DatabaseManager
    let repositories: RepositoryContainer
}

@main
/// 应用入口，常驻挂载根界面并在后台完成数据库与仓储依赖组装。
struct xmnoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()
    @State private var sceneStateStore = SceneStateStore()
    @State private var toastCenter = XMToastCenter()
    @State private var runtime: AppRuntimeContext?
    @State private var bookCollectionImportRouter = BookCollectionImportRouter()
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
            ContentView(runtime: runtime, initializationError: initError)
                .scrollBounceBehavior(.always, axes: [.vertical, .horizontal])
                .environment(appState)
                .environment(sceneStateStore)
                .environment(bookCollectionImportRouter)
                .environment(toastCenter)
                .xmToastHost(center: toastCenter)
                .task {
                    bookCollectionImportRouter.consumePendingShareImport()
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
                        let repositories = RepositoryContainer(databaseManager: manager)
                        runtime = AppRuntimeContext(
                            databaseManager: manager,
                            repositories: repositories
                        )
                    } catch {
                        initError = error
                    }
                }
                .onOpenURL { url in
                    _ = Aliyunpan.handleOpenURL(url)
                    bookCollectionImportRouter.handle(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    bookCollectionImportRouter.consumePendingShareImport()
                }
        }
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
/// UI Test 专用启动配置，使用隔离数据库构造书架首页、二级书籍列表与可排序分组的稳定测试场景。
enum UITestLaunchConfiguration {
    nonisolated static let seedBookListArgument = "-XMNoteUITestSeedBookshelfBookList"
    nonisolated static let openDefaultBookshelfArgument = "-XMNoteUITestOpenDefaultBookshelf"
    nonisolated static let openWantReadListArgument = "-XMNoteUITestOpenWantReadList"
    nonisolated static let openReorderGroupListArgument = "-XMNoteUITestOpenReorderGroupList"
    nonisolated static let reorderGroupID: Int64 = 9_001
    nonisolated static let manualCollectionID: Int64 = 9_101
    nonisolated static let annualCollectionID: Int64 = 9_102
    nonisolated static let annualFinishedBookID: Int64 = 4_001

    /// 根据 UI Test 启动参数决定是否创建临时数据库；返回 nil 时保持生产数据库路径。
    nonisolated static func makeDatabaseIfNeeded() throws -> AppDatabase? {
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

    /// 需要隔离书架数据的 UI Test 启动参数集合。
    nonisolated static var shouldSeedBookshelfFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(seedBookListArgument)
            || arguments.contains(openDefaultBookshelfArgument)
            || arguments.contains(openWantReadListArgument)
            || arguments.contains(openReorderGroupListArgument)
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
