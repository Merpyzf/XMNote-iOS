/**
 * [INPUT]: 依赖 RepositoryContainer 注入 BookGroupManagementRepositoryProtocol，依赖 BookGroupManagementViewModel 驱动分组管理与搜索状态，依赖外部 BookRoute 导航回调进入组内书籍列表
 * [OUTPUT]: 对外提供 BookGroupManagementView，承接“我的 > 书籍分组”入口的真实管理、搜索与长按操作页面
 * [POS]: Views/Personal 的书籍分组管理页面壳层，被 PersonalRoute.groupManagement 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍分组管理页面，提供新增、重命名、排序、删除和进入分组书籍列表能力。
struct BookGroupManagementView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookGroupManagementViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    private let onOpenBookRoute: (BookRoute) -> Void

    /// 注入组内书籍列表导航回调，保持个人页所在 NavigationStack 的路由所有权。
    init(onOpenBookRoute: @escaping (BookRoute) -> Void = { _ in }) {
        self.onOpenBookRoute = onOpenBookRoute
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            if let viewModel {
                BookGroupManagementContentView(
                    viewModel: viewModel,
                    onOpenBookRoute: onOpenBookRoute
                )
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在加载分组…", style: .card)
            }
        }
        .navigationTitle("分组管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            viewModel = BookGroupManagementViewModel(repository: repositories.bookGroupManagementRepository)
            bootstrapLoadingGate.update(intent: .none)
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

private struct BookGroupManagementContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(XMToastCenter.self) private var toastCenter
    @Bindable var viewModel: BookGroupManagementViewModel
    let onOpenBookRoute: (BookRoute) -> Void
    @State private var readLoadingGate = LoadingGate()
    @State private var isSearchPresented = false
    @State private var isReordering = false
    @State private var reorderGroups: [BookGroupManagementItem] = []
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        content
            .id(contentTransitionKey)
            .transition(.opacity)
            .animation(contentTransitionAnimation, value: contentTransitionKey)
            .searchable(
                text: $viewModel.searchText,
                isPresented: $isSearchPresented,
                prompt: "搜索分组"
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
                BookGroupNameEditSheet(viewModel: viewModel, edit: edit)
            }
            .xmSystemAlert(item: $viewModel.activeDeleteConfirmation) { confirmation in
                deleteDescriptor(for: confirmation)
            }
            .onAppear {
                reorderGroups = viewModel.groups
                syncLoadingGate()
            }
            .onChange(of: viewModel.contentState) { _, _ in
                syncLoadingGate()
            }
            .onChange(of: viewModel.toastFeedback) { _, feedback in
                presentToastFeedback(feedback)
            }
            .onChange(of: viewModel.groups) { _, groups in
                guard !isReordering else { return }
                reorderGroups = groups
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
            return "empty"
        case .error:
            return "error"
        case .content:
            if viewModel.isSearchResultEmpty {
                return "search-empty"
            }
            return isReordering ? "reorder" : "content"
        }
    }

    private var topTrailingMode: BookGroupManagementTopTrailingMode {
        if isReordering {
            return .reordering
        }
        if viewModel.isSelectionMode {
            return .selecting
        }
        return .normal
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                LoadingStateView("正在加载分组…", style: .inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        case .empty:
            ContentUnavailableView(
                "暂无书籍分组",
                systemImage: "folder"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ContentUnavailableView(
                "分组加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            if viewModel.isSearchResultEmpty {
                ContentUnavailableView.search(text: viewModel.normalizedSearchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                groupList
            }
        }
    }

    private var groupList: some View {
        List {
            if isReordering {
                ForEach(reorderGroups) { item in
                    BookGroupManagementRowView(
                        item: item,
                        isSelectionMode: false,
                        isSelected: false,
                        isDisabled: viewModel.activeWriteAction != nil,
                        showsDisclosureIndicator: false
                    )
                    .bookGroupManagementListRowChrome()
                }
                .onMove(perform: moveReorderGroups)
            } else {
                ForEach(viewModel.visibleGroups) { item in
                    if viewModel.isSelectionMode {
                        BookGroupManagementRowView(
                            item: item,
                            isSelectionMode: true,
                            isSelected: viewModel.selectedGroupIDs.contains(item.id),
                            isDisabled: viewModel.activeWriteAction != nil,
                            showsDisclosureIndicator: false,
                            onPrimaryAction: {
                                withAnimation(selectionToggleAnimation) {
                                    viewModel.toggleSelection(for: item)
                                }
                            }
                        )
                        .bookGroupManagementListRowChrome()
                    } else {
                        BookGroupManagementRowView(
                            item: item,
                            isSelectionMode: false,
                            isSelected: false,
                            isDisabled: viewModel.activeWriteAction != nil,
                            showsDisclosureIndicator: true,
                            searchKeyword: viewModel.normalizedSearchText,
                            onPrimaryAction: {
                                onOpenBookRoute(bookRoute(for: item))
                            },
                            onRename: {
                                viewModel.presentRenameSheet(for: item)
                            },
                            onDelete: {
                                viewModel.presentDeleteConfirmation(for: item)
                            }
                        )
                        .bookGroupManagementListRowChrome()
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, Spacing.tight, for: .scrollContent)
        .contentMargins(.bottom, Spacing.double, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .environment(\.defaultMinListRowHeight, 1)
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .background(Color.surfacePage)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            BookGroupManagementTopTrailingControl(
                mode: topTrailingMode,
                isBusy: viewModel.activeWriteAction != nil,
                isReorderBusy: viewModel.activeWriteAction == .reorder,
                canEnterSelectionMode: viewModel.canEnterSelectionMode,
                canEnterReorder: viewModel.canEnterReorder,
                reorderAccessibilityHint: viewModel.reorderActionAccessibilityHint,
                onEnterSelectionMode: {
                    dismissSearch()
                    viewModel.enterSelectionMode()
                },
                onEnterReorder: {
                    dismissSearch()
                    enterReorderMode()
                },
                onCompleteSelection: { viewModel.exitSelectionMode() },
                onFinishReorder: finishReorderMode
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
                .accessibilityLabel("添加分组")
            }
        }
    }

    private var selectionBottomChrome: some View {
        BookGroupManagementSelectionBottomBar(
            selectedCount: viewModel.selectedCount,
            isAllSelected: viewModel.isAllSelected,
            isBusy: viewModel.activeWriteAction != nil,
            canRename: selectedSingleGroup != nil,
            onToggleSelectAll: toggleSelection,
            onRename: renameSelectedGroup,
            onDelete: { viewModel.presentDeleteConfirmationForSelection() }
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.base)
    }

    private var selectedSingleGroup: BookGroupManagementItem? {
        let selected = viewModel.selectedGroups
        guard selected.count == 1 else { return nil }
        return selected.first
    }

    private func bookRoute(for item: BookGroupManagementItem) -> BookRoute {
        .bookshelfList(BookshelfBookListRoute(
            context: .defaultGroup(item.id),
            title: item.name,
            subtitleHint: "\(item.bookCount)本"
        ))
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

    private func enterReorderMode() {
        guard viewModel.canEnterReorder else { return }
        viewModel.exitSelectionMode()
        reorderGroups = viewModel.groups
        isReordering = true
    }

    private func finishReorderMode() {
        guard isReordering else { return }
        let orderedIDs = reorderGroups.map(\.id)
        isReordering = false
        viewModel.commitGroupOrder(orderedIDs)
    }

    private func moveReorderGroups(from source: IndexSet, to destination: Int) {
        reorderGroups.move(fromOffsets: source, toOffset: destination)
    }

    private func toggleSelection() {
        withAnimation(selectionToggleAnimation) {
            if viewModel.isAllSelected {
                viewModel.clearSelection()
            } else {
                viewModel.selectAll()
            }
        }
    }

    private func renameSelectedGroup() {
        guard let group = selectedSingleGroup else { return }
        viewModel.presentRenameSheet(for: group)
    }

    private func presentToastFeedback(_ feedback: BookGroupManagementToastFeedback?) {
        guard let feedback else { return }
        switch feedback.role {
        case .warning:
            toastCenter.warning(feedback.message)
        case .error:
            toastCenter.error(feedback.message)
        }
        viewModel.consumeToastFeedback()
    }

    private func deleteDescriptor(for confirmation: BookGroupManagementDeleteConfirmation) -> XMSystemAlertDescriptor {
        if confirmation.containsBooks {
            return XMSystemAlertDescriptor(
                title: "删除分组",
                message: deleteWithBooksMessage(for: confirmation),
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "移到最前并删除", role: .destructive) {
                        viewModel.submitDelete(placement: .start)
                    },
                    XMSystemAlertAction(title: "移到最后并删除", role: .destructive) {
                        viewModel.submitDelete(placement: .end)
                    }
                ],
                preferredActionID: nil
            )
        }

        return XMSystemAlertDescriptor(
            title: "删除分组",
            message: deleteEmptyMessage(for: confirmation),
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    viewModel.submitDelete(placement: .end)
                }
            ],
            preferredActionID: nil
        )
    }

    private func deleteWithBooksMessage(for confirmation: BookGroupManagementDeleteConfirmation) -> String {
        let groupText = confirmation.groupCount > 1 ? "\(confirmation.groupCount) 个分组" : "该分组"
        return "\(groupText)会被删除，分组内 \(confirmation.affectedBookCount) 本书会移回默认书架。请选择移出后的位置。"
    }

    private func deleteEmptyMessage(for confirmation: BookGroupManagementDeleteConfirmation) -> String {
        let groupText = confirmation.groupCount > 1 ? "\(confirmation.groupCount) 个分组" : "该分组"
        return "\(groupText)会被删除，当前没有包含书籍。"
    }
}

private enum BookGroupManagementBottomBarMetrics {
    static let controlHeight: CGFloat = 52
    static let actionButtonWidth: CGFloat = 72
    static let selectionToggleButtonWidth: CGFloat = 92
    static let ornamentMinWidth: CGFloat = 86
    static let ornamentMaxWidth: CGFloat = 128
    static let ornamentHorizontalPadding: CGFloat = Spacing.tight
    static let groupSpacing: CGFloat = Spacing.cozy
}

private extension View {
    func bookGroupManagementListRowChrome() -> some View {
        listRowInsets(EdgeInsets(
            top: Spacing.half,
            leading: Spacing.screenEdge,
            bottom: Spacing.half,
            trailing: Spacing.screenEdge
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// 书籍分组管理顶部右侧操作区模式，让系统 toolbar slot 在模式切换时保持稳定身份。
private enum BookGroupManagementTopTrailingMode: Hashable {
    case normal
    case selecting
    case reordering
}

/// 书籍分组管理顶部右侧操作区，在同一个 44pt toolbar slot 内完成模式 icon 的局部过渡。
private struct BookGroupManagementTopTrailingControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: BookGroupManagementTopTrailingMode
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
                XMMenuLabel("选择分组", systemImage: "checklist")
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
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18)
    }

    private var modeTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.94))
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
            .font(AppTypography.bodyMedium)
            .foregroundStyle(foregroundColor)
    }
}

/// 书籍分组选择态底部浮层，提供单选重命名、全选切换、只读选择状态与删除入口。
private struct BookGroupManagementSelectionBottomBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selectedCount: Int
    let isAllSelected: Bool
    let isBusy: Bool
    let canRename: Bool
    let onToggleSelectAll: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var selectionToggleTitle: String {
        isAllSelected ? "取消全选" : "全选"
    }

    private var leadingActionTitle: String {
        canRename ? "重命名" : selectionToggleTitle
    }

    private var statusText: String {
        guard selectedCount > 0 else { return "未选择" }
        if dynamicTypeSize.isAccessibilitySize {
            return "\(selectedCount) 个"
        }
        return "已选 \(selectedCount) 个"
    }

    private var statusAccessibilityLabel: String {
        selectedCount > 0 ? "已选择 \(selectedCount) 个分组" : "未选择分组"
    }

    private var canDelete: Bool {
        selectedCount > 0 && !isBusy
    }

    private var canToggleSelection: Bool {
        !isBusy
    }

    private var canUseLeadingAction: Bool {
        canRename ? !isBusy : canToggleSelection
    }

    var body: some View {
        GlassEffectContainer(spacing: BookGroupManagementBottomBarMetrics.groupSpacing) {
            HStack(spacing: BookGroupManagementBottomBarMetrics.groupSpacing) {
                leadingActionButton

                selectionOrnament
                    .layoutPriority(1)

                deleteButton
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var leadingActionButton: some View {
        Button(action: handleLeadingAction) {
            Text(leadingActionTitle)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(canUseLeadingAction ? Color.textPrimary : Color.textHint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: BookGroupManagementBottomBarMetrics.selectionToggleButtonWidth)
                .frame(minHeight: BookGroupManagementBottomBarMetrics.controlHeight)
                .contentTransition(.opacity)
                .animation(selectionCountAnimation, value: leadingActionTitle)
        }
        .buttonStyle(.plain)
        .disabled(!canUseLeadingAction)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(leadingActionTitle)
    }

    private func handleLeadingAction() {
        if canRename {
            onRename()
        } else {
            onToggleSelectAll()
        }
    }

    private var selectionOrnament: some View {
        Text(statusText)
            .font(AppTypography.subheadlineMedium)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(
                minWidth: BookGroupManagementBottomBarMetrics.ornamentMinWidth,
                maxWidth: BookGroupManagementBottomBarMetrics.ornamentMaxWidth,
                minHeight: BookGroupManagementBottomBarMetrics.controlHeight
            )
            .padding(.horizontal, BookGroupManagementBottomBarMetrics.ornamentHorizontalPadding)
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
        reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.16)
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(canDelete ? Color.feedbackError : Color.textHint)
                .frame(width: BookGroupManagementBottomBarMetrics.actionButtonWidth)
                .frame(minHeight: BookGroupManagementBottomBarMetrics.controlHeight)
        }
        .buttonStyle(.plain)
        .disabled(!canDelete)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(canDelete ? "删除" : "删除，当前不可用")
    }
}

#Preview {
    NavigationStack {
        BookGroupManagementView()
            .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
            .environment(XMToastCenter())
    }
}
