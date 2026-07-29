/**
 * [INPUT]: 依赖 Hummingbird Router、multipart 解析器和 App 注入的 DesktopWebImportPort
 * [OUTPUT]: 注册导入任务创建、查询、提交和删除共 4 条路由
 * [POS]: XMNoteWeb 导入路由层；解析、任务状态和数据库提交均由 App Adapter 承担
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

struct DesktopWebImportRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.post, "/api/v1/import/tasks"),
        .init(.get, "/api/v1/import/tasks/{taskId}"),
        .init(.post, "/api/v1/import/tasks/{taskId}/commit"),
        .init(.delete, "/api/v1/import/tasks/{taskId}")
    ]

    let port: any DesktopWebImportPort

    func register(on router: Router<BasicRequestContext>) {
        router.post("/api/v1/import/tasks") { request, _ in
            let missingFileMessage = "Missing param [file] for method parameter."
            let form = try await DesktopWebMultipartForm.decode(
                request,
                maxBytes: 100 * 1_024 * 1_024,
                missingMultipartMessage: missingFileMessage
            )
            guard let file = form.files["file"] else {
                throw DesktopWebAPIError(code: 40001, message: missingFileMessage)
            }
            do {
                return try DesktopWebAPIResponse.success(
                    try await port.createImportTask(file: file)
                )
            } catch let error as DesktopWebAPIError {
                return try DesktopWebAPIResponse.error(
                    code: error.code,
                    message: error.message
                )
            }
        }
        router.get("/api/v1/import/tasks/:id") { _, context in
            let id = try context.parameters.require("id")
            do {
                return try DesktopWebAPIResponse.success(try await port.importTask(id: id))
            } catch let error as DesktopWebAPIError {
                return try DesktopWebAPIResponse.error(
                    code: error.code,
                    message: error.message
                )
            }
        }
        router.post("/api/v1/import/tasks/:id/commit") { request, context in
            let id = try context.parameters.require("id")
            let body = try await request.decodeStrictJSON(as: DesktopWebImportTaskCommitRequest.self, context: context)
            do {
                return try DesktopWebAPIResponse.success(
                    try await port.commitImportTask(id: id, request: body)
                )
            } catch let error as DesktopWebAPIError {
                return try DesktopWebAPIResponse.error(
                    code: error.code,
                    message: error.message
                )
            }
        }
        router.delete("/api/v1/import/tasks/:id") { _, context in
            let id = try context.parameters.require("id")
            do {
                try await port.deleteImportTask(id: id)
                return try DesktopWebAPIResponse.success(nil as Bool?)
            } catch let error as DesktopWebAPIError {
                return try DesktopWebAPIResponse.error(
                    code: error.code,
                    message: error.message
                )
            }
        }
    }
}
