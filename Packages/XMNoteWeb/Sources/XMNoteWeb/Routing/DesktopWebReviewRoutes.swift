/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebReviewPort
 * [OUTPUT]: 注册 ReviewController 全部 11 条列表、草稿、排序与 CRUD 路由
 * [POS]: XMNoteWeb 书评业务路由；只处理 HTTP 参数和 JSON 解码，不访问 App 数据库或 UserDefaults
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebReviewRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/reviews"),
        .init(.get, "/api/v1/reviews/drafts"),
        .init(.put, "/api/v1/reviews/drafts"),
        .init(.delete, "/api/v1/reviews/drafts"),
        .init(.get, "/api/v1/books/{bookId}/reviews"),
        .init(.get, "/api/v1/books/{bookId}/reviews/sort-rule"),
        .init(.put, "/api/v1/books/{bookId}/reviews/sort-rule"),
        .init(.get, "/api/v1/reviews/{id}"),
        .init(.post, "/api/v1/reviews"),
        .init(.put, "/api/v1/reviews/{id}"),
        .init(.delete, "/api/v1/reviews/{id}")
    ]

    private static let allowedSortFields: Set<String> = ["create_time", "word_count"]
    private static let allowedSortModes: Set<String> = ["latest", "ordered", "random"]

    let port: any DesktopWebReviewPort

    /// 注册 Android v46 ReviewController 路由；drafts 静态路径先于动态详情路径。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/reviews/drafts") { request, _ in
            let bookID = try Self.requiredQueryInt64(request, name: "bookId")
            let reviewID = try Self.queryInt64(
                request.uri.queryParameters["reviewId"],
                defaultValue: 0
            )
            do {
                return try DesktopWebAPIResponse.success(
                    try await port.reviewDraft(bookID: bookID, reviewID: reviewID)
                )
            } catch let error as DesktopWebAPIError where error.code == 40001 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.put("/api/v1/reviews/drafts") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebReviewDraftUpsertRequest.self,
                context: context
            )
            do {
                return try DesktopWebAPIResponse.success(try await port.upsertReviewDraft(body))
            } catch let error as DesktopWebAPIError where error.code == 40001 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.delete("/api/v1/reviews/drafts") { request, _ in
            let bookID = try Self.requiredQueryInt64(request, name: "bookId")
            let reviewID = try Self.queryInt64(
                request.uri.queryParameters["reviewId"],
                defaultValue: 0
            )
            do {
                try await port.deleteReviewDraft(bookID: bookID, reviewID: reviewID)
                return try DesktopWebAPIResponse.success(nil as Bool?)
            } catch let error as DesktopWebAPIError where error.code == 40001 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.get("/api/v1/reviews") { request, _ in
            let pagination = try Self.pagination(request)
            let filter = DesktopWebGlobalReviewFilter(
                keyword: String(request.uri.queryParameters["keyword"] ?? ""),
                bookID: try Self.queryInt64(
                    request.uri.queryParameters["bookId"],
                    defaultValue: 0
                ),
                sortBy: Self.sortField(String(request.uri.queryParameters["sortBy"] ?? "create_time")),
                sortOrder: Self.sortOrder(String(request.uri.queryParameters["sortOrder"] ?? "desc")),
                sortMode: Self.sortMode(String(request.uri.queryParameters["sortMode"] ?? "latest")),
                excludeIDs: Self.commaSeparatedInt64(request.uri.queryParameters["excludeIds"])
            )
            return try DesktopWebAPIResponse.success(
                try await port.globalReviews(
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    filter: filter
                )
            )
        }

        router.post("/api/v1/reviews") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebReviewCreateRequest.self,
                context: context
            )
            do {
                return try DesktopWebAPIResponse.success(try await port.createReview(body))
            } catch let error as DesktopWebAPIError where error.code == 40001 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.get("/api/v1/books/:id/reviews/sort-rule") { _, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(
                try await port.bookReviewSortRule(bookID: bookID)
            )
        }

        router.put("/api/v1/books/:id/reviews/sort-rule") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebReviewSortRuleUpdateRequest.self,
                context: context
            )
            let normalized = DesktopWebReviewSortRuleUpdateRequest(
                sortBy: Self.sortField(body.sortBy),
                sortOrder: Self.sortOrder(body.sortOrder)
            )
            do {
                return try DesktopWebAPIResponse.success(
                    try await port.updateBookReviewSortRule(bookID: bookID, request: normalized)
                )
            } catch let error as DesktopWebAPIError where error.code == 40001 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.get("/api/v1/books/:id/reviews") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let pagination = try Self.pagination(request)
            return try DesktopWebAPIResponse.success(
                try await port.bookReviews(
                    bookID: bookID,
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    sortBy: Self.sortField(String(request.uri.queryParameters["sortBy"] ?? "create_time")),
                    sortOrder: Self.sortOrder(String(request.uri.queryParameters["sortOrder"] ?? "desc"))
                )
            )
        }

        router.get("/api/v1/reviews/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            do {
                return try DesktopWebAPIResponse.success(try await port.review(id: id))
            } catch let error as DesktopWebAPIError where error.code == 40002 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.put("/api/v1/reviews/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebReviewUpdateRequest.self,
                context: context
            )
            do {
                return try DesktopWebAPIResponse.success(try await port.updateReview(id: id, request: body))
            } catch let error as DesktopWebAPIError where error.code == 40001 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.delete("/api/v1/reviews/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            do {
                try await port.deleteReview(id: id)
                return try DesktopWebAPIResponse.success(nil as Bool?)
            } catch let error as DesktopWebAPIError where error.code == 40002 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }
    }

    private static func pagination(_ request: Request) throws -> (page: Int, pageSize: Int) {
        let page = try queryInt(request.uri.queryParameters["page"], defaultValue: 1)
        let pageSize = try queryInt(request.uri.queryParameters["pageSize"], defaultValue: 20)
        return (max(1, page), min(max(1, pageSize), Int(Int32.max)))
    }

    private static func requiredQueryInt64(_ request: Request, name: String) throws -> Int64 {
        guard let value = request.uri.queryParameters[Substring(name)] else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "Missing param [\(name)] for method parameter."
            )
        }
        guard let parsed = Int64(value) else {
            throw DesktopWebAPIError(code: 40001, message: "For input string: \"\(value)\"")
        }
        return parsed
    }

    private static func queryInt(_ value: Substring?, defaultValue: Int) throws -> Int {
        guard let value else { return defaultValue }
        guard let parsed = Int(value), parsed >= Int(Int32.min), parsed <= Int(Int32.max) else {
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

    private static func sortField(_ raw: String) -> String {
        let value = raw.lowercased()
        return allowedSortFields.contains(value) ? value : "create_time"
    }

    private static func sortOrder(_ raw: String) -> String {
        let value = raw.lowercased()
        return value == "asc" || value == "desc" ? value : "desc"
    }

    private static func sortMode(_ raw: String) -> String {
        let value = raw.lowercased()
        return allowedSortModes.contains(value) ? value : "latest"
    }

    private static func commaSeparatedInt64(_ value: Substring?) -> [Int64] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",", omittingEmptySubsequences: false).compactMap {
            Int64($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
