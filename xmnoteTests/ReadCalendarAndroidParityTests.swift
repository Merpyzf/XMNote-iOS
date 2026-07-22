import Foundation
import GRDB
import Testing
@testable import xmnote

/// 以 Android 阅读日历仓储的既有行为为真值，锁定 iOS 查询边界、聚合口径与排序规则。
@MainActor
struct ReadCalendarAndroidParityTests {
    @Test
    func earliestDateUsesGlobalStatisticsSourcesAndIgnoresDisplayFilters() async throws {
        let harness = try Self.makeHarness()
        let bookCreatedAt = Self.date(2020, 1, 3, hour: 9)
        let noteCreatedAt = Self.date(2024, 6, 8, hour: 10)

        try await harness.write { db in
            try Self.insertBook(db, id: 91_001, name: "最早建书", createdAt: bookCreatedAt)
            try Self.insertNote(db, bookID: 91_001, createdAt: noteCreatedAt)
        }

        let unfiltered = try await harness.repository.fetchEarliestDate(excludedEventTypes: [])
        let noteExcluded = try await harness.repository.fetchEarliestDate(excludedEventTypes: [.note])
        let expected = Calendar.current.startOfDay(for: bookCreatedAt)

        // Android StatisticsRepository 的可用月份下界包含 book.created_date，且不受阅读日历展示筛选影响。
        #expect(unfiltered == expected)
        #expect(noteExcluded == expected)
    }

    @Test
    func currentMonthKeepsRowsThroughNaturalMonthEnd() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let futureDay = calendar.date(byAdding: .day, value: 1, to: today),
              calendar.isDate(futureDay, equalTo: today, toGranularity: .month) else {
            // 月末没有“本月未来日”可构造；代码审查仍覆盖该边界，运行态用例留到非月末执行。
            return
        }

        let harness = try Self.makeHarness()
        let eventTime = calendar.date(byAdding: .hour, value: 12, to: futureDay) ?? futureDay
        try await harness.write { db in
            try Self.insertBook(db, id: 91_002, name: "未来日记录")
            try Self.insertNote(db, bookID: 91_002, createdAt: eventTime)
        }

        let data = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(today),
            excludedEventTypes: []
        )
        let day = data.days[calendar.startOfDay(for: futureDay)]

        // Android 始终查询完整自然月；未来月份由年度展示层遮罩，而不是截断当前月 SQL 范围。
        #expect(day?.noteCount == 1)
        #expect(day?.books.map(\.id) == [91_002])
    }

    @Test
    func zeroDurationFinishedTimingStillCreatesAnActivityDay() async throws {
        let harness = try Self.makeHarness()
        let eventTime = Self.date(2024, 4, 9, hour: 20)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_003, name: "零时长记录")
            try Self.insertTiming(
                db,
                id: 92_003,
                bookID: 91_003,
                startAt: eventTime,
                endAt: eventTime.addingTimeInterval(1),
                elapsedSeconds: 0
            )
        }

        let data = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(eventTime),
            excludedEventTypes: []
        )
        let day = data.days[Calendar.current.startOfDay(for: eventTime)]

        // Android 会保留 status=3 的零时长计时作为书籍活动，只是不增加阅读秒数。
        #expect(day?.books.map(\.id) == [91_003])
        #expect(day?.readSeconds == 0)
        #expect(data.readingDurationTopBooks.isEmpty)
        #expect(data.summary.peakTimeSlot == nil)
    }

    @Test
    func monthSummaryIncludesPreviousPeriodDeltas() async throws {
        let harness = try Self.makeHarness()
        let previousMonthDay = Self.date(2024, 5, 6, hour: 9)
        let currentMonthDay1 = Self.date(2024, 6, 7, hour: 9)
        let currentMonthDay2 = Self.date(2024, 6, 8, hour: 9)

        try await harness.write { db in
            try Self.insertBook(db, id: 91_004, name: "月环比")
            try Self.insertNote(db, bookID: 91_004, createdAt: previousMonthDay)
            try Self.insertNote(db, bookID: 91_004, createdAt: currentMonthDay1)
            try Self.insertNote(db, bookID: 91_004, createdAt: currentMonthDay2)
        }

        let data = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(currentMonthDay1),
            excludedEventTypes: []
        )

        // Android buildComposeMonthData 同步查询上月，当前月 2 个活跃日相对上月 1 个活跃日应为 +1。
        #expect(data.summary.activeDays == 2)
        #expect(data.summary.activeDaysDelta == 1)
        #expect(data.summary.noteCountDelta == 1)
    }

    @Test
    func equalDurationRankingPreservesAndroidFirstEventOrder() async throws {
        let harness = try Self.makeHarness()
        let firstEvent = Self.date(2024, 7, 2, hour: 8)
        let secondEvent = Self.date(2024, 7, 2, hour: 9)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_005, name: "Zeta")
            try Self.insertBook(db, id: 91_006, name: "Alpha")
            try Self.insertFuzzyTiming(
                db,
                id: 92_005,
                bookID: 91_005,
                at: firstEvent,
                elapsedSeconds: 600
            )
            try Self.insertFuzzyTiming(
                db,
                id: 92_006,
                bookID: 91_006,
                at: secondEvent,
                elapsedSeconds: 600
            )
        }

        let data = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(firstEvent),
            excludedEventTypes: []
        )

        // Android LinkedHashMap + 稳定降序排序在时长相同时保留原始事件首次出现顺序。
        #expect(data.readingDurationTopBooks.map(\.bookId) == [91_005, 91_006])
    }

    @Test
    func currentYearRankingMasksFutureMonths() async throws {
        let calendar = Calendar.current
        let now = Date()
        let currentMonth = Self.monthStart(now)
        guard let futureMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth),
              calendar.component(.year, from: futureMonth) == calendar.component(.year, from: now) else {
            return
        }

        let harness = try Self.makeHarness()
        let futureEvent = calendar.date(byAdding: .day, value: 2, to: futureMonth) ?? futureMonth
        try await harness.write { db in
            try Self.insertBook(db, id: 91_007, name: "未来月份排行")
            try Self.insertFuzzyTiming(
                db,
                id: 92_007,
                bookID: 91_007,
                at: futureEvent,
                elapsedSeconds: 3_600
            )
        }

        let ranking = try await harness.repository.fetchYearTopBooks(
            year: calendar.component(.year, from: now),
            excludedEventTypes: [],
            limit: 10
        )

        // Android 年度排行仅聚合当前月及以前的有效月份，未来月份记录必须被遮罩。
        #expect(ranking.isEmpty)
    }

    @Test
    func yearSummaryAlwaysContainsTwelveMonthContributions() async throws {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let earliest = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let repository = EmptyCalendarFixtureRepository(earliestDate: earliest)
        let settings = ReadCalendarSettings()
        let viewModel = ReadCalendarViewModel(initialDate: Date(), settings: settings)

        await viewModel.loadIfNeeded(using: repository, colorRepository: EmptyColorRepository())
        await viewModel.prepareHeatmapYearIfNeeded(
            using: repository,
            colorRepository: EmptyColorRepository()
        )

        // Android 年视图固定返回 12 个贡献槽，未来月份使用零值遮罩。
        #expect(viewModel.yearSummaryState(for: year).monthContributions.count == 12)
    }

    @Test
    func dailySummaryUsesTheSameFilteredBookUniverseAsCalendar() async throws {
        let harness = try Self.makeHarness()
        let day = Self.date(2024, 8, 11, hour: 10)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_008, name: "仅书摘活动")
            try Self.insertNote(db, bookID: 91_008, createdAt: day)
        }

        let month = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(day),
            excludedEventTypes: [.note]
        )
        let summary = try await harness.repository.fetchDailySummary(
            for: day,
            excludedEventTypes: [.note]
        )

        #expect(month.days[Calendar.current.startOfDay(for: day)] == nil)
        // Android 先按日历筛选得到当日 bookIds，再查询单书指标；被排除的唯一事件不能把书带入二级页。
        #expect(summary.books.isEmpty)
    }

    @Test
    func dailySummaryKeepsAndroidAllMetricsAndReadDoneSnapshotMerge() async throws {
        let harness = try Self.makeHarness()
        let day = Self.date(2024, 8, 12, hour: 10)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_019, name: "筛选后可见")
            try Self.insertRelevant(db, bookID: 91_019, createdAt: day)
            try Self.insertNote(db, bookID: 91_019, createdAt: day.addingTimeInterval(60))
            try Self.insertFuzzyTiming(
                db,
                id: 92_019,
                bookID: 91_019,
                at: day.addingTimeInterval(120),
                elapsedSeconds: 600
            )
            try Self.insertBook(
                db,
                id: 91_020,
                name: "仅读完快照",
                readStatusID: 3,
                readStatusChangedAt: day.addingTimeInterval(180)
            )
        }

        let summary = try await harness.repository.fetchDailySummary(
            for: day,
            excludedEventTypes: [.note, .readTiming, .readDone]
        )

        // Android 先用筛选后的日历事件确定普通书籍，再查询入选书的全部指标；读完书籍由快照查询始终补入。
        #expect(summary.books.map(\.id) == [91_019, 91_020])
        let visibleBook = try #require(summary.books.first { $0.id == 91_019 })
        let readDoneBook = try #require(summary.books.first { $0.id == 91_020 })
        #expect(visibleBook.relevantCount == 1)
        #expect(visibleBook.noteCount == 1)
        #expect(visibleBook.readSeconds == 600)
        #expect(readDoneBook.readDoneCount == 1)
    }

    @Test
    func dailySummaryOrdersBooksByLatestActivity() async throws {
        let harness = try Self.makeHarness()
        let day = Self.date(2024, 9, 12)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_009, name: "早开始早结束")
            try Self.insertBook(db, id: 91_010, name: "晚结束")
            try Self.insertNote(db, bookID: 91_009, createdAt: day.addingTimeInterval(8 * 3_600))
            try Self.insertNote(db, bookID: 91_009, createdAt: day.addingTimeInterval(11 * 3_600))
            try Self.insertNote(db, bookID: 91_010, createdAt: day.addingTimeInterval(10 * 3_600))
            try Self.insertNote(db, bookID: 91_010, createdAt: day.addingTimeInterval(20 * 3_600))
        }

        let summary = try await harness.repository.fetchDailySummary(for: day)

        // Android 当日书籍沿用日历聚合的 latestEventTime 降序，而不是 firstEventTime 升序。
        #expect(summary.books.map(\.id) == [91_010, 91_009])
    }

    @Test
    func dailySummaryIncludesCurrentReadDoneSnapshotInBookUniverse() async throws {
        let harness = try Self.makeHarness()
        let changedAt = Self.date(2024, 10, 3, hour: 18)
        try await harness.write { db in
            try Self.insertBook(
                db,
                id: 91_011,
                name: "仅当前读完快照",
                readStatusID: 3,
                readStatusChangedAt: changedAt
            )
        }

        let summary = try await harness.repository.fetchDailySummary(for: changedAt)

        // Android 日历 bookIds 合并 book 当前 READ_DONE 快照；二级页即使无历史状态行也应保留该书。
        #expect(summary.books.map(\.id) == [91_011])
    }

    @Test
    func dailyTimingDetailReturnsAndroidSplitSegmentAndEndTimeOrderingKey() async throws {
        let harness = try Self.makeHarness()
        let firstDayStart = Self.date(2024, 11, 6)
        let start = firstDayStart.addingTimeInterval(23 * 3_600)
        let end = start.addingTimeInterval(2 * 3_600)
        let secondDay = Calendar.current.startOfDay(for: end)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_012, name: "跨日计时")
            try Self.insertTiming(
                db,
                id: 92_012,
                bookID: 91_012,
                startAt: start,
                endAt: end,
                elapsedSeconds: 7_200
            )
        }

        let records = try await harness.repository.fetchDailyBookRecords(
            for: secondDay,
            bookID: 91_012,
            filter: .readTiming,
            sortOrder: .descending
        )
        let record = try #require(records.first)
        guard case .readTiming(let timing) = record.event.kind else {
            Issue.record("预期返回计时记录")
            return
        }

        // Android 三级页返回 splitCrossDayRecords 生成的当日分段，并以精确计时 endTime 排序。
        #expect(timing.elapsedSeconds == 3_600)
        #expect(timing.startTime == Self.millis(secondDay))
        #expect(timing.endTime == Self.millis(end))
        #expect(record.event.timestamp == Self.millis(end))
    }

    @Test
    func shareBookExclusionRebuildsAllMonthMetrics() async throws {
        let harness = try Self.makeHarness()
        let eventTime = Self.date(2024, 12, 5, hour: 10)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_013, name: "分享排除")
            try Self.insertNote(db, bookID: 91_013, createdAt: eventTime)
        }

        let settings = ReadCalendarSettings()
        let wasNoteEnabled = settings.isBehaviorEnabled(.note)
        _ = settings.setBehavior(.note, isEnabled: true)
        defer { _ = settings.setBehavior(.note, isEnabled: wasNoteEnabled) }

        let viewModel = ReadCalendarShareViewModel(
            monthStart: eventTime,
            initialType: .monthEvent,
            settings: settings
        )
        await viewModel.loadIfNeeded(using: harness.repository)
        #expect(viewModel.snapshot?.monthData.summary.activeDays == 1)

        await viewModel.changeExcludedBooks([91_013], using: harness.repository)

        // Android changeExcludedBooks 会带 excludedBookIds 重跑月聚合，热力、摘要与排行都归零。
        #expect(viewModel.snapshot?.monthData.summary.activeDays == 0)
        #expect(viewModel.snapshot?.monthData.days.isEmpty == true)
    }

    @Test
    func shareYearMasksMonthsBeforeAccessibleBoundary() async throws {
        let harness = try Self.makeHarness()
        let calendar = Calendar.current
        let accessibleMonth = Self.monthStart(Self.date(2024, 6, 1))
        let january = Self.monthStart(Self.date(2024, 1, 1))
        try await harness.write { db in
            try Self.insertBook(db, id: 91_021, name: "锁定分享月份")
            try Self.insertBook(db, id: 91_022, name: "可访问分享月份")
            try Self.insertNote(db, bookID: 91_021, createdAt: january.addingTimeInterval(10 * 3_600))
            try Self.insertNote(db, bookID: 91_022, createdAt: accessibleMonth.addingTimeInterval(10 * 3_600))
        }

        let settings = ReadCalendarSettings()
        let wasNoteEnabled = settings.isBehaviorEnabled(.note)
        _ = settings.setBehavior(.note, isEnabled: true)
        defer { _ = settings.setBehavior(.note, isEnabled: wasNoteEnabled) }
        let viewModel = ReadCalendarShareViewModel(
            monthStart: accessibleMonth,
            initialType: .yearHeatmap,
            settings: settings
        )
        viewModel.updateAccessBoundary(minimumAccessibleMonthStart: accessibleMonth)
        await viewModel.loadIfNeeded(using: harness.repository)

        let januaryData = try #require(viewModel.snapshot?.yearMonths.first {
            calendar.isDate($0.monthStart, equalTo: january, toGranularity: .month)
        })
        let currentData = try #require(viewModel.snapshot?.yearMonths.first {
            calendar.isDate($0.monthStart, equalTo: accessibleMonth, toGranularity: .month)
        })
        #expect(januaryData.days.isEmpty)
        #expect(currentData.summary.activeDays == 1)
        #expect(viewModel.filterBooks.map(\.bookId) == [91_022])
    }

    @Test
    func yearRankingOnlyUsesExplicitlyAccessibleMonths() async throws {
        let harness = try Self.makeHarness()
        let lockedEvent = Self.date(2024, 1, 5, hour: 9)
        let accessibleEvent = Self.date(2024, 6, 5, hour: 9)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_015, name: "锁定月份书籍")
            try Self.insertBook(db, id: 91_016, name: "可访问月份书籍")
            try Self.insertFuzzyTiming(
                db,
                id: 92_015,
                bookID: 91_015,
                at: lockedEvent,
                elapsedSeconds: 7_200
            )
            try Self.insertFuzzyTiming(
                db,
                id: 92_016,
                bookID: 91_016,
                at: accessibleEvent,
                elapsedSeconds: 600
            )
        }

        let ranking = try await harness.repository.fetchYearTopBooks(
            year: 2024,
            excludedEventTypes: [],
            limit: 10,
            includedMonthStarts: [Self.monthStart(accessibleEvent)],
            excludedBookIDs: []
        )

        // Android 只用有效且未锁定月份生成年度排行，不因存在锁定月隐藏整个年度结果。
        #expect(ranking.map(\.bookId) == [91_016])
    }

    @Test
    func monthContributionsKeepAllBooksBeyondRankingLimit() async throws {
        let harness = try Self.makeHarness()
        let day = Self.date(2024, 2, 9, hour: 8)
        try await harness.write { db in
            for index in 0..<11 {
                let bookID = Int64(91_100 + index)
                try Self.insertBook(db, id: bookID, name: "贡献书籍\(index)")
                try Self.insertFuzzyTiming(
                    db,
                    id: Int64(92_100 + index),
                    bookID: bookID,
                    at: day.addingTimeInterval(Double(index * 60)),
                    elapsedSeconds: Int64((11 - index) * 100)
                )
            }
        }

        let data = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(day),
            excludedEventTypes: []
        )
        let smallestContribution = data.bookContributions.first { $0.bookId == 91_110 }

        // Android 排行最多十本，但分享筛选的贡献集合必须保留全部活跃书籍及真实时长。
        #expect(data.readingDurationTopBooks.count == 10)
        #expect(data.bookContributions.count == 11)
        #expect(smallestContribution?.readSeconds == 100)
        #expect(smallestContribution?.activeDays == 1)
    }

    @Test
    func equalPeakTimeSlotsKeepFirstEventSlot() async throws {
        let harness = try Self.makeHarness()
        let firstEvent = Self.date(2024, 3, 8, hour: 1)
        let secondEvent = Self.date(2024, 3, 8, hour: 20)
        try await harness.write { db in
            try Self.insertBook(db, id: 91_017, name: "峰值时段")
            try Self.insertFuzzyTiming(
                db,
                id: 92_017,
                bookID: 91_017,
                at: firstEvent,
                elapsedSeconds: 600
            )
            try Self.insertFuzzyTiming(
                db,
                id: 92_018,
                bookID: 91_017,
                at: secondEvent,
                elapsedSeconds: 600
            )
        }

        let data = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(firstEvent),
            excludedEventTypes: []
        )

        // Android LinkedHashMap 的 maxByOrNull 在同值时保留先出现的时段。
        #expect(data.summary.peakTimeSlot == .lateNight)
        #expect(data.summary.peakTimeSlotRatio == 50)
    }

    @Test
    func alignedEventQueriesKeepCountsFiltersHeatmapAndReadDoneDeduplication() async throws {
        let harness = try Self.makeHarness()
        let eventTime = Self.date(2023, 3, 14, hour: 9)
        try await harness.write { db in
            try Self.insertBook(
                db,
                id: 91_014,
                name: "已对齐聚合",
                readStatusID: 3,
                readStatusChangedAt: eventTime
            )
            try Self.insertNote(db, bookID: 91_014, createdAt: eventTime.addingTimeInterval(60))
            try Self.insertRelevant(db, bookID: 91_014, createdAt: eventTime.addingTimeInterval(120))
            try Self.insertReview(db, bookID: 91_014, createdAt: eventTime.addingTimeInterval(180))
            try Self.insertCheckIn(db, bookID: 91_014, amount: 4, at: eventTime.addingTimeInterval(240))
            try Self.insertFuzzyTiming(
                db,
                id: 92_014,
                bookID: 91_014,
                at: eventTime.addingTimeInterval(300),
                elapsedSeconds: 1_800
            )
            try Self.insertReadStatus(db, bookID: 91_014, statusID: 3, changedAt: eventTime)
        }

        let full = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(eventTime),
            excludedEventTypes: []
        )
        let dayKey = Calendar.current.startOfDay(for: eventTime)
        let day = try #require(full.days[dayKey])

        #expect(day.noteCount == 1)
        #expect(day.contentActivityCount == 2)
        #expect(day.checkInCount == 1)
        #expect(day.checkInAmount == 4)
        #expect(day.readDoneCount == 1)
        #expect(day.readSeconds == 1_800)
        #expect(day.heatmapLevel == .more)
        #expect(full.summary.finishedBookCount == 1)
        #expect(full.summary.totalReadSeconds == 1_800)

        let relevantOnly = try await harness.repository.fetchMonthData(
            monthStart: Self.monthStart(eventTime),
            excludedEventTypes: [.note, .review, .checkIn, .readDone, .readTiming]
        )
        let filteredDay = try #require(relevantOnly.days[dayKey])
        #expect(filteredDay.books.map(\.id) == [91_014])
        #expect(filteredDay.noteCount == 0)
        #expect(filteredDay.contentActivityCount == 1)
        #expect(filteredDay.checkInCount == 0)
        #expect(filteredDay.readDoneCount == 0)
        #expect(filteredDay.readSeconds == 0)
    }
}

private extension ReadCalendarAndroidParityTests {
    struct Harness {
        let dbPool: DatabasePool
        let repository: ReadCalendarRepository

        /// 在独立空数据库事务中写入单个测试场景，避免 fixture 彼此污染。
        func write(_ updates: (Database) throws -> Void) async throws {
            try await dbPool.write { db in
                try updates(db)
            }
        }
    }

    /// 创建完成 Room v44 migration 与 seed 的真实 Repository 测试环境。
    static func makeHarness() throws -> Harness {
        let database = try AppDatabase.empty()
        let manager = DatabaseManager(database: database)
        return Harness(
            dbPool: database.dbPool,
            repository: ReadCalendarRepository(databaseManager: manager)
        )
    }

    /// 插入具备有效外键与 Android 时间字段的书籍 fixture。
    static func insertBook(
        _ db: Database,
        id: Int64,
        name: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_672_531_200),
        purchaseAt: Date? = nil,
        readStatusID: Int64 = 1,
        readStatusChangedAt: Date? = nil,
        isDeleted: Int64 = 0
    ) throws {
        // SQL 目的：插入可控书籍，覆盖阅读日历来源下界、活动聚合与状态快照场景。
        // 涉及表：book；read_status_id 使用 seed 状态外键。
        // 关键过滤：无；id、is_deleted 与状态由测试显式控制。
        // 时间字段：created_date、purchase_date、read_status_changed_date 均为本地场景对应的 epoch 毫秒。
        // 副作用用途：为后续事件 fixture 提供有效书籍与当前读完快照。
        try db.execute(
            sql: """
                INSERT INTO book (
                    id, user_id, douban_id, name, raw_name, cover, author, author_intro, translator,
                    isbn, pub_date, press, summary, read_position, total_position, total_pagination,
                    type, current_position_unit, position_unit, source_id, purchase_date, price,
                    book_order, pinned, pin_order, read_status_id, read_status_changed_date,
                    score, catalog, book_mark_modified_time, word_count, created_date, updated_date,
                    last_sync_date, is_deleted
                ) VALUES (
                    ?, 1, 0, ?, ?, '', '', '', '',
                    '', '', '', '', 0, 100, 100,
                    1, 1, 2, 0, ?, 0,
                    0, 0, 0, ?, ?,
                    0, '', 0, NULL, ?, 0,
                    0, ?
                )
                """,
            arguments: [
                id,
                name,
                name,
                purchaseAt.map(millis) ?? 0,
                readStatusID,
                readStatusChangedAt.map(millis) ?? 0,
                millis(createdAt),
                isDeleted
            ]
        )
    }

    /// 插入有效书摘事件。
    static func insertNote(_ db: Database, bookID: Int64, createdAt: Date) throws {
        // SQL 目的：插入书摘事件，验证 created_date 范围、事件筛选和计数。
        // 涉及表：note，book_id 关联有效 book。
        // 关键过滤：fixture 固定 is_deleted=0。
        // 时间字段：created_date/updated_date 使用同一 epoch 毫秒，无额外时区换算。
        // 副作用用途：驱动月聚合、当日汇总与分享数据。
        let timestamp = millis(createdAt)
        try db.execute(
            sql: """
                INSERT INTO note (
                    book_id, chapter_id, content, idea, position, position_unit,
                    include_time, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, 0, '', '', '', 0, 0, ?, ?, 0, 0)
                """,
            arguments: [bookID, timestamp, timestamp]
        )
    }

    /// 插入相关内容事件。
    static func insertRelevant(_ db: Database, bookID: Int64, createdAt: Date) throws {
        // SQL 目的：插入相关内容事件，验证 contentActivityCount 与独立筛选分支。
        // 涉及表：category_content，book_id 关联有效 book，category/content_book 使用 seed 占位行。
        // 关键过滤：fixture 固定 is_deleted=0。
        // 时间字段：created_date/updated_date 使用同一 epoch 毫秒。
        // 副作用用途：驱动月度内容活动聚合。
        let timestamp = millis(createdAt)
        let categoryID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM category WHERE book_id = 0 AND is_deleted = 0 ORDER BY id LIMIT 1"
        ) ?? 1
        try db.execute(
            sql: """
                INSERT INTO category_content (
                    category_id, book_id, title, content, content_book_id,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, '', '', 0, ?, ?, 0, 0)
                """,
            arguments: [categoryID, bookID, timestamp, timestamp]
        )
    }

    /// 插入书评事件。
    static func insertReview(_ db: Database, bookID: Int64, createdAt: Date) throws {
        // SQL 目的：插入书评事件，验证 review 与相关内容共享的内容活动统计口径。
        // 涉及表：review，book_id 关联有效 book。
        // 关键过滤：fixture 固定 is_deleted=0。
        // 时间字段：created_date/updated_date 使用同一 epoch 毫秒。
        // 副作用用途：驱动月聚合和事件排除分支。
        let timestamp = millis(createdAt)
        try db.execute(
            sql: """
                INSERT INTO review (
                    book_id, title, content, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, '', '', ?, ?, 0, 0)
                """,
            arguments: [bookID, timestamp, timestamp]
        )
    }

    /// 插入阅读打卡事件。
    static func insertCheckIn(_ db: Database, bookID: Int64, amount: Int, at date: Date) throws {
        // SQL 目的：插入打卡事件，验证 count、amount 与热力等级取最大值规则。
        // 涉及表：check_in_record，book_id 关联有效 book。
        // 关键过滤：fixture 固定 is_deleted=0，amount 由场景控制。
        // 时间字段：checkin_date/created_date/updated_date 使用同一 epoch 毫秒。
        // 副作用用途：驱动月度打卡聚合与筛选。
        let timestamp = millis(date)
        try db.execute(
            sql: """
                INSERT INTO check_in_record (
                    book_id, amount, position, position_unit, remark,
                    checkin_date, created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, '', 0, '', ?, ?, ?, 0, 0)
                """,
            arguments: [bookID, amount, timestamp, timestamp, timestamp]
        )
    }

    /// 插入精确阅读计时事件。
    static func insertTiming(
        _ db: Database,
        id: Int64,
        bookID: Int64,
        startAt: Date,
        endAt: Date,
        elapsedSeconds: Int64
    ) throws {
        // SQL 目的：插入已完成精确计时，验证区间重叠、跨日切分与零时长活动语义。
        // 涉及表：read_time_record，book_id 关联有效 book。
        // 关键过滤：status=3、fuzzy_read_date=0、is_deleted=0。
        // 时间字段：start_time/end_time 为真实 epoch 毫秒，elapsed_seconds 为业务累计秒数。
        // 副作用用途：驱动月/年时长聚合、排行和三级计时详情。
        try db.execute(
            sql: """
                INSERT INTO read_time_record (
                    id, book_id, start_time, end_time, interrupt_time, elapsed_seconds,
                    countdown_seconds, paused_duration_millis, paused, position,
                    status, fuzzy_read_date, weread_read_date, insight,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, 0, ?, 0, 0, 0, 0, 3, 0, 0, '', ?, ?, 0, 0)
                """,
            arguments: [
                id,
                bookID,
                millis(startAt),
                millis(endAt),
                elapsedSeconds,
                millis(startAt),
                millis(startAt)
            ]
        )
    }

    /// 插入模糊日期阅读计时事件。
    static func insertFuzzyTiming(
        _ db: Database,
        id: Int64,
        bookID: Int64,
        at date: Date,
        elapsedSeconds: Int64
    ) throws {
        // SQL 目的：插入已完成模糊计时，验证自然日归属、排行与年度范围遮罩。
        // 涉及表：read_time_record，book_id 关联有效 book。
        // 关键过滤：status=3、fuzzy_read_date!=0、is_deleted=0。
        // 时间字段：fuzzy_read_date 为归属日期 epoch 毫秒；start/end 固定 0，不参与区间判断。
        // 副作用用途：驱动月/年阅读秒数聚合。
        let timestamp = millis(date)
        try db.execute(
            sql: """
                INSERT INTO read_time_record (
                    id, book_id, start_time, end_time, interrupt_time, elapsed_seconds,
                    countdown_seconds, paused_duration_millis, paused, position,
                    status, fuzzy_read_date, weread_read_date, insight,
                    created_date, updated_date, last_sync_date, is_deleted
                ) VALUES (?, ?, 0, 0, 0, ?, 0, 0, 0, 0, 3, ?, 0, '', ?, ?, 0, 0)
                """,
            arguments: [id, bookID, elapsedSeconds, timestamp, timestamp, timestamp]
        )
    }

    /// 插入阅读状态历史事件。
    static func insertReadStatus(
        _ db: Database,
        bookID: Int64,
        statusID: Int64,
        changedAt: Date
    ) throws {
        // SQL 目的：插入阅读状态历史，验证 READ_DONE 历史与 book 当前快照的去重。
        // 涉及表：book_read_status_record，关联 book 与 seed read_status。
        // 关键过滤：fixture 固定 is_deleted=0，状态由场景控制。
        // 时间字段：changed_date/created_date/updated_date 使用同一 epoch 毫秒。
        // 副作用用途：驱动日历读完标记与 finishedBookCount。
        let timestamp = millis(changedAt)
        try db.execute(
            sql: """
                INSERT INTO book_read_status_record (
                    book_id, read_status_id, changed_date, created_date, updated_date,
                    last_sync_date, is_deleted
                ) VALUES (?, ?, ?, ?, ?, 0, 0)
                """,
            arguments: [bookID, statusID, timestamp, timestamp, timestamp]
        )
    }

    /// 构造与生产 Calendar.current 一致的本地日期，避免固定时区掩盖自然日边界问题。
    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        Calendar.current.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    /// 把日期归一化到本地自然月首日。
    static func monthStart(_ date: Date) -> Date {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return Calendar.current.date(from: components)!
    }

    /// 转换 Android Room 使用的 epoch 毫秒时间戳。
    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

/// 为年度贡献槽测试提供无数据但有明确最早月份的仓储。
private struct EmptyCalendarFixtureRepository: ReadCalendarRepositoryProtocol {
    let earliestDate: Date

    func fetchEarliestDate(excludedEventTypes: Set<ReadCalendarEventType>) async throws -> Date? {
        earliestDate
    }

    func fetchMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>,
        excludedBookIDs: Set<Int64>
    ) async throws -> ReadCalendarMonthData {
        .empty(for: monthStart)
    }

    func fetchYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int,
        includedMonthStarts: Set<Date>?,
        excludedBookIDs: Set<Int64>
    ) async throws -> [ReadCalendarMonthlyDurationBook] {
        []
    }

    func fetchDailySummary(
        for date: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> DailyReadingSummary {
        .empty(for: date)
    }

    func fetchDailyBookRecords(
        for date: Date,
        bookID: Int64,
        filter: DailyReadingTimelineFilter,
        sortOrder: DailyReadingSortOrder
    ) async throws -> [DailyReadingRecord] {
        []
    }

    func saveCheckIn(_ draft: ReadCalendarCheckInDraft) async throws {}

    func updateTiming(_ draft: ReadCalendarTimingDraft) async throws {}

    func deleteCheckIn(recordID: Int64) async throws {}

    func deleteTiming(recordID: Int64) async throws {}
}

/// 年度贡献槽测试无需封面取色，固定返回 pending 即可。
private struct EmptyColorRepository: ReadCalendarColorRepositoryProtocol {
    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String
    ) async -> ReadCalendarSegmentColor {
        .pending
    }
}
