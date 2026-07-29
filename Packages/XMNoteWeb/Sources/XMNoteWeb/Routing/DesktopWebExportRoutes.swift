/**
 * [INPUT]: 依赖 Hummingbird Router、Android 包络和 App 注入的 DesktopWebExportPort
 * [OUTPUT]: 注册平台枚举、本地下载和远端导出共 4 条路由
 * [POS]: XMNoteWeb 导出路由层；文件生成、凭据和远端副作用均由 App Adapter 承担
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebExportRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/export/platforms/siyuan/notebooks"),
        .init(.get, "/api/v1/export/platforms/obsidian/dirs"),
        .init(.post, "/api/v1/export/notes/local"),
        .init(.post, "/api/v1/export/notes/remote")
    ]

    let port: any DesktopWebExportPort

    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/export/platforms/siyuan/notebooks") { _, _ in
            do { return try DesktopWebAPIResponse.success(try await port.siYuanNotebooks()) }
            catch { return try DesktopWebAPIResponse.error(code: 400, message: error.localizedDescription) }
        }
        router.get("/api/v1/export/platforms/obsidian/dirs") { _, _ in
            do { return try DesktopWebAPIResponse.success(try await port.obsidianDirectories()) }
            catch { return try DesktopWebAPIResponse.error(code: 400, message: error.localizedDescription) }
        }
        router.post("/api/v1/export/notes/local") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebNoteExportRequest.self, context: context)
            let file = try await port.exportNotesLocally(body)
            let encodedName = file.fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.fileName
            return DesktopWebRawResponse.make(.init(
                statusCode: 200,
                headers: [
                    "Content-Type": file.mediaType,
                    "Content-Disposition": "attachment; filename*=UTF-8''\(encodedName)",
                    "Cache-Control": "no-store",
                    "Access-Control-Expose-Headers": "Content-Disposition, Content-Type, Cache-Control"
                ],
                body: file.data
            ))
        }
        router.post("/api/v1/export/notes/remote") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebNoteExportRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.exportNotesRemotely(body))
        }
    }
}
