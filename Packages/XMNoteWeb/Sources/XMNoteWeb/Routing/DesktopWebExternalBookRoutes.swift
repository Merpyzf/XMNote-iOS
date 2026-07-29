/**
 * [INPUT]: 依赖 Hummingbird Router、Android 包络和 App 注入的在线搜索与封面代理端口
 * [OUTPUT]: 注册在线书籍搜索与免访问码封面代理 2 条路由
 * [POS]: XMNoteWeb 外部书籍路由层；不直接访问网络、缓存或 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebExternalBookRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/books/search/online"),
        .init(.get, "/api/v1/book-covers/proxy/{bookId}")
    ]

    let onlineBook: (any DesktopWebOnlineBookPort)?
    let bookCover: (any DesktopWebBookCoverPort)?

    func register(on router: Router<BasicRequestContext>) {
        if let onlineBook {
            router.get("/api/v1/books/search/online") { request, _ in
                guard let keyword = request.uri.queryParameters["keyword"] else {
                    throw DesktopWebAPIError(
                        code: 40001,
                        message: "Missing param [keyword] for method parameter."
                    )
                }
                return try DesktopWebAPIResponse.success(
                    try await onlineBook.searchOnlineBooks(keyword: String(keyword))
                )
            }
        }
        if let bookCover {
            router.get("/api/v1/book-covers/proxy/:id") { request, context in
                let bookID = try context.parameters.require("id", as: Int64.self)
                let expires = request.uri.queryParameters["expires"].flatMap { Int64($0) }
                let signature = request.uri.queryParameters["sig"].map(String.init)
                do {
                    return DesktopWebRawResponse.make(
                        try await bookCover.proxiedBookCover(
                            bookID: bookID,
                            expires: expires,
                            signature: signature
                        )
                    )
                } catch let error as DesktopWebAPIError {
                    let statusCode = switch error.code {
                    case 403, 404, 413, 415: error.code
                    default: 502
                    }
                    return DesktopWebRawResponse.make(.init(
                        statusCode: statusCode,
                        headers: [:],
                        body: Data(error.message.utf8)
                    ))
                }
            }
        }
    }
}
