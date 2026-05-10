//
//  BookGridView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

/**
 * [INPUT]: 依赖 BookViewModel 提供书架快照、维度状态、显示设置、编辑态与 UICollectionView 排序状态，依赖页面可见态驱动 UIKit 滚动观察，依赖 LoadingGate 约束读取加载反馈，依赖容器注入路由、进入编辑态回调与底部滚动余量
 * [OUTPUT]: 对外提供 BookGridView，展示书架内容区、多维度 UICollectionView 聚合入口、选择覆盖层、写入错误浮层与拖拽排序交互
 * [POS]: Book 模块网格展示层，被 BookContainerView 嵌入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍页内容视图，负责书架多维度只读渲染、选择覆盖层与排序交互。
struct BookGridView: View {
    @Bindable var viewModel: BookViewModel
    var isPageActive = true
    var bottomContentInset: CGFloat = 0
    var onOpenRoute: (BookRoute) -> Void = { _ in }
    var onOpenNoteRoute: (NoteRoute) -> Void = { _ in }
    var onEnterEditing: (BookshelfItemID?) -> Void = { _ in }
    @State private var readLoadingGate = LoadingGate()
    @State private var hasPresentedInitialContent = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack(alignment: .top) {
            gridContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let writeError = viewModel.writeError, !writeError.isEmpty {
                writeErrorHint(writeError)
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
            EmptyStateView(icon: "book", message: "暂无书籍")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            EmptyStateView(icon: "exclamationmark.triangle", message: message.isEmpty ? "书架加载失败" : message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
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
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(Color.feedbackWarning.opacity(0.28))
        }
        .transition(.opacity)
        .zIndex(2)
    }

    @ViewBuilder
    private func defaultContent(_ sections: [BookshelfDefaultSection]) -> some View {
        BookshelfDefaultCollectionView(
            sections: sections,
            layoutMode: viewModel.displaySetting.layoutMode,
            columnCount: viewModel.displaySetting.columnCount,
            showsNoteCount: viewModel.displaySetting.showsNoteCount,
            titleDisplayMode: viewModel.displaySetting.titleDisplayMode,
            allowsStructuralAnimation: hasPresentedInitialContent,
            isEditing: viewModel.isEditing,
            bottomContentInset: bottomContentInset,
            selectedIDs: viewModel.selectedIDSet,
            canReorder: viewModel.canReorderDefaultItems,
            isScrollObservationEnabled: isDefaultScrollObservationEnabled,
            activeWriteAction: viewModel.activeWriteAction,
            movableIDs: movableIDs(in: sections.flatMap(\.items)),
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
            onContextAction: handleAggregateContextAction(_:group:),
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
            onOpenNoteRoute(.create(seed: NoteEditorSeed(
                bookId: bookID,
                chapterId: nil,
                contentHTML: "",
                ideaHTML: ""
            )))
        case .pin:
            viewModel.pinItem(itemID)
        case .unpin:
            viewModel.unpinItem(itemID)
        case .editBook:
            guard case .book(let bookID) = itemID else { return }
            onOpenRoute(.edit(bookId: bookID))
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

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        BookGridView(viewModel: BookViewModel(repository: repositories.bookRepository))
    }
}
