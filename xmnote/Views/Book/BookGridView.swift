//
//  BookGridView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

/**
 * [INPUT]: 依赖 BookViewModel 提供书架快照、维度状态、搜索态、显示设置、编辑态与拖拽排序状态
 * [OUTPUT]: 对外提供 BookGridView，展示默认书架、多维度只读聚合骨架、默认书架编辑态与排序置顶入口
 * [POS]: Book 模块网格展示层，被 BookContainerView 嵌入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍页内容视图，负责维度 rail、搜索态提示与书架多维度只读渲染。
struct BookGridView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: BookViewModel
    @State private var itemFrames: [BookshelfItemID: CGRect] = [:]

    private static let gridCoordinateSpace = "book-grid-reorder-space"

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Spacing.screenEdge),
            count: max(2, min(viewModel.displaySetting.columnCount, 4))
        )
    }

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
                    activeAction: viewModel.activeWriteAction,
                    onPin: viewModel.pinSelectedItems,
                    onMoveToStart: viewModel.moveSelectedItemsToStart,
                    onMoveToEnd: viewModel.moveSelectedItemsToEnd
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Grid Content

    @ViewBuilder
    private var gridContent: some View {
        switch viewModel.contentState {
        case .loading:
            LoadingStateView("正在整理书架", style: .inline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        switch viewModel.displaySetting.layoutMode {
        case .grid:
            bookshelfGrid(items)
        case .list:
            bookshelfList(items)
        }
    }

    private func bookshelfGrid(_ items: [BookshelfItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Spacing.section) {
                ForEach(items) { item in
                    gridItem(item)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BookshelfItemFramePreferenceKey.self,
                                    value: [item.id: proxy.frame(in: .named(Self.gridCoordinateSpace))]
                                )
                            }
                        }
                }
            }
            .coordinateSpace(name: Self.gridCoordinateSpace)
            .onPreferenceChange(BookshelfItemFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .padding(.bottom, viewModel.isEditing ? 84 : 0)
        }
    }

    private func bookshelfList(_ items: [BookshelfItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.base) {
                ForEach(items) { item in
                    defaultListItem(item)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .padding(.bottom, viewModel.isEditing ? 84 : 0)
        }
    }

    private func aggregateContent(_ groups: [BookshelfAggregateGroup]) -> some View {
        ScrollView {
            LazyVGrid(columns: aggregateColumns, spacing: Spacing.base) {
                ForEach(groups) { group in
                    BookshelfAggregateCardView(group: group)
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
                    BookshelfSectionCardView(section: section)
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
                    BookshelfAggregateCardView(group: author)
                }
            }
        }
    }

    @ViewBuilder
    private func gridItem(_ item: BookshelfItem) -> some View {
        if viewModel.isEditing {
            Button {
                viewModel.toggleSelection(item.id)
            } label: {
                editableGridItemLabel(item)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(reorderGesture(for: item))
            .accessibilityLabel("\(item.title)，\(viewModel.selectedIDSet.contains(item.id) ? "已选中" : "未选中")")
        } else {
            switch item.content {
            case .book(let book):
                NavigationLink(value: BookRoute.detail(bookId: book.id)) {
                    BookGridItemView(book: book, showsNoteCount: viewModel.displaySetting.showsNoteCount)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    itemContextMenu(for: item)
                }
            case .group(let group):
                BookshelfGroupGridItemView(group: group)
                    .contextMenu {
                        itemContextMenu(for: item)
                    }
            }
        }
    }

    @ViewBuilder
    private func defaultListItem(_ item: BookshelfItem) -> some View {
        if viewModel.isEditing {
            Button {
                viewModel.toggleSelection(item.id)
            } label: {
                editableListItemLabel(item)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title)，\(viewModel.selectedIDSet.contains(item.id) ? "已选中" : "未选中")")
        } else {
            switch item.content {
            case .book(let book):
                NavigationLink(value: BookRoute.detail(bookId: book.id)) {
                    BookshelfDefaultListRow(
                        item: item,
                        showsNoteCount: viewModel.displaySetting.showsNoteCount
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    itemContextMenu(for: item)
                }
            case .group:
                BookshelfDefaultListRow(
                    item: item,
                    showsNoteCount: viewModel.displaySetting.showsNoteCount
                )
                .contextMenu {
                    itemContextMenu(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func editableGridItemLabel(_ item: BookshelfItem) -> some View {
        switch item.content {
        case .book(let book):
            selectableItemShell(item) {
                BookGridItemView(book: book, showsNoteCount: viewModel.displaySetting.showsNoteCount)
            }
        case .group(let group):
            selectableItemShell(item) {
                BookshelfGroupGridItemView(group: group)
            }
        }
    }

    private func editableListItemLabel(_ item: BookshelfItem) -> some View {
        selectableItemShell(item) {
            BookshelfDefaultListRow(
                item: item,
                showsNoteCount: viewModel.displaySetting.showsNoteCount
            )
        }
    }

    private func selectableItemShell<Content: View>(
        _ item: BookshelfItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSelected = viewModel.selectedIDSet.contains(item.id)
        let isDragged = viewModel.draggedItemID == item.id
        let isTargeted = viewModel.dragTargetItemID == item.id && viewModel.draggedItemID != item.id
        return content()
            .opacity(isDragged ? 0.58 : (isSelected ? 1 : 0.78))
            .scaleEffect(isDragged ? 1.035 : 1)
            .shadow(color: Color.black.opacity(isDragged ? 0.14 : 0), radius: isDragged ? 14 : 0, y: isDragged ? 7 : 0)
            .zIndex(isDragged ? 2 : 0)
            .overlay(alignment: .topTrailing) {
                BookshelfSelectionOverlay(isSelected: isSelected)
            }
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .stroke(
                        isTargeted ? Color.brand : (isSelected ? Color.brand.opacity(0.72) : Color.clear),
                        style: StrokeStyle(lineWidth: (isTargeted || isSelected) ? 1.5 : 0, dash: isTargeted ? [5, 4] : [])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
    }

    @ViewBuilder
    private func itemContextMenu(for item: BookshelfItem) -> some View {
        Button {
            viewModel.enterEditing(initialSelection: item.id)
        } label: {
            Label("选择", systemImage: "checkmark.circle")
        }

        Divider()

        if item.pinned {
            Button {
                viewModel.unpinItem(item.id)
            } label: {
                Label("取消置顶", systemImage: "pin.slash")
            }
            .disabled(viewModel.activeWriteAction != nil)
        } else {
            Button {
                viewModel.pinItem(item.id)
            } label: {
                Label("置顶", systemImage: "pin")
            }
            .disabled(viewModel.activeWriteAction != nil)

            Button {
                viewModel.moveItemToStart(item.id)
            } label: {
                Label("移到最前", systemImage: "arrow.up.to.line")
            }
            .disabled(viewModel.activeWriteAction != nil)

            Button {
                viewModel.moveItemToEnd(item.id)
            } label: {
                Label("移到最后", systemImage: "arrow.down.to.line")
            }
            .disabled(viewModel.activeWriteAction != nil)
        }

        Button { } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .disabled(true)

        Button(role: .destructive) { } label: {
            Label("删除", systemImage: "trash")
        }
        .disabled(true)
    }

    private var reorderAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .snappy(duration: 0.22, extraBounce: 0.04)
    }

    private func reorderGesture(for item: BookshelfItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridCoordinateSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    viewModel.beginReorder(itemID: item.id)
                case .second(true, let drag):
                    guard let drag else { return }
                    withAnimation(reorderAnimation) {
                        viewModel.updateReorder(
                            itemID: item.id,
                            location: drag.location,
                            itemFrames: itemFrames
                        )
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                withAnimation(reorderAnimation) {
                    viewModel.endReorder(itemID: item.id)
                }
            }
    }
}

private struct BookshelfItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [BookshelfItemID: CGRect] = [:]

    static func reduce(
        value: inout [BookshelfItemID: CGRect],
        nextValue: () -> [BookshelfItemID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        BookGridView(viewModel: BookViewModel(repository: repositories.bookRepository))
    }
}
