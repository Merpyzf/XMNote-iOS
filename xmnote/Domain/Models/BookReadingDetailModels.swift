/**
 * [INPUT]: 依赖 Foundation、HeatmapDay 与书籍阅读状态/进度数据库语义
 * [OUTPUT]: 对外提供 BookReadingDetailSnapshot、封面主题色、阅读分析/月度时长/状态历程、状态写入与庆祝追踪模型
 * [POS]: Domain 层单书阅读数据页模型，隔离数据库 Record 与 SwiftUI 页面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 封面主题取色结果；代表色、背景色、图表强调色与可读前景色均来自同一次 Android Palette 等价量化。
nonisolated struct BookCoverThemeColor: Hashable, Sendable {
    let state: ReadCalendarSegmentColorState
    let representativeRGBAHex: UInt32
    let backgroundRGBAHex: UInt32
    let accentRGBAHex: UInt32
    let onRepresentativeRGBAHex: UInt32

    static let pending = BookCoverThemeColor(
        state: .pending,
        representativeRGBAHex: 0,
        backgroundRGBAHex: 0,
        accentRGBAHex: 0,
        onRepresentativeRGBAHex: 0
    )
}

/// 阅读详情页书籍资料，保留 Android 页面展示和编辑所需的最小字段集合。
nonisolated struct BookReadingDetailBook: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let coverURL: String
    let author: String
    let translator: String
    let isbn: String
    let publicationDate: String
    let press: String
    let summary: String
    let score: Int64
    let bookType: Int64
    let currentPositionUnit: Int64
    let positionUnit: Int64
    let readPosition: Double
    let totalPosition: Int64
    let totalPagination: Int64
    let readStatusID: Int64
    let readStatusName: String
    let readStatusChangedAt: Int64
    let readDoneCount: Int
    let sourceName: String
    let groupNames: [String]
    let tagNames: [String]
    let wordCount: Int64?
    let price: Double
    let createdAt: Int64
}

/// 阅读进度快照；百分比单位直接使用业务值，位置/页码单位使用当前值与总值。
nonisolated struct BookReadingProgress: Hashable, Sendable {
    let unit: Int64
    let currentValue: Double
    let totalValue: Int64?
    let fraction: Double?

    var percentage: Int? {
        guard let fraction else { return nil }
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}

/// 单书阅读分析，口径与 Android BookRepository 的三个聚合方法一致。
nonisolated struct BookReadingAnalytics: Hashable, Sendable {
    let readingDayCount: Int
    let lastReadingAt: Int64?
    let progress: BookReadingProgress
    let totalReadingSeconds: Int64
    let actualStartAt: Int64?
    let statusStartAt: Int64?
    let noteCount: Int
    let ideaCount: Int
}

/// 月度图表中的单日阅读时长；跨日精确记录在 Repository 中先按自然日切分。
nonisolated struct BookReadingDailyDuration: Identifiable, Hashable, Sendable {
    let date: Date
    let seconds: Int64

    var id: Date { date }
}

/// 单书单月阅读时长分组，月份按新到旧排列，组内日期按旧到新排列。
nonisolated struct BookReadingMonthDuration: Identifiable, Hashable, Sendable {
    let year: Int
    let month: Int
    let days: [BookReadingDailyDuration]

    var id: String { "\(year)-\(month)" }
    var totalSeconds: Int64 { days.reduce(0) { $0 + $1.seconds } }
}

/// 阅读状态历程节点；加入书架节点为页面补充语义，不对应可编辑数据库记录。
nonisolated struct BookReadingStatusHistoryItem: Identifiable, Hashable, Sendable {
    let recordID: Int64?
    let statusID: Int64
    let statusName: String
    let changedAt: Int64
    let isSyntheticShelfNode: Bool

    var id: String {
        if let recordID { return "record-\(recordID)" }
        return "shelf-\(changedAt)"
    }
}

/// 阅读状态选择项，直接来自 read_status 有效种子数据。
nonisolated struct BookReadingStatusOption: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
}

/// 新增或编辑阅读状态的输入；recordID 为空代表追加新历史，否则精确更新该历史记录。
nonisolated struct BookReadingStatusInput: Hashable, Sendable {
    let recordID: Int64?
    let statusID: Int64
    let changedAt: Date
    let ratingScore: Int64
}

/// 读完庆祝文案所需的累计进度，三个数值与 Android ReadingTracker 完全同义。
nonisolated struct BookReadingCompletionTracker: Hashable, Sendable {
    let totalCompletedBookCount: Int
    let completedBookCountThisYear: Int
    let targetBookCountThisYear: Int
}

/// 独立阅读详情一次性数据快照；GRDB 观察流以此作为页面唯一数据源。
nonisolated struct BookReadingDetailSnapshot: Sendable {
    let book: BookReadingDetailBook
    let heatmapDays: [Date: HeatmapDay]
    let heatmapEarliestDate: Date?
    let heatmapLatestDate: Date?
    let analytics: BookReadingAnalytics
    let monthlyDurations: [BookReadingMonthDuration]
    let statusHistory: [BookReadingStatusHistoryItem]
    let statusOptions: [BookReadingStatusOption]
}

/// 阅读详情页面偏好；默认值严格复刻 Android 的两个开启状态。
nonisolated struct BookReadingDetailSetting: Codable, Hashable, Sendable {
    var isCoverBackgroundEnabled = true
    var isMonthlyChartCollapsedByDefault = true
}

/// 阅读详情长图开关；七项默认全部开启，与 Android BookReadingDetailShareSetting 一致。
nonisolated struct BookReadingDetailShareSetting: Codable, Hashable, Sendable {
    var showsBookAttributes = true
    var showsBookSummary = true
    var showsHeatmap = true
    var showsReadingAnalytics = true
    var showsMonthlyChart = true
    var showsReadingTimeline = true
    var showsAppIdentity = true
}

/// 进度编辑输入，按书籍原进度单位选择目标字段，不更改 schema。
nonisolated struct BookReadingProgressInput: Hashable, Sendable {
    let currentValue: Double
    let totalValue: Int64?
}
