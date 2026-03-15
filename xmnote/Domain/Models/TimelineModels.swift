/**
 * [INPUT]: 无外部依赖，纯数据定义
 * [OUTPUT]: 对外提供 TimelineEvent / TimelineSection / TimelineEventKind 等时间线领域模型
 * [POS]: Domain/Models 层的时间线数据结构，供 Repository 组装、ViewModel 持有、View 渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

// MARK: - 事件子结构

/// 书摘事件，携带划线正文、用户批注、附图地址与关联标签
struct TimelineNoteEvent: Equatable {
    let content: String
    let idea: String
    let bookTitle: String
    let imageURLs: [String]
    let tagNames: [String]
}

/// 阅读计时事件，携带时长与时间范围
struct TimelineReadTimingEvent: Equatable {
    let elapsedSeconds: Int64
    let startTime: Int64
    let endTime: Int64
    let fuzzyReadDate: Int64
}

/// 阅读状态变更事件，携带状态 ID、读完次数与评分
struct TimelineReadStatusEvent: Equatable {
    let statusId: Int64
    let readDoneCount: Int64
    let bookScore: Int64
}

/// 打卡事件，携带阅读量级别
struct TimelineCheckInEvent: Equatable {
    let amount: Int64
}

/// 书评事件，携带标题、正文、评分与图片地址
struct TimelineReviewEvent: Equatable {
    let title: String
    let content: String
    let bookScore: Int64
    let imageURLs: [String]
}

/// 相关内容事件，携带标题、正文、链接、分类名与图片地址
struct TimelineRelevantEvent: Equatable {
    let title: String
    let content: String
    let url: String
    let categoryTitle: String
    let imageURLs: [String]
}

/// 相关书籍事件，携带被关联书籍信息与分类标签
struct TimelineRelevantBookEvent: Equatable {
    let contentBookName: String
    let contentBookAuthor: String
    let contentBookCover: String
    let categoryTitle: String
}

// MARK: - 事件类型

/// 7 种时间线事件的类型判别联合体
enum TimelineEventKind: Equatable {
    case note(TimelineNoteEvent)
    case readTiming(TimelineReadTimingEvent)
    case readStatus(TimelineReadStatusEvent)
    case checkIn(TimelineCheckInEvent)
    case review(TimelineReviewEvent)
    case relevant(TimelineRelevantEvent)
    case relevantBook(TimelineRelevantBookEvent)
}

// MARK: - 统一事件

/// 时间线单条事件，聚合事件类型与书籍信息，按 timestamp 排序
struct TimelineEvent: Identifiable, Equatable {
    let id: String
    let kind: TimelineEventKind
    let timestamp: Int64
    let bookName: String
    let bookAuthor: String
    let bookCover: String
}

// MARK: - 按日分组

/// 时间线按日分组，date 为当日零时，events 按时间降序排列
struct TimelineSection: Identifiable, Equatable {
    let id: String
    let date: Date
    let events: [TimelineEvent]
}

// MARK: - 筛选类别

/// 时间线事件筛选类别，对齐 Android 端 7 种 + 全部
enum TimelineEventCategory: String, CaseIterable, Identifiable, Equatable {
    case all = "全部"
    case note = "书摘"
    case readStatus = "状态"
    case relevant = "相关"
    case review = "书评"
    case readTiming = "计时"
    case checkIn = "打卡"

    var id: String { rawValue }
}

// MARK: - Emoji 映射

extension TimelineEventKind {

    /// 事件类型对应的 Emoji 标记，对齐 Android TimelineRepository 的 emojiSign 字段
    var emoji: String {
        switch self {
        case .note: "📝"
        case .readTiming: "⌛️"
        case .checkIn: "📅"
        case .review: "✏️"
        case .relevant, .relevantBook: "🗂"
        case .readStatus(let e):
            switch e.statusId {
            case 1: "😍"
            case 2: "👁"
            case 3: "🎊"
            case 4: "😵‍💫"
            case 5: "📦"
            default: "📖"
            }
        }
    }

    /// 事件类型的中文简称，用于时间行标注
    var label: String {
        switch self {
        case .note: "书摘"
        case .readTiming: "阅读"
        case .readStatus: "状态"
        case .checkIn: "打卡"
        case .review: "书评"
        case .relevant: "相关"
        case .relevantBook: "相关书籍"
        }
    }
}

// MARK: - 阅读状态辅助

/// 阅读状态 ID → 显示名，对齐 Android READ_STATUS_NAMES
enum ReadStatusHelper {

    /// 把阅读状态 ID 和刷读次数转换成时间线可直接展示的状态文案。
    static func statusName(for statusId: Int64, readDoneCount: Int64 = 0) -> String {
        switch statusId {
        case 1: "想读"
        case 2: "在读"
        case 3: readDoneCount > 1 ? "读完（\(readDoneCount)刷）" : "读完"
        case 4: "弃读"
        case 5: "搁置"
        default: "未知"
        }
    }
}

// MARK: - 阅读时长格式化

/// 秒数 → 可读时长，对齐 Android LongExtensions.toReadableTimeDuration
enum ReadDurationFormatter {

    /// 把秒数压缩成时间线卡片可读时长，保持和 Android 可读时长文案一致。
    static func format(seconds: Int64) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return m > 0 ? "\(h)小时 \(m)分钟" : "\(h)小时"
        }
        if m > 0 {
            return s > 0 ? "\(m)分钟 \(s)秒" : "\(m)分钟"
        }
        return "\(s)秒"
    }
}

// MARK: - 打卡阅读量级别

/// 阅读量级别 1-4 的文案与颜色，对齐 Android ReadAmountLevel + ChartHelper
enum CheckInAmountLevel {
    case veryLess, less, more, veryMore

    init(amount: Int64) {
        switch amount {
        case 1: self = .veryLess
        case 2: self = .less
        case 3: self = .more
        case 4: self = .veryMore
        default: self = .veryLess
        }
    }

    var label: String {
        switch self {
        case .veryLess: "少"
        case .less: "中等"
        case .more: "多"
        case .veryMore: "很多"
        }
    }
}

// MARK: - 日历标记

/// 日历单日标记，标识该日是否有事件活动及阅读进度，供日历 cell 渲染点标记与进度环。
struct TimelineDayMarker: Hashable {
    let isActive: Bool
    /// 阅读进度百分比（0-100），0 表示无阅读计时记录
    let readingProgress: Int

    /// 归一化进度比例（0.0-1.0），供进度环弧长渲染
    var progressRatio: Double {
        let clamped = min(100, max(0, readingProgress))
        return Double(clamped) / 100.0
    }
}
