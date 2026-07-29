/**
 * [INPUT]: 依赖 Hummingbird Router、请求体流和 Package 内部路由注册约定
 * [OUTPUT]: 提供 /health 基础设施路由与供后续大文件接口复用的流式请求体消费能力
 * [POS]: XMNoteWeb 的内部路由层；不公开 Hummingbird 类型，也不注册业务 API
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

protocol DesktopWebRouteCollection: Sendable {
    func register(on router: Router<BasicRequestContext>)
}

struct DesktopWebHealthRoutes: DesktopWebRouteCollection {
    /// 注册只用于判断 HTTP 基础设施存活的健康检查，不暴露业务状态。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/health") { _, _ in "ok" }
    }
}

enum DesktopWebStreamingBody {
    /// 逐块消费请求体；调用任务取消时停止继续读取，当前不解析 multipart。
    static func consume(
        _ request: Request,
        handler: @escaping @Sendable (ByteBuffer) async throws -> Void
    ) async throws {
        for try await buffer in request.body {
            try Task.checkCancellation()
            try await handler(buffer)
        }
    }
}
