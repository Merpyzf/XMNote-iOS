import Foundation

/**
 * [INPUT]: 依赖 Foundation 提供 Date 与集合类型
 * [OUTPUT]: 对外提供阅读日历、当日阅读汇总、单书时间线与打卡/计时编辑领域模型
 * [POS]: Domain 层阅读日历数据结构定义，供 ReadCalendarRepository 产出、ViewModel 与视图层消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 日历单日中的书籍事件条基础信息
nonisolated struct ReadCalendarDayBook: Identifiable, Hashable {
    let id: Int64
    let name: String
    let coverURL: String
    let firstEventTime: Int64
    let isReadDoneOnThisDay: Bool

    /// 创建单日书籍事件模型，写入书籍基础信息、首个事件时间与读完标记。
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
    let contentActivityCount: Int
    let checkInCount: Int
    let checkInAmount: Int
    let checkInSeconds: Int

    /// 构造单日聚合结果；新增字段提供默认值以兼容旧调用方逐步迁移。
    init(
        date: Date,
        books: [ReadCalendarDayBook],
        readDoneCount: Int,
        readSeconds: Int,
        noteCount: Int,
        contentActivityCount: Int = 0,
        checkInCount: Int,
        checkInAmount: Int = 0,
        checkInSeconds: Int
    ) {
        self.date = date
        self.books = books
        self.readDoneCount = readDoneCount
        self.readSeconds = readSeconds
        self.noteCount = noteCount
        self.contentActivityCount = contentActivityCount
        self.checkInCount = checkInCount
        self.checkInAmount = checkInAmount
        self.checkInSeconds = checkInSeconds
    }

    var isReadDoneDay: Bool {
        readDoneCount > 0
    }

    /// 对齐 Android 阅读日历：时长、内容活动、打卡量与读完标记取最大档位。
    var heatmapLevel: HeatmapLevel {
        let readLevel = Self.readHeatmapLevel(seconds: readSeconds)
        let contentLevel = Self.countHeatmapLevel(count: noteCount + contentActivityCount)
        let checkInLevel = Self.countHeatmapLevel(count: max(checkInCount, checkInAmount))
        let readDoneLevel = readDoneCount > 0 ? HeatmapLevel.less : .none
        let maxRaw = max(
            max(readLevel.rawValue, contentLevel.rawValue),
            max(checkInLevel.rawValue, readDoneLevel.rawValue)
        )
        return HeatmapLevel(rawValue: maxRaw) ?? .none
    }

    /// 把阅读秒数映射为 Android 阅读日历的 15/30/60 分钟五级阈值。
    private static func readHeatmapLevel(seconds: Int) -> HeatmapLevel {
        switch seconds {
        case ...0: .none
        case 1..<900: .veryLess
        case 900..<1_800: .less
        case 1_800..<3_600: .more
        default: .veryMore
        }
    }

    /// 把内容数或打卡量映射为 Android 阅读日历的 1/2/3-4/5+ 五级阈值。
    private static func countHeatmapLevel(count: Int) -> HeatmapLevel {
        switch count {
        case ...0: .none
        case 1: .veryLess
        case 2: .less
        case 3...4: .more
        default: .veryMore
        }
    }
}

/// 阅读日历月维度数据
nonisolated struct ReadCalendarMonthData: Hashable {
    let monthStart: Date
    let days: [Date: ReadCalendarDay]
    let readingDurationTopBooks: [ReadCalendarMonthlyDurationBook]
    let summary: ReadCalendarMonthSummary

    /// 构造空月份默认数据，保证无记录月份也可稳定渲染。
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
    let activeDays: Int
    let totalDays: Int
    let longestStreak: Int
    let uniqueReadBookCount: Int
    let finishedBookCount: Int
    let noteCount: Int
    let checkInCount: Int
    let totalReadSeconds: Int
    let timeSlotReadSeconds: [ReadCalendarTimeSlot: Int]
    let peakTimeSlot: ReadCalendarTimeSlot?
    let peakTimeSlotRatio: Double
    let activeDaysDelta: Int
    let uniqueReadBookCountDelta: Int
    let finishedBookCountDelta: Int
    let noteCountDelta: Int
    let totalReadSecondsDelta: Int

    /// 构造月度摘要；比较字段缺省为 0，便于当前月与历史缓存分阶段接入。
    init(
        activeDays: Int = 0,
        totalDays: Int = 0,
        longestStreak: Int = 0,
        uniqueReadBookCount: Int,
        finishedBookCount: Int,
        noteCount: Int,
        checkInCount: Int = 0,
        totalReadSeconds: Int,
        timeSlotReadSeconds: [ReadCalendarTimeSlot: Int],
        peakTimeSlot: ReadCalendarTimeSlot? = nil,
        peakTimeSlotRatio: Double = 0,
        activeDaysDelta: Int = 0,
        uniqueReadBookCountDelta: Int = 0,
        finishedBookCountDelta: Int = 0,
        noteCountDelta: Int = 0,
        totalReadSecondsDelta: Int = 0
    ) {
        self.activeDays = activeDays
        self.totalDays = totalDays
        self.longestStreak = longestStreak
        self.uniqueReadBookCount = uniqueReadBookCount
        self.finishedBookCount = finishedBookCount
        self.noteCount = noteCount
        self.checkInCount = checkInCount
        self.totalReadSeconds = totalReadSeconds
        self.timeSlotReadSeconds = timeSlotReadSeconds
        self.peakTimeSlot = peakTimeSlot
        self.peakTimeSlotRatio = peakTimeSlotRatio
        self.activeDaysDelta = activeDaysDelta
        self.uniqueReadBookCountDelta = uniqueReadBookCountDelta
        self.finishedBookCountDelta = finishedBookCountDelta
        self.noteCountDelta = noteCountDelta
        self.totalReadSecondsDelta = totalReadSecondsDelta
    }

    static let empty = ReadCalendarMonthSummary(
        activeDays: 0,
        totalDays: 0,
        longestStreak: 0,
        uniqueReadBookCount: 0,
        finishedBookCount: 0,
        noteCount: 0,
        checkInCount: 0,
        totalReadSeconds: 0,
        timeSlotReadSeconds: [:]
    )

    /// 读取指定时段的阅读秒数；缺省时返回 0。
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

    /// 构造取色成功态，用于事件条渲染真实封面主色。
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

    /// 构造取色失败态，使用回退色继续完成事件条渲染。
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

    /// 创建跨天连续事件区间，写入书籍信息、日期范围与泳道位置。
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

    /// 创建周内事件段模型，写入切片区间、跨周标记、读完徽章与颜色信息。
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

// MARK: - 当日阅读

/// 当日单书聚合，供二级页面按书展示阅读行为摘要。
nonisolated struct DailyReadingBookSummary: Identifiable, Hashable {
    let book: ReadCalendarDayBook
    let readSeconds: Int
    let noteCount: Int
    let relevantCount: Int
    let reviewCount: Int
    let checkInCount: Int
    let readDoneCount: Int

    var id: Int64 { book.id }

    var hasActivity: Bool {
        readSeconds > 0 || noteCount > 0 || relevantCount > 0 || reviewCount > 0 || checkInCount > 0 || readDoneCount > 0
    }
}

/// 当日阅读汇总，保存二级页面标题与指标计算所需的完整原始计数。
nonisolated struct DailyReadingSummary: Hashable {
    let date: Date
    let books: [DailyReadingBookSummary]
    let readSeconds: Int
    let noteCount: Int
    let relevantCount: Int
    let reviewCount: Int
    let checkInCount: Int
    let finishedBookCount: Int

    static func empty(for date: Date) -> DailyReadingSummary {
        DailyReadingSummary(
            date: date,
            books: [],
            readSeconds: 0,
            noteCount: 0,
            relevantCount: 0,
            reviewCount: 0,
            checkInCount: 0,
            finishedBookCount: 0
        )
    }
}

/// 单书当日时间线筛选；读完状态只参与汇总，不进入 Android 的三级记录流。
nonisolated enum DailyReadingTimelineFilter: String, CaseIterable, Identifiable, Hashable, Codable {
    case all
    case note
    case relevant
    case review
    case checkIn
    case readTiming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .note: "书摘"
        case .relevant: "相关"
        case .review: "书评"
        case .checkIn: "打卡"
        case .readTiming: "计时"
        }
    }
}

/// 单书当日时间线排序方向。
nonisolated enum DailyReadingSortOrder: String, CaseIterable, Identifiable, Hashable, Codable {
    case descending
    case ascending

    var id: String { rawValue }

    var title: String { self == .descending ? "从新到旧" : "从旧到新" }
}

/// 单书当日时间线记录，补充底层主键以支持编辑与物理删除。
nonisolated struct DailyReadingRecord: Identifiable, Equatable {
    let recordID: Int64
    let event: TimelineEvent

    var id: String { event.id }
}

/// 打卡新增/编辑草稿；recordID 为空表示按“同书同日”规则新增或更新。
nonisolated struct ReadCalendarCheckInDraft: Hashable {
    let recordID: Int64?
    let bookID: Int64
    let amount: Int
    let date: Date
}

/// 阅读计时记录类型，对齐 Android 精确时间与模糊时间两种补录方式。
nonisolated enum ReadCalendarTimingKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case accurate
    case fuzzy

    var id: String { rawValue }
}

/// 计时编辑草稿，包含 Android 阅读时间记录页允许修改的业务字段。
nonisolated struct ReadCalendarTimingDraft: Hashable {
    let recordID: Int64
    let bookID: Int64
    let kind: ReadCalendarTimingKind
    let startDate: Date?
    let endDate: Date?
    let fuzzyDate: Date?
    let elapsedSeconds: Int64
    let position: Double
    let recordedPositionUnit: Int64?
    let insight: String
    let shouldMarkReadDone: Bool
}
