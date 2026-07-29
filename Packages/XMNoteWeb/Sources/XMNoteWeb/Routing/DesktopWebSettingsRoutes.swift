/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容 API 包络和 App 注入的 DesktopWebSettingsPort
 * [OUTPUT]: 注册设置、访问授权状态、会员能力与原生高级版动作共 7 条路由
 * [POS]: XMNoteWeb 第一阶段业务路由；不持久化设置，也不直接触发 App 导航
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

struct DesktopWebSettingsRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.post, "/api/v1/native/actions/open-vip-upgrade"),
        .init(.get, "/api/v1/settings/web"),
        .init(.get, "/api/v1/settings/access-auth"),
        .init(.get, "/api/v1/settings/export"),
        .init(.get, "/api/v1/settings/membership"),
        .init(.put, "/api/v1/settings/web"),
        .init(.put, "/api/v1/settings/export")
    ]

    let port: any DesktopWebSettingsPort

    /// 注册 7 条 Android Settings/NativeAction 路由；异步执行与取消继续交由端口实现收口。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/settings/web") { _, _ in
            try DesktopWebAPIResponse.success(try await port.webSettings())
        }

        router.get("/api/v1/settings/access-auth") { _, _ in
            try DesktopWebAPIResponse.success(await port.accessAuthSettings())
        }

        router.get("/api/v1/settings/export") { _, _ in
            try DesktopWebAPIResponse.success(try await port.exportSettings())
        }

        router.get("/api/v1/settings/membership") { _, _ in
            try DesktopWebAPIResponse.success(await port.membershipCapability())
        }

        router.put("/api/v1/settings/web") { request, context in
            let patch = try await request.decodeStrictJSON(as: DesktopWebJSONValue.self, context: context)
            do {
                try await port.updateWebSettings(patch)
                return try DesktopWebAPIResponse.success(nil as Bool?)
            } catch {
                return try DesktopWebAPIResponse.error(
                    code: 400,
                    message: "设置更新失败: \(error.localizedDescription)"
                )
            }
        }

        router.put("/api/v1/settings/export") { request, context in
            let patch = try await request.decodeStrictJSON(as: DesktopWebJSONValue.self, context: context)
            do {
                try await port.updateExportSettings(patch)
                return try DesktopWebAPIResponse.success(nil as Bool?)
            } catch {
                return try DesktopWebAPIResponse.error(
                    code: 400,
                    message: "导出设置更新失败: \(error.localizedDescription)"
                )
            }
        }

        router.post("/api/v1/native/actions/open-vip-upgrade") { _, _ in
            try DesktopWebAPIResponse.success(await port.openPremiumUpgrade())
        }
    }
}
