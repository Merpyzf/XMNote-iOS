/**
 * [INPUT]: 依赖 RepositoryContainer 或 Debug 仓储替身提供本地书与在线搜索，Debug 可附带固定远端预选；依赖 BookPickerViewModel 维护共享选择草稿，并复用 XMScrollEdgeChrome 协调固定控件与滚动内容
 * [OUTPUT]: 对外提供生产与测试中心共用的 iOS 26 系统样式 BookPickerView，空态遵守创建能力，支持确定性异步确认验证及品牌操作前景随外观配对
 * [POS]: Book 模块业务 Sheet，负责统一书籍选择流，不承担具体业务页保存逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 允许测试中心替换数据源，同时保持生产入口继续从 App 环境读取仓储。
private struct BookPickerRepositoryOverride {
    let bookRepository: any BookPickerRepositoryProtocol
    let searchRepository: any BookSearchRepositoryProtocol
    let preselectedRemoteResults: [BookSearchResult]
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
        preselectedRemoteResults: [BookSearchResult] = [],
        onComplete: @escaping (BookPickerResult) -> Void
    ) {
        self.configuration = configuration
        self.onComplete = onComplete
        self.repositoryOverride = BookPickerRepositoryOverride(
            bookRepository: bookRepository,
            searchRepository: searchRepository,
            preselectedRemoteResults: preselectedRemoteResults
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
                searchRepository: repositoryOverride.searchRepository,
                initialRemoteSelections: repositoryOverride.preselectedRemoteResults
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
            searchRepository: repositories.bookSearchRepository,
            initialRemoteSelections: []
        )
    }
}

/// 持有一次选择会话的共享草稿，并把同一份状态提供给外层与已选管理 Sheet。
private struct BookPickerResolvedView: View {
    let configuration: BookPickerConfiguration
    let onComplete: (BookPickerResult) -> Void
    let bookRepository: any BookPickerRepositoryProtocol
    let searchRepository: any BookSearchRepositoryProtocol
    let initialRemoteSelections: [BookSearchResult]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var viewModel: BookPickerViewModel?
    @State private var isSearchActive = false
    @State private var isPreparingSeed = false
    @State private var didComplete = false
    @State private var pendingScrollBookID: Int64?
    @State private var appleNavigationPath: [AppleRoute] = []
    @State private var localLoadingGate = LoadingGate()
    @State private var confirmationTask: Task<Void, Never>?

    private enum AppleRoute: Hashable {
        case selectedBooks
    }

    var body: some View {
        ZStack {
            if let viewModel {
                appleRecommendedPickerScaffold(viewModel)
            } else {
                loadingPresentation
            }

            if let viewModel, let blockingOverlayMessage = blockingOverlayMessage(for: viewModel) {
                Color.overlay.ignoresSafeArea()
                LoadingStateView(blockingOverlayMessage, style: .card)
            }
        }
        .task {
            await prepareViewModelIfNeeded()
        }
        .interactiveDismissDisabled(isAppleRecommendedConfirmationRunning)
        .onDisappear {
            localLoadingGate.hideImmediately()
            confirmationTask?.cancel()
            confirmationTask = nil
        }
    }

    private var loadingPresentation: some View {
        NavigationStack {
            loadingContent
                .background(Color.surfaceSheet.ignoresSafeArea())
                .navigationTitle(configuration.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        appleRecommendedCloseButton(isDisabled: false)
                    }
                }
        }
    }

    private var loadingContent: some View {
        LoadingStateView("正在准备书籍选择…", style: .card)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.section)
    }

    private func appleRecommendedPickerScaffold(_ viewModel: BookPickerViewModel) -> some View {
        NavigationStack(path: $appleNavigationPath) {
            XMScrollEdgeChrome(
                presentation: .overlaySoft,
                edges: [.top, .bottom],
                topBar: {
                    appleRecommendedContentTopBar(viewModel)
                },
                bottomBar: {
                    appleRecommendedBottomEdgeBar
                }
            ) {
                appleRecommendedResultsList(viewModel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surfaceSheet.ignoresSafeArea())
            .allowsHitTesting(!viewModel.isResolvingRemoteSelections)
            .navigationTitle(configuration.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                appleRecommendedToolbar(viewModel)
            }
            .navigationDestination(for: AppleRoute.self) { route in
                switch route {
                case .selectedBooks:
                    BookPickerSelectedBooksScreen(viewModel: viewModel)
                }
            }
        }
    }

    @ViewBuilder
    private func appleRecommendedContentTopBar(_ viewModel: BookPickerViewModel) -> some View {
        VStack(spacing: Spacing.none) {
            appleRecommendedSearchBar(viewModel)

            if appleRecommendedShowsSupportBar(viewModel) {
                appleRecommendedSupportBar(viewModel)
            }
        }
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.half)
    }

    private var appleRecommendedBottomEdgeBar: some View {
        Color.surfaceSheet
            .frame(height: Spacing.half)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ToolbarContentBuilder
    private func appleRecommendedToolbar(_ viewModel: BookPickerViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            appleRecommendedCloseButton(isDisabled: viewModel.isResolvingRemoteSelections)
        }

        if viewModel.isMultipleSelectionEnabled {
            ToolbarItem(placement: .confirmationAction) {
                appleRecommendedConfirmationButton(viewModel)
            }
        }
    }

    private func appleRecommendedCloseButton(isDisabled: Bool) -> some View {
        Button("关闭", systemImage: "xmark", action: handleCancel)
            .labelStyle(.iconOnly)
            .tint(Color.textSecondary)
            .disabled(isDisabled)
            .accessibilityIdentifier("book.picker.cancel")
    }

    private func appleRecommendedConfirmationButton(_ viewModel: BookPickerViewModel) -> some View {
        Button {
            confirmMultipleSelection(viewModel)
        } label: {
            Image(systemName: "checkmark")
                .opacity(viewModel.isResolvingRemoteSelections ? 0 : 1)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.primaryActionForeground)
                        .opacity(viewModel.isResolvingRemoteSelections ? 1 : 0)
                }
        }
        .foregroundStyle(Color.primaryActionForeground)
        .buttonStyle(.borderedProminent)
        .tint(Color.appTint)
        .disabled(!canConfirmMultipleSelection(viewModel))
        .accessibilityLabel(
            viewModel.isResolvingRemoteSelections
                ? "正在确认"
                : "确认"
        )
        .accessibilityValue("已选择 \(viewModel.selectedCount) 本书")
        .accessibilityIdentifier("book.picker.confirm")
    }

    private var isAppleRecommendedConfirmationRunning: Bool {
        viewModel?.isResolvingRemoteSelections == true
    }

    private func appleRecommendedSearchBar(_ viewModel: BookPickerViewModel) -> some View {
        XMSystemSearchBar(
            text: Binding(
                get: { viewModel.query },
                set: { viewModel.updateQuery($0) }
            ),
            isActive: $isSearchActive,
            prompt: "搜索书名、作者、ISBN",
            accessibilityIdentifier: "book.picker.search",
            isEnabled: !viewModel.isResolvingRemoteSelections,
            onSubmit: {
                guard viewModel.visibleScope == .online else { return }
                Task {
                    await viewModel.submitOnlineSearch()
                }
            }
        )
        .padding(.horizontal, Spacing.cozy)
    }

    private func appleRecommendedShowsSupportBar(_ viewModel: BookPickerViewModel) -> Bool {
        viewModel.isMultipleSelectionEnabled || appleRecommendedShowsSourceMenu(viewModel)
    }

    @ViewBuilder
    private func appleRecommendedSupportBar(_ viewModel: BookPickerViewModel) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    appleRecommendedSourceMenu(viewModel)

                    if viewModel.isMultipleSelectionEnabled {
                        appleRecommendedSelectionSummary(viewModel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.base)
            } else {
                HStack(spacing: Spacing.base) {
                    appleRecommendedSourceMenu(viewModel)

                    Spacer(minLength: Spacing.none)

                    if viewModel.isMultipleSelectionEnabled {
                        appleRecommendedSelectionSummary(viewModel)
                    }
                }
            }
        }
        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        .padding(.horizontal, Spacing.screenEdge)
        .disabled(viewModel.isResolvingRemoteSelections)
    }

    private func appleRecommendedShowsSourceMenu(_ viewModel: BookPickerViewModel) -> Bool {
        switch configuration.scope {
        case .local:
            return false
        case .both:
            return viewModel.supportsScopeSwitch
        case .online:
            return viewModel.supportsOnline && configuration.onlineSources.count > 1
        }
    }

    @ViewBuilder
    private func appleRecommendedSourceMenu(_ viewModel: BookPickerViewModel) -> some View {
        if appleRecommendedShowsSourceMenu(viewModel) {
            BookPickerAppleSourceMenu(
                scope: configuration.scope,
                visibleScope: viewModel.visibleScope,
                selectedOnlineSource: viewModel.selectedOnlineSource,
                onlineSources: configuration.onlineSources,
                onSelectLocal: {
                    viewModel.switchVisibleScope(.local)
                },
                onSelectOnlineSource: { source in
                    selectAppleRecommendedOnlineSource(source, viewModel: viewModel)
                }
            )
        }
    }

    private func selectAppleRecommendedOnlineSource(
        _ source: BookSearchSource,
        viewModel: BookPickerViewModel
    ) {
        viewModel.selectOnlineSource(source)
        viewModel.switchVisibleScope(.online)
    }

    @ViewBuilder
    private func appleRecommendedSelectionSummary(_ viewModel: BookPickerViewModel) -> some View {
        if viewModel.selectedCount > 0 {
            Button {
                isSearchActive = false
                appleNavigationPath.append(.selectedBooks)
            } label: {
                HStack(spacing: Spacing.compact) {
                    Text("已选 \(viewModel.selectedCount) 本")
                        .contentTransition(.numericText())

                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.iconSecondary)
                        .accessibilityHidden(true)
                }
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .xmMinimumHitTarget(anchor: .leading)
            .accessibilityLabel("已选 \(viewModel.selectedCount) 本书")
            .accessibilityHint("查看并管理已选书籍")
            .accessibilityIdentifier("book.picker.selection-summary")
        } else {
            Text(viewModel.allowsEmptyMultipleConfirmation ? "全部书籍" : "已选 0 本")
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textSecondary)
                .accessibilityIdentifier("book.picker.selection-summary")
        }
    }

    private func appleRecommendedResultsList(_ viewModel: BookPickerViewModel) -> some View {
        ScrollViewReader { proxy in
            List {
                appleRecommendedResultRows(viewModel)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.surfaceSheet)
            .scrollBounceBehavior(.always)
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

    @ViewBuilder
    private func appleRecommendedResultRows(_ viewModel: BookPickerViewModel) -> some View {
        switch viewModel.status {
        case .localLoading:
            if localLoadingGate.isVisible {
                appleRecommendedSkeletonRows()
            } else {
                Color.clear
                    .frame(minHeight: Spacing.section * 2)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.surfaceSheet)
                    .accessibilityHidden(true)
            }
        case .localResults:
            ForEach(viewModel.localBooks) { book in
                let isUnavailable = viewModel.isBookUnavailable(book)
                Button {
                    if let result = viewModel.handleLocalBookTap(book) {
                        finish(result)
                    }
                } label: {
                    BookPickerAppleBookRow(
                        title: book.title,
                        author: book.author,
                        detail: book.press,
                        coverURL: book.coverURL,
                        keyword: viewModel.localSnapshotQuery,
                        isSelected: viewModel.isBookSelected(book),
                        showsSelectionIndicator: viewModel.isMultipleSelectionEnabled,
                        statusText: isUnavailable ? viewModel.unavailableLocalBookMessage : nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(isUnavailable || viewModel.isResolvingRemoteSelections)
                .accessibilityHint(
                    isUnavailable
                        ? (viewModel.unavailableLocalBookMessage ?? "当前不可选择")
                        : localAccessibilityHint(for: viewModel)
                )
                .accessibilityIdentifier("book.picker.local.\(book.id)")
                .id(book.id)
                .modifier(
                    BookPickerAppleListRowModifier(
                        showsSeparator: book.id != viewModel.localBooks.last?.id
                    )
                )
            }
        case .localEmptyLibrary:
            appleRecommendedStateRow(
                role: .empty,
                title: "还没有书籍",
                message: configuration.allowsCreationFlow ? "先创建一本书，后续书摘才能关联到阅读对象" : "书库中暂无可选书籍",
                systemImage: "books.vertical",
                action: localStatePrimaryAction(viewModel),
                secondaryAction: localStateSecondaryAction(viewModel)
            )
        case .localNoResults:
            appleRecommendedStateRow(
                role: .noResults,
                title: "没有找到匹配的书",
                message: localNoResultsMessage,
                systemImage: "magnifyingglass",
                action: localStatePrimaryAction(viewModel),
                secondaryAction: localStateSecondaryAction(viewModel)
            )
        case .onlineIdle:
            appleRecommendedStateRow(
                role: .instruction,
                title: "输入关键词开始搜索",
                message: "输入书名、作者或 ISBN 后，将在当前在线来源中搜索",
                systemImage: "text.magnifyingglass",
                action: creationStateAction(viewModel),
                secondaryAction: nil
            )
        case .onlineLoading:
            appleRecommendedSkeletonRows()
        case .onlineResults:
            ForEach(viewModel.remoteResults) { result in
                Button {
                    Task {
                        await handleRemoteResultTap(result, viewModel: viewModel)
                    }
                } label: {
                    BookPickerAppleBookRow(
                        title: result.title,
                        author: result.author,
                        detail: appleRecommendedRemoteDetail(for: result),
                        coverURL: result.coverURL,
                        keyword: viewModel.trimmedQuery,
                        isSelected: viewModel.isRemoteResultSelected(result),
                        showsSelectionIndicator: viewModel.isMultipleSelectionEnabled && viewModel.supportsDirectRemoteSelection,
                        statusText: nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isResolvingRemoteSelections)
                .accessibilityHint(remoteAccessibilityHint(for: viewModel))
                .modifier(
                    BookPickerAppleListRowModifier(
                        showsSeparator: result.id != viewModel.remoteResults.last?.id
                    )
                )
            }
        case .onlineFailure(let message):
            appleRecommendedStateRow(
                role: .failure,
                title: "当前来源搜索失败",
                message: message,
                systemImage: "wifi.exclamationmark",
                action: XMStateAction("重试") {
                    Task {
                        await viewModel.submitOnlineSearch()
                    }
                },
                secondaryAction: creationStateAction(viewModel)
            )
        case .onlineNoResults:
            appleRecommendedStateRow(
                role: .noResults,
                title: "没有找到匹配的书",
                message: onlineNoResultsMessage,
                systemImage: "magnifyingglass",
                action: creationStateAction(viewModel),
                secondaryAction: nil
            )
        }
    }

    @ViewBuilder
    private func appleRecommendedSkeletonRows() -> some View {
        ForEach(0..<3, id: \.self) { index in
            BookPickerAppleBookSkeletonRow()
                .modifier(BookPickerAppleListRowModifier(showsSeparator: index < 2))
        }
    }

    private func appleRecommendedStateRow(
        role: XMStateRole,
        title: String,
        message: String,
        systemImage: String,
        action: XMStateAction?,
        secondaryAction: XMStateAction?
    ) -> some View {
        VStack(spacing: Spacing.base) {
            XMContentStateView(
                role: role,
                title: title,
                message: message,
                systemImage: systemImage,
                action: action
            )
            .frame(minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)

            if let secondaryAction {
                Button(action: secondaryAction.perform) {
                    XMStateActionLabel(action: secondaryAction)
                        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.textPrimary)
            }
        }
        .listRowInsets(BookPickerAppleListLayout.stateInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.surfaceSheet)
    }

    private func localStatePrimaryAction(_ viewModel: BookPickerViewModel) -> XMStateAction? {
        if viewModel.supportsOnline {
            return XMStateAction("在线搜索") {
                viewModel.switchToOnlineIfSupported()
            }
        }
        return creationStateAction(viewModel)
    }

    private func localStateSecondaryAction(_ viewModel: BookPickerViewModel) -> XMStateAction? {
        guard viewModel.supportsOnline else { return nil }
        return creationStateAction(viewModel)
    }

    private func creationStateAction(_ viewModel: BookPickerViewModel) -> XMStateAction? {
        guard viewModel.supportsCreationFlow else { return nil }
        return XMStateAction(creationEntryLabel) {
            openCreationFlow()
        }
    }

    private func localAccessibilityHint(for viewModel: BookPickerViewModel) -> String {
        viewModel.isMultipleSelectionEnabled
            ? "双击切换书籍选择状态"
            : "双击选择这本书"
    }

    private func appleRecommendedRemoteDetail(for result: BookSearchResult) -> String {
        let structuredDetail = [result.press, result.pubDate, result.source.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        guard structuredDetail.isEmpty else { return structuredDetail }

        let subtitle = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return subtitle.isEmpty ? result.source.title : "\(subtitle) · \(result.source.title)"
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
                                    .foregroundStyle(viewModel.selectedOnlineSource == source ? Color.primaryActionForeground : Color.textSecondary)
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
                title: "还没有可选书籍",
                message: "请先添加书籍",
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
                title: "没有匹配的书籍",
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
                action: XMStateAction("重试") {
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
                title: "没有匹配的书籍",
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

    /// 在 MainActor 上启动一次多选确认；新请求会取消旧任务，Sheet 离场时同步取消，完成前检查取消状态避免过期结果回流。
    private func confirmMultipleSelection(_ viewModel: BookPickerViewModel) {
        confirmationTask?.cancel()
        confirmationTask = Task {
            guard let result = await viewModel.confirmMultipleSelection() else { return }
            guard !Task.isCancelled else { return }
            finish(result)
        }
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

    private var localNoResultsMessage: String {
        guard configuration.allowsCreationFlow else { return "试试其他书名或作者" }
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
        guard configuration.allowsCreationFlow else { return "试试其他关键词或搜索源" }
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
        #if DEBUG
        newViewModel.seedRemoteSelectionsForDebug(initialRemoteSelections)
        #endif
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

/// 多选标题副文案保留标准副标题视觉，仅在存在已选书籍时提供低频管理入口。
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
                // 该文本以副标题信息展示为主，打开已选管理仅为低频、非破坏性辅助操作；按项目例外保留文字自然命中范围，避免标题栏空白响应点击。
                Button(action: onOpenSelection) {
                    Text("已选择 \(displayedCount) 本")
                        .contentTransition(.numericText(countsDown: countsDown))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("已选择 \(displayedCount) 本书")
                .accessibilityHint("查看并管理已选书籍")
                .transition(.opacity)
            } else {
                Text(allowsEmptySelection ? "全部书籍" : "请选择书籍")
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

/// Apple 推荐列表的页面私有几何，统一书籍行缩进和从封面后起始的系统分隔线。
enum BookPickerAppleListLayout {
    static let rowInsets = EdgeInsets(
        top: Spacing.cozy,
        leading: Spacing.screenEdge,
        bottom: Spacing.cozy,
        trailing: Spacing.screenEdge
    )
    static let stateInsets = EdgeInsets(
        top: Spacing.none,
        leading: Spacing.none,
        bottom: Spacing.none,
        trailing: Spacing.none
    )
    static let separatorLeading = BookPickerAppleBookRow.Layout.coverWidth + Spacing.base
}

/// 为 Apple 推荐书籍行统一应用系统 List 的缩进、表层与正文对齐分隔线。
struct BookPickerAppleListRowModifier: ViewModifier {
    let showsSeparator: Bool

    func body(content: Content) -> some View {
        content
            .listRowInsets(BookPickerAppleListLayout.rowInsets)
            .listRowBackground(Color.surfaceSheet)
            .listRowSeparator(showsSeparator ? .visible : .hidden)
            .listRowSeparatorTint(Color.surfaceDividerSubtle)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + BookPickerAppleListLayout.separatorLeading
            }
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
