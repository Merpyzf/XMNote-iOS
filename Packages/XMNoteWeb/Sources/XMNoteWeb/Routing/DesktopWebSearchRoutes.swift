/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebSearchPort
 * [OUTPUT]: 注册 SearchController 的单域搜索与四域聚合两条只读路由
 * [POS]: XMNoteWeb 搜索路由；只处理必填参数、Int 边界和分页归一化
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

struct DesktopWebSearchRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/search"),
        .init(.get, "/api/v1/search/aggregate")
    ]

    let port: any DesktopWebSearchPort

    /// 注册 Android v46 查询参数合同；不 trim type/keyword，避免改变 SQLite LIKE 输入。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/search/aggregate") { request, _ in
            let query = try Self.commonQuery(request, requiresType: false)
            return try DesktopWebAPIResponse.success(
                await port.searchAggregate(
                    keyword: query.keyword,
                    page: query.page,
                    pageSize: query.pageSize,
                    bookID: query.bookID,
                    tagID: query.tagID
                )
            )
        }

        router.get("/api/v1/search") { request, _ in
            let query = try Self.commonQuery(request, requiresType: true)
            guard let type = query.type else {
                throw DesktopWebAPIError(code: 40001, message: "请求参数格式错误")
            }
            return try DesktopWebAPIResponse.success(
                try await port.search(
                    type: type,
                    keyword: query.keyword,
                    page: query.page,
                    pageSize: query.pageSize,
                    bookID: query.bookID,
                    tagID: query.tagID
                )
            )
        }
    }

    private static func commonQuery(
        _ request: Request,
        requiresType: Bool
    ) throws -> (
        type: DesktopWebSearchType?,
        keyword: String,
        page: Int,
        pageSize: Int,
        bookID: Int64,
        tagID: Int64
    ) {
        let type: DesktopWebSearchType?
        if requiresType {
            guard let rawType = request.uri.queryParameters["type"] else {
                throw DesktopWebAPIError(
                    code: 40001,
                    message: "Missing param [type] for method parameter."
                )
            }
            let original = String(rawType)
            guard let parsed = DesktopWebSearchType(rawValue: original.lowercased()) else {
                throw DesktopWebAPIError(
                    code: 40001,
                    message: "Invalid search type: \(original). Allowed: book, note, review, relevant"
                )
            }
            type = parsed
        } else {
            type = nil
        }
        guard let rawKeyword = request.uri.queryParameters["keyword"] else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "Missing param [keyword] for method parameter."
            )
        }
        let page = try queryInt(request.uri.queryParameters["page"], defaultValue: 1)
        let pageSize = try queryInt(request.uri.queryParameters["pageSize"], defaultValue: 20)
        return (
            type,
            String(rawKeyword),
            max(1, page),
            min(max(1, pageSize), Int(Int32.max)),
            try queryInt64(request.uri.queryParameters["bookId"], defaultValue: 0),
            try queryInt64(request.uri.queryParameters["tagId"], defaultValue: 0)
        )
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
}
