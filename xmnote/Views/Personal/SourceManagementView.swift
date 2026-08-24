/**
 * [INPUT]: 依赖 RepositoryContainer 注入 SourceManagementRepositoryProtocol，依赖 SourceManagementViewModel 驱动来源管理状态，依赖 PersonalManagementSearchBar、XMScopeSelector 与系统分组 List/Toolbar/scroll-edge，并由页面壳层稳定承载导航命令
 * [OUTPUT]: 对外提供 SourceManagementView，以首帧稳定的顶部命令、固定来源范围、可滚动系统搜索、自动顶部边缘过渡和单一数据容器承接来源管理
 * [POS]: Views/Personal 的书籍来源管理页面壳层，被 PersonalRoute.bookSource 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍来源管理页面，按我的来源/默认来源两个范围提供搜索、增改删和排序能力。
struct SourceManagementView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: SourceManagementViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var isReordering = false
    @State private var isInlineSearchActive = false

    var body: some View {
        Group {
            if let viewModel {
                SourceManagementContentView(
                    viewModel: viewModel,
                    isReordering: $isReordering,
                    isInlineSearchActive: $isInlineSearchActive
                )
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在加载来源…", style: .card)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePage.ignoresSafeArea())
        .tint(Color.iconPrimary)
        .navigationTitle(isReordering ? "调整来源顺序" : "书籍来源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            viewModel = SourceManagementViewModel(repository: repositories.sourceManagementRepository)
            bootstrapLoadingGate.update(intent: .none)
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
            clearAndDeactivateSearch()
        }
    }

    private var isToolbarReady: Bool {
        viewModel != nil
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isReordering {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("完成") {
                    isReordering = false
                }
                .disabled(viewModel?.activeWriteAction == .reorder)
                .allowsHitTesting(isToolbarReady)
                .accessibilityHidden(!isToolbarReady)
            }
        } else if viewModel?.selectedScope != .appDefault {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    viewModel?.presentCreateSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.map { !$0.canCreateSource } ?? false)
                .allowsHitTesting(isToolbarReady)
                .accessibilityHidden(!isToolbarReady)
                .accessibilityLabel("添加来源")

                Menu {
                    Button("调整顺序", systemImage: "arrow.up.arrow.down") {
                        guard viewModel?.canEnterReorder == true else { return }
                        deactivateSearch()
                        isReordering = true
                    }
                    .disabled(viewModel?.canEnterReorder != true)
                    .accessibilityHint(viewModel?.reorderActionAccessibilityHint ?? "")
                } label: {
                    Image(systemName: "ellipsis")
                }
                .disabled(viewModel?.activeWriteAction != nil)
                .allowsHitTesting(isToolbarReady)
                .accessibilityHidden(!isToolbarReady)
                .accessibilityLabel("更多操作")
            }
        }
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
}

private struct SourceManagementContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(XMToastCenter.self) private var toastCenter
    @Bindable var viewModel: SourceManagementViewModel
    @Binding var isReordering: Bool
    @Binding var isInlineSearchActive: Bool
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        sourceList
        .safeAreaBar(edge: .top, spacing: 0) {
            scopeSelector
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.half)
        }
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
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
    }

    private var modeTransitionAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
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
        .disabled(viewModel.activeWriteAction != nil || isReordering)
        .accessibilityHint(isReordering ? "完成排序后可切换来源范围" : "")
    }

    @ViewBuilder
    private var sourceSectionContent: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                LoadingStateView("正在加载来源…", style: .inline)
                    .sourceManagementStateRow()
            } else {
                Color.clear.sourceManagementStateRow()
            }
        case .empty:
            XMContentStateView(
                role: .empty,
                title: emptyTitle,
                message: emptyDescription,
                systemImage: emptySystemImage
            )
            .sourceManagementStateRow()
        case .error(let message):
            XMContentStateView(
                role: .failure,
                title: "来源加载失败",
                message: message,
                systemImage: "exclamationmark.triangle"
            )
            .sourceManagementStateRow()
        case .content:
            if viewModel.isSearchResultEmpty {
                XMContentStateView(
                    role: .noResults,
                    title: "没有匹配的来源",
                    message: "未找到与“\(viewModel.normalizedSearchText)”匹配的来源。"
                )
                    .sourceManagementStateRow()
            } else {
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
            }
        }
    }

    private var sourceList: some View {
        List {
            if !isReordering {
                Section {
                    PersonalManagementSearchListRow(
                        text: $viewModel.searchText,
                        isActive: $isInlineSearchActive,
                        prompt: searchPrompt,
                        isEnabled: viewModel.activeWriteAction == nil
                    )
                }
                .listSectionMargins(.horizontal, 0)
            }

            Section {
                sourceSectionContent
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(Spacing.base)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, Spacing.compact, for: .scrollContent)
        .contentMargins(.bottom, Spacing.double, for: .scrollContent)
        .scrollBounceBehavior(.always)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .environment(\.editMode, .constant(isReordering ? EditMode.active : EditMode.inactive))
        .background(Color.surfacePage)
        .animation(modeTransitionAnimation, value: isReordering)
    }

    private var emptyTitle: String {
        switch viewModel.selectedScope {
        case .mine:
            return "暂无我的来源"
        case .appDefault:
            return "暂无默认来源"
        }
    }

    private var searchPrompt: String {
        switch viewModel.selectedScope {
        case .mine:
            return "搜索我的来源"
        case .appDefault:
            return "搜索默认来源"
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

private extension View {
    /// 统一来源加载、空态和失败态的列表占位，保证控制区在状态变化时保持可见。
    func sourceManagementStateRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 260)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
