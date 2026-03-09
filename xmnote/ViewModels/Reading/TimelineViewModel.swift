import Foundation
import SwiftUI

/**
 * [INPUT]: 依赖 TimelineRepositoryProtocol 提供事件查询与日历标记聚合
 * [OUTPUT]: 对外提供 TimelineViewModel（时间线页面状态管理：事件列表、日期选择、分类筛选、日历标记预加载）
 * [POS]: Reading 模块时间线状态中枢，编排时间范围计算、事件加载与日历标记缓存
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 时间线页面状态管理，持有事件数据与日历标记缓存。
/// 时间范围策略对齐 Android：选中"今天"时按用户配置回溯（默认半年），非今天仅查当天。
/// - 线程归属: @MainActor，所有状态修改在主线程
/// - 取消行为: 视图销毁时 Task 自动取消
@MainActor
@Observable
final class TimelineViewModel {
    var sections: [TimelineSection] = []
    var selectedDate: Date
    var selectedCategory: TimelineEventCategory = .all
    var displayedMonthStart: Date
    var isLoading = false
    private(set) var markerRevision: Int = 0

    private var markerCache: [String: [Date: TimelineDayMarker]] = [:]
    private let repository: any TimelineRepositoryProtocol
    private let calendar: Calendar

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

    /// 首次加载：拉取事件列表与当月 ± 1 日历标记。
    func loadInitialData() async {
        await loadEvents()
        await preloadMarkers(around: displayedMonthStart)
    }

    /// 按当前 selectedDate 和 selectedCategory 拉取事件列表。
    func loadEvents() async {
        isLoading = true
        defer { isLoading = false }

        let (start, end) = calculateTimeRange()
        do {
            sections = try await repository.fetchTimelineEvents(
                startTimestamp: start,
                endTimestamp: end,
                category: selectedCategory
            )
        } catch {
            sections = []
        }
    }

    /// 选中日期变更：更新 selectedDate 并重新拉取事件。
    func selectDate(_ date: Date) async {
        selectedDate = calendar.startOfDay(for: date)
        await loadEvents()
    }

    /// 分类筛选变更：清空日历标记缓存，重新拉取事件与标记。
    func selectCategory(_ category: TimelineEventCategory) async {
        selectedCategory = category
        markerCache.removeAll()
        markerRevision &+= 1
        await loadEvents()
        await preloadMarkers(around: displayedMonthStart)
    }

    /// 月份翻页后预加载前后月份日历标记。
    func updateDisplayedMonth(_ monthStart: Date) async {
        displayedMonthStart = monthStart
        await preloadMarkers(around: monthStart)
    }

    /// 预加载目标月份 ± 1 的日历标记，已缓存月份跳过。
    func preloadMarkers(around monthStart: Date) async {
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
                markerCache[key] = [:]
                didUpdate = true
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
}

// MARK: - 工具方法

private extension TimelineViewModel {
    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let comps = calendar.dateComponents([.year, .month], from: normalized)
        let start = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: start)
    }

    static func monthKey(for date: Date, using calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month], from: monthStart(of: date, using: calendar))
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }
}
