/**
 * [INPUT]: 依赖 Hummingbird 请求链、App 注入的请求门禁端口与 Android Web 当前错误合同
 * [OUTPUT]: 提供 API CORS、稳定异常包络、访问码校验和会员写保护
 * [POS]: XMNoteWeb 的业务 API 中间件层；静态资源请求不进入这些业务规则
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

enum DesktopWebAPIMiddleware {
    /// 按 Android 拦截顺序组装 API 中间件；异步门禁均在异常包络内执行并共享同一依赖快照。
    static func install(
        on router: Router<BasicRequestContext>,
        dependencies: DesktopWebAPIDependencies,
        routeMatcher: DesktopWebAPIRouteMatcher
    ) {
        router.middlewares.add(DesktopWebAPICORSMiddleware(routeMatcher: routeMatcher))
        router.middlewares.add(DesktopWebAPIErrorMiddleware(routeMatcher: routeMatcher))
        router.middlewares.add(
            DesktopWebAccessAuthorizationMiddleware(
                requestGate: dependencies.requestGate,
                routeMatcher: routeMatcher
            )
        )
        router.middlewares.add(
            DesktopWebMembershipWriteGuardMiddleware(
                requestGate: dependencies.requestGate,
                routeMatcher: routeMatcher
            )
        )
    }
}

struct DesktopWebAPICORSMiddleware: RouterMiddleware {
    private static let defaultAllowHeaders = "X-XMNote-Access-Code, Content-Type, Accept"
    private static let defaultAllowMethods = "GET, POST, PUT, DELETE, PATCH, OPTIONS"
    private static let allMethods = "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, TRACE"
    let routeMatcher: DesktopWebAPIRouteMatcher

    /// 为 API 响应回显 Origin；预检请求按 Android AndServer 合同返回 HTTP 200 和 OK。
    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: @concurrent (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard routeMatcher.contains(request),
              let origin = Self.trimmed(request.headers[.origin]) else {
            return try await next(request, context)
        }

        if request.method == .options {
            let requestedHeaders = Self.trimmed(request.headers[.accessControlRequestHeaders])
                ?? Self.defaultAllowHeaders
            let requestedMethod = Self.trimmed(request.headers[.accessControlRequestMethod])
                ?? Self.defaultAllowMethods
            return Response(
                status: .ok,
                headers: [
                    .accessControlAllowOrigin: origin,
                    .accessControlAllowMethods: requestedMethod,
                    .accessControlAllowHeaders: requestedHeaders,
                    .accessControlAllowCredentials: "true",
                    .accessControlMaxAge: "1800",
                    .allow: Self.allMethods,
                    .vary: "Origin"
                ],
                body: .init(byteBuffer: ByteBuffer(bytes: "OK".utf8))
            )
        }

        var response = try await next(request, context)
        response.headers[.accessControlAllowOrigin] = origin
        response.headers[.accessControlAllowCredentials] = "true"
        response.headers[.vary] = "Origin"
        return response
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct DesktopWebAPIErrorMiddleware: RouterMiddleware {
    let routeMatcher: DesktopWebAPIRouteMatcher

    /// 将路由和端口抛出的错误统一转换为 Android Web 的 HTTP 200 业务错误包络。
    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: @concurrent (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard routeMatcher.contains(request) else {
            return try await next(request, context)
        }
        do {
            return try await next(request, context)
        } catch let error as DesktopWebAPIError {
            return try Self.errorResponse(code: error.code, message: error.message)
        } catch is CancellationError {
            return try Self.errorResponse(code: 50001, message: "请求已取消")
        } catch let error as HTTPError {
            let mapped = Self.mapHTTPError(error)
            return try Self.errorResponse(code: mapped.code, message: mapped.message)
        } catch is DecodingError {
            return try Self.errorResponse(code: 40001, message: "请求体 JSON 格式错误")
        } catch {
            return try Self.errorResponse(code: 50001, message: "服务器内部错误")
        }
    }

    private static func errorResponse(code: Int, message: String) throws -> Response {
        var response = try DesktopWebAPIResponse.error(code: code, message: message)
        response.headers[.contentType] = DesktopWebAPIResponse.jsonContentType
        return response
    }

    private static func mapHTTPError(_ error: HTTPError) -> (code: Int, message: String) {
        let code: Int
        switch error.status {
        case .badRequest, .methodNotAllowed, .notAcceptable, .unsupportedMediaType, .contentTooLarge:
            code = 40001
        case .unauthorized, .forbidden:
            code = 40005
        case .notFound:
            code = 40002
        default:
            code = 50001
        }

        let message: String
        if error.status == .contentTooLarge {
            message = "上传文件过大，单文件不能超过 10MB"
        } else if let body = error.body,
                  let input = androidNumericInput(from: body) {
            message = "For input string: \"\(input)\""
        } else {
            message = error.body ?? "请求处理失败"
        }
        return (code, message)
    }

    private static func androidNumericInput(from message: String) -> String? {
        let prefix = "Parameter '"
        let separator = "' can not be converted to the expected type ("
        guard message.hasPrefix(prefix),
              let separatorRange = message.range(of: separator),
              message.hasSuffix(")") else {
            return nil
        }
        let valueStart = message.index(message.startIndex, offsetBy: prefix.count)
        return String(message[valueStart..<separatorRange.lowerBound])
    }
}

struct DesktopWebAccessAuthorizationMiddleware: RouterMiddleware {
    private static let accessAuthStatusPath = "/api/v1/settings/access-auth"
    private static let bookCoverProxyPathPrefix = "/api/v1/book-covers/proxy/"
    private static let unauthorizedMessage =
        "访问未授权，请在电脑端输入正确的访问授权码，或在手机「网页端-访问安全」中关闭访问授权码后重试。"

    let requestGate: any DesktopWebRequestGatePort
    let routeMatcher: DesktopWebAPIRouteMatcher

    /// 在业务 handler 前异步校验访问码；任务取消只终止当前读取，不修改授权状态。
    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: @concurrent (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard routeMatcher.contains(request),
              request.method != .options,
              Self.requiresAuthorization(request.uri.path) else {
            return try await next(request, context)
        }

        let value = request.headers[.init("X-XMNote-Access-Code")!]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        guard await requestGate.isAccessAuthorized(value) else {
            var response = try DesktopWebAPIResponse.error(
                code: 40005,
                message: Self.unauthorizedMessage
            )
            response.headers[.contentType] = DesktopWebAPIResponse.jsonContentType
            return response
        }
        return try await next(request, context)
    }

    private static func requiresAuthorization(_ path: String) -> Bool {
        let normalizedPath = normalize(path)
        guard normalizedPath.hasPrefix("/api/v1/") else { return false }
        guard !normalizedPath.hasPrefix(bookCoverProxyPathPrefix) else { return false }
        return normalizedPath != accessAuthStatusPath
    }

    private static func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}

struct DesktopWebMembershipWriteGuardMiddleware: RouterMiddleware {
    private static let whitelistedWritePaths: Set<String> = [
        "/api/v1/settings/web",
        "/api/v1/settings/export",
        "/api/v1/statistics/yearly-goal-celebration",
        "/api/v1/ai/config",
        "/api/v1/native/actions/open-vip-upgrade",
        "/api/v1/bookshelf/items/query"
    ]
    private static let whitelistedWritePrefixes = [
        "/api/v1/settings/access-auth"
    ]
    private static let readOnlyMessage =
        "网页端当前仅支持浏览。开通高级版后，可在电脑上创建、编辑、整理书籍与笔记。"

    let requestGate: any DesktopWebRequestGatePort
    let routeMatcher: DesktopWebAPIRouteMatcher

    /// 在核心写 handler 前读取会员能力；同一请求只判断一次，取消时不执行下游写入。
    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: @concurrent (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard routeMatcher.contains(request),
              request.method != .options,
              request.method != .get else {
            return try await next(request, context)
        }
        let normalizedPath = Self.normalize(request.uri.path)
        guard Self.isCoreWritePath(normalizedPath), await requestGate.isDesktopReadOnly() else {
            return try await next(request, context)
        }
        var response = try DesktopWebAPIResponse.error(
            code: 40009,
            message: Self.readOnlyMessage
        )
        response.headers[.contentType] = DesktopWebAPIResponse.jsonContentType
        return response
    }

    private static func isCoreWritePath(_ path: String) -> Bool {
        guard path.hasPrefix("/api/v1/") else { return false }
        guard !whitelistedWritePaths.contains(path) else { return false }
        return !whitelistedWritePrefixes.contains { path.hasPrefix($0) }
    }

    private static func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
