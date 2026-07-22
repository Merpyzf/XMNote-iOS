/**
 * [INPUT]: 依赖 Hummingbird Router、FileMiddleware 与可选网页静态资源目录
 * [OUTPUT]: 对外提供 8090 网页端可复用路由集合、CORS、静态文件和流式 Body 基础
 * [POS]: Services 的未来 Android 网页端承载基础；当前不补造仓库中不存在的网页产物
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

nonisolated protocol DesktopWebRouteCollection: Sendable {
    nonisolated func register(on router: Router<BasicRequestContext>)
}

nonisolated struct DesktopWebHealthRoutes: DesktopWebRouteCollection {
    nonisolated func register(on router: Router<BasicRequestContext>) {
        router.get("/health") { _, _ in "ok" }
    }
}

nonisolated enum DesktopWebStreamingBody {
    /// 逐块消费请求体，供后续网页端大文件接口复用；这里不解析 multipart。
    static func consume(
        _ request: Request,
        handler: @escaping @Sendable (ByteBuffer) async throws -> Void
    ) async throws {
        for try await buffer in request.body { try await handler(buffer) }
    }
}

actor DesktopWebServerFoundation {
    private var task: Task<Void, Never>?

    func start(
        port: Int = 8090,
        staticRoot: URL?,
        routeCollections: [any DesktopWebRouteCollection] = [DesktopWebHealthRoutes()],
        onFailure: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        guard task == nil else { return }
        let router = Router()
        router.add(middleware: CORSMiddleware(allowOrigin: .all))
        for collection in routeCollections { collection.register(on: router) }
        if let staticRoot, FileManager.default.fileExists(atPath: staticRoot.path) {
            router.middlewares.add(FileMiddleware(staticRoot.path, searchForIndexHtml: true))
        }
        let application = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "XMNote-Web", reuseAddress: false)
        )
        task = Task { [weak self] in
            do { try await application.run() }
            catch is CancellationError {}
            catch { await onFailure(error.localizedDescription) }
            await self?.clearTask()
        }
    }

    func stop() { task?.cancel(); task = nil }
    private func clearTask() { task = nil }
}
