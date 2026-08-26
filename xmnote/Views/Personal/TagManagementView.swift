/**
 * [INPUT]: 依赖 RepositoryContainer 注入 TagManagementRepositoryProtocol，依赖 TagManagementViewModel 驱动标签管理状态，依赖系统 segmented Picker/Toolbar、TagManagementCollectionView、safeAreaBar 与范围栏真实几何高度，并由页面壳层稳定承载导航命令
 * [OUTPUT]: 对外提供 TagManagementView，以几何居中的动态标题、满宽原生范围选择、集合内下拉搜索、延伸至导航层下方的 UIKit 主滚动视图、系统自动顶部边缘过渡和响应式标签直接内容平面承接管理任务
 * [POS]: Views/Personal 的标签管理页面壳层，被 PersonalRoute.tagManagement 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 标签管理页面，按书摘/书籍两个范围提供新增、重命名、排序和删除能力。
struct TagManagementView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: TagManagementViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var isReordering = false
    @State private var isInlineSearchActive = false

    var body: some View {
        Group {
            if let viewModel {
                TagManagementContentView(
                    viewModel: viewModel,
                    isReordering: $isReordering,
                    isInlineSearchActive: $isInlineSearchActive
                )
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在加载标签…", style: .card)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePage.ignoresSafeArea())
        .tint(Color.iconPrimary)
        .navigationTitle(
            navigationTitle
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            viewModel = TagManagementViewModel(repository: repositories.tagManagementRepository)
            bootstrapLoadingGate.update(intent: .none)
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
            clearAndDeactivateSearch()
        }
    }

    private var navigationTitle: String {
        if viewModel?.isSelectionMode == true {
            return "已选择 \(viewModel?.selectedTagIDs.count ?? 0) 个"
        }
        if isReordering {
            return "调整标签顺序"
        }
        return "标签管理"
    }

    private var isToolbarReady: Bool {
        viewModel != nil
    }

    private var selectionToggleAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.16)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(navigationTitle)
                .font(AppTypography.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }

        if isReordering {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("完成") {
                    isReordering = false
                }
                .tint(Color.iconPrimary)
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
                .tint(Color.iconPrimary)
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
                        .foregroundStyle(Color.iconPrimary)
                }
                .tint(Color.iconPrimary)
                .disabled(viewModel?.activeWriteAction != nil)
                .allowsHitTesting(isToolbarReady)
                .accessibilityHidden(!isToolbarReady)
                .accessibilityLabel("添加标签")

                Menu {
                    Button("选择标签", systemImage: "checklist") {
                        viewModel?.enterSelectionMode()
                    }
                    .disabled(viewModel?.canEnterSelectionMode != true)

                    Button("调整顺序", systemImage: "arrow.up.arrow.down") {
                        guard viewModel?.canEnterReorder == true else { return }
                        deactivateSearch()
                        isReordering = true
                    }
                    .disabled(viewModel?.canEnterReorder != true)
                    .accessibilityHint(viewModel?.reorderActionAccessibilityHint ?? "")
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.iconPrimary)
                }
                .tint(Color.iconPrimary)
                .disabled(viewModel?.activeWriteAction != nil)
                .allowsHitTesting(isToolbarReady)
                .accessibilityHidden(!isToolbarReady)
                .accessibilityLabel("更多操作")
            }
        }
    }

    private var selectionActionMenu: some View {
        Menu {
            Button(selectionToggleTitle, systemImage: "checkmark.circle") {
                toggleVisibleSelection()
            }
            .disabled((viewModel?.visibleTags.isEmpty ?? true) || viewModel?.activeWriteAction != nil)

            Divider()

            Button("删除", systemImage: "trash", role: .destructive) {
                viewModel?.presentDeleteConfirmationForSelection()
            }
            .disabled((viewModel?.selectedTagIDs.isEmpty ?? true) || viewModel?.activeWriteAction != nil)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Color.iconPrimary)
        }
        .tint(Color.iconPrimary)
        .allowsHitTesting(isToolbarReady)
        .accessibilityHidden(!isToolbarReady)
        .accessibilityLabel("批量操作")
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

    private func clearAndDeactivateSearch(disablesAnimations: Bool = true) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = disablesAnimations || reduceMotion
        withTransaction(transaction) {
            isInlineSearchActive = false
            viewModel?.clearSearchText()
        }
    }

    private func toggleVisibleSelection() {
        guard let viewModel else { return }
        withAnimation(selectionToggleAnimation) {
            if viewModel.isAllVisibleSelected {
                viewModel.clearVisibleSelection()
            } else {
                viewModel.selectAllVisible()
            }
        }
    }
}

private struct TagManagementContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(XMToastCenter.self) private var toastCenter
    @Bindable var viewModel: TagManagementViewModel
    @Binding var isReordering: Bool
    @Binding var isInlineSearchActive: Bool
    @State private var readLoadingGate = LoadingGate()
    @State private var measuredScopeSelectorHeight: CGFloat?
    @ScaledMetric(relativeTo: .subheadline)
    private var defaultScopeSelectorTouchHeight = InteractionMetrics.minimumTouchTarget

    var body: some View {
        tagGrid
            .safeAreaBar(edge: .top, spacing: Spacing.none) {
                scopeSelector
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
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

    private var selectionToggleAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.16)
    }

    private var isScopeLocked: Bool {
        viewModel.isSelectionMode || isReordering || viewModel.activeWriteAction != nil
    }

    private var scopeSelector: some View {
        Picker("标签范围", selection: $viewModel.selectedScope) {
            ForEach(TagManagementScope.allCases) { scope in
                Text(scope.title)
                    .tag(scope)
                    .accessibilityLabel(scopeAccessibilityLabel(for: scope))
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
        .disabled(isScopeLocked)
        .accessibilityLabel("标签范围")
        .accessibilityValue(scopeAccessibilityLabel(for: viewModel.selectedScope))
        .accessibilityHint(isScopeLocked ? "完成当前操作后可切换范围" : "")
        .padding(.horizontal, Spacing.double)
        .padding(.vertical, Spacing.half)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            guard height > 0,
                  abs((measuredScopeSelectorHeight ?? 0) - height) > Spacing.hairline else {
                return
            }
            measuredScopeSelectorHeight = height
        }
    }

    private var collectionEmptyState: TagManagementCollectionEmptyState {
        switch viewModel.contentState {
        case .loading:
            return readLoadingGate.isVisible ? .loading("正在加载标签…") : .none
        case .empty:
            return .empty(title: "暂无\(viewModel.selectedScope.tagTitle)")
        case .error(let message):
            return .error(message: message)
        case .content:
            if viewModel.isSearchResultEmpty {
                return .search(query: viewModel.normalizedSearchText)
            }
            return .none
        }
    }

    private var tagGrid: some View {
        TagManagementCollectionView(
            items: isReordering ? viewModel.currentTags : viewModel.visibleTags,
            scope: viewModel.selectedScope,
            searchText: viewModel.searchText,
            isSearchActive: isInlineSearchActive,
            searchPrompt: "搜索标签",
            isSearchVisible: !isReordering,
            isSearchEnabled: viewModel.activeWriteAction == nil,
            emptyState: collectionEmptyState,
            searchKeyword: viewModel.normalizedSearchText,
            isSelectionMode: viewModel.isSelectionMode,
            isReordering: isReordering,
            selectedTagIDs: viewModel.selectedTagIDs,
            isDisabled: viewModel.activeWriteAction != nil,
            topBarHeight: scopeSelectorHeight,
            onScrollEdgeWashEdgesChange: { _ in },
            onSearchTextChange: { viewModel.searchText = $0 },
            onSearchActiveChange: { isInlineSearchActive = $0 },
            onPrimaryAction: { item in handlePrimaryAction(for: item) },
            onRename: { item in viewModel.presentRenameSheet(for: item) },
            onDelete: { item in viewModel.presentDeleteConfirmation(for: item) },
            onCommitOrder: { orderedIDs in viewModel.commitTagOrder(orderedIDs) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }

    private var scopeSelectorHeight: CGFloat {
        measuredScopeSelectorHeight
            ?? (defaultScopeSelectorTouchHeight + Spacing.half * 2)
    }

    private func scopeAccessibilityLabel(for scope: TagManagementScope) -> String {
        "\(scope.tagTitle)，\(viewModel.snapshot.tags(for: scope).count) 项"
    }

    private func syncLoadingGate() {
        readLoadingGate.update(intent: viewModel.contentState == .loading ? .read : .none)
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
            ? "当前将影响 \(confirmation.associatedCount) 条\(confirmation.scope.associatedItemTitle)关联"
            : "当前没有关联的\(confirmation.scope.associatedItemTitle)"
        return "\(confirmation.scope.deleteMessage)\n\(countText)会被删除，\(relationText)。"
    }
}

#Preview {
    NavigationStack {
        TagManagementView()
            .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
            .environment(XMToastCenter())
    }
}
