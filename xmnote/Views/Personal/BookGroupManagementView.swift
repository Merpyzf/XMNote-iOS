/**
 * [INPUT]: 依赖 RepositoryContainer 注入 BookGroupManagementRepositoryProtocol，依赖 BookGroupManagementViewModel 驱动分组管理状态，依赖 PersonalManagementSearchBar、系统分组 List/Toolbar 与外部 BookRoute 回调，并由页面壳层稳定承载导航命令和排序草稿
 * [OUTPUT]: 对外提供 BookGroupManagementView，以中性顶部命令、可滚动系统搜索和单一数据容器承接分组管理、选择与排序
 * [POS]: Views/Personal 的书籍分组管理页面壳层，被 PersonalRoute.groupManagement 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍分组管理页面，提供新增、重命名、排序、删除和进入分组书籍列表能力。
struct BookGroupManagementView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: BookGroupManagementViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var isReordering = false
    @State private var isInlineSearchActive = false
    @State private var reorderGroups: [BookGroupManagementItem] = []
    private let onOpenBookRoute: (BookRoute) -> Void

    /// 注入组内书籍列表导航回调，保持个人页所在 NavigationStack 的路由所有权。
    init(onOpenBookRoute: @escaping (BookRoute) -> Void = { _ in }) {
        self.onOpenBookRoute = onOpenBookRoute
    }

    var body: some View {
        Group {
            if let viewModel {
                BookGroupManagementContentView(
                    viewModel: viewModel,
                    isReordering: $isReordering,
                    isInlineSearchActive: $isInlineSearchActive,
                    reorderGroups: $reorderGroups,
                    onOpenBookRoute: onOpenBookRoute
                )
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在加载分组…", style: .card)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationTitle(
            navigationTitle
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            viewModel = BookGroupManagementViewModel(repository: repositories.bookGroupManagementRepository)
            bootstrapLoadingGate.update(intent: .none)
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
            clearAndDeactivateSearch()
        }
    }

    private var navigationTitle: String {
        if viewModel?.isSelectionMode == true {
            return "已选择 \(viewModel?.selectedCount ?? 0) 个"
        }
        if isReordering {
            return "调整分组顺序"
        }
        return "分组管理"
    }

    private var isToolbarReady: Bool {
        viewModel != nil
    }

    private var selectionToggleAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.16)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isReordering {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("完成", action: finishReorderMode)
                    .xmToolbarNeutralTint()
                    .disabled(viewModel?.activeWriteAction == .reorder)
                    .allowsHitTesting(isToolbarReady)
                    .accessibilityHidden(!isToolbarReady)
            }
        } else if viewModel?.isSelectionMode == true {
            ToolbarItemGroup(placement: .topBarTrailing) {
                selectionActionMenu

                Button("完成") {
                    viewModel?.exitSelectionMode()
                }
                .xmToolbarNeutralTint()
                .disabled(viewModel?.activeWriteAction != nil)
                .allowsHitTesting(isToolbarReady)
                .accessibilityHidden(!isToolbarReady)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    viewModel?.presentCreateSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .xmToolbarNeutralTint()
                .disabled(viewModel?.activeWriteAction != nil)
                .allowsHitTesting(isToolbarReady)
                .accessibilityHidden(!isToolbarReady)
                .accessibilityLabel("添加分组")

                Menu {
                    Button {
                        guard viewModel?.canEnterSelectionMode == true else { return }
                        deactivateSearch()
                        viewModel?.enterSelectionMode()
                    } label: {
                        XMMenuLabel("选择分组", systemImage: "checklist")
                    }
                    .disabled(viewModel?.canEnterSelectionMode != true)

                    Button {
                        enterReorderMode()
                    } label: {
                        XMMenuLabel("调整顺序", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(viewModel?.canEnterReorder != true)
                    .accessibilityHint(viewModel?.reorderActionAccessibilityHint ?? "")
                } label: {
                    Image(systemName: "ellipsis")
                }
                .xmToolbarNeutralTint()
                .disabled(viewModel?.activeWriteAction != nil)
                .allowsHitTesting(isToolbarReady)
                .accessibilityHidden(!isToolbarReady)
                .accessibilityLabel("更多操作")
            }
        }
    }

    private var selectionActionMenu: some View {
        Menu {
            Button {
                toggleSelection()
            } label: {
                XMMenuLabel(selectionToggleTitle, systemImage: "checkmark.circle")
            }
            .disabled((viewModel?.visibleGroups.isEmpty ?? true) || viewModel?.activeWriteAction != nil)

            Button {
                renameSelectedGroup()
            } label: {
                XMMenuLabel("重命名", systemImage: "pencil")
            }
            .disabled(selectedSingleGroup == nil || viewModel?.activeWriteAction != nil)

            Divider()

            Button("删除", systemImage: "trash", role: .destructive) {
                viewModel?.presentDeleteConfirmationForSelection()
            }
            .disabled((viewModel?.selectedCount ?? 0) == 0 || viewModel?.activeWriteAction != nil)
        } label: {
            Image(systemName: "ellipsis")
        }
        .xmToolbarNeutralTint()
        .allowsHitTesting(isToolbarReady)
        .accessibilityHidden(!isToolbarReady)
        .accessibilityLabel("批量操作")
    }

    private var selectedSingleGroup: BookGroupManagementItem? {
        guard let selectedGroups = viewModel?.selectedGroups,
              selectedGroups.count == 1 else {
            return nil
        }
        return selectedGroups.first
    }

    private var selectionToggleTitle: String {
        guard let viewModel else { return "全选" }
        if viewModel.isSearchFiltering {
            return viewModel.isAllVisibleSelected ? "取消选择搜索结果" : "选择全部搜索结果"
        }
        return viewModel.isAllVisibleSelected ? "取消全选" : "全选"
    }

    private func deactivateSearch(disablesAnimations: Bool = true) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = disablesAnimations || reduceMotion
        withTransaction(transaction) {
            isInlineSearchActive = false
        }
    }

    private func clearAndDeactivateSearch() {
        deactivateSearch()
        viewModel?.clearSearchText()
    }

    private func enterReorderMode() {
        guard let viewModel, viewModel.canEnterReorder else { return }
        deactivateSearch()
        viewModel.exitSelectionMode()
        reorderGroups = viewModel.groups
        isReordering = true
    }

    private func finishReorderMode() {
        guard isReordering, let viewModel else { return }
        let orderedIDs = reorderGroups.map(\.id)
        isReordering = false
        viewModel.commitGroupOrder(orderedIDs)
    }

    private func toggleSelection() {
        guard let viewModel else { return }
        withAnimation(selectionToggleAnimation) {
            if viewModel.isAllVisibleSelected {
                viewModel.clearVisibleSelection()
            } else {
                viewModel.selectAllVisible()
            }
        }
    }

    private func renameSelectedGroup() {
        guard let viewModel, let group = selectedSingleGroup else { return }
        viewModel.presentRenameSheet(for: group)
    }
}

private struct BookGroupManagementContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(XMToastCenter.self) private var toastCenter
    @Bindable var viewModel: BookGroupManagementViewModel
    @Binding var isReordering: Bool
    @Binding var isInlineSearchActive: Bool
    @Binding var reorderGroups: [BookGroupManagementItem]
    let onOpenBookRoute: (BookRoute) -> Void
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        groupList
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
            .onDisappear {
                readLoadingGate.hideImmediately()
            }
    }

    private var modeTransitionAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    private var selectionToggleAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.16)
    }

    @ViewBuilder
    private var groupSectionContent: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                LoadingStateView("正在加载分组…", style: .inline)
                    .bookGroupManagementStateRow()
            } else {
                Color.clear.bookGroupManagementStateRow()
            }
        case .empty:
            XMContentStateView(
                role: .empty,
                title: "暂无书籍分组"
            )
            .bookGroupManagementStateRow()
        case .error:
            XMContentStateView(
                role: .failure,
                title: "暂时无法加载分组",
                action: XMStateAction("重试", perform: viewModel.retryObservation)
            )
            .bookGroupManagementStateRow()
        case .content:
            if viewModel.isSearchResultEmpty {
                XMContentStateView(
                    role: .noResults,
                    title: "没有匹配的分组"
                )
                    .bookGroupManagementStateRow()
            } else {
                groupRows
            }
        }
    }

    private var groupList: some View {
        List {
            if let observationErrorMessage = viewModel.observationErrorMessage {
                Section {
                    XMInlineStatusBanner(
                        observationErrorMessage,
                        tone: .error,
                        action: XMStateAction("重试", perform: viewModel.retryObservation)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if !isReordering {
                Section {
                    PersonalManagementSearchListRow(
                        text: $viewModel.searchText,
                        isActive: $isInlineSearchActive,
                        prompt: "搜索分组",
                        isEnabled: viewModel.activeWriteAction == nil
                    )
                }
                .listSectionMargins(.horizontal, 0)
            }

            Section {
                groupSectionContent
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Spacing.base)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, Spacing.tight, for: .scrollContent)
        .contentMargins(.bottom, Spacing.double, for: .scrollContent)
        .scrollBounceBehavior(.always)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .environment(\.defaultMinListRowHeight, 1)
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .background(Color.surfacePage)
    }

    @ViewBuilder
    private var groupRows: some View {
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

    private func moveReorderGroups(from source: IndexSet, to destination: Int) {
        reorderGroups.move(fromOffsets: source, toOffset: destination)
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

private extension View {
    /// 让分组数据行共享系统分组容器与分隔线，不再为每行创建独立卡片。
    func bookGroupManagementListRowChrome() -> some View {
        listRowInsets(EdgeInsets(
            top: 0,
            leading: Spacing.cozy,
            bottom: 0,
            trailing: Spacing.tight
        ))
        .listRowBackground(Color.surfaceCard)
    }

    /// 统一分组加载、空态和失败态的列表占位，保证内容区搜索始终可达。
    func bookGroupManagementStateRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 260)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview {
    NavigationStack {
        BookGroupManagementView()
            .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
            .environment(XMToastCenter())
    }
}
