/**
 * [INPUT]: 依赖 TimelineEvent/TimelineSection 领域模型、7 种 Card 组件、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineEventRow（时间线单事件行）、TimelineSectionHeader（粘性日期头 + 右侧筛选占位）与 TimelineSectionView（按日分组渲染）
 * [POS]: Reading/Timeline 页面私有子视图，整合左侧虚线装饰列与右侧事件卡片
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Timeline Section Header

/// 粘性日期头部：绿点 + MM.dd yyyy + 右侧筛选入口占位，用于 LazyVStack pinnedViews。
/// 实际筛选入口由页面层单实例承载，避免 section 切换时控件实例抖动。
struct TimelineSectionHeader: View, Equatable {
    let date: Date
    let trailingPlaceholderWidth: CGFloat

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Circle()
                .fill(Color.brand)
                .frame(width: dotSize, height: dotSize)

            HStack(alignment: .lastTextBaseline, spacing: Spacing.base) {
                Text(monthDayString)
                    .font(TimelineCalendarStyle.sectionDateFont)
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                    .brandVerticalTrim(TimelineCalendarStyle.sectionDateVerticalTrim, edges: [.top, .bottom])

                Text(yearString)
                    .font(TimelineCalendarStyle.sectionYearFont)
                    .monospacedDigit()
                    .foregroundStyle(Color.textHint)
                    .brandVerticalTrim(TimelineCalendarStyle.sectionDateVerticalTrim, edges: [.top, .bottom])
            }

            Spacer()

            Color.clear
                .frame(
                    width: trailingPlaceholderWidth,
                    height: sectionHeaderTrailingPlaceholderHeight
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.cozy)
        .background {
            Rectangle()
                .fill(Color.surfacePage)
        }
    }

    // MARK: - Date Formatting

    private var monthDayString: String {
        Self.monthDayFormatter.string(from: date)
    }

    private var yearString: String {
        Self.yearFormatter.string(from: date)
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM.dd"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()
}

// MARK: - Timeline Section

/// 一日内的事件分组，头部仅负责日期展示与筛选占位。
struct TimelineSectionView: View {
    let section: TimelineSection
    let isLast: Bool
    let trailingPlaceholderWidth: CGFloat

    var body: some View {
        Section {
            ForEach(section.events) { event in
                TimelineEventRow(
                    event: event,
                    isLastEvent: isLast && event.id == section.events.last?.id
                )
                .equatable()
            }
        } header: {
            TimelineSectionHeader(
                date: section.date,
                trailingPlaceholderWidth: trailingPlaceholderWidth
            )
        }
    }
}

// MARK: - Timeline Event Row

/// 时间线单事件行：左侧虚线装饰 + 右侧卡片，时间与书名已移入卡片内部。
struct TimelineEventRow: View, Equatable {
    let event: TimelineEvent
    let isLastEvent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.none) {
            TimelineConnectorShape(isLastEvent: isLastEvent)
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(Color.textHint.opacity(0.35))
                .frame(width: decoratorWidth)

            cardContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Spacing.cozy)
                .padding(.bottom, Spacing.screenEdge)
        }
    }

    // MARK: - Card Content

    @ViewBuilder
    private var cardContent: some View {
        switch event.kind {
        case .note(let e):
            TimelineNoteCard(
                event: e,
                timestamp: event.timestamp,
                bookName: event.bookName
            )

        case .readTiming(let e):
            TimelineTimingCard(
                event: e,
                timestamp: event.timestamp,
                bookName: event.bookName,
                bookAuthor: event.bookAuthor,
                bookCover: event.bookCover
            )

        case .readStatus(let e):
            TimelineStatusCard(
                event: e,
                timestamp: event.timestamp,
                bookName: event.bookName,
                bookAuthor: event.bookAuthor,
                bookCover: event.bookCover
            )

        case .checkIn(let e):
            TimelineCheckInCard(
                event: e,
                timestamp: event.timestamp,
                bookName: event.bookName,
                bookAuthor: event.bookAuthor,
                bookCover: event.bookCover
            )

        case .review(let e):
            TimelineReviewCard(
                event: e,
                timestamp: event.timestamp,
                bookName: event.bookName
            )

        case .relevant(let e):
            TimelineRelevantCard(
                event: e,
                timestamp: event.timestamp,
                bookName: event.bookName
            )

        case .relevantBook(let e):
            TimelineRelevantBookCard(
                event: e,
                timestamp: event.timestamp,
                bookName: event.bookName
            )
        }
    }
}

private struct TimelineConnectorShape: Shape {
    let isLastEvent: Bool

    /// 按是否为最后一条事件绘制时间线装饰虚线，避免分组尾部继续向下延伸。
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = dotSize / 2
        let endY = isLastEvent ? rect.height * 0.5 : rect.height
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: endY))
        return path
    }
}

// MARK: - Shared Constants

/// 绿色圆点直径，section header 与装饰列共用
private let dotSize: CGFloat = 8

/// SectionHeader 右侧筛选入口占位高度
private let sectionHeaderTrailingPlaceholderHeight: CGFloat = 24

/// 左侧装饰列宽度
private let decoratorWidth: CGFloat = 16

// MARK: - Meta Line Helper

/// 卡片内部 meta 行：HH:mm · 《书名》，7 种卡片统一复用
struct TimelineCardMetaLine: View {
    let timestamp: Int64
    let bookName: String

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Text(timeString)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)

            if !bookName.isEmpty {
                Text("·")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)

                Text("《\(bookName)》")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var timeString: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

#Preview {
    let section = TimelineSection(
        id: "2026-03-07",
        date: Date(),
        events: [
            TimelineEvent(
                id: "note_1",
                kind: .note(TimelineNoteEvent(
                    content: "好的代码读起来像散文一样流畅。",
                    idea: "这就是为什么命名如此重要",
                    bookTitle: "代码整洁之道",
                    imageURLs: [],
                    tagNames: ["编码", "命名"]
                )),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                bookName: "代码整洁之道",
                bookAuthor: "Robert C. Martin",
                bookCover: ""
            ),
            TimelineEvent(
                id: "timing_1",
                kind: .readTiming(TimelineReadTimingEvent(
                    elapsedSeconds: 3600,
                    startTime: 0, endTime: 0, fuzzyReadDate: 0
                )),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000) - 3600000,
                bookName: "代码整洁之道",
                bookAuthor: "Robert C. Martin",
                bookCover: ""
            ),
        ]
    )

    ScrollView {
        LazyVStack(spacing: Spacing.none, pinnedViews: [.sectionHeaders]) {
            TimelineSectionView(
                section: section,
                isLast: true,
                trailingPlaceholderWidth: 76
            )
        }
    }
    .background(Color.surfacePage)
}

/// Preview 专用空实现
private struct _StubTimelineRepository: TimelineRepositoryProtocol {
    /// 预览环境不依赖真实时间线数据，返回空分组即可满足页面挂载。
    func fetchTimelineEvents(startTimestamp: Int64, endTimestamp: Int64, category: TimelineEventCategory) async throws -> [TimelineSection] { [] }
    /// 预览环境不渲染真实月标记，返回空字典避免额外数据库依赖。
    func fetchCalendarMarkers(for monthStart: Date, category: TimelineEventCategory) async throws -> [Date: TimelineDayMarker] { [:] }
}
