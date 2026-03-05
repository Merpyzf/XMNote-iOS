/**
 * [INPUT]: 依赖 DesignTokens 视觉令牌、ReadCalendarCoverFanStack 与周网格输入（WeekData/EventSegment/DayPayload，含显示模式与事件条颜色三态），可选依赖全屏封面展开回调
 * [OUTPUT]: 对外提供 ReadCalendarMonthGrid（月视图周网格组件，支持热力图/活动事件/书籍封面三种展示模式）
 * [POS]: ReadCalendar 页面私有月网格组件，承载日期格展示、选中态与多模式内容渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 阅读日历月网格组件，负责渲染热力图、事件条与封面堆叠三种日格内容。
struct ReadCalendarMonthGrid: View {
    /// 月网格展示模式：普通热力图、年度紧凑热力图、事件条、封面堆叠。
    enum DisplayMode: Hashable {
        case heatmap
        case heatmapYearCompact
        case activityEvent
        case bookCover
    }

    /// 事件条颜色解析状态：待解析、解析成功、解析失败回退。
    enum EventColorState: Hashable {
        case pending
        case resolved
        case failed
    }

    /// 事件条颜色载荷，包含状态以及背景/文字色的 RGBA 值。
    struct EventColor: Hashable {
        let state: EventColorState
        let backgroundRGBAHex: UInt32
        let textRGBAHex: UInt32

        static let pending = EventColor(
            state: .pending,
            backgroundRGBAHex: 0,
            textRGBAHex: 0
        )
    }

    /// 单周内的事件条切片，描述某本书在该周的连续区间与所在泳道。
    struct EventSegment: Identifiable, Hashable {
        let bookId: Int64
        let bookName: String
        let weekStart: Date
        let segmentStartDate: Date
        let segmentEndDate: Date
        let laneIndex: Int
        let continuesFromPrevWeek: Bool
        let continuesToNextWeek: Bool
        let showsReadDoneBadge: Bool
        let color: EventColor

        var id: String {
            "\(bookId)-\(weekStart.timeIntervalSince1970)-\(segmentStartDate.timeIntervalSince1970)-\(laneIndex)"
        }
    }

    /// 单周渲染数据，包含 7 天占位与该周所有事件条切片。
    struct WeekData: Identifiable, Hashable {
        let weekStart: Date
        let days: [Date?]
        let segments: [EventSegment]

        var id: Date { weekStart }
    }

    /// 单日渲染数据，聚合热力图等级、书籍数、连读状态与选中状态。
    struct DayPayload: Hashable {
        let bookCount: Int
        let isReadDoneDay: Bool
        let heatmapLevel: HeatmapLevel
        let overflowCount: Int
        let isStreakDay: Bool
        let isToday: Bool
        let isSelected: Bool
        let isFuture: Bool

        static let empty = DayPayload(
            bookCount: 0,
            isReadDoneDay: false,
            heatmapLevel: .none,
            overflowCount: 0,
            isStreakDay: false,
            isToday: false,
            isSelected: false,
            isFuture: false
        )
    }

    private enum Layout {
        static let dayHeaderHeight: CGFloat = 24
        static let laneTopInset: CGFloat = 7
        static let laneBottomInset: CGFloat = 8
        static let laneBarHeight: CGFloat = 15
        static let laneSpacing: CGFloat = Spacing.compact
        static let segmentHorizontalInset: CGFloat = 2
        static let weekSpacing: CGFloat = Spacing.cozy
        static let gridBottomPadding: CGFloat = 2
        static let yearCompactWeekSpacing: CGFloat = 4
        static let yearCompactGridBottomPadding: CGFloat = 0
    }

    static let sourceCoverSize = CGSize(width: 14, height: 20)

    let weeks: [WeekData]
    let laneLimit: Int
    let displayMode: DisplayMode
    let selectedDate: Date?
    let isHapticsEnabled: Bool
    let dayPayloadProvider: (Date) -> DayPayload
    let coverItemsProvider: ((Date) -> [ReadCalendarCoverFanStack.Item])?
    let bookCoverStyleProvider: ((Date) -> ReadCalendarCoverFanStack.Style)?
    let coverComponentVisibleLimit: Int?
    let coverBusinessVisibleLimit: Int?
    let coverEntryCueDate: Date?
    let coverEntryCueProgress: CGFloat
    let frameCoordinateSpaceName: String?
    let onBookCoverStackFramesChange: (([Date: CGRect]) -> Void)?
    let onOpenBookCoverFullscreen: ((Date) -> Void)?
    let onSelectDay: (Date) -> Void

    /// 注入周数据与回调，构建阅读日历月网格（支持可选封面条目与样式覆写）。
    init(
        weeks: [WeekData],
        laneLimit: Int,
        displayMode: DisplayMode,
        selectedDate: Date?,
        isHapticsEnabled: Bool,
        dayPayloadProvider: @escaping (Date) -> DayPayload,
        coverItemsProvider: ((Date) -> [ReadCalendarCoverFanStack.Item])? = nil,
        bookCoverStyleProvider: ((Date) -> ReadCalendarCoverFanStack.Style)? = nil,
        coverComponentVisibleLimit: Int? = nil,
        coverBusinessVisibleLimit: Int? = nil,
        coverEntryCueDate: Date? = nil,
        coverEntryCueProgress: CGFloat = 0,
        frameCoordinateSpaceName: String? = nil,
        onBookCoverStackFramesChange: (([Date: CGRect]) -> Void)? = nil,
        onOpenBookCoverFullscreen: ((Date) -> Void)? = nil,
        onSelectDay: @escaping (Date) -> Void
    ) {
        self.weeks = weeks
        self.laneLimit = laneLimit
        self.displayMode = displayMode
        self.selectedDate = selectedDate
        self.isHapticsEnabled = isHapticsEnabled
        self.dayPayloadProvider = dayPayloadProvider
        self.coverItemsProvider = coverItemsProvider
        self.bookCoverStyleProvider = bookCoverStyleProvider
        self.coverComponentVisibleLimit = coverComponentVisibleLimit
        self.coverBusinessVisibleLimit = coverBusinessVisibleLimit
        self.coverEntryCueDate = coverEntryCueDate
        self.coverEntryCueProgress = max(0, min(1, coverEntryCueProgress))
        self.frameCoordinateSpaceName = frameCoordinateSpaceName
        self.onBookCoverStackFramesChange = onBookCoverStackFramesChange
        self.onOpenBookCoverFullscreen = onOpenBookCoverFullscreen
        self.onSelectDay = onSelectDay
    }

    var body: some View {
        VStack(spacing: weekSpacing) {
            ForEach(weeks) { week in
                ReadCalendarMonthGridWeekRow(
                    week: week,
                    laneLimit: laneLimit,
                    displayMode: displayMode,
                    dayHeaderHeight: displayMode == .heatmapYearCompact ? 0 : Layout.dayHeaderHeight,
                    laneTopInset: displayMode == .heatmapYearCompact ? 0 : Layout.laneTopInset,
                    laneBottomInset: displayMode == .heatmapYearCompact ? 0 : Layout.laneBottomInset,
                    laneBarHeight: Layout.laneBarHeight,
                    laneSpacing: Layout.laneSpacing,
                    segmentHorizontalInset: Layout.segmentHorizontalInset,
                    selectedDate: selectedDate,
                    isHapticsEnabled: isHapticsEnabled,
                    dayPayloadProvider: dayPayloadProvider,
                    coverItemsProvider: coverItemsProvider,
                    bookCoverStyleProvider: bookCoverStyleProvider,
                    coverComponentVisibleLimit: coverComponentVisibleLimit,
                    coverBusinessVisibleLimit: coverBusinessVisibleLimit,
                    coverEntryCueDate: coverEntryCueDate,
                    coverEntryCueProgress: coverEntryCueProgress,
                    frameCoordinateSpaceName: frameCoordinateSpaceName,
                    onOpenBookCoverFullscreen: onOpenBookCoverFullscreen,
                    onSelectDay: onSelectDay
                )
                .background {
                    if displayMode != .heatmapYearCompact {
                        RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                            .fill(Color.readCalendarSelectionFill.opacity(0.14))
                    }
                }
            }
        }
        .padding(.bottom, gridBottomPadding)
        .onPreferenceChange(ReadCalendarMonthGridCoverStackFramePreferenceKey.self) { frames in
            guard displayMode == .bookCover else { return }
            onBookCoverStackFramesChange?(frames)
        }
        .onChange(of: displayMode) { _, mode in
            guard mode != .bookCover else { return }
            onBookCoverStackFramesChange?([:])
        }
    }

    private var weekSpacing: CGFloat {
        displayMode == .heatmapYearCompact
            ? Layout.yearCompactWeekSpacing
            : Layout.weekSpacing
    }

    private var gridBottomPadding: CGFloat {
        displayMode == .heatmapYearCompact
            ? Layout.yearCompactGridBottomPadding
            : Layout.gridBottomPadding
    }
}

private struct ReadCalendarMonthGridWeekRow: View {
    private enum Layout {
        static let modeContentHPadding: CGFloat = Spacing.cozy
        static let modeContentTopPadding: CGFloat = Spacing.half
        static let overflowBadgeHPadding: CGFloat = 3
        static let overflowBadgeBottomPadding: CGFloat = 2
        static let overflowBadgeLeading: CGFloat = 3
        static let yearCompactCellSpacing: CGFloat = 3
        static let yearCompactCellCornerRadius: CGFloat = 2.5
    }

    let week: ReadCalendarMonthGrid.WeekData
    let laneLimit: Int
    let displayMode: ReadCalendarMonthGrid.DisplayMode
    let dayHeaderHeight: CGFloat
    let laneTopInset: CGFloat
    let laneBottomInset: CGFloat
    let laneBarHeight: CGFloat
    let laneSpacing: CGFloat
    let segmentHorizontalInset: CGFloat
    let selectedDate: Date?
    let isHapticsEnabled: Bool
    let dayPayloadProvider: (Date) -> ReadCalendarMonthGrid.DayPayload
    let coverItemsProvider: ((Date) -> [ReadCalendarCoverFanStack.Item])?
    let bookCoverStyleProvider: ((Date) -> ReadCalendarCoverFanStack.Style)?
    let coverComponentVisibleLimit: Int?
    let coverBusinessVisibleLimit: Int?
    let coverEntryCueDate: Date?
    let coverEntryCueProgress: CGFloat
    let frameCoordinateSpaceName: String?
    let onOpenBookCoverFullscreen: ((Date) -> Void)?
    let onSelectDay: (Date) -> Void
    @State private var flowPhase: CGFloat = 0
    @State private var badgePulseIDs: Set<String> = []
    @State private var badgePulseToken = 0

    private var isYearCompactMode: Bool {
        displayMode == .heatmapYearCompact
    }

    private var activityEventHeight: CGFloat {
        CGFloat(laneLimit) * laneBarHeight
            + CGFloat(max(0, laneLimit - 1)) * laneSpacing
    }

    private var modeContentHeight: CGFloat {
        switch displayMode {
        case .activityEvent:
            return activityEventHeight
        case .heatmap:
            return 34
        case .heatmapYearCompact:
            return 0
        case .bookCover:
            return 40
        }
    }

    private var rowHeight: CGFloat {
        return dayHeaderHeight
            + laneTopInset
            + laneBottomInset
            + modeContentHeight
    }

    var body: some View {
        Group {
            if isYearCompactMode {
                HStack(spacing: Layout.yearCompactCellSpacing) {
                    ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                        yearCompactDayCell(day)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                GeometryReader { proxy in
                    let totalWidth = proxy.size.width
                    let cellWidth = totalWidth / 7

                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                                dayCell(day)
                                    .frame(width: cellWidth, height: rowHeight)
                            }
                        }

                        if displayMode == .activityEvent {
                            ForEach(week.segments) { segment in
                                segmentView(segment, cellWidth: cellWidth)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: isYearCompactMode ? nil : rowHeight)
        .onAppear {
            startFlowAnimationIfNeeded()
        }
        .onChange(of: selectedDate) { _, newValue in
            triggerBadgePulseIfNeeded(for: newValue)
        }
    }

    @ViewBuilder
    private func yearCompactDayCell(_ day: Date?) -> some View {
        let payload = day.map(dayPayloadProvider) ?? .empty
        let fillColor = day == nil
            ? HeatmapLevel.none.color.opacity(0.42)
            : yearCompactHeatmapColor(for: payload)

        RoundedRectangle(
            cornerRadius: Layout.yearCompactCellCornerRadius,
            style: .continuous
        )
        .fill(fillColor)
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        let payload = day.map(dayPayloadProvider) ?? .empty
        let dayOverflowCount = day.map { overflowCount(for: payload, day: $0) } ?? 0
        let readDone = payload.isReadDoneDay

        ZStack(alignment: .topLeading) {
            Color.clear

            if let day {
                let today = payload.isToday
                let selected = payload.isSelected
                let dayNum = Calendar.current.component(.day, from: day)

                VStack(spacing: 1) {
                    ZStack {
                        if selected {
                            Circle()
                                .fill(Color.brand.opacity(0.18))
                                .overlay {
                                    Circle()
                                        .stroke(Color.brand.opacity(0.62), lineWidth: 0.95)
                                }
                                .frame(width: 22, height: 22)
                        }
                        Text("\(dayNum)")
                            .font(.system(size: 12, weight: selected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(
                                payload.isFuture ? Color.textHint :
                                selected ? Color.brand : Color.textPrimary
                            )
                    }
                    .frame(height: dayHeaderHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .overlay(alignment: .topTrailing) {
                        if readDone && displayMode != .activityEvent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.readCalendarTodayMark)
                                .offset(x: -2, y: 4)
                        }
                    }

                    if payload.isStreakDay && displayMode == .activityEvent {
                        Capsule(style: .continuous)
                            .fill(
                                selected
                                ? Color.brand.opacity(0.82)
                                : Color.brand.opacity(0.56)
                            )
                            .frame(width: selected ? 12 : 10, height: 2)
                            .offset(y: -1)
                    }

                    if today && !selected {
                        Capsule(style: .continuous)
                            .fill(Color.readCalendarTodayMark)
                            .frame(width: 6, height: 4)
                            .offset(y: -2)
                    }

                    modeContent(for: day, payload: payload)

                    Spacer(minLength: 0)

                    if dayOverflowCount > 0 {
                        overflowBadge(dayOverflowCount)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let day, !payload.isFuture else { return }
            if displayMode == .bookCover,
               payload.bookCount > 0,
               let onOpenBookCoverFullscreen {
                if isHapticsEnabled {
                    ReadCalendarHaptics.selection()
                }
                onOpenBookCoverFullscreen(day)
                return
            }
            if !payload.isSelected, isHapticsEnabled {
                ReadCalendarHaptics.selection()
            }
            onSelectDay(day)
        }
        .overlay {
            if let day,
               displayMode == .bookCover,
               isCoverEntryCueDay(day) {
                coverEntryCueOverlay
            }
        }
        .opacity(payload.isFuture ? 0.55 : 1)
    }

    @ViewBuilder
    private func modeContent(for day: Date, payload: ReadCalendarMonthGrid.DayPayload) -> some View {
        switch displayMode {
        case .activityEvent:
            EmptyView()
        case .heatmap:
            RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                .fill(heatmapColor(for: payload))
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 34)
                .padding(.horizontal, Layout.modeContentHPadding)
                .padding(.top, Layout.modeContentTopPadding)
        case .heatmapYearCompact:
            EmptyView()
        case .bookCover:
            coverStackContent(for: day, payload: payload)
        }
    }

    @ViewBuilder
    private func coverStackContent(for day: Date, payload: ReadCalendarMonthGrid.DayPayload) -> some View {
        let coverItems = resolvedCoverStackItems(for: day, payload: payload)
        let requestedCount = max(payload.bookCount, coverItems.count)
        let presentationMode: ReadCalendarCoverFanStack.PresentationMode = .collapsed
        ReadCalendarCoverFanStack(
            items: coverItems,
            maxVisibleCount: coverStackVisibleCount(requestedCount: requestedCount),
            coverSize: ReadCalendarMonthGrid.sourceCoverSize,
            isAnimated: requestedCount > 0,
            style: coverStackStyle(for: day),
            presentationMode: presentationMode,
            layoutSeed: coverStackSeed(for: day, items: coverItems, mode: presentationMode)
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, Layout.modeContentTopPadding)
        .background {
            if requestedCount > 0 {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ReadCalendarMonthGridCoverStackFramePreferenceKey.self,
                        value: [Calendar.current.startOfDay(for: day): resolvedCoverStackFrame(in: proxy)]
                    )
                }
            }
        }
    }

    private func overflowCount(for payload: ReadCalendarMonthGrid.DayPayload, day: Date?) -> Int {
        switch displayMode {
        case .heatmap, .heatmapYearCompact:
            return 0
        case .activityEvent:
            return payload.overflowCount
        case .bookCover:
            let fallbackLimit = max(1, coverBusinessVisibleLimit ?? 3)
            guard let day else { return max(0, payload.bookCount - fallbackLimit) }
            return max(0, payload.bookCount - coverStackVisibleLimit(for: day))
        }
    }

    private func overflowBadge(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.readCalendarSubtleText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.overflowBadgeHPadding)
            .padding(.bottom, Layout.overflowBadgeBottomPadding)
            .padding(.leading, Layout.overflowBadgeLeading)
            .background(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                    .fill(Color.readCalendarSelectionFill.opacity(0.72))
                    .frame(width: 24, height: 12)
                    .padding(.leading, 4)
                    .padding(.bottom, 1.5)
            }
    }

    private func heatmapColor(for payload: ReadCalendarMonthGrid.DayPayload) -> Color {
        payload.heatmapLevel.color
    }

    private func yearCompactHeatmapColor(for payload: ReadCalendarMonthGrid.DayPayload) -> Color {
        payload.heatmapLevel.color
    }

    /// 返回封面堆叠数据：优先使用外部注入，未注入时回落到内置占位生成逻辑。
    private func resolvedCoverStackItems(
        for day: Date,
        payload: ReadCalendarMonthGrid.DayPayload
    ) -> [ReadCalendarCoverFanStack.Item] {
        if let provided = coverItemsProvider?(day) {
            return provided
        }
        return fallbackCoverStackItems(for: day, payload: payload)
    }

    /// 基于日期和当日读书数量生成封面堆叠数据；无书时返回空集合避免误导点击。
    private func fallbackCoverStackItems(
        for day: Date,
        payload: ReadCalendarMonthGrid.DayPayload
    ) -> [ReadCalendarCoverFanStack.Item] {
        let daySeed = Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970 / 86_400)
        guard payload.bookCount > 0 else {
            return []
        }
        return (0..<payload.bookCount).map { index in
            ReadCalendarCoverFanStack.Item(id: "cover-\(daySeed)-\(index)")
        }
    }

    /// 计算封面堆叠可见张数：请求有数据时保持原值，具体折叠上限交给组件 style 控制。
    private func coverStackVisibleCount(requestedCount: Int) -> Int {
        let requested = max(1, requestedCount)
        guard let coverComponentVisibleLimit else { return requested }
        return min(requested, max(1, coverComponentVisibleLimit))
    }

    /// 计算封面折叠态可见上限，默认沿用标准样式上限兜底。
    private func coverStackVisibleLimit(for day: Date) -> Int {
        max(1, coverStackStyle(for: day).collapsedVisibleCount)
    }

    /// 返回封面堆叠样式：优先使用外部注入，默认回退到标准样式。
    private func coverStackStyle(for day: Date) -> ReadCalendarCoverFanStack.Style {
        let resolved = bookCoverStyleProvider?(day) ?? .standard
        guard let coverBusinessVisibleLimit else { return resolved }
        let businessCap = max(1, coverBusinessVisibleLimit)
        guard resolved.collapsedVisibleCount > businessCap else { return resolved }
        return ReadCalendarCoverFanStack.Style(
            secondaryRotation: resolved.secondaryRotation,
            tertiaryRotation: resolved.tertiaryRotation,
            secondaryOffsetXRatio: resolved.secondaryOffsetXRatio,
            tertiaryOffsetXRatio: resolved.tertiaryOffsetXRatio,
            secondaryOffsetYRatio: resolved.secondaryOffsetYRatio,
            tertiaryOffsetYRatio: resolved.tertiaryOffsetYRatio,
            shadowOpacity: resolved.shadowOpacity,
            shadowRadius: resolved.shadowRadius,
            shadowX: resolved.shadowX,
            shadowY: resolved.shadowY,
            collapsedVisibleCount: businessCap,
            jitterDegree: resolved.jitterDegree,
            jitterOffsetRatio: resolved.jitterOffsetRatio,
            fullscreenMaxRotation: resolved.fullscreenMaxRotation
        )
    }

    /// 返回封面入口聚焦提示层，强调“从当前日期进入详情”。
    var coverEntryCueOverlay: some View {
        let progress = max(0, min(1, coverEntryCueProgress))
        let fillOpacity = 0.12 * progress
        let strokeOpacity = 0.58 * progress
        let scale = 1 + (1 - progress) * 0.05

        return RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
            .fill(Color.brand.opacity(fillOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                    .stroke(Color.brand.opacity(strokeOpacity), lineWidth: 1.05)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .scaleEffect(scale)
            .allowsHitTesting(false)
    }

    /// 判断日期是否命中封面入口 cue，避免非目标日期出现高亮干扰。
    func isCoverEntryCueDay(_ day: Date) -> Bool {
        guard let coverEntryCueDate else { return false }
        guard coverEntryCueProgress > 0 else { return false }
        return Calendar.current.isDate(coverEntryCueDate, inSameDayAs: day)
    }

    /// 返回封面堆叠稳定随机种子，保证同日布局可复现。
    private func coverStackSeed(
        for day: Date,
        items: [ReadCalendarCoverFanStack.Item],
        mode: ReadCalendarCoverFanStack.PresentationMode
    ) -> ReadCalendarCoverFanStack.LayoutSeed {
        ReadCalendarCoverFanStack.makeLayoutSeed(date: day, items: items, mode: mode)
    }

    /// 返回封面堆叠在指定坐标系内的几何 frame，供弹层过渡使用。
    private func resolvedCoverStackFrame(in proxy: GeometryProxy) -> CGRect {
        if let frameCoordinateSpaceName {
            return proxy.frame(in: .named(frameCoordinateSpaceName))
        }
        return proxy.frame(in: .global)
    }

    private func segmentView(_ segment: ReadCalendarMonthGrid.EventSegment, cellWidth: CGFloat) -> some View {
        let startOffset = dayOffset(for: segment.segmentStartDate, weekStart: segment.weekStart)
        let endOffset = dayOffset(for: segment.segmentEndDate, weekStart: segment.weekStart)
        let segmentWidth = CGFloat(endOffset - startOffset + 1) * cellWidth - segmentHorizontalInset * 2
        let x = CGFloat(startOffset) * cellWidth + segmentHorizontalInset
        let y = dayHeaderHeight + laneTopInset + CGFloat(segment.laneIndex) * (laneBarHeight + laneSpacing)

        let fillColor = fillColor(for: segment.color)
        let textColor = textColor(for: segment.color)
        let isPending = segment.color.state == .pending
        let showBadge = !isPending && segment.showsReadDoneBadge && segmentWidth >= 20
        let showText = !isPending && segmentWidth >= 42
        let isFocused = isSegmentFocused(segment)
        let shouldDefocus = shouldDefocusSegment(segment)
        let segmentOpacity: CGFloat = shouldDefocus ? 0.5 : 1

        let leftRadius: CGFloat = segment.continuesFromPrevWeek ? 2.5 : CornerRadius.blockSmall
        let rightRadius: CGFloat = segment.continuesToNextWeek ? 2.5 : CornerRadius.blockSmall
        let segmentShape = UnevenRoundedRectangle(
            topLeadingRadius: leftRadius,
            bottomLeadingRadius: leftRadius,
            bottomTrailingRadius: rightRadius,
            topTrailingRadius: rightRadius
        )

        return ZStack(alignment: .leading) {
            if isPending {
                segmentShape
                    .fill(Color.clear)
                segmentShape
                    .stroke(Color.readCalendarSelectionStroke.opacity(0.55), lineWidth: 0.7)
            } else {
                segmentShape
                    .fill(fillColor.opacity(isFocused ? 0.97 : 0.92))
                    .saturation(isFocused ? 1.06 : 0.92)
                    .brightness(isFocused ? 0.025 : -0.01)
                segmentShape
                    .stroke(fillColor.opacity(isFocused ? 0.74 : 0.44), lineWidth: isFocused ? 0.62 : 0.45)

                if segment.continuesFromPrevWeek {
                    LinearGradient(
                        colors: [fillColor.opacity(0.0), fillColor.opacity(0.55)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if segment.continuesToNextWeek {
                    LinearGradient(
                        colors: [fillColor.opacity(0.55), fillColor.opacity(0.0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 9)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if isFocused && (segment.continuesFromPrevWeek || segment.continuesToNextWeek) {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 12, height: laneBarHeight)
                    .offset(x: flowingHighlightOffset(segmentWidth: segmentWidth))
                    .blendMode(.plusLighter)
                }
            }

            if showText {
                Text(segment.bookName)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(textColor.opacity(isPending ? 0.86 : 0.92))
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .padding(.trailing, showBadge ? 14 : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showBadge {
                let style = readDoneBadgeStyle(for: segment.color)
                Circle()
                    .fill(style.background)
                    .frame(width: 11, height: 11)
                    .scaleEffect(badgePulseIDs.contains(segment.id) ? 1.15 : 1)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(style.foreground)
                    }
                    .padding(.trailing, 3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .clipShape(segmentShape)
        .frame(width: max(0, segmentWidth), height: laneBarHeight)
        .offset(x: x, y: y)
        .opacity(segmentOpacity)
        .animation(.snappy(duration: 0.22), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: isPending)
        .animation(.spring(response: 0.2, dampingFraction: 0.62), value: badgePulseIDs.contains(segment.id))
    }

    private func dayOffset(for date: Date, weekStart: Date) -> Int {
        let start = Calendar.current.startOfDay(for: weekStart)
        let target = Calendar.current.startOfDay(for: date)
        let offset = Calendar.current.dateComponents([.day], from: start, to: target).day ?? 0
        return min(6, max(0, offset))
    }

    private func fillColor(for color: ReadCalendarMonthGrid.EventColor) -> Color {
        switch color.state {
        case .pending:
            return Color.readCalendarEventPendingBase
        case .resolved, .failed:
            return Color(rgbaHex: color.backgroundRGBAHex)
        }
    }

    private func textColor(for color: ReadCalendarMonthGrid.EventColor) -> Color {
        switch color.state {
        case .pending:
            return Color.readCalendarEventPendingText
        case .resolved, .failed:
            return Color(rgbaHex: color.textRGBAHex)
        }
    }

    private func readDoneBadgeStyle(for color: ReadCalendarMonthGrid.EventColor) -> (background: Color, foreground: Color) {
        let isDark = isDarkBackground(color)
        if isDark {
            return (
                background: Color.white.opacity(0.9),
                foreground: Color.black.opacity(0.76)
            )
        }
        return (
            background: Color.black.opacity(0.34),
            foreground: Color.white.opacity(0.96)
        )
    }

    private func isDarkBackground(_ color: ReadCalendarMonthGrid.EventColor) -> Bool {
        let hex: UInt32
        switch color.state {
        case .pending:
            return false
        case .resolved, .failed:
            hex = color.backgroundRGBAHex
        }

        let red = Double((hex >> 24) & 0xFF) / 255.0
        let green = Double((hex >> 16) & 0xFF) / 255.0
        let blue = Double((hex >> 8) & 0xFF) / 255.0
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance < 0.55
    }

    private func shouldDefocusSegment(_ segment: ReadCalendarMonthGrid.EventSegment) -> Bool {
        guard hasFocusedSegment else { return false }
        return !isSegmentFocused(segment)
    }

    private var hasFocusedSegment: Bool {
        week.segments.contains { isSegmentFocused($0) }
    }

    private func isSegmentFocused(_ segment: ReadCalendarMonthGrid.EventSegment) -> Bool {
        guard let selected = selectedDate else { return false }
        let normalized = Calendar.current.startOfDay(for: selected)
        let start = Calendar.current.startOfDay(for: segment.segmentStartDate)
        let end = Calendar.current.startOfDay(for: segment.segmentEndDate)
        return normalized >= start && normalized <= end
    }

    private func flowingHighlightOffset(segmentWidth: CGFloat) -> CGFloat {
        let distance = max(12, segmentWidth + 16)
        return -12 + distance * flowPhase
    }

    private func startFlowAnimationIfNeeded() {
        guard displayMode == .activityEvent else { return }
        guard flowPhase == 0 else { return }
        withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
            flowPhase = 1
        }
    }

    private func triggerBadgePulseIfNeeded(for selected: Date?) {
        guard displayMode == .activityEvent else { return }
        guard let selected else {
            badgePulseIDs.removeAll()
            return
        }

        let normalized = Calendar.current.startOfDay(for: selected)
        let focusedWithBadge = week.segments.filter { segment in
            guard segment.showsReadDoneBadge else { return false }
            let start = Calendar.current.startOfDay(for: segment.segmentStartDate)
            let end = Calendar.current.startOfDay(for: segment.segmentEndDate)
            return normalized >= start && normalized <= end
        }
        let ids = Set(focusedWithBadge.map(\.id))
        guard !ids.isEmpty else {
            badgePulseIDs.removeAll()
            return
        }

        badgePulseToken += 1
        let token = badgePulseToken
        badgePulseIDs = ids
        if isHapticsEnabled {
            ReadCalendarHaptics.rigid()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard token == badgePulseToken else { return }
            badgePulseIDs.removeAll()
        }
    }
}

private struct ReadCalendarMonthGridCoverStackFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Date: CGRect] = [:]

    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private enum ReadCalendarHaptics {
    /// 触发轻量选择触感，用于日期切换反馈。
    static func selection() {
#if canImport(UIKit)
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
#endif
    }

    /// 触发强反馈触感，用于事件条脉冲提示。
    static func rigid() {
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.88)
#endif
    }
}
