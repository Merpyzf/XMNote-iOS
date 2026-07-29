/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebRelatedPort
 * [OUTPUT]: 注册 RelatedController 全部 18 条类别、列表、排序、CRUD 与批量路由
 * [POS]: XMNoteWeb 相关内容业务路由；只处理 HTTP 参数和 JSON 解码，不访问 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebRelatedRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/related-categories"),
        .init(.get, "/api/v1/books/{bookId}/related-categories"),
        .init(.post, "/api/v1/books/{bookId}/related-categories"),
        .init(.put, "/api/v1/related-categories/{id}"),
        .init(.put, "/api/v1/related-categories/{id}/visibility"),
        .init(.delete, "/api/v1/related-categories/{id}"),
        .init(.post, "/api/v1/books/{bookId}/related-categories/reorder"),
        .init(.get, "/api/v1/books/{bookId}/related-notes/sort-rule"),
        .init(.put, "/api/v1/books/{bookId}/related-notes/sort-rule"),
        .init(.get, "/api/v1/books/{bookId}/related-notes"),
        .init(.get, "/api/v1/books/{bookId}/related-notes/all"),
        .init(.get, "/api/v1/related-notes"),
        .init(.get, "/api/v1/related-notes/{id}"),
        .init(.post, "/api/v1/related-notes"),
        .init(.put, "/api/v1/related-notes/{id}"),
        .init(.delete, "/api/v1/related-notes/{id}"),
        .init(.post, "/api/v1/related-notes/batch-delete"),
        .init(.post, "/api/v1/related-notes/batch-update-category")
    ]

    private static let allowedSortFields: Set<String> = [
        "create_time", "update_time", "title"
    ]
    private static let allowedSortModes: Set<String> = ["latest", "ordered", "random"]

    let port: any DesktopWebRelatedPort

    /// 注册 Android v46 RelatedController 路由；批量、all、sort-rule 路径先于动态详情。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/related-categories") { request, _ in
            return try DesktopWebAPIResponse.success(
                try await port.globalRelatedCategories(
                    includeHidden: Self.boolean(request.uri.queryParameters["includeHidden"])
                )
            )
        }

        router.post("/api/v1/related-notes/batch-delete") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedNoteBatchDeleteRequest.self,
                context: context
            )
            try await port.batchDeleteRelatedNotes(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/related-notes/batch-update-category") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedNoteBatchUpdateCategoryRequest.self,
                context: context
            )
            try await port.batchUpdateRelatedNotesCategory(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.get("/api/v1/related-notes") { request, _ in
            let pagination = try Self.pagination(request)
            let filter = DesktopWebGlobalRelatedNoteFilter(
                bookID: try Self.queryInt64(request.uri.queryParameters["bookId"], defaultValue: 0),
                categoryID: try Self.queryInt64(
                    request.uri.queryParameters["categoryId"],
                    defaultValue: 0
                ),
                keyword: String(request.uri.queryParameters["keyword"] ?? ""),
                sortBy: Self.sortField(String(request.uri.queryParameters["sortBy"] ?? "create_time")),
                sortOrder: Self.sortOrder(String(request.uri.queryParameters["sortOrder"] ?? "desc")),
                sortMode: Self.sortMode(String(request.uri.queryParameters["sortMode"] ?? "latest")),
                excludeIDs: Self.commaSeparatedInt64(request.uri.queryParameters["excludeIds"])
            )
            return try DesktopWebAPIResponse.success(
                try await port.globalRelatedNotes(
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    filter: filter
                )
            )
        }

        router.post("/api/v1/related-notes") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedNoteCreateRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(try await port.createRelatedNote(body))
        }

        router.get("/api/v1/books/:id/related-categories") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(
                try await port.relatedCategories(
                    bookID: bookID,
                    includeHidden: Self.boolean(request.uri.queryParameters["includeHidden"])
                )
            )
        }

        router.post("/api/v1/books/:id/related-categories/reorder") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedCategoryReorderRequest.self,
                context: context
            )
            try await port.reorderRelatedCategories(bookID: bookID, request: body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/books/:id/related-categories") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedCategoryCreateRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.createRelatedCategory(bookID: bookID, request: body)
            )
        }

        router.get("/api/v1/books/:id/related-notes/sort-rule") { _, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(
                try await port.relatedNoteSortRule(bookID: bookID)
            )
        }

        router.put("/api/v1/books/:id/related-notes/sort-rule") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedSortRuleUpdateRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.updateRelatedNoteSortRule(bookID: bookID, request: body)
            )
        }

        router.get("/api/v1/books/:id/related-notes/all") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(
                try await port.allRelatedNotes(bookID: bookID, filter: try Self.filter(request))
            )
        }

        router.get("/api/v1/books/:id/related-notes") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let pagination = try Self.pagination(request)
            return try DesktopWebAPIResponse.success(
                try await port.relatedNotes(
                    bookID: bookID,
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    filter: try Self.filter(request)
                )
            )
        }

        router.put("/api/v1/related-categories/:id/visibility") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedCategoryVisibilityRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.updateRelatedCategoryVisibility(id: id, request: body)
            )
        }

        router.put("/api/v1/related-categories/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedCategoryUpdateRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.updateRelatedCategory(id: id, request: body)
            )
        }

        router.delete("/api/v1/related-categories/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            try await port.deleteRelatedCategory(id: id)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.get("/api/v1/related-notes/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            do {
                return try DesktopWebAPIResponse.success(try await port.relatedNote(id: id))
            } catch let error as DesktopWebAPIError where error.code == 40002 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.put("/api/v1/related-notes/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebRelatedNoteUpdateRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.updateRelatedNote(id: id, request: body)
            )
        }

        router.delete("/api/v1/related-notes/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            try await port.deleteRelatedNote(id: id)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }

    private static func filter(_ request: Request) throws -> DesktopWebRelatedNoteFilter {
        DesktopWebRelatedNoteFilter(
            categoryID: try queryInt64(
                request.uri.queryParameters["categoryId"],
                defaultValue: 0
            ),
            keyword: String(request.uri.queryParameters["keyword"] ?? ""),
            sortBy: sortField(String(request.uri.queryParameters["sortBy"] ?? "create_time")),
            sortOrder: sortOrder(String(request.uri.queryParameters["sortOrder"] ?? "desc"))
        )
    }

    private static func pagination(_ request: Request) throws -> (page: Int, pageSize: Int) {
        // NOTE(ANDROID-WEB-003): Android 未设置实用 pageSize 上限；一致性阶段保留 Int32.max 边界。
        let page = try queryInt(request.uri.queryParameters["page"], defaultValue: 1)
        let pageSize = try queryInt(request.uri.queryParameters["pageSize"], defaultValue: 20)
        return (max(1, page), min(max(1, pageSize), Int(Int32.max)))
    }

    private static func queryInt(_ value: Substring?, defaultValue: Int) throws -> Int {
        guard let value else { return defaultValue }
        guard let parsed = Int(value), Int32(exactly: parsed) != nil else {
            throw DesktopWebAPIError(code: 40001, message: "For input string: \"\(value)\"")
        }
        return parsed
    }

    private static func queryInt64(_ value: Substring?, defaultValue: Int64) throws -> Int64 {
        guard let value else { return defaultValue }
        guard let parsed = Int64(value) else {
            throw DesktopWebAPIError(code: 40001, message: "For input string: \"\(value)\"")
        }
        return parsed
    }

    private static func boolean(_ value: Substring?) -> Bool {
        String(value ?? "false").lowercased() == "true"
    }

    private static func sortField(_ raw: String) -> String {
        let normalized = raw.lowercased() == "modify_time" ? "update_time" : raw.lowercased()
        return allowedSortFields.contains(normalized) ? normalized : "create_time"
    }

    private static func sortOrder(_ raw: String) -> String {
        let normalized = raw.lowercased()
        return normalized == "asc" || normalized == "desc" ? normalized : "desc"
    }

    private static func sortMode(_ raw: String) -> String {
        let normalized = raw.lowercased()
        return allowedSortModes.contains(normalized) ? normalized : "latest"
    }

    private static func commaSeparatedInt64(_ value: Substring?) -> [Int64] {
        guard let value, !isKotlinBlank(String(value)) else { return [] }
        return value.split(separator: ",", omittingEmptySubsequences: false).compactMap {
            Int64($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func isKotlinBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value <= 0x20 || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}
