import Foundation

/**
 * [INPUT]: 依赖 Foundation 提供 Date 与集合类型
 * [OUTPUT]: 对外提供阅读日历、全量书籍贡献、月度摘要、同期比较、当日阅读汇总及编辑领域模型
 * [POS]: Domain 层阅读日历数据结构定义，供 ReadCalendarRepository 产出、ViewModel 与视图层消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 日历单日中的书籍事件条基础信息
nonisolated struct ReadCalendarDayBook: Identifiable, Hashable {
    let id: Int64
    let name: String
    let coverURL: String
    let firstEventTime: Int64
    let lastEventTime: Int64
    let isReadDoneOnThisDay: Bool

    /// 创建单日书籍事件模型，写入书籍基础信息、首末事件时间与读完标记。
    init(
        id: Int64,
        name: String,
        coverURL: String,
        firstEventTime: Int64,
        lastEventTime: Int64? = nil,
        isReadDoneOnThisDay: Bool = false
    ) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.firstEventTime = firstEventTime
        self.lastEventTime = lastEventTime ?? firstEventTime
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
    let bookContributions: [ReadCalendarBookContribution]
    let summary: ReadCalendarMonthSummary

    /// 构造单月完整聚合；书籍贡献保留所有活跃书籍，不能由截断后的排行榜反推。
    init(
        monthStart: Date,
        days: [Date: ReadCalendarDay],
        readingDurationTopBooks: [ReadCalendarMonthlyDurationBook],
        bookContributions: [ReadCalendarBookContribution] = [],
        summary: ReadCalendarMonthSummary
    ) {
        self.monthStart = monthStart
        self.days = days
        self.readingDurationTopBooks = readingDurationTopBooks
        self.bookContributions = bookContributions
        self.summary = summary
    }

    /// 构造空月份默认数据，保证无记录月份也可稳定渲染。
    static func empty(for monthStart: Date) -> ReadCalendarMonthData {
        ReadCalendarMonthData(
            monthStart: monthStart,
            days: [:],
            readingDurationTopBooks: [],
            bookContributions: [],
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

/// 阅读日历周期内单本书的完整贡献，用于分享排除与全量排行重算。
nonisolated struct ReadCalendarBookContribution: Identifiable, Hashable {
    let bookId: Int64
    let name: String
    let coverURL: String
    let readSeconds: Int
    let activeDays: Int

    var id: Int64 { bookId }

    /// 转换为现有排行展示模型，避免页面层重复拼装书籍元数据。
    var durationBook: ReadCalendarMonthlyDurationBook {
        ReadCalendarMonthlyDurationBook(
            bookId: bookId,
            name: name,
            coverURL: coverURL,
            readSeconds: readSeconds
        )
    }
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
    let peakTimeSlotRatio: Int?
    let activeDaysDelta: Int?
    let readSecondsDelta: Int?
    let uniqueReadBookCountDelta: Int?
    let finishedBookCountDelta: Int?
    let noteCountDelta: Int?

    /// 构造月度摘要；缺少有效上一周期时比较字段保持为空，避免伪造零值环比。
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
        peakTimeSlotRatio: Int? = nil,
        activeDaysDelta: Int? = nil,
        readSecondsDelta: Int? = nil,
        uniqueReadBookCountDelta: Int? = nil,
        finishedBookCountDelta: Int? = nil,
        noteCountDelta: Int? = nil
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
        self.readSecondsDelta = readSecondsDelta
        self.uniqueReadBookCountDelta = uniqueReadBookCountDelta
        self.finishedBookCountDelta = finishedBookCountDelta
        self.noteCountDelta = noteCountDelta
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

    /// 合并上一周期快照并生成五类可选环比；上一周期无有效行为时保持无对比状态。
    func applyingComparison(_ previous: ReadCalendarSummaryComparisonSnapshot?) -> ReadCalendarMonthSummary {
        let comparablePrevious = previous?.hasActivity == true ? previous : nil
        return ReadCalendarMonthSummary(
            activeDays: activeDays,
            totalDays: totalDays,
            longestStreak: longestStreak,
            uniqueReadBookCount: uniqueReadBookCount,
            finishedBookCount: finishedBookCount,
            noteCount: noteCount,
            checkInCount: checkInCount,
            totalReadSeconds: totalReadSeconds,
            timeSlotReadSeconds: timeSlotReadSeconds,
            peakTimeSlot: peakTimeSlot,
            peakTimeSlotRatio: peakTimeSlotRatio,
            activeDaysDelta: comparablePrevious.map { activeDays - $0.activeDays },
            readSecondsDelta: comparablePrevious.map { totalReadSeconds - $0.totalReadSeconds },
            uniqueReadBookCountDelta: comparablePrevious.map { uniqueReadBookCount - $0.uniqueReadBookCount },
            finishedBookCountDelta: comparablePrevious.map { finishedBookCount - $0.finishedBookCount },
            noteCountDelta: comparablePrevious.map { noteCount - $0.noteCount }
        )
    }
}

/// 阅读日历统计对比快照，集中承载月度与年度同期比较所需的五类指标。
nonisolated struct ReadCalendarSummaryComparisonSnapshot: Hashable {
    let activeDays: Int
    let totalReadSeconds: Int
    let uniqueReadBookCount: Int
    let finishedBookCount: Int
    let noteCount: Int

    var hasActivity: Bool {
        activeDays > 0
            || totalReadSeconds > 0
            || uniqueReadBookCount > 0
            || finishedBookCount > 0
            || noteCount > 0
    }

    /// 从 Repository 产出的每日快照聚合比较指标，可按截止日裁切当前周期的同期范围。
    static func make(
        days: [Date: ReadCalendarDay],
        through cutoff: Date? = nil,
        calendar: Calendar = .current
    ) -> ReadCalendarSummaryComparisonSnapshot {
        let normalizedCutoff = cutoff.map { calendar.startOfDay(for: $0) }
        let includedDays = days.filter { date, _ in
            guard let normalizedCutoff else { return true }
            return calendar.startOfDay(for: date) <= normalizedCutoff
        }
        let values = includedDays.map(\.value)
        let uniqueBookIDs = Set(values.flatMap { $0.books.map(\.id) })
        let finishedBookIDs = Set(values.flatMap { day in
            day.books.filter(\.isReadDoneOnThisDay).map(\.id)
        })
        return ReadCalendarSummaryComparisonSnapshot(
            activeDays: values.count { !$0.books.isEmpty || $0.isReadDoneDay },
            totalReadSeconds: values.reduce(0) { $0 + $1.readSeconds },
            uniqueReadBookCount: uniqueBookIDs.count,
            finishedBookCount: finishedBookIDs.count,
            noteCount: values.reduce(0) { $0 + $1.noteCount }
        )
    }
}

/// 阅读日历同期边界计算器，负责短月与闰年日期的安全收口。
nonisolated enum ReadCalendarSummaryComparison {
    /// 当前月返回上月同日截止日期，历史月返回 nil 表示比较完整上月。
    static func previousMonthCutoff(
        selectedMonthStart: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard calendar.isDate(selectedMonthStart, equalTo: now, toGranularity: .month),
              let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: selectedMonthStart) else {
            return nil
        }
        let requestedDay = calendar.component(.day, from: now)
        return clampedDate(
            year: calendar.component(.year, from: previousMonthStart),
            month: calendar.component(.month, from: previousMonthStart),
            day: requestedDay,
            calendar: calendar
        )
    }

    /// 当前年返回上年同月同日截止日期，历史年返回 nil 表示比较完整上一年。
    static func previousYearCutoff(
        selectedYear: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard selectedYear == calendar.component(.year, from: now) else { return nil }
        return clampedDate(
            year: selectedYear - 1,
            month: calendar.component(.month, from: now),
            day: calendar.component(.day, from: now),
            calendar: calendar
        )
    }

    /// 将目标年月日收口到该月最后一个有效自然日。
    private static func clampedDate(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Date? {
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else {
            return nil
        }
        let clampedDay = min(max(day, dayRange.lowerBound), dayRange.upperBound - 1)
        return calendar.date(from: DateComponents(year: year, month: month, day: clampedDay))
            .map { calendar.startOfDay(for: $0) }
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
