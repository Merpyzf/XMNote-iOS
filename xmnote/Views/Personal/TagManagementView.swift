/**
 * [INPUT]: 依赖 RepositoryContainer 注入 TagManagementRepositoryProtocol，依赖 TagManagementViewModel 驱动标签管理状态，依赖 XMScopeSelector/XMSystemAlert/LoadingGate 渲染 iOS 原生管理交互
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
    @Bindable var viewModel: TagManagementViewModel
    @State private var readLoadingGate = LoadingGate()
    @State private var isSearchPresented = false
    @State private var isReordering = false
    @State private var scrollEdgeWashEdges = XMScrollEdgeWashEdges.hidden

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: Spacing.base) {
                scopeSelector
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.base)
                content
            }

            if let message = viewModel.writeError ?? viewModel.actionNotice {
                notice(message)
            }
        }
        .searchable(
            text: $viewModel.searchText,
            isPresented: $isSearchPresented,
            prompt: "搜索"
        )
        .toolbar(removing: isNormalMode ? nil : .search)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: Spacing.none) {
            if viewModel.isSelectionMode {
                selectionBottomChrome
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.22), value: viewModel.isSelectionMode)
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
            isSearchPresented = false
            viewModel.clearSearchText()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
            viewModel.clearSearchText()
            scrollEdgeWashEdges = .hidden
        }
    }

    private var isNormalMode: Bool {
        !viewModel.isSelectionMode && !isReordering
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
            isSelectionMode: viewModel.isSelectionMode,
            isReordering: isReordering,
            selectedTagIDs: viewModel.selectedTagIDs,
            isDisabled: viewModel.activeWriteAction != nil,
            bottomContentInset: contentBottomInset,
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

    private var contentBottomInset: CGFloat {
        if viewModel.isSelectionMode {
            return TagManagementBottomBarMetrics.selectionContentInset
        }
        return 0
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewModel.isSelectionMode {
            ToolbarItem(placement: .topBarTrailing) {
                Button("取消") {
                    viewModel.exitSelectionMode()
                }
                .disabled(viewModel.activeWriteAction != nil)
                .xmToolbarNeutralTint()
            }
        } else if isReordering {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    isReordering = false
                }
                .disabled(viewModel.activeWriteAction == .reorder)
                .xmToolbarNeutralTint()
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        viewModel.enterSelectionMode()
                    } label: {
                        XMMenuLabel("选择标签", systemImage: "checklist")
                    }
                    .disabled(!viewModel.canEnterSelectionMode)

                    Button {
                        isReordering = true
                        isSearchPresented = false
                        viewModel.clearSearchText()
                    } label: {
                        XMMenuLabel("调整顺序", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(!viewModel.canEnterReorder)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .disabled(viewModel.activeWriteAction != nil)
                .xmToolbarNeutralTint()
                .accessibilityLabel("更多操作")
            }

            DefaultToolbarItem(kind: .search, placement: .bottomBar)

            ToolbarSpacer(placement: .bottomBar)

            ToolbarItem(placement: .bottomBar) {
                Button {
                    viewModel.presentCreateSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.activeWriteAction != nil)
                .xmToolbarNeutralTint()
                .accessibilityLabel("添加标签")
            }
        }
    }

    private var selectionBottomChrome: some View {
        VStack(spacing: Spacing.none) {
            LinearGradient(
                colors: [
                    Color.surfacePage.opacity(0),
                    Color.surfacePage.opacity(0.82),
                    Color.surfacePage
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Spacing.double)
            .allowsHitTesting(false)

            TagManagementSelectionBottomBar(
                selectedCount: viewModel.selectedTagIDs.count,
                isBusy: viewModel.activeWriteAction != nil,
                notice: viewModel.actionNotice,
                onCancel: { viewModel.exitSelectionMode() },
                onDelete: { viewModel.presentDeleteConfirmationForSelection() }
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.base)
        }
        .background(Color.surfacePage)
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

    private func notice(_ message: String) -> some View {
        Text(message)
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.tight)
            .background(Color.surfaceCard)
            .overlay(alignment: .bottom) {
                Divider()
                    .overlay(Color.surfaceBorderSubtle)
            }
            .transition(.opacity)
            .zIndex(2)
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
    static let destructiveButtonSize: CGFloat = 50
    static let selectionContentInset: CGFloat = 96
}

private enum TagManagementLayoutMetrics {
    static let gridTopWashStyle = XMScrollEdgeWashStyle(
        height: 28,
        strength: .regular,
        surface: .page
    )
}

private struct TagManagementSelectionBottomBar: View {
    let selectedCount: Int
    let isBusy: Bool
    let notice: String?
    let onCancel: () -> Void
    let onDelete: () -> Void

    private var statusText: String? {
        if let notice, !notice.isEmpty {
            return notice
        }
        return selectedCount > 0 ? "已选择 \(selectedCount) 个标签" : "请选择标签"
    }

    var body: some View {
        VStack(spacing: Spacing.tight) {
            if let statusText {
                Text(statusText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    Button(action: onCancel) {
                        Text("取消")
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)
                            .frame(minWidth: 74, minHeight: TagManagementBottomBarMetrics.controlHeight)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button(role: .destructive, action: onDelete) {
                        ImmersiveBottomChromeIcon(
                            systemName: "trash",
                            foregroundStyle: selectedCount > 0 && !isBusy ? Color.feedbackError : Color.textHint
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedCount == 0 || isBusy)
                    .frame(
                        width: TagManagementBottomBarMetrics.destructiveButtonSize,
                        height: TagManagementBottomBarMetrics.destructiveButtonSize
                    )
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel(selectedCount > 0 && !isBusy ? "删除" : "删除，当前不可用")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        TagManagementView()
            .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    }
}
