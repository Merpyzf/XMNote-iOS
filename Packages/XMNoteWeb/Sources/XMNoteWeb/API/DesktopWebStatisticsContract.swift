/**
 * [INPUT]: 依赖 Foundation Codable/Sendable，不依赖 App 数据库、UI 或 Hummingbird
 * [OUTPUT]: 提供 StatisticsController 20 条 API 的请求、响应模型和 App 能力端口
 * [POS]: XMNoteWeb 统计公共边界；完整表达 Android v46 Web 合同
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

public struct DesktopWebDayReadingTime: Codable, Sendable, Equatable {
    public let day: Int
    public let date: String
    public let readTime: Int64

    public init(day: Int, date: String, readTime: Int64) {
        self.day = day
        self.date = date
        self.readTime = readTime
    }
}

public struct DesktopWebMonthlyReading: Codable, Sendable, Equatable {
    public let year: Int
    public let month: Int
    public let label: String
    public let totalReadTime: Int64
    public let daysInMonth: Int
    public let dailyReadingTimes: [DesktopWebDayReadingTime]

    public init(
        year: Int,
        month: Int,
        label: String,
        totalReadTime: Int64,
        daysInMonth: Int,
        dailyReadingTimes: [DesktopWebDayReadingTime]
    ) {
        self.year = year
        self.month = month
        self.label = label
        self.totalReadTime = totalReadTime
        self.daysInMonth = daysInMonth
        self.dailyReadingTimes = dailyReadingTimes
    }
}

public struct DesktopWebWeekDayReading: Codable, Sendable, Equatable {
    public let dayOfWeek: Int
    public let date: String
    public let readTime: Int64
    public let hasReading: Bool

    public init(dayOfWeek: Int, date: String, readTime: Int64, hasReading: Bool) {
        self.dayOfWeek = dayOfWeek
        self.date = date
        self.readTime = readTime
        self.hasReading = hasReading
    }
}

public struct DesktopWebWeeklyReading: Codable, Sendable, Equatable {
    public let totalReadTime: Int64
    public let weekStart: String
    public let weekEnd: String
    public let days: [DesktopWebWeekDayReading]
    public let currentStreak: Int

    public init(
        totalReadTime: Int64,
        weekStart: String,
        weekEnd: String,
        days: [DesktopWebWeekDayReading],
        currentStreak: Int
    ) {
        self.totalReadTime = totalReadTime
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.days = days
        self.currentStreak = currentStreak
    }
}

public struct DesktopWebReadingRhythmSegment: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let startHour: Int
    public let endHour: Int
    public let readTime: Int64
    public let ratio: Double

    public init(id: String, label: String, startHour: Int, endHour: Int, readTime: Int64, ratio: Double) {
        self.id = id
        self.label = label
        self.startHour = startHour
        self.endHour = endHour
        self.readTime = readTime
        self.ratio = ratio
    }
}

public struct DesktopWebReadingRhythm: Codable, Sendable, Equatable {
    public let totalReadTime: Int64
    public let segments: [DesktopWebReadingRhythmSegment]
    public let peakSegmentIds: [String]
    public let rhythmType: String
    public let rhythmLabel: String
    public let rhythmDescription: String
    public let mostFrequentTime: String?
    public let hasTimedData: Bool
    public let scopeTotalReadTime: Int64
    public let accurateReadTime: Int64
    public let fuzzyReadTime: Int64

    public init(
        totalReadTime: Int64,
        segments: [DesktopWebReadingRhythmSegment],
        peakSegmentIds: [String],
        rhythmType: String,
        rhythmLabel: String,
        rhythmDescription: String,
        mostFrequentTime: String?,
        hasTimedData: Bool,
        scopeTotalReadTime: Int64,
        accurateReadTime: Int64,
        fuzzyReadTime: Int64
    ) {
        self.totalReadTime = totalReadTime
        self.segments = segments
        self.peakSegmentIds = peakSegmentIds
        self.rhythmType = rhythmType
        self.rhythmLabel = rhythmLabel
        self.rhythmDescription = rhythmDescription
        self.mostFrequentTime = mostFrequentTime
        self.hasTimedData = hasTimedData
        self.scopeTotalReadTime = scopeTotalReadTime
        self.accurateReadTime = accurateReadTime
        self.fuzzyReadTime = fuzzyReadTime
    }
}

public struct DesktopWebHeatmapDay: Codable, Sendable, Equatable {
    public let date: String
    public let readTime: Int
    public let noteCount: Int
    public let checkInTime: Int
    public let bookStates: [Bool]
    public let level: Int

    public init(
        date: String,
        readTime: Int,
        noteCount: Int,
        checkInTime: Int,
        bookStates: [Bool],
        level: Int
    ) {
        self.date = date
        self.readTime = readTime
        self.noteCount = noteCount
        self.checkInTime = checkInTime
        self.bookStates = bookStates
        self.level = level
    }
}

public struct DesktopWebHeatmap: Codable, Sendable, Equatable {
    public let days: [DesktopWebHeatmapDay]
    public let startDate: String
    public let endDate: String
    public let yearRange: [Int]
    public let earliestDate: String?
    public let latestDate: String?

    public init(
        days: [DesktopWebHeatmapDay],
        startDate: String,
        endDate: String,
        yearRange: [Int],
        earliestDate: String?,
        latestDate: String?
    ) {
        self.days = days
        self.startDate = startDate
        self.endDate = endDate
        self.yearRange = yearRange
        self.earliestDate = earliestDate
        self.latestDate = latestDate
    }
}

public struct DesktopWebStatusDistribution: Codable, Sendable, Equatable {
    public let status: Int
    public let label: String
    public let count: Int
    public let ratio: Double

    public init(status: Int, label: String, count: Int, ratio: Double) {
        self.status = status
        self.label = label
        self.count = count
        self.ratio = ratio
    }
}

public struct DesktopWebStatisticsTrend: Codable, Sendable, Equatable {
    public let label: Int
    public let value: Int

    public init(label: Int, value: Int) {
        self.label = label
        self.value = value
    }
}

public struct DesktopWebOverviewComparisonDelta: Codable, Sendable, Equatable {
    public let totalReadingTime: Int
    public let readingDays: Int
    public let noteCount: Int
    public let readDoneBookCount: Int
    public let totalWordCount: Int64
    public let purchaseBookCount: Int

    public init(
        totalReadingTime: Int,
        readingDays: Int,
        noteCount: Int,
        readDoneBookCount: Int,
        totalWordCount: Int64,
        purchaseBookCount: Int
    ) {
        self.totalReadingTime = totalReadingTime
        self.readingDays = readingDays
        self.noteCount = noteCount
        self.readDoneBookCount = readDoneBookCount
        self.totalWordCount = totalWordCount
        self.purchaseBookCount = purchaseBookCount
    }
}

public struct DesktopWebOverviewComparison: Codable, Sendable, Equatable {
    public let mode: String
    public let label: String
    public let hasBaseline: Bool
    public let delta: DesktopWebOverviewComparisonDelta?

    public init(mode: String, label: String, hasBaseline: Bool, delta: DesktopWebOverviewComparisonDelta?) {
        self.mode = mode
        self.label = label
        self.hasBaseline = hasBaseline
        self.delta = delta
    }
}

public struct DesktopWebStatisticsOverview: Codable, Sendable, Equatable {
    public let totalReadingTime: Int
    public let readingDays: Int
    public let noteCount: Int
    public let readDoneBookCount: Int
    public let totalWordCount: Int64
    public let purchaseBookCount: Int
    public let statusDistribution: [DesktopWebStatusDistribution]
    public let readingTimeTrend: [DesktopWebStatisticsTrend]
    public let readingTimeTrendUnit: String
    public let comparison: DesktopWebOverviewComparison?

    public init(
        totalReadingTime: Int,
        readingDays: Int,
        noteCount: Int,
        readDoneBookCount: Int,
        totalWordCount: Int64,
        purchaseBookCount: Int,
        statusDistribution: [DesktopWebStatusDistribution],
        readingTimeTrend: [DesktopWebStatisticsTrend],
        readingTimeTrendUnit: String,
        comparison: DesktopWebOverviewComparison?
    ) {
        self.totalReadingTime = totalReadingTime
        self.readingDays = readingDays
        self.noteCount = noteCount
        self.readDoneBookCount = readDoneBookCount
        self.totalWordCount = totalWordCount
        self.purchaseBookCount = purchaseBookCount
        self.statusDistribution = statusDistribution
        self.readingTimeTrend = readingTimeTrend
        self.readingTimeTrendUnit = readingTimeTrendUnit
        self.comparison = comparison
    }
}

public struct DesktopWebYearlyBook: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let rawName: String
    public let cover: String
    public let author: String
    public let translator: String
    public let isbn: String
    public let press: String
    public let pubDate: String
    public let doubanId: Int?
    public let readStatus: Int
    public let readStatusChangedTime: Int64
    public let readDoneCount: Int
    public let score: Int
    public let readPosition: Double
    public let totalPosition: Int
    public let totalPagination: Int
    public let currentPositionUnit: Int
    public let positionUnit: Int
    public let type: Int
    public let sourceId: Int64
    public let sourceName: String
    public let purchaseDate: Int64?
    public let price: Double?
    public let isPinned: Bool
    public let pinOrder: Int
    public let order: Int
    public let wordCount: Int64?
    public let totalReadingTime: Int64
    public let createdTime: Int64
    public let updatedTime: Int64
    public let noteCount: Int
    public let reviewCount: Int
    public let relevantCount: Int
    public let readDoneTime: Int64?
    public let bookmarkModifiedTime: Int64?
    public let groups: [DesktopWebBookGroup]
    public let tags: [DesktopWebBookTag]
    public let isDeleted: Bool

    public init(
        id: Int64, name: String, rawName: String, cover: String, author: String,
        translator: String, isbn: String, press: String, pubDate: String, doubanId: Int?,
        readStatus: Int, readStatusChangedTime: Int64, readDoneCount: Int, score: Int,
        readPosition: Double, totalPosition: Int, totalPagination: Int, currentPositionUnit: Int,
        positionUnit: Int, type: Int, sourceId: Int64, sourceName: String, purchaseDate: Int64?,
        price: Double?, isPinned: Bool, pinOrder: Int, order: Int, wordCount: Int64?,
        totalReadingTime: Int64, createdTime: Int64, updatedTime: Int64, noteCount: Int,
        reviewCount: Int, relevantCount: Int, readDoneTime: Int64?, bookmarkModifiedTime: Int64?,
        groups: [DesktopWebBookGroup], tags: [DesktopWebBookTag], isDeleted: Bool
    ) {
        self.id = id; self.name = name; self.rawName = rawName; self.cover = cover
        self.author = author; self.translator = translator; self.isbn = isbn; self.press = press
        self.pubDate = pubDate; self.doubanId = doubanId; self.readStatus = readStatus
        self.readStatusChangedTime = readStatusChangedTime; self.readDoneCount = readDoneCount
        self.score = score; self.readPosition = readPosition; self.totalPosition = totalPosition
        self.totalPagination = totalPagination; self.currentPositionUnit = currentPositionUnit
        self.positionUnit = positionUnit; self.type = type; self.sourceId = sourceId
        self.sourceName = sourceName; self.purchaseDate = purchaseDate; self.price = price
        self.isPinned = isPinned; self.pinOrder = pinOrder; self.order = order; self.wordCount = wordCount
        self.totalReadingTime = totalReadingTime; self.createdTime = createdTime
        self.updatedTime = updatedTime; self.noteCount = noteCount; self.reviewCount = reviewCount
        self.relevantCount = relevantCount; self.readDoneTime = readDoneTime
        self.bookmarkModifiedTime = bookmarkModifiedTime; self.groups = groups; self.tags = tags
        self.isDeleted = isDeleted
    }
}

public struct DesktopWebYearlyBooks: Codable, Sendable, Equatable {
    public let year: Int
    public let books: [DesktopWebYearlyBook]
    public let totalCount: Int
    public let yearRange: [Int]

    public init(year: Int, books: [DesktopWebYearlyBook], totalCount: Int, yearRange: [Int]) {
        self.year = year
        self.books = books
        self.totalCount = totalCount
        self.yearRange = yearRange
    }
}

public struct DesktopWebReadTarget: Codable, Sendable, Equatable {
    public let year: Int
    public let target: Int

    public init(year: Int, target: Int) {
        self.year = year
        self.target = target
    }
}

public struct DesktopWebReadTargetRequest: Codable, Sendable, Equatable {
    public let year: Int
    public let target: Int

    public init(year: Int, target: Int) {
        self.year = year
        self.target = target
    }
}

public struct DesktopWebYearlyGoalCelebration: Codable, Sendable, Equatable {
    public let year: Int
    public let shown: Bool

    public init(year: Int, shown: Bool) {
        self.year = year
        self.shown = shown
    }
}

public struct DesktopWebYearlyGoalCelebrationRequest: Codable, Sendable, Equatable {
    public let year: Int

    public init(year: Int) { self.year = year }
}

public struct DesktopWebDailyReadingTarget: Codable, Sendable, Equatable {
    public let target: Int
    public let todayReadingTime: Int

    public init(target: Int, todayReadingTime: Int) {
        self.target = target
        self.todayReadingTime = todayReadingTime
    }
}

public struct DesktopWebDailyReadingTargetRequest: Codable, Sendable, Equatable {
    public let target: Int

    public init(target: Int) { self.target = target }
}

public struct DesktopWebChartData: Codable, Sendable, Equatable {
    public let unit: String
    public let total: String
    public let items: [DesktopWebStatisticsTrend]
    public let scope: String
    public let scopeLabel: String

    public init(unit: String, total: String, items: [DesktopWebStatisticsTrend], scope: String, scopeLabel: String) {
        self.unit = unit
        self.total = total
        self.items = items
        self.scope = scope
        self.scopeLabel = scopeLabel
    }
}

public struct DesktopWebPurchaseChart: Codable, Sendable, Equatable {
    public let unit: String
    public let totalMoney: Float
    public let totalCount: Int
    public let items: [DesktopWebStatisticsTrend]
    public let countItems: [DesktopWebStatisticsTrend]
    public let scope: String
    public let scopeLabel: String

    public init(
        unit: String, totalMoney: Float, totalCount: Int,
        items: [DesktopWebStatisticsTrend], countItems: [DesktopWebStatisticsTrend],
        scope: String, scopeLabel: String
    ) {
        self.unit = unit
        self.totalMoney = totalMoney
        self.totalCount = totalCount
        self.items = items
        self.countItems = countItems
        self.scope = scope
        self.scopeLabel = scopeLabel
    }
}

public struct DesktopWebPieItem: Codable, Sendable, Equatable {
    public let label: String
    public let count: Int
    public let ratio: Float
    public let scope: String
    public let scopeLabel: String

    public init(label: String, count: Int, ratio: Float, scope: String, scopeLabel: String) {
        self.label = label
        self.count = count
        self.ratio = ratio
        self.scope = scope
        self.scopeLabel = scopeLabel
    }
}

/// 统计能力由 App Repository 实现；Package 只持有 Android Web 合同和值类型。
public protocol DesktopWebStatisticsPort: Sendable {
    func monthlyReading(year: Int, month: Int) async throws -> DesktopWebMonthlyReading
    func weeklyReading(weekStart: String?) async throws -> DesktopWebWeeklyReading
    func readingRhythm(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebReadingRhythm
    func heatmap(year: Int, type: String) async throws -> DesktopWebHeatmap
    func statisticsOverview(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebStatisticsOverview
    func yearlyBooks(year: Int) async throws -> DesktopWebYearlyBooks
    func readTargets() async throws -> [DesktopWebReadTarget]
    func readTarget(year: Int) async throws -> DesktopWebReadTarget
    func setReadTarget(_ request: DesktopWebReadTargetRequest) async throws -> DesktopWebReadTarget
    func yearlyGoalCelebration(year: Int) async throws -> DesktopWebYearlyGoalCelebration
    func markYearlyGoalCelebration(_ request: DesktopWebYearlyGoalCelebrationRequest) async throws -> DesktopWebYearlyGoalCelebration
    func dailyReadingTarget() async throws -> DesktopWebDailyReadingTarget
    func setDailyReadingTarget(_ request: DesktopWebDailyReadingTargetRequest) async throws -> DesktopWebDailyReadingTarget
    func noteCountChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData
    func readDoneChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData
    func wordCountChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebChartData
    func purchaseChart(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebPurchaseChart
    func bookSourceChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem]
    func noteTagChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem]
    func bookTagChart(year: Int, month: Int, weekStart: String?) async throws -> [DesktopWebPieItem]
}
