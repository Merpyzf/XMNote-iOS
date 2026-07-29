/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容 API 包络和 App 注入的 DesktopWebGroupPort
 * [OUTPUT]: 注册分组列表、组内书籍及分组写操作共 8 条路由
 * [POS]: XMNoteWeb 分组业务路由；只负责 HTTP 解码与 Android 参数归一化，不访问 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebGroupRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/groups"),
        .init(.get, "/api/v1/groups/{id}/books"),
        .init(.post, "/api/v1/groups"),
        .init(.put, "/api/v1/groups/{id}"),
        .init(.delete, "/api/v1/groups/{id}"),
        .init(.put, "/api/v1/groups/{id}/pin"),
        .init(.put, "/api/v1/groups/order"),
        .init(.put, "/api/v1/groups/{id}/books/order")
    ]

    private static let allowedBookSortFields: Set<String> = [
        "custom",
        "create_time",
        "modify_time",
        "name",
        "rating",
        "publish_date",
        "note_count",
        "read_done_time",
        "total_reading_time",
        "reading_progress"
    ]

    let port: any DesktopWebGroupPort

    /// 注册 Android GroupController 的 8 条路由，写操作继续由统一会员门禁保护。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/groups") { request, _ in
            let pagination = try Self.pagination(request)
            return try DesktopWebAPIResponse.success(
                try await port.groups(page: pagination.page, pageSize: pagination.pageSize)
            )
        }

        router.put("/api/v1/groups/order") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebOrderRequest.self, context: context)
            try await port.reorderGroups(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.get("/api/v1/groups/:id/books") { request, context in
            let id = try Self.pathInt64(try context.parameters.require("id"))
            let pagination = try Self.pagination(request)
            let sortBy = Self.bookSortField(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "sortBy",
                    default: "custom",
                    in: request
                )
            )
            let sortOrder = Self.sortOrder(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "sortOrder",
                    default: "desc",
                    in: request
                )
            )
            return try DesktopWebAPIResponse.success(
                try await port.booksInGroup(
                    id: id,
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    sortBy: sortBy,
                    sortOrder: sortOrder
                )
            )
        }

        router.put("/api/v1/groups/:id/books/order") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(as: DesktopWebOrderRequest.self, context: context)
            try await port.reorderGroupBooks(groupID: id, request: body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.put("/api/v1/groups/:id/pin") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(as: DesktopWebGroupPinRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.updateGroupPin(id: id, request: body))
        }

        router.post("/api/v1/groups") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebGroupCreateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.createGroup(body))
        }

        router.put("/api/v1/groups/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(as: DesktopWebGroupUpdateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.updateGroup(id: id, request: body))
        }

        router.delete("/api/v1/groups/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let placeAtEnd = (request.uri.queryParameters["placeAtEnd"] ?? "false")
                .lowercased() == "true"
            try await port.deleteGroup(id: id, placeAtEnd: placeAtEnd)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }

    /// 复刻 ParamValidator：页码至少 1，pageSize 允许一直到 Android Int.MAX_VALUE。
    private static func pagination(_ request: Request) throws -> (page: Int, pageSize: Int) {
        // NOTE(ANDROID-WEB-003): Android 未设置实用 pageSize 上限；一致性阶段保留 Int32.max 边界。
        // TODO(ANDROID-WEB-091): AndServer 会泄露 Java 解析文本并异常拼接重复查询参数。
        let page = try DesktopWebAndroidFormQuery.optionalInt32(
            named: "page",
            default: 1,
            in: request
        )
        let pageSize = try DesktopWebAndroidFormQuery.optionalInt32(
            named: "pageSize",
            default: 20,
            in: request
        )
        return (max(1, page), min(max(1, pageSize), Int(Int32.max)))
    }

    private static func pathInt64(_ rawValue: String) throws -> Int64 {
        let decoded = rawValue.removingPercentEncoding ?? rawValue
        guard let value = Int64(decoded) else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "For input string: \"\(decoded)\""
            )
        }
        return value
    }

    private static func bookSortField(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return allowedBookSortFields.contains(normalized) ? normalized : "custom"
    }

    private static func sortOrder(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return normalized == "asc" || normalized == "desc" ? normalized : "desc"
    }
}
