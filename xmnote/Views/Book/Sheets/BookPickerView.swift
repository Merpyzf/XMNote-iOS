/**
 * [INPUT]: 依赖 RepositoryContainer 或 Debug 仓储替身提供本地书与在线搜索，依赖 BookPickerViewModel 维护共享选择草稿
 * [OUTPUT]: 对外提供 BookPickerView，使用统一 Sheet 骨架、原生系统搜索与单一分组表面承载选择流
 * [POS]: Book 模块业务 Sheet，负责统一书籍选择流，不承担具体业务页保存逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 允许测试中心替换数据源，同时保持生产入口继续从 App 环境读取仓储。
private struct BookPickerRepositoryOverride {
    let bookRepository: any BookPickerRepositoryProtocol
    let searchRepository: any BookSearchRepositoryProtocol
}

/// 通用书籍选择流入口，生产路径从 App 环境解析仓储，测试中心可显式注入固定数据源。
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
                XMSettingsPageScaffold(
                    title: configuration.title,
                    onClose: handleCancel
                ) {
                    LoadingStateView("正在准备书籍选择…", style: .card)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Spacing.section)
                }
            }

            if let blockingOverlayMessage {
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
            XMSettingsPageScaffold(
                title: configuration.title,
                onClose: handleCancel,
                scrollEdgePresentation: .overlaySoft,
                subtitle: {
                    BookPickerSelectionSubtitle(
                        count: viewModel.selectedCount,
                        allowsEmptySelection: viewModel.allowsEmptyMultipleConfirmation,
                        onOpenSelection: { activeSheet = .selectedBooks }
                    )
                },
                contentTopBar: {
                    searchBar(viewModel)
                },
                bottomBar: {
                    multipleSelectionBar(viewModel)
                }
            ) {
                scrollableContent(viewModel)
            }
        } else {
            XMSettingsPageScaffold(
                title: configuration.title,
                onClose: handleCancel,
                scrollEdgePresentation: .overlaySoft,
                contentTopBar: {
                    searchBar(viewModel)
                }
            ) {
                scrollableContent(viewModel)
            }
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
                                        AppTypography.semantic(
                                            .footnote,
                                            weight: viewModel.selectedOnlineSource == source ? .semibold : .medium
                                        )
                                    )
                                    .foregroundStyle(viewModel.selectedOnlineSource == source ? .white : Color.textSecondary)
                                    .padding(.horizontal, Spacing.base)
                                    .frame(height: 34)
                                    .background(
                                        viewModel.selectedOnlineSource == source
                                            ? AnyShapeStyle(Color.brand)
                                            : AnyShapeStyle(Color.controlFillSecondary),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(
                                                viewModel.selectedOnlineSource == source ? Color.clear : Color.surfaceBorderSubtle,
                                                lineWidth: CardStyle.borderWidth
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
            onlineIdleSection
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
                    Button {
                        if let result = viewModel.handleLocalBookTap(book) {
                            finish(result)
                        }
                    } label: {
                        BookPickerLocalBookRow(
                            book: book,
                            keyword: viewModel.trimmedQuery,
                            selectionStyle: viewModel.isMultipleSelectionEnabled ? .multiple : .single,
                            isSelected: viewModel.isBookSelected(book),
                            statusText: isUnavailable ? viewModel.unavailableLocalBookMessage : nil
                        )
                    }
                    .buttonStyle(BookPickerGroupedRowButtonStyle())
                    .disabled(isUnavailable || viewModel.isResolvingRemoteSelections)
                    .accessibilityHint(isUnavailable ? (viewModel.unavailableLocalBookMessage ?? "当前不可选择") : "双击切换书籍选择状态")
                    .accessibilityIdentifier("book.picker.local.\(book.id)")
                    .id(book.id)

                    if index < viewModel.localBooks.count - 1 {
                        BookPickerGroupedDivider(
                            leadingInset: BookPickerGroupedSurfaceLayout.compactBookTextInset
                        )
                    }
                }
            }
        }
    }

    private func syncLocalLoadingGate(_ viewModel: BookPickerViewModel) {
        localLoadingGate.update(intent: viewModel.status == .localLoading ? .read : .none)
    }

    private func localEmptyLibrarySection(_ viewModel: BookPickerViewModel) -> some View {
        ContentUnavailableView {
            Label("还没有书籍", systemImage: "books.vertical")
        } description: {
            Text("添加一本书，之后就可以在这里选择。")
        } actions: {
            if viewModel.supportsCreationFlow {
                unavailableActionButton("添加第一本书", prominence: .primary, action: openCreationFlow)
            }
            if viewModel.supportsOnline {
                unavailableActionButton(
                    "在线搜索",
                    prominence: viewModel.supportsCreationFlow ? .secondary : .primary,
                    action: viewModel.switchToOnlineIfSupported
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    private func localNoResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        ContentUnavailableView {
            Label("没有找到“\(viewModel.trimmedQuery)”", systemImage: "magnifyingglass")
        } description: {
            Text("可以调整关键词，或换一种方式继续查找。")
        } actions: {
            if viewModel.supportsOnline {
                unavailableActionButton(
                    "在线搜索",
                    prominence: .primary,
                    action: viewModel.switchToOnlineIfSupported
                )
            }
            if viewModel.supportsCreationFlow {
                unavailableActionButton(
                    "添加新书",
                    prominence: viewModel.supportsOnline ? .secondary : .primary,
                    action: openCreationFlow
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    private var onlineIdleSection: some View {
        ContentUnavailableView(
            "输入关键词开始搜索",
            systemImage: "text.magnifyingglass",
            description: Text("输入书名、作者或 ISBN，在当前在线来源中查找。")
        )
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
        BookSearchStatusCard(
            systemImage: "wifi.exclamationmark",
            tint: .feedbackWarning,
            title: "当前来源搜索失败",
            message: message,
            actionTitle: "重试",
            action: {
                Task {
                    await viewModel.submitOnlineSearch()
                }
            }
        )
    }

    private func onlineNoResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        ContentUnavailableView {
            Label("没有找到“\(viewModel.trimmedQuery)”", systemImage: "magnifyingglass")
        } description: {
            Text("可以切换搜索来源，或调整关键词后重试。")
        } actions: {
            if viewModel.supportsCreationFlow {
                unavailableActionButton("添加新书", prominence: .primary, action: openCreationFlow)
            }
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    @ViewBuilder
    private func unavailableActionButton(
        _ title: String,
        prominence: BookPickerUnavailableActionProminence,
        action: @escaping () -> Void
    ) -> some View {
        switch prominence {
        case .primary:
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .tint(Color.brand)
        case .secondary:
            Button(title, action: action)
                .buttonStyle(.bordered)
        }
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

    private var blockingOverlayMessage: String? {
        isPreparingSeed ? "正在补全书籍信息…" : nil
    }

    private func canConfirmMultipleSelection(_ viewModel: BookPickerViewModel) -> Bool {
        !viewModel.isResolvingRemoteSelections
            && (viewModel.selectedCount > 0 || viewModel.allowsEmptyMultipleConfirmation)
    }

    private func multipleConfirmationTitle(for viewModel: BookPickerViewModel) -> String {
        viewModel.isResolvingRemoteSelections ? "正在整理…" : configuration.multipleConfirmationTitle
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
        let width = max(rect.width, Spacing.actionReserved)
        let height = max(rect.height, Spacing.actionReserved)
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
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                XMKeywordHighlighting.text(
                    book.title,
                    keyword: keyword,
                    baseFont: AppTypography.subheadlineSemibold,
                    highlightFont: AppTypography.semantic(.subheadline, weight: .bold),
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

/// 空态操作的视觉优先级，仅用于系统 ContentUnavailableView 的恢复动作排序。
private enum BookPickerUnavailableActionProminence {
    case primary
    case secondary
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
