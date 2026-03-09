/**
 * [INPUT]: 依赖 TimelineEvent/TimelineSection/TimelineEventCategory 领域模型、7 种 Card 组件、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineEventRow（时间线单事件行）、TimelineSectionHeader（粘性日期头 + 筛选 Menu）与 TimelineSectionView（按日分组渲染，每组均携带分类筛选）
 * [POS]: Reading/Timeline 页面私有子视图，整合左侧虚线装饰列与右侧事件卡片
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Timeline Section Header

/// 粘性日期头部：绿点 + MM.dd yyyy + 筛选 Menu，用于 LazyVStack pinnedViews。
/// 每个 SectionHeader 均携带筛选 Menu，吸顶切换时无缝接力、无闪烁。
struct TimelineSectionHeader: View {
    let date: Date
    let selectedCategory: TimelineEventCategory
    let onCategorySelected: (TimelineEventCategory) -> Void

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

                Text(yearString)
                    .font(TimelineCalendarStyle.sectionYearFont)
                    .monospacedDigit()
                    .foregroundStyle(Color.textHint)
            }

            Spacer()

            categoryFilterMenu(selected: selectedCategory, action: onCategorySelected)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.cozy)
        .background {
            Rectangle()
                .fill(Color.windowBackground)
        }
    }

    // MARK: - Filter Menu

    private func categoryFilterMenu(
        selected: TimelineEventCategory,
        action: @escaping (TimelineEventCategory) -> Void
    ) -> some View {
        Menu {
            ForEach(TimelineEventCategory.allCases) { category in
                Button {
                    action(category)
                } label: {
                    if category == selected {
                        Label(category.rawValue, systemImage: "checkmark")
                    } else {
                        Text(category.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.compact) {
                Text(selected.rawValue)
                    .font(TimelineCalendarStyle.sectionFilterFont)
                    .foregroundStyle(Color.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.textHint)
            }
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Color.bgSecondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Date Formatting

    private var monthDayString: String {
        let f = DateFormatter()
        f.dateFormat = "MM.dd"
        return f.string(from: date)
    }

    private var yearString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f.string(from: date)
    }
}

// MARK: - Timeline Section

/// 一日内的事件分组，每个头部均携带分类筛选 Menu。
struct TimelineSectionView: View {
    let section: TimelineSection
    let isLast: Bool
    let selectedCategory: TimelineEventCategory
    let onCategorySelected: (TimelineEventCategory) -> Void

    var body: some View {
        Section {
            ForEach(Array(section.events.enumerated()), id: \.element.id) { index, event in
                TimelineEventRow(
                    event: event,
                    isLastEvent: index == section.events.count - 1 && isLast
                )
            }
        } header: {
            TimelineSectionHeader(
                date: section.date,
                selectedCategory: selectedCategory,
                onCategorySelected: onCategorySelected
            )
        }
    }
}

// MARK: - Timeline Event Row

/// 时间线单事件行：左侧虚线装饰 + 右侧卡片，时间与书名已移入卡片内部。
struct TimelineEventRow: View {
    let event: TimelineEvent
    let isLastEvent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.none) {
            dashedLine
                .frame(width: decoratorWidth)

            cardContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Spacing.cozy)
                .padding(.bottom, Spacing.screenEdge)
        }
    }

    // MARK: - Left Decorator

    private var dashedLine: some View {
        GeometryReader { geo in
            Path { path in
                let x = dotSize / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: isLastEvent ? geo.size.height * 0.5 : geo.size.height))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(Color.textHint.opacity(0.35))
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

// MARK: - Shared Constants

/// 绿色圆点直径，section header 与装饰列共用
private let dotSize: CGFloat = 8

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
                .font(.caption)
                .foregroundStyle(Color.textHint)

            if !bookName.isEmpty {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(Color.textHint)

                Text("《\(bookName)》")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var timeString: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
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
                    imageURLs: []
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
                selectedCategory: .all,
                onCategorySelected: { _ in }
            )
        }
    }
    .background(Color.windowBackground)
}
