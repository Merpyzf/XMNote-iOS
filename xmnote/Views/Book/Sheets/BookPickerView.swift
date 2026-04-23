/**
 * [INPUT]: 依赖 RepositoryContainer 注入本地书仓储与在线搜索仓储，依赖 BookPickerViewModel 驱动本地/远端混合选择状态机，依赖 BookEditorView 与 BookSearchView 承接页内创建与搜索回填
 * [OUTPUT]: 对外提供 BookPickerView，承载通用书籍选择流的本地/在线/新增入口、远端直返与多选交互
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
    @State private var activeSeed: BookEditorSeed?
    @State private var showsNestedSearchPage = false
    @State private var isPreparingSeed = false
    @State private var didComplete = false
    @State private var pendingScrollBookID: Int64?

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
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopBarBackButton {
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
            .navigationDestination(item: $activeSeed) { seed in
                BookEditorView(
                    seed: seed,
                    onSavedBookID: { bookId in
                        Task {
                            await handleCreatedBook(bookId)
                        }
                    }
                )
            }
            .navigationDestination(isPresented: $showsNestedSearchPage) {
                BookSearchView(
                    onCompletedBookSelection: { book in
                        finish(.single(.local(book)))
                    },
                    completionDismissBehavior: .handledByParent
                )
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
                scrollToPendingBookIfNeeded(using: proxy, viewModel: viewModel)
            }
            .onChange(of: viewModel.localBooks.map(\.id)) { _, _ in
                scrollToPendingBookIfNeeded(using: proxy, viewModel: viewModel)
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
                            .buttonStyle(SearchChipButtonStyle())
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
            ProgressView("正在读取本地书籍…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Spacing.section)
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
                .id(book.id)
            }
        }
    }

    private func localEmptyLibrarySection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            BookSearchStatusCard(
                systemImage: "books.vertical",
                title: "还没有书籍",
                message: "先创建一本书，后续书摘才能关联到阅读对象。"
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
            BookSearchStatusCard(
                systemImage: "magnifyingglass",
                title: "没有找到匹配的书",
                message: localNoResultsMessage
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
            BookSearchStatusCard(
                systemImage: "text.magnifyingglass",
                title: "输入关键词开始搜索",
                message: "输入书名、作者或 ISBN 后，将在当前在线来源中搜索。"
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
            if viewModel.supportsCreationFlow {
                secondaryActionButton(creationEntryLabel) {
                    openCreationFlow()
                }
            }
        }
    }

    private func onlineNoResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            BookSearchStatusCard(
                systemImage: "magnifyingglass",
                title: "没有找到匹配的书",
                message: onlineNoResultsMessage
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

    private func presentManualCreate() {
        activeSeed = .manual
    }

    private func openCreationFlow() {
        switch configuration.creationAction {
        case .inlineManualEditor:
            presentManualCreate()
        case .separateSearchPage:
            finish(.addFlowRequested)
        case .nestedSearchPage:
            showsNestedSearchPage = true
        }
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
            activeSeed = seed
        case .complete(let result):
            finish(result)
        case nil:
            break
        }
    }

    private func handleCreatedBook(_ bookId: Int64) async {
        guard let viewModel else { return }
        if let result = await viewModel.handleCreatedBook(bookId: bookId) {
            finish(result)
            return
        }
        if viewModel.visibleScope == .local {
            pendingScrollBookID = bookId
            await viewModel.refreshLocalBooks()
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
                highlightedText(
                    book.title,
                    baseFont: AppTypography.subheadlineSemibold,
                    highlightFont: AppTypography.semantic(.subheadline, weight: .bold),
                    baseColor: Color.textPrimary,
                    highlightColor: Color.keywordHighlight
                )
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    if !book.author.isEmpty {
                        highlightedText(
                            book.author,
                            baseFont: AppTypography.caption,
                            highlightFont: AppTypography.captionSemibold,
                            baseColor: Color.textSecondary,
                            highlightColor: Color.keywordHighlight
                        )
                        .lineLimit(1)
                    }

                    if !book.press.isEmpty {
                        highlightedText(
                            book.press,
                            baseFont: AppTypography.caption,
                            highlightFont: AppTypography.captionSemibold,
                            baseColor: Color.textSecondary,
                            highlightColor: Color.keywordHighlight
                        )
                        .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            if let indicatorSystemName {
                Image(systemName: indicatorSystemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.brand : Color.textHint)
            }
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var indicatorSystemName: String? {
        switch selectionStyle {
        case .single:
            return isSelected ? "largecircle.fill.circle" : nil
        case .multiple:
            return isSelected ? "checkmark.circle.fill" : "circle"
        }
    }

    private func highlightedText(
        _ text: String,
        baseFont: Font,
        highlightFont: Font,
        baseColor: Color,
        highlightColor: Color
    ) -> Text {
        Text(
            highlightedAttributedString(
                text,
                baseFont: baseFont,
                highlightFont: highlightFont,
                baseColor: baseColor,
                highlightColor: highlightColor
            )
        )
    }

    private func highlightedAttributedString(
        _ text: String,
        baseFont: Font,
        highlightFont: Font,
        baseColor: Color,
        highlightColor: Color
    ) -> AttributedString {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return AttributedString() }

        guard !trimmedKeyword.isEmpty else {
            return styledSegment(text, font: baseFont, color: baseColor)
        }

        var result = AttributedString()
        var searchStart = text.startIndex
        var didMatch = false

        while searchStart < text.endIndex,
              let range = text.range(
                  of: trimmedKeyword,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<text.endIndex,
                  locale: .current
              ) {
            if searchStart < range.lowerBound {
                result.append(
                    styledSegment(
                        String(text[searchStart..<range.lowerBound]),
                        font: baseFont,
                        color: baseColor
                    )
                )
            }

            result.append(
                styledSegment(
                    String(text[range]),
                    font: highlightFont,
                    color: highlightColor
                )
            )
            didMatch = true
            searchStart = range.upperBound
        }

        if searchStart < text.endIndex {
            result.append(
                styledSegment(
                    String(text[searchStart..<text.endIndex]),
                    font: baseFont,
                    color: baseColor
                )
            )
        }

        if didMatch {
            return result
        }

        return styledSegment(text, font: baseFont, color: baseColor)
    }

    private func styledSegment(_ text: String, font: Font, color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = font
        attributed.foregroundColor = color
        return attributed
    }
}
