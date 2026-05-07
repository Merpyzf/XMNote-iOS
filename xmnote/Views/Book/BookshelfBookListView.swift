//
//  BookshelfBookListView.swift
//  xmnote
//
//  Created by Codex on 2026/5/6.
//

/**
 * [INPUT]: 依赖 BookshelfBookListRoute 提供聚合上下文，依赖 BookRepositoryProtocol 提供二级列表观察流，依赖外层 BookRoute 闭包承接书籍详情导航
 * [OUTPUT]: 对外提供 BookshelfBookListView，使用 UIKit UICollectionView 展示分组、状态、标签、来源、评分、作者与出版社聚合下的书籍列表和编辑选择入口
 * [POS]: Book 模块二级列表页，被 BookRoute.bookshelfList 导航目标消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书架聚合入口的二级只读列表页，通过 Repository 实时观察聚合上下文下的书籍集合。
struct BookshelfBookListView: View {
    @Environment(RepositoryContainer.self) private var repositories
    let route: BookshelfBookListRoute
    let onOpenRoute: (BookRoute) -> Void
    @State private var viewModel: BookshelfBookListViewModel?

    /// 构建二级书籍列表；点击书籍时把导航意图交回外层 NavigationStack。
    init(
        route: BookshelfBookListRoute,
        onOpenRoute: @escaping (BookRoute) -> Void = { _ in }
    ) {
        self.route = route
        self.onOpenRoute = onOpenRoute
    }

    var body: some View {
        Group {
            if let viewModel {
                BookshelfBookListContentView(
                    viewModel: viewModel,
                    onOpenRoute: onOpenRoute
                )
            } else {
                Color.clear
                    .background(Color.surfacePage.ignoresSafeArea())
            }
        }
        .task(id: route) {
            viewModel = BookshelfBookListViewModel(
                route: route,
                repository: repositories.bookRepository
            )
        }
    }
}

/// 二级书籍列表 SwiftUI 壳层，承接搜索栏、加载态和 UIKit 集合区。
private struct BookshelfBookListContentView: View {
    @Bindable var viewModel: BookshelfBookListViewModel
    let onOpenRoute: (BookRoute) -> Void

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
            } else {
                BookshelfBookListSearchBar(
                    text: $viewModel.searchKeyword,
                    onClear: viewModel.clearSearchKeyword
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            BookshelfBookListCollectionView(
                snapshot: viewModel.snapshot,
                subtitle: viewModel.subtitle,
                contentState: viewModel.contentState,
                isEditing: viewModel.isEditing,
                selectedBookIDs: viewModel.selectedBookIDSet,
                onToggleSelection: viewModel.toggleSelection,
                onOpenBook: { bookID in
                    onOpenRoute(.detail(bookId: bookID))
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: viewModel.isEditing)
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationTitle(viewModel.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !viewModel.isEditing, viewModel.canEnterEditing {
                    Button("选择", action: viewModel.enterEditing)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: Spacing.none) {
            if viewModel.isEditing {
                BookshelfBookListEditBottomBar(
                    selectedCount: viewModel.selectedCount,
                    actions: viewModel.editActions,
                    notice: viewModel.actionNotice,
                    onAction: viewModel.performPlaceholderAction
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// 二级书籍列表 UIKit 集合区，负责滚动、空态和行点击命中。
private struct BookshelfBookListCollectionView: UIViewRepresentable {
    let snapshot: BookshelfBookListSnapshot
    let subtitle: String
    let contentState: BookshelfContentState
    let isEditing: Bool
    let selectedBookIDs: Set<Int64>
    let onToggleSelection: (Int64) -> Void
    let onOpenBook: (Int64) -> Void

    /// 创建 collection view 承载视图。
    func makeUIView(context: Context) -> BookshelfBookListCollectionHostView {
        let view = BookshelfBookListCollectionHostView()
        view.update(with: configuration, animated: false)
        return view
    }

    /// 同步最新路由载荷。
    func updateUIView(_ uiView: BookshelfBookListCollectionHostView, context: Context) {
        uiView.update(with: configuration, animated: true)
    }

    private var configuration: BookshelfBookListCollectionConfiguration {
        BookshelfBookListCollectionConfiguration(
            snapshot: snapshot,
            subtitle: subtitle,
            contentState: contentState,
            isEditing: isEditing,
            selectedBookIDs: selectedBookIDs,
            onToggleSelection: onToggleSelection,
            onOpenBook: onOpenBook
        )
    }
}

/// UIKit 集合区输入配置。
private struct BookshelfBookListCollectionConfiguration {
    let snapshot: BookshelfBookListSnapshot
    let subtitle: String
    let contentState: BookshelfContentState
    let isEditing: Bool
    let selectedBookIDs: Set<Int64>
    let onToggleSelection: (Int64) -> Void
    let onOpenBook: (Int64) -> Void

    static let empty = BookshelfBookListCollectionConfiguration(
        snapshot: .empty,
        subtitle: "",
        contentState: .loading,
        isEditing: false,
        selectedBookIDs: [],
        onToggleSelection: { _ in },
        onOpenBook: { _ in }
    )
}

/// 二级书籍列表 item 类型，把 subtitle、empty 与书籍行统一交给 collection view 管理。
private enum BookshelfBookListCollectionItem: Hashable {
    case subtitle(String)
    case loading
    case empty
    case book(BookshelfBookListItem)
}

/// UICollectionView 承载视图，负责单列布局和行点击。
private final class BookshelfBookListCollectionHostView: UIView {
    private var configuration = BookshelfBookListCollectionConfiguration.empty
    private var items: [BookshelfBookListCollectionItem] = []

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .automatic
        view.keyboardDismissMode = .onDrag
        view.dataSource = self
        view.delegate = self
        view.register(
            BookshelfBookListCollectionCell.self,
            forCellWithReuseIdentifier: BookshelfBookListCollectionCell.reuseIdentifier
        )
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 同步 SwiftUI 路由载荷到本地 item 列表。
    func update(
        with configuration: BookshelfBookListCollectionConfiguration,
        animated: Bool
    ) {
        let nextItems = Self.makeItems(from: configuration)
        let didChangeEditing = configuration.isEditing != self.configuration.isEditing
        self.configuration = configuration
        guard nextItems != items else {
            refreshVisibleCells()
            if didChangeEditing {
                collectionView.collectionViewLayout.invalidateLayout()
            }
            return
        }
        items = nextItems
        collectionView.reloadData()
    }
}

private extension BookshelfBookListCollectionHostView {
    /// 建立 collection view 约束。
    func setupViewHierarchy() {
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "bookshelf.book-list.collection"

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 使用单列估算高度布局，让 SwiftUI row 自适应文本高度。
    func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(92)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(92)
            )
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = Spacing.base
            section.contentInsets = NSDirectionalEdgeInsets(
                top: Spacing.base,
                leading: Spacing.screenEdge,
                bottom: Spacing.base,
                trailing: Spacing.screenEdge
            )
            return section
        }
    }

    /// 根据观察快照生成 collection item。
    static func makeItems(from configuration: BookshelfBookListCollectionConfiguration) -> [BookshelfBookListCollectionItem] {
        var nextItems: [BookshelfBookListCollectionItem] = []
        if !configuration.subtitle.isEmpty {
            nextItems.append(.subtitle(configuration.subtitle))
        }
        switch configuration.contentState {
        case .loading:
            nextItems.append(.loading)
        case .empty:
            nextItems.append(.empty)
        case .error(let message):
            nextItems.append(.subtitle(message.isEmpty ? "书籍加载失败" : message))
            nextItems.append(.empty)
        case .content:
            nextItems.append(contentsOf: configuration.snapshot.books.map(BookshelfBookListCollectionItem.book))
        }
        return nextItems
    }

    /// 刷新可见 cell 中的闭包和选中态，不触发布局重载。
    func refreshVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? BookshelfBookListCollectionCell,
                  items.indices.contains(indexPath.item) else {
                continue
            }
            cell.configure(with: items[indexPath.item], configuration: configuration)
        }
    }
}

extension BookshelfBookListCollectionHostView: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BookshelfBookListCollectionCell.reuseIdentifier,
            for: indexPath
        ) as? BookshelfBookListCollectionCell else {
            return UICollectionViewCell()
        }
        cell.configure(with: items[indexPath.item], configuration: configuration)
        return cell
    }
}

extension BookshelfBookListCollectionHostView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard items.indices.contains(indexPath.item) else { return }
        if case .book(let book) = items[indexPath.item] {
            if configuration.isEditing {
                configuration.onToggleSelection(book.id)
            } else {
                configuration.onOpenBook(book.id)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard items.indices.contains(indexPath.item) else { return false }
        if case .book = items[indexPath.item] {
            return true
        }
        return false
    }
}

/// 二级列表 cell，使用 UIHostingConfiguration 复用 SwiftUI 行视觉。
private final class BookshelfBookListCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfBookListCollectionCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 渲染当前 item。
    func configure(
        with item: BookshelfBookListCollectionItem,
        configuration: BookshelfBookListCollectionConfiguration
    ) {
        backgroundColor = .clear
        contentConfiguration = UIHostingConfiguration {
            switch item {
            case .subtitle(let subtitle):
                BookshelfBookListSubtitleView(subtitle: subtitle)
            case .loading:
                LoadingStateView("正在整理书籍", style: .inline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 320)
            case .empty:
                EmptyStateView(icon: "books.vertical", message: "暂无书籍")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 320)
            case .book(let book):
                BookshelfBookListRowView(
                    book: book,
                    isEditing: configuration.isEditing,
                    isSelected: configuration.selectedBookIDs.contains(book.id)
                )
            }
        }
        .margins(.all, 0)
    }
}

/// 二级列表搜索栏。
private struct BookshelfBookListSearchBar: View {
    @Binding var text: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索书名或作者", text: $text)
                .font(AppTypography.body)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(minHeight: 40)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
    }
}

/// 二级列表副标题。
private struct BookshelfBookListSubtitleView: View {
    let subtitle: String

    var body: some View {
        Text(subtitle)
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.tiny)
    }
}

/// 二级列表书籍行视觉。
private struct BookshelfBookListRowView: View {
    let book: BookshelfBookListItem
    let isEditing: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                48,
                urlString: book.cover,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(book.title)
                    .font(AppTypography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text(metadata)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.compact)

            if !isEditing {
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
            }
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .opacity(isEditing ? (isSelected ? 1 : 0.78) : 1)
        .overlay(alignment: .topTrailing) {
            if isEditing {
                BookshelfSelectionOverlay(isSelected: isSelected)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var metadata: String {
        let authorText = book.author.isEmpty ? "未知作者" : book.author
        guard book.noteCount > 0 else { return authorText }
        return "\(authorText) · \(book.noteCount)条书摘"
    }

    private var accessibilityLabel: String {
        if isEditing {
            return "\(book.title)，\(metadata)，\(isSelected ? "已选中" : "未选中")"
        }
        return "\(book.title)，\(metadata)"
    }
}

/// 二级列表编辑态底部栏，先提供 Android 管理动作入口，占位写入会显示保护提示。
private struct BookshelfBookListEditBottomBar: View {
    let selectedCount: Int
    let actions: [BookshelfBookListEditAction]
    let notice: String?
    let onAction: (BookshelfBookListEditAction) -> Void

    var body: some View {
        VStack(spacing: Spacing.cozy) {
            HStack(spacing: Spacing.compact) {
                ForEach(primaryActions) { action in
                    Button {
                        onAction(action)
                    } label: {
                        actionLabel(action)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title)
                }

                if !secondaryActions.isEmpty {
                    Menu {
                        ForEach(secondaryActions) { action in
                            Button(role: action.isDestructive ? .destructive : nil) {
                                onAction(action)
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    } label: {
                        actionLabel(.setTag, titleOverride: "更多", iconOverride: "ellipsis.circle", isDestructiveOverride: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更多操作")
                }
            }
            .padding(.horizontal, Spacing.screenEdge)

            Text(statusText)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(2)
                .padding(.horizontal, Spacing.screenEdge)
        }
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.cozy)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var statusText: String {
        if let notice, !notice.isEmpty {
            return notice
        }
        if selectedCount == 0 {
            return "选择书籍后可批量管理；重命名与删除需完成 Android 写入核对后开放"
        }
        return "已选 \(selectedCount) 本，批量写入动作暂未开放"
    }

    private var primaryActions: [BookshelfBookListEditAction] {
        Array(actions.prefix(4))
    }

    private var secondaryActions: [BookshelfBookListEditAction] {
        Array(actions.dropFirst(4))
    }

    private func actionLabel(
        _ action: BookshelfBookListEditAction,
        titleOverride: String? = nil,
        iconOverride: String? = nil,
        isDestructiveOverride: Bool? = nil
    ) -> some View {
        VStack(spacing: Spacing.compact) {
            Image(systemName: iconOverride ?? action.systemImage)
                .font(AppTypography.headline)
                .fontWeight(.medium)
            Text(titleOverride ?? action.title)
                .font(AppTypography.caption2)
                .lineLimit(1)
        }
        .foregroundStyle((isDestructiveOverride ?? action.isDestructive) ? Color.feedbackError : Color.textPrimary)
        .frame(width: 64)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        BookshelfBookListView(route: BookshelfBookListRoute(
            context: .tag(1),
            title: "文学",
            subtitleHint: "2本"
        ))
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
