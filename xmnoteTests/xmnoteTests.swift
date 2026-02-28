//
//  xmnoteTests.swift
//  xmnoteTests
//
//  Created by 王珂 on 2026/2/9.
//

import Testing
import Foundation
@testable import xmnote

struct xmnoteTests {

    @Test func serializerCombinedParagraphWithBulletThenQuote() {
        let original = HTMLSerializer.comboParagraphOrderStrategy
        defer { HTMLSerializer.comboParagraphOrderStrategy = original }

        HTMLSerializer.comboParagraphOrderStrategy = .bulletThenQuote
        let attributed = HTMLParser.parse("<ul><li><blockquote>组合段落</blockquote></li></ul>")
        let html = HTMLSerializer.serialize(attributed)
        #expect(html == "<ul><li><blockquote>组合段落</blockquote></li></ul>")
    }

    @Test func serializerCombinedParagraphWithQuoteThenBullet() {
        let original = HTMLSerializer.comboParagraphOrderStrategy
        defer { HTMLSerializer.comboParagraphOrderStrategy = original }

        HTMLSerializer.comboParagraphOrderStrategy = .quoteThenBullet
        let attributed = HTMLParser.parse("<ul><li><blockquote>组合段落</blockquote></li></ul>")
        let html = HTMLSerializer.serialize(attributed)
        #expect(html == "<blockquote><ul><li>组合段落</li></ul></blockquote>")
    }

    @Test func richTextBridgeRemovesAndroidZWJPrefix() {
        let attributed = RichTextBridge.htmlToAttributed("&zwj;<b>Android</b> 兼容")
        #expect(attributed.string == "Android 兼容")
    }

    @Test func heatmapLevelFromCheckInSecondsThresholds() {
        #expect(HeatmapLevel.from(checkInSeconds: 0) == .none)
        #expect(HeatmapLevel.from(checkInSeconds: 1) == .veryLess)
        #expect(HeatmapLevel.from(checkInSeconds: 1200) == .veryLess)
        #expect(HeatmapLevel.from(checkInSeconds: 1201) == .less)
        #expect(HeatmapLevel.from(checkInSeconds: 2400) == .less)
        #expect(HeatmapLevel.from(checkInSeconds: 2401) == .more)
        #expect(HeatmapLevel.from(checkInSeconds: 3600) == .more)
        #expect(HeatmapLevel.from(checkInSeconds: 3601) == .veryMore)
    }

    @Test func heatmapDayLevelIncludesCheckInActivity() {
        let day = HeatmapDay(
            id: Date(timeIntervalSince1970: 0),
            readSeconds: 0,
            noteCount: 0,
            checkInCount: 1,
            checkInSeconds: 20 * 60
        )
        #expect(day.level == .veryLess)
    }

    @Test func heatmapDayLevelPicksMaxAcrossThreeSources() {
        let day = HeatmapDay(
            id: Date(timeIntervalSince1970: 0),
            readSeconds: 500,
            noteCount: 8,
            checkInCount: 3,
            checkInSeconds: 5000
        )
        #expect(day.level == .veryMore)
    }

    @Test func readCalendarCrossWeekSegmentsKeepContinuityFlagsAndLane() {
        let calendar = Self.mondayCalendar
        let dates = [
            Self.date(2026, 3, 29, calendar: calendar), // 周日
            Self.date(2026, 3, 30, calendar: calendar), // 周一
            Self.date(2026, 3, 31, calendar: calendar)
        ]
        let days = Dictionary(uniqueKeysWithValues: dates.enumerated().map { index, date in
            (calendar.startOfDay(for: date), ReadCalendarDay(
                date: date,
                books: [
                    ReadCalendarDayBook(
                        id: 1,
                        name: "SwiftUI 设计",
                        coverURL: "",
                        firstEventTime: Int64(1000 + index)
                    )
                ],
                readDoneCount: 0
            ))
        })

        let engine = ReadCalendarEventLayoutEngine(calendar: calendar, mode: .crossWeekContinuous)
        let layouts = engine.buildWeekLayouts(days: days)
        #expect(layouts.count == 2)

        let allSegments = layouts.flatMap(\.segments).filter { $0.bookId == 1 }.sorted {
            $0.segmentStartDate < $1.segmentStartDate
        }
        #expect(allSegments.count == 2)
        #expect(allSegments[0].continuesToNextWeek == true)
        #expect(allSegments[1].continuesFromPrevWeek == true)
        #expect(allSegments[0].laneIndex == allSegments[1].laneIndex)
    }

    @Test func readCalendarAndroidCompatibleDisablesCrossWeekConnectorFlags() {
        let calendar = Self.mondayCalendar
        let dates = [
            Self.date(2026, 3, 29, calendar: calendar),
            Self.date(2026, 3, 30, calendar: calendar)
        ]
        let days = Dictionary(uniqueKeysWithValues: dates.map { date in
            (calendar.startOfDay(for: date), ReadCalendarDay(
                date: date,
                books: [
                    ReadCalendarDayBook(id: 7, name: "iOS 架构", coverURL: "", firstEventTime: 1)
                ],
                readDoneCount: 0
            ))
        })

        let engine = ReadCalendarEventLayoutEngine(calendar: calendar, mode: .androidCompatible)
        let layouts = engine.buildWeekLayouts(days: days)
        let segments = layouts.flatMap(\.segments)
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { !$0.continuesFromPrevWeek && !$0.continuesToNextWeek })
    }

    @Test func readCalendarBuildRunsMergesNaturalContinuousDates() {
        let calendar = Self.mondayCalendar
        let d1 = Self.date(2026, 2, 10, calendar: calendar)
        let d2 = Self.date(2026, 2, 11, calendar: calendar)
        let d3 = Self.date(2026, 2, 13, calendar: calendar)

        let days: [Date: ReadCalendarDay] = [
            calendar.startOfDay(for: d1): ReadCalendarDay(
                date: d1,
                books: [ReadCalendarDayBook(id: 2, name: "算法", coverURL: "", firstEventTime: 1)],
                readDoneCount: 0
            ),
            calendar.startOfDay(for: d2): ReadCalendarDay(
                date: d2,
                books: [ReadCalendarDayBook(id: 2, name: "算法", coverURL: "", firstEventTime: 2)],
                readDoneCount: 0
            ),
            calendar.startOfDay(for: d3): ReadCalendarDay(
                date: d3,
                books: [ReadCalendarDayBook(id: 2, name: "算法", coverURL: "", firstEventTime: 3)],
                readDoneCount: 0
            )
        ]

        let engine = ReadCalendarEventLayoutEngine(calendar: calendar, mode: .crossWeekContinuous)
        let runs = engine.buildRuns(days: days).filter { $0.bookId == 2 }.sorted { $0.startDate < $1.startDate }
        #expect(runs.count == 2)
        #expect(calendar.isDate(runs[0].startDate, inSameDayAs: d1))
        #expect(calendar.isDate(runs[0].endDate, inSameDayAs: d2))
        #expect(calendar.isDate(runs[1].startDate, inSameDayAs: d3))
        #expect(calendar.isDate(runs[1].endDate, inSameDayAs: d3))
    }

    @Test func readCalendarRunKeepsStableLaneAcrossWeeks() {
        let calendar = Self.mondayCalendar
        let dates = [
            Self.date(2026, 3, 25, calendar: calendar),
            Self.date(2026, 3, 26, calendar: calendar),
            Self.date(2026, 3, 27, calendar: calendar),
            Self.date(2026, 3, 30, calendar: calendar),
            Self.date(2026, 3, 31, calendar: calendar)
        ]
        let days = Dictionary(uniqueKeysWithValues: dates.enumerated().map { index, date in
            (calendar.startOfDay(for: date), ReadCalendarDay(
                date: date,
                books: [ReadCalendarDayBook(id: 10, name: "系统设计", coverURL: "", firstEventTime: Int64(index + 1))],
                readDoneCount: 0
            ))
        })

        let engine = ReadCalendarEventLayoutEngine(calendar: calendar, mode: .crossWeekContinuous)
        let layouts = engine.buildWeekLayouts(days: days)
        let segments = layouts.flatMap(\.segments).filter { $0.bookId == 10 }
        #expect(segments.count == 2)
        #expect(Set(segments.map(\.laneIndex)).count == 1)
    }
}

private extension xmnoteTests {
    static var mondayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
