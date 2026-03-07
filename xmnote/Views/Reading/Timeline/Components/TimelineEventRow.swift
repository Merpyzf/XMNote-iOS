/**
 * [INPUT]: 依赖 TimelineEvent/TimelineSection 领域模型、7 种 Card 组件、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineEventRow（时间线单事件行）、TimelineSectionHeader（粘性日期头）与 TimelineSectionView（按日分组渲染）
 * [POS]: Reading/Timeline 页面私有子视图，整合左侧虚线装饰列与右侧事件卡片
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Timeline Section Header

/// 粘性日期头部：绿点 + MM.dd yyyy，用于 LazyVStack pinnedViews
struct TimelineSectionHeader: View {
    let date: Date

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Circle()
                .fill(Color.brand)
                .frame(width: dotSize, height: dotSize)

            HStack(spacing: Spacing.compact) {
                Text(monthDayString)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.textPrimary)

                Text(yearString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.textHint)
            }

            Spacer()
        }
        .padding(.vertical, Spacing.cozy)
        .padding(.horizontal, Spacing.screenEdge)
        .background(Color.windowBackground)
    }

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

/// 一日内的事件分组，使用 Section(header:) 实现粘性日期头部。
struct TimelineSectionView: View {
    let section: TimelineSection
    let isLast: Bool

    var body: some View {
        Section {
            ForEach(Array(section.events.enumerated()), id: \.element.id) { index, event in
                TimelineEventRow(
                    event: event,
                    isLastEvent: index == section.events.count - 1 && isLast
                )
            }
        } header: {
            TimelineSectionHeader(date: section.date)
        }
    }
}

// MARK: - Timeline Event Row

/// 时间线单事件行：左侧虚线装饰 + 右侧卡片，时间与书名已移入卡片内部。
struct TimelineEventRow: View {
    let event: TimelineEvent
    let isLastEvent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            dashedLine
                .frame(width: decoratorWidth)

            cardContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Spacing.compact)
                .padding(.bottom, Spacing.screenEdge)
        }
        .padding(.horizontal, Spacing.screenEdge)
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
private let decoratorWidth: CGFloat = 20

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
                    bookTitle: "代码整洁之道"
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
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            TimelineSectionView(section: section, isLast: true)
        }
    }
    .background(Color.windowBackground)
}
