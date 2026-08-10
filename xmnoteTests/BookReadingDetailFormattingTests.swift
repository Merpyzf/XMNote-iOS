import Foundation
import Testing
@testable import xmnote

struct BookReadingDetailFormattingTests {
    @Test
    func smartDateMatchesAndroidRelativeAndCalendarYearRules() {
        let reference = Self.date(2026, 8, 10, hour: 12)

        #expect(Self.smartDate(Self.date(2026, 8, 10), relativeTo: reference) == "今天")
        #expect(Self.smartDate(Self.date(2026, 8, 9), relativeTo: reference) == "昨天")
        #expect(Self.smartDate(Self.date(2026, 8, 8), relativeTo: reference) == "前天")
        #expect(Self.smartDate(Self.date(2026, 7, 12), relativeTo: reference) == "7月12日")
        #expect(Self.smartDate(Self.date(2025, 12, 31), relativeTo: reference) == "2025年12月31日")
    }

    @Test
    func compactDurationDropsLowerUnitsExactlyLikeAndroid() {
        #expect(Self.durationTexts(0) == ["0", "秒"])
        #expect(Self.durationTexts(59) == ["59", "秒"])
        #expect(Self.durationTexts(60) == ["1", "分钟"])
        #expect(Self.durationTexts(3_599) == ["59", "分钟"])
        #expect(Self.durationTexts(3_600) == ["1", "小时"])
        #expect(Self.durationTexts(3_660) == ["1", "小时", "1", "分钟"])
        #expect(Self.durationTexts(3_605) == ["1", "小时"])
    }

    @Test
    func monthAndDayLabelsMatchAndroidReadingDetail() {
        let reference = Self.date(2026, 8, 10)

        #expect(
            BookReadingDetailFormatting.monthSummary(
                year: 2026,
                month: 7,
                seconds: 10_200,
                relativeTo: reference,
                calendar: Self.calendar
            ) == "7月 · 2小时50分钟"
        )
        #expect(
            BookReadingDetailFormatting.monthSummary(
                year: 2025,
                month: 12,
                seconds: 60,
                relativeTo: reference,
                calendar: Self.calendar
            ) == "2025年12月 · 1分钟"
        )
        #expect(
            BookReadingDetailFormatting.dayLabel(
                Self.date(2026, 7, 12),
                calendar: Self.calendar
            ) == "12日"
        )
    }
}

private extension BookReadingDetailFormattingTests {
    static func smartDate(_ date: Date, relativeTo reference: Date) -> String {
        BookReadingDetailFormatting.smartDate(
            date,
            relativeTo: reference,
            calendar: calendar
        )
    }

    static func durationTexts(_ seconds: Int64) -> [String] {
        BookReadingDetailFormatting.compactDurationParts(seconds).map(\.text)
    }

    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }()
}
