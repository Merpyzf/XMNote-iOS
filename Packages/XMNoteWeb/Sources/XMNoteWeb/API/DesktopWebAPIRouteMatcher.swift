/**
 * [INPUT]: 依赖 Hummingbird 的 HTTP 请求方法与 URI，以及各业务路由集合声明的路径模板
 * [OUTPUT]: 识别当前真正已注册的 Web API，避免未迁移路径被授权或错误中间件伪装成业务接口
 * [POS]: XMNoteWeb 的内部路由清单边界；随已实现 RouteCollection 增长，不对 App 暴露
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebAPIRouteDefinition: Hashable, Sendable {
    let method: HTTPRequest.Method
    let pathPattern: String

    init(_ method: HTTPRequest.Method, _ pathPattern: String) {
        self.method = method
        self.pathPattern = Self.normalize(pathPattern)
    }

    /// 比较请求方法与路径段；Android 清单中的 `{id}` 段只匹配单个非空路径参数。
    func matches(method requestMethod: HTTPRequest.Method, path requestPath: String) -> Bool {
        guard method == requestMethod else { return false }
        let patternSegments = Self.normalize(pathPattern).split(separator: "/", omittingEmptySubsequences: true)
        let requestSegments = Self.normalize(requestPath).split(separator: "/", omittingEmptySubsequences: true)
        guard patternSegments.count == requestSegments.count else { return false }

        return zip(patternSegments, requestSegments).allSatisfy { pattern, request in
            let isParameter = pattern.first == "{" && pattern.last == "}"
            return isParameter ? !request.isEmpty : pattern == request
        }
    }

    private static func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}

struct DesktopWebAPIRouteMatcher: Sendable {
    let routes: Set<DesktopWebAPIRouteDefinition>

    init(routes: some Sequence<DesktopWebAPIRouteDefinition>) {
        self.routes = Set(routes)
    }

    /// OPTIONS 使用浏览器声明的目标方法匹配，其余请求直接使用当前 HTTP 方法。
    func contains(_ request: Request) -> Bool {
        if request.method == .options {
            if let requested = Self.trimmed(request.headers[.accessControlRequestMethod]),
               let requestedMethod = HTTPRequest.Method(requested.uppercased()) {
                return routes.contains {
                    $0.matches(method: requestedMethod, path: request.uri.path)
                }
            }

            return routes.contains { $0.matchesPath(request.uri.path) }
        }
        return routes.contains { $0.matches(method: request.method, path: request.uri.path) }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension DesktopWebAPIRouteDefinition {
    /// 缺少 Access-Control-Request-Method 时只比较已注册路径，维持 Android 默认预检响应。
    func matchesPath(_ requestPath: String) -> Bool {
        Self.allMethods.contains { matches(method: $0, path: requestPath) }
    }

    static let allMethods: [HTTPRequest.Method] = [
        .get,
        .head,
        .post,
        .put,
        .patch,
        .delete,
        .options,
        .trace
    ]
}
