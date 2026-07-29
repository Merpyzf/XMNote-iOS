/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebCalendarPort
 * [OUTPUT]: 注册阅读日历月视图与单日汇总共 2 条 GET 路由
 * [POS]: XMNoteWeb 阅读日历业务路由；只解析必填毫秒时间戳，不访问 App 数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

struct DesktopWebCalendarRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/calendar/month"),
        .init(.get, "/api/v1/calendar/day")
    ]

    let port: any DesktopWebCalendarPort

    /// 注册 Android CalendarController 两条只读路由，必填参数错误统一进入 40001 包络。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/calendar/month") { request, _ in
            // TODO(ANDROID-WEB-091): Android 暴露 Java Long 解析文本并异常拼接重复参数；基线收敛前保留该兼容语义。
            try DesktopWebAPIResponse.success(
                try await port.calendarMonth(
                    monthMillis: try DesktopWebAndroidFormQuery.requiredInt64(
                        named: "month",
                        in: request
                    )
                )
            )
        }

        router.get("/api/v1/calendar/day") { request, _ in
            // TODO(ANDROID-WEB-091): 与 month 保持相同的 AndServer 必填 Long 参数合同。
            try DesktopWebAPIResponse.success(
                try await port.calendarDay(
                    dateMillis: try DesktopWebAndroidFormQuery.requiredInt64(
                        named: "date",
                        in: request
                    )
                )
            )
        }
    }
}
