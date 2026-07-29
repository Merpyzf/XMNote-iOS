/**
 * [INPUT]: 依赖 Hummingbird 中间件链、请求路径、响应头和正式 APK 异常分支的内部标记
 * [OUTPUT]: 提供在途请求统计，以及静态资源、业务响应和入口文档的分层缓存策略
 * [POS]: XMNoteWeb 的内部 HTTP 中间件层，不改变业务响应语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

enum DesktopWebInternalHeaders {
    static let suppressCacheControl = HTTPFields.Key("X-XMNote-Suppress-Cache-Control")!
}

/// 记录仍在路由处理中、尚未生成响应的请求，供 App 后台切换时判断是否需要有限收尾。
actor DesktopWebRequestActivity {
    private var activeRequestCount = 0

    /// 请求进入中间件链时增加计数；每个 begin 必须由 end 成对收口。
    func begin() {
        activeRequestCount += 1
    }

    /// 请求完成或抛错时减少计数，并防止取消竞态导致计数小于零。
    func end() {
        activeRequestCount = max(0, activeRequestCount - 1)
    }

    /// 返回当前是否仍有 handler 在处理请求。
    func hasInFlightRequests() -> Bool {
        activeRequestCount > 0
    }
}

/// 在不改变响应语义的前提下，为 HTTP 会话维护请求处理计数。
struct DesktopWebRequestActivityMiddleware: RouterMiddleware {
    let activity: DesktopWebRequestActivity

    /// 覆盖完整中间件链并在成功或失败时成对减计数；取消由下游错误路径统一收口。
    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: @concurrent (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        await activity.begin()
        do {
            let response = try await next(request, context)
            await activity.end()
            return response
        } catch {
            await activity.end()
            throw error
        }
    }
}

/// 为哈希静态资源与入口文档覆写不同缓存策略，避免升级后旧 HTML 引用失效 chunk。
struct DesktopWebCachePolicyMiddleware: RouterMiddleware {
    /// 外层包裹文件中间件，在保留 ETag、Range 与 MIME 的同时按请求路径调整 Cache-Control。
    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: @concurrent (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        var response = try await next(request, context)
        if response.headers[DesktopWebInternalHeaders.suppressCacheControl] != nil {
            response.headers[DesktopWebInternalHeaders.suppressCacheControl] = nil
            response.headers[.cacheControl] = nil
            return response
        }
        if request.uri.path.hasPrefix("/api/v1/") {
            if (request.method == .get || request.method == .head),
               response.headers[.cacheControl] == nil {
                response.headers[.cacheControl] = "private"
            }
        } else if request.uri.path.hasPrefix("/_next/static/") {
            response.headers[.cacheControl] = "public, max-age=31536000, immutable"
        } else if request.uri.path == "/health" {
            response.headers[.cacheControl] = "no-store"
        } else {
            response.headers[.cacheControl] = "no-cache"
        }
        return response
    }
}
