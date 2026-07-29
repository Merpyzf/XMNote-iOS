/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容 API 包络和 App 注入的 DesktopWebSourcePort
 * [OUTPUT]: 注册来源列表、详情、新增、编辑、删除和排序共 6 条路由
 * [POS]: XMNoteWeb 来源业务路由；不访问 App 数据库，也不实现来源业务规则
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebSourceRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/sources"),
        .init(.get, "/api/v1/sources/{id}"),
        .init(.post, "/api/v1/sources"),
        .init(.put, "/api/v1/sources/{id}"),
        .init(.delete, "/api/v1/sources/{id}"),
        .init(.put, "/api/v1/sources/order")
    ]

    let port: any DesktopWebSourcePort

    /// 注册 6 条 Android SourceController 路由；所有数据语义交由能力端口实现。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/sources") { request, _ in
            let showAll = request.uri.queryParameters["showAll"]
                .map { String($0).lowercased() == "true" }
                ?? false
            return try DesktopWebAPIResponse.success(try await port.sources(showAll: showAll))
        }

        router.put("/api/v1/sources/order") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebOrderRequest.self, context: context)
            try await port.reorderSources(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.get("/api/v1/sources/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(try await port.source(id: id))
        }

        router.post("/api/v1/sources") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebSourceCreateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.createSource(body))
        }

        router.put("/api/v1/sources/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(as: DesktopWebSourceUpdateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.updateSource(id: id, request: body))
        }

        router.delete("/api/v1/sources/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            try await port.deleteSource(id: id)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }
}
