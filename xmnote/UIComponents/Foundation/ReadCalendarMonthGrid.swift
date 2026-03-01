/**
 * [INPUT]: 依赖 DesignTokens 视觉令牌与周网格输入（WeekData/EventSegment/DayPayload，含显示模式与事件条颜色三态）
 * [OUTPUT]: 对外提供 ReadCalendarMonthGrid（月视图周网格组件，支持热力图/活动事件/书籍封面三种展示模式）
 * [POS]: UIComponents/Foundation 的阅读日历可复用网格组件，承载日期格展示、选中态与多模式内容渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ReadCalendarMonthGrid: View {
    enum DisplayMode: Hashable {
        case heatmap
        case activityEvent
        case bookCover
    }

    enum EventColorState: Hashable {
        case pending
        case resolved
        case failed
    }

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

    struct WeekData: Identifiable, Hashable {
        let weekStart: Date
        let days: [Date?]
        let segments: [EventSegment]

        var id: Date { weekStart }
    }

    struct DayPayload: Hashable {
        let bookCount: Int
        let isReadDoneDay: Bool
        let overflowCount: Int
        let isStreakDay: Bool
        let isToday: Bool
        let isSelected: Bool
        let isFuture: Bool

        static let empty = DayPayload(
            bookCount: 0,
            isReadDoneDay: false,
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
    }

    let weeks: [WeekData]
    let laneLimit: Int
    let displayMode: DisplayMode
    let selectedDate: Date?
    let isHapticsEnabled: Bool
    let dayPayloadProvider: (Date) -> DayPayload
    let onSelectDay: (Date) -> Void

    var body: some View {
        VStack(spacing: Layout.weekSpacing) {
            ForEach(weeks) { week in
                ReadCalendarMonthGridWeekRow(
                    week: week,
                    laneLimit: laneLimit,
                    displayMode: displayMode,
                    dayHeaderHeight: Layout.dayHeaderHeight,
                    laneTopInset: Layout.laneTopInset,
                    laneBottomInset: Layout.laneBottomInset,
                    laneBarHeight: Layout.laneBarHeight,
                    laneSpacing: Layout.laneSpacing,
                    segmentHorizontalInset: Layout.segmentHorizontalInset,
                    selectedDate: selectedDate,
                    isHapticsEnabled: isHapticsEnabled,
                    dayPayloadProvider: dayPayloadProvider,
                    onSelectDay: onSelectDay
                )
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .fill(Color.readCalendarSelectionFill.opacity(0.14))
                )
            }
        }
        .padding(.bottom, Layout.gridBottomPadding)
    }
}

private struct ReadCalendarMonthGridWeekRow: View {
    private enum Layout {
        static let modeContentHPadding: CGFloat = Spacing.cozy
        static let modeContentTopPadding: CGFloat = Spacing.half
        static let overflowBadgeHPadding: CGFloat = 3
        static let overflowBadgeBottomPadding: CGFloat = 2
        static let overflowBadgeLeading: CGFloat = 3
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
    let onSelectDay: (Date) -> Void
    @State private var flowPhase: CGFloat = 0
    @State private var badgePulseIDs: Set<String> = []
    @State private var badgePulseToken = 0

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
        case .bookCover:
            return 40
        }
    }

    private var rowHeight: CGFloat {
        dayHeaderHeight
            + laneTopInset
            + laneBottomInset
            + modeContentHeight
    }

    var body: some View {
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
        .frame(height: rowHeight)
        .onAppear {
            startFlowAnimationIfNeeded()
        }
        .onChange(of: selectedDate) { _, newValue in
            triggerBadgePulseIfNeeded(for: newValue)
        }
    }

    private func dayCell(_ day: Date?) -> some View {
        let hasDate = day != nil
        let payload = day.map(dayPayloadProvider) ?? .empty
        let overflowCount = hasDate ? overflowCount(for: payload) : 0
        let readDone = payload.isReadDoneDay

        return ZStack(alignment: .topLeading) {
            Color.clear

            if let day {
                let today = payload.isToday
                let selected = payload.isSelected
                let dayNum = Calendar.current.component(.day, from: day)

                VStack(spacing: 1) {
                    ZStack {
                        if selected {
                            Circle()
                                .fill(Color.accentColor.opacity(0.18))
                                .overlay {
                                    Circle()
                                        .stroke(Color.accentColor.opacity(0.62), lineWidth: 0.95)
                                }
                                .frame(width: 22, height: 22)
                        }
                        Text("\(dayNum)")
                            .font(.system(size: 12, weight: selected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(
                                payload.isFuture ? Color.textHint :
                                selected ? Color.accentColor : Color.textPrimary
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
                                ? Color.accentColor.opacity(0.82)
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

                    if overflowCount > 0 {
                        overflowBadge(overflowCount)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let day, !payload.isFuture else { return }
            if !payload.isSelected, isHapticsEnabled {
                ReadCalendarHaptics.selection()
            }
            onSelectDay(day)
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
        case .bookCover:
            HStack(spacing: 3) {
                let coverCount = min(3, payload.bookCount)
                if coverCount == 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.readCalendarSelectionFill.opacity(0.5))
                        .frame(width: 14, height: 20)
                } else {
                    ForEach(0..<coverCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(coverColor(for: day, index: index))
                            .frame(width: 14, height: 20)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(Color.white.opacity(0.48), lineWidth: 0.45)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.half)
            .padding(.top, Layout.modeContentTopPadding)
        }
    }

    private func overflowCount(for payload: ReadCalendarMonthGrid.DayPayload) -> Int {
        switch displayMode {
        case .heatmap:
            return 0
        case .activityEvent:
            return payload.overflowCount
        case .bookCover:
            return max(0, payload.bookCount - 3)
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
        let rawLevel = payload.bookCount + (payload.isReadDoneDay ? 1 : 0)
        let level = payload.bookCount == 0 ? 0 : min(4, max(1, rawLevel))
        switch level {
        case 0:
            return Color.readCalendarSelectionFill.opacity(0.35)
        case 1:
            return Color.brand.opacity(0.24)
        case 2:
            return Color.brand.opacity(0.36)
        case 3:
            return Color.brand.opacity(0.5)
        default:
            return Color.brand.opacity(0.64)
        }
    }

    private func coverColor(for day: Date, index: Int) -> Color {
        let daySeed = Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970 / 86_400)
        let seed = abs(daySeed &+ index * 37)
        let palette: [Color] = [
            Color(red: 0.69, green: 0.78, blue: 0.89),
            Color(red: 0.84, green: 0.74, blue: 0.61),
            Color(red: 0.74, green: 0.83, blue: 0.72),
            Color(red: 0.78, green: 0.7, blue: 0.86),
            Color(red: 0.71, green: 0.78, blue: 0.68),
            Color(red: 0.86, green: 0.7, blue: 0.72)
        ]
        return palette[seed % palette.count]
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

private enum ReadCalendarHaptics {
    static func selection() {
#if canImport(UIKit)
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
#endif
    }

    static func rigid() {
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.88)
#endif
    }
}
