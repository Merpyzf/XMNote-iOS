#if DEBUG
import Foundation
import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarCoverFanStack / ReadCalendarMonthGrid 组件契约，依赖 BookRepositoryProtocol 提供 Book 表封面
 * [OUTPUT]: 对外提供 ReadCalendarCoverStackTestViewModel（封面堆叠测试页状态编排）
 * [POS]: Debug 测试状态中枢，覆盖组件级与网格级封面堆叠效果验证，并支持手动参数调节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
final class ReadCalendarCoverStackTestViewModel {
    /// Scenario 描述封面堆叠测试页的预置场景。
    enum Scenario: String, CaseIterable, Identifiable {
        case empty
        case single
        case double
        case triple
        case overflowEight
        case edgeSunday
        case edgeSaturday

        var id: String { rawValue }

        var title: String {
            switch self {
            case .empty:
                return "0 本"
            case .single:
                return "1 本"
            case .double:
                return "2 本"
            case .triple:
                return "3 本"
            case .overflowEight:
                return "8 本"
            case .edgeSunday:
                return "周日边界"
            case .edgeSaturday:
                return "周六边界"
            }
        }
    }

    private enum Layout {
        static let minCoverWidth: CGFloat = 16
        static let maxCoverWidth: CGFloat = 96
        static let minCoverHeight: CGFloat = 24
        static let maxCoverHeight: CGFloat = 140
        static let defaultCoverWidth: CGFloat = 42
        static let defaultCoverHeight: CGFloat = 62
        static let minShadowOpacity: CGFloat = 0
        static let maxShadowOpacity: CGFloat = 0.45
        static let minShadowRadius: CGFloat = 0
        static let maxShadowRadius: CGFloat = 10
        static let minShadowOffset: CGFloat = -4
        static let maxShadowOffset: CGFloat = 8
        static let minRotation: Double = -35
        static let maxRotation: Double = 0
        static let minOffsetRatio: CGFloat = -0.8
        static let maxOffsetRatio: CGFloat = 0.4
        static let minVisibleCount = 1
        static let maxVisibleCount = 12
        static let defaultCollapsedVisibleCount = 6
    }

    var selectedScenario: Scenario = .overflowEight
    var targetDayIndex: Int = 2
    var bookCount: Int = 8
    var maxVisibleCount: Int = Layout.defaultCollapsedVisibleCount
    var collapsedVisibleCount: Int = Layout.defaultCollapsedVisibleCount
    var isAnimated = true
    var isAutoExpandToListEnabled = true
    var isPanelAwareSizingEnabled = true
    var coverWidth: CGFloat = Layout.defaultCoverWidth
    var coverHeight: CGFloat = Layout.defaultCoverHeight
    var secondaryRotation: Double = -12
    var tertiaryRotation: Double = -24
    var secondaryOffsetXRatio: CGFloat = -0.24
    var tertiaryOffsetXRatio: CGFloat = -0.48
    var secondaryOffsetYRatio: CGFloat = -0.08
    var tertiaryOffsetYRatio: CGFloat = 0.06
    var shadowOpacity: CGFloat = 0.22
    var shadowRadius: CGFloat = 5
    var shadowX: CGFloat = 2
    var shadowY: CGFloat = 3
    var selectedDate: Date?
    var isLoadingBookCovers = false
    var bookCoverLoadError: String?
    var bookSourceTotalCount: Int = 0
    var validBookCoverCount: Int = 0

    private let calendar = Calendar.current
    private let referenceWeekStart: Date
    private let fallbackCoverURLs: [String] = [
        "https://upload.wikimedia.org/wikipedia/commons/thumb/8/84/Example.svg/320px-Example.svg.png",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Example.jpg/320px-Example.jpg",
        "https://www.gstatic.com/webp/gallery/1.sm.webp",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/320px-PNG_transparency_demonstration_1.png",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/f/fa/Apple_logo_black.svg/320px-Apple_logo_black.svg.png"
    ]
    private var bookCoverURLs: [String] = []
    private var hasLoadedBookCovers = false

    /// 初始化封面堆叠测试页状态，默认加载 8 本溢出场景。
    init() {
        self.referenceWeekStart = Self.resolveReferenceWeekStart()
        applyScenario(.overflowEight)
    }

    /// 当前组件级预览使用的封面堆叠样式。
    var fanStyle: ReadCalendarCoverFanStack.Style {
        ReadCalendarCoverFanStack.Style(
            secondaryRotation: secondaryRotation,
            tertiaryRotation: tertiaryRotation,
            secondaryOffsetXRatio: secondaryOffsetXRatio,
            tertiaryOffsetXRatio: tertiaryOffsetXRatio,
            secondaryOffsetYRatio: secondaryOffsetYRatio,
            tertiaryOffsetYRatio: tertiaryOffsetYRatio,
            shadowOpacity: shadowOpacity,
            shadowRadius: shadowRadius,
            shadowX: shadowX,
            shadowY: shadowY,
            collapsedVisibleCount: collapsedVisibleCount
        )
    }

    /// 当前组件级预览封面尺寸。
    var coverSize: CGSize {
        CGSize(width: coverWidth, height: coverHeight)
    }

    /// 组件级预览用封面条目（仅做视觉测试，允许 URL 为空触发占位）。
    var componentItems: [ReadCalendarCoverFanStack.Item] {
        makeCoverItems(count: bookCount, idPrefix: "component")
    }

    /// 组件级预览的溢出数量（用于 +N 标记）。
    var componentOverflowCount: Int {
        max(0, bookCount - componentVisibleLimit)
    }

    /// 组件级预览最终可见上限（组件请求与业务折叠上限二者取小）。
    var componentVisibleLimit: Int {
        max(1, min(maxVisibleCount, collapsedVisibleCount))
    }

    /// 当前封面数据来源描述（优先 Book 表，其次回退样例 URL）。
    var coverDataSourceTitle: String {
        if !bookCoverURLs.isEmpty {
            return "Book 表封面（\(validBookCoverCount)/\(bookSourceTotalCount)）"
        }
        return "示例封面回退"
    }

    /// 网格级预览周数据。
    var previewWeeks: [ReadCalendarMonthGrid.WeekData] {
        [ReadCalendarMonthGrid.WeekData(
            weekStart: referenceWeekStart,
            days: weekDates,
            segments: []
        )]
    }

    /// 场景切换并应用对应默认值。
    func selectScenario(_ scenario: Scenario) {
        selectedScenario = scenario
        applyScenario(scenario)
    }

    /// 恢复场景默认值（不改变当前场景类型）。
    func resetScenarioValues() {
        applyScenario(selectedScenario)
    }

    /// 恢复样式参数到标准值。
    func resetStyleValues() {
        let style = ReadCalendarCoverFanStack.Style.standard
        coverWidth = Layout.defaultCoverWidth
        coverHeight = Layout.defaultCoverHeight
        maxVisibleCount = Layout.defaultCollapsedVisibleCount
        collapsedVisibleCount = style.collapsedVisibleCount
        isAnimated = true
        isPanelAwareSizingEnabled = true
        secondaryRotation = style.secondaryRotation
        tertiaryRotation = style.tertiaryRotation
        secondaryOffsetXRatio = style.secondaryOffsetXRatio
        tertiaryOffsetXRatio = style.tertiaryOffsetXRatio
        secondaryOffsetYRatio = style.secondaryOffsetYRatio
        tertiaryOffsetYRatio = style.tertiaryOffsetYRatio
        shadowOpacity = style.shadowOpacity
        shadowRadius = style.shadowRadius
        shadowX = style.shadowX
        shadowY = style.shadowY
    }

    /// 返回指定日期的网格渲染载荷。
    func payload(for date: Date) -> ReadCalendarMonthGrid.DayPayload {
        let normalized = calendar.startOfDay(for: date)
        let target = targetDate
        let isTargetDay = calendar.isDate(normalized, inSameDayAs: target)
        let count = isTargetDay ? bookCount : 0
        return ReadCalendarMonthGrid.DayPayload(
            bookCount: count,
            isReadDoneDay: false,
            heatmapLevel: .none,
            overflowCount: max(0, count - collapsedVisibleCount),
            isStreakDay: false,
            isToday: calendar.isDateInToday(normalized),
            isSelected: selectedDate.map { calendar.isDate(normalized, inSameDayAs: $0) } ?? false,
            isFuture: false
        )
    }

    /// 返回指定日期的封面条目列表，仅目标日注入真实样例。
    func coverItems(for date: Date) -> [ReadCalendarCoverFanStack.Item] {
        let normalized = calendar.startOfDay(for: date)
        guard calendar.isDate(normalized, inSameDayAs: targetDate) else { return [] }
        return makeCoverItems(count: bookCount, idPrefix: "grid")
    }

    /// 记录网格点击选中的日期。
    func selectDay(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
    }

    /// 首次按需加载 Book 表封面，避免重复触发仓储读取。
    func loadBookCoversIfNeeded(using repository: any BookRepositoryProtocol) async {
        await loadBookCovers(using: repository, force: false)
    }

    /// 强制刷新 Book 表封面，供调试面板手动触发。
    func reloadBookCovers(using repository: any BookRepositoryProtocol) async {
        await loadBookCovers(using: repository, force: true)
    }

    /// 限制并归一化可编辑输入，避免越界值影响预览。
    func clampEditableValues() {
        targetDayIndex = min(6, max(0, targetDayIndex))
        bookCount = max(0, bookCount)
        maxVisibleCount = min(Layout.maxVisibleCount, max(Layout.minVisibleCount, maxVisibleCount))
        collapsedVisibleCount = min(Layout.maxVisibleCount, max(Layout.minVisibleCount, collapsedVisibleCount))
        coverWidth = min(Layout.maxCoverWidth, max(Layout.minCoverWidth, coverWidth))
        coverHeight = min(Layout.maxCoverHeight, max(Layout.minCoverHeight, coverHeight))
        secondaryRotation = min(Layout.maxRotation, max(Layout.minRotation, secondaryRotation))
        tertiaryRotation = min(Layout.maxRotation, max(Layout.minRotation, tertiaryRotation))
        secondaryOffsetXRatio = min(Layout.maxOffsetRatio, max(Layout.minOffsetRatio, secondaryOffsetXRatio))
        tertiaryOffsetXRatio = min(Layout.maxOffsetRatio, max(Layout.minOffsetRatio, tertiaryOffsetXRatio))
        secondaryOffsetYRatio = min(Layout.maxOffsetRatio, max(Layout.minOffsetRatio, secondaryOffsetYRatio))
        tertiaryOffsetYRatio = min(Layout.maxOffsetRatio, max(Layout.minOffsetRatio, tertiaryOffsetYRatio))
        shadowOpacity = min(Layout.maxShadowOpacity, max(Layout.minShadowOpacity, shadowOpacity))
        shadowRadius = min(Layout.maxShadowRadius, max(Layout.minShadowRadius, shadowRadius))
        shadowX = min(Layout.maxShadowOffset, max(Layout.minShadowOffset, shadowX))
        shadowY = min(Layout.maxShadowOffset, max(Layout.minShadowOffset, shadowY))
        if let selectedDate {
            self.selectedDate = calendar.startOfDay(for: selectedDate)
        } else {
            self.selectedDate = targetDate
        }
    }
}

private extension ReadCalendarCoverStackTestViewModel {
    func loadBookCovers(using repository: any BookRepositoryProtocol, force: Bool) async {
        guard force || !hasLoadedBookCovers else { return }

        isLoadingBookCovers = true
        bookCoverLoadError = nil

        do {
            var books: [BookItem] = []
            for try await observed in repository.observeBooks() {
                books = observed
                break
            }

            let normalized = books.compactMap { normalizeCoverURL($0.cover) }
            let deduplicated = deduplicatedPreservingOrder(normalized)

            bookSourceTotalCount = books.count
            validBookCoverCount = deduplicated.count
            if deduplicated.isEmpty {
                bookCoverLoadError = "Book 表暂无有效封面，已回退到示例封面。"
            }
            bookCoverURLs = deduplicated
            hasLoadedBookCovers = true
        } catch {
            bookCoverLoadError = "Book 表封面加载失败：\(error.localizedDescription)"
        }

        isLoadingBookCovers = false
    }

    func normalizeCoverURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func deduplicatedPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    var resolvedCoverURLs: [String] {
        if !bookCoverURLs.isEmpty {
            return bookCoverURLs
        }
        return fallbackCoverURLs
    }

    var weekDates: [Date?] {
        (0..<7).map { offset in
            calendar.date(byAdding: .day, value: offset, to: referenceWeekStart)
        }
    }

    var targetDate: Date {
        let safeIndex = min(6, max(0, targetDayIndex))
        guard safeIndex < weekDates.count, let date = weekDates[safeIndex] else {
            return referenceWeekStart
        }
        return calendar.startOfDay(for: date)
    }

    func applyScenario(_ scenario: Scenario) {
        switch scenario {
        case .empty:
            targetDayIndex = 2
            bookCount = 0
        case .single:
            targetDayIndex = 2
            bookCount = 1
        case .double:
            targetDayIndex = 2
            bookCount = 2
        case .triple:
            targetDayIndex = 2
            bookCount = 3
        case .overflowEight:
            targetDayIndex = 2
            bookCount = 8
        case .edgeSunday:
            targetDayIndex = 0
            bookCount = 3
        case .edgeSaturday:
            targetDayIndex = 6
            bookCount = 3
        }
        if selectedDate == nil {
            selectedDate = targetDate
        } else {
            selectedDate = targetDate
        }
        clampEditableValues()
    }

    func makeCoverItems(count: Int, idPrefix: String) -> [ReadCalendarCoverFanStack.Item] {
        guard count > 0 else {
            return [ReadCalendarCoverFanStack.Item(id: "\(idPrefix)-placeholder")]
        }
        guard !resolvedCoverURLs.isEmpty else {
            return [ReadCalendarCoverFanStack.Item(id: "\(idPrefix)-placeholder")]
        }
        return (0..<count).map { index in
            let url = resolvedCoverURLs[index % resolvedCoverURLs.count]
            return ReadCalendarCoverFanStack.Item(
                id: "\(idPrefix)-\(index)",
                coverURL: url
            )
        }
    }

    static func resolveReferenceWeekStart() -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let interval = calendar.dateInterval(of: .weekOfYear, for: today) {
            return calendar.startOfDay(for: interval.start)
        }
        return today
    }
}
#endif
