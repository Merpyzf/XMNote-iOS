/**
 * [INPUT]: 依赖 RepositoryContainer、BookReadingDetailViewModel、BookReadingDetailContent、业务 Sheet、LoadingGate 与完成庆祝层
 * [OUTPUT]: 对外提供 BookReadingDetailView，承载单一封面色沉浸背景、单书阅读详情加载、编辑、同构长图分享和一次性读完庆祝
 * [POS]: Views/Book 独立二级页面壳层，页面内容归位到 Components，业务弹层归位到 Sheets
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 单书阅读详情页面；只拥有页面级呈现状态，数据事实与写入统一委托给 ViewModel/Repository。
struct BookReadingDetailView: View {
    let onOpenBookRoute: (BookRoute) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @State private var viewModel: BookReadingDetailViewModel
    @State private var loadingGate = LoadingGate()
    @State private var presentedSheet: PresentedSheet?
    @State private var expandedMonthIDs: Set<MonthlyReadingChart.MonthID> = []
    @State private var didApplyMonthlyDefault = false
    @State private var toastCenter = XMToastCenter()

    /// 注入书籍主键与书籍模块路由回调。
    init(bookID: Int64, onOpenBookRoute: @escaping (BookRoute) -> Void) {
        self.onOpenBookRoute = onOpenBookRoute
        _viewModel = State(initialValue: BookReadingDetailViewModel(bookID: bookID))
    }

    var body: some View {
        ZStack {
            BookReadingDetailAtmosphere(theme: visualTheme, topPlateau: 0.20)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            pageContent

            if let tracker = viewModel.completionTracker {
                BookReadingCompletionCelebration(
                    tracker: tracker,
                    onDismiss: viewModel.dismissCompletionCelebration
                )
                .zIndex(10)
                .transition(.opacity)
            }
        }
        .animation(.smooth, value: viewModel.completionTracker)
        .animation(
            accessibilityReduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.8),
            value: visualTheme.identity
        )
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: $presentedSheet, content: presentedSheetContent)
        .xmToastHost(center: toastCenter)
        .task {
            syncLoadingGate()
            await viewModel.observe(using: repositories.bookReadingDetailRepository)
        }
        .task(id: viewModel.snapshot?.book.coverURL) {
            guard viewModel.snapshot != nil else { return }
            await viewModel.resolveCoverThemeColor(using: repositories.readCalendarColorRepository)
        }
        .onChange(of: viewModel.loadPhase) { _, _ in syncLoadingGate() }
        .onChange(of: viewModel.snapshot?.book.id) { _, newValue in
            guard newValue != nil, !didApplyMonthlyDefault else { return }
            didApplyMonthlyDefault = true
            applyMonthlyDefault()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            toastCenter.error(message)
            viewModel.consumeError()
        }
        .onDisappear { loadingGate.hideImmediately() }
    }
}

private extension BookReadingDetailView {
    enum PresentedSheet: Identifiable {
        case progress
        case addStatus
        case editStatus(Int64)
        case setting
        case share
        case cover

        var id: String {
            switch self {
            case .progress: "progress"
            case .addStatus: "add-status"
            case let .editStatus(recordID): "edit-status-\(recordID)"
            case .setting: "setting"
            case .share: "share"
            case .cover: "cover"
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                presentedSheet = .share
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .tint(Color.textPrimary)
            .accessibilityLabel("分享阅读详情")
            .disabled(viewModel.snapshot == nil || viewModel.isWriting)

            Button {
                onOpenBookRoute(.edit(bookId: viewModel.bookID))
            } label: {
                Image(systemName: "pencil")
                    .font(AppTypography.headlineSemibold)
            }
            .tint(Color.textPrimary)
            .accessibilityLabel("编辑书籍")
            .disabled(viewModel.isWriting)

            Menu {
                Button("显示设置", systemImage: "slider.horizontal.3") {
                    presentedSheet = .setting
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppTypography.bodyMedium)
                    .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
            }
            .tint(Color.textPrimary)
            .accessibilityLabel("阅读详情更多操作")
            .disabled(viewModel.isWriting)
        }
    }

    @ViewBuilder
    var pageContent: some View {
        if let snapshot = viewModel.snapshot {
            ScrollView {
                BookReadingDetailContent(
                    snapshot: snapshot,
                    mode: .interactive,
                    theme: visualTheme,
                    ratingValue: Binding(
                        get: { viewModel.ratingValue },
                        set: { viewModel.ratingValue = $0 }
                    ),
                    expandedMonthIDs: $expandedMonthIDs,
                    onOpenCover: { presentedSheet = .cover },
                    onOpenBookInfo: { onOpenBookRoute(.edit(bookId: viewModel.bookID)) },
                    onRatingChanged: { value in
                        Task {
                            await viewModel.updateRating(
                                value,
                                using: repositories.bookReadingDetailRepository
                            )
                        }
                    },
                    onChangeReadingStatus: { presentedSheet = .addStatus },
                    onEditReadingStatus: { item in
                        guard let recordID = item.recordID else { return }
                        presentedSheet = .editStatus(recordID)
                    },
                    onUpdateReadingProgress: { presentedSheet = .progress }
                )
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.contentEdge)
                .padding(.bottom, Spacing.base)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.always)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else if viewModel.loadPhase == .failed {
            ContentUnavailableView(
                "无法加载阅读详情",
                systemImage: "exclamationmark.triangle",
                description: Text(viewModel.errorMessage ?? "书籍不存在或已被删除")
            )
        } else if loadingGate.isVisible {
            LoadingStateView("正在整理阅读数据…", style: .card)
        }
    }

    @ViewBuilder
    func presentedSheetContent(_ sheet: PresentedSheet) -> some View {
        switch sheet {
        case .progress:
            if let snapshot = viewModel.snapshot {
                BookReadingProgressSheet(
                    book: snapshot.book,
                    progress: snapshot.analytics.progress,
                    isSaving: viewModel.isSavingProgress,
                    onSave: { current, total in
                        try await viewModel.updateProgress(
                            currentValue: current,
                            totalValue: total,
                            using: repositories.bookReadingDetailRepository
                        )
                    }
                )
            }
        case .addStatus:
            if let snapshot = viewModel.snapshot {
                statusSheet(snapshot: snapshot, editingItem: nil)
            }
        case let .editStatus(recordID):
            if let snapshot = viewModel.snapshot,
               let item = snapshot.statusHistory.first(where: { $0.recordID == recordID }) {
                statusSheet(snapshot: snapshot, editingItem: item)
            }
        case .setting:
            BookReadingDetailSettingSheet(
                setting: viewModel.setting,
                onChange: { value in
                    viewModel.saveSetting(value, using: repositories.bookReadingDetailRepository)
                    if !value.isMonthlyChartCollapsedByDefault {
                        expandAllMonths()
                    }
                }
            )
        case .share:
            if let snapshot = viewModel.snapshot {
                BookReadingDetailShareSheet(
                    snapshot: snapshot,
                    theme: visualTheme,
                    setting: viewModel.shareSetting,
                    expandedMonthIDs: expandedMonthIDs,
                    onSettingChange: {
                        viewModel.saveShareSetting(
                            $0,
                            using: repositories.bookReadingDetailRepository
                        )
                    }
                )
            }
        case .cover:
            if let book = viewModel.snapshot?.book {
                BookReadingCoverPreview(book: book)
            }
        }
    }

    @ViewBuilder
    func statusSheet(
        snapshot: BookReadingDetailSnapshot,
        editingItem: BookReadingStatusHistoryItem?
    ) -> some View {
        if editingItem?.recordID != nil {
            BookReadingStatusSheet(
                book: snapshot.book,
                options: snapshot.statusOptions,
                editingItem: editingItem,
                isSaving: viewModel.isSavingStatus,
                onSave: saveReadingStatus,
                onDelete: deleteReadingStatus
            )
        } else {
            BookReadingStatusSheet(
                book: snapshot.book,
                options: snapshot.statusOptions,
                editingItem: nil,
                isSaving: viewModel.isSavingStatus,
                onSave: saveReadingStatus
            )
        }
    }

    /// 将状态 Sheet 的保存动作收敛到稳定方法引用，规避复杂 ViewBuilder 中可选异步闭包推断歧义。
    func saveReadingStatus(_ input: BookReadingStatusInput) async throws {
        try await viewModel.saveReadingStatus(
            input,
            using: repositories.bookReadingDetailRepository
        )
    }

    /// 删除精确状态记录；唯一记录保护与当前状态回落由 Repository 事务负责。
    func deleteReadingStatus(_ recordID: Int64) async throws {
        try await viewModel.deleteReadingStatus(
            recordID: recordID,
            using: repositories.bookReadingDetailRepository
        )
    }

    var visualTheme: BookReadingDetailTheme {
        BookReadingDetailTheme(
            coverColor: viewModel.coverThemeColor,
            isEnabled: viewModel.setting.isCoverBackgroundEnabled,
            colorScheme: colorScheme,
            reducesTransparency: accessibilityReduceTransparency
        )
    }

    /// 设置首次月图状态；默认收起时保持空集合，否则一次性展开当前全部月份。
    func applyMonthlyDefault() {
        if viewModel.setting.isMonthlyChartCollapsedByDefault {
            expandedMonthIDs = []
        } else {
            expandAllMonths()
        }
    }

    /// 以自然年月稳定标识展开全部月份，观察流刷新不会丢失仍存在月份的状态。
    func expandAllMonths() {
        expandedMonthIDs = Set(
            viewModel.snapshot?.monthlyDurations.map {
                MonthlyReadingChart.MonthID(year: $0.year, month: $0.month)
            } ?? []
        )
    }

    /// 将页面加载意图同步给延迟显示、最短驻留的读取门闩。
    func syncLoadingGate() {
        loadingGate.update(intent: viewModel.loadPhase == .loading ? .read : .none)
    }
}
