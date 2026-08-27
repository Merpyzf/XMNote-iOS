import Foundation
import OSLog
import SwiftUI

/**
 * [INPUT]: 依赖 TimelineRepositoryProtocol 提供事件查询与日历标记聚合
 * [OUTPUT]: 对外提供 TimelineViewModel（时间线页面状态管理：事件列表、日期选择、分类筛选、日历标记预加载与 viewer 来源上下文）
 * [POS]: Reading 模块时间线状态中枢，编排时间范围计算、事件加载与日历标记缓存
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 时间线页面状态管理，持有事件数据与日历标记缓存。
/// 时间范围策略对齐 Android：选中"今天"时按用户配置回溯（默认半年），非今天仅查当天。
/// - 线程归属: @MainActor，所有状态修改在主线程
/// - 取消行为: 视图销毁时 Task 自动取消
@MainActor
@Observable
/// TimelineViewModel 负责时间线页的日期选择、分类过滤、事件加载和月份标记缓存。
final class TimelineViewModel {
    enum BootstrapPhase: Equatable {
        case bootstrapping
        case ready
        case failed
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "XMNote",
        category: "Timeline"
    )

    var sections: [TimelineSection] = []
    private(set) var sectionsRevision: Int = 0
    var selectedDate: Date
    var selectedCategory: TimelineEventCategory = .all
    var displayedMonthStart: Date
    private(set) var bootstrapPhase: BootstrapPhase = .bootstrapping
    private(set) var isRefreshing = false
    private(set) var initialErrorMessage: String?
    private(set) var refreshErrorMessage: String?
    private(set) var markerRevision: Int = 0

    private var markerCache: [String: [Date: TimelineDayMarker]] = [:]
    private let repository: any TimelineRepositoryProtocol
    private let calendar: Calendar
    private var hasResolvedInitialSnapshot = false

    /// 时间范围配置，对齐 Android SpSettingHelper.getTimeLineDataShowRange()。
    /// 0=当天, 1=过去一个月, 2=过去半年(默认), 3=过去一年, 4=全部
    @ObservationIgnored
    @AppStorage("timelineDataShowRange") private var dataShowRange: Int = 2

    /// 构造器注入仓储依赖，初始化选中日期为当天、显示月份为当月。
    init(repository: any TimelineRepositoryProtocol) {
        self.repository = repository
        var cal = Calendar.current
        cal.timeZone = .current
        self.calendar = cal
        let today = cal.startOfDay(for: Date())
        self.selectedDate = today
        self.displayedMonthStart = Self.monthStart(of: today, using: cal)
    }

    /// 首次加载：并发拉取首屏列表与当前月份 marker，并以单次快照提交首屏。
    func loadInitialData() async {
        guard !hasResolvedInitialSnapshot else { return }
        bootstrapPhase = .bootstrapping
        initialErrorMessage = nil

        do {
            let snapshot = try await fetchBootstrapSnapshot()
            applySections(snapshot.sections)
            if let markerCache = snapshot.markerCache {
                replaceMarkerCache(with: markerCache)
            }
            hasResolvedInitialSnapshot = true
            bootstrapPhase = .ready
            await preloadMarkers(around: displayedMonthStart)
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Initial timeline load failed: \(error.localizedDescription, privacy: .public)")
            initialErrorMessage = "请检查后重试"
            bootstrapPhase = .failed
        }
    }

    /// 首次读取失败后重新获取列表与日历标记；失败期间不提交空数据快照。
    func retryInitialData() async {
        guard !hasResolvedInitialSnapshot else { return }
        await loadInitialData()
    }

    /// 按当前 selectedDate 和 selectedCategory 拉取事件列表。
    @discardableResult
    func loadEvents() async -> Bool {
        guard hasResolvedInitialSnapshot else {
            await loadInitialData()
            return hasResolvedInitialSnapshot
        }

        isRefreshing = true
        refreshErrorMessage = nil
        defer { isRefreshing = false }
        do {
            applySections(try await fetchSections())
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            Self.logger.error("Timeline refresh failed: \(error.localizedDescription, privacy: .public)")
            refreshErrorMessage = "时间线更新失败，请重试"
            return false
        }
    }

    /// 阅读计时记录在其他页面完成写入后，刷新当前列表与当前月份标记缓存。
    /// 并发语义：方法运行在 MainActor；并发读取期间只展示轻量刷新状态，取消后不会提交半截数据。
    func reloadAfterExternalMutation() async {
        guard hasResolvedInitialSnapshot else {
            await loadInitialData()
            return
        }

        isRefreshing = true
        refreshErrorMessage = nil
        defer { isRefreshing = false }

        let currentMonthStart = displayedMonthStart
        async let sections = fetchSectionsResult()
        async let markers = fetchMarkersResult(for: currentMonthStart, category: selectedCategory)
        let (resolvedSections, resolvedMarkers) = await (sections, markers)

        switch resolvedSections {
        case .success(let newSections):
            applySections(newSections)
        case .failure(let error):
            Self.logger.error("Timeline mutation refresh failed: \(error.localizedDescription, privacy: .public)")
            refreshErrorMessage = "时间线更新失败，请重试"
        }

        if case .success(let newMarkers) = resolvedMarkers {
            var nextMarkerCache = markerCache
            nextMarkerCache[Self.monthKey(for: currentMonthStart, using: calendar)] = newMarkers
            replaceMarkerCache(with: nextMarkerCache)
        }
    }

    /// 选中日期变更：更新 selectedDate 并重新拉取事件。
    func selectDate(_ date: Date) async {
        let normalized = calendar.startOfDay(for: date)
        guard normalized != selectedDate else { return }
        let previousDate = selectedDate
        selectedDate = normalized
        if !(await loadEvents()) {
            selectedDate = previousDate
        }
    }

    /// 分类筛选变更：保留旧内容在位，待新分类列表与当前月份 marker 就绪后一次性替换。
    func selectCategory(_ category: TimelineEventCategory) async {
        guard category != selectedCategory else { return }
        guard hasResolvedInitialSnapshot else {
            selectedCategory = category
            await loadInitialData()
            return
        }

        let previousCategory = selectedCategory
        selectedCategory = category
        isRefreshing = true
        refreshErrorMessage = nil
        defer { isRefreshing = false }
        let currentMonthStart = displayedMonthStart
        async let sections = fetchSectionsResult()
        async let markers = fetchMarkersResult(for: currentMonthStart, category: category)
        let (resolvedSections, resolvedMarkers) = await (sections, markers)

        guard case .success(let newSections) = resolvedSections else {
            selectedCategory = previousCategory
            if case .failure(let error) = resolvedSections {
                Self.logger.error("Timeline filter failed: \(error.localizedDescription, privacy: .public)")
            }
            refreshErrorMessage = "筛选结果更新失败，请重试"
            return
        }

        applySections(newSections)
        if case .success(let newMarkers) = resolvedMarkers {
            replaceMarkerCache(with: [Self.monthKey(for: currentMonthStart, using: calendar): newMarkers])
        } else {
            replaceMarkerCache(with: [:])
        }
        await preloadMarkers(around: displayedMonthStart)
    }

    /// 月份翻页后预加载前后月份日历标记。
    func updateDisplayedMonth(_ monthStart: Date) async {
        let normalized = Self.monthStart(of: monthStart, using: calendar)
        guard normalized != displayedMonthStart else { return }
        displayedMonthStart = normalized
        guard hasResolvedInitialSnapshot else { return }
        await preloadMarkers(around: normalized)
    }

    /// 预加载目标月份 ± 1 的日历标记，已缓存月份跳过。
    func preloadMarkers(around monthStart: Date) async {
        guard hasResolvedInitialSnapshot else { return }
        let anchor = Self.monthStart(of: monthStart, using: calendar)
        var didUpdate = false

        for offset in [-1, 0, 1] {
            guard let month = calendar.date(byAdding: .month, value: offset, to: anchor) else { continue }
            let normalized = Self.monthStart(of: month, using: calendar)
            let key = Self.monthKey(for: normalized, using: calendar)
            guard markerCache[key] == nil else { continue }

            do {
                let markers = try await repository.fetchCalendarMarkers(
                    for: normalized,
                    category: selectedCategory
                )
                markerCache[key] = markers
                didUpdate = true
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error("Timeline marker preload failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if didUpdate {
            markerRevision &+= 1
        }
    }

    /// 从缓存读取指定日期的日历标记，供日历 cell 渲染。
    func marker(for date: Date) -> TimelineDayMarker? {
        let key = Self.monthKey(for: date, using: calendar)
        let normalized = calendar.startOfDay(for: date)
        return markerCache[key]?[normalized]
    }

    /// 将当前时间线筛选与时间范围折叠成内容查看器来源，供点击书摘/书评/相关内容时复用同一分页上下文。
    func currentViewerSourceContext() -> ContentViewerSourceContext {
        let range = calculateTimeRange()
        return .timeline(
            startTimestamp: range.start,
            endTimestamp: range.end,
            filter: currentContentFilter
        )
    }

    /// 仅在列表数据实际变化时递增 revision，避免滚动期为 Equatable 深比较整组 section。
    func applySections(_ newSections: [TimelineSection]) {
        guard newSections != sections else { return }
        sections = newSections
        sectionsRevision &+= 1
    }

    var isLoading: Bool {
        bootstrapPhase == .bootstrapping || isRefreshing
    }

    var sceneSnapshot: TimelineSceneSnapshot {
        TimelineSceneSnapshot(
            selectedDate: selectedDate,
            displayedMonthStart: displayedMonthStart,
            selectedCategory: selectedCategory
        )
    }

    /// 应用 scene 恢复快照，让首次加载直接命中用户上次停留的时间线语义位置。
    func applySceneSnapshot(_ snapshot: TimelineSceneSnapshot) {
        selectedDate = calendar.startOfDay(for: snapshot.selectedDate)
        displayedMonthStart = Self.monthStart(of: snapshot.displayedMonthStart, using: calendar)
        selectedCategory = snapshot.selectedCategory
    }
}

// MARK: - 时间范围计算

private extension TimelineViewModel {
    /// 根据选中日期是否为"今天"决定查询的毫秒时间戳范围。
    /// 对齐 Android TimelineRepository 时间范围策略：
    /// - 今天: 按 dataShowRange 回溯（0=当天/1=31 天/2=183 天(默认)/3=366 天/4=全部）
    /// - 非今天: 仅查选中日期当天 00:00:00 ~ 23:59:59.999
    func calculateTimeRange() -> (start: Int64, end: Int64) {
        let endOfDay = calendar.startOfDay(for: selectedDate)
            .addingTimeInterval(86400 - 0.001)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)

        if calendar.isDateInToday(selectedDate) {
            let startDate: Date
            switch dataShowRange {
            case 0:
                startDate = calendar.startOfDay(for: selectedDate)
            case 1:
                startDate = calendar.startOfDay(
                    for: calendar.date(byAdding: .day, value: -31, to: selectedDate)!
                )
            case 3:
                startDate = calendar.startOfDay(
                    for: calendar.date(byAdding: .day, value: -366, to: selectedDate)!
                )
            case 4:
                return (start: 0, end: endMs)
            default:
                startDate = calendar.startOfDay(
                    for: calendar.date(byAdding: .day, value: -183, to: selectedDate)!
                )
            }
            return (start: Int64(startDate.timeIntervalSince1970 * 1000), end: endMs)
        }

        let startMs = Int64(calendar.startOfDay(for: selectedDate).timeIntervalSince1970 * 1000)
        return (start: startMs, end: endMs)
    }

    var currentContentFilter: TimelineContentFilter {
        switch selectedCategory {
        case .note:
            .note
        case .review:
            .review
        case .relevant:
            .relevant
        default:
            .allContent
        }
    }
}

// MARK: - 工具方法

private extension TimelineViewModel {
    struct BootstrapSnapshot {
        let sections: [TimelineSection]
        let markerCache: [String: [Date: TimelineDayMarker]]?
    }

    /// 并发获取首屏最小可用快照，保证列表和当前月份 marker 一次性提交。
    func fetchBootstrapSnapshot() async throws -> BootstrapSnapshot {
        let currentMonthStart = displayedMonthStart
        async let sections = fetchSections()
        async let markers = try? await fetchMarkers(for: currentMonthStart, category: selectedCategory)
        let resolvedSections = try await sections
        let resolvedMarkers = await markers
        return BootstrapSnapshot(
            sections: resolvedSections,
            markerCache: resolvedMarkers.map {
                [Self.monthKey(for: currentMonthStart, using: calendar): $0]
            }
        )
    }

    /// 读取当前筛选条件下的时间线列表；错误必须交给页面状态映射，不得伪装为空数据。
    func fetchSections() async throws -> [TimelineSection] {
        let (start, end) = calculateTimeRange()
        return try await repository.fetchTimelineEvents(
            startTimestamp: start,
            endTimestamp: end,
            category: selectedCategory
        )
    }

    /// 读取指定月份的 marker；失败保持未缓存，让后续预加载仍可重试。
    func fetchMarkers(for monthStart: Date, category: TimelineEventCategory) async throws -> [Date: TimelineDayMarker] {
        try await repository.fetchCalendarMarkers(
            for: monthStart,
            category: category
        )
    }

    func fetchSectionsResult() async -> Result<[TimelineSection], Error> {
        do {
            return .success(try await fetchSections())
        } catch {
            return .failure(error)
        }
    }

    func fetchMarkersResult(
        for monthStart: Date,
        category: TimelineEventCategory
    ) async -> Result<[Date: TimelineDayMarker], Error> {
        do {
            return .success(try await fetchMarkers(for: monthStart, category: category))
        } catch {
            return .failure(error)
        }
    }

    /// 用新 marker cache 替换当前缓存，仅在实际变化时递增 markerRevision。
    func replaceMarkerCache(with newCache: [String: [Date: TimelineDayMarker]]) {
        guard newCache != markerCache else { return }
        markerCache = newCache
        markerRevision &+= 1
    }

    /// 把日期折叠到月份首日，供查询范围和 marker cache key 统一使用。
    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let comps = calendar.dateComponents([.year, .month], from: normalized)
        let start = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: start)
    }

    /// 生成月份缓存 key，避免 `Date` 时分秒差异导致同月重复缓存。
    static func monthKey(for date: Date, using calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month], from: monthStart(of: date, using: calendar))
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }
}
