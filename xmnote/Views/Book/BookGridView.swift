//
//  BookGridView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

/**
 * [INPUT]: 依赖 BookViewModel、AppNavigationCoordinator、页面可见态、LoadingGate、Reicon 整理入口、InteractionMetrics 与容器注入的浏览/搜索/编辑回调
 * [OUTPUT]: 对外提供 BookGridView，展示书籍子页维度工具行、书架内容区、集合顶部搜索 drawer、多维度 UICollectionView 聚合入口、选择覆盖层、搜索空态、写入错误浮层与拖拽排序交互
 * [POS]: Book 模块网格展示层，被 BookContainerView 嵌入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

private enum BookGridToolbarMetrics {
    static let dimensionRailHeight: CGFloat = InteractionMetrics.minimumTouchTarget
}

private enum BookshelfDimensionManagementAction {
    case tag
    case source
    case author
    case press

    var title: String {
        switch self {
        case .tag:
            return "标签管理"
        case .source:
            return "来源管理"
        case .author:
            return "作者管理"
        case .press:
            return "出版社管理"
        }
    }

    var systemImage: String {
        switch self {
        case .tag:
            return "tag"
        case .source:
            return "tray.full"
        case .author:
            return "person.text.rectangle"
        case .press:
            return "building.2"
        }
    }
}

private extension BookshelfDimension {
    var managementAction: BookshelfDimensionManagementAction? {
        switch self {
        case .tag:
            return .tag
        case .source:
            return .source
        case .author:
            return .author
        case .press:
            return .press
        case .default, .status, .rating:
            return nil
        }
    }
}

/// 书籍页内容视图，负责书架多维度只读渲染、选择覆盖层与排序交互。
struct BookGridView: View {
    @Bindable var viewModel: BookViewModel
    var isPageActive = true
    var bottomContentInset: CGFloat = 0
    var hasSearchKeyword = false
    var searchDrawerHeight: CGFloat = 0
    var searchPresentation: BookshelfSearchDrawerPresentation = .hidden
    var isSearchPresented = false
    var isSearchFocused = false
    var searchText = ""
    var searchKeyword = ""
    var searchPlaceholder = ""
    var searchFocusTrigger = 0
    var canShowSelectAction = false
    var canEditCurrentDimension = false
    var onActivateSearch: () -> Void = {}
    var onRequestSearchFocus: () -> Void = {}
    var onSearchKeywordChange: (String) -> Void = { _ in }
    var onSubmitSearch: (String) -> Void = { _ in }
    var onClearSearch: () -> Void = {}
    var onCancelSearch: () -> Void = {}
    var onSearchFocusChange: (Bool) -> Void = { _ in }
    var onOpenRoute: (BookRoute) -> Void = { _ in }
    var onOpenNoteRoute: (NoteRoute) -> Void = { _ in }
    var onEnterEditing: (BookshelfItemID?) -> Void = { _ in }
    var onShowDisplaySettings: () -> Void = {}
    var onOpenTagManagement: () -> Void = {}
    var onOpenSourceManagement: () -> Void = {}
    var onOpenAuthorManagement: () -> Void = {}
    var onOpenPressManagement: () -> Void = {}
    var onOpenGuide: () -> Void = {}
    @State private var readLoadingGate = LoadingGate()
    @State private var hasPresentedInitialContent = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: Spacing.none) {
                if showsDimensionToolbar {
                    dimensionToolRow
                        .frame(height: BookGridToolbarMetrics.dimensionRailHeight)
                        .transition(BookshelfManagementMotion.browsingChromeTransition(reduceMotion: reduceMotion))
                }

                gridContent
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let writeError = viewModel.writeError, !writeError.isEmpty {
                writeErrorHint(writeError)
                    .padding(.top, showsDimensionToolbar ? BookGridToolbarMetrics.dimensionRailHeight : Spacing.none)
            } else if let observationErrorMessage = viewModel.observationErrorMessage {
                XMInlineStatusBanner(
                    observationErrorMessage,
                    tone: .error,
                    action: XMStateAction("重试", perform: viewModel.retryObservation)
                )
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.cozy)
                .padding(.top, showsDimensionToolbar ? BookGridToolbarMetrics.dimensionRailHeight : Spacing.none)
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .xmSystemAlert(item: $viewModel.activeContributorNameEdit) { nameEdit in
            contributorNameEditDescriptor(for: nameEdit)
        }
        .xmSystemAlert(item: $viewModel.activeContributorDeleteConfirmation) { confirmation in
            contributorDeleteDescriptor(for: confirmation)
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: viewModel.selectedDimension)
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

    // MARK: - Grid Content

    private func syncReadLoadingGate() {
        readLoadingGate.update(intent: viewModel.contentState == .loading ? .read : .none)
    }

    private var showsDimensionToolbar: Bool {
        !viewModel.isEditing
    }

    private var dimensionToolRow: some View {
        HStack(spacing: Spacing.none) {
            BookshelfDimensionRail(
                selectedDimension: viewModel.selectedDimension,
                onSelect: viewModel.selectDimension,
                trailingPadding: Spacing.none
            )
            .frame(maxWidth: .infinity)

            bookshelfToolMenu
                .padding(.leading, Spacing.tight)
                .padding(.trailing, Spacing.screenEdge)
        }
        .accessibilityElement(children: .contain)
    }

    private var bookshelfToolMenu: some View {
        Menu {
            if viewModel.selectedDimension == .default {
                Button {
                    onEnterEditing(nil)
                } label: {
                    BookshelfEditingMenuLabel(title: "书籍整理", icon: .checklist)
                }
                .disabled(!canShowSelectAction || !canEditCurrentDimension)
            }

            if let managementAction = viewModel.selectedDimension.managementAction {
                Button(action: managementActionHandler(for: managementAction)) {
                    XMMenuLabel(managementAction.title, systemImage: managementAction.systemImage)
                }
            }

            Button(action: onShowDisplaySettings) {
                XMMenuLabel("显示与排序", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button(action: onOpenGuide) {
                XMMenuLabel("使用说明", systemImage: "questionmark.circle")
            }
        } label: {
            BookshelfToolMenuButton()
        }
        .xmMenuNeutralTint()
        .menuOrder(.fixed)
        .accessibilityLabel("书架更多操作")
    }

    private func managementActionHandler(for action: BookshelfDimensionManagementAction) -> () -> Void {
        switch action {
        case .tag:
            return onOpenTagManagement
        case .source:
            return onOpenSourceManagement
        case .author:
            return onOpenAuthorManagement
        case .press:
            return onOpenPressManagement
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                BookshelfLoadingSkeletonView(
                    layoutMode: viewModel.displaySetting.layoutMode,
                    columnCount: viewModel.displaySetting.columnCount,
                    bottomContentInset: bottomContentInset
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .empty:
            if hasSearchKeyword {
                dimensionCollectionContent
            } else {
                emptyStateView
            }
        case .error:
            XMContentStateView(
                role: .failure,
                title: "暂时无法加载书架",
                action: XMStateAction("重试", perform: viewModel.retryObservation)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            dimensionCollectionContent
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        if hasSearchKeyword {
            XMContentStateView(
                role: .noResults,
                title: "没有匹配的书籍"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            XMContentStateView(
                role: .empty,
                title: "暂无书籍"
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var dimensionCollectionContent: some View {
        dimensionContent
            .transaction { transaction in
                guard !hasPresentedInitialContent else { return }
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .onAppear {
                guard !hasPresentedInitialContent else { return }
                hasPresentedInitialContent = true
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

    private func writeErrorHint(_ message: String) -> some View {
        XMInlineStatusBanner(
            message,
            tone: .warning,
            systemImage: "exclamationmark.triangle.fill"
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .zIndex(2)
    }

    @ViewBuilder
    private func defaultContent(_ sections: [BookshelfDefaultSection]) -> some View {
        BookshelfDefaultCollectionView(
            sections: sections,
            layoutMode: viewModel.displaySetting.layoutMode,
            columnCount: viewModel.displaySetting.columnCount,
            contentState: viewModel.contentState,
            showsNoteCount: viewModel.displaySetting.showsNoteCount,
            sortCriteria: viewModel.displaySetting.sortCriteria,
            titleDisplayMode: viewModel.displaySetting.titleDisplayMode,
            allowsStructuralAnimation: hasPresentedInitialContent,
            isPageActive: isPageActive,
            isEditing: viewModel.isEditing,
            bottomContentInset: bottomContentInset,
            searchDrawerHeight: searchDrawerHeight,
            searchPresentation: searchPresentation,
            isSearchPresented: isSearchPresented,
            isSearchFocused: isSearchFocused,
            searchText: searchText,
            searchKeyword: searchKeyword,
            searchPlaceholder: searchPlaceholder,
            searchFocusTrigger: searchFocusTrigger,
            selectedIDs: viewModel.selectedIDSet,
            canReorder: viewModel.canReorderDefaultItems,
            isScrollObservationEnabled: isDefaultScrollObservationEnabled,
            activeWriteAction: viewModel.activeWriteAction,
            movableIDs: movableIDs(in: sections.flatMap(\.items)),
            onActivateSearch: onActivateSearch,
            onRequestSearchFocus: onRequestSearchFocus,
            onSearchKeywordChange: onSearchKeywordChange,
            onSubmitSearch: onSubmitSearch,
            onClearSearch: onClearSearch,
            onCancelSearch: onCancelSearch,
            onSearchFocusChange: onSearchFocusChange,
            onOpenRoute: onOpenRoute,
            onToggleSelection: viewModel.toggleSelection,
            onEnterEditing: enterEditing,
            onPin: viewModel.pinItem,
            onUnpin: viewModel.unpinItem,
            onMoveToStart: viewModel.moveItemToStart,
            onMoveToEnd: viewModel.moveItemToEnd,
            onContextAction: handleContextAction(_:itemID:),
            onCommitOrder: viewModel.commitDefaultItemsOrder
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
            contentState: viewModel.contentState,
            allowsStructuralAnimation: hasPresentedInitialContent,
            isPageActive: isPageActive,
            searchDrawerHeight: searchDrawerHeight,
            searchPresentation: searchPresentation,
            isSearchPresented: isSearchPresented,
            isSearchFocused: isSearchFocused,
            searchText: searchText,
            searchKeyword: searchKeyword,
            searchPlaceholder: searchPlaceholder,
            searchFocusTrigger: searchFocusTrigger,
            canReorder: viewModel.canReorderAggregateItems(for: dimension),
            onActivateSearch: onActivateSearch,
            onRequestSearchFocus: onRequestSearchFocus,
            onSearchKeywordChange: onSearchKeywordChange,
            onSubmitSearch: onSubmitSearch,
            onClearSearch: onClearSearch,
            onCancelSearch: onCancelSearch,
            onSearchFocusChange: onSearchFocusChange,
            onOpenRoute: onOpenRoute,
            onContextAction: handleAggregateContextAction(_:group:),
            onCommitOrder: { viewModel.commitAggregateOrder($0, for: dimension) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
            return horizontalSizeClass == .regular ? 4 : 3
        case .default, .status, .tag, .source, .rating:
            return max(2, min(viewModel.displaySetting.columnCount, 3))
        }
    }

    private func movableIDs(in items: [BookshelfItem]) -> Set<BookshelfItemID> {
        Set(items.compactMap { item in
            viewModel.canMoveItem(item.id) ? item.id : nil
        })
    }

    private func enterEditing(_ initialSelection: BookshelfItemID) {
        onEnterEditing(initialSelection)
    }

    private func handleContextAction(_ action: BookshelfBookContextAction, itemID: BookshelfItemID) {
        switch action {
        case .addNote:
            guard case .book(let bookID) = itemID else { return }
            navigationCoordinator.present(
                .noteEditor(
                    mode: .create,
                    seed: NoteEditorSeed(
                        bookId: bookID,
                        chapterId: nil,
                        contentHTML: "",
                        ideaHTML: ""
                    )
                )
            )
        case .pin:
            viewModel.pinItem(itemID)
        case .unpin:
            viewModel.unpinItem(itemID)
        case .editBook:
            guard case .book(let bookID) = itemID else { return }
            navigationCoordinator.present(.bookEditor(.edit(bookId: bookID)))
        case .showReadingDetail:
            viewModel.presentContextPlaceholder("阅读详情将在阅读模块迁移后开放")
        case .startReadTiming:
            viewModel.presentContextPlaceholder("开始计时将在阅读模块迁移后开放")
        case .organizeBooks:
            onEnterEditing(nil)
        case .delete:
            viewModel.presentDeleteConfirmation(for: itemID)
        }
    }

    private func handleAggregateContextAction(
        _ action: BookshelfAggregateContextAction,
        group: BookshelfAggregateGroup
    ) {
        switch action {
        case .edit:
            viewModel.presentContributorNameEdit(for: group)
        case .delete:
            viewModel.presentContributorDeleteConfirmation(for: group)
        }
    }

    private func contributorNameEditDescriptor(for nameEdit: BookContributorNameEdit) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "编辑\(nameEdit.kind.itemTitle)",
            message: "将同步更新 \(nameEdit.bookCount) 本书的\(nameEdit.kind.itemTitle)名称。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "完成") {
                    viewModel.submitContributorNameEdit()
                }
            ],
            textFields: [
                XMSystemAlertTextField(
                    text: Binding(
                        get: { viewModel.contributorNameEditText },
                        set: { viewModel.contributorNameEditText = $0 }
                    ),
                    placeholder: nameEdit.currentName,
                    autocorrectionDisabled: true
                )
            ]
        )
    }

    private func contributorDeleteDescriptor(for confirmation: BookContributorDeleteConfirmation) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "删除\(confirmation.kind.itemTitle)",
            message: "将删除“\(confirmation.name)”下的 \(confirmation.bookCount) 本书，并移除对应\(confirmation.kind.itemTitle)资料。此操作不可撤销。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    viewModel.submitContributorDelete()
                }
            ],
            preferredActionID: nil
        )
    }
}

/// 书架维度 rail 右侧固定的末尾 chip，保持 44pt 热区并对齐未选中维度项。
private struct BookshelfToolMenuButton: View {
    private enum Style {
        static let hitSize = InteractionMetrics.minimumTouchTarget
        static let visualWidth: CGFloat = 32
        static let visualHeight: CGFloat = 28
        static let cornerRadius = CornerRadius.blockSmall
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .fill(Color.surfaceCard)

            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.18), lineWidth: StrokeWidth.hairline)

            BookshelfMoreGlyph()
        }
        .frame(width: Style.visualWidth, height: Style.visualHeight)
        .frame(width: Style.hitSize, height: Style.hitSize)
        .contentShape(Rectangle())
    }
}

/// 自绘竖向三点，避免 SF Symbol 旋转或 `ellipsis.vertical` 在菜单 label 中显示不稳定。
private struct BookshelfMoreGlyph: View {
    private enum Style {
        static let dotSize: CGFloat = 3
        static let dotSpacing: CGFloat = 2.5
    }

    var body: some View {
        VStack(spacing: Style.dotSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.iconSecondary)
                    .frame(width: Style.dotSize, height: Style.dotSize)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        BookGridView(viewModel: BookViewModel(repository: repositories.bookRepository))
    }
}
