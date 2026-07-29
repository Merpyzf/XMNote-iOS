/**
 * [INPUT]: 依赖 HummingbirdTesting、DesktopWebCalendarRoutes 与可观测 CalendarPort stub
 * [OUTPUT]: 验证 2 条阅读日历 API 的必填毫秒参数、响应形状与只读门禁
 * [POS]: XMNoteWeb Package 阅读日历路由单元测试，锁定 Android CalendarController HTTP 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import XMNoteWeb

struct DesktopWebCalendarRoutesTests {
    @Test
    func monthPassesRequiredInt64AndReturnsEveryCalendarField() async throws {
        let port = CalendarPortStub()
        try await withCalendarAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/calendar/month?month=-1",
                method: .get
            ) { response in
                let data = try calendarDataObject(response)
                #expect(data["year"] as? Int == 2026)
                #expect(data["month"] as? Int == 7)
                #expect(data["startDayOfWeek"] as? Int == 2)
                #expect(data["totalDays"] as? Int == 31)
                let days = try #require(data["days"] as? [[String: Any]])
                #expect(days.first?["hasActivity"] as? Bool == true)
                let books = try #require(days.first?["books"] as? [[String: Any]])
                #expect(books.first?["isContinuation"] as? Bool == false)
                #expect(books.first?["cover"] == nil)
                #expect(books.first?["author"] == nil)
            }
        }
        #expect(await port.monthMillis == -1)
    }

    @Test
    func dayPassesRequiredInt64AndReturnsAggregateShape() async throws {
        let port = CalendarPortStub()
        try await withCalendarAPI(port: port) { client in
            try await client.execute(
                uri: "/api/v1/calendar/day?date=9223372036854775807",
                method: .get
            ) { response in
                let data = try calendarDataObject(response)
                #expect(data["date"] as? String == "2026-07-23")
                #expect(data["totalReadingTime"] as? Int == 90)
                #expect(data["totalNoteCount"] as? Int == 2)
                let details = try #require(data["details"] as? [[String: Any]])
                #expect(details.first?["readingTime"] as? Int == 90)
                #expect(details.first?["isReadDoneInToday"] as? Bool == true)
            }
        }
        #expect(await port.dayMillis == Int64.max)
    }

    @Test
    func requiredLongQueryMatchesAndroidFormAndErrorBoundaries() async throws {
        let port = CalendarPortStub()
        try await withCalendarAPI(port: port) { client in
            try await client.execute(uri: "/api/v1/calendar/month", method: .get) { response in
                let envelope = try calendarEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(
                    envelope["msg"] as? String
                        == "Missing param [month] for method parameter."
                )
            }
            try await client.execute(
                uri: "/api/v1/calendar/day?date=1.5",
                method: .get
            ) { response in
                let envelope = try calendarEnvelope(response)
                #expect(envelope["code"] as? Int == 40001)
                #expect(envelope["msg"] as? String == "For input string: \"1.5\"")
            }
            try await client.execute(
                uri: "/api/v1/calendar/month?month=9223372036854775808",
                method: .get
            ) { response in
                let envelope = try calendarEnvelope(response)
                #expect(envelope["msg"] as? String == "For input string: \"9223372036854775808\"")
            }
            try await client.execute(
                uri: "/api/v1/calendar/month?month=+1",
                method: .get
            ) { response in
                let envelope = try calendarEnvelope(response)
                #expect(envelope["msg"] as? String == "For input string: \" 1\"")
            }
            try await client.execute(
                uri: "/api/v1/calendar/month?month=1&month=2",
                method: .get
            ) { response in
                let envelope = try calendarEnvelope(response)
                #expect(envelope["msg"] as? String == "For input string: \"1month=2\"")
            }
            try await client.execute(
                uri: "/api/v1/calendar/day?date=%2B1",
                method: .get
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/api/v1/calendar/day?date&date=2",
                method: .get
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(await port.monthMillis == nil)
        #expect(await port.dayMillis == 2)
    }

    private func withCalendarAPI(
        port: CalendarPortStub,
        test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        let router = Router()
        let dependencies = DesktopWebAPIDependencies(
            requestGate: CalendarGateStub(),
            calendar: port
        )
        DesktopWebAPIMiddleware.install(
            on: router,
            dependencies: dependencies,
            routeMatcher: DesktopWebAPIRouteMatcher(routes: DesktopWebCalendarRoutes.definitions)
        )
        DesktopWebCalendarRoutes(port: port).register(on: router)
        try await Application(responder: router.buildResponder()).test(.router, test)
    }
}

private actor CalendarGateStub: DesktopWebRequestGatePort {
    func isAccessAuthorized(_ accessCode: String?) async -> Bool { true }
    func isDesktopReadOnly() async -> Bool { true }
}

private actor CalendarPortStub: DesktopWebCalendarPort {
    private(set) var monthMillis: Int64?
    private(set) var dayMillis: Int64?

    func calendarMonth(monthMillis: Int64) async throws -> DesktopWebCalendarMonth {
        self.monthMillis = monthMillis
        return DesktopWebCalendarMonth(
            year: 2026,
            month: 7,
            days: [
                DesktopWebCalendarDay(
                    dayOfMonth: 23,
                    date: "2026-07-23",
                    books: [
                        DesktopWebCalendarBook(
                            id: 1,
                            name: "日历",
                            cover: nil,
                            author: nil,
                            isContinuation: false
                        )
                    ],
                    readDoneBookCount: 1,
                    hasActivity: true
                )
            ],
            startDayOfWeek: 2,
            totalDays: 31
        )
    }

    func calendarDay(dateMillis: Int64) async throws -> DesktopWebDailyReadingSummary {
        self.dayMillis = dateMillis
        let book = DesktopWebCalendarBook(
            id: 1,
            name: "日历",
            cover: "",
            author: "作者",
            isContinuation: false
        )
        return DesktopWebDailyReadingSummary(
            date: "2026-07-23",
            details: [
                DesktopWebDailyReadingDetail(
                    book: book,
                    readingTime: 90,
                    noteCount: 2,
                    reviewCount: 1,
                    checkInCount: 1,
                    isReadDoneInToday: true
                )
            ],
            totalReadingTime: 90,
            totalNoteCount: 2
        )
    }
}

private func calendarEnvelope(_ response: TestResponse) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
    )
}

private func calendarDataObject(_ response: TestResponse) throws -> [String: Any] {
    try #require(try calendarEnvelope(response)["data"] as? [String: Any])
}
