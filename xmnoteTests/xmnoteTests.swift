//
//  xmnoteTests.swift
//  xmnoteTests
//
//  Created by 王珂 on 2026/2/9.
//

import Testing
import Foundation
import UIKit
@testable import xmnote

struct xmnoteTests {

    @Test func richTextAttributedCacheReusesParsedContentAcrossExpandStateChanges() {
        RichText.testingResetCaches()

        let contentKey = RichText.testingContentCacheKey(
            html: "<b>缓存</b>命中",
            baseFont: .systemFont(ofSize: 16),
            textColor: .label,
            lineSpacing: 4,
            traitCollection: UITraitCollection(userInterfaceStyle: .light)
        )

        var buildCount = 0
        _ = RichText.testingResolveAttributedString(contentKey: contentKey) {
            buildCount += 1
            return NSAttributedString(string: "缓存命中")
        }
        _ = RichText.testingResolveAttributedString(contentKey: contentKey) {
            buildCount += 1
            return NSAttributedString(string: "缓存命中")
        }

        #expect(buildCount == 1)
    }

    @Test func richTextLayoutCacheKeyBucketsEquivalentWidths() {
        let contentKey = RichText.testingContentCacheKey(
            html: "宽度桶",
            baseFont: .systemFont(ofSize: 15),
            textColor: .label,
            lineSpacing: 4,
            traitCollection: UITraitCollection(userInterfaceStyle: .light)
        )

        let first = RichText.testingLayoutCacheKey(
            contentKey: contentKey,
            maxLines: 3,
            width: 123.24,
            screenScale: 2
        )
        let second = RichText.testingLayoutCacheKey(
            contentKey: contentKey,
            maxLines: 3,
            width: 123.249,
            screenScale: 2
        )
        let third = RichText.testingLayoutCacheKey(
            contentKey: contentKey,
            maxLines: 3,
            width: 123.76,
            screenScale: 2
        )

        #expect(first == second)
        #expect(first != third)
    }

    @Test func richTextLayoutCacheSeparatesCollapsedAndExpandedSnapshots() {
        RichText.testingResetCaches()

        let contentKey = RichText.testingContentCacheKey(
            html: "布局快照",
            baseFont: .systemFont(ofSize: 14),
            textColor: .secondaryLabel,
            lineSpacing: 6,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark)
        )
        let collapsedKey = RichText.testingLayoutCacheKey(
            contentKey: contentKey,
            maxLines: 3,
            width: 180,
            screenScale: 3
        )
        let expandedKey = RichText.testingLayoutCacheKey(
            contentKey: contentKey,
            maxLines: 0,
            width: 180,
            screenScale: 3
        )

        let collapsedSnapshot = RichTextLayoutSnapshot(
            size: CGSize(width: 180, height: 68),
            isTruncated: true
        )
        let expandedSnapshot = RichTextLayoutSnapshot(
            size: CGSize(width: 180, height: 132),
            isTruncated: false
        )
        RichText.testingStoreLayoutSnapshot(collapsedSnapshot, for: collapsedKey)
        RichText.testingStoreLayoutSnapshot(expandedSnapshot, for: expandedKey)

        #expect(RichText.testingCachedLayoutSnapshot(for: collapsedKey) == collapsedSnapshot)
        #expect(RichText.testingCachedLayoutSnapshot(for: expandedKey) == expandedSnapshot)
        #expect(collapsedKey != expandedKey)
    }

    @Test func serializerCombinedParagraphWithBulletThenQuote() {
        Self.serializerStrategyLock.lock()
        defer { Self.serializerStrategyLock.unlock() }

        let original = HTMLSerializer.comboParagraphOrderStrategy
        defer { HTMLSerializer.comboParagraphOrderStrategy = original }

        HTMLSerializer.comboParagraphOrderStrategy = .bulletThenQuote
        let attributed = HTMLParser.parse("<ul><li><blockquote>组合段落</blockquote></li></ul>")
        let html = HTMLSerializer.serialize(attributed)
        #expect(html == "<ul><li><blockquote>组合段落</blockquote></li></ul>")
    }

    @Test func serializerCombinedParagraphWithQuoteThenBullet() {
        Self.serializerStrategyLock.lock()
        defer { Self.serializerStrategyLock.unlock() }

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

#if DEBUG
    @Test func readCalendarColorRejectsNearWhiteDominantAndSelectsVisualPriorityColor() {
        let imageData = Self.makeColorImageData { _, y in
            if y < 45 {
                return (255, 255, 255, 255)
            }
            return (24, 66, 228, 255)
        }

        let hex = ReadCalendarColorRepository.testingExtractPreferredEventBarColorHex(from: imageData)
        #expect(hex != nil)

        guard let hex else { return }
        let rgba = Self.rgbaComponents(hex)
        #expect(rgba.red < 64)
        #expect(rgba.green < 96)
        #expect(rgba.blue > 180)
    }

    @Test func readCalendarColorRejectsLightGrayDominantAndSelectsSaturatedCandidate() {
        let imageData = Self.makeColorImageData { _, y in
            if y < 42 {
                return (236, 236, 236, 255)
            }
            return (18, 190, 92, 255)
        }

        let hex = ReadCalendarColorRepository.testingExtractPreferredEventBarColorHex(from: imageData)
        #expect(hex != nil)

        guard let hex else { return }
        let rgba = Self.rgbaComponents(hex)
        #expect(rgba.red < 90)
        #expect(rgba.green > 150)
        #expect(rgba.blue < 140)
    }

    @Test func readCalendarColorReturnsNilWhenNoVisualPriorityCandidate() {
        let imageData = Self.makeColorImageData { _, y in
            if y < 34 {
                return (255, 255, 255, 255)
            }
            return (223, 223, 223, 255)
        }

        let hex = ReadCalendarColorRepository.testingExtractPreferredEventBarColorHex(from: imageData)
        #expect(hex == nil)
    }

    @Test func readCalendarColorCacheKeyIncludesAlgorithmVersion() {
        let key = ReadCalendarColorRepository.testingCacheKey(
            bookId: 7,
            bookName: "缓存测试",
            coverURL: "https://example.com/cover.png"
        )
        #expect(key.contains("|algo:v2"))
    }

    @Test func readCalendarColorCancellationFallsBackToFailedColor() async {
        let imageData = Self.makeColorImageData { _, _ in
            (12, 78, 210, 255)
        }
        let image = UIImage(data: imageData)!
        let repository = ReadCalendarColorRepository(
            imageLoader: SlowCoverImageLoader(image: image, delayNanoseconds: 80_000_000)
        )

        let task = Task {
            await repository.resolveEventColor(
                bookId: 9_999_001,
                bookName: "取消测试",
                coverURL: "https://example.com/cancel-cover.jpg"
            )
        }
        task.cancel()

        let color = await task.value
        #expect(color.state == .failed)
        #expect(color != .pending)
    }
#endif

    @Test func imageRequestBuilderDetectsGIFByResponseMimeType() {
        let response = URLResponse(
            url: URL(string: "https://example.com/cover")!,
            mimeType: "image/gif",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        #expect(XMImageRequestBuilder.isGIFResponse(response))
    }

    @Test func imageRequestBuilderDetectsGIFByDataSignature() {
        let gifData = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x00, 0x00])
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x00])
        #expect(XMImageRequestBuilder.isGIFData(gifData))
        #expect(!XMImageRequestBuilder.isGIFData(pngData))
    }

    @Test func imageRequestBuilderProbesOnlyAmbiguousExtensionsForGIFData() {
        let noExtensionURL = URL(string: "https://example.com/cover")!
        let jpegURL = URL(string: "https://example.com/cover.jpg")!
        let customExtensionURL = URL(string: "https://example.com/cover.image")!

        #expect(XMImageRequestBuilder.shouldProbeGIFData(for: noExtensionURL))
        #expect(!XMImageRequestBuilder.shouldProbeGIFData(for: jpegURL))
        #expect(XMImageRequestBuilder.shouldProbeGIFData(for: customExtensionURL))
    }

    @MainActor
    @Test func readCalendarReloadSelectsInitialDateFromEntry() async {
        let calendar = Self.mondayCalendar
        let initialDate = Self.date(2026, 2, 12, calendar: calendar)
        let earliestDate = Self.date(2025, 11, 8, calendar: calendar)
        let viewModel = ReadCalendarViewModel(initialDate: initialDate, settings: ReadCalendarSettings())

        await viewModel.reload(
            using: StubStatisticsRepository(earliestDate: earliestDate),
            colorRepository: StubReadCalendarColorRepository()
        )

        #expect(calendar.isDate(viewModel.selectedDate, inSameDayAs: initialDate))
        #expect(calendar.isDate(viewModel.pagerSelection, equalTo: initialDate, toGranularity: .month))
    }

    @MainActor
    @Test func readCalendarReloadClampsFutureInitialDateToToday() async {
        let calendar = Self.mondayCalendar
        let futureDate = calendar.date(byAdding: .day, value: 21, to: Date())!
        let earliestDate = Self.date(2024, 1, 2, calendar: calendar)
        let viewModel = ReadCalendarViewModel(initialDate: futureDate, settings: ReadCalendarSettings())

        await viewModel.reload(
            using: StubStatisticsRepository(earliestDate: earliestDate),
            colorRepository: StubReadCalendarColorRepository()
        )

        let today = calendar.startOfDay(for: Date())
        #expect(calendar.isDate(viewModel.selectedDate, inSameDayAs: today))
        #expect(calendar.isDate(viewModel.pagerSelection, equalTo: today, toGranularity: .month))
    }

    @MainActor
    @Test func readCalendarJumpToTodayUpdatesSelectionAndMonth() async {
        let calendar = Self.mondayCalendar
        let initialDate = Self.date(2025, 10, 3, calendar: calendar)
        let earliestDate = Self.date(2024, 2, 1, calendar: calendar)
        let viewModel = ReadCalendarViewModel(initialDate: initialDate, settings: ReadCalendarSettings())

        await viewModel.reload(
            using: StubStatisticsRepository(earliestDate: earliestDate),
            colorRepository: StubReadCalendarColorRepository()
        )
        viewModel.jumpToToday()

        let today = calendar.startOfDay(for: Date())
        #expect(calendar.isDate(viewModel.selectedDate, inSameDayAs: today))
        #expect(calendar.isDate(viewModel.pagerSelection, equalTo: today, toGranularity: .month))
    }

    @MainActor
    @Test func readCalendarMonthStateReadKeepsLRUOrderStable() async {
        let calendar = Self.mondayCalendar
        let initialDate = Self.date(2025, 10, 3, calendar: calendar)
        let earliestDate = Self.date(2024, 2, 1, calendar: calendar)
        let viewModel = ReadCalendarViewModel(initialDate: initialDate, settings: ReadCalendarSettings())

        await viewModel.reload(
            using: StubStatisticsRepository(earliestDate: earliestDate),
            colorRepository: StubReadCalendarColorRepository()
        )

        let before = viewModel.testingMonthAccessOrderSnapshot()
        guard viewModel.availableMonths.count > 1 else {
            #expect(!before.isEmpty)
            return
        }

        _ = viewModel.monthState(for: viewModel.pagerSelection)
        let after = viewModel.testingMonthAccessOrderSnapshot()
        #expect(after == before)
    }
}

private extension xmnoteTests {
    static let serializerStrategyLock = NSLock()

    static var mondayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func makeColorImageData(
        width: Int = 40,
        height: Int = 56,
        pixelProvider: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let (r, g, b, a) = pixelProvider(x, y)
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
                bytes[offset + 3] = a
            }
        }

        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else {
            fatalError("Failed to create CGDataProvider")
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            fatalError("Failed to create CGImage")
        }

        let image = UIImage(cgImage: cgImage)
        guard let pngData = image.pngData() else {
            fatalError("Failed to encode PNG data")
        }
        return pngData
    }

    static func rgbaComponents(_ hex: UInt32) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let red = UInt8((hex >> 24) & 0xFF)
        let green = UInt8((hex >> 16) & 0xFF)
        let blue = UInt8((hex >> 8) & 0xFF)
        let alpha = UInt8(hex & 0xFF)
        return (red: red, green: green, blue: blue, alpha: alpha)
    }
}

private struct StubStatisticsRepository: StatisticsRepositoryProtocol {
    let earliestDate: Date?

    func fetchHeatmapData(
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) async throws -> (days: [Date: HeatmapDay], earliestDate: Date?, latestDate: Date?) {
        ([:], nil, nil)
    }

    func fetchReadCalendarEarliestDate(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> Date? {
        earliestDate
    }

    func fetchReadCalendarMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: monthStart)
        let normalized = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) ?? monthStart
        return .empty(for: calendar.startOfDay(for: normalized))
    }

    func fetchReadCalendarYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int
    ) async throws -> [ReadCalendarMonthlyDurationBook] {
        []
    }
}

private struct StubReadCalendarColorRepository: ReadCalendarColorRepositoryProtocol {
    func resolveEventColor(bookId: Int64, bookName: String, coverURL: String) async -> ReadCalendarSegmentColor {
        .pending
    }
}

private struct SlowCoverImageLoader: XMCoverImageLoading {
    let image: UIImage
    let delayNanoseconds: UInt64

    func loadImage(for request: XMImageLoadRequest) async throws -> UIImage {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return image
    }

    func loadData(for request: XMImageLoadRequest) async throws -> Data {
        Data()
    }
}
