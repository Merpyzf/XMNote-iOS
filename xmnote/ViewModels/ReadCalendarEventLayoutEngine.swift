import Foundation

/**
 * [INPUT]: 依赖 ReadCalendarDay/ReadCalendarEventRun/ReadCalendarEventSegment 领域模型与 Calendar 日期计算
 * [OUTPUT]: 对外提供 ReadCalendarEventLayoutEngine（按日聚合数据构建 Run/Segment/WeekLayout）
 * [POS]: ViewModels 层阅读日历布局算法引擎，负责跨周连续事件条的数据计算，不涉及 UI 渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarEventLayoutEngine {
    private struct DraftRun {
        let bookId: Int64
        let bookName: String
        let bookCoverURL: String
        let firstEventTime: Int64
        let startDate: Date
        let endDate: Date
    }

    let calendar: Calendar
    let mode: ReadCalendarRenderMode

    init(calendar: Calendar, mode: ReadCalendarRenderMode) {
        self.calendar = calendar
        self.mode = mode
    }

    func buildWeekLayouts(days: [Date: ReadCalendarDay]) -> [ReadCalendarWeekLayout] {
        let runs = buildRuns(days: days)
        guard !runs.isEmpty else { return [] }
        switch mode {
        case .crossWeekContinuous:
            return buildContinuousWeekLayouts(runs: runs)
        case .androidCompatible:
            return buildAndroidCompatibleWeekLayouts(runs: runs)
        }
    }

    func buildRuns(days: [Date: ReadCalendarDay]) -> [ReadCalendarEventRun] {
        var dateBookMap: [Int64: (name: String, cover: String, firstEventTime: Int64, dates: Set<Date>)] = [:]

        for (day, payload) in days {
            let normalizedDay = calendar.startOfDay(for: day)
            for book in payload.books {
                if var item = dateBookMap[book.id] {
                    item.dates.insert(normalizedDay)
                    item.firstEventTime = min(item.firstEventTime, book.firstEventTime)
                    dateBookMap[book.id] = item
                } else {
                    dateBookMap[book.id] = (
                        name: book.name,
                        cover: book.coverURL,
                        firstEventTime: book.firstEventTime,
                        dates: [normalizedDay]
                    )
                }
            }
        }

        var draftRuns: [DraftRun] = []
        for (bookId, item) in dateBookMap {
            let sortedDates = item.dates.sorted()
            guard var runStart = sortedDates.first else { continue }
            var runEnd = runStart

            for date in sortedDates.dropFirst() {
                guard let nextExpected = calendar.date(byAdding: .day, value: 1, to: runEnd) else { continue }
                if calendar.isDate(date, inSameDayAs: nextExpected) {
                    runEnd = date
                } else {
                    draftRuns.append(DraftRun(
                        bookId: bookId,
                        bookName: item.name,
                        bookCoverURL: item.cover,
                        firstEventTime: item.firstEventTime,
                        startDate: runStart,
                        endDate: runEnd
                    ))
                    runStart = date
                    runEnd = date
                }
            }
            draftRuns.append(DraftRun(
                bookId: bookId,
                bookName: item.name,
                bookCoverURL: item.cover,
                firstEventTime: item.firstEventTime,
                startDate: runStart,
                endDate: runEnd
            ))
        }

        let sorted = draftRuns.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            let lhsDuration = dayDistanceInclusive(from: lhs.startDate, to: lhs.endDate)
            let rhsDuration = dayDistanceInclusive(from: rhs.startDate, to: rhs.endDate)
            if lhsDuration != rhsDuration {
                return lhsDuration > rhsDuration
            }
            if lhs.firstEventTime != rhs.firstEventTime {
                return lhs.firstEventTime < rhs.firstEventTime
            }
            return lhs.bookId < rhs.bookId
        }

        var laneEndDates: [Date] = []
        var runs: [ReadCalendarEventRun] = []
        runs.reserveCapacity(sorted.count)
        for run in sorted {
            let lane = resolveLane(for: run, laneEndDates: &laneEndDates)
            runs.append(ReadCalendarEventRun(
                bookId: run.bookId,
                bookName: run.bookName,
                bookCoverURL: run.bookCoverURL,
                firstEventTime: run.firstEventTime,
                startDate: run.startDate,
                endDate: run.endDate,
                laneIndex: lane
            ))
        }
        return runs
    }
}

// MARK: - 连续模式

private extension ReadCalendarEventLayoutEngine {
    func buildContinuousWeekLayouts(runs: [ReadCalendarEventRun]) -> [ReadCalendarWeekLayout] {
        let segments = splitRunsIntoSegments(runs: runs)
        let grouped = Dictionary(grouping: segments, by: \.weekStart)
        return grouped.keys.sorted().map { weekStart in
            ReadCalendarWeekLayout(
                weekStart: weekStart,
                segments: (grouped[weekStart] ?? []).sorted(by: compareSegment)
            )
        }
    }

    func splitRunsIntoSegments(runs: [ReadCalendarEventRun]) -> [ReadCalendarEventSegment] {
        var result: [ReadCalendarEventSegment] = []
        for run in runs {
            var segmentStart = run.startDate
            while segmentStart <= run.endDate {
                let weekStart = startOfWeek(for: segmentStart)
                guard let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else { break }
                let segmentEnd = min(weekEnd, run.endDate)
                result.append(ReadCalendarEventSegment(
                    bookId: run.bookId,
                    bookName: run.bookName,
                    bookCoverURL: run.bookCoverURL,
                    firstEventTime: run.firstEventTime,
                    weekStart: weekStart,
                    segmentStartDate: segmentStart,
                    segmentEndDate: segmentEnd,
                    laneIndex: run.laneIndex,
                    continuesFromPrevWeek: segmentStart > run.startDate,
                    continuesToNextWeek: segmentEnd < run.endDate
                ))
                guard let next = calendar.date(byAdding: .day, value: 1, to: segmentEnd) else { break }
                segmentStart = next
            }
        }
        return result
    }
}

// MARK: - Android 兼容模式

private extension ReadCalendarEventLayoutEngine {
    func buildAndroidCompatibleWeekLayouts(runs: [ReadCalendarEventRun]) -> [ReadCalendarWeekLayout] {
        let segments = splitRunsIntoSegments(runs: runs)
        let grouped = Dictionary(grouping: segments, by: \.weekStart)
        return grouped.keys.sorted().map { weekStart in
            let raw = grouped[weekStart] ?? []
            let sorted = raw.sorted { lhs, rhs in
                if lhs.segmentStartDate != rhs.segmentStartDate {
                    return lhs.segmentStartDate < rhs.segmentStartDate
                }
                if lhs.segmentEndDate != rhs.segmentEndDate {
                    return lhs.segmentEndDate > rhs.segmentEndDate
                }
                if lhs.firstEventTime != rhs.firstEventTime {
                    return lhs.firstEventTime < rhs.firstEventTime
                }
                return lhs.bookId < rhs.bookId
            }

            var laneEndOffsets: [Int] = []
            var remapped: [ReadCalendarEventSegment] = []
            remapped.reserveCapacity(sorted.count)
            for segment in sorted {
                let startOffset = dayDistanceInclusive(from: weekStart, to: segment.segmentStartDate) - 1
                let endOffset = dayDistanceInclusive(from: weekStart, to: segment.segmentEndDate) - 1
                let lane = resolveLane(
                    startOffset: startOffset,
                    endOffset: endOffset,
                    laneEndOffsets: &laneEndOffsets
                )
                remapped.append(ReadCalendarEventSegment(
                    bookId: segment.bookId,
                    bookName: segment.bookName,
                    bookCoverURL: segment.bookCoverURL,
                    firstEventTime: segment.firstEventTime,
                    weekStart: segment.weekStart,
                    segmentStartDate: segment.segmentStartDate,
                    segmentEndDate: segment.segmentEndDate,
                    laneIndex: lane,
                    continuesFromPrevWeek: false,
                    continuesToNextWeek: false
                ))
            }

            return ReadCalendarWeekLayout(
                weekStart: weekStart,
                segments: remapped.sorted(by: compareSegment)
            )
        }
    }
}

// MARK: - Helpers

private extension ReadCalendarEventLayoutEngine {
    private func resolveLane(for run: DraftRun, laneEndDates: inout [Date]) -> Int {
        for lane in laneEndDates.indices {
            if run.startDate > laneEndDates[lane] {
                laneEndDates[lane] = run.endDate
                return lane
            }
        }
        laneEndDates.append(run.endDate)
        return laneEndDates.count - 1
    }

    private func resolveLane(startOffset: Int, endOffset: Int, laneEndOffsets: inout [Int]) -> Int {
        for lane in laneEndOffsets.indices {
            if startOffset > laneEndOffsets[lane] {
                laneEndOffsets[lane] = endOffset
                return lane
            }
        }
        laneEndOffsets.append(endOffset)
        return laneEndOffsets.count - 1
    }

    private func startOfWeek(for date: Date) -> Date {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return calendar.startOfDay(for: start)
    }

    private func dayDistanceInclusive(from: Date, to: Date) -> Int {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        let distance = calendar.dateComponents([.day], from: fromDay, to: toDay).day ?? 0
        return max(1, distance + 1)
    }

    private func compareSegment(_ lhs: ReadCalendarEventSegment, _ rhs: ReadCalendarEventSegment) -> Bool {
        if lhs.laneIndex != rhs.laneIndex {
            return lhs.laneIndex < rhs.laneIndex
        }
        if lhs.segmentStartDate != rhs.segmentStartDate {
            return lhs.segmentStartDate < rhs.segmentStartDate
        }
        if lhs.segmentEndDate != rhs.segmentEndDate {
            return lhs.segmentEndDate < rhs.segmentEndDate
        }
        return lhs.bookId < rhs.bookId
    }
}
