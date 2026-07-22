/**
 * [INPUT]: 依赖 DesignTokens 视觉令牌、ReadCalendarCoverFanStack 与周网格输入（WeekData/EventSegment/DayPayload，含显示模式与事件条颜色三态），可选依赖全屏封面展开与读完事件选择回调
 * [OUTPUT]: 对外提供 ReadCalendarMonthGrid（月视图周网格组件，支持热力图/活动事件/书籍封面三种展示模式，并提供事件标题渐隐与读完庆祝反馈）
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

    /// 单日渲染数据，聚合热力图等级、书籍数与选中状态。
    struct DayPayload: Hashable {
        let bookCount: Int
        let isReadDoneDay: Bool
        let heatmapLevel: HeatmapLevel
        let overflowCount: Int
        let isToday: Bool
        let isSelected: Bool
        let isFuture: Bool

        static let empty = DayPayload(
            bookCount: 0,
            isReadDoneDay: false,
            heatmapLevel: .none,
            overflowCount: 0,
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

    /// 日历格子内单张封面源尺寸，宽度保持紧凑密度，高度由统一封面比例推导。
    /// 主卡在背景容器中占比 70%×77%。
    /// depth 2 边缘自然溢出约 10pt（iPhone 17 Pro），保留有机溢出美学，不使用 .clipped()。
    static let sourceCoverSize = XMBookCover.size(width: sourceCoverWidth)

    private static let sourceCoverWidth: CGFloat = 28

    let weeks: [WeekData]
    let laneLimit: Int
    let displayMode: DisplayMode
    let selectedDate: Date?
    let isHapticsEnabled: Bool
    let doneMarkerStyle: ReadCalendarDoneMarkerStyle
    let doneEmojiAssetName: String
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
    let onReadDoneEventSelected: ((Date) -> Void)?
    let onSelectDay: (Date) -> Void

    /// 注入周数据与回调，构建阅读日历月网格（支持可选封面条目与样式覆写）。
    init(
        weeks: [WeekData],
        laneLimit: Int,
        displayMode: DisplayMode,
        selectedDate: Date?,
        isHapticsEnabled: Bool,
        doneMarkerStyle: ReadCalendarDoneMarkerStyle = .checkmark,
        doneEmojiAssetName: String = "ReadCalendarDonePartyPopper",
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
        onReadDoneEventSelected: ((Date) -> Void)? = nil,
        onSelectDay: @escaping (Date) -> Void
    ) {
        self.weeks = weeks
        self.laneLimit = laneLimit
        self.displayMode = displayMode
        self.selectedDate = selectedDate
        self.isHapticsEnabled = isHapticsEnabled
        self.doneMarkerStyle = doneMarkerStyle
        self.doneEmojiAssetName = doneEmojiAssetName
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
        self.onReadDoneEventSelected = onReadDoneEventSelected
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
                    doneMarkerStyle: doneMarkerStyle,
                    doneEmojiAssetName: doneEmojiAssetName,
                    dayPayloadProvider: dayPayloadProvider,
                    coverItemsProvider: coverItemsProvider,
                    bookCoverStyleProvider: bookCoverStyleProvider,
                    coverComponentVisibleLimit: coverComponentVisibleLimit,
                    coverBusinessVisibleLimit: coverBusinessVisibleLimit,
                    coverEntryCueDate: coverEntryCueDate,
                    coverEntryCueProgress: coverEntryCueProgress,
                    frameCoordinateSpaceName: frameCoordinateSpaceName,
                    onOpenBookCoverFullscreen: onOpenBookCoverFullscreen,
                    onReadDoneEventSelected: onReadDoneEventSelected,
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
        static let bookCoverContentTopPadding: CGFloat = 0
        static let overflowBadgeHPadding: CGFloat = 3
        static let overflowBadgeBottomPadding: CGFloat = 2
        static let overflowBadgeLeading: CGFloat = 3
        static let yearCompactCellSpacing: CGFloat = 3
        static let yearCompactCellCornerRadius: CGFloat = CornerRadius.inlayTiny
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
    let doneMarkerStyle: ReadCalendarDoneMarkerStyle
    let doneEmojiAssetName: String
    let dayPayloadProvider: (Date) -> ReadCalendarMonthGrid.DayPayload
    let coverItemsProvider: ((Date) -> [ReadCalendarCoverFanStack.Item])?
    let bookCoverStyleProvider: ((Date) -> ReadCalendarCoverFanStack.Style)?
    let coverComponentVisibleLimit: Int?
    let coverBusinessVisibleLimit: Int?
    let coverEntryCueDate: Date?
    let coverEntryCueProgress: CGFloat
    let frameCoordinateSpaceName: String?
    let onOpenBookCoverFullscreen: ((Date) -> Void)?
    let onReadDoneEventSelected: ((Date) -> Void)?
    let onSelectDay: (Date) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ScaledMetric(relativeTo: .caption) private var selectedDayCircleSize = 24
    @ScaledMetric(relativeTo: .caption2) private var readDoneIndicatorSize = 8
    @ScaledMetric(relativeTo: .caption2) private var overflowBadgeBackgroundWidth = 24
    @ScaledMetric(relativeTo: .caption2) private var overflowBadgeBackgroundHeight = 12
    @ScaledMetric(relativeTo: .caption2) private var readDoneBadgeCircleSize = 14
    @ScaledMetric(relativeTo: .caption2) private var readDoneBadgeEmojiSize = 12
    @ScaledMetric(relativeTo: .caption2) private var readDoneBadgeCheckmarkSize = 9
    @State private var doneCelebrationSegmentID: String?
    @State private var doneCelebrationTrigger = 0

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
            return 54
        }
    }

    private var rowHeight: CGFloat {
        switch displayMode {
        case .bookCover:
            return dayHeaderHeight + modeContentHeight
        default:
            return dayHeaderHeight + laneTopInset + laneBottomInset + modeContentHeight
        }
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
                        HStack(spacing: Spacing.none) {
                            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                                dayCell(day)
                                    .frame(width: cellWidth, height: rowHeight)
                            }
                        }

                        if displayMode == .activityEvent {
                            ForEach(week.segments) { segment in
                                segmentView(segment, cellWidth: cellWidth)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: isYearCompactMode ? nil : rowHeight)
    }

    @ViewBuilder
    private func yearCompactDayCell(_ day: Date?) -> some View {
        let payload = day.map(dayPayloadProvider) ?? .empty
        let fillColor = day == nil
            ? Color.readCalendarHeatmapNone.opacity(0.42)
            : yearCompactHeatmapColor(for: payload).opacity(payload.isFuture ? 0.32 : 1)

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

                VStack(spacing: Spacing.hairline) {
                    ZStack {
                        Circle()
                            .fill(Color.readCalendarSelectedDayFill)
                            .frame(width: selectedDayCircleSize, height: selectedDayCircleSize)
                            .scaleEffect(selected ? 1 : 0.84)
                            .opacity(selected ? 1 : 0)
                            .animation(
                                accessibilityReduceMotion ? nil : .snappy(duration: 0.18),
                                value: selected
                            )

                        Text("\(dayNum)")
                            .font(
                                selected
                                ? ReadCalendarTypography.monthGridDayNumberSelectedFont
                                : ReadCalendarTypography.monthGridDayNumberFont
                            )
                            .foregroundStyle(
                                payload.isFuture ? Color.textHint :
                                selected ? Color.readCalendarSelectedDayText : Color.textPrimary
                            )
                    }
                    .frame(height: dayHeaderHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .overlay(alignment: .topTrailing) {
                        if readDone && displayMode != .activityEvent {
                            readDoneMarker(size: readDoneIndicatorSize)
                                .offset(x: -2, y: 4)
                        }
                    }

                    if today && !selected {
                        Capsule(style: .continuous)
                            .fill(Color.readCalendarTodayMark)
                            .frame(width: 6, height: 4)
                            .offset(y: -2)
                    }

                    modeContent(for: day, payload: payload)

                    Spacer(minLength: 0)

                    if displayMode == .activityEvent, dayOverflowCount > 0 {
                        overflowBadge(dayOverflowCount)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let day else { return }
            activateDay(day, payload: payload)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dayAccessibilityLabel(day, payload: payload))
        .accessibilityAddTraits(day != nil && !payload.isFuture ? .isButton : [])
        .accessibilityAddTraits(payload.isSelected ? .isSelected : [])
        .accessibilityHidden(day == nil)
        .accessibilityAction {
            guard let day else { return }
            activateDay(day, payload: payload)
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

    /// 统一触摸与辅助功能激活路径，避免读屏用户无法进入当日阅读。
    private func activateDay(_ day: Date, payload: ReadCalendarMonthGrid.DayPayload) {
        guard !payload.isFuture else { return }
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

    /// 生成日期格的完整读屏描述，包含活动书数、热度和读完状态。
    private func dayAccessibilityLabel(
        _ day: Date?,
        payload: ReadCalendarMonthGrid.DayPayload
    ) -> String {
        guard let day else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日"
        var parts = [formatter.string(from: day), "\(payload.bookCount)本书", payload.heatmapLevel.accessibilityText]
        if payload.isReadDoneDay { parts.append("有读完记录") }
        if payload.isToday { parts.append("今天") }
        return parts.joined(separator: "，")
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
            layoutSeed: coverStackSeed(for: day, items: coverItems, mode: presentationMode),
            showsOverflowTailCue: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, Layout.bookCoverContentTopPadding)
        .frame(height: modeContentHeight, alignment: .center)
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
            return 0
        }
    }

    private func overflowBadge(_ count: Int) -> some View {
        Text("+\(count)")
            .font(
                AppTypography.fixed(
                    baseSize: 9,
                    relativeTo: .caption2,
                    weight: .semibold,
                    design: .rounded,
                    minimumPointSize: 9
                )
            )
            .foregroundStyle(Color.readCalendarSubtleText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.overflowBadgeHPadding)
            .padding(.bottom, Layout.overflowBadgeBottomPadding)
            .padding(.leading, Layout.overflowBadgeLeading)
            .background(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                    .fill(Color.readCalendarSelectionFill.opacity(0.72))
                    .frame(width: overflowBadgeBackgroundWidth, height: overflowBadgeBackgroundHeight)
                    .padding(.leading, Spacing.compact)
                    .padding(.bottom, Spacing.tiny)
            }
    }

    private func heatmapColor(for payload: ReadCalendarMonthGrid.DayPayload) -> Color {
        Color.readCalendarHeatmapColor(for: payload.heatmapLevel)
    }

    private func yearCompactHeatmapColor(for payload: ReadCalendarMonthGrid.DayPayload) -> Color {
        Color.readCalendarHeatmapColor(for: payload.heatmapLevel)
    }

    /// 返回封面堆叠数据：优先使用外部注入，未注入时回落到内置占位生成逻辑。
    private func resolvedCoverStackItems(
        for day: Date,
        payload: ReadCalendarMonthGrid.DayPayload
    ) -> [ReadCalendarCoverFanStack.Item] {
        if let provided = coverItemsProvider?(day) {
            return Array(provided.prefix(14))
        }
        return Array(fallbackCoverStackItems(for: day, payload: payload).prefix(14))
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
            .padding(.horizontal, Spacing.tiny)
            .padding(.vertical, Spacing.tiny)
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

        let isPending = segment.color.state == .pending
        let showBadge = !isPending && segment.showsReadDoneBadge && segmentWidth >= 44
        let showText = !isPending
        let isInteractive = showBadge && onReadDoneEventSelected != nil
        let isFocused = isSegmentFocused(segment)
        let shouldDefocus = shouldDefocusSegment(segment)
        let segmentOpacity: CGFloat = shouldDefocus ? 0.42 : (isFocused ? 1 : 0.92)
        let daySpan = endOffset - startOffset + 1
        let backgroundBlendOpacity: CGFloat = (segment.continuesFromPrevWeek || segment.continuesToNextWeek)
            ? 0.09
            : (daySpan >= 3 ? 0.06 : 0)
        let visualStyle = eventVisualStyle(
            for: segment.color,
            backgroundBlendOpacity: backgroundBlendOpacity,
            isFocused: isFocused
        )

        let leftRadius: CGFloat = segment.continuesFromPrevWeek ? CornerRadius.inlayTiny : CornerRadius.blockSmall
        let rightRadius: CGFloat = segment.continuesToNextWeek ? CornerRadius.inlayTiny : CornerRadius.blockSmall
        let segmentShape = UnevenRoundedRectangle(
            topLeadingRadius: leftRadius,
            bottomLeadingRadius: leftRadius,
            bottomTrailingRadius: rightRadius,
            topTrailingRadius: rightRadius
        )
        let textTrailingInset: CGFloat = showBadge
            ? readDoneBadgeCircleSize + 2
            : (segment.continuesToNextWeek ? 4 : 0)

        return ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                if isPending {
                    segmentShape
                        .fill(Color.clear)
                    segmentShape
                        .stroke(Color.readCalendarSelectionStroke.opacity(0.55), lineWidth: 0.7)
                } else {
                    segmentShape
                        .fill(visualStyle.displayBackground.color)
                    segmentShape
                        .stroke(visualStyle.borderColor.color, lineWidth: 0.5)

                    if segment.continuesFromPrevWeek {
                        Capsule(style: .continuous)
                            .fill(visualStyle.continuationColor.color)
                            .frame(width: 2, height: laneBarHeight * 0.68)
                            .padding(.leading, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if segment.continuesToNextWeek && !showBadge {
                        Capsule(style: .continuous)
                            .fill(visualStyle.continuationColor.color)
                            .frame(width: 2, height: laneBarHeight * 0.68)
                            .padding(.trailing, 1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                if showText {
                    ReadCalendarEventTitle(
                        text: segment.bookName,
                        textColor: visualStyle.textColor.color,
                        fadeColor: visualStyle.visibleBackground.color,
                        leadingInset: 5,
                        trailingInset: textTrailingInset,
                        fadeWidth: 14,
                        topMaskHeight: 3
                    )
                }
            }
            .clipShape(segmentShape)

            if showBadge {
                ReadCalendarEventDoneBadge(
                    badgeSize: readDoneBadgeCircleSize,
                    emojiSize: readDoneBadgeEmojiSize,
                    checkmarkSize: readDoneBadgeCheckmarkSize,
                    markerStyle: doneMarkerStyle,
                    emojiAssetName: doneEmojiAssetName,
                    visualStyle: visualStyle,
                    celebrationTrigger: doneCelebrationSegmentID == segment.id
                        ? doneCelebrationTrigger
                        : 0
                )
                    .padding(.trailing, 2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if isInteractive {
                Button {
                    activateReadDoneEvent(segment)
                } label: {
                    Color.clear
                        .contentShape(segmentShape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(segment.bookName)，读完事件")
                .accessibilityHint("选择读完日期")
            }
        }
        .frame(width: max(0, segmentWidth), height: laneBarHeight)
        .contentShape(segmentShape)
        .offset(x: x, y: y)
        .opacity(segmentOpacity)
        .scaleEffect(x: 1, y: isFocused ? 1.08 : 1)
        .animation(.snappy(duration: 0.22), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: isPending)
        .allowsHitTesting(isInteractive)
    }

    private func dayOffset(for date: Date, weekStart: Date) -> Int {
        let start = Calendar.current.startOfDay(for: weekStart)
        let target = Calendar.current.startOfDay(for: date)
        let offset = Calendar.current.dateComponents([.day], from: start, to: target).day ?? 0
        return min(6, max(0, offset))
    }

    /// 依据用户设置渲染日格读完标记；图案直接使用 Android 同源资源。
    @ViewBuilder
    private func readDoneMarker(size: CGFloat) -> some View {
        if doneMarkerStyle == .emoji {
            Image(doneEmojiAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: size + 3, height: size + 3)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(Color.readCalendarTodayMark)
        }
    }

    /// 对长段混色和聚焦修正后的实际可见背景重新计算文字、边缘与徽标颜色。
    private func eventVisualStyle(
        for color: ReadCalendarMonthGrid.EventColor,
        backgroundBlendOpacity: CGFloat,
        isFocused: Bool
    ) -> ReadCalendarEventVisualStyle {
        guard color.state != .pending else {
            let page = ReadCalendarEventRGBA.pageBackground(for: colorScheme)
            let background = ReadCalendarEventRGBA(
                red: 0.52,
                green: 0.56,
                blue: 0.60,
                alpha: 0.18
            )
            return ReadCalendarEventVisualStyle.make(
                baseBackground: background,
                rawText: .init(red: 0.34, green: 0.38, blue: 0.42, alpha: 0.86),
                pageBackground: page,
                backgroundBlendOpacity: Double(backgroundBlendOpacity),
                isFocused: isFocused
            )
        }

        return ReadCalendarEventVisualStyle.make(
            baseBackground: .init(rgbaHex: color.backgroundRGBAHex),
            rawText: .init(rgbaHex: color.textRGBAHex),
            pageBackground: .pageBackground(for: colorScheme),
            backgroundBlendOpacity: Double(backgroundBlendOpacity),
            isFocused: isFocused
        )
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

    /// 触发指定读完事件的独立庆祝反馈，并将交互日期切换到事件结束日。
    private func activateReadDoneEvent(_ segment: ReadCalendarMonthGrid.EventSegment) {
        if isHapticsEnabled {
            ReadCalendarHaptics.selection()
        }
        doneCelebrationSegmentID = segment.id
        doneCelebrationTrigger &+= 1
        onReadDoneEventSelected?(segment.segmentEndDate)
    }
}

/// 在单行标题进入尾部保护区时绘制 Android 同口径的背景色渐隐，不生成省略号。
private struct ReadCalendarEventTitle: View {
    let text: String
    let textColor: Color
    let fadeColor: Color
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let fadeWidth: CGFloat
    let topMaskHeight: CGFloat
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = max(0, proxy.size.width - leadingInset - trailingInset)
            let resolvedFadeWidth = min(fadeWidth, viewportWidth)
            let shouldFade = textWidth > 0 &&
                textWidth >= max(0, viewportWidth - resolvedFadeWidth - 1)

            ZStack(alignment: .topLeading) {
                Text(text)
                    .font(ReadCalendarTypography.monthGridEventTitleFont)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.width
                    } action: { newWidth in
                        guard abs(textWidth - newWidth) > 0.5 else { return }
                        textWidth = newWidth
                    }
                    .frame(width: viewportWidth, height: proxy.size.height, alignment: .leading)
                    .clipped()
                    .offset(x: leadingInset)

                if shouldFade, resolvedFadeWidth > 0 {
                    LinearGradient(
                        stops: [
                            .init(color: fadeColor.opacity(0.04), location: 0),
                            .init(color: fadeColor.opacity(0.18), location: 0.42),
                            .init(color: fadeColor.opacity(0.72), location: 0.78),
                            .init(color: fadeColor, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: resolvedFadeWidth, height: proxy.size.height)
                    .offset(x: proxy.size.width - trailingInset - resolvedFadeWidth)
                    .accessibilityHidden(true)

                    LinearGradient(
                        colors: [fadeColor.opacity(0.86), fadeColor.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: resolvedFadeWidth, height: topMaskHeight)
                    .offset(x: proxy.size.width - trailingInset - resolvedFadeWidth)
                    .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(text)
    }
}

/// 在事件条末端绘制读完徽标，并按触发值重播 Android 同节奏的庆祝反馈。
private struct ReadCalendarEventDoneBadge: View {
    let badgeSize: CGFloat
    let emojiSize: CGFloat
    let checkmarkSize: CGFloat
    let markerStyle: ReadCalendarDoneMarkerStyle
    let emojiAssetName: String
    let visualStyle: ReadCalendarEventVisualStyle
    let celebrationTrigger: Int

    var body: some View {
        ReadCalendarDoneCelebrationEffect(
            trigger: celebrationTrigger,
            badgeSize: badgeSize,
            maximumRotation: markerStyle == .emoji ? 5 : 3,
            eventBackground: visualStyle.visibleBackground,
            eventText: visualStyle.textColor,
            badgeBackground: visualStyle.doneBadgeBackground
        ) {
            marker
        }
    }

    /// 绘制静态徽标本体；动画仅作用于该对象的变换，不改变布局尺寸。
    @ViewBuilder
    private var marker: some View {
        ZStack {
            Circle()
                .fill(visualStyle.doneBadgeBackground.color)

            if markerStyle == .emoji {
                Image(emojiAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: emojiSize, height: emojiSize)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: checkmarkSize, weight: .bold))
                    .foregroundStyle(visualStyle.doneBadgeGlyph.color)
            }
        }
        .frame(width: badgeSize, height: badgeSize)
    }
}

private struct ReadCalendarEventVisualStyle {
    let displayBackground: ReadCalendarEventRGBA
    let visibleBackground: ReadCalendarEventRGBA
    let textColor: ReadCalendarEventRGBA
    let borderColor: ReadCalendarEventRGBA
    let continuationColor: ReadCalendarEventRGBA
    let doneBadgeBackground: ReadCalendarEventRGBA
    let doneBadgeGlyph: ReadCalendarEventRGBA

    /// 复刻 Android 事件条的背景混色、可见色合成和二次文字对比度校正。
    static func make(
        baseBackground: ReadCalendarEventRGBA,
        rawText: ReadCalendarEventRGBA,
        pageBackground: ReadCalendarEventRGBA,
        backgroundBlendOpacity: Double,
        isFocused: Bool
    ) -> ReadCalendarEventVisualStyle {
        let eventBackground = baseBackground.lerp(
            to: pageBackground,
            amount: backgroundBlendOpacity
        )
        let focusedBackground = baseBackground.lerp(
            to: .white,
            amount: baseBackground.isDark ? 0.08 : 0.18
        )
        let displayBackground = isFocused ? focusedBackground : eventBackground
        let visibleBackground = displayBackground.composite(over: pageBackground)
        let normalizedText = rawText.withAlpha(max(rawText.alpha, 0.88))
        let textColor: ReadCalendarEventRGBA
        if visibleBackground.compositeContrast(with: normalizedText) >= 3.2 {
            textColor = normalizedText
        } else {
            let darkText = ReadCalendarEventRGBA.black.withAlpha(
                visibleBackground.simpleLuminance > 0.72 ? 0.72 : 0.64
            )
            let lightText = ReadCalendarEventRGBA.white.withAlpha(
                visibleBackground.isDark ? 0.96 : 0.90
            )
            textColor = visibleBackground.compositeContrast(with: darkText)
                > visibleBackground.compositeContrast(with: lightText)
                ? darkText
                : lightText
        }

        let borderAlpha: Double
        if visibleBackground.isDark {
            borderAlpha = isFocused ? 0.20 : 0.08
        } else {
            borderAlpha = isFocused ? 0.24 : 0.10
        }
        let borderColor = textColor.withAlpha(borderAlpha)

        var continuationColor = textColor.withAlpha(visibleBackground.isDark ? 0.48 : 0.36)
        if visibleBackground.compositeContrast(with: continuationColor) < 1.28 {
            continuationColor = visibleBackground.isDark
                ? .white.withAlpha(0.46)
                : .black.withAlpha(0.32)
        }

        let badgeOverlay = visibleBackground.isDark
            ? ReadCalendarEventRGBA.white.withAlpha(0.16)
            : textColor.withAlpha(0.12)
        let badgeBackground = badgeOverlay.composite(over: visibleBackground)

        return ReadCalendarEventVisualStyle(
            displayBackground: displayBackground,
            visibleBackground: visibleBackground,
            textColor: textColor,
            borderColor: borderColor,
            continuationColor: continuationColor,
            doneBadgeBackground: badgeBackground,
            doneBadgeGlyph: textColor.withAlpha(0.96)
        )
    }
}

/// 统一事件条与读完庆祝动效的 RGBA 颜色计算，避免 SwiftUI 动态颜色参与离线对比度运算。
struct ReadCalendarEventRGBA {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let black = ReadCalendarEventRGBA(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = ReadCalendarEventRGBA(red: 1, green: 1, blue: 1, alpha: 1)

    /// 从领域层 RRGGBBAA 表示构造颜色分量。
    init(rgbaHex: UInt32) {
        self.init(
            red: Double((rgbaHex >> 24) & 0xFF) / 255,
            green: Double((rgbaHex >> 16) & 0xFF) / 255,
            blue: Double((rgbaHex >> 8) & 0xFF) / 255,
            alpha: Double(rgbaHex & 0xFF) / 255
        )
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var simpleLuminance: Double {
        0.299 * red + 0.587 * green + 0.114 * blue
    }

    var isDark: Bool {
        simpleLuminance < 0.5
    }

    var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// 解析 iOS 当前外观下的页面底色，保持平台设计令牌同时复用 Android 合成规则。
    static func pageBackground(for colorScheme: ColorScheme) -> ReadCalendarEventRGBA {
#if canImport(UIKit)
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let resolved = UIColor.systemGroupedBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return ReadCalendarEventRGBA(
                red: Double(red),
                green: Double(green),
                blue: Double(blue),
                alpha: Double(alpha)
            )
        }
#endif
        return colorScheme == .dark
            ? .black
            : ReadCalendarEventRGBA(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
    }

    func withAlpha(_ value: Double) -> ReadCalendarEventRGBA {
        ReadCalendarEventRGBA(red: red, green: green, blue: blue, alpha: value)
    }

    func lerp(to other: ReadCalendarEventRGBA, amount: Double) -> ReadCalendarEventRGBA {
        let progress = min(1, max(0, amount))
        return ReadCalendarEventRGBA(
            red: red + (other.red - red) * progress,
            green: green + (other.green - green) * progress,
            blue: blue + (other.blue - blue) * progress,
            alpha: alpha + (other.alpha - alpha) * progress
        )
    }

    func composite(over background: ReadCalendarEventRGBA) -> ReadCalendarEventRGBA {
        let outputAlpha = alpha + background.alpha * (1 - alpha)
        guard outputAlpha > 0 else { return .init(red: 0, green: 0, blue: 0, alpha: 0) }
        return ReadCalendarEventRGBA(
            red: (red * alpha + background.red * background.alpha * (1 - alpha)) / outputAlpha,
            green: (green * alpha + background.green * background.alpha * (1 - alpha)) / outputAlpha,
            blue: (blue * alpha + background.blue * background.alpha * (1 - alpha)) / outputAlpha,
            alpha: outputAlpha
        )
    }

    func compositeContrast(with foreground: ReadCalendarEventRGBA) -> Double {
        let visibleForeground = foreground.composite(over: self)
        let lighter = max(relativeLuminance, visibleForeground.relativeLuminance)
        let darker = min(relativeLuminance, visibleForeground.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

private struct ReadCalendarMonthGridCoverStackFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Date: CGRect] = [:]

    /// 合并各日期封面堆叠容器的 frame 映射，供后续全屏转场精确对位。
    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

enum ReadCalendarHaptics {
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
