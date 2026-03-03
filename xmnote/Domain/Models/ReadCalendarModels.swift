import Foundation

/**
 * [INPUT]: 依赖 Foundation 提供 Date 与集合类型
 * [OUTPUT]: 对外提供阅读日历领域模型（ReadCalendarDayBook/ReadCalendarDay/ReadCalendarMonthData/ReadCalendarMonthSummary/ReadCalendarTimeSlot/ReadCalendarMonthlyDurationBook/ReadCalendarEventRun/ReadCalendarEventSegment/ReadCalendarWeekLayout/ReadCalendarRenderMode/ReadCalendarSegmentColor）
 * [POS]: Domain 层阅读日历数据结构定义，供 StatisticsRepository 产出、ReadCalendarViewModel 与视图层消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 日历单日中的书籍事件条基础信息
nonisolated struct ReadCalendarDayBook: Identifiable, Hashable {
    let id: Int64
    let name: String
    let coverURL: String
    let firstEventTime: Int64
    let isReadDoneOnThisDay: Bool

    init(
        id: Int64,
        name: String,
        coverURL: String,
        firstEventTime: Int64,
        isReadDoneOnThisDay: Bool = false
    ) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.firstEventTime = firstEventTime
        self.isReadDoneOnThisDay = isReadDoneOnThisDay
    }
}

/// 日历单日聚合数据（日期 + 书籍 + 读完标记）
nonisolated struct ReadCalendarDay: Hashable {
    let date: Date
    let books: [ReadCalendarDayBook]
    let readDoneCount: Int
    let readSeconds: Int
    let noteCount: Int
    let checkInCount: Int
    let checkInSeconds: Int

    var isReadDoneDay: Bool {
        readDoneCount > 0
    }

    /// 对齐在读页热力图：阅读时长/书摘数/打卡时长三者取最大档位
    var heatmapLevel: HeatmapLevel {
        let readLevel = HeatmapLevel.from(readSeconds: readSeconds)
        let noteLevel = HeatmapLevel.from(noteCount: noteCount)
        let checkInLevel = HeatmapLevel.from(checkInSeconds: checkInSeconds)
        let maxRaw = max(max(readLevel.rawValue, noteLevel.rawValue), checkInLevel.rawValue)
        return HeatmapLevel(rawValue: maxRaw) ?? .none
    }
}

/// 阅读日历月维度数据
nonisolated struct ReadCalendarMonthData: Hashable {
    let monthStart: Date
    let days: [Date: ReadCalendarDay]
    let readingDurationTopBooks: [ReadCalendarMonthlyDurationBook]
    let summary: ReadCalendarMonthSummary

    static func empty(for monthStart: Date) -> ReadCalendarMonthData {
        ReadCalendarMonthData(
            monthStart: monthStart,
            days: [:],
            readingDurationTopBooks: [],
            summary: .empty
        )
    }
}

/// 阅读日历月度阅读时长排行项（按本月阅读秒数降序）
nonisolated struct ReadCalendarMonthlyDurationBook: Identifiable, Hashable {
    let bookId: Int64
    let name: String
    let coverURL: String
    let readSeconds: Int

    var id: Int64 { bookId }
}

/// 月度阅读时段（按本地时间小时段）
nonisolated enum ReadCalendarTimeSlot: String, CaseIterable, Hashable {
    case morning
    case afternoon
    case evening
    case lateNight
}

/// 阅读日历月度摘要（供总结 Sheet 展示）
nonisolated struct ReadCalendarMonthSummary: Hashable {
    let uniqueReadBookCount: Int
    let finishedBookCount: Int
    let noteCount: Int
    let totalReadSeconds: Int
    let timeSlotReadSeconds: [ReadCalendarTimeSlot: Int]

    static let empty = ReadCalendarMonthSummary(
        uniqueReadBookCount: 0,
        finishedBookCount: 0,
        noteCount: 0,
        totalReadSeconds: 0,
        timeSlotReadSeconds: [:]
    )

    func readSeconds(in slot: ReadCalendarTimeSlot) -> Int {
        timeSlotReadSeconds[slot] ?? 0
    }
}

/// 阅读日历事件条渲染模式
nonisolated enum ReadCalendarRenderMode: Hashable {
    case androidCompatible
    case crossWeekContinuous
}

/// 阅读日历事件条颜色状态
nonisolated enum ReadCalendarSegmentColorState: String, Hashable, Codable {
    /// 封面取色进行中（UI 使用骨架样式）
    case pending
    /// 封面主色取色成功
    case resolved
    /// 封面取色失败（回退哈希色）
    case failed
}

/// 阅读日历事件条颜色（RGBA Hex: 0xRRGGBBAA）
nonisolated struct ReadCalendarSegmentColor: Hashable, Codable {
    let state: ReadCalendarSegmentColorState
    let backgroundRGBAHex: UInt32
    let textRGBAHex: UInt32

    static let pending = ReadCalendarSegmentColor(
        state: .pending,
        backgroundRGBAHex: 0,
        textRGBAHex: 0
    )

    static func resolved(
        backgroundRGBAHex: UInt32,
        textRGBAHex: UInt32
    ) -> ReadCalendarSegmentColor {
        ReadCalendarSegmentColor(
            state: .resolved,
            backgroundRGBAHex: backgroundRGBAHex,
            textRGBAHex: textRGBAHex
        )
    }

    static func failed(
        backgroundRGBAHex: UInt32,
        textRGBAHex: UInt32
    ) -> ReadCalendarSegmentColor {
        ReadCalendarSegmentColor(
            state: .failed,
            backgroundRGBAHex: backgroundRGBAHex,
            textRGBAHex: textRGBAHex
        )
    }
}

/// 自然日连续区间（跨周不断）
nonisolated struct ReadCalendarEventRun: Identifiable, Hashable {
    let bookId: Int64
    let bookName: String
    let bookCoverURL: String
    let firstEventTime: Int64
    let startDate: Date
    let endDate: Date
    let laneIndex: Int
    let readDoneDates: Set<Date>

    init(
        bookId: Int64,
        bookName: String,
        bookCoverURL: String,
        firstEventTime: Int64,
        startDate: Date,
        endDate: Date,
        laneIndex: Int,
        readDoneDates: Set<Date> = []
    ) {
        self.bookId = bookId
        self.bookName = bookName
        self.bookCoverURL = bookCoverURL
        self.firstEventTime = firstEventTime
        self.startDate = startDate
        self.endDate = endDate
        self.laneIndex = laneIndex
        self.readDoneDates = readDoneDates
    }

    var id: String {
        "\(bookId)-\(startDate.timeIntervalSince1970)-\(endDate.timeIntervalSince1970)-\(laneIndex)"
    }
}

/// 周内事件条分段（渲染实体）
nonisolated struct ReadCalendarEventSegment: Identifiable, Hashable {
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
    let showsReadDoneBadge: Bool
    let color: ReadCalendarSegmentColor

    init(
        bookId: Int64,
        bookName: String,
        bookCoverURL: String,
        firstEventTime: Int64,
        weekStart: Date,
        segmentStartDate: Date,
        segmentEndDate: Date,
        laneIndex: Int,
        continuesFromPrevWeek: Bool,
        continuesToNextWeek: Bool,
        showsReadDoneBadge: Bool = false,
        color: ReadCalendarSegmentColor
    ) {
        self.bookId = bookId
        self.bookName = bookName
        self.bookCoverURL = bookCoverURL
        self.firstEventTime = firstEventTime
        self.weekStart = weekStart
        self.segmentStartDate = segmentStartDate
        self.segmentEndDate = segmentEndDate
        self.laneIndex = laneIndex
        self.continuesFromPrevWeek = continuesFromPrevWeek
        self.continuesToNextWeek = continuesToNextWeek
        self.showsReadDoneBadge = showsReadDoneBadge
        self.color = color
    }

    var id: String {
        "\(bookId)-\(weekStart.timeIntervalSince1970)-\(segmentStartDate.timeIntervalSince1970)-\(laneIndex)"
    }
}

/// 每周渲染布局（周起始 + 该周事件段）
nonisolated struct ReadCalendarWeekLayout: Identifiable, Hashable {
    let weekStart: Date
    let segments: [ReadCalendarEventSegment]

    var id: Date { weekStart }
}

// MARK: - 事件类型过滤

/// 阅读日历事件源类型（与 SQL 子查询一一对应）
nonisolated enum ReadCalendarEventType: CaseIterable, Hashable {
    case readTiming   // read_time_record
    case note         // note（书摘）
    case relevant     // category_content（相关笔记）
    case review       // review（书评）
    case readDone     // book_read_status_record
    case checkIn      // check_in_record
}
