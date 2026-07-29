/**
 * [INPUT]: 依赖 Hummingbird Router、multipart 解析器和 App 注入的 DesktopWebUploadPort
 * [OUTPUT]: 注册票据预留、笔记图片上传、票据释放与封面上传共 4 条路由
 * [POS]: XMNoteWeb 上传路由层；风控、对象存储与票据提交均由 App Adapter 承担
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

struct DesktopWebUploadRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.post, "/api/v1/note-images/upload-tickets"),
        .init(.post, "/api/v1/note-images/upload"),
        .init(.post, "/api/v1/note-images/upload-tickets/release"),
        .init(.post, "/api/v1/book-covers/upload")
    ]

    let port: any DesktopWebUploadPort

    func register(on router: Router<BasicRequestContext>) {
        router.post("/api/v1/note-images/upload-tickets") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebUploadTicketReserveRequest.self, context: context)
            do {
                return try DesktopWebAPIResponse.success(
                    try await port.reserveNoteImageTickets(count: max(1, body.count))
                )
            } catch let error as DesktopWebAPIError {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }
        router.post("/api/v1/note-images/upload") { request, _ in
            let form = try await DesktopWebMultipartForm.decode(
                request,
                missingMultipartMessage: "Missing param [ticketId] for method parameter."
            )
            guard let ticketID = form.fields["ticketId"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ticketID.isEmpty else {
                throw DesktopWebAPIError(code: 40001, message: "上传票据不能为空")
            }
            guard let file = form.files["file"] else {
                throw DesktopWebAPIError(code: 40001, message: "请选择图片")
            }
            do {
                return try DesktopWebAPIResponse.success(
                    try await port.uploadNoteImage(ticketID: ticketID, file: file)
                )
            } catch let error as DesktopWebAPIError {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }
        router.post("/api/v1/note-images/upload-tickets/release") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebUploadTicketReleaseRequest.self, context: context)
            do {
                try await port.releaseNoteImageTickets(body.ticketIds)
                return try DesktopWebAPIResponse.success([String: Bool]())
            } catch let error as DesktopWebAPIError {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }
        router.post("/api/v1/book-covers/upload") { request, _ in
            let form = try await DesktopWebMultipartForm.decode(
                request,
                missingMultipartMessage: "Missing param [file] for method parameter."
            )
            guard let file = form.files["file"] else {
                throw DesktopWebAPIError(code: 40001, message: "请选择图片")
            }
            do {
                return try DesktopWebAPIResponse.success(try await port.uploadBookCover(file: file))
            } catch let error as DesktopWebAPIError {
                return try DesktopWebAPIResponse.error(code: error.code, message: error.message)
            }
        }
    }
}
