/**
 * [INPUT]: 依赖 Foundation 与 App 注入的阅读日历能力
 * [OUTPUT]: 提供 CalendarController 2 个 API 的月历、单日汇总 DTO 与能力端口
 * [POS]: XMNoteWeb 阅读日历公共边界；只表达 Android Web 合同，不依赖 App 数据库或 UI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android WebCalendarBookDto；连续阅读标记保留当前 Web 恒为 false 的可观察合同。
public struct DesktopWebCalendarBook: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let cover: String?
    public let author: String?
    public let isContinuation: Bool

    public init(
        id: Int64,
        name: String,
        cover: String?,
        author: String?,
        isContinuation: Bool
    ) {
        self.id = id
        self.name = name
        self.cover = cover
        self.author = author
        self.isContinuation = isContinuation
    }
}

/// Android WebCalendarDayDto；无活动日期仍会出现在 month 响应中。
public struct DesktopWebCalendarDay: Codable, Sendable, Equatable {
    public let dayOfMonth: Int
    public let date: String
    public let books: [DesktopWebCalendarBook]
    public let readDoneBookCount: Int
    public let hasActivity: Bool

    public init(
        dayOfMonth: Int,
        date: String,
        books: [DesktopWebCalendarBook],
        readDoneBookCount: Int,
        hasActivity: Bool
    ) {
        self.dayOfMonth = dayOfMonth
        self.date = date
        self.books = books
        self.readDoneBookCount = readDoneBookCount
        self.hasActivity = hasActivity
    }
}

/// Android WebCalendarMonthDto；startDayOfWeek 使用周一为 0 的索引。
public struct DesktopWebCalendarMonth: Codable, Sendable, Equatable {
    public let year: Int
    public let month: Int
    public let days: [DesktopWebCalendarDay]
    public let startDayOfWeek: Int
    public let totalDays: Int

    public init(
        year: Int,
        month: Int,
        days: [DesktopWebCalendarDay],
        startDayOfWeek: Int,
        totalDays: Int
    ) {
        self.year = year
        self.month = month
        self.days = days
        self.startDayOfWeek = startDayOfWeek
        self.totalDays = totalDays
    }
}

/// Android WebDailyReadingDetailDto，按书籍聚合当天五类计数与读完状态。
public struct DesktopWebDailyReadingDetail: Codable, Sendable, Equatable {
    public let book: DesktopWebCalendarBook
    public let readingTime: Int
    public let noteCount: Int
    public let reviewCount: Int
    public let checkInCount: Int
    public let isReadDoneInToday: Bool

    public init(
        book: DesktopWebCalendarBook,
        readingTime: Int,
        noteCount: Int,
        reviewCount: Int,
        checkInCount: Int,
        isReadDoneInToday: Bool
    ) {
        self.book = book
        self.readingTime = readingTime
        self.noteCount = noteCount
        self.reviewCount = reviewCount
        self.checkInCount = checkInCount
        self.isReadDoneInToday = isReadDoneInToday
    }
}

/// Android WebDailyReadingSummaryDto；汇总值按返回 details 再次相加。
public struct DesktopWebDailyReadingSummary: Codable, Sendable, Equatable {
    public let date: String
    public let details: [DesktopWebDailyReadingDetail]
    public let totalReadingTime: Int
    public let totalNoteCount: Int

    public init(
        date: String,
        details: [DesktopWebDailyReadingDetail],
        totalReadingTime: Int,
        totalNoteCount: Int
    ) {
        self.date = date
        self.details = details
        self.totalReadingTime = totalReadingTime
        self.totalNoteCount = totalNoteCount
    }
}

/// 隔离阅读日历聚合查询；实现由 App Repository 提供，不向 Package 泄漏 GRDB 或领域模型。
public protocol DesktopWebCalendarPort: Sendable {
    func calendarMonth(monthMillis: Int64) async throws -> DesktopWebCalendarMonth

    func calendarDay(dateMillis: Int64) async throws -> DesktopWebDailyReadingSummary
}
