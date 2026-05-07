//
//  BookGridView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

/**
 * [INPUT]: 依赖 BookViewModel 提供书架快照、维度状态、搜索态、显示设置、编辑态与 UICollectionView 排序状态，依赖页面可见态驱动 UIKit 滚动观察，依赖 LoadingGate 约束读取加载反馈
 * [OUTPUT]: 对外提供 BookGridView，展示默认书架、多维度 UICollectionView 聚合入口、默认书架编辑态、排序置顶入口与拖拽排序交互
 * [POS]: Book 模块网格展示层，被 BookContainerView 嵌入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍页内容视图，负责维度 rail、搜索态提示与书架多维度只读渲染。
struct BookGridView: View {
    @Bindable var viewModel: BookViewModel
    var isPageActive = true
    var onOpenRoute: (BookRoute) -> Void = { _ in }
    @State private var readLoadingGate = LoadingGate()
    @State private var showsMoveSheet = false

    var body: some View {
        VStack(spacing: Spacing.compact) {
            if viewModel.isEditing {
                BookshelfEditHeader(
                    selectedCount: viewModel.selectedCount,
                    isAllVisibleSelected: viewModel.isAllVisibleSelected,
                    onCancel: viewModel.exitEditing,
                    onSelectAll: viewModel.selectAllVisible,
                    onInvertSelection: viewModel.invertVisibleSelection
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if viewModel.isSearchActive {
                BookshelfSearchBar(
                    text: $viewModel.searchKeyword,
                    onCancel: viewModel.deactivateSearch,
                    onClear: viewModel.clearSearchKeyword
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !viewModel.isEditing {
                BookshelfDimensionRail(
                    selectedDimension: viewModel.selectedDimension,
                    onSelect: viewModel.selectDimension
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if viewModel.hasSearchKeyword, !viewModel.isEditing {
                searchHint
            }

            if let writeError = viewModel.writeError, !writeError.isEmpty {
                writeErrorHint(writeError)
            }

            gridContent
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: viewModel.isSearchActive)
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: viewModel.isEditing)
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: viewModel.selectedDimension)
        .safeAreaInset(edge: .bottom, spacing: Spacing.none) {
            if viewModel.isEditing {
                BookshelfEditBottomBar(
                    selectedCount: viewModel.selectedCount,
                    canPin: viewModel.canSubmitSelectedPin,
                    canMove: viewModel.canMoveSelectedItems,
                    canMore: viewModel.canMoreSelectedItems,
                    canDelete: viewModel.canDeleteSelectedItems,
                    moveDisabledReason: viewModel.moveDisabledReason,
                    activeAction: viewModel.activeWriteAction,
                    moreActions: viewModel.defaultMoreActions,
                    isLoadingOptions: viewModel.isLoadingBatchOptions,
                    notice: viewModel.actionNotice,
                    onPin: viewModel.pinSelectedItems,
                    onMove: { showsMoveSheet = true },
                    onMoreAction: viewModel.performMoreAction,
                    onDelete: viewModel.presentDeleteConfirmation
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showsMoveSheet) {
            BookshelfMoveSheet(
                selectedCount: viewModel.selectedCount,
                canSubmit: viewModel.canMoveSelectedItems,
                disabledReason: viewModel.moveDisabledReason,
                activeAction: viewModel.activeWriteAction,
                onMoveToStart: {
                    showsMoveSheet = false
                    viewModel.moveSelectedItemsToStart()
                },
                onMoveToEnd: {
                    showsMoveSheet = false
                    viewModel.moveSelectedItemsToEnd()
                }
            )
        }
        .sheet(item: $viewModel.activeBatchSheet) { sheet in
            switch sheet {
            case .tags(
                options: let options,
                initialSelectedIDs: let initialSelectedIDs,
                allowsEmptySelection: let allowsEmptySelection
            ):
                BookshelfBatchTagsSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    initialSelectedIDs: initialSelectedIDs,
                    allowsEmptySelection: allowsEmptySelection,
                    onConfirm: viewModel.submitBatchTags
                )
            case .source(options: let options, initialSelectedID: let initialSelectedID):
                BookshelfBatchSourceSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    initialSelectedID: initialSelectedID,
                    onConfirm: viewModel.submitBatchSource
                )
            case .readStatus(
                options: let options,
                initialStatusID: let initialStatusID,
                initialChangedAt: let initialChangedAt,
                initialRatingScore: let initialRatingScore
            ):
                BookshelfBatchReadStatusSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    initialStatusID: initialStatusID,
                    initialChangedAt: initialChangedAt,
                    initialRatingScore: initialRatingScore,
                    onConfirm: viewModel.submitBatchReadStatus
                )
            case .moveGroup(options: let options):
                BookshelfMoveGroupSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    onConfirm: viewModel.submitMoveToGroup
                )
            }
        }
        .xmSystemAlert(item: $viewModel.activeDeleteConfirmation) { confirmation in
            defaultDeleteDescriptor(for: confirmation)
        }
        .onAppear {
            syncReadLoadingGate()
        }
        .onChange(of: viewModel.contentState) { _, _ in
            syncReadLoadingGate()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func defaultDeleteDescriptor(for confirmation: BookshelfDefaultDeleteConfirmation) -> XMSystemAlertDescriptor {
        if confirmation.groupCount == 0 {
            return XMSystemAlertDescriptor(
                title: "删除书籍",
                message: "将删除已选 \(confirmation.bookCount) 本书，并清理书摘、标签、分组、阅读状态、打卡、书单关系等关联数据。此操作不可撤销。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "删除", role: .destructive) {
                        viewModel.submitDeleteSelectedItems(placement: .end)
                    }
                ]
            )
        }

        let bookText = confirmation.bookCount > 0 ? "\(confirmation.bookCount) 本书" : ""
        let groupText = "\(confirmation.groupCount) 个分组"
        let targetText = [bookText, groupText].filter { !$0.isEmpty }.joined(separator: "和")
        return XMSystemAlertDescriptor(
            title: "删除书架项目",
            message: "将删除已选 \(targetText)。分组内书籍会移回默认书架，请选择它们的位置；此操作不可撤销。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "移到最前并删除", role: .destructive) {
                    viewModel.submitDeleteSelectedItems(placement: .start)
                },
                XMSystemAlertAction(title: "移到最后并删除", role: .destructive) {
                    viewModel.submitDeleteSelectedItems(placement: .end)
                }
            ]
        )
    }

    // MARK: - Grid Content

    private func syncReadLoadingGate() {
        readLoadingGate.update(intent: viewModel.contentState == .loading ? .read : .none)
    }

    @ViewBuilder
    private var gridContent: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                LoadingStateView("正在整理书架", style: .inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .empty:
            EmptyStateView(icon: "book", message: "暂无书籍")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            EmptyStateView(icon: "exclamationmark.triangle", message: message.isEmpty ? "书架加载失败" : message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            dimensionContent
        }
    }

    @ViewBuilder
    private var dimensionContent: some View {
        switch viewModel.selectedDimension {
        case .default:
            defaultContent(viewModel.snapshot.defaultSections)
        case .status:
            aggregateContent(
                sections: [aggregateSection(id: "status", groups: groups(from: viewModel.snapshot.statusSections))],
                dimension: .status
            )
        case .tag:
            aggregateContent(
                sections: [aggregateSection(id: "tag", groups: viewModel.snapshot.tagGroups)],
                dimension: .tag
            )
        case .source:
            aggregateContent(
                sections: [aggregateSection(id: "source", groups: viewModel.snapshot.sourceGroups)],
                dimension: .source
            )
        case .rating:
            aggregateContent(
                sections: [aggregateSection(id: "rating", groups: groups(from: viewModel.snapshot.ratingSections))],
                dimension: .rating
            )
        case .author:
            aggregateContent(
                sections: viewModel.snapshot.authorSections.map {
                    BookshelfAggregateCollectionSection(
                        id: $0.id,
                        title: $0.title.isEmpty ? nil : $0.title,
                        groups: $0.authors
                    )
                },
                dimension: .author
            )
        case .press:
            aggregateContent(
                sections: [aggregateSection(id: "press", groups: viewModel.snapshot.pressGroups)],
                dimension: .press
            )
        }
    }

    private var searchHint: some View {
        Text("搜索结果不支持排序，清除搜索后可调整书架顺序")
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenEdge)
            .transition(.opacity)
    }

    private func writeErrorHint(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppTypography.caption)
                .foregroundStyle(Color.feedbackWarning)
                .padding(.top, 2)

            Text(message)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.feedbackWarning.opacity(0.10))
        .transition(.opacity)
    }

    @ViewBuilder
    private func defaultContent(_ sections: [BookshelfDefaultSection]) -> some View {
        BookshelfDefaultCollectionView(
            sections: sections,
            layoutMode: viewModel.displaySetting.layoutMode,
            columnCount: viewModel.displaySetting.columnCount,
            showsNoteCount: viewModel.displaySetting.showsNoteCount,
            isEditing: viewModel.isEditing,
            selectedIDs: viewModel.selectedIDSet,
            canReorder: viewModel.canReorderDefaultItems,
            isScrollObservationEnabled: isDefaultScrollObservationEnabled,
            activeWriteAction: viewModel.activeWriteAction,
            movableIDs: movableIDs(in: sections.flatMap(\.items)),
            onOpenRoute: onOpenRoute,
            onToggleSelection: viewModel.toggleSelection,
            onEnterEditing: { viewModel.enterEditing(initialSelection: $0) },
            onPin: viewModel.pinItem,
            onUnpin: viewModel.unpinItem,
            onMoveToStart: viewModel.moveItemToStart,
            onMoveToEnd: viewModel.moveItemToEnd,
            onCommitOrder: viewModel.commitDefaultItemsOrder
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var isDefaultScrollObservationEnabled: Bool {
        isPageActive
            && viewModel.selectedDimension == .default
            && viewModel.contentState == .content
            && !viewModel.isSearchActive
            && !viewModel.hasSearchKeyword
    }

    private func aggregateContent(
        sections: [BookshelfAggregateCollectionSection],
        dimension: BookshelfDimension
    ) -> some View {
        BookshelfAggregateCollectionView(
            sections: sections,
            layoutMode: viewModel.displaySetting.layoutMode,
            columnCount: aggregateColumnCount(for: dimension),
            canReorder: viewModel.canReorderAggregateItems(for: dimension),
            onOpenRoute: onOpenRoute,
            onCommitOrder: { viewModel.commitAggregateOrder($0, for: dimension) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func aggregateSection(
        id: String,
        groups: [BookshelfAggregateGroup]
    ) -> BookshelfAggregateCollectionSection {
        BookshelfAggregateCollectionSection(
            id: id,
            title: nil,
            groups: groups
        )
    }

    private func groups(from sections: [BookshelfSection]) -> [BookshelfAggregateGroup] {
        sections.map { section in
            BookshelfAggregateGroup(
                id: section.id,
                title: section.title,
                subtitle: section.subtitle,
                count: section.count,
                context: section.context,
                orderID: section.orderID,
                sortMetadata: section.sortMetadata,
                representativeCovers: section.books.prefix(6).map(\.cover),
                books: section.books.map { BookshelfBookListItem(payload: $0) }
            )
        }
    }

    private func aggregateColumnCount(for dimension: BookshelfDimension) -> Int {
        switch dimension {
        case .author, .press:
            return max(2, min(viewModel.displaySetting.columnCount, 4))
        case .default, .status, .tag, .source, .rating:
            return max(2, min(viewModel.displaySetting.columnCount, 3))
        }
    }

    private func movableIDs(in items: [BookshelfItem]) -> Set<BookshelfItemID> {
        Set(items.compactMap { item in
            viewModel.canMoveItem(item.id) ? item.id : nil
        })
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        BookGridView(viewModel: BookViewModel(repository: repositories.bookRepository))
    }
}
