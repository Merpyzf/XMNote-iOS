/**
 * [INPUT]: 依赖 DesignTokens 视觉令牌与周网格输入（WeekData/EventSegment/DayPayload）
 * [OUTPUT]: 对外提供 ReadCalendarMonthGrid（月视图周网格与事件条渲染组件）
 * [POS]: UIComponents/Foundation 的阅读日历可复用网格组件，承载日期格展示、选中态与事件条渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct ReadCalendarMonthGrid: View {
    struct EventSegment: Identifiable, Hashable {
        let bookId: Int64
        let bookName: String
        let weekStart: Date
        let segmentStartDate: Date
        let segmentEndDate: Date
        let laneIndex: Int
        let continuesFromPrevWeek: Bool
        let continuesToNextWeek: Bool

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
        let isReadDoneDay: Bool
        let overflowCount: Int
        let isToday: Bool
        let isSelected: Bool
        let isFuture: Bool

        static let empty = DayPayload(
            isReadDoneDay: false,
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
        static let laneSpacing: CGFloat = 4
        static let segmentHorizontalInset: CGFloat = 2
        static let weekSpacing: CGFloat = 8
    }

    let weeks: [WeekData]
    let laneLimit: Int
    let dayPayloadProvider: (Date) -> DayPayload
    let onSelectDay: (Date) -> Void

    var body: some View {
        VStack(spacing: Layout.weekSpacing) {
            ForEach(weeks) { week in
                ReadCalendarMonthGridWeekRow(
                    week: week,
                    laneLimit: laneLimit,
                    dayHeaderHeight: Layout.dayHeaderHeight,
                    laneTopInset: Layout.laneTopInset,
                    laneBottomInset: Layout.laneBottomInset,
                    laneBarHeight: Layout.laneBarHeight,
                    laneSpacing: Layout.laneSpacing,
                    segmentHorizontalInset: Layout.segmentHorizontalInset,
                    dayPayloadProvider: dayPayloadProvider,
                    onSelectDay: onSelectDay
                )
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.item, style: .continuous)
                        .fill(Color.readCalendarSelectionFill.opacity(0.22))
                )
            }
        }
        .padding(.bottom, 2)
    }
}

private struct ReadCalendarMonthGridWeekRow: View {
    let week: ReadCalendarMonthGrid.WeekData
    let laneLimit: Int
    let dayHeaderHeight: CGFloat
    let laneTopInset: CGFloat
    let laneBottomInset: CGFloat
    let laneBarHeight: CGFloat
    let laneSpacing: CGFloat
    let segmentHorizontalInset: CGFloat
    let dayPayloadProvider: (Date) -> ReadCalendarMonthGrid.DayPayload
    let onSelectDay: (Date) -> Void

    private var rowHeight: CGFloat {
        dayHeaderHeight
            + laneTopInset
            + laneBottomInset
            + CGFloat(laneLimit) * laneBarHeight
            + CGFloat(max(0, laneLimit - 1)) * laneSpacing
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

                ForEach(week.segments) { segment in
                    segmentView(segment, cellWidth: cellWidth)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func dayCell(_ day: Date?) -> some View {
        let hasDate = day != nil
        let payload = day.map(dayPayloadProvider) ?? .empty
        let overflowCount = hasDate ? payload.overflowCount : 0
        let readDone = payload.isReadDoneDay

        return ZStack(alignment: .topLeading) {
            Color.clear

            if let day {
                let today = payload.isToday
                let selected = payload.isSelected
                let dayNum = Calendar.current.component(.day, from: day)

                VStack(spacing: 1) {
                    HStack(spacing: 2) {
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

                        if readDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.readCalendarTodayMark)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: dayHeaderHeight, alignment: .center)

                    if today && !selected {
                        Capsule(style: .continuous)
                            .fill(Color.readCalendarTodayMark)
                            .frame(width: 6, height: 4)
                            .offset(y: -2)
                    }

                    Spacer(minLength: 0)

                    if overflowCount > 0 {
                        Text("+\(overflowCount)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.readCalendarSubtleText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 3)
                            .padding(.bottom, 2)
                            .padding(.leading, 3)
                            .background(alignment: .bottomLeading) {
                                RoundedRectangle(cornerRadius: CornerRadius.calendarTag, style: .continuous)
                                    .fill(Color.readCalendarSelectionFill.opacity(0.72))
                                    .frame(width: 24, height: 12)
                                    .padding(.leading, 4)
                                    .padding(.bottom, 1.5)
                            }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let day, !payload.isFuture else { return }
            onSelectDay(day)
        }
        .opacity(payload.isFuture ? 0.55 : 1)
    }

    private func segmentView(_ segment: ReadCalendarMonthGrid.EventSegment, cellWidth: CGFloat) -> some View {
        let startOffset = dayOffset(for: segment.segmentStartDate, weekStart: segment.weekStart)
        let endOffset = dayOffset(for: segment.segmentEndDate, weekStart: segment.weekStart)
        let segmentWidth = CGFloat(endOffset - startOffset + 1) * cellWidth - segmentHorizontalInset * 2
        let x = CGFloat(startOffset) * cellWidth + segmentHorizontalInset
        let y = dayHeaderHeight + laneTopInset + CGFloat(segment.laneIndex) * (laneBarHeight + laneSpacing)

        let fillColor = color(for: segment.bookId)
        let showText = segmentWidth >= 42

        let leftRadius: CGFloat = segment.continuesFromPrevWeek ? 2.5 : CornerRadius.calendarEvent
        let rightRadius: CGFloat = segment.continuesToNextWeek ? 2.5 : CornerRadius.calendarEvent
        let segmentShape = UnevenRoundedRectangle(
            topLeadingRadius: leftRadius,
            bottomLeadingRadius: leftRadius,
            bottomTrailingRadius: rightRadius,
            topTrailingRadius: rightRadius
        )

        return ZStack(alignment: .leading) {
            segmentShape
                .fill(fillColor.opacity(0.92))
            segmentShape
                .stroke(fillColor.opacity(0.58), lineWidth: 0.5)

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

            if showText {
                Text(segment.bookName)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readCalendarEventText.opacity(0.88))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .clipShape(segmentShape)
        .frame(width: max(0, segmentWidth), height: laneBarHeight)
        .offset(x: x, y: y)
        .shadow(color: Color.black.opacity(0.08), radius: 1.2, x: 0, y: 0.8)
    }

    private func dayOffset(for date: Date, weekStart: Date) -> Int {
        let start = Calendar.current.startOfDay(for: weekStart)
        let target = Calendar.current.startOfDay(for: date)
        let offset = Calendar.current.dateComponents([.day], from: start, to: target).day ?? 0
        return min(6, max(0, offset))
    }

    private func color(for bookId: Int64) -> Color {
        Color.readCalendarEventPalette[abs(Int(bookId)) % Color.readCalendarEventPalette.count]
    }
}
