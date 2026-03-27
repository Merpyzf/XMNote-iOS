/**
 * [INPUT]: 依赖 RepositoryContainer 注入本地书仓储与在线搜索仓储，依赖 BookPickerViewModel 驱动选择状态机，依赖 BookEditorView 承接创建与回填
 * [OUTPUT]: 对外提供 BookPickerView，承载通用书籍选择流的本地/在线/创建/多选交互
 * [POS]: Book 模块业务 Sheet，负责统一书籍选择流，不承担具体业务页保存逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用书籍选择流入口，统一承接本地选择、在线搜索、手动创建与结果回填。
struct BookPickerView: View {
    let configuration: BookPickerConfiguration
    let onComplete: (BookPickerResult) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: BookPickerViewModel?
    @State private var activeSeed: BookEditorSeed?
    @State private var isPreparingSeed = false
    @State private var didComplete = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.surfacePage.ignoresSafeArea()

                if let viewModel {
                    content(viewModel)
                } else {
                    LoadingStateView("正在准备书籍选择…", style: .card)
                }

                if isPreparingSeed {
                    Color.overlay.ignoresSafeArea()
                    LoadingStateView("正在补全书籍信息…", style: .card)
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
        }
        .task {
            guard viewModel == nil else { return }
            let newViewModel = BookPickerViewModel(
                configuration: configuration,
                bookRepository: repositories.bookRepository,
                searchRepository: repositories.bookSearchRepository
            )
            viewModel = newViewModel
            await newViewModel.loadIfNeeded()
        }
    }

    private func content(_ viewModel: BookPickerViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                controlsSection(viewModel)
                resultsSection(viewModel)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.section)
        }
        .scrollIndicators(.hidden)
        .searchable(
            text: Binding(
                get: { viewModel.query },
                set: { viewModel.updateQuery($0) }
            ),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索书名、作者、ISBN"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) {
            guard viewModel.visibleScope == .online else { return }
            Task {
                await viewModel.submitOnlineSearch()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.isMultipleSelectionEnabled, viewModel.selectedCount > 0 {
                multipleSelectionBar(viewModel)
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
                        isSelected: viewModel.isBookSelected(book),
                        showsSelectionIndicator: viewModel.isMultipleSelectionEnabled
                    )
                }
                .buttonStyle(.plain)
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
                secondaryTitle: viewModel.supportsManualCreate ? "手动创建书籍" : nil,
                secondaryAction: viewModel.supportsManualCreate ? { activeSeed = viewModel.makeManualSeed() } : nil
            )
        }
    }

    private func localNoResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            BookSearchStatusCard(
                systemImage: "magnifyingglass",
                title: "没有找到匹配的书",
                message: "你可以继续修改关键词，或直接手动创建。"
            )
            stateActionGroup(
                primaryTitle: viewModel.supportsOnline ? "在线搜索" : nil,
                primaryAction: viewModel.supportsOnline ? { viewModel.switchToOnlineIfSupported() } : nil,
                secondaryTitle: viewModel.supportsManualCreate ? "手动创建书籍" : nil,
                secondaryAction: viewModel.supportsManualCreate ? { activeSeed = viewModel.makeManualSeed() } : nil
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
            if viewModel.supportsManualCreate {
                secondaryActionButton("手动创建书籍") {
                    activeSeed = viewModel.makeManualSeed()
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
                    keyword: viewModel.trimmedQuery
                ) {
                    Task {
                        isPreparingSeed = true
                        let seed = await viewModel.prepareSeed(for: result)
                        isPreparingSeed = false
                        if let seed {
                            activeSeed = seed
                        }
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
            if viewModel.supportsManualCreate {
                secondaryActionButton("手动创建书籍") {
                    activeSeed = viewModel.makeManualSeed()
                }
            }
        }
    }

    private func onlineNoResultsSection(_ viewModel: BookPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            BookSearchStatusCard(
                systemImage: "magnifyingglass",
                title: "没有找到匹配的书",
                message: "可以切换搜索源继续查找，或直接手动创建。"
            )
            if viewModel.supportsManualCreate {
                secondaryActionButton("手动创建书籍") {
                    activeSeed = viewModel.makeManualSeed()
                }
            }
        }
    }

    private func multipleSelectionBar(_ viewModel: BookPickerViewModel) -> some View {
        VStack(spacing: Spacing.cozy) {
            Divider()
            Button {
                if let result = viewModel.confirmMultipleSelection() {
                    finish(result)
                }
            } label: {
                HStack {
                    Text("添加所选书籍")
                    Spacer()
                    Text("\(viewModel.selectedCount)")
                }
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.vertical, Spacing.base)
                .background(Color.brand, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
            }
            .buttonStyle(.plain)
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

    private func handleCreatedBook(_ bookId: Int64) async {
        guard let viewModel else { return }
        if let result = await viewModel.handleCreatedBook(bookId: bookId) {
            finish(result)
            return
        }
        if viewModel.visibleScope == .local {
            await viewModel.refreshLocalBooks()
        }
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
    let book: BookPickerBook
    let isSelected: Bool
    let showsSelectionIndicator: Bool

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

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(book.title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if !book.author.isEmpty {
                    Text(book.author)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if showsSelectionIndicator {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.brand : Color.textHint)
            }
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }
}
