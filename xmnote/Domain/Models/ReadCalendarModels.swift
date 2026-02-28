import Foundation

/**
 * [INPUT]: 依赖 Foundation 提供 Date 与集合类型
 * [OUTPUT]: 对外提供阅读日历领域模型（ReadCalendarDayBook/ReadCalendarDay/ReadCalendarMonthData/ReadCalendarEventRun/ReadCalendarEventSegment/ReadCalendarWeekLayout/ReadCalendarRenderMode）
 * [POS]: Domain 层阅读日历数据结构定义，供 StatisticsRepository 产出、ReadCalendarViewModel 与视图层消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 日历单日中的书籍事件条基础信息
struct ReadCalendarDayBook: Identifiable, Hashable {
    let id: Int64
    let name: String
    let coverURL: String
    let firstEventTime: Int64
}

/// 日历单日聚合数据（日期 + 书籍 + 读完标记）
struct ReadCalendarDay: Hashable {
    let date: Date
    let books: [ReadCalendarDayBook]
    let readDoneCount: Int

    var isReadDoneDay: Bool {
        readDoneCount > 0
    }
}

/// 阅读日历月维度数据
struct ReadCalendarMonthData: Hashable {
    let monthStart: Date
    let days: [Date: ReadCalendarDay]

    static func empty(for monthStart: Date) -> ReadCalendarMonthData {
        ReadCalendarMonthData(monthStart: monthStart, days: [:])
    }
}

/// 阅读日历事件条渲染模式
enum ReadCalendarRenderMode: Hashable {
    case androidCompatible
    case crossWeekContinuous
}

/// 自然日连续区间（跨周不断）
struct ReadCalendarEventRun: Identifiable, Hashable {
    let bookId: Int64
    let bookName: String
    let bookCoverURL: String
    let firstEventTime: Int64
    let startDate: Date
    let endDate: Date
    let laneIndex: Int

    var id: String {
        "\(bookId)-\(startDate.timeIntervalSince1970)-\(endDate.timeIntervalSince1970)-\(laneIndex)"
    }
}

/// 周内事件条分段（渲染实体）
struct ReadCalendarEventSegment: Identifiable, Hashable {
    let bookId: Int64
    let bookName: String
    let bookCoverURL: String
    let firstEventTime: Int64
    let weekStart: Date
    let segmentStartDate: Date
    let segmentEndDate: Date
    let laneIndex: Int
    let continuesFromPrevWeek: Bool
    let continuesToNextWeek: Bool

    var id: String {
        "\(bookId)-\(weekStart.timeIntervalSince1970)-\(segmentStartDate.timeIntervalSince1970)-\(laneIndex)"
    }
}

/// 每周渲染布局（周起始 + 该周事件段）
struct ReadCalendarWeekLayout: Identifiable, Hashable {
    let weekStart: Date
    let segments: [ReadCalendarEventSegment]

    var id: Date { weekStart }
}
