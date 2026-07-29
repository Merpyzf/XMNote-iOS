/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容 API 包络和 App 注入的 DesktopWebTagPort
 * [OUTPUT]: 注册标签列表、新增、编辑、删除和排序共 5 条路由
 * [POS]: XMNoteWeb 标签业务路由；不访问 App 数据库，也不修正 Android Web 的既有异常语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebTagRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/tags"),
        .init(.post, "/api/v1/tags"),
        .init(.put, "/api/v1/tags/{id}"),
        .init(.delete, "/api/v1/tags/{id}"),
        .init(.put, "/api/v1/tags/order")
    ]

    let port: any DesktopWebTagPort

    /// 注册 5 条 Android TagController 路由；参数校验和写入副作用由能力端口统一承担。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/tags") { request, _ in
            // TODO(ANDROID-WEB-091): Android 暴露 Java Int32 解析文本并异常拼接重复参数；基线收敛前保留该兼容语义。
            let rawType = DesktopWebAndroidFormQuery.value(named: "type", in: request)
            let type: Int
            if let rawType, !rawType.isEmpty {
                guard let parsedType = Int32(rawType) else {
                    throw DesktopWebAPIError(
                        code: 40001,
                        message: "For input string: \"\(rawType)\""
                    )
                }
                type = Int(parsedType)
            } else {
                type = 0
            }
            return try DesktopWebAPIResponse.success(try await port.tags(type: type))
        }

        router.put("/api/v1/tags/order") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebOrderRequest.self, context: context)
            try await port.reorderTags(body)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }

        router.post("/api/v1/tags") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebTagCreateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.createTag(body))
        }

        router.put("/api/v1/tags/:id") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decodeStrictJSON(as: DesktopWebTagUpdateRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.updateTag(id: id, request: body))
        }

        router.delete("/api/v1/tags/:id") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            try await port.deleteTag(id: id)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
    }

}
