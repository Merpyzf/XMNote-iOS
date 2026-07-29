/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebStatisticsRoutes 与可观测 StatisticsPort stub
 * [OUTPUT]: 验证 StatisticsController 20 条 API 的默认值、参数透传、响应形状、错误包络与会员写门禁
 * [POS]: XMNoteWeb Package 统计路由单元测试，锁定 Android v46 StatisticsController HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebStatisticsRoutesTests {
    @Test
    func readEndpointsApplyAndroidDefaultsAndEncodeAllResponseFamilies() async throws {
        let port = StatisticsPortStub()
        try await withStatisticsAPI(port: port) { client in
            let cases: [(String, (TestResponse) throws -> Void)] = [
                ("/api/v1/statistics/monthly-reading", { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["label"] as? String == "2026年7月")
                }),
                ("/api/v1/statistics/weekly-reading", { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["currentStreak"] as? Int == 2)
                }),
                ("/api/v1/statistics/reading-rhythm", { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["peakSegmentIds"] as? [String] == ["night"])
                }),
                ("/api/v1/statistics/heatmap", { response in
                    let data = try statisticsDataObject(response)
                    #expect((data["days"] as? [[String: Any]])?.first?["level"] as? Int == 3)
                }),
                ("/api/v1/statistics/overview", { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["readingTimeTrendUnit"] as? String == "month")
                }),
                ("/api/v1/statistics/yearly-books", { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["totalCount"] as? Int == 0)
                }),
                ("/api/v1/statistics/read-targets", { response in
                    let data = try #require(statisticsEnvelope(response)["data"] as? [[String: Any]])
                    #expect(data.first?["target"] as? Int == 12)
                }),
                ("/api/v1/statistics/read-target", { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["year"] as? Int == 2026)
                }),
                ("/api/v1/statistics/yearly-goal-celebration", { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["shown"] as? Bool == false)
                }),
                ("/api/v1/statistics/daily-reading-target", { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["todayReadingTime"] as? Int == 300)
                })
            ]
            for (uri, assertion) in cases {
                try await client.execute(uri: uri, method: .get) { response in
                    try assertion(response)
                }
            }
        }

        let calls = await port.calls
        #expect(calls.contains("monthly:0:0"))
        #expect(calls.contains("weekly:nil"))
        #expect(calls.contains("rhythm:0:0:nil"))
        #expect(calls.contains("heatmap:0:all"))
        #expect(calls.contains("overview:0:0:nil"))
        #expect(calls.contains("yearly:0"))
        #expect(calls.contains("target:0"))
        #expect(calls.contains("celebration:0"))
    }

    @Test
    func chartEndpointsForwardTheSameScopeAndPreserveFloatPayloads() async throws {
        let port = StatisticsPortStub()
        try await withStatisticsAPI(port: port) { client in
            let paths = ["note-count", "read-done", "word-count"]
            for path in paths {
                try await client.execute(
                    uri: "/api/v1/statistics/chart/\(path)?year=2025&month=12&weekStart=2025-12-29",
                    method: .get
                ) { response in
                    let data = try statisticsDataObject(response)
                    #expect(data["scope"] as? String == "week")
                    #expect((data["items"] as? [[String: Any]])?.first?["value"] as? Int == 7)
                }
            }
            try await client.execute(
                uri: "/api/v1/statistics/chart/purchase?year=2025&month=12&weekStart=2025-12-29",
                method: .get
            ) { response in
                let data = try statisticsDataObject(response)
                #expect((data["totalMoney"] as? NSNumber)?.floatValue == 12.5)
                #expect(data["totalCount"] as? Int == 2)
            }
            for path in ["book-source", "note-tag", "book-tag"] {
                try await client.execute(
                    uri: "/api/v1/statistics/chart/\(path)?year=2025&month=12&weekStart=2025-12-29",
                    method: .get
                ) { response in
                    let data = try #require(statisticsEnvelope(response)["data"] as? [[String: Any]])
                    #expect(data.first?["label"] as? String == "分类")
                    #expect((data.first?["ratio"] as? NSNumber)?.floatValue == 0.5)
                }
            }
        }

        let calls = await port.calls.filter { $0.contains("2025:12:2025-12-29") }
        #expect(calls.count == 7)
    }

    @Test
    func explicitValuesAndEmptyWeekStartAreForwardedWithoutExtraValidation() async throws {
        let port = StatisticsPortStub()
        try await withStatisticsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/statistics/monthly-reading?year=-1&month=13",
                method: .get
            ) { response in
                let envelope = try statisticsEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/statistics/weekly-reading?weekStart=",
                method: .get
            ) { response in
                let envelope = try statisticsEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
            try await client.execute(
                uri: "/api/v1/statistics/heatmap?year=-2&type=custom",
                method: .get
            ) { response in
                let envelope = try statisticsEnvelope(response)
                #expect(envelope["code"] as? Int == 200)
            }
        }
        let calls = await port.calls
        #expect(calls.contains("monthly:-1:13"))
        #expect(calls.contains("weekly:nil"))
        #expect(calls.contains("heatmap:-2:custom"))
    }

    @Test
    func malformedInt32QueriesFailBeforeCallingPort() async throws {
        let port = StatisticsPortStub()
        try await withStatisticsAPI(port: port) { client in
            for (uri, value) in [
                ("/api/v1/statistics/monthly-reading?year=bad", "bad"),
                ("/api/v1/statistics/overview?month=2147483648", "2147483648"),
                ("/api/v1/statistics/chart/note-count?year=1.5", "1.5")
            ] {
                try await client.execute(uri: uri, method: .get) { response in
                    let envelope = try statisticsEnvelope(response)
                    #expect(envelope["code"] as? Int == 40001)
                    #expect(envelope["msg"] as? String == "For input string: \"\(value)\"")
                }
            }
        }
        #expect(await port.calls.isEmpty)
    }

    @Test
    func writeBodiesReachPortAndReadOnlyGateKeepsAndroidCelebrationWhitelist() async throws {
        let writable = StatisticsPortStub()
        try await withStatisticsAPI(port: writable) { client in
            let writes: [(String, String)] = [
                ("/api/v1/statistics/read-target", #"{"year":2026,"target":18}"#),
                ("/api/v1/statistics/yearly-goal-celebration", #"{"year":2026}"#),
                ("/api/v1/statistics/daily-reading-target", #"{"target":0}"#)
            ]
            for (uri, body) in writes {
                try await client.execute(
                    uri: uri,
                    method: .put,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: body)
                ) { response in
                    let envelope = try statisticsEnvelope(response)
                    #expect(envelope["code"] as? Int == 200)
                }
            }
        }
        #expect(await writable.calls.contains("set-target:2026:18"))
        #expect(await writable.calls.contains("mark-celebration:2026"))
        #expect(await writable.calls.contains("set-daily:0"))

        let blocked = StatisticsPortStub()
        try await withStatisticsAPI(
            port: blocked,
            gate: StatisticsGateStub(isReadOnly: true)
        ) { client in
            for (uri, body, expectedCode) in [
                ("/api/v1/statistics/read-target", #"{"year":2026,"target":18}"#, 40009),
                ("/api/v1/statistics/yearly-goal-celebration", #"{"year":2026}"#, 200),
                ("/api/v1/statistics/daily-reading-target", #"{"target":60}"#, 40009)
            ] {
                try await client.execute(
                    uri: uri,
                    method: .put,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: body)
                ) { response in
                    let envelope = try statisticsEnvelope(response)
                    #expect(envelope["code"] as? Int == expectedCode)
                }
            }
        }
        #expect(await blocked.calls == ["mark-celebration:2026"])
    }

    @Test
    func malformedBodyAndBusinessFailureUseAndroidEnvelope() async throws {
        let port = StatisticsPortStub()
        await port.setFailure(DesktopWebAPIError(code: 40001, message: "年份必须大于 0"))
        try await withStatisticsAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/statistics/read-target",
                method: .put,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"year":"bad"}"#)
            ) { response in
                let envelope = try statisticsEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
            }
            try await client.execute(
                uri: "/api/v1/statistics/yearly-goal-celebration?year=0",
                method: .get
            ) { response in
                let envelope = try statisticsEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "年份必须大于 0")
            }
        }
        #expect(await port.calls == ["celebration:0"])
    }

    private func withStatisticsAPI(
        port: StatisticsPortStub,
        gate: StatisticsGateStub = StatisticsGateStub(isReadOnly: false),
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(requestGate: gate, statistics: port)
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebStatisticsRoutes.definitions)
        )
        DesktopWebStatisticsRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private actor StatisticsGateStub: DesktopWebRequestGatePort {
    let isReadOnly: Bool

    init(isReadOnly: Bool) { self.isReadOnly = isReadOnly }

    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { isReadOnly }
}

private actor StatisticsPortStub: DesktopWebStatisticsPort {
    private(set) var calls: [String] = []
    private var failure: Error?

    func setFailure(_ failure: Error) { self.failure = failure }

    func monthlyReading(year: Int, month: Int) async throws -> DesktopWebMonthlyReading {
        try record("monthly:\(year):\(month)")
        return .init(
            year: 2026, month: 7, label: "2026年7月", totalReadTime: 60, daysInMonth: 31,
            dailyReadingTimes: [.init(day: 23, date: "2026-07-23", readTime: 60)]
        )
    }

    func weeklyReading(weekStart: String?) async throws -> DesktopWebWeeklyReading {
        try record("weekly:\(weekStart ?? "nil")")
        return .init(
            totalReadTime: 60, weekStart: "2026-07-20", weekEnd: "2026-07-26",
            days: [.init(dayOfWeek: 4, date: "2026-07-23", readTime: 60, hasReading: true)],
            currentStreak: 2
        )
    }

    func readingRhythm(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebReadingRhythm {
        try record("rhythm:\(year):\(month):\(weekStart ?? "nil")")
        return .init(
            totalReadTime: 60,
            segments: [.init(id: "night", label: "夜晚", startHour: 21, endHour: 24, readTime: 60, ratio: 1)],
            peakSegmentIds: ["night"], rhythmType: "night_reader", rhythmLabel: "夜读者",
            rhythmDescription: "描述", mostFrequentTime: "21:05", hasTimedData: true,
            scopeTotalReadTime: 60, accurateReadTime: 60, fuzzyReadTime: 0
        )
    }

    func heatmap(year: Int, type: String) async throws -> DesktopWebHeatmap {
        try record("heatmap:\(year):\(type)")
        return .init(
            days: [.init(date: "2026-07-23", readTime: 3600, noteCount: 1, checkInTime: 0, bookStates: [true, false, false, false, false], level: 3)],
            startDate: "2026-01-01", endDate: "2026-12-31", yearRange: [2026],
            earliestDate: "2026-01-01", latestDate: "2026-07-23"
        )
    }

    func statisticsOverview(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebStatisticsOverview {
        try record("overview:\(year):\(month):\(weekStart ?? "nil")")
        return .init(
            totalReadingTime: 60, readingDays: 1, noteCount: 1, readDoneBookCount: 1,
            totalWordCount: 100, purchaseBookCount: 1,
            statusDistribution: [.init(status: 3, label: "读完", count: 1, ratio: 1)],
            readingTimeTrend: [.init(label: 7, value: 60)], readingTimeTrendUnit: "month",
            comparison: nil
        )
    }

    func yearlyBooks(year: Int) async throws -> DesktopWebYearlyBooks {
        try record("yearly:\(year)")
        return .init(year: 2026, books: [], totalCount: 0, yearRange: [2026])
    }

    func readTargets() async throws -> [DesktopWebReadTarget] {
        try record("targets")
        return [.init(year: 2026, target: 12)]
    }

    func readTarget(year: Int) async throws -> DesktopWebReadTarget {
        try record("target:\(year)")
        return .init(year: year == 0 ? 2026 : year, target: 12)
    }

    func setReadTarget(_ request: DesktopWebReadTargetRequest) async throws -> DesktopWebReadTarget {
        try record("set-target:\(request.year):\(request.target)")
        return .init(year: request.year, target: request.target)
    }

    func yearlyGoalCelebration(year: Int) async throws -> DesktopWebYearlyGoalCelebration {
        try record("celebration:\(year)")
        return .init(year: year, shown: false)
    }

    func markYearlyGoalCelebration(_ request: DesktopWebYearlyGoalCelebrationRequest) async throws -> DesktopWebYearlyGoalCelebration {
        try record("mark-celebration:\(request.year)")
        return .init(year: request.year, shown: true)
    }

    func dailyReadingTarget() async throws -> DesktopWebDailyReadingTarget {
        try record("daily")
        return .init(target: 3_600, todayReadingTime: 300)
    }

    func setDailyReadingTarget(_ request: DesktopWebDailyReadingTargetRequest) async throws -> DesktopWebDailyReadingTarget {
        try record("set-daily:\(request.target)")
        return .init(target: request.target, todayReadingTime: 300)
    }

    func noteCountChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData {
        try chart("note", year, month, weekStart)
    }

    func readDoneChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData {
        try chart("done", year, month, weekStart)
    }

    func wordCountChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData {
        try chart("word", year, month, weekStart)
    }

    func purchaseChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebPurchaseChart {
        try record("purchase:\(year):\(month):\(weekStart ?? "nil")")
        return .init(
            unit: "month", totalMoney: 12.5, totalCount: 2,
            items: [.init(label: 12, value: 12)], countItems: [.init(label: 12, value: 2)],
            scope: "week", scopeLabel: "本周"
        )
    }

    func bookSourceChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem] {
        try pie("source", year, month, weekStart)
    }

    func noteTagChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem] {
        try pie("note-tag", year, month, weekStart)
    }

    func bookTagChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem] {
        try pie("book-tag", year, month, weekStart)
    }

    private func record(_ call: String) throws {
        calls.append(call)
        if let failure { throw failure }
    }

    private func chart(_ name: String, _ year: Int, _ month: Int, _ weekStart: String?) throws -> DesktopWebChartData {
        try record("\(name):\(year):\(month):\(weekStart ?? "nil")")
        return .init(
            unit: "day", total: "7", items: [.init(label: 1, value: 7)],
            scope: "week", scopeLabel: "本周"
        )
    }

    private func pie(_ name: String, _ year: Int, _ month: Int, _ weekStart: String?) throws -> [DesktopWebPieItem] {
        try record("\(name):\(year):\(month):\(weekStart ?? "nil")")
        return [.init(label: "分类", count: 1, ratio: 0.5, scope: "week", scopeLabel: "本周")]
    }
}

private func statisticsEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
}

private func statisticsDataObject(_ response: TestResponse) throws -> [String: Any] {
    try #require(try statisticsEnvelope(response)["data"] as? [String: Any])
}
