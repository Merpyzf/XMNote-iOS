/**
 * [INPUT]: 依赖 RepositoryContainer、DailyReadingViewModel、当日阅读私有组件与 ReadCalendarRoute/BookRoute 回调
 * [OUTPUT]: 对外提供 DailyReadingView，展示日期汇总、逐书卡片并承接当日打卡
 * [POS]: ReadCalendar 二级页面壳层，采用当前 iOS 导航、卡片与加载反馈真相源
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 当日阅读二级页，进入时按日期重查全部数据，避免依赖日历页的裁剪快照。
struct DailyReadingView: View {
    let onOpenRoute: (ReadCalendarRoute) -> Void
    let onOpenBookRoute: (BookRoute) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DailyReadingViewModel
    @State private var loadingGate = LoadingGate()
    @State private var isCheckInPresented = false

    /// 注入目标日期和跨页面导航回调。
    init(
        date: Date,
        onOpenRoute: @escaping (ReadCalendarRoute) -> Void,
        onOpenBookRoute: @escaping (BookRoute) -> Void
    ) {
        self.onOpenRoute = onOpenRoute
        self.onOpenBookRoute = onOpenBookRoute
        _viewModel = State(initialValue: DailyReadingViewModel(date: date))
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            content
        }
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarBackButton { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCheckInPresented = true
                } label: {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                }
                .accessibilityLabel("当天阅读打卡")
            }
        }
        .sheet(isPresented: $isCheckInPresented) {
            ReadCalendarCheckInSheet(
                date: viewModel.date,
                initialBook: viewModel.summary.books.first?.book,
                isSaving: viewModel.isSavingCheckIn,
                onSave: { bookID, amount in
                    try await viewModel.saveCheckIn(
                        bookID: bookID,
                        amount: amount,
                        using: repositories.readCalendarRepository
                    )
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
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
        case .idle, .loading where viewModel.summary.books.isEmpty:
            if loadingGate.isVisible {
                LoadingStateView("正在加载当天阅读…", style: .card)
            } else {
                Color.clear
            }
        case .failed where viewModel.summary.books.isEmpty:
            failureState
        default:
            if viewModel.hasAnyData {
                loadedContent
            } else {
                emptyState
            }
        }
    }

    private var loadedContent: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.base) {
                if let headline = viewModel.headline {
                    DailyReadingSummaryCard(
                        headline: headline,
                        metrics: viewModel.metrics,
                        books: viewModel.summary.books
                    )
                }

                ForEach(viewModel.summary.books) { item in
                    DailyReadingBookCard(
                        summary: item,
                        onOpenReadingDetail: {
                            onOpenRoute(.dailyBook(date: viewModel.date, summary: item))
                        },
                        onOpenBook: {
                            onOpenBookRoute(.detail(bookId: item.book.id))
                        }
                    )
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .padding(.bottom, Spacing.double)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaPadding(.bottom, Spacing.base)
        .overlay(alignment: .top) {
            if viewModel.loadPhase == .loading, !viewModel.summary.books.isEmpty {
                Rectangle()
                    .fill(Color.brand)
                    .frame(height: 2)
                    .transition(.opacity)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("当天还没有阅读记录", systemImage: "calendar.badge.clock")
        } description: {
            Text("可以先完成一次阅读打卡，之后会在这里汇总。")
        } actions: {
            Button("阅读打卡") { isCheckInPresented = true }
                .buttonStyle(.bordered)
        }
    }

    private var failureState: some View {
        ContentUnavailableView {
            Label("无法加载当天阅读", systemImage: "exclamationmark.triangle")
        } description: {
            Text(viewModel.errorMessage ?? "请稍后重试")
        } actions: {
            Button("重试") {
                Task { await viewModel.reload(using: repositories.readCalendarRepository) }
            }
            .buttonStyle(.bordered)
        }
    }

    /// 将读取阶段接入延迟显示和最短驻留门闩，避免短请求闪烁。
    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.loadPhase == .loading ? .read : .none)
    }
}
