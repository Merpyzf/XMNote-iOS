/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容 API 包络和 App 注入的 DesktopWebBookPort
 * [OUTPUT]: 注册 7 条只读书籍路由及单书、批量书籍共 12 条写路由
 * [POS]: XMNoteWeb 书籍业务路由；只负责 HTTP 参数归一化，不访问 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebBookRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/books/stats"),
        .init(.get, "/api/v1/books/{id}"),
        .init(.get, "/api/v1/books"),
        .init(.get, "/api/v1/books/recent-read"),
        .init(.get, "/api/v1/books/last-note-book"),
        .init(.get, "/api/v1/books/pinned"),
        .init(.get, "/api/v1/books/ungrouped"),
        .init(.post, "/api/v1/books"),
        .init(.put, "/api/v1/books/{id}"),
        .init(.delete, "/api/v1/books/{id}"),
        .init(.put, "/api/v1/books/{id}/pin"),
        .init(.put, "/api/v1/books/{id}/add-to-bookshelf"),
        .init(.post, "/api/v1/books/batch-delete"),
        .init(.post, "/api/v1/books/batch-pin"),
        .init(.post, "/api/v1/books/batch-update"),
        .init(.post, "/api/v1/books/batch-set-tags"),
        .init(.post, "/api/v1/books/batch-replace-tags"),
        .init(.post, "/api/v1/books/batch-move-to-group"),
        .init(.post, "/api/v1/books/batch-move-out")
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

    private static let allowedSectionFields: Set<String> = [
        "create_time",
        "modify_time",
        "publish_date",
        "name",
        "read_done_time"
    ]

    let port: any DesktopWebBookPort

    /// 注册 Android BookController 当前批次的 19 条路由；固定路径优先于动态详情路径。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/books/stats") { _, _ in
            try DesktopWebAPIResponse.success(try await port.bookStats())
        }

        router.get("/api/v1/books/recent-read") { request, _ in
            let pagination = try Self.recentPagination(request)
            return try DesktopWebAPIResponse.success(
                try await port.recentReadBooks(
                    page: pagination.page,
                    pageSize: pagination.pageSize
                )
            )
        }

        router.get("/api/v1/books/last-note-book") { _, _ in
            try DesktopWebAPIResponse.success(try await port.lastNoteBook())
        }

        router.get("/api/v1/books/pinned") { request, _ in
            let pagination = try Self.pagination(request)
            return try DesktopWebAPIResponse.success(
                try await port.pinnedBooks(page: pagination.page, pageSize: pagination.pageSize)
            )
        }

        router.get("/api/v1/books/ungrouped") { request, _ in
            let pagination = try Self.pagination(request)
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
            return try DesktopWebAPIResponse.success(
                try await port.ungroupedBooks(
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    sortBy: sortBy,
                    sortOrder: sortOrder
                )
            )
        }

        router.get("/api/v1/books") { request, _ in
            let pagination = try Self.pagination(request)
            let rawSortBy = DesktopWebAndroidFormQuery.optionalString(
                named: "sortBy",
                default: "custom",
                in: request
            )
            let sortBy = Self.sortField(rawSortBy)
            let sortOrder = Self.sortOrder(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "sortOrder",
                    default: "desc",
                    in: request
                )
            )
            let sectionBy = Self.sectionField(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "sectionBy",
                    default: "none",
                    in: request
                )
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
            let filter = try Self.filter(request)

            if !sectionBy.isEmpty {
                return try DesktopWebAPIResponse.success(
                    try await port.bookSections(
                        filter: filter,
                        sectionBy: sectionBy,
                        sortOrder: sortOrder,
                        groupSortBy: groupSortBy,
                        groupSortOrder: groupSortOrder,
                        groupEnableSection: groupEnableSection
                    )
                )
            }
            return try DesktopWebAPIResponse.success(
                try await port.books(
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    filter: filter,
                    sortBy: sortBy,
                    sortOrder: sortOrder
                )
            )
        }

        router.get("/api/v1/books/:id") { _, context in
            let id = try DesktopWebAndroidPath.int64(try context.parameters.require("id"))
            return try DesktopWebAPIResponse.success(try await port.book(id: id))
        }

        router.post("/api/v1/books") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebBookCreateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.createBook(body))
        }

        router.put("/api/v1/books/:id") { request, context in
            let id = try DesktopWebAndroidPath.int64(try context.parameters.require("id"))
            let body = try await request.decodeStrictJSON(as: DesktopWebBookUpdateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(
                try await port.updateBook(id: id, request: body)
            )
        }

        router.delete("/api/v1/books/:id") { _, context in
            let id = try DesktopWebAndroidPath.int64(try context.parameters.require("id"))
            try await port.deleteBook(id: id)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.put("/api/v1/books/:id/pin") { request, context in
            let id = try DesktopWebAndroidPath.int64(try context.parameters.require("id"))
            let body = try await request.decodeStrictJSON(as: DesktopWebBookPinRequest.self, context: context)
            return try DesktopWebAPIResponse.success(
                try await port.updateBookPin(id: id, request: body)
            )
        }

        router.put("/api/v1/books/:id/add-to-bookshelf") { _, context in
            let id = try DesktopWebAndroidPath.int64(try context.parameters.require("id"))
            return try DesktopWebAPIResponse.success(try await port.addToBookshelf(id: id))
        }

        router.post("/api/v1/books/batch-delete") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookBatchDeleteRequest.self,
                context: context
            )
            try await port.batchDeleteBooks(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/books/batch-pin") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookBatchPinRequest.self,
                context: context
            )
            try await port.batchPinBooks(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/books/batch-update") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookBatchUpdateRequest.self,
                context: context
            )
            try await port.batchUpdateBooks(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/books/batch-set-tags") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookBatchSetTagsRequest.self,
                context: context
            )
            try await port.batchSetBookTags(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/books/batch-replace-tags") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookBatchReplaceTagsRequest.self,
                context: context
            )
            try await port.batchReplaceBookTags(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/books/batch-move-to-group") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookBatchMoveToGroupRequest.self,
                context: context
            )
            try await port.batchMoveToGroup(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/books/batch-move-out") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebBookBatchMoveOutRequest.self,
                context: context
            )
            try await port.batchMoveOut(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }

    /// 复刻 ParamValidator：普通分页至少为 1，pageSize 上限仍是 Android Int.MAX_VALUE。
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
            default: 20,
            in: request
        )
        return (max(1, page), min(max(1, pageSize), Int(Int32.max)))
    }

    /// 复刻最近阅读的 page/pageSize 与旧 limit 参数选择及 1...200 二次约束。
    private static func recentPagination(_ request: Request) throws -> (page: Int, pageSize: Int) {
        let page = try DesktopWebAndroidFormQuery.optionalInt32(
            named: "page",
            default: 0,
            in: request
        )
        let pageSize = try DesktopWebAndroidFormQuery.optionalInt32(
            named: "pageSize",
            default: 0,
            in: request
        )
        let limit = try DesktopWebAndroidFormQuery.optionalInt32(
            named: "limit",
            default: 0,
            in: request
        )
        let usesPagedParameters = page > 0 || pageSize > 0
        let resolvedPage = usesPagedParameters ? max(1, page) : 1
        let requestedSize: Int
        if usesPagedParameters && pageSize > 0 {
            requestedSize = pageSize
        } else if usesPagedParameters {
            requestedSize = 50
        } else if limit > 0 {
            requestedSize = limit
        } else {
            requestedSize = 50
        }
        return (resolvedPage, min(max(1, requestedSize), 200))
    }

    /// 复制 Controller 的 Long 参数绑定与 tag/source 逗号列表处理。
    private static func filter(_ request: Request) throws -> DesktopWebBookFilter {
        let keyword = DesktopWebAndroidFormQuery.optionalString(
            named: "keyword",
            default: "",
            in: request
        )
        let status = try DesktopWebAndroidFormQuery.optionalInt32(
            named: "status",
            default: 0,
            in: request
        )
        let groupID = try DesktopWebAndroidFormQuery.optionalInt64(
            named: "groupId",
            default: 0,
            in: request
        )
        let sourceID = try DesktopWebAndroidFormQuery.optionalInt64(
            named: "sourceId",
            default: 0,
            in: request
        )
        let tagIDs = distinctPositiveIDs(
            commaSeparatedInt64(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "tagIds",
                    default: "",
                    in: request
                )
            )
        )
        let parsedSourceIDs = distinctPositiveIDs(
            commaSeparatedInt64(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "sourceIds",
                    default: "",
                    in: request
                )
            )
        )
        let sourceIDs = parsedSourceIDs.isEmpty && sourceID > 0 ? [sourceID] : parsedSourceIDs
        let rawTagMode = DesktopWebAndroidFormQuery.optionalString(
            named: "tagMode",
            default: "or",
            in: request
        ).lowercased()
        return DesktopWebBookFilter(
            keyword: keyword,
            status: status,
            groupID: groupID,
            tagIDs: tagIDs,
            tagMode: rawTagMode == "and" || rawTagMode == "or" ? rawTagMode : "or",
            sourceIDs: sourceIDs
        )
    }

    private static func commaSeparatedInt64(_ rawValue: String) -> [Int64] {
        rawValue.split(separator: ",", omittingEmptySubsequences: false).compactMap {
            Int64($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func distinctPositiveIDs(_ values: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        return values.filter { $0 > 0 && seen.insert($0).inserted }
    }

    private static func sortField(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return allowedSortFields.contains(normalized) ? normalized : "custom"
    }

    private static func sortOrder(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return normalized == "asc" || normalized == "desc" ? normalized : "desc"
    }

    private static func sectionField(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return allowedSectionFields.contains(normalized) ? normalized : ""
    }
}
