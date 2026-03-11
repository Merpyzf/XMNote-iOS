import CoreGraphics
import Testing
@testable import xmnote

@MainActor
struct ReadingDashboardFormattingTests {
    @Test
    func durationDisplayBuildsNumberAndUnitSegments() {
        let display = ReadingDashboardFormatting.durationDisplay(seconds: 80)

        #expect(display.segments.map(\.text) == ["1", " 分钟", "20", " 秒"])
        #expect(display.segments.map(\.role) == [.number, .unit, .number, .unit])
    }

    @Test
    func durationDisplayKeepsHourMinuteAndDropsSecondsWhenHourExists() {
        let display = ReadingDashboardFormatting.durationDisplay(seconds: 3_665)

        #expect(display.segments.map(\.text) == ["1", " 小时", "1", " 分钟"])
    }

    @Test
    func metricValueDisplayKeepsSingleSuffixForCountMetrics() {
        let metric = ReadingTrendMetric(
            kind: .noteCount,
            title: "书摘数量",
            totalValue: 12,
            points: []
        )

        let display = ReadingDashboardFormatting.metricValueDisplay(metric: metric)
        #expect(display.segments.map(\.text) == ["12", " 条"])
    }

    @Test
    func displayedBarRatiosLiftSmallNonZeroValuesButKeepZeroAtZero() {
        let points = [
            ReadingTrendMetric.Point(id: "a", label: "A", value: 100),
            ReadingTrendMetric.Point(id: "b", label: "B", value: 3),
            ReadingTrendMetric.Point(id: "c", label: "C", value: 1),
            ReadingTrendMetric.Point(id: "d", label: "D", value: 0)
        ]

        let ratios = ReadingDashboardFormatting.displayedBarRatios(points: points, chartHeight: 40)

        #expect(ratios[0] == 1)
        #expect(ratios[1] > 0.03)
        #expect(ratios[2] > 0.01)
        #expect(ratios[1] > ratios[2])
        #expect(ratios[3] == 0)
    }

    @Test
    func displayedBarRatiosReturnAllZeroWhenDatasetIsEmptyOrZero() {
        let emptyRatios = ReadingDashboardFormatting.displayedBarRatios(points: [], chartHeight: 40)
        #expect(emptyRatios.isEmpty)

        let zeroPoints = [
            ReadingTrendMetric.Point(id: "a", label: "A", value: 0),
            ReadingTrendMetric.Point(id: "b", label: "B", value: 0)
        ]
        let zeroRatios = ReadingDashboardFormatting.displayedBarRatios(points: zeroPoints, chartHeight: 40)
        #expect(zeroRatios == [0, 0])
    }
}
