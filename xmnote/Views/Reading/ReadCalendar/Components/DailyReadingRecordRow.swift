/**
 * [INPUT]: 依赖 DailyReadingRecord、Timeline 各事件卡片与查看/编辑/复制/删除回调
 * [OUTPUT]: 对外提供 DailyReadingRecordRow，渲染单书当日记录及类型对应操作菜单
 * [POS]: ReadCalendar 三级页面私有组件，复用既有时间线视觉并补齐 Android 记录管理入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 单书当日记录行；内容点击进入查看，计时/打卡点击进入编辑，删除统一交给页面确认。
struct DailyReadingRecordRow: View {
    let record: DailyReadingRecord
    let isLast: Bool
    let onOpenContent: (ContentViewerItemID) -> Void
    let onOpenBook: (Int64) -> Void
    let onEdit: () -> Void
    let onCopy: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.none) {
            connector

            ZStack(alignment: .topTrailing) {
                Button(action: handleTap) {
                    cardContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                recordMenu
                    .padding(.top, Spacing.cozy)
                    .padding(.trailing, Spacing.cozy)
            }
            .padding(.leading, Spacing.cozy)
            .padding(.bottom, Spacing.screenEdge)
        }
    }

    private var connector: some View {
        VStack(spacing: Spacing.compact) {
            Text(timeText)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
                .monospacedDigit()
                .fixedSize()
            Circle()
                .fill(Color.brand)
                .frame(width: 7, height: 7)
            if !isLast {
                Rectangle()
                    .fill(Color.textHint.opacity(0.24))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 46)
    }

    @ViewBuilder
    private var cardContent: some View {
        switch record.event.kind {
        case .note(let event):
            TimelineNoteCard(event: event, timestamp: record.event.timestamp, bookName: record.event.bookName)
        case .readTiming(let event):
            TimelineTimingCard(
                event: event,
                timestamp: record.event.timestamp,
                bookName: record.event.bookName,
                bookAuthor: record.event.bookAuthor,
                bookCover: record.event.bookCover
            )
        case .checkIn(let event):
            TimelineCheckInCard(
                event: event,
                timestamp: record.event.timestamp,
                bookName: record.event.bookName,
                bookAuthor: record.event.bookAuthor,
                bookCover: record.event.bookCover
            )
        case .review(let event):
            TimelineReviewCard(event: event, timestamp: record.event.timestamp, bookName: record.event.bookName)
        case .relevant(let event):
            TimelineRelevantCard(event: event, timestamp: record.event.timestamp, bookName: record.event.bookName)
        case .relevantBook(let event):
            TimelineRelevantBookCard(event: event, timestamp: record.event.timestamp, bookName: record.event.bookName)
        case .readStatus(let event):
            TimelineStatusCard(
                event: event,
                timestamp: record.event.timestamp,
                bookName: record.event.bookName,
                bookAuthor: record.event.bookAuthor,
                bookCover: record.event.bookCover
            )
        }
    }

    private var recordMenu: some View {
        Menu {
            Button("打开书籍", systemImage: "book") {
                onOpenBook(record.event.sourceBookId)
            }

            switch record.event.kind {
            case .readTiming, .checkIn:
                Button("编辑", systemImage: "pencil") { onEdit() }
            case .note, .review, .relevant:
                Button("编辑", systemImage: "pencil") { onEdit() }
                Button("复制", systemImage: "doc.on.doc") { onCopy(shareText) }
                ShareLink(item: shareText) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            case .relevantBook(let event):
                Button("打开相关书籍", systemImage: "books.vertical") {
                    onOpenBook(event.contentBookId)
                }
            case .readStatus:
                EmptyView()
            }

            if canDelete {
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) {
                    onDelete()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .accessibilityLabel("记录操作")
    }

    private var canDelete: Bool {
        if case .readStatus = record.event.kind { return false }
        return true
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(record.event.timestamp) / 1_000))
    }

    private var shareText: String {
        switch record.event.kind {
        case .note(let event):
            return [event.content, event.idea].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .review(let event):
            return [event.title, event.content].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .relevant(let event):
            return [event.title, event.content, event.url].filter { !$0.isEmpty }.joined(separator: "\n\n")
        default:
            return record.event.bookName
        }
    }

    private func handleTap() {
        switch record.event.kind {
        case .note(let event): onOpenContent(.note(event.noteId))
        case .review(let event): onOpenContent(.review(event.reviewId))
        case .relevant(let event): onOpenContent(.relevant(event.contentId))
        case .relevantBook(let event): onOpenBook(event.contentBookId)
        case .readTiming, .checkIn: onEdit()
        case .readStatus: onOpenBook(record.event.sourceBookId)
        }
    }
}
