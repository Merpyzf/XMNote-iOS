/**
 * [INPUT]: 依赖 RepositoryContainer 注入 TagManagementRepositoryProtocol，依赖 TagManagementViewModel 驱动标签管理与搜索标签状态，依赖 XMScopeSelector/XMSystemAlert/XMToastCenter/LoadingGate 渲染 iOS 原生管理交互
 * [OUTPUT]: 对外提供 TagManagementView，承接“我的 > 标签管理”入口的真实管理页
 * [POS]: Views/Personal 的标签管理页面壳层，被 PersonalRoute.tagManagement 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 标签管理页面，按书摘/书籍两个范围提供新增、重命名、排序和删除能力。
struct TagManagementView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: TagManagementViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            if let viewModel {
                TagManagementContentView(viewModel: viewModel)
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在加载标签…", style: .card)
            }
        }
        .navigationTitle("标签管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            viewModel = TagManagementViewModel(repository: repositories.tagManagementRepository)
            bootstrapLoadingGate.update(intent: .none)
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

private struct TagManagementContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(XMToastCenter.self) private var toastCenter
    @Bindable var viewModel: TagManagementViewModel
    @State private var readLoadingGate = LoadingGate()
    @State private var isSearchPresented = false
    @State private var isReordering = false
    @State private var scrollEdgeWashEdges = XMScrollEdgeWashEdges.hidden
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
            prompt: "搜索标签"
        )
        .searchFocused($isSearchFocused)
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar(removing: isNormalMode ? nil : .search)
        .toolbar { toolbarContent }
        .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
            if viewModel.isSelectionMode {
                selectionBottomChrome
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(modeTransitionAnimation, value: viewModel.isSelectionMode)
        .animation(modeTransitionAnimation, value: isReordering)
        .sheet(item: $viewModel.activeNameEdit) { edit in
            TagNameEditSheet(viewModel: viewModel, edit: edit)
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
            scrollEdgeWashEdges = .hidden
        }
        .onChange(of: viewModel.isSelectionMode) { _, isSelectionMode in
            if isSelectionMode {
                isReordering = false
            }
        }
        .onChange(of: isNormalMode) { _, isNormalMode in
            guard !isNormalMode else { return }
            dismissSearch()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
            dismissSearch()
            scrollEdgeWashEdges = .hidden
        }
    }

    private var isNormalMode: Bool {
        !viewModel.isSelectionMode && !isReordering
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

    private var selectionToggleAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.16)
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
            return viewModel.isSearchResultEmpty ? "search-empty" : "content"
        }
    }

    private var topTrailingMode: TagManagementTopTrailingMode {
        if isReordering {
            return .reordering
        }
        if viewModel.isSelectionMode {
            return .selecting
        }
        return .normal
    }

    private var scopeSelector: some View {
        XMScopeSelector(
            items: [
                XMScopeSelectorItem(
                    id: TagManagementScope.note,
                    title: TagManagementScope.note.title,
                    count: viewModel.snapshot.noteTags.count,
                    accessibilityTitle: TagManagementScope.note.tagTitle
                ),
                XMScopeSelectorItem(
                    id: TagManagementScope.book,
                    title: TagManagementScope.book.title,
                    count: viewModel.snapshot.bookTags.count,
                    accessibilityTitle: TagManagementScope.book.tagTitle
                )
            ],
            selection: $viewModel.selectedScope,
            style: .content,
            accessibilityLabel: "标签范围"
        )
        .disabled(viewModel.activeWriteAction != nil)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                LoadingStateView("正在加载标签…", style: .inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        case .empty:
            ContentUnavailableView(
                "暂无\(viewModel.selectedScope.tagTitle)",
                systemImage: "tag"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ContentUnavailableView(
                "标签加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            if viewModel.isSearchResultEmpty {
                ContentUnavailableView.search(text: viewModel.normalizedSearchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tagGrid
            }
        }
    }

    private var tagGrid: some View {
        TagManagementCollectionView(
            items: isReordering ? viewModel.currentTags : viewModel.visibleTags,
            scope: viewModel.selectedScope,
            searchKeyword: viewModel.normalizedSearchText,
            isSelectionMode: viewModel.isSelectionMode,
            isReordering: isReordering,
            selectedTagIDs: viewModel.selectedTagIDs,
            isDisabled: viewModel.activeWriteAction != nil,
            bottomContentInset: 0,
            onScrollEdgeWashEdgesChange: { scrollEdgeWashEdges = $0 },
            onPrimaryAction: { item in handlePrimaryAction(for: item) },
            onRename: { item in viewModel.presentRenameSheet(for: item) },
            onDelete: { item in viewModel.presentDeleteConfirmation(for: item) },
            onCommitOrder: { orderedIDs in viewModel.commitTagOrder(orderedIDs) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .xmScrollEdgeWash(
            edges: .top,
            style: TagManagementLayoutMetrics.gridTopWashStyle,
            activeEdges: scrollEdgeWashEdges
        )
        .ignoresSafeArea(.container, edges: .bottom)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            TagManagementTopTrailingControl(
                mode: topTrailingMode,
                isBusy: viewModel.activeWriteAction != nil,
                isReorderBusy: viewModel.activeWriteAction == .reorder,
                canEnterSelectionMode: viewModel.canEnterSelectionMode,
                canEnterReorder: viewModel.canEnterReorder,
                reorderAccessibilityHint: viewModel.reorderActionAccessibilityHint,
                onEnterSelectionMode: { viewModel.enterSelectionMode() },
                onEnterReorder: {
                    dismissSearch()
                    isReordering = true
                },
                onCompleteSelection: { viewModel.exitSelectionMode() },
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
                .disabled(viewModel.activeWriteAction != nil || isSearchActive)
                .opacity(isSearchActive ? 0 : 1)
                .animation(searchControlAnimation, value: isSearchActive)
                .xmToolbarNeutralTint()
                .accessibilityHidden(isSearchActive)
                .accessibilityLabel("添加标签")
            }
        }
    }

    private var selectionBottomChrome: some View {
        TagManagementSelectionBottomBar(
            selectedCount: viewModel.selectedTagIDs.count,
            isAllVisibleSelected: viewModel.isAllVisibleSelected,
            isBusy: viewModel.activeWriteAction != nil,
            onToggleSelectAll: toggleVisibleSelection,
            onDelete: { viewModel.presentDeleteConfirmationForSelection() }
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.base)
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

    private func handlePrimaryAction(for item: TagManagementItem) {
        if viewModel.isSelectionMode {
            viewModel.toggleSelection(for: item)
        } else if !isReordering {
            viewModel.presentRenameSheet(for: item)
        }
    }

    private func toggleVisibleSelection() {
        withAnimation(selectionToggleAnimation) {
            if viewModel.isAllVisibleSelected {
                viewModel.clearVisibleSelection()
            } else {
                viewModel.selectAllVisible()
            }
        }
    }

    private func presentToastFeedback(_ feedback: TagManagementToastFeedback?) {
        guard let feedback else { return }
        switch feedback.role {
        case .warning:
            toastCenter.warning(feedback.message)
        case .error:
            toastCenter.error(feedback.message)
        }
        viewModel.consumeToastFeedback()
    }

    private func deleteDescriptor(for confirmation: TagManagementDeleteConfirmation) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: confirmation.tagCount > 1 ? "删除标签" : "删除标签",
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

    private func deleteMessage(for confirmation: TagManagementDeleteConfirmation) -> String {
        let countText = confirmation.tagCount > 1 ? "\(confirmation.tagCount) 个标签" : "该标签"
        let relationText = confirmation.associatedCount > 0
            ? "当前将影响 \(confirmation.associatedCount) 条\(confirmation.scope.associatedItemTitle)关联。"
            : "当前没有关联的\(confirmation.scope.associatedItemTitle)。"
        return "\(confirmation.scope.deleteMessage)\n\(countText)会被删除，\(relationText)"
    }
}

private enum TagManagementBottomBarMetrics {
    static let controlHeight: CGFloat = 52
    static let actionButtonWidth: CGFloat = 72
    static let selectionToggleButtonWidth: CGFloat = 92
    static let ornamentMinWidth: CGFloat = 86
    static let ornamentMaxWidth: CGFloat = 128
    static let ornamentHorizontalPadding: CGFloat = Spacing.tight
    static let groupSpacing: CGFloat = Spacing.cozy
}

private enum TagManagementLayoutMetrics {
    static let gridTopWashStyle = XMScrollEdgeWashStyle(
        height: 28,
        strength: .regular,
        surface: .page
    )
}

/// 标签管理顶部右侧操作区模式，让系统 toolbar slot 在模式切换时保持稳定身份。
private enum TagManagementTopTrailingMode: Hashable {
    case normal
    case selecting
    case reordering
}

/// 标签管理顶部右侧操作区，在同一个 44pt toolbar slot 内完成模式 icon 的局部过渡。
private struct TagManagementTopTrailingControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: TagManagementTopTrailingMode
    let isBusy: Bool
    let isReorderBusy: Bool
    let canEnterSelectionMode: Bool
    let canEnterReorder: Bool
    let reorderAccessibilityHint: String
    let onEnterSelectionMode: () -> Void
    let onEnterReorder: () -> Void
    let onCompleteSelection: () -> Void
    let onFinishReorder: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            switch mode {
            case .normal:
                normalMenu
                    .transition(modeTransition)
            case .selecting:
                toolbarIconButton(
                    systemName: "checkmark",
                    foregroundColor: isBusy ? Color.textHint : Color.brand,
                    isEnabled: !isBusy,
                    accessibilityLabel: "完成选择",
                    action: onCompleteSelection
                )
                    .transition(modeTransition)
            case .reordering:
                toolbarIconButton(
                    systemName: "checkmark",
                    foregroundColor: isReorderBusy ? Color.textHint : Color.brand,
                    isEnabled: !isReorderBusy,
                    accessibilityLabel: "完成排序",
                    action: onFinishReorder
                )
                    .transition(modeTransition)
            }
        }
        .fixedSize()
        .animation(modeAnimation, value: mode)
    }

    private var normalMenu: some View {
        Menu {
            Button {
                onEnterSelectionMode()
            } label: {
                XMMenuLabel("选择标签", systemImage: "checklist")
            }
            .disabled(!canEnterSelectionMode)

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
            return .easeOut(duration: TagManagementTopTrailingMetrics.reducedMotionDuration)
        }
        return .smooth(duration: TagManagementTopTrailingMetrics.transitionDuration)
    }

    private var modeTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: TagManagementTopTrailingMetrics.hiddenScale))
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
            .font(.system(size: TagManagementTopTrailingMetrics.iconSize, weight: .semibold))
            .foregroundStyle(foregroundColor)
    }
}

private enum TagManagementTopTrailingMetrics {
    static let iconSize: CGFloat = 15
    static let hiddenScale: CGFloat = 0.94
    static let transitionDuration: TimeInterval = 0.18
    static let reducedMotionDuration: TimeInterval = 0.12
}

/// 标签选择态底部浮层，提供可见范围全选切换、只读选择状态与删除入口。
private struct TagManagementSelectionBottomBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selectedCount: Int
    let isAllVisibleSelected: Bool
    let isBusy: Bool
    let onToggleSelectAll: () -> Void
    let onDelete: () -> Void

    private var selectionToggleTitle: String {
        isAllVisibleSelected ? "取消全选" : "全选"
    }

    private var statusText: String {
        guard selectedCount > 0 else { return "未选择" }
        if dynamicTypeSize.isAccessibilitySize {
            return "\(selectedCount) 个"
        }
        return "已选 \(selectedCount) 个"
    }

    private var statusAccessibilityLabel: String {
        selectedCount > 0 ? "已选择 \(selectedCount) 个标签" : "未选择标签"
    }

    private var canDelete: Bool {
        selectedCount > 0 && !isBusy
    }

    private var canToggleSelection: Bool {
        !isBusy
    }

    var body: some View {
        GlassEffectContainer(spacing: TagManagementBottomBarMetrics.groupSpacing) {
            HStack(spacing: TagManagementBottomBarMetrics.groupSpacing) {
                selectionToggleButton

                selectionOrnament
                    .layoutPriority(1)

                deleteButton
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var selectionToggleButton: some View {
        Button(action: onToggleSelectAll) {
            Text(selectionToggleTitle)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(canToggleSelection ? Color.textPrimary : Color.textHint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: TagManagementBottomBarMetrics.selectionToggleButtonWidth)
                .frame(minHeight: TagManagementBottomBarMetrics.controlHeight)
                .contentTransition(.opacity)
                .animation(selectionCountAnimation, value: isAllVisibleSelected)
        }
        .buttonStyle(.plain)
        .disabled(!canToggleSelection)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(selectionToggleTitle)
    }

    private var selectionOrnament: some View {
        Text(statusText)
            .font(AppTypography.subheadlineMedium)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(
                minWidth: TagManagementBottomBarMetrics.ornamentMinWidth,
                maxWidth: TagManagementBottomBarMetrics.ornamentMaxWidth,
                minHeight: TagManagementBottomBarMetrics.controlHeight
            )
            .padding(.horizontal, TagManagementBottomBarMetrics.ornamentHorizontalPadding)
            .contentTransition(selectionCountTransition)
            .animation(selectionCountAnimation, value: selectedCount)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusAccessibilityLabel)
    }

    private var selectionCountTransition: ContentTransition {
        reduceMotion ? .opacity : .numericText(value: Double(selectedCount))
    }

    private var selectionCountAnimation: Animation? {
        if reduceMotion {
            return .easeOut(duration: 0.12)
        }
        return .snappy(duration: 0.16)
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(canDelete ? Color.feedbackError : Color.textHint)
                .frame(width: TagManagementBottomBarMetrics.actionButtonWidth)
                .frame(minHeight: TagManagementBottomBarMetrics.controlHeight)
        }
        .buttonStyle(.plain)
        .disabled(!canDelete)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(canDelete ? "删除" : "删除，当前不可用")
    }
}

#Preview {
    NavigationStack {
        TagManagementView()
            .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
            .environment(XMToastCenter())
    }
}
