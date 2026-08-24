/**
 * [INPUT]: 依赖 RepositoryContainer 注入本地书仓储与在线搜索仓储，依赖 BookPickerViewModel 驱动本地/远端混合选择状态机
 * [OUTPUT]: 对外提供 BookPickerView，承载通用书籍选择流的本地/在线/新增任务请求、远端直返与多选交互
 * [POS]: Book 模块业务 Sheet，负责统一书籍选择流，不承担具体业务页保存逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用书籍选择流入口，统一承接本地选择、在线搜索、新增入口与结果回填。
struct BookPickerView: View {
    let configuration: BookPickerConfiguration
    let onComplete: (BookPickerResult) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: BookPickerViewModel?
    @State private var isPreparingSeed = false
    @State private var didComplete = false
    @State private var pendingScrollBookID: Int64?
    @State private var localLoadingGate = LoadingGate()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.surfacePage.ignoresSafeArea()

                if let viewModel {
                    content(viewModel)
                } else {
                    LoadingStateView("正在准备书籍选择…", style: .card)
                }

                if let viewModel, let blockingOverlayMessage = blockingOverlayMessage(for: viewModel) {
                    Color.overlay.ignoresSafeArea()
                    LoadingStateView(blockingOverlayMessage, style: .card)
                }
            }
            .navigationTitle(configuration.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        handleCancel()
                    }
                }
                if let viewModel, viewModel.supportsCreationFlow {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            openCreationFlow()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(creationEntryLabel)
                    }
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            let newViewModel = BookPickerViewModel(
                configuration: configuration,
                bookRepository: repositories.bookRepository,
                searchRepository: repositories.bookSearchRepository
            )
            viewModel = newViewModel
            pendingScrollBookID = configuration.preselectedBooks.first?.id
            await newViewModel.loadIfNeeded()
        }
    }

    private func content(_ viewModel: BookPickerViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    controlsSection(viewModel)
                    resultsSection(viewModel)
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.section)
            }
            .safeAreaInset(edge: .bottom) {
                if shouldShowMultipleSelectionBar(viewModel) {
                    multipleSelectionBar(viewModel)
                }
            }
            .searchable(
                text: Binding(
                    get: { viewModel.query },
                    set: { viewModel.updateQuery($0) }
                ),
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索书名、作者、ISBN"
            )
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) {
                guard viewModel.visibleScope == .online else { return }
                Task {
                    await viewModel.submitOnlineSearch()
                }
            }
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
            .onDisappear {
                localLoadingGate.hideImmediately()
            }
        }
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
                        }
                    }
                }
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
        LazyVStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(viewModel.localBooks) { book in
                Button {
                    if let result = viewModel.handleLocalBookTap(book) {
                        finish(result)
                    }
                } label: {
                    BookPickerLocalBookRow(
                        book: book,
                        keyword: viewModel.trimmedQuery,
                        selectionStyle: viewModel.isMultipleSelectionEnabled ? .multiple : .single,
                        isSelected: viewModel.isBookSelected(book)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("book.picker.local.\(book.id)")
                .id(book.id)
            }
        }
    }

    private func syncLocalLoadingGate(_ viewModel: BookPickerViewModel) {
        localLoadingGate.update(intent: viewModel.status == .localLoading ? .read : .none)
    }

    private func localEmptyLibrarySection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMCompactStateView(
                role: .empty,
                title: "还没有书籍",
                message: "先创建一本书，后续书摘才能关联到阅读对象。",
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
    }

    private func onlineIdleSection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMCompactStateView(
                role: .instruction,
                title: "输入关键词开始搜索",
                message: "输入书名、作者或 ISBN 后，将在当前在线来源中搜索。",
                systemImage: "text.magnifyingglass",
                style: .card
            )
            if viewModel.supportsCreationFlow {
                secondaryActionButton(creationEntryLabel) {
                    openCreationFlow()
                }
            }
        }
    }

    private func onlineLoadingSection(_ viewModel: BookPickerViewModel) -> some View {
        LazyVStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(0..<3, id: \.self) { index in
                BookSearchResultSkeletonRow(
                    source: configuration.onlineSources.indices.contains(index)
                        ? configuration.onlineSources[index]
                        : viewModel.selectedOnlineSource
                )
            }
        }
    }

    private func onlineResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        LazyVStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(viewModel.remoteResults) { result in
                BookSearchResultRow(
                    result: result,
                    keyword: viewModel.trimmedQuery,
                    accessory: remoteRowAccessory(for: result, viewModel: viewModel),
                    accessibilityHint: remoteAccessibilityHint(for: viewModel)
                ) {
                    Task {
                        await handleRemoteResultTap(result, viewModel: viewModel)
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
    }

    private func multipleSelectionBar(_ viewModel: BookPickerViewModel) -> some View {
        VStack(spacing: Spacing.cozy) {
            Divider()
            Button {
                Task {
                    if let result = await viewModel.confirmMultipleSelection() {
                        finish(result)
                    }
                }
            } label: {
                HStack {
                    Text(configuration.multipleConfirmationTitle)
                    Spacer()
                    Text(multipleSelectionCountLabel(for: viewModel))
                }
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.vertical, Spacing.base)
                .background(Color.brand, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isResolvingRemoteSelections)
            .accessibilityIdentifier("book.picker.confirm")
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.cozy)
            .padding(.top, Spacing.half)
            .background(Color.surfacePage)
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
                    .foregroundStyle(Color.brand)
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
        case .separateSearchPage:
            return "添加新书"
        case .nestedSearchPage:
            return "添加新书"
        }
    }

    private var localNoResultsMessage: String {
        switch configuration.creationAction {
        case .inlineManualEditor:
            return "你可以继续修改关键词，或直接手动创建。"
        case .separateSearchPage:
            return "你可以继续修改关键词，或直接去新增一本书。"
        case .nestedSearchPage:
            return "你可以继续修改关键词，或进入添加书籍页。"
        }
    }

    private var onlineNoResultsMessage: String {
        switch configuration.creationAction {
        case .inlineManualEditor:
            return "可以切换搜索源继续查找，或直接手动创建。"
        case .separateSearchPage:
            return "可以切换搜索源继续查找，或前往新增书籍页。"
        case .nestedSearchPage:
            return "可以切换搜索源继续查找，或进入添加书籍页。"
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

    private func shouldShowMultipleSelectionBar(_ viewModel: BookPickerViewModel) -> Bool {
        guard viewModel.isMultipleSelectionEnabled else { return false }
        return viewModel.selectedCount > 0 || viewModel.allowsEmptyMultipleConfirmation
    }

    private func multipleSelectionCountLabel(for viewModel: BookPickerViewModel) -> String {
        if viewModel.selectedCount == 0, viewModel.allowsEmptyMultipleConfirmation {
            return "未限制"
        }
        return "\(viewModel.selectedCount)"
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

private struct BookPickerLocalBookRow: View {
    enum SelectionStyle {
        case single
        case multiple
    }

    let book: BookPickerBook
    let keyword: String
    let selectionStyle: SelectionStyle
    let isSelected: Bool

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

            Spacer(minLength: 0)

            if showsIndicator {
                XMSelectionIndicator(
                    style: indicatorStyle,
                    isSelected: isSelected,
                    font: AppTypography.body,
                    showsUnselectedBase: selectionStyle == .multiple
                )
            }
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
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
