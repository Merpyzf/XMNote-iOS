//
//  BookGridView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

/**
 * [INPUT]: 依赖 BookViewModel 提供书架快照、维度状态、搜索态、显示设置、编辑态与拖拽排序状态，依赖页面可见态驱动 UIKit 滚动观察，依赖 LoadingGate 约束读取加载反馈
 * [OUTPUT]: 对外提供 BookGridView，展示默认书架、多维度只读聚合入口、默认书架编辑态、排序置顶入口与拖拽排序交互
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

    private let aggregateColumns = Array(
        repeating: GridItem(.flexible(), spacing: Spacing.base),
        count: 2
    )

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
                    moveDisabledReason: viewModel.moveDisabledReason,
                    activeAction: viewModel.activeWriteAction,
                    onPin: viewModel.pinSelectedItems,
                    onMove: { showsMoveSheet = true }
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
        .onAppear {
            syncReadLoadingGate()
        }
        .onChange(of: viewModel.contentState) { _, _ in
            syncReadLoadingGate()
        }
        .onDisappear {
            viewModel.cancelReorderSession()
            readLoadingGate.hideImmediately()
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
            defaultContent(viewModel.snapshot.defaultItems)
        case .status:
            sectionContent(viewModel.snapshot.statusSections)
        case .tag:
            aggregateContent(viewModel.snapshot.tagGroups)
        case .source:
            aggregateContent(viewModel.snapshot.sourceGroups)
        case .rating:
            sectionContent(viewModel.snapshot.ratingSections)
        case .author:
            authorContent(viewModel.snapshot.authorSections)
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
    private func defaultContent(_ items: [BookshelfItem]) -> some View {
        BookshelfDefaultCollectionView(
            items: items,
            layoutMode: viewModel.displaySetting.layoutMode,
            columnCount: viewModel.displaySetting.columnCount,
            showsNoteCount: viewModel.displaySetting.showsNoteCount,
            isEditing: viewModel.isEditing,
            selectedIDs: viewModel.selectedIDSet,
            canReorder: viewModel.canReorderDefaultItems,
            isScrollObservationEnabled: isDefaultScrollObservationEnabled,
            activeWriteAction: viewModel.activeWriteAction,
            movableIDs: movableIDs(in: items),
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

    private func aggregateContent(_ groups: [BookshelfAggregateGroup]) -> some View {
        ScrollView {
            LazyVGrid(columns: aggregateColumns, spacing: Spacing.base) {
                ForEach(groups) { group in
                    NavigationLink(value: BookRoute.bookshelfList(route(for: group))) {
                        BookshelfAggregateCardView(group: group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
    }

    private func sectionContent(_ sections: [BookshelfSection]) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.base) {
                ForEach(sections) { section in
                    NavigationLink(value: BookRoute.bookshelfList(route(for: section))) {
                        BookshelfSectionCardView(section: section)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
    }

    private func authorContent(_ sections: [BookshelfAuthorSection]) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.section) {
                        ForEach(sections) { section in
                            authorSection(section)
                                .id(section.id)
                        }
                    }
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.trailing, Spacing.double)
                    .padding(.vertical, Spacing.base)
                }

                VStack(spacing: Spacing.tiny) {
                    ForEach(sections) { section in
                        Button {
                            withAnimation(.snappy(duration: 0.22, extraBounce: 0.04)) {
                                proxy.scrollTo(section.id, anchor: .top)
                            }
                        } label: {
                            Text(section.title)
                                .font(AppTypography.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(Color.brand)
                                .frame(width: 22, height: 18)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, Spacing.tiny)
            }
        }
    }

    private func authorSection(_ section: BookshelfAuthorSection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(section.title)
                .font(AppTypography.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .padding(.leading, Spacing.tiny)

            LazyVGrid(columns: aggregateColumns, spacing: Spacing.base) {
                ForEach(section.authors) { author in
                    NavigationLink(value: BookRoute.bookshelfList(route(for: author))) {
                        BookshelfAggregateCardView(group: author)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func route(for group: BookshelfAggregateGroup) -> BookshelfBookListRoute {
        BookshelfBookListRoute(
            title: group.title,
            subtitle: group.subtitle,
            books: group.books
        )
    }

    private func route(for section: BookshelfSection) -> BookshelfBookListRoute {
        BookshelfBookListRoute(
            title: section.title,
            subtitle: section.subtitle,
            books: section.books.map { BookshelfBookListItem(payload: $0) }
        )
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
