/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebReadingRecordPort
 * [OUTPUT]: 注册 ReadTimeController 与 ReadingRecordController 全部 6 条路由
 * [POS]: XMNoteWeb 阅读记录路由；只处理 HTTP 参数、默认值和 JSON 解码
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebReadingRecordRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.post, "/api/v1/reading-timer/sessions"),
        .init(.get, "/api/v1/books/{bookId}/reading-records"),
        .init(.get, "/api/v1/books/{bookId}/reading-records/{recordId}"),
        .init(.post, "/api/v1/books/{bookId}/reading-records"),
        .init(.put, "/api/v1/books/{bookId}/reading-records/{recordId}"),
        .init(.delete, "/api/v1/books/{bookId}/reading-records/{recordId}")
    ]

    let port: any DesktopWebReadingRecordPort

    /// 注册 Android v46 路由；同一路径的列表和详情由 Hummingbird 参数段区分。
    func register(on router: Router<BasicRequestContext>) {
        router.post("/api/v1/reading-timer/sessions") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebReadingSessionCreateRequest.self,
                context: context
            )
            let id = try await port.createReadingSession(body)
            return try DesktopWebAPIResponse.success(DesktopWebCreatedReadingSession(id: id))
        }

        router.get("/api/v1/books/:id/reading-records") { request, context in
            let bookID = try Self.pathInt64(try context.parameters.require("id"))
            // TODO(ANDROID-WEB-091): AndServer 的首键重复值缺陷同样作用于 String 排序参数。
            let sortOrder = Self.sortOrder(
                DesktopWebAndroidFormQuery.optionalString(
                    named: "sortOrder",
                    default: "desc",
                    in: request
                )
            )
            return try DesktopWebAPIResponse.success(
                try await port.readingRecords(bookID: bookID, sortOrder: sortOrder)
            )
        }

        router.get("/api/v1/books/:id/reading-records/:recordId") { _, context in
            let bookID = try Self.pathInt64(try context.parameters.require("id"))
            let recordID = try Self.pathInt64(try context.parameters.require("recordId"))
            return try DesktopWebAPIResponse.success(
                try await port.readingRecord(bookID: bookID, recordID: recordID)
            )
        }

        router.post("/api/v1/books/:id/reading-records") { request, context in
            let bookID = try Self.pathInt64(try context.parameters.require("id"))
            let body = try await request.decodeStrictJSON(
                as: DesktopWebReadingRecordUpsertRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.createReadingRecord(bookID: bookID, request: body)
            )
        }

        router.put("/api/v1/books/:id/reading-records/:recordId") { request, context in
            let bookID = try Self.pathInt64(try context.parameters.require("id"))
            let recordID = try Self.pathInt64(try context.parameters.require("recordId"))
            let body = try await request.decodeStrictJSON(
                as: DesktopWebReadingRecordUpsertRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.updateReadingRecord(
                    bookID: bookID,
                    recordID: recordID,
                    request: body
                )
            )
        }

        router.delete("/api/v1/books/:id/reading-records/:recordId") { _, context in
            let bookID = try Self.pathInt64(try context.parameters.require("id"))
            let recordID = try Self.pathInt64(try context.parameters.require("recordId"))
            try await port.deleteReadingRecord(bookID: bookID, recordID: recordID)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }

    private static func sortOrder(_ raw: String) -> String {
        let normalized = raw.lowercased()
        return normalized == "asc" || normalized == "desc" ? normalized : "desc"
    }

    /// 复刻 AndServer Long 路径绑定的百分号解码和 Java 解析错误文本。
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
}
