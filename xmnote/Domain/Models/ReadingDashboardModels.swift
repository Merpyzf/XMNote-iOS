import Foundation

/**
 * [INPUT]: 依赖 Foundation 的 Date 与数值类型承载首页阅读仪表盘聚合结果
 * [OUTPUT]: 对外提供 BookReadingStatus 与 ReadingDashboardSnapshot 等首页领域模型
 * [POS]: Domain/Models 的在读首页聚合模型定义，供 ReadingDashboardRepository 与 ReadingDashboardViewModel 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 统一阅读状态语义，避免首页仓储与视图散落硬编码状态 ID。
enum BookReadingStatus: Int64, CaseIterable, Hashable {
    case wantRead = 1
    case reading = 2
    case readDone = 3
    case abandon = 4
    case onHold = 5

    var title: String {
        switch self {
        case .wantRead: "想读"
        case .reading: "在读"
        case .readDone: "读完"
        case .abandon: "弃读"
        case .onHold: "搁置"
        }
    }
}

/// 在读首页整页快照，聚合趋势、目标、继续阅读、最近在读与年度摘要。
struct ReadingDashboardSnapshot: Equatable {
    let referenceDate: Date
    let trends: [ReadingTrendMetric]
    let dailyGoal: ReadingDailyGoal
    let resumeBook: ReadingResumeBook?
    let recentBooks: [ReadingRecentBook]
    let yearSummary: ReadingYearSummary
}

/// 趋势指标卡定义，统一收口标题、总值与近期折线/柱状数据。
struct ReadingTrendMetric: Identifiable, Equatable {
    /// Kind 约束首页趋势卡口径，确保仓储、格式化工具与视图层使用同一指标枚举。
    enum Kind: String, Equatable {
        case readingDuration
        case noteCount
        case readDoneCount
    }

    /// Point 表示单个时间窗口的趋势值，供迷你柱图和辅助读屏共同消费。
    struct Point: Identifiable, Equatable {
        let id: String
        let label: String
        let value: Int
    }

    let kind: Kind
    let title: String
    let totalValue: Int
    let points: [Point]

    var id: Kind { kind }
}

/// 今日阅读目标卡数据，包含已读秒数、目标秒数与完成比例。
struct ReadingDailyGoal: Equatable {
    let readSeconds: Int
    let targetSeconds: Int

    var progress: Double {
        guard targetSeconds > 0 else { return 0 }
        return min(1, max(0, Double(readSeconds) / Double(targetSeconds)))
    }
}

/// 继续阅读卡数据，保留书籍信息与阅读进度百分比。
struct ReadingResumeBook: Identifiable, Equatable {
    let id: Int64
    let name: String
    let coverURL: String
    let progressPercent: Double?
}

/// 最近在读列表项，记录最近活动时间与阅读进度百分比。
struct ReadingRecentBook: Identifiable, Equatable {
    let id: Int64
    let name: String
    let coverURL: String
    let latestActivityAt: Int64
    let progressPercent: Double?
}

/// 年度摘要数据，聚合年度目标、已读列表与剩余量。
struct ReadingYearSummary: Equatable {
    let year: Int
    let targetCount: Int
    let readCount: Int
    let books: [ReadingYearReadBook]

    var remainingCount: Int {
        max(0, targetCount - readCount)
    }

    var isTargetAchieved: Bool {
        readCount >= targetCount
    }
}

/// 年度已读书籍条目，供摘要 Sheet 展示封面、时长与刷书次数。
struct ReadingYearReadBook: Identifiable, Equatable {
    let id: Int64
    let name: String
    let coverURL: String
    let readStatusChangedDate: Int64
    let totalReadSeconds: Int
    let readDoneCount: Int
}
