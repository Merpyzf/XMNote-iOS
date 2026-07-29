/**
 * [INPUT]: 依赖 XMNoteWeb 能力端口、DesktopWebSettingsRepository、可延迟注入的目录/分组/书籍/日历/章节/书摘/书评/相关内容/搜索/阅读记录及在线章节仓储、生产会员读取闭包与主线程原生动作桥
 * [OUTPUT]: 对外提供 App 到 XMNoteWeb 的设置、安全、会员、来源、标签、分组、书籍、阅读日历、章节、书摘、书评、相关内容、搜索、阅读记录、在线目录、导入投影和原生导航 Adapter
 * [POS]: Infra 层网页模块适配边界；Package 不接触 UserDefaults、AppState 或 SwiftUI 导航
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Darwin
import Foundation
import UIKit
import XMNoteWeb

/// 把 Web 原生动作切换到主线程；是否存在消费方决定 Android 对应的 upgradeActionAvailable。
@MainActor
final class DesktopWebNativeActionBridge {
    var onOpenPremiumUpgrade: (() -> Void)?

    var isPremiumUpgradeAvailable: Bool {
        onOpenPremiumUpgrade != nil
    }

    /// 在主线程同步发出导航请求；调用方取消不会撤销已被 App 接受的导航事件。
    func openPremiumUpgrade() -> DesktopWebNativeActionResult {
        guard let onOpenPremiumUpgrade else {
            return DesktopWebNativeActionResult(
                accepted: false,
                message: "当前环境无法直接打开高级版页面，请在手机 App 中完成开通"
            )
        }
        onOpenPremiumUpgrade()
        return DesktopWebNativeActionResult(accepted: true)
    }
}

/// 禁止 URLSession 自动跟随封面重定向，由代理服务逐跳执行 DNS/私网复检并限制三次。
private final class DesktopWebCoverRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = DesktopWebCoverRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 将 Package 的平台无关 DTO 映射到 App Repository，并固定生产会员未接入期间的只读能力。
final class DesktopWebAPIAdapter: @unchecked Sendable,
    DesktopWebRequestGatePort,
    DesktopWebSettingsPort,
    DesktopWebSourcePort,
    DesktopWebTagPort,
    DesktopWebGroupPort,
    DesktopWebBookPort,
    DesktopWebBookshelfPort,
    DesktopWebCalendarPort,
    DesktopWebChapterPort,
    DesktopWebNotePort,
    DesktopWebRelatedPort,
    DesktopWebReviewPort,
    DesktopWebReadingRecordPort,
    DesktopWebSearchPort,
    DesktopWebStatisticsPort,
    DesktopWebAIPort,
    DesktopWebOnlineBookPort,
    DesktopWebBookCoverPort,
    DesktopWebExportPort,
    DesktopWebImportPort,
    DesktopWebUploadPort {
    private let repository: DesktopWebSettingsRepository
    private let nativeActionBridge: DesktopWebNativeActionBridge
    private let isPremiumProvider: @Sendable () async -> Bool
    private let currentTimeMillis: @Sendable () -> Int64
    private let defaults: UserDefaults
    private let reviewDraftStore: DesktopWebReviewDraftStore
    private let aiService: DesktopWebAIService
    private let onlineBookService: DesktopWebOnlineBookService
    private let coverSession: URLSession
    private var exportService: (any DesktopWebExportPort)?
    private var importService: (any DesktopWebImportPort)?
    private var uploadService: (any DesktopWebUploadPort)?
    private let catalogLock = NSLock()
    private var catalogRepository: DesktopWebCatalogRepository?
    private var groupRepository: DesktopWebGroupRepository?
    private var bookRepository: DesktopWebBookRepository?
    private var calendarRepository: DesktopWebCalendarRepository?
    private var chapterRepository: DesktopWebChapterRepository?
    private var chapterOnlineRepository: DesktopWebChapterOnlineRepository?
    private var noteRepository: DesktopWebNoteRepository?
    private var relatedRepository: DesktopWebRelatedRepository?
    private var reviewRepository: DesktopWebReviewRepository?
    private var readingRecordRepository: DesktopWebReadingRecordRepository?
    private var searchRepository: DesktopWebSearchRepository?
    private var statisticsRepository: DesktopWebStatisticsRepository?
    private var coverService: DesktopWebBookCoverService?

    init(
        repository: DesktopWebSettingsRepository,
        nativeActionBridge: DesktopWebNativeActionBridge,
        defaults: UserDefaults = .standard,
        isPremiumProvider: @escaping @Sendable () async -> Bool = { false },
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.repository = repository
        self.nativeActionBridge = nativeActionBridge
        self.defaults = defaults
        self.reviewDraftStore = DesktopWebReviewDraftStore(defaults: defaults)
        self.aiService = DesktopWebAIService(defaults: defaults)
        self.onlineBookService = DesktopWebOnlineBookService()
        let coverConfiguration = URLSessionConfiguration.default
        coverConfiguration.timeoutIntervalForRequest = 10
        coverConfiguration.timeoutIntervalForResource = 10
        self.coverSession = URLSession(
            configuration: coverConfiguration,
            delegate: DesktopWebCoverRedirectDelegate.shared,
            delegateQueue: nil
        )
        self.isPremiumProvider = isPremiumProvider
        self.currentTimeMillis = currentTimeMillis
    }

    /// 在 App 数据库完成迁移后原子安装网页目录仓储；后续请求只读取同一快照，不持有 DatabaseManager。
    func configure(database: AppDatabase) {
        catalogLock.withLock {
            let commitUploadedTickets: @Sendable ([String]?, [String]) throws -> Void = { [weak self] ids, urls in
                guard let service = self?.uploadService as? DesktopWebUploadService else { return }
                try service.commitUploadedTickets(ids, imageURLs: urls)
            }
            catalogRepository = DesktopWebCatalogRepository(database: database)
            groupRepository = DesktopWebGroupRepository(
                database: database,
                currentTimeMillis: currentTimeMillis
            )
            let books = DesktopWebBookRepository(
                database: database,
                currentTimeMillis: currentTimeMillis
            )
            bookRepository = books
            coverService = DesktopWebBookCoverService(
                repository: books,
                settingsRepository: repository,
                session: coverSession,
                currentTimeMillis: currentTimeMillis
            )
            calendarRepository = DesktopWebCalendarRepository(database: database)
            let chapters = DesktopWebChapterRepository(
                database: database,
                currentTimeMillis: currentTimeMillis
            )
            chapterRepository = chapters
            chapterOnlineRepository = DesktopWebChapterOnlineRepository(
                chapterRepository: chapters
            )
            let notes = DesktopWebNoteRepository(
                database: database,
                currentTimeMillis: currentTimeMillis,
                commitUploadedTickets: commitUploadedTickets
            )
            noteRepository = notes
            relatedRepository = DesktopWebRelatedRepository(
                database: database,
                currentTimeMillis: currentTimeMillis,
                commitUploadedTickets: commitUploadedTickets
            )
            let reviews = DesktopWebReviewRepository(
                database: database,
                draftStore: reviewDraftStore,
                currentTimeMillis: currentTimeMillis,
                commitUploadedTickets: commitUploadedTickets
            )
            reviewRepository = reviews
            readingRecordRepository = DesktopWebReadingRecordRepository(
                database: database,
                currentTimeMillis: currentTimeMillis
            )
            searchRepository = DesktopWebSearchRepository(
                database: database,
                bookRepository: books,
                noteRepository: notes,
                reviewRepository: reviews
            )
            statisticsRepository = DesktopWebStatisticsRepository(
                database: database,
                bookRepository: books,
                currentTimeMillis: currentTimeMillis,
                latestDailyTarget: { [defaults] in
                    defaults.object(forKey: "latest_reading_time_of_day") as? Int ?? 3_600
                },
                saveLatestDailyTarget: { [defaults] target in
                    defaults.set(target, forKey: "latest_reading_time_of_day")
                }
            )
        }
    }

    /// 安装依赖 App Repository 的导入导出与对象存储服务；Package 始终只看到能力端口。
    func configureExternalServices(
        export: any DesktopWebExportPort,
        importTask: any DesktopWebImportPort,
        upload: any DesktopWebUploadPort
    ) {
        catalogLock.withLock {
            exportService = export
            importService = importTask
            uploadService = upload
        }
    }

    /// 转发 AI 配置读取，actor 内部保证与局部更新不会交叉。
    func aiConfig() async throws -> DesktopWebJSONValue {
        try await aiService.aiConfig()
    }

    /// 转发 AI 配置 Patch；取消前尚未写入的字段不会继续执行网络动作。
    func updateAIConfig(_ patch: DesktopWebJSONValue) async throws {
        try await aiService.updateAIConfig(patch)
    }

    /// 保留上游状态和 SSE 流，路由只负责将平台无关响应写回 socket。
    func chatCompletions(body: Data) async throws -> DesktopWebRawHTTPResponse {
        try await aiService.chatCompletions(body: body)
    }

    /// 复用 App Wenqu 真实请求，并按 Android fuzzywuzzy title+author 分数稳定降序。
    func searchOnlineBooks(keyword: String) async throws -> [DesktopWebOnlineBook] {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopWebAPIError(code: 40001, message: "搜索关键词不能为空")
        }
        return try await onlineBookService.searchOnlineBooks(keyword: keyword)
    }

    /// 查询包含 tombstone 的原始封面并执行签名、SSRF、重定向、类型和大小校验。
    func proxiedBookCover(
        bookID: Int64,
        expires: Int64?,
        signature: String?
    ) async throws -> DesktopWebRawHTTPResponse {
        try await coverServiceValue().proxiedBookCover(
            bookID: bookID,
            expires: expires,
            signature: signature
        )
    }

    func siYuanNotebooks() async throws -> [DesktopWebExportPlatformOption] {
        try await requireExportService().siYuanNotebooks()
    }

    func obsidianDirectories() async throws -> [DesktopWebExportPlatformOption] {
        try await requireExportService().obsidianDirectories()
    }

    func exportNotesLocally(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebExportFile {
        try await requireExportService().exportNotesLocally(request)
    }

    func exportNotesRemotely(_ request: DesktopWebNoteExportRequest) async throws -> DesktopWebRemoteExportResult {
        try await requireExportService().exportNotesRemotely(request)
    }

    func createImportTask(file: DesktopWebUploadedFile) async throws -> DesktopWebImportTaskCreateResponse {
        try await requireImportService().createImportTask(file: file)
    }

    func importTask(id: String) async throws -> DesktopWebJSONValue {
        try await requireImportService().importTask(id: id)
    }

    func commitImportTask(id: String, request: DesktopWebImportTaskCommitRequest) async throws -> DesktopWebImportTaskCommitResponse {
        try await requireImportService().commitImportTask(id: id, request: request)
    }

    func deleteImportTask(id: String) async throws {
        try await requireImportService().deleteImportTask(id: id)
    }

    func reserveNoteImageTickets(count: Int) async throws -> DesktopWebUploadTicketReserveResult {
        try await requireUploadService().reserveNoteImageTickets(count: count)
    }

    func uploadNoteImage(ticketID: String, file: DesktopWebUploadedFile) async throws -> DesktopWebNoteImageUploadResult {
        try await requireUploadService().uploadNoteImage(ticketID: ticketID, file: file)
    }

    func releaseNoteImageTickets(_ ticketIDs: [String]) async throws {
        try await requireUploadService().releaseNoteImageTickets(ticketIDs)
    }

    func uploadBookCover(file: DesktopWebUploadedFile) async throws -> DesktopWebBookCoverUploadResult {
        try await requireUploadService().uploadBookCover(file: file)
    }

    /// 在 Repository actor 内完成设置读取，取消时不会产生写入。
    func webSettings() async throws -> DesktopWebJSONValue {
        try JSONDecoder().decode(
            DesktopWebJSONValue.self,
            from: await repository.webSettingsData()
        )
    }

    /// 编码 Package DTO 后交给 Repository 原子应用局部 Patch。
    func updateWebSettings(_ patch: DesktopWebJSONValue) async throws {
        try await repository.updateWebSettingsData(JSONEncoder().encode(patch))
    }

    /// 读取访问授权状态；该路径不触发访问码生成。
    func accessAuthSettings() async -> DesktopWebAccessAuthSettings {
        DesktopWebAccessAuthSettings(
            enabled: await repository.isAccessAuthEnabled(),
            headerName: "X-XMNote-Access-Code"
        )
    }

    /// 在 Repository actor 内读取导出配置，保留 Android 现有明文凭据合同。
    func exportSettings() async throws -> DesktopWebJSONValue {
        // NOTE(ANDROID-WEB-002): 最新 Android v46 Web 合同仍原样返回凭据；本轮按用户要求保留这一行为。
        return try JSONDecoder().decode(
            DesktopWebJSONValue.self,
            from: await repository.exportSettingsData()
        )
    }

    /// 编码 Package DTO 后交给 Repository 一次性提交导出设置。
    func updateExportSettings(_ patch: DesktopWebJSONValue) async throws {
        try await repository.updateExportSettingsData(JSONEncoder().encode(patch))
    }

    /// 生产会员状态尚未接入时 provider 固定为 false，因此核心写能力保持只读。
    func membershipCapability() async -> DesktopWebMembershipCapability {
        let isPremium = await isPremiumProvider()
        let isUpgradeAvailable = await nativeActionBridge.isPremiumUpgradeAvailable
        return DesktopWebMembershipCapability(
            isPremium: isPremium,
            desktopReadOnly: !isPremium,
            canWriteCoreData: isPremium,
            upgradeActionAvailable: isUpgradeAvailable
        )
    }

    /// 高级版已开通时拒绝重复导航，否则由主线程桥发出 App 路由请求。
    func openPremiumUpgrade() async -> DesktopWebNativeActionResult {
        guard !(await isPremiumProvider()) else {
            return DesktopWebNativeActionResult(
                accepted: false,
                message: "当前已开通高级版"
            )
        }
        return await nativeActionBridge.openPremiumUpgrade()
    }

    /// 在 Repository actor 内读取访问安全设置并比较 trim 后的访问码。
    func isAccessAuthorized(_ accessCode: String?) async -> Bool {
        await repository.isAccessAuthorized(accessCode)
    }

    /// 复用同一会员 provider，确保响应能力与写保护不会读取两套状态源。
    func isDesktopReadOnly() async -> Bool {
        !(await isPremiumProvider())
    }

    /// 映射来源列表快照，数据库 I/O 由 App Repository 承担。
    func sources(showAll: Bool) async throws -> [DesktopWebSource] {
        do {
            return try await catalog().sources(showAll: showAll).map(Self.mapSource)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射单个来源详情；分类错误继续转换为 Android Web 业务错误码。
    func source(id: Int64) async throws -> DesktopWebSource {
        do {
            return Self.mapSource(try await catalog().source(id: id))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 创建来源并返回 Package DTO；请求名称校验保留在专用 Repository。
    func createSource(_ request: DesktopWebSourceCreateRequest) async throws -> DesktopWebSource {
        do {
            return Self.mapSource(try await catalog().createSource(name: request.name))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 把局部来源更新请求透传给专用 Repository。
    func updateSource(
        id: Int64,
        request: DesktopWebSourceUpdateRequest
    ) async throws -> DesktopWebSource {
        do {
            return Self.mapSource(
                try await catalog().updateSource(
                    id: id,
                    name: request.name,
                    isHidden: request.isHidden
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 删除来源并保留 Android 的预置来源保护与关联书籍回退语义。
    func deleteSource(id: Int64) async throws {
        do {
            try await catalog().deleteSource(id: id)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按原始 ID 数组写入来源顺序，不在 Adapter 去重或过滤。
    func reorderSources(_ request: DesktopWebOrderRequest) async throws {
        do {
            try await catalog().reorderSources(ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射标签列表及两类关系数量，保留 Android Web 的跨 owner 行为。
    func tags(type: Int) async throws -> [DesktopWebTag] {
        do {
            return try await catalog().tags(type: type).map(Self.mapTag)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 创建标签并映射为 Android WebTagResultDto 对应模型。
    func createTag(_ request: DesktopWebTagCreateRequest) async throws -> DesktopWebTagResult {
        do {
            return Self.mapTagMutation(
                try await catalog().createTag(name: request.name, type: request.type)
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新标签名称并保留原类型与排序值。
    func updateTag(id: Int64, request: DesktopWebTagUpdateRequest) async throws -> DesktopWebTagResult {
        do {
            return Self.mapTagMutation(try await catalog().updateTag(id: id, name: request.name))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 删除标签，关系处理完全由 Android Web 语义专用 Repository 承担。
    func deleteTag(id: Int64) async throws {
        do {
            try await catalog().deleteTag(id: id)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按原始 ID 数组写入标签顺序，不在 Adapter 限制 owner 或标签类型。
    func reorderTags(_ request: DesktopWebOrderRequest) async throws {
        do {
            try await catalog().reorderTags(ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 分页读取分组列表，保留 Android Web 的跨 owner 和首关系计数规则。
    func groups(page: Int, pageSize: Int) async throws -> DesktopWebPageResult<DesktopWebGroup> {
        do {
            return Self.mapGroupPage(try await group().groups(page: page, pageSize: pageSize))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取组内完整书籍 DTO，并在 Adapter 应用依赖访问码状态的封面代理 URL 规则。
    func booksInGroup(
        id: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        do {
            let page = try await group().booksInGroup(
                id: id,
                page: page,
                pageSize: pageSize,
                sortBy: sortBy,
                sortOrder: sortOrder
            )
            var items: [DesktopWebBook] = []
            items.reserveCapacity(page.items.count)
            for snapshot in page.items {
                items.append(await mapBook(snapshot))
            }
            return DesktopWebPageResult(
                items: items,
                pagination: DesktopWebPagination(
                    page: page.page,
                    pageSize: page.pageSize,
                    total: page.total,
                    totalPages: page.totalPages
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 创建分组；名称校验和固定 user 1 行为由专用 Repository 承担。
    func createGroup(_ request: DesktopWebGroupCreateRequest) async throws -> DesktopWebGroup {
        do {
            return Self.mapGroup(try await group().createGroup(name: request.name))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新分组名称，不引入 App 管理页的重名或长度限制。
    func updateGroup(
        id: Int64,
        request: DesktopWebGroupUpdateRequest
    ) async throws -> DesktopWebGroup {
        do {
            return Self.mapGroup(try await group().updateGroup(id: id, name: request.name))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 删除分组并由 Repository 在单一事务内保留 Android 的逐本迁出顺序和全关系归一化语义。
    func deleteGroup(id: Int64, placeAtEnd: Bool) async throws {
        do {
            try await group().deleteGroup(id: id, placeAtEnd: placeAtEnd)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新分组置顶状态并返回回读结果。
    func updateGroupPin(
        id: Int64,
        request: DesktopWebGroupPinRequest
    ) async throws -> DesktopWebGroup {
        do {
            return Self.mapGroup(try await group().updateGroupPin(id: id, pinned: request.pinned))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按原始 ID 数组写入分组顺序，不在 Adapter 预处理重复项。
    func reorderGroups(_ request: DesktopWebOrderRequest) async throws {
        do {
            try await group().reorderGroups(ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 把原始请求交给 Repository 执行 Android 的正数过滤、去重与归属校验。
    func reorderGroupBooks(groupID: Int64, request: DesktopWebOrderRequest) async throws {
        do {
            try await group().reorderGroupBooks(groupID: groupID, ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 汇总有效非占位书籍，保留 Android 未按 owner 隔离及未知状态只进入 total 的行为。
    func bookStats() async throws -> DesktopWebBookStats {
        do {
            let snapshot = try await bookRepositoryValue().stats()
            return DesktopWebBookStats(
                total: snapshot.total,
                reading: snapshot.reading,
                want: snapshot.want,
                read: snapshot.read,
                dropped: snapshot.dropped,
                hold: snapshot.hold
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取单本完整 DTO，并在 App Adapter 层统一应用封面代理规则。
    func book(id: Int64) async throws -> DesktopWebBook {
        do {
            return await mapBook(try await bookRepositoryValue().book(id: id))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射 Android 主书籍列表的组合筛选、分页和完整 DTO。
    func books(
        page: Int,
        pageSize: Int,
        filter: DesktopWebBookFilter,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        do {
            return await mapBookPage(
                try await bookRepositoryValue().books(
                    page: page,
                    pageSize: pageSize,
                    filter: Self.mapBookFilter(filter),
                    sortBy: sortBy,
                    sortOrder: sortOrder
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射五类书籍 section 和置顶分组卡，两类封面统一在 App 边界生成代理地址。
    func bookSections(
        filter: DesktopWebBookFilter,
        sectionBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebBookSectionResult {
        do {
            let result = try await bookRepositoryValue().bookSections(
                filter: Self.mapBookFilter(filter),
                sectionBy: sectionBy,
                sortOrder: sortOrder,
                groupSortBy: groupSortBy,
                groupSortOrder: groupSortOrder,
                groupEnableSection: groupEnableSection
            )
            var sections: [DesktopWebBookSection] = []
            sections.reserveCapacity(result.sections.count)
            for section in result.sections {
                var books: [DesktopWebBook] = []
                for snapshot in section.books {
                    books.append(await mapBook(snapshot))
                }
                var groups: [DesktopWebBookshelfGroup] = []
                for snapshot in section.groups {
                    groups.append(await mapBookshelfGroup(snapshot))
                }
                sections.append(
                    DesktopWebBookSection(
                        title: section.title,
                        count: section.count,
                        books: books,
                        groups: groups
                    )
                )
            }
            return DesktopWebBookSectionResult(sections: sections, total: result.total)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射最近阅读分页，并保留 Repository 给出的 recentReadTime。
    func recentReadBooks(
        page: Int,
        pageSize: Int
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        do {
            return await mapBookPage(
                try await bookRepositoryValue().recentReadBooks(page: page, pageSize: pageSize)
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射最近书摘所属书籍；Android 无数据成功响应不包含 data 字段。
    func lastNoteBook() async throws -> DesktopWebBook? {
        do {
            guard let snapshot = try await bookRepositoryValue().lastNoteBook() else { return nil }
            return await mapBook(snapshot)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射 pinOrder 升序的置顶书籍分页。
    func pinnedBooks(
        page: Int,
        pageSize: Int
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        do {
            return await mapBookPage(
                try await bookRepositoryValue().pinnedBooks(page: page, pageSize: pageSize)
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射未分组书籍分页，排序参数已由 Package 路由完成 Android 兼容归一化。
    func ungroupedBooks(
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBook> {
        do {
            return await mapBookPage(
                try await bookRepositoryValue().ungroupedBooks(
                    page: page,
                    pageSize: pageSize,
                    sortBy: sortBy,
                    sortOrder: sortOrder
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 将 Package 创建合同完整映射为无框架 Data 输入，并返回带封面代理规则的完整书籍 DTO。
    func createBook(_ request: DesktopWebBookCreateRequest) async throws -> DesktopWebBook {
        do {
            let input = DesktopWebBookCreateInput(
                name: request.name,
                rawName: request.rawName,
                author: request.author,
                cover: request.cover,
                authorIntro: request.authorIntro,
                translator: request.translator,
                summary: request.summary,
                isbn: request.isbn,
                press: request.press,
                pubDate: request.pubDate,
                doubanID: request.doubanId,
                readStatus: request.readStatus,
                readStatusChangedTime: request.readStatusChangedTime,
                score: request.score,
                type: request.type,
                positionUnit: request.positionUnit,
                readPosition: request.readPosition,
                totalPosition: request.totalPosition,
                totalPagination: request.totalPagination,
                sourceID: request.sourceId,
                purchaseDate: request.purchaseDate,
                price: request.price,
                wordCount: request.wordCount,
                catalog: request.catalog,
                tagIDs: request.tagIds,
                groupID: request.groupId,
                isDeleted: request.isDeleted,
                creationMode: request.creationMode
            )
            return await mapBook(try await bookRepositoryValue().createBook(input))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 将 Package 局部更新合同逐字段映射，保留 nil 与显式清空 wordCount 的差异。
    func updateBook(
        id: Int64,
        request: DesktopWebBookUpdateRequest
    ) async throws -> DesktopWebBook {
        do {
            let input = DesktopWebBookUpdateInput(
                name: request.name,
                rawName: request.rawName,
                author: request.author,
                cover: request.cover,
                authorIntro: request.authorIntro,
                translator: request.translator,
                summary: request.summary,
                isbn: request.isbn,
                press: request.press,
                pubDate: request.pubDate,
                doubanID: request.doubanId,
                readStatus: request.readStatus,
                readStatusChangedTime: request.readStatusChangedTime,
                score: request.score,
                type: request.type,
                positionUnit: request.positionUnit,
                readPosition: request.readPosition,
                totalPosition: request.totalPosition,
                totalPagination: request.totalPagination,
                sourceID: request.sourceId,
                purchaseDate: request.purchaseDate,
                price: request.price,
                wordCount: request.wordCount,
                clearWordCount: request.clearWordCount,
                catalog: request.catalog,
                tagIDs: request.tagIds,
                groupID: request.groupId
            )
            return await mapBook(try await bookRepositoryValue().updateBook(id: id, input: input))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 透传原始 ID 序列，Repository 负责 Android distinct 与缺失记录跳过规则。
    func batchDeleteBooks(_ request: DesktopWebBookBatchDeleteRequest) async throws {
        do {
            try await bookRepositoryValue().batchDeleteBooks(ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 透传批量置顶请求，不在 Adapter 去重或预校验分组作用域。
    func batchPinBooks(_ request: DesktopWebBookBatchPinRequest) async throws {
        do {
            try await bookRepositoryValue().batchPinBooks(
                ids: request.ids,
                pinned: request.pinned,
                groupID: request.groupId
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射批量局部更新输入，保留重复 ID、nil 字段和原始追加标签序列。
    func batchUpdateBooks(_ request: DesktopWebBookBatchUpdateRequest) async throws {
        do {
            try await bookRepositoryValue().batchUpdateBooks(
                DesktopWebBookBatchUpdateInput(
                    ids: request.ids,
                    readStatus: request.readStatus,
                    readStatusChangedTime: request.readStatusChangedTime,
                    sourceID: request.sourceId,
                    groupID: request.groupId,
                    addTagIDs: request.addTagIds
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 将 append/replace 请求完整交给 Data 层统一归一化和事务处理。
    func batchSetBookTags(_ request: DesktopWebBookBatchSetTagsRequest) async throws {
        do {
            try await bookRepositoryValue().batchSetBookTags(
                ids: request.ids,
                tagIDs: request.tagIds,
                mode: request.mode
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射逐书最终标签集合，不在 Adapter 改变重复条目的覆盖顺序。
    func batchReplaceBookTags(_ request: DesktopWebBookBatchReplaceTagsRequest) async throws {
        do {
            try await bookRepositoryValue().batchReplaceBookTags(
                request.items.map {
                    DesktopWebBookBatchReplaceTagsItemInput(id: $0.id, tagIDs: $0.tagIds)
                }
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 透传目标与来源分组 ID，Repository 负责 Android 同组短路和整批事务。
    func batchMoveToGroup(_ request: DesktopWebBookBatchMoveToGroupRequest) async throws {
        do {
            try await bookRepositoryValue().batchMoveToGroup(
                ids: request.ids,
                targetGroupID: request.targetGroupId,
                sourceGroupID: request.sourceGroupId
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 透传移出顺序策略，Repository 保留向头部移动时的逆序处理。
    func batchMoveOut(_ request: DesktopWebBookBatchMoveOutRequest) async throws {
        do {
            try await bookRepositoryValue().batchMoveOut(
                ids: request.ids,
                placeAtEnd: request.placeAtEnd
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 通过网页专用 Repository 执行 Android 书籍删除事务，Package 不接触数据库类型。
    func deleteBook(id: Int64) async throws {
        do {
            try await bookRepositoryValue().deleteBook(id: id)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射 Android 置顶请求和回读结果；生产只读门禁在进入此方法前阻断请求。
    func updateBookPin(
        id: Int64,
        request: DesktopWebBookPinRequest
    ) async throws -> DesktopWebBookPinResult {
        do {
            let result = try await bookRepositoryValue().updateBookPin(
                id: id,
                pinned: request.pinned,
                groupID: request.groupId
            )
            return DesktopWebBookPinResult(
                id: result.id,
                isPinned: result.isPinned,
                pinOrder: result.pinOrder
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 恢复隐藏书籍并映射完整 DTO；封面代理继续只在 Adapter 边界生成。
    func addToBookshelf(id: Int64) async throws -> DesktopWebBook {
        do {
            return await mapBook(try await bookRepositoryValue().addToBookshelf(id: id))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }
}

extension DesktopWebAPIAdapter {
    /// 映射手动混排分页，分组封面与书籍封面均在 Adapter 边界生成代理地址。
    func bookshelf(
        page: Int,
        pageSize: Int,
        keyword: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebPageResult<DesktopWebBookshelfItem> {
        do {
            return await mapBookshelfPage(
                try await bookRepositoryValue().bookshelf(
                    page: page,
                    pageSize: pageSize,
                    keyword: keyword,
                    groupSortBy: groupSortBy,
                    groupSortOrder: groupSortOrder,
                    groupEnableSection: groupEnableSection
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射非手动排序书架，保留置顶分组与置顶书籍的统一 pinOrder 顺序。
    func sortedBookshelf(
        page: Int,
        pageSize: Int,
        keyword: String,
        sortBy: String,
        sortOrder: String,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool
    ) async throws -> DesktopWebPageResult<DesktopWebBookshelfItem> {
        do {
            return await mapBookshelfPage(
                try await bookRepositoryValue().sortedBookshelf(
                    page: page,
                    pageSize: pageSize,
                    keyword: keyword,
                    sortBy: sortBy,
                    sortOrder: sortOrder,
                    groupSortBy: groupSortBy,
                    groupSortOrder: groupSortOrder,
                    groupEnableSection: groupEnableSection
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射轻量 manifest，不在 Adapter 改变混排顺序或过滤条目。
    func bookshelfManifest() async throws -> [DesktopWebBookshelfManifestItem] {
        do {
            return try await bookRepositoryValue().bookshelfManifest().map {
                DesktopWebBookshelfManifestItem(
                    type: $0.type,
                    id: $0.id,
                    isPinned: $0.isPinned,
                    pinOrder: $0.pinOrder,
                    order: $0.order
                )
            }
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 映射置顶分组元数据；Android 中未消费的顶层排序参数仍原样传入 Repository。
    func bookshelfPinnedGroupsMeta(
        sortBy: String,
        sortOrder: String,
        enableSection: Bool,
        groupSortBy: String,
        groupSortOrder: String,
        groupEnableSection: Bool,
        layout: String
    ) async throws -> DesktopWebBookshelfPinnedGroupsMeta {
        do {
            let snapshot = try await bookRepositoryValue().bookshelfPinnedGroupsMeta(
                sortBy: sortBy,
                sortOrder: sortOrder,
                enableSection: enableSection,
                groupSortBy: groupSortBy,
                groupSortOrder: groupSortOrder,
                groupEnableSection: groupEnableSection,
                layout: layout
            )
            var groups: [DesktopWebBookshelfGroup] = []
            groups.reserveCapacity(snapshot.groups.count)
            for group in snapshot.groups {
                groups.append(await mapBookshelfGroup(group))
            }
            return DesktopWebBookshelfPinnedGroupsMeta(
                groups: groups,
                bookIds: snapshot.bookIDs
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 展开任意原始 item ref；Repository 负责复刻未知、缺失及越界引用行为。
    func queryBookshelfItems(
        _ request: DesktopWebBookshelfItemsQueryRequest
    ) async throws -> [DesktopWebBookshelfItem] {
        do {
            return await mapBookshelfItems(
                try await bookRepositoryValue().queryBookshelfItems(
                    itemRefs: request.items.map(Self.mapBookshelfItemRef),
                    groupSortBy: request.groupSortBy,
                    groupSortOrder: request.groupSortOrder,
                    groupEnableSection: request.groupEnableSection
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 透传移动项、锚点和 placement，事务与无效项处理均由 Repository 保持 Android 语义。
    func moveBookshelfItems(_ request: DesktopWebBookshelfMoveRequest) async throws {
        do {
            try await bookRepositoryValue().moveBookshelfItems(
                movedItems: request.movedItems.map(Self.mapBookshelfItemRef),
                anchorItem: request.anchorItem.map(Self.mapBookshelfItemRef),
                placement: request.placement
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按原始数组重排书架，不在 Adapter 去重、校验类型或限制顶层归属。
    func reorderBookshelf(_ request: DesktopWebBookshelfReorderRequest) async throws {
        do {
            try await bookRepositoryValue().reorderBookshelf(
                request.items.map(Self.mapBookshelfItemRef)
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }
}

extension DesktopWebAPIAdapter {
    /// 读取 iOS 阅读日历筛选快照并映射 Android 月历 DTO；封面代理仍在 Adapter 边界生成。
    func calendarMonth(monthMillis: Int64) async throws -> DesktopWebCalendarMonth {
        let snapshot = try await calendarRepositoryValue().month(
            monthMillis: monthMillis,
            configuration: calendarConfiguration()
        )
        var days: [DesktopWebCalendarDay] = []
        days.reserveCapacity(snapshot.days.count)
        for day in snapshot.days {
            var books: [DesktopWebCalendarBook] = []
            books.reserveCapacity(day.books.count)
            for book in day.books {
                books.append(await mapCalendarBook(book))
            }
            days.append(
                DesktopWebCalendarDay(
                    dayOfMonth: day.dayOfMonth,
                    date: day.date,
                    books: books,
                    readDoneBookCount: day.readDoneBookCount,
                    hasActivity: day.hasActivity
                )
            )
        }
        return DesktopWebCalendarMonth(
            year: snapshot.year,
            month: snapshot.month,
            days: days,
            startDayOfWeek: snapshot.startDayOfWeek,
            totalDays: snapshot.totalDays
        )
    }

    /// 映射单日阅读汇总，保留 Repository 给出的书籍顺序、计数溢出和读完状态。
    func calendarDay(dateMillis: Int64) async throws -> DesktopWebDailyReadingSummary {
        let snapshot = try await calendarRepositoryValue().day(
            dateMillis: dateMillis,
            configuration: calendarConfiguration()
        )
        var details: [DesktopWebDailyReadingDetail] = []
        details.reserveCapacity(snapshot.details.count)
        for detail in snapshot.details {
            details.append(
                DesktopWebDailyReadingDetail(
                    book: await mapCalendarBook(detail.book),
                    readingTime: detail.readingTime,
                    noteCount: detail.noteCount,
                    reviewCount: detail.reviewCount,
                    checkInCount: detail.checkInCount,
                    isReadDoneInToday: detail.isReadDoneInToday
                )
            )
        }
        return DesktopWebDailyReadingSummary(
            date: snapshot.date,
            details: details,
            totalReadingTime: snapshot.totalReadingTime,
            totalNoteCount: snapshot.totalNoteCount
        )
    }
}

extension DesktopWebAPIAdapter {
    /// 返回章节树并保持 Repository 已计算的孤儿、层级、路径和递归书摘计数。
    func chapters(bookID: Int64) async throws -> [DesktopWebChapterFull] {
        do {
            return try await chapterRepositoryValue().chapters(bookID: bookID).map(Self.mapChapterFull)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 返回最近书摘关联章节；nil 由包络编码器省略 data 字段。
    func lastUsedChapter(bookID: Int64) async throws -> DesktopWebChapter? {
        do {
            return try await chapterRepositoryValue().lastUsedChapter(bookID: bookID).map(Self.mapChapter)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 聚合星标章节分组，并在 Adapter 边界统一生成书籍封面代理地址。
    func starredChapterGroups() async throws -> [DesktopWebStarredChapterGroup] {
        do {
            let snapshots = try await chapterRepositoryValue().starredChapterGroups()
            var groups: [DesktopWebStarredChapterGroup] = []
            groups.reserveCapacity(snapshots.count)
            for snapshot in snapshots {
                groups.append(
                    DesktopWebStarredChapterGroup(
                        book: DesktopWebChapterBook(
                            id: snapshot.book.id,
                            name: snapshot.book.name,
                            cover: await resolvedCover(
                                bookID: snapshot.book.id,
                                rawCover: snapshot.book.cover
                            ),
                            author: snapshot.book.author,
                            press: snapshot.book.press
                        ),
                        chapters: snapshot.chapters.map(Self.mapStarredChapter),
                        chapterCount: snapshot.chapterCount,
                        noteCount: snapshot.noteCount,
                        latestUpdatedTime: snapshot.latestUpdatedTime
                    )
                )
            }
            return groups
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 创建章节，父 ID 缺省和层级规则由 Repository 按 Kotlin 合同处理。
    func createChapter(
        bookID: Int64,
        request: DesktopWebChapterCreateRequest
    ) async throws -> DesktopWebChapterResult {
        do {
            return Self.mapChapterResult(
                try await chapterRepositoryValue().createChapter(
                    bookID: bookID,
                    title: request.title,
                    parentID: request.parentId
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新标题并保留 Android 分步 metadata 刷新边界。
    func updateChapter(
        id: Int64,
        request: DesktopWebChapterUpdateRequest
    ) async throws -> DesktopWebChapterResult {
        do {
            return Self.mapChapterResult(
                try await chapterRepositoryValue().updateChapter(id: id, title: request.title)
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新星标并返回重建后的完整轻量章节路径。
    func updateChapterStarred(
        id: Int64,
        request: DesktopWebChapterStarredRequest
    ) async throws -> DesktopWebChapter {
        do {
            return Self.mapChapter(
                try await chapterRepositoryValue().updateChapterStarred(
                    id: id,
                    isStarred: request.isStarred
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 软删除单棵章节子树并解除书摘关联。
    func deleteChapter(id: Int64) async throws {
        do {
            try await chapterRepositoryValue().deleteChapter(id: id)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 透传批量删除原始 ID，包含 Android 对不存在 ID 的既有副作用。
    func batchDeleteChapters(_ request: DesktopWebChapterIDsRequest) async throws {
        do {
            try await chapterRepositoryValue().batchDeleteChapters(ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按请求顺序重排顶层章节，不自动补全缺失同级项。
    func reorderParentChapters(
        bookID: Int64,
        request: DesktopWebChapterIDsRequest
    ) async throws {
        do {
            try await chapterRepositoryValue().reorderParentChapters(
                bookID: bookID,
                ids: request.ids
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按请求顺序重排目标父章节的直接子项。
    func reorderChildChapters(
        parentID: Int64,
        request: DesktopWebChapterIDsRequest
    ) async throws {
        do {
            try await chapterRepositoryValue().reorderChildChapters(
                parentID: parentID,
                ids: request.ids
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 把章节追加到父节点末尾；重复与非正 ID 的归一化由 Repository 对齐 Android。
    func moveChaptersToParent(_ request: DesktopWebChapterMoveToParentRequest) async throws {
        do {
            try await chapterRepositoryValue().moveToParent(
                chapterIDs: request.chapterIds,
                parentID: request.parentId
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 把同书子章节追加到顶层末尾。
    func moveChaptersOut(_ request: DesktopWebChapterMoveOutRequest) async throws {
        do {
            try await chapterRepositoryValue().moveOut(chapterIDs: request.chapterIds)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按标题输入顺序逐项创建同级章节，并返回实际未被空白过滤的结果。
    func batchCreateChapters(
        bookID: Int64,
        request: DesktopWebChapterBatchCreateRequest
    ) async throws -> DesktopWebChapterBatchResult {
        do {
            let snapshots = try await chapterRepositoryValue().batchCreateChapters(
                bookID: bookID,
                titles: request.titles,
                parentID: request.parentId
            )
            return DesktopWebChapterBatchResult(created: snapshots.map(Self.mapChapterResult))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 校验本地书籍后请求文渠候选，并保持 Android fuzzywuzzy 稳定排序。
    func searchOnlineChapterCandidates(
        bookID: Int64,
        keyword: String
    ) async throws -> [DesktopWebOnlineChapterCandidate] {
        do {
            return try await chapterOnlineRepositoryValue()
                .searchCandidates(bookID: bookID, keyword: keyword)
                .map(Self.mapOnlineChapterCandidate)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 解析显式或书籍内置豆瓣编号并返回规范化后的文渠目录。
    func onlineChapterCatalog(
        bookID: Int64,
        doubanID: Int?
    ) async throws -> DesktopWebOnlineChapterCatalog {
        do {
            let snapshot = try await chapterOnlineRepositoryValue().onlineCatalog(
                bookID: bookID,
                requestedDoubanID: doubanID
            )
            return DesktopWebOnlineChapterCatalog(
                doubanId: snapshot.doubanID,
                title: snapshot.title,
                catalog: snapshot.catalog
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 把目录预览树递归映射到 Package DTO；该 POST 不写数据库且不受会员写门禁影响。
    func previewChapterImport(
        bookID: Int64,
        request: DesktopWebChapterImportPreviewRequest
    ) async throws -> DesktopWebChapterImportPreview {
        do {
            let snapshot = try await chapterRepositoryValue().previewImport(
                bookID: bookID,
                catalog: request.catalog
            )
            return DesktopWebChapterImportPreview(
                items: snapshot.items.map(Self.mapChapterImportNode),
                totalCount: snapshot.totalCount,
                selectableCount: snapshot.selectableCount,
                duplicateCount: snapshot.duplicateCount,
                selectedCount: snapshot.selectedCount
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 在 Repository 单事务内提交目录导入，并保留 Android 当前选择计数语义。
    func commitChapterImport(
        bookID: Int64,
        request: DesktopWebChapterImportCommitRequest
    ) async throws -> DesktopWebChapterImportCommitResult {
        do {
            let snapshot = try await chapterRepositoryValue().commitImport(
                bookID: bookID,
                catalog: request.catalog,
                selectedKeys: request.selectedKeys
            )
            return DesktopWebChapterImportCommitResult(
                created: snapshot.created,
                skipped: snapshot.skipped,
                duplicated: snapshot.duplicated
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取书内分页书摘并映射章节、标签、图片及章节计数。
    func bookNotes(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        filter: DesktopWebBookNoteFilter
    ) async throws -> DesktopWebBookNotesPage {
        do {
            let snapshot = try await noteRepositoryValue().bookNotes(
                bookID: bookID,
                page: page,
                pageSize: pageSize,
                filter: DesktopWebBookNoteFilterInput(
                    chapterID: filter.chapterID,
                    tagID: filter.tagID,
                    tagIDs: filter.tagIDs,
                    tagMode: filter.tagMode,
                    sortBy: filter.sortBy,
                    sortOrder: filter.sortOrder
                )
            )
            return DesktopWebBookNotesPage(
                items: snapshot.items.map(Self.mapBookNote),
                pagination: DesktopWebPagination(
                    page: snapshot.page,
                    pageSize: snapshot.pageSize,
                    total: Int64(snapshot.total),
                    totalPages: snapshot.totalPages
                ),
                chapterNoteCounts: snapshot.chapterNoteCounts.map {
                    DesktopWebBookNoteChapterCount(chapterId: $0.chapterID, noteCount: $0.noteCount)
                }
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 返回书内默认和自定义书摘标签筛选项。
    func bookNoteTagFilters(bookID: Int64) async throws -> [DesktopWebNoteTagFilter] {
        do {
            return try await noteRepositoryValue().bookNoteTagFilters(bookID: bookID).map(Self.mapNoteTagFilter)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取书摘排序设置。
    func bookNoteSortRule(bookID: Int64) async throws -> DesktopWebNoteSortRule {
        do {
            return Self.mapNoteSortRule(try await noteRepositoryValue().bookNoteSortRule(bookID: bookID))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新书摘排序设置并返回数据库最终值。
    func updateBookNoteSortRule(
        bookID: Int64,
        request: DesktopWebNoteSortRuleUpdateRequest
    ) async throws -> DesktopWebNoteSortRule {
        do {
            return Self.mapNoteSortRule(
                try await noteRepositoryValue().updateBookNoteSortRule(
                    bookID: bookID,
                    sortBy: request.sortBy,
                    sortOrder: request.sortOrder
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取全局分页书摘，并异步应用与书架一致的封面代理规则。
    func globalNotes(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalNote> {
        do {
            let snapshot = try await noteRepositoryValue().globalNotes(
                page: page,
                pageSize: pageSize,
                filter: DesktopWebGlobalNoteFilterInput(
                    keyword: filter.keyword,
                    bookID: filter.bookID,
                    bookIDs: filter.bookIDs,
                    tagID: filter.tagID,
                    tagIDs: filter.tagIDs,
                    tagMode: filter.tagMode,
                    sortBy: filter.sortBy,
                    sortOrder: filter.sortOrder,
                    sortMode: filter.sortMode,
                    excludeIDs: filter.excludeIDs
                )
            )
            var items: [DesktopWebGlobalNote] = []
            items.reserveCapacity(snapshot.items.count)
            for item in snapshot.items {
                items.append(await mapGlobalNote(item))
            }
            return DesktopWebPageResult(
                items: items,
                pagination: DesktopWebPagination(
                    page: snapshot.page,
                    pageSize: snapshot.pageSize,
                    total: Int64(snapshot.total),
                    totalPages: snapshot.totalPages
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 返回所有有效书籍范围的书摘标签筛选项。
    func globalNoteTagFilters() async throws -> [DesktopWebNoteTagFilter] {
        do {
            return try await noteRepositoryValue().globalNoteTagFilters().map(Self.mapNoteTagFilter)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取一条有效书摘详情；所属书籍软删除状态由 Android 基线决定，不在 Adapter 加码。
    func note(id: Int64) async throws -> DesktopWebBookNote {
        do {
            return Self.mapBookNote(try await noteRepositoryValue().note(id: id))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 创建书摘并映射 Android 写响应中的临时图片 ID。
    func createNote(_ request: DesktopWebNoteCreateRequest) async throws -> DesktopWebNoteResult {
        do {
            return Self.mapNoteResult(
                try await noteRepositoryValue().createNote(
                    DesktopWebNoteCreateInput(
                        bookID: request.bookId,
                        chapterID: request.chapterId,
                        content: request.content,
                        idea: request.idea,
                        position: request.position,
                        tagIDs: request.tagIds,
                        imageURLs: request.imageUrls,
                        uploadedTicketIDs: request.uploadedTicketIds,
                        createdTime: request.createdTime
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 局部更新书摘，nil 与空数组语义由专用 Repository 保留。
    func updateNote(
        id: Int64,
        request: DesktopWebNoteUpdateRequest
    ) async throws -> DesktopWebNoteResult {
        do {
            return Self.mapNoteResult(
                try await noteRepositoryValue().updateNote(
                    id: id,
                    input: DesktopWebNoteUpdateInput(
                        bookID: request.bookId,
                        chapterID: request.chapterId,
                        content: request.content,
                        idea: request.idea,
                        position: request.position,
                        tagIDs: request.tagIds,
                        imageURLs: request.imageUrls,
                        uploadedTicketIDs: request.uploadedTicketIds,
                        createdTime: request.createdTime
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 软删除书摘图谱。
    func deleteNote(id: Int64) async throws {
        do {
            try await noteRepositoryValue().deleteNote(id: id)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 批量软删除书摘，缺失 ID 静默跳过。
    func batchDeleteNotes(_ request: DesktopWebNoteIDsRequest) async throws {
        do {
            try await noteRepositoryValue().batchDeleteNotes(ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 批量移动到章节，保留 Android 无公共事务的部分提交边界。
    func batchMoveNotesToChapter(_ request: DesktopWebNoteBatchMoveChapterRequest) async throws {
        do {
            try await noteRepositoryValue().batchMoveNotesToChapter(
                ids: request.ids,
                chapterID: request.chapterId
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 批量追加或替换书摘标签。
    func batchSetNoteTags(_ request: DesktopWebNoteBatchSetTagsRequest) async throws {
        do {
            try await noteRepositoryValue().batchSetNoteTags(
                ids: request.ids,
                tagIDs: request.tagIds,
                mode: request.mode
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 批量移动到目标书籍并映射章节祖先路径。
    func batchMoveNotesToBook(_ request: DesktopWebNoteBatchMoveBookRequest) async throws {
        do {
            try await noteRepositoryValue().batchMoveNotesToBook(
                ids: request.ids,
                targetBookID: request.targetBookId
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 合并书摘并返回新记录。
    func batchMergeNotes(_ request: DesktopWebNoteBatchMergeRequest) async throws -> DesktopWebNoteResult {
        do {
            return Self.mapNoteResult(
                try await noteRepositoryValue().batchMergeNotes(
                    DesktopWebNoteMergeInput(
                        ids: request.ids,
                        contentOrderedIDs: request.contentOrderedIds,
                        ideaOrderedIDs: request.ideaOrderedIds,
                        orderedIDs: request.orderedIds,
                        contentMergeRule: request.contentMergeRule,
                        ideaMergeRule: request.ideaMergeRule,
                        merged: request.merged.map {
                            DesktopWebNoteMergeDraftInput(
                                content: $0.content,
                                idea: $0.idea,
                                position: $0.position,
                                positionUnit: $0.positionUnit,
                                chapterID: $0.chapterId,
                                tagIDs: $0.tagIds,
                                imageURLs: $0.imageUrls,
                                uploadedTicketIDs: $0.uploadedTicketIds,
                                createdTime: $0.createdTime
                            )
                        }
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取全局分页书评，并对关联书籍封面应用与书架一致的代理规则。
    func globalReviews(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalReviewFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalReview> {
        do {
            let snapshot = try await reviewRepositoryValue().globalReviews(
                page: page,
                pageSize: pageSize,
                filter: DesktopWebGlobalReviewFilterInput(
                    keyword: filter.keyword,
                    bookID: filter.bookID,
                    sortBy: filter.sortBy,
                    sortOrder: filter.sortOrder,
                    sortMode: filter.sortMode,
                    excludeIDs: filter.excludeIDs
                )
            )
            var items: [DesktopWebGlobalReview] = []
            items.reserveCapacity(snapshot.items.count)
            for item in snapshot.items {
                items.append(await mapGlobalReview(item))
            }
            return DesktopWebPageResult(
                items: items,
                pagination: DesktopWebPagination(
                    page: snapshot.page,
                    pageSize: snapshot.pageSize,
                    total: Int64(snapshot.total),
                    totalPages: snapshot.totalPages
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取精确书评草稿；不存在时保留 Android data:null 响应。
    func reviewDraft(bookID: Int64, reviewID: Int64) async throws -> DesktopWebReviewDraft? {
        do {
            return try await reviewRepositoryValue().reviewDraft(bookID: bookID, reviewID: reviewID)
                .map(Self.mapReviewDraft)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 保存、清空或替换书评草稿。
    func upsertReviewDraft(
        _ request: DesktopWebReviewDraftUpsertRequest
    ) async throws -> DesktopWebReviewDraft {
        do {
            return Self.mapReviewDraft(
                try await reviewRepositoryValue().upsertReviewDraft(
                    DesktopWebReviewDraftInput(
                        bookID: request.bookId,
                        reviewID: request.reviewId,
                        title: request.title,
                        content: request.content,
                        imageURLs: request.imageUrls,
                        uploadedTicketIDs: request.uploadedTicketIds,
                        createdTime: request.createdTime,
                        savedTimeMillis: request.savedTimeMillis
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 删除指定书评草稿，缺失草稿保持幂等成功。
    func deleteReviewDraft(bookID: Int64, reviewID: Int64) async throws {
        do {
            try await reviewRepositoryValue().deleteReviewDraft(bookID: bookID, reviewID: reviewID)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取书内分页书评。
    func bookReviews(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> DesktopWebPageResult<DesktopWebBookReview> {
        do {
            let snapshot = try await reviewRepositoryValue().bookReviews(
                bookID: bookID,
                page: page,
                pageSize: pageSize,
                sortBy: sortBy,
                sortOrder: sortOrder
            )
            return DesktopWebPageResult(
                items: snapshot.items.map(Self.mapBookReview),
                pagination: DesktopWebPagination(
                    page: snapshot.page,
                    pageSize: snapshot.pageSize,
                    total: Int64(snapshot.total),
                    totalPages: snapshot.totalPages
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取书评排序设置。
    func bookReviewSortRule(bookID: Int64) async throws -> DesktopWebReviewSortRule {
        do {
            return Self.mapReviewSortRule(
                try await reviewRepositoryValue().bookReviewSortRule(bookID: bookID)
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新书评排序设置并返回数据库最终值。
    func updateBookReviewSortRule(
        bookID: Int64,
        request: DesktopWebReviewSortRuleUpdateRequest
    ) async throws -> DesktopWebReviewSortRule {
        do {
            return Self.mapReviewSortRule(
                try await reviewRepositoryValue().updateBookReviewSortRule(
                    bookID: bookID,
                    sortBy: request.sortBy,
                    sortOrder: request.sortOrder
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取一条有效书评详情；所属书籍删除态不在 Adapter 加码。
    func review(id: Int64) async throws -> DesktopWebBookReview {
        do {
            return Self.mapBookReview(try await reviewRepositoryValue().review(id: id))
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 创建书评并保留 Android 写响应的临时图片 ID。
    func createReview(_ request: DesktopWebReviewCreateRequest) async throws -> DesktopWebBookReview {
        do {
            return Self.mapBookReview(
                try await reviewRepositoryValue().createReview(
                    DesktopWebReviewCreateInput(
                        bookID: request.bookId,
                        title: request.title,
                        content: request.content,
                        imageURLs: request.imageUrls,
                        uploadedTicketIDs: request.uploadedTicketIds,
                        createdTime: request.createdTime
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 局部更新书评，nil 与空图片数组语义由专用 Repository 保留。
    func updateReview(
        id: Int64,
        request: DesktopWebReviewUpdateRequest
    ) async throws -> DesktopWebBookReview {
        do {
            return Self.mapBookReview(
                try await reviewRepositoryValue().updateReview(
                    id: id,
                    input: DesktopWebReviewUpdateInput(
                        title: request.title,
                        content: request.content,
                        imageURLs: request.imageUrls,
                        uploadedTicketIDs: request.uploadedTicketIds,
                        createdTime: request.createdTime
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 软删除书评及图片图谱。
    func deleteReview(id: Int64) async throws {
        do {
            try await reviewRepositoryValue().deleteReview(id: id)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取 Android 未限定 book_id 的“全局类别”集合。
    func globalRelatedCategories(includeHidden: Bool) async throws -> [DesktopWebRelatedCategory] {
        do {
            return try await relatedRepositoryValue().globalCategories(includeHidden: includeHidden)
                .map(Self.mapRelatedCategory)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取指定书籍可用的全局与书内类别。
    func relatedCategories(
        bookID: Int64,
        includeHidden: Bool
    ) async throws -> [DesktopWebRelatedCategory] {
        do {
            return try await relatedRepositoryValue()
                .categories(bookID: bookID, includeHidden: includeHidden)
                .map(Self.mapRelatedCategory)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 创建书内或全局相关类别。
    func createRelatedCategory(
        bookID: Int64,
        request: DesktopWebRelatedCategoryCreateRequest
    ) async throws -> DesktopWebRelatedCategory {
        do {
            return Self.mapRelatedCategory(
                try await relatedRepositoryValue().createCategory(
                    bookID: bookID,
                    input: DesktopWebRelatedCategoryCreateInput(
                        title: request.title,
                        order: request.order,
                        scope: request.scope
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 局部更新相关类别，保留 scope 变更不迁移内容的 Android 行为。
    func updateRelatedCategory(
        id: Int64,
        request: DesktopWebRelatedCategoryUpdateRequest
    ) async throws -> DesktopWebRelatedCategory {
        do {
            return Self.mapRelatedCategory(
                try await relatedRepositoryValue().updateCategory(
                    id: id,
                    input: DesktopWebRelatedCategoryUpdateInput(
                        title: request.title,
                        order: request.order,
                        scope: request.scope,
                        bookID: request.bookId
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新相关类别隐藏状态。
    func updateRelatedCategoryVisibility(
        id: Int64,
        request: DesktopWebRelatedCategoryVisibilityRequest
    ) async throws -> DesktopWebRelatedCategory {
        do {
            return Self.mapRelatedCategory(
                try await relatedRepositoryValue().updateCategoryVisibility(
                    id: id,
                    isHidden: request.isHide
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 删除类别；该 Controller 将不存在错误归类为 40002。
    func deleteRelatedCategory(id: Int64) async throws {
        do {
            try await relatedRepositoryValue().deleteCategory(id: id)
        } catch {
            throw Self.mapRelatedResourceError(error)
        }
    }

    /// 按请求顺序重排指定书籍的全局与书内类别。
    func reorderRelatedCategories(
        bookID: Int64,
        request: DesktopWebRelatedCategoryReorderRequest
    ) async throws {
        do {
            try await relatedRepositoryValue().reorderCategories(bookID: bookID, ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取书内相关内容排序规则。
    func relatedNoteSortRule(bookID: Int64) async throws -> DesktopWebRelatedSortRule {
        do {
            let snapshot = try await relatedRepositoryValue().sortRule(bookID: bookID)
            return DesktopWebRelatedSortRule(sortBy: snapshot.sortBy, sortOrder: snapshot.sortOrder)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 更新书内相关内容排序规则。
    func updateRelatedNoteSortRule(
        bookID: Int64,
        request: DesktopWebRelatedSortRuleUpdateRequest
    ) async throws -> DesktopWebRelatedSortRule {
        do {
            let snapshot = try await relatedRepositoryValue().updateSortRule(
                bookID: bookID,
                sortBy: request.sortBy,
                sortOrder: request.sortOrder
            )
            return DesktopWebRelatedSortRule(sortBy: snapshot.sortBy, sortOrder: snapshot.sortOrder)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 分页读取书内相关内容并解析封面代理 URL。
    func relatedNotes(
        bookID: Int64,
        page: Int,
        pageSize: Int,
        filter: DesktopWebRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebRelatedNote> {
        do {
            return try await mapRelatedPage(
                relatedRepositoryValue().relatedNotes(
                    bookID: bookID,
                    page: page,
                    pageSize: pageSize,
                    filter: Self.mapRelatedFilter(filter)
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 不分页读取书内相关内容，保留 Android 空页 pageSize=0。
    func allRelatedNotes(
        bookID: Int64,
        filter: DesktopWebRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebRelatedNote> {
        do {
            return try await mapRelatedPage(
                relatedRepositoryValue().allRelatedNotes(
                    bookID: bookID,
                    filter: Self.mapRelatedFilter(filter)
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 分页读取全局相关内容并解析来源书与内容书封面。
    func globalRelatedNotes(
        page: Int,
        pageSize: Int,
        filter: DesktopWebGlobalRelatedNoteFilter
    ) async throws -> DesktopWebPageResult<DesktopWebGlobalRelatedNote> {
        do {
            let snapshot = try await relatedRepositoryValue().globalRelatedNotes(
                page: page,
                pageSize: pageSize,
                filter: DesktopWebGlobalRelatedNoteFilterInput(
                    bookID: filter.bookID,
                    categoryID: filter.categoryID,
                    keyword: filter.keyword,
                    sortBy: filter.sortBy,
                    sortOrder: filter.sortOrder,
                    sortMode: filter.sortMode,
                    excludeIDs: filter.excludeIDs
                )
            )
            var items: [DesktopWebGlobalRelatedNote] = []
            items.reserveCapacity(snapshot.items.count)
            for item in snapshot.items {
                items.append(await mapGlobalRelatedNote(item))
            }
            return DesktopWebPageResult(
                items: items,
                pagination: DesktopWebPagination(
                    page: snapshot.page,
                    pageSize: snapshot.pageSize,
                    total: Int64(snapshot.total),
                    totalPages: snapshot.totalPages
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按 ID 读取相关内容详情；不存在错误按 Controller 合同返回 40002。
    func relatedNote(id: Int64) async throws -> DesktopWebRelatedNote {
        do {
            return try await mapRelatedNote(relatedRepositoryValue().relatedNote(id: id))
        } catch {
            throw Self.mapRelatedResourceError(error)
        }
    }

    /// 创建相关内容并原样传递可选图片与上传票据。
    func createRelatedNote(
        _ request: DesktopWebRelatedNoteCreateRequest
    ) async throws -> DesktopWebRelatedNote {
        do {
            return try await mapRelatedNote(
                relatedRepositoryValue().createRelatedNote(
                    input: DesktopWebRelatedNoteCreateInput(
                        bookID: request.bookId,
                        categoryID: request.categoryId,
                        title: request.title,
                        content: request.content,
                        url: request.url,
                        imageURLs: request.imageUrls,
                        uploadedTicketIDs: request.uploadedTicketIds,
                        contentBookID: request.contentBookId,
                        createdTime: request.createdTime
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 局部更新相关内容；nil 与显式空图片数组的差异由 Repository 保留。
    func updateRelatedNote(
        id: Int64,
        request: DesktopWebRelatedNoteUpdateRequest
    ) async throws -> DesktopWebRelatedNote {
        do {
            return try await mapRelatedNote(
                relatedRepositoryValue().updateRelatedNote(
                    id: id,
                    input: DesktopWebRelatedNoteUpdateInput(
                        categoryID: request.categoryId,
                        title: request.title,
                        content: request.content,
                        url: request.url,
                        imageURLs: request.imageUrls,
                        uploadedTicketIDs: request.uploadedTicketIds,
                        contentBookID: request.contentBookId,
                        createdTime: request.createdTime
                    )
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 软删除单条相关内容；不存在错误按 Controller 合同返回 40002。
    func deleteRelatedNote(id: Int64) async throws {
        do {
            try await relatedRepositoryValue().deleteRelatedNote(id: id)
        } catch {
            throw Self.mapRelatedResourceError(error)
        }
    }

    /// 批量软删除相关内容。
    func batchDeleteRelatedNotes(_ request: DesktopWebRelatedNoteBatchDeleteRequest) async throws {
        do {
            try await relatedRepositoryValue().batchDeleteRelatedNotes(ids: request.ids)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 完整预检后批量移动相关内容类别。
    func batchUpdateRelatedNotesCategory(
        _ request: DesktopWebRelatedNoteBatchUpdateCategoryRequest
    ) async throws {
        do {
            try await relatedRepositoryValue().batchUpdateRelatedNotesCategory(
                ids: request.ids,
                categoryID: request.categoryId
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 保存网页计时完成记录；Android 的宽松计时字段校验由专用 Repository 保留。
    func createReadingSession(_ request: DesktopWebReadingSessionCreateRequest) async throws -> Int64 {
        do {
            return try await readingRecordRepositoryValue().createReadingSession(
                DesktopWebReadingSessionInput(
                    bookID: request.bookId,
                    startTime: request.startTime,
                    endTime: request.endTime,
                    elapsedSeconds: request.elapsedSeconds,
                    countdownSeconds: request.countdownSeconds,
                    pausedDurationMillis: request.pausedDurationMillis,
                    position: request.position,
                    recordedPositionUnit: request.recordedPositionUnit,
                    insight: request.insight,
                    confirmedLongDuration: request.confirmedLongDuration
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 读取书内完成态阅读记录并映射为 Package DTO。
    func readingRecords(bookID: Int64, sortOrder: String) async throws -> [DesktopWebReadingRecord] {
        do {
            return try await readingRecordRepositoryValue()
                .readingRecords(bookID: bookID, sortOrder: sortOrder)
                .map(Self.mapReadingRecord)
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 按 book/record 归属读取单条记录。
    func readingRecord(bookID: Int64, recordID: Int64) async throws -> DesktopWebReadingRecord {
        do {
            return Self.mapReadingRecord(
                try await readingRecordRepositoryValue().readingRecord(
                    bookID: bookID,
                    recordID: recordID
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 创建精确或模糊阅读记录，并返回数据库回读结果。
    func createReadingRecord(
        bookID: Int64,
        request: DesktopWebReadingRecordUpsertRequest
    ) async throws -> DesktopWebReadingRecord {
        do {
            return Self.mapReadingRecord(
                try await readingRecordRepositoryValue().createReadingRecord(
                    bookID: bookID,
                    input: Self.mapReadingRecordInput(request)
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 全量更新阅读记录，保留 Android 对可选位置字段的覆盖语义。
    func updateReadingRecord(
        bookID: Int64,
        recordID: Int64,
        request: DesktopWebReadingRecordUpsertRequest
    ) async throws -> DesktopWebReadingRecord {
        do {
            return Self.mapReadingRecord(
                try await readingRecordRepositoryValue().updateReadingRecord(
                    bookID: bookID,
                    recordID: recordID,
                    input: Self.mapReadingRecordInput(request)
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 软删除精确归属记录；未完成状态的兼容行为由 Repository 决定。
    func deleteReadingRecord(bookID: Int64, recordID: Int64) async throws {
        do {
            try await readingRecordRepositoryValue().deleteReadingRecord(
                bookID: bookID,
                recordID: recordID
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 执行单一搜索域并把 App 快照异步映射为 Package 的透明异构项。
    func search(
        type: DesktopWebSearchType,
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async throws -> DesktopWebSearchPage {
        do {
            guard let domain = DesktopWebSearchDomain(rawValue: type.rawValue) else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("Invalid search type: \(type.rawValue)")
            }
            return await mapSearchPage(
                try await searchRepositoryValue().search(
                    domain: domain,
                    keyword: keyword,
                    page: page,
                    pageSize: pageSize,
                    bookID: bookID,
                    tagID: tagID
                )
            )
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 严格按 Android 的 book→note→relevant→review 顺序查询，单域失败只写入该域 errors。
    func searchAggregate(
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async -> DesktopWebSearchAggregateResult {
        let book = await aggregateSearch(
            type: .book,
            keyword: keyword,
            page: page,
            pageSize: pageSize,
            bookID: bookID,
            tagID: tagID
        )
        let note = await aggregateSearch(
            type: .note,
            keyword: keyword,
            page: page,
            pageSize: pageSize,
            bookID: bookID,
            tagID: tagID
        )
        let relevant = await aggregateSearch(
            type: .relevant,
            keyword: keyword,
            page: page,
            pageSize: pageSize,
            bookID: bookID,
            tagID: tagID
        )
        let review = await aggregateSearch(
            type: .review,
            keyword: keyword,
            page: page,
            pageSize: pageSize,
            bookID: bookID,
            tagID: tagID
        )
        return DesktopWebSearchAggregateResult(
            book: book.page,
            note: note.page,
            relevant: relevant.page,
            review: review.page,
            errors: DesktopWebSearchAggregateErrors(
                book: book.error,
                note: note.error,
                relevant: relevant.error,
                review: review.error
            )
        )
    }

    /// 解析 Controller 的 year/month=0 默认值后返回自然月阅读统计。
    func monthlyReading(year: Int, month: Int) async throws -> DesktopWebMonthlyReading {
        try await withStatistics { repository in
            let now = Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000)
            let calendar = Calendar.current
            let actualYear = year == 0 ? calendar.component(.year, from: now) : year
            let actualMonth = month == 0 ? calendar.component(.month, from: now) : month
            let value = try await repository.monthlyReading(year: actualYear, month: actualMonth)
            return DesktopWebMonthlyReading(
                year: value.year,
                month: value.month,
                label: "\(value.year)年\(value.month)月",
                totalReadTime: value.totalReadTime,
                daysInMonth: value.daysInMonth,
                dailyReadingTimes: value.dailyReadingTimes.map {
                    DesktopWebDayReadingTime(day: $0.day, date: $0.date, readTime: $0.readTime)
                }
            )
        }
    }

    /// 返回周阅读统计；nil 由 Repository 解析为当前周周一。
    func weeklyReading(weekStart: String?) async throws -> DesktopWebWeeklyReading {
        try await withStatistics { repository in
            let value = try await repository.weeklyReading(weekStart: weekStart)
            return DesktopWebWeeklyReading(
                totalReadTime: value.totalReadTime,
                weekStart: value.weekStart,
                weekEnd: value.weekEnd,
                days: value.days.map {
                    DesktopWebWeekDayReading(
                        dayOfWeek: $0.dayOfWeek, date: $0.date,
                        readTime: $0.readTime, hasReading: $0.hasReading
                    )
                },
                currentStreak: value.currentStreak
            )
        }
    }

    /// 返回六时段阅读节律；准确与模糊记录的可视化差异由 Repository 固定。
    func readingRhythm(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebReadingRhythm {
        try await withStatistics { repository in
            let value = try await repository.readingRhythm(year: year, month: month, weekStart: weekStart)
            return DesktopWebReadingRhythm(
                totalReadTime: value.totalReadTime,
                segments: value.segments.map {
                    DesktopWebReadingRhythmSegment(
                        id: $0.id, label: $0.label, startHour: $0.startHour,
                        endHour: $0.endHour, readTime: $0.readTime, ratio: $0.ratio
                    )
                },
                peakSegmentIds: value.peakSegmentIDs,
                rhythmType: value.rhythmType,
                rhythmLabel: value.rhythmLabel,
                rhythmDescription: value.rhythmDescription,
                mostFrequentTime: value.mostFrequentTime,
                hasTimedData: value.hasTimedData,
                scopeTotalReadTime: value.scopeTotalReadTime,
                accurateReadTime: value.accurateReadTime,
                fuzzyReadTime: value.fuzzyReadTime
            )
        }
    }

    /// 返回全量或年度热力图；未知 type 保持 Android 的 all 回退语义。
    func heatmap(year: Int, type: String) async throws -> DesktopWebHeatmap {
        try await withStatistics { repository in
            let value = try await repository.heatmap(year: year, type: type)
            return DesktopWebHeatmap(
                days: value.days.map {
                    DesktopWebHeatmapDay(
                        date: $0.date, readTime: $0.readTime, noteCount: $0.noteCount,
                        checkInTime: $0.checkInTime, bookStates: $0.bookStates, level: $0.level
                    )
                },
                startDate: value.startDate,
                endDate: value.endDate,
                yearRange: value.yearRange,
                earliestDate: value.earliestDate,
                latestDate: value.latestDate
            )
        }
    }

    /// 返回统计概览并逐项映射环比差值和 Float 饼图比例。
    func statisticsOverview(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebStatisticsOverview {
        try await withStatistics { repository in
            let value = try await repository.overview(year: year, month: month, weekStart: weekStart)
            let comparison = value.comparison.map { item in
                DesktopWebOverviewComparison(
                    mode: item.mode,
                    label: item.label,
                    hasBaseline: item.hasBaseline,
                    delta: item.delta.map {
                        DesktopWebOverviewComparisonDelta(
                            totalReadingTime: $0.totalReadingTime,
                            readingDays: $0.readingDays,
                            noteCount: $0.noteCount,
                            readDoneBookCount: $0.readDoneBookCount,
                            totalWordCount: $0.totalWordCount,
                            purchaseBookCount: $0.purchaseBookCount
                        )
                    }
                )
            }
            return DesktopWebStatisticsOverview(
                totalReadingTime: value.totalReadingTime,
                readingDays: value.readingDays,
                noteCount: value.noteCount,
                readDoneBookCount: value.readDoneBookCount,
                totalWordCount: value.totalWordCount,
                purchaseBookCount: value.purchaseBookCount,
                statusDistribution: value.statusDistribution.map {
                    DesktopWebStatusDistribution(
                        status: $0.status, label: $0.label, count: $0.count, ratio: $0.ratio
                    )
                },
                readingTimeTrend: value.readingTimeTrend.map(Self.mapTrend),
                readingTimeTrendUnit: value.readingTimeTrendUnit,
                comparison: comparison
            )
        }
    }

    /// 返回年度完读书单；year=0 由 Controller 语义解析为当前年。
    func yearlyBooks(year: Int) async throws -> DesktopWebYearlyBooks {
        try await withStatistics { repository in
            let actualYear = year == 0
                ? Calendar.current.component(
                    .year,
                    from: Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000)
                )
                : year
            let value = try await repository.yearlyBooks(year: actualYear)
            var books: [DesktopWebYearlyBook] = []
            books.reserveCapacity(value.books.count)
            for item in value.books {
                let book = await mapBook(item.book)
                let readDoneCount = book.readDoneCount == 0
                    && book.readStatus == 3
                    && item.readDoneTime > 0 ? 1 : book.readDoneCount
                books.append(
                    DesktopWebYearlyBook(
                        id: book.id, name: book.name, rawName: book.rawName, cover: book.cover,
                        author: book.author, translator: book.translator, isbn: book.isbn,
                        press: book.press, pubDate: book.pubDate, doubanId: book.doubanId,
                        readStatus: book.readStatus, readStatusChangedTime: item.readDoneTime,
                        readDoneCount: readDoneCount, score: book.score, readPosition: book.readPosition,
                        totalPosition: book.totalPosition, totalPagination: book.totalPagination,
                        currentPositionUnit: book.currentPositionUnit, positionUnit: book.positionUnit,
                        type: book.type, sourceId: book.sourceId, sourceName: book.sourceName,
                        purchaseDate: book.purchaseDate, price: book.price.map { Double(Float($0)) },
                        isPinned: book.isPinned, pinOrder: book.pinOrder, order: book.order,
                        wordCount: book.wordCount, totalReadingTime: book.totalReadingTime,
                        createdTime: book.createdTime, updatedTime: book.updatedTime,
                        noteCount: book.noteCount, reviewCount: book.reviewCount,
                        relevantCount: book.relevantCount, readDoneTime: item.readDoneTime,
                        bookmarkModifiedTime: book.bookmarkModifiedTime,
                        groups: Array(book.groups.prefix(1)), tags: book.tags, isDeleted: book.isDeleted
                    )
                )
            }
            return DesktopWebYearlyBooks(
                year: value.year, books: books, totalCount: books.count, yearRange: value.years
            )
        }
    }

    /// 返回全部年度目标，保持数据库原始顺序。
    func readTargets() async throws -> [DesktopWebReadTarget] {
        try await withStatistics { repository in
            try await repository.readTargets().map { DesktopWebReadTarget(year: $0.year, target: $0.target) }
        }
    }

    /// year=0 回退当前年份，缺失目标返回 12。
    func readTarget(year: Int) async throws -> DesktopWebReadTarget {
        try await withStatistics { repository in
            let actualYear = year == 0
                ? Calendar.current.component(
                    .year,
                    from: Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000)
                )
                : year
            let value = try await repository.readTarget(year: actualYear)
            return DesktopWebReadTarget(year: value.year, target: value.target)
        }
    }

    /// 原样写入 Android 未校验的年度目标参数；写请求仍由会员门禁统一保护。
    func setReadTarget(_ request: DesktopWebReadTargetRequest) async throws -> DesktopWebReadTarget {
        try await withStatistics { repository in
            let value = try await repository.setReadTarget(year: request.year, target: request.target)
            return DesktopWebReadTarget(year: value.year, target: value.target)
        }
    }

    /// 返回指定年度庆祝标记，非法年份映射为 40001。
    func yearlyGoalCelebration(year: Int) async throws -> DesktopWebYearlyGoalCelebration {
        try await withStatistics { repository in
            DesktopWebYearlyGoalCelebration(
                year: year,
                shown: try await repository.yearlyGoalCelebration(year: year)
            )
        }
    }

    /// 幂等标记年度庆祝已展示；写请求仍由会员门禁统一保护。
    func markYearlyGoalCelebration(
        _ request: DesktopWebYearlyGoalCelebrationRequest
    ) async throws -> DesktopWebYearlyGoalCelebration {
        try await withStatistics { repository in
            try await repository.markYearlyGoalCelebration(year: request.year)
            return DesktopWebYearlyGoalCelebration(year: request.year, shown: true)
        }
    }

    /// 读取今日目标和阅读秒数；缺失记录时 Repository 按 Android 产生初始化写入。
    func dailyReadingTarget() async throws -> DesktopWebDailyReadingTarget {
        try await withStatistics { repository in
            let value = try await repository.dailyReadingTarget()
            return DesktopWebDailyReadingTarget(target: value.target, todayReadingTime: value.todayReadingTime)
        }
    }

    /// 写入今日目标和最近目标偏好；负数映射为 40001。
    func setDailyReadingTarget(
        _ request: DesktopWebDailyReadingTargetRequest
    ) async throws -> DesktopWebDailyReadingTarget {
        try await withStatistics { repository in
            let value = try await repository.setDailyReadingTarget(request.target)
            return DesktopWebDailyReadingTarget(target: value.target, todayReadingTime: value.todayReadingTime)
        }
    }

    func noteCountChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData {
        try await mapChart { try await $0.noteCountChart(year: year, month: month, weekStart: weekStart) }
    }

    func readDoneChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData {
        try await mapChart { try await $0.readDoneChart(year: year, month: month, weekStart: weekStart) }
    }

    func wordCountChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData {
        try await mapChart { try await $0.wordCountChart(year: year, month: month, weekStart: weekStart) }
    }

    func purchaseChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebPurchaseChart {
        try await withStatistics { repository in
            let value = try await repository.purchaseChart(year: year, month: month, weekStart: weekStart)
            return DesktopWebPurchaseChart(
                unit: value.unit, totalMoney: value.totalMoney, totalCount: value.totalCount,
                items: value.items.map(Self.mapTrend), countItems: value.countItems.map(Self.mapTrend),
                scope: value.scope, scopeLabel: value.scopeLabel
            )
        }
    }

    func bookSourceChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem] {
        try await mapPie { try await $0.bookSourceChart(year: year, month: month, weekStart: weekStart) }
    }

    func noteTagChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem] {
        try await mapPie { try await $0.noteTagChart(year: year, month: month, weekStart: weekStart) }
    }

    func bookTagChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem] {
        try await mapPie { try await $0.bookTagChart(year: year, month: month, weekStart: weekStart) }
    }
}

private extension DesktopWebAPIAdapter {
    func requireExportService() throws -> any DesktopWebExportPort {
        guard let service = catalogLock.withLock({ exportService }) else {
            throw DesktopWebAPIError(code: 50001, message: "导出服务尚未就绪")
        }
        return service
    }

    func requireImportService() throws -> any DesktopWebImportPort {
        guard let service = catalogLock.withLock({ importService }) else {
            throw DesktopWebAPIError(code: 50001, message: "导入服务尚未就绪")
        }
        return service
    }

    func requireUploadService() throws -> any DesktopWebUploadPort {
        guard let service = catalogLock.withLock({ uploadService }) else {
            throw DesktopWebAPIError(code: 50001, message: "上传服务尚未就绪")
        }
        return service
    }

    static func normalizeOnlineCatalog(_ catalog: String) -> String {
        catalog.split(separator: "\n", omittingEmptySubsequences: false)
            .map {
                $0.replacingOccurrences(of: "\u{00A0}", with: " ")
                    .replacingOccurrences(of: "\u{200B}", with: "")
                    .replacingOccurrences(of: "\u{200C}", with: "")
                    .replacingOccurrences(of: "\u{200D}", with: "")
                    .replacingOccurrences(of: "\u{FEFF}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 复刻 java fuzzywuzzy ratio 使用的 Levenshtein 归一化相似度。
    static func fuzzyRatio(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        let total = left.count + right.count
        guard total > 0 else { return 100 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return Int((Double(total - previous[right.count]) / Double(total) * 100).rounded())
    }

    static func shouldProxyCover(_ cover: String) -> Bool {
        guard !cover.isEmpty,
              !cover.hasPrefix("/api/v1/book-covers/proxy/"),
              cover.lowercased().hasPrefix("http://") || cover.lowercased().hasPrefix("https://") else {
            return false
        }
        return !cover.localizedCaseInsensitiveContains("clippingkk")
            && !cover.localizedCaseInsensitiveContains("xmnote-")
    }

    static func coverURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            throw DesktopWebAPIError(code: 404, message: "封面地址无效")
        }
        return url
    }

    static func coverSignature(bookID: Int64, cover: String, expires: Int64, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data("\(bookID)|\(cover)|\(expires)".utf8),
            using: key
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func validatePublicHost(_ host: String?) throws {
        guard let host, !host.isEmpty, host.lowercased() != "localhost" else {
            throw DesktopWebAPIError(code: 403, message: "不支持访问本地地址")
        }
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw DesktopWebAPIError(code: 502, message: "无法解析封面地址")
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let info = cursor {
            found = true
            if isBlockedAddress(info.pointee.ai_addr, family: info.pointee.ai_family) {
                throw DesktopWebAPIError(code: 403, message: "不支持访问内网地址")
            }
            cursor = info.pointee.ai_next
        }
        if !found { throw DesktopWebAPIError(code: 502, message: "无法解析封面地址") }
    }

    static func isBlockedAddress(_ address: UnsafeMutablePointer<sockaddr>?, family: Int32) -> Bool {
        guard let address else { return true }
        if family == AF_INET {
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let first = Int((value >> 24) & 0xff)
            let second = Int((value >> 16) & 0xff)
            return first == 0 || first == 10 || first == 127 || first >= 224
                || (first == 100 && (64...127).contains(second))
                || (first == 169 && second == 254)
                || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168)
                || (first == 198 && (18...19).contains(second))
        }
        if family == AF_INET6 {
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
            guard bytes.count >= 2 else { return true }
            return bytes.allSatisfy { $0 == 0 }
                || bytes == Array(repeating: 0, count: 15) + [1]
                || bytes[0] == 0xfc || bytes[0] == 0xfd
                || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
                || bytes[0] == 0xff
        }
        return true
    }

    static func inferImageMIME(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return "image/png" }
        if data.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if data.starts(with: Data("GIF8".utf8)) { return "image/gif" }
        if data.count >= 12, String(decoding: data[8..<12], as: UTF8.self) == "WEBP" { return "image/webp" }
        return "application/octet-stream"
    }

    /// 在线程锁内读取已配置仓储；未就绪时返回稳定的 50001，而不是触碰空数据库。
    func catalog() throws -> DesktopWebCatalogRepository {
        guard let repository = catalogLock.withLock({ catalogRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置分组仓储，避免数据库迁移完成前执行请求。
    func group() throws -> DesktopWebGroupRepository {
        guard let repository = catalogLock.withLock({ groupRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置书籍仓储，避免数据库迁移完成前执行请求。
    func bookRepositoryValue() throws -> DesktopWebBookRepository {
        guard let repository = catalogLock.withLock({ bookRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取封面代理 actor；数据库尚未注入时不发起任何外部请求。
    func coverServiceValue() throws -> DesktopWebBookCoverService {
        guard let service = catalogLock.withLock({ coverService }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return service
    }

    /// 在线程锁内读取已配置日历仓储，避免数据库迁移完成前执行请求。
    func calendarRepositoryValue() throws -> DesktopWebCalendarRepository {
        guard let repository = catalogLock.withLock({ calendarRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置章节仓储，避免数据库迁移完成前执行请求。
    func chapterRepositoryValue() throws -> DesktopWebChapterRepository {
        guard let repository = catalogLock.withLock({ chapterRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置在线章节仓储，避免数据库迁移完成前发起外部请求。
    func chapterOnlineRepositoryValue() throws -> DesktopWebChapterOnlineRepository {
        guard let repository = catalogLock.withLock({ chapterOnlineRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置书摘仓储，避免数据库迁移完成前执行请求。
    func noteRepositoryValue() throws -> DesktopWebNoteRepository {
        guard let repository = catalogLock.withLock({ noteRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置相关内容仓储，避免数据库迁移完成前执行请求。
    func relatedRepositoryValue() throws -> DesktopWebRelatedRepository {
        guard let repository = catalogLock.withLock({ relatedRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置书评仓储，避免数据库迁移完成前执行请求。
    func reviewRepositoryValue() throws -> DesktopWebReviewRepository {
        guard let repository = catalogLock.withLock({ reviewRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置阅读记录仓储，避免数据库迁移完成前执行请求。
    func readingRecordRepositoryValue() throws -> DesktopWebReadingRecordRepository {
        guard let repository = catalogLock.withLock({ readingRecordRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置搜索仓储，避免数据库迁移完成前执行四域查询。
    func searchRepositoryValue() throws -> DesktopWebSearchRepository {
        guard let repository = catalogLock.withLock({ searchRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 在线程锁内读取已配置统计仓储，避免数据库迁移完成前执行聚合或目标写入。
    func statisticsRepositoryValue() throws -> DesktopWebStatisticsRepository {
        guard let repository = catalogLock.withLock({ statisticsRepository }) else {
            throw DesktopWebAPIError(code: 50001, message: "数据库尚未就绪")
        }
        return repository
    }

    /// 统一执行统计仓储调用并把 Data 层分类错误映射成 Android Web 业务码。
    func withStatistics<Value>(
        _ operation: (DesktopWebStatisticsRepository) async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation(statisticsRepositoryValue())
        } catch DesktopWebStatisticsRepositoryError.invalidYear {
            throw DesktopWebAPIError(code: 40001, message: "year 必须大于 0")
        } catch DesktopWebStatisticsRepositoryError.negativeDailyTarget {
            throw DesktopWebAPIError(code: 40001, message: "每日阅读目标不能小于 0")
        } catch let DesktopWebStatisticsRepositoryError.invalidDateInput(message) {
            throw DesktopWebAPIError(code: 50001, message: message)
        } catch DesktopWebStatisticsRepositoryError.invalidDate {
            throw DesktopWebAPIError(code: 50001, message: "日期解析异常")
        } catch {
            throw Self.mapCatalogError(error)
        }
    }

    /// 将 Data 层通用柱状图映射为 Package DTO。
    func mapChart(
        _ operation: (DesktopWebStatisticsRepository) async throws -> DesktopWebChartSnapshot
    ) async throws -> DesktopWebChartData {
        try await withStatistics { repository in
            let value = try await operation(repository)
            return DesktopWebChartData(
                unit: value.unit, total: value.total, items: value.items.map(Self.mapTrend),
                scope: value.scope, scopeLabel: value.scopeLabel
            )
        }
    }

    /// 将 Data 层饼图列表映射为 Package DTO，并保留 Android Float 比例精度。
    func mapPie(
        _ operation: (DesktopWebStatisticsRepository) async throws -> [DesktopWebPieItemSnapshot]
    ) async throws -> [DesktopWebPieItem] {
        try await withStatistics { repository in
            try await operation(repository).map {
                DesktopWebPieItem(
                    label: $0.label, count: $0.count, ratio: $0.ratio,
                    scope: $0.scope, scopeLabel: $0.scopeLabel
                )
            }
        }
    }

    /// 转换统一趋势项，供概览和七类图表复用。
    static func mapTrend(_ value: DesktopWebStatisticsTrendSnapshot) -> DesktopWebStatisticsTrend {
        DesktopWebStatisticsTrend(label: value.label, value: value.value)
    }

    /// 聚合查询单域失败时返回同分页元数据的空页，并保留业务错误消息而不终止其他域。
    func aggregateSearch(
        type: DesktopWebSearchType,
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) async -> (page: DesktopWebSearchPage, error: String?) {
        do {
            return (
                try await search(
                    type: type,
                    keyword: keyword,
                    page: page,
                    pageSize: pageSize,
                    bookID: bookID,
                    tagID: tagID
                ),
                nil
            )
        } catch let error as DesktopWebAPIError {
            return (.empty(page: page, pageSize: pageSize), error.message)
        } catch {
            return (.empty(page: page, pageSize: pageSize), error.localizedDescription)
        }
    }

    /// 把 Data 层异构搜索页逐项转换，并在此边界统一生成受保护封面 URL。
    func mapSearchPage(_ snapshot: DesktopWebSearchPageSnapshot) async -> DesktopWebSearchPage {
        var items: [DesktopWebSearchItem] = []
        items.reserveCapacity(snapshot.items.count)
        for item in snapshot.items {
            switch item {
            case .book(let value):
                items.append(
                    .book(
                        await mapBook(
                            value.book,
                            searchSource: value.searchSource,
                            isInBookshelf: value.isInBookshelf,
                            fromRelatedContentBook: value.fromRelatedContentBook
                        )
                    )
                )
            case .note(let value):
                items.append(
                    .note(
                        DesktopWebSearchNote(
                            id: value.id,
                            content: value.content,
                            idea: value.idea,
                            createdTime: value.createdTime,
                            isIncludeTime: value.isIncludeTime,
                            book: await mapSearchSimpleBook(value.book),
                            chapter: value.chapter,
                            tags: value.tags.map { DesktopWebSearchTag(id: $0.id, name: $0.name) },
                            previewImages: value.previewImageURLs.map(DesktopWebSearchPreviewImage.init)
                        )
                    )
                )
            case .review(let value):
                items.append(
                    .review(
                        DesktopWebSearchReview(
                            id: value.id,
                            title: value.title,
                            content: value.content,
                            createdTime: value.createdTime,
                            book: await mapSearchSimpleBook(value.book),
                            previewImages: value.previewImageURLs.map(DesktopWebSearchPreviewImage.init)
                        )
                    )
                )
            case .relevant(let value):
                let contentBook: DesktopWebSearchSimpleBook?
                if let rawContentBook = value.contentBook {
                    contentBook = await mapSearchSimpleBook(rawContentBook)
                } else {
                    contentBook = nil
                }
                items.append(
                    .relevant(
                        DesktopWebSearchRelevant(
                            id: value.id,
                            title: value.title,
                            content: value.content,
                            url: value.url,
                            createdTime: value.createdTime,
                            book: await mapSearchSimpleBook(value.book),
                            categoryTitle: value.categoryTitle,
                            displayKind: value.displayKind,
                            previewImages: value.previewImageURLs.map(DesktopWebSearchPreviewImage.init),
                            contentBook: contentBook
                        )
                    )
                )
            }
        }
        return DesktopWebSearchPage(
            items: items,
            pagination: DesktopWebPagination(
                page: snapshot.page,
                pageSize: snapshot.pageSize,
                total: Int64(snapshot.total),
                totalPages: snapshot.totalPages
            )
        )
    }

    /// 映射搜索轻量书籍，并仅对存在的封面值应用现有代理签名规则。
    func mapSearchSimpleBook(
        _ snapshot: DesktopWebSearchSimpleBookSnapshot
    ) async -> DesktopWebSearchSimpleBook {
        DesktopWebSearchSimpleBook(
            id: snapshot.id,
            name: snapshot.name,
            cover: await resolvedCover(bookID: snapshot.id, rawCover: snapshot.cover),
            author: snapshot.author,
            press: snapshot.press,
            translator: snapshot.translator,
            pubDate: snapshot.pubDate,
            isDeleted: snapshot.isDeleted
        )
    }

    /// 映射书内书摘投影，不改变 Repository 确定的标签和图片顺序。
    static func mapBookNote(_ snapshot: DesktopWebBookNoteSnapshot) -> DesktopWebBookNote {
        DesktopWebBookNote(
            id: snapshot.id,
            content: snapshot.content,
            idea: snapshot.idea,
            position: snapshot.position,
            positionUnit: snapshot.positionUnit,
            isIncludeTime: snapshot.isIncludeTime,
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime,
            chapter: snapshot.chapter.map(mapChapter),
            tags: snapshot.tags.map { DesktopWebNoteTag(id: $0.id, name: $0.name) },
            images: snapshot.images.map { DesktopWebNoteImage(id: $0.id, url: $0.url) }
        )
    }

    /// 映射全局书摘，并对关联书籍封面应用访问码签名和本机代理规则。
    func mapGlobalNote(_ snapshot: DesktopWebGlobalNoteSnapshot) async -> DesktopWebGlobalNote {
        let note = Self.mapBookNote(snapshot.note)
        return DesktopWebGlobalNote(
            id: note.id,
            content: note.content,
            idea: note.idea,
            position: note.position,
            positionUnit: note.positionUnit,
            createdTime: note.createdTime,
            updatedTime: note.updatedTime,
            isIncludeTime: note.isIncludeTime,
            chapter: note.chapter,
            tags: note.tags,
            images: note.images,
            book: DesktopWebNoteBook(
                id: snapshot.book.id,
                name: snapshot.book.name,
                cover: await resolvedCover(bookID: snapshot.book.id, rawCover: snapshot.book.cover),
                author: snapshot.book.author,
                press: snapshot.book.press
            )
        )
    }

    /// 映射默认或自定义标签筛选项。
    static func mapNoteTagFilter(_ snapshot: DesktopWebNoteTagFilterSnapshot) -> DesktopWebNoteTagFilter {
        DesktopWebNoteTagFilter(
            id: snapshot.id,
            name: snapshot.name,
            noteCount: snapshot.noteCount,
            section: snapshot.section
        )
    }

    /// 映射书摘排序规则。
    static func mapNoteSortRule(_ snapshot: DesktopWebNoteSortRuleSnapshot) -> DesktopWebNoteSortRule {
        DesktopWebNoteSortRule(sortBy: snapshot.sortBy, sortOrder: snapshot.sortOrder)
    }

    /// 映射创建、更新或合并后的 Android WebNoteResultDto。
    static func mapNoteResult(_ snapshot: DesktopWebNoteResultSnapshot) -> DesktopWebNoteResult {
        DesktopWebNoteResult(
            id: snapshot.id,
            bookId: snapshot.bookID,
            chapterId: snapshot.chapterID,
            content: snapshot.content,
            idea: snapshot.idea,
            position: snapshot.position,
            positionUnit: snapshot.positionUnit,
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime,
            tags: snapshot.tags.map { DesktopWebNoteTag(id: $0.id, name: $0.name) },
            images: snapshot.images.map { DesktopWebNoteImage(id: $0.id, url: $0.url) }
        )
    }

    /// 映射相关类别投影。
    static func mapRelatedCategory(
        _ snapshot: DesktopWebRelatedCategorySnapshot
    ) -> DesktopWebRelatedCategory {
        DesktopWebRelatedCategory(
            id: snapshot.id,
            bookId: snapshot.bookID,
            scope: snapshot.scope,
            title: snapshot.title,
            order: snapshot.order,
            isHide: snapshot.isHidden,
            contentCount: snapshot.contentCount,
            isSystemDefault: snapshot.isSystemDefault,
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime
        )
    }

    /// 映射相关内容书籍投影，并对远程封面应用本机代理规则。
    func mapRelatedBook(_ snapshot: DesktopWebRelatedBookSnapshot) async -> DesktopWebRelatedBook {
        DesktopWebRelatedBook(
            id: snapshot.id,
            name: snapshot.name,
            cover: await resolvedCover(bookID: snapshot.id, rawCover: snapshot.cover),
            author: snapshot.author,
            press: snapshot.press,
            translator: snapshot.translator,
            pubDate: snapshot.publicationDate,
            isDeleted: snapshot.isDeleted
        )
    }

    /// 映射书内相关内容，保持类别回退、图片顺序与可选内容书字段。
    func mapRelatedNote(_ snapshot: DesktopWebRelatedNoteSnapshot) async -> DesktopWebRelatedNote {
        let contentBook: DesktopWebRelatedBook? = if let book = snapshot.contentBook {
            await mapRelatedBook(book)
        } else {
            nil
        }
        return DesktopWebRelatedNote(
            id: snapshot.id,
            bookId: snapshot.bookID,
            categoryId: snapshot.categoryID,
            categoryTitle: snapshot.categoryTitle,
            title: snapshot.title,
            content: snapshot.content,
            url: snapshot.url,
            contentBookId: snapshot.contentBookID,
            contentBook: contentBook,
            images: snapshot.images.map {
                DesktopWebRelatedImage(id: $0.id, url: $0.url, order: $0.order)
            },
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime
        )
    }

    /// 映射书内相关内容分页结果。
    func mapRelatedPage(
        _ snapshot: DesktopWebRelatedPageSnapshot<DesktopWebRelatedNoteSnapshot>
    ) async -> DesktopWebPageResult<DesktopWebRelatedNote> {
        var items: [DesktopWebRelatedNote] = []
        items.reserveCapacity(snapshot.items.count)
        for item in snapshot.items {
            items.append(await mapRelatedNote(item))
        }
        return DesktopWebPageResult(
            items: items,
            pagination: DesktopWebPagination(
                page: snapshot.page,
                pageSize: snapshot.pageSize,
                total: Int64(snapshot.total),
                totalPages: snapshot.totalPages
            )
        )
    }

    /// 映射全局相关内容，额外补齐来源书籍。
    func mapGlobalRelatedNote(
        _ snapshot: DesktopWebGlobalRelatedNoteSnapshot
    ) async -> DesktopWebGlobalRelatedNote {
        let note = await mapRelatedNote(snapshot.note)
        return DesktopWebGlobalRelatedNote(
            id: note.id,
            bookId: note.bookId,
            categoryId: note.categoryId,
            categoryTitle: note.categoryTitle,
            title: note.title,
            content: note.content,
            url: note.url,
            contentBookId: note.contentBookId,
            contentBook: note.contentBook,
            images: note.images,
            createdTime: note.createdTime,
            updatedTime: note.updatedTime,
            book: await mapRelatedBook(snapshot.book)
        )
    }

    /// 映射 Package 书内筛选到 Repository 输入。
    static func mapRelatedFilter(
        _ filter: DesktopWebRelatedNoteFilter
    ) -> DesktopWebRelatedNoteFilterInput {
        DesktopWebRelatedNoteFilterInput(
            categoryID: filter.categoryID,
            keyword: filter.keyword,
            sortBy: filter.sortBy,
            sortOrder: filter.sortOrder
        )
    }

    /// 映射全局书评，并对关联书籍封面应用访问码签名和本机代理规则。
    func mapGlobalReview(_ snapshot: DesktopWebGlobalReviewSnapshot) async -> DesktopWebGlobalReview {
        DesktopWebGlobalReview(
            id: snapshot.id,
            title: snapshot.title,
            content: snapshot.content,
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime,
            images: snapshot.images.map { DesktopWebReviewImage(id: $0.id, url: $0.url) },
            book: DesktopWebReviewBook(
                id: snapshot.book.id,
                name: snapshot.book.name,
                cover: await resolvedCover(bookID: snapshot.book.id, rawCover: snapshot.book.cover),
                author: snapshot.book.author,
                press: snapshot.book.press
            )
        )
    }

    /// 映射书内、详情和写入书评 DTO，不改变图片顺序与临时 ID。
    static func mapBookReview(_ snapshot: DesktopWebBookReviewSnapshot) -> DesktopWebBookReview {
        DesktopWebBookReview(
            id: snapshot.id,
            title: snapshot.title,
            content: snapshot.content,
            wordCount: snapshot.wordCount,
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime,
            images: snapshot.images.map { DesktopWebReviewImage(id: $0.id, url: $0.url) }
        )
    }

    /// 映射书评草稿设置投影。
    static func mapReviewDraft(_ snapshot: DesktopWebReviewDraftSnapshot) -> DesktopWebReviewDraft {
        DesktopWebReviewDraft(
            bookId: snapshot.bookID,
            reviewId: snapshot.reviewID,
            title: snapshot.title,
            content: snapshot.content,
            imageUrls: snapshot.imageURLs,
            createdTime: snapshot.createdTime,
            savedTimeMillis: snapshot.savedTimeMillis
        )
    }

    /// 映射书评排序规则。
    static func mapReviewSortRule(_ snapshot: DesktopWebReviewSortRuleSnapshot) -> DesktopWebReviewSortRule {
        DesktopWebReviewSortRule(sortBy: snapshot.sortBy, sortOrder: snapshot.sortOrder)
    }

    /// 映射阅读记录的完整时间、进度与审计字段。
    static func mapReadingRecord(_ snapshot: DesktopWebReadingRecordSnapshot) -> DesktopWebReadingRecord {
        DesktopWebReadingRecord(
            id: snapshot.id,
            bookId: snapshot.bookID,
            mode: snapshot.mode,
            startTime: snapshot.startTime,
            endTime: snapshot.endTime,
            fuzzyReadDate: snapshot.fuzzyReadDate,
            elapsedSeconds: snapshot.elapsedSeconds,
            countdownSeconds: snapshot.countdownSeconds,
            pausedDurationMillis: snapshot.pausedDurationMillis,
            position: snapshot.position,
            recordedPositionUnit: snapshot.recordedPositionUnit,
            insight: snapshot.insight,
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime
        )
    }

    /// 把 Package upsert DTO 转为 Data 层无框架输入。
    static func mapReadingRecordInput(
        _ request: DesktopWebReadingRecordUpsertRequest
    ) -> DesktopWebReadingRecordInput {
        DesktopWebReadingRecordInput(
            mode: request.mode,
            startTime: request.startTime,
            endTime: request.endTime,
            fuzzyReadDate: request.fuzzyReadDate,
            elapsedSeconds: request.elapsedSeconds,
            position: request.position,
            recordedPositionUnit: request.recordedPositionUnit,
            insight: request.insight
        )
    }

    /// 把 iOS 当前阅读日历设置映射为 Android 六类事件过滤；iOS 的“笔记记录”同时覆盖书摘、相关与书评。
    func calendarConfiguration() -> DesktopWebCalendarConfiguration {
        let excludesNotes = defaults.bool(forKey: "rcExcludeNoteRecord")
        return DesktopWebCalendarConfiguration(
            excludeNote: excludesNotes,
            excludeRelevant: excludesNotes,
            excludeReview: excludesNotes,
            excludeReadTime: defaults.bool(forKey: "rcExcludeReadTiming"),
            excludeReadDone: false,
            excludeCheckIn: defaults.bool(forKey: "rcExcludeCheckIn"),
            dayEventCount: defaults.object(forKey: "rcDayEventCount") as? Int ?? 6
        )
    }

    /// 映射日历书籍并应用与书架完全一致的封面代理和签名规则。
    func mapCalendarBook(
        _ snapshot: DesktopWebCalendarBookSnapshot
    ) async -> DesktopWebCalendarBook {
        DesktopWebCalendarBook(
            id: snapshot.id,
            name: snapshot.name,
            cover: await resolvedCover(bookID: snapshot.id, rawCover: snapshot.cover),
            author: snapshot.author,
            isContinuation: snapshot.isContinuation
        )
    }

    /// 递归映射章节树 DTO，不改变 Repository 已确定的子节点顺序。
    static func mapChapterFull(_ snapshot: DesktopWebChapterFullSnapshot) -> DesktopWebChapterFull {
        DesktopWebChapterFull(
            id: snapshot.id,
            title: snapshot.title,
            order: snapshot.order,
            noteCount: snapshot.noteCount,
            children: snapshot.children.map(mapChapterFull),
            parentId: snapshot.parentID,
            level: snapshot.level,
            pathTitles: snapshot.pathTitles,
            directNoteCount: snapshot.directNoteCount,
            descendantNoteCount: snapshot.descendantNoteCount,
            isStarred: snapshot.isStarred
        )
    }

    /// 映射最近章节或星标状态更新结果。
    static func mapChapter(_ snapshot: DesktopWebChapterSnapshot) -> DesktopWebChapter {
        DesktopWebChapter(
            id: snapshot.id,
            title: snapshot.title,
            parentTitle: snapshot.parentTitle,
            parentId: snapshot.parentID,
            level: snapshot.level,
            pathTitles: snapshot.pathTitles,
            isStarred: snapshot.isStarred
        )
    }

    /// 映射星标章节分组中的单个章节。
    static func mapStarredChapter(
        _ snapshot: DesktopWebStarredChapterSnapshot
    ) -> DesktopWebStarredChapter {
        DesktopWebStarredChapter(
            id: snapshot.id,
            title: snapshot.title,
            parentTitle: snapshot.parentTitle,
            parentId: snapshot.parentID,
            level: snapshot.level,
            pathTitles: snapshot.pathTitles,
            order: snapshot.order,
            noteCount: snapshot.noteCount,
            directNoteCount: snapshot.directNoteCount,
            descendantNoteCount: snapshot.descendantNoteCount,
            updatedTime: snapshot.updatedTime,
            ancestorIds: snapshot.ancestorIDs,
            isStarred: snapshot.isStarred
        )
    }

    /// 映射章节创建或标题更新结果。
    static func mapChapterResult(
        _ snapshot: DesktopWebChapterResultSnapshot
    ) -> DesktopWebChapterResult {
        DesktopWebChapterResult(
            id: snapshot.id,
            title: snapshot.title,
            parentId: snapshot.parentID,
            order: snapshot.order
        )
    }

    /// 映射文渠候选结果，不在 Adapter 二次修改排序或目录可用性。
    static func mapOnlineChapterCandidate(
        _ snapshot: DesktopWebOnlineChapterCandidateSnapshot
    ) -> DesktopWebOnlineChapterCandidate {
        DesktopWebOnlineChapterCandidate(
            title: snapshot.title,
            author: snapshot.author,
            publisher: snapshot.publisher,
            pubDate: snapshot.pubDate,
            cover: snapshot.cover,
            doubanId: snapshot.doubanID,
            hasCatalog: snapshot.hasCatalog
        )
    }

    /// 递归映射目录导入预览节点，保持预览键与选择默认值不变。
    static func mapChapterImportNode(
        _ snapshot: DesktopWebChapterImportNodeSnapshot
    ) -> DesktopWebChapterImportNode {
        DesktopWebChapterImportNode(
            key: snapshot.key,
            title: snapshot.title,
            depth: snapshot.depth,
            duplicate: snapshot.duplicate,
            selected: snapshot.selected,
            children: snapshot.children.map(mapChapterImportNode)
        )
    }

    /// 将 App 来源快照转换为 Package DTO，不让 Record 或 GRDB 类型越过模块边界。
    static func mapSource(_ snapshot: DesktopWebSourceSnapshot) -> DesktopWebSource {
        DesktopWebSource(
            id: snapshot.id,
            name: snapshot.name,
            order: snapshot.order,
            isHidden: snapshot.isHidden,
            isDefault: snapshot.isDefault,
            bookCount: snapshot.bookCount,
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime
        )
    }

    /// 将 App 标签列表快照转换为 Package DTO。
    static func mapTag(_ snapshot: DesktopWebTagSnapshot) -> DesktopWebTag {
        DesktopWebTag(
            id: snapshot.id,
            name: snapshot.name,
            type: snapshot.type,
            order: snapshot.order,
            noteCount: snapshot.noteCount,
            bookCount: snapshot.bookCount,
            createdTime: snapshot.createdTime
        )
    }

    /// 将 App 标签写入结果转换为 Package DTO。
    static func mapTagMutation(_ snapshot: DesktopWebTagMutationSnapshot) -> DesktopWebTagResult {
        DesktopWebTagResult(
            id: snapshot.id,
            name: snapshot.name,
            type: snapshot.type,
            order: snapshot.order
        )
    }

    /// 将 App 分组分页快照转换为 Package PageResult。
    static func mapGroupPage(
        _ snapshot: DesktopWebPagedSnapshot<DesktopWebGroupSnapshot>
    ) -> DesktopWebPageResult<DesktopWebGroup> {
        DesktopWebPageResult(
            items: snapshot.items.map(mapGroup),
            pagination: DesktopWebPagination(
                page: snapshot.page,
                pageSize: snapshot.pageSize,
                total: snapshot.total,
                totalPages: snapshot.totalPages
            )
        )
    }

    /// 将 App 分组快照转换为 Package DTO。
    static func mapGroup(_ snapshot: DesktopWebGroupSnapshot) -> DesktopWebGroup {
        DesktopWebGroup(
            id: snapshot.id,
            name: snapshot.name,
            isPinned: snapshot.isPinned,
            pinOrder: snapshot.pinOrder,
            order: snapshot.order,
            bookCount: snapshot.bookCount,
            createdTime: snapshot.createdTime
        )
    }

    /// 将 Package 的平台无关筛选转为 App Repository 快照。
    static func mapBookFilter(_ filter: DesktopWebBookFilter) -> DesktopWebBookFilterSnapshot {
        DesktopWebBookFilterSnapshot(
            keyword: filter.keyword,
            status: filter.status,
            groupID: filter.groupID,
            tagIDs: filter.tagIDs,
            tagMode: filter.tagMode,
            sourceIDs: filter.sourceIDs
        )
    }

    static func mapBookshelfItemRef(
        _ item: DesktopWebBookshelfItemRef
    ) -> DesktopWebBookshelfItemRefInput {
        DesktopWebBookshelfItemRefInput(type: item.type, id: item.id)
    }

    /// 映射 App 混排分页并保留 pagination 的 Android Long/Int 字段宽度。
    func mapBookshelfPage(
        _ snapshot: DesktopWebPagedSnapshot<DesktopWebBookshelfItemSnapshot>
    ) async -> DesktopWebPageResult<DesktopWebBookshelfItem> {
        DesktopWebPageResult(
            items: await mapBookshelfItems(snapshot.items),
            pagination: DesktopWebPagination(
                page: snapshot.page,
                pageSize: snapshot.pageSize,
                total: snapshot.total,
                totalPages: snapshot.totalPages
            )
        )
    }

    /// 逐项异步解析书籍与分组预览封面，未知类型在 Repository 阶段已被丢弃。
    func mapBookshelfItems(
        _ snapshots: [DesktopWebBookshelfItemSnapshot]
    ) async -> [DesktopWebBookshelfItem] {
        var items: [DesktopWebBookshelfItem] = []
        items.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            if let book = snapshot.book {
                items.append(
                    DesktopWebBookshelfItem(type: "book", book: await mapBook(book))
                )
            } else if let group = snapshot.group {
                items.append(
                    DesktopWebBookshelfItem(type: "group", group: await mapBookshelfGroup(group))
                )
            }
        }
        return items
    }

    /// 将 App 书籍分页快照异步映射为 Package DTO，逐项应用封面代理规则。
    func mapBookPage(
        _ snapshot: DesktopWebPagedSnapshot<DesktopWebBookSnapshot>
    ) async -> DesktopWebPageResult<DesktopWebBook> {
        var items: [DesktopWebBook] = []
        items.reserveCapacity(snapshot.items.count)
        for item in snapshot.items {
            items.append(await mapBook(item))
        }
        return DesktopWebPageResult(
            items: items,
            pagination: DesktopWebPagination(
                page: snapshot.page,
                pageSize: snapshot.pageSize,
                total: snapshot.total,
                totalPages: snapshot.totalPages
            )
        )
    }

    /// 将 App 完整书籍快照转换为 Package DTO，并解析封面代理地址。
    func mapBook(
        _ snapshot: DesktopWebBookSnapshot,
        searchSource: String = "bookshelf",
        isInBookshelf: Bool = true,
        fromRelatedContentBook: Bool = false
    ) async -> DesktopWebBook {
        DesktopWebBook(
            id: snapshot.id,
            name: snapshot.name,
            rawName: snapshot.rawName,
            cover: await resolvedCover(bookID: snapshot.id, rawCover: snapshot.cover),
            author: snapshot.author,
            authorIntro: snapshot.authorIntro,
            translator: snapshot.translator,
            summary: snapshot.summary,
            isbn: snapshot.isbn,
            press: snapshot.press,
            pubDate: snapshot.pubDate,
            doubanId: snapshot.doubanId,
            readStatus: snapshot.readStatus,
            readStatusChangedTime: snapshot.readStatusChangedTime,
            recentReadTime: snapshot.recentReadTime,
            readDoneCount: snapshot.readDoneCount,
            score: snapshot.score,
            readPosition: snapshot.readPosition,
            totalPosition: snapshot.totalPosition,
            totalPagination: snapshot.totalPagination,
            currentPositionUnit: snapshot.currentPositionUnit,
            positionUnit: snapshot.positionUnit,
            type: snapshot.type,
            sourceId: snapshot.sourceId,
            sourceName: snapshot.sourceName,
            purchaseDate: snapshot.purchaseDate,
            price: snapshot.price,
            isPinned: snapshot.isPinned,
            pinOrder: snapshot.pinOrder,
            order: snapshot.order,
            wordCount: snapshot.wordCount,
            totalReadingTime: snapshot.totalReadingTime,
            createdTime: snapshot.createdTime,
            updatedTime: snapshot.updatedTime,
            lastModifiedTime: snapshot.lastModifiedTime,
            noteCount: snapshot.noteCount,
            reviewCount: snapshot.reviewCount,
            relevantCount: snapshot.relevantCount,
            readDoneTime: snapshot.readDoneTime,
            bookmarkModifiedTime: snapshot.bookmarkModifiedTime,
            groups: snapshot.groups.map { DesktopWebBookGroup(id: $0.id, name: $0.name) },
            tags: snapshot.tags.map { DesktopWebBookTag(id: $0.id, name: $0.name) },
            isDeleted: snapshot.isDeleted,
            searchSource: searchSource,
            isInBookshelf: isInBookshelf,
            fromRelatedContentBook: fromRelatedContentBook
        )
    }

    /// 转换置顶分组卡，保证 covers 与 previewBooks.cover 完全同源。
    func mapBookshelfGroup(
        _ snapshot: DesktopWebBookshelfGroupSnapshot
    ) async -> DesktopWebBookshelfGroup {
        var previews: [DesktopWebGroupPreviewBook] = []
        previews.reserveCapacity(snapshot.previewBooks.count)
        for preview in snapshot.previewBooks {
            previews.append(
                DesktopWebGroupPreviewBook(
                    bookId: preview.bookID,
                    cover: await resolvedCover(bookID: preview.bookID, rawCover: preview.cover)
                )
            )
        }
        return DesktopWebBookshelfGroup(
            id: snapshot.id,
            name: snapshot.name,
            isPinned: snapshot.isPinned,
            pinOrder: snapshot.pinOrder,
            order: snapshot.order,
            bookCount: snapshot.bookCount,
            createdTime: snapshot.createdTime,
            covers: previews.map(\.cover),
            previewBooks: previews
        )
    }

    /// 复刻 BookCoverUrlResolver：外部远程封面走本机代理，开启访问码时附一小时 HMAC 签名。
    func resolvedCover(bookID: Int64, rawCover: String) async -> String {
        let cover = rawCover.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyPath = "/api/v1/book-covers/proxy/\(bookID)"
        guard !cover.isEmpty,
              !cover.hasPrefix("/api/v1/book-covers/proxy/"),
              cover.lowercased().hasPrefix("http://") || cover.lowercased().hasPrefix("https://"),
              !cover.localizedCaseInsensitiveContains("clippingkk"),
              !cover.localizedCaseInsensitiveContains("xmnote-") else {
            return cover
        }
        let auth = await repository.accessAuthSnapshot()
        guard auth.isEnabled else { return proxyPath }
        let expires = currentTimeMillis() + 60 * 60 * 1_000
        let payload = "\(bookID)|\(cover)|\(expires)"
        let key = SymmetricKey(data: Data(auth.accessCode.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        return "\(proxyPath)?expires=\(expires)&sig=\(signature)"
    }

    /// 将 Repository 分类错误映射为 Android Web 的 40001/40002/40003，其余错误保留给 50001 中间件。
    static func mapCatalogError(_ error: Error) -> Error {
        switch error {
        case DesktopWebCatalogRepositoryError.invalidArgument(let message):
            return DesktopWebAPIError(code: 40001, message: message)
        case DesktopWebCatalogRepositoryError.notFound(let message):
            return DesktopWebAPIError(code: 40002, message: message)
        case DesktopWebCatalogRepositoryError.duplicate(let message):
            return DesktopWebAPIError(code: 40003, message: message)
        case DesktopWebCatalogRepositoryError.invalidDatabaseValue(let message):
            return DesktopWebAPIError(code: 50001, message: message)
        default:
            return error
        }
    }

    /// RelatedController 的详情与删除把同一 IllegalArgumentException 映射为资源不存在 40002。
    static func mapRelatedResourceError(_ error: Error) -> Error {
        if case DesktopWebCatalogRepositoryError.invalidArgument(let message) = error {
            return DesktopWebAPIError(code: 40002, message: message)
        }
        return mapCatalogError(error)
    }
}
