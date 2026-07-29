/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebChapterPort
 * [OUTPUT]: 注册 ChapterController 全部 17 条本地、在线目录与导入路由
 * [POS]: XMNoteWeb 章节业务路由；只处理 HTTP 参数和 JSON 解码，不访问 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

struct DesktopWebChapterRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/books/{bookId}/chapters"),
        .init(.get, "/api/v1/books/{bookId}/chapters/last-used"),
        .init(.get, "/api/v1/chapters/starred"),
        .init(.post, "/api/v1/books/{bookId}/chapters"),
        .init(.put, "/api/v1/chapters/{id}"),
        .init(.put, "/api/v1/chapters/{id}/starred"),
        .init(.delete, "/api/v1/chapters/{id}"),
        .init(.post, "/api/v1/chapters/batch-delete"),
        .init(.put, "/api/v1/books/{bookId}/chapters/order"),
        .init(.put, "/api/v1/chapters/{parentId}/children/order"),
        .init(.put, "/api/v1/chapters/move-to-parent"),
        .init(.put, "/api/v1/chapters/move-out"),
        .init(.post, "/api/v1/books/{bookId}/chapters/batch"),
        .init(.get, "/api/v1/books/{bookId}/chapters/online/search"),
        .init(.get, "/api/v1/books/{bookId}/chapters/online-catalog"),
        .init(.post, "/api/v1/books/{bookId}/chapters/import-preview"),
        .init(.post, "/api/v1/books/{bookId}/chapters/import-commit")
    ]

    let port: any DesktopWebChapterPort

    /// 注册 Android v46 ChapterController 全量路由；仅导入提交属于核心写操作。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/chapters/starred") { _, _ in
            try DesktopWebAPIResponse.success(try await port.starredChapterGroups())
        }

        router.post("/api/v1/chapters/batch-delete") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebChapterIDsRequest.self, context: context)
            try await port.batchDeleteChapters(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.put("/api/v1/chapters/move-to-parent") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebChapterMoveToParentRequest.self,
                context: context
            )
            try await port.moveChaptersToParent(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.put("/api/v1/chapters/move-out") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebChapterMoveOutRequest.self, context: context)
            try await port.moveChaptersOut(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.get("/api/v1/books/:id/chapters/last-used") { _, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(try await port.lastUsedChapter(bookID: bookID))
        }

        router.put("/api/v1/books/:id/chapters/order") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(as: DesktopWebChapterIDsRequest.self, context: context)
            try await port.reorderParentChapters(bookID: bookID, request: body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/books/:id/chapters/batch") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebChapterBatchCreateRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.batchCreateChapters(bookID: bookID, request: body)
            )
        }

        router.get("/api/v1/books/:id/chapters/online/search") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            guard let rawKeyword = request.uri.queryParameters["keyword"] else {
                throw DesktopWebAPIError(code: 40001, message: "请求参数格式错误")
            }
            return try DesktopWebAPIResponse.success(
                try await port.searchOnlineChapterCandidates(
                    bookID: bookID,
                    keyword: String(rawKeyword)
                )
            )
        }

        router.get("/api/v1/books/:id/chapters/online-catalog") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let doubanID = try Self.optionalPositiveInt(request.uri.queryParameters["doubanId"])
            return try DesktopWebAPIResponse.success(
                try await port.onlineChapterCatalog(bookID: bookID, doubanID: doubanID)
            )
        }

        router.post("/api/v1/books/:id/chapters/import-preview") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebChapterImportPreviewRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.previewChapterImport(bookID: bookID, request: body)
            )
        }

        router.post("/api/v1/books/:id/chapters/import-commit") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebChapterImportCommitRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.commitChapterImport(bookID: bookID, request: body)
            )
        }

        router.get("/api/v1/books/:id/chapters") { _, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            return try DesktopWebAPIResponse.success(try await port.chapters(bookID: bookID))
        }

        router.post("/api/v1/books/:id/chapters") { request, context in
            let bookID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebChapterCreateRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.createChapter(bookID: bookID, request: body)
            )
        }

        router.put("/api/v1/chapters/:id/children/order") { request, context in
            let parentID = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(as: DesktopWebChapterIDsRequest.self, context: context)
            try await port.reorderChildChapters(parentID: parentID, request: body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.put("/api/v1/chapters/:id/starred") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebChapterStarredRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(
                try await port.updateChapterStarred(id: id, request: body)
            )
        }

        router.put("/api/v1/chapters/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(
                as: DesktopWebChapterUpdateRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(try await port.updateChapter(id: id, request: body))
        }

        router.delete("/api/v1/chapters/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            try await port.deleteChapter(id: id)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }

    private static func optionalPositiveInt(_ rawValue: Substring?) throws -> Int? {
        guard let rawValue else { return nil }
        guard let value = Int(rawValue) else {
            throw DesktopWebAPIError(code: 40001, message: "请求参数格式错误")
        }
        return value > 0 ? value : nil
    }
}
