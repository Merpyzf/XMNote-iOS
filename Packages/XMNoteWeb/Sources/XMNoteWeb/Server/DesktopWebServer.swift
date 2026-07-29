/**
 * [INPUT]: 依赖 Hummingbird listener、Bundle.module 冻结网页资源、内部路由/中间件和可选 API 端口
 * [OUTPUT]: 对 App 仅公开可等待监听就绪、查询在途请求和有限优雅停机的 DesktopWebServer
 * [POS]: XMNoteWeb 的唯一公开运行时入口；隐藏全部 Hummingbird 与静态资源实现细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

/// 区分冻结网页资源错误与监听错误，让 App 可以展示可执行提示。
enum DesktopWebServerError: LocalizedError, Sendable {
    case staticDirectoryMissing
    case indexFileMissing
    case listenerFailed(port: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .staticDirectoryMissing:
            return "网页资源目录缺失，请重新安装应用"
        case .indexFileMissing:
            return "网页首页资源缺失，请重新安装应用"
        case .listenerFailed(let port, let message):
            return DesktopWebServer.readableServerError(message, port: port)
        }
    }
}

/// 持有单个进程内 HTTP listener，并以 actor 串行保护启停状态。
public actor DesktopWebServer {
    private struct RunningServer {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var runningServer: RunningServer?
    private let requestActivity = DesktopWebRequestActivity()
    private let apiDependencies: DesktopWebAPIDependencies?

    /// 创建尚未监听端口的 Web 运行时；状态由 actor 隔离，不继承 App 的 MainActor。
    public init(apiDependencies: DesktopWebAPIDependencies? = nil) {
        self.apiDependencies = apiDependencies
    }

    /// 校验 Package 静态资源并启动 listener；只有 socket 真正 bind 成功才返回。
    public func start(
        port: Int = 8090,
        onFailure: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard runningServer == nil else { return }
        guard let staticRoot = Bundle.module.url(
            forResource: "DesktopWebSite",
            withExtension: nil
        ), Self.isDirectory(staticRoot) else {
            throw DesktopWebServerError.staticDirectoryMissing
        }
        guard FileManager.default.fileExists(
            atPath: staticRoot.appending(path: "index.html").path
        ) else {
            throw DesktopWebServerError.indexFileMissing
        }

        let readiness = DesktopWebServerReadiness(port: port)
        let router = Router()
        router.middlewares.add(DesktopWebRequestActivityMiddleware(activity: requestActivity))
        router.middlewares.add(DesktopWebCachePolicyMiddleware())
        if let apiDependencies {
            var routeDefinitions: Set<DesktopWebAPIRouteDefinition> = []
            if apiDependencies.settings != nil {
                routeDefinitions.formUnion(DesktopWebSettingsRoutes.definitions)
            }
            if apiDependencies.source != nil {
                routeDefinitions.formUnion(DesktopWebSourceRoutes.definitions)
            }
            if apiDependencies.tag != nil {
                routeDefinitions.formUnion(DesktopWebTagRoutes.definitions)
            }
            if apiDependencies.group != nil {
                routeDefinitions.formUnion(DesktopWebGroupRoutes.definitions)
            }
            if apiDependencies.book != nil {
                routeDefinitions.formUnion(DesktopWebBookRoutes.definitions)
            }
            if apiDependencies.bookshelf != nil {
                routeDefinitions.formUnion(DesktopWebBookshelfRoutes.definitions)
            }
            if apiDependencies.calendar != nil {
                routeDefinitions.formUnion(DesktopWebCalendarRoutes.definitions)
            }
            if apiDependencies.chapter != nil {
                routeDefinitions.formUnion(DesktopWebChapterRoutes.definitions)
            }
            if apiDependencies.note != nil {
                routeDefinitions.formUnion(DesktopWebNoteRoutes.definitions)
            }
            if apiDependencies.related != nil {
                routeDefinitions.formUnion(DesktopWebRelatedRoutes.definitions)
            }
            if apiDependencies.review != nil {
                routeDefinitions.formUnion(DesktopWebReviewRoutes.definitions)
            }
            if apiDependencies.readingRecord != nil {
                routeDefinitions.formUnion(DesktopWebReadingRecordRoutes.definitions)
            }
            if apiDependencies.search != nil {
                routeDefinitions.formUnion(DesktopWebSearchRoutes.definitions)
            }
            if apiDependencies.statistics != nil {
                routeDefinitions.formUnion(DesktopWebStatisticsRoutes.definitions)
            }
            if apiDependencies.ai != nil {
                routeDefinitions.formUnion(DesktopWebAIRoutes.definitions)
            }
            if apiDependencies.onlineBook != nil || apiDependencies.bookCover != nil {
                routeDefinitions.formUnion(DesktopWebExternalBookRoutes.definitions)
            }
            if apiDependencies.export != nil {
                routeDefinitions.formUnion(DesktopWebExportRoutes.definitions)
            }
            if apiDependencies.importTask != nil {
                routeDefinitions.formUnion(DesktopWebImportRoutes.definitions)
            }
            if apiDependencies.upload != nil {
                routeDefinitions.formUnion(DesktopWebUploadRoutes.definitions)
            }
            DesktopWebAPIMiddleware.install(
                on: router,
                dependencies: apiDependencies,
                routeMatcher: DesktopWebAPIRouteMatcher(routes: routeDefinitions)
            )
            if let settings = apiDependencies.settings {
                DesktopWebSettingsRoutes(port: settings).register(on: router)
            }
            if let source = apiDependencies.source {
                DesktopWebSourceRoutes(port: source).register(on: router)
            }
            if let tag = apiDependencies.tag {
                DesktopWebTagRoutes(port: tag).register(on: router)
            }
            if let group = apiDependencies.group {
                DesktopWebGroupRoutes(port: group).register(on: router)
            }
            if let book = apiDependencies.book {
                DesktopWebBookRoutes(port: book).register(on: router)
            }
            if let bookshelf = apiDependencies.bookshelf {
                DesktopWebBookshelfRoutes(port: bookshelf).register(on: router)
            }
            if let calendar = apiDependencies.calendar {
                DesktopWebCalendarRoutes(port: calendar).register(on: router)
            }
            if let chapter = apiDependencies.chapter {
                DesktopWebChapterRoutes(port: chapter).register(on: router)
            }
            if let note = apiDependencies.note {
                DesktopWebNoteRoutes(port: note).register(on: router)
            }
            if let related = apiDependencies.related {
                DesktopWebRelatedRoutes(port: related).register(on: router)
            }
            if let review = apiDependencies.review {
                DesktopWebReviewRoutes(port: review).register(on: router)
            }
            if let readingRecord = apiDependencies.readingRecord {
                DesktopWebReadingRecordRoutes(port: readingRecord).register(on: router)
            }
            if let search = apiDependencies.search {
                DesktopWebSearchRoutes(port: search).register(on: router)
            }
            if let statistics = apiDependencies.statistics {
                DesktopWebStatisticsRoutes(port: statistics).register(on: router)
            }
            if let ai = apiDependencies.ai {
                DesktopWebAIRoutes(port: ai).register(on: router)
            }
            if apiDependencies.onlineBook != nil || apiDependencies.bookCover != nil {
                DesktopWebExternalBookRoutes(
                    onlineBook: apiDependencies.onlineBook,
                    bookCover: apiDependencies.bookCover
                ).register(on: router)
            }
            if let export = apiDependencies.export {
                DesktopWebExportRoutes(port: export).register(on: router)
            }
            if let importTask = apiDependencies.importTask {
                DesktopWebImportRoutes(port: importTask).register(on: router)
            }
            if let upload = apiDependencies.upload {
                DesktopWebUploadRoutes(port: upload).register(on: router)
            }
        }
        DesktopWebHealthRoutes().register(on: router)
        router.middlewares.add(FileMiddleware(staticRoot.path, searchForIndexHtml: true))

        let configuration = ApplicationConfiguration(
            address: .hostname("0.0.0.0", port: port),
            serverName: "XMNote-Web",
            reuseAddress: false
        )
        let application = Application(router: router, configuration: configuration) { _ in
            await readiness.succeed()
        }
        let serverID = UUID()
        let serverTask = Task { [weak self] in
            do {
                try await application.run()
            } catch is CancellationError {
                await readiness.fail("服务启动已取消")
            } catch {
                let message = error.localizedDescription
                let isRuntimeFailure = await readiness.fail(message)
                if isRuntimeFailure {
                    await onFailure(Self.readableServerError(message, port: port))
                }
            }
            await self?.clearServer(id: serverID)
        }
        runningServer = RunningServer(id: serverID, task: serverTask)

        do {
            try await readiness.wait()
        } catch {
            serverTask.cancel()
            if runningServer?.id == serverID {
                runningServer = nil
            }
            throw error
        }
    }

    /// 返回是否仍有路由处理中的请求，供 App 避免在无请求时申请后台执行时间。
    public func hasInFlightRequests() async -> Bool {
        await requestActivity.hasInFlightRequests()
    }

    /// 取消 listener 并最多等待给定宽限期；调用任务取消不会绕过服务器任务的关闭请求。
    public func stop(gracePeriod: Duration = .seconds(5)) async {
        guard let server = runningServer else { return }
        server.task.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await server.task.value
            }
            group.addTask {
                try? await Task.sleep(for: gracePeriod)
            }
            await group.next()
            group.cancelAll()
        }
        if runningServer?.id == server.id {
            runningServer = nil
        }
    }

    /// 把底层 bind 错误转换为用户可行动的中文提示。
    static func readableServerError(_ rawMessage: String, port: Int) -> String {
        if rawMessage.localizedCaseInsensitiveContains("address already in use")
            || rawMessage.contains("EADDRINUSE")
            || rawMessage.contains("errno: 48") {
            return "端口 \(port) 已被占用，请关闭占用服务后重试"
        }
        if rawMessage.localizedCaseInsensitiveContains("permission")
            || rawMessage.localizedCaseInsensitiveContains("prohibited") {
            return "本地网络访问被系统阻止，请在“设置”中允许 XMNote 访问本地网络"
        }
        return "网页服务启动失败：\(rawMessage)"
    }

    /// 仅清理同一次启动对应的任务，防止旧任务结束覆盖后续会话。
    private func clearServer(id: UUID) {
        guard runningServer?.id == id else { return }
        runningServer = nil
    }

    /// 同时检查路径存在且确为目录，避免普通文件被误当作站点根目录。
    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// 串行裁决 listener ready 与启动失败，保证 continuation 只恢复一次。
private actor DesktopWebServerReadiness {
    private enum State {
        case waiting
        case ready
        case failed(String)
    }

    private let port: Int
    private var state: State = .waiting
    private var continuations: [CheckedContinuation<Void, Error>] = []

    init(port: Int) {
        self.port = port
    }

    /// 等待 bind 完成；底层 server task 负责在取消或失败时唤醒此等待。
    func wait() async throws {
        switch state {
        case .ready:
            return
        case .failed(let message):
            throw DesktopWebServerError.listenerFailed(port: port, message: message)
        case .waiting:
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }

    /// 标记 socket 已监听并恢复全部启动等待者。
    func succeed() {
        guard case .waiting = state else { return }
        state = .ready
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    /// 记录失败并返回它是否发生在监听之后，供上层区分启动错误与运行时错误。
    @discardableResult
    func fail(_ message: String) -> Bool {
        switch state {
        case .ready:
            return true
        case .failed:
            return false
        case .waiting:
            state = .failed(message)
            continuations.forEach {
                $0.resume(
                    throwing: DesktopWebServerError.listenerFailed(port: port, message: message)
                )
            }
            continuations.removeAll()
            return false
        }
    }
}
