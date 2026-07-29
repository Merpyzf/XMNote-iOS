/**
 * [INPUT]: 依赖 AppDatabase/GRDB 的统计事件、阅读记录与 read_target 表，并接收本地时区、时钟和最近目标偏好闭包
 * [OUTPUT]: 对外提供 Android StatisticsWebService 的月/周阅读、阅读节律和目标设置数据快照
 * [POS]: Data 层网页统计专用仓储；独立复刻 Android 统计路径，不让 XMNoteWeb 接触 GRDB
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

nonisolated enum DesktopWebStatisticsRepositoryError: Error, Sendable, Equatable {
    case invalidDate
    case invalidDateInput(String)
    case invalidYear
    case negativeDailyTarget
}

nonisolated struct DesktopWebStatisticsTrendSnapshot: Sendable, Equatable {
    let label: Int
    let value: Int
}

nonisolated struct DesktopWebMonthlyReadingSnapshot: Sendable, Equatable {
    struct Day: Sendable, Equatable {
        let day: Int
        let date: String
        let readTime: Int64
    }

    let year: Int
    let month: Int
    let totalReadTime: Int64
    let daysInMonth: Int
    let dailyReadingTimes: [Day]
}

nonisolated struct DesktopWebWeeklyReadingSnapshot: Sendable, Equatable {
    struct Day: Sendable, Equatable {
        let dayOfWeek: Int
        let date: String
        let readTime: Int64
        let hasReading: Bool
    }

    let totalReadTime: Int64
    let weekStart: String
    let weekEnd: String
    let days: [Day]
    let currentStreak: Int
}

nonisolated struct DesktopWebReadingRhythmSnapshot: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let id: String
        let label: String
        let startHour: Int
        let endHour: Int
        let readTime: Int64
        let ratio: Double
    }

    let totalReadTime: Int64
    let segments: [Segment]
    let peakSegmentIDs: [String]
    let rhythmType: String
    let rhythmLabel: String
    let rhythmDescription: String
    let mostFrequentTime: String?
    let hasTimedData: Bool
    let scopeTotalReadTime: Int64
    let accurateReadTime: Int64
    let fuzzyReadTime: Int64
}

nonisolated struct DesktopWebReadTargetSnapshot: Sendable, Equatable {
    let year: Int
    let target: Int
}

nonisolated struct DesktopWebDailyReadingTargetSnapshot: Sendable, Equatable {
    let target: Int
    let todayReadingTime: Int
}

nonisolated struct DesktopWebYearlyBookSnapshot: Sendable, Equatable {
    let book: DesktopWebBookSnapshot
    let readDoneTime: Int64
}

nonisolated struct DesktopWebStatisticsRepository: Sendable {
    struct TimeScope: Sendable, Equatable {
        let start: Int64
        let end: Int64
        let isAll: Bool
    }

    struct ReadRecord: Sendable, Equatable {
        let id: Int64
        let bookID: Int64
        let startTime: Int64
        let endTime: Int64
        let elapsedSeconds: Int64
        let fuzzyReadDate: Int64

        var eventTime: Int64 { fuzzyReadDate != 0 ? fuzzyReadDate : startTime }
    }

    private struct RhythmSegmentMeta: Sendable {
        let id: String
        let label: String
        let startHour: Int
        let endHour: Int
        let rhythmType: String
        let rhythmLabel: String
        let rhythmDescription: String
    }

    let database: AppDatabase
    let bookRepository: DesktopWebBookRepository
    let calendar: Calendar
    let currentTimeMillis: @Sendable () -> Int64
    let latestDailyTarget: @Sendable () -> Int
    let saveLatestDailyTarget: @Sendable (Int) -> Void

    private static let rhythmSegments = [
        RhythmSegmentMeta(
            id: "late_night", label: "深夜", startHour: 0, endHour: 6,
            rhythmType: "late_night_reader", rhythmLabel: "深夜读者",
            rhythmDescription: "夜色最深的时候，你仍愿意把时间留给阅读。"
        ),
        RhythmSegmentMeta(
            id: "early_morning", label: "清晨", startHour: 6, endHour: 9,
            rhythmType: "early_morning_reader", rhythmLabel: "清晨读者",
            rhythmDescription: "许多人刚醒来时，你已经在阅读中进入状态。"
        ),
        RhythmSegmentMeta(
            id: "morning", label: "上午", startHour: 9, endHour: 12,
            rhythmType: "daytime_reader", rhythmLabel: "白昼读者",
            rhythmDescription: "白天的节奏里，你把阅读安排在稳定而清醒的时段。"
        ),
        RhythmSegmentMeta(
            id: "afternoon", label: "下午", startHour: 12, endHour: 18,
            rhythmType: "afternoon_reader", rhythmLabel: "午后读者",
            rhythmDescription: "午后的时间被你留给阅读，节奏平稳且持续。"
        ),
        RhythmSegmentMeta(
            id: "evening", label: "傍晚", startHour: 18, endHour: 21,
            rhythmType: "evening_reader", rhythmLabel: "傍晚读者",
            rhythmDescription: "一天将尽的时段里，你常把注意力留给书本。"
        ),
        RhythmSegmentMeta(
            id: "night", label: "夜晚", startHour: 21, endHour: 24,
            rhythmType: "night_reader", rhythmLabel: "夜读者",
            rhythmDescription: "当城市渐渐安静，你的阅读才真正展开。"
        )
    ]

    /// 注入数据库、书籍投影与设置闭包；所有数据库工作在 GRDB 连接池执行，已提交写入不因调用任务取消而回滚。
    init(
        database: AppDatabase,
        bookRepository: DesktopWebBookRepository,
        calendar: Calendar = .current,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        latestDailyTarget: @escaping @Sendable () -> Int = { 3_600 },
        saveLatestDailyTarget: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.database = database
        self.bookRepository = bookRepository
        self.calendar = calendar
        self.currentTimeMillis = currentTimeMillis
        self.latestDailyTarget = latestDailyTarget
        self.saveLatestDailyTarget = saveLatestDailyTarget
    }

    /// 统计指定自然月每天的阅读秒数；准确计时先按跨日墙钟比例拆分，再与模糊日期记录合并。
    func monthlyReading(year: Int, month: Int) async throws -> DesktopWebMonthlyReadingSnapshot {
        guard year > 0 else {
            throw DesktopWebStatisticsRepositoryError.invalidDateInput("year 必须大于 0")
        }
        guard (1...12).contains(month) else {
            throw DesktopWebStatisticsRepositoryError.invalidDateInput("month 必须在 1 到 12 之间")
        }
        let range = try monthRange(year: year, month: month)
        let dayMap = try await dayReadingTimes(range: range)
        let days = dayMap.keys.sorted().map { date in
            DesktopWebMonthlyReadingSnapshot.Day(
                day: calendar.component(.day, from: date),
                date: dateString(date),
                readTime: dayMap[date] ?? 0
            )
        }
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else {
            throw DesktopWebStatisticsRepositoryError.invalidDate
        }
        return DesktopWebMonthlyReadingSnapshot(
            year: year,
            month: month,
            totalReadTime: days.reduce(0) { $0 + $1.readTime },
            daysInMonth: dayRange.count,
            dailyReadingTimes: days
        )
    }

    /// 统计周一到周日阅读数据；历史周锚定周末，当前周只锚定今天。
    func weeklyReading(weekStart: String?) async throws -> DesktopWebWeeklyReadingSnapshot {
        let monday: Date
        if let weekStart {
            monday = try parseDate(weekStart)
        } else {
            monday = startOfWeek(for: Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000))
        }
        let mondayMillis = millis(monday)
        let sundayProbe = Date(timeIntervalSince1970: Double(mondayMillis + 6 * 86_400_000) / 1_000)
        let sunday = calendar.startOfDay(for: sundayProbe)
        guard let dayAfterSunday = calendar.date(byAdding: .day, value: 1, to: sunday) else {
            throw DesktopWebStatisticsRepositoryError.invalidDate
        }
        let sundayEnd = millis(dayAfterSunday) - 1
        let range = mondayMillis...sundayEnd
        let readTimes = try await dayReadingTimes(range: range)
        var days: [DesktopWebWeeklyReadingSnapshot.Day] = []
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
            let readTime = readTimes[calendar.startOfDay(for: date)] ?? 0
            days.append(.init(dayOfWeek: offset + 1, date: dateString(date), readTime: readTime, hasReading: readTime > 0))
        }

        let today = calendar.startOfDay(
            for: Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000)
        )
        let streakAnchor = min(today, sunday)
        let streakStart = calendar.date(byAdding: .day, value: -60, to: streakAnchor) ?? monday
        let streakTimes = try await dayReadingTimes(range: millis(streakStart)...sundayEnd)
        let activeDates = Set(streakTimes.filter { $0.value > 0 }.map { calendar.startOfDay(for: $0.key) })
        var streak = 0
        var checkDate = streakAnchor
        while activeDates.contains(checkDate) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = previous
        }

        return DesktopWebWeeklyReadingSnapshot(
            totalReadTime: days.reduce(0) { $0 + $1.readTime },
            weekStart: dateString(monday),
            weekEnd: dateString(sunday),
            days: days,
            currentStreak: streak
        )
    }

    /// 将统计范围内准确计时按六个时段分摊，模糊日期只计入范围总时长而不进入节律图。
    func readingRhythm(year: Int, month: Int, weekStart: String?) async throws -> DesktopWebReadingRhythmSnapshot {
        let scope = try await timeScope(year: year, month: month, weekStart: weekStart)
        let allRecords = try await readRecords()
        let records = allRecords.filter { record in
            record.elapsedSeconds > 0
                && record.eventTime > 0
                && (scope.isAll || scope.start...scope.end ~= record.eventTime)
        }
        let accurate = records.filter { $0.fuzzyReadDate == 0 }.reduce(Int64(0)) { $0 + $1.elapsedSeconds }
        let fuzzy = records.filter { $0.fuzzyReadDate != 0 }.reduce(Int64(0)) { $0 + $1.elapsedSeconds }
        var segmentSeconds = Array(repeating: Int64(0), count: Self.rhythmSegments.count)
        var bucketCounts: [Int: Int] = [:]
        for record in records where record.fuzzyReadDate == 0 {
            allocate(record: record, to: &segmentSeconds)
            let components = calendar.dateComponents(
                [.hour, .minute],
                from: Date(timeIntervalSince1970: Double(record.startTime) / 1_000)
            )
            let bucket = ((components.hour ?? 0) * 60 + (components.minute ?? 0)) / 5
            bucketCounts[bucket, default: 0] += 1
        }
        let timedTotal = segmentSeconds.reduce(0, +)
        let segments = Self.rhythmSegments.enumerated().map { index, meta in
            DesktopWebReadingRhythmSnapshot.Segment(
                id: meta.id,
                label: meta.label,
                startHour: meta.startHour,
                endHour: meta.endHour,
                readTime: segmentSeconds[index],
                ratio: timedTotal > 0 ? Double(segmentSeconds[index]) / Double(timedTotal) : 0
            )
        }
        let ranked = segmentSeconds.enumerated()
            .filter { $0.element > 0 }
            .sorted { lhs, rhs in lhs.element == rhs.element ? lhs.offset < rhs.offset : lhs.element > rhs.element }
        var peaks: [String] = []
        let primary = ranked.first.map { Self.rhythmSegments[$0.offset] }
        if let first = ranked.first {
            peaks.append(Self.rhythmSegments[first.offset].id)
            if let second = ranked.dropFirst().first,
               Double(first.element - second.element) / Double(first.element) <= 0.10 {
                peaks.append(Self.rhythmSegments[second.offset].id)
            }
        }
        let bestBucket = bucketCounts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key
        return DesktopWebReadingRhythmSnapshot(
            totalReadTime: timedTotal,
            segments: segments,
            peakSegmentIDs: peaks,
            rhythmType: primary?.rhythmType ?? "unknown",
            rhythmLabel: primary?.rhythmLabel ?? "阅读节律待生成",
            rhythmDescription: primary?.rhythmDescription ?? "记录到更多阅读时长后，这里会展示你的阅读节律标签。",
            mostFrequentTime: bestBucket.map(formatBucket),
            hasTimedData: timedTotal > 0,
            scopeTotalReadTime: accurate + fuzzy,
            accurateReadTime: accurate,
            fuzzyReadTime: fuzzy
        )
    }

    /// 读取全部年度目标；保持 Room 无显式排序的行顺序和 Int 截断合同。
    func readTargets() async throws -> [DesktopWebReadTargetSnapshot] {
        try await database.dbPool.read { db in
            // SQL 目的：复刻 ReadTargetDao.queryAll(type=0) 读取全部有效年度目标。
            // 涉及表：read_target；不增加排序，保留 SQLite 当前行顺序。
            // 时间字段：time 直接保存年份整数，不是毫秒时间戳。
            // 返回字段用途：WebReadTargetDto 列表。
            try Row.fetchAll(
                db,
                sql: "SELECT time, target FROM read_target WHERE is_deleted = 0 AND type = 0"
            ).map {
                DesktopWebReadTargetSnapshot(year: Int($0["time"] as Int64), target: Int($0["target"] as Int64))
            }
        }
    }

    /// 读取指定年度目标；缺失时返回 Android 默认的 12 本，不产生写入。
    func readTarget(year: Int) async throws -> DesktopWebReadTargetSnapshot {
        let actualYear = year == 0
            ? calendar.component(
                .year,
                from: Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000)
            )
            : year
        let target = try await database.dbPool.read { db in
            // SQL 目的：复刻 ReadTargetDao.queryReadTarget(year, type=0)。
            // 涉及表：read_target；只取未删除首行。
            // 时间字段：time 是年份整数。
            // 返回字段用途：缺失时由上层使用默认 12。
            try Int64.fetchOne(
                db,
                sql: "SELECT target FROM read_target WHERE time = ? AND type = 0 AND is_deleted = 0 LIMIT 1",
                arguments: [actualYear]
            )
        }
        return DesktopWebReadTargetSnapshot(year: actualYear, target: Int(target ?? 12))
    }

    /// 只接受正年份和 1...365 的年度目标。
    func setReadTarget(year: Int, target: Int) async throws -> DesktopWebReadTargetSnapshot {
        guard year > 0 else {
            throw DesktopWebStatisticsRepositoryError.invalidDateInput("year 必须大于 0")
        }
        guard (1...365).contains(target) else {
            throw DesktopWebStatisticsRepositoryError.invalidDateInput("年度阅读目标必须在 1 到 365 之间")
        }
        try await upsertReadTarget(time: Int64(year), target: Int64(target), type: 0)
        return DesktopWebReadTargetSnapshot(year: year, target: target)
    }

    /// 读取年度目标庆祝展示状态；year 非正数沿用 Android 业务错误。
    func yearlyGoalCelebration(year: Int) async throws -> Bool {
        guard year > 0 else { throw DesktopWebStatisticsRepositoryError.invalidYear }
        let target = try await database.dbPool.read { db in
            // SQL 目的：读取 Web 年度目标庆祝标记，type=2 且 target=1 表示已展示。
            // 涉及表：read_target；time 是年份整数。
            // 返回字段用途：WebYearlyGoalCelebrationDto.shown。
            try Int64.fetchOne(
                db,
                sql: "SELECT target FROM read_target WHERE time = ? AND type = 2 AND is_deleted = 0 LIMIT 1",
                arguments: [year]
            )
        }
        return target == 1
    }

    /// 幂等写入年度目标庆祝标记；已有 target=1 时不更新记录。
    func markYearlyGoalCelebration(year: Int) async throws {
        guard year > 0 else { throw DesktopWebStatisticsRepositoryError.invalidYear }
        try await upsertReadTarget(time: Int64(year), target: 1, type: 2)
    }

    /// 读取今日目标并在缺失时用最近偏好创建 type=1 记录，保持 Android GET 的写副作用。
    func dailyReadingTarget() async throws -> DesktopWebDailyReadingTargetSnapshot {
        // NOTE(ANDROID-WEB-061): GET 会插入 read_target，重试、预取或只读访问都会改变数据库。
        let now = Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000)
        let dayStart = calendar.startOfDay(for: now)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw DesktopWebStatisticsRepositoryError.invalidDate
        }
        let dayStartMillis = millis(dayStart)
        let target = try await ensureDailyTarget(dayStartMillis: dayStartMillis)
        let readTime = try await dayReadingTimes(range: dayStartMillis...(millis(nextDay) - 1))
            .values.reduce(0, +)
        return DesktopWebDailyReadingTargetSnapshot(target: target, todayReadingTime: Int(readTime))
    }

    /// 写入今日目标并同步“最近目标”偏好；仅拒绝负数，target=0 是 Android 允许的关闭语义。
    func setDailyReadingTarget(_ target: Int) async throws -> DesktopWebDailyReadingTargetSnapshot {
        guard target >= 0 else {
            throw DesktopWebStatisticsRepositoryError.negativeDailyTarget
        }
        let now = Date(timeIntervalSince1970: Double(currentTimeMillis()) / 1_000)
        let dayStartMillis = millis(calendar.startOfDay(for: now))
        try await upsertReadTarget(time: dayStartMillis, target: Int64(target), type: 1)
        saveLatestDailyTarget(target)
        return try await dailyReadingTarget()
    }
}

nonisolated extension DesktopWebStatisticsRepository {
    /// 解析 Android 的 all/week/month/year 优先级并生成本地时区毫秒闭区间。
    func timeScope(year: Int, month: Int, weekStart: String?) async throws -> TimeScope {
        if year == 0, month == 0, weekStart == nil {
            return TimeScope(start: try await earliestStatisticsTimestamp(), end: currentTimeMillis(), isAll: true)
        }
        if let weekStart {
            let start = try parseDate(weekStart)
            guard let end = calendar.date(byAdding: .day, value: 7, to: start) else {
                throw DesktopWebStatisticsRepositoryError.invalidDate
            }
            return TimeScope(start: millis(start), end: millis(end) - 1, isAll: false)
        }
        if month > 0, year > 0 {
            let range = try monthRange(year: year, month: month)
            return TimeScope(start: range.lowerBound, end: range.upperBound, isAll: false)
        }
        let range = try yearRange(year)
        return TimeScope(start: range.lowerBound, end: range.upperBound, isAll: false)
    }

    func monthRange(year: Int, month: Int) throws -> ClosedRange<Int64> {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else {
            throw DesktopWebStatisticsRepositoryError.invalidDate
        }
        return millis(start)...(millis(end) - 1)
    }

    func yearRange(_ year: Int) throws -> ClosedRange<Int64> {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else {
            throw DesktopWebStatisticsRepositoryError.invalidDate
        }
        return millis(start)...(millis(end) - 1)
    }

    /// 生成热力图专用自然年完整毫秒闭区间。
    func heatmapYearRange(_ year: Int) throws -> ClosedRange<Int64> {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else {
            throw DesktopWebStatisticsRepositoryError.invalidDate
        }
        return millis(start)...(millis(end) - 1)
    }

    func earliestStatisticsTimestamp() async throws -> Int64 {
        try await database.dbPool.read { db in
            // SQL 目的：复刻 StatisticsRepository.getEarliestStatisticsTimestamp 的六类最早事件合并。
            // 涉及表：book、note、read_time_record、check_in_record；均只消费未删除有效业务数据。
            // 时间字段：阅读记录优先 fuzzy_read_date，否则 start_time；其余均为毫秒时间戳。
            // 返回字段用途：all-time 统计起点；全空时回退当前时间。
            let sql = """
                SELECT MIN(value) FROM (
                    SELECT MIN(created_date) AS value FROM book WHERE is_deleted = 0 AND id != 0 AND created_date > 0
                    UNION ALL SELECT MIN(read_status_changed_date) FROM book WHERE is_deleted = 0 AND id != 0 AND read_status_changed_date > 0
                    UNION ALL SELECT MIN(created_date) FROM note WHERE is_deleted = 0 AND created_date > 0
                    UNION ALL SELECT MIN(CASE WHEN fuzzy_read_date != 0 THEN fuzzy_read_date ELSE start_time END)
                        FROM read_time_record WHERE is_deleted = 0 AND status = 3 AND book_id != 0
                    UNION ALL SELECT MIN(purchase_date) FROM book WHERE is_deleted = 0 AND id != 0 AND purchase_date > 0
                    UNION ALL SELECT MIN(checkin_date) FROM check_in_record
                ) WHERE value > 0
                """
            return try Int64.fetchOne(db, sql: sql) ?? currentTimeMillis()
        }
    }

    func dayReadingTimes(range: ClosedRange<Int64>) async throws -> [Date: Int64] {
        let records = try await readRecords()
        var result: [Date: Int64] = [:]
        for record in records where range ~= record.eventTime {
            let day = calendar.startOfDay(
                for: Date(timeIntervalSince1970: Double(record.eventTime) / 1_000)
            )
            result[day, default: 0] += record.elapsedSeconds
        }
        return result
    }

    func rawReadRecords() async throws -> [ReadRecord] {
        try await database.dbPool.read { db in
            // SQL 目的：读取 Android TimingRecordRepository.queryAllTimingRecords 的完整统计输入。
            // 涉及表：read_time_record；过滤已完成 status=3、未删除且非占位书籍记录。
            // 时间字段：start/end/fuzzy 均为毫秒；elapsed_seconds 为秒。
            // 返回字段用途：热力图保持原始记录归日，其他统计可在调用侧继续做跨日拆分。
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, book_id, start_time, end_time, elapsed_seconds, fuzzy_read_date
                    FROM read_time_record
                    WHERE status = 3 AND is_deleted = 0 AND book_id != 0
                    ORDER BY start_time ASC
                    """
            ).map {
                ReadRecord(
                    id: $0["id"], bookID: $0["book_id"], startTime: $0["start_time"],
                    endTime: $0["end_time"], elapsedSeconds: $0["elapsed_seconds"],
                    fuzzyReadDate: $0["fuzzy_read_date"]
                )
            }
        }
    }

    func readRecords() async throws -> [ReadRecord] {
        try await rawReadRecords().flatMap(splitCrossDay)
    }

    func parseDate(_ value: String) throws -> Date {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            throw DesktopWebStatisticsRepositoryError.invalidDateInput(
                javaLocalDateParseMessage(value)
            )
        }
        return calendar.startOfDay(for: date)
    }

    /// 复刻 `LocalDate.parse` 暴露给 Web 的异常消息，避免 Foundation 错误文本成为跨平台合同。
    func javaLocalDateParseMessage(_ value: String) -> String {
        let characters = Array(value)
        if characters.count > 10,
           isFourDigitYear(characters),
           characters[4] == "-",
           characters[5].isNumber,
           characters[6].isNumber,
           characters[7] == "-",
           characters[8].isNumber,
           characters[9].isNumber {
            return "Text '\(value)' could not be parsed, unparsed text found at index 10"
        }

        guard characters.count == 10 else {
            return "Text '\(value)' could not be parsed at index \(javaDateParseFailureIndex(characters))"
        }
        guard isFourDigitYear(characters) else {
            let index = characters.first == "-" ? 1 : 0
            return "Text '\(value)' could not be parsed at index \(index)"
        }
        guard characters[4] == "-" else {
            return "Text '\(value)' could not be parsed at index 4"
        }
        guard characters[5].isNumber, characters[6].isNumber else {
            return "Text '\(value)' could not be parsed at index 5"
        }
        guard characters[7] == "-" else {
            return "Text '\(value)' could not be parsed at index 7"
        }
        guard characters[8].isNumber, characters[9].isNumber else {
            return "Text '\(value)' could not be parsed at index 8"
        }

        let year = Int(String(characters[0...3])) ?? 0
        let month = Int(String(characters[5...6])) ?? 0
        let day = Int(String(characters[8...9])) ?? 0
        guard 1...12 ~= month else {
            return "Invalid value for MonthOfYear (valid values 1 - 12): \(month)"
        }
        guard 1...31 ~= day else {
            return "Invalid value for DayOfMonth (valid values 1 - 28/31): \(day)"
        }

        let monthNames = [
            "", "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
            "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"
        ]
        let monthLengths = [
            0, 31, isGregorianLeapYear(year) ? 29 : 28, 31, 30, 31, 30,
            31, 31, 30, 31, 30, 31
        ]
        if month == 2, day == 29, !isGregorianLeapYear(year) {
            return "Invalid date 'February 29' as '\(year)' is not a leap year"
        }
        if day > monthLengths[month] {
            return "Invalid date '\(monthNames[month]) \(day)'"
        }
        return "Text '\(value)' could not be parsed at index 0"
    }

    func positiveMillisecondRemainder(_ value: Int64) -> Int64 {
        let remainder = value % 1_000
        return remainder >= 0 ? remainder : remainder + 1_000
    }

    private func isFourDigitYear(_ characters: [Character]) -> Bool {
        characters.count >= 4 && characters[0...3].allSatisfy(\.isNumber)
    }

    private func javaDateParseFailureIndex(_ characters: [Character]) -> Int {
        guard !characters.isEmpty else { return 0 }
        if characters.first == "-" { return min(1, characters.count) }
        if characters.count < 4 || !characters.prefix(min(4, characters.count)).allSatisfy(\.isNumber) {
            return 0
        }
        if characters.count == 4 { return 4 }
        if characters[4] != "-" { return 4 }
        if characters.count <= 5 { return 5 }
        if !characters[5].isNumber { return 5 }
        if characters.count <= 6 || !characters[6].isNumber { return 5 }
        if characters.count <= 7 || characters[7] != "-" { return 7 }
        if characters.count <= 8 || !characters[8].isNumber { return 8 }
        if characters.count <= 9 || !characters[9].isNumber { return 8 }
        return 0
    }

    private func isGregorianLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
    }

    func dateString(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    func dateComponent(_ component: Calendar.Component, millis: Int64) -> Int {
        calendar.component(component, from: Date(timeIntervalSince1970: Double(millis) / 1_000))
    }

    private func startOfWeek(for date: Date) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    private func splitCrossDay(_ record: ReadRecord) -> [ReadRecord] {
        guard record.fuzzyReadDate == 0 else { return [record] }
        let startDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(record.startTime) / 1_000))
        let endDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(record.endTime) / 1_000))
        guard startDate != endDate else { return [record] }
        let wallTotal = record.endTime - record.startTime
        guard wallTotal > 0, record.elapsedSeconds > 0 else { return [] }

        var results: [ReadRecord] = []
        var allocated: Int64 = 0
        var cursor = record.startTime
        var date = startDate
        while date <= endDate, allocated < record.elapsedSeconds {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            let segmentStart = max(cursor, millis(date))
            let segmentEnd = min(record.endTime, millis(nextDay) - 1)
            if segmentStart < segmentEnd {
                let ratio = Double(segmentEnd - segmentStart) / Double(wallTotal)
                var seconds = Int64((ratio * Double(record.elapsedSeconds)).rounded())
                seconds = min(seconds, record.elapsedSeconds - allocated)
                allocated += seconds
                results.append(
                    ReadRecord(
                        id: record.id, bookID: record.bookID, startTime: segmentStart,
                        endTime: segmentEnd, elapsedSeconds: seconds, fuzzyReadDate: 0
                    )
                )
                cursor = segmentEnd + 1
            }
            date = nextDay
        }
        return results
    }

    private func allocate(record: ReadRecord, to segmentSeconds: inout [Int64]) {
        guard record.startTime > 0, record.elapsedSeconds > 0 else { return }
        let end = record.endTime > record.startTime
            ? record.endTime
            : record.startTime + record.elapsedSeconds * 1_000
        guard end > record.startTime else { return }
        var wall = Array(repeating: Int64(0), count: Self.rhythmSegments.count)
        var dayStart = millis(calendar.startOfDay(
            for: Date(timeIntervalSince1970: Double(record.startTime) / 1_000)
        ))
        // TODO(ANDROID-WEB-066): Android 用固定 24 小时推进自然日，夏令时切换日会错配本地时段。
        while dayStart < end {
            let nextDayStart = dayStart + 86_400_000
            let activeStart = max(record.startTime, dayStart)
            let activeEnd = min(end, nextDayStart)
            if activeEnd > activeStart {
                for (index, meta) in Self.rhythmSegments.enumerated() {
                    let start = dayStart + Int64(meta.startHour) * 3_600_000
                    let finish = dayStart + Int64(meta.endHour) * 3_600_000
                    wall[index] += max(0, min(activeEnd, finish) - max(activeStart, start))
                }
            }
            dayStart = nextDayStart
        }
        let totalWall = wall.reduce(0, +)
        guard totalWall > 0 else {
            segmentSeconds[segmentIndex(for: record.startTime)] += record.elapsedSeconds
            return
        }
        var allocated = Array(repeating: Int64(0), count: wall.count)
        var fractions: [(index: Int, value: Double)] = []
        var floorTotal: Int64 = 0
        for index in wall.indices where wall[index] > 0 {
            let exact = Double(record.elapsedSeconds) * Double(wall[index]) / Double(totalWall)
            let base = Int64(floor(exact))
            allocated[index] = base
            floorTotal += base
            fractions.append((index, exact - Double(base)))
        }
        fractions.sort { lhs, rhs in lhs.value == rhs.value ? lhs.index > rhs.index : lhs.value > rhs.value }
        var remainder = record.elapsedSeconds - floorTotal
        var cursor = 0
        while remainder > 0, !fractions.isEmpty {
            allocated[fractions[cursor % fractions.count].index] += 1
            cursor += 1
            remainder -= 1
        }
        if remainder > 0 { allocated[segmentIndex(for: record.startTime)] += remainder }
        for index in allocated.indices { segmentSeconds[index] += allocated[index] }
    }

    private func segmentIndex(for millis: Int64) -> Int {
        let hour = dateComponent(.hour, millis: millis)
        return Self.rhythmSegments.firstIndex { hour >= $0.startHour && hour < $0.endHour }
            ?? Self.rhythmSegments.indices.last!
    }

    private func formatBucket(_ bucket: Int) -> String {
        let minutes = bucket * 5
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func upsertReadTarget(time: Int64, target: Int64, type: Int) async throws {
        try await database.dbPool.write { db in
            // SQL 目的：复刻 ReadTargetDao.queryReadTarget 后的 @Update/@Insert 分支。
            // 涉及表：read_target；只匹配未删除首行，Android 不维护本次写入的审计时间。
            // 时间字段：年度类型保存年份，日目标保存本地自然日零点毫秒。
            // 副作用：命中时只改 target；缺失时其余 BaseEntity 字段均写 0。
            let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM read_target WHERE time = ? AND type = ? AND is_deleted = 0 LIMIT 1",
                arguments: [time, type]
            )
            if let id {
                try db.execute(sql: "UPDATE read_target SET target = ? WHERE id = ?", arguments: [target, id])
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO read_target
                            (time, target, type, created_date, updated_date, last_sync_date, is_deleted)
                        VALUES (?, ?, ?, 0, 0, 0, 0)
                        """,
                    arguments: [time, target, type]
                )
            }
        }
    }

    private func ensureDailyTarget(dayStartMillis: Int64) async throws -> Int {
        if let target = try await database.dbPool.read({ db in
            // SQL 目的：读取今日每日阅读目标；仅匹配 type=1 的未删除首行。
            // 涉及表：read_target；time 是本地自然日零点毫秒。
            // 返回字段用途：存在时避免 GET 产生重复插入。
            try Int64.fetchOne(
                db,
                sql: "SELECT target FROM read_target WHERE time = ? AND type = 1 AND is_deleted = 0 LIMIT 1",
                arguments: [dayStartMillis]
            )
        }) {
            return Int(target)
        }
        let target = latestDailyTarget()
        try await upsertReadTarget(time: dayStartMillis, target: Int64(target), type: 1)
        return target
    }
}
