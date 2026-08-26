/**
 * [INPUT]: 依赖 RepositoryContainer 或 Debug 仓储替身提供本地书与在线搜索，依赖 BookPickerViewModel 维护共享选择草稿
 * [OUTPUT]: 对外提供 BookPickerView，使用统一 Sheet 骨架、原生系统搜索、稳定结果快照与可降级结构过渡承载选择流
 * [POS]: Book 模块业务 Sheet，负责统一书籍选择流，不承担具体业务页保存逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 允许测试中心替换数据源，同时保持生产入口继续从 App 环境读取仓储。
private struct BookPickerRepositoryOverride {
    let bookRepository: any BookPickerRepositoryProtocol
    let searchRepository: any BookSearchRepositoryProtocol
}

/// 书籍选择页的局部强调排版，承接搜索结果中高亮字重的专属规格。
private enum BookPickerTypography {
    static let resultTitleHighlight = AppTypography.semantic(.subheadline, weight: .bold)
}

/// 通用书籍选择流入口；生产路径读取 App 仓储，测试中心可注入固定数据源。
struct BookPickerView: View {
    let configuration: BookPickerConfiguration
    let onComplete: (BookPickerResult) -> Void

    private let repositoryOverride: BookPickerRepositoryOverride?

    /// 创建使用 App 仓储环境的生产书籍选择 Sheet。
    init(
        configuration: BookPickerConfiguration,
        onComplete: @escaping (BookPickerResult) -> Void
    ) {
        self.configuration = configuration
        self.onComplete = onComplete
        self.repositoryOverride = nil
    }

    #if DEBUG
    /// 为测试中心注入固定仓储替身，避免调试场景依赖真实书架或外部网络。
    init(
        configuration: BookPickerConfiguration,
        bookRepository: any BookPickerRepositoryProtocol,
        searchRepository: any BookSearchRepositoryProtocol,
        onComplete: @escaping (BookPickerResult) -> Void
    ) {
        self.configuration = configuration
        self.onComplete = onComplete
        self.repositoryOverride = BookPickerRepositoryOverride(
            bookRepository: bookRepository,
            searchRepository: searchRepository
        )
    }
    #endif

    @ViewBuilder
    var body: some View {
        if let repositoryOverride {
            BookPickerResolvedView(
                configuration: configuration,
                onComplete: onComplete,
                bookRepository: repositoryOverride.bookRepository,
                searchRepository: repositoryOverride.searchRepository
            )
        } else {
            BookPickerEnvironmentResolver(
                configuration: configuration,
                onComplete: onComplete
            )
        }
    }
}

/// 仅生产分支读取仓储环境，确保 Debug 固定场景不需要挂载完整 App 依赖树。
private struct BookPickerEnvironmentResolver: View {
    let configuration: BookPickerConfiguration
    let onComplete: (BookPickerResult) -> Void

    @Environment(RepositoryContainer.self) private var repositories

    var body: some View {
        BookPickerResolvedView(
            configuration: configuration,
            onComplete: onComplete,
            bookRepository: repositories.bookRepository,
            searchRepository: repositories.bookSearchRepository
        )
    }
}

/// 持有一次选择会话的共享草稿，并把同一份状态提供给外层与已选管理 Sheet。
private struct BookPickerResolvedView: View {
    let configuration: BookPickerConfiguration
    let onComplete: (BookPickerResult) -> Void
    let bookRepository: any BookPickerRepositoryProtocol
    let searchRepository: any BookSearchRepositoryProtocol

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var viewModel: BookPickerViewModel?
    @State private var activeSheet: ActiveSheet?
    @State private var isSearchActive = false
    @State private var isPreparingSeed = false
    @State private var didComplete = false
    @State private var pendingScrollBookID: Int64?
    @State private var localLoadingGate = LoadingGate()
    @State private var confirmationTask: Task<Void, Never>?

    private enum ActiveSheet: String, Identifiable {
        case selectedBooks

        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            if let viewModel {
                pickerScaffold(viewModel)
            } else {
                XMSheetScaffold(
                    title: configuration.title,
                    onClose: handleCancel
                ) {
                    LoadingStateView("正在准备书籍选择…", style: .card)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Spacing.section)
                }
            }

            if let viewModel, let blockingOverlayMessage = blockingOverlayMessage(for: viewModel) {
                Color.overlay.ignoresSafeArea()
                LoadingStateView(blockingOverlayMessage, style: .card)
            }
        }
        .task {
            await prepareViewModelIfNeeded()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .selectedBooks:
                if let viewModel {
                    BookPickerSelectedBooksSheet(viewModel: viewModel)
                }
            }
        }
        .onDisappear {
            localLoadingGate.hideImmediately()
            confirmationTask?.cancel()
            confirmationTask = nil
        }
    }

    @ViewBuilder
    private func pickerScaffold(_ viewModel: BookPickerViewModel) -> some View {
        if viewModel.isMultipleSelectionEnabled {
            XMSheetScaffold(
                title: configuration.title,
                onClose: handleCancel,
                scrollEdgePresentation: .overlaySoft,
                contentTopBar: {
                    pickerTopBar(viewModel, includesSelectionSummary: true)
                },
                bottomBar: {
                    multipleSelectionBar(viewModel)
                }
            ) {
                scrollableContent(viewModel)
            }
        } else {
            XMSheetScaffold(
                title: configuration.title,
                onClose: handleCancel,
                scrollEdgePresentation: .overlaySoft,
                contentTopBar: {
                    pickerTopBar(viewModel, includesSelectionSummary: false)
                }
            ) {
                scrollableContent(viewModel)
            }
        }
    }

    private func pickerTopBar(
        _ viewModel: BookPickerViewModel,
        includesSelectionSummary: Bool
    ) -> some View {
        VStack(spacing: Spacing.none) {
            if includesSelectionSummary {
                BookPickerSelectionSubtitle(
                    count: viewModel.selectedCount,
                    allowsEmptySelection: viewModel.allowsEmptyMultipleConfirmation,
                    onOpenSelection: { activeSheet = .selectedBooks }
                )
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.bottom, Spacing.comfortable)
            }

            searchBar(viewModel)
        }
    }

    private func searchBar(_ viewModel: BookPickerViewModel) -> some View {
        XMSearchBar(
            text: Binding(
                get: { viewModel.query },
                set: { viewModel.updateQuery($0) }
            ),
            isActive: $isSearchActive,
            prompt: "搜索书名、作者、ISBN",
            isEnabled: !viewModel.isResolvingRemoteSelections,
            onSubmit: {
                guard viewModel.visibleScope == .online else { return }
                Task {
                    await viewModel.submitOnlineSearch()
                }
            }
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.section)
    }

    private func scrollableContent(_ viewModel: BookPickerViewModel) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: Spacing.base) {
                if showsControls(viewModel) {
                    controlsSection(viewModel)
                }
                resultsSection(viewModel)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.section)
            .onAppear {
                syncLocalLoadingGate(viewModel)
                scrollToPendingBookIfNeeded(using: proxy, viewModel: viewModel)
            }
            .onChange(of: viewModel.status) { _, _ in
                syncLocalLoadingGate(viewModel)
            }
            .onChange(of: viewModel.localBooks.map(\.id)) { _, _ in
                scrollToPendingBookIfNeeded(using: proxy, viewModel: viewModel)
            }
        }
    }

    private func showsControls(_ viewModel: BookPickerViewModel) -> Bool {
        viewModel.supportsScopeSwitch
            || (viewModel.supportsOnline && viewModel.visibleScope == .online)
    }

    @ViewBuilder
    private func controlsSection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if viewModel.supportsScopeSwitch {
                Picker(
                    "结果来源",
                    selection: Binding(
                        get: { viewModel.visibleScope },
                        set: { viewModel.switchVisibleScope($0) }
                    )
                ) {
                    Text("本地").tag(BookPickerVisibleScope.local)
                    Text("在线").tag(BookPickerVisibleScope.online)
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.isResolvingRemoteSelections)
            }

            if viewModel.supportsOnline, viewModel.visibleScope == .online {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.half) {
                        ForEach(configuration.onlineSources, id: \.self) { source in
                            Button {
                                viewModel.selectOnlineSource(source)
                            } label: {
                                Text(source.title)
                                    .font(
                                        viewModel.selectedOnlineSource == source
                                            ? AppTypography.footnoteSemibold
                                            : AppTypography.footnoteMedium
                                    )
                                    .foregroundStyle(viewModel.selectedOnlineSource == source ? .white : Color.textSecondary)
                                    .padding(.horizontal, Spacing.base)
                                    .frame(height: 34)
                                    .background(
                                        viewModel.selectedOnlineSource == source
                                            ? AnyShapeStyle(Color.selectionAccent)
                                            : AnyShapeStyle(Color.controlFillSecondary),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(
                                                viewModel.selectedOnlineSource == source ? Color.clear : Color.surfaceBorderSubtle,
                                                lineWidth: StrokeWidth.hairline
                                            )
                                    }
                            }
                            .buttonStyle(BookSearchChipButtonStyle())
                            .disabled(viewModel.isResolvingRemoteSelections)
                        }
                    }
                }
                .scrollBounceBehavior(.always)
            }

        }
    }

    @ViewBuilder
    private func resultsSection(_ viewModel: BookPickerViewModel) -> some View {
        Group {
            switch viewModel.status {
            case .localLoading:
                localLoadingSection
            case .localResults:
                localResultsSection(viewModel)
            case .localEmptyLibrary:
                localEmptyLibrarySection(viewModel)
            case .localNoResults:
                localNoResultsSection(viewModel)
            case .onlineIdle:
                onlineIdleSection(viewModel)
            case .onlineLoading:
                onlineLoadingSection(viewModel)
            case .onlineResults:
                onlineResultsSection(viewModel)
            case .onlineFailure(let message):
                onlineFailureSection(viewModel, message: message)
            case .onlineNoResults:
                onlineNoResultsSection(viewModel)
            }
        }
        .id(viewModel.status)
        .transition(.opacity)
        .animation(resultsTransitionAnimation, value: viewModel.status)
    }

    private var localLoadingSection: some View {
        VStack(spacing: Spacing.base) {
            if localLoadingGate.isVisible {
                LoadingStateView("正在读取本地书籍…", style: .inline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Spacing.section)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: Spacing.section * 2)
                    .accessibilityHidden(true)
            }
        }
    }

    private func localResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        BookPickerGroupedSurface {
            LazyVStack(alignment: .leading, spacing: Spacing.none) {
                ForEach(viewModel.localBooks.enumerated(), id: \.element.id) { index, book in
                    let isUnavailable = viewModel.isBookUnavailable(book)
                    VStack(spacing: Spacing.none) {
                        Button {
                            if let result = viewModel.handleLocalBookTap(book) {
                                finish(result)
                            }
                        } label: {
                            BookPickerLocalBookRow(
                                book: book,
                                keyword: viewModel.localSnapshotQuery,
                                selectionStyle: viewModel.isMultipleSelectionEnabled ? .multiple : .single,
                                isSelected: viewModel.isBookSelected(book),
                                statusText: isUnavailable ? viewModel.unavailableLocalBookMessage : nil
                            )
                        }
                        .buttonStyle(BookPickerGroupedRowButtonStyle())
                        .disabled(isUnavailable || viewModel.isResolvingRemoteSelections)
                        .accessibilityHint(isUnavailable ? (viewModel.unavailableLocalBookMessage ?? "当前不可选择") : "双击切换书籍选择状态")
                        .accessibilityIdentifier("book.picker.local.\(book.id)")

                        if index < viewModel.localBooks.count - 1 {
                            BookPickerGroupedDivider(
                                leadingInset: BookPickerGroupedSurfaceLayout.compactBookTextInset
                            )
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(resultsTransitionAnimation, value: viewModel.localBooks.map(\.id))
        }
    }

    /// 为结果结构变化提供短促且可中断的过渡；开启“减少动态效果”时直接落位。
    private var resultsTransitionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .smooth(duration: StatePresentationMetrics.phaseTransitionDuration)
    }

    private func syncLocalLoadingGate(_ viewModel: BookPickerViewModel) {
        localLoadingGate.update(intent: viewModel.status == .localLoading ? .read : .none)
    }

    private func localEmptyLibrarySection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMCompactStateView(
                role: .empty,
                title: "还没有书籍",
                message: "先创建一本书，后续书摘才能关联到阅读对象",
                systemImage: "books.vertical",
                style: .card
            )
            stateActionGroup(
                primaryTitle: viewModel.supportsOnline ? "在线搜索" : nil,
                primaryAction: viewModel.supportsOnline ? { viewModel.switchToOnlineIfSupported() } : nil,
                secondaryTitle: viewModel.supportsCreationFlow ? creationEntryLabel : nil,
                secondaryAction: viewModel.supportsCreationFlow ? { openCreationFlow() } : nil
            )
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    private func localNoResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMCompactStateView(
                role: .noResults,
                title: "没有找到匹配的书",
                message: localNoResultsMessage,
                systemImage: "magnifyingglass",
                style: .card
            )
            stateActionGroup(
                primaryTitle: viewModel.supportsOnline ? "在线搜索" : nil,
                primaryAction: viewModel.supportsOnline ? { viewModel.switchToOnlineIfSupported() } : nil,
                secondaryTitle: viewModel.supportsCreationFlow ? creationEntryLabel : nil,
                secondaryAction: viewModel.supportsCreationFlow ? { openCreationFlow() } : nil
            )
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    private func onlineIdleSection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMCompactStateView(
                role: .instruction,
                title: "输入关键词开始搜索",
                message: "输入书名、作者或 ISBN 后，将在当前在线来源中搜索",
                systemImage: "text.magnifyingglass",
                style: .card
            )
            if viewModel.supportsCreationFlow {
                secondaryActionButton(creationEntryLabel) {
                    openCreationFlow()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    private func onlineLoadingSection(_ viewModel: BookPickerViewModel) -> some View {
        BookPickerGroupedSurface {
            LazyVStack(alignment: .leading, spacing: Spacing.none) {
                ForEach(0..<3, id: \.self) { index in
                    BookSearchResultSkeletonRow(
                        source: configuration.onlineSources.indices.contains(index)
                            ? configuration.onlineSources[index]
                            : viewModel.selectedOnlineSource,
                        presentation: .grouped
                    )

                    if index < 2 {
                        BookPickerGroupedDivider(
                            leadingInset: BookPickerGroupedSurfaceLayout.onlineBookTextInset
                        )
                    }
                }
            }
        }
    }

    private func onlineResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        BookPickerGroupedSurface {
            LazyVStack(alignment: .leading, spacing: Spacing.none) {
                ForEach(viewModel.remoteResults.enumerated(), id: \.element.id) { index, result in
                    BookSearchResultRow(
                        result: result,
                        keyword: viewModel.trimmedQuery,
                        accessory: remoteRowAccessory(for: result, viewModel: viewModel),
                        presentation: .grouped,
                        accessibilityHint: remoteAccessibilityHint(for: viewModel)
                    ) {
                        Task {
                            await handleRemoteResultTap(result, viewModel: viewModel)
                        }
                    }
                    .disabled(viewModel.isResolvingRemoteSelections)

                    if index < viewModel.remoteResults.count - 1 {
                        BookPickerGroupedDivider(
                            leadingInset: BookPickerGroupedSurfaceLayout.onlineBookTextInset
                        )
                    }
                }
            }
        }
    }

    private func onlineFailureSection(_ viewModel: BookPickerViewModel, message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMCompactStateView(
                role: .failure,
                title: "当前来源搜索失败",
                message: message,
                systemImage: "wifi.exclamationmark",
                action: XMStateAction("重试", systemImage: "arrow.clockwise") {
                    Task {
                        await viewModel.submitOnlineSearch()
                    }
                },
                style: .card
            )
            if viewModel.supportsCreationFlow {
                secondaryActionButton(creationEntryLabel) {
                    openCreationFlow()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    private func onlineNoResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMCompactStateView(
                role: .noResults,
                title: "没有找到匹配的书",
                message: onlineNoResultsMessage,
                systemImage: "magnifyingglass",
                style: .card
            )
            if viewModel.supportsCreationFlow {
                secondaryActionButton(creationEntryLabel) {
                    openCreationFlow()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    private func multipleSelectionBar(_ viewModel: BookPickerViewModel) -> some View {
        XMPrimaryActionButton(multipleConfirmationTitle(for: viewModel)) {
            confirmationTask?.cancel()
            confirmationTask = Task {
                guard let result = await viewModel.confirmMultipleSelection() else { return }
                guard !Task.isCancelled else { return }
                finish(result)
            }
        }
        .disabled(!canConfirmMultipleSelection(viewModel))
        .accessibilityIdentifier("book.picker.confirm")
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.base)
    }

    @ViewBuilder
    private func stateActionGroup(
        primaryTitle: String?,
        primaryAction: (() -> Void)?,
        secondaryTitle: String?,
        secondaryAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if let primaryTitle, let primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.plain)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.appTint)
            }
            if let secondaryTitle, let secondaryAction {
                secondaryActionButton(secondaryTitle, action: secondaryAction)
            }
        }
    }

    private func secondaryActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(AppTypography.subheadlineSemibold)
            .foregroundStyle(Color.textPrimary)
    }

    private var creationEntryLabel: String {
        switch configuration.creationAction {
        case .inlineManualEditor:
            return "手动创建书籍"
        case .separateSearchPage, .nestedSearchPage:
            return "添加新书"
        }
    }

    private func canConfirmMultipleSelection(_ viewModel: BookPickerViewModel) -> Bool {
        !viewModel.isResolvingRemoteSelections
            && (viewModel.selectedCount > 0 || viewModel.allowsEmptyMultipleConfirmation)
    }

    private func multipleConfirmationTitle(for viewModel: BookPickerViewModel) -> String {
        viewModel.isResolvingRemoteSelections ? "正在整理…" : configuration.multipleConfirmationTitle
    }

    private var localNoResultsMessage: String {
        switch configuration.creationAction {
        case .inlineManualEditor:
            return "你可以继续修改关键词，或直接手动创建"
        case .separateSearchPage:
            return "你可以继续修改关键词，或直接去新增一本书"
        case .nestedSearchPage:
            return "你可以继续修改关键词，或进入添加书籍页"
        }
    }

    private var onlineNoResultsMessage: String {
        switch configuration.creationAction {
        case .inlineManualEditor:
            return "可以切换搜索源继续查找，或直接手动创建"
        case .separateSearchPage:
            return "可以切换搜索源继续查找，或前往新增书籍页"
        case .nestedSearchPage:
            return "可以切换搜索源继续查找，或进入添加书籍页"
        }
    }

    private func blockingOverlayMessage(for viewModel: BookPickerViewModel) -> String? {
        if viewModel.isResolvingRemoteSelections {
            return "正在整理选中书籍…"
        }
        if isPreparingSeed {
            return "正在补全书籍信息…"
        }
        return nil
    }

    private func remoteRowAccessory(
        for result: BookSearchResult,
        viewModel: BookPickerViewModel
    ) -> BookSearchResultRowAccessory {
        guard viewModel.isMultipleSelectionEnabled, viewModel.supportsDirectRemoteSelection else {
            return .none
        }
        return .multiple(isSelected: viewModel.isRemoteResultSelected(result))
    }

    private func remoteAccessibilityHint(for viewModel: BookPickerViewModel) -> String {
        if viewModel.supportsDirectRemoteSelection {
            return viewModel.isMultipleSelectionEnabled
                ? "双击切换书籍选择状态"
                : "双击补全书籍信息并直接返回结果"
        }
        return "双击补全书籍信息并进入编辑页"
    }

    private func prepareViewModelIfNeeded() async {
        guard viewModel == nil else { return }
        let newViewModel = BookPickerViewModel(
            configuration: configuration,
            bookRepository: bookRepository,
            searchRepository: searchRepository
        )
        viewModel = newViewModel
        pendingScrollBookID = configuration.preselectedBooks.first?.id
        await newViewModel.loadIfNeeded()
    }

    private func openCreationFlow() {
        finish(.addFlowRequested)
    }

    private func handleRemoteResultTap(
        _ result: BookSearchResult,
        viewModel: BookPickerViewModel
    ) async {
        if viewModel.supportsDirectRemoteSelection, viewModel.isMultipleSelectionEnabled {
            _ = await viewModel.handleRemoteResultTap(result)
            return
        }

        isPreparingSeed = true
        let outcome = await viewModel.handleRemoteResultTap(result)
        isPreparingSeed = false

        switch outcome {
        case .presentEditor(let seed):
            finish(.editorRequested(seed))
        case .complete(let result):
            finish(result)
        case nil:
            break
        }
    }

    private func scrollToPendingBookIfNeeded(
        using proxy: ScrollViewProxy,
        viewModel: BookPickerViewModel
    ) {
        guard viewModel.visibleScope == .local else { return }
        guard let pendingScrollBookID else { return }
        guard viewModel.localBooks.contains(where: { $0.id == pendingScrollBookID }) else { return }
        proxy.scrollTo(pendingScrollBookID, anchor: .center)
        self.pendingScrollBookID = nil
    }

    private func handleCancel() {
        guard !didComplete else { return }
        didComplete = true
        confirmationTask?.cancel()
        confirmationTask = nil
        onComplete(.cancelled)
        dismiss()
    }

    private func finish(_ result: BookPickerResult) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(result)
        dismiss()
    }
}

/// 多选标题副文案只扩展命中形状，不改变普通副标题的字体、颜色、间距或可见尺寸。
private struct BookPickerSelectionSubtitle: View {
    let count: Int
    let allowsEmptySelection: Bool
    let onOpenSelection: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedCount: Int
    @State private var countsDown = false

    init(
        count: Int,
        allowsEmptySelection: Bool,
        onOpenSelection: @escaping () -> Void
    ) {
        self.count = count
        self.allowsEmptySelection = allowsEmptySelection
        self.onOpenSelection = onOpenSelection
        _displayedCount = State(initialValue: count)
    }

    var body: some View {
        ZStack {
            if displayedCount > 0 {
                Button(action: onOpenSelection) {
                    Text("已选择 \(displayedCount) 本")
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .contentTransition(.numericText(countsDown: countsDown))
                }
                .buttonStyle(.plain)
                .contentShape(BookPickerSubtitleHitShape())
                .accessibilityLabel("已选择 \(displayedCount) 本书")
                .accessibilityHint("查看并管理已选书籍")
                .transition(.opacity)
            } else {
                Text(allowsEmptySelection ? "全部书籍" : "请选择书籍")
                    .font(AppTypography.caption2)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .onChange(of: count) { oldValue, newValue in
            updateDisplayedCount(newValue, countsDown: newValue < oldValue)
        }
    }

    /// 数字局部过渡保持可中断；Reduce Motion 下用无动画事务立即落位。
    private func updateDisplayedCount(_ newValue: Int, countsDown: Bool) {
        guard displayedCount != newValue else { return }
        self.countsDown = countsDown

        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedCount = newValue
            }
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                displayedCount = newValue
            }
        }
    }
}

/// 把副标题命中区域扩展到至少 44pt，路径扩展不参与布局计算也不产生可见样式。
private struct BookPickerSubtitleHitShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = max(rect.width, InteractionMetrics.minimumTouchTarget)
        let height = max(rect.height, InteractionMetrics.minimumTouchTarget)
        return Path(
            CGRect(
                x: rect.midX - width / 2,
                y: rect.midY - height / 2,
                width: width,
                height: height
            )
        )
    }
}

private struct BookPickerLocalBookRow: View {
    enum SelectionStyle {
        case single
        case multiple
    }

    let book: BookPickerBook
    let keyword: String
    let selectionStyle: SelectionStyle
    let isSelected: Bool
    let statusText: String?

    var body: some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                44,
                urlString: book.coverURL,
                cornerRadius: CornerRadius.inlayHairline,
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                XMKeywordHighlighting.text(
                    book.title,
                    keyword: keyword,
                    baseFont: AppTypography.subheadlineSemibold,
                    highlightFont: BookPickerTypography.resultTitleHighlight,
                    baseColor: Color.textPrimary
                )
                .lineLimit(1)

                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    if !book.author.isEmpty {
                        XMKeywordHighlighting.text(
                            book.author,
                            keyword: keyword,
                            baseFont: AppTypography.caption,
                            highlightFont: AppTypography.captionSemibold,
                            baseColor: Color.textSecondary
                        )
                        .lineLimit(1)
                    }

                    if !book.press.isEmpty {
                        XMKeywordHighlighting.text(
                            book.press,
                            keyword: keyword,
                            baseFont: AppTypography.caption,
                            highlightFont: AppTypography.captionSemibold,
                            baseColor: Color.textSecondary
                        )
                        .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: Spacing.none)

            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            } else if showsIndicator {
                XMSelectionIndicator(
                    style: indicatorStyle,
                    isSelected: isSelected,
                    font: AppTypography.body,
                    showsUnselectedBase: selectionStyle == .multiple
                )
            }
        }
        .padding(Spacing.contentEdge)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var indicatorStyle: XMSelectionIndicatorStyle {
        switch selectionStyle {
        case .single:
            return .radio
        case .multiple:
            return .checkbox
        }
    }

    private var showsIndicator: Bool {
        switch selectionStyle {
        case .single:
            return isSelected
        case .multiple:
            return true
        }
    }
}

/// BookPicker 连续分组表面的局部布局常量，分隔线从正文起点开始而不穿过封面。
enum BookPickerGroupedSurfaceLayout {
    static let compactBookTextInset = Spacing.contentEdge + 44 + Spacing.base
    static let onlineBookTextInset = Spacing.contentEdge + BookSearchResultRow.coverWidth + Spacing.base
    static let unavailableMinimumHeight: CGFloat = 260
}

/// 书籍选择 Sheet 的单一内容分组表面；只提供普通 surface、16pt 圆角和裁切。
struct BookPickerGroupedSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceCard)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: CornerRadius.containerMedium,
                    style: .continuous
                )
            )
    }
}

/// 分组书籍行之间的弱分隔线，支持按本地或在线封面宽度对齐正文。
struct BookPickerGroupedDivider: View {
    let leadingInset: CGFloat

    var body: some View {
        XMSettingsDivider()
            .padding(.leading, leadingInset)
            .padding(.trailing, Spacing.contentEdge)
    }
}

/// 分组行按压态只改变中性底色，不缩放、不增加轮廓或额外容器。
struct BookPickerGroupedRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.controlFillSecondary.opacity(
                    isEnabled && configuration.isPressed ? 1 : 0
                )
            )
    }
}
