/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebNotePort
 * [OUTPUT]: 注册 NoteController 全部 15 条列表、筛选、CRUD 与批量路由
 * [POS]: XMNoteWeb 书摘业务路由；只处理 HTTP 参数和 JSON 解码，不访问 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebNoteRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/books/{bookId}/notes"),
        .init(.get, "/api/v1/books/{bookId}/note-tags"),
        .init(.get, "/api/v1/books/{bookId}/notes/sort-rule"),
        .init(.put, "/api/v1/books/{bookId}/notes/sort-rule"),
        .init(.get, "/api/v1/notes"),
        .init(.get, "/api/v1/note-tags/filters"),
        .init(.get, "/api/v1/notes/{id}"),
        .init(.post, "/api/v1/notes"),
        .init(.put, "/api/v1/notes/{id}"),
        .init(.delete, "/api/v1/notes/{id}"),
        .init(.post, "/api/v1/notes/batch-delete"),
        .init(.post, "/api/v1/notes/batch-move-chapter"),
        .init(.post, "/api/v1/notes/batch-set-tags"),
        .init(.post, "/api/v1/notes/batch-move-book"),
        .init(.post, "/api/v1/notes/batch-merge")
    ]

    private static let allowedSortFields: Set<String> = ["create_time", "modify_time", "position"]
    private static let allowedSortModes: Set<String> = ["latest", "ordered", "random"]

    let port: any DesktopWebNotePort

    /// 注册 Android v46 NoteController 路由；固定批量路径先于动态详情路径。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/note-tags/filters") { _, _ in
            try DesktopWebAPIResponse.success(try await port.globalNoteTagFilters())
        }

        router.get("/api/v1/notes") { request, _ in
            let pagination = try Self.pagination(request)
            let filter = try Self.globalFilter(request)
            return try DesktopWebAPIResponse.success(
                try await port.globalNotes(
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    filter: filter
                )
            )
        }

        router.post("/api/v1/notes/batch-delete") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebNoteIDsRequest.self, context: context)
            try await port.batchDeleteNotes(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/notes/batch-move-chapter") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebNoteBatchMoveChapterRequest.self,
                context: context
            )
            try await port.batchMoveNotesToChapter(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/notes/batch-set-tags") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebNoteBatchSetTagsRequest.self,
                context: context
            )
            try await port.batchSetNoteTags(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/notes/batch-move-book") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebNoteBatchMoveBookRequest.self,
                context: context
            )
            try await port.batchMoveNotesToBook(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/notes/batch-merge") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebNoteBatchMergeRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(try await port.batchMergeNotes(body))
        }

        router.post("/api/v1/notes") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebNoteCreateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.createNote(body))
        }

        router.get("/api/v1/books/:id/note-tags") { _, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(
                try await port.bookNoteTagFilters(bookID: bookID)
            )
        }

        router.get("/api/v1/books/:id/notes/sort-rule") { _, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(
                try await port.bookNoteSortRule(bookID: bookID)
            )
        }

        router.put("/api/v1/books/:id/notes/sort-rule") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebNoteSortRuleUpdateRequest.self,
                context: context
            )
            let normalized = DesktopWebNoteSortRuleUpdateRequest(
                sortBy: Self.sortField(body.sortBy),
                sortOrder: Self.sortOrder(body.sortOrder)
            )
            return try DesktopWebAPIResponse.success(
                try await port.updateBookNoteSortRule(bookID: bookID, request: normalized)
            )
        }

        router.get("/api/v1/books/:id/notes") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let pagination = try Self.pagination(request)
            let filter = try Self.bookFilter(request)
            if filter.tagID != 0 && !filter.tagIDs.isEmpty {
                return try DesktopWebAPIResponse.error(
                    code: 40001,
                    message: "tagId 与 tagIds 不能同时传入"
                )
            }
            return try DesktopWebAPIResponse.success(
                try await port.bookNotes(
                    bookID: bookID,
                    page: pagination.page,
                    pageSize: pagination.pageSize,
                    filter: filter
                )
            )
        }

        router.get("/api/v1/notes/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            do {
                return try DesktopWebAPIResponse.success(try await port.note(id: id))
            } catch let error as DesktopWebAPIError where error.code == 40002 {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }

        router.put("/api/v1/notes/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(as: DesktopWebNoteUpdateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.updateNote(id: id, request: body))
        }

        router.delete("/api/v1/notes/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            try await port.deleteNote(id: id)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }

    private static func pagination(_ request: Request) throws -> (page: Int, pageSize: Int) {
        let page = try queryInt(request.uri.queryParameters["page"], defaultValue: 1)
        let pageSize = try queryInt(request.uri.queryParameters["pageSize"], defaultValue: 20)
        return (max(1, page), min(max(1, pageSize), Int(Int32.max)))
    }

    private static func bookFilter(_ request: Request) throws -> DesktopWebBookNoteFilter {
        let tagIDs = distinctPositiveIDs(commaSeparatedInt64(request.uri.queryParameters["tagIds"]))
        return DesktopWebBookNoteFilter(
            chapterID: try queryInt64(request.uri.queryParameters["chapterId"], defaultValue: 0),
            tagID: try queryInt64(request.uri.queryParameters["tagId"], defaultValue: 0),
            tagIDs: tagIDs,
            tagMode: tagMode(String(request.uri.queryParameters["tagMode"] ?? "or")),
            sortBy: sortField(String(request.uri.queryParameters["sortBy"] ?? "create_time")),
            sortOrder: sortOrder(String(request.uri.queryParameters["sortOrder"] ?? "desc"))
        )
    }

    private static func globalFilter(_ request: Request) throws -> DesktopWebGlobalNoteFilter {
        DesktopWebGlobalNoteFilter(
            keyword: String(request.uri.queryParameters["keyword"] ?? ""),
            bookID: try queryInt64(request.uri.queryParameters["bookId"], defaultValue: 0),
            bookIDs: commaSeparatedInt64(request.uri.queryParameters["bookIds"]),
            tagID: try queryInt64(request.uri.queryParameters["tagId"], defaultValue: 0),
            tagIDs: commaSeparatedInt64(request.uri.queryParameters["tagIds"]),
            tagMode: tagMode(String(request.uri.queryParameters["tagMode"] ?? "or")),
            sortBy: sortField(String(request.uri.queryParameters["sortBy"] ?? "create_time")),
            sortOrder: sortOrder(String(request.uri.queryParameters["sortOrder"] ?? "desc")),
            sortMode: sortMode(String(request.uri.queryParameters["sortMode"] ?? "latest")),
            excludeIDs: commaSeparatedInt64(request.uri.queryParameters["excludeIds"])
        )
    }

    private static func queryInt(_ rawValue: Substring?, defaultValue: Int) throws -> Int {
        guard let rawValue else { return defaultValue }
        guard let value = Int(rawValue), Int32(exactly: value) != nil else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "For input string: \"\(rawValue)\""
            )
        }
        return value
    }

    private static func queryInt64(_ rawValue: Substring?, defaultValue: Int64) throws -> Int64 {
        guard let rawValue else { return defaultValue }
        guard let value = Int64(rawValue) else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "For input string: \"\(rawValue)\""
            )
        }
        return value
    }

    private static func commaSeparatedInt64(_ rawValue: Substring?) -> [Int64] {
        guard let rawValue, !isKotlinBlank(String(rawValue)) else { return [] }
        return rawValue.split(separator: ",", omittingEmptySubsequences: false).compactMap {
            Int64(kotlinTrimmed(String($0)))
        }
    }

    private static func distinctPositiveIDs(_ values: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        return values.filter { $0 > 0 && seen.insert($0).inserted }
    }

    private static func sortField(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        let legacyNormalized = normalized == "page_index" ? "position" : normalized
        return allowedSortFields.contains(legacyNormalized) ? legacyNormalized : "create_time"
    }

    private static func sortOrder(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return normalized == "asc" || normalized == "desc" ? normalized : "desc"
    }

    private static func sortMode(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return allowedSortModes.contains(normalized) ? normalized : "latest"
    }

    private static func tagMode(_ rawValue: String) -> String {
        let normalized = rawValue.lowercased()
        return normalized == "and" || normalized == "or" ? normalized : "or"
    }

    private static func isKotlinBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy(isKotlinWhitespace)
    }

    private static func kotlinTrimmed(_ value: String) -> String {
        let scalars = value.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isKotlinWhitespace(scalars[start]) {
            start = scalars.index(after: start)
        }
        while start < end {
            let previous = scalars.index(before: end)
            guard isKotlinWhitespace(scalars[previous]) else { break }
            end = previous
        }
        return String(scalars[start..<end])
    }

    private static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.value == 0x1C || scalar.value == 0x1D ||
            scalar.value == 0x1E || scalar.value == 0x1F
    }
}
