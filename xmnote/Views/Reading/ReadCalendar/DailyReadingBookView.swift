/**
 * [INPUT]: 依赖 RepositoryContainer、DailyReadingBookViewModel、DailyReadingRecordRow 与 Book/Note/Content 导航回调
 * [OUTPUT]: 对外提供 DailyReadingBookView，展示单书当日可筛选、可排序、可编辑与可物理删除的记录流
 * [POS]: ReadCalendar 三级页面壳层，复用现有时间线卡片与系统菜单/弹窗表达
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 单书当日三级页，按 Android 记录类型提供查看、编辑、复制、分享与删除入口。
struct DailyReadingBookView: View {
    let onOpenBookRoute: (BookRoute) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    let onOpenContentRoute: (ContentRoute) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DailyReadingBookViewModel
    @State private var loadingGate = LoadingGate()
    @State private var editingRecord: DailyReadingRecord?
    @State private var pendingDelete: DailyReadingRecord?
    @State private var toastCenter = XMToastCenter()

    /// 注入日期、书籍摘要与跨模块路由回调。
    init(
        date: Date,
        summary: DailyReadingBookSummary,
        onOpenBookRoute: @escaping (BookRoute) -> Void,
        onOpenNoteRoute: @escaping (NoteRoute) -> Void,
        onOpenContentRoute: @escaping (ContentRoute) -> Void
    ) {
        self.onOpenBookRoute = onOpenBookRoute
        self.onOpenNoteRoute = onOpenNoteRoute
        self.onOpenContentRoute = onOpenContentRoute
        _viewModel = State(initialValue: DailyReadingBookViewModel(date: date, bookSummary: summary))
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            content
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarBackButton { dismiss() }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: Spacing.tiny) {
                    Text(viewModel.bookSummary.book.name)
                        .font(AppTypography.headline)
                        .lineLimit(1)
                    Text(viewModel.dateSubtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .sheet(item: $editingRecord) { record in
            editSheet(for: record)
        }
        .xmSystemAlert(item: $pendingDelete) { record in
            deleteDescriptor(for: record)
        }
        .xmToastHost(center: toastCenter)
        .task {
            syncLoadingGate()
            await viewModel.loadIfNeeded(using: repositories.readCalendarRepository)
            syncLoadingGate()
        }
        .onChange(of: viewModel.loadPhase) { _, _ in
            syncLoadingGate()
        }
        .onDisappear {
            viewModel.cancel()
            loadingGate.hideImmediately()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadPhase {
        case .idle, .loading where viewModel.records.isEmpty:
            if loadingGate.isVisible {
                LoadingStateView("正在加载阅读记录…", style: .card)
            } else {
                Color.clear
            }
        case .failed where viewModel.records.isEmpty:
            failureState
        default:
            loadedContent
        }
    }

    private var loadedContent: some View {
        VStack(spacing: Spacing.none) {
            controls

            if viewModel.records.isEmpty {
                ContentUnavailableView(
                    "没有符合条件的记录",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("可以切换记录类型，或返回当天汇总查看其他书籍。")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.none) {
                        ForEach(Array(viewModel.records.enumerated()), id: \.element.id) { index, record in
                            DailyReadingRecordRow(
                                record: record,
                                isLast: index == viewModel.records.count - 1,
                                onOpenContent: openContent,
                                onOpenBook: { bookID in
                                    onOpenBookRoute(.detail(bookId: bookID))
                                },
                                onEdit: { edit(record) },
                                onCopy: copy,
                                onDelete: { pendingDelete = record }
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.base)
                    .padding(.bottom, Spacing.double)
                }
                .safeAreaPadding(.bottom, Spacing.base)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .overlay(alignment: .top) {
            if viewModel.loadPhase == .loading, !viewModel.records.isEmpty {
                Rectangle().fill(Color.brand).frame(height: 2)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Spacing.half) {
            Menu {
                ForEach(DailyReadingTimelineFilter.allCases) { filter in
                    Button {
                        Task {
                            await viewModel.selectFilter(filter, using: repositories.readCalendarRepository)
                        }
                    } label: {
                        if filter == viewModel.filter {
                            Label(filter.title, systemImage: "checkmark")
                        } else {
                            Text(filter.title)
                        }
                    }
                }
            } label: {
                Label(viewModel.filter.title, systemImage: "line.3.horizontal.decrease")
                    .font(AppTypography.subheadlineMedium)
            }
            .buttonStyle(.bordered)

            Menu {
                ForEach(DailyReadingSortOrder.allCases) { order in
                    Button {
                        Task {
                            await viewModel.selectSort(order, using: repositories.readCalendarRepository)
                        }
                    } label: {
                        if order == viewModel.sortOrder {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            } label: {
                Label(
                    viewModel.sortOrder.title,
                    systemImage: viewModel.sortOrder == .descending ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease"
                )
                .font(AppTypography.subheadlineMedium)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var failureState: some View {
        ContentUnavailableView {
            Label("无法加载阅读记录", systemImage: "exclamationmark.triangle")
        } description: {
            Text(viewModel.errorMessage ?? "请稍后重试")
        } actions: {
            Button("重试") {
                Task { await viewModel.reload(using: repositories.readCalendarRepository) }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func editSheet(for record: DailyReadingRecord) -> some View {
        switch record.event.kind {
        case .checkIn(let event):
            ReadCalendarCheckInSheet(
                date: viewModel.date,
                recordID: record.recordID,
                initialBook: viewModel.bookSummary.book,
                initialAmount: Int(event.amount),
                isSaving: viewModel.isWriting,
                onSave: { bookID, amount in
                    try await viewModel.updateCheckIn(
                        recordID: record.recordID,
                        bookID: bookID,
                        amount: amount,
                        using: repositories.readCalendarRepository
                    )
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .readTiming(let event):
            ReadCalendarTimingEditorSheet(
                recordID: record.recordID,
                initialBook: viewModel.bookSummary.book,
                event: event,
                isSaving: viewModel.isWriting,
                onSave: { draft in
                    try await viewModel.updateTiming(draft, using: repositories.readCalendarRepository)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        default:
            Color.clear.onAppear { editingRecord = nil }
        }
    }

    /// 内容事件进入既有编辑页；计时与打卡使用本页业务 Sheet。
    private func edit(_ record: DailyReadingRecord) {
        switch record.event.kind {
        case .note(let note):
            onOpenNoteRoute(.edit(noteId: note.noteId))
        case .review(let review):
            onOpenContentRoute(.reviewEditor(reviewId: review.reviewId))
        case .relevant(let relevant):
            onOpenContentRoute(.relevantEditor(contentId: relevant.contentId))
        case .readTiming, .checkIn:
            editingRecord = record
        case .relevantBook, .readStatus:
            break
        }
    }

    /// 内容卡片进入通用查看器，范围限定为目标自然日与当前内容类型。
    private func openContent(_ itemID: ContentViewerItemID) {
        let start = Int64(viewModel.date.timeIntervalSince1970 * 1_000)
        let next = Calendar.current.date(byAdding: .day, value: 1, to: viewModel.date) ?? viewModel.date.addingTimeInterval(86_400)
        let end = Int64(next.timeIntervalSince1970 * 1_000) - 1
        let filter: TimelineContentFilter
        switch itemID {
        case .note: filter = .note
        case .review: filter = .review
        case .relevant: filter = .relevant
        }
        onOpenContentRoute(
            .contentViewer(
                source: .timeline(startTimestamp: start, endTimestamp: end, filter: filter),
                initialItemID: itemID
            )
        )
    }

    /// 复制记录文本并通过状态变化反馈完成，不额外弹成功提示。
    private func copy(_ text: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = text
#endif
    }

    /// 构建物理删除确认弹窗，明确不可撤销范围。
    private func deleteDescriptor(for record: DailyReadingRecord) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "删除这条记录？",
            message: "记录及其附图或关系会被物理删除，此操作无法撤销。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    Task { await delete(record) }
                }
            ]
        )
    }

    /// 执行删除并在失败时展示错误反馈；成功由列表收缩直接表达。
    private func delete(_ record: DailyReadingRecord) async {
        do {
            try await viewModel.delete(
                record,
                readCalendarRepository: repositories.readCalendarRepository,
                contentRepository: repositories.contentRepository
            )
        } catch {
            toastCenter.error("删除失败：\(error.localizedDescription)")
        }
    }

    /// 将读取阶段接入延迟显示和最短驻留门闩。
    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.loadPhase == .loading ? .read : .none)
    }
}
