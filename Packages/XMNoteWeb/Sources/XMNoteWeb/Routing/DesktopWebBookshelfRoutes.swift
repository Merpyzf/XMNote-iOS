/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebBookshelfPort
 * [OUTPUT]: 注册书架混排、manifest、批量查询、移动与重排共 7 条路由
 * [POS]: XMNoteWeb 书架业务路由；只归一化 HTTP 参数，不访问 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

struct DesktopWebBookshelfRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/bookshelf"),
        .init(.get, "/api/v1/bookshelf/sorted"),
        .init(.get, "/api/v1/bookshelf/manifest"),
        .init(.get, "/api/v1/bookshelf/pinned-groups/meta"),
        .init(.post, "/api/v1/bookshelf/items/query"),
        .init(.post, "/api/v1/bookshelf/move"),
        .init(.put, "/api/v1/bookshelf/order")
    ]

    private static let allowedSortFields: Set<String> = [
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

    let port: any DesktopWebBookshelfPort

    /// 注册 Android BookshelfController 的 7 条路由，items/query 继续按只读 POST 放行会员门禁。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/bookshelf/manifest") { _, _ in
            try DesktopWebAPIResponse.success(try await port.bookshelfManifest())
        }

        router.get("/api/v1/bookshelf/pinned-groups/meta") { request, _ in
            let sortBy = Self.sortField(
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
            let enableSection = DesktopWebAndroidFormQuery.optionalBoolean(
                named: "enableSection",
                default: false,
                in: request
            )
            let groupSortBy = Self.sortField(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "groupSortBy",
                    default: "custom",
                    in: request
                )
            )
            let groupSortOrder = Self.sortOrder(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "groupSortOrder",
                    default: "desc",
                    in: request
                )
            )
            let groupEnableSection = DesktopWebAndroidFormQuery.optionalBoolean(
                named: "groupEnableSection",
                default: false,
                in: request
            )
            let layout = DesktopWebAndroidFormQuery.optionalString(
                named: "layout",
                default: "grid",
                in: request
            )
            .lowercased() == "list"
                ? "list"
                : "grid"
            return try DesktopWebAPIResponse.success(
                try await port.bookshelfPinnedGroupsMeta(
                    sortBy: sortBy,
                    sortOrder: sortOrder,
                    enableSection: enableSection,
                    groupSortBy: groupSortBy,
                    groupSortOrder: groupSortOrder,
                    groupEnableSection: groupEnableSection,
                    layout: layout
                )
            )
        }

        router.get("/api/v1/bookshelf/sorted") { request, _ in
            let pagination = try Self.pagination(request)
            return try DesktopWebAPIResponse.success(
                try await port.sortedBookshelf(
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    keyword: DesktopWebAndroidFormQuery.optionalString(
                        named: "keyword",
                        default: "",
                        in: request
                    ),
                    sortBy: Self.sortField(
                        DesktopWebAndroidFormQuery.optionalString(
                            named: "sortBy",
                            default: "create_time",
                            in: request
                        )
                    ),
                    sortOrder: Self.sortOrder(
                        DesktopWebAndroidFormQuery.optionalString(
                            named: "sortOrder",
                            default: "desc",
                            in: request
                        )
                    ),
                    groupSortBy: Self.sortField(
                        DesktopWebAndroidFormQuery.optionalString(
                            named: "groupSortBy",
                            default: "custom",
                            in: request
                        )
                    ),
                    groupSortOrder: Self.sortOrder(
                        DesktopWebAndroidFormQuery.optionalString(
                            named: "groupSortOrder",
                            default: "desc",
                            in: request
                        )
                    ),
                    groupEnableSection: DesktopWebAndroidFormQuery.optionalBoolean(
                        named: "groupEnableSection",
                        default: false,
                        in: request
                    )
                )
            )
        }

        router.get("/api/v1/bookshelf") { request, _ in
            let pagination = try Self.pagination(request)
            return try DesktopWebAPIResponse.success(
                try await port.bookshelf(
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    keyword: DesktopWebAndroidFormQuery.optionalString(
                        named: "keyword",
                        default: "",
                        in: request
                    ),
                    groupSortBy: Self.sortField(
                        DesktopWebAndroidFormQuery.optionalString(
                            named: "groupSortBy",
                            default: "custom",
                            in: request
                        )
                    ),
                    groupSortOrder: Self.sortOrder(
                        DesktopWebAndroidFormQuery.optionalString(
                            named: "groupSortOrder",
                            default: "desc",
                            in: request
                        )
                    ),
                    groupEnableSection: DesktopWebAndroidFormQuery.optionalBoolean(
                        named: "groupEnableSection",
                        default: false,
                        in: request
                    )
                )
            )
        }

        router.post("/api/v1/bookshelf/items/query") { request, context in
            var body = try await request.decodeStrictJSON(
                as: DesktopWebBookshelfItemsQueryRequest.self,
                context: context
            )
            body = DesktopWebBookshelfItemsQueryRequest(
                items: body.items,
                groupSortBy: Self.sortField(body.groupSortBy),
                groupSortOrder: Self.sortOrder(body.groupSortOrder),
                groupEnableSection: body.groupEnableSection
            )
            return try DesktopWebAPIResponse.success(try await port.queryBookshelfItems(body))
        }

        router.post("/api/v1/bookshelf/move") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookshelfMoveRequest.self,
                context: context
            )
            try await port.moveBookshelfItems(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.put("/api/v1/bookshelf/order") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookshelfReorderRequest.self,
                context: context
            )
            try await port.reorderBookshelf(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }

    /// 复刻 ParamValidator：默认 200，页码至少为 1，pageSize 仍允许至 Int32.max。
    private static func pagination(_ request: Request) throws -> (page: Int, pageSize: Int) {
        // NOTE(ANDROID-WEB-003): Android 未设置实用 pageSize 上限；一致性阶段保留 Int32.max 边界。
        // TODO(ANDROID-WEB-091): 复刻 AndServer 首键重复值拼接及 Java 数字解析文本。
        let page = try DesktopWebAndroidFormQuery.optionalInt32(
            named: "page",
            default: 1,
            in: request
        )
        let pageSize = try DesktopWebAndroidFormQuery.optionalInt32(
            named: "pageSize",
            default: 200,
            in: request
        )
        return (max(1, page), min(max(1, pageSize), Int(Int32.max)))
    }

    private static func sortField(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return allowedSortFields.contains(normalized) ? normalized : "custom"
    }

    private static func sortOrder(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return normalized == "asc" || normalized == "desc" ? normalized : "desc"
    }
}
