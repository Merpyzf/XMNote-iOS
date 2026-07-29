/**
 * [INPUT]: 依赖 Hummingbird Router、Android 兼容包络与 App 注入的 DesktopWebStatisticsPort
 * [OUTPUT]: 注册 StatisticsController 的 20 条统计、目标与图表路由
 * [POS]: XMNoteWeb 统计路由；只处理 Android v46 查询默认值、Int 边界和 JSON 解码
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Hummingbird

struct DesktopWebStatisticsRoutes: DesktopWebRouteCollection {
    static let definitions: Set<DesktopWebAPIRouteDefinition> = [
        .init(.get, "/api/v1/statistics/monthly-reading"),
        .init(.get, "/api/v1/statistics/weekly-reading"),
        .init(.get, "/api/v1/statistics/reading-rhythm"),
        .init(.get, "/api/v1/statistics/heatmap"),
        .init(.get, "/api/v1/statistics/overview"),
        .init(.get, "/api/v1/statistics/yearly-books"),
        .init(.get, "/api/v1/statistics/read-targets"),
        .init(.get, "/api/v1/statistics/read-target"),
        .init(.put, "/api/v1/statistics/read-target"),
        .init(.get, "/api/v1/statistics/yearly-goal-celebration"),
        .init(.put, "/api/v1/statistics/yearly-goal-celebration"),
        .init(.get, "/api/v1/statistics/daily-reading-target"),
        .init(.put, "/api/v1/statistics/daily-reading-target"),
        .init(.get, "/api/v1/statistics/chart/note-count"),
        .init(.get, "/api/v1/statistics/chart/read-done"),
        .init(.get, "/api/v1/statistics/chart/word-count"),
        .init(.get, "/api/v1/statistics/chart/purchase"),
        .init(.get, "/api/v1/statistics/chart/book-source"),
        .init(.get, "/api/v1/statistics/chart/note-tag"),
        .init(.get, "/api/v1/statistics/chart/book-tag")
    ]

    let port: any DesktopWebStatisticsPort

    /// 注册统计 HTTP 合同；空 weekStart 映射 nil，其余字符串不做 trim 或日期预校验。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/statistics/monthly-reading") { request, _ in
            let year = try Self.intQuery(request, "year")
            let month = try Self.intQuery(request, "month")
            return try DesktopWebAPIResponse.success(try await port.monthlyReading(year: year, month: month))
        }
        router.get("/api/v1/statistics/weekly-reading") { request, _ in
            return try DesktopWebAPIResponse.success(
                try await port.weeklyReading(weekStart: Self.weekStart(request))
            )
        }
        router.get("/api/v1/statistics/reading-rhythm") { request, _ in
            return try DesktopWebAPIResponse.success(
                try await port.readingRhythm(
                    year: Self.intQuery(request, "year"),
                    month: Self.intQuery(request, "month"),
                    weekStart: Self.weekStart(request)
                )
            )
        }
        router.get("/api/v1/statistics/heatmap") { request, _ in
            return try DesktopWebAPIResponse.success(
                try await port.heatmap(
                    year: Self.intQuery(request, "year"),
                    type: String(request.uri.queryParameters["type"] ?? "all")
                )
            )
        }
        router.get("/api/v1/statistics/overview") { request, _ in
            return try DesktopWebAPIResponse.success(
                try await port.statisticsOverview(
                    year: Self.intQuery(request, "year"),
                    month: Self.intQuery(request, "month"),
                    weekStart: Self.weekStart(request)
                )
            )
        }
        router.get("/api/v1/statistics/yearly-books") { request, _ in
            return try DesktopWebAPIResponse.success(
                try await port.yearlyBooks(year: Self.intQuery(request, "year"))
            )
        }
        router.get("/api/v1/statistics/read-targets") { _, _ in
            try DesktopWebAPIResponse.success(try await port.readTargets())
        }
        router.get("/api/v1/statistics/read-target") { request, _ in
            return try DesktopWebAPIResponse.success(
                try await port.readTarget(year: Self.intQuery(request, "year"))
            )
        }
        router.put("/api/v1/statistics/read-target") { request, context in
            let body = try await request.decodeStrictJSON(as: DesktopWebReadTargetRequest.self, context: context)
            return try DesktopWebAPIResponse.success(try await port.setReadTarget(body))
        }
        router.get("/api/v1/statistics/yearly-goal-celebration") { request, _ in
            return try DesktopWebAPIResponse.success(
                try await port.yearlyGoalCelebration(year: Self.intQuery(request, "year"))
            )
        }
        router.put("/api/v1/statistics/yearly-goal-celebration") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebYearlyGoalCelebrationRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(try await port.markYearlyGoalCelebration(body))
        }
        router.get("/api/v1/statistics/daily-reading-target") { _, _ in
            try DesktopWebAPIResponse.success(try await port.dailyReadingTarget())
        }
        router.put("/api/v1/statistics/daily-reading-target") { request, context in
            let body = try await request.decodeStrictJSON(
                as: DesktopWebDailyReadingTargetRequest.self,
                context: context
            )
            return try DesktopWebAPIResponse.success(try await port.setDailyReadingTarget(body))
        }

        registerChartRoutes(on: router)
    }

    private func registerChartRoutes(on router: Router<BasicRequestContext>) {
        router.get("/api/v1/statistics/chart/note-count") { request, _ in
            let scope = try Self.scope(request)
            return try DesktopWebAPIResponse.success(
                try await port.noteCountChart(year: scope.year, month: scope.month, weekStart: scope.weekStart)
            )
        }
        router.get("/api/v1/statistics/chart/read-done") { request, _ in
            let scope = try Self.scope(request)
            return try DesktopWebAPIResponse.success(
                try await port.readDoneChart(year: scope.year, month: scope.month, weekStart: scope.weekStart)
            )
        }
        router.get("/api/v1/statistics/chart/word-count") { request, _ in
            let scope = try Self.scope(request)
            return try DesktopWebAPIResponse.success(
                try await port.wordCountChart(year: scope.year, month: scope.month, weekStart: scope.weekStart)
            )
        }
        router.get("/api/v1/statistics/chart/purchase") { request, _ in
            let scope = try Self.scope(request)
            return try DesktopWebAPIResponse.success(
                try await port.purchaseChart(year: scope.year, month: scope.month, weekStart: scope.weekStart)
            )
        }
        router.get("/api/v1/statistics/chart/book-source") { request, _ in
            let scope = try Self.scope(request)
            return try DesktopWebAPIResponse.success(
                try await port.bookSourceChart(year: scope.year, month: scope.month, weekStart: scope.weekStart)
            )
        }
        router.get("/api/v1/statistics/chart/note-tag") { request, _ in
            let scope = try Self.scope(request)
            return try DesktopWebAPIResponse.success(
                try await port.noteTagChart(year: scope.year, month: scope.month, weekStart: scope.weekStart)
            )
        }
        router.get("/api/v1/statistics/chart/book-tag") { request, _ in
            let scope = try Self.scope(request)
            return try DesktopWebAPIResponse.success(
                try await port.bookTagChart(year: scope.year, month: scope.month, weekStart: scope.weekStart)
            )
        }
    }

    private static func scope(_ request: Request) throws -> (year: Int, month: Int, weekStart: String?) {
        (try intQuery(request, "year"), try intQuery(request, "month"), weekStart(request))
    }

    private static func weekStart(_ request: Request) -> String? {
        let value = String(request.uri.queryParameters["weekStart"] ?? "")
        return value.isEmpty ? nil : value
    }

    private static func intQuery(_ request: Request, _ key: String) throws -> Int {
        guard let raw = request.uri.queryParameters[Substring(key)] else { return 0 }
        guard let value = Int(raw), Int32(exactly: value) != nil else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "For input string: \"\(raw)\""
            )
        }
        return value
    }
}
