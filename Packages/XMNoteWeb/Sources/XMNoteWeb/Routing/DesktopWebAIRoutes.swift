/**
 * [INPUT]: 依赖 Hummingbird Router、Android 包络和 App 注入的 DesktopWebAIPort
 * [OUTPUT]: 注册 AIController 的配置读取、局部更新与透明对话代理 3 条路由
 * [POS]: XMNoteWeb AI 路由层；不持有凭据，也不直接访问外部 LLM
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

struct DesktopWebAIRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/ai/config"),
        .init(.put, "/api/v1/ai/config"),
        .init(.post, "/api/v1/ai/chat/completions")
    ]

    let port: any DesktopWebAIPort

    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/ai/config") { _, _ in
            try DesktopWebAPIResponse.success(try await port.aiConfig())
        }
        router.put("/api/v1/ai/config") { request, context in
            let patch = try await request.decodeStrictJSON(
                as: DesktopWebJSONValue.self,
                context: context
            )
            guard patch != .null else {
                throw DesktopWebAPIError(code: 40001, message: "请求体不能为空")
            }
            guard patch.objectValue != nil else {
                throw DesktopWebAPIError(code: 40001, message: "请求体 JSON 格式错误")
            }
            try await port.updateAIConfig(patch)
            return try DesktopWebAPIResponse.success(nil as Bool?)
        }
        router.post("/api/v1/ai/chat/completions") { request, _ in
            let buffer = try await request.body.collect(upTo: 2 * 1_024 * 1_024)
            return DesktopWebRawResponse.make(
                try await port.chatCompletions(body: Data(buffer.readableBytesView))
            )
        }
    }
}
