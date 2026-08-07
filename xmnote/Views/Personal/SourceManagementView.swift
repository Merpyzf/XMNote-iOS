/**
 * [INPUT]: 依赖 RepositoryContainer 注入 SourceManagementRepositoryProtocol，依赖 SourceManagementViewModel 驱动书籍来源管理与搜索状态，依赖 XMScopeSelector/XMSystemAlert/XMToastCenter/LoadingGate 渲染 iOS 原生管理交互
 * [OUTPUT]: 对外提供 SourceManagementView，承接“我的 > 书籍来源”入口的真实管理页
 * [POS]: Views/Personal 的书籍来源管理页面壳层，被 PersonalRoute.bookSource 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍来源管理页面，按我的来源/默认来源两个范围提供搜索、增改删和排序能力。
struct SourceManagementView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: SourceManagementViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            if let viewModel {
                SourceManagementContentView(viewModel: viewModel)
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在加载来源…", style: .card)
            }
        }
        .navigationTitle("书籍来源")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            viewModel = SourceManagementViewModel(repository: repositories.sourceManagementRepository)
            bootstrapLoadingGate.update(intent: .none)
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

private struct SourceManagementContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(XMToastCenter.self) private var toastCenter
    @Bindable var viewModel: SourceManagementViewModel
    @State private var readLoadingGate = LoadingGate()
    @State private var isSearchPresented = false
    @State private var isReordering = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: Spacing.base) {
            scopeSelector
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.base)
            content
                .id(contentTransitionKey)
                .transition(.opacity)
                .animation(contentTransitionAnimation, value: contentTransitionKey)
        }
        .searchable(
            text: $viewModel.searchText,
            isPresented: $isSearchPresented,
            prompt: "搜索来源"
        )
        .searchFocused($isSearchFocused)
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar(removing: isNormalMode ? nil : .search)
        .toolbar { toolbarContent }
        .sheet(item: $viewModel.activeNameEdit) { edit in
            SourceNameEditSheet(viewModel: viewModel, edit: edit)
        }
        .xmSystemAlert(item: $viewModel.activeDeleteConfirmation) { confirmation in
            deleteDescriptor(for: confirmation)
        }
        .onAppear {
            syncLoadingGate()
        }
        .onChange(of: viewModel.contentState) { _, _ in
            syncLoadingGate()
        }
        .onChange(of: viewModel.toastFeedback) { _, feedback in
            presentToastFeedback(feedback)
        }
        .onChange(of: viewModel.selectedScope) { _, _ in
            isReordering = false
        }
        .onChange(of: isNormalMode) { _, isNormalMode in
            guard !isNormalMode else { return }
            dismissSearch()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
            dismissSearch()
        }
    }

    private var isNormalMode: Bool {
        !isReordering
    }

    private var isSearchActive: Bool {
        isSearchPresented || isSearchFocused || viewModel.isSearchFiltering
    }

    private var searchControlAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.14)
    }

    private var modeTransitionAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    private var contentTransitionAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18)
    }

    private var contentTransitionKey: String {
        switch viewModel.contentState {
        case .loading:
            return readLoadingGate.isVisible ? "loading-visible" : "loading-hidden"
        case .empty:
            return "empty-\(viewModel.selectedScope.rawValue)"
        case .error:
            return "error"
        case .content:
            return viewModel.isSearchResultEmpty ? "search-empty" : "content-\(viewModel.selectedScope.rawValue)"
        }
    }

    private var scopeSelector: some View {
        XMScopeSelector(
            items: [
                XMScopeSelectorItem(
                    id: SourceManagementScope.mine,
                    title: SourceManagementScope.mine.title,
                    count: viewModel.snapshot.mineSources.count,
                    accessibilityTitle: SourceManagementScope.mine.accessibilityTitle
                ),
                XMScopeSelectorItem(
                    id: SourceManagementScope.appDefault,
                    title: SourceManagementScope.appDefault.title,
                    count: viewModel.snapshot.defaultSources.count,
                    accessibilityTitle: SourceManagementScope.appDefault.accessibilityTitle
                )
            ],
            selection: $viewModel.selectedScope,
            style: .content,
            accessibilityLabel: "来源范围"
        )
        .disabled(viewModel.activeWriteAction != nil)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                LoadingStateView("正在加载来源…", style: .inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        case .empty:
            ContentUnavailableView(
                emptyTitle,
                systemImage: emptySystemImage,
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ContentUnavailableView(
                "来源加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            if viewModel.isSearchResultEmpty {
                ContentUnavailableView.search(text: viewModel.normalizedSearchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sourceList
            }
        }
    }

    private var sourceList: some View {
        SourceManagementListView(
            items: isReordering ? viewModel.currentSources : viewModel.visibleSources,
            scope: viewModel.selectedScope,
            searchKeyword: viewModel.normalizedSearchText,
            isReordering: isReordering,
            isDisabled: viewModel.activeWriteAction != nil,
            onPrimaryAction: { item in viewModel.presentRenameSheet(for: item) },
            onRename: { item in viewModel.presentRenameSheet(for: item) },
            onDelete: { item in viewModel.presentDeleteConfirmation(for: item) },
            onCommitOrder: { orderedIDs in viewModel.commitSourceOrder(orderedIDs) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(modeTransitionAnimation, value: isReordering)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            SourceManagementTopTrailingControl(
                isReordering: isReordering,
                isBusy: viewModel.activeWriteAction != nil,
                isReorderBusy: viewModel.activeWriteAction == .reorder,
                canEnterReorder: viewModel.canEnterReorder,
                reorderAccessibilityHint: viewModel.reorderActionAccessibilityHint,
                onEnterReorder: {
                    dismissSearch()
                    isReordering = true
                },
                onFinishReorder: { isReordering = false }
            )
            .xmToolbarNeutralTint()
        }

        if isNormalMode {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)

            ToolbarSpacer(placement: .bottomBar)

            ToolbarItem(placement: .bottomBar) {
                Button {
                    viewModel.presentCreateSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!viewModel.canCreateSource || isSearchActive)
                .opacity(shouldShowCreateButton ? 1 : 0)
                .animation(searchControlAnimation, value: shouldShowCreateButton)
                .xmToolbarNeutralTint()
                .accessibilityHidden(!shouldShowCreateButton)
                .accessibilityLabel("添加来源")
            }
        }
    }

    private var shouldShowCreateButton: Bool {
        viewModel.selectedScope == .mine && !isSearchActive
    }

    private var emptyTitle: String {
        switch viewModel.selectedScope {
        case .mine:
            return "暂无我的来源"
        case .appDefault:
            return "暂无默认来源"
        }
    }

    private var emptyDescription: String {
        switch viewModel.selectedScope {
        case .mine:
            return "添加来源后，可在录入和批量编辑书籍时选择。"
        case .appDefault:
            return "默认来源随基础数据初始化生成。"
        }
    }

    private var emptySystemImage: String {
        switch viewModel.selectedScope {
        case .mine:
            return "books.vertical"
        case .appDefault:
            return "building.columns"
        }
    }

    private func syncLoadingGate() {
        readLoadingGate.update(intent: viewModel.contentState == .loading ? .read : .none)
    }

    private func dismissSearch(disablesAnimations: Bool = true) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = disablesAnimations || reduceMotion
        withTransaction(transaction) {
            isSearchFocused = false
            isSearchPresented = false
            viewModel.clearSearchText()
        }
    }

    private func presentToastFeedback(_ feedback: SourceManagementToastFeedback?) {
        guard let feedback else { return }
        switch feedback.role {
        case .warning:
            toastCenter.warning(feedback.message)
        case .error:
            toastCenter.error(feedback.message)
        }
        viewModel.consumeToastFeedback()
    }

    private func deleteDescriptor(for confirmation: SourceManagementDeleteConfirmation) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "删除来源",
            message: deleteMessage(for: confirmation),
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    viewModel.submitDelete()
                }
            ],
            preferredActionID: nil
        )
    }

    private func deleteMessage(for confirmation: SourceManagementDeleteConfirmation) -> String {
        let relationText = confirmation.associatedBookCount > 0
            ? "当前将影响 \(confirmation.associatedBookCount) 本书。"
            : "当前没有关联书籍。"
        return "删除后，关联书籍的来源会被设为「未知」，你确定要继续吗？\n\(relationText)"
    }
}

/// 来源管理顶部右侧操作区，在同一个 toolbar slot 内完成普通态和排序态切换。
private struct SourceManagementTopTrailingControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isReordering: Bool
    let isBusy: Bool
    let isReorderBusy: Bool
    let canEnterReorder: Bool
    let reorderAccessibilityHint: String
    let onEnterReorder: () -> Void
    let onFinishReorder: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            if isReordering {
                toolbarIconButton(
                    systemName: "checkmark",
                    foregroundColor: isReorderBusy ? Color.textHint : Color.brand,
                    isEnabled: !isReorderBusy,
                    accessibilityLabel: "完成排序",
                    action: onFinishReorder
                )
                .transition(modeTransition)
            } else {
                normalMenu
                    .transition(modeTransition)
            }
        }
        .fixedSize()
        .animation(modeAnimation, value: isReordering)
    }

    private var normalMenu: some View {
        Menu {
            Button {
                onEnterReorder()
            } label: {
                XMMenuLabel("调整顺序", systemImage: "arrow.up.arrow.down")
            }
            .disabled(!canEnterReorder)
            .accessibilityHint(reorderAccessibilityHint)
        } label: {
            toolbarGlyph(
                systemName: "ellipsis",
                foregroundColor: isBusy ? Color.textHint : Color.iconPrimary
            )
        }
        .disabled(isBusy)
        .accessibilityLabel("更多操作")
    }

    private var modeAnimation: Animation? {
        if reduceMotion {
            return .easeOut(duration: SourceManagementTopTrailingMetrics.reducedMotionDuration)
        }
        return .smooth(duration: SourceManagementTopTrailingMetrics.transitionDuration)
    }

    private var modeTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: SourceManagementTopTrailingMetrics.hiddenScale))
    }

    private func toolbarIconButton(
        systemName: String,
        foregroundColor: Color,
        isEnabled: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarGlyph(systemName: systemName, foregroundColor: foregroundColor)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func toolbarGlyph(
        systemName: String,
        foregroundColor: Color
    ) -> some View {
        Image(systemName: systemName)
            .font(AppTypography.subheadlineSemibold)
            .foregroundStyle(foregroundColor)
    }
}

private enum SourceManagementTopTrailingMetrics {
    static let hiddenScale: CGFloat = 0.94
    static let transitionDuration: TimeInterval = 0.18
    static let reducedMotionDuration: TimeInterval = 0.12
}
